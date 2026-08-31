// VPNBoundRouteTests.swift
// Coverage for which routes actually go stale when the VPN disconnects.
//
// Why this exists: the disconnect handler used to tear down EVERY route and the reconnect then
// rebuilt them all. With a tunnel that flaps, that dominated everything — one machine logged 15
// disconnect events and 8 full 342-route rebuilds in a single day, and every rebuild fires hundreds
// of kernel route-change events that the VPN client itself reacts to, feeding the instability that
// caused the disconnect in the first place.
//
// The distinction that fixes it: in Bypass mode every route egresses via the LOCAL gateway, so a
// VPN disconnect leaves them correct — those destinations were already going direct. Only routes
// bound to the VPN (its gateway, or a tunnel interface) and the VPN-Only catch-alls actually go
// stale. Getting this wrong in the permissive direction would leave a route pointing at a dead
// gateway (blackhole); in the aggressive direction it is merely the old churn.

import XCTest
@testable import VPNBypassCore

final class VPNBoundRouteTests: XCTestCase {

    private let local = "192.168.1.1"
    private let vpn = "10.10.0.1"
    private let catchAlls = RouteCompiler.catchAllDestinations

    private func route(_ dest: String, _ gw: String, _ source: String = "s") -> RouteManager.ActiveRoute {
        RouteManager.ActiveRoute(destination: dest, gateway: gw, source: source, timestamp: Date())
    }

    private func stale(_ routes: [RouteManager.ActiveRoute], localGateway: String? = "192.168.1.1") -> [String] {
        RouteManager.vpnBoundDestinations(activeRoutes: routes, localGateway: localGateway, catchAlls: catchAlls)
    }

    /// The Bypass case, and the whole point of the change: nothing is stale, so a disconnect costs
    /// zero kernel mutations and the reconnect finds every route already correct.
    func testBypassRoutesViaLocalGatewayAreNotStale() {
        let routes = [route("1.1.1.1", local), route("2.2.2.2", local), route("10.0.0.0/8", local)]
        XCTAssertTrue(stale(routes).isEmpty,
            "routes egressing the local gateway stay valid when the VPN goes away — removing them is pure churn")
    }

    /// Routes pointing at the VPN's gateway are dead the moment the tunnel drops; leaving them
    /// installed would blackhole those destinations.
    func testRoutesViaVPNGatewayAreStale() {
        let routes = [route("3.3.3.3", vpn), route("4.4.4.4", local)]
        XCTAssertEqual(stale(routes), ["3.3.3.3"])
    }

    /// Interface-scoped routes name a tunnel that is going away (the `iface:` convention used for
    /// VPNs that publish a link-only default route, e.g. Cisco Secure Client).
    func testInterfaceBoundRoutesAreStale() {
        let routes = [route("5.5.5.5", "iface:utun4"), route("6.6.6.6", local)]
        XCTAssertEqual(stale(routes), ["5.5.5.5"])
    }

    /// VPN-Only catch-alls are always torn down, even though they egress the LOCAL gateway and so
    /// would otherwise look "still valid" by the gateway test alone. The /1 pair here is what
    /// builds up to 4.8.0 installed — it stays recognised so an update cleans an old strand.
    func testCatchAllsAreAlwaysStaleEvenViaLocalGateway() {
        let routes = [route("0.0.0.0/1", local, "VPN Only catch-all"),
                      route("128.0.0.0/1", local, "VPN Only catch-all"),
                      route("7.7.7.7", local)]
        XCTAssertEqual(Set(stale(routes)), ["0.0.0.0/1", "128.0.0.0/1"])
    }

    /// The /2 quartet VPN Only installs since #103 is recognised the same way.
    func testQuartetCatchAllsAreStale() {
        let routes = ClassicRouteCompiler.bypassAllCatchAlls.map { route($0, local, "VPN Only catch-all") }
            + [route("7.7.7.7", local)]
        XCTAssertEqual(Set(stale(routes)), Set(ClassicRouteCompiler.bypassAllCatchAlls))
    }

    /// With no known local gateway we cannot prove any route is still valid, so everything is
    /// treated as stale. Fails toward removing (churn) rather than toward leaving a dead route.
    func testUnknownLocalGatewayTreatsEverythingAsStale() {
        let routes = [route("8.8.8.8", local), route("9.9.9.9", vpn)]
        XCTAssertEqual(Set(stale(routes, localGateway: String?.none)), ["8.8.8.8", "9.9.9.9"])
    }

    func testEmptyRouteSetHasNothingStale() {
        XCTAssertTrue(stale([]).isEmpty)
    }

    /// Mixed real-world shape: a Bypass set plus one leftover VPN-bound route.
    func testMixedSetRemovesOnlyTheVPNBoundOne() {
        let routes = [route("1.1.1.1", local), route("2.2.2.2", local),
                      route("3.3.3.3", vpn), route("4.4.4.4", local)]
        let result = stale(routes)
        XCTAssertEqual(result, ["3.3.3.3"])
        XCTAssertEqual(routes.count - result.count, 3, "the three local-gateway routes must be kept")
    }
}
