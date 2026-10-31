// SettingsShellTests.swift
// The Settings window's shell (section 3.2 B and flow fix 1 of the 6.0 rework): a sidebar that
// lists every page in every mode, pages of another mode that open read-only, a resizable
// window that reopens on the last page, and one search field in the title bar of list pages.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class SettingsShellTests: XCTestCase {

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

    // MARK: - The sidebar model

    func testTheSidebarListsEveryPageInThreeGroupsAfterStatus() {
        XCTAssertEqual(SettingsSidebar.groups.map(\.pages), [
            [.status],
            [.domains, .services, .rules, .routes],
            [.lookups, .logs],
            [.general, .about],
        ])
        XCTAssertEqual(SettingsSidebar.groups.map { $0.title() }, [nil, "Routing", "Insight", "App"])
        XCTAssertEqual(Set(SettingsSidebar.pages), Set(SettingsView.SettingsTab.allCases), "a page is missing from the sidebar")
    }

    /// The sidebar never changes shape: a mode only decides which pages are read-only.
    func testEachModeGreysOnlyThePagesOfAnotherMode() {
        func readOnly(_ mode: RoutingMode) -> [SettingsView.SettingsTab] {
            SettingsSidebar.pages.filter { SettingsSidebar.isReadOnly($0, in: mode) }
        }
        XCTAssertEqual(readOnly(.bypass), [.rules, .routes])
        XCTAssertEqual(readOnly(.vpnOnly), [.services, .rules, .routes])
        XCTAssertEqual(readOnly(.custom), [.domains, .services])
    }

    func testAReadOnlyPageSaysWhichModeItAppliesInAndOffersThatMode() {
        XCTAssertEqual(SettingsSidebar.readOnlyLine(.rules, in: .bypass), "Rules apply in Custom mode. You are in Bypass.")
        XCTAssertEqual(SettingsSidebar.readOnlyLine(.routes, in: .vpnOnly), "Routes apply in Custom mode. You are in VPN Only.")
        XCTAssertEqual(SettingsSidebar.readOnlyLine(.services, in: .custom), "Services apply in Bypass mode. You are in Custom.")
        XCTAssertEqual(SettingsSidebar.readOnlyLine(.domains, in: .custom),
                       "Domains apply in Bypass and VPN Only modes. You are in Custom.")
        XCTAssertNil(SettingsSidebar.readOnlyLine(.rules, in: .custom))
        XCTAssertNil(SettingsSidebar.readOnlyLine(.lookups, in: .vpnOnly))
        XCTAssertEqual(SettingsSidebar.switchTarget(for: .rules), .custom)
        XCTAssertEqual(SettingsSidebar.switchTarget(for: .services), .bypass)
        XCTAssertEqual(SettingsSidebar.switchTarget(for: .domains), .bypass)
        XCTAssertNil(SettingsSidebar.switchTarget(for: .general))
    }

    func testTheShellsWordsAreTranslated() throws {
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            // Some names read the same ("Services" in French), so the entry is checked, not the text.
            for page in SettingsView.SettingsTab.allCases {
                let key = page.name(in: .main)
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "\u{0}", table: nil), "\u{0}", "\(language) has no \"\(key)\"")
            }
            for group in SettingsSidebar.groups {
                if let title = group.title(in: bundle) {
                    XCTAssertNotEqual(title, group.title(), "\(language): \(group.kind)")
                }
            }
            for (page, mode) in [(SettingsView.SettingsTab.rules, RoutingMode.bypass), (.routes, .bypass), (.services, .custom), (.domains, .custom)] {
                let line = try XCTUnwrap(SettingsSidebar.readOnlyLine(page, in: mode, bundle: bundle))
                XCTAssertNotEqual(line, SettingsSidebar.readOnlyLine(page, in: mode), "\(language): \(page)")
                XCTAssertTrue(line.contains(DropdownModePicker.label(mode, in: bundle)), "\(language): \(line)")
            }
            for key in ["Switch…", "Switch to %@…", "Read-only in this mode"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key, "\(language) leaves \"\(key)\" in English")
            }
        }
    }

    func testTheWindowReopensOnTheLastPage() {
        XCTAssertEqual(SettingsSidebar.restoredPage(nil), .status)
        XCTAssertEqual(SettingsSidebar.restoredPage("rules"), .rules)
        XCTAssertEqual(SettingsSidebar.restoredPage("about"), .about)
        XCTAssertEqual(SettingsSidebar.restoredPage("no such page"), .status)
    }

    func testTheSearchMatchesNamesIgnoringCaseAndAccents() {
        XCTAssertTrue(SettingsSidebar.matches("en.wikipedia.org", search: ""))
        XCTAssertTrue(SettingsSidebar.matches("en.wikipedia.org", search: "  "))
        XCTAssertTrue(SettingsSidebar.matches("en.wikipedia.org", search: "WIKI"))
        XCTAssertTrue(SettingsSidebar.matches("Télégram", search: "telegram"))
        XCTAssertFalse(SettingsSidebar.matches("Telegram", search: "zoom"))
        XCTAssertEqual(SettingsView.SettingsTab.allCases.filter(SettingsSidebar.isSearchable),
                       [.domains, .services, .rules, .routes, .lookups, .logs])
    }

    /// The System Routes rows follow the Routes search like the listener routes do.
    func testTheRoutesSearchFiltersTheSystemRoutes() {
        XCTAssertTrue(RoutesTab.shownSystemRoutes(direct: "Direct", vpn: "GlobalProtect", search: "") == (true, true))
        XCTAssertTrue(RoutesTab.shownSystemRoutes(direct: "Direct", vpn: "GlobalProtect", search: "dir") == (true, false))
        XCTAssertTrue(RoutesTab.shownSystemRoutes(direct: "Direct", vpn: "GlobalProtect", search: "GLOBAL") == (false, true))
        XCTAssertTrue(RoutesTab.shownSystemRoutes(direct: "Direct", vpn: "GlobalProtect", search: "office-proxy") == (false, false))
    }

    // MARK: - The window

    func testTheWindowIsResizableDownTo720By480() {
        let window = SettingsWindowController.makeWindow()
        self.window = window
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 720, height: 480))
        XCTAssertEqual(window.contentMaxSize.width, CGFloat(Float.greatestFiniteMagnitude), accuracy: 1)
    }

    func testThePageNameIsTheWindowTitleAndTheLastPageComesBack() {
        UserDefaults.standard.set("routes", forKey: SettingsSidebar.lastPageKey)
        let window = open()
        XCTAssertEqual(window.title, "Routes")

        SettingsPageRequest.shared.page = .logs
        settle(window)
        XCTAssertEqual(window.title, "Logs")
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey), "logs")
    }

    /// Flow fix 1: switching mode left the user on another page, because the page they were on
    /// left the toolbar. Now the page stays, read-only.
    func testChangingModeKeepsThePageOpen() {
        var config = rm.config
        config.routingMode = .bypass
        rm.config = config
        SettingsPageRequest.shared.page = .services
        let window = open()
        XCTAssertEqual(window.title, "Services")

        config.routingMode = .custom
        rm.config = config
        settle(window)
        XCTAssertEqual(window.title, "Services", "the mode change moved the window off the page")
        XCTAssertTrue(hasElement(labelled: "Switch to Bypass…", in: window), "the read-only page has no Switch… button")

        config.routingMode = .bypass
        rm.config = config
        settle(window)
        XCTAssertFalse(hasElement(labelled: "Switch to Bypass…", in: window), "the page is still read-only in its own mode")
    }

    /// ⌘F puts the cursor in the title bar search on every list page, and a click on the field
    /// reaches it through the title bar.
    func testCommandFSearchesEveryListPage() throws {
        var config = rm.config
        config.routingMode = .custom
        rm.config = config
        let window = open()
        for page in SettingsView.SettingsTab.allCases {
            SettingsPageRequest.shared.page = page
            settle(window)
            window.makeFirstResponder(nil)
            press("f", in: window)
            let editor = window.firstResponder as? NSTextView
            let field = editor?.delegate as? NSTextField
            if SettingsSidebar.isSearchable(page) {
                XCTAssertEqual(field?.placeholderString, "Search", "\(page): ⌘F left the cursor in \(String(describing: window.firstResponder))")
            } else {
                XCTAssertNil(editor, "\(page) is not a list page but ⌘F found a field")
            }
        }

        SettingsPageRequest.shared.page = .rules
        settle(window)
        let search = try XCTUnwrap(find(in: window.contentView!) { ($0 as? NSTextField)?.placeholderString == "Search" })
        let center = search.convert(NSPoint(x: search.bounds.midX, y: search.bounds.midY), to: nil)
        XCTAssertGreaterThan(center.y, window.contentLayoutRect.maxY - 1, "the search field is not in the title bar row")
        window.makeFirstResponder(nil)
        click(center, in: window)
        let editor = window.firstResponder as? NSTextView
        XCTAssertTrue(editor?.delegate === search, "a click on the search left the cursor in \(String(describing: window.firstResponder))")
    }

    /// The page scrolls in the window's one scroll view: Services and Logs each nested a second.
    func testNoPageNestsASecondScrollView() {
        var config = rm.config
        config.routingMode = .bypass
        for i in config.services.indices.prefix(8) { config.services[i].enabled = true }
        rm.config = config
        rm.log(.info, "A line for the Logs page")
        let window = open()
        for page in [SettingsView.SettingsTab.services, .logs] {
            SettingsPageRequest.shared.page = page
            settle(window)
            // The sidebar has its own; the page's are right of it.
            let pageScrolls = all(in: window.contentView!) {
                guard let scroll = $0 as? NSScrollView else { return false }
                return scroll.convert(scroll.bounds, to: nil).minX >= SettingsSidebarView.width
            }
            XCTAssertEqual(pageScrolls.count, 1, "\(page) has \(pageScrolls.count) scroll views")
        }
    }

    // MARK: - Helpers

    private func open() -> NSWindow {
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

    /// A real click, through the window's own event handling, as the title bar sees it. The
    /// mouse-up is queued first: a text field tracks the mouse until it comes.
    private func click(_ point: NSPoint, in window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        settle(window)
    }

    private func press(_ key: String, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        _ = window.performKeyEquivalent(with: event)
        settle(window)
    }

    /// SwiftUI draws its buttons itself, so they are found the way VoiceOver finds them: with
    /// an accessibility client switched on, and each getter sent by name, since SwiftUI's nodes
    /// answer them without declaring the protocol to Swift (as in UnknownVPNRenderTests).
    private func hasElement(labelled label: String, in window: NSWindow) -> Bool {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasClient = (NSApplication.shared.accessibilityAttributeValue(attribute) as? Bool) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApplication.shared.accessibilitySetValue(wasClient, forAttribute: attribute) }
        settle(window)
        func find(_ element: Any, depth: Int) -> Bool {
            guard depth < 80, let element = element as? NSObject else { return false }
            func get(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
            }
            if (get("accessibilityLabel") as? String) == label { return true }
            return (get("accessibilityChildren") as? [Any] ?? []).contains { find($0, depth: depth + 1) }
        }
        return find(window, depth: 0)
    }

    private func all(in view: NSView, where match: (NSView) -> Bool) -> [NSView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { all(in: $0, where: match) }
    }

    private func find(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        all(in: view, where: match).first
    }

    /// A language folder from the source tree; a test run has no app bundle to take it from.
    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }
}
