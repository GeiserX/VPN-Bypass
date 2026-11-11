// HostsBlockTests.swift
// Custom mode's Block route for a list too large for wildcards: the names go in a separate section of
// /etc/hosts as `0.0.0.0 name`. The text work is a pure function shared with the helper; the rest runs
// against the test seam of the helper's call.

import XCTest
@testable import VPNBypassCore

final class HostsBlockSectionTests: XCTestCase {

    private let start = HostsBlockSection.startMarker
    private let end = HostsBlockSection.endMarker
    private let base = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1\tlocalhost\n"

    func testANameIsValidOnlyAsAHostName() {
        for good in ["example.com", "ads.example.co.uk", "a-b.example.com", "x1.y2.example.org", "EXAMPLE.com"] {
            XCTAssertTrue(HostsBlockSection.isValidName(good), good)
        }
        for bad in ["", "localhost", "com", "a b.example.com", "a.example.com\n127.0.0.1 evil.com", "a.example.com #x",
                    "-a.example.com", "a-.example.com", "a..example.com", ".example.com", "example.com.", "ex_ample.com",
                    "1.2.3.4", "a.example.123", String(repeating: "a", count: 64) + ".com",
                    String(repeating: "a.", count: 130) + "com", "é.example.com", "a.example.com\t1.2.3.4"] {
            XCTAssertFalse(HostsBlockSection.isValidName(bad), "\(bad.debugDescription) must not be written")
        }
    }

    func testASectionIsAddedAtTheEndWithTheOtherLinesLeftAlone() throws {
        let out = try XCTUnwrap(HostsBlockSection.rewritten(base, names: ["ads.example.com", "track.example.net"]))
        XCTAssertTrue(out.hasPrefix(base))
        XCTAssertEqual(out, base + "\n\(start)\n0.0.0.0 ads.example.com\n0.0.0.0 track.example.net\n\(end)\n")
        XCTAssertEqual(HostsBlockSection.names(in: out), ["ads.example.com", "track.example.net"])
        XCTAssertTrue(HostsBlockSection.hasSection(out))
    }

    func testTheSectionIsReplacedNotAppendedTo() throws {
        let first = try XCTUnwrap(HostsBlockSection.rewritten(base, names: ["a.example.com", "b.example.com"]))
        let second = try XCTUnwrap(HostsBlockSection.rewritten(first, names: ["c.example.com"]))
        XCTAssertEqual(HostsBlockSection.names(in: second), ["c.example.com"])
        XCTAssertEqual(second.components(separatedBy: start).count - 1, 1)
    }

    func testNoNamesRemovesTheSectionAndNothingElse() throws {
        let with = try XCTUnwrap(HostsBlockSection.rewritten(base, names: ["a.example.com"]))
        let without = try XCTUnwrap(HostsBlockSection.rewritten(with, names: []))
        XCTAssertEqual(without, base)
        XCTAssertNil(HostsBlockSection.rewritten(base, names: []), "nothing to remove, nothing to write")
    }

    func testAnUnchangedListWritesNothing() throws {
        let first = try XCTUnwrap(HostsBlockSection.rewritten(base, names: ["a.example.com", "b.example.com"]))
        XCTAssertNil(HostsBlockSection.rewritten(first, names: ["a.example.com", "b.example.com"]))
        XCTAssertNotNil(HostsBlockSection.rewritten(first, names: ["a.example.com"]))
    }

    func testTheAppsPinnedNamesSectionIsLeftAloneAndItsNamesAreNotBlocked() throws {
        let pinned = base + "\n# VPN-BYPASS-MANAGED - START\n203.0.113.7 pinned.example.com\n# VPN-BYPASS-MANAGED - END\n"
        let out = try XCTUnwrap(HostsBlockSection.rewritten(pinned, names: ["pinned.example.com", "ads.example.com"]))
        XCTAssertTrue(out.contains("203.0.113.7 pinned.example.com"))
        XCTAssertEqual(HostsBlockSection.names(in: out), ["ads.example.com"], "a name already mapped keeps its mapping")
        let again = try XCTUnwrap(HostsBlockSection.rewritten(out, names: []))
        XCTAssertTrue(again.contains("# VPN-BYPASS-MANAGED - START"), "removing ours leaves the pinned section")
    }

    func testANameAnotherLineMapsIsNotBlocked() throws {
        let content = base + "10.0.0.5 intranet.example.com wiki.example.com # mine\n"
        let out = try XCTUnwrap(HostsBlockSection.rewritten(content, names: ["wiki.example.com", "ads.example.com"]))
        XCTAssertEqual(HostsBlockSection.names(in: out), ["ads.example.com"])
    }

