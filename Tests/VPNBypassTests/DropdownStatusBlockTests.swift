// DropdownStatusBlockTests.swift
// Step 3 of the app rework: the dropdown's three-line status block on one `DropdownStatus`, its
// chip, the footer, the width by language, and Status > Problems, where "Show" lands.
//
// The problem it locks down: the dropdown worked out its state in four places that disagreed.
// With the helper down a banner said nothing was routed while the line under Refresh said
// "62 addresses routed, none failed", and "7 failed" named no failure anywhere in the app.

import XCTest
@testable import VPNBypassCore

final class DropdownStatusBlockTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "WireGuard", helperReady: true, mode: .bypass,
            enabledServices: 4, enabledDomains: 2, enabledRules: 0, installedRoutes: 62,
            pending: nil,
            lastRouteChange: .init(kind: .applied, at: now.addingTimeInterval(-24), routeCount: 62, failedCount: 0),
            lastDNSRefresh: now.addingTimeInterval(-12 * 60),
            nextDNSRefresh: now.addingTimeInterval(18 * 60),
            autoDNSRefresh: true)
        edit(&i)
        return i
    }

    private func status(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus {
        DropdownStatus.make(input(edit), now: now)
    }

    // MARK: The block, as the mockup draws it

    func testOnIsThreeLinesWithTheNumbers() {
        let s = status()
        XCTAssertEqual(s.chip, .on)
        XCTAssertEqual(s.headline, "WireGuard connected")
        XCTAssertEqual(s.sentence, "4 services and 2 domains skip the VPN.")
        XCTAssertEqual(s.line3, .init(text: "62 addresses · applied 24 s ago · DNS again in 18 min"))
        XCTAssertNil(s.line3.action, "nothing to do when all is well")
    }

    /// With the helper down it never says "nothing is routed": the routes it added stay in the
    /// kernel, so line 3 says how many, with Fix….
    func testHelperDownSaysWhatIsStillInPlace() {
        let s = status { $0.helperReady = false }
        XCTAssertEqual(s.chip, .notRouting)
        XCTAssertEqual(s.sentence, "The helper is not running, so no route can change.")
        XCTAssertEqual(s.line3, .init(text: "62 addresses from before are still routed.", isProblem: true, action: .fix))
        XCTAssertEqual(status { $0.helperReady = false; $0.installedRoutes = 1 }.line3.text,
                       "1 address from before is still routed.")
        XCTAssertEqual(status { $0.helperReady = false; $0.installedRoutes = 0 }.line3.text, "No address is routed.")
        for text in [s.headline, s.sentence, s.line3.text] {
            XCTAssertFalse(text.lowercased().contains("nothing is routed"), text)
            XCTAssertFalse(text.contains("none failed"), "A2: no past apply over a stopped helper: \(text)")
        }
    }

    /// Failures name their count on line 3 with Show, which opens Status > Problems.
    func testPartlyRoutedOffersShow() {
        let s = status {
            $0.lastRouteChange = .init(kind: .applied, at: self.now.addingTimeInterval(-64), routeCount: 62, failedCount: 7)
        }
        XCTAssertEqual(s.chip, .partlyRouted)
        XCTAssertTrue(s.isPartial)
        XCTAssertEqual(s.line3, .init(text: "62 addresses, 7 failed · 1 min ago", isProblem: true, action: .show))
        // With no failed apply, line 3 says the first other reason, still with Show.
        let empty = status { $0.entriesWithoutAddresses = 1 }
        XCTAssertEqual(empty.line3, .init(text: "1 entry has no addresses.", isProblem: true, action: .show))
        let wrongWay = status { $0.lastCheckCount = 5; $0.lastCheckWrongWay = 2 }
        XCTAssertEqual(wrongWay.line3.action, .show)
    }

    /// Nothing routed with a failed apply behind it offers Show; with nothing failed there is
    /// nothing to show.
    func testNothingRoutedShowsOnlyWhenSomethingFailed() {
        let failed = status {
            $0.installedRoutes = 0
            $0.lastRouteChange = .init(kind: .applied, at: self.now.addingTimeInterval(-5), routeCount: 0, failedCount: 3)
        }
        XCTAssertEqual(failed.chip, .notRouting)
        XCTAssertEqual(failed.line3.action, .show)
        XCTAssertTrue(failed.line3.isProblem)
        let quiet = status { $0.installedRoutes = 0; $0.lastRouteChange = nil }
        XCTAssertEqual(quiet.chip, .notRouting)
        XCTAssertNil(quiet.line3.action)
    }

    /// No VPN is an ordinary state: ○ Off, grey, and line 3 says what connecting does here.
    func testDisconnectedIsGreyAndSaysWhatConnectingDoes() {
        for (mode, text) in [(DropdownCopy.Mode.bypass, "Your list skips the VPN once one connects."),
                             (.vpnOnly, "Your list goes through the VPN once one connects."),
                             (.custom, "Your rules apply once a VPN connects.")] {
            let s = status { $0.isVPNConnected = false; $0.mode = mode }
            XCTAssertEqual(s.chip, .off, "\(mode)")
            XCTAssertEqual(s.tone, .idle, "\(mode)")
            XCTAssertEqual(s.line3, .init(text: text), "\(mode)")
            XCTAssertFalse(s.line3.text.contains("\n"), "line 3 is one line")
        }
    }

    /// Every state maps to one chip, and only On is green.
    func testEveryStateHasItsChip() {
        let settling = RouteManager.PendingReconnectApply(reason: .settling, connectedAt: now,
                                                           appliesAt: now.addingTimeInterval(30))
        let held = RouteManager.PendingReconnectApply(reason: .heldBack(strikes: 3), connectedAt: now,
                                                       appliesAt: now.addingTimeInterval(300))
        let killSwitch = VPNKillSwitch(name: "Proton VPN", includeAllNetworks: true, enforceRoutes: false, excludeLocalNetworks: false)
        let table: [(String, (inout DropdownStatus.Input) -> Void, StatusChip.Kind)] = [
            ("starting", { $0.isStarting = true }, .waiting),
            ("no VPN", { $0.isVPNConnected = false }, .off),
            ("helper down", { $0.helperReady = false }, .notRouting),
            ("kill switch", { $0.killSwitch = killSwitch }, .notRouting),
            ("waiting", { $0.pending = settling; $0.lastRouteChange = nil }, .waiting),
            ("held back", { $0.pending = held; $0.lastRouteChange = nil }, .waiting),
            ("not set up", { $0.installedRoutes = 0; $0.nothingConfigured = true }, .off),
            ("nothing routed", { $0.installedRoutes = 0 }, .notRouting),
            ("partly", { $0.entriesWithoutAddresses = 2 }, .partlyRouted),
            ("on", { _ in }, .on),
        ]
        for (name, edit, chip) in table {
            let s = status(edit)
            XCTAssertEqual(s.chip, chip, name)
            XCTAssertFalse(s.headline.isEmpty, name)
            XCTAssertFalse(s.sentence.isEmpty, name)
            XCTAssertEqual(s.chip.color == Theme.live, chip == .on, "\(name): only On is green")
        }
    }

    // MARK: Width by language

    func testTheWidthGrowsWithTheLanguage() {
        XCTAssertEqual(DropdownLayout.width(language: "en"), 340)
        XCTAssertEqual(DropdownLayout.width(language: nil), 340)
        XCTAssertGreaterThan(DropdownLayout.width(language: "es"), DropdownLayout.width(language: "en"))
        XCTAssertGreaterThan(DropdownLayout.width(language: "fr-CA"), DropdownLayout.width(language: "en"))
        for language in ["en", "es", "fr", "de", "fr-FR"] {
            let width = DropdownLayout.width(language: language)
            XCTAssertTrue((DropdownLayout.minWidth...DropdownLayout.maxWidth).contains(width), "\(language): \(width)")
        }
    }

    // MARK: Spoken names and translations

    func testTheButtonsHaveSpokenNamesInEveryLanguage() throws {
        XCTAssertEqual(DropdownStatus.Line3.spokenName(.fix), "Fix the helper in Settings > Status")
        XCTAssertEqual(DropdownStatus.Line3.spokenName(.show), "Show the problems in Settings > Status")
        for language in ["es", "fr"] {
            let bundle = try ReworkSource.lproj(language)
            for action in [DropdownStatus.Line3.Action.fix, .show] {
                XCTAssertNotEqual(DropdownStatus.Line3.spokenName(action, in: bundle),
                                  DropdownStatus.Line3.spokenName(action), "\(language) \(action)")
            }
            XCTAssertNotEqual(RoutedBySource.disconnectedTitle(.bypass, in: bundle), "Kept for when it reconnects", language)
            XCTAssertNotEqual(RoutedBySource.disconnectedTitle(.custom, in: bundle), "Still routed", language)
        }
    }

    // MARK: The dropdown's views

    /// One source of truth: the banner, the result line and the route-check card are gone from
    /// the dropdown, and the block reads its three lines as three VoiceOver elements.
    func testTheDropdownHasOneStatusBlock() throws {
        let menu = try ReworkSource.body(of: "struct MenuContent: View", in: "MenuBarViews.swift")
        for gone in ["helperDownBanner", "routeChangeLine", "RouteCheckCard(", "StatusHeader(", "StatusPill(",
                     "actionButtons", "loadingContent", ".frame(width: 340)", "systemImage: \"power\""] {
            XCTAssertFalse(menu.contains(gone), "MenuContent still has \(gone)")
        }
        XCTAssertTrue(menu.contains("StatusBlock(status: status)"))
        XCTAssertTrue(menu.contains("StatusChip(state: status.chip)"))
        XCTAssertTrue(menu.contains(".frame(width: DropdownLayout.current)"))

        let block = try ReworkSource.body(of: "struct StatusBlock: View", in: "MenuBarViews.swift")
        XCTAssertFalse(block.contains(".accessibilityElement(children: .combine)"),
                       "the block is read line by line, not as one long element")
        XCTAssertEqual(block.components(separatedBy: "Text(status.").count - 1, 3, "three lines")

        let mode = try ReworkSource.body(of: "struct DropdownModeRow: View", in: "MenuBarViews.swift")
        XCTAssertTrue(mode.contains(".pickerStyle(.menu)"), "the mode is a popup")
        XCTAssertFalse(mode.contains(".segmented"))
        XCTAssertFalse(mode.contains("ViewThatFits"), "no stacked fallback for es and fr")

        let status = try ReworkSource.read("StatusTab.swift")
        XCTAssertTrue(status.contains("RouteCheckCard(run: run"), "the route check moved to Status")
        XCTAssertTrue(status.contains("onDismiss: { routeManager.clearRouteCheck() }"), "and can be dismissed")
    }

    func testTheFooterIconsHaveA24PointHitArea() {
        XCTAssertEqual(DropdownIconButton.hitSize, 24)
    }
}

