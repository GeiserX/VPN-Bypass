// GeoSiteTests.swift
// Site (GeoSite) rules and the searchable pickers: the geosite.dat reader, a list's expansion into
// wildcards and names, the limits, the rule's reach into the compiler, the wildcard planner, the
// lookup that explains a name, the sources, and the picker's search. The files are encoded by hand
// from made-up names (reserved example domains), so nothing here reads the network or the real lists.

import XCTest
@testable import VPNBypassCore

extension Dat {
    /// A geosite `Domain`: type 0 keyword, 1 regex, 2 domain (suffix), 3 full, with its attributes.
    static func domain(_ type: UInt64, _ value: String, attrs: [String] = []) -> [UInt8] {
        bytes(2, number(1, type) + bytes(2, Array(value.utf8)) + attrs.flatMap { bytes(3, bytes(1, Array($0.utf8))) })
    }
    static func site(_ name: String, _ domains: [[UInt8]]) -> [UInt8] {
        bytes(1, bytes(1, Array(name.utf8)) + domains.flatMap { $0 })
    }

    static let sites = file([
        site("GAMES", [domain(2, "steampowered.com"), domain(2, "store.steampowered.com"),
                       domain(3, "cdn.steampowered.com"), domain(3, "login.example.net"),
                       domain(3, "steampowered.com"), domain(0, "steam"), domain(1, "^cdn[0-9]\\.example\\.org$"),
                       domain(2, "com")]),
        site("MICROSOFT", [domain(2, "microsoft.com", attrs: ["cn"]), domain(2, "office.com"),
                           domain(3, "login.live.com", attrs: ["cn", "ads"])]),
        site("EMPTY", [domain(0, "only-keyword")]),
    ])
}

final class GeoSiteDatTests: XCTestCase {

    func testAListBecomesWildcardsAndNamesWithShorterSuffixesAbsorbingLongerOnes() throws {
        let games = try XCTUnwrap(GeoSiteDat.expansions(for: ["games"], in: Dat.sites)["games"])
        XCTAssertEqual(games.suffixes, ["steampowered.com"], "store. and the bare name sit under steampowered.com; `com` is not a usable suffix")
        XCTAssertEqual(games.names, ["login.example.net"], "cdn.steampowered.com is under a suffix, the apex is the suffix itself")
        XCTAssertEqual(games.unsupported, 3, "the keyword, the regex and the one-label suffix")
        XCTAssertTrue(games.found)
        XCTAssertEqual(games.count, 2)
    }

    func testAnAttributeKeepsOnlyTheEntriesThatCarryIt() throws {
        let out = GeoSiteDat.expansions(for: ["microsoft", "microsoft@cn", "microsoft@ads", "microsoft@none"], in: Dat.sites)
        XCTAssertEqual(out["microsoft"]?.suffixes, ["microsoft.com", "office.com"])
        XCTAssertEqual(out["microsoft"]?.names, ["login.live.com"])
        XCTAssertEqual(out["microsoft@cn"]?.suffixes, ["microsoft.com"])
        XCTAssertEqual(out["microsoft@cn"]?.names, ["login.live.com"])
        XCTAssertEqual(out["microsoft@ads"]?.suffixes, [])
        XCTAssertEqual(out["microsoft@ads"]?.names, ["login.live.com"])
        XCTAssertEqual(out["microsoft@none"]?.count, 0)
        XCTAssertEqual(out["microsoft@none"]?.found, true, "the list exists; no entry carries that attribute")
    }

    func testAListTheFileLacksIsNotFoundAndRoutesNothing() {
        let out = GeoSiteDat.expansions(for: ["nowhere", "nowhere@cn"], in: Dat.sites)
        XCTAssertEqual(out["nowhere"]?.found, false)
        XCTAssertEqual(out["nowhere@cn"]?.found, false)
        XCTAssertTrue(out["nowhere"]!.usable.suffixes.isEmpty)
    }

    func testNamesAreReadInAnyCase() {
        XCTAssertNotNil(GeoSiteDat.expansions(for: ["games"], in: Dat.sites)["games"]?.suffixes.first)
        XCTAssertEqual(GeoSiteDat.parse(pattern: "Steam@CN").name, "steam")
        XCTAssertEqual(GeoSiteDat.parse(pattern: "Steam@CN").attribute, "cn")
        XCTAssertNil(GeoSiteDat.parse(pattern: "steam").attribute)
        XCTAssertNil(GeoSiteDat.parse(pattern: "steam@").attribute)
    }

