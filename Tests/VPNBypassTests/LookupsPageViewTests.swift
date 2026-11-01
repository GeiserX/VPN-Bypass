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
        DNSLookupsMonitor.shared.learning = nil
        DNSLookupsMonitor.shared.searchDomains = []
        DNSLookupsMonitor.shared.readsSearchDomains = true
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

    /// The actions show only under the pointer, so VoiceOver must still reach each one on a
    /// row nobody hovers: the add, the panel, and a listed name's remove.
    func testEveryRowActionIsReachableWithoutThePointer() {
        var config = rm.config
        config.routingMode = .bypass
        config.dnsLookupsEnabled = true
        config.domains = [DomainEntry(domain: "listed-probe.example")]
        rm.config = config
        var tally = DNSLookupTally()
        tally.record(["unlisted-probe.example", "listed-probe.example"], at: Date())
        DNSLookupsMonitor.shared.tally = tally
        DNSLookupsMonitor.shared.since = Date()
        let texts = texts(onLookups: open())
        XCTAssertTrue(texts.contains("Add to Bypass"), "VoiceOver cannot reach the add: \(texts.sorted())")
        XCTAssertTrue(texts.contains("More ways to add unlisted-probe.example"), "VoiceOver cannot reach the add panel")
        XCTAssertTrue(texts.contains("Remove"), "VoiceOver cannot reach a listed name's remove: \(texts.sorted())")
    }

    /// Learn a site, closed with three names under one site: VoiceOver reaches the Learn
    /// button, the wildcard offer, the one Add with its count, and Done.
    func testLearnedNamesOfferTheWildcardAndOneAddToVoiceOver() {
        var config = rm.config
        config.routingMode = .bypass
        config.dnsLookupsEnabled = false
        config.domains = []
        rm.config = config
        var learning = SiteLearning(started: Date())
        learning.record(["www.learn-probe.test", "api.learn-probe.test", "img.learn-probe.test"], at: Date())
        learning.close()
        DNSLookupsMonitor.shared.learning = learning
        let texts = texts(onLookups: open())
        XCTAssertTrue(texts.contains("Learn a Site"), "VoiceOver cannot reach Learn a Site: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Add as *.learn-probe.test"), "no wildcard offer: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Add to Bypass, 3 entries"), "no one Add: \(texts.sorted())")
        XCTAssertTrue(texts.contains("Done Learning"))
    }

    // MARK: - Helpers

    /// One failed name the resolver retried with each search domain appended filled the list
    /// with retries. They are folded under a "Show N search-domain retries" toggle.
    func testSearchDomainRetriesAreFoldedUnderAToggle() throws {
        var config = rm.config
        config.routingMode = .bypass
        config.dnsLookupsEnabled = true
        rm.config = config
        DNSLookupsMonitor.shared.readsSearchDomains = false
        DNSLookupsMonitor.shared.searchDomains = ["corp.example", "lab.example"]
        var tally = DNSLookupTally()
        tally.record(["host.example.com", "host.example.com.corp.example", "host.example.com.lab.example", "github.com"], at: Date())
        DNSLookupsMonitor.shared.tally = tally
        DNSLookupsMonitor.shared.since = Date()
        let texts = texts(onLookups: open())
        XCTAssertTrue(texts.contains { $0.contains("host.example.com") }, "the name itself is gone: \(texts.sorted())")
        XCTAssertFalse(texts.contains { $0.contains("host.example.com.corp.example") }, "a retry is still listed")
        XCTAssertTrue(texts.contains("Show 2 search-domain retries"), "no toggle for the retries: \(texts.sorted())")

        // Pressed as VoiceOver does, the toggle lists the retries and offers to hide them.
        let window = try XCTUnwrap(self.window)
        let toggle = try XCTUnwrap(AccessibilityTree.elements(under: window, settle: { settle(window) })
            .first { AccessibilityTree.label($0) == "Show 2 search-domain retries" })
        AccessibilityTree.press(toggle)
        settle(window)
        let shown = self.texts(onLookups: window)
        XCTAssertTrue(shown.contains { $0.contains("host.example.com.corp.example") }, "the retries do not show: \(shown.sorted())")
        XCTAssertTrue(shown.contains("Hide search-domain retries"), "no way to hide them again: \(shown.sorted())")
    }

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
