// PauseTests.swift
// Pause (flow fix 2, idea 4): which modes may pause, what the dropdown says, the lengths
// `vpnb` takes, how Resume waits, and, against a fake kernel, that nothing puts a route back
// while paused: not an apply, a DNS refresh, a reconnect, an edit or a wildcard.

import XCTest
@testable import VPNBypassCore

// MARK: - Pure parts

final class PauseGateTests: XCTestCase {

    private func customConfig(_ rules: [(Egress, MatchType, String)], extraRoutes: [Route] = []) -> RouteManager.Config {
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault)
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        cfg.routes = [direct, vpn, proxy] + extraRoutes
        cfg.rules = rules.enumerated().map { i, r in
            let id: UUID
            switch r.0 {
            case .direct: id = direct.id
            case .vpnDefault: id = vpn.id
            default: id = proxy.id
            }
            return Rule(matchType: r.1, pattern: r.2, routeId: id, order: i)
        }
        // The proxy route stays off unless a test turns it on: an enabled one runs a listener.
        cfg.routes[2].enabled = rules.contains { $0.0 == .proxySOCKS5 }
        cfg.defaultRouteId = direct.id
        return cfg
    }

    func testBypassMayPause() {
        XCTAssertNil(PauseGate.blocker(RouteManager.Config()))
    }

    func testVPNOnlyNeverPauses() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .vpnOnly
        XCTAssertEqual(PauseGate.blocker(cfg), .vpnOnly)
        XCTAssertEqual(PauseGate.message(.vpnOnly),
                       "Pausing VPN Only would send listed sites outside the VPN. Switch mode instead.")
    }

    func testCustomPausesWhenEveryEnabledRuleGoesDirect() {
        XCTAssertNil(PauseGate.blocker(customConfig([(.direct, .domain, "en.wikipedia.org"),
                                                     (.direct, .cidr, "203.0.113.0/24")])))
    }

    func testCustomIsBlockedByTheFirstRuleThatIsNotDirect() {
        let cfg = customConfig([(.direct, .domain, "en.wikipedia.org"),
                                (.vpnDefault, .cidr, "203.0.113.0/24"),
                                (.vpnDefault, .domain, "git.example.com")])
        XCTAssertEqual(PauseGate.blocker(cfg), .rule("203.0.113.0/24", usesProxy: false))
        XCTAssertTrue(PauseGate.message(.rule("203.0.113.0/24", usesProxy: false)).contains("203.0.113.0/24"))
    }

    func testADisabledRuleDoesNotBlock() {
        var cfg = customConfig([(.direct, .domain, "en.wikipedia.org"), (.vpnDefault, .cidr, "203.0.113.0/24")])
        cfg.rules[1].enabled = false
        XCTAssertNil(PauseGate.blocker(cfg))
    }

    /// RouteCompiler skips a rule whose route is off, so it routes nothing and does not block.
    func testARuleOnARouteTurnedOffDoesNotBlock() {
        var cfg = customConfig([(.direct, .domain, "en.wikipedia.org"), (.vpnDefault, .cidr, "203.0.113.0/24")])
        cfg.routes[1].enabled = false
        XCTAssertNil(PauseGate.blocker(cfg))
    }

    func testAServiceRuleIsNamedByItsService() {
        var cfg = customConfig([(.vpnDefault, .service, "telegram")])
        cfg.services = [ServiceEntry(id: "telegram", name: "Telegram", enabled: false, domains: ["t.me"], ipRanges: [], isCustom: false)]
        XCTAssertEqual(PauseGate.blocker(cfg), .rule("Telegram", usesProxy: false))
    }

    /// A proxy rule is served by a loopback listener that keeps running, so the paused line
    /// would be false; the rule is named before the route.
    func testAProxyRuleBlocksAndIsNamed() {
        let cfg = customConfig([(.direct, .domain, "a.example.com"), (.proxySOCKS5, .domain, "b.example.com")])
        XCTAssertEqual(PauseGate.blocker(cfg), .rule("b.example.com", usesProxy: true))
    }

    func testAnEnabledProxyRouteBlocksEvenWithNoRuleOnIt() {
        var cfg = customConfig([(.direct, .domain, "en.wikipedia.org")])
        cfg.routes[2].enabled = true
        XCTAssertEqual(PauseGate.blocker(cfg), .listener("office-proxy"))
    }

    /// Bypass runs proxy listeners only with the multi-route option on.
    func testBypassWithAProxyRouteBlocksOnlyWhenItsListenerRuns() {
        var cfg = RouteManager.Config()
        cfg.routes = [Route(name: "office-proxy", egress: .proxyHTTP, proxyHost: "198.51.100.7", proxyPort: 8080)]
        cfg.multiRouteEnabled = false
        XCTAssertNil(PauseGate.blocker(cfg))
        cfg.multiRouteEnabled = true
        XCTAssertEqual(PauseGate.blocker(cfg), .listener("office-proxy"))
        cfg.routes[0].enabled = false
        XCTAssertNil(PauseGate.blocker(cfg))
    }

    func testARuleOnAMissingRouteRoutesNothingAndDoesNotBlock() {
        var cfg = customConfig([(.direct, .domain, "en.wikipedia.org")])
        cfg.rules.append(Rule(matchType: .domain, pattern: "x.example.com", routeId: UUID(), order: 5))
        XCTAssertNil(PauseGate.blocker(cfg))
    }
}

final class PauseLengthTests: XCTestCase {