    func testTheListsOfAFileAreCountedByTheirSupportedEntries() {
        XCTAssertEqual(GeoSiteDat.lists(in: Dat.sites), ["games": 6, "microsoft": 3],
                       "a list with only keywords is not offered; the count is of entries as written")
    }

    func testAFileIsUsableOnlyWithAListThatHasASuffixOrAName() {
        XCTAssertTrue(GeoSiteDat.isUsable(Dat.sites))
        XCTAssertFalse(GeoSiteDat.isUsable(Data()))
        XCTAssertFalse(GeoSiteDat.isUsable(Data("<html>Not Found</html>".utf8)))
        XCTAssertFalse(GeoSiteDat.isUsable(Dat.file([Dat.site("EMPTY", [Dat.domain(0, "kw")])])))
        XCTAssertFalse(GeoSiteDat.isUsable(Dat.sample), "a geoip file is not a geosite file")
        XCTAssertFalse(GeoKind.ip.isUsable(Dat.sites), "and the other way round")
    }

    func testATruncatedOrCorruptFileNeverTraps() {
        let data = Dat.sites
        for length in 0..<data.count {
            let cut = data.prefix(length)
            _ = GeoSiteDat.expansions(for: ["games", "microsoft@cn"], in: cut)
            _ = GeoSiteDat.lists(in: cut)
            _ = GeoSiteDat.isUsable(cut)
        }
        let lying = Data([0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x0A, 0x02, 0x69, 0x72])
        XCTAssertFalse(GeoSiteDat.isUsable(lying))
        XCTAssertFalse(GeoSiteDat.isUsable(Data(repeating: 0xFF, count: 40)))
    }

    func testAListWithMoreWildcardsThanTheLimitIsRefusedWhole() {
        let many = (0...GeoSiteExpansion.maxSuffixes).map { "host\($0).example.net" }
        let data = Dat.file([Dat.site("BIG", many.map { Dat.domain(2, $0) })])
        let big = GeoSiteDat.expansions(for: ["big"], in: data)["big"]!
        XCTAssertEqual(big.suffixes.count, GeoSiteExpansion.maxSuffixes + 1)
        XCTAssertTrue(big.isTooLarge)
        XCTAssertEqual(big.usable.count, 0, "a part of a list would send some of a site's names one way and some another")
    }

    func testMatchingAHostByItsList() throws {
        let games = try XCTUnwrap(GeoSiteDat.expansions(for: ["games"], in: Dat.sites)["games"])
        XCTAssertTrue(games.matches("steampowered.com"))
        XCTAssertTrue(games.matches("A.B.SteamPowered.com"))
        XCTAssertTrue(games.matches("login.example.net"))
        XCTAssertFalse(games.matches("other.example.net"), "a full entry is one name")
        XCTAssertFalse(games.matches("notsteampowered.com"))
    }

    func testAPatternIsAListNameWithAnOptionalAttribute() {
        XCTAssertEqual(GeoSiteRule.normalized(" Category-Games@CN "), "category-games@cn")
        XCTAssertEqual(GeoSiteRule.normalized("geolocation-!cn"), "geolocation-!cn")
        for bad in ["", "a", "a@b@c", "steam@", "@cn", "st eam", "steam/x", "é", String(repeating: "a", count: 61)] {
            XCTAssertNil(GeoSiteRule.normalized(bad), "\(bad) is not a list name")
        }
    }
}

