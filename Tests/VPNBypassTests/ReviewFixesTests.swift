// ReviewFixesTests.swift
// What review found in the GeoIP, GeoSite and Block work, each as a test: a download that is not a whole
// list never replaces the good copy, a country is never cut short, the size limit holds while a
// download runs, a source chosen mid-download wins, a failed download is tried again, a name sent to
// Block is never looked up, a route this build does not know claims nothing, a suffix moved to Block
// keeps no learned routes, a blackhole leaves another resolver's names to it, Everything else is never
// Block, a row keeps its route's warning beside a count, a newer version's rule keeps all its fields,
// and the site check does not look past a block.

import XCTest
@testable import VPNBypassCore

// MARK: - The data files

final class GeoDatCompleteParseTests: XCTestCase {

    private func cut(_ pieces: [[UInt8]], isUsable: (Data) -> Bool, line: UInt = #line) {
        let whole = Data(pieces.flatMap { $0 })
        var boundaries: Set<Int> = [0]
        var total = 0
        for piece in pieces { total += piece.count; boundaries.insert(total) }
        for length in 1..<whole.count where !boundaries.contains(length) {
            XCTAssertFalse(isUsable(whole.prefix(length)), "a file cut at \(length) of \(whole.count) is not a list", line: line)
        }
        XCTAssertTrue(isUsable(whole), line: line)
    }

    func testAGeoIPFileCutMidEntryIsNotUsable() {
        cut([Dat.entry("IR", [Dat.cidr([203, 0, 113, 0], 24)]), Dat.entry("RU", [Dat.cidr([198, 51, 100, 0], 24)])],
            isUsable: GeoIPDat.isUsable)
    }

    func testAGeoSiteFileCutMidEntryIsNotUsable() {
        cut([Dat.site("GAMES", [Dat.domain(2, "steampowered.com")]), Dat.site("MS", [Dat.domain(2, "microsoft.com"), Dat.domain(3, "login.live.com")])],
            isUsable: GeoSiteDat.isUsable)
    }

    func testACompleteFirstEntryFollowedByATruncatedSecondIsRefused() {
        let first = Dat.entry("IR", [Dat.cidr([203, 0, 113, 0], 24)])
        let second = Dat.entry("RU", [Dat.cidr([198, 51, 100, 0], 24)])
        XCTAssertTrue(GeoIPDat.isUsable(Data(first)), "a shorter file that ends between entries is a whole file")
        XCTAssertFalse(GeoIPDat.isUsable(Data(first + second.dropLast(3))), "the first entry must not vouch for a cut second")
    }

    func testALengthThatRunsPastTheEndAndAVarintWithNoEndAreRefused() {
        let good = Dat.entry("IR", [Dat.cidr([203, 0, 113, 0], 24)])
        XCTAssertFalse(GeoIPDat.isUsable(Data(good + [0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F])))
        XCTAssertFalse(GeoIPDat.isUsable(Data(good + [0x0A] + Array(repeating: 0xFF, count: 12))))
        XCTAssertFalse(GeoSiteDat.isUsable(Data(Dat.site("A", [Dat.domain(2, "x.example.com")]) + [0x08, 0x80])))
    }

    func testTheRealFilesAreStillUsableWhole() {
        XCTAssertTrue(GeoIPDat.isUsable(Dat.sample))
        XCTAssertTrue(GeoSiteDat.isUsable(Dat.sites))
    }
}

