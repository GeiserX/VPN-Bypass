// GeoReviewNewTests.swift
// The parts of the review of the GeoIP, GeoSite and Block work that need what the review added: the
// row wording, the downloaded-range policy, the checksum and the time limit of a download, and the
// Block route that goes with its last rule.

import XCTest
@testable import VPNBypassCore

final class GeoReviewNewTests: XCTestCase {

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

    /// A list too large for wildcards on the Block route is refused whole, and its row says so.
    func testAListTooLargeForWildcardsOnBlockIsRefusedAndTheRowSaysSo() {
        let suffixes = (0..<9_000).map { "s\($0).example.net" }
        let names = (0..<1_500).map { "n\($0).example.org" }
        let list = GeoSiteExpansion(suffixes: suffixes, names: names)
        XCTAssertFalse(list.isTooLarge, "fits on Direct")
        XCTAssertTrue(WildcardPlanner.configured(custom([Rule(matchType: .geosite, pattern: "big", routeId: block.id, order: 0)]),
                                                 geosite: ["big": list]).isEmpty)
        XCTAssertEqual(GeoDisplay.siteDetail(list, hasData: true, onBlock: true),
                       String(localized: "Too large to route: \(10_500) domains, the limit is \(GeoSiteExpansion.maxSuffixes)."))
        XCTAssertEqual(GeoDisplay.siteDetail(list, hasData: true, onBlock: false), String(localized: "\(10_500) domains"))
    }

    func testThePrivateListMayNameTheMacsOwnNetworksButNotHugeRanges() {
        let rules = [Rule(matchType: .geoip, pattern: "private", routeId: direct.id, order: 0)]
        let built = RuleDestinationBuilder.build(rules: rules, services: [], resolved: [:],
                                                 geoip: ["private": ["10.0.0.0/8", "192.168.0.0/16", "0.0.0.0/2"]])
        XCTAssertEqual(built.first?.dests.map(\.value), ["10.0.0.0/8", "192.168.0.0/16"])
        XCTAssertTrue(GeoIPRangePolicy.allows("8.0.0.0/8", code: "us"))
        XCTAssertFalse(GeoIPRangePolicy.allows("8.0.0.0/7", code: "us"))
        XCTAssertFalse(GeoIPRangePolicy.allows("not a range", code: "us"))
    }

    func testACountryRowSaysOnlyIPv4IsUsed() {
        XCTAssertTrue(GeoDisplay.withIPv4Note("3 ranges").hasPrefix("3 ranges"))
        XCTAssertTrue(GeoDisplay.withIPv4Note("3 ranges").contains(String(localized: "IPv4 only; IPv6 is not routed or blocked.")))
    }

    func testTheTotalOfAllListsStaysUnderWhatTheHelperTakes() {
        XCTAssertLessThanOrEqual(WildcardPlanner.maxListWildcards, WildcardSpec.maxSpecs)
    }
}

// MARK: - Download checks

@MainActor
final class GeoDownloadCheckTests: XCTestCase {

    private var directory: URL!
    private var store: GeoDataStore!
    private let source = URL(string: "https://example.org/geoip.dat")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("geo-check-\(UUID().uuidString)")
        store = GeoDataStore(kind: .ip, directory: directory)
        store.fetch = { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Dat.sample.write(to: file)
            return file
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testADownloadThatDoesNotMatchItsPublishedChecksumIsRefused() async {
        var asked: [URL] = []
        store.fetchChecksum = { url in
            asked.append(url)
            return String(repeating: "0", count: 64) + "  geoip.dat\n"
        }
        let replaced = await store.update(from: source)
        XCTAssertFalse(replaced)
        XCTAssertFalse(store.hasData)
        XCTAssertEqual(store.phase, .failed(String(localized: "The download does not match the checksum its source publishes.")))
        XCTAssertEqual(asked.map(\.absoluteString), ["https://example.org/geoip.dat.sha256sum"])
    }

    func testADownloadThatMatchesItsChecksumOrHasNoneIsUsed() async {
        let digest = GeoChecksum.sha256(Dat.sample)
        store.fetchChecksum = { _ in "\(digest.uppercased())  release/geoip.dat\n" }
        let matched = await store.update(from: source)
        XCTAssertTrue(matched)
        store.fetchChecksum = { _ in "<html>Not Found</html>" }
        let unpublished = await store.update(from: source)
        XCTAssertTrue(unpublished, "a source that publishes no checksum is read as before")
    }

    func testAWholeDownloadHasATimeLimit() {
        XCTAssertLessThanOrEqual(GeoDownloader(limit: 1).resourceTimeout, 300)
    }
}

// MARK: - The Block route is kept only while a rule uses it

@MainActor
final class BlockRouteKeptWhileUsedTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: RouteManager.Config!