final class GeoSiteRuleTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)
    private let proxy = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "p", proxyPort: 1080)

    private func rule(_ pattern: String, route: Route? = nil, order: Int = 0, type: MatchType = .geosite) -> Rule {
        Rule(matchType: type, pattern: pattern, routeId: (route ?? direct).id, order: order)
    }

    private func custom(_ rules: [Rule]) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [direct, proxy]
        c.rules = rules
        return c
    }

    private var games: [String: GeoSiteExpansion] { GeoSiteDat.expansions(for: ["games"], in: Dat.sites) }

    // MARK: - Compiling

    func testTheNamesOfAListAreResolvedAndItsSuffixesAreLeftToTheWildcards() {
        let hosts = RuleDestinationBuilder.hostsToResolve(rules: [rule("games")], services: [], geosite: games)
        XCTAssertEqual(hosts, ["login.example.net"])
        let out = RuleDestinationBuilder.build(rules: [rule("games")], services: [],
                                               resolved: ["login.example.net": ["203.0.113.7"], "steampowered.com": ["198.51.100.1"]],
                                               geosite: games)
        XCTAssertEqual(out[0].dests.map(\.value), ["203.0.113.7"])
        XCTAssertFalse(out[0].dests[0].isNetwork)
    }

    func testNoListOrADisabledRuleResolvesNothing() {
        XCTAssertTrue(RuleDestinationBuilder.hostsToResolve(rules: [rule("games")], services: []).isEmpty)
        var off = rule("games"); off.enabled = false
        XCTAssertTrue(RuleDestinationBuilder.hostsToResolve(rules: [off], services: [], geosite: games).isEmpty)
    }

    // MARK: - Wildcards

    func testTheSuffixesOfAListBecomeWildcardsOnADirectRoute() {
        let configured = WildcardPlanner.configured(custom([rule("games")]), geosite: games)
        XCTAssertEqual(configured.map(\.suffix), ["steampowered.com"])
        XCTAssertEqual(configured.first?.via, .physical)
    }

    func testAListOnAProxyRouteMakesNoWildcard() {
        XCTAssertTrue(WildcardPlanner.configured(custom([rule("games", route: proxy)]), geosite: games).isEmpty,
                      "a proxy route is a listener; a resolver file cannot send it names")
    }

    func testFirstMatchHoldsWhenAnEarlierRuleClaimsAName() {
        let earlier = rule("steampowered.com", route: proxy, order: 0, type: .suffix)
        let configured = WildcardPlanner.configured(custom([earlier, rule("games", order: 1)]), geosite: games)
        XCTAssertTrue(configured.isEmpty, "the suffix is under one an earlier rule claims")
        let exact = rule("store.steampowered.com", route: proxy, order: 0, type: .domain)
        let second = WildcardPlanner.configured(custom([exact, rule("games", order: 1)]), geosite: games)
        XCTAssertEqual(second.first?.excluded, ["store.steampowered.com"], "the name stays with the earlier rule")
    }

    func testAListThatIsMissingOrTooLargeMakesNoWildcard() {
        XCTAssertTrue(WildcardPlanner.configured(custom([rule("nowhere")]), geosite: GeoSiteDat.expansions(for: ["nowhere"], in: Dat.sites)).isEmpty)
        let many = (0...GeoSiteExpansion.maxSuffixes).map { "host\($0).example.net" }
        let big = GeoSiteDat.expansions(for: ["big"], in: Dat.file([Dat.site("BIG", many.map { Dat.domain(2, $0) })]))
        XCTAssertTrue(WildcardPlanner.configured(custom([rule("big")]), geosite: big).isEmpty)
    }

    func testTheLimitsAre10kWildcardsAnd2kNames() {
        XCTAssertEqual(GeoSiteExpansion.maxSuffixes, 10_000)
        XCTAssertEqual(GeoSiteExpansion.maxNames, 2_000)
        XCTAssertFalse(GeoSiteExpansion(suffixes: Array(repeating: "a.example.net", count: 10_000)).isTooLarge)
        XCTAssertTrue(GeoSiteExpansion(suffixes: Array(repeating: "a.example.net", count: 10_001)).isTooLarge)
        XCTAssertTrue(GeoSiteExpansion(names: Array(repeating: "a.example.net", count: 2_001)).isTooLarge)
    }

    func testTheRowNamesTheNumberThatIsOver() {
        let manyNames = GeoSiteExpansion(names: (0...GeoSiteExpansion.maxNames).map { "h\($0).example.net" })
        XCTAssertEqual(GeoDisplay.siteDetail(manyNames, hasData: true),
                       String(localized: "Too large to route: \(GeoSiteExpansion.maxNames + 1) domains, the limit is \(GeoSiteExpansion.maxNames)."))
        let manySuffixes = GeoSiteExpansion(suffixes: (0...GeoSiteExpansion.maxSuffixes).map { "h\($0).example.net" })
        XCTAssertEqual(GeoDisplay.siteDetail(manySuffixes, hasData: true),
                       String(localized: "Too large to route: \(GeoSiteExpansion.maxSuffixes + 1) domains, the limit is \(GeoSiteExpansion.maxSuffixes)."))
    }

    /// 10,000 wildcards plan in one pass, with an earlier rule's names excluded from the right ones.
    func testTenThousandSuffixesPlanQuicklyAndExcludeWhatAnEarlierRuleClaims() {
        let suffixes = (0..<GeoSiteExpansion.maxSuffixes).map { "h\($0).t\($0 % 97).example.net" }
        let lists = GeoSiteDat.expansions(for: ["many"], in: Dat.file([Dat.site("MANY", suffixes.map { Dat.domain(2, $0) })]))
        let early = rule("login.h7.t7.example.net", order: 0, type: .domain)
        let started = CFAbsoluteTimeGetCurrent()
        let configured = WildcardPlanner.configured(custom([early, rule("many", order: 1)]), geosite: lists)
        let seconds = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(configured.count, 10_000)
        XCTAssertEqual(configured.first { $0.suffix == "h7.t7.example.net" }?.excluded, ["login.h7.t7.example.net"])
        XCTAssertTrue(configured.filter { $0.suffix != "h7.t7.example.net" }.allSatisfy { $0.excluded.isEmpty })
        XCTAssertLessThan(seconds, 5, "planning 10,000 wildcards took \(seconds) s")
    }

    func testAThousandSuffixesPlanAtOnceAndKeepTheirOrder() {
        let suffixes = (0..<1_500).map { "h\($0).example.net" }
        let data = Dat.file([Dat.site("MANY", suffixes.map { Dat.domain(2, $0) })])
        let lists = GeoSiteDat.expansions(for: ["many"], in: data)
        let started = CFAbsoluteTimeGetCurrent()
        let configured = WildcardPlanner.configured(custom([rule("many")]), geosite: lists)
        let seconds = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(configured.count, 1_500)
        XCTAssertLessThan(seconds, 5, "planning 1,500 wildcards took \(seconds) s")
    }

    /// The most a list may hold is a resolver file each. The helper writes them as root into
    /// /etc/resolver; this writes the same files into a folder of the test's own.
    func testTheLargestListWritesItsResolverFilesAndTakesThemBackOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let wanted = Set((0..<GeoSiteExpansion.maxSuffixes).map { "h\($0).example.net" })
        let started = CFAbsoluteTimeGetCurrent()
        let first = WildcardResolverFile.sync(wanted: wanted, in: dir)
        let wrote = (CFAbsoluteTimeGetCurrent() - started) * 1000
        XCTAssertTrue(first.errors.isEmpty, "\(first.errors)")
        XCTAssertTrue(first.foreign.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).count, GeoSiteExpansion.maxSuffixes)
        let again = WildcardResolverFile.sync(wanted: wanted, in: dir)
        XCTAssertFalse(again.changed, "a second sync with the same list writes nothing")
        let fewer = WildcardResolverFile.sync(wanted: Set(wanted.prefix(10)), in: dir)
        XCTAssertTrue(fewer.changed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).count, 10, "a list taken off removes its files")
        print("RESOLVER wrote \(wanted.count) files in \(Int(wrote)) ms")
    }

    // MARK: - Explaining a name

    func testTheResolverAndTheSiteAnswerMatchANameByItsList() {
        let r = rule("games")
        XCTAssertEqual(RuleResolver.route(forDomain: "x.steampowered.com", rules: [r], routes: [direct], defaultRouteId: nil, geosite: games)?.id, direct.id)
        XCTAssertNil(RuleResolver.route(forDomain: "example.org", rules: [r], routes: [direct], defaultRouteId: nil, geosite: games))
        XCTAssertNil(RuleResolver.route(forIP: "203.0.113.7", rules: [r], routes: [direct], defaultRouteId: nil),
                     "a site rule matches names, not addresses")
        XCTAssertTrue(SiteRoute.ruleMatches(r, host: "steampowered.com", addresses: [], services: [], geosite: games))
        XCTAssertFalse(SiteRoute.ruleMatches(r, host: "example.org", addresses: [], services: [], geosite: games))
        XCTAssertFalse(SiteRoute.ruleMatches(r, host: "steampowered.com", addresses: [], services: []), "no list, no match")
    }

    // MARK: - The config and vpnb

    func testARuleAndASourceSurviveTheConfigFile() throws {
        var c = custom([rule("games@cn")])
        c.geositeSourceURL = "https://mirror.example/geosite.dat"
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.rules.first?.matchType, .geosite)
        XCTAssertEqual(back.rules.first?.pattern, "games@cn")
        XCTAssertEqual(back.geositeSourceURL, "https://mirror.example/geosite.dat")
        XCTAssertNil(try JSONDecoder().decode(RouteManager.Config.self, from: Data("{}".utf8)).geositeSourceURL)
    }

    func testRuleAddTakesAListAndRefusesAnythingElse() {
        var c = RouteManager.Config()
        c.routes = [direct]
        let add = ControlRequest(cmd: "rule.add", args: ["match": "geosite", "pattern": "Category-Games@CN", "routeId": direct.id.uuidString])
        let (updated, response) = CommandRouter.apply(add, to: c)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(updated.rules.last?.pattern, "category-games@cn")
        for bad in ["a", "x@y@z", "not a list"] {
            let req = ControlRequest(cmd: "rule.add", args: ["match": "geosite", "pattern": bad, "routeId": direct.id.uuidString])
            let (none, refused) = CommandRouter.apply(req, to: c)
            XCTAssertFalse(refused.ok, bad)
            XCTAssertEqual(refused.error?.code, "invalid_args")
            XCTAssertTrue(none.rules.isEmpty)
        }
    }

    // MARK: - Wording

    func testTheLineUnderASiteRowSaysWhatItHoldsOrWhyItRoutesNothing() {
        XCTAssertEqual(GeoDisplay.siteDetail(nil, hasData: false), "Site list not downloaded yet.")
        XCTAssertEqual(GeoDisplay.siteDetail(GeoSiteExpansion(found: false), hasData: true), "Not in the site list.")
        XCTAssertEqual(GeoDisplay.siteDetail(games["games"], hasData: true), String(localized: "\(String(localized: "\(2) domains")), \(3) not supported"))
        XCTAssertEqual(GeoDisplay.siteDetail(GeoSiteExpansion(suffixes: ["a.example.net"]), hasData: true), "1 domain")
        let big = GeoSiteExpansion(suffixes: (0...GeoSiteExpansion.maxSuffixes).map { "h\($0).example.net" })
        XCTAssertTrue(GeoDisplay.siteDetail(big, hasData: true).hasPrefix("Too large to route"))
        XCTAssertEqual(RuleRow.glyph(for: .geosite), "list.bullet.rectangle")
    }
}

