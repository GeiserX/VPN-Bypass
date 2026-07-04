// RuleResolverEdgeCaseTests.swift
// Additional edge-case coverage for RuleResolver, layered on top of
// RuleResolverTests.swift: the resolver-vs-compiler specificity asymmetry, /0 and
// network-boundary IPs through the full route(forIP:) API, non-IPv4 input handling,
// and suffix/service pattern edge cases.

import XCTest
@testable import VPNBypassCore

final class RuleResolverEdgeCaseTests: XCTestCase {

    private let vpn = Route(name: "vpn", egress: .vpnDefault)
    private let direct = Route(name: "direct", egress: .direct)
    private let proxy = Route(name: "proxy", egress: .proxySOCKS5)
    private var routes: [Route] { [vpn, direct, proxy] }

    /// UNLIKE RouteCompiler (which claims by CIDR containment so the narrowest/most-
    /// specific range effectively wins regardless of rule order), RuleResolver is pure
    /// first-match-by-order: a broader /8 listed FIRST wins over a narrower, more
    /// specific /24 listed second, even though the /24 is contained in the /8. This
    /// documents the intentional asymmetry between the two engines.
    func testFirstMatchByOrderIgnoresCIDRSpecificity() {
        let rules = [
            Rule(matchType: .cidr, pattern: "10.0.0.0/8", routeId: direct.id, order: 0),
            Rule(matchType: .cidr, pattern: "10.1.2.0/24", routeId: proxy.id, order: 1),
        ]
        XCTAssertEqual(RuleResolver.route(forIP: "10.1.2.99", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id,
                        "first rule (the broader /8) wins by order, ignoring that the /24 is more specific")
    }

    /// A /0 CIDR rule is a valid (if unusual) catch-all at the resolver level: it
    /// matches literally any IPv4 address.
    func testRouteForIPWithSlashZeroCIDRRuleMatchesAnyIP() {
        let rules = [Rule(matchType: .cidr, pattern: "0.0.0.0/0", routeId: proxy.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forIP: "8.8.8.8", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, proxy.id)
        XCTAssertEqual(RuleResolver.route(forIP: "255.255.255.255", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, proxy.id)
    }

    /// The network address and the broadcast address of a /24 are both inside it; the
    /// address just past the broadcast address (the next network) is not.
    func testBoundaryAddressesOfSlash24NetworkMatchCorrectly() {
        let rules = [Rule(matchType: .cidr, pattern: "10.0.1.0/24", routeId: direct.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forIP: "10.0.1.0", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id,
                        "the network address itself is in range")
        XCTAssertEqual(RuleResolver.route(forIP: "10.0.1.255", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id,
                        "the broadcast address is in range")
        XCTAssertEqual(RuleResolver.route(forIP: "10.0.2.0", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id,
                        "the next network's address falls through to the default")
    }

    /// A non-IPv4 `ip` argument (e.g. an IPv6 literal) against a `.cidr` rule never
    /// matches — ipv4ToUInt32 fails to parse it — so resolution falls through to the
    /// default route rather than crashing or false-matching.
    func testNonIPv4InputToRouteForIPFallsBackToDefault() {
        let rules = [Rule(matchType: .cidr, pattern: "0.0.0.0/0", routeId: proxy.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forIP: "::1", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id,
                        "an IPv6 literal never matches an IPv4 CIDR, even 0.0.0.0/0")
    }

    /// `.ip` rules compare by PLAIN STRING equality (not IP-family-aware parsing), so
    /// they can match a non-IPv4 literal verbatim — unlike `.cidr`, which requires
    /// valid IPv4 on both sides.
    func testIPRuleMatchesByExactStringEvenForNonIPv4Literals() {
        let rules = [Rule(matchType: .ip, pattern: "::1", routeId: proxy.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forIP: "::1", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, proxy.id)
        XCTAssertEqual(RuleResolver.route(forIP: "::2", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id)
    }

    /// A single-label suffix (e.g. "com") matches ANY domain under that TLD, not just
    /// a specific registered domain — a broad but intentional consequence of the plain
    /// dot-boundary suffix rule.
    func testSuffixSingleLabelMatchesAnySubdomainUnderThatTLD() {
        let rules = [Rule(matchType: .suffix, pattern: "com", routeId: direct.id, order: 0)]
        XCTAssertEqual(RuleResolver.route(forDomain: "example.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "sub.example.com", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, direct.id)
        XCTAssertEqual(RuleResolver.route(forDomain: "example.org", rules: rules, routes: routes, defaultRouteId: vpn.id)?.id, vpn.id,
                        "a different TLD must not match")
    }
}
