// RuleBlocks.swift
// Custom mode's Block route, the address half: the `ip`, `cidr`, GeoIP and service-range addresses a
// Block rule names become reject routes (RTF_REJECT), through the helper's block routes that VPN
// Only already uses (`addBlockRoutesBatch`, helper 2.6.0). A packet to one fails at once with "no
// route to host". Names are blackholed by the DNS forwarder instead (WildcardPlanner).
//
// These blocks have their own record, `ruleBlocks`, apart from VPN Only's `blockedRoutes`: those are
// released when the VPN returns and when the mode is not VPN Only, these follow the rules. They are
// removed with every other route when a mode switch, a pause, Remove All Routes or a quit takes
// them (`removeAllRoutes`), and kept across a VPN drop, which is not a reason to stop blocking.

import Foundation

extension RouteManager {

    /// The addresses a block must not cover: the gateways and every DNS server in use.
    func protectedAddresses() async -> [String] {
        // The gateways, the DNS servers the app falls back to, the one it found at start, and the
        // ones the system resolvers use now (the physical network's and the tunnel's).
        let output = await runProcessAsync("/usr/sbin/scutil", arguments: ["--dns"], timeout: 3)?.output ?? ""
        let active = ScutilDNS.parse(output).flatMap(\.nameservers)
        return [localGateway, vpnGateway, detectedDNSServerDisplay].compactMap { $0 } + config.fallbackDNS + active
    }

    /// A block on `destination` would cut the Mac off from its own network: it holds the gateway
    /// the routes go through, the VPN's, or a DNS server the app asks. Refused, as the batch add
    /// refuses a route to the VPN's gateway.
    static func address(in protected: [String], isCoveredBy destination: String) -> Bool {
        protected.contains { address in
            guard WildcardIPv4.parse(address) != nil else { return false }
            return destination.contains("/") ? RuleResolver.ipv4(address, inCIDR: destination) : destination == address
        }
    }

    /// Makes `ruleBlocks` the blocks the rules want: puts the new ones in, takes the ones no rule
    /// wants any more out. Called by every Custom apply, so editing a rule, switching it off or
    /// changing its route is enough.
    func applyRuleBlocks(_ desired: [RouteCompiler.DesiredBlock]) async {
        guard !isPaused, !isShuttingDown,
              HelperManager.shared.isHelperInstalled || addBlockRoutesBatchOverrideForTests != nil else { return }
        var wanted: [String: String] = [:]
        var refused = 0
        let protected = await protectedAddresses()
        for block in desired where wanted[block.destination] == nil {
            if Self.address(in: protected, isCoveredBy: block.destination) { refused += 1; continue }
            wanted[block.destination] = block.source
        }
        if refused > 0 {
            log(.warning, "Block: \(refused) address range(s) left out because they hold the gateway or a DNS server this Mac uses")
        }
        let have = Set(ruleBlocks.map(\.destination))

        // An address a rule routes now was a block a moment ago: the install replaced the block
        // (RouteKernel.installStep), so its record goes and the kernel is left alone. Removing it
        // by destination would take the new route.
        let routedNow = Set(activeRoutes.map(\.destination))
        let stale = have.subtracting(wanted.keys)
        ruleBlocks.removeAll { stale.contains($0.destination) && routedNow.contains($0.destination) }
        let toRelease = stale.subtracting(routedNow).sorted()
        if !toRelease.isEmpty {
            let result = await removeRoutesBatchVia(toRelease)
            let failed = (result.error != nil && result.failedDestinations.isEmpty) ? Set(toRelease) : Set(result.failedDestinations)
            ruleBlocks.removeAll { toRelease.contains($0.destination) && !failed.contains($0.destination) }
            if !failed.isEmpty { log(.warning, "Block: \(failed.count) address(es) could not be released and stay listed for the next try") }
        }

        // An address already routed (a wildcard learned it, say) is left to its route: first match was
        // decided when the rules were compiled, so this is only a race, and a block would replace it.
        let fresh = wanted.keys.filter { !have.contains($0) && !routedNow.contains($0) }.sorted()
        if !fresh.isEmpty {
            let epoch = ruleBlockEpoch
            let result = await addBlockRoutesBatchVia(fresh)
            // An error with no failed destinations is a deadline: the helper may still install the
            // batch, so these are kept as ours (a removal of one that never landed is harmless).
            let failed = Set(result.failedDestinations)
            let blocked = fresh.filter { !failed.contains($0) }
            let now = Date()
            ruleBlocks += blocked.map { ActiveRoute(destination: $0, gateway: "", source: wanted[$0] ?? "", timestamp: now) }
            if epoch != ruleBlockEpoch {
                // A teardown ran while the batch was out: what it installed is released now.
                await releaseRuleBlocks(reason: "the batch finished after a teardown")
                return
            }
            if failed.isEmpty {
                log(.success, "Block: \(blocked.count) address(es) blocked")
            } else {
                log(.warning, "Block: \(blocked.count) address(es) blocked, \(failed.count) could not be (\(result.error ?? "no reason given")); the next apply tries again")
            }
        }
        // A kept block follows the rule that holds it now, so its row counts it.
        for i in ruleBlocks.indices {
            if let source = wanted[ruleBlocks[i].destination], source != ruleBlocks[i].source {
                ruleBlocks[i] = ActiveRoute(destination: ruleBlocks[i].destination, gateway: "", source: source,
                                            timestamp: ruleBlocks[i].timestamp)
            }
        }
    }

    /// Takes every rule block out. A failed removal keeps its record, so a later pass, the next
    /// teardown or the startup sweep can still remove it.
    func releaseRuleBlocks(reason: String) async {
        ruleBlockEpoch &+= 1
        guard !ruleBlocks.isEmpty else { return }
        // A block an install replaced is a route, and was removed with the routes.
        let routedNow = Set(activeRoutes.map(\.destination))
        ruleBlocks.removeAll { routedNow.contains($0.destination) }
        guard !ruleBlocks.isEmpty else { return }
        let destinations = Array(Set(ruleBlocks.map(\.destination))).sorted()
        guard HelperManager.shared.isHelperInstalled || removeRoutesBatchOverrideForTests != nil else {
            log(.error, "Cannot release \(destinations.count) block(s): the helper is not ready; they stay listed so they can still be removed")
            return
        }
        let result = await removeRoutesBatchVia(destinations)
        let failed = (result.error != nil && result.failedDestinations.isEmpty) ? Set(destinations) : Set(result.failedDestinations)
        ruleBlocks.removeAll { !failed.contains($0.destination) }
        if failed.isEmpty {
            log(.info, "Released \(destinations.count) block(s): \(reason)")
        } else {
            log(.warning, "Released \(destinations.count - failed.count) block(s) (\(reason)); \(failed.count) could not be removed and stay listed for the next try")
        }
    }

    /// How many addresses the Block rule with this pattern holds now, for its row.
    func ruleBlockCount(forPattern pattern: String) -> Int {
        ruleBlocks.filter { $0.source == pattern }.count
    }
}
