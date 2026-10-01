// OneMeaningForRouteTests.swift
// Coverage for proposal 16 of #119: on screen, "route" means one thing.
//
// The problem it locks down: "route" named three things. The kernel entries the app installs
// ("62 routes" in the dropdown), the ways out in Custom mode (the Routes page, "1/1 active"),
// and the ways out that have rules (Routes In Use). A user counting "62 routes" next to
// "1/1 active" was counting two different things under one word. Kernel entries now read as
// addresses; "route" is kept for the Custom-mode ways out. The Domains page said "Custom
// Domains", which read as Custom mode's list; it now names the list after its mode.

import XCTest
@testable import VPNBypassCore

final class OneMeaningForRouteTests: XCTestCase {

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

    // MARK: Kernel entries read as addresses

    /// Every count of kernel entries the dropdown and the Status page show, in both numbers.
    /// None may say "route": that word now names the Custom-mode ways out only.
    private func kernelCountTexts(_ n: Int) -> [String] {
        let applied = RouteManager.RouteChangeOutcome(kind: .applied, at: now, routeCount: n, failedCount: 0)
        let failed = RouteManager.RouteChangeOutcome(kind: .applied, at: now, routeCount: n, failedCount: 1)
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 0, failedCount: 0)
        let removedSome = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: n, failedCount: 1)
        let settling = RouteManager.PendingReconnectApply(reason: .settling, connectedAt: now,
                                                           appliesAt: now.addingTimeInterval(30))
        let telegram = (0..<n).map { RoutedBySource.InstalledRoute(destination: "91.108.\($0).0/24", source: "Telegram") }
        var config = RouteManager.Config()
        config.services = [RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: [], ipRanges: [])]
        config.domains = []
        let summary = RoutedBySource.make(mode: .bypass, config: config, routes: telegram, busy: false)

        var texts = [
            DropdownCopy.routeChangeLine(applied, now: now).text,
            DropdownCopy.routeChangeLine(failed, now: now).text,
            DropdownCopy.routeChangeLine(removed, now: now).text,
            DropdownCopy.routeChangeLine(removedSome, now: now).text,
            DropdownCopy.removeAllConfirmation(mode: .bypass, routeCount: n, serviceCount: 1, domainCount: 0,
                                               autoApplyOnVPN: false, autoDNSRefresh: false).title,
            RouteCheck.scope(checked: 0, singleAddresses: 0, routeCount: n).text,
            RouteCheck.scope(checked: n, singleAddresses: n, routeCount: n).text,
            RouteCheck.scope(checked: 1, singleAddresses: 1, routeCount: n + 1).text,
            StatusPage.routes(n),
            StatusPage.appliedLine(installed: n, lastChange: applied, now: now).text,
            DropdownStatus.make(input { $0.isVPNConnected = false; $0.installedRoutes = n }, now: now).sentence,
            DropdownStatus.make(input { $0.isVPNConnected = false; $0.installedRoutes = n; $0.mode = .custom }, now: now).sentence,
            DropdownStatus.make(input { $0.installedRoutes = n; $0.lastRouteChange = nil; $0.pending = settling }, now: now).note ?? "",
            OutsideChange(kind: .removedAllRoutes(routesLeft: 0), at: now).line(now: now).text,
            OutsideChange(kind: .removedAllRoutes(routesLeft: n), at: now).line(now: now).text,
            NotificationManager.disconnectedBody(wasInterface: "utun9", routesKept: n, routesFailed: 0),
            NotificationManager.disconnectedBody(wasInterface: "utun9", routesKept: 0, routesFailed: n),
            NotificationManager.disconnectedBody(wasInterface: "utun9", routesKept: 0, routesFailed: 0),
        ]
        texts += DropdownStatus.make(input { $0.installedRoutes = n }, now: now).facts.map { "\($0.label): \($0.value)" }
        texts += summary.map { [$0.countText] + $0.rows.map(\.countText) } ?? []
        return texts
    }

    func testNoKernelCountSaysRoute() {
        for n in [1, 62] {
            let texts = kernelCountTexts(n)
            XCTAssertGreaterThan(texts.count, 18, "a count went missing from the list")
            for text in texts {
                // "routed" is the verb and stays; the noun "route" or "routes" may not appear.
                XCTAssertNil(text.range(of: #"\b[Rr]outes?\b"#, options: .regularExpression), "n=\(n): \(text)")
            }
        }
        // The empty states, which have no count.
        let empty = DropdownStatus.make(input { $0.installedRoutes = 0 }, now: now)
        XCTAssertEqual(empty.pill, "NOTHING ROUTED")
        XCTAssertEqual(empty.facts.map(\.label), ["Addresses", "DNS"])
        XCTAssertEqual(StatusPage.summary(input { $0.installedRoutes = 0 }, now: now).title, "Nothing routed")
        XCTAssertEqual(RoutedBySource.Row(id: "x", name: "x", icon: .domain, routeCount: 0, isProblem: true,
                                          addresses: [], hiddenAddresses: 0).countText, "no addresses")
    }

    /// One address is singular everywhere. The old "%@ stay in place" and "The %@ from before the
    /// drop are still in place" took "1 route" into a plural sentence.
    func testOneAddressIsSingular() {
        XCTAssertEqual(DropdownStatus.make(input { $0.isVPNConnected = false; $0.installedRoutes = 1 }, now: now).sentence,
                       "1 address stays routed for when it reconnects.")
        XCTAssertEqual(DropdownStatus.make(input { $0.isVPNConnected = false; $0.installedRoutes = 1; $0.mode = .vpnOnly }, now: now).sentence,
                       "1 address is still routed: removing it failed.")
        let settling = RouteManager.PendingReconnectApply(reason: .settling, connectedAt: now,
                                                           appliesAt: now.addingTimeInterval(30))
        XCTAssertEqual(DropdownStatus.make(input { $0.installedRoutes = 1; $0.lastRouteChange = nil; $0.pending = settling }, now: now).note,
                       "The 1 address routed before the drop stays routed.")
        XCTAssertEqual(DropdownStatus.make(input { $0.installedRoutes = 0; $0.lastRouteChange = nil; $0.pending = settling }, now: now).note,
                       "Nothing is routed until then.")
        XCTAssertEqual(DropdownCopy.removeAllConfirmation(mode: .bypass, routeCount: 1, serviceCount: 1, domainCount: 0,
                                                          autoApplyOnVPN: false, autoDNSRefresh: false).title,
                       "Stop routing the 1 address?")
        XCTAssertEqual(StatusPage.routes(1), "1 address")
    }

    func testTheRefreshLineAndTheFactsSayRouted() {
        let removedSome = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now, routeCount: 4, failedCount: 2)
        XCTAssertEqual(DropdownCopy.routeChangeLine(removedSome, now: now).text,
                       "Removed routed addresses just now, 2 could not be removed.")
        XCTAssertEqual(DropdownStatus.routesFact(input(), now: now), "62 routed 23 s ago, none failed")
    }

    // MARK: "Route" stays for the Custom-mode ways out

    func testCustomModeKeepsRoute() {
        XCTAssertEqual(OutsideChange(kind: .changedRoutes, at: now).line(now: now).text,
                       "Last change: changed the routes via the command line, just now")
        XCTAssertEqual(RoutingModeCopy.name(.custom), "Custom Routes")
    }

    // MARK: The Domains page names its list after its mode

    func testDomainListTitleNamesTheMode() {
        XCTAssertEqual(DomainListCopy.title(isInverse: false), "Bypass list")
        XCTAssertEqual(DomainListCopy.title(isInverse: true), "VPN Only list")
    }

    // MARK: Translations

    private func core() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            guard dir.pathComponents.count > 1 else { throw XCTSkip("repo root not found from \(#filePath)") }
            dir = dir.deletingLastPathComponent()
        }
        return dir.appendingPathComponent("Sources/VPNBypassCore")
    }

    /// The lookup keys this change introduced. Each needs an entry in all three tables, and the
    /// Spanish and French ones must not be the English text.
    static let newKeys = [
        "1 address", "%lld addresses", "no addresses", "Addresses", "NOTHING ROUTED", "Nothing routed", "Routed",
        "%lld routed", "none routed yet", "%lld routed %@, none failed", "%lld routed %@, %lld failed",
        "VPN Bypass: VPN connected but nothing is being routed",
        "No addresses to route, checked %@.", "%@ routed %@, none failed.", "%@ routed %@, %lld failed.",
        "Removed all routed addresses %@.", "Removed routed addresses %@, %lld could not be removed.",
        "Stop routing the 1 address?", "Stop routing all %lld addresses?",
        "Nothing to check: the only address is a range, which ping cannot test",
        "Nothing to check: all %lld addresses are ranges, which ping cannot test",
        "Checked the only address", "Checked all %lld addresses", "Checked %lld of %lld addresses",
        "Checked 1 of %lld addresses",
        "1 address stays routed for when it reconnects.", "%lld addresses stay routed for when it reconnects.",
        "1 address is still routed: removing it failed.", "%lld addresses are still routed: removing them failed.",
        "Nothing is routed until then.", "The 1 address routed before the drop stays routed.",
        "The %lld addresses routed before the drop stay routed.",
        "Addresses owned (kernel-tagged)",
        "Last change: removed all routed addresses via the command line, %@",
        "Last change: removed routed addresses via the command line, %@; still routed: %lld",
        "%lld address(es) are still routed: removing them failed.",
        "Keeping %lld address(es) routed around the VPN — they use your normal connection and will be reused on reconnect.",
        "Nothing is routed now.", "%lld address(es) routed.", "Addresses Routed", "%lld address(es) updated",
        "Bypass list", "VPN Only list", "Addresses: services, domains, DNS refresh",
    ]

    /// The wording proposal 16 retired. No table keeps them, so a stale key cannot hide a
    /// view that still asks for the old text.
    static let retiredKeys = [
        "1 route", "%lld routes", "no routes", "NO ROUTES", "No routes installed", "Custom Domains",
        "VPN Only Domains", "Routes owned (kernel-tagged)", "%lld route(s) applied successfully.",
        "Checked all %lld routes", "Routes Applied",
    ]

    func testEveryNewStringIsTranslated() throws {
        let core = try core()
        var tables: [String: [String: String]] = [:]
        for lang in ["en", "es", "fr"] {
            let url = core.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
            tables[lang] = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
        }
        for key in Self.newKeys {
            let en = try XCTUnwrap(tables["en"]?[key], "en.lproj has no entry for \"\(key)\"")
            for lang in ["es", "fr"] {
                let value = try XCTUnwrap(tables[lang]?[key], "\(lang).lproj has no entry for \"\(key)\"")
                XCTAssertNotEqual(value, en, "\(lang) is English for \"\(key)\"")
            }
        }
        for key in Self.retiredKeys {
            for lang in ["en", "es", "fr"] {
                XCTAssertNil(tables[lang]?[key], "\(lang).lproj still has \"\(key)\"")
            }
        }
    }

    /// The keys above are the forms Foundation looks up at run time: the bundles answer them.
    func testTheLookupsResolve() throws {
        let core = try core()
        let expected: [(String, String, String)] = [
            ("es", "Lista Bypass", "Lista Solo VPN"),
            ("fr", "Liste Contournement", "Liste VPN uniquement"),
        ]
        for (lang, bypass, vpnOnly) in expected {
            let bundle = try XCTUnwrap(Bundle(url: core.appendingPathComponent("Resources/\(lang).lproj")), lang)
            XCTAssertEqual(DomainListCopy.title(isInverse: false, bundle: bundle), bypass)
            XCTAssertEqual(DomainListCopy.title(isInverse: true, bundle: bundle), vpnOnly)
            XCTAssertEqual(StatusPage.routes(62, bundle: bundle), lang == "es" ? "62 direcciones" : "62 adresses")
            XCTAssertEqual(OutsideChange(kind: .removedAllRoutes(routesLeft: 2), at: now).line(now: now, in: bundle).text,
                           lang == "es"
                           ? "Último cambio: se quitaron direcciones enrutadas desde la línea de comandos, ahora mismo; siguen enrutadas: 2"
                           : "Dernière modification : adresses routées retirées via la ligne de commande, à l'instant ; toujours routées : 2")
        }
    }
}
