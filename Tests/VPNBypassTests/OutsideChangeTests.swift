// OutsideChangeTests.swift
// Changes made through the control socket show in the app (proposal 15 of #119): which
// request becomes the dropdown footer's "Last change" line and how it reads, the log's
// "via the command line" tag, the Logs filter the line opens, and the Spanish and French text.
// The last part runs real requests through ControlSurface.handle, with the same save/restore
// discipline as ClassicControlTests.

import XCTest
@testable import VPNBypassCore

final class OutsideChangeTests: XCTestCase {

    private typealias Config = RouteManager.Config
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func config(domains: [DomainEntry] = [], inverse: [DomainEntry] = [],
                        mode: RouteManager.RoutingMode = .bypass) -> Config {
        var cfg = Config()
        cfg.routingMode = mode
        cfg.domains = domains
        cfg.inverseDomains = inverse
        return cfg
    }

    private func make(_ cmd: String, result: ControlResult? = nil, before: Config, after: Config,
                      routesBefore: Int = 0, routesLeft: Int = 0) -> OutsideChange? {
        OutsideChange.make(cmd: cmd, result: result, before: before, after: after,
                           routesBefore: routesBefore, routesLeft: routesLeft, at: t0)
    }

    // MARK: Which requests are a change

    func testAddingADomainNamesIt() {
        let entry = DomainEntry(domain: "en.wikipedia.org")
        let change = make("domain.add", result: ControlResult(domains: [ControlDomain(entry, list: .bypass)]),
                          before: config(), after: config(domains: [entry]))
        XCTAssertEqual(change, OutsideChange(kind: .addedDomain("en.wikipedia.org"), at: t0))
    }

    func testRemovingADomainNamesTheEntryThatLeftEitherList() {
        let keep = DomainEntry(domain: "news.ycombinator.com")
        let gone = DomainEntry(domain: "10.0.0.0/8")
        let change = make("domain.rm", result: ControlResult(message: "domain removed"),
                          before: config(domains: [keep], inverse: [gone]), after: config(domains: [keep]))
        XCTAssertEqual(change?.kind, .removedDomain("10.0.0.0/8"))
    }

