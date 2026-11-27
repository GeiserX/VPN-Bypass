// HostsListTests.swift
// Hosts-format blocklists: the parser, the store that keeps the last good copy, and the planner that
// decides which names the list rules block. Every body here is a small fixture; no test fetches a list.

import XCTest
@testable import VPNBypassCore

final class HostsListParserTests: XCTestCase {

    private func parse(_ text: String, skipping: Set<String> = []) -> Result<HostsList.Parsed, HostsList.Refusal> {
        HostsList.parse(Data(text.utf8), skipping: skipping)
    }

    private func names(_ text: String, skipping: Set<String> = []) -> [String]? {
        guard case .success(let parsed) = parse(text, skipping: skipping) else { return nil }
        return parsed.names
    }

    /// StevenBlack's header maps the local host's own names, and its first row is `0.0.0.0 0.0.0.0`.
    /// None of them is a name to block.
    func testTheLocalRowsOfAStevenBlackHeaderAreDropped() {
        let body = """
        # Title: StevenBlack/hosts
        127.0.0.1 localhost
        127.0.0.1 localhost.localdomain
        127.0.0.1 local
        255.255.255.255 broadcasthost
        ::1 localhost
        ::1 ip6-localhost
        ::1 ip6-loopback
        fe80::1%lo0 localhost
        ff00::0 ip6-localnet
        ff02::1 ip6-allnodes
        0.0.0.0 0.0.0.0

        # Custom host records are listed here.
        0.0.0.0 ads.example.com
        0.0.0.0 tracker.example.net
        """
        XCTAssertEqual(names(body), ["ads.example.com", "tracker.example.net"])
    }

    func testSeveralNamesOnOneLineAreAllKept() {
        XCTAssertEqual(names("0.0.0.0 a.com 0ad.com"), ["a.com", "0ad.com"])
    }

    /// A list may only blackhole a name, never send it somewhere.
    func testARowThatRedirectsANameIsSkippedAndCounted() throws {
        guard case .success(let parsed) = parse("1.2.3.4 bank.com\n0.0.0.0 ads.example.com\n") else {
            return XCTFail("the body was refused")
        }
        XCTAssertEqual(parsed.names, ["ads.example.com"])
        XCTAssertEqual(parsed.redirects, 1)
    }

    func testEveryBlackholeAddressIsAccepted() {
        let body = "0.0.0.0 a.example.com\n127.0.0.1 b.example.com\n:: c.example.com\n::1 d.example.com\n0 e.example.com\n"
        XCTAssertEqual(names(body), ["a.example.com", "b.example.com", "c.example.com", "d.example.com", "e.example.com"])
    }

    func testAnInlineCommentEndsTheLine() {
        XCTAssertEqual(names("0.0.0.0 ads.example.com # not.this.one\n0.0.0.0 x.example.com#nor.this\n"),
                       ["ads.example.com", "x.example.com"])
    }

    /// Names that are not valid, are local, or are the host the list comes from are skipped; the
    /// rest of the line is still read.
    func testNamesTheMacNeedsOrThatAreNotNamesAreSkipped() {
        let body = """
        0.0.0.0 printer.local 4.3.2.1.in-addr.arpa app.localhost raw.example.org kept.example.com
        0.0.0.0 single tld. bad_label-.example.com caf\u{E9}.example.com 10.0.0.1 also.example.com
        """
        XCTAssertEqual(names(body, skipping: ["raw.example.org"]), ["kept.example.com", "also.example.com"])
    }

    func testNamesAreLowerCasedAndKeptOnce() {
        XCTAssertEqual(names("0.0.0.0 Ads.Example.COM.\n0.0.0.0 ads.example.com\n"), ["ads.example.com"])
    }

    func testALineOverTheLimitIsSkipped() throws {
        let long = "0.0.0.0 " + String(repeating: "a", count: 60) + ".example.com" + String(repeating: " x.example.com", count: 80)
        XCTAssertGreaterThan(long.utf8.count, HostsList.maxLineBytes)
        let body = (0..<5).map { "0.0.0.0 n\($0).example.com" }.joined(separator: "\n") + "\n" + long + "\n"
        guard case .success(let parsed) = parse(body) else { return XCTFail("the body was refused") }
        XCTAssertEqual(parsed.longLines, 1)
        XCTAssertEqual(parsed.names.count, 5)
        XCTAssertFalse(parsed.names.contains("x.example.com"))
    }

