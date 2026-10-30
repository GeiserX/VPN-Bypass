// ReworkBugFixTests.swift
// The bugs the app rework listed to fix first (A1 to A7, B1 to B4), and the Lookups add panel
// offering a built-in service the catalogue has retired. Each test fails on the code before
// its fix.

import SwiftUI
import XCTest
@testable import VPNBypassCore

// MARK: - The dropdown's status

final class ReworkStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "WireGuard", helperReady: true, mode: .bypass,
            enabledServices: 4, enabledDomains: 2, enabledRules: 0, installedRoutes: 62,
            pending: nil,
            lastRouteChange: .init(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 62, failedCount: 0),
            lastDNSRefresh: now.addingTimeInterval(-12 * 60),
            nextDNSRefresh: now.addingTimeInterval(18 * 60),
            autoDNSRefresh: true)
        edit(&i)
        return i
    }

    private func status(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus {
        DropdownStatus.make(input(edit), now: now)
    }

    /// A2: under "Helper not running, nothing is being routed" the line said "62 addresses
    /// routed 24 s ago, none failed."
    func testTheResultLineHidesWhileTheHelperIsNotReady() {
        let applied = RouteManager.RouteChangeOutcome(kind: .applied, at: now, routeCount: 62, failedCount: 0)
        XCTAssertEqual(DropdownCopy.shownRouteChange(applied, currentRouteCount: 62, helperReady: true), applied)
        XCTAssertNil(DropdownCopy.shownRouteChange(applied, currentRouteCount: 62, helperReady: false))
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 0, failedCount: 0)
        XCTAssertNil(DropdownCopy.shownRouteChange(removed, currentRouteCount: 0, helperReady: false))
    }

    /// A3: at launch the header said "WireGuard connected" and NOTHING ROUTED over the
    /// "Setting Up…" spinner.
    func testTheFirstDetectionShowsStarting() {
        for edit: (inout DropdownStatus.Input) -> Void in [
            { $0.isStarting = true; $0.installedRoutes = 0; $0.lastRouteChange = nil },
            { $0.isStarting = true; $0.isVPNConnected = false; $0.installedRoutes = 0 },
            { $0.isStarting = true; $0.helperReady = false },
        ] {
            let s = status(edit)
            XCTAssertEqual(s.pill, "STARTING")
            XCTAssertEqual(s.tone, .idle)
            XCTAssertEqual(s.headline, "Starting…")
            XCTAssertEqual(s.sentence, "Detecting the VPN and applying routes.")
            XCTAssertEqual(s.facts, [])
        }
        XCTAssertEqual(status { $0.isStarting = false }.pill, "ON")
        XCTAssertEqual(StatusPage.summary(input { $0.isStarting = true }, now: now).title, "Starting…")
    }

    /// A4: the pill stayed a green ON with failures, with an entry at zero addresses, and with
    /// checked addresses not answering.
    func testFailuresMakeItPartlyRouted() {
        let failed = status {
            $0.lastRouteChange = .init(kind: .applied, at: self.now.addingTimeInterval(-5), routeCount: 60, failedCount: 7)
            $0.installedRoutes = 60
        }
        XCTAssertEqual(failed.pill, "PARTLY ROUTED")
        XCTAssertEqual(failed.tone, .warn)
        XCTAssertTrue(failed.isPartial)
        XCTAssertEqual(failed.note, "7 failed in the last apply.")
        XCTAssertEqual(failed.facts.first?.value, "60 routed 5 s ago, 7 failed", "the facts stay")

        let empty = status { $0.entriesWithoutAddresses = 1 }
        XCTAssertEqual(empty.pill, "PARTLY ROUTED")
        XCTAssertEqual(empty.note, "1 entry has no addresses.")
        XCTAssertEqual(status { $0.entriesWithoutAddresses = 3 }.note, "3 entries have no addresses.")

        let checked = status { $0.lastCheckCount = 5; $0.lastCheckFailures = 4 }
        XCTAssertEqual(checked.pill, "PARTLY ROUTED")
        XCTAssertEqual(checked.note, "4 of 5 checked addresses did not answer.")

        let all = status {
            $0.lastRouteChange = .init(kind: .applied, at: self.now, routeCount: 62, failedCount: 1)
            $0.entriesWithoutAddresses = 2
            $0.lastCheckCount = 5; $0.lastCheckFailures = 1
        }
        XCTAssertEqual(all.note, "1 failed in the last apply. 2 entries have no addresses. 1 of 5 checked addresses did not answer.")
    }

    func testNothingWrongStaysOn() {
        let s = status { $0.lastCheckCount = 5; $0.lastCheckFailures = 0 }
        XCTAssertEqual(s.pill, "ON")
        XCTAssertEqual(s.tone, .ok)
        XCTAssertFalse(s.isPartial)
        XCTAssertNil(s.note)
    }

    /// The Status page reads the same state, so it does not say Working either.
    func testTheStatusPageSaysPartlyWorking() {
        XCTAssertEqual(StatusPage.summary(input { $0.entriesWithoutAddresses = 1 }, now: now).title, "Partly working")
        XCTAssertEqual(StatusPage.summary(input(), now: now).title, "Working")
    }

    /// The live input counts an entry with no addresses, as the routes card marks it.
    @MainActor
    func testTheLiveInputCountsEntriesWithoutAddresses() {
        let rm = RouteManager.shared
        let saved = (rm.config, rm.activeRoutes, rm.lastRouteCheck, rm.isLoading)
        defer { rm.config = saved.0; rm.activeRoutes = saved.1; rm.lastRouteCheck = saved.2; rm.isLoading = saved.3 }
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "a.example.com", enabled: true), DomainEntry(domain: "b.example.com", enabled: true)]
        cfg.inverseDomains = []
        for i in cfg.services.indices { cfg.services[i].enabled = false }
        rm.config = cfg
        rm.isLoading = false
        rm.activeRoutes = [.init(destination: "192.0.2.1", gateway: "192.168.1.1", source: "a.example.com", timestamp: Date())]
        let plan = RouteCheck.Plan(destinations: ["192.0.2.1"], sources: ["192.0.2.1": "a.example.com"],
                                   singleAddresses: 1, routeCount: 1)
        rm.lastRouteCheck = RouteCheck.Run(
            plan: plan, results: [RouteVerificationResult(destination: "192.0.2.1", isReachable: false, latency: nil,
                                                           timestamp: Date(), error: "timeout")],
            logsFrom: Date(), at: Date())
        let live = DropdownStatus.Input.current(rm, helperReady: true)
        XCTAssertEqual(live.entriesWithoutAddresses, 1, "b.example.com has none")
        XCTAssertEqual(live.lastCheckCount, 1)
        XCTAssertEqual(live.lastCheckFailures, 1)
    }

    /// The pill's strings exist in Spanish and French.
    func testTheNewStatusWordsAreTranslated() throws {
        let keys = ["STARTING", "Starting…", "Detecting the VPN and applying routes.", "PARTLY ROUTED",
                    "1 failed in the last apply.", "%lld failed in the last apply.", "1 entry has no addresses.",
                    "%lld entries have no addresses.", "%lld of %lld checked addresses did not answer.", "Partly working",
                    "Add a Direct rule…", "Added as rule %lld, to the Direct route.",
                    "Added as rule %lld; rule %lld matches first.",
                    "Connect to a VPN to send\nyour listed sites through it.",
                    "Connect to a VPN to start\nrouting traffic by your rules."]
        for language in ["es", "fr"] {
            let bundle = try ReworkSource.lproj(language)
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key, "\(language): \(key)")
            }
        }
    }
}

