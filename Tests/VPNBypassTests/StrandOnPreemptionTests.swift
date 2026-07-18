// StrandOnPreemptionTests.swift
// Regression coverage for #61 (strand-on-preemption): an apply that adds routes to the
// KERNEL and is then preempted by an interleaving removeAllRoutes() (which bumps routeEpoch
// and removes only *tracked* activeRoutes dests) must self-remove the routes it added before
// it returns — otherwise those kernel routes are left installed-but-untracked, and no later
// removeAllRoutes() can ever clean them. For VPN-Only that means the 0.0.0.0/1 + 128.0.0.0/1
// catch-alls stay installed → a silent full-tunnel-defeating leak.
//
// Two layers:
//   1. Pure-function tests for RouteManager.destinationsToUnstrand — the set algebra that
//      decides what an aborting apply must remove (catch-alls first, add-failed excluded).
//   2. A deterministic strand repro that drives the REAL removeAllRoutes() +
//      commitAppliedRoutes() against a fake kernel and asserts the catch-alls are gone.

import XCTest
import Foundation
@testable import VPNBypassCore

// MARK: - Pure set algebra (destinationsToUnstrand)

final class DestinationsToUnstrandTests: XCTestCase {

    func testEmptyAttemptedYieldsBothEmpty() {
        let s = RouteManager.destinationsToUnstrand(attempted: [], addFailed: [])
        XCTAssertTrue(s.catchAlls.isEmpty)
        XCTAssertTrue(s.rest.isEmpty)
    }

    func testEmptyAttemptedWithAddFailedStillEmpty() {
        // Nothing was added → nothing to unstrand, regardless of addFailed.
        let s = RouteManager.destinationsToUnstrand(attempted: [], addFailed: ["1.2.3.4"])
        XCTAssertTrue(s.catchAlls.isEmpty)
        XCTAssertTrue(s.rest.isEmpty)
    }

    func testCatchAllsComeBackSeparatelyFromRest() {
        // Mixed set: the two VPN-Only catch-alls plus ordinary host routes.
        let s = RouteManager.destinationsToUnstrand(
            attempted: ["0.0.0.0/1", "128.0.0.0/1", "5.6.7.8", "1.2.3.4"],
            addFailed: []
        )
        XCTAssertEqual(s.catchAlls, ["0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertEqual(s.rest, ["1.2.3.4", "5.6.7.8"])
        // Every catch-all really is a catch-all; nothing in rest is.
        XCTAssertTrue(s.catchAlls.allSatisfy { RouteCompiler.catchAllDestinations.contains($0) })
        XCTAssertTrue(s.rest.allSatisfy { !RouteCompiler.catchAllDestinations.contains($0) })
    }

    func testExcludesAddFailed() {
        // Add-failed dests were removed by the helper's delete-before-add — must NOT be
        // re-removed (they are already gone) and must appear in neither bucket.
        let s = RouteManager.destinationsToUnstrand(
            attempted: ["0.0.0.0/1", "1.2.3.4", "5.6.7.8"],
            addFailed: ["1.2.3.4"]
        )
        XCTAssertEqual(s.catchAlls, ["0.0.0.0/1"])
        XCTAssertEqual(s.rest, ["5.6.7.8"])
        XCTAssertFalse(s.catchAlls.contains("1.2.3.4"))
        XCTAssertFalse(s.rest.contains("1.2.3.4"))
    }

    func testAddFailedCanRemoveACatchAll() {
        let s = RouteManager.destinationsToUnstrand(
            attempted: ["0.0.0.0/1", "128.0.0.0/1"],
            addFailed: ["0.0.0.0/1"]
        )
        XCTAssertEqual(s.catchAlls, ["128.0.0.0/1"])
        XCTAssertTrue(s.rest.isEmpty)
    }

    func testCustomFullTunnelCatchAllRecognized() {
        // The custom-mode 0.0.0.0/0 catch-all is also treated leak-critical (removed first).
        let s = RouteManager.destinationsToUnstrand(
            attempted: ["0.0.0.0/0", "9.9.9.9"],
            addFailed: []
        )
        XCTAssertEqual(s.catchAlls, ["0.0.0.0/0"])
        XCTAssertEqual(s.rest, ["9.9.9.9"])
    }

    func testRestIsSortedDeterministically() {
        let s = RouteManager.destinationsToUnstrand(
            attempted: ["3.3.3.3", "1.1.1.1", "2.2.2.2"],
            addFailed: []
        )
        XCTAssertTrue(s.catchAlls.isEmpty)
        XCTAssertEqual(s.rest, ["1.1.1.1", "2.2.2.2", "3.3.3.3"])
    }
}

// MARK: - Deterministic strand repro (REAL removeAllRoutes + commitAppliedRoutes)

/// Minimal in-memory stand-in for the kernel routing table. `removeRoutesBatchOverrideForTests`
/// routes RouteManager's removals here instead of the privileged helper, so a test can seed the
/// "installed" set, then observe exactly what an aborting apply removes.
private final class FakeKernel {
    var installed: Set<String>
    let failRemovals: Bool
    init(installed: Set<String>, failRemovals: Bool = false) {
        self.installed = installed
        self.failRemovals = failRemovals
    }

    func remove(_ destinations: [String]) -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        if failRemovals {
            // Simulate a kernel-delete failure: nothing is removed; every dest is reported failed.
            return (successCount: 0, failureCount: destinations.count, failedDestinations: destinations, error: nil)
        }
        var success = 0
        for d in destinations where installed.remove(d) != nil { success += 1 }
        return (successCount: success, failureCount: 0, failedDestinations: [], error: nil)
    }
}

@MainActor
final class StrandOnPreemptionTests: XCTestCase {

