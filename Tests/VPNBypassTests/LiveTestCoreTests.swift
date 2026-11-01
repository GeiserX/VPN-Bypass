// LiveTestCoreTests.swift
// What a 6.0 install on a real Mac with GlobalProtect up showed, engine side: list entries an
// older version saved as ".example.com", `vpnb why` while paused, and the dropdown and the Status
// page giving two counts for the same routes. (Resume's wait is in PauseTests.)

import XCTest
@testable import VPNBypassCore

// MARK: - Leading-dot entries

final class LeadingDotMigrationTests: XCTestCase {

    func testALegacyEntryBecomesTheWildcardItMeant() {
        let off = DomainEntry(domain: ".example.net", enabled: false)
        let on = DomainEntry(domain: ".Example.org")
        let plain = DomainEntry(domain: "keep.example.com")
        let result = LeadingDotMigration.migrate([off, plain, on])
        XCTAssertEqual(result.entries.map(\.domain), ["*.example.net", "keep.example.com", "*.example.org"],
                       "rewritten in place, in the same order")
        XCTAssertEqual(result.entries.map(\.id), [off.id, plain.id, on.id], "ids kept")
        XCTAssertEqual(result.entries.map(\.enabled), [false, true, true], "switched off stays off")
        XCTAssertEqual(result.entries.map(\.isWildcard), [true, false, true])
        XCTAssertEqual(result.migrated, [".example.net", ".Example.org"])
    }

    func testNoDuplicateWhenTheWildcardIsAlreadyListed() {
        let wildcard = DomainEntry(domain: "*.example.net", enabled: false)
        let legacy = DomainEntry(domain: ".example.net")
        let twice = DomainEntry(domain: ".example.org")
        let again = DomainEntry(domain: ".example.org")
        let result = LeadingDotMigration.migrate([legacy, wildcard, twice, again])
        XCTAssertEqual(result.entries.map(\.domain), ["*.example.net", "*.example.org"])
        XCTAssertEqual(result.entries[0].id, wildcard.id, "the wildcard already listed stays, as the user set it")
        XCTAssertFalse(result.entries[0].enabled)
        XCTAssertEqual(result.entries[1].id, twice.id)
        XCTAssertEqual(result.migrated.count, 3)
    }

    /// A wildcard saved with a trailing dot or in capitals is the same wildcard to routing.
    func testTheWildcardAlreadyListedIsFoundByItsSuffix() {
        let wildcard = DomainEntry(domain: "*.Example.net.", enabled: false)
        let legacy = DomainEntry(domain: ".example.net")
        let result = LeadingDotMigration.migrate([wildcard, legacy])
        XCTAssertEqual(result.entries.map(\.id), [wildcard.id])
    }

    func testOtherEntriesAreLeftAlone() {
        let entries = [DomainEntry(domain: "example.com"), DomainEntry(domain: "*.example.com"),
                       DomainEntry(domain: ".com"), DomainEntry(domain: "10.0.0.0/8", isCIDR: true)]
        let result = LeadingDotMigration.migrate(entries)
        XCTAssertEqual(result.entries, entries, "\".com\" names no suffix a wildcard may take")
        XCTAssertEqual(result.migrated, [])
    }

    func testALegacyRuleBecomesASuffixRule() {
        let route = UUID()
        let legacy = Rule(matchType: .domain, pattern: ".example.org", routeId: route, enabled: false, order: 3)
        let exact = Rule(matchType: .domain, pattern: "example.com", routeId: route, order: 4)
        let result = LeadingDotMigration.migrate([legacy, exact])
        XCTAssertEqual(result.rules.count, 2)
        XCTAssertEqual(result.rules[0].id, legacy.id)
        XCTAssertEqual(result.rules[0].matchType, .suffix)
        XCTAssertEqual(result.rules[0].pattern, "example.org", "the form RuleResolver matches")
        XCTAssertEqual(result.rules[0].routeId, route)
        XCTAssertEqual(result.rules[0].order, 3)
        XCTAssertFalse(result.rules[0].enabled)
        XCTAssertEqual(result.rules[1], exact)
        XCTAssertTrue(SiteRoute.ruleMatches(result.rules[0], host: "api.example.org", addresses: [], services: []))
    }

