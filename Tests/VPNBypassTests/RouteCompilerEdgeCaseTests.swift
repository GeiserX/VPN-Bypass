// RouteCompilerEdgeCaseTests.swift
// Additional edge-case coverage for RouteCompiler, layered on top of
// RouteCompilerTests.swift: deeper CIDR-containment interleaving, IPv6-CIDR-notation
// fallback, the GlobalProtect catch-all guard combined across multiple destinations
// in one compile, and the parseIPv4 validation boundaries (octet count/range, prefix
// bounds) that make malformed destinations fall back to exact-string claiming.

import XCTest
@testable import VPNBypassCore

final class RouteCompilerEdgeCaseTests: XCTestCase {

    private let direct = Route(name: "direct", egress: .direct)
    private let direct2 = Route(name: "direct2", egress: .direct)
    private let vpn = Route(name: "vpn", egress: .vpnDefault)

    private let noIface: (Route) -> String? = { _ in nil }

    /// Build one resolved rule (rule + its already-resolved destinations) — mirrors
    /// RouteCompilerTests's local `rr` helper.
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

    // MARK: - Deep CIDR-containment interleaving

    /// Several overlapping CIDRs at DIFFERENT prefix lengths interleaved with plain
    /// hosts, in one compile: an earlier /8 suppresses both a later contained HOST and
    /// a later contained /16 (network claims work the same as host claims); an
    /// unrelated range elsewhere is untouched; and a later BROADER CIDR over a
    /// previously-claimed host still emits (kernel LPM carves the host out of it).
    func testMultipleOverlappingCIDRsAtDifferentPrefixLengthsInterleavedWithHosts() {
        let out = RouteCompiler.compile(
            resolvedRules: [
                rr(direct, [("10.0.0.0/8", true)], pattern: "r0", matchType: .cidr, order: 0),
                rr(vpn, [("10.1.2.3", false)], pattern: "r1", order: 1),                       // contained in /8 → suppressed
                rr(direct2, [("10.1.0.0/16", true)], pattern: "r2", matchType: .cidr, order: 2), // also contained → suppressed
                rr(direct, [("172.16.5.5", false)], pattern: "r3", order: 3),                  // unrelated → emits
                rr(vpn, [("172.16.0.0/12", true)], pattern: "r4", matchType: .cidr, order: 4),  // broader than r3's host → still emits
            ],
            routes: [direct, direct2, vpn], localGateway: "gw", ifaceGatewayForRoute: { _ in "iface:utun7" }
        )
        XCTAssertEqual(out.count, 3, "only the /8, the unrelated host, and the broader /12 emit")
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "10.0.0.0/8", gateway: "gw", isNetwork: true, source: "r0")))
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "172.16.5.5", gateway: "gw", isNetwork: false, source: "r3")))
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "172.16.0.0/12", gateway: "iface:utun7", isNetwork: true, source: "r4")))
        XCTAssertFalse(out.contains { $0.destination == "10.1.2.3" }, "host contained in the earlier /8 must be suppressed")
        XCTAssertFalse(out.contains { $0.destination == "10.1.0.0/16" }, "network contained in the earlier /8 must be suppressed too")
    }

    // MARK: - IPv6 CIDR notation also falls back to exact-string claiming

    /// An IPv6 CIDR-shaped destination ("prefix/len") is NOT IPv4 (its address part
    /// isn't 4 dotted octets), so parseIPv4 must return nil and claiming falls back to
    /// exact-string — distinct from the bare-IPv6-literal case already covered.
    func testIPv6CIDRNotationFallsBackToExactStringClaiming() {
        let out = RouteCompiler.compile(
            resolvedRules: [
                rr(direct, [("2606:4700::/32", true)], pattern: "a", matchType: .cidr, order: 0),
                rr(vpn, [("2606:4700::/32", true)], pattern: "b", matchType: .cidr, order: 1),      // exact dup ⇒ suppressed
                rr(direct, [("2001:db8::/32", true)], pattern: "c", matchType: .cidr, order: 2),    // distinct ⇒ emits
            ],
            routes: [direct, vpn], localGateway: "gw", ifaceGatewayForRoute: { _ in "iface:utun3" }
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "2606:4700::/32", gateway: "gw", isNetwork: true, source: "a")))
        XCTAssertTrue(out.contains(RouteCompiler.DesiredRoute(destination: "2001:db8::/32", gateway: "gw", isNetwork: true, source: "c")))
    }

    // MARK: - GlobalProtect catch-all guard, more thoroughly

    /// A /2 is broad but NOT a catch-all (isCatchAll requires prefix <= 1); routed
    /// through the FULL compile → guard pipeline (not just isCatchAll directly) it
    /// must be kept even while GlobalProtect is active.
    func testBroadButNonCatchAllSlash2CIDRIsKeptUnderGlobalProtect() {
        let compiled = RouteCompiler.compile(
            resolvedRules: [rr(direct, [("64.0.0.0/2", true)], pattern: "64.0.0.0/2", matchType: .cidr)],
            routes: [direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        XCTAssertEqual(compiled.count, 1)
        let g = RouteCompiler.guardCatchAllUnderGlobalProtect(compiled, isGlobalProtect: true)
        XCTAssertEqual(g.kept.count, 1, "a /2 is additive under LPM, not a teardown vector — GP must not refuse it")
        XCTAssertTrue(g.refused.isEmpty)
    }

    /// The canonical catch-all trio (0.0.0.0/0 + both halves) compiled TOGETHER into
    /// non-primary egresses is refused IN FULL under GlobalProtect — none partially slip
    /// through because another destination in the same batch was safe. The two halves
    /// are listed BEFORE the full /0 (broadest last) so CIDR-containment claiming does
    /// not itself suppress one as "contained in an earlier claim" before the guard ever
    /// runs — each must reach the guard and be refused on its own merits.
    func testAllThreeCatchAllFormsTogetherAreAllRefusedUnderGlobalProtect() {
        let compiled = RouteCompiler.compile(
            resolvedRules: [
                rr(direct, [("0.0.0.0/1", true)], pattern: "lowerHalf", matchType: .cidr, order: 0),
                rr(vpn, [("128.0.0.0/1", true)], pattern: "upperHalf", matchType: .cidr, order: 1),
                rr(direct, [("0.0.0.0/0", true)], pattern: "full", matchType: .cidr, order: 2),
            ],
            routes: [direct, vpn], localGateway: "gw", ifaceGatewayForRoute: { _ in "iface:utun4" }
        )
        XCTAssertEqual(compiled.count, 3, "the compiler itself emits all three; the GP guard is what refuses them")
        let g = RouteCompiler.guardCatchAllUnderGlobalProtect(compiled, isGlobalProtect: true)
        XCTAssertTrue(g.kept.isEmpty, "all three catch-all forms must be refused together")
        XCTAssertEqual(Set(g.refused.map(\.destination)), ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1"])
    }

    // MARK: - A disabled route interacting with the GP guard

    /// A disabled route's CIDR rule is inert (no claim, no emission) even when its
    /// pattern LOOKS like a catch-all — and does not interfere with a later ENABLED
    /// catch-all rule still being correctly refused by the GP guard.
    func testDisabledRouteCIDRRuleInertDoesNotBlockLaterEnabledCatchAllGuard() {
        var disabledDirect = Route(name: "off", egress: .direct)
        disabledDirect.enabled = false
        let compiled = RouteCompiler.compile(
            resolvedRules: [
                rr(disabledDirect, [("0.0.0.0/0", true)], pattern: "disabled-catchall", matchType: .cidr, order: 0),
                rr(direct, [("0.0.0.0/0", true)], pattern: "enabled-catchall", matchType: .cidr, order: 1),
            ],
            routes: [disabledDirect, direct], localGateway: "gw", ifaceGatewayForRoute: noIface
        )
        // The disabled route emits/claims nothing, so the enabled rule at order 1 is
        // the one that actually claims + emits 0.0.0.0/0.
        XCTAssertEqual(compiled.count, 1)
        XCTAssertEqual(compiled.first?.source, "enabled-catchall")
        let g = RouteCompiler.guardCatchAllUnderGlobalProtect(compiled, isGlobalProtect: true)
        XCTAssertTrue(g.kept.isEmpty, "the enabled catch-all must still be refused under GP")
        XCTAssertEqual(g.refused.map(\.destination), ["0.0.0.0/0"])
    }

    // MARK: - parseIPv4 validation boundaries (malformed → exact-string fallback)

    /// Destinations with the wrong OCTET COUNT (empty, too few, too many) are not
    /// parseable as IPv4 and must fall back to exact-string claiming without crashing.
    func testMalformedOctetCountFallsBackToExactStringClaiming() {
        for malformed in ["", "1.2.3", "1.2.3.4.5"] {
            let out = RouteCompiler.compile(
                resolvedRules: [
                    rr(direct, [(malformed, false)], pattern: "a", order: 0),
                    rr(vpn, [(malformed, false)], pattern: "b", order: 1),   // exact dup ⇒ suppressed
                ],
                routes: [direct, vpn], localGateway: "gw", ifaceGatewayForRoute: { _ in "iface:utun5" }
            )
            XCTAssertEqual(out, [RouteCompiler.DesiredRoute(destination: malformed, gateway: "gw", isNetwork: false, source: "a")],
                            "malformed destination '\(malformed)' should exact-string-claim without crashing")
        }
    }

    /// An out-of-range OCTET VALUE (>255) and an out-of-range / non-numeric CIDR
    /// PREFIX (>32, negative, non-numeric) both fail IPv4 parsing and fall back to
    /// exact-string claiming.
    func testMalformedCIDRPrefixFallsBackToExactStringClaiming() {
        for malformed in ["1.2.3.999", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/abc"] {
            let out = RouteCompiler.compile(
                resolvedRules: [rr(direct, [(malformed, true)], pattern: "only", matchType: .cidr, order: 0)],
                routes: [direct], localGateway: "gw", ifaceGatewayForRoute: noIface
            )
            XCTAssertEqual(out, [RouteCompiler.DesiredRoute(destination: malformed, gateway: "gw", isNetwork: true, source: "only")],
                            "malformed CIDR '\(malformed)' should still exact-string-claim and emit once, no crash")
        }
    }
}
