// StaleRoutePartitionTests.swift
// Exhaustive coverage for RouteManager.partitionStaleRoutes — the pure two-population
// split of stale kernel routes extracted from commitAppliedRoutes' apply-tail (closes
// "Trap 7": the suite previously did not cover this set algebra).
//
//   stale     = active − new
//   orphaned  = stale − attempted   (never in this batch → a failed remove means the
//                                     route is still installed, so re-attach)
//   addFailed = stale ∩ attempted   (in the batch but the add failed → delete-before-add
//                                     already removed it, so don't re-attach)
//
// The function is pure string-set algebra: destinations are opaque keys (bare hosts,
// CIDR blocks, IPv6 — all treated identically).

import XCTest
@testable import VPNBypassCore

final class StaleRoutePartitionTests: XCTestCase {

    // MARK: - Empty-input edge cases

    func testEmptyActiveYieldsBothEmpty() {
        let p = RouteManager.partitionStaleRoutes(active: [], applied: ["1.2.3.4"], attempted: ["1.2.3.4"])
        XCTAssertTrue(p.orphaned.isEmpty)
        XCTAssertTrue(p.addFailed.isEmpty)
    }

    func testEmptyNewMakesAllActiveStale() {
        // Nothing survives → every active dest is stale, partitioned by `attempted`.
        let active: Set<String> = ["a", "b", "c"]
        let p = RouteManager.partitionStaleRoutes(active: active, applied: [], attempted: ["b"])
        XCTAssertEqual(p.orphaned.union(p.addFailed), active)
        XCTAssertEqual(p.addFailed, ["b"])
        XCTAssertEqual(p.orphaned, ["a", "c"])
    }

    func testEmptyAttemptedMakesAllStaleOrphaned() {
        // No batch adds attempted → no stale dest can be "add-failed"; all are orphaned.
        let active: Set<String> = ["a", "b", "c"]
        let p = RouteManager.partitionStaleRoutes(active: active, applied: ["a"], attempted: [])
        XCTAssertEqual(p.orphaned, ["b", "c"])
        XCTAssertTrue(p.addFailed.isEmpty)
    }

    // MARK: - Single-dest membership rules

    func testDestinationInActiveAndNewSurvives() {
        // "keep" is in both active and new → not stale → in neither population.
        let p = RouteManager.partitionStaleRoutes(active: ["keep", "gone"], applied: ["keep"], attempted: ["gone"])
        XCTAssertFalse(p.orphaned.contains("keep"))
        XCTAssertFalse(p.addFailed.contains("keep"))
        XCTAssertEqual(p.addFailed, ["gone"])
        XCTAssertTrue(p.orphaned.isEmpty)
    }

    func testStaleDestInAttemptedIsAddFailedNotOrphaned() {
        let p = RouteManager.partitionStaleRoutes(active: ["s"], applied: [], attempted: ["s"])
        XCTAssertTrue(p.addFailed.contains("s"))
        XCTAssertFalse(p.orphaned.contains("s"))
    }

    func testStaleDestNotInAttemptedIsOrphanedNotAddFailed() {
        let p = RouteManager.partitionStaleRoutes(active: ["s"], applied: [], attempted: ["other"])
        XCTAssertTrue(p.orphaned.contains("s"))
        XCTAssertFalse(p.addFailed.contains("s"))
    }

    func testAttemptedItemsNotStaleAreIgnored() {
        // attempted holds "a" (survives, in new) and "z" (never active). Neither is stale,
        // so neither may leak into either population — only genuinely stale dests partition.
        let p = RouteManager.partitionStaleRoutes(active: ["a", "b"], applied: ["a"], attempted: ["a", "z"])
        XCTAssertFalse(p.orphaned.contains("a"))
        XCTAssertFalse(p.addFailed.contains("a"))
        XCTAssertFalse(p.orphaned.contains("z"))
        XCTAssertFalse(p.addFailed.contains("z"))
        XCTAssertEqual(p.orphaned, ["b"])
        XCTAssertTrue(p.addFailed.isEmpty)
    }

    // MARK: - Canonical overlap case

