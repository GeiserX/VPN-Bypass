// ShutdownRaceTests.swift
// Regression coverage for the two quit races proven live on 2026-08-07:
//
// Race 1 — the compensation-after-commit hole. Teardown deliberately skips the operation gate
// and preempts in-flight work via an epoch bump; but the in-flight apply's kernel batch-add ran
// BEFORE its epoch check, and quit killed the process before the compensating removal executed.
// Result: 93 routes in the kernel with no record in `activeRoutes` — invisible to any future
// teardown, because the epoch guard had (correctly) skipped the model append.
//
// Race 2 — the quit-mid-apply hole. `cleanupOnQuit` guarded teardown with
// `if !activeRoutes.isEmpty`; a quit landing during a startup apply saw an empty model, skipped
// `removeAllRoutes`, therefore never bumped the epoch, and the in-flight apply finished
// installing all 319 routes AFTER "cleanup" completed.
//
// The fixes under test: a shutdown flag refusing new work at the gate and at the batch-add
// wrapper; destinations recorded as pending BEFORE every kernel add; teardown sweeping the union
// of tracked + pending; pending-only failures retained as records; the epoch always bumped.
//
// The helper is never installed in the test environment, so helper-path calls fail fast — which
// is exactly the path these tests need.

import XCTest
@testable import VPNBypassCore

@MainActor
final class ShutdownRaceTests: XCTestCase {

    private var savedRoutes: [RouteManager.ActiveRoute] = []
    private var savedPending: Set<String> = []

    override func setUp() {
        super.setUp()
        savedRoutes = RouteManager.shared.activeRoutes
        savedPending = RouteManager.shared.pendingKernelAdds
        RouteManager.shared.activeRoutes = []
        RouteManager.shared.pendingKernelAdds = []
    }

    override func tearDown() {
        RouteManager.shared.resetShutdownStateForTests()
        RouteManager.shared.activeRoutes = savedRoutes
        RouteManager.shared.pendingKernelAdds = savedPending
        super.tearDown()
    }

    // MARK: - Shutdown flag

    func testBeginShutdownFlipsFlagAndIsIdempotent() {
        let rm = RouteManager.shared
        XCTAssertFalse(rm.isShuttingDown)
        rm.beginShutdown()
        XCTAssertTrue(rm.isShuttingDown)
        rm.beginShutdown() // second call must be harmless
        XCTAssertTrue(rm.isShuttingDown)
    }

    /// Once shutdown begins, the batch-add wrapper must refuse WITHOUT contacting the helper and
    /// WITHOUT recording pending destinations — nothing may land in the kernel mid-teardown.
    func testBatchAddRefusesDuringShutdown() async {
        let rm = RouteManager.shared
        rm.beginShutdown()
        let result = await rm.addRoutesBatchTracked(routes: [
            (destination: "203.0.113.1", gateway: "192.168.1.1", isNetwork: false),
            (destination: "203.0.113.2", gateway: "192.168.1.1", isNetwork: false),
        ])
        XCTAssertEqual(result.failureCount, 2)
        XCTAssertEqual(Set(result.failedDestinations), ["203.0.113.1", "203.0.113.2"])
        XCTAssertNotNil(result.error)
        XCTAssertTrue(rm.pendingKernelAdds.isEmpty,
                      "a refused add must not leave pending records — there is nothing to sweep")
    }

    // MARK: - Pending bookkeeping

    /// A failed add (helper not ready here) must not leak pending records: destinations are
    /// recorded BEFORE the write, and failures — which never reached the kernel — subtracted after.
    func testFailedAddDoesNotLeakPendingRecords() async {
        let rm = RouteManager.shared
        let result = await rm.addRoutesBatchTracked(routes: [
            (destination: "203.0.113.3", gateway: "192.168.1.1", isNetwork: false),
        ])
        XCTAssertEqual(result.failureCount, 1, "helper is not installed in tests — the add must fail")
        XCTAssertTrue(rm.pendingKernelAdds.isEmpty)
    }

    // MARK: - Teardown sweeps pending (Race 1)

    /// Teardown must attempt destinations the model never tracked — and when removal fails
    /// (helper not ready), the pending-only destination must be RETAINED as a record, not
    /// silently forgotten. Losing the record was the original strand mechanism.
    func testRemoveAllRoutesSweepsPendingAndRetainsFailures() async {
        let rm = RouteManager.shared
        rm.pendingKernelAdds = ["203.0.113.9"]  // kernel-visible, never committed to the model
        await rm.removeAllRoutes()
        XCTAssertTrue(rm.pendingKernelAdds.isEmpty, "pending is consumed by teardown")
        XCTAssertTrue(rm.activeRoutes.contains { $0.destination == "203.0.113.9" },
                      "a pending-only destination that failed removal must keep a record")
    }

    // MARK: - Epoch always bumps (Race 2)

    /// `cleanupOnQuit` must preempt an in-flight apply even when the model is empty — the epoch
    /// bump IS the preemption signal, and skipping it was how a quit-mid-apply installed 319
    /// routes after cleanup finished.
    func testRemoveAllRoutesBumpsEpochEvenWhenEmpty() async {
        let rm = RouteManager.shared
        XCTAssertTrue(rm.activeRoutes.isEmpty)
        XCTAssertTrue(rm.pendingKernelAdds.isEmpty)
        let before = rm.routeEpoch
        await rm.removeAllRoutes()
        XCTAssertGreaterThan(rm.routeEpoch, before,
                             "the epoch must advance even with nothing to remove")
    }

    /// The operation gate must refuse new work once shutdown began — and recover after reset.
    func testGateRefusesAfterShutdown() throws {
        let rm = RouteManager.shared
        guard rm.tryAcquireRouteOperationForTests() else {
            // Another test leaked the gate held — this test cannot own the invariant then.
            throw XCTSkip("operation gate already held by unrelated state")
        }
        rm.releaseRouteOperationForTests()

        rm.beginShutdown()
        XCTAssertFalse(rm.tryAcquireRouteOperationForTests(),
                       "the gate must refuse every new operation during shutdown")

        rm.resetShutdownStateForTests()
        XCTAssertTrue(rm.tryAcquireRouteOperationForTests(), "gate usable again after reset")
        rm.releaseRouteOperationForTests()
    }
}