    private var savedManageHostsFile = false

    override func setUp() {
        super.setUp()
        let rm = RouteManager.shared
        savedManageHostsFile = rm.config.manageHostsFile
        rm.config.manageHostsFile = false          // never touch /etc/hosts from a unit test
        rm.activeRoutes = []
        rm.removeRoutesBatchOverrideForTests = nil
    }

    override func tearDown() {
        let rm = RouteManager.shared
        rm.removeRoutesBatchOverrideForTests = nil
        rm.activeRoutes = []
        rm.config.manageHostsFile = savedManageHostsFile
        super.tearDown()
    }

    /// The #61 repro. Models the exact interleave:
    ///   1. an apply snapshots the epoch and adds the two VPN-Only catch-alls to the KERNEL,
    ///   2. a teardown removeAllRoutes() interleaves — it bumps the epoch and, because the
    ///      catch-alls are not yet in activeRoutes, removes nothing (they are untracked),
    ///   3. the apply resumes into commitAppliedRoutes() with its now-stale epoch.
    /// The commit must abort AND self-remove the two catch-alls it added. Without the abort-
    /// cleanup, the fake kernel would still hold them — the strand.
    func testPreemptedCommitUnstrandsCatchAlls() async {
        let rm = RouteManager.shared
        let fake = FakeKernel(installed: ["0.0.0.0/1", "128.0.0.0/1"])
        rm.removeRoutesBatchOverrideForTests = { dests in fake.remove(dests) }

        // (1) The in-flight apply's epoch snapshot, taken before the kernel add.
        let capturedEpoch = rm.routeEpochForTests

        // (2) Teardown interleaves. activeRoutes is empty, so removeAllRoutes removes nothing
        //     from the (untracked) kernel — it only bumps the epoch.
        await rm.removeAllRoutes()
        XCTAssertNotEqual(rm.routeEpochForTests, capturedEpoch, "removeAllRoutes must bump routeEpoch")
        XCTAssertEqual(fake.installed, ["0.0.0.0/1", "128.0.0.0/1"],
                       "removeAllRoutes is tracked-only — it cannot see the untracked catch-alls")

        // (3) The apply resumes into commit with the stale epoch and the routes it already
        //     pushed to the kernel.
        let catchAlls: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = [
            (destination: "0.0.0.0/1", gateway: "10.0.0.1", isNetwork: true, source: "vpn-only"),
            (destination: "128.0.0.0/1", gateway: "10.0.0.1", isNetwork: true, source: "vpn-only"),
        ]
        let sources: [(destination: String, gateway: String, source: String)] = catchAlls.map {
            (destination: $0.destination, gateway: $0.gateway, source: $0.source)
        }

        let committed = await rm.commitAppliedRoutes(
            routesToAdd: catchAlls,
            allSourceEntries: sources,
            batchFailedDests: [],
            epoch: capturedEpoch,
            logLabel: ""
        )

        XCTAssertFalse(committed, "commit must abort on the stale epoch")
        XCTAssertTrue(fake.installed.isEmpty,
                      "#61: a preempted apply MUST remove the catch-alls it added — otherwise they are stranded (silent VPN-Only leak)")
        XCTAssertTrue(rm.activeRoutes.isEmpty, "an aborted apply must not record routes in activeRoutes")
    }

