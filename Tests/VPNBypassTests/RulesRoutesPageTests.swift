// RulesRoutesPageTests.swift
// The Rules and Routes pages on the shared components (rework step 8, section 3.3 of
// docs/design/APP-REWORK-PROPOSALS.md). The model tests pin what each row says and offers;
// the view tests open a real Settings window and read it the way VoiceOver does: no heading
// of the page's own, no badges or boxed buttons, one chip per rule with its row's name, and
// every hover action reachable without the pointer.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

final class RulesRoutesPageModelTests: XCTestCase {

    // MARK: - Rules

    /// A suffix rule stores its suffix; the row writes it as the wildcard the user typed.
    func testASuffixRuleShowsItsWildcard() {
        let route = UUID()
        XCTAssertEqual(RuleRow.patternDisplay(Rule(matchType: .suffix, pattern: "example.com", routeId: route, order: 0), services: []),
                       "*.example.com")
        XCTAssertEqual(RuleRow.patternDisplay(Rule(matchType: .suffix, pattern: "*.example.com", routeId: route, order: 0), services: []),
                       "*.example.com", "a wildcard pattern is not prefixed twice")
        XCTAssertEqual(RuleRow.patternDisplay(Rule(matchType: .domain, pattern: "example.com", routeId: route, order: 0), services: []),
                       "example.com", "positive control: a domain rule is shown as stored")
        let telegram = ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: [], ipRanges: [])
        XCTAssertEqual(RuleRow.patternDisplay(Rule(matchType: .service, pattern: "telegram", routeId: route, order: 0), services: [telegram]),
                       "Telegram")
    }

    /// The glyph says what a rule matches, now that the uppercase badge is gone.
    func testTheGlyphSaysWhatARuleMatches() {
        XCTAssertEqual(RuleRow.glyph(for: .domain), "globe")
        XCTAssertEqual(RuleRow.glyph(for: .suffix), "globe")
        XCTAssertEqual(RuleRow.glyph(for: .service), "square.grid.2x2")
        XCTAssertEqual(RuleRow.glyph(for: .ip), "network")
        XCTAssertEqual(RuleRow.glyph(for: .cidr), "network")
        XCTAssertEqual(RuleRow.glyph(for: .process), "app")
    }

    /// The two explanations of ordering are one line; the drag hint joins it at two rules.
    func testThePurposeLineMentionsDraggingOnlyWithTwoRules() {
        XCTAssertEqual(RulesTab.purpose(ruleCount: 0), "The first rule that matches wins.")
        XCTAssertEqual(RulesTab.purpose(ruleCount: 1), "The first rule that matches wins.")
        XCTAssertEqual(RulesTab.purpose(ruleCount: 2), "The first rule that matches wins. Drag to reorder.")
    }

    /// The chip is the shared one: a grey glyph per egress and the route's name.
    func testTheRuleChipIsTheSharedRouteChip() {
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5)
        let chip = RulesRouteChipMenu.chip(for: proxy, vpnName: nil)
        XCTAssertEqual(chip.name, "office-proxy")
        XCTAssertEqual(chip.systemImage, RouteChip.systemImage(for: .proxySOCKS5))
        let vpn = RulesRouteChipMenu.chip(for: Route(name: "", egress: .vpnDefault), vpnName: "WireGuard")
        XCTAssertEqual(vpn.name, "WireGuard", "the detected VPN shows its name")
        XCTAssertEqual(vpn.systemImage, "key")
        XCTAssertEqual(RulesRouteChipMenu.chip(for: nil, vpnName: nil).name, "Choose Route")
    }

    // MARK: - Routes

    /// One mono line: where the app listens, then where the route goes.
    func testTheDetailLineJoinsListenerAndUpstream() {
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        XCTAssertEqual(RouteRow.detail(proxy, listenerPort: 18168), "127.0.0.1:18168 → 198.51.100.7:1080")
        XCTAssertEqual(RouteRow.detail(proxy, listenerPort: nil), "Listener starting… → 198.51.100.7:1080")
        var off = proxy
        off.enabled = false
        XCTAssertEqual(RouteRow.detail(off, listenerPort: nil), "Listener off → 198.51.100.7:1080")
        let peer = Route(name: "home", egress: .tailscaleExit, proxyHost: "100.64.0.2", proxyPort: 8888, tailscaleExitNode: "home-mini")
        XCTAssertEqual(RouteRow.detail(peer, listenerPort: 18170), "127.0.0.1:18170 → home-mini · :8888")
        let pinned = Route(name: "Work VPN", egress: .vpnDefault,
                           vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun4"))
        XCTAssertEqual(RouteRow.detail(pinned, listenerPort: nil), "→ utun4", "a pinned VPN route has no listener")
    }

    /// Copy Proxy URL and edit under the pointer, ⋯ for the rest; no copies without a port.
    func testARouteOffersCopyEditAndAMoreMenu() {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5)
        var copied: [RouteRow.CopyKind] = []
        var duplicated = 0
        let actions = RouteRow.actions(for: route, canCopy: true, copy: { copied.append($0) }, edit: {},
                                       duplicate: { duplicated += 1 }, delete: {})
        XCTAssertEqual(actions.map(\.name), ["Copy Proxy URL", "Edit office-proxy", "More actions for office-proxy"])
        XCTAssertEqual(actions.last?.menu?.map(\.name), ["Copy Shell Exports", "Duplicate office-proxy", "Delete office-proxy"])
        XCTAssertEqual(RowAction.flattened(actions).map(\.name),
                       ["Copy Proxy URL", "Edit office-proxy", "Copy Shell Exports", "Duplicate office-proxy", "Delete office-proxy"])
        actions[0].perform()
        actions.last?.menu?[0].perform()
        actions.last?.menu?[1].perform()
        XCTAssertEqual(copied, [.proxyURL, .exports])
        XCTAssertEqual(duplicated, 1)

        let noPort = RouteRow.actions(for: route, canCopy: false, copy: { _ in }, edit: {}, duplicate: {}, delete: {})
        XCTAssertEqual(RowAction.flattened(noPort).map(\.name), ["Edit office-proxy", "Duplicate office-proxy", "Delete office-proxy"])
    }

    /// Duplicate keeps the route's settings but takes a new id, a new name and its own port.
    func testADuplicateKeepsSettingsButNotIdentity() {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, enabled: false, proxyHost: "198.51.100.7",
                          proxyPort: 1080, proxyUser: "me", proxyPass: "pw", localListenPort: 18168)
        let copy = RouteManager.duplicate(of: route)
        XCTAssertNotEqual(copy.id, route.id)
        XCTAssertEqual(copy.name, "office-proxy copy")
        XCTAssertNil(copy.localListenPort, "the copy gets its own listener port")
        XCTAssertEqual(copy.egress, route.egress)
        XCTAssertEqual(copy.enabled, route.enabled)
        XCTAssertEqual(copy.proxyHost, route.proxyHost)
        XCTAssertEqual(copy.proxyPort, route.proxyPort)
        XCTAssertEqual(copy.proxyUser, route.proxyUser)
        XCTAssertEqual(copy.proxyPass, route.proxyPass)
    }
}

