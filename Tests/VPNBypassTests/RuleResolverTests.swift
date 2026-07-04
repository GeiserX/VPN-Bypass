// RuleResolverTests.swift
// Coverage for the pure rule→route resolver (P1, VPN-Bypass-3sc.8).

import XCTest
@testable import VPNBypassCore

final class RuleResolverTests: XCTestCase {

    private let vpn = Route(name: "vpn", egress: .vpnDefault)
    private let direct = Route(name: "direct", egress: .direct)
    private let proxy = Route(name: "proxy", egress: .proxySOCKS5)
    private var routes: [Route] { [vpn, direct, proxy] }

    func testExactDomainMatchCaseInsensitiveWithDefaultFallback() {
        let rules = [Rule(matchType: .domain, pattern: "x.com", routeId: proxy.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forDomain: "x.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, proxy.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "X.COM", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, proxy.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "y.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id)
    }

    func testSuffixMatchesOnDotBoundaryOnly() {
        let rules = [Rule(matchType: .suffix, pattern: "example.com", routeId: direct.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forDomain: "api.example.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "example.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "notexample.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id)
    }

    func testServiceMatchRequiresMatchingServiceId() {
        let rules = [Rule(matchType: .service, pattern: "telegram", routeId: direct.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forDomain: "t.me", serviceId: "telegram", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "t.me", serviceId: "spotify", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "t.me", serviceId: nil, rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id)
    }

    func testFirstMatchByOrderWins() {
        let rules = [
            Rule(matchType: .suffix, pattern: "com", routeId: direct.id, order: 5),
            Rule(matchType: .domain, pattern: "x.com", routeId: proxy.id, order: 1),
        ]
        XCTAssertEqual(RuleResolver.route(forDomain: "x.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, proxy.id)
    }

    func testDisabledRuleSkipped() {
        let rules = [Rule(matchType: .domain, pattern: "x.com", routeId: proxy.id, enabled: false, order: 0)]
        XCTAssertEqual(RuleResolver.route(forDomain: "x.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id)
    }

    func testRuleToUnknownRouteFallsThrough() {
        let rules = [
            Rule(matchType: .domain, pattern: "x.com", routeId: UUID(), order: 0),
            Rule(matchType: .domain, pattern: "x.com", routeId: direct.id, order: 1),
        ]
        XCTAssertEqual(RuleResolver.route(forDomain: "x.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id)
    }

    func testNilDefaultWhenNothingMatches() {
        XCTAssertNil(RuleResolver.route(forDomain: "x.com", rules: [], routes: routes, defaultRouteId: nil))
    }

    func testIPExactAndCIDRRouting() {
        let rules = [
            Rule(matchType: .ip, pattern: "1.2.3.4", routeId: proxy.id, order: 0),
            Rule(matchType: .cidr, pattern: "10.0.0.0/8", routeId: direct.id, order: 1),
        ]
        XCTAssertEqual(RuleResolver.route(forIP: "1.2.3.4", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, proxy.id)
        XCTAssertEqual(RuleResolver.route(forIP: "10.1.2.3", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id)
        XCTAssertEqual(RuleResolver.route(forIP: "11.1.2.3", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id)
    }

    func testCIDRContainmentEdges() {
        XCTAssertTrue(RuleResolver.ipv4("10.255.255.255", inCIDR: "10.0.0.0/8"))
        XCTAssertFalse(RuleResolver.ipv4("11.0.0.0", inCIDR: "10.0.0.0/8"))
        XCTAssertTrue(RuleResolver.ipv4("1.2.3.4", inCIDR: "1.2.3.4/32"))
        XCTAssertFalse(RuleResolver.ipv4("1.2.3.5", inCIDR: "1.2.3.4/32"))
        XCTAssertTrue(RuleResolver.ipv4("8.8.8.8", inCIDR: "0.0.0.0/0"))
        XCTAssertFalse(RuleResolver.ipv4("notanip", inCIDR: "10.0.0.0/8"))
        XCTAssertFalse(RuleResolver.ipv4("10.0.0.1", inCIDR: "garbage"))
        XCTAssertFalse(RuleResolver.ipv4("::1", inCIDR: "10.0.0.0/8"))
    }
}
