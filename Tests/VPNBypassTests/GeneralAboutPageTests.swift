// GeneralAboutPageTests.swift
// Rework step 10 (sections 3.5 and 3.6 of docs/design/APP-REWORK-PROPOSALS.md): General as five
// groups with the SOCKS5 proxy behind Advanced and hidden in Custom, About in place of Info with
// a diagnostics bundle that carries no names, and every sheet on SheetScaffold. The model tests
// pin the choices; the view tests open real windows and read them the way VoiceOver does.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

final class GeneralAboutModelTests: XCTestCase {

    // MARK: General

    func testGeneralGroupsInOrder() {
        XCTAssertEqual(GeneralPage.Group.allCases.map { $0.title() },
                       ["Startup", "Routing", "Network profiles", "DNS servers", "Notifications", "Configuration"])
    }

    /// Auto DNS Refresh and Refresh Interval are one popup, with Never as its last choice.
    func testLookUpAgainIsOnePopupWithNever() {
        XCTAssertEqual(GeneralPage.refreshChoices(current: 3600), [900, 1800, 3600, 7200, 21600, nil])
        XCTAssertEqual(GeneralPage.refreshChoices(current: 600), [600, 900, 1800, 3600, 7200, 21600, nil],
                       "a saved interval the popup does not list is kept as a choice")
        XCTAssertEqual(GeneralPage.refreshChoices(current: 600).map { GeneralPage.refreshLabel($0) },
                       ["Every 10 minutes", "Every 15 minutes", "Every 30 minutes", "Every hour",
                        "Every 2 hours", "Every 6 hours", "Never"])
        XCTAssertEqual(GeneralPage.refreshLabel(10), "Every 10 seconds", "an interval under a minute says so")
        XCTAssertEqual(GeneralPage.refreshChoices(current: 3599).map { GeneralPage.refreshLabel($0) }.filter { $0 == "Every hour" }.count,
                       1, "3599 s is not a second Every hour")
        XCTAssertEqual(GeneralPage.refreshSelection(autoRefresh: true, interval: 1800), 1800)
        XCTAssertNil(GeneralPage.refreshSelection(autoRefresh: false, interval: 1800), "off reads Never")
    }

    func testPickingNeverTurnsTheLookupOffAndKeepsTheInterval() {
        var config = RouteManager.Config()
        config.dnsRefreshInterval = 7200
        GeneralPage.apply(nil, to: &config)
        XCTAssertFalse(config.autoDNSRefresh)
        XCTAssertEqual(config.dnsRefreshInterval, 7200)
        GeneralPage.apply(900, to: &config)
        XCTAssertTrue(config.autoDNSRefresh)
        XCTAssertEqual(config.dnsRefreshInterval, 900)
    }

    /// 3.5 A: the global proxy sits behind Advanced, and Custom mode does not show it.
    func testTheGlobalProxyIsHiddenInCustomMode() {
        XCTAssertTrue(GeneralPage.showsGlobalProxy(in: .bypass))
        XCTAssertTrue(GeneralPage.showsGlobalProxy(in: .vpnOnly))
        XCTAssertFalse(GeneralPage.showsGlobalProxy(in: .custom))
        XCTAssertTrue(GeneralPage.customProxyNote().contains("Routes page"))
        XCTAssertTrue(GeneralPage.advancedStartsOpen(proxyEnabled: true), "a user of the proxy finds it open")
        XCTAssertFalse(GeneralPage.advancedStartsOpen(proxyEnabled: false))
    }

    @MainActor func testNotificationKindsAreFourDistinctCheckboxes() {
        let kinds = GeneralPage.NotificationKind.allCases
        XCTAssertEqual(kinds.map { $0.title() }, ["VPN connects", "VPN drops", "Addresses change", "Something fails"])
        XCTAssertEqual(Set(kinds.map(\.keyPath)).count, 4, "each checkbox has its own setting")
    }

