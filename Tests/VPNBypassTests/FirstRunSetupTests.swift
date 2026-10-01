// FirstRunSetupTests.swift
// The question a fresh install asks in the dropdown (proposal 6A): when it shows, which
// services it offers, what the pill and header say meanwhile, and that its switches and its
// "All N services…" row reach the same code as the Services page.
//
// The problem it locks down: a fresh install showed an amber NO ROUTES pill and a tinted box
// that sent the user to Settings with no button to get there.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

final class FirstRunSetupTests: XCTestCase {

    private let services = RouteManager.Config.defaultServices

    private func on(_ ids: String...) -> [ServiceEntry] {
        services.map { var s = $0; s.enabled = ids.contains(s.id); return s }
    }

    // MARK: When it shows

    func testAFreshBypassInstallIsFresh() {
        XCTAssertTrue(FirstRunSetup.isFresh(mode: .bypass, domains: [], services: services, installedRoutes: 0))
    }

    func testAnythingConfiguredIsNotFresh() {
        XCTAssertFalse(FirstRunSetup.isFresh(mode: .bypass, domains: [], services: on("telegram"), installedRoutes: 0),
                       "a service is on")
        XCTAssertFalse(FirstRunSetup.isFresh(mode: .bypass, domains: [DomainEntry(domain: "x.com")], services: services, installedRoutes: 0),
                       "a domain is listed")
        var off = DomainEntry(domain: "x.com")
        off.enabled = false
        XCTAssertFalse(FirstRunSetup.isFresh(mode: .bypass, domains: [off], services: services, installedRoutes: 0),
                       "a domain switched off is still something the user set up")
        XCTAssertFalse(FirstRunSetup.isFresh(mode: .bypass, domains: [], services: services, installedRoutes: 3),
                       "routes are installed: the normal view keeps Remove All Routes in reach")
    }

    /// VPN Only installs its catch-all routes with an empty list, and Custom has its own
    /// pages; the question is about the Bypass list.
    func testOnlyBypassAsks() {
        XCTAssertFalse(FirstRunSetup.isFresh(mode: .vpnOnly, domains: [], services: services, installedRoutes: 0))
        XCTAssertFalse(FirstRunSetup.isFresh(mode: .custom, domains: [], services: services, installedRoutes: 0))
    }

    // MARK: What it offers

    func testSixCommonServicesInTheMockupsOrder() {
        let common = FirstRunSetup.commonServices(in: services)
        XCTAssertEqual(common.map(\.name), ["Telegram", "WhatsApp", "YouTube", "Zoom", "Microsoft Teams", "Spotify"])
    }

    func testAServiceMissingFromTheCatalogueIsSkipped() {
        let common = FirstRunSetup.commonServices(in: services.filter { $0.id != "zoom" })
        XCTAssertEqual(common.map(\.id), ["telegram", "whatsapp", "youtube", "teams", "spotify"])
    }

    /// Zoom and Teams drew a globe, the symbol for "no symbol".
    func testEveryOfferedServiceHasItsOwnSymbol() {
        let symbols = FirstRunSetup.commonServiceIDs.map { ServiceChip.iconName(for: $0) }
        XCTAssertFalse(symbols.contains("globe"), "\(symbols)")
        XCTAssertEqual(Set(symbols).count, symbols.count, "two services share a symbol: \(symbols)")
        XCTAssertEqual(ServiceChip.iconName(for: "zoom"), "video.fill")
        XCTAssertEqual(ServiceChip.iconName(for: "teams"), "person.2.fill")
        XCTAssertEqual(ServiceChip.iconName(for: "no-such-service"), "globe")
    }

    func testWording() {
        XCTAssertEqual(FirstRunSetup.title, "What should skip the VPN?")
        XCTAssertEqual(FirstRunSetup.allServices(37), "All 37 services…")
        XCTAssertEqual(FirstRunSetup.domainCount(1), "1 domain")
        XCTAssertEqual(FirstRunSetup.domainCount(6), "6 domains")
        XCTAssertEqual(FirstRunSetup.modeLine + " " + FirstRunSetup.useVPNOnly,
                       "Mode: Bypass. Want only a few sites on the VPN and everything else direct? Use VPN Only instead…")
    }

    // MARK: The pill and the header