    func testTurningADomainOrServiceOnAndOffNamesIt() {
        var entry = DomainEntry(domain: "example.com")
        let on = config(domains: [entry])
        entry.enabled = false
        let off = config(domains: [entry])
        XCTAssertEqual(make("domain.disable", result: ControlResult(domains: [ControlDomain(entry, list: .bypass)]),
                            before: on, after: off)?.kind, .turnedOff("example.com"))

        var before = config(), after = config()
        before.services = [RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: false, domains: [], ipRanges: [])]
        after.services = [RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: [], ipRanges: [])]
        XCTAssertEqual(make("service.enable", result: ControlResult(services: [ControlService(after.services[0])]),
                            before: before, after: after)?.kind, .turnedOn("Telegram"))
    }

    func testSwitchingModeNamesTheNewMode() {
        XCTAssertEqual(make("mode", before: config(), after: config(mode: .vpnOnly))?.kind, .switchedMode(.vpnOnly))
    }

    func testCustomModeVerbsSayWhatKindOfSettingChanged() {
        var after = config(mode: .custom)
        after.defaultRouteId = UUID()
        for cmd in ["route.add", "route.set", "route.enable", "route.disable", "route.rm", "default"] {
            XCTAssertEqual(make(cmd, before: config(mode: .custom), after: after)?.kind, .changedRoutes, cmd)
        }
        for cmd in ["rule.add", "rule.rm"] {
            XCTAssertEqual(make(cmd, before: config(mode: .custom), after: after)?.kind, .changedRules, cmd)
        }
    }

    /// A request that leaves every setting as it was changes nothing the footer could name:
    /// `mode` to the mode in use, enabling what is already on.
    func testARequestThatChangesNoSettingIsNoChange() {
        let entry = DomainEntry(domain: "example.com")
        let same = config(domains: [entry])
        XCTAssertNil(make("mode", before: config(), after: config()))
        XCTAssertNil(make("domain.enable", result: ControlResult(domains: [ControlDomain(entry, list: .bypass)]),
                          before: same, after: same))
    }

    func testRefreshesAndReadsAreNoChange() {
        for cmd in ["refresh", "dns.refresh", "status", "domain.list", "service.list", "routes.active", "logs",
                    "route.list", "rule.list"] {
            XCTAssertNil(make(cmd, before: config(), after: config(domains: [DomainEntry(domain: "x.org")])), cmd)
        }
    }

    func testRemovingAllRoutesNeedsRoutesAndStopsShowingOnceTheCountMoves() {
        XCTAssertNil(make("routes.clear", before: config(), after: config(), routesBefore: 0, routesLeft: 0))
        let change = make("routes.clear", before: config(), after: config(), routesBefore: 62, routesLeft: 2)
        XCTAssertEqual(change?.kind, .removedAllRoutes(routesLeft: 2))
        XCTAssertEqual(change?.isShown(currentRouteCount: 2), true)
        XCTAssertEqual(change?.isShown(currentRouteCount: 9), false, "a DNS refresh brought routes back")
        XCTAssertEqual(OutsideChange(kind: .addedDomain("x.org"), at: t0).isShown(currentRouteCount: 9), true)
    }

    // MARK: Wording

    func testTheLineSaysWhatWhereAndWhen() {
        let line = OutsideChange(kind: .addedDomain("en.wikipedia.org"), at: t0).line(now: t0.addingTimeInterval(150))
        XCTAssertEqual(line.text, "Last change: added en.wikipedia.org via the command line, 2 min ago")
        XCTAssertEqual(line.subject, "en.wikipedia.org")
        let cases: [(OutsideChange.Kind, String, String?)] = [
            (.removedDomain("x.org"), "Last change: removed x.org via the command line, just now", "x.org"),
            (.turnedOn("Telegram"), "Last change: turned on Telegram via the command line, just now", "Telegram"),
            (.turnedOff("Slack"), "Last change: turned off Slack via the command line, just now", "Slack"),
            (.switchedMode(.vpnOnly), "Last change: switched to VPN Only via the command line, just now", "VPN Only"),
            (.removedAllRoutes(routesLeft: 0), "Last change: removed all routes via the command line, just now", nil),
            (.removedAllRoutes(routesLeft: 2), "Last change: removed routes via the command line, just now; routes left: 2", nil),
            (.changedRoutes, "Last change: changed the routes via the command line, just now", nil),
            (.changedRules, "Last change: changed the rules via the command line, just now", nil),
        ]
        for (kind, text, subject) in cases {
            let line = OutsideChange(kind: kind, at: t0).line(now: t0)
            XCTAssertEqual(line.text, text)
            XCTAssertEqual(line.subject, subject)
        }
    }

    // MARK: The log

    private func entry(_ message: String, _ source: LogSource) -> RouteManager.LogEntry {
        RouteManager.LogEntry(timestamp: t0, level: .success, message: message, source: source)
    }

    func testOnlySocketLinesCarryATag() {
        XCTAssertEqual(LogSource.controlSocket.tag, "via the command line")
        XCTAssertNil(LogSource.app.tag)
        XCTAssertEqual(RouteManager.LogEntry(timestamp: t0, level: .info, message: "x").source, .app)
    }

    /// The `logs` verb answers with the verb line's old text, so a script sees what it saw.
    func testTheSocketLogsReplyKeepsTheOldVerbLine() {
        XCTAssertEqual(entry("Control: 'domain.add' applied", .controlSocket).socketReplyMessage,
                       "Control: 'domain.add' applied via the command line")
        XCTAssertEqual(entry("Added domain: en.wikipedia.org", .controlSocket).socketReplyMessage, "Added domain: en.wikipedia.org")
        XCTAssertEqual(entry("Control: 'domain.add' applied", .app).socketReplyMessage, "Control: 'domain.add' applied")
    }

    func testCopyKeepsTheTag() {
        let text = LogFilter.clipboardText([entry("Added domain: en.wikipedia.org", .controlSocket),
                                            entry("Added domain: news.ycombinator.com", .app)],
                                           timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, """
            [2026-09-21 14:13:20] [SUCCESS] Added domain: en.wikipedia.org (via the command line)
            [2026-09-21 14:13:20] [SUCCESS] Added domain: news.ycombinator.com
            """)
    }

    func testTheSocketFilterShowsOnlySocketLines() {
        let log = [entry("Config saved", .controlSocket), entry("Added domain: en.wikipedia.org", .controlSocket),
                   entry("DNS refresh complete: 2 added, 1 removed", .app)]
        let filter = LogFilter(onlyControlSocket: true)
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.apply(log).map(\.message), ["Config saved", "Added domain: en.wikipedia.org"])
        XCTAssertEqual(LogFilter(query: "domain", onlyControlSocket: true).apply(log).count, 1)
        XCTAssertEqual(LogFilter().apply(log).count, 3)
        XCTAssertEqual(filter.countLine(shown: 2, total: 3), "2 of 3 entries")
    }

    func testTheSocketFilterSaysWhenNothingCameThrough() {
        XCTAssertEqual(LogFilter(onlyControlSocket: true).emptyLine(shown: 0), "Nothing came through the command line.")
        XCTAssertEqual(LogFilter(level: .errors, onlyControlSocket: true).emptyLine(shown: 0),
                       "Nothing from the command line matches this filter.")
        XCTAssertEqual(LogFilter(query: "zoom", onlyControlSocket: true).emptyLine(shown: 0),
                       "Nothing from the command line matches this filter.")
        XCTAssertNil(LogFilter(onlyControlSocket: true).emptyLine(shown: 1))
    }

    // MARK: Spanish and French

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    private let everyKind: [OutsideChange.Kind] = [
        .addedDomain("en.wikipedia.org"), .removedDomain("x.org"), .turnedOn("Telegram"), .turnedOff("Slack"),
        .switchedMode(.vpnOnly), .removedAllRoutes(routesLeft: 0), .removedAllRoutes(routesLeft: 2),
        .changedRoutes, .changedRules,
    ]

    func testEveryStringIsTranslated() throws {
        let en = try lproj("en")
        let later = t0.addingTimeInterval(150)
        for name in ["es", "fr"] {
            let bundle = try lproj(name)
            var pairs: [(String, String)] = everyKind.map {
                (OutsideChange(kind: $0, at: t0).line(now: later, in: en).text,
                 OutsideChange(kind: $0, at: t0).line(now: later, in: bundle).text)
            }
            pairs.append((LogSource.controlSocket.tag(in: en) ?? "", LogSource.controlSocket.tag(in: bundle) ?? ""))
            pairs.append((LogSource.tagHelp(in: en), LogSource.tagHelp(in: bundle)))
            pairs.append((OutsideChange.help(in: en), OutsideChange.help(in: bundle)))
            pairs.append((LogFilter.sourceTokenTitle(in: en), LogFilter.sourceTokenTitle(in: bundle)))
            pairs.append((LogFilter.sourceTokenHelp(in: en), LogFilter.sourceTokenHelp(in: bundle)))
            for f in [LogFilter(onlyControlSocket: true), LogFilter(level: .errors, onlyControlSocket: true)] {
                pairs.append((f.emptyLine(shown: 0, in: en) ?? "", f.emptyLine(shown: 0, in: bundle) ?? ""))
            }
            for (english, translated) in pairs {
                XCTAssertFalse(english.isEmpty)
                XCTAssertNotEqual(translated, english, "\(name) has no entry for \"\(english)\"")
                XCTAssertFalse(translated.contains("%"), "\(name): \(translated)")
            }
            // The name and the age land in the sentence, translated, in their own places.
            for kind in everyKind {
                let line = OutsideChange(kind: kind, at: t0).line(now: later, in: bundle)
                // A missing entry falls back to the English sentence around a translated age,
                // which the inequality above cannot see.
                XCTAssertFalse(line.text.hasPrefix("Last change"), "\(name) has no entry for \(kind): \(line.text)")
                XCTAssertTrue(line.text.contains(DropdownCopy.age(since: t0, now: later, in: bundle)), "\(name): \(line.text)")
                if let subject = line.subject { XCTAssertTrue(line.text.contains(subject), "\(name): \(line.text)") }
            }
        }
        XCTAssertEqual(OutsideChange(kind: .addedDomain("en.wikipedia.org"), at: t0).line(now: later, in: try lproj("es")).text,
                       "Último cambio: se añadió en.wikipedia.org desde la línea de comandos, hace 2 min")
        XCTAssertEqual(OutsideChange(kind: .switchedMode(.vpnOnly), at: t0).line(now: later, in: try lproj("fr")).text,
                       "Dernière modification : passage au mode VPN uniquement via la ligne de commande, il y a 2 min")
    }
}