// MARK: - The dropdown's add and disconnected state

@MainActor
final class ReworkDropdownTests: RouteManagerTestCase {

    /// A Custom-mode config with a Direct route, a proxy route and `rules`.
    private func custom(_ rules: (Route, Route) -> [Rule]) -> (direct: Route, proxy: Route) {
        let direct = Route(name: "Direct", egress: .direct)
        let proxy = Route(name: "Work Proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.manageHostsFile = false
        cfg.routes = [direct, proxy]
        cfg.rules = rules(direct, proxy)
        rm.config = cfg
        return (direct, proxy)
    }

    /// A5: in Custom the button said "Add Domain to Bypass".
    func testTheQuickAddSaysWhatItAddsInEachMode() {
        XCTAssertEqual(DropdownCopy.quickAddLabel(.bypass), "Add Domain to Bypass")
        XCTAssertEqual(DropdownCopy.quickAddLabel(.vpnOnly), "Add Domain to VPN")
        XCTAssertEqual(DropdownCopy.quickAddLabel(.custom), "Add a Direct rule…")
    }

    /// A5: the rule went last and the field closed without a word, even when an earlier rule
    /// matched the name first.
    func testACustomAddSaysWhichRuleItBecameAndWhatMatchesFirst() throws {
        custom { _, proxy in
            [Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: proxy.id, order: 0),
             Rule(matchType: .suffix, pattern: "example.com", routeId: proxy.id, order: 1),
             Rule(matchType: .domain, pattern: "other.org", routeId: proxy.id, order: 2)]
        }
        let shadowed = try XCTUnwrap(rm.addForCurrentMode("shop.example.com")).get()
        XCTAssertEqual(shadowed.rulePlace, RulePlace(number: 4, matchedFirstBy: 2))
        XCTAssertEqual(shadowed.message, "Added as rule 4; rule 2 matches first.")

        let state = MenuContent.quickAdd(after: .success(shadowed), typed: "shop.example.com")
        XCTAssertTrue(state.isOpen, "the field stays open to say where the rule went")
        XCTAssertEqual(state.text, "")
        XCTAssertEqual(state.feedback?.isError, false)
        XCTAssertEqual(state.feedback?.message, "Added as rule 4; rule 2 matches first.")

        let clear = try XCTUnwrap(rm.addForCurrentMode("news.ycombinator.com")).get()
        XCTAssertEqual(clear.rulePlace, RulePlace(number: 5, matchedFirstBy: nil))
        XCTAssertEqual(clear.message, "Added as rule 5, to the Direct route.")

        let inRange = try XCTUnwrap(rm.addForCurrentMode("203.0.113.0/25")).get()
        XCTAssertEqual(inRange.rulePlace, RulePlace(number: 6, matchedFirstBy: 1))
    }

