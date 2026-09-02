// ReconnectSettleTests.swift
// Coverage for the reconnect settle-gate delay policy (ReconnectSettle).
//
// The contract being locked down: a warm restore (bypass routes still installed and carrying
// traffic) waits the full settle window; a cold start (nothing installed, the user is waiting)
// waits less; and once a flap storm has cancelled the pending apply `maxDeferrals` times, the
// delay collapses so the apply can never be starved indefinitely.

import XCTest
@testable import VPNBypassCore

final class ReconnectSettleTests: XCTestCase {

    /// Routes still installed → the apply is pure refresh, so it can wait the longest.
    func testWarmRestoreUsesFullSettleWindow() {
        XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: true),
                       ReconnectSettle.warmDelay)
    }

    /// Nothing installed → the user is waiting for their bypasses; shorter, but still clear of
    /// the tunnel's immediate post-connect turbulence.
    func testColdStartWaitsLess() {
        XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: false),
                       ReconnectSettle.coldDelay)
        XCTAssertLessThan(ReconnectSettle.coldDelay, ReconnectSettle.warmDelay)
    }

    /// Below the cap, deferrals do not change the delay — the wait simply re-arms.
    func testDeferralsBelowCapKeepNormalDelay() {
        XCTAssertEqual(ReconnectSettle.delay(deferrals: ReconnectSettle.maxDeferrals - 1,
                                             hasInstalledRoutes: true),
                       ReconnectSettle.warmDelay)
    }

    /// At the cap the delay collapses regardless of warm/cold — anti-starvation kicks in.
    func testCapCollapsesDelay() {
        for warm in [true, false] {
            XCTAssertEqual(ReconnectSettle.delay(deferrals: ReconnectSettle.maxDeferrals,
                                                 hasInstalledRoutes: warm),
                           ReconnectSettle.cappedDelay)
        }
        XCTAssertLessThan(ReconnectSettle.cappedDelay, ReconnectSettle.coldDelay)
    }

    // MARK: - Apply-kill backoff (the resonance breaker)

    /// Each strike doubles the wait from the warm/cold base, then the ceiling holds. This is
    /// what turns a 2–3-minute kill cycle into multi-minute calm windows for the VPN client.
    func testKillStrikesGrowDelayExponentiallyAndCap() {
        XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: true, killStrikes: 1),
                       ReconnectSettle.warmDelay * 2)
        XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: true, killStrikes: 2),
                       ReconnectSettle.warmDelay * 4)
        XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: true, killStrikes: 3),
                       ReconnectSettle.warmDelay * 8)
        for strikes in 4...50 {
            XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: true,
                                                 killStrikes: strikes),
                           ReconnectSettle.maxBackoffDelay)
        }
    }

    /// The regression test for the observed logout loop: every drop landed AFTER the apply,
    /// so deferrals stayed at zero — but had they climbed, the anti-starvation collapse would
    /// have fired the apply FASTER into an already-dying tunnel. With strikes on the board,
    /// backoff must win over the collapse: when we are the suspected killer, starving the
    /// apply is the point.
    func testKillStrikesOverrideDeferralCollapse() {
        let delay = ReconnectSettle.delay(deferrals: ReconnectSettle.maxDeferrals,
                                          hasInstalledRoutes: true,
                                          killStrikes: 2)
        XCTAssertEqual(delay, ReconnectSettle.warmDelay * 4)
        XCTAssertGreaterThan(delay, ReconnectSettle.cappedDelay)
    }

    /// A cold start backs off from its own (shorter) base — the user is waiting, but a dead
    /// VPN serves them worse than a late apply.
    func testKillStrikesFromColdBase() {
        XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: false, killStrikes: 1),
                       ReconnectSettle.coldDelay * 2)
    }

    /// killStrikes defaults to 0, so every pre-existing call keeps its exact meaning.
    func testZeroStrikesKeepLegacyBehavior() {
        XCTAssertEqual(ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: true, killStrikes: 0),
                       ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: true))
        XCTAssertEqual(ReconnectSettle.delay(deferrals: ReconnectSettle.maxDeferrals,
                                             hasInstalledRoutes: true, killStrikes: 0),
                       ReconnectSettle.cappedDelay)
    }

    /// Attribution only ever looks forward from the burst, within the window: a drop inside
    /// it is ours to answer for; outside it, before it (clock adjustment), or with no burst
    /// recorded at all, the drop is external.
    func testSuspectedApplyKillWindow() {
        let burst = Date()
        XCTAssertTrue(ReconnectSettle.isSuspectedApplyKill(
            dropAt: burst.addingTimeInterval(ReconnectSettle.killWindow - 1), lastBurstAt: burst))
        XCTAssertFalse(ReconnectSettle.isSuspectedApplyKill(
            dropAt: burst.addingTimeInterval(ReconnectSettle.killWindow), lastBurstAt: burst))
        XCTAssertFalse(ReconnectSettle.isSuspectedApplyKill(
            dropAt: burst.addingTimeInterval(-1), lastBurstAt: burst))
        XCTAssertFalse(ReconnectSettle.isSuspectedApplyKill(dropAt: burst, lastBurstAt: nil))
    }

    /// The way OUT of backoff is time, not an unrelated drop: strikes hold while the flap is
    /// hot (a wedged client dropping on its own in between must not reset the backoff and
    /// re-enable the resonance) and expire as a whole once the last strike is old.
    func testEffectiveStrikesDecay() {
        let now = Date()
        let hot = now.addingTimeInterval(-(ReconnectSettle.strikeExpiry - 60))
        let cold = now.addingTimeInterval(-(ReconnectSettle.strikeExpiry + 60))
        XCTAssertEqual(ReconnectSettle.effectiveStrikes(3, lastStrikeAt: hot, now: now), 3)
        XCTAssertEqual(ReconnectSettle.effectiveStrikes(3, lastStrikeAt: cold, now: now), 0)
        XCTAssertEqual(ReconnectSettle.effectiveStrikes(0, lastStrikeAt: hot, now: now), 0)
        XCTAssertEqual(ReconnectSettle.effectiveStrikes(3, lastStrikeAt: nil, now: now), 0)
    }
}
