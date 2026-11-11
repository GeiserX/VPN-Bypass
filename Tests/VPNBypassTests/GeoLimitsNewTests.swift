// GeoLimitsNewTests.swift
// What the rows and the log say about a rule the limits leave out (GeoLimitsTests holds the limits
// themselves), and a measurement of the Country total against the real list.

import XCTest
@testable import VPNBypassCore

final class RuleRefusalTests: XCTestCase {

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

    func testAListLeftOutForTheUsersOwnWildcardsSaysSo() {
        let list = GeoSiteExpansion(suffixes: (0..<10_000).map { "l\($0).example.net" })
        let listRule = Rule(matchType: .geosite, pattern: "big", routeId: direct.id, order: 0)
        let own = (0..<3_000).map { Rule(matchType: .suffix, pattern: "u\($0).example.org", routeId: direct.id, order: $0 + 1) }
        let selection = WildcardPlanner.selection(custom([listRule] + own), geosite: ["big": list])
        XCTAssertEqual(selection.refused, [listRule.id: .overTotal(wildcards: 10_000, limit: WildcardSpec.maxSpecs - 3_000)])
    }

    /// Two lists of 6,000 each: the second is left out, and its row says that instead of "6,000 domains".
    func testTheRowOfAListLeftOutByTheTotalSaysWhy() {
        let first = Rule(matchType: .geosite, pattern: "first", routeId: direct.id, order: 0)
        let second = Rule(matchType: .geosite, pattern: "second", routeId: direct.id, order: 1)
        let config = custom([first, second])
        let selection = WildcardPlanner.selection(config, geosite: [
            "first": GeoSiteExpansion(suffixes: (0..<6_000).map { "a\($0).example.net" }),
            "second": GeoSiteExpansion(suffixes: (0..<6_000).map { "b\($0).example.org" }),
        ])
        let notes = GeoDisplay.refusalNotes(config: config, wildcards: selection.refused)
        XCTAssertNil(notes[first.id])
        XCTAssertEqual(notes[second.id], String(localized:
            "Left out: all rules together would pass the limit of \(WildcardPlanner.maxListWildcards) wildcards (this one adds \(6_000))."))
    }

    func testABlockWildcardWithTooManyEarlierNamesSaysSoOnItsRow() {
        var rules = (0...WildcardSpec.maxExcluded).map {
            Rule(matchType: .domain, pattern: "n\($0).ads.example.com", routeId: direct.id, order: $0)
        }
        let blocked = Rule(matchType: .suffix, pattern: "ads.example.com", routeId: block.id, order: 1_000)
        rules.append(blocked)
        let selection = WildcardPlanner.selection(custom(rules))
        XCTAssertEqual(selection.refused, [blocked.id: .tooManyExcluded(wildcards: 1)])
        XCTAssertEqual(GeoDisplay.refusal(.tooManyExcluded(wildcards: 1)),
                       String(localized: "Wildcards left out: \(1). Earlier rules take more than \(WildcardSpec.maxExcluded) names under each."))
    }

    /// The user's own rules past the helper's limit: the rule that no longer fits is left out whole,
    /// and its row says so, instead of a part of it being cut.
    func testTheUsersOwnRulesPastTheHelpersLimitAreLeftOutWhole() {
        let rules = (0...WildcardSpec.maxSpecs).map {
            Rule(matchType: .suffix, pattern: "u\($0).example.org", routeId: direct.id, order: $0)
        }
        let selection = WildcardPlanner.selection(custom(rules))
        XCTAssertEqual(selection.items.count, WildcardSpec.maxSpecs)
        XCTAssertEqual(selection.refused, [rules[WildcardSpec.maxSpecs].id: .overTotal(wildcards: 1, limit: WildcardSpec.maxSpecs)])
    }

    func testCountriesCountInRuleOrderUnderTheTotal() {
        let rules = ["gb", "fr", "de", "gb"].enumerated().map {
            Rule(matchType: .geoip, pattern: $0.element, routeId: direct.id, order: $0.offset)
        }
        let picked = GeoIPBudget.select(rules: rules, routes: [direct], counts: ["gb": 36_445, "fr": 33_770, "de": 30_196])
        XCTAssertEqual(picked.accepted, ["gb", "fr"], "a country two rules name counts once")
        XCTAssertEqual(picked.refused, ["de": 30_196])
        XCTAssertGreaterThanOrEqual(GeoDataFile.maxRangesTotal, GeoDataFile.maxRangesPerCountry)
        XCTAssertEqual(GeoDisplay.countryRefusal(count: 30_196), String(localized:
            "Left out: all Country rules together would pass the limit of \(GeoDataFile.maxRangesTotal) ranges (this one adds \(30_196))."))
    }

    func testACountryRowSaysHowManyRangesAreLeftOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("geo-leftout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = GeoDataFile(kind: .ip, directory: directory)
        try Dat.file([Dat.entry("IR", [Dat.cidr([203, 0, 113, 0], 24), Dat.cidr([10, 202, 10, 10], 32)])]).write(to: file.url)
        XCTAssertEqual(file.ranges(for: ["ir"])["ir"], ["203.0.113.0/24"])
        XCTAssertEqual(file.leftOut(for: "ir"), 1)
        XCTAssertEqual(GeoDisplay.detail(count: 1, hasData: true, leftOut: 1), String(localized: "\(1) ranges, \(1) left out"))
        XCTAssertEqual(GeoDisplay.detail(count: 1, hasData: true), String(localized: "1 range"))
    }
}