    func testOnlyValidDistinctLowerCaseNamesAreWritten() throws {
        let out = try XCTUnwrap(HostsBlockSection.rewritten(base, names: [
            "Ads.Example.COM", "ads.example.com", "localhost", "bad name.com", "x.example.com\n127.0.0.1 evil.com", "ok.example.org"]))
        XCTAssertEqual(HostsBlockSection.names(in: out), ["ads.example.com", "ok.example.org"])
        XCTAssertFalse(out.contains("evil.com"))
        XCTAssertFalse(out.contains("127.0.0.1 evil"))
    }

    func testASectionOfOnlyInvalidNamesIsNoSection() {
        XCTAssertNil(HostsBlockSection.rewritten(base, names: ["localhost", "a b"]))
    }

    func testAFileWithoutATrailingNewlineIsHandled() throws {
        let out = try XCTUnwrap(HostsBlockSection.rewritten("127.0.0.1 localhost", names: ["a.example.com"]))
        XCTAssertEqual(out, "127.0.0.1 localhost\n\n\(start)\n0.0.0.0 a.example.com\n\(end)\n")
    }

    func testTwoHundredThousandNamesAreWrittenAndFoundAgainQuickly() throws {
        let names = (0..<200_000).map { "h\($0).t\($0 % 997).example.net" }
        let started = CFAbsoluteTimeGetCurrent()
        let out = try XCTUnwrap(HostsBlockSection.rewritten(base, names: names))
        let wrote = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(HostsBlockSection.names(in: out).count, 200_000)
        XCTAssertNil(HostsBlockSection.rewritten(out, names: names), "the same list is not written again")
        XCTAssertLessThan(wrote, 10, "200,000 names took \(wrote) s")
        XCTAssertLessThan(out.utf8.count, HostsBlockSection.maxBytes)
    }
}

