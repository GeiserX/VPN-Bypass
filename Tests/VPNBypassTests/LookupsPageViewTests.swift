// LookupsPageViewTests.swift
// The Lookups page in a real Settings window, read the way VoiceOver reads it: the page's own
// heading and switch are gone (the title bar names the page), the empty state starts watching,
// Stop Watching stops it, and the old column headers are gone.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class LookupsPageViewTests: XCTestCase {

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
        DNSLookupsMonitor.shared.tally = DNSLookupTally()
        DNSLookupsMonitor.shared.since = nil
        UserDefaults.standard.set(savedLastPage, forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    func testOffThePageOffersStartWatchingAndHasNoHeadingOrSwitchOfItsOwn() {
        var config = rm.config
        config.routingMode = .bypass
        config.dnsLookupsEnabled = false
        rm.config = config
        let texts = texts(onLookups: open())
        XCTAssertTrue(texts.contains("Start Watching"), "the empty state has no Start Watching: \(texts.sorted())")
        XCTAssertFalse(texts.contains("Watch DNS Lookups"), "the page still has its own switch")
        XCTAssertFalse(texts.contains("DNS Lookups"), "the page still repeats its name under the title bar")
        XCTAssertFalse(texts.contains("Stop Watching"))
    }

    func testOnThePageOffersStopWatchingAndListsTheNamesWithoutColumnHeaders() {
        var config = rm.config
        config.routingMode = .bypass
        config.dnsLookupsEnabled = true
        rm.config = config
        var tally = DNSLookupTally()
        tally.record(["github.com", "slack.com"], at: Date())
        DNSLookupsMonitor.shared.tally = tally
        DNSLookupsMonitor.shared.since = Date()
        let texts = texts(onLookups: open())
        XCTAssertTrue(texts.contains("Stop Watching"), "no Stop Watching while watching: \(texts.sorted())")
        XCTAssertFalse(texts.contains("Start Watching"))
        XCTAssertFalse(texts.contains("Watch DNS Lookups"), "the page still has its own switch")
        XCTAssertTrue(texts.contains { $0.contains("github.com") }, "the names are not listed")
        for header in ["LOOKUPS", "NAME", "BYPASS"] {
            XCTAssertFalse(texts.contains(header), "the uppercase column header \(header) is still there")
        }
    }

    // MARK: - Helpers

    private func open() -> NSWindow {
        SettingsPageRequest.shared.page = .lookups
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
    private func texts(onLookups window: NSWindow) -> Set<String> {
        XCTAssertEqual(window.title, "Lookups")
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
            (get("accessibilityChildren") as? [Any] ?? []).forEach { walk($0, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }
}
