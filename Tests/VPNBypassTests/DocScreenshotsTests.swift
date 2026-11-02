// DocScreenshotsTests.swift
// Renders every screenshot in docs/images/screenshots/ from the real views, offscreen, with
// fixed fake state. Skipped unless VPNB_DOC_SCREENSHOTS names an output directory:
//
//   VPNB_DOC_SCREENSHOTS=/tmp/shots swift test --filter DocScreenshotsTests
//
// Run it on a Mac with a 2x display: the images are 2x and the renders take the screen's
// scale. Nothing here touches the routing table: the VPN check is off, routes are only
// written into `activeRoutes`, and the config is the test-run temp copy.

import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import VPNBypassCore

/// The dropdown's stand-in window: borderless, yet able to become key like the menu bar's.
final class DocScreenshotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    /// Kept where it is put, offscreen, instead of being pulled onto a display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class DocScreenshotsTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var outputDir: URL!
    private var windows: [NSWindow] = []
    /// A loopback listener started for the proxy route, stopped after the render.
    private var startedListener = false
    /// The app's appearance before the renders forced dark, put back in `tearDown`.
    private var savedAppearance: NSAppearance?
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, type: VPNType?,
                        gateway: String?, routes: [RouteManager.ActiveRoute], update: Date?,
                        loading: Bool, change: RouteManager.RouteChangeOutcome?, dns: Date?, helper: HelperState)!

    nonisolated private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The dropdown's ground in the menu bar on a dark desktop, sampled from a real capture.
    private static var dropdownGround: Color {
        isLight ? Color(red: 236 / 255, green: 236 / 255, blue: 236 / 255)
                : Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)
    }

    /// VPNB_DOC_APPEARANCE=light renders in the light appearance; dark otherwise.
    private static var isLight: Bool { ProcessInfo.processInfo.environment["VPNB_DOC_APPEARANCE"] == "light" }
    private static var renderAppearance: NSAppearance? { NSAppearance(named: isLight ? .aqua : .darkAqua) }

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VPNB_DOC_SCREENSHOTS"], !dir.isEmpty else {
            throw XCTSkip("Set VPNB_DOC_SCREENSHOTS to an output directory to render the doc screenshots.")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        Self.serveBrandMark(true)
        Self.serveLanguage(true)
        XCTAssertNotNil(Bundle.main.image(forResource: "menubar-icon-active"), "the title bar's mark loads")
        Self.drawAsFrontmost(true)
        XCTAssertNotEqual(NSApplication.shared.appearance?.name, .darkAqua,
                          "an earlier render's tearDown left the app forced dark")
        savedAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = Self.renderAppearance

        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.vpnType, rm.localGateway,
                 rm.activeRoutes, rm.lastUpdate, rm.isLoading, rm.lastRouteChange,
                 rm.lastDNSRefresh, HelperManager.shared.helperState)
        rm.refreshStatusOverrideForTests = {}
        SettingsPageRequest.shared.page = nil
    }

    override func tearDown() async throws {
        guard saved != nil else { return }
        Self.drawAsFrontmost(false)
        Self.serveBrandMark(false)
        Self.serveLanguage(false)
        XCTAssertNil(Bundle.main.image(forResource: "menubar-icon-active"),
                     "the test runner's own bundle answers again once the renders are done")
        NSApplication.shared.appearance = savedAppearance
        if startedListener { ProxyListenerManager.shared.stopAll() }
        startedListener = false
        windows.forEach { $0.orderOut(nil) }
        windows = []
        rm.refreshStatusOverrideForTests = nil
        rm.config = saved.config
        DNSLookupsMonitor.shared.tally = DNSLookupTally()
        DNSLookupsMonitor.shared.since = nil
        DNSLookupsMonitor.shared.learning = nil
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.vpnType = saved.type
        rm.localGateway = saved.gateway
        rm.activeRoutes = saved.routes
        rm.lastUpdate = saved.update
        rm.isLoading = saved.loading
        rm.lastRouteChange = saved.change
        rm.lastDNSRefresh = saved.dns
        HelperManager.shared.helperState = saved.helper
        SettingsPageRequest.shared.page = nil
        FrontTabWatcher.shared.suggestion = nil
    }

    // MARK: - The screenshots

    func testDropdownInBypassMode() throws {
        seedBypass()
        let size = try renderDropdown(to: "menu-bar.png")
        XCTAssertEqual(size.width, 680)
    }

    func testDropdownOnFirstRun() throws {
        seedConnected(mode: .bypass)
        rm.activeRoutes = []
        rm.lastRouteChange = nil
        // A Mac set to Spain, whatever the region of the Mac that renders it.
        FirstRunSetup.regionOverride = "ES"
        defer { FirstRunSetup.regionOverride = nil }
        let size = try renderDropdown(to: "first-run.png")
        XCTAssertEqual(size.width, 680)
    }

    func testDropdownInVPNOnlyMode() throws {
        seedConnected(mode: .vpnOnly)
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                                    DomainEntry(domain: "git.example.com", enabled: true)]
        var routes = ClassicRouteCompiler.bypassAllCatchAlls.map {
            route($0, via: "192.168.1.1", for: ClassicRouteCompiler.catchAllSource)
        }
        routes += addresses(["intranet.example.com": 2, "git.example.com": 1], gateway: "10.0.0.1")
        rm.activeRoutes = routes
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-19), routeCount: 3, failedCount: 0)
        let size = try renderDropdown(to: "vpn-only.png")
        XCTAssertEqual(size.width, 680)
    }

    /// VPN Only with the VPN down, as a user without the block setting sees it.
    func testDropdownInVPNOnlyWithTheVPNDown() throws {
        seedVPNOnlyDown()
        let size = try renderDropdown(to: "vpn-only-down.png")
        XCTAssertEqual(size.width, 680)
    }

    /// The same with the block setting on: the listed addresses of two entries are blocked,
    /// with the way out.
    func testDropdownInVPNOnlyWithBlocks() throws {
        seedVPNOnlyDown()
        let saved = rm.blockedRoutes
        addTeardownBlock { @MainActor in RouteManager.shared.blockedRoutes = saved }
        rm.config.blockListedWhenVPNDown = true
        rm.blockedRoutes = addresses(["intranet.example.com": 2, "git.example.com": 1], gateway: "")
        let size = try renderDropdown(to: "vpn-only-blocked.png")
        XCTAssertEqual(size.width, 680)
    }

    /// The General page, where the block setting is.
    func testSettingsOnGeneral() throws {
        seedVPNOnlyDown()
        rm.config.blockListedWhenVPNDown = true
        let size = try renderSettings(page: .general, to: "general.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    private func seedVPNOnlyDown() {
        seedConnected(mode: .vpnOnly)
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                                    DomainEntry(domain: "git.example.com", enabled: true)]
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        rm.activeRoutes = []
        rm.lastRouteChange = nil
    }

    /// The dropdown after Verify Routes, with the path check's three kinds of result: one address
    /// that went into the tunnel, one that left the right way without an answer on 443, and the
    /// rest the right way and answering.
    func testDropdownWithARouteCheck() throws {
        try renderRouteCheck(control: .passed, to: "route-check.png")
    }

    /// The same check when its control left around the VPN too: every result reads "Check broken".
    func testDropdownWithABrokenRouteCheck() throws {
        try renderRouteCheck(control: .broken(interface: "en0"), to: "route-check-broken.png")
    }

    private func renderRouteCheck(control: PathCheck.Control, to name: String) throws {
        seedBypass()
        let plan = RouteCheck.plan(routes: rm.activeRoutes.map { .init(destination: $0.destination, source: $0.source) },
                                   vpnOnly: false, isSingleAddress: { !$0.contains("/") })
        let results = plan.destinations.enumerated().map { index, address -> RouteVerificationResult in
            let probe: PathCheck.Probe
            switch index {
            case 0: probe = .init(address: address, routeInterface: "utun4", sourceAddress: "10.8.0.2",
                                  sourceInterface: "utun4", answer: .connected, latencyMs: 31)
            case 1: probe = .init(address: address, routeInterface: "en0", sourceAddress: "192.168.1.20",
                                  sourceInterface: "en0", answer: .noAnswer)
            default: probe = .init(address: address, routeInterface: "en0", sourceAddress: "192.168.1.20",
                                   sourceInterface: "en0", answer: .connected, latencyMs: Double(18 + index * 7))
            }
            return PathCheck.verificationResult(probe, expected: .physical, control: control)
        }
        var broken = false
        if case .broken = control { broken = true }
        rm.lastRouteCheck = RouteCheck.Run(plan: plan, results: results, logsFrom: Date(), at: Date(),
                                           controlBroken: broken)
        defer { rm.clearRouteCheck() }
        let size = try renderDropdown(to: name)
        XCTAssertEqual(size.width, 680)
    }

    func testSettingsOnServices() throws {
        seedBypass()
        let size = try renderSettings(page: .services, to: "services.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// A name added to Telegram from the Lookups page, a custom service that is off, and the
    /// pointer on Telegram, whose row offers the added name's remove.
    func testSettingsOnServicesHovered() throws {
        seedBypass()
        rm.config.builtInServiceExtras["telegram"] = ["telegram-cdn.example"]
        if let i = rm.config.services.firstIndex(where: { $0.id == "telegram" }) {
            rm.config.services[i].domains.append("telegram-cdn.example")
        }
        rm.config.services.append(ServiceEntry(id: "custom_work_tools", name: "Work Tools", enabled: false,
                                               domains: ["jira.example.com", "wiki.example.com"],
                                               ipRanges: ["203.0.113.0/24"], isCustom: true))
        ServicesTab.hoveredForScreenshots = "Telegram"
        defer { ServicesTab.hoveredForScreenshots = nil }
        let size = try renderSettings(page: .services, to: "services-hover.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// A fresh install: no service of the user's yet, so the page offers the catalogue.
    func testSettingsOnServicesWhenEmpty() throws {
        seedConnected(mode: .bypass)
        let size = try renderSettings(page: .services, to: "services-empty.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// A search that none of the user's services matches offers the same search in the catalogue.
    func testSettingsOnServicesWithASearchThatMisses() throws {
        seedBypass()
        SettingsView.searchForScreenshots = "netflix"
        defer { SettingsView.searchForScreenshots = nil }
        let size = try renderSettings(page: .services, to: "services-search.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// The catalogue sheet on the Banks chip, two banks picked: "Bypass 2 services".
    func testCatalogueSheet() throws {
        seedBypass()
        let hosting = NSHostingView(rootView: CatalogueSheet(category: .banks, picked: ["fr_lcl", "fr_boursobank"]) { _ in }
            .environmentObject(rm))
        let window = DocScreenshotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        show(window)
        window.setContentSize(hosting.fittingSize)
        settle(hosting)
        let size = try write(hosting, cornerRadius: 12, outline: NSColor(white: 1, alpha: 0.2), to: "catalogue.png")
        XCTAssertEqual(size.width, SheetScaffold<EmptyView>.width * 2)
    }

    /// The catalogue sheet on one country, as the first run's "Services for Spain…" opens it.
    func testCatalogueSheetOnACountry() throws {
        seedBypass()
        let hosting = NSHostingView(rootView: CatalogueSheet(region: "ES") { _ in }
            .environmentObject(rm))
        let window = DocScreenshotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        show(window)
        window.setContentSize(hosting.fittingSize)
        settle(hosting)
        let size = try write(hosting, cornerRadius: 12, outline: NSColor(white: 1, alpha: 0.2), to: "catalogue-region.png")
        XCTAssertEqual(size.width, SheetScaffold<EmptyView>.width * 2)
    }

    /// The Bypass list with a wildcard that has learned 11 routes, the pointer on the first
    /// row, and the VPN Only list read-only under it.
    func testSettingsOnDomains() throws {
        seedDomains(mode: .bypass)
        DomainsTab.hoveredForScreenshots = "en.wikipedia.org"
        defer { DomainsTab.hoveredForScreenshots = nil }
        let size = try renderSettings(page: .domains, to: "domains.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// VPN Only mode: its list, an IP range in it, and the Bypass list read-only under it.
    func testSettingsOnDomainsInVPNOnlyMode() throws {
        seedDomains(mode: .vpnOnly)
        let size = try renderSettings(page: .domains, to: "domains-vpn-only.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// An empty Bypass list: the add row, then the empty state under it.
    func testSettingsOnDomainsWhenEmpty() throws {
        seedBypass()
        rm.config.domains = []
        rm.config.inverseDomains = []
        let size = try renderSettings(page: .domains, to: "domains-empty.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// Custom mode: the page opens read-only with both lists, the Bypass list first.
    func testSettingsOnDomainsInCustomMode() throws {
        seedDomains(mode: .bypass)
        seedCustomRules()
        rm.config.routingMode = .custom
        let size = try renderSettings(page: .domains, to: "domains-custom.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// A Bypass entry that has not resolved for three refreshes with the VPN up: its row says
    /// since when, the pointer is on it (Remove), and the header offers the filter.
    func testSettingsOnDomainsWithAStaleEntry() throws {
        seedStaleDomain()
        DomainsTab.hoveredForScreenshots = "old-intranet.example.net"
        defer { DomainsTab.hoveredForScreenshots = nil }
        XCTAssertEqual(try renderSettings(page: .domains, to: "domains-stale.png"), Self.settingsSize)
    }

    /// The same page with the "Not resolving" filter on.
    func testSettingsOnDomainsFilteredToStaleEntries() throws {
        seedStaleDomain()
        DomainsTab.staleOnlyForScreenshots = true
        defer { DomainsTab.staleOnlyForScreenshots = false }
        XCTAssertEqual(try renderSettings(page: .domains, to: "domains-stale-filter.png"), Self.settingsSize)
    }

    /// A listed name and a wildcard whose routes reach CDN addresses (Fastly, Cloudflare): each
    /// row's detail line says other sites on the address take the same way.
    func testSettingsOnDomainsWithSharedCDNAddresses() throws {
        seedSharedDomains(mode: .bypass)
        XCTAssertEqual(try renderSettings(page: .domains, to: "domains-shared.png"), Self.settingsSize)
    }

    /// The same in VPN Only mode, where the other sites use the VPN too.
    func testSettingsOnDomainsWithASharedCDNAddressInVPNOnlyMode() throws {
        seedSharedDomains(mode: .vpnOnly)
        XCTAssertEqual(try renderSettings(page: .domains, to: "domains-shared-vpn-only.png"), Self.settingsSize)
    }

    /// CDN addresses from the published ranges the warning reads (SharedAddress), on top of
    /// the usual Domains seed.
    private func seedSharedDomains(mode: RoutingMode) {
        seedDomains(mode: mode)
        let cdn = ["151.101.1.140", "151.101.65.140", "151.101.129.140", "151.101.193.140"]
        if mode == .vpnOnly {
            rm.config.inverseDomains.insert(DomainEntry(domain: "status.example.org", enabled: true), at: 1)
            rm.activeRoutes += cdn.prefix(2).map { route($0, via: "iface:utun4", for: "status.example.org") }
        } else {
            rm.config.domains.insert(DomainEntry(domain: "www.reddit.com", enabled: true), at: 1)
            rm.activeRoutes += cdn.map { route($0, via: "192.168.1.1", for: "www.reddit.com") }
            rm.activeRoutes += ["104.18.32.7", "172.64.155.9"].map { route($0, via: "192.168.1.1", for: "*.example.com") }
        }
    }

    private func seedStaleDomain() {
        seedDomains(mode: .bypass)
        var dead = DomainEntry(domain: "old-intranet.example.net", enabled: true)
        dead.resolveFailures = ResolveFailures(count: StaleEntries.threshold,
                                               since: Date().addingTimeInterval(-9 * 86_400))
        rm.config.domains.insert(dead, at: 1)
    }

    private func seedDomains(mode: RoutingMode) {
        seedBypass()
        rm.config.domains.append(DomainEntry(domain: "*.example.com", enabled: true))
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.org", enabled: true),
                                    DomainEntry(domain: "10.20.0.0/16", enabled: true, isCIDR: true),
                                    DomainEntry(domain: "wiki.example.org", enabled: false)]
        if mode == .vpnOnly {
            rm.config.routingMode = .vpnOnly
            rm.activeRoutes = addresses(["intranet.example.org": 3, "10.20.0.0/16": 1], gateway: "iface:utun4")
        } else {
            rm.activeRoutes += addresses(["*.example.com": 11], gateway: "192.168.1.1")
        }
    }

    func testSettingsOnRules() throws {
        seedCustom()
        let size = try renderSettings(page: .rules, to: "rules.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    func testSettingsOnRoutes() throws {
        seedCustom()
        let size = try renderSettings(page: .routes, to: "routes.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// The pointer on the proxy rule: its edit and delete show beside the route chip.
    func testSettingsOnRulesHovered() throws {
        seedCustom()
        RulesTab.hoveredForScreenshots = "en.wikipedia.org"
        defer { RulesTab.hoveredForScreenshots = nil }
        XCTAssertEqual(try renderSettings(page: .rules, to: "rules-hover.png"), Self.settingsSize)
    }

    /// No rules yet: the empty state, then Everything else.
    func testSettingsOnRulesEmpty() throws {
        seedCustom()
        rm.config.rules = []
        XCTAssertEqual(try renderSettings(page: .rules, to: "rules-empty.png"), Self.settingsSize)
    }

    /// The pointer on office-proxy: Copy Proxy URL, edit and ⋯ show beside the type chip,
    /// and the line under the list is the one a proxy URL copy leaves, with the sign-in hint.
    func testSettingsOnRoutesHovered() throws {
        seedCustom()
        RoutesTab.hoveredForScreenshots = "office-proxy"
        RoutesTab.copiedLineForScreenshots = RouteRow.CopyKind.proxyURL.confirmation(routeName: "office-proxy")
        defer {
            RoutesTab.hoveredForScreenshots = nil
            RoutesTab.copiedLineForScreenshots = nil
        }
        XCTAssertEqual(try renderSettings(page: .routes, to: "routes-hover.png"), Self.settingsSize)
    }

    /// No routes of your own: Always there, then the empty state.
    func testSettingsOnRoutesEmpty() throws {
        seedCustom()
        rm.config.routes.removeAll { ProxyListenerManager.usesLocalListener($0.egress) }
        XCTAssertEqual(try renderSettings(page: .routes, to: "routes-empty.png"), Self.settingsSize)
    }

    // MARK: - The header, the search, the mode control and the logo

    // Every page's header band, the sidebar's logo and mode cards, and the dropdown's mode track,
    // rendered for the pull request in dark and light (VPNB_DOC_APPEARANCE) and in French
    // (VPNB_DOC_LANGUAGE=fr).

    func testHeaderEveryPage() throws {
        seedBypass()
        for page in SettingsView.SettingsTab.allCases {
            _ = try renderSettings(page: page, to: "header-\(page.rawValue).png")
        }
    }

    // BEGIN POLISH R3 SHOTS
    /// Every page's header at the default width and at the smallest, for the pull request.
    func testPolishHeaders() throws {
        seedBypass()
        let min = SettingsWindowController.minimumContentSize
        for page in SettingsView.SettingsTab.allCases {
            _ = try renderSettings(page: page, to: "polish-header-\(page.rawValue)-860.png")
            _ = try renderSettings(page: page, height: min.height, width: min.width, to: "polish-header-\(page.rawValue)-720.png")
        }
        // Custom mode with rules: the longer Rules line, "… Drag to reorder.".
        seedCustom()
        _ = try renderSettings(page: .rules, to: "polish-header-rules-custom-860.png")
        _ = try renderSettings(page: .rules, height: min.height, width: min.width, to: "polish-header-rules-custom-720.png")
    }

    /// The Domains list with two names that stopped resolving, and the Services list, whose
    /// headers hold the chip, the ⋯ menu and "addresses".
    func testPolishListHeaders() throws {
        seedStaleDomain()
        var second = DomainEntry(domain: "old-wiki.example.net", enabled: true)
        second.resolveFailures = ResolveFailures(count: StaleEntries.threshold, since: Date().addingTimeInterval(-4 * 86_400))
        rm.config.domains.insert(second, at: 2)
        let min = SettingsWindowController.minimumContentSize
        _ = try renderSettings(page: .domains, to: "polish-domains-860.png")
        _ = try renderSettings(page: .domains, height: min.height, width: min.width, to: "polish-domains-720.png")
        _ = try renderSettings(page: .services, to: "polish-services-860.png")
        _ = try renderSettings(page: .services, height: min.height, width: min.width, to: "polish-services-720.png")
    }

    /// Status > Problems for a listed name that stopped resolving and has no address.
    func testPolishProblems() throws {
        seedBypass()
        var dead = DomainEntry(domain: "old-intranet.example.net", enabled: true)
        dead.resolveFailures = ResolveFailures(count: StaleEntries.threshold, since: Date().addingTimeInterval(-9 * 86_400))
        rm.config.domains.append(dead)
        _ = try renderSettings(page: .status, to: "polish-status-problems.png")
    }

    /// The Lookups page after one name failed and the resolver retried it with two search domains.
    func testPolishLookupsRetries() throws {
        seedBypass()
        seedLookups()
        DNSLookupsMonitor.shared.readsSearchDomains = false // POLISH-AFTER-ONLY
        DNSLookupsMonitor.shared.searchDomains = ["corp.example", "lab.example"] // POLISH-AFTER-ONLY
        defer { DNSLookupsMonitor.shared.searchDomains = []; DNSLookupsMonitor.shared.readsSearchDomains = true } // POLISH-AFTER-ONLY
        var tally = DNSLookupsMonitor.shared.tally
        for _ in 0..<40 {
            tally.record(["build.example.com", "build.example.com.corp.example", "build.example.com.lab.example"], at: Date())
        }
        DNSLookupsMonitor.shared.tally = tally
        _ = try renderSettings(page: .lookups, to: "polish-lookups.png")
    }
    // END POLISH R3 SHOTS

    func testHeaderDomains() throws {
        seedDomains(mode: .bypass)
        _ = try renderSettings(page: .domains, to: "header-domains-filled.png")
    }

    func testHeaderRulesReadOnly() throws {
        seedBypass()
        seedCustomRules()
        _ = try renderSettings(page: .rules, to: "header-rules-readonly.png")
    }

    func testHeaderSearchTyped() throws {
        seedDomains(mode: .bypass)
        SettingsView.searchForScreenshots = "wiki"
        defer { SettingsView.searchForScreenshots = nil }
        _ = try renderSettings(page: .domains, to: "header-search.png")
    }

    /// The smallest window: the subtitle gives way, the search narrows, nothing overlaps.
    func testHeaderAtTheMinimumSize() throws {
        seedDomains(mode: .bypass)
        let min = SettingsWindowController.minimumContentSize
        _ = try renderSettings(page: .domains, height: min.height, width: min.width, to: "header-minimum.png")
    }

    func testHeaderCustomMode() throws {
        seedBypass()
        seedCustomRules()
        var config = rm.config
        config.routingMode = .custom
        rm.config = config
        _ = try renderSettings(page: .rules, to: "header-custom-rules.png")
    }

    func testHeaderDropdown() throws {
        seedBypass()
        _ = try renderDropdown(to: "header-dropdown.png")
    }

    func testHeaderDropdownCustom() throws {
        seedBypass()
        seedCustomRules()
        var config = rm.config
        config.routingMode = .custom
        rm.config = config
        _ = try renderDropdown(to: "header-dropdown-custom.png")
    }

    /// The Settings window at its default size, at 2x.
    private static let settingsSize = NSSize(width: 1720, height: 1240)

    /// The sidebar in each mode: Bypass on Rules (another mode's page, read-only), VPN Only on
    /// Services (read-only too), Custom on Rules (its own page).
    func testSidebarInBypassModeOnAReadOnlyPage() throws {
        seedBypass()
        seedCustomRules()
        XCTAssertEqual(try renderSettings(page: .rules, to: "sidebar-bypass.png"), Self.settingsSize)
    }

    func testSidebarInVPNOnlyModeOnAReadOnlyPage() throws {
        seedBypass()
        rm.config.routingMode = .vpnOnly
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                                    DomainEntry(domain: "10.20.0.0/16", enabled: true)]
        XCTAssertEqual(try renderSettings(page: .services, to: "sidebar-vpn-only.png"), Self.settingsSize)
    }

    func testSidebarInCustomMode() throws {
        seedCustom()
        XCTAssertEqual(try renderSettings(page: .rules, to: "sidebar-custom.png"), Self.settingsSize)
    }

    /// The title bar search on Domains, with one of the two domains left.
    func testSettingsSearchInTheTitleBar() throws {
        seedBypass()
        SettingsView.searchForScreenshots = "wiki"
        defer { SettingsView.searchForScreenshots = nil }
        XCTAssertEqual(try renderSettings(page: .domains, to: "search.png"), Self.settingsSize)
    }

    /// Custom mode's rules on a Bypass config, so the read-only Rules page has rows to show.
    private func seedCustomRules() {
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))
        rm.config.routes = [direct, vpn]
        rm.config.rules = [
            Rule(matchType: .domain, pattern: "en.wikipedia.org", routeId: direct.id, order: 0),
            Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: vpn.id, order: 1),
        ]
        rm.config.defaultRouteId = direct.id
        rm.config.schemaVersion = 2
    }

    func testSettingsOnLookups() throws {
        seedBypass()
        seedLookups()
        // The pointer on an unlisted row shows its add and ⋯ actions; every other row stays quiet.
        LookupsTab.hoveredForScreenshots = "api.openai.com"
        defer { LookupsTab.hoveredForScreenshots = nil }
        let size = try renderSettings(page: .lookups, to: "lookups.png")
        XCTAssertEqual(size, Self.settingsSize)
    }

    /// The Lookups page before it watches: the empty state with Start Watching, and the privacy note.
    func testSettingsOnLookupsOff() throws {
        seedBypass()
        rm.config.dnsLookupsEnabled = false
        XCTAssertEqual(try renderSettings(page: .lookups, to: "lookups-off.png"), Self.settingsSize)
    }

    /// Learn a site, 23 seconds into its window: the countdown, Stop, and the names the
    /// reload asked for so far, grouped by site.
    func testSettingsOnLookupsLearning() throws {
        seedBypass()
        rm.config.dnsLookupsEnabled = false
        var learning = SiteLearning(started: Date().addingTimeInterval(-23))
        learning.record(["shop.example.com", "static.example-cdn.net", "api.example.com"], at: Date().addingTimeInterval(-20))
        DNSLookupsMonitor.shared.learning = learning
        XCTAssertEqual(try renderSettings(page: .lookups, to: "lookups-learning.png"), Self.settingsSize)
    }

    /// Learn a site after its window: one row per site, the wildcard offer for the site with
    /// three names or more, a site already on the Bypass list with a check, and the one Add.
    func testSettingsOnLookupsLearned() throws {
        seedBypass()
        rm.config.dnsLookupsEnabled = false
        var learning = SiteLearning(started: Date().addingTimeInterval(-60))
        learning.record(["shop.example.com", "static.example-cdn.net", "api.example.com", "login.example.com",
                         "img.example-cdn.net", "en.wikipedia.org", "assets.example.com"], at: Date().addingTimeInterval(-50))
        learning.close()
        DNSLookupsMonitor.shared.learning = learning
        XCTAssertEqual(try renderSettings(page: .lookups, to: "lookups-learned.png"), Self.settingsSize)
    }

    /// Learn a site beside other apps: a news site's names first, a failed name's search-domain
    /// retries folded under their toggle, and a music and a call app that were already looking
    /// up their names set apart under Seen before you started.
    func testSettingsOnLookupsLearnedBesideOtherApps() throws {
        seedBypass()
        rm.config.dnsLookupsEnabled = false
        DNSLookupsMonitor.shared.readsSearchDomains = false
        DNSLookupsMonitor.shared.searchDomains = ["corp.example"]
        defer {
            DNSLookupsMonitor.shared.searchDomains = []
            DNSLookupsMonitor.shared.readsSearchDomains = true
        }
        var learning = SiteLearning(started: Date().addingTimeInterval(-60), seenBefore: Self.learnedNoiseSeenBefore)
        learning.record(Self.learnedNoiseNames, at: Date().addingTimeInterval(-50))
        learning.close()
        DNSLookupsMonitor.shared.learning = learning
        XCTAssertEqual(try renderSettings(page: .lookups, to: "lookups-learned-noise.png"), Self.settingsSize)
    }

    /// One failed name a VPN client retried with twenty company domains of its own, which no
    /// resolver lists: the Lookups list, and Learn a Site after a reload, with no search domain
    /// read. Renders `retry-shape-lookups.png` and `retry-shape-learned.png`.
    func testRetriesNoResolverLists() throws {
        seedBypass()
        seedLookups()
        DNSLookupsMonitor.shared.readsSearchDomains = false
        DNSLookupsMonitor.shared.searchDomains = []
        defer { DNSLookupsMonitor.shared.readsSearchDomains = true }
        let tails = ["net", "co", "media", "com", "org"]
        let retries = (1...20).map { "host.example.com.corp\($0).example.\(tails[$0 % 5])" }
        var tally = DNSLookupsMonitor.shared.tally
        for _ in 0..<6 { tally.record(["host.example.com"] + retries, at: Date()) }
        DNSLookupsMonitor.shared.tally = tally
        _ = try renderSettings(page: .lookups, to: "retry-shape-lookups.png")

        var learning = SiteLearning(started: Date().addingTimeInterval(-60))
        learning.record(["www.news.example", "img.news.example", "api.news.example", "host.example.com"]
                        + retries.prefix(8), at: Date().addingTimeInterval(-50))
        learning.close()
        DNSLookupsMonitor.shared.learning = learning
        _ = try renderSettings(page: .lookups, to: "retry-shape-learned.png")
    }

    /// What a news site reload looked up, with the noise around it.
    static let learnedNoiseNames = [
        "www.news.example", "api.music.example", "img.news.example", "metrics.news.example",
        "metrics.news.example.corp.example", "audio.music.example", "static.news-cdn.example",
        "ads.example.net", "ads.example.net.corp.example", "sip.voip.example", "api.news.example",
    ]
    static let learnedNoiseSeenBefore: Set<String> = ["api.music.example", "audio.music.example", "sip.voip.example"]

    /// A change a Shortcuts action made, named in the dropdown footer as `vpnb` changes are,
    /// and the Logs page that a click on the line opens.
    func testDropdownWithAShortcutsChange() throws {
        try renderOutsideChange(via: .shortcuts, dropdown: "shortcuts-change.png", logs: "logs-shortcuts.png")
    }

    /// The same for a `vpnb` change, which reads as it did before Shortcuts.
    func testDropdownWithACommandLineChange() throws {
        try renderOutsideChange(via: .controlSocket, dropdown: "command-line-change.png", logs: "logs-command-line.png")
    }

    private func renderOutsideChange(via: LogSource, dropdown: String, logs: String) throws {
        let savedLogs = rm.recentLogs, savedChange = rm.lastOutsideChange
        addTeardownBlock { @MainActor in
            RouteManager.shared.recentLogs = savedLogs
            RouteManager.shared.lastOutsideChange = savedChange
        }
        seedBypass()
        let now = Date()
        func line(_ ago: TimeInterval, _ level: RouteManager.LogEntry.LogLevel, _ message: String,
                  _ source: LogSource = .app) -> RouteManager.LogEntry {
            RouteManager.LogEntry(timestamp: now.addingTimeInterval(-ago), level: level, message: message, source: source)
        }
        rm.recentLogs = [
            line(118, .info, "Control: 'domain.add' applied", via),
            line(118, .info, "Config saved", via),
            line(119, .success, "Added domain: example.org", via),
            line(240, .success, "DNS refresh complete: 2 added, 1 removed"),
            line(600, .info, "Control: 'service.disable' applied", .controlSocket),
            line(600, .success, "Disabled service: Spotify", .controlSocket),
            line(900, .success, "Routes applied: 62"),
        ]
        rm.lastOutsideChange = OutsideChange(kind: .addedDomain("example.org"), at: now.addingTimeInterval(-118), via: via)
        _ = try renderDropdown(to: dropdown)
        // Run alone: a Settings window an earlier render left open takes the page request.
        SettingsPageRequest.shared.logFilter = LogFilter(onlySource: via)
        _ = try renderSettings(page: .logs, to: logs)
    }

    /// The add panel a Lookups row's chevron opens. A popover does not draw in an offscreen
    /// window, so the panel is drawn on its own, on the popover's dark ground, with a wildcard
    /// and a service chosen so both halves show what they do.
    func testLookupsAddPanel() throws {
        seedBypass()
        rm.config.services.append(ServiceEntry(id: "custom_datadog", name: "Datadog", enabled: true,
                                               domains: ["app.datadoghq.com"], ipRanges: [], isCustom: true))
        let name = "api.us5.datadoghq.com"
        let choices = LookupAddChoices(name: name, mode: .bypass, services: rm.lookupServices(for: name))
        XCTAssertEqual(choices.services.first?.name, "Datadog", "the service with a datadoghq.com name comes first")
        let panel = LookupAddPanel(choices: choices, level: "*.datadoghq.com", target: .service("custom_datadog"),
                                   onAdd: { _, _ in }, onCancel: {})
            .environmentObject(rm)
            .background(Self.popoverGround)
        let hosting = NSHostingView(rootView: panel)
        let window = DocScreenshotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: LookupAddPanel.width, height: 600),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        show(window)
        window.setContentSize(hosting.fittingSize)
        window.makeFirstResponder(nil)
        settle(hosting)
        let size = try write(hosting, cornerRadius: 10, outline: NSColor(white: 1, alpha: 0.15), to: "lookups-add.png")
        XCTAssertEqual(size.width, LookupAddPanel.width * 2)
    }

    // MARK: - The rework's shared components (step 2), one snapshot each

    /// 1. The group section: a section label, rows divided by an inset hairline.
    func testComponentGroupSection() throws {
        struct Item: Identifiable { let id: String; let detail: String }
        let items = [Item(id: "en.wikipedia.org", detail: "4 addresses"), Item(id: "github.com", detail: "12 addresses"),
                     Item(id: "example.com", detail: "1 address")]
        let view = GroupSection("Your domains", rows: items, trailing: { Text(verbatim: "addresses") }) { item in
            ListRow(glyph: "globe", name: item.id, detail: item.detail)
        }
        try renderComponent(view, to: "components-1-group-section.png")
    }

    /// 2. The list row: at rest, hovered with its actions, needing attention, switched off.
    func testComponentListRow() throws {
        let numbers = ["4", "1,203", "0", "–"]
        let width = ListRow.numberColumnWidth(for: numbers)
        let actions: (String) -> [RowAction] = { name in
            [.edit(name) {}, .delete(name) {}, RowAction(kind: .more, name: "More actions", systemImage: "ellipsis") {}]
        }
        let view = GroupSection("Section title", trailing: { Text(verbatim: "addresses") }) {
            ListRow(glyph: "globe", name: "At rest", detail: "detail line, secondary", number: numbers[0],
                    numberWidth: width, actions: actions("At rest"), isOn: .constant(true))
            InsetDivider()
            ListRow(glyph: "globe", name: "Hovered: actions fade in", detail: "also on right-click and keyboard",
                    number: numbers[1], numberWidth: width, actions: actions("Hovered"), isOn: .constant(true),
                    showsActions: true)
            InsetDivider()
            ListRow(glyph: "globe", name: "Needs attention", detail: "the reason, in the detail line",
                    needsAttention: true, number: numbers[2], numberWidth: width, actions: actions("Needs attention"),
                    isOn: .constant(true))
            InsetDivider()
            ListRow(glyph: "globe", name: "Switched off", detail: "off", number: numbers[3], numberWidth: width,
                    actions: actions("Switched off"), isOn: .constant(false))
            InsetDivider()
            ListRow(glyph: "network", name: "a-very-long-name-that-truncates-in-the-middle.cdn.example.com",
                    number: "12", numberWidth: width, isOn: .constant(true))
        }
        try renderComponent(view, to: "components-2-list-row.png")
    }

    /// 3. The page header: title, search, one +, and the line that says what the page is for.
    func testComponentPageHeader() throws {
        let view = PageHeader(title: "Routes", subtitle: "Where traffic can go: direct, a VPN, or a proxy.",
                              search: .constant(""), addName: "Add Route", onAdd: {})
        try renderComponent(view, to: "components-3-page-header.png")
    }

    /// 4. The empty state, inside its group box.
    func testComponentEmptyState() throws {
        let view = GroupSection {
            EmptyState(systemImage: "globe", title: "No domains yet",
                       message: "Add a site that should skip the VPN, or see what this Mac looks up.",
                       primary: .init(title: "Add Domain…") {}, link: .init(title: "Open Lookups") {})
        }
        try renderComponent(view, to: "components-4-empty-state.png")
    }

    /// 5. The status chip, every state.
    func testComponentStatusChip() throws {
        let view = HStack(spacing: Theme.Space.s) {
            ForEach(StatusChip.Kind.allCases, id: \.self) { StatusChip(state: $0) }
        }
        try renderComponent(view, to: "components-5-status-chip.png")
    }

    /// 6. The route chip: Direct, the VPN by name, a proxy, and one as a menu's label.
    func testComponentRouteChip() throws {
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5)
        let view = HStack(spacing: Theme.Space.s) {
            RouteChip(route: Route(name: "", egress: .direct), vpnName: "WireGuard")
            RouteChip(route: Route(name: "", egress: .vpnDefault), vpnName: "WireGuard")
            RouteChip(route: proxy, vpnName: "WireGuard")
            RouteChipMenu(RouteChip(route: proxy, vpnName: "WireGuard")) { Button("Direct") {} }
        }
        try renderComponent(view, to: "components-6-route-chip.png")
    }

    /// 7. The sheet scaffold, as a sheet and as a destructive confirm.
    func testComponentSheetScaffold() throws {
        let view = VStack(spacing: Theme.Space.l) {
            SheetScaffold("New Rule", confirmTitle: "Add Rule", onCancel: {}, onConfirm: {}) {
                GroupSection {
                    ListRow(glyph: "globe", name: "en.wikipedia.org", detail: "Domain")
                    InsetDivider()
                    ListRow(glyph: "arrow.up.right", name: "Direct", detail: "Route")
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.bgSecondary))
            SheetScaffold("Remove all routes?", confirmTitle: "Remove All", isDestructive: true,
                          onCancel: {}, onConfirm: {}) {
                Text("Every address this app routed goes back to the VPN.")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textSecondary)
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sheet).fill(Theme.bgSecondary))
        }
        try renderComponent(view, width: SheetScaffold<EmptyView>.width + 48, to: "components-7-sheet-scaffold.png")
    }

    /// Draws one component on the window's ground, 24 pt around it, at the given width.
    private func renderComponent<V: View>(_ view: V, width: CGFloat = 520, to name: String) throws {
        let hosting = NSHostingView(rootView: view
            .padding(Theme.Space.page)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.bgPrimary))
        let window = DocScreenshotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        show(window)
        window.setContentSize(hosting.fittingSize)
        window.makeFirstResponder(nil)
        settle(hosting)
        let size = try write(hosting, cornerRadius: 12, outline: NSColor(white: 1, alpha: 0.15), to: name)
        XCTAssertEqual(size.width, width * 2, name)
    }

    // MARK: - The rework's first fixes (A2 to A7, B1, B2), drawn for the pull request

    /// A2: the helper is down, yet the line under Refresh said what an old apply routed.
    func testReworkHelperDown() throws {
        seedBypass()
        HelperManager.shared.helperState = .missing
        _ = try renderDropdown(to: "rework-a2-helper-down.png")
    }

    /// A3: the first detection is still running.
    func testReworkStarting() throws {
        seedConnected(mode: .bypass)
        rm.activeRoutes = []
        rm.lastRouteChange = nil
        rm.config.domains = [DomainEntry(domain: "en.wikipedia.org", enabled: true)]
        rm.isLoading = true
        rm.lastUpdate = nil
        _ = try renderDropdown(to: "rework-a3-starting.png")
    }

    /// A4: an apply with failures.
    func testReworkPartlyRouted() throws {
        seedBypass()
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-23), routeCount: 62, failedCount: 7)
        _ = try renderDropdown(to: "rework-a4-partly-routed.png")
    }

    /// A5: the quick add in Custom mode.
    func testReworkCustomQuickAdd() throws {
        seedCustom()
        _ = try renderDropdown(to: "rework-a5-custom.png")
    }

    /// The Custom-mode "Routes In Use" summary with every kind of way out: Direct, the VPN,
    /// an HTTP proxy, a SOCKS5 proxy and a Tailscale exit node. Each shows its grey glyph,
    /// never a colour of its own.
    func testDropdownRoutesInUseWithEveryEgress() throws {
        seedCustom()
        let http = Route(name: "web-proxy", egress: .proxyHTTP, proxyHost: "198.51.100.8", proxyPort: 3128)
        let exit = Route(name: "exit-node", egress: .tailscaleExit, proxyHost: "100.64.0.9", proxyPort: 1055)
        // The summary shows four: Direct, grey before and after, is the one left in "+1 more".
        let seeded = rm.config.routes
        rm.config.routes = [http, seeded[2], exit, seeded[1], seeded[0]]
        rm.config.rules += [Rule(matchType: .domain, pattern: "intranet.example.com", routeId: http.id, order: 3),
                            Rule(matchType: .suffix, pattern: "example.org", routeId: exit.id, order: 4)]
        _ = try renderDropdown(to: "routes-in-use-every-egress.png")
    }

    /// Paused until resumed, then config.json stopped reading: Resume would put nothing back,
    /// so line 3 says why instead of offering it.
    func testDropdownPausedWithAnUnreadableConfig() throws {
        seedPaused(.untilResume)
        rm.isConfigLoadFailed = true
        addTeardownBlock { @MainActor in RouteManager.shared.isConfigLoadFailed = false }
        _ = try renderDropdown(to: "paused-config-unreadable.png")
    }

    /// Bypass with no VPN connected and nothing routed: Pause has nothing to take out.
    func testDropdownWithNothingRouted() throws {
        seedConnected(mode: .bypass)
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        rm.activeRoutes = []
        rm.lastRouteChange = nil
        _ = try renderDropdown(to: "mactest-nothing-routed.png")
    }

    /// The Logs page after three detection passes with no VPN connected, on this Mac's own
    /// interfaces, as the 30 s status timer runs them.
    func testLogsAfterThreeStatusPassesWithNoVPN() async throws {
        let savedLogs = rm.recentLogs
        addTeardownBlock { @MainActor in RouteManager.shared.recentLogs = savedLogs }
        seedConnected(mode: .bypass)
        rm.recentLogs = []
        for _ in 0..<3 { await rm.detectVPNStateOnly() }
        // That entry point adds a line of its own, which the status timer's pass does not.
        rm.recentLogs.removeAll { $0.message.hasPrefix("VPN state detected (display only)") }
        rm.isVPNConnected = false
        rm.activeRoutes = []
        XCTAssertEqual(try renderSettings(page: .logs, to: "mactest-logs-three-passes.png"), Self.settingsSize)
    }

    /// A6 and A7: Custom mode with no VPN, and a removal that left an address behind.
    func testReworkDisconnectedCustom() throws {
        seedCustom()
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        rm.activeRoutes = addresses(["Telegram": 1], gateway: "192.168.1.1")
        rm.lastRouteChange = .init(kind: .removedAll, at: Date().addingTimeInterval(-40), routeCount: 1, failedCount: 1)
        _ = try renderDropdown(to: "rework-a6-a7-disconnected-custom.png")
    }

    /// A7: Bypass mode keeps its routes for the reconnect.
    func testReworkDisconnectedBypass() throws {
        seedBypass()
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        _ = try renderDropdown(to: "rework-a7-disconnected-bypass.png")
    }

    /// B1: the route chips on the Rules page.
    func testReworkRules() throws {
        seedCustom()
        _ = try renderSettings(page: .rules, to: "rework-b1-rules.png")
    }

    /// B2: the General page's switches, some off.
    func testReworkGeneral() throws {
        seedBypass()
        rm.config.autoDNSRefresh = false
        _ = try renderSettings(page: .general, to: "rework-b2-general.png")
    }

    // MARK: - General, About and the sheets (rework step 10)

    /// General, the whole page: five groups, then Advanced closed.
    func testGeneralPage() throws {
        seedBypass()
        GeneralTab.detectedDNSForScreenshots = "192.0.2.53"
        defer { GeneralTab.detectedDNSForScreenshots = nil }
        NotificationManager.shared.notifyOnRoutesApplied = false
        _ = try renderSettings(page: .general, height: 1180, to: "general-page.png")
    }

    /// General with the global SOCKS5 proxy on: Advanced opens by itself.
    func testGeneralPageWithTheProxyOn() throws {
        seedBypass()
        GeneralTab.detectedDNSForScreenshots = "192.0.2.53"
        defer { GeneralTab.detectedDNSForScreenshots = nil }
        rm.config.proxyConfig.enabled = true
        rm.config.proxyConfig.server = "198.51.100.9"
        rm.config.proxyConfig.port = 1080
        // The page alone, in a borderless window that may be taller than the screen.
        try renderComponent(GeneralTab()
                                .environmentObject(rm)
                                .environmentObject(NotificationManager.shared)
                                .environmentObject(LaunchAtLoginManager.shared),
                            width: 620, to: "general-page-proxy.png")
    }

    /// General in Custom mode: no Advanced, one sentence that points at Routes.
    func testGeneralPageInCustomMode() throws {
        seedCustom()
        GeneralTab.detectedDNSForScreenshots = "192.0.2.53"
        defer { GeneralTab.detectedDNSForScreenshots = nil }
        _ = try renderSettings(page: .general, height: 1180, to: "general-page-custom.png")
    }

    // MARK: - Rework follow-ups, drawn for the pull request

    /// A rule whose route has a long name: the chip stops at its cap and truncates the name.
    func testFollowupRulesWithALongRouteName() throws {
        seedCustom()
        if let i = rm.config.routes.firstIndex(where: { $0.name == "office-proxy" }) {
            rm.config.routes[i].name = "office proxy through the second building, floor 3"
        }
        XCTAssertEqual(try renderSettings(page: .rules, to: "followup-rules-long-route.png"), Self.settingsSize)
    }

    /// Duplicate on office-proxy: the copy under it, and the line that can take it back.
    func testFollowupRoutesAfterDuplicate() throws {
        seedCustom()
        let proxy = try XCTUnwrap(rm.config.routes.first { $0.name == "office-proxy" })
        let copy = try XCTUnwrap(rm.duplicateRoute(proxy.id))
        let undo = SettingsUndo(last: .routeDuplicated(copy, original: proxy.name))
        // Opened on the page it was left on, so no page change drops the line.
        let savedPage = UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey)
        UserDefaults.standard.set(SettingsView.SettingsTab.routes.rawValue, forKey: SettingsSidebar.lastPageKey)
        defer { UserDefaults.standard.set(savedPage, forKey: SettingsSidebar.lastPageKey) }
        XCTAssertEqual(try renderSettings(page: .routes, settingsUndo: undo, to: "followup-routes-duplicated.png"),
                       Self.settingsSize)
    }

    /// A custom service named Telegram comes in while the page is open (an import, `vpnb`) and
    /// holds the built-in Telegram off: its row stays, its switch greyed.
    func testFollowupServicesWithAHeldOffService() throws {
        seedBypass()
        SettingsPageRequest.shared.page = .services
        let window = SettingsWindowController.makeWindow()
        window.setContentSize(SettingsWindowController.defaultContentSize)
        window.appearance = NSAppearance(named: .darkAqua)
        show(window)
        window.makeFirstResponder(nil)
        let frame = try XCTUnwrap(window.contentView?.superview, "the window's frame view")
        settle(frame)
        if let i = rm.config.services.firstIndex(where: { $0.id == "telegram" }) { rm.config.services[i].enabled = false }
        rm.config.services.append(ServiceEntry(id: "custom_telegram", name: "Telegram", enabled: true,
                                               domains: ["t.example"], ipRanges: [], isCustom: true))
        settle(frame)
        XCTAssertEqual(try write(frame, cornerRadius: 17, outline: NSColor(white: 1, alpha: 0.2),
                                 to: "followup-services-held-off.png"), Self.settingsSize)
    }

    private func seedProfiles() {
        let office = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:01", kind: .ethernet)
        let home = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:02", kind: .wifi)
        rm.currentNetwork = office
        var config = NetworkProfiles.creatingProfile(named: "Home", for: home, in: rm.config)
        config = NetworkProfiles.switching(config, to: .otherNetworks)
        config = NetworkProfiles.creatingProfile(named: "Office", for: office, in: config)
        rm.config = config
    }

    /// The dropdown names the profile in use at the end of its first line.
    func testFollowupDropdownWithAProfile() throws {
        seedBypass()
        let savedNetwork = rm.currentNetwork
        defer { rm.currentNetwork = savedNetwork }
        seedProfiles()
        _ = try renderDropdown(to: "followup-dropdown-profile.png")
    }

    /// Status > Connection names it too.
    func testFollowupStatusWithAProfile() throws {
        seedBypass()
        let savedNetwork = rm.currentNetwork
        defer { rm.currentNetwork = savedNetwork }
        seedProfiles()
        _ = try renderSettings(page: .status, height: 1500, to: "followup-status-profile.png")
    }

    func testFollowupSheetRenameProfile() throws {
        let home = NetworkProfile(id: UUID(), name: "Home", networks: [], settings: ProfileSettings(capturing: rm.config))
        try renderSheet(NewProfileSheet(profiles: [home], renaming: home, name: "", onCancel: {}, onSave: { _ in }),
                        to: "followup-sheet-rename-profile.png")
    }

    // MARK: - Profiles per network (idea 9)

    /// General with two profiles: Office in use on this network, Home on another, and Other
    /// networks for the rest.
    func testGeneralPageWithNetworkProfiles() throws {
        seedBypass()
        GeneralTab.detectedDNSForScreenshots = "192.0.2.53"
        let savedNetwork = rm.currentNetwork
        defer {
            GeneralTab.detectedDNSForScreenshots = nil
            rm.currentNetwork = savedNetwork
        }
        let office = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:01", kind: .ethernet)
        let home = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:02", kind: .wifi)
        rm.currentNetwork = office
        var config = NetworkProfiles.creatingProfile(named: "Home", for: home, in: rm.config)
        config = NetworkProfiles.switching(config, to: .otherNetworks)
        config = NetworkProfiles.creatingProfile(named: "Office", for: office, in: config)
        config.routingMode = .vpnOnly
        rm.config = config
        _ = try renderSettings(page: .general, height: 1400, to: "general-page-network-profiles.png")
    }

    /// The same page on a network no profile claims, so Home and Office offer to take it.
    func testGeneralPageOnANewNetwork() throws {
        seedBypass()
        GeneralTab.detectedDNSForScreenshots = "192.0.2.53"
        let savedNetwork = rm.currentNetwork
        defer {
            GeneralTab.detectedDNSForScreenshots = nil
            rm.currentNetwork = savedNetwork
        }
        let office = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:01", kind: .ethernet)
        let home = NetworkIdentity(gateway: "192.0.2.1", routerMAC: "02:00:00:00:00:02", kind: .wifi)
        var config = NetworkProfiles.creatingProfile(named: "Home", for: home, in: rm.config)
        config = NetworkProfiles.creatingProfile(named: "Office", for: office, in: config)
        config = NetworkProfiles.switching(config, to: .otherNetworks)
        rm.config = config
        rm.currentNetwork = NetworkIdentity(gateway: "198.51.100.1", routerMAC: "02:00:00:00:00:03", kind: .wifi)
        _ = try renderSettings(page: .general, height: 1400, to: "general-page-network-new.png")
    }

    func testSheetNewProfile() throws {
        try renderSheet(NewProfileSheet(profiles: [], name: "Office", onCancel: {}, onSave: { _ in }),
                        to: "sheet-new-profile.png")
    }

    /// About: the wordmark, one line, three buttons and the Support row.
    func testAboutPage() throws {
        seedBypass()
        _ = try renderSettings(page: .about, to: "about-page.png")
    }

    func testSheetNewService() throws {
        try renderSheet(NewServiceSheet(domain: "http-intake.logs.us5.datadoghq.com", onCreate: { _ in }, onCancel: {}),
                        to: "sheet-new-service.png")
    }

    func testSheetRoutingMode() throws {
        seedBypass()
        try renderSheet(RoutingModeSheet(selected: .vpnOnly, lists: RoutingModeCopy.lists(from: rm.config),
                                         onCancel: {}, onSwitch: { _ in }),
                        to: "sheet-routing-mode.png")
    }

    func testSheetRouteEditor() throws {
        seedBypass()
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        try renderSheet(RouteEditorSheet(editingRoute: proxy, selectableLinks: [], onSave: { _ in }, onCancel: {}),
                        to: "sheet-route-editor.png")
    }

    func testSheetRuleEditor() throws {
        seedCustom()
        let rule = rm.config.rules[0]
        try renderSheet(RuleEditorSheet(editingRule: rule, services: rm.config.services, onSave: { _ in }, onCancel: {})
                            .environmentObject(rm),
                        to: "sheet-rule-editor.png")
    }

    func testSheetCustomService() throws {
        seedBypass()
        try renderSheet(CustomServiceEditor(service: nil, name: "Work Tools").environmentObject(rm),
                        to: "sheet-custom-service.png")
    }

    func testSheetCatalogue() throws {
        seedBypass()
        try renderSheet(CatalogueSheet(category: .banks, picked: ["fr_lcl", "fr_boursobank"]) { _ in }
                            .environmentObject(rm),
                        to: "sheet-catalogue.png")
    }

    /// One sheet on its own, at the size it asks for.
    private func renderSheet<V: View>(_ view: V, to name: String) throws {
        let hosting = NSHostingView(rootView: view)
        let window = DocScreenshotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        show(window)
        window.setContentSize(hosting.fittingSize)
        window.makeFirstResponder(nil)
        settle(hosting)
        _ = try write(hosting, cornerRadius: Theme.Radius.sheet, outline: NSColor(white: 1, alpha: 0.2), to: name)
    }

    // MARK: - The dropdown's status block and Status > Problems (rework step 3)

    func testStatusBlockOn() throws {
        seedBypass()
        _ = try renderDropdown(to: "dropdown-on.png")
    }

    func testStatusBlockHelperDown() throws {
        seedBypass()
        HelperManager.shared.helperState = .missing
        _ = try renderDropdown(to: "dropdown-helper-down.png")
    }

    func testStatusBlockPartlyRouted() throws {
        seedPartlyRouted()
        _ = try renderDropdown(to: "dropdown-partly.png")
    }

    func testStatusBlockDisconnected() throws {
        seedBypass()
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        _ = try renderDropdown(to: "dropdown-disconnected.png")
    }

    func testStatusBlockStarting() throws {
        seedConnected(mode: .bypass)
        rm.activeRoutes = []
        rm.lastRouteChange = nil
        rm.config.domains = [DomainEntry(domain: "en.wikipedia.org", enabled: true)]
        rm.isLoading = true
        rm.lastUpdate = nil
        _ = try renderDropdown(to: "dropdown-starting.png")
    }

    func testStatusBlockVPNOnly() throws {
        seedConnected(mode: .vpnOnly)
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                                    DomainEntry(domain: "git.example.com", enabled: true)]
        var routes = ClassicRouteCompiler.bypassAllCatchAlls.map {
            route($0, via: "192.168.1.1", for: ClassicRouteCompiler.catchAllSource)
        }
        routes += addresses(["intranet.example.com": 2, "git.example.com": 1], gateway: "10.0.0.1")
        rm.activeRoutes = routes
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-19), routeCount: 3, failedCount: 0)
        _ = try renderDropdown(to: "dropdown-vpn-only.png")
    }

    /// Custom mode with no VPN and a removal that left an address behind: "Still routed".
    func testStatusBlockDisconnectedCustom() throws {
        seedCustom()
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        rm.activeRoutes = addresses(["Telegram": 1], gateway: "192.168.1.1")
        rm.lastRouteChange = .init(kind: .removedAll, at: Date().addingTimeInterval(-40), routeCount: 1, failedCount: 1)
        _ = try renderDropdown(to: "dropdown-disconnected-custom.png")
    }

    /// Where "Show" lands: the seven failures with their entry and reason, Zoom with no address,
    /// and the last route check, which left the dropdown.
    func testStatusPageProblems() throws {
        seedPartlyRouted()
        let plan = RouteCheck.plan(routes: rm.activeRoutes.map { .init(destination: $0.destination, source: $0.source) },
                                   vpnOnly: false, isSingleAddress: { !$0.contains("/") })
        let results = plan.destinations.enumerated().map { index, address -> RouteVerificationResult in
            let probe = PathCheck.Probe(address: address, routeInterface: "en0", sourceAddress: "192.168.1.20",
                                        sourceInterface: "en0", answer: index == 1 ? .noAnswer : .connected,
                                        latencyMs: Double(18 + index * 7))
            return PathCheck.verificationResult(probe, expected: .physical, control: .passed)
        }
        rm.lastRouteCheck = RouteCheck.Run(plan: plan, results: results, logsFrom: Date(), at: Date().addingTimeInterval(-51))
        defer { rm.clearRouteCheck() }
        _ = try renderSettings(page: .status, to: "status-problems.png")
    }

    // MARK: - Status and Logs on the components (step 9), drawn for the pull request

    // BEGIN STATUS LOGS SHOTS
    /// "Where does this site go?" for a site no list has: it follows the VPN, with Add.
    func testStatusPageSiteCheckUnlisted() throws {
        seedBypass()
        StatusTab.siteCheckForScreenshots = ("cdn.example.net", siteAnswer(
            host: "cdn.example.net", found: SiteRoute.Found(match: .none, expected: .tunnel("utun4")), via: "utun4"))
        defer { StatusTab.siteCheckForScreenshots = nil }
        XCTAssertEqual(try renderSettings(page: .status, to: "status-site-unlisted.png"), Self.settingsSize)
    }

    /// The same for a listed site whose route took it the wrong way.
    func testStatusPageSiteCheckWrongWay() throws {
        seedBypass()
        StatusTab.siteCheckForScreenshots = ("en.wikipedia.org", siteAnswer(
            host: "en.wikipedia.org",
            found: SiteRoute.Found(match: .route, entry: "en.wikipedia.org", routedDestination: "198.51.100.4",
                                   expected: .physical),
            via: "utun4"))
        defer { StatusTab.siteCheckForScreenshots = nil }
        XCTAssertEqual(try renderSettings(page: .status, to: "status-site-wrong-way.png"), Self.settingsSize)
    }

    /// The helper down with no VPN: the helper is the verdict and its section comes first.
    func testStatusPageHelperDownWithNoVPN() throws {
        seedBypass()
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        HelperManager.shared.helperState = .failed("Helper could not be started")
        XCTAssertEqual(try renderSettings(page: .status, to: "status-helper-down.png"), Self.settingsSize)
    }

    func testLogsPage() throws {
        try renderLogs(search: nil, to: "logs.png")
    }

    /// The title bar search on Logs.
    func testLogsPageSearched() throws {
        try renderLogs(search: "wiki", to: "logs-search.png")
    }

    private func renderLogs(search: String?, to name: String) throws {
        let savedLogs = rm.recentLogs
        addTeardownBlock { @MainActor in RouteManager.shared.recentLogs = savedLogs }
        seedBypass()
        let now = Date()
        func line(_ ago: TimeInterval, _ level: RouteManager.LogEntry.LogLevel, _ message: String) -> RouteManager.LogEntry {
            RouteManager.LogEntry(timestamp: now.addingTimeInterval(-ago), level: level, message: message)
        }
        rm.recentLogs = [
            line(20, .success, "Routes applied: 62"),
            line(64, .warning, "Could not resolve zoom.us: no answer from DNS"),
            line(65, .error, "Route add failed for 192.0.2.240: File exists"),
            line(119, .success, "Added domain: en.wikipedia.org"),
            line(119, .info, "Config saved"),
            line(240, .success, "DNS refresh complete: 2 added, 1 removed"),
            line(600, .info, "Detected VPN: WireGuard on utun4"),
        ]
        SettingsView.searchForScreenshots = search
        defer { SettingsView.searchForScreenshots = nil }
        XCTAssertEqual(try renderSettings(page: .logs, to: name), Self.settingsSize)
    }

    private func siteAnswer(host: String, found: SiteRoute.Found, via interface: String) -> SiteRouteAnswer {
        let probes = ["203.0.113.7", "203.0.113.8"].map {
            PathCheck.Probe(address: $0, routeInterface: interface, sourceAddress: "10.8.0.2",
                            sourceInterface: interface, answer: .connected, latencyMs: 24)
        }
        let control = PathCheck.Probe(address: "192.0.2.1", routeInterface: "utun4", answer: .notTried)
        return SiteRoute.answer(host: host, mode: .bypass, addresses: probes.map(\.address), found: found,
                                probes: probes, control: (control, .passed), vpnConnected: true)
    }
    // END STATUS LOGS SHOTS

    // MARK: - Dropdown rows and the add field (step 11), drawn for the pull request

    // BEGIN ROWS SHOTS
    func testRowsOn() throws {
        seedBypass()
        hoverRow("YouTube")
        _ = try renderDropdown(to: "rows-on.png")
    }

    func testRowsPartlyRouted() throws {
        seedPartlyRouted()
        hoverRow("Zoom")
        _ = try renderDropdown(to: "rows-partly.png")
    }

    func testRowsDisconnected() throws {
        seedBypass()
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        _ = try renderDropdown(to: "rows-disconnected.png")
    }

    func testRowsStarting() throws {
        seedConnected(mode: .bypass)
        rm.activeRoutes = []
        rm.lastRouteChange = nil
        rm.config.domains = [DomainEntry(domain: "en.wikipedia.org", enabled: true)]
        rm.isLoading = true
        rm.lastUpdate = nil
        _ = try renderDropdown(to: "rows-starting.png")
    }

    func testRowsLongList() throws {
        seedBypass()
        let more = ["github.com", "docs.example.com", "status.example.com", "registry.npmjs.org"]
        rm.config.domains += more.map { DomainEntry(domain: $0, enabled: true) }
        rm.activeRoutes += addresses(["github.com": 3, "docs.example.com": 2, "status.example.com": 1,
                                      "registry.npmjs.org": 2], gateway: "192.168.1.1")
        _ = try renderDropdown(to: "rows-long.png")
    }

    func testRowsVPNOnly() throws {
        seedConnected(mode: .vpnOnly)
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                                    DomainEntry(domain: "git.example.com", enabled: true)]
        rm.activeRoutes = ClassicRouteCompiler.bypassAllCatchAlls.map {
            route($0, via: "192.168.1.1", for: ClassicRouteCompiler.catchAllSource)
        } + addresses(["intranet.example.com": 2, "git.example.com": 1], gateway: "10.0.0.1")
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-19), routeCount: 3, failedCount: 0)
        _ = try renderDropdown(to: "rows-vpn-only.png")
    }

    func testRowsCustom() throws {
        seedCustom()
        _ = try renderDropdown(to: "rows-custom.png")
    }
    // END ROWS SHOTS

    // MARK: - Pause (step 12), drawn for the pull request

    // BEGIN PAUSE SHOTS
    func testPauseBypassOn() throws {
        seedBypass()
        _ = try renderDropdown(to: "pause-bypass-on.png")
    }

    func testPauseVPNOnly() throws {
        seedConnected(mode: .vpnOnly)
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                                    DomainEntry(domain: "git.example.com", enabled: true)]
        rm.activeRoutes = ClassicRouteCompiler.bypassAllCatchAlls.map {
            route($0, via: "192.168.1.1", for: ClassicRouteCompiler.catchAllSource)
        } + addresses(["intranet.example.com": 2, "git.example.com": 1], gateway: "10.0.0.1")
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-19), routeCount: 3, failedCount: 0)
        _ = try renderDropdown(to: "pause-vpn-only.png")
    }

    func testPauseCustomWithAProxyRule() throws {
        seedCustom()
        _ = try renderDropdown(to: "pause-custom.png")
    }
    // END PAUSE SHOTS

    // MARK: - Bypass the site you are on (idea 3), drawn for the pull request

    // BEGIN FRONT TAB SHOTS
    func testFrontTabBypass() throws {
        seedBypass()
        showFrontTab(host: "shop.example.com", browser: "Safari", id: "com.apple.Safari")
        _ = try renderDropdown(to: "fronttab-bypass.png")
    }

    func testFrontTabAlreadyListed() throws {
        seedBypass()
        showFrontTab(host: "en.wikipedia.org", browser: "Google Chrome", id: "com.google.Chrome")
        _ = try renderDropdown(to: "fronttab-listed.png")
    }

    func testFrontTabNotYetAllowed() throws {
        seedBypass()
        showFrontTab(host: nil, browser: "Safari", id: "com.apple.Safari")
        _ = try renderDropdown(to: "fronttab-allow.png")
    }

    func testFrontTabVPNOnly() throws {
        seedConnected(mode: .vpnOnly)
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true)]
        rm.activeRoutes = ClassicRouteCompiler.bypassAllCatchAlls.map {
            route($0, via: "192.168.1.1", for: ClassicRouteCompiler.catchAllSource)
        } + addresses(["intranet.example.com": 2], gateway: "10.0.0.1")
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-19), routeCount: 2, failedCount: 0)
        showFrontTab(host: "git.example.com", browser: "Brave Browser", id: "com.brave.Browser")
        _ = try renderDropdown(to: "fronttab-vpn-only.png")
    }

    func testFrontTabCustom() throws {
        seedCustom()
        showFrontTab(host: "shop.example.com", browser: "Microsoft Edge", id: "com.microsoft.edgemac")
        _ = try renderDropdown(to: "fronttab-custom.png")
    }

    func testFrontTabDisconnected() throws {
        seedBypass()
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.vpnType = nil
        rm.activeRoutes = []
        showFrontTab(host: "shop.example.com", browser: "Safari", id: "com.apple.Safari")
        _ = try renderDropdown(to: "fronttab-disconnected.png")
    }

    // The open as macOS 27 hands it over: Safari with process id -1, access on, then off.
    func testFrontTabReadWithHiddenProcessID() async throws {
        seedBypass()
        await driveFrontTab(permission: .granted)
        _ = try renderDropdown(to: "fronttab-read-granted.png")
    }

    func testFrontTabAccessOff() async throws {
        seedBypass()
        await driveFrontTab(permission: .denied)
        _ = try renderDropdown(to: "fronttab-access-off.png")
    }
    // END FRONT TAB SHOTS

    // MARK: - Every catalogue service draws its own symbol (live-test L7), drawn for the pull request

    // BEGIN SERVICE GLYPH SHOTS
    func testServiceGlyphsInTheDropdown() throws {
        seedServiceGlyphs()
        _ = try renderDropdown(to: "glyphs-dropdown.png")
    }

    func testServiceGlyphsOnServices() throws {
        seedServiceGlyphs()
        _ = try renderSettings(page: .services, to: "glyphs-services.png")
    }
    // END SERVICE GLYPH SHOTS

    /// Bypass with a service of each kind on: two that had their own symbol (Telegram,
    /// YouTube) beside Signal, Netflix, a bank, a public service and an AI service.
    private func seedServiceGlyphs() {
        seedConnected(mode: .bypass)
        let counts = ["telegram": 18, "signal": 6, "youtube": 16, "netflix": 9, "es_bbva": 3, "es_gov": 4, "openai": 5]
        var routes: [RouteManager.ActiveRoute] = []
        var found: Set<String> = []
        for i in rm.config.services.indices {
            guard let n = counts[rm.config.services[i].id] else { continue }
            found.insert(rm.config.services[i].id)
            rm.config.services[i].enabled = true
            for _ in 0..<n { routes.append(route("192.0.2.\(routes.count + 1)", via: "192.168.1.1", for: rm.config.services[i].name)) }
        }
        XCTAssertEqual(found, Set(counts.keys), "every service the glyph shots ask for is in the catalogue")
        rm.activeRoutes = routes
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-23),
                                   routeCount: counts.values.reduce(0, +), failedCount: 0)
    }

    /// Runs one dropdown open through a watcher whose macOS is swapped for seams: Safari in front
    /// with the process id -1 macOS 27 reports, the given permission, a page on shop.example.com.
    /// The dropdown draws the row that open published.
    private func driveFrontTab(permission: FrontTabPermission) async {
        let safari = FrontAppTracker.App(bundleID: "com.apple.Safari", name: "Safari", isRegular: true,
                                         pid: -1, process: StubProcess(terminated: false))
        let watcher = FrontTabWatcher(system: .init(
            frontmost: { nil },
            isRunning: FrontTabWatcher.stillRuns,
            permission: { _, _ in permission },
            runScript: { _ in FrontTabScriptResult(url: "https://shop.example.com/cart", errorNumber: nil) },
            log: { _, _ in }), ownBundleID: "com.example.vpnbypass", readsTabs: true)
        watcher.activated(safari)
        watcher.refresh()
        await watcher.readTask?.value
        FrontTabWatcher.shared.suggestion = watcher.suggestion
    }

    /// What the front tab row shows; nil `host` is a browser macOS has not been asked about.
    private func showFrontTab(host: String?, browser: String, id: String) {
        let found = FrontTabBrowser.detect(bundleID: id, name: browser)!
        FrontTabWatcher.shared.suggestion = host.map { .site(host: $0, browser: found) } ?? .needsConsent(browser: found)
    }

    func testPausePausedForAnHour() throws {
        seedPaused(.oneHour)
        _ = try renderDropdown(to: "pause-paused-hour.png")
    }

    func testPausePausedUntilReconnect() throws {
        seedPaused(.untilReconnect)
        _ = try renderDropdown(to: "pause-paused-reconnect.png")
    }

    func testPausePausedUntilResume() throws {
        seedPaused(.untilResume)
        _ = try renderDropdown(to: "pause-paused-resume.png")
    }

    /// The removal failed for five addresses: Retry, never Paused.
    func testPausePausedWithRoutesLeft() throws {
        seedPaused(.oneHour)
        rm.activeRoutes = addresses(["Telegram": 5], gateway: "192.168.1.1")
        rm.lastRouteChange = .init(kind: .removedAll, at: Date().addingTimeInterval(-60), routeCount: 5, failedCount: 5)
        _ = try renderDropdown(to: "pause-paused-left.png")
    }

    func testPausePausedStatusPage() throws {
        seedPaused(.oneHour)
        _ = try renderSettings(page: .status, to: "pause-paused-status.png")
    }

    // BEGIN LIVE TEST CORE SHOTS
    /// A list entry an older version saved as ".example.net", loaded from config.json.
    private func seedLeadingDotEntry() throws {
        seedBypass()
        var cfg = rm.config
        cfg.domains.append(DomainEntry(domain: ".example.net", enabled: true))
        try JSONEncoder().encode(cfg).write(to: rm.configURL)
        rm.loadConfig()
    }

    func testLiveCoreLeadingDotDomains() throws {
        try seedLeadingDotEntry()
        _ = try renderSettings(page: .domains, to: "live-leading-dot-domains.png")
    }

    func testLiveCoreLeadingDotDropdown() throws {
        try seedLeadingDotEntry()
        _ = try renderDropdown(to: "live-leading-dot-dropdown.png")
    }

    /// "Where does this site go?" for a listed site while routing is paused for 15 minutes.
    func testLiveCoreSiteCheckWhilePaused() throws {
        seedPaused(.fifteenMinutes)
        let addresses = ["203.0.113.7", "203.0.113.8"]
        let found = SiteRoute.match(host: "en.wikipedia.org", addresses: addresses, in: rm.siteRouteSnapshot)
        StatusTab.siteCheckForScreenshots = ("en.wikipedia.org", siteAnswer(host: "en.wikipedia.org", found: found, via: "utun4"))
        defer { StatusTab.siteCheckForScreenshots = nil }
        _ = try renderSettings(page: .status, to: "live-why-paused.png")
    }

    /// The apply installed 58; a wildcard lookup added 4 since. The dropdown and Status count the same.
    private func seedRoutesLearnedSinceTheApply() {
        seedBypass()
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-23), routeCount: 58, failedCount: 0)
    }

    func testLiveCoreCountDropdown() throws {
        seedRoutesLearnedSinceTheApply()
        _ = try renderDropdown(to: "live-count-dropdown.png")
    }

    func testLiveCoreCountStatus() throws {
        seedRoutesLearnedSinceTheApply()
        _ = try renderSettings(page: .status, to: "live-count-status.png")
    }
    // END LIVE TEST CORE SHOTS

    // BEGIN LEGACY DOT NOTICE SHOTS
    /// The first launch after the upgrade rewrote two entries saved as ".name": Status says which.
    func testLegacyDotNoticeStatus() throws {
        seedBypass()
        try? FileManager.default.removeItem(at: rm.convertedEntriesURL)
        let notify = rm.notifyConvertedEntries
        rm.notifyConvertedEntries = { _ in }
        defer {
            rm.notifyConvertedEntries = notify
            rm.dismissConvertedEntries()
        }
        var cfg = rm.config
        cfg.domains += [DomainEntry(domain: ".example.net", enabled: true), DomainEntry(domain: ".example.org", enabled: true)]
        try JSONEncoder().encode(cfg).write(to: rm.configURL)
        rm.loadConfig()
        _ = try renderSettings(page: .status, to: "legacy-dot-notice-status.png")
    }
    // END LEGACY DOT NOTICE SHOTS

    // BEGIN FOLLOWUPS CORE SHOTS
    /// "Until the VPN reconnects": the VPN came back while the helper was down, so the pause
    /// holds and says it waits for the helper.
    func testFollowupsPauseWaitingForTheHelper() throws {
        seedPaused(.untilReconnect)
        var pause = try XCTUnwrap(rm.pauseState)
        pause.reconnectedWaiting = true
        rm.setPauseStateForTests(pause)
        HelperManager.shared.helperState = .missing
        _ = try renderDropdown(to: "followups-pause-waiting.png")
    }

    /// Custom paused with every rule Direct: the list says what Resume puts back.
    func testFollowupsPauseCustom() throws {
        seedConnected(mode: .custom)
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))
        rm.config.routes = [direct, vpn]
        rm.config.rules = [
            Rule(matchType: .domain, pattern: "en.wikipedia.org", routeId: direct.id, order: 0),
            Rule(matchType: .domain, pattern: "news.ycombinator.com", routeId: direct.id, order: 1),
            Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: direct.id, order: 2),
        ]
        rm.config.defaultRouteId = vpn.id
        rm.config.schemaVersion = 2
        rm.activeRoutes = []
        rm.lastRouteChange = .init(kind: .removedAll, at: Date().addingTimeInterval(-120), routeCount: 0, failedCount: 0)
        rm.setPauseStateForTests(PauseState(length: .oneHour, since: Date().addingTimeInterval(-120), mode: .custom))
        addTeardownBlock { @MainActor in RouteManager.shared.setPauseStateForTests(nil) }
        _ = try renderDropdown(to: "followups-pause-custom.png")
    }

    /// A VPN kill switch is on: the shared CDN line no longer says the other sites bypass it.
    func testFollowupsSharedAddressUnderAKillSwitch() throws {
        seedSharedDomains(mode: .bypass)
        rm.vpnKillSwitch = VPNKillSwitch(name: "Proton VPN", includeAllNetworks: true, enforceRoutes: false,
                                         excludeLocalNetworks: false)
        addTeardownBlock { @MainActor in RouteManager.shared.vpnKillSwitch = nil }
        XCTAssertEqual(try renderSettings(page: .domains, to: "followups-shared-kill-switch.png"), Self.settingsSize)
    }
    // END FOLLOWUPS CORE SHOTS

    /// Bypass paused two minutes ago: every route out, the lists kept for Resume.
    private func seedPaused(_ length: PauseLength) {
        seedBypass()
        rm.activeRoutes = []
        rm.lastRouteChange = .init(kind: .removedAll, at: Date().addingTimeInterval(-120), routeCount: 0, failedCount: 0)
        rm.setPauseStateForTests(PauseState(length: length, since: Date().addingTimeInterval(-120), mode: .bypass))
        addTeardownBlock { @MainActor in RouteManager.shared.setPauseStateForTests(nil) }
    }

    /// The Status page when the app is opened again with its menu bar icon hidden.
    func testRowsStatusWithTheIconHidden() throws {
        seedBypass()
        MenuBarIconVisibility.shared.isHidden = true
        defer { MenuBarIconVisibility.shared.isHidden = false }
        _ = try renderSettings(page: .status, to: "rows-status-icon-hidden.png")
    }

    private func hoverRow(_ name: String) {
        RoutedBySourceCard.hoveredRowForScreenshots = name
        addTeardownBlock { @MainActor in RoutedBySourceCard.hoveredRowForScreenshots = nil }
    }

    /// Bypass with Zoom on and no address for it, and an apply 64 s ago with seven failures:
    /// two names that did not resolve and five addresses the helper refused.
    private func seedPartlyRouted() {
        seedBypass()
        if let i = rm.config.services.firstIndex(where: { $0.id == "zoom" }) {
            rm.config.services[i].enabled = true
        } else {
            rm.config.services.append(ServiceEntry(id: "zoom", name: "Zoom", enabled: true,
                                                   domains: ["zoom.us"], ipRanges: [], isCustom: false))
        }
        let refused = ["192.0.2.240", "192.0.2.241", "192.0.2.242", "198.51.100.17", "198.51.100.18"]
        rm.lastRouteChange = .init(
            kind: .applied, at: Date().addingTimeInterval(-64), routeCount: 62, failedCount: 7,
            failures: RouteManager.RouteFailure.unresolved([("zoom.us", "Zoom"), ("zoomgov.com", "Zoom")])
                + RouteManager.RouteFailure.batch(.notRouted, failed: refused,
                                                  sources: refused.map { ($0, $0.hasPrefix("192") ? "Telegram" : "WhatsApp") },
                                                  error: "File exists"))
    }

    /// Close to a popover's ground in dark mode.
    private static let popoverGround = Color(red: 40 / 255, green: 40 / 255, blue: 42 / 255)

    // MARK: - Fake state

    /// WireGuard on utun4, helper ready, nothing on any list yet.
    private func seedConnected(mode: RouteManager.RoutingMode) {
        var cfg = RouteManager.Config()
        cfg.routingMode = mode
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        rm.config = cfg
        rm.isVPNConnected = true
        rm.vpnInterface = "utun4"
        rm.vpnType = .wireGuard
        rm.localGateway = "192.168.1.1"
        rm.isLoading = false
        rm.lastUpdate = Date().addingTimeInterval(-23)
        rm.lastDNSRefresh = Date().addingTimeInterval(-12 * 60)
        HelperManager.shared.helperState = .ready
    }

    /// Four services and two domains, 62 addresses routed around the VPN.
    private func seedBypass() {
        seedConnected(mode: .bypass)
        let on: Set = ["telegram", "whatsapp", "youtube", "spotify"]
        for i in rm.config.services.indices where on.contains(rm.config.services[i].id) {
            rm.config.services[i].enabled = true
        }
        rm.config.domains = [DomainEntry(domain: "en.wikipedia.org", enabled: true),
                             DomainEntry(domain: "news.ycombinator.com", enabled: true)]
        rm.activeRoutes = addresses(["Telegram": 18, "WhatsApp": 12, "YouTube": 16, "Spotify": 8,
                                     "en.wikipedia.org": 4, "news.ycombinator.com": 4],
                                    gateway: "192.168.1.1")
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-23), routeCount: 62, failedCount: 0)
    }

    /// The DNS Lookups page on, with a morning of browsing counted: the two listed domains and
    /// zoom.us (in the custom service Meetings) show as Bypassed; the rest show only their
    /// names, long ones in full, until the pointer is on them.
    private func seedLookups() {
        rm.config.dnsLookupsEnabled = true
        rm.config.services.append(ServiceEntry(id: "custom_meetings", name: "Meetings", enabled: true,
                                               domains: ["zoom.us"], ipRanges: [], isCustom: true))
        // Counts from one to four digits, so the shot shows the bars still line up.
        let counts = ["github.com": 1602, "slack.com": 755, "en.wikipedia.org": 548, "zoom.us": 321,
                      "api.openai.com": 214, "docs.google.com": 181, "news.ycombinator.com": 96,
                      "registry.npmjs.org": 41, "http-intake.logs.us5.datadoghq.com": 12,
                      "browser-intake-us5-datadoghq.com": 7, "status.example.com": 3]
        var tally = DNSLookupTally()
        let start = Date().addingTimeInterval(-3 * 3600)
        for round in 0..<(counts.values.max() ?? 0) {
            tally.record(counts.filter { $0.value > round }.map(\.key), at: start.addingTimeInterval(Double(round) * 6))
        }
        DNSLookupsMonitor.shared.tally = tally
        DNSLookupsMonitor.shared.since = start
    }

    /// A domain to a SOCKS5 proxy, a service direct, a subnet to the VPN, the rest direct.
    private func seedCustom() {
        seedConnected(mode: .custom)
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5,
                          proxyHost: "198.51.100.7", proxyPort: 1080, localListenPort: 18168)
        rm.config.routes = [direct, vpn, proxy]
        rm.config.rules = [
            Rule(matchType: .domain, pattern: "en.wikipedia.org", routeId: proxy.id, order: 0),
            Rule(matchType: .service, pattern: "telegram", routeId: direct.id, order: 1),
            Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: vpn.id, order: 2),
        ]
        rm.config.defaultRouteId = direct.id
        rm.config.schemaVersion = 2
        rm.config.multiRouteEnabled = true
        rm.activeRoutes = addresses(["Telegram": 18], gateway: "192.168.1.1")
            + [route("203.0.113.0/24", via: "10.0.0.1", for: "203.0.113.0/24")]

        // The Routes page shows a proxy route's local address once its listener is up. This
        // one listens on 127.0.0.1 only and reaches its upstream only if a client connects.
        var up = false
        ProxyListenerManager.shared.reconcile(routes: rm.config.routes, boundInterface: nil) { up = true }
        startedListener = true
        let deadline = Date().addingTimeInterval(5)
        while !up && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(ProxyListenerManager.shared.port(for: proxy.id), 18168,
                       "office-proxy's listener is up on the port the docs show")
    }

    private func route(_ destination: String, via gateway: String, for source: String) -> RouteManager.ActiveRoute {
        .init(destination: destination, gateway: gateway, source: source, timestamp: Date())
    }

    /// Addresses from the documentation ranges (RFC 5737), never a real host.
    private func addresses(_ counts: KeyValuePairs<String, Int>, gateway: String) -> [RouteManager.ActiveRoute] {
        let blocks = ["192.0.2", "198.51.100", "203.0.113"]
        var next = 0
        var out: [RouteManager.ActiveRoute] = []
        for (source, count) in counts {
            for _ in 0..<count {
                let ip = "\(blocks[next / 250]).\(next % 250 + 1)"
                out.append(route(ip, via: gateway, for: source))
                next += 1
            }
        }
        return out
    }

    // MARK: - Rendering

    private func renderDropdown(to name: String) throws -> NSSize {
        let hosting = NSHostingView(rootView: MenuContent()
            .environmentObject(rm)
            .environmentObject(NotificationManager.shared)
            .environmentObject(LaunchAtLoginManager.shared)
            .background(Self.dropdownGround))
        let window = DocScreenshotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = Self.renderAppearance
        window.contentView = hosting
        show(window)
        window.setContentSize(hosting.fittingSize)
        settle(hosting)
        return try write(hosting, cornerRadius: 15, outline: NSColor(white: 0.2, alpha: 1), to: name)
    }

    private func renderSettings(page: SettingsView.SettingsTab, height: CGFloat? = nil, width: CGFloat? = nil,
                                settingsUndo: SettingsUndo? = nil, to name: String) throws -> NSSize {
        SettingsPageRequest.shared.page = page
        let window = SettingsWindowController.makeWindow(settingsUndo: settingsUndo)
        // makeWindow brings back a size saved by an earlier run; the renders use the default,
        // or a taller window to show a whole page.
        var windowSize = SettingsWindowController.defaultContentSize
        if let height { windowSize.height = height }
        if let width { windowSize.width = width }
        window.setContentSize(windowSize)
        window.appearance = Self.renderAppearance
        show(window)
        window.makeFirstResponder(nil)
        let frame = try XCTUnwrap(window.contentView?.superview, "the window's frame view")
        settle(frame)
        let size = try write(frame, cornerRadius: 17, outline: NSColor(white: 1, alpha: 0.2), to: name)
        // Sampled where the close button really is, so a title bar change cannot move it off
        // the sampled pixel and pass on the window's ground.
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton), "the window has a close button")
        let centre = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        try assertCloseButtonIsRed(name, at: NSPoint(x: centre.x, y: frame.bounds.height - centre.y))
        return size
    }

    /// The close button is red only in the key window of the active app: grey here means the
    /// render came out inactive, switches and accents included.
    private func assertCloseButtonIsRed(_ name: String, at point: NSPoint) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: outputDir.appendingPathComponent(name))))
        // The renders are 2x; the point is in the window's points, from its top left.
        let close = try XCTUnwrap(rep.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(close.redComponent, 0.8, "\(name): close button \(close)")
        XCTAssertLessThan(close.greenComponent, 0.5, "\(name): close button \(close)")
    }

    /// Off every display, drawn as the key window of the active app (see `drawAsFrontmost`).
    private func show(_ window: NSWindow) {
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        windows.append(window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.post(name: name, object: window)
        }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        settle(window.contentView!)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Caches `view`, rounds its corners, draws a 1 pt outline inside the edge, and writes a PNG.
    private func write(_ view: NSView, cornerRadius: CGFloat, outline: NSColor, to name: String) throws -> NSSize {
        let bounds = view.bounds
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let scale = CGFloat(image.width) / bounds.width
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let radius = cornerRadius * scale
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: rect)
        let edge = rect.insetBy(dx: scale / 2, dy: scale / 2)
        ctx.addPath(CGPath(roundedRect: edge, cornerWidth: radius - scale / 2, cornerHeight: radius - scale / 2, transform: nil))
        ctx.setStrokeColor(outline.cgColor)
        ctx.setLineWidth(scale)
        ctx.strokePath()
        let out = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
        let png = try XCTUnwrap(out.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent(name))
        return NSSize(width: image.width, height: image.height)
    }

    // MARK: - Drawn as the frontmost window

    /// A process started over ssh cannot activate itself, so AppKit would draw every window
    /// inactive: grey traffic lights, grey switches. While on, every window reports itself key
    /// and main, and the app active. AppKit draws from its private appearance getters as well
    /// as the public ones, so both are answered; a selector a later macOS drops is skipped, and
    /// the close-button check in `renderSettings` catches a render that comes out inactive.
    /// Swapped per class, not per window: changing a window's class breaks the key-value
    /// observers AppKit keeps on it.
    private static var originals: [(Method, IMP)] = []

    private static func drawAsFrontmost(_ on: Bool) {
        guard on else {
            originals.forEach { method_setImplementation($0.0, $0.1) }
            originals = []
            return
        }
        guard originals.isEmpty else { return }
        let alwaysTrue = method_getImplementation(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.docScreenshotTrue))!)
        let getters: [(AnyClass, [String])] = [
            (NSWindow.self, ["isKeyWindow", "isMainWindow", "hasKeyAppearance", "hasMainAppearance",
                             "_isKeyWindow", "_hasKeyAppearance", "_hasMainAppearance", "_hasActiveControls",
                             "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus",
                             "_hasActiveAppearanceForStandardWindowButton:"]),
            (NSApplication.self, ["isActive", "_isActiveApp"]),
        ]
        for (cls, names) in getters {
            for name in names {
                guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { continue }
                originals.append((method, method_setImplementation(method, alwaysTrue)))
            }
        }
    }

    // MARK: - Brand mark

    /// The title bar and wordmark load the mark from `Bundle.main`, which under XCTest is the
    /// test runner. Serve it from `assets/`, where the app bundle copies it from, while on;
    /// off swaps the two methods back.
    private static var brandMarkInstalled = false

    private static func serveBrandMark(_ on: Bool) {
        guard on != brandMarkInstalled else { return }
        brandMarkInstalled = on
        let original = class_getInstanceMethod(Bundle.self, #selector(Bundle.image(forResource:)))!
        let replacement = class_getInstanceMethod(Bundle.self, #selector(Bundle.docScreenshotImage(forResource:)))!
        method_exchangeImplementations(original, replacement)
    }

    // MARK: - Language

    /// VPNB_DOC_LANGUAGE=fr (or es) renders in that language: `Bundle.main`, the test runner,
    /// answers from the source tree's lproj folder while on.
    nonisolated(unsafe) fileprivate static var languageBundle: Bundle?
    private static var languageInstalled = false

    private static func serveLanguage(_ on: Bool) {
        guard let language = ProcessInfo.processInfo.environment["VPNB_DOC_LANGUAGE"], language != "en",
              on != languageInstalled else { return }
        languageInstalled = on
        languageBundle = on ? Bundle(url: repoRoot.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")) : nil
        // Text and String(localized:) reach the table through one of these three.
        for (name, swap) in [("localizedStringForKey:value:table:", #selector(Bundle.docScreenshotLocalizedString(forKey:value:table:))),
                             ("localizedStringForKey:value:table:localizations:",
                              #selector(Bundle.docScreenshotLocalizedString(forKey:value:table:localizations:))),
                             ("_localizedStringForKey:value:table:localizations:",
                              #selector(Bundle.docScreenshotPrivateLocalizedString(forKey:value:table:localizations:)))] {
            // A selector this macOS lacks (the public localizations: one arrived in 15.4) is skipped.
            guard let original = class_getInstanceMethod(Bundle.self, NSSelectorFromString(name)),
                  let replacement = class_getInstanceMethod(Bundle.self, swap) else { continue }
            method_exchangeImplementations(original, replacement)
        }
    }

    nonisolated fileprivate static func assetImage(_ name: String) -> NSImage? {
        let assets = repoRoot.appendingPathComponent("assets")
        guard let one = NSImageRep(contentsOf: assets.appendingPathComponent("\(name).png")) else {
            return NSImage(contentsOf: assets.appendingPathComponent("\(name).icns"))
        }
        let image = NSImage(size: one.size)
        image.addRepresentation(one)
        if let two = NSImageRep(contentsOf: assets.appendingPathComponent("\(name)@2x.png")) {
            two.size = one.size
            image.addRepresentation(two)
        }
        return image
    }
}

extension NSWindow {
    @objc fileprivate func docScreenshotTrue() -> Bool { true }
}

extension Bundle {
    /// Swapped with `localizedString(forKey:value:table:)` while a language other than English
    /// renders; calling itself calls the original.
    @objc fileprivate func docScreenshotLocalizedString(forKey key: String, value: String?, table: String?) -> String {
        if self == Bundle.main, let language = DocScreenshotsTests.languageBundle {
            return language.docScreenshotLocalizedString(forKey: key, value: value, table: table)
        }
        return docScreenshotLocalizedString(forKey: key, value: value, table: table)
    }

    @objc fileprivate func docScreenshotLocalizedString(forKey key: String, value: String?, table: String?,
                                                        localizations: [String]?) -> String {
        if self == Bundle.main, let language = DocScreenshotsTests.languageBundle {
            return language.docScreenshotLocalizedString(forKey: key, value: value, table: table)
        }
        return docScreenshotLocalizedString(forKey: key, value: value, table: table, localizations: localizations)
    }

    @objc fileprivate func docScreenshotPrivateLocalizedString(forKey key: String, value: String?, table: String?,
                                                               localizations: [String]?) -> String {
        if self == Bundle.main, let language = DocScreenshotsTests.languageBundle {
            return language.docScreenshotLocalizedString(forKey: key, value: value, table: table)
        }
        return docScreenshotPrivateLocalizedString(forKey: key, value: value, table: table, localizations: localizations)
    }

    /// Swapped with `image(forResource:)` while the screenshots render; calling itself calls
    /// the original.
    @objc fileprivate func docScreenshotImage(forResource name: NSImage.Name) -> NSImage? {
        if self == Bundle.main, let image = DocScreenshotsTests.assetImage(name) { return image }
        return docScreenshotImage(forResource: name)
    }
}
