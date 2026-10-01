// RouteCheckTests.swift
// Coverage for what Verify Routes checks and how its card says so (RouteCheck).
//
// The problem it locks down: Verify pinged at most 10 single addresses, the first in sort order,
// and its card showed "10/10" next to a badge that said 62 routes, so a sample read as everything.
// It listed three results taken from a Swift Dictionary, in no stable order, so a failure could
// sit in the rows nobody saw. The card now says how many of how many it checked, lists failures
// first, and every result is one line in the log.

import XCTest
@testable import VPNBypassCore

final class RouteCheckTests: XCTestCase {

    private func route(_ destination: String, _ source: String = "s") -> RoutedBySource.InstalledRoute {
        .init(destination: destination, source: source)
    }

    private func isSingle(_ s: String) -> Bool { !s.contains("/") }

    private func result(_ destination: String, ok: Bool, ms: Double? = nil) -> RouteVerificationResult {
        RouteVerificationResult(destination: destination, isReachable: ok, latency: ms, timestamp: Date(),
                                error: ok ? nil : "Ping timed out")
    }

    // MARK: Plan

    /// Single addresses only, the first ten in sort order, out of a count of every route.
    func testThePlanSamplesTheFirstTenSingleAddresses() {
        let singles = (10...29).map { "10.0.0.\($0)" }
        let ranges = ["149.154.160.0/20", "91.108.4.0/22"]
        let routes = (singles + ranges).reversed().map { route($0) }
        let plan = RouteCheck.plan(routes: routes, vpnOnly: false, isSingleAddress: isSingle)
        XCTAssertEqual(plan.destinations, Array(singles.sorted().prefix(10)))
        XCTAssertEqual(plan.singleAddresses, 20)
        XCTAssertEqual(plan.routeCount, 22)
    }

    /// A destination recorded twice counts once and reads as its first source.
    func testADestinationRecordedTwiceCountsOnce() {
        let routes = [route("1.1.1.1", "Telegram"), route("1.1.1.1", "WhatsApp"), route("2.2.2.2", "YouTube")]
        let plan = RouteCheck.plan(routes: routes, vpnOnly: false, isSingleAddress: isSingle)
        XCTAssertEqual(plan.routeCount, 2)
        XCTAssertEqual(plan.sources, ["1.1.1.1": "Telegram", "2.2.2.2": "YouTube"])
    }

    /// Only the sampled addresses carry a source.
    func testSourcesCoverOnlyTheSample() {
        let routes = (10...25).map { route("10.0.0.\($0)", "src\($0)") }
        let plan = RouteCheck.plan(routes: routes, vpnOnly: false, isSingleAddress: isSingle)
        XCTAssertEqual(Set(plan.sources.keys), Set(plan.destinations))
    }

    /// VPN Only leaves its catch-alls out of the count, as the list above the card does. In
    /// another mode they are routes like any other.
    func testVPNOnlyCatchAllsAreNotCounted() {
        let catchAlls = RouteCompiler.catchAllDestinations.map { route($0, ClassicRouteCompiler.catchAllSource) }
        let routes = catchAlls + [route("1.1.1.1", "corp.example.com")]
        XCTAssertEqual(RouteCheck.plan(routes: routes, vpnOnly: true, isSingleAddress: isSingle).routeCount, 1)
        XCTAssertEqual(RouteCheck.plan(routes: routes, vpnOnly: false, isSingleAddress: isSingle).routeCount,
                       1 + catchAlls.count)
    }

    // MARK: Scope sentence

    func testASampleWithRangesLeftOutSaysSingleAddressesOnly() {
        let s = RouteCheck.scope(checked: 10, singleAddresses: 40, routeCount: 62)
        XCTAssertEqual(s.main, "Checked 10 of 62 addresses")
        XCTAssertEqual(s.qualifier, "(single addresses only)")
        XCTAssertEqual(s.text, "Checked 10 of 62 addresses (single addresses only).")
    }

    /// Only the sample size cut the list: no range was left out, so no qualifier.
    func testASampleOfSingleAddressesHasNoQualifier() {
        XCTAssertEqual(RouteCheck.scope(checked: 10, singleAddresses: 62, routeCount: 62).text,
                       "Checked 10 of 62 addresses.")
    }

    /// Ranges left out with fewer than ten single addresses.
    func testFewSingleAddressesAndSomeRanges() {
        XCTAssertEqual(RouteCheck.scope(checked: 3, singleAddresses: 3, routeCount: 5).text,
                       "Checked 3 of 5 addresses (single addresses only).")
    }