    override func setUp() async throws { saved = rm.config }

    override func tearDown() async throws {
        rm.config = saved
        rm.droppedBlockRoutes = []
    }

    /// A version before Block cannot read a config that holds a Block route, so the route the Rules
    /// page made goes when its last rule does (`saveRulesAndReapply` runs this on every rule change).
    /// Called directly: a real save would start an apply that leaks into the next test.
    func testTheBlockRouteGoesWhenNoRuleUsesIt() {
        let direct = Route(name: "Direct", egress: .direct)
        let block = Route(id: Route.rulesPageBlockId, name: Route.blockName, egress: .block)
        let blocked = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: block.id, order: 0)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.routes = [direct, block]
        cfg.defaultRouteId = direct.id
        cfg.rules = [blocked, Rule(matchType: .ip, pattern: "198.51.100.7", routeId: direct.id, order: 1)]
        rm.config = cfg
        XCTAssertFalse(rm.removeUnusedBlockRoutes(), "kept while a rule uses it")
        XCTAssertTrue(rm.config.routes.contains { $0.id == block.id })

        rm.config.rules.removeAll { $0.id == blocked.id }
        XCTAssertTrue(rm.removeUnusedBlockRoutes())
        XCTAssertFalse(rm.config.routes.contains { $0.egress == .block }, "the Block route outlived its last rule")
        XCTAssertTrue(rm.config.routes.contains { $0.id == direct.id })
    }

    /// A Block route made in Routes under its own name is the user's: a rule change or a cancelled
    /// sheet leaves it, even before a rule uses it.
    func testABlockRouteTheUserNamedStays() {
        let direct = Route(name: "Direct", egress: .direct)
        let mine = Route(name: "Block ads", egress: .block)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.routes = [direct, mine]
        cfg.defaultRouteId = direct.id
        cfg.rules = [Rule(matchType: .ip, pattern: "198.51.100.7", routeId: direct.id, order: 0)]
        rm.config = cfg
        XCTAssertFalse(rm.removeUnusedBlockRoutes())
        XCTAssertTrue(rm.config.routes.contains { $0.id == mine.id }, "a Block route the user made in Routes was deleted")
    }

    /// Undo of the delete that took the last Block rule puts the rule back on its Block route, not on
    /// a route that no longer exists (a rule whose route is gone matches nothing).
    func testUndoOfTheLastBlockRuleBringsItsRouteBack() {
        let direct = Route(name: "Direct", egress: .direct)
        let block = Route(id: Route.rulesPageBlockId, name: Route.blockName, egress: .block)
        let blocked = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: block.id, order: 0)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.routes = [direct, block]
        cfg.defaultRouteId = direct.id
        cfg.rules = [blocked]
        rm.config = cfg
        // removeRule's change to the config, without its apply.
        rm.config.rules.removeAll { $0.id == blocked.id }
        XCTAssertTrue(rm.removeUnusedBlockRoutes())
        // restoreRule's first step.
        rm.restoreDroppedBlockRoute(for: blocked)
        XCTAssertEqual(rm.config.routes.filter { $0.id == block.id }.map(\.egress), [.block],
                       "the restored Block rule points at a route that no longer exists")
        rm.restoreDroppedBlockRoute(for: blocked)
        XCTAssertEqual(rm.config.routes.filter { $0.id == block.id }.count, 1, "put back once")
    }
}
