// RerouteDeciderTests.swift
// Coverage for the leak-critical re-route decision (RerouteDecider). The real bug:
// checkVPNStatus() commits the NEW vpnInterface / Tailscale fingerprint BEFORE it
// re-routes, so if the re-route is blocked (route-op gate held by a concurrent DNS
// refresh, or the 10s cooldown) the old code dropped it and `interfaceChanged` could
// never re-fire — a silent, persistent VPN leak. These tests pin the three-way
// decision that now LATCHES a blocked re-route (via `pending`) and drains it later,
// so a needed re-route is never lost. Each expected action is hand-computed from:
//   needed    = interfaceChanged || tailscaleChanged || pending
//   canRunNow = !isLoading && !isApplyingRoutes && !cooldownActive && hasGateway
//   result    = !needed ? .none : (canRunNow ? .reroute : .latch)

import XCTest
@testable import VPNBypassCore

final class RerouteDeciderTests: XCTestCase {

    private typealias Action = RerouteDecider.RerouteAction

    /// All-clear preconditions (gate free, not loading, no cooldown, gateway+helper ready).
    private func decideAllClear(
        interfaceChanged: Bool = false,
        tailscaleChanged: Bool = false,
        pending: Bool = false
    ) -> Action {
        RerouteDecider.decide(
            interfaceChanged: interfaceChanged,
            tailscaleChanged: tailscaleChanged,
            pending: pending,
            isLoading: false,
            isApplyingRoutes: false,
            cooldownActive: false,
            hasGateway: true
        )
    }

    // MARK: - Nothing needed → .none

    func testNothingNeededReturnsNone() {
        XCTAssertEqual(decideAllClear(), .none)
    }

