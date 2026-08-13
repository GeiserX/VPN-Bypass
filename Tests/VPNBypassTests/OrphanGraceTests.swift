// OrphanGraceTests.swift
// Coverage for the orphan-grace decision (RouteManager.orphanGraceDecision).
//
// The churn being eliminated: rotating CDN DNS makes 100–150 installed routes fall out of the
// desired set on EVERY auto re-apply, and each of those deletes — plus the re-add when the IP
// rotates back — is a broadcast routing event the tunnel client must sit through. The grace
// contract: a fresh orphan is retained (still installed, still tracked); it is deleted only
// after staying gone for the TTL; a destination that becomes desired again has its history
// forgiven at zero kernel cost; and the retained set is bounded by evicting oldest-first.

import XCTest
@testable import VPNBypassCore

final class OrphanGraceTests: XCTestCase {

    private let ttl: TimeInterval = 1800
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A first-seen orphan must be retained, with its clock started at `now`.
    func testFreshOrphanIsRetainedNotDeleted() {
        let outcome = RouteManager.orphanGraceDecision(
            orphaned: ["1.2.3.4"], applied: [], firstSeen: [:],
            now: now, ttl: ttl, cap: 400
        )
        XCTAssertEqual(outcome.deleteNow, [])
        XCTAssertEqual(outcome.retained, ["1.2.3.4"])
        XCTAssertEqual(outcome.updatedFirstSeen["1.2.3.4"], now)
    }

    /// Once an orphan has stayed gone for the TTL it is deleted and its history dropped.
    func testAgedOrphanIsDeleted() {
        let outcome = RouteManager.orphanGraceDecision(
            orphaned: ["1.2.3.4"], applied: [],
            firstSeen: ["1.2.3.4": now.addingTimeInterval(-ttl)],
            now: now, ttl: ttl, cap: 400
        )
        XCTAssertEqual(outcome.deleteNow, ["1.2.3.4"])
        XCTAssertEqual(outcome.retained, [])
        XCTAssertNil(outcome.updatedFirstSeen["1.2.3.4"])
    }

    /// An orphan still inside its TTL keeps its ORIGINAL first-seen time — the clock must not
    /// restart on every apply, or nothing would ever age out.
    func testRetainedOrphanKeepsOriginalClock() {
        let earlier = now.addingTimeInterval(-600)
        let outcome = RouteManager.orphanGraceDecision(
            orphaned: ["1.2.3.4"], applied: [],
            firstSeen: ["1.2.3.4": earlier],
            now: now, ttl: ttl, cap: 400
        )
        XCTAssertEqual(outcome.retained, ["1.2.3.4"])
        XCTAssertEqual(outcome.updatedFirstSeen["1.2.3.4"], earlier)
    }

    /// Rotation-back: a destination that is desired again must have its history forgiven —
    /// no delete, no re-add, no clock left behind to mis-age it later.
    func testReappearedDestinationHistoryIsForgiven() {
        let outcome = RouteManager.orphanGraceDecision(
            orphaned: [], applied: ["1.2.3.4"],
            firstSeen: ["1.2.3.4": now.addingTimeInterval(-900)],
            now: now, ttl: ttl, cap: 400
        )
        XCTAssertEqual(outcome.deleteNow, [])
        XCTAssertEqual(outcome.retained, [])
        XCTAssertTrue(outcome.updatedFirstSeen.isEmpty)
    }

    /// History for a destination that vanished entirely (not orphaned, not applied) must be
    /// dropped, or the map would grow without bound.
    func testVanishedDestinationHistoryIsPruned() {
        let outcome = RouteManager.orphanGraceDecision(
            orphaned: ["5.6.7.8"], applied: [],
            firstSeen: ["9.9.9.9": now.addingTimeInterval(-100)],
            now: now, ttl: ttl, cap: 400
        )
        XCTAssertNil(outcome.updatedFirstSeen["9.9.9.9"])
        XCTAssertEqual(outcome.retained, ["5.6.7.8"])
    }

    /// Past the cap, the OLDEST graced routes are evicted to deleteNow so the retained set
    /// stays bounded; the newest survive.
    func testCapEvictsOldestFirst() {
        let outcome = RouteManager.orphanGraceDecision(
            orphaned: ["10.0.0.1", "10.0.0.2", "10.0.0.3"], applied: [],
            firstSeen: [
                "10.0.0.1": now.addingTimeInterval(-300),   // oldest → evicted
                "10.0.0.2": now.addingTimeInterval(-200),
                "10.0.0.3": now.addingTimeInterval(-100),
            ],
            now: now, ttl: ttl, cap: 2
        )
        XCTAssertEqual(outcome.deleteNow, ["10.0.0.1"])
        XCTAssertEqual(outcome.retained, ["10.0.0.2", "10.0.0.3"])
        XCTAssertNil(outcome.updatedFirstSeen["10.0.0.1"])
    }
}
