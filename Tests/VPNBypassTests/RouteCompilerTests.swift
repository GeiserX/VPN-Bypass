// RouteCompilerTests.swift
// Coverage for the pure custom-mode route compiler (Slice 4). RouteCompiler maps
// already-resolved rules → the routesToAdd batch shape the apply paths install:
// direct/specific-VPN egresses emit kernel routes; proxy/tailscale/primary-VPN emit
// nothing (a loopback listener / the OS default carries them); first rule wins per
// destination; and the GlobalProtect catch-all guard refuses tunnel-tearing routes.

import XCTest
@testable import VPNBypassCore

final class RouteCompilerTests: XCTestCase {

    private let direct = Route(name: "direct", egress: .direct)
    private let vpn = Route(name: "vpn", egress: .vpnDefault)
    private let socks = Route(name: "proxy", egress: .proxySOCKS5)
    private let http = Route(name: "http", egress: .proxyHTTP)
    private let tailscale = Route(name: "ts", egress: .tailscaleExit)

    /// Build one resolved rule (rule + its already-resolved destinations).
    private func rr(
        _ route: Route,
        _ dests: [(String, Bool)],
        pattern: String = "p",
        matchType: MatchType = .domain,
        enabled: Bool = true,
        order: Int = 0
    ) -> (rule: Rule, dests: [(value: String, isNetwork: Bool)]) {
        (rule: Rule(matchType: matchType, pattern: pattern, routeId: route.id, enabled: enabled, order: order),
         dests: dests.map { (value: $0.0, isNetwork: $0.1) })
    }

    private let noIface: (Route) -> String? = { _ in nil }

    // MARK: - Egress → gateway mapping

    func testDirectRuleEmitsHostRouteViaLocalGateway() {
        let out = RouteCompiler.compile(
            resolvedRules: [rr(direct, [("1.2.3.4", false)], pattern: "x.com")],
            routes: [direct], localGateway: "192.168.1.1", ifaceGatewayForRoute: noIface
        )
        XCTAssertEqual(out, [RouteCompiler.DesiredRoute(destination: "1.2.3.4", gateway: "192.168.1.1", isNetwork: false, source: "x.com")])
    }

    func testCIDRDestinationEmitsNetworkRoute() {
        let out = RouteCompiler.compile(
            resolvedRules: [rr(direct, [("10.0.0.0/8", true)], pattern: "10.0.0.0/8", matchType: .cidr)],
            routes: [direct], localGateway: "192.168.1.1", ifaceGatewayForRoute: noIface
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.destination, "10.0.0.0/8")
        XCTAssertTrue(out.first?.isNetwork ?? false)
        XCTAssertEqual(out.first?.gateway, "192.168.1.1")
    }