@MainActor
final class GeoCountryRangesTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: RouteManager.Config!

    override func setUp() async throws { saved = rm.config }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: GeoDataFile.geoip.url)
        GeoDataFile.geoip.invalidate()
        rm.config = saved
    }

    private func ranges(_ count: Int) -> [[UInt8]] {
        var result: [[UInt8]] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let first: UInt8 = UInt8(10 + i / 65_536)
            let second: UInt8 = UInt8((i / 256) % 256)
            let third: UInt8 = UInt8(i % 256)
            let ip: [UInt8] = [first, second, third, 0]
            result.append(Dat.cidr(ip, 24))
        }
        return result
    }

    private func install(_ code: String, _ count: Int) throws {
        try Dat.file([Dat.entry(code, ranges(count))]).write(to: GeoDataFile.geoip.url)
        GeoDataFile.geoip.invalidate()
    }

    func testACountryOverThirtyThousandRangesIsReadWhole() throws {
        try install("DE", 30_200)
        XCTAssertEqual(GeoDataFile.geoip.ranges(for: ["de"])["de"]?.count, 30_200, "no range is dropped")
        XCTAssertEqual(GeoDataFile.geoip.countries()["de"], 30_200)
    }

    func testACountryThatFitsIsRouted() throws {
        try install("DE", 30_200)
        rm.config.rules = [Rule(matchType: .geoip, pattern: "de", routeId: UUID(), order: 0)]
        XCTAssertEqual(rm.geoipRanges()["de"]?.count, 30_200)
    }

    func testACountryOverTheLimitRoutesNothingAndSaysSo() throws {
        let over = GeoDataFile.maxRangesPerCountry + 1
        try install("US", over)
        rm.config.rules = [Rule(matchType: .geoip, pattern: "us", routeId: UUID(), order: 0)]
        XCTAssertNil(rm.geoipRanges()["us"], "never a part of a country")
        XCTAssertEqual(GeoDisplay.detail(count: over, hasData: true),
                       String(localized: "Too large to route: \(over) ranges, the limit is \(GeoDataFile.maxRangesPerCountry)."))
        XCTAssertEqual(GeoDisplay.detail(count: GeoDataFile.maxRangesPerCountry, hasData: true),
                       String(localized: "\(GeoDataFile.maxRangesPerCountry) ranges"))
    }
}

// MARK: - Downloads

@MainActor
final class GeoStoreSafetyTests: XCTestCase {

    private var directory: URL!
    private var store: GeoDataStore!
    private let a = URL(string: "https://a.example/geoip.dat")!
    private let b = URL(string: "https://b.example/geoip.dat")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("geo-safety-\(UUID().uuidString)")
        store = GeoDataStore(kind: .ip, directory: directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func list(_ code: String, _ octet: UInt8) -> Data {
        Dat.file([Dat.entry(code, [Dat.cidr([octet, 0, 0, 0], 8)])])
    }

    private func serve(_ data: Data) -> (URL) async throws -> URL {
        { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try data.write(to: file)
            return file
        }
    }

    func testAFailedSaveLeavesTheLastGoodCopyInPlace() async throws {
        store.fetch = serve(list("IR", 11))
        let first = await store.update(from: a)
        XCTAssertTrue(first)
        // The folder can no longer be written: the staged copy cannot be made.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        store.fetch = serve(list("RU", 12))
        let second = await store.update(from: a)
        XCTAssertFalse(second)
        XCTAssertEqual(store.phase, .failed("Could not save the list."))
        XCTAssertEqual(store.file.ranges(for: ["ir"])["ir"], ["11.0.0.0/8"], "the copy in use is untouched, not deleted first")
        XCTAssertNil(store.file.ranges(for: ["ru"])["ru"])
    }

    func testAFirstInstallThatCannotBeSavedLeavesNothing() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        store.fetch = serve(list("IR", 11))
        let saved = await store.update(from: a)
        XCTAssertFalse(saved)
        XCTAssertFalse(store.hasData)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path + ".partial"), "no staged file is left behind")
    }

    func testASourceChosenWhileADownloadRunsWins() async {
        var calls: [URL] = []
        var gate: CheckedContinuation<Void, Never>?
        store.fetch = { [unowned self] url in
            calls.append(url)
            if url == self.a { await withCheckedContinuation { gate = $0 } }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try (url == self.a ? self.list("RU", 12) : self.list("IR", 11)).write(to: file)
            return file
        }
        let first = Task { await store.update(from: a) }
        while gate == nil { await Task.yield() }
        let queued = await store.update(from: b)
        XCTAssertFalse(queued, "the call that finds one running returns at once")
        gate?.resume()
        let result = await first.value
        XCTAssertTrue(result)
        XCTAssertEqual(calls, [a, b], "the first source's list was dropped and the chosen one fetched")
        XCTAssertEqual(store.file.ranges(for: ["ir"])["ir"], ["11.0.0.0/8"])
        XCTAssertNil(store.file.ranges(for: ["ru"])["ru"], "the list of the source no longer wanted was not installed")
        XCTAssertEqual(store.phase, .idle)
    }

    func testChoosingTheRunningSourceAgainCancelsTheQueuedOne() async {
        var calls: [URL] = []
        var gate: CheckedContinuation<Void, Never>?
        store.fetch = { [unowned self] url in
            calls.append(url)
            if url == self.a { await withCheckedContinuation { gate = $0 } }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try self.list("RU", 12).write(to: file)
            return file
        }
        let first = Task { await store.update(from: a) }
        while gate == nil { await Task.yield() }
        _ = await store.update(from: b)
        _ = await store.update(from: a)
        gate?.resume()
        _ = await first.value
        XCTAssertEqual(calls, [a], "the last choice was A, so B is never fetched")
        XCTAssertEqual(store.file.ranges(for: ["ru"])["ru"], ["12.0.0.0/8"])
    }

    func testAFailureIsReportedAndTheStoreCanTryAgain() async {
        store.fetch = { _ in throw URLError(.timedOut) }
        let failed = await store.update(from: a)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.phase, .failed("Could not download the list."))
        store.fetch = serve(list("IR", 11))
        let again = await store.update(from: a)
        XCTAssertTrue(again)
        XCTAssertEqual(store.phase, .idle)
    }

    func testADownloadThatIsTooLargeIsReportedAsThat() async {
        store.fetch = { _ in throw GeoDownloadError.tooLarge }
        let result = await store.update(from: a)
        XCTAssertFalse(result)
        XCTAssertEqual(store.phase, .failed("The download is larger than a list can be."))
    }
}

