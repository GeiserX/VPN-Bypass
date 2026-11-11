// GeoRound3Tests.swift
// First match against a Block range, the Country total and inert routes, the excluded-name limit
// counted once per name, the checksum address of a custom source, and the Block route the user made.

import XCTest
@testable import VPNBypassCore

/// An earlier rule keeps its address when a later Block rule names a range around it.
final class BlockRangeFirstMatchTests: XCTestCase {

    private let block = Route(name: Route.blockName, egress: .block)

    /// Whether `address` (the last octet under 203.0.113.0/24) falls in one of `blocks`.
    private func blocked(_ last: UInt32, by blocks: [RouteCompiler.DesiredBlock]) -> Bool {
        let address = (203 << 24) | (0 << 16) | (113 << 8) | last
        return blocks.contains { block in
            let parts = block.destination.split(separator: "/")
            let prefix = parts.count == 2 ? Int(parts[1])! : 32
            let octets = parts[0].split(separator: ".").map { UInt32($0)! }
            let network = octets.reduce(UInt32(0)) { $0 << 8 | $1 }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
            return address & mask == network & mask
        }
    }

    private func compile(earlier route: Route, gateway: String? = nil)
        -> (routes: [RouteCompiler.DesiredRoute], blocks: [RouteCompiler.DesiredBlock]) {
        let host = Rule(matchType: .ip, pattern: "203.0.113.7", routeId: route.id, order: 0)
        let range = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: block.id, order: 1)
        return RouteCompiler.compileAll(
            resolvedRules: [(host, [("203.0.113.7", false)]), (range, [("203.0.113.0/24", true)])],
            routes: [route, block], localGateway: "192.0.2.1",
            ifaceGatewayForRoute: { _ in gateway })
    }

    func testAnAddressTheEarlierRuleSendsToThePrimaryVPNIsNotBlocked() {
        let compiled = compile(earlier: Route(name: "VPN", egress: .vpnDefault))
        XCTAssertTrue(compiled.routes.isEmpty, "the primary VPN needs no route")
        XCTAssertFalse(blocked(7, by: compiled.blocks), "the later Block range took the earlier rule's address")
        for last in UInt32(0)...255 where last != 7 {
            XCTAssertTrue(blocked(last, by: compiled.blocks), "203.0.113.\(last) is no longer blocked")
        }
        XCTAssertTrue(compiled.blocks.allSatisfy { $0.source == "203.0.113.0/24" })
    }

    func testAnAddressTheEarlierRuleSendsToAProxyIsNotBlocked() {
        let compiled = compile(earlier: Route(name: "Proxy", egress: .proxySOCKS5))
        XCTAssertFalse(blocked(7, by: compiled.blocks))
        XCTAssertTrue(blocked(6, by: compiled.blocks))
    }

    /// A Direct or pinned-tunnel route is narrower than the block, so the kernel picks it: the block
    /// stays one range.
    func testAnEarlierRouteOfItsOwnLeavesTheBlockWhole() {
        let direct = compile(earlier: Route(name: "Direct", egress: .direct))
        XCTAssertEqual(direct.routes.map(\.destination), ["203.0.113.7"])
        XCTAssertEqual(direct.blocks.map(\.destination), ["203.0.113.0/24"])
        let pinned = compile(earlier: Route(name: "Work", egress: .vpnDefault), gateway: "iface:utun5")
        XCTAssertEqual(pinned.routes.map(\.gateway), ["iface:utun5"])
        XCTAssertEqual(pinned.blocks.map(\.destination), ["203.0.113.0/24"])
    }

    /// A range a LATER rule sends to the primary VPN changes nothing: the earlier block holds.
    func testALaterBroaderRuleDoesNotUnblockAnEarlierAddress() {
        let vpn = Route(name: "VPN", egress: .vpnDefault)
        let host = Rule(matchType: .ip, pattern: "203.0.113.7", routeId: block.id, order: 0)
        let range = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: vpn.id, order: 1)
        let compiled = RouteCompiler.compileAll(
            resolvedRules: [(host, [("203.0.113.7", false)]), (range, [("203.0.113.0/24", true)])],
            routes: [vpn, block], localGateway: "192.0.2.1", ifaceGatewayForRoute: { _ in nil })
        XCTAssertEqual(compiled.blocks.map(\.destination), ["203.0.113.7"])
    }
}
