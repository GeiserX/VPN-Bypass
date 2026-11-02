// StatusLogsPageTests.swift
// The Status and Logs pages on the shared components (rework step 9, section 3.4 of
// docs/design/APP-REWORK-PROPOSALS.md), and the Status page's "Where does this site go?" field
// (idea 2). The model tests pin the order, the verdict and the answer's look; the view tests
// open a real Settings window and read it the way VoiceOver does.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

final class StatusLogsPageModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ edit: (inout DropdownStatus.Input) -> Void) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "WireGuard", helperReady: true, mode: .bypass,
            enabledServices: 4, enabledDomains: 2, enabledRules: 0, installedRoutes: 0,
            pending: nil, lastRouteChange: nil, lastDNSRefresh: nil, nextDNSRefresh: nil, autoDNSRefresh: true)
        edit(&i)
        return i
    }

    // MARK: The real blocker first

    /// With the helper down and no VPN, the verdict is the helper, not "No VPN connected".
    func testTheHelperIsTheVerdictEvenWithNoVPN() {
        let s = StatusPage.summary(input { $0.isVPNConnected = false; $0.helperReady = false }, now: now)
        XCTAssertEqual(s.title, "Not working")
        XCTAssertEqual(s.sentence, "The helper is not running, so no route can change.")
        XCTAssertEqual(s.note, "Nothing is routed until a VPN connects.", "no VPN is still said, under the verdict")
        let kept = StatusPage.summary(input { $0.isVPNConnected = false; $0.helperReady = false; $0.installedRoutes = 62 }, now: now)
        XCTAssertEqual(kept.note, "62 addresses stay routed for when it reconnects.", "what stays routed is still said")
        XCTAssertEqual(s.tone, .warn)

        let control = StatusPage.summary(input { $0.isVPNConnected = false }, now: now)
        XCTAssertEqual(control.title, "No VPN connected", "control: with the helper ready, no VPN is the verdict")
        let starting = StatusPage.summary(input { $0.isVPNConnected = false; $0.helperReady = false; $0.isStarting = true }, now: now)
        XCTAssertEqual(starting.title, "Starting…", "at launch nothing is known yet")
    }

    /// A helper that is not ready opens the page; a ready one sits with the other facts.
    func testTheHelperSectionComesFirstWhenItIsNotReady() {
        XCTAssertEqual(StatusPage.sections(helperReady: false).first, .helper)
        let ready = StatusPage.sections(helperReady: true)
        XCTAssertEqual(ready.first, .problems)
        XCTAssertLessThan(try XCTUnwrap(ready.firstIndex(of: .siteCheck)), try XCTUnwrap(ready.firstIndex(of: .helper)))
        for order in [ready, StatusPage.sections(helperReady: false)] {
            XCTAssertEqual(Set(order).count, 9, "every section once")
            XCTAssertEqual(order.last, .warnings)
        }
    }

    // MARK: Where does this site go?

    private func probe(_ address: String, via interface: String, _ answer: PathCheck.Answer = .connected) -> PathCheck.Probe {
        PathCheck.Probe(address: address, routeInterface: interface, answer: answer, latencyMs: answer.answered ? 12 : nil)
    }

    private func unlisted(via interface: String) -> SiteRouteAnswer {
        SiteRoute.answer(host: "cdn.example.net", mode: .bypass, addresses: ["203.0.113.7"],
                         found: SiteRoute.Found(match: .none, expected: .tunnel("utun4")),
                         probes: [probe("203.0.113.7", via: interface)], control: nil, vpnConnected: true)
    }

    func testAnUnlistedSiteOffersTheModesAdd() throws {
        let answer = unlisted(via: "utun4")
        XCTAssertEqual(try XCTUnwrap(StatusPage.siteAdd(answer, mode: .bypass)).title, "Add to Bypass")
        XCTAssertEqual(try XCTUnwrap(StatusPage.siteAdd(answer, mode: .bypass)).help, "Add to the Bypass list")
        XCTAssertEqual(try XCTUnwrap(StatusPage.siteAdd(answer, mode: .vpnOnly)).title, "Add to VPN Only")
        XCTAssertEqual(try XCTUnwrap(StatusPage.siteAdd(answer, mode: .custom)).title, "Send Direct")

        let listed = SiteRoute.answer(host: "en.wikipedia.org", mode: .bypass, addresses: ["198.51.100.4"],
                                      found: SiteRoute.Found(match: .route, entry: "en.wikipedia.org",
                                                             routedDestination: "198.51.100.4", expected: .physical),
                                      probes: [probe("198.51.100.4", via: "en0")], control: nil, vpnConnected: true)
        XCTAssertNil(StatusPage.siteAdd(listed, mode: .bypass), "a listed site has nothing to add")
    }

    func testTheAnswersGlyphMarksOnlyWhatNeedsALook() {
        XCTAssertEqual(StatusPage.siteGlyph(unlisted(via: "utun4").verdict).needsAttention, false)
        XCTAssertEqual(StatusPage.siteGlyph(unlisted(via: "en0").verdict).needsAttention, true, "the wrong way needs a look")
        for verdict: SiteRouteAnswer.Verdict in [.noAnswer, .wrongWay, .unknown, .checkBroken, .unresolved] {
            XCTAssertTrue(StatusPage.siteGlyph(verdict).needsAttention, "\(verdict)")
        }
        for verdict: SiteRouteAnswer.Verdict in [.ok, .notChecked, .noVPN] {
            XCTAssertFalse(StatusPage.siteGlyph(verdict).needsAttention, "\(verdict)")
        }
    }

    @MainActor
    func testTheModelKeepsWhatItWasAsked() {
        let empty = SiteRouteModel()
        XCTAssertNil(empty.checkedQuery, "nothing was asked yet, so no 'not a host' line")
        let seeded = SiteRouteModel(query: "cdn.example.net", answer: unlisted(via: "utun4"))
        XCTAssertEqual(seeded.checkedQuery, "cdn.example.net")
        XCTAssertEqual(seeded.answer?.host, "cdn.example.net")
    }

    /// Add checks the site again only after the route apply it started is over; a check
    /// before that would see the site listed but leaving the old way.
    @MainActor
    func testTheRecheckAfterAddWaitsForTheApply() async {
        var polls = 0
        await StatusPage.waitForRouteApply(start: .zero, poll: .milliseconds(1), limit: .seconds(5)) {
            polls += 1
            return polls < 4
        }
        XCTAssertEqual(polls, 4, "it polled until the apply was over")

        var asked = 0
        let clock = ContinuousClock(), began = clock.now
        await StatusPage.waitForRouteApply(start: .zero, poll: .milliseconds(5), limit: .milliseconds(50)) {
            asked += 1
            return true
        }
        XCTAssertLessThan(clock.now - began, .seconds(2), "an apply that never ends does not hold the check forever")
        XCTAssertGreaterThan(asked, 1)
    }

    /// The first look for an apply waits out the start delay, so an apply the add queued in
    /// a task has begun by then.
    @MainActor
    func testTheWaitHoldsTheFirstPollUntilTheStartDelayEnds() async {
        var firstPoll: ContinuousClock.Instant?
        let clock = ContinuousClock(), began = clock.now
        await StatusPage.waitForRouteApply(start: .milliseconds(50), poll: .milliseconds(1), limit: .seconds(5)) {
            firstPoll = firstPoll ?? clock.now
            return false
        }
        guard let first = firstPoll else { return XCTFail("the wait never checked for an apply") }
        XCTAssertGreaterThanOrEqual(first - began, .milliseconds(50), "the first check waits for the start delay")
    }

    /// An edit to the field hides the answer, so Add never adds the site asked before.
    @MainActor
    func testAnEditHidesTheAnswerForTheOldText() {
        let model = SiteRouteModel(query: "cdn.example.net", answer: unlisted(via: "utun4"))
        XCTAssertTrue(model.answersQuery)
        model.query = " cdn.example.net "
        XCTAssertTrue(model.answersQuery, "spaces around the same text change nothing")
        model.query = "other.example.org"
        XCTAssertFalse(model.answersQuery, "the answer is for the old text")
    }

    // MARK: Logs

    func testLogsTakeTheTitleBarSearch() {
        XCTAssertTrue(SettingsSidebar.isSearchable(.logs))
        let filter = LogsTab.effectiveFilter(LogFilter(level: .warnings, onlySource: .controlSocket), search: "wiki")
        XCTAssertEqual(filter, LogFilter(level: .warnings, query: "wiki", onlySource: .controlSocket),
                       "the search joins the page's level and source")
    }

    /// Green is for live routing only, so a success line is grey; a warning and an error keep
    /// their colour.
    func testLogLevelsUseTheColourRoles() {
        XCTAssertEqual(LogRow.levelColor(.success), Theme.textSecondary)
        XCTAssertNotEqual(LogRow.levelColor(.success), Theme.live)
        XCTAssertEqual(LogRow.levelColor(.warning), Theme.attention)
        XCTAssertEqual(LogRow.levelColor(.error), Theme.failure)
    }

    /// VoiceOver says each line's level, so a warning does not sound like an info line.
    func testEveryLogLevelHasASpokenName() {
        let levels: [RouteManager.LogEntry.LogLevel] = [.info, .success, .warning, .error]
        XCTAssertEqual(levels.map { LogRow.levelName($0) }, ["Info", "Success", "Warning", "Error"])
    }
}

