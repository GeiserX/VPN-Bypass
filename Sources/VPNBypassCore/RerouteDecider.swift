// RerouteDecider.swift
// Pure, side-effect-free decision for WHETHER (and whether we CAN right now) a VPN
// re-route must happen — the leak-critical seam behind checkVPNStatus().
//
// Background: checkVPNStatus() commits `vpnInterface` / `lastTailscaleSelfFingerprint`
// to the *new* values BEFORE it tries to re-route. If the re-route is skipped (the
// route-operation gate is held by a concurrent DNS refresh, or the 10s cooldown is
// active), the old ad-hoc code dropped it with no retry — and because the interface
// value already advanced, `interface != oldInterface` could never fire again. For a
// VPN-Only + link-based tunnel (e.g. Cisco Secure Client, `iface:utunX`) a utun
// renumber during a DNS refresh then left the routes pinned to a dead interface,
// which fell through to the VPN-Only catch-all onto the LOCAL gateway: a silent,
// persistent VPN leak until the next reconnect or manual refresh.
//
// The fix latches an un-runnable re-route (`pending`) so it is NEVER lost, then
// drains it once the blocker clears. This enum is the single source of truth for
// that three-way decision, extracted as a pure function so the leak scenario is
// unit-testable without driving the @MainActor RouteManager, its subprocesses, or
// real kernel routes. No @MainActor, no I/O — inputs in, action out.

enum RerouteDecider {

    /// What checkVPNStatus (or the latch-retry chain) should do this pass.
    enum RerouteAction: Equatable {
        /// Re-route now: drop every route and re-install the full set through the
        /// current gateway (the byte-identical action the old code performed).
        case reroute
        /// A re-route is needed but can't run right now — remember it (`pendingReroute`)
        /// and retry until it can, so a blocked re-route is never silently dropped.
        case latch
        /// Nothing to do.
        case none
    }

    /// Decide the re-route action for one checkVPNStatus pass.
    ///
    /// - A re-route is NEEDED iff the VPN interface changed, the Tailscale profile
    ///   changed, or a prior re-route is still latched (`pending`). The `pending`
    ///   input is what closes the leak: after checkVPNStatus prematurely commits the
    ///   new interface, `interfaceChanged` goes false, so only `pending` can carry
    ///   the still-unsatisfied need forward to a later pass.
    /// - If needed AND every precondition is clear
    ///   (`!isLoading && !isApplyingRoutes && !cooldownActive && hasGateway`) →
    ///   `.reroute`. `hasGateway` folds in every hard prerequisite for actually
    ///   installing routes (a local gateway present, the privileged helper ready).
    /// - If needed but any precondition is blocked → `.latch` (defer, don't drop).
    /// - If not needed → `.none` (blockers are irrelevant when there's nothing to do).
    static func decide(
        interfaceChanged: Bool,
        tailscaleChanged: Bool,
        pending: Bool,
        isLoading: Bool,
        isApplyingRoutes: Bool,
        cooldownActive: Bool,
        hasGateway: Bool
    ) -> RerouteAction {
        let needed = interfaceChanged || tailscaleChanged || pending
        guard needed else { return .none }

        let canRunNow = !isLoading && !isApplyingRoutes && !cooldownActive && hasGateway
        return canRunNow ? .reroute : .latch
    }
}