    func testNothingNeededIgnoresBlockers() {
        // Every blocker set, but nothing is needed → still .none (blockers are only
        // consulted once a re-route is actually needed).
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: false,
            isLoading: true, isApplyingRoutes: true, cooldownActive: true, hasGateway: false
        ), .none)
    }

    func testNothingNeededWithGatewayStillNone() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: false,
            isLoading: false, isApplyingRoutes: false, cooldownActive: false, hasGateway: true
        ), .none)
    }

    // MARK: - Needed + all clear → .reroute

    func testInterfaceChangedAndClearReroutes() {
        XCTAssertEqual(decideAllClear(interfaceChanged: true), .reroute)
    }

    func testTailscaleChangedAndClearReroutes() {
        XCTAssertEqual(decideAllClear(tailscaleChanged: true), .reroute)
    }

    func testPendingAndClearReroutes() {
        // The drain path: a previously-latched re-route runs once the gate frees.
        XCTAssertEqual(decideAllClear(pending: true), .reroute)
    }

    // MARK: - The leak scenario: blocked while applying → .latch

    func testInterfaceChangedWhileApplyingRoutesLatches() {
        // Gate held (isApplyingRoutes) by a concurrent DNS refresh — the exact window
        // where the old code dropped the re-route. Must LATCH, not drop.
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: false, pending: false,
            isLoading: false, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
        ), .latch)
    }

    func testTailscaleChangedWhileApplyingRoutesLatches() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: true, pending: false,
            isLoading: false, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
        ), .latch)
    }

    func testLatchedThenGateFreeReroutes() {
        // Continuation of the leak scenario: the interface value has already advanced,
        // so interfaceChanged is now FALSE, but the latch (pending) carries the need.
        // Gate now free → the re-route finally runs. This is what closes the leak.
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: false, isApplyingRoutes: false, cooldownActive: false, hasGateway: true
        ), .reroute)
    }

    // MARK: - Each blocker alone defers a needed re-route → .latch

    func testCooldownActiveLatches() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: false, pending: false,
            isLoading: false, isApplyingRoutes: false, cooldownActive: true, hasGateway: true
        ), .latch)
    }

    func testIsLoadingLatches() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: false, pending: false,
            isLoading: true, isApplyingRoutes: false, cooldownActive: false, hasGateway: true
        ), .latch)
    }

    func testNoGatewayLatches() {
        // hasGateway folds in "gateway present AND helper ready"; either missing → latch.
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: false, pending: false,
            isLoading: false, isApplyingRoutes: false, cooldownActive: false, hasGateway: false
        ), .latch)
    }

    func testPendingDuringCooldownLatches() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: false, isApplyingRoutes: false, cooldownActive: true, hasGateway: true
        ), .latch)
    }

    func testPendingWithNoGatewayLatches() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: false, isApplyingRoutes: false, cooldownActive: false, hasGateway: false
        ), .latch)
    }

    func testPendingWhileApplyingLatches() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: true, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
        ), .latch)
    }

    func testAllBlockersTogetherLatch() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: false, pending: false,
            isLoading: true, isApplyingRoutes: true, cooldownActive: true, hasGateway: false
        ), .latch)
    }

    // MARK: - Premature-commit invariant

    func testPendingSurvivesInterfaceFlagGoingFalse() {
        // The crux of the fix: after the premature commit interfaceChanged==false, so
        // ONLY `pending` keeps the re-route alive. It must still be honored.
        XCTAssertEqual(decideAllClear(interfaceChanged: false, pending: true), .reroute)
    }

    func testPendingLatchedStaysNeededAcrossBlockedPasses() {
        // Multiple blocked passes in a row: still latched every time, never dropped.
        for _ in 0..<3 {
            XCTAssertEqual(RerouteDecider.decide(
                interfaceChanged: false, tailscaleChanged: false, pending: true,
                isLoading: false, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
            ), .latch)
        }
    }

    // MARK: - End-to-end leak sequence (blocked → latched → healed)

    func testLeakSequenceBlockedThenLatchedThenRerouted() {
        // 1) utun renumbers during a DNS refresh: interface changed, gate held → latch.
        let step1 = RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: false, pending: false,
            isLoading: false, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
        )
        XCTAssertEqual(step1, .latch, "gate held → must latch (not drop) the re-route")

        // 2) checkVPNStatus has committed the new interface (interfaceChanged now false)
        //    and the DNS refresh still holds the gate → still latched via pending.
        let step2 = RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: false, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
        )
        XCTAssertEqual(step2, .latch, "committed interface + gate still held → stay latched")

        // 3) DNS refresh releases the gate → the latched re-route finally runs.
        let step3 = RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: false, isApplyingRoutes: false, cooldownActive: false, hasGateway: true
        )
        XCTAssertEqual(step3, .reroute, "gate freed → drain the latch, closing the leak")
    }

    func testTailscaleLatchThenDrainViaPending() {
        // Tailscale profile change blocked, then drained through pending after the
        // fingerprint has been committed (tailscaleChanged goes false).
        let blocked = RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: true, pending: false,
            isLoading: false, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
        )
        XCTAssertEqual(blocked, .latch)
        let drained = RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: false, isApplyingRoutes: false, cooldownActive: false, hasGateway: true
        )
        XCTAssertEqual(drained, .reroute)
    }

    func testCooldownExpiryDrainsLatch() {
        // During cooldown a needed change latches; once the 10s window elapses
        // (cooldownActive=false) the latch drains.
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: false, pending: false,
            isLoading: false, isApplyingRoutes: false, cooldownActive: true, hasGateway: true
        ), .latch)
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: false, tailscaleChanged: false, pending: true,
            isLoading: false, isApplyingRoutes: false, cooldownActive: false, hasGateway: true
        ), .reroute)
    }

    // MARK: - Combined change flags

    func testBothChangesClearReroutes() {
        XCTAssertEqual(decideAllClear(interfaceChanged: true, tailscaleChanged: true), .reroute)
    }

    func testBothChangesBlockedLatch() {
        XCTAssertEqual(RerouteDecider.decide(
            interfaceChanged: true, tailscaleChanged: true, pending: false,
            isLoading: false, isApplyingRoutes: true, cooldownActive: false, hasGateway: true
        ), .latch)
    }

    // MARK: - RerouteAction equality sanity

    func testRerouteActionEquality() {
        XCTAssertEqual(Action.reroute, .reroute)
        XCTAssertEqual(Action.latch, .latch)
        XCTAssertEqual(Action.none, .none)
        XCTAssertNotEqual(Action.reroute, .latch)
        XCTAssertNotEqual(Action.latch, .none)
        XCTAssertNotEqual(Action.reroute, .none)
    }
}

