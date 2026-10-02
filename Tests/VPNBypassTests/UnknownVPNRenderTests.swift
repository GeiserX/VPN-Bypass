// UnknownVPNRenderTests.swift
// A tunnel the app could not name carries the label "Unknown VPN", an English placeholder.
// The Status page's tunnel list, its Act on picker and the route editor's VPN picker show
// the localized "VPN" in its place (#159). These draw the real views offscreen in English,
// Spanish and French, with one such tunnel in fixed fake state, and read what they show.
// Every menu and segmented control in the route editor, the rule editor and the General
// page also carries a name for VoiceOver; five of them had none.
// Nothing is routed: the VPN check is off and the tunnels are handed in, never read.
//
// Set VPNB_RENDERS to a directory to also write each render there as a PNG.

import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class UnknownVPNRenderTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var window: NSWindow?
    /// Whether the app was already set up as an assistive client, put back in `tearDown`.
    private var wasAccessibilityClient = false
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, type: VPNType?,
                        gateway: String?, ssid: String?, routes: [RouteManager.ActiveRoute], update: Date?,
                        loading: Bool, change: RouteManager.RouteChangeOutcome?, dns: Date?,
                        logs: [RouteManager.LogEntry], helper: HelperState, helperVersion: String?, helperError: String?)!

    private static let languages = ["en", "es", "fr"]
    private static let unknown = VPNType.unknown.rawValue

    override func setUp() async throws {
        let helper = HelperManager.shared
        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.vpnType, rm.localGateway, rm.currentNetworkSSID,
                 rm.activeRoutes, rm.lastUpdate, rm.isLoading, rm.lastRouteChange, rm.lastDNSRefresh,
                 rm.recentLogs, helper.helperState, helper.helperVersion, helper.installationError)
        rm.refreshStatusOverrideForTests = {}
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        rm.config = cfg
        rm.isVPNConnected = true
        rm.vpnInterface = "utun7"
        rm.vpnType = .unknown
        rm.localGateway = "192.168.1.1"
        rm.currentNetworkSSID = nil
        rm.activeRoutes = []
        rm.lastUpdate = Date().addingTimeInterval(-23)
        rm.isLoading = false
        rm.lastRouteChange = nil
        rm.lastDNSRefresh = Date().addingTimeInterval(-12 * 60)
        rm.recentLogs = []
        helper.helperState = .ready
        helper.helperVersion = nil
        helper.installationError = nil
        // SwiftUI builds its accessibility tree only for an assistive client, which this sets
        // the app up as; without it the page reads as one empty group.
        wasAccessibilityClient = Self.isAccessibilityClient
        Self.setAccessibilityClient(true)
        XCTAssertTrue(Self.isAccessibilityClient, "control: the setting reads back")
    }

    override func tearDown() async throws {
        Self.speak(nil)
        Self.setAccessibilityClient(wasAccessibilityClient)
        window?.orderOut(nil)
        window = nil
        guard saved != nil else { return }
        let helper = HelperManager.shared
        rm.refreshStatusOverrideForTests = nil
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.vpnType = saved.type
        rm.localGateway = saved.gateway
        rm.currentNetworkSSID = saved.ssid
        rm.activeRoutes = saved.routes
        rm.lastUpdate = saved.update
        rm.isLoading = saved.loading
        rm.lastRouteChange = saved.change
        rm.lastDNSRefresh = saved.dns
        rm.recentLogs = saved.logs
        helper.helperState = saved.helper
        helper.helperVersion = saved.helperVersion
        helper.installationError = saved.helperError
    }

    // MARK: - The three spots

    func testTheTunnelListShowsVPN() throws {
        for language in Self.languages {
            let shown = try renderStatusPage(language)
            assertNoPlaceholder(shown, "\(language) Status page")
            let row = try XCTUnwrap(shown.text.firstIndex(of: "utun7"), "\(language): control, the tunnel row is on the page")
            XCTAssertEqual(shown.text[row + 1], "VPN", "\(language): the tunnel row's label")
        }
    }

    func testTheActOnPickerShowsVPN() throws {
        let automatic = ["en": "Automatic (recommended)", "es": "Automático (recomendado)", "fr": "Automatique (recommandé)"]
        for language in Self.languages {
            let shown = try renderStatusPage(language)
            assertNoPlaceholder(shown, "\(language) Status page")
            XCTAssertEqual(shown.menus, [[automatic[language]!, "VPN · utun7"]], "\(language): the Act on picker")
            XCTAssertEqual(shown.controlNames, [["en": "Act on", "es": "Actuar sobre", "fr": "Agir sur"][language]!],
                           "\(language): control, the Act on picker's name reads from the tree")
        }
    }

    func testTheRouteEditorPickerShowsVPN() throws {
        let items = ["en": ["Primary VPN (automatic)", "VPN · utun7", "VPN · utun9 — not connected"],
                     "es": ["VPN principal (automática)", "VPN · utun7", "VPN · utun9 — no conectada"],
                     "fr": ["VPN principal (automatique)", "VPN · utun7", "VPN · utun9 — non connecté"]]
        for language in Self.languages {
            let shown = try renderRouteEditor(language)
            assertNoPlaceholder(shown, "\(language) route editor")
            XCTAssertEqual(shown.menus, [items[language]!], "\(language): the VPN picker")
            // An unnamed control reads as just "pop-up button" or "radio group" in VoiceOver.
            XCTAssertEqual(shown.controlNames, [Self.word("Type", language), Self.word("VPN", language)],
                           "\(language): the Type control's and the VPN picker's names")
        }
    }

    func testTheRouteEditorNamesItsTailscalePeerMenu() throws {
        let route = Route(name: "home-exit", egress: .tailscaleExit, proxyHost: "100.64.0.1", proxyPort: 8888)
        let peer = RouteManager.TailscalePeer(name: "home-exit", ip: "100.64.0.1", online: true, exitNodeCapable: true)
        for language in Self.languages {
            let shown = try render(RouteEditorSheet(editingRoute: route, selectableLinks: [], peers: [peer],
                                                    onSave: { _ in }, onCancel: {}),
                                   language: language, name: "route-editor-peer-\(language).png")
            XCTAssertEqual(shown.controlNames, [Self.word("Type", language), Self.word("Tailscale Peer", language)],
                           "\(language): the route editor's controls")
            // The peer's name stays as typed. The suffix was a plain String, so it showed in English.
            XCTAssertEqual(shown.menus, [[["en": "home-exit · exit node", "es": "home-exit · nodo de salida",
                                           "fr": "home-exit · nœud de sortie"][language]!]], "\(language): the peer menu")
        }
    }

    func testTheRuleEditorNamesItsControls() throws {
        let services = Array(RouteManager.Config().services.prefix(2))
        let rule = Rule(matchType: .service, pattern: services[0].id, routeId: UUID(), order: 0)
        for language in Self.languages {
            let shown = try render(RuleEditorSheet(editingRule: rule, services: services, onSave: { _ in }, onCancel: {})
                                       .environmentObject(rm),
                                   language: language, name: "rule-editor-\(language).png")
            XCTAssertEqual(Array(shown.controlNames.prefix(2)), [Self.word("Match", language), Self.word("Service", language)],
                           "\(language): the rule editor's controls")
            XCTAssertFalse(shown.controlNames.contains(""), "\(language): an unnamed control in \(shown.controlNames)")
        }
    }

    func testTheGeneralPageNamesTheRefreshIntervalMenu() throws {
        for language in Self.languages {
            let shown = try render(GeneralTab().environmentObject(rm).environmentObject(NotificationManager.shared)
                                       .environmentObject(LaunchAtLoginManager.shared).frame(width: 532).padding(24)
                                       .background(Theme.bgPrimary),
                                   language: language, name: "general-\(language).png")
            XCTAssertTrue(shown.controlNames.contains(Self.word("Refresh Interval", language)),
                          "\(language): the DNS refresh menu's name, in \(shown.controlNames)")
            XCTAssertFalse(shown.controlNames.contains(""), "\(language): an unnamed control in \(shown.controlNames)")
        }
    }

    /// A key's text in one language, from the source tree.
    private static func word(_ key: String, _ language: String) -> String {
        lproj(language)!.localizedString(forKey: key, value: nil, table: nil)
    }

    private func assertNoPlaceholder(_ shown: Shown, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let all = shown.text + shown.menus.flatMap { $0 }
        XCTAssertFalse(all.isEmpty, "\(what): control, the render shows text", file: file, line: line)
        let english = all.filter { $0.contains(Self.unknown) }
        XCTAssertEqual(english, [], "\(what) shows the English placeholder", file: file, line: line)
    }

    // MARK: - Rendering

    /// What a render shows: every label, value and title in its accessibility tree, the name
    /// VoiceOver reads for each menu and segmented control, and each menu's items, which exist
    /// while the menu is closed.
    private struct Shown {
        var text: [String] = []
        var controlNames: [String] = []
        var menus: [[String]] = []
    }

    private func renderStatusPage(_ language: String) throws -> Shown {
        let tunnel = RouteManager.VPNLink(interface: "utun7", addresses: ["10.0.0.2"], label: Self.unknown, isTailscale: false)
        let snapshot = RouteManager.CoexistenceSnapshot(links: [tunnel], selectedInterface: "utun7",
                                                        defaultRouteInterface: "utun7", taggedDestinations: [])
        return try render(StatusTab(snapshot: snapshot).environmentObject(rm).frame(width: 532).padding(24)
                              .background(Theme.bgPrimary),
                          language: language, name: "status-\(language).png")
    }

    private func renderRouteEditor(_ language: String) throws -> Shown {
        let route = Route(name: "ACME VPN", egress: .vpnDefault,
                          vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun7", productHint: Self.unknown))
        let links = [(link: RouteManager.RememberedLink(interface: "utun7", label: Self.unknown), isLive: true),
                     (link: RouteManager.RememberedLink(interface: "utun9", label: Self.unknown), isLive: false)]
        return try render(RouteEditorSheet(editingRoute: route, selectableLinks: links, onSave: { _ in }, onCancel: {}),
                          language: language, name: "route-editor-\(language).png")
    }

    private func render<V: View>(_ view: V, language: String, name: String) throws -> Shown {
        Self.speak(language)
        defer { Self.speak(nil) }
        window?.orderOut(nil)
        let hosting = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        self.window = window
        settle(hosting)
        window.setContentSize(hosting.fittingSize)
        settle(hosting)
        if let dir = ProcessInfo.processInfo.environment["VPNB_RENDERS"], !dir.isEmpty {
            try write(hosting, to: URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name))
        }
        var shown = Shown()
        collectText(window, into: &shown, depth: 0)
        collectMenus(hosting, into: &shown.menus)
        return shown
    }

    private func settle(_ view: NSView) {
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// SwiftUI's own nodes answer the accessibility getters without declaring the protocol
    /// to Swift, so each getter is sent by name.
    private func collectText(_ element: Any, into shown: inout Shown, depth: Int) {
        guard depth < 80, let element = element as? NSObject else { return }
        func get(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
        }
        func text(_ name: String) -> String? { (get(name) as? String) ?? (get(name) as? NSAttributedString)?.string }
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            if let text = text(name), !text.isEmpty { shown.text.append(text) }
        }
        if [NSAccessibility.Role.popUpButton.rawValue, NSAccessibility.Role.radioGroup.rawValue]
            .contains(get("accessibilityRole") as? String) {
            shown.controlNames.append(text("accessibilityLabel") ?? "")
        }
        for child in get("accessibilityChildren") as? [Any] ?? [] {
            collectText(child, into: &shown, depth: depth + 1)
        }
    }

    private func collectMenus(_ view: NSView, into out: inout [[String]]) {
        if let popUp = view as? NSPopUpButton { out.append(popUp.itemTitles) }
        view.subviews.forEach { collectMenus($0, into: &out) }
    }

    private func write(_ view: NSView, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private static let enhancedUserInterface = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    private static var isAccessibilityClient: Bool {
        (NSApplication.shared.accessibilityAttributeValue(enhancedUserInterface) as? Bool) ?? false
    }

    private static func setAccessibilityClient(_ on: Bool) {
        NSApplication.shared.accessibilitySetValue(on, forAttribute: enhancedUserInterface)
    }

    // MARK: - The language

    /// The views look their words up in `Bundle.main`, which under XCTest is the test runner
    /// and has no translations. While a language is set, `Bundle.main` is that language's
    /// folder in the source tree; nil swaps the original back. Swapping
    /// `localizedString(forKey:value:table:)` instead does not reach SwiftUI's `Text` or
    /// `String(localized:)`, which look up through other entry points.
    nonisolated(unsafe) fileprivate static var spoken: Bundle?
    private static var swapped = false

    private static func speak(_ language: String?) {
        spoken = language.flatMap { lproj($0) }
        guard (spoken != nil) != swapped else { return }
        swapped.toggle()
        let original = class_getClassMethod(Bundle.self, #selector(getter: Bundle.main))!
        let replacement = class_getClassMethod(Bundle.self, #selector(getter: Bundle.unknownVPNRenderMain))!
        method_exchangeImplementations(original, replacement)
    }

    private static func lproj(_ language: String) -> Bundle? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj"))
    }
}

extension Bundle {
    /// Swapped with `Bundle.main` while a language is set; reading itself reads the original.
    @objc fileprivate class var unknownVPNRenderMain: Bundle {
        UnknownVPNRenderTests.spoken ?? unknownVPNRenderMain
    }
}