/// A canned HTTP server for `GeoDownloader`: what `handler` sends is what the session receives.
final class StubGeoServer: URLProtocol {
    nonisolated(unsafe) static var handler: ((StubGeoServer) -> Void)?
    nonisolated(unsafe) static var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.stopped = false; Self.handler?(self) }
    override func stopLoading() { Self.stopped = true }

    func respond(status: Int = 200, length: Int? = nil) {
        var headers: [String: String] = [:]
        if let length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    func send(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func finish() { client?.urlProtocolDidFinishLoading(self) }
}

final class GeoDownloaderTests: XCTestCase {

    private let url = URL(string: "https://stub.example/geoip.dat")!

    private func downloader(limit: Int) -> GeoDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubGeoServer.self]
        return GeoDownloader(limit: limit, configuration: configuration)
    }

    override func tearDown() { StubGeoServer.handler = nil }

    func testASmallResponseIsSavedToAFile() async throws {
        StubGeoServer.handler = { server in
            server.respond(length: 5)
            server.send(Data("hello".utf8))
            server.finish()
        }
        let file = try await downloader(limit: 1_000).fetch(url)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    }

    func testAResponseThatSaysItIsTooLargeIsStoppedAtOnce() async {
        StubGeoServer.handler = { server in
            server.respond(length: 50_000_000)
            server.send(Data(repeating: 1, count: 4_096))
            // The server would go on; the downloader must not.
            DispatchQueue.global().async { Thread.sleep(forTimeInterval: 0.3); server.finish() }
        }
        do {
            _ = try await downloader(limit: 1_000_000).fetch(url)
            XCTFail("a 50 MB response was accepted under a 1 MB limit")
        } catch {
            XCTAssertEqual(error as? GeoDownloadError, .tooLarge)
        }
    }

    func testAResponseThatNeverSaysItsLengthIsStoppedWhenItPassesTheLimit() async {
        let sent = Counter()
        StubGeoServer.handler = { server in
            server.respond()
            DispatchQueue.global().async {
                for _ in 0..<40 {
                    if StubGeoServer.stopped { return }
                    server.send(Data(repeating: 1, count: 100_000))
                    sent.add()
                    Thread.sleep(forTimeInterval: 0.02)
                }
                server.finish()
            }
        }
        do {
            _ = try await downloader(limit: 300_000).fetch(url)
            XCTFail("4 MB were accepted under a 300 KB limit")
        } catch {
            XCTAssertEqual(error as? GeoDownloadError, .tooLarge)
        }
        XCTAssertLessThan(sent.value, 40, "the transfer was cut, not read to the end")
    }

    func testAnErrorStatusIsAnError() async {
        StubGeoServer.handler = { server in
            server.respond(status: 404, length: 3)
            server.send(Data("no!".utf8))
            server.finish()
        }
        do {
            _ = try await downloader(limit: 1_000).fetch(url)
            XCTFail("a 404 was taken for a list")
        } catch {
            XCTAssertEqual(error as? GeoDownloadError, .badResponse(404))
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}

// MARK: - A failed download is tried again; an import fetches

@MainActor
final class GeoRetryTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, auto: Bool, wait: TimeInterval, fetch: (URL) async throws -> URL)!
    private var attempts = 0

    override func setUp() async throws {
        saved = (rm.config, GeoDataStore.autoUpdate, GeoSyncPlan.retryAfter, GeoDataStore.geoip.fetch)
        attempts = 0
        try? FileManager.default.removeItem(at: GeoDataFile.geoip.url)
        GeoDataFile.geoip.invalidate()
        GeoDataStore.autoUpdate = true
        GeoSyncPlan.retryAfter = 0.05
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        let direct = Route(name: "Direct", egress: .direct)
        cfg.routes = [direct]
        cfg.defaultRouteId = direct.id
        cfg.rules = [Rule(matchType: .geoip, pattern: "ir", routeId: direct.id, order: 0)]
        cfg.geoSync = .weekly
        rm.config = cfg
    }

    override func tearDown() async throws {
        for task in rm.geoRetryTasks.values { task.cancel() }
        rm.geoRetryTasks = [:]
        GeoDataStore.autoUpdate = saved.auto
        GeoSyncPlan.retryAfter = saved.wait
        GeoDataStore.geoip.fetch = saved.fetch
        try? FileManager.default.removeItem(at: GeoDataFile.geoip.url)
        GeoDataFile.geoip.invalidate()
        await rm.cancelConfigFollowUps()
        rm.config = saved.config
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testAFailedDownloadIsTriedAgainOnItsOwn() async {
        GeoDataStore.geoip.fetch = { [unowned self] _ in
            self.attempts += 1
            if self.attempts == 1 { throw URLError(.notConnectedToInternet) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Dat.sample.write(to: file)
            return file
        }
        rm.refreshGeoDataIfNeeded()
        await waitUntil { GeoDataStore.geoip.hasData }
        XCTAssertTrue(GeoDataStore.geoip.hasData, "nothing else would have fetched it before the next launch")
        XCTAssertEqual(attempts, 2)
    }

    func testNoRetryIsScheduledWhenNothingNeedsTheList() async {
        rm.config.rules = []
        GeoDataStore.geoip.fetch = { [unowned self] _ in self.attempts += 1; throw URLError(.timedOut) }
        _ = await rm.updateGeoData(.ip)
        XCTAssertTrue(rm.geoRetryTasks.isEmpty)
    }

    func testNoRetryIsScheduledWithSyncOff() async {
        rm.config.geoSync = .off
        GeoDataStore.geoip.fetch = { _ in throw URLError(.timedOut) }
        _ = await rm.updateGeoData(.ip)
        XCTAssertTrue(rm.geoRetryTasks.isEmpty)
    }

    func testAnImportThatBringsAGeoRuleFetchesItsList() async throws {
        GeoDataStore.geoip.fetch = { [unowned self] _ in
            self.attempts += 1
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Dat.sample.write(to: file)
            return file
        }
        let source = rm.config
        let data = try JSONEncoder().encode(RouteManager.ExportData(version: "1", exportDate: Date(), config: source))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).json")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        rm.config.rules = []
        _ = rm.importConfig(from: file)
        await waitUntil { GeoDataStore.geoip.hasData }
        XCTAssertTrue(GeoDataStore.geoip.hasData, "an import saves without saveConfig, so it asks for the list itself")
    }
}