final class GeoPickerTests: XCTestCase {

    private let en = Locale(identifier: "en_US")

    func testCountriesComeFirstByTheirNameAndOtherListsFollowByCode() {
        let choices = GeoChoices.countries(["ru": 5, "ir": 2, "private": 1, "cloudflare": 3, "de": 9], locale: en)
        XCTAssertEqual(choices.map(\.code), ["de", "ir", "ru", "cloudflare", "private"])
        XCTAssertEqual(choices.first?.title, "Germany (DE)")
        XCTAssertEqual(choices.first(where: { $0.code == "private" })?.title, "PRIVATE")
    }

    func testSiteListsAreOfferedByName() {
        XCTAssertEqual(GeoChoices.sites(["steam": 61, "category-games": 1063]).map(\.code), ["category-games", "steam"])
    }

    func testSearchFindsACountryByNameOrCodeAndPutsTheBestFirst() {
        let all = GeoChoices.countries(["ir": 2, "iq": 3, "ie": 4, "ru": 5, "us": 6, "private": 1], locale: en)
        XCTAssertEqual(GeoChoices.filter(all, query: "iran").shown.map(\.code), ["ir"])
        XCTAssertEqual(GeoChoices.filter(all, query: "IR").shown.first?.code, "ir", "the code typed whole comes first")
        XCTAssertEqual(GeoChoices.filter(all, query: "ir").shown.map(\.code), ["ir", "iq", "ie"],
                       "the exact code, then names that start with it, in the list's order")
        XCTAssertTrue(GeoChoices.filter(all, query: "zzz").shown.isEmpty)
        XCTAssertEqual(GeoChoices.filter(all, query: "  ").shown.count, all.count, "no query shows everything")
    }