/// A Site list the wildcard total leaves out routes none of its exact names either: never a part of a list.
@MainActor
final class RefusedListNamesTests: XCTestCase {
    private var rm: RouteManager { RouteManager.shared }
    private var saved: RouteManager.Config!

    override func setUp() async throws { saved = rm.config }
    override func tearDown() async throws {
        rm.config = saved
        try? FileManager.default.removeItem(at: GeoDataFile.geosite.url)
        GeoDataFile.geosite.invalidate()
    }

    func testAListLeftOutByTheTotalRoutesNoneOfItsNames() throws {
        let first = Dat.site("FIRST", (0..<6_000).map { Dat.domain(2, "a\($0).example.net") })
        let second = Dat.site("SECOND", (0..<6_000).map { Dat.domain(2, "b\($0).example.org") } + [Dat.domain(3, "www.example.com")])
        try FileManager.default.createDirectory(at: GeoDataFile.geosite.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Dat.file([first, second]).write(to: GeoDataFile.geosite.url)
        GeoDataFile.geosite.invalidate()

        let direct = Route(name: "Direct", egress: .direct)
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [direct]
        c.defaultRouteId = direct.id
        let r1 = Rule(matchType: .geosite, pattern: "first", routeId: direct.id, order: 0)
        let r2 = Rule(matchType: .geosite, pattern: "second", routeId: direct.id, order: 1)
        c.rules = [r1, r2]
        rm.config = c

        let selection = WildcardPlanner.selection(c)
        XCTAssertNotNil(selection.refused[r2.id], "precondition: the second list is left out by the total")
        let hosts = RuleDestinationBuilder.hostsToResolve(rules: c.rules, services: [], geosite: rm.geositeExpansions(), routes: c.routes)
        XCTAssertFalse(hosts.contains("www.example.com"), "a list left out whole still routes its exact names")

        // Alone, the same list fits, and its name is routed.
        c.rules = [Rule(matchType: .geosite, pattern: "second", routeId: direct.id, order: 0)]
        rm.config = c
        let alone = RuleDestinationBuilder.hostsToResolve(rules: c.rules, services: [], geosite: rm.geositeExpansions(), routes: c.routes)
        XCTAssertTrue(alone.contains("www.example.com"))
    }
}

/// The engine's pass publishes the refusals the rows read, and logs each once.
@MainActor
final class WildcardRefusalEngineTests: XCTestCase {

    func testTheEnginePublishesWhatItLeavesOut() async {
        let rm = RouteManager.shared
        let saved = rm.config
        defer { rm.config = saved }
        let direct = Route(name: "Direct", egress: .direct)
        let block = Route(name: Route.blockName, egress: .block)
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [direct, block]
        c.defaultRouteId = direct.id
        c.rules = (0...WildcardSpec.maxExcluded).map {
            Rule(matchType: .domain, pattern: "n\($0).ads.example.com", routeId: direct.id, order: $0)
        }
        let blocked = Rule(matchType: .suffix, pattern: "ads.example.com", routeId: block.id, order: 1_000)
        c.rules.append(blocked)
        rm.config = c
        await rm.wildcards.syncForTests()
        XCTAssertEqual(rm.wildcardRefusals, [blocked.id: .tooManyExcluded(wildcards: 1)])
        XCTAssertTrue(rm.recentLogs.contains { $0.message.contains("ads.example.com") && $0.message.contains("left out") })

        rm.config = saved
        await rm.wildcards.syncForTests()
        XCTAssertNil(rm.wildcardRefusals[blocked.id], "the refusal goes with its rule")
    }
}

/// Reads the real list when `VPNB_GEOIP_FILE` names one, and measures the app's side of routing the
/// largest countries together:
///
///   VPNB_GEOIP_FILE=/path/to/geoip.dat swift test --filter GeoCountryTotalRealFileTests
final class GeoCountryTotalRealFileTests: XCTestCase {
    func testTheLargestCountriesTogether() throws {
        guard let path = ProcessInfo.processInfo.environment["VPNB_GEOIP_FILE"] else {
            throw XCTSkip("Set VPNB_GEOIP_FILE to a geoip.dat to read it.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let largest = GeoIPDat.countries(in: data).filter { $0.key.count == 2 && $0.value <= GeoDataFile.maxRangesPerCountry }
            .sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let direct = Route(name: "Direct", egress: .direct)
        let rules = largest.enumerated().map { Rule(matchType: .geoip, pattern: $0.element, routeId: direct.id, order: $0.offset) }

        var start = CFAbsoluteTimeGetCurrent()
        let ranges = GeoIPDat.ranges(for: Set(largest), in: data)
        let read = CFAbsoluteTimeGetCurrent() - start
        start = CFAbsoluteTimeGetCurrent()
        let built = RuleDestinationBuilder.build(rules: rules, services: [], resolved: [:], geoip: ranges)
        let compiled = RouteCompiler.compileAll(resolvedRules: built, routes: [direct], localGateway: "192.0.2.1",
                                                ifaceGatewayForRoute: { _ in nil })
        let planned = CFAbsoluteTimeGetCurrent() - start
        let picked = GeoIPBudget.select(rules: rules, routes: [direct], counts: ranges.mapValues(\.count))
        let all = ranges.values.map(\.count).reduce(0, +)
        let kept = picked.accepted.map { ranges[$0]?.count ?? 0 }.reduce(0, +)
        print("GEOIP TOTAL \(largest) all=\(all) routes=\(compiled.routes.count) read=\(String(format: "%.2f", read)) s "
              + "build+compile=\(String(format: "%.2f", planned)) s kept=\(kept) refused=\(picked.refused)")
        XCTAssertLessThanOrEqual(kept, GeoDataFile.maxRangesTotal)
    }
}
