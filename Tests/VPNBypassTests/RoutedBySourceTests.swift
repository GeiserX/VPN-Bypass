// RoutedBySourceTests.swift
// Coverage for the dropdown's list of what is routed (RoutedBySource.make).
//
// The problem it locks down: the dropdown listed raw kernel destinations, the first four that
// happened to sort first, with "+ 58 more". In VPN Only four of the six were the app's own
// catch-alls, and the count included them. The list now has one row per service, domain, IP
// range or rule the user added, with its route count, and the catch-alls are one line.

import XCTest
@testable import VPNBypassCore

final class RoutedBySourceTests: XCTestCase {

    private func route(_ destination: String, _ source: String) -> RoutedBySource.InstalledRoute {
        .init(destination: destination, source: source)
    }

    private func service(_ id: String, _ name: String, enabled: Bool = true) -> RouteManager.ServiceEntry {
        RouteManager.ServiceEntry(id: id, name: name, enabled: enabled, domains: [], ipRanges: [])
    }

    private func config(_ edit: (inout RouteManager.Config) -> Void) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.services = []
        c.domains = []
        c.inverseDomains = []
        c.rules = []
        edit(&c)
        return c
    }

    private let catchAlls = ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"]

    // MARK: Bypass

    /// One row per enabled entry, services first, then domains, each in config order, with its
    /// own count. Disabled entries are not listed.
    func testBypassListsWhatTheUserAddedInSettingsOrder() throws {
        let c = config {
            $0.services = [service("telegram", "Telegram"), service("spotify", "Spotify", enabled: false),
                           service("youtube", "YouTube")]
            $0.domains = [DomainEntry(domain: "en.wikipedia.org"), DomainEntry(domain: "off.example", enabled: false)]
        }
        let routes = [route("185.15.58.224", "en.wikipedia.org"),
                      route("91.108.56.0/22", "Telegram"), route("91.108.4.0/22", "Telegram"),
                      route("142.250.1.1", "YouTube")]
        let s = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false))
        XCTAssertEqual(s.title, "Skipping the VPN")
        XCTAssertEqual(s.countText, "4 routes")
        XCTAssertEqual(s.rows.map(\.name), ["Telegram", "YouTube", "en.wikipedia.org"])
        XCTAssertEqual(s.rows.map(\.countText), ["2 routes", "1 route", "1 route"])
        XCTAssertEqual(s.rows.map(\.icon), [.service(id: "telegram"), .service(id: "youtube"), .domain])
        XCTAssertFalse(s.rows.contains(where: \.isProblem))
        XCTAssertFalse(s.everythingElseDirect, "Bypass has no catch-alls")
        XCTAssertEqual(s.hiddenRows, 0)
    }

    /// The app records a destination once per source that wants it, and can record the same
    /// pair twice. A row counts each destination once; the header counts each once overall.
    func testCountsAreUniqueDestinations() throws {
        let c = config {
            $0.services = [service("telegram", "Telegram")]
            $0.domains = [DomainEntry(domain: "t.me")]
        }
        let routes = [route("149.154.167.99", "Telegram"), route("149.154.167.99", "Telegram"),
                      route("149.154.167.99", "t.me"), route("91.108.4.0/22", "Telegram")]
        let s = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false))
        XCTAssertEqual(s.rows.map(\.routeCount), [2, 1])
        XCTAssertEqual(s.routeCount, 2, "a destination two entries share is one route")
    }

    /// An entry that should have routes and has none gets the warning, unless an apply is
    /// running that could still add them.
    func testAnEntryWithNoRoutesIsAProblemOnlyWhenNothingIsApplying() throws {
        let c = config {
            $0.services = [service("telegram", "Telegram")]
            $0.domains = [DomainEntry(domain: "nx.example")]
        }
        let routes = [route("91.108.4.0/22", "Telegram")]
        let idle = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false))
        XCTAssertEqual(idle.rows.map(\.isProblem), [false, true])
        XCTAssertEqual(idle.rows[1].countText, "no routes")

        let busy = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: true))
        XCTAssertEqual(busy.rows.map(\.isProblem), [false, false])
        XCTAssertEqual(busy.rows[1].countText, "no routes")
    }

    /// After a reconnect the app waits before it re-applies (WAITING), or holds the apply back
    /// for up to 30 minutes (HELD BACK). Neither sets the busy flags, but the apply is coming,
    /// so a row the drop emptied is not a warning while it waits.
    func testAPendingReconnectApplyIsNotAWarning() throws {
        let c = config { $0.inverseDomains = [DomainEntry(domain: "git.corp.example.com")] }
        let now = Date()
        for reason: RouteManager.PendingReconnectApply.Reason in [.settling, .heldBack(strikes: 2)] {
            let pending = RouteManager.PendingReconnectApply(reason: reason, connectedAt: now,
                                                             appliesAt: now.addingTimeInterval(60))
            let busy = RoutedBySource.mayStillAddRoutes(running: false, pending: pending)
            XCTAssertTrue(busy, "\(reason)")
            let s = try XCTUnwrap(RoutedBySource.make(mode: .vpnOnly, config: c, routes: [], busy: busy))
            XCTAssertEqual(s.rows.map(\.isProblem), [false], "\(reason)")
        }
        XCTAssertTrue(RoutedBySource.mayStillAddRoutes(running: true, pending: nil))
        XCTAssertFalse(RoutedBySource.mayStillAddRoutes(running: false, pending: nil))
    }

    /// The catch-alls left installed outside VPN Only (a mode switch whose clean-up has not run,
    /// or a removal that failed) are not hidden: they are routes no entry owns, counted with the
    /// rest, so the card agrees with the header and does not vanish when they are all there is.
    func testCatchAllsLeftOutsideVPNOnlyAreLeftovers() throws {
        let c = config { $0.services = [service("telegram", "Telegram")] }
        let leftovers = catchAlls.map { route($0, ClassicRouteCompiler.catchAllSource) }
        let s = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c,
                                                  routes: leftovers + [route("91.108.4.0/22", "Telegram")], busy: false))
        XCTAssertEqual(s.rows.map(\.name), ["Telegram", "Left from earlier"])
        XCTAssertEqual(s.rows.map(\.routeCount), [1, 4])
        XCTAssertEqual(s.routeCount, 5)
        XCTAssertFalse(s.everythingElseDirect)

        for mode: DropdownCopy.Mode in [.bypass, .custom] {
            let only = try XCTUnwrap(RoutedBySource.make(mode: mode, config: config { _ in }, routes: leftovers, busy: false),
                                     "\(mode)")
            XCTAssertEqual(only.rows.map(\.name), ["Left from earlier"], "\(mode)")
            XCTAssertEqual(only.routeCount, 4, "\(mode)")
        }
    }

    /// Routes no listed entry owns (an entry removed or switched off while its routes wait for
    /// cleanup, or a removal the app retries) are one line at the end, still counted.
    func testRoutesNoEntryOwnsAreOneLeftoverLine() throws {
        let c = config { $0.services = [service("telegram", "Telegram")] }
        let routes = [route("91.108.4.0/22", "Telegram"), route("1.2.3.4", "removed.example"),
                      route("1.2.3.4", "#61 cleanup-retry"), route("5.6.7.8", "pending-sweep-retry")]
        let s = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false))
        XCTAssertEqual(s.rows.map(\.name), ["Telegram", "Left from earlier"])
        XCTAssertEqual(s.rows.last?.routeCount, 2)
        XCTAssertEqual(s.rows.last?.icon, .leftover)
        XCTAssertEqual(s.rows.last?.isProblem, false)
        XCTAssertEqual(s.routeCount, 3)
    }

    /// Nothing on and nothing installed: no card. The status line above already says so.
    func testNothingToListIsNoCard() {
        let c = config { $0.services = [service("telegram", "Telegram", enabled: false)] }
        XCTAssertNil(RoutedBySource.make(mode: .bypass, config: c, routes: [], busy: false))
        XCTAssertNil(RoutedBySource.make(mode: .vpnOnly, config: c, routes: [], busy: false))
        XCTAssertNil(RoutedBySource.make(mode: .custom, config: c, routes: [], busy: false))
    }

    /// A long list shows the first rows and says how many more.
    func testALongListIsCapped() throws {
        let c = config { $0.domains = (1...11).map { DomainEntry(domain: "d\($0).example") } }
        let routes = (1...11).map { route("10.0.0.\($0)", "d\($0).example") }
        let s = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false))
        XCTAssertEqual(s.rows.count, RoutedBySource.visibleRows)
        XCTAssertEqual(s.hiddenRows, 11 - RoutedBySource.visibleRows)
        XCTAssertEqual(s.routeCount, 11)
    }

    /// The addresses stay one hover away: the row's tooltip lists them, capped.
    func testTheTooltipListsTheAddresses() throws {
        let c = config { $0.services = [service("youtube", "YouTube")] }
        let routes = (1...13).map { route("142.250.0.\($0)", "YouTube") }
        let row = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false)?.rows.first)
        let lines = row.tooltip.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, RoutedBySource.tooltipAddresses + 1)
        XCTAssertEqual(lines.first, "142.250.0.1")
        XCTAssertEqual(lines.last, "+ 3 more")

        let small = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c,
                                                      routes: [route("1.1.1.1", "YouTube")], busy: false)?.rows.first)
        XCTAssertEqual(small.tooltip, "1.1.1.1")
    }

    // MARK: VPN Only

    /// The four catch-alls are one "Everything else: direct" line and are not counted.
    func testVPNOnlyCatchAllsAreOneLineAndNotCounted() throws {
        let c = config {
            $0.inverseDomains = [DomainEntry(domain: "git.corp.example.com"),
                                 DomainEntry(domain: "10.20.0.0/16", isCIDR: true),
                                 DomainEntry(domain: "jira.corp.example.com")]
        }
        let routes = catchAlls.map { route($0, ClassicRouteCompiler.catchAllSource) }
            + [route("10.20.0.0/16", "10.20.0.0/16"), route("10.1.2.3", "git.corp.example.com")]
        let s = try XCTUnwrap(RoutedBySource.make(mode: .vpnOnly, config: c, routes: routes, busy: false))
        XCTAssertEqual(s.title, "Through the VPN")
        XCTAssertEqual(s.countText, "2 routes")
        XCTAssertEqual(s.rows.map(\.name), ["git.corp.example.com", "10.20.0.0/16", "jira.corp.example.com"])
        XCTAssertEqual(s.rows.map(\.icon), [.domain, .ipRange, .domain])
        XCTAssertEqual(s.rows.map(\.isProblem), [false, false, true])
        XCTAssertTrue(s.everythingElseDirect)
        XCTAssertFalse(s.rows.contains { $0.name == "Left from earlier" }, "catch-alls are not leftovers")
    }

    /// A catch-all is matched by destination AND the source it is recorded under, as stale-route
    /// cleanup matches it: a user's own /2 is the user's row and is counted.
    func testAUsersOwnSlashTwoIsNotACatchAll() throws {
        let c = config { $0.inverseDomains = [DomainEntry(domain: "64.0.0.0/2", isCIDR: true)] }
        let routes = [route("64.0.0.0/2", "64.0.0.0/2"), route("0.0.0.0/2", ClassicRouteCompiler.catchAllSource)]
        let s = try XCTUnwrap(RoutedBySource.make(mode: .vpnOnly, config: c, routes: routes, busy: false))
        XCTAssertEqual(s.rows.map(\.routeCount), [1])
        XCTAssertEqual(s.routeCount, 1)
        XCTAssertTrue(s.everythingElseDirect)
    }

    /// VPN Only with an empty list still installs its catch-alls: the card shows only that line.
    /// Without them installed (refused under GlobalProtect) the line does not claim direct.
    func testVPNOnlyEverythingElseFollowsTheInstalledCatchAlls() throws {
        let empty = config { _ in }
        let s = try XCTUnwrap(RoutedBySource.make(mode: .vpnOnly, config: empty,
                                                  routes: catchAlls.map { route($0, ClassicRouteCompiler.catchAllSource) },
                                                  busy: false))
        XCTAssertEqual(s.rows, [])
        XCTAssertEqual(s.countText, "0 routes")
        XCTAssertTrue(s.everythingElseDirect)

        let listed = config { $0.inverseDomains = [DomainEntry(domain: "git.corp.example.com")] }
        let without = try XCTUnwrap(RoutedBySource.make(mode: .vpnOnly, config: listed,
                                                        routes: [route("10.1.2.3", "git.corp.example.com")], busy: false))
        XCTAssertFalse(without.everythingElseDirect)
    }

    /// VPN Only routes its own list; a Bypass domain or a service is not one of its rows.
    func testVPNOnlyIgnoresTheBypassLists() throws {
        let c = config {
            $0.services = [service("telegram", "Telegram")]
            $0.domains = [DomainEntry(domain: "en.wikipedia.org")]
            $0.inverseDomains = [DomainEntry(domain: "git.corp.example.com")]
        }
        let s = try XCTUnwrap(RoutedBySource.make(mode: .vpnOnly, config: c,
                                                  routes: [route("10.1.2.3", "git.corp.example.com")], busy: false))
        XCTAssertEqual(s.rows.map(\.name), ["git.corp.example.com"])
    }

    // MARK: Custom

    /// Custom lists rules in rule order, a service rule by the service's name. A rule with no
    /// kernel route (a proxy or the primary VPN) is normal there: not listed, never a warning.
    func testCustomListsRulesThatInstalledRoutes() throws {
        let direct = UUID()
        let c = config {
            $0.services = [service("telegram", "Telegram")]
            $0.rules = [Rule(matchType: .domain, pattern: "b.example", routeId: direct, order: 2),
                        Rule(matchType: .service, pattern: "telegram", routeId: direct, order: 1),
                        Rule(matchType: .domain, pattern: "via-proxy.example", routeId: direct, order: 3),
                        Rule(matchType: .cidr, pattern: "10.9.0.0/16", routeId: direct, order: 4),
                        Rule(matchType: .domain, pattern: "off.example", routeId: direct, enabled: false, order: 0)]
        }
        let routes = [route("1.1.1.1", "b.example"), route("91.108.4.0/22", "telegram"),
                      route("10.9.0.0/16", "10.9.0.0/16"), route("2.2.2.2", "off.example")]
        let s = try XCTUnwrap(RoutedBySource.make(mode: .custom, config: c, routes: routes, busy: false))
        XCTAssertEqual(s.title, "Routed by your rules")
        XCTAssertEqual(s.rows.map(\.name), ["Telegram", "b.example", "10.9.0.0/16", "Left from earlier"])
        XCTAssertEqual(s.rows.map(\.icon), [.service(id: "telegram"), .rule, .ipRange, .leftover])
        XCTAssertFalse(s.rows.contains(where: \.isProblem))
        XCTAssertFalse(s.everythingElseDirect)
    }

    // MARK: Translations

    /// Every string the list can show has an es and a fr entry.
    func testEveryStringIsTranslated() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            guard dir.pathComponents.count > 1 else { throw XCTSkip("repo root not found from \(#filePath)") }
            dir = dir.deletingLastPathComponent()
        }
        let core = dir.appendingPathComponent("Sources/VPNBypassCore")
        let source = try String(contentsOf: core.appendingPathComponent("MenuBarViews.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "enum RoutedBySource {"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - Mode control", range: start.upperBound..<source.endIndex))
        let text = String(source[start.lowerBound..<end.lowerBound])

        let literal = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        let interpolation = try NSRegularExpression(pattern: #"\\\((.*?)\)"#)
        var keys: [String] = []
        for m in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let raw = String(text[Range(m.range(at: 1), in: text)!])
            keys.append(interpolation.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw),
                                                               withTemplate: "%lld"))
        }
        XCTAssertEqual(Set(keys), ["no routes", "+ %lld more", "Skipping the VPN", "Through the VPN",
                                   "Routed by your rules", "Left from earlier", "Everything else", "direct",
                                   "1 route", "%lld routes"], "the scan found a different set; update the list")

        for lang in ["en", "es", "fr"] {
            let url = core.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys {
                XCTAssertNotNil(table[key], "\(lang).lproj has no entry for \"\(key)\"")
            }
        }
    }
}
