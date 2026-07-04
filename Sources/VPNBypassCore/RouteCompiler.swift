// RouteCompiler.swift
// Pure custom-mode route compilation (Slice 4, schemaVersion >= 2 + routingMode.custom).
//
// Maps the multi-route model (ordered rules → named routes → typed egresses) onto
// the SAME `routesToAdd` batch shape the four legacy apply paths hand to
// HelperManager.addRoutesBatch. It is deliberately pure — no async, no I/O, no
// singletons — so it is unit-testable in isolation exactly like RuleResolver /
// HookGenerator. The engine (RouteManager) does the DNS resolution up front and
// hands the already-resolved destinations in; RouteCompiler only decides, per
// destination, which gateway (if any) a kernel route should carry.
//
// Only egresses that need a kernel route emit one:
//   • .direct         → a host/net route via the local gateway.
//   • .vpnDefault     → the primary VPN (ifaceGatewayForRoute == nil) emits NOTHING
//                        (the OS default route already carries it); a *specific* VPN
//                        (ifaceGatewayForRoute == "iface:utunX") emits an iface route.
//   • .proxyHTTP / .proxySOCKS5 / .tailscaleExit → NOTHING; a loopback listener
//                        (ProxyListenerManager) serves these, so the routing table
//                        must stay clear of them.
// See docs/MULTI-ROUTE-DESIGN.md § "Locked architecture".

import Foundation

enum RouteCompiler {

    /// One desired kernel route: the exact tuple shape the apply paths already build.
    struct DesiredRoute: Equatable {
        let destination: String
        let gateway: String
        let isNetwork: Bool
        let source: String
    }

    /// Compile the enabled rules (in first-match order) + their already-resolved
    /// destinations into a deduplicated kernel-route batch.
    ///
    /// - Parameters:
    ///   - resolvedRules: each enabled rule paired with the concrete destinations its
    ///     matcher resolved to (domain/service → IPs; ip → itself; cidr → itself).
    ///     Must be supplied in evaluation order (ascending `rule.order`) — the FIRST
    ///     rule to claim a destination wins, matching RuleResolver's first-match rule.
    ///   - routes: the named routes a rule's `routeId` refers to.
    ///   - localGateway: the physical gateway `.direct` egresses route through.
    ///   - ifaceGatewayForRoute: maps a `.vpnDefault` route to a specific tunnel
    ///     (`"iface:utunX"`) or nil for the primary VPN (nil ⇒ emit nothing). For
    ///     Slice 4 this is the multi-VPN hook; earlier slices always pass a closure
    ///     returning nil, so `.vpnDefault` emits nothing (traffic stays on default).
    /// - Returns: one DesiredRoute per kernel-routable destination, first-rule-wins.
    static func compile(
        resolvedRules: [(rule: Rule, dests: [(value: String, isNetwork: Bool)])],
        routes: [Route],
        localGateway: String,
        ifaceGatewayForRoute: (Route) -> String?
    ) -> [DesiredRoute] {
        let byId = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [DesiredRoute] = []
        // A destination is "claimed" by the first rule that matches it, EVEN when that
        // rule's egress emits no kernel route (e.g. a proxy). Otherwise a later Direct
        // rule could install a kernel route for a destination the proxy listener owns,
        // splitting one destination across two egresses.
        //
        // Claiming is by CIDR CONTAINMENT, not exact string: a new destination is
        // suppressed when it is fully contained in (a subset of, or equal to) a range an
        // EARLIER rule already claimed. This is required for first-match correctness under
        // the kernel's longest-prefix-match. If an earlier /8 owns 10.0.0.0/8 and a later
        // rule routes the host 10.1.2.3 into a different egress (e.g. a specific utun),
        // both would be distinct strings and both emit — then the kernel's LPM lets the
        // /32 win for 10.1.2.3, sending it to the VPN even though the earlier /8 claimed
        // it. So the narrower-or-equal later dest is dropped; the earlier rule keeps it.
        // Directionality matters: ONLY a narrower-or-equal new dest is suppressed. A later
        // BROADER dest (e.g. a /8 after an earlier /32) still emits — LPM correctly lets
        // the earlier narrower route win for its sub-range while the broader route serves
        // the rest. IPv4 only; a non-IPv4 dest (IPv6 literal, ::/0, malformed) falls back
        // to exact-string claiming so the containment math never runs on it (never crashes).
        var claimed: [Claim] = []

        for entry in resolvedRules where entry.rule.enabled {
            // A rule pointing at a route that no longer exists — OR a route the user has
            // DISABLED — is inert: skip it entirely, and do NOT claim its destinations, so
            // they fall through to a later rule or the default. Matches the resilient
            // all-zero-UUID decode (skip, never fail the whole compile). Without the
            // `route.enabled` check, toggling a .vpnDefault route off in the Routes tab
            // would leave its iface:utunX kernel route installed.
            guard let route = byId[entry.rule.routeId], route.enabled else { continue }

            // nil gateway ⇒ this egress is served without a kernel route; the
            // destination is still claimed so no later rule re-routes it.
            let gateway: String?
            switch route.egress {
            case .direct:
                gateway = localGateway
            case .vpnDefault:
                gateway = ifaceGatewayForRoute(route)   // nil = primary VPN ⇒ no route
            case .proxyHTTP, .proxySOCKS5, .tailscaleExit:
                gateway = nil                            // a loopback listener serves it
            }

            for dest in entry.dests {
                guard claim(dest.value, in: &claimed) else { continue }  // first rule wins (by containment)
                guard let gateway else { continue }
                out.append(DesiredRoute(
                    destination: dest.value,
                    gateway: gateway,
                    isNetwork: dest.isNetwork,
                    source: entry.rule.pattern
                ))
            }
        }
        return out
    }