    func testParse() {
        XCTAssertEqual(PauseLength.parse("15m"), .minutes(15))
        XCTAssertEqual(PauseLength.parse("1h"), .minutes(60))
        XCTAssertEqual(PauseLength.parse("2h"), .minutes(120))
        XCTAssertEqual(PauseLength.parse("90"), .minutes(90))
        XCTAssertEqual(PauseLength.parse("30min"), .minutes(30))
        XCTAssertEqual(PauseLength.parse(" 24H "), .minutes(1440))
        XCTAssertEqual(PauseLength.parse("reconnect"), .untilReconnect)
        XCTAssertEqual(PauseLength.parse("resume"), .untilResume)
        XCTAssertEqual(PauseLength.parse(nil), .untilResume)
        XCTAssertEqual(PauseLength.parse(""), .untilResume)
        for bad in ["0m", "25h", "1441", "-5m", "abc", "1.5h", "m", "١٥m"] {
            XCTAssertNil(PauseLength.parse(bad), bad)
        }
    }

    func testTheWireValueReadsBack() {
        for length in PauseLength.choices + [.minutes(90)] {
            XCTAssertEqual(PauseLength.parse(length.wireValue), length)
        }
    }

    func testTimedPauseEndsAtItsLength() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PauseState(length: .oneHour, since: since, mode: .bypass).until, since.addingTimeInterval(3600))
        XCTAssertNil(PauseState(length: .untilReconnect, since: since, mode: .bypass).until)
        XCTAssertNil(PauseState(length: .untilResume, since: since, mode: .bypass).until)
        XCTAssertEqual(PauseState(length: .untilResume, since: since, mode: .bypass).wireDescription, "until resumed")
        XCTAssertEqual(PauseState(length: .fifteenMinutes, since: since, mode: .bypass).wireDescription,
                       "until 1970-01-12T14:01:40Z")
    }

    func testTheMenuOffersTheFourLengths() {
        XCTAssertEqual(PauseLength.choices.map { $0.title() },
                       ["For 15 Minutes", "For 1 Hour", "Until the VPN Reconnects", "Until I Resume"])
    }

    /// With no VPN connected and no route in, Pause would take nothing out: it is greyed with
    /// one line saying so. A route left in (a removal that failed) or a VPN up offers it again,
    /// and while paused a new length may still replace the old one.
    func testPauseIsGreyedWhenNothingIsRouted() {
        let cfg = RouteManager.Config()
        XCTAssertEqual(PauseGate.blocker(cfg, isPaused: false, vpnConnected: false, routedCount: 0), .nothingRouted)
        XCTAssertNil(PauseGate.blocker(cfg, isPaused: false, vpnConnected: true, routedCount: 0))
        XCTAssertNil(PauseGate.blocker(cfg, isPaused: false, vpnConnected: false, routedCount: 2))
        XCTAssertNil(PauseGate.blocker(cfg, isPaused: true, vpnConnected: false, routedCount: 0))
        var vpnOnly = cfg
        vpnOnly.routingMode = .vpnOnly
        XCTAssertEqual(PauseGate.blocker(vpnOnly, isPaused: false, vpnConnected: false, routedCount: 0), .vpnOnly,
                       "the mode's reason comes first")
        XCTAssertNil(PauseGate.blocker(cfg), "a config alone never says nothing is routed, so a pause is not ended for it")
        XCTAssertEqual(PauseGate.message(.nothingRouted), "Nothing to pause: no VPN is connected and no route is in.")
        XCTAssertEqual(PauseShortcut.action(isPaused: false, blocker: .nothingRouted), .nothing)
    }

    func testTheShortcutResumesOrPausesForAnHour() {
        XCTAssertEqual(PauseShortcut.action(isPaused: true, blocker: nil), .resume)
        XCTAssertEqual(PauseShortcut.action(isPaused: true, blocker: .vpnOnly), .resume)
        XCTAssertEqual(PauseShortcut.action(isPaused: false, blocker: nil), .pause(.oneHour))
        XCTAssertEqual(PauseShortcut.action(isPaused: false, blocker: .vpnOnly), .nothing)
        XCTAssertEqual(DropdownShortcut.pause.symbol, "⌘P")
    }

    func testVPNBTakesTheLengthBare() {
        XCTAssertEqual(VPNBCLI.parse(["pause", "15m"]).args, ["for": "15m"])
        XCTAssertEqual(VPNBCLI.parse(["pause", "for=1h"]).args, ["for": "1h"])
        XCTAssertEqual(VPNBCLI.parse(["pause"]).args, [:])
        XCTAssertTrue(VPNBCLI.parse(["resume"]).malformed.isEmpty)
    }

    func testTheShortcutsActionsSendWhatVPNBSends() {
        XCTAssertEqual(ShortcutAction.pause(.fifteenMinutes).request, ControlRequest(cmd: "pause", args: ["for": "15m"]))
        XCTAssertEqual(ShortcutAction.pause(.untilReconnect).request, ControlRequest(cmd: "pause", args: ["for": "reconnect"]))
        XCTAssertEqual(ShortcutAction.resume.request, ControlRequest(cmd: "resume"))
        XCTAssertEqual(ShortcutPauseLength.oneHour.length, .oneHour)
        XCTAssertEqual(PauseIntent(length: .untilResume).action, .pause(.untilResume))
        XCTAssertEqual(ResumeIntent().action, .resume)
    }

    func testStatusSaysPaused() {
        let runtime = RuntimeStatus(helperReady: true, helperState: "ready", vpnConnected: true,
                                    enforcedRouteCount: 0, enforcing: false, paused: "until resumed")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .bypass, runtime: runtime),
                       "Bypass mode. Paused: traffic follows the VPN's own routes.")
        XCTAssertTrue(VPNBCLI.textLines(ControlResponse(ok: true, result: ControlResult(runtime: runtime)))
            .contains { $0.contains("paused: until resumed") })
    }

    /// Get Status says Paused only when the dropdown would: a VPN up and every route out.
    func testStatusSaysPausedOnlyWithAVPNAndNoRoutesLeft() {
        let noVPN = RuntimeStatus(helperReady: true, helperState: "ready", vpnConnected: false,
                                  enforcedRouteCount: 0, enforcing: false, paused: "until resumed")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .bypass, runtime: noVPN),
                       "Bypass mode. The VPN is not connected.")
        let left = RuntimeStatus(helperReady: true, helperState: "ready", vpnConnected: true,
                                 enforcedRouteCount: 4, enforcing: true, paused: "until resumed")
        XCTAssertFalse(ShortcutActions.statusLine(mode: .bypass, runtime: left).contains("Paused"))
    }

    func testTheShortcutsDialogsSayWhatHappened() {
        XCTAssertEqual(ShortcutActions.pausePartial(left: 3),
                       "Paused, but 3 addresses are still routed: removing them failed. Retry from the dropdown.")
        XCTAssertEqual(ShortcutActions.pausePartial(left: 1),
                       "Paused, but 1 address is still routed: removing it failed. Retry from the dropdown.")
        XCTAssertEqual(ShortcutActions.notPaused(), "Routing was not paused.")
    }
}