// MARK: - Routing decisions

final class BlockReviewFixesTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)
    private let unknown = Route(name: "?", egress: .unsupported)

    private let env = WildcardPlanner.Environment(
        localGateway: "192.168.10.1", physicalInterface: "en0", physicalDNS: ["192.168.10.1"],
        vpnGateway: "10.20.0.1", vpnInterface: "utun4", vpnDNS: ["10.20.0.53"])

    private func custom(_ rules: [Rule], routes: [Route]? = nil) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = routes ?? [direct, block, unknown]
        c.rules = rules
        return c
    }

    private func rule(_ type: MatchType, _ pattern: String, _ route: Route, order: Int) -> Rule {
        Rule(matchType: type, pattern: pattern, routeId: route.id, order: order)
    }

    // A name sent to Block is never looked up

    func testNamesSentToBlockAreNotResolved() {
        let services = [ServiceEntry(id: "svc", name: "Svc", enabled: true, domains: ["a.example.org"], ipRanges: ["198.51.100.0/24"])]
        let lists = GeoSiteDat.expansions(for: ["ads"], in: Dat.file([Dat.site("ADS", [Dat.domain(3, "pixel.example.net")])]))
        let rules = [rule(.domain, "blocked.example.com", block, order: 0), rule(.service, "svc", block, order: 1),
                     rule(.geosite, "ads", block, order: 2), rule(.domain, "open.example.com", direct, order: 3)]
        let hosts = RuleDestinationBuilder.hostsToResolve(rules: rules, services: services, geosite: lists, routes: [direct, block])
        XCTAssertEqual(hosts, ["open.example.com"], "only the names a rule routes are looked up")
    }

    func testANameOnBothABlockAndARouteIsStillResolvedForTheRoute() {
        let rules = [rule(.domain, "both.example.com", direct, order: 0), rule(.domain, "both.example.com", block, order: 1)]
        XCTAssertEqual(RuleDestinationBuilder.hostsToResolve(rules: rules, services: [], routes: [direct, block]), ["both.example.com"])
    }

    func testBuildGivesABlockedServiceItsRangesAndNoResolvedHosts() {
        let services = [ServiceEntry(id: "svc", name: "Svc", enabled: true, domains: ["a.example.org"], ipRanges: ["198.51.100.0/24"])]
        let out = RuleDestinationBuilder.build(rules: [rule(.service, "svc", block, order: 0)], services: services,
                                               resolved: ["a.example.org": ["203.0.113.5"]], routes: [direct, block])
        XCTAssertEqual(out[0].dests.map(\.value), ["198.51.100.0/24"])
        let name = RuleDestinationBuilder.build(rules: [rule(.domain, "a.example.org", block, order: 0)], services: [],
                                                resolved: ["a.example.org": ["203.0.113.5"]], routes: [direct, block])
        XCTAssertTrue(name[0].dests.isEmpty)
    }

    func testTheNamesOfASiteListThatDoNotResolveAreNotRetried() {
        let split = RouteManager.partitionUnresolved(["mine.example.com", "dead1.example.net", "dead2.example.net"],
                                                     entryNames: ["mine.example.com"])
        XCTAssertEqual(split.retry, ["mine.example.com"])
        XCTAssertEqual(split.inLists, 2)
    }

    // A route this build does not know claims nothing

    func testAnUnknownRouteDoesNotClaimAWildcard() {
        let early = rule(.suffix, "ads.example.com", unknown, order: 0)
        let later = rule(.suffix, "ads.example.com", direct, order: 1)
        let configured = WildcardPlanner.configured(custom([early, later]))
        XCTAssertEqual(configured.map(\.suffix), ["ads.example.com"], "the later Direct rule is served")
        XCTAssertEqual(configured.first?.via, .physical)
    }

    // A suffix moved to Block keeps no learned routes

    func testABlockedSuffixIsNotInTheSetThatKeepsLearnedRoutes() {
        let c = custom([rule(.suffix, "ads.example.com", block, order: 0), rule(.suffix, "video.example.com", direct, order: 1)])
        XCTAssertEqual(WildcardPlanner.configuredSuffixes(c), ["video.example.com"])
        XCTAssertEqual(Set(WildcardPlanner.configuredSuffixes(c, includingBlocked: true)), ["ads.example.com", "video.example.com"],
                       "but a blackhole is still noticed when it is added")
    }

    // A blackhole leaves another resolver's names to it

    func testABlockSpecCarriesTheResolversOfItsDomain() {
        var withTailnet = env
        withTailnet.resolvers = [ScutilDNS.Resolver(domain: "tail.ads.example.com", nameservers: ["100.100.100.100"], interface: nil, order: 100)]
        let c = custom([rule(.suffix, "ads.example.com", block, order: 0)])
        let spec = WildcardPlanner.plan(c, env: withTailnet).specs.first
        XCTAssertEqual(spec?.block, true)
        XCTAssertEqual(spec?.delegated.map(\.domain), ["tail.ads.example.com"], "names it serves are not answered NXDOMAIN")
    }

    func testABlockSpecWithoutAnUpstreamStillCarriesThem() {
        var offline = env
        offline.localGateway = nil
        offline.physicalInterface = nil
        offline.physicalDNS = []
        offline.resolvers = [ScutilDNS.Resolver(domain: "corp.ads.example.com", nameservers: ["10.20.0.53"], interface: "utun4", order: 100)]
        let spec = WildcardPlanner.plan(custom([rule(.suffix, "ads.example.com", block, order: 0)]), env: offline).specs.first
        XCTAssertEqual(spec?.upstream, [])
        XCTAssertEqual(spec?.delegated.map(\.domain), ["corp.ads.example.com"])
        XCTAssertNotNil(spec.flatMap { WildcardSpec(dictionary: $0.dictionary) }, "and it still crosses to the helper")
    }

    func testAResolverThatMatchesThePhysicalUpstreamIsStillCarriedByABlockSpec() {
        var same = env
        same.resolvers = [ScutilDNS.Resolver(domain: "dns.ads.example.com", nameservers: ["192.168.10.1"], interface: "en0", order: 100)]
        let spec = WildcardPlanner.plan(custom([rule(.suffix, "ads.example.com", block, order: 0)]), env: same).specs.first
        XCTAssertEqual(spec?.delegated.map(\.domain), ["dns.ads.example.com"],
                       "a blackhole asks no upstream, so the 'same servers' exemption does not apply")
    }

    // Everything else is never Block

    func testEverythingElseDoesNotOfferBlock() {
        let routes = [direct, block, Route(name: "VPN", egress: .vpnDefault)]
        XCTAssertEqual(RulesRouteChipMenu.systemRoutes(routes, allowsBlock: true).map(\.egress), [.direct, .vpnDefault, .block])
        XCTAssertEqual(RulesRouteChipMenu.systemRoutes(routes, allowsBlock: false).map(\.egress), [.direct, .vpnDefault])
    }

    // A row keeps its route's warning beside a count

    func testALineIsJoinedWithTheRoutesNote() {
        XCTAssertEqual(RuleRow.joined("2,070 ranges", "Only apps set to use office-proxy take it."),
                       "2,070 ranges\nOnly apps set to use office-proxy take it.")
        XCTAssertEqual(RuleRow.joined("2,070 ranges", nil), "2,070 ranges")
        XCTAssertEqual(RuleRow.joined(nil, "note"), "note")
        XCTAssertNil(RuleRow.joined(nil, nil))
    }

    // The Routes page lists Block and unknown routes

    func testTheRoutesPageListsBlockAndUnknownRoutes() {
        XCTAssertTrue(RoutesTab.isListed(block))
        XCTAssertTrue(RoutesTab.isListed(unknown))
        XCTAssertTrue(RoutesTab.isListed(Route(name: "p", egress: .proxySOCKS5, proxyHost: "h", proxyPort: 1)))
        XCTAssertFalse(RoutesTab.isListed(direct), "Direct and the primary VPN are the system routes above")
        XCTAssertFalse(RoutesTab.isListed(Route(name: "VPN", egress: .vpnDefault)))
    }

    // The attribute of a site list

    func testPickingTheSameListKeepsItsAttribute() {
        XCTAssertEqual(GeoSiteRule.pattern(afterPicking: "microsoft", current: "microsoft@cn"), "microsoft@cn")
        XCTAssertEqual(GeoSiteRule.pattern(afterPicking: "Microsoft", current: "microsoft@cn"), "Microsoft@cn")
        XCTAssertEqual(GeoSiteRule.pattern(afterPicking: "steam", current: "microsoft@cn"), "steam", "another list starts without one")
        XCTAssertEqual(GeoSiteRule.pattern(afterPicking: "microsoft", current: "microsoft"), "microsoft")
        XCTAssertEqual(GeoSiteRule.pattern(afterPicking: "microsoft", current: ""), "microsoft")
    }
}