    func testEveryRouteChecked() {
        XCTAssertEqual(RouteCheck.scope(checked: 4, singleAddresses: 4, routeCount: 4).text, "Checked all 4 addresses.")
        XCTAssertEqual(RouteCheck.scope(checked: 1, singleAddresses: 1, routeCount: 1).text, "Checked the only address.")
    }

    /// One address out of several routes takes the singular form, which es and fr spell
    /// differently ("1 route vérifiée sur 2", never "1 routes vérifiées").
    func testCheckingOneOfSeveralRoutes() {
        XCTAssertEqual(RouteCheck.scope(checked: 1, singleAddresses: 1, routeCount: 2).text,
                       "Checked 1 of 2 addresses (single addresses only).")
    }

    func testOnlyRangesMeansNothingToCheck() {
        XCTAssertEqual(RouteCheck.scope(checked: 0, singleAddresses: 0, routeCount: 3).text,
                       "Nothing to check: all 3 addresses are ranges, which ping cannot test.")
        XCTAssertEqual(RouteCheck.scope(checked: 0, singleAddresses: 0, routeCount: 1).text,
                       "Nothing to check: the only address is a range, which ping cannot test.")
    }

    // MARK: Results

    /// A failure the old card would not have shown (eighth of ten) is in `failures`, and both
    /// lists keep the order the addresses were pinged in.
    func testFailuresComeOutInPingOrderWhereverTheyAre() {
        let plan = RouteCheck.Plan(destinations: [], sources: [:], singleAddresses: 10, routeCount: 62)
        var results = (0..<10).map { result("10.0.0.\($0)", ok: true, ms: Double($0 + 20)) }
        results[7] = result("10.0.0.7", ok: false)
        results[2] = result("10.0.0.2", ok: false)
        let run = RouteCheck.Run(plan: plan, results: results, logsFrom: Date(), at: Date())
        XCTAssertEqual(run.failures.map(\.destination), ["10.0.0.2", "10.0.0.7"])
        XCTAssertEqual(run.reachable.map(\.destination),
                       ["10.0.0.0", "10.0.0.1", "10.0.0.3", "10.0.0.4", "10.0.0.5", "10.0.0.6", "10.0.0.8", "10.0.0.9"])
    }

    func testLatencyRange() {
        XCTAssertEqual(RouteCheck.latencyRange([result("a", ok: true, ms: 118.4), result("b", ok: true, ms: 23.6),
                                                result("c", ok: false)]), "24 to 118 ms")
        XCTAssertEqual(RouteCheck.latencyRange([result("a", ok: true, ms: 31)]), "31 ms")
        XCTAssertEqual(RouteCheck.latencyRange([result("a", ok: true, ms: 31), result("b", ok: true, ms: 31.2)]), "31 ms")
        XCTAssertNil(RouteCheck.latencyRange([result("a", ok: true)]))
        XCTAssertNil(RouteCheck.latencyRange([result("a", ok: false)]))
    }

    func testCounts() {
        XCTAssertEqual(RouteCheck.notReachable(1), "1 not reachable")
        XCTAssertEqual(RouteCheck.notReachable(3), "3 not reachable")
        XCTAssertEqual(RouteCheck.reachable(1), "1 reachable")
        XCTAssertEqual(RouteCheck.reachable(9), "9 reachable")
        XCTAssertEqual(RouteCheck.logsLink(1), "Show the result in Logs")
        XCTAssertEqual(RouteCheck.logsLink(10), "Show all 10 results in Logs")
    }

    /// The Logs link shows only while the log still holds every result line: it keeps the newest
    /// 200 lines and can be emptied, and both drop the oldest first.
    func testTheLogsLinkNeedsTheResultLinesInTheLog() {
        let start = Date(timeIntervalSince1970: 1_000)
        let plan = RouteCheck.Plan(destinations: [], sources: [:], singleAddresses: 1, routeCount: 1)
        let run = RouteCheck.Run(plan: plan, results: [result("1.1.1.1", ok: true)], logsFrom: start,
                                 at: start.addingTimeInterval(5))
        XCTAssertTrue(run.logsHoldResults(oldestLogAt: start.addingTimeInterval(-60)))
        XCTAssertTrue(run.logsHoldResults(oldestLogAt: start))
        XCTAssertFalse(run.logsHoldResults(oldestLogAt: start.addingTimeInterval(1)), "older lines were trimmed")
        XCTAssertFalse(run.logsHoldResults(oldestLogAt: nil), "the log was emptied")
    }

    // MARK: Translations