    func testALegacyRuleWhoseSuffixHasARuleIsDropped() {
        let suffix = Rule(matchType: .suffix, pattern: "example.org", routeId: UUID(), order: 5)
        let legacy = Rule(matchType: .domain, pattern: ".example.org", routeId: UUID(), order: 1)
        let result = LeadingDotMigration.migrate([legacy, suffix])
        XCTAssertEqual(result.rules, [suffix])
        XCTAssertEqual(result.migrated, [".example.org"])
    }

    func testTheConfigMigratesBothListsTheRulesAndEveryProfile() {
        var cfg = RouteManager.Config()
        cfg.domains = [DomainEntry(domain: ".example.net")]
        cfg.inverseDomains = [DomainEntry(domain: ".example.org")]
        cfg.rules = [Rule(matchType: .domain, pattern: ".example.com", routeId: UUID(), order: 0)]
        var profile = NetworkProfile(id: UUID(), name: "Office", networks: [], settings: ProfileSettings(capturing: cfg))
        profile.settings.domains = [DomainEntry(domain: ".example.info")]
        cfg.profiles = [profile]
        cfg.otherNetworksSettings = ProfileSettings(capturing: cfg)

        let result = cfg.migratingLeadingDotEntries()
        XCTAssertEqual(result.config.domains.map(\.domain), ["*.example.net"])
        XCTAssertEqual(result.config.inverseDomains.map(\.domain), ["*.example.org"])
        XCTAssertEqual(result.config.rules.map(\.pattern), ["example.com"])
        XCTAssertEqual(result.config.profiles[0].settings.domains.map(\.domain), ["*.example.info"])
        XCTAssertEqual(result.config.otherNetworksSettings?.domains.map(\.domain), ["*.example.net"])
        XCTAssertEqual(result.migrated, [".example.net", ".example.org", ".example.com", ".example.info"],
                       "each name once, though the Other networks copy holds it again")
        XCTAssertEqual(RouteManager.Config().migratingLeadingDotEntries().migrated, [], "a clean config changes nothing")
    }

    /// The same form typed today is the wildcard too, so it cannot be saved broken again.
    func testTypingALeadingDotAddsTheWildcard() {
        XCTAssertEqual(RouteManager.cleanDomain(".Example.net"), "*.example.net")
        XCTAssertEqual(RouteManager.cleanDomain("..example.net"), "*.example.net")
        XCTAssertEqual(RouteManager.cleanDomain(".com"), "")
    }
}

/// config.json from an older version, loaded the way the app loads it.
@MainActor
final class LeadingDotLoadTests: RouteManagerTestCase {