    func testSearchIgnoresCaseAndAccentsAndRanksPrefixesBeforeInnerMatches() {
        let all = GeoChoices.sites(["category-games": 1, "gaming": 2, "games-cn": 3, "wargaming": 4, "steam": 5])
        XCTAssertEqual(GeoChoices.filter(all, query: "gam").shown.map(\.code), ["games-cn", "gaming", "category-games", "wargaming"])
        XCTAssertEqual(GeoChoices.filter(all, query: "GAMING").shown.map(\.code), ["gaming", "wargaming"])
        let accented = [GeoChoice(code: "ci", title: "Côte d’Ivoire (CI)", count: 1)]
        XCTAssertEqual(GeoChoices.filter(accented, query: "cote").shown.count, 1)
    }

    func testALongResultIsCutAndSaysHowManyAreLeftOut() {
        let all = GeoChoices.sites(Dictionary(uniqueKeysWithValues: (0..<1_000).map { ("list\($0)", 1) }))
        let result = GeoChoices.filter(all, query: "list", limit: 300)
        XCTAssertEqual(result.shown.count, 300)
        XCTAssertEqual(result.hidden, 700)
        XCTAssertEqual(GeoChoices.filter(all, query: "", limit: 50).hidden, 950)
    }

    // MARK: - Sources