// MARK: - The failures behind the count

final class RouteFailureTests: XCTestCase {

    func testABatchFailureTakesItsEntryAndTheHelpersReason() {
        let sources: [(destination: String, source: String)] = [("192.0.2.1", "Telegram"), ("192.0.2.2", "Zoom"),
                                                                 ("192.0.2.1", "Other")]
        let failures = RouteManager.RouteFailure.batch(.notRouted, failed: ["192.0.2.2", "192.0.2.1"],
                                                       sources: sources, error: "File exists")
        XCTAssertEqual(failures, [
            .init(kind: .notRouted, target: "192.0.2.1", entry: "Telegram", reason: "File exists"),
            .init(kind: .notRouted, target: "192.0.2.2", entry: "Zoom", reason: "File exists"),
        ], "sorted, and an address recorded twice reads as its first entry")
        XCTAssertEqual(RouteManager.RouteFailure.batch(.notRouted, failed: ["192.0.2.9"], sources: [], error: nil),
                       [.init(kind: .notRouted, target: "192.0.2.9", entry: "", reason: "the system refused the route")])
        XCTAssertEqual(RouteManager.RouteFailure.batch(.notRemoved, failed: ["192.0.2.9"], sources: [], error: "")
                        .first?.reason, "the system did not remove it", "an empty error is no reason")
    }

