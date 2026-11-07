// FlowPolicyCompiler.swift
// The app's side: its rules, routes and state, compiled into the policy it pushes.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, 3.3 and 4. The input is a plain copy of what
// the policy needs, so this target never imports VPNBypassCore (the extension links this target,
// and Core's resources would trap there); the app builds it with `FlowPolicyCompiler.Input(config:…)`.
//
// What compiles to what:
// - Custom: every enabled process rule whose route exists and is enabled, in first-match order.
//   A Direct route becomes `direct(interface)`; the primary VPN `vpnDefault`; anything else
//   `unsupported`. Non-Direct rules stay in the list so first match holds: an earlier VPN rule for
//   an app keeps a later Direct rule from claiming it.
// - Bypass: the Apps list, each entry that is on Direct, under the entry's own id (so its
//   counters stay on its row when another entry is removed or turned off).
// - VPN Only, Pause and a VPN kill switch: no matchers. Per-app routing never runs there.

import Foundation

public enum FlowPolicyCompiler {
    public enum Mode: Equatable, Sendable {
        case bypass
        case vpnOnly
        case custom
    }

    /// A route, reduced to what per-app routing can do with it.
    public enum RouteKind: Equatable, Sendable {
        /// The OS default VPN.
        case vpnPrimary
        /// A VPN pinned to one tunnel.
        case vpnPinned
        case direct
        case tailscaleExit
        case proxy
    }

    public struct Route: Equatable, Sendable {
        public var id: UUID
        public var kind: RouteKind
        public var enabled: Bool

        public init(id: UUID, kind: RouteKind, enabled: Bool = true) {
            self.id = id
            self.kind = kind
            self.enabled = enabled
        }
    }

    /// A Custom rule that matches an app.
    public struct ProcessRule: Equatable, Sendable {
        public var id: UUID
        public var pattern: String
        public var routeID: UUID
        public var enabled: Bool
        /// Lower runs earlier, as in the app's rule list.
        public var order: Int

        public init(id: UUID, pattern: String, routeID: UUID, enabled: Bool = true, order: Int) {
            self.id = id
            self.pattern = pattern
            self.routeID = routeID
            self.enabled = enabled
            self.order = order
        }
    }

    /// An entry of Bypass mode's Apps list.
    public struct BypassApp: Equatable, Sendable {
        /// The entry's id, which the policy carries as the matcher's rule id.
        public var id: String
        /// A bundle id or an executable name.
        public var pattern: String
        public var enabled: Bool

        public init(id: String, pattern: String, enabled: Bool = true) {
            self.id = id
            self.pattern = pattern
            self.enabled = enabled
        }
    }

    public struct Input: Equatable, Sendable {
        public var mode: Mode
        /// Custom mode's process rules. Other rule kinds stay with the kernel engine.
        public var processRules: [ProcessRule]
        public var routes: [Route]
        /// Bypass mode's Apps list: bundle ids or executable names, each sent Direct while on.
        public var bypassApps: [BypassApp]
        public var paused: Bool
        /// A VPN with `includeAllNetworks` or `enforceRoutes` is up: interface scoping cannot
        /// escape it, so per-app routing stands down (3.7).
        public var killSwitchActive: Bool
        /// The interface Direct flows leave on (`RouteManager.detectPhysicalInterface()`). Nil lets
        /// the extension pick the most preferred Wi-Fi or Ethernet interface.
        public var physicalInterface: String?
        /// Team ids of the processes that own the live tunnels.
        public var tunnelOwnerTeams: [String]

        public init(mode: Mode, processRules: [ProcessRule] = [], routes: [Route] = [], bypassApps: [BypassApp] = [],
                    paused: Bool = false, killSwitchActive: Bool = false, physicalInterface: String? = nil,
                    tunnelOwnerTeams: [String] = []) {
            self.mode = mode
            self.processRules = processRules
            self.routes = routes
            self.bypassApps = bypassApps
            self.paused = paused
            self.killSwitchActive = killSwitchActive
            self.physicalInterface = physicalInterface
            self.tunnelOwnerTeams = tunnelOwnerTeams
        }
    }

    public static func compile(_ input: Input, generation: Int,
                               leaseSeconds: Int = FlowPolicy.defaultLeaseSeconds) -> FlowPolicy {
        FlowPolicy(generation: generation, matchers: matchers(input),
                   declinedTeams: unique(input.tunnelOwnerTeams), leaseSeconds: leaseSeconds)
    }

    static func matchers(_ input: Input) -> [AppMatcher] {
        if input.paused || input.killSwitchActive { return [] }
        let direct = FlowEgress.direct(interface: input.physicalInterface.flatMap { $0.isEmpty ? nil : $0 })
        switch input.mode {
        case .vpnOnly:
            return []
        case .bypass:
            // An entry that is off matches nothing; of two entries naming one app, the first wins.
            var seen = Set<String>()
            return input.bypassApps.compactMap { app -> AppMatcher? in
                let pattern = trimmed(app.pattern)
                guard app.enabled, !pattern.isEmpty, seen.insert(pattern).inserted else { return nil }
                return AppMatcher(ruleID: app.id, kind: AppMatcher.kind(of: pattern), pattern: pattern, egress: direct)
            }
        case .custom:
            let routes = Dictionary(input.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return input.processRules.enumerated()
                // First match: by order, ties kept in list order.
                .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
                .compactMap { _, rule -> AppMatcher? in
                    let pattern = trimmed(rule.pattern)
                    // A rule off, or one whose route is gone or off, matches nothing; the next
                    // rule decides, as the kernel engine does (RouteCompiler).
                    guard rule.enabled, !pattern.isEmpty, let route = routes[rule.routeID], route.enabled else { return nil }
                    let egress: FlowEgress
                    switch route.kind {
                    case .direct: egress = direct
                    case .vpnPrimary: egress = .vpnDefault
                    case .vpnPinned, .tailscaleExit, .proxy: egress = .unsupported
                    }
                    return AppMatcher(ruleID: rule.id.uuidString, kind: AppMatcher.kind(of: pattern),
                                      pattern: pattern, egress: egress)
                }
        }
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Trimmed, blanks dropped, first occurrence kept.
    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map(trimmed).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
