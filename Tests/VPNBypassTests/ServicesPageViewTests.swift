// ServicesPageViewTests.swift
// The Services page in a real Settings window, read the way VoiceOver reads it: no heading of
// its own and no uppercase ON / CUSTOM SERVICES sections, one "Your services" list under the
// purpose line, Browse catalogue… under the list, the empty state's way to the catalogue, and
// a row's actions reachable without the pointer.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class ServicesPageViewTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var window: NSWindow?
    private var savedConfig: RouteManager.Config!
    private var savedLastPage: String?

    override func setUp() async throws {
        savedConfig = rm.config
        savedLastPage = UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        rm.config = savedConfig
        UserDefaults.standard.set(savedLastPage, forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    func testThePageIsOneListUnderItsPurposeWithTheCatalogueUnderIt() {
        var config = RouteManager.Config()
        config.routingMode = .bypass
        for i in config.services.indices where ["telegram", "youtube"].contains(config.services[i].id) {
            config.services[i].enabled = true
        }
        config.services.append(ServiceEntry(id: "custom_probe", name: "Probe Tools", enabled: false,
                                            domains: ["probe.example"], ipRanges: [], isCustom: true))
        rm.config = config
        let texts = texts(onServices: open())
        XCTAssertTrue(texts.contains("A service skips the VPN while its switch is on."), "no purpose line: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Your services"), "the list has no title")
        for header in ["ON", "CUSTOM SERVICES"] {
            XCTAssertFalse(texts.contains(header), "the uppercase section \(header) is still there")
        }
        XCTAssertTrue(texts.contains { $0.contains("Custom · 1 domain") }, "a custom service does not say so on its detail line")
        XCTAssertTrue(texts.contains("Browse catalogue…"))
        XCTAssertTrue(texts.contains { $0.hasSuffix("services, pick several at once") }, "no catalogue line under the list")
        XCTAssertTrue(texts.contains("Create Custom Service"))
        XCTAssertTrue(texts.contains("Edit Probe Tools"), "VoiceOver cannot reach a custom service's edit")
        XCTAssertTrue(texts.contains("Delete Probe Tools"), "VoiceOver cannot reach a custom service's delete")
    }

    func testANameAddedToABuiltInServiceIsOnItsLineAndRemovableWithoutThePointer() {
        var config = RouteManager.Config()
        config.routingMode = .bypass
        if let i = config.services.firstIndex(where: { $0.id == "telegram" }) {
            config.services[i].enabled = true
            config.services[i].domains.append("added-probe.example")
        }
        config.builtInServiceExtras["telegram"] = ["added-probe.example"]
        rm.config = config
        let texts = texts(onServices: open())
        XCTAssertTrue(texts.contains { $0.contains("Added: added-probe.example") }, "the added name is not listed: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Remove added-probe.example from Telegram"), "VoiceOver cannot reach the remove")
    }

    func testAFreshInstallOffersTheCatalogue() {
        var config = RouteManager.Config()
        config.routingMode = .bypass
        rm.config = config
        let texts = texts(onServices: open())
        XCTAssertTrue(texts.contains("No services yet"), "no empty state: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Browse catalogue…"))
    }

    // MARK: - Helpers

    private func open() -> NSWindow {
        SettingsPageRequest.shared.page = .services
        let window = SettingsWindowController.makeWindow()
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        settle(window)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Every label, title and value in the window, found with an accessibility client switched
    /// on and each getter sent by name, as in SettingsShellTests.
    private func texts(onServices window: NSWindow) -> Set<String> {
        XCTAssertEqual(window.title, "Services")
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