    func testEveryNewStringIsInSpanishAndFrench() throws {
        let keys = ["DNS servers", "Never", "Every hour", "Every %lld hours", "Every %lld minutes", "VPN connects",
                    "VPN drops", "Addresses change", "Something fails", "Open at login", "Apply when a VPN connects",
                    "Pin listed names in /etc/hosts", "Look up addresses again", "Check the path after applying",
                    "Block listed sites when the VPN drops", "Send notifications", "Tell me when", "Play a sound",
                    "Advanced: SOCKS5 for VPNs that block UDP",
                    "In Custom mode, send traffic through a proxy with a route on the Routes page.",
                    "Version %@ · GPL-3.0 · by GeiserX", "Website", "Report a problem…", "Support the project",
                    "Four ways to give, in one menu", "Choose…"]
        for language in ["es", "fr"] {
            let bundle = try ReworkSource.lproj(language)
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "\u{0}", table: nil), "\u{0}",
                                  "\(language) has no \(key)")
            }
            XCTAssertEqual(GeneralPage.refreshLabel(7200, in: bundle), language == "es" ? "Cada 2 horas" : "Toutes les 2 heures")
        }
    }

    // MARK: About

    func testAboutHasOneVersionLineAndFourWaysToGive() {
        XCTAssertEqual(AboutPage.versionLine("6.0.0"), "Version 6.0.0 · GPL-3.0 · by GeiserX")
        XCTAssertEqual(AboutPage.supportOptions.map(\.name), ["GitHub Sponsors", "Buy Me a Coffee", "Patreon", "Thanks.dev"])
        XCTAssertTrue(AboutPage.supportOptions.allSatisfy { $0.url.scheme == "https" })
        XCTAssertEqual(AboutPage.websiteURL.host, "geiserx.github.io")
        XCTAssertEqual(AboutPage.repositoryURL.path, "/GeiserX/VPN-Bypass")
    }

    /// The fundraising colours left the UI with the four coloured buttons.
    func testTheFundraisingColoursAreGone() throws {
        let theme = try ReworkSource.read("Theme.swift")
        for name in ["githubSponsors", "buyMeACoffee", "patreon"] {
            XCTAssertFalse(theme.contains(name), "Theme.\(name) is back")
        }
    }

    // MARK: Diagnostics

    func testRedactionTakesOutEveryKindOfName() {
        let names = ["Work Tools", "intranet.example.org", "office-proxy"]
        let cases: [(String, String)] = [
            ("Applied routes for Work Tools", "Applied routes for <name>"),
            ("Resolved intranet.example.org to 198.51.100.4", "Resolved <name> to <address>"),
            ("Route 203.0.113.0/24 failed", "Route <address> failed"),
            ("No route for *.cdn.example.net", "No route for <name>"),
            ("Upstream office-proxy refused", "Upstream <name> refused"),
            ("DoH https://dns.example.com/dns-query timed out", "DoH <url> timed out"),
            ("Sent to someone@example.com", "Sent to <email>"),
            ("Config at /Users/alice/Library/x.json", "Config at /Users/<user>/Library/<name>"),
            ("Skipped 2001:db8::1", "Skipped <address>"),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(Diagnostics.redact(line, names: names), expected, line)
        }
        // Controls: plain words, versions and counts are kept.
        for line in ["Helper not running", "VPN connected", "Helper version mismatch: installed=1.4.0, expected=1.5.0",
                     "Applied routes (3 kernel failures)"] {
            XCTAssertEqual(Diagnostics.redact(line, names: names), line, "a plain line was changed")
        }
    }

    private func input(recent: [RouteManager.LogEntry]) -> Diagnostics.Input {
        Diagnostics.Input(appVersion: "6.0.0", helperVersion: "1.5.0", helperState: "ready",
                          macOS: "Version 27.0 (Build 27A1)", architecture: "arm64", vpnConnected: true,
                          vpnType: "WireGuard", mode: .bypass, servicesOn: 4, domainsOn: 2, domainsTotal: 3,
                          vpnOnlyEntries: 0, rules: 0, routes: 2, routedAddresses: 62, lastFailed: 7,
                          autoApply: true, hostsFile: false, pathCheck: true, refreshEvery: 3600,
                          globalProxy: false, lookups: false, recent: recent,
                          names: ["Work Tools", "intranet.example.org"])
    }

    func testTheBundleSaysTheStateAndNoNames() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let logs = (0..<14).map {
            RouteManager.LogEntry(timestamp: now.addingTimeInterval(Double($0)), level: .warning,
                                  message: "Work Tools: intranet.example.org got no addresses (\($0))")
        }
        let text = Diagnostics.bundle(input(recent: logs))
        for fact in ["App: 6.0.0", "Helper: 1.5.0, ready", "VPN: connected, WireGuard", "Mode: bypass",
                     "4 services on, 2 of 3 domains on", "Routed: 62 addresses, 7 failed at the last apply",
                     "path check on", "look up again every 3600 s"] {
            XCTAssertTrue(text.contains(fact), "\(fact) missing from:\n\(text)")
        }
        XCTAssertFalse(text.contains("Work Tools"))
        XCTAssertFalse(text.contains("intranet"))
        XCTAssertEqual(text.components(separatedBy: "\n- ").count - 1, Diagnostics.recentLimit, "only the newest warnings")
        XCTAssertTrue(text.contains("(13)"), "the newest one is kept")
        XCTAssertFalse(text.contains("(3)"), "an old one is dropped")
        XCTAssertTrue(Diagnostics.bundle(input(recent: [])).hasSuffix("Recent warnings and errors:\n(none)"))
    }

    func testOneLetterNamesGoAndWordsAroundThemStay() {
        XCTAssertEqual(Diagnostics.redact("Route a failed via B", names: ["a", "b"]), "Route <name> failed via <name>")
    }

    func testTheHelperStateIsRedactedToo() {
        var failed = input(recent: [])
        failed.helperState = #"failed("Cannot copy /Users/alice/Downloads/helper to intranet.example.org")"#
        let text = Diagnostics.bundle(failed)
        XCTAssertFalse(text.contains("alice"), text)
        XCTAssertFalse(text.contains("intranet"), text)
        XCTAssertTrue(text.contains("Helper: 1.5.0, failed(\"Cannot copy /Users/<user>"), text)
    }

    func testTheIssueLinkFillsTheBugForm() throws {
        let url = Diagnostics.issueURL(version: "6.0.0", bundle: "a+b = c")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "/GeiserX/VPN-Bypass/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["template"], "bug_report.yml")
        XCTAssertEqual(items["version"], "6.0.0")
        XCTAssertEqual(items["logs"], "a+b = c")
        XCTAssertTrue(url.absoluteString.contains("a%2Bb"), "a + would reach the form as a space")
        let long = Diagnostics.issueURL(version: "6.0.0", bundle: String(repeating: "x", count: 9000))
        XCTAssertFalse(long.absoluteString.contains("logs="), "a bundle too long for a link stays on the clipboard only")
    }
}

