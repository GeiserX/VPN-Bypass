// WildcardEngine.swift
// Drives always-on wildcard domains from the app: tells the helper which wildcards to serve,
// drains the routes its forwarder learned into `activeRoutes`, keeps the ledger, and expires
// what has not been looked up for a day. Design: docs/research/wildcards-and-network-extension.md.
//
// The engine runs only while routes are live: it starts after an apply commits and stops when
// Remove All Routes, a mode switch or quit clears them, exactly as the listed domains do. With
// no wildcard it costs nothing: no timer, no forwarder, no resolver file.
//
// A learned route is an ordinary `ActiveRoute` whose source is the wildcard (`*.example.com`).
// That puts it in the startup sweep, in `reconcileMissingRoutes` and in teardown with no extra
// code; the apply paths only have to leave it alone (`RouteManager.isLearnedWildcardRoute`).

import Foundation

@MainActor
final class WildcardEngine {
    static let drainInterval: TimeInterval = 5
    static let maintenanceInterval: TimeInterval = 60

    private unowned let manager: RouteManager
    private let ledgerURL: URL
    private(set) var ledger: WildcardLedger

    /// True from launch, and from every Remove All Routes, until the next apply commits.
    private(set) var suspended = true
    /// What the helper was last asked to serve. Nil when unknown: the next pass sets it again.
    private var sentSpecs: [WildcardSpec]?
    /// The part of `sentSpecs` the helper actually serves: a suffix whose resolver file is
    /// another program's is left out. Reset with `sentSpecs`.
    private var servedSpecs: [WildcardSpec]?
    /// The wildcards configured at the last pass, to tell when one is added. Nil after launch
    /// and after Remove All Routes: the next pass only takes note.
    private var lastConfigured: Set<String>?
    private var sentGuard: WildcardSafetyGuard?
    private var lastSkipped: [String: String] = [:]
    private var warnedShadows: [String: [String]] = [:]
    private var adoptedLedger = false
    private var ledgerDirty = false
    private var lastMaintenance = Date()
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var syncAgain = false
    private var draining = false
    /// The kernel table adoption reads; tests hand in their own.
    var kernelTable: () -> [RouteKernel.KernelRoute]? = RouteKernel.currentTable

    init(manager: RouteManager, ledgerURL: URL) {
        self.manager = manager
        self.ledgerURL = ledgerURL
        ledger = WildcardLedger.load(from: ledgerURL)
    }

    var isServing: Bool { !(servedSpecs ?? []).isEmpty }

    // MARK: - Triggers

