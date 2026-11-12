// GeoIPTests.swift
// Country (GeoIP) rules: the geoip.dat reader, the expansion of a rule into routes, the store's
// download handling, the pattern checks and the wording. The geoip files here are encoded by hand
// from made-up ranges (documentation addresses), so nothing here reads the network or the real
// lists.

import XCTest
@testable import VPNBypassCore

/// Encodes the geoip.dat protobuf, to give the reader data in the format the real lists use.
enum Dat {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
    static func bytes(_ field: UInt64, _ payload: [UInt8]) -> [UInt8] {
        varint(field << 3 | 2) + varint(UInt64(payload.count)) + payload
    }
    static func number(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        varint(field << 3) + varint(value)
    }
    static func cidr(_ ip: [UInt8], _ prefix: UInt64) -> [UInt8] {
        bytes(2, bytes(1, ip) + number(2, prefix))
    }
    static func entry(_ code: String, _ cidrs: [[UInt8]], reverse: Bool = false) -> [UInt8] {
        bytes(1, bytes(1, Array(code.utf8)) + cidrs.flatMap { $0 } + (reverse ? number(3, 1) : []))
    }
    static func file(_ entries: [[UInt8]]) -> Data { Data(entries.flatMap { $0 }) }

    static let sample = file([
        entry("IR", [cidr([203, 0, 113, 0], 24), cidr([198, 51, 100, 0], 22),
                     cidr([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 32)]),   // IPv6: skipped
        entry("PRIVATE", [cidr([10, 0, 0, 0], 8), cidr([192, 168, 0, 0], 16)]),
        entry("XX", [cidr([192, 0, 2, 0], 24)], reverse: true),
    ])
}

final class GeoIPDatTests: XCTestCase {

    func testReadsTheRangesOfACountryAndLeavesIPv6Out() {
        let ranges = GeoIPDat.ranges(for: ["ir"], in: Dat.sample)
        XCTAssertEqual(ranges["ir"], ["203.0.113.0/24", "198.51.100.0/22"])
    }

    func testAnswersForSeveralCountriesAndAnyCase() {
        let ranges = GeoIPDat.ranges(for: ["ir", "private", "nowhere"], in: Dat.sample)
        XCTAssertEqual(Set(ranges.keys), ["ir", "private"], "a code the file lacks is absent, not empty")
        XCTAssertEqual(ranges["private"], ["10.0.0.0/8", "192.168.0.0/16"])
    }

    func testSkipsAReverseMatchEntry() {
        XCTAssertNil(GeoIPDat.ranges(for: ["xx"], in: Dat.sample)["xx"], "\"everything but\" cannot be a list of routes")
        XCTAssertNil(GeoIPDat.countries(in: Dat.sample)["xx"])
    }

    func testCountsTheIPv4RangesOfEveryCountry() {
        XCTAssertEqual(GeoIPDat.countries(in: Dat.sample), ["ir": 2, "private": 2])
    }

    func testTheSameCodeTwiceInTheFileAddsUp() {
        let data = Dat.file([Dat.entry("IR", [Dat.cidr([203, 0, 113, 0], 24)]),
                             Dat.entry("ir", [Dat.cidr([198, 51, 100, 0], 24)])])
        XCTAssertEqual(GeoIPDat.ranges(for: ["ir"], in: data)["ir"]?.count, 2)
    }

    func testDropsAPrefixPastThirtyTwoAndAnIPOfTheWrongLength() {
        let data = Dat.file([Dat.entry("IR", [Dat.cidr([203, 0, 113, 0], 33), Dat.cidr([1, 2, 3], 8),
                                               Dat.cidr([203, 0, 113, 0], 32)])])
        XCTAssertEqual(GeoIPDat.ranges(for: ["ir"], in: data)["ir"], ["203.0.113.0/32"])
    }

