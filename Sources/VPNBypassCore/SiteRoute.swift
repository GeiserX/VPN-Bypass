// SiteRoute.swift
// "Where does this site go?": which entry routes a host, and the path check on its addresses.
//
// The host is resolved as the Mac and the app resolve it, then matched in this order: an
// installed route for one of its addresses (`ActiveRoute.source` says what it was added for),
// a listed wildcard that covers the name, the Custom rules in first-match order, a list entry
// that has no route yet, and nothing. The path check (PathCheck) then says which way the
// addresses actually leave, with its control. `vpnb why <host>` prints the answer; the Status
// page's field reads the same model (`SiteRouteModel`). The matching and the wording are pure.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One checked address in an answer: what the probe saw, and its verdict.
public struct SiteRouteCheck: Codable, Equatable, Sendable {
    public var address: String
    public var interface: String?
    public var routeInterface: String?
    public var gateway: String?
    public var sourceAddress: String?
    public var answer: PathCheck.Answer
    public var latencyMs: Double?
    /// Nil for the control, and when there was no way to judge against.
    public var verdict: PathCheck.Verdict?

    public init(_ probe: PathCheck.Probe, verdict: PathCheck.Verdict?) {
        address = probe.address
        interface = probe.interface
        routeInterface = probe.routeInterface
        gateway = probe.gateway
        sourceAddress = probe.sourceAddress
        answer = probe.answer
        latencyMs = probe.latencyMs
        self.verdict = verdict
    }
}

/// The answer to "where does this site go?".
public struct SiteRouteAnswer: Codable, Equatable, Sendable {
    /// What decided the way.
    public enum Match: String, Codable, Equatable, Sendable {
        /// An installed route for one of its addresses.
        case route
        /// A listed wildcard covers the name; its routes are learned on lookup.
        case wildcard
        /// Custom mode: a rule matched.
        case rule
        /// Custom mode: no rule matched, the default route takes it.
        case defaultRoute
        /// On the list, but none of its addresses has a route now.
        case listed
        /// Not on any list.
        case none
        /// The name did not resolve.
        case unresolved
        /// Routing is paused: the app's routes are out, so it follows the VPN until the pause ends.
        case paused
    }

    /// The whole check, worst address first.
    public enum Verdict: String, Codable, Equatable, Sendable {
        case ok, noAnswer, wrongWay, unknown, checkBroken, notChecked, noVPN, unresolved
    }

    public var host: String
    public var mode: String
    public var addresses: [String]
    public var match: Match
    /// route: what the route was added for; wildcard and listed: the list entry; rule: its pattern.
    public var entry: String?
    /// route: the installed destination (an address or a range).
    public var routedDestination: String?
    /// rule: its position among the enabled rules, from 1, and its match type.
    public var rulePosition: Int?
    public var ruleMatchType: String?
    /// rule and defaultRoute: the route's name.
    public var routeName: String?
    /// The way the addresses should leave ("physical" or "tunnel:utun4"); nil when the routing
    /// table does not decide it (a proxy, an exit node).
    public var expected: String?
    public var checks: [SiteRouteCheck]
    public var control: SiteRouteCheck?
    public var verdict: Verdict
    /// One or two sentences in the app's language.
    public var summary: String
    /// Nothing lists it, so the Status page offers to add it.
    public var canAdd: Bool
    /// While routing is paused, how long for (`PauseState.wireDescription`); nil otherwise.
    public var paused: String? = nil
}

enum SiteRoute {
    /// Addresses path-checked per answer, so `why` stays within a few seconds.
    static let maxChecked = 4

    /// What the matching reads, copied off RouteManager.
    struct Snapshot {
        var mode: RoutingMode
        /// True when the Custom rule engine runs.
        var custom: Bool
        /// The current mode's list: the Bypass list, or VPN Only's.
        var list: [DomainEntry]
        /// Bypass: the enabled services. Custom: every service, since a service rule reads its
        /// service whether or not the Bypass list has it on (RuleDestinationBuilder).
        var services: [ServiceEntry]
        var rules: [Rule]
        var routes: [Route]
        var defaultRouteId: UUID?
        var activeRoutes: [(destination: String, gateway: String, source: String)]
        var localGateway: String?
        /// Nil while no VPN is connected.
        var vpnInterface: String?
        /// Custom routes pinned to one tunnel, by id: the interface the pin resolves to now
        /// (`RouteManager.ifaceGateway`, which follows a renumbered utun). A pinned route
        /// missing here is not up, so its traffic takes the system's default.
        var pinnedInterfaces: [UUID: String] = [:]
        /// The pause in progress, if any: its routes are out, so the lists decide nothing.
        var pause: PauseState? = nil
    }

