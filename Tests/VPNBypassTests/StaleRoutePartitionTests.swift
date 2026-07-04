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

    /// Asserts, for one hand-built case, that `partitionStaleRoutes` produces the EXACT
    /// `orphaned`/`addFailed` sets computed BY HAND for these inputs (concrete literals,
    /// not a re-derivation of the implementation's formula — so a formula regression fails
    /// here). Also checks the two structural invariants that must always hold: the two
    /// populations are disjoint, and together they equal the hand-computed stale set.
    private func assertInvariants(active: Set<String>, new: Set<String>, attempted: Set<String>,
                                  expectedOrphaned: Set<String>, expectedAddFailed: Set<String>,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let p = RouteManager.partitionStaleRoutes(active: active, applied: new, attempted: attempted)
        XCTAssertEqual(p.orphaned, expectedOrphaned, "orphaned mismatch", file: file, line: line)
        XCTAssertEqual(p.addFailed, expectedAddFailed, "addFailed mismatch", file: file, line: line)
        XCTAssertTrue(p.orphaned.isDisjoint(with: p.addFailed), "orphaned ∩ addFailed must be empty", file: file, line: line)
        XCTAssertEqual(p.orphaned.union(p.addFailed), expectedOrphaned.union(expectedAddFailed),
                       "orphaned ∪ addFailed must equal the stale set", file: file, line: line)
    }

    func testInvariantsAcrossHandBuiltCases() {
        // active,new,attempted → hand-computed (orphaned, addFailed). stale = active − new;
        // orphaned = stale − attempted; addFailed = stale ∩ attempted — all worked out by hand below.
        assertInvariants(active: [], new: [], attempted: [],
                         expectedOrphaned: [], expectedAddFailed: [])
        // stale={a}, a∉attempted → orphaned={a}
        assertInvariants(active: ["a"], new: [], attempted: [],
                         expectedOrphaned: ["a"], expectedAddFailed: [])
        // stale=∅ (a survives) → both empty
        assertInvariants(active: ["a"], new: ["a"], attempted: ["a"],
                         expectedOrphaned: [], expectedAddFailed: [])
        // stale={b,c,d}; attempted={b,d} → orphaned={c}, addFailed={b,d}
        assertInvariants(active: ["a", "b", "c", "d"], new: ["a"], attempted: ["b", "d"],
                         expectedOrphaned: ["c"], expectedAddFailed: ["b", "d"])
        // nothing stale
        assertInvariants(active: ["a", "b", "c"], new: ["a", "b", "c"], attempted: ["a", "b", "c"],
                         expectedOrphaned: [], expectedAddFailed: [])
        // new never active → stale={x,y}; both in attempted → addFailed={x,y}, orphaned=∅
        assertInvariants(active: ["x", "y"], new: ["z"], attempted: ["x", "y", "z"],
                         expectedOrphaned: [], expectedAddFailed: ["x", "y"])
        // stale={10.0.0.0/8}; in attempted → addFailed={10.0.0.0/8}, orphaned=∅
        assertInvariants(active: ["10.0.0.0/8", "1.1.1.1"], new: ["1.1.1.1"], attempted: ["10.0.0.0/8"],
                         expectedOrphaned: [], expectedAddFailed: ["10.0.0.0/8"])
    }

    // MARK: - Byte-preservation vs the old inline set math

    /// Executable proof the extraction is behavior-preserving: for each concrete input the
    /// static must yield exactly the `(trulyOrphanedDests, addFailedStaleDests)` the old
    /// inline set math in commitAppliedRoutes produced. The expected values here are the
    /// results HAND-COMPUTED from that old formulation — pinned literals, not a live
    /// re-derivation — so a drift in the extracted static's math is caught here.
    func testMatchesOldInlineSetMath() {
        // (active, new, attempted, expectedOrphaned, expectedAddFailed)
        //   allStale = active − new; orphaned = allStale − attempted; addFailed = allStale ∩ attempted
        let cases: [(active: Set<String>, new: Set<String>, attempted: Set<String>,
                     expectedOrphaned: Set<String>, expectedAddFailed: Set<String>)] = [
            // allStale=∅
            ([], [], [], [], []),
            // allStale={b,c,d}; ∩{b,d}={b,d}; −{b,d}={c}
            (["a", "b", "c", "d"], ["a"], ["b", "d"], ["c"], ["b", "d"]),
            // allStale={10.0.0.0/8,192.168.0.1}; attempted {10.0.0.0/8,x}: addFailed={10.0.0.0/8},
            // orphaned={192.168.0.1} ("x" is not stale so it never appears)
            (["10.0.0.0/8", "1.1.1.1", "192.168.0.1"], ["1.1.1.1"], ["10.0.0.0/8", "x"],
             ["192.168.0.1"], ["10.0.0.0/8"]),
            // allStale=∅ (p,q both survive) → both empty
            (["p", "q"], ["p", "q"], ["p"], [], []),
        ]
        for c in cases {
            let p = RouteManager.partitionStaleRoutes(active: c.active, applied: c.new, attempted: c.attempted)
            XCTAssertEqual(p.orphaned, c.expectedOrphaned, "orphaned mismatch for active=\(c.active)")
            XCTAssertEqual(p.addFailed, c.expectedAddFailed, "addFailed mismatch for active=\(c.active)")
        }
    }
}