    func testReadsTheFieldsInAnyOrderAndStepsOverOnesItDoesNotKnow() {
        // The code after the ranges, and an unknown varint and fixed32 field around them.
        let body = Dat.cidr([203, 0, 113, 0], 24) + Dat.number(9, 7) + Dat.bytes(1, Array("ir".utf8))
            + [UInt8(0x35), 1, 2, 3, 4]
        let data = Data(Dat.bytes(1, body))
        XCTAssertEqual(GeoIPDat.ranges(for: ["ir"], in: data)["ir"], ["203.0.113.0/24"])
    }

    func testAFileIsUsableOnlyWithACountryAndAnIPv4Range() {
        XCTAssertTrue(GeoIPDat.isUsable(Dat.sample))
        XCTAssertFalse(GeoIPDat.isUsable(Data()))
        XCTAssertFalse(GeoIPDat.isUsable(Data("<html>Not Found</html>".utf8)), "an error page is not a list")
        XCTAssertFalse(GeoIPDat.isUsable(Dat.file([Dat.entry("IR", [])])), "a country with no ranges")
        XCTAssertFalse(GeoIPDat.isUsable(Dat.file([Dat.entry("XX", [Dat.cidr([192, 0, 2, 0], 24)], reverse: true)])))
    }

    /// A download cut short, or a hostile file, must give less and never trap.
    func testATruncatedOrCorruptFileNeverTraps() {
        let data = Dat.sample
        for length in 0..<data.count {
            let cut = data.prefix(length)
            _ = GeoIPDat.ranges(for: ["ir", "private"], in: cut)
            _ = GeoIPDat.countries(in: cut)
            _ = GeoIPDat.isUsable(cut)
        }
        // A length that claims far more than the file holds.
        let lying = Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x0A, 0x02, 0x69, 0x72])
        XCTAssertTrue(GeoIPDat.ranges(for: ["ir"], in: lying).isEmpty)
        XCTAssertFalse(GeoIPDat.isUsable(lying))
        // A varint with no end.
        XCTAssertFalse(GeoIPDat.isUsable(Data(repeating: 0xFF, count: 40)))
    }
}

