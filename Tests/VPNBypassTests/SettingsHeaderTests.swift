// SettingsHeaderTests.swift
// The Settings window's header: the title bar holds only the traffic lights, the page header
// band under it holds the title, the search (named for the list it filters) and the page's
// actions, the sidebar opens with the app's icon and name level with the page title, and the
// mode is one control with all three modes, each named for VoiceOver with what it does.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class SettingsHeaderTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var window: NSWindow?
    private var savedConfig: RouteManager.Config!
    private var savedLastPage: String?

    override func setUp() async throws {
        savedConfig = rm.config
        savedLastPage = UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
        var config = rm.config
        config.routingMode = .bypass
        config.schemaVersion = 2
        rm.config = config
    }

    override func tearDown() async throws {
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        window?.orderOut(nil)
        window = nil
        rm.config = savedConfig
        UserDefaults.standard.set(savedLastPage, forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    // MARK: - The mode control

    func testTheModeControlOffersAllThreeModesWithOneLineEach() throws {
        XCTAssertEqual(ModeControl.modes, [.bypass, .vpnOnly, .custom])
        XCTAssertEqual(ModeControl.modes.map { ModeControl.meaning($0) },
                       ["Your list skips the VPN.", "Only your list uses the VPN.", "Your rules pick each route."])
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for mode in ModeControl.modes {
                XCTAssertNotEqual(ModeControl.meaning(mode, in: bundle), ModeControl.meaning(mode), "\(language): \(mode)")
            }
        }
        XCTAssertEqual(Set(ModeControl.modes.map(ModeControl.glyph)).count, 3, "each mode has its own glyph")
    }

    /// Each mode is a button VoiceOver reads by its name, with what it does as the hint, and
    /// only the mode in use is selected; in every mode.
    func testTheSidebarNamesEachModeForVoiceOver() throws {
        for current in ModeControl.modes {
            var config = rm.config
            config.routingMode = current
            rm.config = config
            let window = open(.general)
            let modes = try sidebarModes(in: window)
            for mode in ModeControl.modes {
                let element = try XCTUnwrap(modes[mode], "\(current): no \(mode) in the sidebar")
                XCTAssertEqual(AccessibilityTree.hint(element), ModeControl.meaning(mode), "\(current): \(mode)'s hint")
                XCTAssertEqual(AccessibilityTree.isSelected(element), mode == current, "\(current): \(mode)'s selected trait")
            }
            window.orderOut(nil)
        }
    }

    /// A pick opens the sheet and switches nothing; the mode in use opens nothing.
    func testPickingAModeInTheSidebarAsksFirst() throws {
        let window = open(.general)
        AccessibilityTree.press(try XCTUnwrap(try sidebarModes(in: window)[.bypass]))
        settle(window)
        XCTAssertNil(window.attachedSheet, "the mode in use opened the sheet")

        AccessibilityTree.press(try XCTUnwrap(try sidebarModes(in: window)[.vpnOnly]))
        settle(window)
        XCTAssertNotNil(window.attachedSheet, "picking VPN Only opened no sheet")
        XCTAssertEqual(rm.config.routingMode, .bypass, "the pick switched before Switch")
    }

    // MARK: - The search

    /// The search says which list it filters, for sight and for VoiceOver, on every list page,
    /// and it is missing on a page with nothing to search.
    func testTheSearchNamesTheListItFilters() throws {
        var config = rm.config
        config.routingMode = .custom
        rm.config = config
        let window = open(.status)
        for page in SettingsView.SettingsTab.allCases {
            SettingsPageRequest.shared.page = page
            settle(window)
            let fields = searchFields(in: window)
            if SettingsSidebar.isSearchable(page) {
                XCTAssertEqual(fields.count, 1, "\(page): \(fields.count) search fields")
                XCTAssertEqual(fields.first?.placeholderString, "Search \(page.name)", "\(page)")
                XCTAssertEqual(fields.first?.accessibilityLabel(), "Search \(page.name)", "\(page)'s spoken name")
            } else {
                XCTAssertTrue(fields.isEmpty, "\(page) has nothing to search but shows a search field")
            }
        }
        for language in ["es", "fr"] {
            let prompt = PageHeader.searchPrompt(for: "Dominios", in: try lproj(language))
            XCTAssertNotEqual(prompt, "Search Dominios", "\(language) leaves the prompt in English")
            XCTAssertTrue(prompt.contains("Dominios"), "\(language): \(prompt)")
        }
    }

    /// The title bar row holds only the traffic lights: the title, the search and the + sit in
    /// the band under it, and a click on each lands on it, not on the title bar (#198).
    func testTheHeaderBandSitsUnderTheTitleBarAndTakesClicks() throws {
        let window = open(.rules)
        let content = try XCTUnwrap(window.contentView)
        let frameView = try XCTUnwrap(content.superview)
        let titleBarBottom = window.contentLayoutRect.maxY
        let bandBottom = titleBarBottom - PageHeader.height

        let search = try XCTUnwrap(searchFields(in: window).first)
        let searchFrame = search.convert(search.bounds, to: nil)
        XCTAssertLessThanOrEqual(searchFrame.maxY, titleBarBottom, "the search reaches into the title bar")
        XCTAssertGreaterThanOrEqual(searchFrame.minY, bandBottom, "the search is under the header band")
        XCTAssertGreaterThanOrEqual(searchFrame.width, PageHeader.searchWidth.lowerBound)
        XCTAssertLessThanOrEqual(searchFrame.width, PageHeader.searchWidth.upperBound)

        let all = AccessibilityTree.elements(under: window) { settle(window) }
        for name in ["Rules", "Add Rule"] {
            let element = try XCTUnwrap(all.first { AccessibilityTree.label($0) == name && isInContent($0, window) },
                                        "no \(name) in the page header")
            let screen = try XCTUnwrap(AccessibilityTree.frame(element))
            let rect = window.convertFromScreen(screen)
            XCTAssertLessThanOrEqual(rect.maxY, titleBarBottom + 0.5, "\(name) reaches into the title bar")
            XCTAssertGreaterThanOrEqual(rect.minY, bandBottom - 0.5, "\(name) is under the header band")
            let hit = frameView.hitTest(frameView.convert(NSPoint(x: rect.midX, y: rect.midY), from: nil))
            XCTAssertTrue(hit?.isDescendant(of: content) == true, "a click on \(name) lands on \(String(describing: hit))")
        }

        let centre = NSPoint(x: searchFrame.midX, y: searchFrame.midY)
        let hit = frameView.hitTest(frameView.convert(centre, from: nil))
        XCTAssertTrue(hit?.isDescendant(of: search) == true, "a click on the search lands on \(String(describing: hit))")
        window.makeFirstResponder(nil)
        click(centre, in: window)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === search,
                      "a click on the search left the cursor in \(String(describing: window.firstResponder))")
    }

    /// The window opens with the sidebar focused, so ↑ and ↓ change page and the search shows
    /// no focus ring until it is clicked or ⌘F is pressed.
    func testTheWindowOpensWithTheSidebarFocusedNotTheSearch() throws {
        let window = open(.domains)
        XCTAssertFalse(window.firstResponder is NSText,
                       "the window opened with the cursor in \(String(describing: window.firstResponder))")
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                  isARepeat: false, keyCode: 125))
        window.sendEvent(down)
        settle(window)
        XCTAssertEqual(window.title, SettingsSidebar.page(after: .domains, movingUp: false).name,
                       "↓ did not move the sidebar: the list has no focus")
    }

    /// On the smallest window the last rows sit below the sidebar's fold. ↓ down to About keeps
    /// the selected row on screen, so the selection never moves out of sight.
    func testTheArrowKeysKeepTheSelectedRowInView() throws {
        let window = open(.general)
        window.setContentSize(NSSize(width: 720, height: 480))
        settle(window)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                  isARepeat: false, keyCode: 125))
        window.sendEvent(down)
        settle(window)
        XCTAssertEqual(window.title, SettingsView.SettingsTab.about.name)
        let all = AccessibilityTree.elements(under: window) { settle(window) }
        // The row, not the window (whose title is About too): narrower than the sidebar.
        let rows = all.compactMap { element -> NSRect? in
            guard AccessibilityTree.label(element) == SettingsView.SettingsTab.about.name,
                  let frame = AccessibilityTree.frame(element) else { return nil }
            let local = window.convertFromScreen(frame)
            return local.width <= SettingsSidebarView.width && local.minX < SettingsSidebarView.width ? local : nil
        }
        let row = try XCTUnwrap(rows.first, "no About row in the sidebar")
        XCTAssertGreaterThanOrEqual(row.minY, -0.5, "the selected About row is below the window's bottom edge")
    }

    // MARK: - The logo

    /// The sidebar opens with the app's icon and its name, one header for VoiceOver, on the
    /// same line as the page title.
    func testTheSidebarOpensWithTheAppIconAndName() throws {
        XCTAssertNotNil(SidebarBrandHeader.icon, "no app icon to show")
        let window = open(.services)
        let all = AccessibilityTree.elements(under: window) { settle(window) }
        let brand = try XCTUnwrap(all.first { AccessibilityTree.label($0) == "VPN Bypass" && !isInContent($0, window) },
                                  "no VPN Bypass header in the sidebar")
        let title = try XCTUnwrap(all.first { AccessibilityTree.label($0) == "Services" && isInContent($0, window) })
        let brandFrame = try XCTUnwrap(AccessibilityTree.frame(brand))
        let titleFrame = try XCTUnwrap(AccessibilityTree.frame(title))
        XCTAssertLessThan(brandFrame.maxY, window.frame.maxY - (window.frame.height - window.contentLayoutRect.height) + 0.5,
                          "the app name reaches into the title bar")
        // The title has a subtitle under it, so its own line sits a little higher than centre.
        XCTAssertEqual(brandFrame.midY, titleFrame.midY, accuracy: 10, "the app name and the page title are not level")
    }

    // MARK: - Helpers

    private func sidebarModes(in window: NSWindow) throws -> [RoutingMode: NSObject] {
        let all = AccessibilityTree.elements(under: window) { settle(window) }
        var found: [RoutingMode: NSObject] = [:]
        for mode in ModeControl.modes {
            found[mode] = all.first {
                AccessibilityTree.label($0) == DropdownModePicker.label(mode) && !isInContent($0, window)
                    && AccessibilityTree.hint($0) != nil
            }
        }
        return found
    }

    /// Right of the sidebar, in the page.
    private func isInContent(_ element: NSObject, _ window: NSWindow) -> Bool {
        guard let screen = AccessibilityTree.frame(element) else { return false }
        return window.convertFromScreen(screen).minX >= SettingsSidebarView.width
    }

    private func searchFields(in window: NSWindow) -> [NSSearchField] {
        func all(_ view: NSView) -> [NSSearchField] {
            ((view as? NSSearchField).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        return window.contentView.map(all) ?? []
    }

    private func open(_ page: SettingsView.SettingsTab) -> NSWindow {
        SettingsPageRequest.shared.page = page
        let window = SettingsWindowController.makeWindow()
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.setContentSize(SettingsWindowController.defaultContentSize)
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

    /// A real click, through the window's own event handling. The mouse-up is queued first: a
    /// text field tracks the mouse until it comes.
    private func click(_ point: NSPoint, in window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
        settle(window)
    }

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }
}