@MainActor
final class StatusLogsPageViewTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var window: NSWindow?
    private var saved: (config: RouteManager.Config, logs: [RouteManager.LogEntry], lastPage: String?)!

    override func setUp() async throws {
        saved = (rm.config, rm.recentLogs, UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey))
        SettingsPageRequest.shared.page = nil
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        rm.config = saved.config
        rm.recentLogs = saved.logs
        UserDefaults.standard.set(saved.lastPage, forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
        StatusTab.siteCheckForScreenshots = nil
        SettingsView.searchForScreenshots = nil
    }

    func testStatusHasTheSiteFieldAndItsAnswer() {
        var config = rm.config
        config.routingMode = .bypass
        config.schemaVersion = 1
        rm.config = config
        let answer = SiteRoute.answer(host: "cdn.example.net", mode: .bypass, addresses: ["203.0.113.7"],
                                      found: SiteRoute.Found(match: .none, expected: .tunnel("utun4")),
                                      probes: [PathCheck.Probe(address: "203.0.113.7", routeInterface: "utun4",
                                                               answer: .connected, latencyMs: 20)],
                                      control: nil, vpnConnected: true)
        StatusTab.siteCheckForScreenshots = ("cdn.example.net", answer)
        let texts = texts(on: .status)
        XCTAssertTrue(texts.contains("Where does this site go?"), "no site field section: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Site to check"), "the field has no spoken name")
        XCTAssertTrue(texts.contains("Check the site"), "the Check button has no spoken name")
        XCTAssertTrue(texts.contains { $0.contains(answer.summary) }, "the one-sentence answer is missing")
        XCTAssertTrue(texts.contains("Add to the Bypass list"), "an unlisted site offers no Add")
    }

    /// The Tunnels Refresh is a plain button, not a blue link.
    func testTheTunnelsRefreshIsAPlainButton() throws {
        let tunnels = try ReworkSource.body(of: "private var tunnelsSection", in: "StatusTab.swift")
        XCTAssertTrue(tunnels.contains("Button(String(localized: \"Refresh\"))"))
        XCTAssertFalse(tunnels.contains(".buttonStyle(.link)"), "Refresh is still drawn as a link")
    }

    func testLogsUseTheTitleBarSearchWithCopyAndClear() throws {
        let now = Date()
        rm.recentLogs = [
            RouteManager.LogEntry(timestamp: now, level: .success, message: "Added domain: en.wikipedia.org"),
            RouteManager.LogEntry(timestamp: now, level: .info, message: "Config saved"),
            RouteManager.LogEntry(timestamp: now, level: .warning, message: "DNS refresh slow"),
        ]
        SettingsView.searchForScreenshots = "wiki"
        let texts = texts(on: .logs)
        XCTAssertTrue(texts.contains("1 of 3 entries"), "the title bar search does not filter the log: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Copy"))
        XCTAssertTrue(texts.contains("Clear"))
        let window = try XCTUnwrap(window)
        // One field: the page header's, named for the page. The page draws none of its own.
        let searchFields = all(in: window.contentView!) { $0 is NSSearchField }
        XCTAssertEqual(searchFields.count, 1, "the page still draws its own search field")
        XCTAssertEqual((searchFields.first as? NSSearchField)?.placeholderString, "Search Logs")
    }

    // MARK: - Helpers

    private func settle(_ window: NSWindow) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func all(in view: NSView, where match: (NSView) -> Bool) -> [NSView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { all(in: $0, where: match) }
    }

    /// Every label, title and value in the window, as RulesRoutesPageViewTests reads it.
    private func texts(on page: SettingsView.SettingsTab) -> Set<String> {
        SettingsPageRequest.shared.page = page
        let window = SettingsWindowController.makeWindow()
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        settle(window)
        XCTAssertEqual(window.title, page.name)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasClient = (NSApplication.shared.accessibilityAttributeValue(attribute) as? Bool) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApplication.shared.accessibilitySetValue(wasClient, forAttribute: attribute) }
        settle(window)
        var found = Set<String>()
        func walk(_ element: Any, depth: Int) {
            guard depth < 80, let element = element as? NSObject else { return }
            func get(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
            }
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityPlaceholderValue"] {
                if let text = get(name) as? String, !text.isEmpty { found.insert(text) }
            }
            (get("accessibilityChildren") as? [Any] ?? []).forEach { walk($0, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }
}