    /// What `match` found, before the check.
    struct Found: Equatable {
        var match: SiteRouteAnswer.Match
        /// route: the address whose installed route matched, so the check probes it.
        var address: String? = nil
        var entry: String? = nil
        var routedDestination: String? = nil
        var rulePosition: Int? = nil
        var ruleMatchType: String? = nil
        var routeName: String? = nil
        /// Nil when the routing table does not decide the way.
        var expected: PathCheck.Way?
        /// paused: the pause, and what would match once it ends (for the Add offer).
        var pause: PauseState? = nil
        var matchAfterPause: SiteRouteAnswer.Match? = nil
        /// paused: whether a VPN is up, so the sentence says the site follows it or not.
        var vpnUp: Bool = true
    }

    // MARK: - Matching

    static func match(host: String, addresses: [String], in s: Snapshot) -> Found {
        // The pause rides along on every answer, so `paused` is there whatever matched.
        guard !addresses.isEmpty else { return Found(match: .unresolved, expected: nil, pause: s.pause) }
        // Paused, the app's routes are out (Pause.swift), and Pause runs only where that sends
        // everything through the VPN: an entry's missing route is the pause, not a stale lookup.
        // A route the pause could not remove is still in, so that answer stands.
        if let pause = s.pause {
            var lists = s
            lists.pause = nil
            let after = match(host: host, addresses: addresses, in: lists)
            if after.match == .route {
                var kept = after
                kept.pause = pause
                return kept
            }
            let loopback = addresses.allSatisfy { $0.hasPrefix("127.") }
            return Found(match: .paused, entry: after.entry,
                         expected: loopback ? .physical : (s.vpnInterface.map { .tunnel($0) } ?? .physical),
                         pause: pause, matchAfterPause: after.match, vpnUp: s.vpnInterface != nil)
        }
        // With no VPN there is one way out, around every tunnel, listed or not.
        let vpnWay: PathCheck.Way = s.vpnInterface.map { .tunnel($0) } ?? .physical
        let listedWay: PathCheck.Way = s.mode == .vpnOnly ? vpnWay : .physical
        let unlistedWay: PathCheck.Way = s.mode == .vpnOnly ? .physical : vpnWay
        let serviceNames = Dictionary(s.services.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Loopback never enters a tunnel, whatever the mode, so an unrouted one expects no tunnel.
        let loopback = addresses.allSatisfy { $0.hasPrefix("127.") }

        // 1. An installed route, host routes before ranges. VPN Only's catch-alls are what an
        //    unlisted address takes, so they are not a match.
        let installed = s.activeRoutes.filter { $0.source != ClassicRouteCompiler.catchAllSource }
        for address in addresses {
            let hit = installed.first { $0.destination == address }
                ?? installed.first { $0.destination.contains("/") && RuleResolver.ipv4(address, inCIDR: $0.destination) }
            if let hit {
                return Found(match: .route, address: address, entry: serviceNames[hit.source] ?? hit.source,
                             routedDestination: hit.destination,
                             expected: PathCheck.way(forGateway: hit.gateway, localGateway: s.localGateway,
                                                     vpnInterface: s.vpnInterface))
            }
        }

        if s.custom {
            // 2. Custom: the rules, first match by order, a name rule or an address rule alike.
            let servicesOfHost = Set(s.services.filter { service in
                service.domains.contains { domainCovers($0, host) }
                    || addresses.contains { a in service.ipRanges.contains { RuleResolver.ipv4(a, inCIDR: $0) } }
            }.map(\.id))
            let byId = Dictionary(s.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = s.rules.filter(\.enabled).sorted { $0.order < $1.order }
            for (index, rule) in ordered.enumerated() {
                // A rule whose route is gone or turned off is inert, as RouteCompiler and
                // WildcardRoutes treat it: the name falls through to a later rule.
                guard ruleMatches(rule, host: host, addresses: addresses, services: servicesOfHost),
                      let route = byId[rule.routeId], route.enabled else { continue }
                return Found(match: .rule, entry: rule.pattern, rulePosition: index + 1,
                             ruleMatchType: rule.matchType.rawValue, routeName: route.name,
                             expected: way(for: route, vpnInterface: s.vpnInterface, pinned: s.pinnedInterfaces))
            }
            if let id = s.defaultRouteId, let route = byId[id] {
                return Found(match: .defaultRoute, routeName: route.name,
                             expected: way(for: route, vpnInterface: s.vpnInterface, pinned: s.pinnedInterfaces))
            }
            return Found(match: .none, expected: loopback ? .physical : s.vpnInterface.map { .tunnel($0) })
        }

        // 2. A listed wildcard (the most specific one, as macOS picks the resolver file).
        let enabled = s.list.filter(\.enabled)
        var wildcards = enabled.filter(\.isWildcard).map(\.domain)
        if s.mode == .bypass { wildcards += s.services.flatMap(\.domains).filter(WildcardDomain.isWildcard) }
        let suffixes = wildcards.compactMap(WildcardDomain.suffix(of:))
        if let suffix = WildcardDomain.mostSpecific(for: host, among: suffixes) {
            return Found(match: .wildcard, entry: WildcardDomain.entry(for: suffix), expected: listedWay)
        }

        // 3. Listed, with no route now: an exact name, a range holding an address, or a service.
        if let entry = enabled.first(where: { entry in
            entry.isCIDR
                ? addresses.contains { RuleResolver.ipv4($0, inCIDR: entry.domain) }
                : entry.domain.caseInsensitiveCompare(host) == .orderedSame
        }) {
            return Found(match: .listed, entry: entry.domain, expected: listedWay)
        }
        if s.mode == .bypass, let service = s.services.first(where: { service in
            service.domains.contains { $0.caseInsensitiveCompare(host) == .orderedSame }
                || addresses.contains { a in service.ipRanges.contains { RuleResolver.ipv4(a, inCIDR: $0) } }
        }) {
            return Found(match: .listed, entry: service.name, expected: listedWay)
        }

        return Found(match: .none, expected: loopback ? .physical : unlistedWay)
    }

    /// A list or service entry that covers `host`: the same name, or a wildcard above it.
    private static func domainCovers(_ entry: String, _ host: String) -> Bool {
        if let suffix = WildcardDomain.suffix(of: entry) { return WildcardDomain.matches(host, suffix: suffix) }
        return entry.caseInsensitiveCompare(host) == .orderedSame
    }

    /// The matchers RuleResolver uses, for a name and its addresses at once.
    static func ruleMatches(_ rule: Rule, host: String, addresses: [String], services: Set<String>) -> Bool {
        switch rule.matchType {
        // A wildcard written as a name rule covers the names under it, as WildcardRoutes reads it.
        case .domain: return domainCovers(rule.pattern, host)
        case .suffix:
            let pattern = WildcardDomain.suffix(of: rule.pattern) ?? rule.pattern
            return RuleResolver.domainMatchesSuffix(host, suffix: pattern)
        case .service: return services.contains(rule.pattern)
        case .ip: return addresses.contains(rule.pattern)
        case .cidr: return addresses.contains { RuleResolver.ipv4($0, inCIDR: rule.pattern) }
        case .process: return false
        }
    }

    /// The way a Custom route sends traffic: Direct around every tunnel, a VPN route into its
    /// tunnel. A pinned route takes the tunnel its pin resolves to now (`pinned`), not the saved
    /// name, which goes stale when macOS renumbers the utun; a pin that is not up falls back to
    /// the system's default, as the engine does. Nil for a proxy or a Tailscale exit, which the
    /// routing table does not decide.
    static func way(for route: Route, vpnInterface: String?, pinned: [UUID: String] = [:]) -> PathCheck.Way? {
        switch route.egress {
        case .direct: return .physical
        case .vpnDefault:
            if route.vpnSelector?.kind == .interface, let name = pinned[route.id] { return .tunnel(name) }
            return vpnInterface.map { .tunnel($0) }
        case .tailscaleExit, .proxyHTTP, .proxySOCKS5: return nil
        }
    }

    /// The way an address no route covers takes, for the control. Nil while no VPN is
    /// connected (one way out). In Custom it is the system's default route, the VPN: the engine
    /// installs kernel routes only for rules (RouteCompiler), never for the default route, so
    /// an address no rule claims follows the VPN whatever the default route says.
    static func unroutedWay(config: Config, vpnInterface: String?) -> PathCheck.Way? {
        guard let vpn = vpnInterface else { return nil }
        if RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            return .tunnel(vpn)
        }
        return PathCheck.ways(mode: config.routingMode.rawValue, vpnInterface: vpn)?.unlisted
    }

    // MARK: - The answer

    static func answer(host: String, mode: RoutingMode, addresses: [String], found: Found,
                       probes: [PathCheck.Probe], control: (probe: PathCheck.Probe, outcome: PathCheck.Control)?,
                       vpnConnected: Bool) -> SiteRouteAnswer {
        let expected = found.expected
        // A broken control means no address can be judged, so none carries a verdict.
        var controlBroken = false
        if case .broken = control?.outcome { controlBroken = true }
        let checks = probes.map { probe in
            SiteRouteCheck(probe, verdict: controlBroken ? nil : expected.map { PathCheck.verdict(probe, expected: $0) })
        }
        let verdict: SiteRouteAnswer.Verdict
        var reported = probes.first
        if found.match == .unresolved {
            verdict = .unresolved
        } else if !vpnConnected {
            verdict = .noVPN
        } else if case .broken = control?.outcome {
            verdict = .checkBroken
            reported = control?.probe
        } else if let expected {
            let worst = PathCheck.worst(probes.map { PathCheck.verdict($0, expected: expected) }) ?? .unknown
            reported = probes.first { PathCheck.verdict($0, expected: expected) == worst }
            switch worst {
            case .ok: verdict = .ok
            case .noAnswer: verdict = .noAnswer
            case .wrongWay: verdict = .wrongWay
            case .unknown: verdict = .unknown
            }
        } else {
            verdict = .notChecked
        }

        let why = whySentence(host: host, mode: mode, found: found)
        let check = checkSentence(verdict, interface: reported?.interface, expected: expected)
        return SiteRouteAnswer(
            host: host, mode: mode.rawValue, addresses: addresses, match: found.match,
            entry: found.entry, routedDestination: found.routedDestination,
            rulePosition: found.rulePosition, ruleMatchType: found.ruleMatchType, routeName: found.routeName,
            expected: expected?.code, checks: checks,
            control: control.map { SiteRouteCheck($0.probe, verdict: nil) },
            verdict: verdict, summary: check.map { why + " " + $0 } ?? why,
            canAdd: [.none, .defaultRoute].contains(found.matchAfterPause ?? found.match),
            paused: found.pause?.wireDescription)
    }

    static func whySentence(host: String, mode: RoutingMode, found: Found, now: Date = Date()) -> String {
        let entry = found.entry ?? ""
        switch found.match {
        case .paused:
            return pausedSentence(host: host, length: found.pause?.length ?? .untilResume,
                                  until: found.pause?.until,
                                  helperWait: found.pause?.reconnectedWaiting ?? false,
                                  vpnUp: found.vpnUp, now: now)
        case .unresolved:
            return String(localized: "\(host) did not resolve, so there is nothing to check.")
        case .route:
            let address = found.routedDestination ?? ""
            return entry.caseInsensitiveCompare(host) == .orderedSame
                ? String(localized: "\(host) is on your list, and its address \(address) has a route.")
                : String(localized: "\(host) uses \(address), which has a route added for \(entry).")
        case .wildcard:
            return String(localized: "\(host) is covered by \(entry), which adds its routes when it is looked up.")
        case .listed:
            return entry.caseInsensitiveCompare(host) == .orderedSame
                ? String(localized: "\(host) is on your list, but none of its addresses has a route now; Re-resolve DNS adds them.")
                : String(localized: "\(host) is listed under \(entry), but none of its addresses has a route now; Re-resolve DNS adds them.")
        case .rule:
            let position = found.rulePosition ?? 0
            let kind = found.ruleMatchType ?? ""
            let route = found.routeName ?? ""
            return String(localized: "\(host) matches rule \(position), \(kind) \(entry), which sends it to \(route).")
        case .defaultRoute:
            return String(localized: "\(host) matches no rule, so it takes the default route, \(found.routeName ?? "").")
        case .none:
            switch mode {
            case .bypass: return String(localized: "\(host) is not on your list, so it follows the VPN.")
            case .vpnOnly: return String(localized: "\(host) is not on your list, so it goes around the VPN.")
            case .custom: return String(localized: "\(host) matches no rule, so it follows the system's own routing.")
            }
        }
    }

    /// "Routing is paused until 14:32, so example.com follows the VPN until then." With no VPN
    /// up the sentence stops at the pause: the check after it says the site leaves like
    /// everything else. `helperWait`: the VPN came back, and the pause holds for the helper.
    static func pausedSentence(host: String, length: PauseLength, until: Date?, helperWait: Bool = false,
                               vpnUp: Bool = true, now: Date = Date()) -> String {
        switch length {
        case .minutes:
            let when = (until ?? now).formatted(date: .omitted, time: .shortened)
            return vpnUp
                ? String(localized: "Routing is paused until \(when), so \(host) follows the VPN until then.")
                : String(localized: "Routing is paused until \(when).")
        case .untilReconnect where helperWait && vpnUp:
            return String(localized: "Routing is paused until the helper is ready, so \(host) follows the VPN until then.")
        case .untilReconnect:
            return vpnUp
                ? String(localized: "Routing is paused until the VPN reconnects, so \(host) follows the VPN until then.")
                : String(localized: "Routing is paused until the VPN reconnects.")
        case .untilResume:
            return vpnUp
                ? String(localized: "Routing is paused until you resume, so \(host) follows the VPN until then.")
                : String(localized: "Routing is paused until you resume.")
        }
    }

    static func checkSentence(_ verdict: SiteRouteAnswer.Verdict, interface: String?,
                              expected: PathCheck.Way?) -> String? {
        let via = interface ?? "?"
        switch verdict {
        case .unresolved: return nil
        case .ok: return String(localized: "The check saw it leave through \(via), and it answered on port 443.")
        case .noAnswer: return String(localized: "The check saw it leave through \(via), but nothing answered on port 443.")
        case .wrongWay:
            if case .tunnel(let tunnel) = expected {
                return String(localized: "But the check saw it leave through \(via), not through \(tunnel).")
            }
            return String(localized: "But the check saw it leave through \(via), a tunnel, not around the VPN.")
        case .unknown: return String(localized: "The routing table named no interface for it.")
        case .checkBroken:
            return String(localized: "The check is broken: an address the app does not route also left through \(via), so it cannot tell the two ways apart.")
        case .notChecked:
            return String(localized: "A proxy or an exit node carries it, which the routing table does not decide, so the path was not checked.")
        case .noVPN: return String(localized: "The VPN is not connected, so it leaves through \(via) like everything else.")
        }
    }

    /// The first `maxChecked` addresses, with the one whose route matched swapped in when it
    /// falls outside them, so the address that decided the answer is always checked.
    static func addressesToCheck(_ addresses: [String], matched: String?) -> [String] {
        var out = Array(addresses.prefix(maxChecked))
        if let matched, !out.contains(matched), !out.isEmpty { out[out.count - 1] = matched }
        return out
    }

    // MARK: - Resolving

    /// The host's IPv4 addresses from the macOS resolver: what a browser connects to, with the
    /// hosts file and the wildcard forwarder in the path.
    static func systemAddresses(_ host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            vpnBypassProcessQueue.async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(result) }
                var out: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let info = cursor {
                    if let sa = info.pointee.ai_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil {
                            let ip = String(cString: buf)
                            if !out.contains(ip) { out.append(ip) }
                        }
                    }
                    cursor = info.pointee.ai_next
                }
                continuation.resume(returning: out)
            }
        }
    }
}