    private func input(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "WireGuard", helperReady: true, mode: .bypass,
            enabledServices: 0, enabledDomains: 0, enabledRules: 0, installedRoutes: 0,
            pending: nil, lastRouteChange: nil, lastDNSRefresh: nil, nextDNSRefresh: nil,
            autoDNSRefresh: true, nothingConfigured: true)
        edit(&i)
        return i
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFreshInstallIsNotSetUpNotNoRoutes() {
        let s = DropdownStatus.make(input(), now: now)
        XCTAssertEqual(s.pill, "NOT SET UP")
        XCTAssertEqual(s.tone, .idle, "grey, not the amber of a fault")
        XCTAssertEqual(s.headerTone, .ok, "the VPN itself is connected and fine")
        XCTAssertEqual(s.headline, "WireGuard connected")
        XCTAssertEqual(s.sentence, "Nothing skips the VPN yet.")
        XCTAssertEqual(s.facts, [], "no Routes or DNS facts about routes nobody asked for")
    }

    func testOnceSomethingIsOnTheNormalStatesReturn() {
        XCTAssertEqual(DropdownStatus.make(input { $0.nothingConfigured = false; $0.enabledServices = 1 }, now: now).pill,
                       "NO ROUTES", "a service is on but its routes are not in yet")
        XCTAssertEqual(DropdownStatus.make(input { $0.nothingConfigured = false; $0.enabledServices = 1; $0.installedRoutes = 6 }, now: now).pill,
                       "ON")
    }

    /// No VPN and a dead helper are bigger facts than an empty list.
    func testNotSetUpNeverHidesAProblem() {
        XCTAssertEqual(DropdownStatus.make(input { $0.isVPNConnected = false }, now: now).pill, "OFF")
        XCTAssertEqual(DropdownStatus.make(input { $0.helperReady = false }, now: now).pill, "NOT ENFORCING")
        XCTAssertEqual(DropdownStatus.make(input { $0.isVPNConnected = false }, now: now).headerTone, .bad)
    }

    func testOtherTonesKeepTheirHeaderColour() {
        for tone: DropdownStatus.Tone in [.ok, .warn, .bad] {
            let s = DropdownStatus(pill: "", tone: tone, headline: "", sentence: "", note: nil, facts: [])
            XCTAssertEqual(s.headerTone, tone)
        }
    }

    // MARK: Translations

    func testTheQuestionIsTranslated() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            guard dir.pathComponents.count > 1 else { throw XCTSkip("repo root not found from \(#filePath)") }
            dir = dir.deletingLastPathComponent()
        }
        let keys = ["NOT SET UP", "What should skip the VPN?", "Switched-on services use your normal connection.",
                    "All %lld services…", "Add a site, like example.com", "Add Site",
                    "Mode: Bypass. Want only a few sites on the VPN and everything else direct?",
                    "Use VPN Only instead…", "Nothing skips the VPN yet.", "1 domain", "%lld domains"]
        for lang in ["en", "es", "fr"] {
            let url = dir.appendingPathComponent("Sources/VPNBypassCore/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys {
                let value = try XCTUnwrap(table[key], "\(lang).lproj has no entry for \"\(key)\"")
                if lang != "en" && key != "1 domain" {
                    XCTAssertNotEqual(value, key, "\(lang).lproj leaves \"\(key)\" in English")
                }
            }
            let bundle = try XCTUnwrap(Bundle(url: url.deletingLastPathComponent()), lang)
            let all = String(localized: "All \(37) services…", bundle: bundle)
            XCTAssertTrue(all.contains("37"), "\(lang): \(all)")
        }
    }
}