@MainActor
final class HostsBlockLifecycleTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, helper: HelperState, signature: Int?, state: HostsBlockState)!
    private var sent: [[String]] = []
    private var failWrites = false
    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)

    override func setUp() async throws {
        await rm.cancelConfigFollowUps()
        saved = (rm.config, HelperManager.shared.helperState, rm.hostsBlockSignature, rm.hostsBlock)
        sent = []
        failWrites = false
        rm.hostsBlockSignature = nil
        rm.hostsBlockMayExist = false
        rm.hostsBlock = HostsBlockState()
        rm.resetShutdownStateForTests()
        HelperManager.shared.helperState = .ready
        rm.updateBlockedHostsOverrideForTests = { [unowned self] names in
            self.sent.append(names)
            return self.failWrites ? (false, "refused") : (true, nil)
        }
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.manageHostsFile = true
        cfg.routes = [direct, block]
        cfg.defaultRouteId = direct.id
        cfg.rules = [Rule(matchType: .geosite, pattern: "bigads", routeId: block.id, order: 0)]
        rm.config = cfg
        install(["bigads": 10_002])
    }

    override func tearDown() async throws {
        rm.updateBlockedHostsOverrideForTests = nil
        try? FileManager.default.removeItem(at: GeoDataFile.geosite.url)
        GeoDataFile.geosite.invalidate()
        rm.config = saved.config
        HelperManager.shared.helperState = saved.helper
        rm.hostsBlockSignature = saved.signature
        rm.hostsBlockMayExist = false
        rm.hostsBlock = saved.state
        rm.resetShutdownStateForTests()
    }

    /// Puts a geosite file with one list of `count` suffixes in place of the real one.
    private func install(_ lists: [String: Int]) {
        let data = Dat.file(lists.map { name, count in
            Dat.site(name.uppercased(), (0..<count).map { Dat.domain(2, "h\($0).t\($0 % 97).example.net") })
        })
        try? FileManager.default.removeItem(at: GeoDataFile.geosite.url)
        try? data.write(to: GeoDataFile.geosite.url)
        GeoDataFile.geosite.invalidate()
    }

    private var expansions: [String: GeoSiteExpansion] { rm.geositeExpansions() }

    // MARK: - Which names

    func testAListTooLargeForWildcardsGoesToTheHostsFile() {
        let names = RouteManager.hostsBlockNames(config: rm.config, geosite: expansions)
        XCTAssertEqual(names.count, 10_002)
        XCTAssertTrue(WildcardPlanner.configured(rm.config, geosite: expansions).isEmpty, "and gets no wildcard")
    }

    func testAListThatFitsStaysWithTheWildcards() {
        install(["bigads": 9_000])
        XCTAssertTrue(RouteManager.hostsBlockNames(config: rm.config, geosite: expansions).isEmpty)
        XCTAssertEqual(WildcardPlanner.configured(rm.config, geosite: expansions).count, 9_000, "subdomains are covered there")
    }

    func testOnlyTheBlockRouteBlocks() {
        rm.config.rules[0].routeId = direct.id
        XCTAssertTrue(RouteManager.hostsBlockNames(config: rm.config, geosite: expansions).isEmpty)
    }

    func testFirstMatchAnAllowRuleAboveKeepsItsNames() {
        rm.config.rules.insert(Rule(matchType: .domain, pattern: "h5.t5.example.net", routeId: direct.id, order: -1), at: 0)
        rm.config.rules.insert(Rule(matchType: .suffix, pattern: "t7.example.net", routeId: direct.id, order: -2), at: 0)
        let names = Set(RouteManager.hostsBlockNames(config: rm.config, geosite: expansions))
        XCTAssertFalse(names.contains("h5.t5.example.net"), "an earlier exact rule claims it")
        XCTAssertFalse(names.contains("h7.t7.example.net"), "an earlier suffix rule claims what is under it")
        XCTAssertTrue(names.contains("h6.t6.example.net"))
    }

    func testARouteOfAnUnknownTypeBlocksAndClaimsNothing() {
        let unknown = Route(name: "?", egress: .unsupported)
        rm.config.routes.append(unknown)
        rm.config.rules.insert(Rule(matchType: .suffix, pattern: "t7.example.net", routeId: unknown.id, order: -1), at: 0)
        XCTAssertTrue(RouteManager.hostsBlockNames(config: rm.config, geosite: expansions).contains("h7.t7.example.net"),
                      "a rule on a route this build does not know is inert, so it claims nothing")
    }

    func testNothingIsBlockedOutsideCustomMode() {
        rm.config.routingMode = .bypass
        XCTAssertTrue(RouteManager.hostsBlockNames(config: rm.config, geosite: expansions).isEmpty)
    }

    func testAListPastTheHostsSectionsLimitIsLeftOut() {
        let big = GeoSiteExpansion(suffixes: (0...HostsBlockSection.maxNames).map { "h\($0).example.net" })
        XCTAssertTrue(RouteManager.hostsBlockNames(config: rm.config, geosite: ["bigads": big]).isEmpty)
    }

    func testListsThatTogetherPassTheHelpersBudgetAreLeftOutWhole() {
        let a = GeoSiteExpansion(suffixes: (0..<300_000).map { "a\($0).example.net" })
        let b = GeoSiteExpansion(suffixes: (0..<300_000).map { "b\($0).example.net" })
        rm.config.rules = [Rule(matchType: .geosite, pattern: "one", routeId: block.id, order: 0),
                           Rule(matchType: .geosite, pattern: "two", routeId: block.id, order: 1)]
        let names = RouteManager.hostsBlockNames(config: rm.config, geosite: ["one": a, "two": b])
        XCTAssertEqual(names.count, 300_000, "the second list would make the update one the helper refuses")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("a") })
    }

    func testAListOfTenThousandSuffixesAndAnExactNameGoesToTheHostsFile() {
        let list = GeoSiteExpansion(suffixes: (0..<GeoSiteExpansion.maxSuffixes).map { "h\($0).example.net" },
                                    names: ["single.example.org"])
        XCTAssertFalse(list.isTooLarge)
        XCTAssertTrue(list.exceedsWildcards(onBlock: true))
        XCTAssertFalse(list.exceedsWildcards(onBlock: false))
        XCTAssertEqual(RouteManager.hostsBlockNames(config: rm.config, geosite: ["bigads": list]).count, 10_001)
        XCTAssertTrue(WildcardPlanner.configured(rm.config, geosite: ["bigads": list]).isEmpty, "and no wildcard, so no name is lost")
    }

    func testAnExactNameOnBlockClaimsItsSuffixForLaterWildcards() {
        let ads = GeoSiteExpansion(suffixes: [], names: ["ads.example.com"])
        rm.config.rules = [Rule(matchType: .geosite, pattern: "adlist", routeId: block.id, order: 0),
                           Rule(matchType: .suffix, pattern: "x.ads.example.com", routeId: direct.id, order: 1)]
        let specs = WildcardPlanner.configured(rm.config, geosite: ["adlist": ads])
        XCTAssertTrue(specs.contains { $0.suffix == "ads.example.com" })
        XCTAssertFalse(specs.contains { $0.suffix == "x.ads.example.com" }, "the block above decides first")
    }

    func testAddressesTheMacNeedsAreNotBlocked() {
        let protected = ["9.9.9.9", "1.1.1.1", "not an address"]
        XCTAssertTrue(RouteManager.address(in: protected, isCoveredBy: "9.9.9.0/24"))
        XCTAssertTrue(RouteManager.address(in: protected, isCoveredBy: "9.9.9.9"))
        XCTAssertFalse(RouteManager.address(in: protected, isCoveredBy: "8.8.8.0/24"))
    }

    // MARK: - Writing them

    func testAnApplySendsTheListOnceAndAnUnchangedListNotAgain() async {
        await rm.applyHostsBlocks()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].count, 10_002)
        XCTAssertEqual(rm.hostsBlock, HostsBlockState(count: 10_002, error: nil, needsHostsFile: false))
        await rm.applyHostsBlocks()
        XCTAssertEqual(sent.count, 1, "the same names are not sent again")
    }

    func testChangingTheListSendsTheNewOne() async {
        await rm.applyHostsBlocks()
        install(["bigads": 10_005])
        await rm.applyHostsBlocks()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].count, 10_005)
    }

    func testWithPinningOffNothingIsWrittenAndTheRowSaysWhy() async {
        rm.config.manageHostsFile = false
        await rm.applyHostsBlocks()
        XCTAssertTrue(sent.isEmpty, "the setting that lets the app write /etc/hosts is off")
        XCTAssertEqual(rm.hostsBlock, HostsBlockState(count: 0, error: nil, needsHostsFile: true))
    }

    func testTurningPinningOffTakesTheWrittenNamesBack() async {
        await rm.applyHostsBlocks()
        rm.config.manageHostsFile = false
        await rm.applyHostsBlocks()
        XCTAssertEqual(sent.last, [], "the names the app wrote are removed when it may no longer write")
        XCTAssertNil(rm.hostsBlockSignature)
    }

    func testAFailedWriteIsRecordedAndTriedAgain() async {
        failWrites = true
        await rm.applyHostsBlocks()
        XCTAssertEqual(rm.hostsBlock.error, "refused")
        XCTAssertEqual(rm.hostsBlock.count, 0)
        failWrites = false
        await rm.applyHostsBlocks()
        XCTAssertEqual(sent.count, 2, "the next apply tries again")
        XCTAssertNil(rm.hostsBlock.error)
        XCTAssertEqual(rm.hostsBlock.count, 10_002)
    }

    func testAFailedReplacementStillOwnsTheSectionForCleanup() async {
        await rm.applyHostsBlocks()
        install(["bigads": 10_003])
        failWrites = true
        await rm.applyHostsBlocks()
        XCTAssertNil(rm.hostsBlockSignature)
        failWrites = false
        rm.config.rules = []
        await rm.removeAllRoutes()
        XCTAssertEqual(sent.last, [], "the earlier section is still taken out")
        XCTAssertFalse(rm.hostsBlockMayExist)
    }

    func testTheRuleGoneTheNamesGo() async {
        await rm.applyHostsBlocks()
        rm.config.rules = []
        await rm.applyHostsBlocks()
        XCTAssertEqual(sent.last, [])
        XCTAssertEqual(rm.hostsBlock, HostsBlockState())
    }

    func testRemoveAllRoutesTakesTheNamesOutToo() async {
        await rm.applyHostsBlocks()
        await rm.removeAllRoutes()
        XCTAssertEqual(sent.last, [], "a mode switch, a pause, Remove All Routes or a quit leaves none behind")
        XCTAssertNil(rm.hostsBlockSignature)
    }

    func testAVPNDropKeepsTheNames() async {
        await rm.applyHostsBlocks()
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        XCTAssertEqual(sent.count, 1, "a block is a block whether the VPN is up or not")
        XCTAssertNotNil(rm.hostsBlockSignature)
    }

    func testNothingIsWrittenWithoutTheHelper() async {
        rm.updateBlockedHostsOverrideForTests = nil
        HelperManager.shared.helperState = .missing
        await rm.applyHostsBlocks()
        XCTAssertNil(rm.hostsBlockSignature)
    }

    func testTheRowSaysWhatTheHostsFileHolds() {
        let list = GeoSiteExpansion(suffixes: (0..<10_002).map { "h\($0).example.net" })
        XCTAssertEqual(GeoDisplay.hostsDetail(count: list.count, manageHosts: false, state: HostsBlockState(needsHostsFile: true)),
                       String(localized: "Turn on “Pin listed names in /etc/hosts” in General to block this list."))
        XCTAssertEqual(GeoDisplay.hostsDetail(count: list.count, manageHosts: true, state: HostsBlockState(count: 0, error: "refused")),
                       String(localized: "Could not write /etc/hosts: refused"))
        XCTAssertEqual(GeoDisplay.hostsDetail(count: list.count, manageHosts: true, state: HostsBlockState()), "Not blocked yet.")
        XCTAssertEqual(GeoDisplay.hostsDetail(count: list.count, manageHosts: true, state: HostsBlockState(count: 10_002)),
                       String(localized: "\(10_002) names blocked in /etc/hosts. Subdomains are not covered."))
    }
}