    /// Only a rule that routes matches first: one switched off, or on a route that is off, does not.
    func testARuleThatRoutesNothingDoesNotMatchFirst() throws {
        var off = Rule(matchType: .suffix, pattern: "example.com", routeId: UUID(), order: 0)
        off.enabled = false
        custom { _, proxy in [off, Rule(matchType: .suffix, pattern: "example.com", routeId: UUID(), order: 1),
                              Rule(matchType: .domain, pattern: "x.org", routeId: proxy.id, order: 2)] }
        let added = try XCTUnwrap(rm.addForCurrentMode("shop.example.com")).get()
        XCTAssertEqual(added.rulePlace, RulePlace(number: 4, matchedFirstBy: nil))
    }

    /// A service rule above holds the name.
    func testAServiceRuleThatHoldsTheNameMatchesFirst() {
        let services = [ServiceEntry(id: "custom_shop", name: "Shop", enabled: true,
                                     domains: ["*.shop.example"], ipRanges: [], isCustom: true)]
        let route = Route(name: "Work Proxy", egress: .proxySOCKS5)
        let rules = [Rule(matchType: .service, pattern: "custom_shop", routeId: route.id, order: 0),
                     Rule(matchType: .domain, pattern: "www.shop.example", routeId: UUID(), order: 1)]
        XCTAssertEqual(RulePlace(of: rules[1], in: rules, routes: [route], services: services),
                       RulePlace(number: 2, matchedFirstBy: 1))
    }