final class PauseResumeTimingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func action(connected: Bool = true, canApply: Bool = true, settle: Bool = false,
                        strikes: Int = 0, strikeAgo: TimeInterval? = nil,
                        connectedAgo: TimeInterval? = 3600) -> PauseGate.ResumeAction {
        PauseGate.resumeAction(vpnConnected: connected, canApply: canApply, settlePending: settle,
                               killStrikes: strikes, lastStrikeAt: strikeAgo.map { now.addingTimeInterval(-$0) },
                               lastConnectAt: connectedAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    func testCalmTunnelAppliesAtOnce() {
        XCTAssertEqual(action(), .apply(after: 0, heldBackStrikes: nil))
        XCTAssertEqual(action(connectedAgo: nil), .apply(after: 0, heldBackStrikes: nil))
    }

    func testNoVPNOrNoHelperAppliesNothing() {
        XCTAssertEqual(action(connected: false), .nothing)
        XCTAssertEqual(action(canApply: false), .nothing)
    }

    func testAPendingSettleApplyIsLeftToRun() {
        XCTAssertEqual(action(settle: true), .waitForSettle)
    }

    /// The tunnel came up 3 s ago: the rest of the cold settle wait first.
    func testAFreshTunnelGetsTheRestOfTheSettleWait() {
        XCTAssertEqual(action(connectedAgo: 3), .apply(after: ReconnectSettle.coldDelay - 3, heldBackStrikes: nil))
    }

    /// The tunnel keeps dropping after our writes: Resume backs off as the reconnect apply does.
    func testStrikesBackTheApplyOff() {
        XCTAssertEqual(action(strikes: 1, strikeAgo: 60),
                       .apply(after: ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: false, killStrikes: 1),
                              heldBackStrikes: nil))
        XCTAssertEqual(action(strikes: 3, strikeAgo: 600),
                       .apply(after: ReconnectSettle.strikeExpiry - 600, heldBackStrikes: 3))
        // Strikes older than the expiry no longer count.
        XCTAssertEqual(action(strikes: 3, strikeAgo: ReconnectSettle.strikeExpiry + 1), .apply(after: 0, heldBackStrikes: nil))
    }
}