/// The real views, hosted in a window. The VPN is never connected here, so a switch only
/// saves the config, and the config is restored after each test.
@MainActor
final class FirstRunSetupViewTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedVPNConnected = false
    private var savedIsLoading = true
    private var window: NSWindow?

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() async throws {
        savedConfig = rm.config
        savedVPNConnected = rm.isVPNConnected
        savedIsLoading = rm.isLoading
        rm.isVPNConnected = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        rm.config = cfg
        SettingsPageRequest.shared.page = nil
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        rm.config = savedConfig
        rm.isVPNConnected = savedVPNConnected
        rm.isLoading = savedIsLoading
        SettingsPageRequest.shared.page = nil
    }

    private func host<V: View>(_ view: V, size: NSSize) -> NSView {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        self.window = window
        settle(hosting)
        return hosting
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func switches(in view: NSView) -> [NSSwitch] {
        var found: [NSSwitch] = []
        func walk(_ v: NSView) {
            if let s = v as? NSSwitch { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }

    /// The first switch is Telegram's, and clicking it turns Telegram on in the config through
    /// `toggleService`, the Services page's call; clicking again turns it off.
    func testASwitchTurnsTheServiceOnAndOff() throws {
        var opened = 0
        let view = host(FirstRunSetupView(onOpenServices: { opened += 1 }, onUseVPNOnly: {})
                            .environmentObject(rm)
                            .frame(width: 308),
                        size: NSSize(width: 308, height: 520))
        let rows = switches(in: view)
        XCTAssertEqual(rows.count, 6, "one switch per common service")
        let telegram = try XCTUnwrap(rows.first)
        XCTAssertFalse(rm.config.services.first { $0.id == "telegram" }!.enabled, "control: off before the click")

        telegram.performClick(nil)
        settle(view)
        XCTAssertTrue(rm.config.services.first { $0.id == "telegram" }!.enabled)
        XCTAssertEqual(rm.config.services.filter(\.enabled).map(\.id), ["telegram"], "only the clicked service")

        telegram.performClick(nil)
        settle(view)
        XCTAssertFalse(rm.config.services.first { $0.id == "telegram" }!.enabled)
        XCTAssertEqual(opened, 0)
    }

    /// While an apply holds the route gate, the add field is off, as on the Domains page: an
    /// add then would save the site without routing it.
    func testTheAddFieldWaitsForAnApply() throws {
        let view = host(FirstRunSetupView(site: "example.com", onOpenServices: {}, onUseVPNOnly: {})
                            .environmentObject(rm)
                            .frame(width: 308),
                        size: NSSize(width: 308, height: 520))
        var fields: [NSTextField] = []
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, f.isEditable { fields.append(f) }
            v.subviews.forEach(walk)
        }
        walk(view)
        let field = try XCTUnwrap(fields.first)
        XCTAssertEqual(fields.count, 1)
        XCTAssertTrue(field.isEnabled, "control: on while nothing is applying")

        XCTAssertTrue(rm.tryAcquireRouteOperationForTests())
        defer { rm.releaseRouteOperationForTests() }
        settle(view)
        XCTAssertFalse(field.isEnabled, "off while an apply runs")
    }

    /// The real dropdown follows the config while it stays open. A MenuBarExtra(.window) runs
    /// `.onAppear` on its first open only and never `.onDisappear`, so anything latched on open
    /// stays latched for the app's life: here the host runs `.onAppear` once and never closes,
    /// the same as the menu bar. The VPN check on open is off, and the change uses a domain
    /// that is switched off, so nothing here can install a route on this machine.
    func testTheDropdownLeavesAndReturnsToTheQuestionWithoutReopening() throws {
        rm.isLoading = false
        let view = host(MenuContent(refreshesOnOpen: false)
                            .environmentObject(rm)
                            .environmentObject(NotificationManager.shared)
                            .environmentObject(LaunchAtLoginManager.shared),
                        size: NSSize(width: 340, height: 760))
        XCTAssertEqual(switches(in: view).count, 6, "control: a fresh install shows the question")

        rm.config.domains = [DomainEntry(domain: "example.com", enabled: false)]
        settle(view)
        XCTAssertEqual(switches(in: view).count, 0, "something on the list: the normal dropdown, at once")

        rm.config.domains = []
        settle(view)
        XCTAssertEqual(switches(in: view).count, 6, "the list emptied again: the question comes back")
    }

    /// The "All N services…" row opens Settings on the Services page, and the request is used
    /// once. The Domains page, the default, has no switch with an empty list; the Services page
    /// has one per service.
    func testTheSettingsWindowOpensOnTheRequestedPage() throws {
        func settings() -> some View {
            SettingsView()
                .environmentObject(rm)
                .environmentObject(NotificationManager.shared)
                .environmentObject(LaunchAtLoginManager.shared)
                .environmentObject(ModeSwitchRequest())
        }
        let plain = host(settings(), size: NSSize(width: 580, height: 680))
        XCTAssertEqual(switches(in: plain).count, 0, "control: with no request the window opens on Domains")
        window?.orderOut(nil)

        SettingsPageRequest.shared.page = .services
        let asked = host(settings(), size: NSSize(width: 580, height: 680))
        XCTAssertGreaterThan(switches(in: asked).count, 5, "the Services page, with its switches")
        XCTAssertNil(SettingsPageRequest.shared.page, "the window took the request")
    }
}