    func testCRLFLinesAreRead() {
        XCTAssertEqual(names("0.0.0.0 a.example.com\r\n0.0.0.0 b.example.com\r\n"), ["a.example.com", "b.example.com"])
    }

    /// An error page is refused whole, with its own reason.
    func testAWebPageIsRefused() {
        let body = "\n  <!DOCTYPE html>\n<html><body><h1>503 Service Unavailable</h1>\n0.0.0.0 ads.example.com\n</body></html>\n"
        XCTAssertEqual(parse(body), .failure(.webPage))
    }

    /// An adblock list means "the name and everything under it", which a hosts line cannot say.
    func testAnAdblockListIsRefused() {
        let body = "! Title: filter\n||ads.example.com^\n||tracker.example.net^\n||x.example.org^\n0.0.0.0 one.example.com\n"
        XCTAssertEqual(parse(body), .failure(.notHostsFormat))
    }

    /// A bare-domain list means the same as an adblock one in the tools that read it.
    func testABareDomainListIsRefused() {
        let body = "# domains\nads.example.com\ntracker.example.net\nx.example.org\n"
        XCTAssertEqual(parse(body), .failure(.notHostsFormat))
    }

    func testHalfHostsRowsIsStillAHostsFile() {
        XCTAssertEqual(names("0.0.0.0 a.example.com\nstray-line\n"), ["a.example.com"])
    }

    func testTheRefusalsSayDifferentThings() {
        XCTAssertNotEqual(HostsList.Refusal.webPage.message, HostsList.Refusal.notHostsFormat.message)
    }
}