    func testLoadingMigratesSavesAndLogsOnce() throws {
        var cfg = RouteManager.Config()
        let legacy = DomainEntry(domain: ".example.net", enabled: false)
        cfg.domains = [legacy, DomainEntry(domain: "keep.example.com")]
        try JSONEncoder().encode(cfg).write(to: configURL)
        rm.recentLogs = []

        rm.loadConfig()
        XCTAssertEqual(rm.config.domains.map(\.domain), ["*.example.net", "keep.example.com"])
        XCTAssertEqual(rm.config.domains[0].id, legacy.id)
        XCTAssertFalse(rm.config.domains[0].enabled)
        XCTAssertTrue(rm.config.domains[0].isWildcard)
        let line = "Changed .example.net to the *.name form, which covers the name and every name under it"
        XCTAssertEqual(rm.recentLogs.filter { $0.message == line }.count, 1)

        // Saved: the next launch finds nothing to change and logs nothing.
        let saved = try JSONDecoder().decode(RouteManager.Config.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(saved.domains.map(\.domain), ["*.example.net", "keep.example.com"])
        rm.loadConfig()
        XCTAssertEqual(rm.recentLogs.filter { $0.message == line }.count, 1)
    }

    func testImportingMigratesToo() throws {
        var cfg = RouteManager.Config()
        cfg.domains = [DomainEntry(domain: ".example.org")]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("leading-dot-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = rm.isVPNConnected
        rm.isVPNConnected = false   // no apply after the import
        defer { rm.isVPNConnected = saved }
        try JSONEncoder().encode(RouteManager.ExportData(version: "2.0", exportDate: Date(), config: cfg)).write(to: file)
        XCTAssertTrue(rm.importConfig(from: file))
        XCTAssertEqual(rm.config.domains.map(\.domain), ["*.example.org"])
    }

    /// The clash check sees the migrated names: ".example.net" becomes "*.example.net", the
    /// name of a custom service in the same file, so both would route under one source.
    func testImportRefusesAClashTheMigrationMakes() throws {
        var cfg = RouteManager.Config()
        cfg.domains = [DomainEntry(domain: ".example.net")]
        cfg.services.append(ServiceEntry(id: "custom_x", name: "*.example.net", enabled: true,
                                         domains: ["a.example.com"], ipRanges: [], isCustom: true))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("leading-dot-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(RouteManager.ExportData(version: "2.0", exportDate: Date(), config: cfg)).write(to: file)
        let before = rm.config.domains
        XCTAssertFalse(rm.importConfig(from: file))
        XCTAssertEqual(rm.config.domains, before, "refused whole")
    }
}

// MARK: - Where does this site go, while paused

final class SiteRoutePausedTests: XCTestCase {

    private let local = "192.168.1.1"

    private func snapshot(list: [DomainEntry], pause: PauseState?, vpn: String? = "utun4") -> SiteRoute.Snapshot {
        SiteRoute.Snapshot(mode: .bypass, custom: false, list: list, services: [], rules: [], routes: [],
                           defaultRouteId: nil, activeRoutes: [], localGateway: local, vpnInterface: vpn,
                           pause: pause)
    }

    private let since = Date(timeIntervalSince1970: 1_790_000_000)

    func testAListedNameWhilePausedFollowsTheVPNUntilThePauseEnds() {
        let pause = PauseState(length: .fifteenMinutes, since: since, mode: .bypass)
        let s = snapshot(list: [DomainEntry(domain: "example.com")], pause: pause)
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .paused)
        XCTAssertEqual(found.expected, .tunnel("utun4"), "the routes are out, so it takes the VPN")

        let probe = PathCheck.Probe(address: "203.0.113.5", routeInterface: "utun4", answer: .connected, latencyMs: 12)
        let answer = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                      probes: [probe], control: nil, vpnConnected: true)
        XCTAssertEqual(answer.verdict, .ok, "leaving through the VPN is what a pause does, not a wrong way")
        let when = pause.until!.formatted(date: .omitted, time: .shortened)
        XCTAssertTrue(answer.summary.hasPrefix("Routing is paused until \(when), so example.com follows the VPN until then."),
                      answer.summary)
        XCTAssertFalse(answer.summary.contains("Re-resolve DNS"))
        XCTAssertEqual(answer.paused, pause.wireDescription)
        XCTAssertFalse(answer.canAdd, "it is on the list")
    }

    /// Without the pause, the same snapshot says the entry has no route: the old answer.
    func testControlWithoutAPauseTheAnswerIsTheListedOne() {
        let s = snapshot(list: [DomainEntry(domain: "example.com")], pause: nil)
        XCTAssertEqual(SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s).match, .listed)
    }