    /// Every string the card can show has an en, es and fr entry, and the positional forms are
    /// the ones Foundation looks up at run time.
    func testEveryStringIsTranslated() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            guard dir.pathComponents.count > 1 else { throw XCTSkip("repo root not found from \(#filePath)") }
            dir = dir.deletingLastPathComponent()
        }
        let core = dir.appendingPathComponent("Sources/VPNBypassCore")
        let source = try String(contentsOf: core.appendingPathComponent("MenuBarViews.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "enum RouteCheck {"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - What is routed", range: start.upperBound..<source.endIndex))
        let text = String(source[start.lowerBound..<end.lowerBound])

        let literal = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        let interpolation = try NSRegularExpression(pattern: #"\\\((.*?)\)"#)
        var keys: [String] = []
        for m in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let raw = String(text[Range(m.range(at: 1), in: text)!])
            keys.append(interpolation.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw),
                                                               withTemplate: "%lld"))
        }
        XCTAssertEqual(Set(keys), [
            "Nothing to check: the only address is a range, which ping cannot test",
            "Nothing to check: all %lld addresses are ranges, which ping cannot test",
            "Checked the only address", "Checked all %lld addresses", "Checked %lld of %lld addresses",
            "Checked 1 of %lld addresses",
            "(single addresses only)", "Route check", "All reachable.",
            "1 not reachable", "%lld not reachable", "1 reachable", "%lld reachable",
            "%lld ms", "%lld to %lld ms", "Show the result in Logs", "Show all %lld results in Logs",
        ], "the scan found a different set; update the list")

        for lang in ["en", "es", "fr"] {
            let url = core.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys {
                XCTAssertNotNil(table[key], "\(lang).lproj has no entry for \"\(key)\"")
            }
            guard lang != "en" else { continue }
            let bundle = try XCTUnwrap(Bundle(url: url.deletingLastPathComponent()), lang)
            let checked = String(localized: "Checked \(10) of \(62) addresses", bundle: bundle)
            XCTAssertNotEqual(checked, "Checked 10 of 62 addresses", lang)
            XCTAssertTrue(checked.contains("10") && checked.contains("62"), "\(lang): \(checked)")
            XCTAssertLessThan(try XCTUnwrap(checked.range(of: "10")).lowerBound,
                              try XCTUnwrap(checked.range(of: "62")).lowerBound, "\(lang): \(checked)")
        }
        for (lang, expected) in [("es", "Comprobada 1 de 2 direcciones"), ("fr", "1 adresse vérifiée sur 2")] {
            let bundle = try XCTUnwrap(Bundle(url: core.appendingPathComponent("Resources/\(lang).lproj")), lang)
            XCTAssertEqual(String(localized: "Checked 1 of \(2) addresses", bundle: bundle), expected)
        }
    }
}

/// `verifyRoutes` on the shared manager: what it publishes and what it logs. It pings only
/// 127.0.0.1, so it needs no network and fires no failure notification.
@MainActor
final class VerifyRoutesLoggingTests: XCTestCase {
    private var savedRoutes: [RouteManager.ActiveRoute] = []
    private var savedConfig = RouteManager.Config()
    private var savedLogs: [RouteManager.LogEntry] = []

    override func setUp() async throws {
        let rm = RouteManager.shared
        savedRoutes = rm.activeRoutes
        savedConfig = rm.config
        savedLogs = rm.recentLogs
    }

    override func tearDown() async throws {
        let rm = RouteManager.shared
        rm.activeRoutes = savedRoutes
        rm.config = savedConfig
        rm.recentLogs = savedLogs
        rm.clearRouteCheck()
    }

    private func route(_ dest: String, _ source: String) -> RouteManager.ActiveRoute {
        RouteManager.ActiveRoute(destination: dest, gateway: "192.168.1.1", source: source, timestamp: Date())
    }

    /// One log line per result, named by what it is routed for, then the scope.
    func testEachResultIsOneLogLine() async {
        let rm = RouteManager.shared
        rm.config.routingMode = .bypass
        rm.activeRoutes = [route("127.0.0.1", "Loopback"), route("10.0.0.0/8", "Office")]
        rm.recentLogs = []

        await rm.verifyRoutes()

        let run = rm.lastRouteCheck
        XCTAssertEqual(run?.results.map(\.destination), ["127.0.0.1"])
        XCTAssertEqual(run?.routeCount, 2)
        XCTAssertEqual(run?.singleAddresses, 1)
        let lines = rm.recentLogs.map(\.message)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Route check: 127.0.0.1 (Loopback) reachable") }, "\(lines)")
        XCTAssertEqual(lines.first, "Route check: all 1 reachable (checked 1 of 2 routes, single addresses only)")

        // The Logs link holds while the lines are there, and goes once the Logs page empties it.
        XCTAssertEqual(run?.logsHoldResults(oldestLogAt: rm.recentLogs.last?.timestamp), true)
        rm.recentLogs.removeAll()
        XCTAssertEqual(run?.logsHoldResults(oldestLogAt: rm.recentLogs.last?.timestamp), false)
        rm.log(.info, "later")
        XCTAssertEqual(run?.logsHoldResults(oldestLogAt: rm.recentLogs.last?.timestamp), false)
    }

