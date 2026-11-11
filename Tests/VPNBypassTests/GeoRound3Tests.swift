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

/// A Country rule that routes nothing takes no part of the Country total.
@MainActor
final class GeoCountryTotalInertRouteTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: RouteManager.Config!

    override func setUp() async throws { saved = rm.config }

    override func tearDown() async throws {
        rm.config = saved
        try? FileManager.default.removeItem(at: GeoDataFile.geoip.url)
        GeoDataFile.geoip.invalidate()
    }

    func testACountryOnARouteThatIsOffOrGoneCountsNothing() throws {
        let codes = ["aa", "bb", "cc", "dd", "ee"]
        let entries = codes.enumerated().map { index, code in
            Dat.entry(code.uppercased(), (0..<40_000).map { Dat.cidr([UInt8(20 + index), UInt8($0 >> 8), UInt8($0 & 0xFF), 1], 32) })
        }
        try FileManager.default.createDirectory(at: GeoDataFile.geoip.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Dat.file(entries).write(to: GeoDataFile.geoip.url)
        GeoDataFile.geoip.invalidate()

        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        let direct = Route(name: "Direct", egress: .direct)
        let off = Route(name: "Off", egress: .direct, enabled: false)
        c.routes = [direct, off]
        c.defaultRouteId = direct.id
        c.rules = [Rule(matchType: .geoip, pattern: "aa", routeId: off.id, order: 0),
                   Rule(matchType: .geoip, pattern: "bb", routeId: UUID(), order: 1),   // its route is gone
                   Rule(matchType: .geoip, pattern: "cc", routeId: direct.id, order: 2),
                   Rule(matchType: .geoip, pattern: "dd", routeId: direct.id, order: 3),
                   Rule(matchType: .geoip, pattern: "ee", routeId: direct.id, order: 4)]
        rm.config = c

        XCTAssertEqual(Set(rm.geoipRanges().keys), ["cc", "dd"], "a rule that routes nothing took part of the total")
        let notes = GeoDisplay.refusalNotes(config: c, wildcards: [:])
        XCTAssertNil(notes[c.rules[2].id])
        XCTAssertNil(notes[c.rules[3].id], "the row says left out, for a rule that routes nothing")
        XCTAssertEqual(notes[c.rules[4].id], GeoDisplay.countryRefusal(count: 40_000), "the third live country is still refused")
    }
}

/// The 64 excluded names a wildcard may carry count each name once.
final class ExcludedNamesCountedOnceTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)

    private func custom(_ rules: [Rule]) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [direct, block]
        c.defaultRouteId = direct.id
        c.rules = rules
        return c
    }

    /// On Block an exact name claims the name and everything under it: one exclusion, not two.
    func testBlockedNamesUnderALaterWildcardCountOnce() {
        let names = (0..<33).map { Rule(matchType: .domain, pattern: "x\($0).example.com", routeId: block.id, order: $0) }
        let later = Rule(matchType: .suffix, pattern: "example.com", routeId: direct.id, order: 33)
        let selection = WildcardPlanner.selection(custom(names + [later]))
        let item = selection.items.first { $0.suffix == "example.com" }
        XCTAssertNotNil(item, "the wildcard was left out for too many excluded names")
        XCTAssertNil(selection.refused[later.id])
        XCTAssertEqual(Set(item?.excluded ?? []), Set((0..<33).map { "*.x\($0).example.com" }), "an earlier claim is no longer excluded")
    }

    /// Names under an earlier wildcard add nothing to what that wildcard excludes.
    func testNamesUnderAnEarlierWildcardCountOnce() {
        let wildcard = Rule(matchType: .suffix, pattern: "a.example.com", routeId: direct.id, order: 0)
        let names = (0..<64).map { Rule(matchType: .domain, pattern: "n\($0).a.example.com", routeId: direct.id, order: $0 + 1) }
        let later = Rule(matchType: .suffix, pattern: "example.com", routeId: block.id, order: 65)
        let selection = WildcardPlanner.selection(custom([wildcard] + names + [later]))
        let item = selection.items.first { $0.suffix == "example.com" }
        XCTAssertEqual(item?.excluded, ["*.a.example.com"])
        XCTAssertNil(selection.refused[later.id])
    }

    /// Positive control: 65 names no wildcard covers are still too many.
    func testSixtyFiveSeparateNamesAreStillTooMany() {
        let names = (0..<65).map { Rule(matchType: .domain, pattern: "n\($0).example.com", routeId: direct.id, order: $0) }
        let later = Rule(matchType: .suffix, pattern: "example.com", routeId: block.id, order: 65)
        let selection = WildcardPlanner.selection(custom(names + [later]))
        XCTAssertFalse(selection.items.contains { $0.suffix == "example.com" })
        XCTAssertEqual(selection.refused[later.id], .tooManyExcluded(wildcards: 1))
    }
}