final class GeoIPRuleTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)

    private func rule(_ pattern: String, order: Int = 0, enabled: Bool = true, type: MatchType = .geoip) -> Rule {
        Rule(matchType: type, pattern: pattern, routeId: direct.id, enabled: enabled, order: order)
    }

    func testAPatternIsALowerCaseListName() {
        XCTAssertEqual(GeoIPRule.normalized(" IR "), "ir")
        XCTAssertEqual(GeoIPRule.normalized("private"), "private")
        XCTAssertEqual(GeoIPRule.normalized("geolocation-!cn"), "geolocation-!cn")
        for bad in ["", "i", "i r", "ir/24", "10.0.0.0/8", "é", "a.b", String(repeating: "a", count: 41)] {
            XCTAssertNil(GeoIPRule.normalized(bad), "\(bad) is not a list name")
        }
    }

    func testARuleBecomesNetworkRoutesForItsRanges() {
        let out = RuleDestinationBuilder.build(rules: [rule("IR")], services: [], resolved: [:],
                                               geoip: ["ir": ["203.0.113.0/24", "198.51.100.0/22"]])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].dests.map(\.value), ["203.0.113.0/24", "198.51.100.0/22"])
        XCTAssertTrue(out[0].dests.allSatisfy(\.isNetwork))
    }

    func testNoListOrAMissingCountryRoutesNothing() {
        XCTAssertTrue(RuleDestinationBuilder.build(rules: [rule("ir")], services: [], resolved: [:])[0].dests.isEmpty)
        XCTAssertTrue(RuleDestinationBuilder.build(rules: [rule("ir")], services: [], resolved: [:],
                                                   geoip: ["ru": ["198.51.100.0/24"]])[0].dests.isEmpty)
    }

    /// A list that claims the whole address space must not be able to take over the routing
    /// table: the install policy that holds a CIDR rule holds each range of a country.
    func testARangeTheInstallPolicyRefusesIsLeftOut() {
        let out = RuleDestinationBuilder.build(rules: [rule("ir")], services: [], resolved: [:],
                                               geoip: ["ir": ["0.0.0.0/0", "128.0.0.0/1", "203.0.113.0/24"]])
        XCTAssertEqual(out[0].dests.map(\.value), ["203.0.113.0/24"])
    }

    func testOnlyEnabledRulesCountAndOrderIsKept() {
        let rules = [rule("ru", order: 1), rule("ir", order: 0), rule("cn", order: 2, enabled: false)]
        let out = RuleDestinationBuilder.build(rules: rules, services: [], resolved: [:],
                                               geoip: ["ir": ["203.0.113.0/24"], "ru": ["198.51.100.0/24"], "cn": ["192.0.2.0/24"]])
        XCTAssertEqual(out.map(\.rule.pattern), ["ir", "ru"])
    }

    func testACountryRuleNeedsNoDNS() {
        XCTAssertTrue(RuleDestinationBuilder.hostsToResolve(rules: [rule("ir")], services: []).isEmpty)
    }

    func testResolvingAnAddressByCountry() {
        let ir = rule("ir", order: 0)
        let routes = [direct]
        let geoip = ["ir": ["203.0.113.0/24"]]
        XCTAssertEqual(RuleResolver.route(forIP: "203.0.113.9", rules: [ir], routes: routes, defaultRouteId: nil, geoip: geoip)?.id, direct.id)
        XCTAssertNil(RuleResolver.route(forIP: "198.51.100.9", rules: [ir], routes: routes, defaultRouteId: nil, geoip: geoip))
        XCTAssertNil(RuleResolver.route(forDomain: "example.ir", rules: [ir], routes: routes, defaultRouteId: nil),
                     "a country rule matches addresses, not names")
    }

    func testTheSiteAnswerMatchesAHostByItsAddress() {
        let ir = rule("ir")
        let geoip = ["ir": ["203.0.113.0/24"]]
        XCTAssertTrue(SiteRoute.ruleMatches(ir, host: "example.ir", addresses: ["203.0.113.9"], services: [], geoip: geoip))
        XCTAssertFalse(SiteRoute.ruleMatches(ir, host: "example.ir", addresses: ["198.51.100.9"], services: [], geoip: geoip))
        XCTAssertFalse(SiteRoute.ruleMatches(ir, host: "example.ir", addresses: ["203.0.113.9"], services: []), "no list, no match")
    }

    func testARuleSurvivesTheConfigFile() throws {
        var config = RouteManager.Config()
        // With routes the loader keeps the rules; with none it derives them from the lists.
        config.routes = [direct]
        config.defaultRouteId = direct.id
        config.schemaVersion = 2
        config.rules = [rule("ir")]
        config.geoipSourceURL = "https://mirror.example/geoip.dat"
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.rules.first?.matchType, .geoip)
        XCTAssertEqual(back.rules.first?.pattern, "ir")
        XCTAssertEqual(back.geoipSourceURL, "https://mirror.example/geoip.dat")
        XCTAssertNil(try JSONDecoder().decode(RouteManager.Config.self, from: Data("{}".utf8)).geoipSourceURL,
                     "a config from before Country rules has the default source")
    }

    // MARK: - vpnb rule.add

    func testRuleAddTakesACountryAndStoresItInLowerCase() {
        var config = RouteManager.Config()
        config.routes = [direct]
        let req = ControlRequest(cmd: "rule.add", args: ["match": "geoip", "pattern": "IR", "routeId": direct.id.uuidString])
        let (updated, response) = CommandRouter.apply(req, to: config)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(updated.rules.last?.matchType, .geoip)
        XCTAssertEqual(updated.rules.last?.pattern, "ir")
    }

    func testRuleAddRefusesAPatternThatIsNotAListName() {
        var config = RouteManager.Config()
        config.routes = [direct]
        for bad in ["10.0.0.0/8", "i", "not a country"] {
            let req = ControlRequest(cmd: "rule.add", args: ["match": "geoip", "pattern": bad, "routeId": direct.id.uuidString])
            let (updated, response) = CommandRouter.apply(req, to: config)
            XCTAssertFalse(response.ok, bad)
            XCTAssertEqual(response.error?.code, "invalid_args")
            XCTAssertTrue(updated.rules.isEmpty)
        }
    }

    // MARK: - Wording

    func testTheRowNamesACountryAndAList() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(GeoDisplay.name(for: "ir", locale: en), "Iran (IR)")
        XCTAssertEqual(GeoDisplay.name(for: "private", locale: en), "PRIVATE")
        XCTAssertEqual(RuleRow.glyph(for: .geoip), "flag")
    }

    func testTheLineUnderARowSaysWhatItHoldsOrWhyNot() {
        XCTAssertEqual(GeoDisplay.detail(count: nil, hasData: false), "Country list not downloaded yet.")
        XCTAssertEqual(GeoDisplay.detail(count: nil, hasData: true), "Not in the country list.")
        XCTAssertEqual(GeoDisplay.detail(count: 1, hasData: true), "1 range")
        XCTAssertEqual(GeoDisplay.detail(count: 1747, hasData: true), String(localized: "\(1747) ranges"),
                       "the count is written the way the locale writes a number")
    }
}