    func testEachPresetHasAnAddressForBothFiles() {
        for preset in GeoSource.presets {
            for kind in GeoKind.allCases {
                let url = GeoDataStore.source(from: preset.url(for: kind), kind: kind)
                XCTAssertNotNil(url, "\(preset.title) \(kind)")
                XCTAssertEqual(url?.lastPathComponent, kind.fileName)
            }
        }
        XCTAssertEqual(Set(GeoSource.presets.map(\.id)).count, GeoSource.presets.count)
    }

    func testTheDefaultIsTheFirstPresetAndACustomAddressIsNamedByItsHost() {
        XCTAssertEqual(GeoSource.preset(for: nil, kind: .ip)?.id, "chocolate4u")
        XCTAssertEqual(GeoSource.preset(for: "", kind: .site)?.id, "chocolate4u")
        XCTAssertEqual(GeoSource.defaultID, "chocolate4u")
        XCTAssertEqual(GeoKind.ip.defaultSource, GeoSource.presets[0].url(for: .ip))
        XCTAssertEqual(GeoKind.ip.defaultSource, "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geoip.dat")
        let loyal = GeoSource.presets.first { $0.id == "loyalsoldier" }!
        XCTAssertEqual(GeoSource.preset(for: loyal.url(for: .site), kind: .site)?.title, "Loyalsoldier")
        XCTAssertNil(GeoSource.preset(for: loyal.url(for: .site), kind: .ip), "a geosite address is not the geoip source")
        XCTAssertNil(GeoSource.preset(for: "https://mirror.example/x/geosite.dat", kind: .site))
        XCTAssertEqual(GeoSource.title(for: "https://mirror.example/x/geosite.dat", kind: .site), "mirror.example")
        XCTAssertEqual(GeoSource.title(for: nil, kind: .ip), "Chocolate4U (Iran)")
    }
}

@MainActor
final class GeoSiteStoreTests: XCTestCase {

    private var directory: URL!
    private var store: GeoDataStore!
    private let source = URL(string: "https://example.org/geosite.dat")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("geosite-test-\(UUID().uuidString)")
        store = GeoDataStore(kind: .site, directory: directory)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func serving(_ data: Data) -> (URL) async throws -> URL {
        { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try data.write(to: file)
            return file
        }
    }