    func testCanonicalOverlapCase() {
        // active={a,b,c,d}, new={a}, attempted={b,d} → stale={b,c,d}, orphaned={c}, addFailed={b,d}
        let p = RouteManager.partitionStaleRoutes(active: ["a", "b", "c", "d"], applied: ["a"], attempted: ["b", "d"])
        XCTAssertEqual(p.orphaned, ["c"])
        XCTAssertEqual(p.addFailed, ["b", "d"])
    }

    // MARK: - Opaque destination keys (host / CIDR / IPv6 mix)

    func testCIDRAndHostFormsAreOpaqueKeys() {
        let active: Set<String> = ["10.0.0.0/8", "192.168.1.1", "1.1.1.1", "2606:4700::/32"]
        let new: Set<String> = ["1.1.1.1"]                             // survives
        let attempted: Set<String> = ["10.0.0.0/8", "2606:4700::/32"]  // re-added, failed
        let p = RouteManager.partitionStaleRoutes(active: active, applied: new, attempted: attempted)
        XCTAssertEqual(p.addFailed, ["10.0.0.0/8", "2606:4700::/32"])
        XCTAssertEqual(p.orphaned, ["192.168.1.1"])
    }

    // MARK: - Partition invariants (property-style)

    /// Asserts, for one hand-built case, that the two populations (a) are disjoint —
    /// orphaned ∩ addFailed = ∅ — and (b) together equal the stale set — orphaned ∪
    /// addFailed = active − new — and each is split exactly by membership in `attempted`.
    private func assertInvariants(active: Set<String>, new: Set<String>, attempted: Set<String>,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let p = RouteManager.partitionStaleRoutes(active: active, applied: new, attempted: attempted)
        let stale = active.subtracting(new)
        XCTAssertTrue(p.orphaned.isDisjoint(with: p.addFailed), "orphaned ∩ addFailed must be empty", file: file, line: line)
        XCTAssertEqual(p.orphaned.union(p.addFailed), stale, "orphaned ∪ addFailed must equal stale", file: file, line: line)
        XCTAssertEqual(p.addFailed, stale.intersection(attempted), file: file, line: line)
        XCTAssertEqual(p.orphaned, stale.subtracting(attempted), file: file, line: line)
    }

    func testInvariantsAcrossHandBuiltCases() {
        assertInvariants(active: [], new: [], attempted: [])
        assertInvariants(active: ["a"], new: [], attempted: [])
        assertInvariants(active: ["a"], new: ["a"], attempted: ["a"])
        assertInvariants(active: ["a", "b", "c", "d"], new: ["a"], attempted: ["b", "d"])
        assertInvariants(active: ["a", "b", "c"], new: ["a", "b", "c"], attempted: ["a", "b", "c"]) // nothing stale
        assertInvariants(active: ["x", "y"], new: ["z"], attempted: ["x", "y", "z"])                // new never active
        assertInvariants(active: ["10.0.0.0/8", "1.1.1.1"], new: ["1.1.1.1"], attempted: ["10.0.0.0/8"])
    }

    // MARK: - Byte-preservation vs the old inline set math

    /// Executable proof the extraction is behavior-preserving: the static must yield
    /// exactly the old inline `(trulyOrphanedDests, addFailedStaleDests)` set math that
    /// lived in commitAppliedRoutes before the refactor.
    func testMatchesOldInlineSetMath() {
        let cases: [(active: Set<String>, new: Set<String>, attempted: Set<String>)] = [
            ([], [], []),
            (["a", "b", "c", "d"], ["a"], ["b", "d"]),
            (["10.0.0.0/8", "1.1.1.1", "192.168.0.1"], ["1.1.1.1"], ["10.0.0.0/8", "x"]),
            (["p", "q"], ["p", "q"], ["p"]),
        ]
        for c in cases {
            // Old inline formulation, verbatim from the pre-refactor commitAppliedRoutes.
            let allStaleDests = c.active.subtracting(c.new)
            let oldOrphaned = Set(allStaleDests.subtracting(c.attempted))
            let oldAddFailed = Set(allStaleDests.intersection(c.attempted))
            // New extracted static.
            let p = RouteManager.partitionStaleRoutes(active: c.active, applied: c.new, attempted: c.attempted)
            XCTAssertEqual(p.orphaned, oldOrphaned)
            XCTAssertEqual(p.addFailed, oldAddFailed)
        }
    }
}