    /// The app refuses the VPN's own gateway before the helper sees the batch; Problems says so.
    func testTheVPNGatewayGetsItsOwnReason() {
        let failures = RouteManager.RouteFailure.batch(.notRouted, failed: ["203.0.113.5/32", "192.0.2.2"],
                                                       sources: [], error: "File exists", vpnGateway: "203.0.113.5")
        XCTAssertEqual(failures.map(\.reason), ["File exists", "it is the VPN's own gateway, which is never rerouted"])
        XCTAssertEqual(RouteManager.RouteFailure.batch(.notRouted, failed: ["203.0.113.5"], sources: [], error: nil,
                                                       vpnGateway: "iface:utun4").first?.reason,
                       "the system refused the route", "an interface gateway has no address to protect")
    }

    func testANameThatDidNotResolveSaysSo() {
        let failures = RouteManager.RouteFailure.unresolved([("zoom.us", "Zoom"), ("zoom.us", "Zoom"), ("a.example", "a.example")])
        XCTAssertEqual(failures, [
            .init(kind: .notResolved, target: "zoom.us", entry: "Zoom", reason: "no answer from DNS"),
            .init(kind: .notResolved, target: "a.example", entry: "a.example", reason: "no answer from DNS"),
        ])
    }

    /// Remove All Routes keeps what it could not remove, and now says which and why.
    @MainActor
    func testARemovalThatFailedNamesEachAddress() async {
        let rm = RouteManager.shared
        let saved = (rm.activeRoutes, rm.lastRouteChange)
        let kernel = FakeKernel(installed: ["192.0.2.1", "192.0.2.2"], failRemovals: true)
        kernel.attach(to: rm)
        defer {
            FakeKernel.detach(from: rm)
            rm.activeRoutes = saved.0
            rm.lastRouteChange = saved.1
        }
        rm.activeRoutes = [.init(destination: "192.0.2.1", gateway: "192.168.1.1", source: "Telegram", timestamp: Date()),
                           .init(destination: "192.0.2.2", gateway: "192.168.1.1", source: "en.wikipedia.org", timestamp: Date())]
        await rm.removeAllRoutes()
        let change = rm.lastRouteChange
        XCTAssertEqual(change?.kind, .removedAll)
        XCTAssertEqual(change?.failedCount, 2)
        XCTAssertEqual(change?.failures, [
            .init(kind: .notRemoved, target: "192.0.2.1", entry: "Telegram", reason: "the system did not remove it"),
            .init(kind: .notRemoved, target: "192.0.2.2", entry: "en.wikipedia.org", reason: "the system did not remove it"),
        ])
    }
}