    /// Guards the other direction: with a matching epoch (no preemption) commit still commits
    /// normally — the abort-cleanup must not fire on the happy path.
    func testUnpreemptedCommitStillCommits() async {
        let rm = RouteManager.shared
        let epoch = rm.routeEpochForTests
        let routes: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = [
            (destination: "1.2.3.4", gateway: "10.0.0.1", isNetwork: false, source: "example.com"),
        ]
        let sources: [(destination: String, gateway: String, source: String)] = [
            (destination: "1.2.3.4", gateway: "10.0.0.1", source: "example.com"),
        ]
        let committed = await rm.commitAppliedRoutes(
            routesToAdd: routes,
            allSourceEntries: sources,
            batchFailedDests: [],
            epoch: epoch,
            logLabel: ""
        )
        XCTAssertTrue(committed, "commit must succeed when the epoch is unchanged")
        XCTAssertEqual(rm.activeRoutes.map { $0.destination }, ["1.2.3.4"])
    }

    /// Finding-1 hardening (CodeRabbit): if the kernel removal DURING unstrand itself fails, the
    /// routes are still installed — so unstrandRoutes must RETAIN them in activeRoutes (tracked)
    /// rather than discard the failure, or they become a permanent untracked strand (the exact
    /// leak this remediation prevents). Mirrors removeAllRoutes()'s failed-removal retention.
    func testFailedUnstrandRetainsRoutesForNextTeardown() async {
        let rm = RouteManager.shared
        let fake = FakeKernel(installed: ["0.0.0.0/1", "128.0.0.0/1"], failRemovals: true)
        rm.removeRoutesBatchOverrideForTests = { dests in fake.remove(dests) }

        let capturedEpoch = rm.routeEpochForTests
        await rm.removeAllRoutes()   // bumps epoch; activeRoutes empty

        let catchAlls: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = [
            (destination: "0.0.0.0/1", gateway: "10.0.0.1", isNetwork: true, source: "vpn-only"),
            (destination: "128.0.0.0/1", gateway: "10.0.0.1", isNetwork: true, source: "vpn-only"),
        ]
        let sources: [(destination: String, gateway: String, source: String)] = catchAlls.map {
            (destination: $0.destination, gateway: $0.gateway, source: $0.source)
        }

        let committed = await rm.commitAppliedRoutes(
            routesToAdd: catchAlls,
            allSourceEntries: sources,
            batchFailedDests: [],
            epoch: capturedEpoch,
            logLabel: ""
        )

        XCTAssertFalse(committed, "commit must abort on the stale epoch")
        // The kernel delete failed, so the catch-alls remain installed...
        XCTAssertEqual(fake.installed, ["0.0.0.0/1", "128.0.0.0/1"],
                       "failRemovals kernel leaves the routes installed")
        // ...therefore they MUST now be TRACKED, so the next teardown removes them — not a strand.
        XCTAssertEqual(Set(rm.activeRoutes.map { $0.destination }), ["0.0.0.0/1", "128.0.0.0/1"],
                       "#61: routes that fail kernel removal during unstrand must be retained in activeRoutes for the next teardown, not dropped")
    }
}