/// Stateful coverage for the leak-critical latch-CLEAR TIMING in performReroute
/// (adversarial review MAJOR-1). The pure RerouteDecider tests above can't catch this —
/// it's about WHEN performReroute clears `pendingReroute` relative to the multi-second
/// apply. Two checkVPNStatus passes can interleave on @MainActor (refreshStatus spawns
/// independent Tasks with no reentrancy guard), so a re-route that cleared the latch at
/// its END would wipe a NEWER change latched by a concurrent pass DURING the apply,
/// stranding routes on the stale interface — a silent VPN-Only leak. These tests drive
/// performReroute through a test-only apply seam (no helper / kernel / hosts I/O) so the
/// ordering is exercised deterministically, with no reliance on timing.
@MainActor
final class RerouteLatchTimingTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func tearDown() {
        rm.rerouteApplyOverrideForTests = nil
        rm.pendingReroute = false
        rm.pendingRerouteReason = nil
        rm.localGateway = nil
        super.tearDown()
    }

    /// MAJOR-1: a latch set by a concurrent checkVPNStatus DURING the apply must survive
    /// performReroute. With the old code (clear at END) it was wiped and the retry then
    /// saw pendingReroute == false and stopped → leak. With the fix (clear at START) the
    /// fresh latch survives so the retry chain drains it to the newest interface.
    func testConcurrentLatchDuringRerouteIsNotWiped() async {
        rm.localGateway = "10.0.0.1"
        rm.pendingReroute = true
        rm.pendingRerouteReason = "initial change"

        rm.rerouteApplyOverrideForTests = {
            // Runs at the mid-apply point — AFTER performReroute's synchronous
            // start-clear. First prove the start-clear happened…
            XCTAssertFalse(RouteManager.shared.pendingReroute,
                           "latch must be cleared at the START of the re-route, before the apply")
            // …then model a concurrent checkVPNStatus latching a NEWER change while the
            // apply is still in flight.
            RouteManager.shared.pendingReroute = true
            RouteManager.shared.pendingRerouteReason = "newer change during apply"
        }

        await rm.performReroute()

        XCTAssertTrue(rm.pendingReroute,
                      "a latch set during the in-flight apply must NOT be wiped by performReroute's completion")
        XCTAssertEqual(rm.pendingRerouteReason, "newer change during apply")
    }

    /// A plain re-route with no concurrent change clears the latch exactly once (at the
    /// start) and leaves it clear.
    func testRerouteClearsLatchWhenNoConcurrentChange() async {
        rm.localGateway = "10.0.0.1"
        rm.pendingReroute = true
        rm.pendingRerouteReason = "some change"
        rm.rerouteApplyOverrideForTests = { /* no concurrent latch */ }

        await rm.performReroute()

        XCTAssertFalse(rm.pendingReroute, "a completed re-route with no concurrent change clears the latch")
        XCTAssertNil(rm.pendingRerouteReason)
    }

    /// The clear lives INSIDE the acquired block: with no gateway, performReroute is a
    /// no-op and must NOT clear an outstanding latch (MINOR-1) — the retry re-detects the
    /// gateway and drains it later.
    func testNoGatewayDoesNotClearLatch() async {
        rm.localGateway = nil
        rm.pendingReroute = true
        rm.pendingRerouteReason = "change awaiting gateway"
        var applyRan = false
        rm.rerouteApplyOverrideForTests = { applyRan = true }

        await rm.performReroute()

        XCTAssertFalse(applyRan, "no gateway → no apply body runs")
        XCTAssertTrue(rm.pendingReroute, "a no-op re-route must not clear the latch")
        XCTAssertEqual(rm.pendingRerouteReason, "change awaiting gateway")
    }
}