// MARK: - A newer version's rule and route keep everything

final class UnknownFieldsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private let rule = """
    {"id":"AAAAAAAA-0000-0000-0000-000000000001","matchType":"asn","pattern":"AS64496",
     "routeId":"11111111-1111-1111-1111-111111111111","enabled":true,"order":4,
     "weight":7,"note":"from a newer version","nested":{"a":[1,2.5,"x",null,true],"b":{"c":"d"}}}
    """

    func testARuleKeepsEveryFieldItHad() throws {
        let r = try decode(Rule.self, rule)
        XCTAssertEqual(r.matchType, .unsupported)
        let out = try object(r)
        XCTAssertEqual(out["matchType"] as? String, "asn")
        XCTAssertEqual(out["weight"] as? Int, 7)
        XCTAssertEqual(out["note"] as? String, "from a newer version")
        let nested = try XCTUnwrap(out["nested"] as? [String: Any])
        XCTAssertEqual((nested["a"] as? [Any])?.count, 5)
        XCTAssertEqual((nested["a"] as? [Any])?[1] as? Double, 2.5)
        XCTAssertEqual((nested["b"] as? [String: String])?["c"], "d")
        XCTAssertEqual(try decode(Rule.self, String(decoding: JSONSerialization.data(withJSONObject: out), as: UTF8.self)), r)
    }

    func testWhatTheUserCanChangeInAnUnknownRuleIsWritten() throws {
        var r = try decode(Rule.self, rule)
        r.enabled = false
        r.order = 9
        r.pattern = "AS64497"
        let newRoute = UUID()
        r.routeId = newRoute
        let out = try object(r)
        XCTAssertEqual(out["enabled"] as? Bool, false)
        XCTAssertEqual(out["order"] as? Int, 9)
        XCTAssertEqual(out["pattern"] as? String, "AS64497")
        XCTAssertEqual((out["routeId"] as? String)?.lowercased(), newRoute.uuidString.lowercased())
        XCTAssertEqual(out["weight"] as? Int, 7, "and what it did not know is still there")
        XCTAssertEqual(out["matchType"] as? String, "asn")
    }

    func testARouteKeepsEveryFieldItHad() throws {
        let json = """
        {"id":"22222222-2222-2222-2222-222222222222","name":"wg","egress":"wireguard2","enabled":true,
         "proxyHost":"198.51.100.7","proxyPort":51820,"keepalive":25,"peers":[{"key":"abc","allowed":["10.0.0.0/8"]}]}
        """
        var r = try decode(Route.self, json)
        XCTAssertEqual(r.egress, .unsupported)
        r.name = "renamed"
        r.enabled = false
        let out = try object(r)
        XCTAssertEqual(out["egress"] as? String, "wireguard2")
        XCTAssertEqual(out["name"] as? String, "renamed")
        XCTAssertEqual(out["enabled"] as? Bool, false)
        XCTAssertEqual(out["keepalive"] as? Int, 25)
        XCTAssertEqual(((out["peers"] as? [[String: Any]])?.first?["allowed"] as? [String]), ["10.0.0.0/8"])
        XCTAssertEqual(out["proxyHost"] as? String, "198.51.100.7")
    }

    func testAKnownRuleIsWrittenAsBefore() throws {
        let r = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: UUID(), order: 2)
        let out = try object(r)
        XCTAssertEqual(Set(out.keys), ["id", "matchType", "pattern", "routeId", "enabled", "order"])
        XCTAssertNil(r.unknownFields)
    }

    func testAnUnknownRuleSurvivesAWholeConfigRoundTrip() throws {
        let direct = Route(name: "Direct", egress: .direct)
        var c = RouteManager.Config()
        c.routes = [direct]
        c.defaultRouteId = direct.id
        c.schemaVersion = 2
        c.rules = [try decode(Rule.self, rule)]
        let json = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: json)
        XCTAssertEqual(back.rules, c.rules)
        let rules = try XCTUnwrap((try JSONSerialization.jsonObject(with: JSONEncoder().encode(back)) as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["weight"] as? Int, 7)
    }
}