@MainActor
final class RulesRoutesPageViewTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var window: NSWindow?
    private var savedConfig: RouteManager.Config!
    private var savedVPNType: VPNType?
    private var savedLastPage: String?

    override func setUp() async throws {
        savedConfig = rm.config
        savedVPNType = rm.vpnType
        savedLastPage = UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        rm.config = savedConfig
        rm.vpnType = savedVPNType
        UserDefaults.standard.set(savedLastPage, forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    /// Custom mode with a proxy rule, a suffix rule and a subnet rule. The proxy route has no
    /// listener here (nothing is started), so it offers no copy.
    private func seedCustom() {
        var config = rm.config
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        config.routes = [direct, vpn, proxy]
        config.rules = [
            Rule(matchType: .domain, pattern: "en.wikipedia.org", routeId: proxy.id, order: 0),
            Rule(matchType: .suffix, pattern: "example.com", routeId: direct.id, order: 1),
            Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: vpn.id, order: 2),
        ]
        config.defaultRouteId = direct.id
        config.schemaVersion = 2
        config.routingMode = .custom
        rm.config = config
        rm.vpnType = .wireGuard
    }

    func testTheRulesPageIsOneListWithOneChipPerRule() {
        seedCustom()
        let texts = texts(on: .rules)
        XCTAssertFalse(texts.contains("Routing Rules"), "the page still repeats its name under the title bar")
        for badge in ["DOMAIN", "SUFFIX", "CIDR"] {
            // The badge was read as part of its row: "en.wikipedia.org, DOMAIN".
            XCTAssertFalse(texts.contains { $0.hasSuffix(badge) }, "the uppercase badge \(badge) is still there")
        }
        XCTAssertFalse(texts.contains { $0.hasPrefix("Drag to reorder") }, "the second ordering hint is still there")
        XCTAssertTrue(texts.contains("The first rule that matches wins. Drag to reorder."), "no purpose line: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Add Rule"), "no + named for VoiceOver")
        XCTAssertTrue(texts.contains("*.example.com"), "a suffix rule does not show its wildcard")
        // Each chip is named after its row, so VoiceOver tells one rule's route from another's.
        XCTAssertTrue(texts.contains("Route for en.wikipedia.org: office-proxy"), "no chip for the proxy rule: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Route for 203.0.113.0/24: WireGuard"), "the VPN chip does not show the VPN's name")
        XCTAssertTrue(texts.contains("Route for Everything else: Direct"), "Everything else is not the last row of the list")
        XCTAssertTrue(texts.contains { $0.contains("Only apps set to use office-proxy. Other apps take the Mac's normal route") },
                      "the proxy rule lost its detail line")
        XCTAssertTrue(texts.contains("Edit en.wikipedia.org"), "VoiceOver cannot reach a rule's edit")
        XCTAssertTrue(texts.contains("Delete *.example.com"), "VoiceOver cannot reach a rule's delete")
    }

    func testTheRoutesPageListsAlwaysThereThenYourRoutes() {
        seedCustom()
        let texts = texts(on: .routes)
        XCTAssertFalse(texts.contains("System Routes"), "the old card title is still there")
        XCTAssertFalse(texts.contains { $0.hasPrefix("Point an app at a route") }, "the sign-in paragraph is still page chrome")
        XCTAssertFalse(texts.contains("1/1 active"))
        XCTAssertTrue(texts.contains("The ways out a rule can pick."), "no purpose line: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Always there"))
        XCTAssertTrue(texts.contains("Your routes"))
        XCTAssertTrue(texts.contains("Add Route"), "no + named for VoiceOver")
        // Direct and the detected VPN carry the chip they get on the Rules page.
        XCTAssertTrue(texts.contains("Route: Direct"), "Direct has no route chip: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Route: WireGuard"), "the detected VPN has no route chip")
        XCTAssertTrue(texts.contains("Route: SOCKS5"), "the user's route has no type chip")
        XCTAssertTrue(texts.contains { $0.contains("Listener starting… → 198.51.100.7:1080") }, "no mono detail line")
        XCTAssertTrue(texts.contains("Edit office-proxy"), "VoiceOver cannot reach the edit")
        XCTAssertTrue(texts.contains("Duplicate office-proxy"), "VoiceOver cannot reach the ⋯ menu's Duplicate")
        XCTAssertTrue(texts.contains("Delete office-proxy"), "VoiceOver cannot reach the ⋯ menu's Delete")
    }

    // MARK: - Helpers

    private func settle(_ window: NSWindow) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Every label, title and value in the window, found with an accessibility client switched
    /// on and each getter sent by name, as in LookupsPageViewTests.
    private func texts(on page: SettingsView.SettingsTab) -> Set<String> {
        SettingsPageRequest.shared.page = page
        let window = SettingsWindowController.makeWindow()
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
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = get(name) as? String, !text.isEmpty { found.insert(text) }
            }
            // VoiceOver's Actions menu (VO-Command-Space) names each custom action.
            for action in get("accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? [] {
                found.insert(action.name)
            }
            (get("accessibilityChildren") as? [Any] ?? []).forEach { walk($0, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }
}
