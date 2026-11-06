// ProcessRuleReason.swift
// Why nothing serves a process rule. Its own file so a build that compiles only the engine's
// files (scripts/ne-live/make-test-app.sh --engine) has FlowEngineState.ruleReason's type
// without ProcessRule.swift, which needs Config, BypassApps and RouteManager.

enum ProcessRule {
    /// Why nothing serves a rule, as the wire code `SanitizedRule.inactiveReason` carries. A
    /// string on the wire, so a later reason still decodes in an older `vpnb`.
    enum InactiveReason: String {
        /// This Mac or this build cannot run per-app routing (macOS 14 or older, a dev build).
        case perAppRoutingNotAvailable
        /// The Per-app routing switch is off.
        case perAppRoutingOff
        /// macOS is waiting for the user to allow the extension or its configuration.
        case perAppRoutingWaitingForApproval
        /// The Mac's administrator forbids it, or the app is not in /Applications.
        case perAppRoutingBlocked
        case perAppRoutingStarting
        /// Pause, a VPN kill switch, or VPN Only mode.
        case perAppRoutingPaused
        /// The extension's update waits for approval and it does not read this app's policy.
        case perAppRoutingUpdateWaiting
        /// It stopped or would not start.
        case perAppRoutingFailed
        /// The rule's route is not Direct: this version carries listed apps around the VPN only.
        case routeNotSupported
        /// The rule's route was deleted or is turned off, so the rule matches nothing.
        case routeUnavailable
        /// An entry of Bypass mode's Apps list, while another mode is in use.
        case notInBypassMode
        /// A process rule while Bypass or VPN Only mode is in use: per-app routing compiles
        /// process rules in Custom mode only (FlowPolicyCompiler).
        case notInCustomMode
        /// The app is VPN Bypass itself or a VPN or network-security app (by its signing team):
        /// the extension turns its connections down, so it keeps its own path.
        case vpnClientApp

        /// The rule does nothing until per-app routing serves it: the engine's state, not the
        /// rule's route or the mode, keeps it out.
        var waitsForEngine: Bool {
            switch self {
            case .perAppRoutingNotAvailable, .perAppRoutingOff, .perAppRoutingWaitingForApproval, .perAppRoutingBlocked,
                 .perAppRoutingStarting, .perAppRoutingPaused, .perAppRoutingUpdateWaiting, .perAppRoutingFailed:
                return true
            case .routeNotSupported, .routeUnavailable, .notInBypassMode, .notInCustomMode, .vpnClientApp:
                return false
            }
        }
    }
}
