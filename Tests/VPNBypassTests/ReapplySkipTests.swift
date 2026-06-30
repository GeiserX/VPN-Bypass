// ReapplySkipTests.swift
// Coverage for the diff-before-mutate no-op skip (VPN-Bypass-3sc.2): an
// automatic re-apply of an identical route set must touch zero kernel routes,
// while the Refresh button (forceReassert) must always re-assert.

import XCTest
@testable import VPNBypassCore

final class ReapplySkipTests: XCTestCase {

    func testSkipsWhenSetsMatchAndNotForced() {
        let s: Set<String> = ["1.2.3.4|10.0.0.1", "5.6.7.8|iface:utun4"]
        XCTAssertTrue(RouteManager.shouldSkipReapply(desiredPairs: s, activePairs: s, forceReassert: false))
    }

    func testForceReassertNeverSkips() {
        let s: Set<String> = ["1.2.3.4|10.0.0.1"]
        XCTAssertFalse(RouteManager.shouldSkipReapply(desiredPairs: s, activePairs: s, forceReassert: true))
    }

    func testDifferentSetsDoNotSkip() {
        XCTAssertFalse(RouteManager.shouldSkipReapply(
            desiredPairs: ["1.2.3.4|10.0.0.1", "9.9.9.9|10.0.0.1"],
            activePairs: ["1.2.3.4|10.0.0.1"],
            forceReassert: false))
    }

    func testEmptyDesiredNeverSkips() {
        XCTAssertFalse(RouteManager.shouldSkipReapply(desiredPairs: [], activePairs: [], forceReassert: false))
    }

    /// A gateway change for the same destination (VPN interface moved utun4→utun5)
    /// must NOT skip — the routes genuinely need to move.
    func testGatewayChangeIsNotSkipped() {
        XCTAssertFalse(RouteManager.shouldSkipReapply(
            desiredPairs: ["1.2.3.4|iface:utun5"],
            activePairs: ["1.2.3.4|iface:utun4"],
            forceReassert: false))
    }
}
