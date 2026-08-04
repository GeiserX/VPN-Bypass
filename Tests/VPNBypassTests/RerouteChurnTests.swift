// RerouteChurnTests.swift
// Regression coverage for #65 (route churn destabilises third-party VPN clients).
//
// A re-route used to be a full teardown-and-rebuild: `removeAllRoutes()` followed by
// `applyAllRoutesInternal()`. Because `removeAllRoutes()` clears `activeRoutes`, the
// `shouldSkipReapply` no-op guard could never fire on that path — activePairs was always
// empty, so it never equalled desiredPairs — and every re-route re-issued the entire route
// set (N deletes, then N delete-before-adds). In Bypass mode the routes egress via the LOCAL
// gateway, so the usual trigger (a VPN interface renumber) changes no destination|gateway pair
// and the whole storm rebuilt routes to the values they already had. Each mutation raises a
// kernel route-change event; GlobalProtect re-validates its gateway route on every one and
// tears down its tunnel when that lookup transiently fails (measured: 757 route-change events
// → 48 tunnel teardowns in one day).
//
// The detector used here is `routeEpoch`. `removeAllRoutes()` increments it as its
// unconditional first statement and nothing else in the apply path touches it, so an unchanged
// epoch across `performReroute()` is exact evidence that no teardown occurred.
// `testRemoveAllRoutesBumpsEpoch` is the negative control proving the detector actually moves.

import XCTest
@testable import VPNBypassCore

@MainActor
final class RerouteChurnTests: XCTestCase {

    private var savedGateway: String?
    private var savedManageHostsFile = false
    private var savedRoutingMode: RoutingMode = .bypass
    private var savedDomains: [DomainEntry] = []
    private var savedServices: [ServiceEntry] = []

    override func setUp() {
        super.setUp()
        let rm = RouteManager.shared
        savedGateway = rm.localGateway
        savedManageHostsFile = rm.config.manageHostsFile
        savedRoutingMode = rm.config.routingMode
        savedDomains = rm.config.domains
        savedServices = rm.config.services

        // Deterministic, side-effect-free state: a gateway (so the re-route is runnable), no
        // hosts-file writes, and an empty desired set so no DNS resolution or helper call is
        // attempted. None of that affects the property under test — whether a TEARDOWN happens.
        rm.localGateway = "192.0.2.1"          // TEST-NET-1 (RFC 5737), never routable
        rm.config.manageHostsFile = false
        rm.config.routingMode = .bypass
        rm.config.domains = []
        rm.config.services = []
        rm.activeRoutes = []
        rm.rerouteApplyOverrideForTests = nil  // exercise the REAL apply path, not the seam
    }

    override func tearDown() {
        let rm = RouteManager.shared
        rm.rerouteApplyOverrideForTests = nil
        rm.activeRoutes = []
        rm.localGateway = savedGateway
        rm.config.manageHostsFile = savedManageHostsFile
        rm.config.routingMode = savedRoutingMode
        rm.config.domains = savedDomains
        rm.config.services = savedServices
        super.tearDown()
    }

    /// Shared precondition. `RouteManager` is a `private init` singleton that loads the real
    /// on-disk config at first touch, so unrelated suites can leave asynchronous startup work
    /// holding the route-operation gate. `performReroute` try-acquires, so with the gate held it
    /// is a no-op and any assertion about its behaviour would be vacuous. Skip loudly instead of
    /// reporting a green pass or a spurious failure. See `.goal-loop/GOAL-WORKLOG.md` — making the
    /// suite hermetic is tracked as its own slice.
    private func requireFreeRouteGate() throws {
        try XCTSkipIf(
            RouteManager.shared.isApplyingRoutes,
            "route-operation gate held by unrelated async startup work — cannot exercise performReroute"
        )
    }

    /// #65: a re-route must RECONCILE, never tear the whole table down first.
    /// Fails against the old `removeAllRoutes()` + `applyAllRoutesInternal()` body.
    func testRerouteDoesNotTearDownTheWholeTable() async throws {
        let rm = RouteManager.shared
        try requireFreeRouteGate()
        let epochBefore = rm.routeEpochForTests

        await rm.performReroute()

        XCTAssertEqual(
            rm.routeEpochForTests, epochBefore,
            "#65: performReroute must not call removeAllRoutes — a teardown re-issues the entire "
            + "route set (~3N kernel mutations), and every mutation is a route-change event that "
            + "destabilises third-party VPN clients"
        )
    }

    /// Negative control: proves the epoch detector above is load-bearing rather than a constant.
    /// `removeAllRoutes()` bumps the epoch even with an empty table, so if `performReroute()`
    /// still tore down, the assertion above would necessarily fail.
    func testRemoveAllRoutesBumpsEpoch() async {
        let rm = RouteManager.shared
        let epochBefore = rm.routeEpochForTests

        await rm.removeAllRoutes()

        XCTAssertNotEqual(
            rm.routeEpochForTests, epochBefore,
            "removeAllRoutes must bump routeEpoch — the preemption/teardown detector depends on it"
        )
    }

    /// Guards against "fixed the churn by making re-route a no-op": the apply body must still be
    /// invoked. Uses the existing `rerouteApplyOverrideForTests` seam, so it asserts the branch is
    /// reached without touching the helper, the kernel, or /etc/hosts.
    func testRerouteStillPerformsTheApply() async throws {
        let rm = RouteManager.shared
        try requireFreeRouteGate()
        var applyRan = false
        rm.rerouteApplyOverrideForTests = { applyRan = true }

        await rm.performReroute()

        XCTAssertTrue(
            applyRan,
            "performReroute must still run the apply — dropping the teardown must not turn the "
            + "re-route itself into a no-op, or a genuine gateway change would never be applied"
        )
    }
}