final class PauseStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func input(paused length: PauseLength?, routes: Int = 0, connected: Bool = true,
                       helperReady: Bool = true) -> DropdownStatus.Input {
        DropdownStatus.Input(isVPNConnected: connected, vpnName: "WireGuard", helperReady: helperReady, mode: .bypass,
                             enabledServices: 3, enabledDomains: 0, enabledRules: 0, installedRoutes: routes,
                             pending: nil, lastRouteChange: nil, lastDNSRefresh: nil, nextDNSRefresh: nil,
                             autoDNSRefresh: false,
                             pause: length.map { PauseState(length: $0, since: now.addingTimeInterval(-2 * 60), mode: .bypass) })
    }

    func testPausedSaysTrafficFollowsTheVPNsOwnRoutes() {
        let status = DropdownStatus.make(input(paused: .oneHour), now: now)
        XCTAssertEqual(status.chip, .paused)
        XCTAssertEqual(status.headline, "WireGuard connected")
        XCTAssertEqual(status.sentence, "Paused: traffic follows the VPN's own routes.")
        XCTAssertEqual(status.line3.action, .resume)
        XCTAssertFalse(status.line3.isProblem)
        XCTAssertTrue(status.line3.text.hasPrefix("Resumes at "), status.line3.text)
        XCTAssertTrue(status.line3.text.hasSuffix(", in 58 min"), status.line3.text)
    }

    func testTheOtherLengthsSayWhenTheyEnd() {
        XCTAssertEqual(DropdownStatus.make(input(paused: .untilReconnect), now: now).line3.text,
                       "Resumes when the VPN reconnects.")
        XCTAssertEqual(DropdownStatus.make(input(paused: .untilResume), now: now).line3.text,
                       "Paused until you resume.")
    }

    /// The VPN came back with the helper down, so "until the VPN reconnects" holds: Paused,
    /// saying it waits for the helper, with Fix. Any other pause shows the helper's state.
    func testAPauseWaitingForTheHelperSaysSoWithFix() {
        var waiting = input(paused: .untilReconnect, helperReady: false)
        waiting.pause?.reconnectedWaiting = true
        let status = DropdownStatus.make(waiting, now: now)
        XCTAssertEqual(status.chip, .paused)
        XCTAssertEqual(status.line3.text, "The VPN is back. Resumes when the helper is ready.")
        XCTAssertEqual(status.line3.action, .fix)
        XCTAssertNotEqual(DropdownStatus.make(input(paused: .untilReconnect, helperReady: false), now: now).chip, .paused)
    }

    /// Paused with no VPN: still Paused, with Resume.
    func testPausedWithNoVPN() {
        let status = DropdownStatus.make(input(paused: .untilResume, connected: false), now: now)
        XCTAssertEqual(status.chip, .paused)
        XCTAssertEqual(status.headline, "No VPN connected")
        XCTAssertEqual(status.line3.action, .resume)
    }

    /// A removal that failed keeps routes in place: the block says how many, with Retry, and
    /// never Paused.
    func testRoutesStillInPlaceAreNeverCalledPaused() {
        let status = DropdownStatus.make(input(paused: .oneHour, routes: 5), now: now)
        XCTAssertNotEqual(status.chip, .paused)
        XCTAssertEqual(status.line3.text, "5 addresses are still routed.")
        XCTAssertEqual(status.line3.action, .retryPause)
        XCTAssertTrue(status.line3.isProblem)
        XCTAssertFalse(status.sentence.contains("Paused"))
    }

    /// With the helper down the helper's own state shows, with Fix: Retry could not work.
    func testRoutesLeftWithTheHelperDownShowFix() {
        let status = DropdownStatus.make(input(paused: .oneHour, routes: 5, helperReady: false), now: now)
        XCTAssertEqual(status.line3.action, .fix)
        XCTAssertNotEqual(status.chip, .paused)
    }

    /// The helper down with a VPN up: its state shows, with Fix, instead of Paused.
    func testAHelperDownWithAVPNUpIsShownOverPaused() {
        let status = DropdownStatus.make(input(paused: .oneHour, helperReady: false), now: now)
        XCTAssertNotEqual(status.chip, .paused)
        XCTAssertEqual(status.line3.action, .fix)
        // With no VPN there is nothing to fix for routing yet: still Paused.
        XCTAssertEqual(DropdownStatus.make(input(paused: .oneHour, connected: false, helperReady: false), now: now).chip,
                       .paused)
    }

    func testTheStatusPageNamesAnIncompletePause() {
        XCTAssertEqual(StatusPage.summary(input(paused: .oneHour, routes: 5), now: now).title, "Pause incomplete")
    }

    func testTheStatusPageSaysPaused() {
        let summary = StatusPage.summary(input(paused: .untilResume), now: now)
        XCTAssertEqual(summary.title, "Paused")
        XCTAssertEqual(summary.sentence, "Paused: traffic follows the VPN's own routes.")
        XCTAssertEqual(summary.note, "Paused until you resume.")
    }

    func testNotPausedIsUnchanged() {
        XCTAssertNotEqual(DropdownStatus.make(input(paused: nil, routes: 5), now: now).chip, .paused)
    }

    func testPausedRowsAreNotProblems() {
        var cfg = RouteManager.Config()
        cfg.domains = [DomainEntry(domain: "en.wikipedia.org", enabled: true)]
        let rows = RoutedBySource.make(mode: .bypass, config: cfg, routes: [], busy: true,
                                       title: RoutedBySource.pausedTitle(.bypass))
        XCTAssertEqual(rows?.title, "Will skip the VPN again")
        XCTAssertEqual(rows?.problemRows, [])
    }

    /// Paused in Custom, the list says what Resume puts back: the rules, which otherwise show
    /// only once they have routes. A rule whose route is off routes nothing on Resume.
    func testPausedCustomListsTheRulesResumePutsBack() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        let direct = Route(name: "Direct", egress: .direct)
        let off = Route(name: "Old", egress: .direct, enabled: false)
        cfg.routes = [direct, off]
        cfg.rules = [Rule(matchType: .domain, pattern: "en.wikipedia.org", routeId: direct.id, order: 0),
                     Rule(matchType: .domain, pattern: "old.example.com", routeId: off.id, order: 1)]
        let rows = RoutedBySource.make(mode: .custom, config: cfg, routes: [], busy: false, paused: true,
                                       title: RoutedBySource.pausedTitle(.custom))
        XCTAssertEqual(rows?.title, "Will be routed by your rules again")
        XCTAssertEqual(rows?.rows.map(\.name), ["en.wikipedia.org"])
        XCTAssertEqual(rows?.problemRows, [], "paused, an entry with no addresses is what was asked for")
        // Not paused, a rule with no routes yet is not listed, as before.
        XCTAssertNil(RoutedBySource.make(mode: .custom, config: cfg, routes: [], busy: false))
    }

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testTheWordsAreTranslated() throws {
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for length in PauseLength.choices {
                XCTAssertNotEqual(length.title(in: bundle), length.title(), "\(language): \(length)")
            }
            for blocker: PauseGate.Blocker in [.vpnOnly, .rule("x", usesProxy: false), .rule("x", usesProxy: true), .listener("x"), .nothingRouted] {
                XCTAssertNotEqual(PauseGate.message(blocker, in: bundle), PauseGate.message(blocker), "\(language): \(blocker)")
            }
            XCTAssertNotEqual(DropdownStatus.Line3.spokenName(.resume, in: bundle), DropdownStatus.Line3.spokenName(.resume))
            XCTAssertNotEqual(RoutedBySource.pausedTitle(.bypass, in: bundle), RoutedBySource.pausedTitle(.bypass))
            XCTAssertNotEqual(String(localized: "The VPN is back. Resumes when the helper is ready.", bundle: bundle),
                              "The VPN is back. Resumes when the helper is ready.")
            let cannotResume = "Can't resume: VPN Bypass could not read its configuration file. Repair it or import a saved configuration in Settings."
            XCTAssertNotEqual(String(localized: String.LocalizationValue(cannotResume), bundle: bundle), cannotResume)
        }
    }
}

