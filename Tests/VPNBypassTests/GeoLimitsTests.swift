// GeoLimitsTests.swift
// The limits of the GeoIP, GeoSite and Block work at their edges: the wildcard total the helper takes,
// the claims of a rule left out, a wildcard with too many names under it, the ranges a country list
// leaves out, and the total of all Country rules. These use only what the planner and the list reader
// had before, so each one also runs against the code it fixes.

import XCTest
@testable import VPNBypassCore

final class WildcardLimitTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)
    private let env = WildcardPlanner.Environment(localGateway: "192.0.2.1", physicalInterface: "en0",
                                                  physicalDNS: ["192.0.2.53"], vpnGateway: nil,
                                                  vpnInterface: nil, vpnDNS: [])

    private func custom(_ rules: [Rule]) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [direct, block]
        c.defaultRouteId = direct.id
        c.rules = rules
        return c
    }

    /// The helper refuses a list of more than `WildcardSpec.maxSpecs` wildcards whole, which would stop
    /// every wildcard, Block ones included. The user's own wildcards count first; a list that no longer
    /// fits is left out.
    func testTheUsersOwnWildcardsAndTheListsTogetherStayUnderWhatTheHelperTakes() {
        let list = GeoSiteExpansion(suffixes: (0..<10_000).map { "l\($0).example.net" })
        var rules = [Rule(matchType: .geosite, pattern: "big", routeId: direct.id, order: 0)]
        rules += (0..<3_000).map { Rule(matchType: .suffix, pattern: "u\($0).example.org", routeId: block.id, order: $0 + 1) }
        let items = WildcardPlanner.configured(custom(rules), geosite: ["big": list])
        XCTAssertLessThanOrEqual(items.count, WildcardSpec.maxSpecs, "more than the helper takes")
        let suffixes = Set(items.map(\.suffix))
        XCTAssertTrue(suffixes.isSuperset(of: (0..<3_000).map { "u\($0).example.org" }), "the user's own rules are kept")
        XCTAssertFalse(suffixes.contains("l0.example.net"), "the list that no longer fits is left out whole")
    }

    /// The Bypass and VPN Only lists have no rules to leave out: past the helper's limit the extra
    /// wildcards are left out, and the log says so, instead of the helper refusing them all.
    func testADomainsListPastTheHelpersLimitIsCut() {
        var c = RouteManager.Config()
        c.routingMode = .bypass
        c.domains = (0..<(WildcardSpec.maxSpecs + 500)).map { DomainEntry(domain: "*.d\($0).example.com") }
        c.services = []
        let plan = WildcardPlanner.plan(c, env: env)
        XCTAssertEqual(plan.specs.count, WildcardSpec.maxSpecs)
        XCTAssertNotNil(plan.skipped["d\(WildcardSpec.maxSpecs).example.com"], "the log says which one is left out")
    }

    /// A list left out by the total serves nothing, so it claims nothing: a later rule keeps its
    /// wildcard and excludes no name of the list.
    func testAListLeftOutByTheTotalClaimsNothing() {
        let first = GeoSiteExpansion(suffixes: (0..<6_000).map { "a\($0).example.net" })
        let second = GeoSiteExpansion(suffixes: (0..<6_000).map { "b\($0).example.org" }, names: ["n.c.example.com"])
        let rules = [Rule(matchType: .geosite, pattern: "first", routeId: direct.id, order: 0),
                     Rule(matchType: .geosite, pattern: "second", routeId: direct.id, order: 1),
                     Rule(matchType: .suffix, pattern: "x.b1.example.org", routeId: block.id, order: 2),
                     Rule(matchType: .suffix, pattern: "c.example.com", routeId: block.id, order: 3)]
        let items = WildcardPlanner.configured(custom(rules), geosite: ["first": first, "second": second])
        XCTAssertFalse(items.contains { $0.suffix == "b0.example.org" }, "the second list is left out")
        XCTAssertTrue(items.contains { $0.suffix == "x.b1.example.org" }, "a refused list took the later rule's wildcard")
        XCTAssertEqual(items.first { $0.suffix == "c.example.com" }?.excluded, [], "a refused list's name is excluded")
    }

    /// A wildcard with more names under it than the helper excludes is left out, on Block as on
    /// Direct, and the log says so.
    func testAWildcardWithTooManyEarlierNamesUnderItIsReported() {
        for route in [block, direct] {
            var rules = (0...WildcardSpec.maxExcluded).map {
                Rule(matchType: .domain, pattern: "n\($0).ads.example.com", routeId: direct.id, order: $0)
            }
            rules.append(Rule(matchType: .suffix, pattern: "ads.example.com", routeId: route.id, order: 1_000))
            let plan = WildcardPlanner.plan(custom(rules), env: env)
            XCTAssertFalse(plan.specs.contains { $0.suffix == "ads.example.com" })
            XCTAssertNotNil(plan.skipped["ads.example.com"], "\(route.name): the wildcard is left out without a word")
        }
    }
}

/// The ranges a Country rule's row counts are the ranges it routes.
final class GeoRangeCountTests: XCTestCase {

    func testARowCountsOnlyTheRangesThatAreRouted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("geo-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = GeoDataFile(kind: .ip, directory: directory)
        try Dat.file([Dat.entry("IR", [Dat.cidr([203, 0, 113, 0], 24), Dat.cidr([10, 202, 10, 10], 32)])]).write(to: file.url)
        let ranges = file.ranges(for: ["ir"])
        let direct = Route(name: "Direct", egress: .direct)
        let routed = RuleDestinationBuilder.build(rules: [Rule(matchType: .geoip, pattern: "ir", routeId: direct.id, order: 0)],
                                                  services: [], resolved: [:], geoip: ranges)
        XCTAssertEqual(ranges["ir"]?.count, routed.first?.dests.count, "the row counts a range that is not routed")
    }
}

/// All Country rules together stay under one total of kernel routes.
@MainActor
final class GeoCountryTotalTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: RouteManager.Config!

    override func setUp() async throws {
        saved = rm.config
    }

    override func tearDown() async throws {
        rm.config = saved
        try? FileManager.default.removeItem(at: GeoDataFile.geoip.url)
        GeoDataFile.geoip.invalidate()
    }

    func testCountriesTogetherStayUnderOneTotal() throws {
        // Three countries of 40,000 ranges each: each is under its own limit, all three are not.
        let codes = ["aa", "bb", "cc"]
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
        c.routes = [direct]
        c.defaultRouteId = direct.id
        c.rules = codes.enumerated().map { Rule(matchType: .geoip, pattern: $0.element, routeId: direct.id, order: $0.offset) }
        rm.config = c

        let ranges = rm.geoipRanges()
        XCTAssertEqual(ranges.count, 2, "every country was taken")
        XCTAssertLessThanOrEqual(ranges.values.map(\.count).reduce(0, +), 100_000)
        XCTAssertFalse(ranges.keys.contains("cc"), "the last country in rule order is the one left out")
    }
}