@MainActor
final class GeneralAboutViewTests: XCTestCase {

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
    }

    private func setMode(_ mode: RouteManager.RoutingMode, proxy: Bool = false) {
        var config = rm.config
        config.routingMode = mode
        config.schemaVersion = mode == .custom ? 2 : 1
        config.proxyConfig.enabled = proxy
        rm.config = config
    }

    func testGeneralShowsFiveGroupsAndAdvancedInBypass() {
        setMode(.bypass)
        let texts = texts(on: .general)
        for name in ["Startup", "Routing", "DNS servers", "Notifications", "Configuration",
                     "Open at login", "Look up addresses again", "Check the path after applying",
                     "VPN connects", "Something fails", "Play a sound", "Export…", "Import…",
                     "Advanced: SOCKS5 for VPNs that block UDP"] {
            XCTAssertTrue(texts.contains(name), "\(name) missing from General: \(texts.sorted())")
        }
        for gone in ["Auto DNS Refresh", "Refresh Interval", "Verify Routes After Apply", "Aggressive Bypass Mode"] {
            XCTAssertFalse(texts.contains(gone), "\(gone) is still on General")
        }
        XCTAssertFalse(texts.contains("Enable SOCKS5 Proxy"), "Advanced starts closed when the proxy is off")
    }

    /// Network profiles: this network, Other networks and each profile with its state, and
    /// every button named for VoiceOver.
    func testGeneralShowsNetworkProfiles() {
        setMode(.bypass)
        let savedNetwork = rm.currentNetwork
        defer { rm.currentNetwork = savedNetwork }
        let office = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:01", kind: .ethernet)
        rm.currentNetwork = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:02", kind: .wifi)
        var config = rm.config
        config.profiles = [NetworkProfile(id: UUID(), name: "Office", networks: [office],
                                          settings: ProfileSettings(capturing: config))]
        config.activeProfileId = nil
        rm.config = config
        let texts = texts(on: .general)
        for name in ["Network profiles", "This network", "Wi-Fi, router 192.0.2.1", "Other networks", "In use",
                     "Office", "Use Office on this network", "Delete Office", "Save as Profile for This Network…"] {
            XCTAssertTrue(texts.contains(name), "\(name) missing from General: \(texts.sorted())")
        }
    }

    func testAdvancedOpensForAUserOfTheProxy() {
        setMode(.vpnOnly, proxy: true)
        XCTAssertTrue(texts(on: .general).contains("Enable SOCKS5 Proxy"))
    }

    func testCustomModeHidesTheGlobalProxyAndPointsAtRoutes() {
        setMode(.custom, proxy: true)
        let texts = texts(on: .general)
        XCTAssertTrue(texts.contains(GeneralPage.customProxyNote()), "no pointer to Routes: \(texts.sorted())")
        XCTAssertFalse(texts.contains("Advanced: SOCKS5 for VPNs that block UDP"))
        XCTAssertFalse(texts.contains("Enable SOCKS5 Proxy"))
    }

    func testAboutHasThreeButtonsAndOneSupportRow() {
        setMode(.bypass)
        let texts = texts(on: .about)
        for name in ["Website", "GitHub", "Report a problem…", "Support the project", "Four ways to give, in one menu"] {
            XCTAssertTrue(texts.contains(name), "\(name) missing from About: \(texts.sorted())")
        }
        XCTAssertTrue(texts.contains { $0.hasPrefix("Version ") && $0.hasSuffix("· GPL-3.0 · by GeiserX") })
        for gone in ["GitHub Sponsors", "Patreon", "Your 100x Engineer, with ❤️", "Blog"] {
            XCTAssertFalse(texts.contains(gone), "\(gone) is still on the page")
        }
    }

    /// The bundle built from the live state names nothing the user typed.
    func testReportAProblemCarriesNoNamesFromTheRealState() {
        var config = rm.config
        config.domains = [DomainEntry(domain: "intranet.example.org", enabled: true)]
        config.services.append(ServiceEntry(id: "custom_work", name: "Work Tools", enabled: true,
                                            domains: ["tools.example.net"], ipRanges: ["198.51.100.0/24"], isCustom: true))
        rm.config = config
        rm.recentLogs = [RouteManager.LogEntry(timestamp: Date(), level: .error,
                                               message: "Work Tools: tools.example.net and intranet.example.org failed via 198.51.100.0/24")]
        let text = Diagnostics.bundle(Diagnostics.current(rm))
        for secret in ["Work Tools", "tools.example.net", "intranet", "198.51.100"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into:\n\(text)")
        }
        XCTAssertTrue(text.contains("[ERROR]"), "the error line is still there")
    }

    func testAServiceRemovedAfterItsWarningIsStillTakenOut() {
        var config = rm.config
        config.services.append(ServiceEntry(id: "custom_gone", name: "Gone Tools", enabled: true,
                                            domains: ["gone.example.net"], ipRanges: [], isCustom: true))
        rm.config = config
        rm.recentLogs = [RouteManager.LogEntry(timestamp: Date(), level: .warning, message: "Gone Tools got no addresses")]
        config.services.removeAll { $0.id == "custom_gone" }
        rm.config = config
        let text = Diagnostics.bundle(Diagnostics.current(rm))
        XCTAssertFalse(text.contains("Gone Tools"), text)
    }

    // MARK: Sheets

    /// Every sheet is one width and is built on SheetScaffold, with no close button.
    func testEverySheetIsOneWidthOnTheScaffold() throws {
        setMode(.bypass)
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        let rule = Rule(matchType: .domain, pattern: "en.wikipedia.org", routeId: route.id, order: 0)
        let sheets: [(String, AnyView)] = [
            ("new service", AnyView(NewServiceSheet(domain: "api.example.com", onCreate: { _ in }, onCancel: {}))),
            ("routing mode", AnyView(RoutingModeSheet(selected: .vpnOnly, lists: RoutingModeCopy.lists(from: rm.config),
                                                     onCancel: {}, onSwitch: { _ in }))),
            ("route editor", AnyView(RouteEditorSheet(editingRoute: route, selectableLinks: [], onSave: { _ in }, onCancel: {}))),
            ("rule editor", AnyView(RuleEditorSheet(editingRule: rule, services: rm.config.services,
                                                   onSave: { _ in }, onCancel: {}).environmentObject(rm))),
            ("custom service", AnyView(CustomServiceEditor(service: nil, name: "Work Tools").environmentObject(rm))),
            ("long custom service", AnyView(CustomServiceEditor(service: ServiceEntry(
                id: "custom_long", name: "Long", enabled: true,
                domains: (1...40).map { "host\($0).example.com" }, ipRanges: ["198.51.100.0/24"], isCustom: true))
                .environmentObject(rm))),
            ("catalogue", AnyView(CatalogueSheet { _ in }.environmentObject(rm))),
        ]
        for (name, sheet) in sheets {
            let hosting = NSHostingView(rootView: sheet)
            let size = hosting.fittingSize
            XCTAssertEqual(size.width, SheetScaffold<EmptyView>.width, "\(name) is \(size.width) pt wide")
            XCTAssertLessThan(size.height, 760, "\(name) does not fit its content")
        }

        let bodies = [("struct NewServiceSheet", "LookupsTab.swift"), ("struct RoutingModeSheet", "RoutingModeSwitcher.swift"),
                      ("struct RouteEditorSheet", "RoutesTab.swift"), ("struct RuleEditorSheet", "RulesTab.swift"),
                      ("struct CustomServiceEditor", "SettingsView.swift"), ("struct CatalogueSheet", "CatalogueSheet.swift")]
        for (declaration, file) in bodies {
            let body = try ReworkSource.body(of: declaration, in: file)
            XCTAssertTrue(body.contains("SheetScaffold("), "\(declaration) has its own frame")
            // The catalogue's search field has its own clear button; no sheet has a close button.
            let crosses = body.components(separatedBy: "xmark.circle.fill").count - 1
            XCTAssertEqual(crosses, body.contains("Clear search") ? 1 : 0, "\(declaration) has a close button")
            XCTAssertFalse(body.contains("Gradient"), "\(declaration) colours its button itself")
        }
    }

    // MARK: Helpers

    private func settle(_ window: NSWindow) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Every label, title and value in the window, as StatusLogsPageViewTests reads it.
    private func texts(on page: SettingsView.SettingsTab) -> Set<String> {
        window?.orderOut(nil)
        SettingsPageRequest.shared.page = page
        let window = SettingsWindowController.makeWindow()
        window.setContentSize(NSSize(width: 860, height: 1500))
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