    // MARK: - CIDR-containment claiming

    /// One entry in the containment-aware claim list: a parsed IPv4 range (compared by
    /// CIDR containment) or a raw string (exact-match fallback for a non-IPv4 dest such
    /// as an IPv6 literal, where the containment math doesn't apply).
    private enum Claim {
        case v4(network: UInt32, prefix: Int)
        case raw(String)
    }

    /// First-match claim of `dest` against the ordered `claimed` list, containment-aware.
    /// Returns true (and records the new claim) when NO earlier claim already covers
    /// `dest`; returns false (suppress) when an earlier claim fully contains it — that
    /// earlier rule owns the IP space, so no later rule may re-route any of it. The
    /// direction is one-way: only a narrower-or-equal `dest` is suppressed; a broader
    /// `dest` is still recorded and routed (kernel LPM carves out the earlier narrower
    /// route). Mirrors Set.insert(_:).inserted, but CIDR-aware for IPv4.
    private static func claim(_ dest: String, in claimed: inout [Claim]) -> Bool {
        if let newRange = parseIPv4(dest) {
            for case let .v4(network, prefix) in claimed
                where isSubset(newRange, of: (network: network, prefix: prefix)) {
                return false
            }
            claimed.append(.v4(network: newRange.network, prefix: newRange.prefix))
        } else {
            for case let .raw(string) in claimed where string == dest { return false }
            claimed.append(.raw(dest))
        }
        return true
    }

    /// Parse an IPv4 host ("A.B.C.D" ⇒ /32) or IPv4 CIDR ("A.B.C.D/N") into a canonical
    /// (network, prefix) with the host bits below `prefix` zeroed. Returns nil for anything
    /// not parseable as IPv4 (empty, malformed, or an IPv6 literal) so the caller falls
    /// back to exact-string claiming. Dotted-quad is parsed by hand — 4 octets 0...255.
    private static func parseIPv4(_ dest: String) -> (network: UInt32, prefix: Int)? {
        let slashParts = dest.split(separator: "/", omittingEmptySubsequences: false)
        guard slashParts.count == 1 || slashParts.count == 2 else { return nil }
        let prefix: Int
        if slashParts.count == 2 {
            guard let p = Int(slashParts[1]), (0...32).contains(p) else { return nil }
            prefix = p
        } else {
            prefix = 32
        }
        let octets = slashParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var addr: UInt32 = 0
        for octet in octets {
            guard let value = UInt32(octet), value <= 255 else { return nil }
            addr = (addr << 8) | value
        }
        return (network: maskIPv4(addr, prefix), prefix: prefix)
    }

    /// Zero the host bits below `prefix` so a network address compares canonically.
    private static func maskIPv4(_ addr: UInt32, _ prefix: Int) -> UInt32 {
        if prefix <= 0 { return 0 }
        if prefix >= 32 { return addr }
        return addr & (~UInt32(0) << (32 - prefix))
    }

    /// True when `inner` is fully contained in (a subset of, or equal to) `outer`: outer's
    /// prefix is shorter-or-equal AND inner's network masked to outer's prefix equals
    /// outer's network — i.e. every address in `inner` is also in `outer`.
    private static func isSubset(
        _ inner: (network: UInt32, prefix: Int),
        of outer: (network: UInt32, prefix: Int)
    ) -> Bool {
        outer.prefix <= inner.prefix && maskIPv4(inner.network, outer.prefix) == outer.network
    }

    // MARK: - GlobalProtect catch-all guard (generalizes refuseVPNOnlyUnderGlobalProtect)

    /// Catch-all destinations that structurally defeat a full-tunnel VPN. Installing
    /// any of them into a NON-primary egress (Direct, or a specific utun — every kernel
    /// route the compiler emits is non-primary by construction) under GlobalProtect
    /// trips its route monitor and tears the tunnel down (the original incident that
    /// motivates the whole project). Custom mode is per-rule and should never produce
    /// these, but the guard is the custom-engine analog of refuseVPNOnlyUnderGlobalProtect.
    static let catchAllDestinations: Set<String> = ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1"]

    /// A destination that structurally shadows a full-tunnel VPN's default route.
    /// The canonical trio, PLUS any CIDR with prefix length <= 1 (a /0 or /1 covers
    /// half-or-more of the address space and replaces/shadows GP's coarse routes →
    /// teardown). A more-specific broad CIDR (/2+) is additive (longest-prefix wins),
    /// not a replacement, so it doesn't trip GP's route monitor — that's the user's
    /// explicit choice, not a teardown vector. Covers IPv4 and IPv6 (::/0) alike.
    static func isCatchAll(_ destination: String) -> Bool {
        if catchAllDestinations.contains(destination) { return true }
        let parts = destination.split(separator: "/")
        if parts.count == 2, let prefix = Int(parts[1]), prefix <= 1 { return true }
        return false
    }

    /// Split compiled routes into the safe set to install and the catch-alls refused
    /// because GlobalProtect is active. When GP is down, nothing is refused.
    static func guardCatchAllUnderGlobalProtect(
        _ routes: [DesiredRoute],
        isGlobalProtect: Bool
    ) -> (kept: [DesiredRoute], refused: [DesiredRoute]) {
        guard isGlobalProtect else { return (routes, []) }
        var kept: [DesiredRoute] = []
        var refused: [DesiredRoute] = []
        for r in routes {
            if isCatchAll(r.destination) { refused.append(r) } else { kept.append(r) }
        }
        return (kept, refused)
    }
}