    /// Run a pass soon. Passes never overlap: one asked for while another runs follows it.
    func requestSync() {
        guard syncTask == nil else {
            syncAgain = true
            return
        }
        syncTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.syncAgain = false
                await self.sync()
            } while self.syncAgain && !self.manager.isShuttingDown
            self.syncTask = nil
        }
    }

    /// An apply committed: routes are live again.
    func routesApplied() {
        // Paused, nothing applies; a commit that raced the pause must not start learning.
        guard !manager.isPaused else { return }
        if suspended {
            suspended = false
            adoptedLedger = false
        }
        requestSync()
    }

    /// Remove All Routes ran (the button, a mode switch, VPN Only losing its VPN, quit). Its
    /// learned routes went with the rest; stop the forwarder and forget the ledger, as the
    /// listed domains forget theirs.
    func routesCleared() async {
        suspended = true
        lastConfigured = nil
        stopTimer()
        if !ledger.seen.isEmpty {
            ledger = WildcardLedger()
            saveLedger()
        }
        // Sent even when we believe nothing is served: a helper the app lost track of may
        // still be answering, and its files must go before the app does.
        if HelperManager.shared.isHelperInstalled, sentSpecs != [] {
            let result = await HelperManager.shared.setWildcards([], guard: WildcardSafetyGuard())
            sentSpecs = result.ok ? [] : nil
            servedSpecs = sentSpecs
            // A lookup that finished just before the stop may have added a route the app has
            // not drained yet. Nothing installs after the stop, so one drain gets them all;
            // `record` takes them out again while suspended.
            if result.ok, let drained = await HelperManager.shared.drainWildcardRoutes() {
                record(drained.routes)
            }
        }
    }

    /// Ledger addresses the startup sweep must keep: a previous run learned them for a
    /// wildcard that is still configured.
    func ledgerDestinations(config: Config) -> Set<String> {
        ledger.addresses(for: Set(WildcardPlanner.configuredSuffixes(config)))
    }

    // MARK: - One pass

    /// One pass, awaited, for tests.
    func syncForTests() async { await sync() }

    private func sync() async {
        guard !manager.isShuttingDown else { return }
        let config = manager.config
        let configured = Set(WildcardPlanner.configuredSuffixes(config))
        // A wildcard added while routes are live works at once, as a listed name does, even
        // when no apply has run since launch (auto-apply off) or since Remove All Routes.
        // Not while paused: a wildcard added then is saved, and Resume starts it.
        if suspended, !manager.isPaused, manager.isVPNConnected, let before = lastConfigured, !configured.subtracting(before).isEmpty {
            suspended = false
            adoptedLedger = false
        }
        lastConfigured = configured
        await dropLearnedRoutes(notIn: configured)
        // Whatever the helper serves: the startup sweep kept these routes for a wildcard that
        // is still configured, and only a tracked route is taken out by teardown and expiry.
        if !suspended { adoptLedgerIfNeeded(suffixes: configured) }

        guard HelperManager.shared.isHelperInstalled else {
            sentSpecs = nil
            servedSpecs = nil
            stopTimer()
            return
        }

        var specs: [WildcardSpec] = []
        var safetyGuard = WildcardSafetyGuard()
        var resolvers: [ScutilDNS.Resolver] = []
        if !suspended, manager.isVPNConnected, !configured.isEmpty {
            resolvers = ScutilDNS.parse(await manager.runProcessAsync("/usr/sbin/scutil", arguments: ["--dns"], timeout: 3)?.output ?? "")
            let env = await environment(config: config, resolvers: resolvers)
            let planned = WildcardPlanner.plan(config, env: env)
            specs = planned.specs
            safetyGuard = WildcardPlanner.safetyGuard(config, env: env, specs: specs)
            if planned.skipped != lastSkipped {
                for (suffix, reason) in planned.skipped.sorted(by: { $0.key < $1.key }) {
                    manager.log(.warning, "Wildcard *.\(suffix) is not routed yet: \(reason)")
                }
                lastSkipped = planned.skipped
            }
        }

        // With no wildcard at all there is nothing to stop: the helper removes its files at start
        // and when its lease runs out. Asking anyway would cost a call per pass, and an error per
        // pass from a helper older than 2.5.0 until it is replaced.
        if configured.isEmpty && sentSpecs == nil {
            sentSpecs = []
            servedSpecs = []
            sentGuard = safetyGuard
        }

        if specs != sentSpecs || safetyGuard != sentGuard {
            let result = await HelperManager.shared.setWildcards(specs, guard: safetyGuard)
            guard !manager.isShuttingDown else { return }
            if result.ok {
                sentSpecs = specs
                servedSpecs = specs.filter { !result.unserved.contains($0.suffix) }
                sentGuard = safetyGuard
                if !specs.isEmpty {
                    manager.log(.info, "Wildcards: \(specs.count - result.unserved.count) served by the helper's DNS forwarder")
                }
                for suffix in result.unserved {
                    manager.log(.warning, "Wildcard *.\(suffix) is not routed: /etc/resolver/\(suffix) belongs to another program, and the helper leaves it alone")
                }
            } else {
                sentSpecs = nil
                servedSpecs = nil
                manager.log(.error, "Wildcards could not be served: \(result.error ?? "the helper did not answer")")
            }
        }

        warnAboutShadowing(specs: specs, resolvers: resolvers)
        if isServing, let served = servedSpecs {
            await moveLearnedRoutes(to: served)
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func environment(config: Config, resolvers: [ScutilDNS.Resolver]) async -> WildcardPlanner.Environment {
        let physicalInterface = await manager.detectPhysicalInterface()
        let physicalDNS = WildcardPlanner.physicalDNS(interface: physicalInterface, resolvers: resolvers, fallback: config.fallbackDNS)
        let vpnInterface = manager.vpnInterface
        var vpnDNS = vpnInterface.map { ScutilDNS.nameservers(forInterface: $0, in: resolvers) } ?? []
        if vpnDNS.isEmpty, let iface = vpnInterface {
            // Some clients publish their servers as the default resolver with no interface.
            vpnDNS = resolvers.first(where: { !$0.scoped && $0.domain == nil && ($0.interface == nil || $0.interface == iface) })?
                .nameservers.filter { WildcardIPv4.parse($0) != nil } ?? []
        }

        let needsLinks = WildcardPlanner.configured(config).contains { if case .pinned = $0.via { return true }; return false }
        let links = needsLinks ? await manager.listVPNLinks() : []
        let manager = self.manager
        return WildcardPlanner.Environment(
            localGateway: manager.localGateway,
            physicalInterface: physicalInterface,
            physicalDNS: physicalDNS,
            vpnGateway: manager.vpnGateway,
            vpnInterface: vpnInterface,
            vpnDNS: vpnDNS,
            pinnedGateway: { manager.ifaceGateway(for: $0, links: links) },
            dnsForInterface: { ScutilDNS.nameservers(forInterface: $0, in: resolvers) }
        )
    }

    /// A more specific resolver hides part of a wildcard; say so once per change.
    private func warnAboutShadowing(specs: [WildcardSpec], resolvers: [ScutilDNS.Resolver]) {
        var now: [String: [String]] = [:]
        for spec in specs {
            let hidden = ScutilDNS.shadowing(spec.suffix, in: resolvers)
            if !hidden.isEmpty { now[spec.suffix] = hidden }
        }
        // Count only: the hiding domains are another resolver's (a VPN's split DNS, say), not
        // the user's own entries, so they stay out of the log.
        for (suffix, hidden) in now.sorted(by: { $0.key < $1.key }) where warnedShadows[suffix] != hidden {
            manager.log(.warning, "Wildcard *.\(suffix): \(hidden.count) more specific resolver(s) answer part of it, and names there are not routed")
        }
        if !specs.isEmpty || !resolvers.isEmpty { warnedShadows = now }
    }

    // MARK: - Draining

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledInCommonModes(withTimeInterval: Self.drainInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() async {
        guard !draining, !manager.isShuttingDown else { return }
        draining = true
        defer { draining = false }
        guard let drained = await HelperManager.shared.drainWildcardRoutes() else { return }
        if !drained.running && isServing {
            // The helper restarted and lost its list (and removed its files): set it again.
            sentSpecs = nil
            servedSpecs = nil
            requestSync()
        }
        record(drained.routes)
        // A table read that failed at the last pass is tried again here, not only at the next
        // change that starts a pass.
        if !suspended && !adoptedLedger {
            adoptLedgerIfNeeded(suffixes: Set(WildcardPlanner.configuredSuffixes(manager.config)))
        }

        if Date().timeIntervalSince(lastMaintenance) >= Self.maintenanceInterval {
            lastMaintenance = Date()
            await expire()
            if ledgerDirty { saveLedger() }
        }
    }

    /// Learned routes join `activeRoutes` under their wildcard. After a Remove All Routes they
    /// are taken out again instead: the helper may have added them before it heard.
    func record(_ routes: [LearnedWildcardRoute]) {
        guard !routes.isEmpty else { return }
        if suspended {
            let tracked = Set(manager.activeRoutes.map(\.destination))
            let stray = Array(Set(routes.map(\.ip)).subtracting(tracked))
            if !stray.isEmpty { Task { _ = await manager.removeRoutesBatchVia(stray) } }
            return
        }
        let now = Date()
        for route in routes {
            ledger.record(route.ip, suffix: route.suffix, at: now)
            let source = WildcardDomain.entry(for: route.suffix)
            if let i = manager.activeRoutes.firstIndex(where: { $0.destination == route.ip && $0.source == source }) {
                if manager.activeRoutes[i].gateway != route.gateway {
                    manager.activeRoutes[i] = RouteManager.ActiveRoute(destination: route.ip, gateway: route.gateway, source: source, timestamp: now)
                }
            } else {
                manager.activeRoutes.append(RouteManager.ActiveRoute(destination: route.ip, gateway: route.gateway, source: source, timestamp: now))
            }
        }
        ledgerDirty = true
    }

    // MARK: - Keeping learned routes right

    /// After a restart: ledger addresses still in the kernel as ours are tracked again; the
    /// rest went with the reboot or the sweep and are forgotten.
    private func adoptLedgerIfNeeded(suffixes: Set<String>) {
        guard !adoptedLedger else { return }
        guard !ledger.seen.isEmpty else {
            adoptedLedger = true
            return
        }
        // A failed read leaves the flag down, so the next pass tries again.
        guard let table = kernelTable() else { return }
        adoptedLedger = true
        let ours = Dictionary(table.filter { $0.isOurs && $0.isHost }.map { ($0.destinationString, $0) },
                              uniquingKeysWith: { first, _ in first })
        for (suffix, ips) in ledger.seen {
            guard suffixes.contains(suffix) else { continue }
            let source = WildcardDomain.entry(for: suffix)
            for (ip, seen) in ips {
                guard let kernel = ours[ip], let gateway = Self.gatewayString(kernel) else {
                    ledger.remove(ip, suffix: suffix)
                    ledgerDirty = true
                    continue
                }
                if !manager.activeRoutes.contains(where: { $0.destination == ip && $0.source == source }) {
                    manager.activeRoutes.append(RouteManager.ActiveRoute(destination: ip, gateway: gateway, source: source, timestamp: seen))
                }
            }
        }
    }

    private static func gatewayString(_ route: RouteKernel.KernelRoute) -> String? {
        if let address = route.gatewayAddress { return WildcardIPv4.dotted(address) }
        if let index = route.gatewayInterfaceIndex {
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            guard if_indextoname(UInt32(index), &name) != nil else { return nil }
            return "iface:" + String(cString: name)
        }
        return nil
    }

    /// The gateway of a wildcard moved (a new network, another tunnel): its learned routes move
    /// with it now, rather than at their next lookup.
    private func moveLearnedRoutes(to specs: [WildcardSpec]) async {
        let gateways = Dictionary(specs.map { (WildcardDomain.entry(for: $0.suffix), $0.gateway) }, uniquingKeysWith: { first, _ in first })
        let stale = manager.activeRoutes.filter { route in
            guard let gateway = gateways[route.source] else { return false }
            return route.gateway != gateway
        }
        guard !stale.isEmpty, manager.acquireRouteOperation() else { return }
        defer { manager.releaseRouteOperation() }
        let epoch = manager.routeEpoch
        let batch = stale.compactMap { route in gateways[route.source].map { (destination: route.destination, gateway: $0, isNetwork: false) } }
        let result = await manager.addRoutesBatchTracked(routes: batch)
        guard manager.routeEpoch == epoch else { return }
        let failed = Set(result.failedDestinations)
        let now = Date()
        for route in stale where !failed.contains(route.destination) {
            guard let gateway = gateways[route.source],
                  let i = manager.activeRoutes.firstIndex(where: { $0.destination == route.destination && $0.source == route.source })
            else { continue }
            manager.activeRoutes[i] = RouteManager.ActiveRoute(destination: route.destination, gateway: gateway, source: route.source, timestamp: now)
        }
        manager.log(.info, "Wildcards: moved \(batch.count - failed.count) learned route(s) to the new gateway")
    }

    /// Takes out the learned routes of wildcards no longer configured (removed, switched off,
    /// another mode).
    private func dropLearnedRoutes(notIn configured: Set<String>) async {
        if ledger.keep(only: configured) { ledgerDirty = true }
        let sources = Set(configured.map(WildcardDomain.entry(for:)))
        await removeLearned { !sources.contains($0.source) }
    }

    /// Takes out a day-old learned route nobody is connected to.
    func expire(at now: Date = Date()) async {
        let netstat = await manager.runProcessAsync("/usr/sbin/netstat", arguments: ["-an", "-p", "tcp"], timeout: 5)
        // Without the connection list nothing expires: a route in use must never go.
        guard let netstat, netstat.exitCode == 0 else { return }
        let expired = ledger.expired(at: now, openPeers: OpenTCPPeers.parse(netstat.output))
        guard !expired.isEmpty else { return }
        let key: (String, String) -> String = { "\($0)|\($1)" }
        let keys = Set(expired.map { key(WildcardDomain.entry(for: $0.suffix), $0.ip) })
        let removed = await removeLearned { keys.contains(key($0.source, $0.destination)) }
        guard removed else { return }
        // A route whose kernel removal failed keeps its entry, and so its ledger line: the
        // next pass tries again.
        let left = Set(manager.activeRoutes.map { key($0.source, $0.destination) })
        let gone = expired.filter { !left.contains(key(WildcardDomain.entry(for: $0.suffix), $0.ip)) }
        guard !gone.isEmpty else { return }
        for entry in gone { ledger.remove(entry.ip, suffix: entry.suffix) }
        ledgerDirty = true
        manager.log(.info, "Wildcards: \(gone.count) learned route(s) expired after a day unused")
    }

    /// Removes the learned entries `matches` picks, and their kernel routes unless another
    /// entry still needs the address. False when the route lock was busy; the next pass retries.
    @discardableResult
    private func removeLearned(_ matches: (RouteManager.ActiveRoute) -> Bool) async -> Bool {
        let doomed = manager.activeRoutes.filter { RouteManager.isLearnedWildcardRoute($0) && matches($0) }
        guard !doomed.isEmpty else { return true }
        guard manager.acquireRouteOperation() else { return false }
        defer { manager.releaseRouteOperation() }
        let doomedIDs = Set(doomed.map(\.id))
        let stillNeeded = Set(manager.activeRoutes.filter { !doomedIDs.contains($0.id) }.map(\.destination))
        let kernel = Array(Set(doomed.map(\.destination)).subtracting(stillNeeded))
        var failed: Set<String> = []
        if !kernel.isEmpty {
            failed = Set(await manager.removeRoutesBatchVia(kernel).failedDestinations)
        }
        // A failed removal keeps its entry, as everywhere else: the route is still installed.
        manager.activeRoutes.removeAll { doomedIDs.contains($0.id) && !failed.contains($0.destination) }
        return true
    }

    private func saveLedger() {
        do {
            try ledger.save(to: ledgerURL)
            ledgerDirty = false
        } catch {
            manager.log(.warning, "Could not save the wildcard route ledger: \(error.localizedDescription)")
        }
    }
}