// MARK: - RouteManager

extension RouteManager {
    /// The interface each pinned Custom route resolves to now, read only when an enabled rule
    /// points at one (listing the tunnels runs ifconfig), as the apply does.
    func pinnedInterfaces() async -> [UUID: String] {
        guard Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) else { return [:] }
        let referenced = Set(config.rules.filter(\.enabled).map(\.routeId))
        let pinned = config.routes.filter {
            referenced.contains($0.id) && $0.egress == .vpnDefault && $0.vpnSelector?.kind == .interface
        }
        guard !pinned.isEmpty else { return [:] }
        let links = await listVPNLinks()
        var out: [UUID: String] = [:]
        for route in pinned {
            if let gateway = ifaceGateway(for: route, links: links), gateway.hasPrefix("iface:") {
                out[route.id] = String(gateway.dropFirst("iface:".count))
            }
        }
        return out
    }

    var siteRouteSnapshot: SiteRoute.Snapshot {
        let custom = Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode)
        return SiteRoute.Snapshot(
            mode: config.routingMode, custom: custom,
            list: config.routingMode == .vpnOnly ? config.inverseDomains : config.domains,
            services: custom ? config.services : config.services.filter(\.enabled),
            rules: config.rules, routes: config.routes, defaultRouteId: config.defaultRouteId,
            activeRoutes: activeRoutes.map { ($0.destination, $0.gateway, $0.source) },
            localGateway: localGateway, vpnInterface: isVPNConnected ? vpnInterface : nil,
            pause: pauseState)
    }

    /// "Where does this site go?" for a name, a link or an address. Nil when the input holds
    /// no host.
    func whereDoesItGo(_ input: String) async -> SiteRouteAnswer? {
        let host = cleanDomain(input).lowercased()
        guard !host.isEmpty, !host.contains(" ") else { return nil }
        var addresses: [String]
        if isValidIP(host) {
            addresses = [host]
        } else {
            // What the Mac connects to first, then what the app resolved for its routes.
            addresses = await SiteRoute.systemAddresses(host)
            for ip in await resolveIPs(for: host) ?? [] where !addresses.contains(ip) && isValidIP(ip) {
                addresses.append(ip)
            }
        }
        var snapshot = siteRouteSnapshot
        snapshot.pinnedInterfaces = await pinnedInterfaces()
        let found = SiteRoute.match(host: host, addresses: addresses, in: snapshot)
        var probes: [PathCheck.Probe] = []
        var control: (probe: PathCheck.Probe, outcome: PathCheck.Control)?
        if found.match != .unresolved {
            probes = await probeAll(SiteRoute.addressesToCheck(addresses, matched: found.address))
            if let unrouted = SiteRoute.unroutedWay(config: config, vpnInterface: snapshot.vpnInterface),
               let address = PathCheck.controlAddress(routed: snapshot.activeRoutes
                   .filter { $0.source != ClassicRouteCompiler.catchAllSource }.map(\.destination)) {
                let probe = await pathProbe(address, waitForAnswer: false)
                control = (probe, PathCheck.control(probe, unrouted: unrouted))
            }
        }
        return SiteRoute.answer(host: host, mode: config.routingMode, addresses: addresses, found: found,
                                probes: probes, control: control, vpnConnected: snapshot.vpnInterface != nil)
    }
}

/// What the Status page's "Where does this site go?" field binds to.
@MainActor
final class SiteRouteModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var answer: SiteRouteAnswer?
    @Published private(set) var isChecking = false
    /// What the last finished check was asked, so a nil answer can say the input held no host.
    @Published private(set) var checkedQuery: String?
    /// Bumped per check, so a slow answer never replaces a newer one.
    private var generation = 0

    /// The answer belongs to the text in the field: an edit hides it, so Add never adds the
    /// site that was asked before.
    var answersQuery: Bool {
        checkedQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
            == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(query: String = "", answer: SiteRouteAnswer? = nil) {
        self.query = query
        self.answer = answer
        checkedQuery = answer == nil ? nil : query
    }

    func check(_ routeManager: RouteManager? = nil) async {
        let routeManager = routeManager ?? .shared
        generation += 1
        let mine = generation
        isChecking = true
        let asked = query
        let result = await routeManager.whereDoesItGo(asked)
        guard mine == generation else { return }
        answer = result
        checkedQuery = asked
        isChecking = false
    }
}
