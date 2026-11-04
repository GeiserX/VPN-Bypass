// FlowPolicySource.swift
// The app's config, copied into the input of the per-app routing policy compiler.
//
// VPNBypassPolicy cannot see Core's types (the extension links it without Core), so this is the
// one place that reads `Config` for it. The runtime facts (Pause, the kill switch, the physical
// interface, the tunnel owners' teams) come from RouteManager when the engine pushes a policy.

import Foundation
import VPNBypassPolicy

extension FlowPolicyCompiler.Input {
    init(config: Config, paused: Bool, killSwitchActive: Bool, physicalInterface: String?,
         tunnelOwnerTeams: [String]) {
        let mode: FlowPolicyCompiler.Mode
        if RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            mode = .custom
        } else if config.routingMode == .vpnOnly {
            mode = .vpnOnly
        } else {
            mode = .bypass
        }
        self.init(
            mode: mode,
            processRules: config.rules.filter { $0.matchType == .process }.map {
                FlowPolicyCompiler.ProcessRule(id: $0.id, pattern: $0.pattern, routeID: $0.routeId,
                                               enabled: $0.enabled, order: $0.order)
            },
            routes: config.routes.map { FlowPolicyCompiler.Route(id: $0.id, kind: flowRouteKind($0), enabled: $0.enabled) },
            bypassApps: config.bypassApps.map {
                FlowPolicyCompiler.BypassApp(id: $0.id.uuidString, pattern: $0.pattern, enabled: $0.enabled)
            },
            paused: paused,
            killSwitchActive: killSwitchActive,
            physicalInterface: physicalInterface,
            tunnelOwnerTeams: tunnelOwnerTeams
        )
    }
}

/// What per-app routing can do with a route. Qualified: `FlowPolicyCompiler` has a `Route` too.
func flowRouteKind(_ route: VPNBypassCore.Route) -> FlowPolicyCompiler.RouteKind {
    switch route.egress {
    case .vpnDefault: return route.vpnSelector?.kind == .interface ? .vpnPinned : .vpnPrimary
    case .direct: return .direct
    case .tailscaleExit: return .tailscaleExit
    case .proxyHTTP, .proxySOCKS5: return .proxy
    }
}