@MainActor
final class ListStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ListStore!
    private let source = URL(string: "https://lists.example.org/hosts")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lists-\(UUID().uuidString)")
        store = ListStore(directory: directory)
    }

    override func tearDown() async throws {
        StubGeoServer.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func hosts(_ count: Int, prefix: String = "n") -> Data {
        Data(((0..<count).map { "0.0.0.0 \(prefix)\($0).example.com" }.joined(separator: "\n") + "\n").utf8)
    }

    private func serve(_ data: Data) -> (URL) async throws -> URL {
        { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try data.write(to: file)
            return file
        }
    }

    func testAGoodCopyIsSavedOwnerOnlyWithItsStatus() async throws {
        store.fetch = serve(hosts(10))
        let saved = await store.update(from: source)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.files.names(for: source)?.count, 10)
        let mode = try FileManager.default.attributesOfItem(atPath: store.files.fileURL(for: source).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let status = try XCTUnwrap(store.status(for: source))
        XCTAssertEqual(status.names, 10)
        XCTAssertNotNil(status.updated)
        XCTAssertNil(status.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.fileURL(for: source).path + ".partial"))
    }

    /// A copy that lost most of its names is a broken build or a truncated mirror: the last good one stays.
    func testACopyThatShrankByEightyPercentKeepsTheOldOne() async throws {
        store.fetch = serve(hosts(100))
        _ = await store.update(from: source)
        let before = try Data(contentsOf: store.files.fileURL(for: source))

        store.fetch = serve(hosts(20, prefix: "m"))
        let replaced = await store.update(from: source)
        XCTAssertFalse(replaced, "a copy with 20% of the names replaced the copy in use")
        XCTAssertEqual(try Data(contentsOf: store.files.fileURL(for: source)), before)
        XCTAssertEqual(store.files.names(for: source)?.count, 100)
        let status = try XCTUnwrap(store.status(for: source))
        XCTAssertEqual(status.names, 100, "the status still counts the copy in use")
        XCTAssertNotNil(status.error)

        // Half is still the same list.
        store.fetch = serve(hosts(50, prefix: "h"))
        let half = await store.update(from: source)
        XCTAssertTrue(half)
    }

    /// A first copy with no names is refused too, though there is no last good copy to compare with.
    func testAFirstCopyWithNoNamesIsNotSaved() async {
        store.fetch = serve(Data("# nothing here\n127.0.0.1 localhost\n".utf8))
        let saved = await store.update(from: source)
        XCTAssertFalse(saved)
        XCTAssertNil(store.files.names(for: source))
        XCTAssertEqual(store.status(for: source)?.error, String(localized: "The list holds no names to block."))
    }

    func testABodyThatIsNotAHostsFileOrHasNoNamesKeepsTheOldOne() async throws {
        store.fetch = serve(hosts(10))
        _ = await store.update(from: source)

        store.fetch = serve(Data("<html>503</html>".utf8))
        let page = await store.update(from: source)
        XCTAssertFalse(page)
        XCTAssertEqual(store.status(for: source)?.error, HostsList.Refusal.webPage.message)

        store.fetch = serve(Data("# nothing here\n0.0.0.0 localhost\n".utf8))
        let empty = await store.update(from: source)
        XCTAssertFalse(empty)
        XCTAssertEqual(store.files.names(for: source)?.count, 10)
    }

    /// A response that is not HTTP 200 never replaces the copy in use. Goes through the real downloader.
    func testAResponseThatIsNotHTTP200KeepsTheOldOne() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubGeoServer.self]
        let store = ListStore(directory: directory, configuration: configuration)
        let good = hosts(10)
        StubGeoServer.handler = { server in
            server.respond(status: 200, length: good.count)
            server.send(good)
            server.finish()
        }
        let first = await store.update(from: source)
        XCTAssertTrue(first)

        StubGeoServer.handler = { server in
            let body = Data((0..<10).map { "0.0.0.0 other\($0).example.com\n" }.joined().utf8)
            server.respond(status: 503, length: body.count)
            server.send(body)
            server.finish()
        }
        let second = await store.update(from: source)
        XCTAssertFalse(second)
        XCTAssertEqual(store.files.names(for: source)?.first, "n0.example.com")
        XCTAssertEqual(store.status(for: source)?.error, String(localized: "The server answered HTTP \(503), not the list."))
    }

    /// The download stops at 16 MB, through the real downloader with the store's own limit.
    func testADownloadOverTheByteCapIsStopped() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubGeoServer.self]
        let store = ListStore(directory: directory, configuration: configuration)
        StubGeoServer.handler = { server in
            server.respond(length: ListStore.maxDownloadBytes + 1)
            server.send(Data(repeating: 0x30, count: 4_096))
            DispatchQueue.global().async { Thread.sleep(forTimeInterval: 0.3); server.finish() }
        }
        let saved = await store.update(from: source)
        XCTAssertFalse(saved)
        XCTAssertNil(store.files.names(for: source))
        XCTAssertEqual(store.status(for: source)?.error, String(localized: "The download is larger than a list can be."))
        XCTAssertEqual(ListStore.maxDownloadBytes, 16 * 1024 * 1024)
    }

    /// The lists follow the GeoSite schedule: a missing copy is due, a fresh one is not, and a failed try
    /// waits an hour.
    func testTheScheduleAndTheRetryWaitDecideWhatIsDue() async throws {
        let now = Date()
        XCTAssertEqual(store.dueSources([source], schedule: .weekly, now: now), [source])
        XCTAssertEqual(store.dueSources([source], schedule: .off, now: now), [])

        store.fetch = { _ in throw URLError(.timedOut) }
        _ = await store.update(from: source)
        XCTAssertEqual(store.dueSources([source], schedule: .weekly, now: Date()), [], "a failed try is retried at once")
        XCTAssertEqual(store.dueSources([source], schedule: .weekly, now: Date().addingTimeInterval(GeoSyncPlan.retryAfter + 1)), [source])

        store.fetch = serve(hosts(5))
        _ = await store.update(from: source)
        let later = Date().addingTimeInterval(GeoSyncPlan.retryAfter + 1)
        XCTAssertEqual(store.dueSources([source], schedule: .weekly, now: later), [])
        XCTAssertEqual(store.dueSources([source], schedule: .daily, now: Date().addingTimeInterval(25 * 3600)), [source])
    }
}

final class HostsBlockPlannerTests: XCTestCase {

    private let listA = "https://lists.example.org/a"
    private let listB = "https://lists.example.org/b"
    private let block = Route(id: Route.rulesPageBlockId, name: Route.blockName, egress: .block)
    private let direct = Route(name: "Direct", egress: .direct)

