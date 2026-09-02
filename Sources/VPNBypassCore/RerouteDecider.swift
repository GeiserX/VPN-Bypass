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

import Foundation

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
    /// - Parameter gatewayChanged: the VPN's gateway address changed while the interface name did
    ///   NOT. A tunnel that renegotiates keeps `utunN` but can come back on a different next-hop,
    ///   and every other signal here is blind to that: `interfaceChanged` compares names, and the
    ///   DNS refresh only schedules work for destinations it does not already track, so an
    ///   already-installed route is never revisited. The route then stays pinned to a gateway that
    ///   no longer exists — in VPN Only the listed destinations blackhole (ARP to a dead next-hop)
    ///   rather than leak, so it fails safe, but it fails silently and does not self-heal.
    ///   Defaulted so existing callers and the decision-table tests keep their meaning.
    static func decide(
        interfaceChanged: Bool,
        tailscaleChanged: Bool,
        pending: Bool,
        isLoading: Bool,
        isApplyingRoutes: Bool,
        cooldownActive: Bool,
        hasGateway: Bool,
        gatewayChanged: Bool = false
    ) -> RerouteAction {
        let needed = interfaceChanged || tailscaleChanged || pending || gatewayChanged
        guard needed else { return .none }

        let canRunNow = !isLoading && !isApplyingRoutes && !cooldownActive && hasGateway
        return canRunNow ? .reroute : .latch
    }
}

/// Pure delay policy for the reconnect settle gate (see RouteManager.reconnectSettleTask).
///
/// The moment a VPN tunnel (re)appears is when its client is most fragile — GlobalProtect
/// re-checks its gateway route repeatedly for the first half minute after a restore, and a
/// full apply fired into that window turned one external drop into a minutes-long flap loop.
/// Warm restores (bypass routes still installed and working) can wait comfortably; a cold
/// start (nothing installed, the user is waiting for their bypasses) waits less; and once a
/// flap storm has cancelled the wait `maxDeferrals` times, the delay collapses so the apply
/// can never be starved forever — by then the paced helper writes are the remaining shield.
///
/// Kill strikes are the second, opposing signal. The deferral collapse assumes the apply is
/// the victim of the flapping; a kill strike is evidence the apply is the CAUSE: the VPN
/// dropped within `killWindow` of our own kernel-write burst. One observed GlobalProtect
/// session died that way 28 times in 51 minutes — restore → settle wait → apply → its
/// gateway-route read starves on our route-change broadcasts → drop → restore re-arms the
/// next apply — until the client's retry gave up and logged the user out of the gateway
/// entirely (an on-demand session never reconnects from that on its own). Every drop in
/// that loop landed AFTER the apply had already fired, so `deferrals` stayed at zero and
/// the collapse would only have poked the client faster. When strikes are on the board,
/// starving the apply is the point: the delay grows exponentially per strike instead, and
/// the deferral collapse is ignored. Bypass-mode routes egress the local gateway and stay
/// correct while we wait; the cap stays modest because a VPN-Only reconnect has no routes
/// installed until the apply runs, so its forced-via-VPN destinations egress direct in the
/// meantime — a bounded wait, not an unbounded one.
enum ReconnectSettle {
    static let warmDelay: TimeInterval = 20
    static let coldDelay: TimeInterval = 10
    static let cappedDelay: TimeInterval = 5
    static let maxDeferrals = 5
    /// A drop this soon after our last kernel-write burst is attributed to the burst. Wide
    /// enough to cover the observed chain — batch → client's route read times out (≤16s) →
    /// teardown → our status timer notices (up to ~30s + the 1.5s disconnect recheck).
    static let killWindow: TimeInterval = 90
    /// Strikes older than this stop shaping the delay: the flap is no longer hot, so the
    /// next reconnect starts from the normal settle window again (the way OUT of backoff).
    static let strikeExpiry: TimeInterval = 1800
    /// Ceiling for the backed-off delay. Long enough to give a struggling client calm
    /// multi-minute windows (the observed loop cycled every 2–3 minutes), short enough to
    /// bound how long a VPN-Only reconnect runs without its forced-via-VPN routes.
    static let maxBackoffDelay: TimeInterval = 240

    static func delay(deferrals: Int, hasInstalledRoutes: Bool, killStrikes: Int = 0) -> TimeInterval {
        let base = hasInstalledRoutes ? warmDelay : coldDelay
        if killStrikes > 0 {
            // We are the suspected killer — the anti-starvation collapse must not apply.
            // min() guards pow against absurd strike counts; the cap lands first anyway.
            return min(base * pow(2.0, Double(min(killStrikes, 8))), maxBackoffDelay)
        }
        if deferrals >= maxDeferrals { return cappedDelay }
        return base
    }

    /// Was this detected drop plausibly caused by our own kernel writes? `dropAt` earlier
    /// than the burst (clock adjustment, reordered detection) is NOT a kill — attribution
    /// only ever looks forward.
    static func isSuspectedApplyKill(dropAt: Date, lastBurstAt: Date?) -> Bool {
        guard let burstAt = lastBurstAt else { return false }
        let sinceBurst = dropAt.timeIntervalSince(burstAt)
        return sinceBurst >= 0 && sinceBurst < killWindow
    }

    /// Strikes decay as a whole once the LAST one is `strikeExpiry` old — an unrelated drop
    /// in between neither adds nor clears (a wedged client dropping on its own mid-storm
    /// must not reset the backoff and re-enable the resonance).
    static func effectiveStrikes(_ strikes: Int, lastStrikeAt: Date?, now: Date) -> Int {
        guard strikes > 0, let last = lastStrikeAt,
              now.timeIntervalSince(last) < strikeExpiry else { return 0 }
        return strikes
    }
}