    /// A route the pause could not remove is still installed, so it still decides the way.
    func testARouteThePauseCouldNotRemoveStillAnswers() {
        let pause = PauseState(length: .untilResume, since: since, mode: .bypass)
        var s = snapshot(list: [DomainEntry(domain: "example.com")], pause: pause)
        s.activeRoutes = [("203.0.113.5", local, "example.com")]
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .route)
        XCTAssertEqual(found.expected, .physical)
    }

    /// `paused` is on every answer while paused: an unremoved route and an unresolved name too.
    func testEveryAnswerWhilePausedCarriesThePause() {
        let pause = PauseState(length: .untilResume, since: since, mode: .bypass)
        var s = snapshot(list: [DomainEntry(domain: "example.com")], pause: pause)
        s.activeRoutes = [("203.0.113.5", local, "example.com")]
        for (addresses, match) in [(["203.0.113.5"], SiteRouteAnswer.Match.route), ([], .unresolved)] {
            let found = SiteRoute.match(host: "example.com", addresses: addresses, in: s)
            XCTAssertEqual(found.match, match)
            let answer = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: addresses, found: found,
                                          probes: [], control: nil, vpnConnected: true)
            XCTAssertEqual(answer.paused, pause.wireDescription, "\(match)")
        }
    }

    /// With no VPN up the pause sentence does not send the site through a VPN.
    func testPausedWithNoVPNDoesNotSayItFollowsTheVPN() {
        let pause = PauseState(length: .untilResume, since: since, mode: .bypass)
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"],
                                    in: snapshot(list: [], pause: pause, vpn: nil))
        XCTAssertEqual(found.expected, .physical)
        let answer = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                      probes: [], control: nil, vpnConnected: false)
        XCTAssertTrue(answer.summary.hasPrefix("Routing is paused until you resume."), answer.summary)
        XCTAssertFalse(answer.summary.contains("follows the VPN"), answer.summary)
    }

    /// The VPN is back and the pause holds for the helper: the sentence says so, as `paused` does.
    func testTheHelperWaitIsInTheSentence() {
        var pause = PauseState(length: .untilReconnect, since: since, mode: .bypass)
        pause.reconnectedWaiting = true
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: snapshot(list: [], pause: pause))
        let answer = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                      probes: [], control: nil, vpnConnected: true)
        XCTAssertTrue(answer.summary.hasPrefix("Routing is paused until the helper is ready, so example.com follows the VPN until then."),
                      answer.summary)
        XCTAssertEqual(answer.paused, "until the helper is ready")
    }

    func testTheUntimedPausesSayUntilWhat() {
        let reconnect = PauseState(length: .untilReconnect, since: since, mode: .bypass)
        let resume = PauseState(length: .untilResume, since: since, mode: .bypass)
        for (pause, text) in [(reconnect, "Routing is paused until the VPN reconnects, so example.com follows the VPN until then."),
                              (resume, "Routing is paused until you resume, so example.com follows the VPN until then.")] {
            let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: snapshot(list: [], pause: pause))
            let answer = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                          probes: [], control: nil, vpnConnected: true)
            XCTAssertTrue(answer.summary.hasPrefix(text), answer.summary)
            XCTAssertTrue(answer.canAdd, "not on the list: Add still offers it")
        }
    }

    func testANameThatDoesNotResolveStillSaysSo() {
        let pause = PauseState(length: .untilResume, since: since, mode: .bypass)
        XCTAssertEqual(SiteRoute.match(host: "nx.example", addresses: [], in: snapshot(list: [], pause: pause)).match,
                       .unresolved)
    }

    @MainActor
    func testTheAppsSnapshotCarriesThePause() {
        let rm = RouteManager.shared
        let saved = rm.pauseState
        defer { rm.setPauseStateForTests(saved) }
        rm.setPauseStateForTests(PauseState(length: .untilResume, since: since, mode: .bypass))
        XCTAssertNotNil(rm.siteRouteSnapshot.pause)
        rm.setPauseStateForTests(nil)
        XCTAssertNil(rm.siteRouteSnapshot.pause)
    }
}

// MARK: - One count for the routes

final class RoutedCountAgreesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// The live test: the apply installed 371, wildcard lookups added 4, and the dropdown said
    /// 375 while Status said 371. Both now say the addresses routed now.
    func testTheDropdownAndTheStatusPageGiveTheSameCount() {
        let applied = RouteManager.RouteChangeOutcome(kind: .applied, at: now.addingTimeInterval(-60),
                                                      routeCount: 371, failedCount: 0)
        let input = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "WireGuard", helperReady: true, mode: .bypass,
            enabledServices: 4, enabledDomains: 2, enabledRules: 0, installedRoutes: 375,
            pending: nil, lastRouteChange: applied, lastDNSRefresh: nil, nextDNSRefresh: nil,
            autoDNSRefresh: false)
        let dropdown = DropdownStatus.make(input, now: now).line3.text
        let summary = StatusPage.summary(input, now: now).sentence
        let row = StatusPage.appliedLine(installed: input.installedRoutes, lastChange: applied, now: now).text
        XCTAssertTrue(dropdown.hasPrefix("375 addresses"), dropdown)
        XCTAssertTrue(summary.contains("375 addresses routed now, applied 1 min ago"), summary)
        XCTAssertTrue(row.hasPrefix("375 addresses, applied 1 min ago"), row)
        XCTAssertFalse((summary + row).contains("371"))
    }
}