// MARK: - The site check

final class BlockedSiteCheckTests: XCTestCase {

    private let block = Route(name: "Block", egress: .block)
    private let direct = Route(name: "Direct", egress: .direct)

    private func snapshot(_ rules: [Rule], geosite: [String: GeoSiteExpansion] = [:]) -> SiteRoute.Snapshot {
        var s = SiteRoute.Snapshot(mode: .custom, custom: true, list: [], services: [], rules: rules, routes: [direct, block],
                                   defaultRouteId: direct.id, activeRoutes: [], localGateway: "192.168.1.1", vpnInterface: "utun4")
        s.geosite = geosite
        return s
    }

    func testANameMatchingABlockRuleIsBlockedWithoutAnAddress() throws {
        let s = snapshot([Rule(matchType: .suffix, pattern: "ads.example.com", routeId: block.id, order: 0)])
        let found = try XCTUnwrap(SiteRoute.matchByName(host: "x.ads.example.com", in: s))
        XCTAssertTrue(found.blocked)
        XCTAssertEqual(found.match, .rule)
        let answer = SiteRoute.answer(host: "x.ads.example.com", mode: .custom, addresses: [], found: found, probes: [], control: nil, vpnConnected: true)
        XCTAssertEqual(answer.verdict, .notChecked)
        XCTAssertTrue(answer.checks.isEmpty, "nothing is probed")
        XCTAssertTrue(answer.summary.contains("Block"), answer.summary)
        XCTAssertTrue(answer.summary.contains("nothing connects"), answer.summary)
    }