    private func config(_ rules: [Rule]) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [block, direct]
        c.rules = rules
        return c
    }

    private func rule(_ type: MatchType, _ pattern: String, _ route: Route, _ order: Int) -> Rule {
        Rule(matchType: type, pattern: pattern, routeId: route.id, order: order)
    }

    /// A rule above a list is how a name is unblocked; the same rule below it does not unblock it.
    func testARuleAboveTheListRemovesItsNameAndOneBelowDoesNot() {
        let lists = [listA: ["ads.example.com", "keep.example.com"]]
        let above = HostsBlockPlanner.plan(config([
            rule(.domain, "keep.example.com", direct, 0),
            rule(.list, listA, block, 1),
        ]), lists: lists, geosite: [:])
        XCTAssertEqual(above.names, ["ads.example.com"])

        let below = HostsBlockPlanner.plan(config([
            rule(.list, listA, block, 0),
            rule(.domain, "keep.example.com", direct, 1),
        ]), lists: lists, geosite: [:])
        XCTAssertEqual(below.names, ["ads.example.com", "keep.example.com"])
    }

    func testASuffixAboveTheListRemovesTheNamesUnderIt() {
        let plan = HostsBlockPlanner.plan(config([
            rule(.suffix, "*.cdn.example.com", direct, 0),
            rule(.list, listA, block, 1),
        ]), lists: [listA: ["a.cdn.example.com", "cdn.example.com", "ads.example.com"]], geosite: [:])
        XCTAssertEqual(plan.names, ["ads.example.com"])
    }

    /// Three names in all, so a cap of 3 holds both lists only if the shared name counts once.
    func testTwoListsSharingNamesCountEachNameOnce() {
        let first = rule(.list, listA, block, 0)
        let second = rule(.list, listB, block, 1)
        let plan = HostsBlockPlanner.plan(config([first, second]),
                                          lists: [listA: ["a.example.com", "b.example.com"], listB: ["b.example.com", "c.example.com"]],
                                          geosite: [:], limit: 3)
        XCTAssertEqual(plan.names, ["a.example.com", "b.example.com", "c.example.com"])
        XCTAssertEqual(plan.accepted, [first.id: 2, second.id: 1])
        XCTAssertTrue(plan.refused.isEmpty)
    }

    /// A list over the cap blocks nothing rather than a part of itself, and says why.
    func testAListOverTheCapIsRefusedWhole() {
        let big = rule(.list, listA, block, 0)
        let plan = HostsBlockPlanner.plan(config([big]),
                                          lists: [listA: ["a.example.com", "b.example.com", "c.example.com"]],
                                          geosite: [:], limit: 2)
        XCTAssertEqual(plan.names, [])
        XCTAssertEqual(plan.refused[big.id], .tooLarge(names: 3, limit: 2))

        let small = rule(.list, listB, block, 0)
        let second = rule(.list, listA, block, 1)
        let together = HostsBlockPlanner.plan(config([small, second]),
                                              lists: [listB: ["x.example.com"], listA: ["a.example.com", "b.example.com"]],
                                              geosite: [:], limit: 2)
        XCTAssertEqual(together.names, ["x.example.com"])
        XCTAssertEqual(together.refused[second.id], .overTotal(names: 2, limit: 2))
    }

    func testTheCapIsOneHundredThousandNames() {
        XCTAssertEqual(HostsBlockPlanner.maxNames, 100_000)
    }

    func testAListRuleOnARouteOtherThanBlockIsInactive() {
        let onDirect = rule(.list, listA, direct, 0)
        let plan = HostsBlockPlanner.plan(config([onDirect]), lists: [listA: ["a.example.com"]], geosite: [:])
        XCTAssertEqual(plan.names, [])
        XCTAssertEqual(plan.inactive[onDirect.id], .notBlockRoute)
    }

    func testOutsideCustomModeNothingIsBlocked() {
        var c = config([rule(.list, listA, block, 0)])
        c.routingMode = .bypass
        let plan = HostsBlockPlanner.plan(c, lists: [listA: ["a.example.com"]], geosite: [:])
        XCTAssertEqual(plan.names, [])
        XCTAssertEqual(plan.inactive.values.first, .notCustomMode)
    }

    /// No list may block a host the app downloads its lists from: it would stop the update that could undo it.
    func testTheHostsTheAppDownloadsFromAreNeverBlocked() {
        let plan = HostsBlockPlanner.plan(config([rule(.list, listA, block, 0)]),
                                          lists: [listA: ["lists.example.org", "github.com", "ads.example.com"]],
                                          geosite: [:])
        XCTAssertEqual(plan.names, ["ads.example.com"])
    }

    /// Older configs never held a list rule, and one written by this build round-trips.
    func testAListRuleRoundTripsThroughTheConfig() throws {
        let original = rule(.list, listA, block, 3)
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.matchType, .list)
    }
}