    /// A6: disconnected, every mode said "start bypassing traffic for configured services",
    /// and Custom counted Bypass services and domains, which it does not use.
    func testTheDisconnectedLinesFollowTheMode() {
        let sentences = [DropdownCopy.Mode.bypass, .vpnOnly, .custom].map { DropdownCopy.disconnectedSentence($0) }
        XCTAssertEqual(Set(sentences).count, 3)
        XCTAssertFalse(sentences[1].contains("bypassing"), sentences[1])
        XCTAssertTrue(sentences[2].contains("rules"), sentences[2])

        let (direct, _) = custom { direct, _ in
            [Rule(matchType: .domain, pattern: "a.example", routeId: direct.id, order: 0),
             Rule(matchType: .domain, pattern: "b.example", routeId: direct.id, order: 1)]
        }
        var off = Rule(matchType: .domain, pattern: "c.example", routeId: direct.id, order: 2)
        off.enabled = false
        rm.config.rules.append(off)
        rm.config.domains = [DomainEntry(domain: "d.example", enabled: true)]
        let custom = DropdownCopy.disconnectedBadges(.custom, config: rm.config)
        XCTAssertEqual(custom.map(\.value), [2])
        XCTAssertEqual(custom.map(\.label), ["Rules"])
        XCTAssertEqual(DropdownCopy.disconnectedBadges(.bypass, config: rm.config).map(\.label), ["Services", "Domains"])
        XCTAssertEqual(DropdownCopy.disconnectedBadges(.vpnOnly, config: rm.config).map(\.label), ["VPN Entries"])
        for language in ["es", "fr"] {
            let bundle = try! ReworkSource.lproj(language)
            XCTAssertNotEqual(DropdownCopy.disconnectedBadges(.custom, config: rm.config, in: bundle).first?.label, "Rules")
        }
    }

    /// A7: the routes kept while disconnected, or left by a failed removal, are listed, and
    /// an entry with none is neither listed nor a warning.
    func testTheDisconnectedListShowsOnlyWhatIsStillRouted() throws {
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.domains = [DomainEntry(domain: "a.example.com", enabled: true), DomainEntry(domain: "b.example.com", enabled: true)]
        for i in cfg.services.indices { cfg.services[i].enabled = false }
        let routes = [RoutedBySource.InstalledRoute(destination: "192.0.2.1", source: "a.example.com")]
        let summary = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: cfg, routes: routes, busy: false, routedOnly: true))
        XCTAssertEqual(summary.rows.map(\.id), ["a.example.com"])
        XCTAssertEqual(summary.problemCount, 0)
        XCTAssertNil(RoutedBySource.make(mode: .bypass, config: cfg, routes: [], busy: false, routedOnly: true),
                     "nothing routed: no card")
        let connected = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: cfg, routes: routes, busy: false))
        XCTAssertEqual(connected.rows.map(\.id), ["a.example.com", "b.example.com"])
        XCTAssertEqual(connected.problemCount, 1)
    }

    /// A7: the disconnected dropdown keeps the "…" menu, and Remove All Routes… in it.
    func testTheDisconnectedDropdownKeepsTheMoreMenu() throws {
        let body = try ReworkSource.body(of: "private var disconnectedContent: some View", in: "MenuBarViews.swift")
        XCTAssertTrue(body.contains("moreActionsMenu"), "no … menu while disconnected")
        XCTAssertTrue(body.contains("RoutedBySourceCard"), "no list while disconnected")
        let menu = try ReworkSource.body(of: "private var moreActionsMenu: some View", in: "MenuBarViews.swift")
        XCTAssertTrue(menu.contains("Remove All Routes…"))
    }
}

// MARK: - Retired services in the Lookups add panel

@MainActor
final class ReworkLookupServicesTests: RouteManagerTestCase {

