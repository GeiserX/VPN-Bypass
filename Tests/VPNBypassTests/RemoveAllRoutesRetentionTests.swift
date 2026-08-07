// RemoveAllRoutesRetentionTests.swift
// Regression coverage: removeAllRoutes() must never discard the record of routes it did not
// actually remove.
//
// The bug: when the privileged helper was not ready, removeAllRoutes() logged an error, fell
// through with an empty `failedDests`, and then executed `activeRoutes.removeAll()` — clearing the
// model while every route was still installed in the kernel. Route ownership lives nowhere else
// (`activeRoutes` is in-memory only and never persisted), so that erased the sole evidence the
// routes were ours: nothing afterwards could identify or remove them.
//
// It is reachable on an ordinary quit — the helper can be booted out, or simply not ready — and it
// strands silently, immediately after logging that cleanup was impossible. In VPN Only the
// survivors can include the `0.0.0.0/1` + `128.0.0.0/1` catch-alls, which then steer every
// connection around the tunnel permanently.
//
// The helper is never installed in the test environment, so these tests exercise exactly that path.

import XCTest
@testable import VPNBypassCore

@MainActor
final class RemoveAllRoutesRetentionTests: XCTestCase {

    private var savedRoutes: [RouteManager.ActiveRoute] = []

    override func setUp() {
        super.setUp()
        savedRoutes = RouteManager.shared.activeRoutes
    }

    override func tearDown() {
        RouteManager.shared.activeRoutes = savedRoutes
        super.tearDown()
    }

    private func route(_ dest: String, _ gw: String = "192.168.1.1", _ source: String = "s") -> RouteManager.ActiveRoute {
        RouteManager.ActiveRoute(destination: dest, gateway: gw, source: source, timestamp: Date())
    }

    /// With no helper, nothing can be removed — so nothing may be forgotten.
    func testRoutesAreRetainedWhenTheHelperCannotRemoveThem() async throws {
        let rm = RouteManager.shared
        try XCTSkipIf(HelperManager.shared.isHelperInstalled,
                      "this test exercises the helper-unavailable path; a real helper is installed here")

        rm.activeRoutes = [route("1.1.1.1"), route("2.2.2.2"), route("3.3.3.3")]
        await rm.removeAllRoutes()

        XCTAssertEqual(
            Set(rm.activeRoutes.map { $0.destination }), ["1.1.1.1", "2.2.2.2", "3.3.3.3"],
            "the helper never ran, so every route is still installed — dropping them from the model "
            + "strands them with nothing left able to identify them as ours"
        )
    }

    /// The leak-critical instance: VPN Only's catch-alls must survive in the model, or they steer
    /// every connection around the tunnel with no record that they belong to us.
    func testCatchAllsAreRetainedWhenTheHelperCannotRemoveThem() async throws {
        let rm = RouteManager.shared
        try XCTSkipIf(HelperManager.shared.isHelperInstalled,
                      "this test exercises the helper-unavailable path; a real helper is installed here")

        rm.activeRoutes = [route("0.0.0.0/1", "192.168.1.1", "VPN Only catch-all"),
                           route("128.0.0.0/1", "192.168.1.1", "VPN Only catch-all")]
        await rm.removeAllRoutes()

        XCTAssertEqual(
            Set(rm.activeRoutes.map { $0.destination }), ["0.0.0.0/1", "128.0.0.0/1"],
            "stranded catch-alls that the model has forgotten route ALL traffic around the tunnel"
        )
    }

    /// An empty model stays empty — the retention path must not invent entries.
    func testEmptyModelStaysEmpty() async {
        let rm = RouteManager.shared
        rm.activeRoutes = []
        await rm.removeAllRoutes()
        XCTAssertTrue(rm.activeRoutes.isEmpty)
    }
}