    func testADownloadOfTheRightKindIsReadAfterwards() async {
        store.fetch = serving(Dat.sites)
        let replaced = await store.update(from: source)
        XCTAssertTrue(replaced)
        XCTAssertEqual(store.file.url.lastPathComponent, "geosite.dat")
        XCTAssertEqual(store.file.lists(), ["games": 6, "microsoft": 3])
        XCTAssertEqual(store.file.expansions(for: ["games"])["games"]?.suffixes, ["steampowered.com"])
    }

    func testAGeoIPFileIsNotAcceptedAsAGeoSiteList() async {
        store.fetch = serving(Dat.sample)
        let replaced = await store.update(from: source)
        XCTAssertFalse(replaced)
        XCTAssertFalse(store.hasData, "the wrong file from a wrong address must not stand in")
        XCTAssertEqual(store.phase, .failed("The download is not a list of the right kind."))
    }

    func testAnUpdateReplacesWhatWasReadBefore() async {
        store.fetch = serving(Dat.sites)
        _ = await store.update(from: source)
        XCTAssertEqual(store.file.expansions(for: ["microsoft"])["microsoft"]?.suffixes, ["microsoft.com", "office.com"])
        store.fetch = serving(Dat.file([Dat.site("MICROSOFT", [Dat.domain(2, "live.com")])]))
        _ = await store.update(from: source)
        XCTAssertEqual(store.file.expansions(for: ["microsoft"])["microsoft"]?.suffixes, ["live.com"])
    }

    func testAKindOnlyAnswersForItsOwnFile() async {
        store.fetch = serving(Dat.sites)
        _ = await store.update(from: source)
        XCTAssertTrue(store.file.ranges(for: ["games"]).isEmpty)
        XCTAssertTrue(store.file.countries().isEmpty)
    }

    func testTheStatusLineNamesTheSiteList() {
        let now = Date()
        XCTAssertEqual(GeoDisplay.status(.site, updated: nil, phase: .idle), "The site list is not downloaded yet.")
        XCTAssertEqual(GeoDisplay.status(.site, updated: nil, phase: .updating), "Downloading the site list…")
        XCTAssertTrue(GeoDisplay.status(.site, updated: now, phase: .idle, now: now).hasPrefix("Site list last synced"))
    }
}