    /// A service rule resolves to a mix of host IPs (its domains) + network ranges
    /// (its ipRanges); the compiler emits both, all via the route's egress.
    func testServiceRuleEmitsDomainsAndIPRanges() {
        let out = RouteCompiler.compile(
            resolvedRules: [rr(direct, [("1.1.1.1", false), ("2.2.2.2", false), ("91.108.4.0/22", true)],
                               pattern: "telegram", matchType: .service)],
            routes: [direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "1.1.1.1", gateway: "gw", isNetwork: false, source: "telegram")))
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "2.2.2.2", gateway: "gw", isNetwork: false, source: "telegram")))
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "91.108.4.0/22", gateway: "gw", isNetwork: true, source: "telegram")))
    }

    /// Proxy, Tailscale, and primary-VPN (iface == nil) egresses are served without a
    /// kernel route — the routing table must stay clear of them.
    func testProxyTailscaleAndPrimaryVPNEmitNothing() {
        let out = RouteCompiler.compile(
            resolvedRules: [
                rr(socks, [("1.1.1.1", false)], pattern: "a", order: 0),
                rr(http, [("2.2.2.2", false)], pattern: "b", order: 1),
                rr(tailscale, [("3.3.3.3", false)], pattern: "c", order: 2),
                rr(vpn, [("4.4.4.4", false)], pattern: "d", order: 3),
            ],
            routes: [socks, http, tailscale, vpn], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        XCTAssertTrue(out.isEmpty)
    }

    /// The Slice-4 hook: a specific VPN (ifaceGatewayForRoute returns "iface:utunX")
    /// DOES emit a kernel route into that tunnel.
    func testVPNDefaultWithIfaceEmitsIfaceRoute() {
        let out = RouteCompiler.compile(
            resolvedRules: [rr(vpn, [("10.1.2.3", false)], pattern: "corp")],
            routes: [vpn], localGateway: "gw", ifaceGatewayForRoute: { _ in "iface:utun4" }
        )
        XCTAssertEqual(out, [RouteCompiler.DesiredRoute(destination: "10.1.2.3", gateway: "iface:utun4", isNetwork: false, source: "corp")])
    }

    // MARK: - Dedup / ordering

    /// First rule to claim a destination wins — even when that rule's egress emits no
    /// kernel route. Here the proxy claims 1.2.3.4, so the later Direct rule must NOT
    /// install a kernel route (otherwise the destination splits across two egresses).
    func testFirstRuleClaimsDestinationEvenWhenItEmitsNothing() {
        let out = RouteCompiler.compile(
            resolvedRules: [
                rr(socks, [("1.2.3.4", false)], pattern: "a", order: 0),
                rr(direct, [("1.2.3.4", false)], pattern: "b", order: 1),
            ],
            routes: [socks, direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        XCTAssertTrue(out.isEmpty, "proxy claimed the dest first; Direct must not route it")
    }

    func testFirstRuleWinsForEmittedRoute() {
        let out = RouteCompiler.compile(
            resolvedRules: [
                rr(direct, [("1.2.3.4", false)], pattern: "a", order: 0),
                rr(vpn, [("1.2.3.4", false)], pattern: "b", order: 1),
            ],
            routes: [direct, vpn], localGateway: "gw", ifaceGatewayForRoute: { _ in "iface:utun9" }
        )
        XCTAssertEqual(out, [RouteCompiler.DesiredRoute(destination: "1.2.3.4", gateway: "gw", isNetwork: false, source: "a")])
    }

    func testDisabledRuleSkipped() {
        let out = RouteCompiler.compile(
            resolvedRules: [rr(direct, [("1.2.3.4", false)], pattern: "x", enabled: false)],
            routes: [direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testDanglingRouteIdSkipped() {
        let dangling = Rule(matchType: .domain, pattern: "x", routeId: UUID(), order: 0)
        let out = RouteCompiler.compile(
            resolvedRules: [(rule: dangling, dests: [(value: "1.2.3.4", isNetwork: false)])],
            routes: [direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - GlobalProtect catch-all guard

    func testIsCatchAllRecognizesAllThreeForms() {
        for d in ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1"] {
            XCTAssertTrue(RouteCompiler.isCatchAll(d), "\(d) should be a catch-all")
        }
        XCTAssertFalse(RouteCompiler.isCatchAll("10.0.0.0/8"))
        XCTAssertFalse(RouteCompiler.isCatchAll("1.2.3.4"))
    }

    func testCatchAllIntoNonPrimaryEgressRefusedUnderGlobalProtect() {
        let compiled = RouteCompiler.compile(
            resolvedRules: [rr(direct, [("0.0.0.0/0", true)], pattern: "0.0.0.0/0", matchType: .cidr)],
            routes: [direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        XCTAssertEqual(compiled.count, 1, "the compiler emits it; the GP guard is what refuses it")

        let underGP = RouteCompiler.guardCatchAllUnderGlobalProtect(compiled, isGlobalProtect: true)
        XCTAssertTrue(underGP.kept.isEmpty)
        XCTAssertEqual(underGP.refused.map(\.destination), ["0.0.0.0/0"])

        // GP down → nothing refused.
        let noGP = RouteCompiler.guardCatchAllUnderGlobalProtect(compiled, isGlobalProtect: false)
        XCTAssertEqual(noGP.kept.count, 1)
        XCTAssertTrue(noGP.refused.isEmpty)
    }

    func testGuardKeepsNonCatchAllRoutesUnderGlobalProtect() {
        let compiled = RouteCompiler.compile(
            resolvedRules: [rr(direct, [("1.2.3.4", false), ("10.0.0.0/8", true)], pattern: "x")],
            routes: [direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        let g = RouteCompiler.guardCatchAllUnderGlobalProtect(compiled, isGlobalProtect: true)
        XCTAssertEqual(g.kept.count, 2)
        XCTAssertTrue(g.refused.isEmpty)
    }
}
