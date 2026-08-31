import XCTest
@testable import VPNBypassCore

/// Exhaustive tests for the classic Bypass / VPN Only route builder — the default-mode apply
/// path that a regression would leak. These pin the catch-all injection, the first-wins dedup
/// (kernel destinations AND (source,destination) ownership pairs), the gateway assignment, and
/// the Bypass-vs-VPN-Only structural differences that used to live untested inside
/// applyAllRoutesInternal.
final class ClassicRouteCompilerTests: XCTestCase {
    typealias C = ClassicRouteCompiler
    private let local = "192.168.1.1"
    private let vpn = "10.0.0.1"

    private func route(_ d: String, _ g: String, _ n: Bool, _ s: String) -> C.Route {
        C.Route(destination: d, gateway: g, isNetwork: n, source: s)
    }
    private func entry(_ d: String, _ g: String, _ s: String) -> C.SourceEntry {
        C.SourceEntry(destination: d, gateway: g, source: s)
    }

    // MARK: - Bypass mode

    func testBypassSimpleDomainsAreHostRoutesViaLocalGateway() {
        let b = C.build(isInverse: false, localGateway: local, routeGateway: local,
                        inverseCIDRs: [],
                        resolvedGroups: [C.ResolvedGroup(source: "a.com", ips: ["1.1.1.1", "1.0.0.1"]),
                                         C.ResolvedGroup(source: "b.com", ips: ["2.2.2.2"])],
                        serviceRanges: [])
        XCTAssertEqual(b.routesToAdd, [
            route("1.1.1.1", local, false, "a.com"),
            route("1.0.0.1", local, false, "a.com"),
            route("2.2.2.2", local, false, "b.com"),
        ])
        XCTAssertEqual(b.allSourceEntries, [
            entry("1.1.1.1", local, "a.com"),
            entry("1.0.0.1", local, "a.com"),
            entry("2.2.2.2", local, "b.com"),
        ])
    }

    func testBypassNoCatchAllInjected() {
        let b = C.build(isInverse: false, localGateway: local, routeGateway: local,
                        inverseCIDRs: [], resolvedGroups: [], serviceRanges: [])
        XCTAssertTrue(b.routesToAdd.isEmpty)
        XCTAssertTrue(b.allSourceEntries.isEmpty)
        XCTAssertFalse(b.routesToAdd.contains { RouteCompiler.catchAllDestinations.contains($0.destination) })
    }

    func testBypassSameIPFromTwoSourcesIsOneRouteButTwoOwnershipEntries() {
        let b = C.build(isInverse: false, localGateway: local, routeGateway: local,
                        inverseCIDRs: [],
                        resolvedGroups: [C.ResolvedGroup(source: "a.com", ips: ["1.1.1.1"]),
                                         C.ResolvedGroup(source: "svc", ips: ["1.1.1.1"])],
                        serviceRanges: [])
        // First source wins the single kernel route...
        XCTAssertEqual(b.routesToAdd, [route("1.1.1.1", local, false, "a.com")])
        // ...but both ownership pairs are recorded.
        XCTAssertEqual(b.allSourceEntries, [
            entry("1.1.1.1", local, "a.com"),
            entry("1.1.1.1", local, "svc"),
        ])
    }

    func testBypassDuplicateIPsWithinOneGroupDeduped() {
        let b = C.build(isInverse: false, localGateway: local, routeGateway: local,
                        inverseCIDRs: [],
                        resolvedGroups: [C.ResolvedGroup(source: "a.com", ips: ["9.9.9.9", "9.9.9.9"])],
                        serviceRanges: [])
        XCTAssertEqual(b.routesToAdd, [route("9.9.9.9", local, false, "a.com")])
        XCTAssertEqual(b.allSourceEntries, [entry("9.9.9.9", local, "a.com")])
    }

    func testBypassServiceRangesAreNetworkRoutesViaLocalGateway() {
        let b = C.build(isInverse: false, localGateway: local, routeGateway: local,
                        inverseCIDRs: [],
                        resolvedGroups: [C.ResolvedGroup(source: "a.com", ips: ["1.1.1.1"])],
                        serviceRanges: [(source: "svc", range: "10.0.0.0/8")])
        XCTAssertEqual(b.routesToAdd, [
            route("1.1.1.1", local, false, "a.com"),
            route("10.0.0.0/8", local, true, "svc"),
        ])
        XCTAssertEqual(b.allSourceEntries, [
            entry("1.1.1.1", local, "a.com"),
            entry("10.0.0.0/8", local, "svc"),
        ])
    }