// MARK: - Status > Problems

final class StatusProblemsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func applied(failed: Int, _ failures: [RouteManager.RouteFailure]) -> RouteManager.RouteChangeOutcome {
        .init(kind: .applied, at: now, routeCount: 60, failedCount: failed, failures: failures)
    }

    func testEveryFailureIsNamedWithItsEntryAndReason() {
        let change = applied(failed: 4, [
            .init(kind: .notResolved, target: "zoom.us", entry: "Zoom", reason: "no answer from DNS"),
            .init(kind: .notResolved, target: "a.example", entry: "a.example", reason: "no answer from DNS"),
            .init(kind: .notRouted, target: "192.0.2.7", entry: "Telegram", reason: "File exists"),
        ])
        let problems = StatusPage.problems(lastChange: change, installed: 60, helperReady: true, withoutAddresses: [])
        XCTAssertEqual(problems.map(\.title), ["zoom.us", "a.example", "192.0.2.7", "1 more failure"])
        XCTAssertEqual(problems.map(\.detail), [
            "Did not resolve, for Zoom: no answer from DNS",
            "Did not resolve: no answer from DNS",
            "Not routed, for Telegram: File exists",
            "Settings > Logs has the details.",
        ])
    }

    func testEntriesWithNoAddressesAreListed() {
        let zoom = RoutedBySource.Row(id: "Zoom", name: "Zoom", icon: .service(id: "zoom"), routeCount: 0, isProblem: true,
                                      addresses: [], hiddenAddresses: 0)
        let fine = RoutedBySource.Row(id: "Telegram", name: "Telegram", icon: .service(id: "telegram"), routeCount: 18,
                                      isProblem: false, addresses: [], hiddenAddresses: 0)
        let problems = StatusPage.problems(lastChange: nil, installed: 60, helperReady: true, withoutAddresses: [fine, zoom])
        XCTAssertEqual(problems.map(\.title), ["Zoom"])
        XCTAssertEqual(problems.first?.kind, .noAddresses)
    }

    /// The page lists only what the dropdown still counts.
    func testNothingIsListedThatTheDropdownDoesNotCount() {
        XCTAssertEqual(StatusPage.problems(lastChange: applied(failed: 0, []), installed: 60, helperReady: true,
                                           withoutAddresses: []), [])
        let failed = applied(failed: 1, [.init(kind: .notRouted, target: "192.0.2.7", entry: "Telegram", reason: "File exists")])
        XCTAssertEqual(StatusPage.problems(lastChange: failed, installed: 60, helperReady: false, withoutAddresses: []), [],
                       "with the helper down a past apply is not reported (A2)")
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 2, failedCount: 2,
            failures: [.init(kind: .notRemoved, target: "192.0.2.1", entry: "Telegram", reason: "the helper is not running")])
        XCTAssertEqual(StatusPage.problems(lastChange: removed, installed: 2, helperReady: false, withoutAddresses: []).first?.detail,
                       "Not removed, for Telegram: the helper is not running", "a failed removal stays, helper or not")
        XCTAssertEqual(StatusPage.problems(lastChange: removed, installed: 9, helperReady: true, withoutAddresses: []), [],
                       "routes came back since, so the removal no longer stands")
    }

    /// Retry after a failed Remove All Routes removes again; applying would put every route back.
    func testRetryRemovesAgainAfterAFailedRemoval() {
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 2, failedCount: 2,
            failures: [.init(kind: .notRemoved, target: "192.0.2.1", entry: "Telegram", reason: "x")])
        XCTAssertEqual(StatusPage.retryAction(lastChange: removed, installed: 2, helperReady: true), .remove)
        XCTAssertEqual(StatusPage.retryAction(lastChange: removed, installed: 9, helperReady: true), .apply,
                       "routes came back since, so the removal no longer stands")
        let failed = applied(failed: 1, [.init(kind: .notRouted, target: "192.0.2.7", entry: "Telegram", reason: "x")])
        XCTAssertEqual(StatusPage.retryAction(lastChange: failed, installed: 60, helperReady: true), .apply)
        XCTAssertEqual(StatusPage.retryAction(lastChange: nil, installed: 60, helperReady: true), .apply)
    }

    /// An address a DNS retry or a later add routed since is no longer a problem.
    func testAnAddressRoutedSinceIsNotListed() {
        let change = applied(failed: 2, [
            .init(kind: .notRouted, target: "192.0.2.7", entry: "Telegram", reason: "File exists"),
            .init(kind: .notRouted, target: "192.0.2.8", entry: "Telegram", reason: "File exists"),
        ])
        let problems = StatusPage.problems(lastChange: change, installed: 60, helperReady: true, withoutAddresses: [],
                                           routes: [.init(destination: "192.0.2.7", source: "Telegram")])
        XCTAssertEqual(problems.map(\.title), ["192.0.2.8"], "and no \"1 more failure\" for the one routed since")
    }

    /// Problems lists every entry with no addresses, past the dropdown's eight rows too.
    func testEveryEntryWithNoAddressesReachesProblems() throws {
        var config = RouteManager.Config()
        config.services = []
        config.domains = (1...10).map { RouteManager.DomainEntry(domain: "site\($0).example") }
        let summary = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: config, routes: [], busy: false))
        XCTAssertEqual(summary.rows.count, RoutedBySource.visibleRows)
        XCTAssertEqual(summary.problemCount, 10)
        let problems = StatusPage.problems(lastChange: nil, installed: 0, helperReady: true,
                                           withoutAddresses: summary.problemRows)
        XCTAssertEqual(problems.count, 10)
        XCTAssertEqual(problems.first?.detail, "No address is routed for it.")
    }

    /// After Remove All Routes the entries it emptied are not problems, so Retry cannot put
    /// back what the user removed; what it could not remove stays listed.
    func testADeliberateRemovalIsNotAProblem() {
        let zoom = RoutedBySource.Row(id: "Zoom", name: "Zoom", icon: .service(id: "zoom"), routeCount: 0, isProblem: true,
                                      addresses: [], hiddenAddresses: 0)
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 0, failedCount: 0)
        XCTAssertEqual(StatusPage.problems(lastChange: removed, installed: 0, helperReady: true, withoutAddresses: [zoom]), [])
        XCTAssertEqual(StatusPage.problems(lastChange: nil, installed: 0, helperReady: true, withoutAddresses: [zoom]).count, 1,
                       "control: without the removal the empty entry is a problem")
        let leftSome = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 1, failedCount: 1,
            failures: [.init(kind: .notRemoved, target: "192.0.2.1", entry: "Telegram", reason: "x")])
        XCTAssertEqual(StatusPage.problems(lastChange: leftSome, installed: 1, helperReady: true, withoutAddresses: [zoom])
                        .map(\.kind), [.notRemoved])
    }

    /// After a Remove All that left routes, Bypass's disconnected list does not call them kept.
    func testAFailedRemovalIsNotKeptForTheReconnect() {
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 2, failedCount: 2)
        XCTAssertEqual(RoutedBySource.disconnectedTitle(.bypass, lastChange: removed), "Still routed")
        XCTAssertEqual(RoutedBySource.disconnectedTitle(.bypass, lastChange: applied(failed: 0, [])),
                       "Kept for when it reconnects")
        XCTAssertEqual(RoutedBySource.disconnectedTitle(.vpnOnly), "Still routed")
    }

    func testTheProblemsWordsAreTranslated() throws {
        let change = applied(failed: 3, [
            .init(kind: .notResolved, target: "zoom.us", entry: "Zoom", reason: "x"),
            .init(kind: .notRouted, target: "192.0.2.7", entry: "", reason: "x"),
        ])
        let english = StatusPage.problems(lastChange: change, installed: 60, helperReady: true, withoutAddresses: [])
        for language in ["es", "fr"] {
            let bundle = try ReworkSource.lproj(language)
            let translated = StatusPage.problems(lastChange: change, installed: 60, helperReady: true,
                                                 withoutAddresses: [], bundle: bundle)
            for (a, b) in zip(english, translated) {
                XCTAssertNotEqual(a.detail, b.detail, "\(language): \(a.detail)")
            }
        }
    }
}
