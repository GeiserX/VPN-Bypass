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
}