final class GeoSyncTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func testTheScheduleSaysHowOftenAListIsDownloadedAgain() {
        XCTAssertNil(GeoSyncSchedule.off.interval)
        XCTAssertEqual(GeoSyncSchedule.daily.interval, 86_400)
        XCTAssertEqual(GeoSyncSchedule.weekly.interval, 7 * 86_400)
        XCTAssertEqual(GeoSyncSchedule.monthly.interval, 30 * 86_400)
        XCTAssertEqual(GeoSyncSchedule.default, .weekly)
        XCTAssertEqual(GeoSyncSchedule.allCases.map(\.title), ["Off", "Every day", "Every week", "Every month"])
    }

    func testOffDownloadsNothingByItself() {
        XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: .off, updated: nil, lastAttempt: nil, now: now), "not even a missing list")
        XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: .off, updated: ago(400 * 86_400), lastAttempt: nil, now: now))
    }

    func testAMissingListIsFetchedAndAFreshOneIsNot() {
        for schedule in [GeoSyncSchedule.daily, .weekly, .monthly] {
            XCTAssertTrue(GeoSyncPlan.shouldFetch(schedule: schedule, updated: nil, lastAttempt: nil, now: now), "\(schedule)")
            XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: schedule, updated: ago(60), lastAttempt: nil, now: now), "\(schedule)")
        }
    }

    func testAListIsFetchedOnceItIsOlderThanTheInterval() {
        XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: .daily, updated: ago(86_400 - 60), lastAttempt: nil, now: now))
        XCTAssertTrue(GeoSyncPlan.shouldFetch(schedule: .daily, updated: ago(86_400 + 60), lastAttempt: nil, now: now))
        XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: .weekly, updated: ago(2 * 86_400), lastAttempt: nil, now: now))
        XCTAssertTrue(GeoSyncPlan.shouldFetch(schedule: .weekly, updated: ago(8 * 86_400), lastAttempt: nil, now: now))
        XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: .monthly, updated: ago(20 * 86_400), lastAttempt: nil, now: now))
        XCTAssertTrue(GeoSyncPlan.shouldFetch(schedule: .monthly, updated: ago(31 * 86_400), lastAttempt: nil, now: now))
    }

    func testAFailedTryIsRepeatedAnHourLater() {
        XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: .weekly, updated: nil, lastAttempt: ago(600), now: now))
        XCTAssertTrue(GeoSyncPlan.shouldFetch(schedule: .weekly, updated: nil, lastAttempt: ago(3_700), now: now))
        XCTAssertFalse(GeoSyncPlan.shouldFetch(schedule: .daily, updated: ago(3 * 86_400), lastAttempt: ago(60), now: now))
    }

    func testTheScheduleSurvivesTheConfigFileAndAnUnknownOneIsTheDefault() throws {
        var c = RouteManager.Config()
        c.geoSync = .monthly
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.geoSync, .monthly)
        XCTAssertEqual(try JSONDecoder().decode(RouteManager.Config.self, from: Data("{}".utf8)).geoSync, .weekly)
        let odd = try JSONDecoder().decode(RouteManager.Config.self, from: Data(#"{"geoSync":"hourly"}"#.utf8))
        XCTAssertEqual(odd.geoSync, .weekly, "an unknown value is the default, not a config that will not load")
    }

    func testTheLineSaysWhenTheListWasLastSyncedAndHowLongAgo() throws {
        let en = GeoDisplay.lastSynced(.ip, updated: ago(3 * 86_400), now: now)
        let line = try XCTUnwrap(en)
        XCTAssertTrue(line.hasPrefix("Country list last synced "))
        XCTAssertTrue(line.contains("3 days ago"), line)
        XCTAssertTrue(line.contains(ago(3 * 86_400).formatted(date: .abbreviated, time: .shortened)), "the time itself is shown")
        XCTAssertTrue(try XCTUnwrap(GeoDisplay.lastSynced(.site, updated: now, now: now)).hasPrefix("Site list last synced "))
        XCTAssertNil(GeoDisplay.lastSynced(.ip, updated: nil, now: now))
    }

    func testAFailureKeepsTheLastSyncVisible() {
        let failed = GeoDisplay.status(.ip, updated: ago(86_400), phase: .failed("Could not download the list."), now: now)
        XCTAssertTrue(failed.hasPrefix("Could not download the list. Country list last synced "), failed)
        XCTAssertEqual(GeoDisplay.status(.ip, updated: nil, phase: .failed("Could not download the list."), now: now),
                       "Could not download the list.")
    }
}

/// Reads real lists when `VPNB_GEOSITE_FILE` names one:
///
///   VPNB_GEOSITE_FILE=/path/to/geosite.dat swift test --filter GeoSiteRealFileTests
final class GeoSiteRealFileTests: XCTestCase {
    func testAPublishedListReads() throws {
        guard let path = ProcessInfo.processInfo.environment["VPNB_GEOSITE_FILE"] else {
            throw XCTSkip("Set VPNB_GEOSITE_FILE to a geosite.dat to read it.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        XCTAssertTrue(GeoSiteDat.isUsable(data))
        var start = CFAbsoluteTimeGetCurrent()
        let lists = GeoSiteDat.lists(in: data)
        let listed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        start = CFAbsoluteTimeGetCurrent()
        let wanted: Set<String> = ["category-games", "steam", "microsoft", "epicgames", "category-ads"]
        let out = GeoSiteDat.expansions(for: wanted, in: data)
        let read = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let summary = wanted.sorted().map { "\($0)=\(out[$0]!.suffixes.count)+\(out[$0]!.names.count)" }.joined(separator: " ")
        print("GEOSITE lists=\(lists.count) \(summary), listing \(Int(listed)) ms, five lists \(Int(read)) ms")
        XCTAssertGreaterThan(lists.count, 100)
        for name in wanted {
            let list = try XCTUnwrap(out[name])
            XCTAssertTrue(list.found, name)
            XCTAssertFalse(list.isTooLarge, "\(name) fits the limits")
            XCTAssertGreaterThan(list.count, 0, name)
            for suffix in list.suffixes { XCTAssertNotNil(WildcardDomain.normalizedSuffix(suffix), suffix) }
        }
        XCTAssertTrue(out["steam"]!.matches("store.steampowered.com"))
    }
}