    /// Waits until verifyRoutes has logged its start `count` times; it logs before its first
    /// await, so after that it is waiting on ping.
    private func waitForStart(_ rm: RouteManager, count: Int = 1) async {
        var spins = 0
        while rm.recentLogs.filter({ $0.message == "Verifying routes..." }).count < count {
            spins += 1
            if spins > 10_000 { XCTFail("the check never started"); return }
            await Task.yield()
        }
    }

    /// The spinner follows a check, whoever started it: on while it pings, off once it is done.
    func testIsCheckingRoutesWhileTheCheckRuns() async {
        let rm = RouteManager.shared
        rm.config.routingMode = .bypass
        rm.activeRoutes = [route("127.0.0.1", "Loopback")]
        rm.recentLogs = []

        let check = Task { await rm.verifyRoutes() }
        await waitForStart(rm)
        XCTAssertTrue(rm.isCheckingRoutes)
        await check.value
        XCTAssertFalse(rm.isCheckingRoutes)
    }

    /// A check dropped by a newer one must not turn the newer one's spinner off when it ends.
    /// The newer one pings a TEST-NET address that never answers, so it is still running then.
    func testADroppedCheckLeavesTheNewerSpinnerOn() async {
        let rm = RouteManager.shared
        rm.config.routingMode = .bypass
        rm.activeRoutes = [route("127.0.0.1", "Loopback")]
        rm.recentLogs = []

        let older = Task { await rm.verifyRoutes() }
        await waitForStart(rm)
        rm.activeRoutes = [route("192.0.2.1", "Nowhere")]
        let newer = Task { await rm.verifyRoutes() }
        await waitForStart(rm, count: 2)

        await older.value
        XCTAssertTrue(rm.isCheckingRoutes, "the dropped check turned the spinner off")
        XCTAssertNil(rm.lastRouteCheck)
        await newer.value
        XCTAssertFalse(rm.isCheckingRoutes)
        XCTAssertEqual(rm.lastRouteCheck?.results.map(\.destination), ["192.0.2.1"])
    }

    /// Only ranges: nothing is pinged, and the card and the log say why.
    func testOnlyRangesPublishAnEmptyCheck() async {
        let rm = RouteManager.shared
        rm.config.routingMode = .bypass
        rm.activeRoutes = [route("10.0.0.0/8", "Office"), route("172.16.0.0/12", "Lab")]
        rm.recentLogs = []

        await rm.verifyRoutes()

        XCTAssertEqual(rm.lastRouteCheck?.results.count, 0)
        XCTAssertEqual(rm.lastRouteCheck?.routeCount, 2)
        XCTAssertEqual(rm.recentLogs.first?.message,
                       "Route check: nothing to check, all 2 routes are address ranges, which ping cannot test")
    }

    /// Routes removed while a check is still pinging: the check must not bring the card back.
    func testACheckClearedWhileRunningPublishesNothing() async throws {
        let rm = RouteManager.shared
        rm.config.routingMode = .bypass
        rm.activeRoutes = [route("127.0.0.1", "Loopback")]
        rm.recentLogs = []

        let check = Task { await rm.verifyRoutes() }
        // verifyRoutes logs before its first await, so once the line is there it is waiting on ping.
        var spins = 0
        while !rm.recentLogs.contains(where: { $0.message == "Verifying routes..." }) {
            spins += 1
            XCTAssertLessThan(spins, 10_000, "the check never started")
            await Task.yield()
        }
        XCTAssertTrue(rm.isCheckingRoutes)
        rm.clearRouteCheck()
        // Its result will be dropped, so nothing is checking any more.
        XCTAssertFalse(rm.isCheckingRoutes)
        await check.value

        XCTAssertNil(rm.lastRouteCheck)
        XCTAssertFalse(rm.isCheckingRoutes)
        XCTAssertEqual(rm.recentLogs.first?.message,
                       "Route check: result dropped, routes were removed or another check started while it ran")
    }

    /// No routes, no card.
    func testNoRoutesNoCard() async {
        let rm = RouteManager.shared
        rm.activeRoutes = []
        await rm.verifyRoutes()
        XCTAssertNil(rm.lastRouteCheck)
    }
}