/// Real requests through ControlSurface.handle: what they tag and what they leave in the footer.
/// The helper is never ready under XCTest and the VPN is never connected, so nothing touches
/// the kernel.
@MainActor
final class OutsideChangeSocketTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedActiveRoutes: [RouteManager.ActiveRoute] = []
    private var savedLogs: [RouteManager.LogEntry] = []
    private var savedVPNConnected = false
    private var savedChange: OutsideChange?

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() async throws {
        savedConfig = rm.config
        savedActiveRoutes = rm.activeRoutes
        savedLogs = rm.recentLogs
        savedVPNConnected = rm.isVPNConnected
        savedChange = rm.lastOutsideChange
        rm.isVPNConnected = false

        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        cfg.services = [RouteManager.ServiceEntry(id: "svc_a", name: "Service A", enabled: true,
                                                  domains: ["a.example.com"], ipRanges: [])]
        rm.config = cfg
        rm.activeRoutes = []
        rm.recentLogs = []
        rm.lastOutsideChange = nil
    }

    override func tearDown() async throws {
        rm.config = savedConfig
        rm.activeRoutes = savedActiveRoutes
        rm.recentLogs = savedLogs
        rm.isVPNConnected = savedVPNConnected
        rm.lastOutsideChange = savedChange
        rm.cancelAllRetries()
        ClassicControl.busyWait = 30
        ClassicControl.routeOperationRunning = { RouteManager.shared.isApplyingRoutes }
    }

    private func send(_ cmd: String, _ args: [String: String]? = nil) async -> ControlResponse {
        await ControlSurface.handle(ControlRequest(cmd: cmd, args: args))
    }

    func testASocketAddIsTaggedInTheLogAndNamedInTheFooter() async {
        let resp = await send("domain.add", ["domain": "https://En.Wikipedia.org/wiki/Main"])
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(rm.lastOutsideChange?.kind, .addedDomain("en.wikipedia.org"))

        // The line the verb wrote, and the lines of the RouteManager method it shares with the
        // app's own Add button.
        for message in ["Added domain: en.wikipedia.org", "Config saved", "Control: 'domain.add' applied"] {
            let line = rm.recentLogs.first { $0.message == message }
            XCTAssertEqual(line?.source, .controlSocket, "\(message) in \(rm.recentLogs.map(\.message))")
        }

        rm.log(.info, "A line from the app")
        XCTAssertEqual(rm.recentLogs.first?.source, .app)
    }

    func testAModeSwitchThroughCommandRouterIsNamedToo() async {
        let resp = await send("mode", ["mode": "vpnOnly"])
        XCTAssertTrue(resp.ok, "\(String(describing: resp.error))")
        XCTAssertEqual(rm.lastOutsideChange?.kind, .switchedMode(.vpnOnly))
        XCTAssertTrue(rm.recentLogs.contains { $0.message == "Control: 'mode' applied" && $0.source == .controlSocket })
    }

    func testTheLogsVerbAnswersAsBefore() async throws {
        _ = await send("domain.add", ["domain": "example.org"])
        let resp = await send("logs", ["limit": "200"])
        let messages = try XCTUnwrap(resp.result?.logs).map(\.message)
        XCTAssertTrue(messages.contains("Control: 'domain.add' applied via the command line"), "\(messages)")
        XCTAssertTrue(messages.contains("Added domain: example.org"), "\(messages)")
    }

    func testAChangeMadeInTheAppClearsTheLine() async {
        _ = await send("domain.add", ["domain": "example.org"])
        XCTAssertNotNil(rm.lastOutsideChange)
        rm.saveConfig()
        XCTAssertNil(rm.lastOutsideChange, "a save outside a socket request is a change made in the app")
    }

    func testARequestThatChangesNothingLeavesTheLastChange() async {
        _ = await send("domain.add", ["domain": "example.org"])
        let named = rm.lastOutsideChange
        XCTAssertNotNil(named)
        let resp = await send("service.enable", ["id": "svc_a"])   // already on
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(rm.lastOutsideChange, named)
        _ = await send("domain.list")
        XCTAssertEqual(rm.lastOutsideChange, named)
    }

    func testAFailedRequestIsNoChange() async {
        let resp = await send("domain.rm", ["domain": "nowhere.example"])
        XCTAssertFalse(resp.ok)
        XCTAssertNil(rm.lastOutsideChange)
    }

    /// An app save while a request runs may be the later change, so the request does not name
    /// itself: a missing line, never a false one.
    func testAnAppSaveWhileARequestRunsKeepsTheRequestOutOfTheFooter() async throws {
        rm.config.domains = [DomainEntry(domain: "example.com")]
        ClassicControl.busyWait = 2
        var holding = true
        ClassicControl.routeOperationRunning = { holding }

        let request = Task { await self.send("domain.disable", ["domain": "example.com"]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        rm.saveConfig()
        holding = false
        let resp = await request.value
        XCTAssertTrue(resp.ok)
        XCTAssertNil(rm.lastOutsideChange)
    }

    /// Two requests that overlap interleave at every await, so one that changed nothing would
    /// find the other's change in its before/after comparison and claim it. Neither names itself.
    func testOverlappingRequestsKeepEachOtherOutOfTheFooter() async throws {
        rm.lastOutsideChange = OutsideChange(kind: .addedDomain("old.example"), at: Date())
        ClassicControl.busyWait = 2
        var holding = true
        ClassicControl.routeOperationRunning = { holding }

        let noOp = Task { await self.send("service.enable", ["id": "svc_a"]) }   // already on
        try await Task.sleep(nanoseconds: 300_000_000)
        let mode = await send("mode", ["mode": "vpnOnly"])
        // The mode switch joined a request that is still running, so it does not name itself
        // either, even though it finishes first.
        XCTAssertNil(rm.lastOutsideChange, "the request that joined named itself")
        holding = false
        let resp = await noOp.value
        XCTAssertTrue(mode.ok, "\(String(describing: mode.error))")
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(rm.config.routingMode, .vpnOnly)
        XCTAssertNil(rm.lastOutsideChange, "a missing line, never a false or stale one")

        // Once neither runs, the next request names itself again.
        _ = await send("domain.add", ["domain": "example.org"])
        XCTAssertEqual(rm.lastOutsideChange?.kind, .addedDomain("example.org"))
    }

    /// The removal line goes for good once the route count moves. It does not come back when
    /// the app's own removal brings the count back to the number the line holds.
    func testARemovalLineStaysGoneWhenTheCountComesBack() {
        let route = RouteManager.ActiveRoute(destination: "93.184.216.34", gateway: "192.168.1.1",
                                             source: "s", timestamp: Date())
        rm.lastOutsideChange = OutsideChange(kind: .removedAllRoutes(routesLeft: 0), at: Date())
        rm.activeRoutes = []
        XCTAssertNotNil(rm.lastOutsideChange, "the count did not move")
        rm.activeRoutes = [route]
        XCTAssertNil(rm.lastOutsideChange, "a refresh brought routes back")
        rm.activeRoutes = []
        XCTAssertNil(rm.lastOutsideChange, "Remove All Routes in the app is not the command line")

        rm.lastOutsideChange = OutsideChange(kind: .addedDomain("x.org"), at: Date())
        rm.activeRoutes = [route]
        XCTAssertEqual(rm.lastOutsideChange?.kind, .addedDomain("x.org"), "only a removal is about the count")
    }

    /// The mark follows the request, not the clock: a line the app writes while a request is
    /// suspended (here, waiting for a route operation) is the app's, untagged.
    func testALineTheAppWritesWhileARequestWaitsIsNotTagged() async throws {
        rm.config.domains = [DomainEntry(domain: "example.com")]
        ClassicControl.busyWait = 2
        var holding = true
        ClassicControl.routeOperationRunning = { holding }

        let request = Task { await self.send("domain.disable", ["domain": "example.com"]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        rm.log(.info, "The user pressed a button")
        holding = false
        let resp = await request.value
        XCTAssertTrue(resp.ok)

        let button = try XCTUnwrap(rm.recentLogs.first { $0.message == "The user pressed a button" })
        XCTAssertEqual(button.source, .app)
        XCTAssertEqual(rm.recentLogs.first { $0.message == "Control: 'domain.disable' applied" }?.source, .controlSocket)
        XCTAssertEqual(rm.lastOutsideChange?.kind, .turnedOff("example.com"))
    }
}