// MARK: - Against a fake kernel

@MainActor
final class PauseLifecycleTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, gateway: String?,
                        loading: Bool, helper: HelperState, update: Date?)!
    private var kernel: FakeKernel!
    /// Every destination any add path asked for.
    private var addCalls: [String] = []

    private let listed = ["203.0.113.1", "203.0.113.2", "198.51.100.9"]

    override func setUp() async throws {
        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.localGateway, rm.isLoading,
                 HelperManager.shared.helperState, rm.lastUpdate)
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.autoApplyOnVPN = true
        // One custom service of address ranges only: an apply needs no DNS.
        cfg.services = [ServiceEntry(id: "custom_lab", name: "Lab", enabled: true, domains: [],
                                     ipRanges: ["203.0.113.0/24"], isCustom: true)]
        rm.config = cfg
        rm.resetShutdownStateForTests()
        rm.pendingKernelAdds = []
        rm.isVPNConnected = true
        rm.vpnInterface = "utun4"
        rm.localGateway = "192.168.1.1"
        rm.isLoading = false
        kernel = FakeKernel(installed: Set(listed))
        kernel.attach(to: rm)
        addCalls = []
        rm.addRoutesBatchOverrideForTests = { [unowned self] routes in
            self.addCalls += routes.map(\.destination)
            return self.kernel.add(routes)
        }
        rm.addRouteOverrideForTests = { [unowned self] destination, gateway, _ in
            self.addCalls.append(destination)
            return self.kernel.add(destination, gateway: gateway)
        }
        rm.activeRoutes = listed.map { .init(destination: $0, gateway: "192.168.1.1", source: "Lab", timestamp: Date()) }
        // An earlier test's reconnect or drop would make a Resume wait out a cold delay or a
        // back-off, past what a test waits.
        rm.resetSettleStateForTests()
    }

    override func tearDown() async throws {
        if rm.pendingReconnectApply != nil {
            // Cancels the settle task a test left scheduled.
            _ = await rm.pause(for: .untilResume)
        }
        // A Resume schedules an apply 300 ms out; it must not run after the fakes are gone.
        await rm.cancelResumeApplyForTests()
        rm.endPause(reason: "test over", apply: false)
        FakeKernel.detach(from: rm)
        rm.detectVPNInterfaceOverrideForTests = nil
        rm.activeRoutes = []
        rm.pendingKernelAdds = []
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.localGateway = saved.gateway
        rm.isLoading = saved.loading
        rm.lastUpdate = saved.update
        HelperManager.shared.helperState = saved.helper
        rm.resetShutdownStateForTests()
    }

    /// Paused, with the helper reported ready, so a path that skips the pause would really
    /// install (the fake kernel takes it) instead of stopping at a helper that is not running.
    private func pauseWithHelperReady(_ length: PauseLength = .untilResume) async {
        await rm.pause(for: length)
        HelperManager.shared.helperState = .ready
    }

    func testPauseInBypassRemovesEveryRoute() async {
        let result = await rm.pause(for: .oneHour)
        XCTAssertEqual(result, .success(0))
        XCTAssertTrue(rm.isPaused)
        XCTAssertEqual(rm.pauseState?.length, .oneHour)
        XCTAssertTrue(kernel.installed.isEmpty)
        XCTAssertTrue(rm.activeRoutes.isEmpty)
    }

    func testPauseIsRefusedInVPNOnlyAndChangesNothing() async {
        rm.config.routingMode = .vpnOnly
        let result = await rm.pause(for: .oneHour)
        XCTAssertEqual(result, .failure(.blocked(.vpnOnly)))
        XCTAssertFalse(rm.isPaused)
        XCTAssertEqual(kernel.installed, Set(listed), "nothing was removed")
    }

    func testPauseIsRefusedInCustomWhenARuleGoesIntoTheVPN() async {
        rm.config.routingMode = .custom
        rm.config.schemaVersion = 2
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault)
        rm.config.routes = [vpn]
        rm.config.rules = [Rule(matchType: .cidr, pattern: "10.20.0.0/16", routeId: vpn.id, order: 0)]
        let result = await rm.pause(for: .untilResume)
        XCTAssertEqual(result, .failure(.blocked(.rule("10.20.0.0/16", usesProxy: false))))
        XCTAssertFalse(rm.isPaused)
        XCTAssertEqual(kernel.installed, Set(listed))
    }

    /// No VPN and no route: Pause, `vpnb pause` and the Pause Routing shortcut all refuse,
    /// the last two with nothing_to_pause, and nothing changes.
    func testPauseWithNothingRoutedIsRefusedEverywhere() async throws {
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.activeRoutes = []
        kernel.installed = []
        let result = await rm.pause(for: .oneHour)
        XCTAssertEqual(result, .failure(.blocked(.nothingRouted)))
        XCTAssertFalse(rm.isPaused)

        let response = await ControlSurface.handle(ControlRequest(cmd: "pause"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "nothing_to_pause")
        XCTAssertEqual(response.error?.message, PauseGate.message(.nothingRouted))
        XCTAssertFalse(rm.isPaused)

        let loaded = rm.hasLoadedConfig
        rm.hasLoadedConfig = true
        defer { rm.hasLoadedConfig = loaded }
        do {
            _ = try await ShortcutActions.run(PauseIntent(length: .oneHour).action)
            XCTFail("the Pause Routing shortcut paused with nothing routed")
        } catch let error as ShortcutActionError {
            XCTAssertEqual(error.code, "nothing_to_pause")
        }
        XCTAssertFalse(rm.isPaused)
    }

    /// A VPN up with nothing in yet still pauses: the apply it would run is held back.
    func testPauseWithAVPNUpAndNoRoutesStillPauses() async {
        rm.activeRoutes = []
        kernel.installed = []
        let result = await rm.pause(for: .oneHour)
        XCTAssertEqual(result, .success(0))
        XCTAssertTrue(rm.isPaused)
    }

    /// A removal that fails keeps its routes, and the count comes back for the dropdown.
    func testAFailedRemovalReportsWhatIsLeft() async {
        rm.removeRoutesBatchOverrideForTests = { dests in (0, dests.count, dests, "refused") }
        let result = await rm.pause(for: .oneHour)
        XCTAssertEqual(result, .success(listed.count))
        XCTAssertTrue(rm.isPaused, "still paused: nothing installs while the Retry is pending")
        kernel.attach(to: rm)
        await rm.retryPauseRemoval()
        XCTAssertTrue(rm.activeRoutes.isEmpty)
    }

    // Nothing reinstalls while paused

    func testAnApplyInstallsNothingWhilePaused() async {
        await pauseWithHelperReady()
        await rm.applyAllRoutes()
        XCTAssertEqual(addCalls, [], "an apply ran while paused")
        XCTAssertTrue(kernel.installed.isEmpty)

        // The control: the same apply, unpaused, installs the range.
        rm.endPause(reason: "control", apply: false)
        await rm.applyAllRoutes()
        XCTAssertEqual(addCalls, ["203.0.113.0/24"], "the control apply must install, or the check above proves nothing")
    }

    func testTheBatchFunnelRefusesWhilePaused() async {
        await pauseWithHelperReady()
        let result = await rm.addRoutesBatchTracked(routes: [(destination: "203.0.113.9", gateway: "192.168.1.1", isNetwork: false)])
        XCTAssertEqual(result.failedDestinations, ["203.0.113.9"])
        XCTAssertEqual(result.error, "paused")
        XCTAssertEqual(addCalls, [])
        XCTAssertTrue(rm.pendingKernelAdds.isEmpty)
    }

    func testADNSRefreshInstallsNothingWhilePaused() async throws {
        await pauseWithHelperReady()
        rm.forceDNSRefresh()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(addCalls, [])
        XCTAssertTrue(rm.recentLogs.contains { $0.message == "DNS refresh skipped: paused" })
    }

    func testTurningAServiceOnWhilePausedSavesItAndInstallsNothing() async throws {
        rm.config.services.append(ServiceEntry(id: "custom_more", name: "More", enabled: false, domains: [],
                                               ipRanges: ["198.51.100.0/24"], isCustom: true))
        await pauseWithHelperReady()
        rm.toggleService("custom_more")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(rm.config.services.first { $0.id == "custom_more" }?.enabled == true, "the change is saved")
        XCTAssertEqual(addCalls, [])
    }

    func testAddingADomainWhilePausedInstallsNothing() async throws {
        kernel.dns["news.example.com"] = ["192.0.2.80"]
        await pauseWithHelperReady()
        _ = rm.addDomain("news.example.com")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(rm.config.domains.contains { $0.domain == "news.example.com" })
        XCTAssertEqual(addCalls, [])
    }

    func testMissingRoutesAreNotPutBackWhilePaused() async {
        HelperManager.shared.helperState = .ready
        rm.removeRoutesBatchOverrideForTests = { dests in (0, dests.count, dests, "refused") }
        await rm.pause(for: .untilResume)   // the removal fails, so routes stay recorded
        XCTAssertFalse(rm.activeRoutes.isEmpty)
        await rm.reconcileMissingRoutes()
        XCTAssertEqual(addCalls, [])
    }

    /// The VPN coming back: down, then `checkVPNStatus` finds it up. `lastUpdate` is cleared, or
    /// the reconnect is skipped as a duplicate of the pause's own removal.
    private func reconnect() async {
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.lastUpdate = nil
        rm.detectVPNInterfaceOverrideForTests = { (true, "utun4", .wireGuard) }
        await rm.checkVPNStatus()
        XCTAssertTrue(rm.isVPNConnected)
    }

    /// The reconnect while paused (any length but "until the VPN reconnects") schedules no apply.
    func testAReconnectWhilePausedSchedulesNoApply() async {
        await rm.pause(for: .untilResume)
        HelperManager.shared.helperState = .ready
        await reconnect()
        XCTAssertNil(rm.pendingReconnectApply, "a settle-gated apply was scheduled while paused")
        XCTAssertTrue(rm.isPaused)

        // The control: the same reconnect, unpaused, schedules the apply.
        rm.endPause(reason: "control", apply: false)
        await reconnect()
        XCTAssertNotNil(rm.pendingReconnectApply, "the control reconnect must schedule, or the check above proves nothing")
    }

    /// "Until the VPN reconnects" ends at the reconnect, and the routes come back through the
    /// settle gate, not at once.
    func testUntilReconnectResumesThroughTheSettleGate() async {
        await rm.pause(for: .untilReconnect)
        HelperManager.shared.helperState = .ready
        rm.config.autoApplyOnVPN = false   // resuming is what was asked for, auto-apply or not
        await reconnect()
        XCTAssertFalse(rm.isPaused)
        XCTAssertNotNil(rm.pendingReconnectApply, "the apply waits in the settle gate")
        XCTAssertEqual(addCalls, [], "nothing is written before the tunnel settles")
    }

    /// "Until the VPN reconnects" with the helper not ready at the reconnect: ending the pause
    /// then left the routes out with nothing to bring them back. It holds, says why, and ends
    /// on the first pass that finds the helper ready, with the apply in the settle gate.
    func testUntilReconnectHoldsUntilTheHelperIsReady() async throws {
        await rm.pause(for: .untilReconnect)
        HelperManager.shared.helperState = .missing
        await reconnect()
        XCTAssertTrue(rm.isPaused, "the pause ended while nothing could put the routes back")
        let pause = try XCTUnwrap(rm.pauseState)
        XCTAssertTrue(pause.reconnectedWaiting)
        XCTAssertEqual(DropdownStatus.resumesLine(pause, now: Date()), "The VPN is back. Resumes when the helper is ready.")
        XCTAssertEqual(pause.wireDescription, "until the helper is ready")

        await rm.checkVPNStatus()   // still not ready: still paused
        XCTAssertTrue(rm.isPaused)

        HelperManager.shared.helperState = .ready
        await rm.checkVPNStatus()
        XCTAssertFalse(rm.isPaused)
        XCTAssertNotNil(rm.pendingReconnectApply, "the routes come back through the settle gate")
        XCTAssertEqual(addCalls, [], "nothing is written before the tunnel settles")
    }

    /// The VPN drops again while the pause waits for the helper: it waits for the next
    /// reconnect again, and no longer says the VPN is back.
    func testAWaitingPauseGoesBackToWaitingForTheVPNWhenItDrops() async throws {
        await rm.pause(for: .untilReconnect)
        HelperManager.shared.helperState = .missing
        await reconnect()
        XCTAssertEqual(rm.pauseState?.reconnectedWaiting, true)
        rm.detectVPNInterfaceOverrideForTests = { (false, nil, nil) }
        await rm.checkVPNStatus()
        XCTAssertFalse(rm.isVPNConnected)
        let pause = try XCTUnwrap(rm.pauseState)
        XCTAssertFalse(pause.reconnectedWaiting, "the dropdown says the VPN is back while it is down")
        XCTAssertEqual(DropdownStatus.resumesLine(pause, now: Date()), "Resumes when the VPN reconnects.")
    }

    /// The reconnect lands while an apply or a load runs: the pause ends and its apply waits
    /// for that work and the settle gate, instead of being skipped with the routes left out.
    func testUntilReconnectWaitsOutAnApplyThatIsRunning() async {
        await rm.pause(for: .untilReconnect)
        HelperManager.shared.helperState = .ready
        rm.isLoading = true
        await reconnect()
        rm.isLoading = false
        XCTAssertFalse(rm.isPaused)
        XCTAssertNotNil(rm.pendingReconnectApply, "the pause ended and no apply is coming")
    }

    func testWildcardsLearnNothingWhilePaused() async {
        await rm.pause(for: .untilResume)
        XCTAssertTrue(rm.wildcards.suspended)
        rm.wildcards.routesApplied()
        XCTAssertTrue(rm.wildcards.suspended, "a commit that raced the pause started wildcard learning")
        // A wildcard added while paused is saved; Resume starts it, not the next pass.
        await rm.wildcards.syncForTests()
        rm.config.domains.append(DomainEntry(domain: "*.example.com", enabled: true))
        await rm.wildcards.syncForTests()
        XCTAssertTrue(rm.wildcards.suspended)
    }

    func testQuittingWhilePausedLeavesNothing() async {
        await rm.pause(for: .untilResume)
        await rm.cleanupOnQuit()
        XCTAssertTrue(kernel.installed.isEmpty)
        XCTAssertEqual(addCalls, [])
    }

    // The ways out

    func testResumePutsTheRoutesBackWithOneApply() async throws {
        await rm.pause(for: .untilResume)
        HelperManager.shared.helperState = .ready
        rm.resume()
        XCTAssertFalse(rm.isPaused)
        // At once: setUp forgets earlier tests' reconnects and strikes, so no settle wait.
        let deadline = Date().addingTimeInterval(5)
        while addCalls.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(addCalls, ["203.0.113.0/24"])
        XCTAssertEqual(kernel.installed, ["203.0.113.0/24"])
    }

    func testChangingModeEndsThePause() async {
        await rm.pause(for: .untilResume)
        rm.isVPNConnected = false   // the switch then applies nothing here
        rm.setRoutingMode(.vpnOnly)
        XCTAssertFalse(rm.isPaused)
    }

    /// A proxy route turned on starts its listener at once, so the pause ends.
    func testTurningOnAProxyRouteEndsThePause() async {
        rm.config.multiRouteEnabled = true
        rm.config.routes = [Route(name: "office-proxy", egress: .proxyHTTP, enabled: false,
                                  proxyHost: "198.51.100.7", proxyPort: 8080)]
        await rm.pause(for: .untilResume)
        XCTAssertTrue(rm.isPaused)
        rm.config.routes[0].enabled = true
        rm.saveConfig()
        XCTAssertFalse(rm.isPaused)
    }

    func testTheTimerEndsATimedPause() async throws {
        await rm.pause(for: .minutes(0))
        let deadline = Date().addingTimeInterval(3)
        while rm.isPaused && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(rm.isPaused)
    }

    func testAPauseWhoseTimePassedEndsOnTheNextStatusPass() async {
        await rm.pause(for: .fifteenMinutes)
        rm.endPauseIfExpired(now: Date().addingTimeInterval(14 * 60))
        XCTAssertTrue(rm.isPaused, "not yet up")
        // The Mac slept through the timer: the next status pass ends the pause.
        rm.endPauseIfExpired(now: Date().addingTimeInterval(16 * 60))
        XCTAssertFalse(rm.isPaused)
    }

    func testUntimedPausesNeverExpire() async {
        for length in [PauseLength.untilReconnect, .untilResume] {
            await rm.pause(for: length)
            rm.endPauseIfExpired(now: Date().addingTimeInterval(30 * 24 * 3600))
            XCTAssertTrue(rm.isPaused, "\(length)")
            rm.endPause(reason: "next", apply: false)
        }
    }

    /// A Resume whose pause removed nothing skips its apply (the routes are current), and
    /// wildcard learning must still start again.
    func testResumeAfterAFailedRemovalRestartsWildcardLearning() async throws {
        rm.removeRoutesBatchOverrideForTests = { dests in (0, dests.count, dests, "test: refused") }
        rm.config.domains = [DomainEntry(domain: "*.example.org", enabled: true)]
        // Exactly what an apply wants, so the Resume apply finds the routes current and skips.
        rm.activeRoutes = [.init(destination: "203.0.113.0/24", gateway: "192.168.1.1", source: "Lab", timestamp: Date())]
        await pauseWithHelperReady()
        XCTAssertFalse(rm.activeRoutes.isEmpty)
        XCTAssertTrue(rm.wildcards.suspended)
        rm.resume()
        // At once: setUp forgets earlier tests' reconnects and strikes, so no settle wait.
        let deadline = Date().addingTimeInterval(5)
        while rm.wildcards.suspended && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(rm.wildcards.suspended)
        XCTAssertEqual(addCalls, [], "the apply skipped: the routes were current")
    }

    /// config.json became unreadable while paused: a Resume would end the pause and put
    /// nothing back (the apply refuses an unreadable config). It stays paused, the log, the
    /// control socket and the dropdown say why, and Resume works again once the file is read.
    func testAResumeWhileTheConfigCannotBeReadKeepsThePauseAndSaysWhy() async {
        await pauseWithHelperReady()
        rm.isConfigLoadFailed = true
        defer { rm.isConfigLoadFailed = false }
        rm.recentLogs = []

        XCTAssertFalse(rm.resume())
        XCTAssertTrue(rm.isPaused, "the pause holds")
        XCTAssertTrue(rm.recentLogs.contains { $0.message.hasPrefix("Resume refused: config.json could not be read") })
        let socket = await ControlSurface.handle(ControlRequest(cmd: "resume"))
        XCTAssertEqual(socket.error?.code, "config_unreadable")
        XCTAssertTrue(rm.isPaused)

        let status = DropdownStatus.make(.current(rm, helperReady: true), now: Date())
        XCTAssertEqual(status.chip, .paused)
        XCTAssertTrue(status.line3.isProblem)
        XCTAssertTrue(status.line3.text.hasPrefix("Can't resume"), status.line3.text)
        XCTAssertNil(status.line3.action, "no Resume button that would do nothing")

        // Control: the file is read again, and Resume ends the pause.
        rm.isConfigLoadFailed = false
        XCTAssertEqual(DropdownStatus.make(.current(rm, helperReady: true), now: Date()).line3.action, .resume)
        XCTAssertTrue(rm.resume())
        XCTAssertFalse(rm.isPaused)
    }

    func testTheControlSocketPausesAndResumes() async {
        let paused = await ControlSurface.handle(ControlRequest(cmd: "pause", args: ["for": "15m"]))
        XCTAssertTrue(paused.ok, "\(String(describing: paused.error))")
        XCTAssertEqual(rm.pauseState?.length, .fifteenMinutes)
        let refresh = await ControlSurface.handle(ControlRequest(cmd: "refresh"))
        XCTAssertEqual(refresh.error?.code, "paused")
        let resumed = await ControlSurface.handle(ControlRequest(cmd: "resume"))
        XCTAssertTrue(resumed.ok)
        XCTAssertFalse(rm.isPaused)

        rm.config.routingMode = .vpnOnly
        let refused = await ControlSurface.handle(ControlRequest(cmd: "pause"))
        XCTAssertEqual(refused.error?.code, "pause_refused")
        let bad = await ControlSurface.handle(ControlRequest(cmd: "pause", args: ["for": "soon"]))
        XCTAssertEqual(bad.error?.code, "invalid_args")
    }
}
