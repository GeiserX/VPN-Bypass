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
        var claimed: Set<String> = []

        for entry in resolvedRules where entry.rule.enabled {
            // A rule pointing at a route that no longer exists is inert (matches the
            // resilient all-zero-UUID decode: skip, never fail the whole compile).
            guard let route = byId[entry.rule.routeId] else { continue }

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
                guard claimed.insert(dest.value).inserted else { continue }  // first rule wins
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

    // MARK: - GlobalProtect catch-all guard (generalizes refuseVPNOnlyUnderGlobalProtect)

    /// Catch-all destinations that structurally defeat a full-tunnel VPN. Installing
    /// any of them into a NON-primary egress (Direct, or a specific utun — every kernel
    /// route the compiler emits is non-primary by construction) under GlobalProtect
    /// trips its route monitor and tears the tunnel down (the original incident that
    /// motivates the whole project). Custom mode is per-rule and should never produce
    /// these, but the guard is the custom-engine analog of refuseVPNOnlyUnderGlobalProtect.
    static let catchAllDestinations: Set<String> = ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1"]

    static func isCatchAll(_ destination: String) -> Bool {
        catchAllDestinations.contains(destination)
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