    func testAGeositeListOnBlockBlocksItsNames() {
        let lists = GeoSiteDat.expansions(for: ["ads"], in: Dat.file([Dat.site("ADS", [Dat.domain(2, "tracker.example.net")])]))
        let s = snapshot([Rule(matchType: .geosite, pattern: "ads", routeId: block.id, order: 0)], geosite: lists)
        XCTAssertEqual(SiteRoute.matchByName(host: "a.tracker.example.net", in: s)?.blocked, true)
        XCTAssertNil(SiteRoute.matchByName(host: "example.org", in: s))
    }

    func testARuleOnARealRouteIsNotBlocked() {
        let s = snapshot([Rule(matchType: .suffix, pattern: "example.com", routeId: direct.id, order: 0)])
        XCTAssertEqual(SiteRoute.matchByName(host: "www.example.com", in: s)?.blocked, false)
    }

    func testAnAllowRuleAboveABlockWins() {
        let s = snapshot([Rule(matchType: .domain, pattern: "ok.ads.example.com", routeId: direct.id, order: 0),
                          Rule(matchType: .suffix, pattern: "ads.example.com", routeId: block.id, order: 1)])
        XCTAssertEqual(SiteRoute.matchByName(host: "ok.ads.example.com", in: s)?.blocked, false)
        XCTAssertEqual(SiteRoute.matchByName(host: "other.ads.example.com", in: s)?.blocked, true)
    }
}