@MainActor
final class GeoDataStoreTests: XCTestCase {

    private var directory: URL!
    private var store: GeoDataStore!
    private let source = URL(string: "https://example.org/geoip.dat")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("geoip-test-\(UUID().uuidString)")
        store = GeoDataStore(kind: .ip, directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A fetch that hands back `data` as a temporary file, as a download does.
    private func serving(_ data: Data) -> (URL) async throws -> URL {
        { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try data.write(to: file)
            return file
        }
    }

    func testADownloadThatReadsAsAListReplacesTheCopyInUse() async {
        store.fetch = serving(Dat.sample)
        let replaced = await store.update(from: source)
        XCTAssertTrue(replaced)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.hasData)
        XCTAssertEqual(store.file.ranges(for: ["ir"])["ir"], ["203.0.113.0/24", "198.51.100.0/22"])
        XCTAssertEqual(store.file.countries(), ["ir": 2, "private": 2])
        XCTAssertEqual(store.revision, 1)
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path))?[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testAnErrorPageDoesNotReplaceTheLastGoodCopy() async {
        store.fetch = serving(Dat.sample)
        _ = await store.update(from: source)
        store.fetch = serving(Data("<html>rate limited</html>".utf8))
        let replaced = await store.update(from: source)
        XCTAssertFalse(replaced)
        if case .failed = store.phase {} else { XCTFail("the failure is shown: \(store.phase)") }
        XCTAssertEqual(store.file.ranges(for: ["ir"])["ir"]?.count, 2, "the copy that was in use still is")
    }

    func testAFailedFetchKeepsTheCopyAndSaysSo() async {
        store.fetch = serving(Dat.sample)
        _ = await store.update(from: source)
        store.fetch = { _ in throw URLError(.notConnectedToInternet) }
        let replaced = await store.update(from: source)
        XCTAssertFalse(replaced)
        XCTAssertEqual(store.phase, .failed("Could not download the list."))
        XCTAssertTrue(store.hasData)
    }

    func testAnEmptyDownloadIsRefused() async {
        store.fetch = serving(Data())
        let replaced = await store.update(from: source)
        XCTAssertFalse(replaced)
        XCTAssertFalse(store.hasData)
    }

    func testANewListIsReadAfterAnUpdate() async {
        store.fetch = serving(Dat.sample)
        _ = await store.update(from: source)
        XCTAssertEqual(store.file.ranges(for: ["ir"])["ir"]?.count, 2)
        store.fetch = serving(Dat.file([Dat.entry("IR", [Dat.cidr([192, 0, 2, 0], 24)])]))
        _ = await store.update(from: source)
        XCTAssertEqual(store.file.ranges(for: ["ir"])["ir"], ["192.0.2.0/24"], "the cache does not outlive its file")
    }

    func testNoListGivesNoRanges() {
        XCTAssertFalse(store.hasData)
        XCTAssertTrue(store.file.ranges(for: ["ir"]).isEmpty)
        XCTAssertTrue(store.file.countries().isEmpty)
    }

    func testAListIsStaleAfterAWeekAndAMissingOneAlwaysIs() async {
        XCTAssertTrue(store.needsRefresh())
        store.fetch = serving(Dat.sample)
        _ = await store.update(from: source)
        XCTAssertFalse(store.needsRefresh())
        let week = GeoSyncSchedule.weekly.interval!
        XCTAssertFalse(store.needsRefresh(every: week, now: Date().addingTimeInterval(week - 60)))
        XCTAssertTrue(store.needsRefresh(every: week, now: Date().addingTimeInterval(week + 60)))
    }

    func testASourceIsHTTPSWithAHostAndDefaultsWhenEmpty() {
        XCTAssertEqual(GeoDataStore.source(from: nil, kind: .ip)?.absoluteString, GeoKind.ip.defaultSource)
        XCTAssertEqual(GeoDataStore.source(from: "  ", kind: .site)?.absoluteString, GeoKind.site.defaultSource)
        XCTAssertEqual(GeoDataStore.source(from: "https://mirror.example/geoip.dat", kind: .ip)?.host, "mirror.example")
        for bad in ["http://mirror.example/geoip.dat", "file:///etc/passwd", "ftp://x/y", "https://", "mirror.example/geoip.dat"] {
            XCTAssertNil(GeoDataStore.source(from: bad, kind: .ip), "\(bad) is not a source")
        }
    }

    func testTheStatusLineSaysWhereTheListIsFromAndHowOldItIs() {
        let now = Date()
        XCTAssertEqual(GeoDisplay.status(.ip, updated: nil, phase: .idle),
                       "The country list is not downloaded yet.")
        XCTAssertEqual(GeoDisplay.status(.ip, updated: nil, phase: .updating), "Downloading the country list…")
        XCTAssertEqual(GeoDisplay.status(.ip, updated: nil, phase: .failed("Could not download the list.")),
                       "Could not download the list.")
        XCTAssertTrue(GeoDisplay.status(.ip, updated: now.addingTimeInterval(-86_400 * 3), phase: .idle, now: now)
            .hasPrefix("Country list last synced"))
    }
}