    func testBypassServiceRangeOwnershipRecordedEvenWhenDestinationIsDuplicate() {
        // The preserved quirk: a duplicate range still records its ownership pair, but only one
        // kernel route.
        let b = C.build(isInverse: false, localGateway: local, routeGateway: local,
                        inverseCIDRs: [], resolvedGroups: [],
                        serviceRanges: [(source: "svc1", range: "10.0.0.0/8"),
                                        (source: "svc2", range: "10.0.0.0/8")])
        XCTAssertEqual(b.routesToAdd, [route("10.0.0.0/8", local, true, "svc1")])
        XCTAssertEqual(b.allSourceEntries, [
            entry("10.0.0.0/8", local, "svc1"),
            entry("10.0.0.0/8", local, "svc2"),
        ])
    }

    // MARK: - VPN Only mode

    /// The catch-alls must be installed LAST, and this ordering is leak-critical rather than
    /// cosmetic. The helper writes `routesToAdd` strictly in order, one subprocess per route, so
    /// emitting the catch-alls first pointed ALL traffic at the local gateway while the listed
    /// destinations still had no VPN route — the exact destinations the user asked to protect went
    /// out in the clear for the length of the apply. Teardown already removes catch-alls first (so
    /// traffic falls back INTO the VPN default); this is the same principle at the other end.
    ///
    /// Note `allSourceEntries` (ownership bookkeeping, not install order) is unchanged.
    func testVPNOnlyInstallsCatchAllLastSoVPNRoutesLandFirst() {
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: [],
                        resolvedGroups: [C.ResolvedGroup(source: "x.com", ips: ["3.3.3.3"])],
                        serviceRanges: [])
        XCTAssertEqual(b.routesToAdd, [
            route("3.3.3.3", vpn, false, "x.com"),   // domain IP rides the VPN gateway — installed FIRST
            route("0.0.0.0/2", local, true, "VPN Only catch-all"),
            route("64.0.0.0/2", local, true, "VPN Only catch-all"),
            route("128.0.0.0/2", local, true, "VPN Only catch-all"),
            route("192.0.0.0/2", local, true, "VPN Only catch-all"),
        ])
        XCTAssertEqual(b.allSourceEntries, [
            entry("0.0.0.0/2", local, "VPN Only catch-all"),
            entry("64.0.0.0/2", local, "VPN Only catch-all"),
            entry("128.0.0.0/2", local, "VPN Only catch-all"),
            entry("192.0.0.0/2", local, "VPN Only catch-all"),
            entry("3.3.3.3", vpn, "x.com"),
        ])
    }

    func testVPNOnlyInverseCIDRsAreInstalledBeforeTheCatchAll() {
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: ["172.16.0.0/12"], resolvedGroups: [], serviceRanges: [])
        XCTAssertEqual(b.routesToAdd, [
            route("172.16.0.0/12", vpn, true, "172.16.0.0/12"),
            route("0.0.0.0/2", local, true, "VPN Only catch-all"),
            route("64.0.0.0/2", local, true, "VPN Only catch-all"),
            route("128.0.0.0/2", local, true, "VPN Only catch-all"),
            route("192.0.0.0/2", local, true, "VPN Only catch-all"),
        ])
    }

    /// Guards the invariant directly, independent of the exact route set: whatever else is being
    /// installed, no catch-all may precede a non-catch-all.
    func testNoCatchAllIsInstalledBeforeAnyProtectedRoute() {
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: ["172.16.0.0/12", "10.1.0.0/16"],
                        resolvedGroups: [C.ResolvedGroup(source: "a.com", ips: ["4.4.4.4", "5.5.5.5"])],
                        serviceRanges: [])
        let catchAlls = Set(C.bypassAllCatchAlls)
        let firstCatchAll = b.routesToAdd.firstIndex { catchAlls.contains($0.destination) }
        let lastProtected = b.routesToAdd.lastIndex { !catchAlls.contains($0.destination) }
        XCTAssertNotNil(firstCatchAll, "VPN Only must install catch-alls")
        if let first = firstCatchAll, let last = lastProtected {
            XCTAssertGreaterThan(first, last,
                "every VPN-bound route must be installed before the first catch-all, or traffic to "
                + "those destinations egresses the local gateway for the duration of the apply")
        }
    }

    /// #104 review: a listed inverse CIDR that is exactly one of the quarters must keep its
    /// VPN route — that quarter is simply not claimed for the local gateway (one kernel entry
    /// exists per destination, and the user's explicit choice wins it).
    func testExactQuarterInverseCIDRKeepsItsVPNRoute() {
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: ["0.0.0.0/2"], resolvedGroups: [], serviceRanges: [])
        XCTAssertEqual(b.routesToAdd, [
            route("0.0.0.0/2", vpn, true, "0.0.0.0/2"),
            route("64.0.0.0/2", local, true, "VPN Only catch-all"),
            route("128.0.0.0/2", local, true, "VPN Only catch-all"),
            route("192.0.0.0/2", local, true, "VPN Only catch-all"),
        ])
        XCTAssertEqual(b.allSourceEntries.filter { $0.destination == "0.0.0.0/2" },
                       [entry("0.0.0.0/2", vpn, "0.0.0.0/2")])
    }

    func testVPNOnlyDuplicateInverseCIDRDeduped() {
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: ["172.16.0.0/12", "172.16.0.0/12"],
                        resolvedGroups: [], serviceRanges: [])
        let cidrRoutes = b.routesToAdd.filter { $0.destination == "172.16.0.0/12" }
        XCTAssertEqual(cidrRoutes, [route("172.16.0.0/12", vpn, true, "172.16.0.0/12")])
        let cidrOwners = b.allSourceEntries.filter { $0.destination == "172.16.0.0/12" }
        XCTAssertEqual(cidrOwners.count, 1)
    }

    func testVPNOnlyIgnoresServiceRanges() {
        // Services are a Bypass-only concept; VPN Only must never emit them even if passed.
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: [], resolvedGroups: [],
                        serviceRanges: [(source: "svc", range: "10.0.0.0/8")])
        XCTAssertEqual(b.routesToAdd, [
            route("0.0.0.0/2", local, true, "VPN Only catch-all"),
            route("64.0.0.0/2", local, true, "VPN Only catch-all"),
            route("128.0.0.0/2", local, true, "VPN Only catch-all"),
            route("192.0.0.0/2", local, true, "VPN Only catch-all"),
        ])
        XCTAssertFalse(b.routesToAdd.contains { $0.destination == "10.0.0.0/8" })
    }

    func testVPNOnlyEmptyIsCatchAllOnly() {
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: [], resolvedGroups: [], serviceRanges: [])
        XCTAssertEqual(b.routesToAdd, [
            route("0.0.0.0/2", local, true, "VPN Only catch-all"),
            route("64.0.0.0/2", local, true, "VPN Only catch-all"),
            route("128.0.0.0/2", local, true, "VPN Only catch-all"),
            route("192.0.0.0/2", local, true, "VPN Only catch-all"),
        ])
        XCTAssertEqual(b.allSourceEntries.count, C.bypassAllCatchAlls.count)
    }

    // MARK: - Invariants that guard against a leak

    func testEveryOwnershipDestinationHasAKernelRoute() {
        // commitAppliedRoutes builds activeRoutes only for allSourceEntries whose destination is
        // in routesToAdd — so every ownership destination must have a matching route, or the
        // ownership row is silently dropped.
        let b = C.build(isInverse: true, localGateway: local, routeGateway: vpn,
                        inverseCIDRs: ["172.16.0.0/12"],
                        resolvedGroups: [C.ResolvedGroup(source: "a.com", ips: ["1.1.1.1"]),
                                         C.ResolvedGroup(source: "svc", ips: ["1.1.1.1"])],
                        serviceRanges: [])
        let routeDests = Set(b.routesToAdd.map { $0.destination })
        for e in b.allSourceEntries {
            XCTAssertTrue(routeDests.contains(e.destination), "ownership dest \(e.destination) has no kernel route")
        }
    }

    func testEachDestinationMapsToExactlyOneGateway() {
        // In classic mode a destination must never appear with two gateways, or the winning
        // route depends on ordering (a real leak risk). Uses overlapping inputs.
        let b = C.build(isInverse: false, localGateway: local, routeGateway: local,
                        inverseCIDRs: [],
                        resolvedGroups: [C.ResolvedGroup(source: "a", ips: ["1.1.1.1", "2.2.2.2"]),
                                         C.ResolvedGroup(source: "b", ips: ["1.1.1.1"])],
                        serviceRanges: [(source: "svc", range: "2.2.2.2")])
        var gatewayByDest: [String: String] = [:]
        for r in b.routesToAdd {
            if let g = gatewayByDest[r.destination] { XCTAssertEqual(g, r.gateway) }
            gatewayByDest[r.destination] = r.gateway
        }
    }
}