    /// The #185 catalogue retired some built-in services. A saved config can still hold one,
    /// but `addDomainToBuiltInService` refuses it, so picking it in the add panel did nothing.
    func testARetiredBuiltInServiceIsNotOffered() {
        let retired = ServiceEntry(id: "retired_service_for_test", name: "Retired", enabled: false,
                                   domains: ["retired.example"], ipRanges: [])
        XCTAssertFalse(Config.defaultServices.contains { $0.id == retired.id })
        rm.config.services.append(retired)
        rm.addCustomService(name: "Mine", domains: ["mine.example"], ipRanges: [])
        let offered = rm.lookupServices(for: "api.example.org").map(\.id)
        XCTAssertFalse(offered.contains(retired.id))
        XCTAssertTrue(offered.contains { $0.hasPrefix("custom_") }, "custom services are offered")
        XCTAssertTrue(offered.contains(Config.defaultServices[0].id), "shipped built-ins are offered")
        XCTAssertNil(rm.addLookup("api.example.org", toService: retired.id),
                     "the refusal the panel used to reach")
    }
}

// MARK: - Views

final class ReworkViewTests: XCTestCase {

    /// A1: the wordmark looked "Bypass" up, which French translates as the mode's name, so it
    /// read "VPN Contournement".
    func testTheWordmarkIsNeverTranslated() throws {
        XCTAssertEqual(try ReworkSource.lproj("fr").localizedString(forKey: "Bypass", value: nil, table: nil),
                       "Contournement", "the mode's name is translated, so the wordmark must not look it up")
        let body = try ReworkSource.body(of: "struct BrandedAppName: View", in: "MenuBarViews.swift")
        XCTAssertFalse(body.contains("Text(\""), "a Text with a literal is looked up:\n\(body)")
        XCTAssertTrue(body.contains("Text(verbatim: \"Bypass\")"))
    }

    /// B1: the Rules route menu drew two chevrons and lost the chip's colour.
    func testTheRouteMenuDrawsOnlyTheChip() throws {
        let body = try ReworkSource.body(of: "struct RouteChipMenu: View", in: "RulesTab.swift")
        XCTAssertFalse(body.contains(".menuStyle(.borderlessButton)"))
        XCTAssertTrue(body.contains(".menuIndicator(.hidden)"))
    }

    /// B2: every General icon was green, on or off.
    func testAGeneralIconIsGreenOnlyWhenOn() {
        XCTAssertEqual(SettingsToggleRow.iconColor(isOn: true), Theme.success)
        XCTAssertNotEqual(SettingsToggleRow.iconColor(isOn: false), Theme.success)
    }

    /// B3: the Services page had a VPN Only banner it could never show.
    func testTheServicesPageHasNoVPNOnlyBanner() throws {
        XCTAssertFalse(SettingsView.tabs(for: .vpnOnly).contains(.services))
        let source = try ReworkSource.read("SettingsView.swift")
        XCTAssertFalse(source.contains("Services disabled in VPN Only mode"))
    }

    /// B4: the Wi-Fi name came from `airport -I`, which current macOS no longer has.
    func testNothingReadsTheRemovedAirportTool() throws {
        let sources = try FileManager.default.contentsOfDirectory(atPath: ReworkSource.core.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(sources.isEmpty)
        for file in sources {
            XCTAssertFalse(try ReworkSource.read(file).contains("Apple80211.framework"), file)
        }
    }
}

/// The app's source tree, for the checks a rendered view cannot make.
enum ReworkSource {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let core = root.appendingPathComponent("Sources/VPNBypassCore")

    static func lproj(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(url: core.appendingPathComponent("Resources/\(language).lproj")))
    }

    static func read(_ file: String) throws -> String {
        try String(contentsOf: core.appendingPathComponent(file), encoding: .utf8)
    }

    /// The braces-balanced block that starts at `declaration`.
    static func body(of declaration: String, in file: String) throws -> String {
        let source = try read(file)
        let start = try XCTUnwrap(source.range(of: declaration), "\(declaration) not in \(file)")
        var depth = 0
        var opened = false
        var index = start.lowerBound
        while index < source.endIndex {
            let c = source[index]
            if c == "{" { depth += 1; opened = true }
            if c == "}" { depth -= 1 }
            index = source.index(after: index)
            if opened && depth == 0 { break }
        }
        return String(source[start.lowerBound..<index])
    }
}