/// Reads a real list when `VPNB_GEOIP_FILE` names one, to check the reader against the format as
/// published (the other tests use lists encoded here):
///
///   VPNB_GEOIP_FILE=/path/to/geoip.dat swift test --filter GeoIPRealFileTests
final class GeoIPRealFileTests: XCTestCase {
    func testAPublishedListReads() throws {
        guard let path = ProcessInfo.processInfo.environment["VPNB_GEOIP_FILE"] else {
            throw XCTSkip("Set VPNB_GEOIP_FILE to a geoip.dat to read it.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        XCTAssertTrue(GeoIPDat.isUsable(data))

        var start = CFAbsoluteTimeGetCurrent()
        let countries = GeoIPDat.countries(in: data)
        let listed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        start = CFAbsoluteTimeGetCurrent()
        let ranges = GeoIPDat.ranges(for: ["ir"], in: data)["ir"] ?? []
        let one = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("GEOIP lists=\(countries.count) ir=\(ranges.count) ranges, listing \(Int(listed)) ms, one country \(Int(one)) ms")

        XCTAssertGreaterThan(countries.count, 50)
        XCTAssertEqual(countries["ir"], ranges.count)
        XCTAssertFalse(ranges.isEmpty)
        for range in ranges {
            XCTAssertNotNil(RouteCIDR.parse(range), "\(range) reads as a range")
            XCTAssertFalse(DestinationInstallPolicy.refusesInstall(range), "\(range) can be installed")
        }
    }
}
