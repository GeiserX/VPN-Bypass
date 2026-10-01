// NamedControlsTests.swift
// Proposal 9 of #119: every row switch carries its row's name and the native small size,
// icon buttons say which row they act on, and the dropdown answers ⌘R, ⌘, and ⌘Q.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class NamedControlsTests: XCTestCase {

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Wording

    func testIconButtonsNameTheRowTheyActOn() {
        XCTAssertEqual(ControlNames.delete("en.wikipedia.org"), "Delete en.wikipedia.org")
        XCTAssertEqual(ControlNames.edit("Telegram"), "Edit Telegram")
        // An editor's blank line has no name yet.
        XCTAssertEqual(ControlNames.delete(""), "Delete")
        XCTAssertEqual(ControlNames.delete("  "), "Delete")
    }

    func testShortcutsReadAsAMenuWritesThem() {
        XCTAssertEqual(DropdownShortcut.refreshRoutes.symbol, "⌘R")
        XCTAssertEqual(DropdownShortcut.settings.symbol, "⌘,")
        XCTAssertEqual(DropdownShortcut.quit.symbol, "⌘Q")
        XCTAssertEqual(DropdownShortcut.settings.help("Settings"), "Settings (⌘,)")
        XCTAssertEqual(DropdownShortcut.quit.help("Quit VPN Bypass"), "Quit VPN Bypass (⌘Q)")
        XCTAssertEqual(ControlNames.help("Search services", shortcut: "⌘F"), "Search services (⌘F)")
        XCTAssertEqual(DropdownShortcut.refreshRoutes.title, "Refresh Routes")
        XCTAssertEqual(DropdownShortcut.settings.title, "Settings…")
        XCTAssertEqual(DropdownShortcut.quit.title, "Quit VPN Bypass")
        // Two shortcuts on one key would leave one of them dead.
        XCTAssertEqual(Set(DropdownShortcut.allCases.map(\.symbol)).count, DropdownShortcut.allCases.count)
    }

    /// A language folder from the source tree; a test run has no app bundle to take it from.
    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testTheNamesAreTranslated() throws {
        let es = try lproj("es"), fr = try lproj("fr")
        XCTAssertEqual(ControlNames.delete("en.wikipedia.org", in: es), "Eliminar en.wikipedia.org")
        XCTAssertEqual(ControlNames.edit("Telegram", in: fr), "Modifier Telegram")
        XCTAssertEqual(ControlNames.delete("", in: fr), "Supprimer")
        for (name, bundle) in [("es", es), ("fr", fr)] {
            for shortcut in DropdownShortcut.allCases {
                XCTAssertNotEqual(shortcut.title(in: bundle), shortcut.title(in: .main), "\(name): \(shortcut)")
            }
            for key in ["Open Logs", "More actions", "Search services", "Clear search", "Add Route", "Add Rule"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key, "\(name) leaves \"\(key)\" in English")
            }
        }
    }

    // MARK: - The shortcuts, pressed

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        settle()
        return window
    }

    private func settle() {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @discardableResult
    private func press(_ key: String, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
        let handled = window.performKeyEquivalent(with: event)
        settle()
        return handled
    }

    func testTheFooterButtonsAnswerTheirOwnKeyOnly() {
        for shortcut in DropdownShortcut.allCases {
            var presses = 0
            let window = host(DropdownIconButton(systemImage: "gearshape.fill", name: "Settings", shortcut: shortcut) { presses += 1 })
            for other in DropdownShortcut.allCases where other != shortcut {
                press(String(other.key.character), in: window)
            }
            XCTAssertEqual(presses, 0, "\(shortcut) answered another key")
            XCTAssertTrue(press(String(shortcut.key.character), in: window), "\(shortcut)")
            XCTAssertEqual(presses, 1, "\(shortcut) did not answer \(shortcut.symbol)")
            window.orderOut(nil)
        }
    }

    /// Presses the key the way the app receives it: through the event queue, so
    /// `NSApp.currentEvent` is the key press while the button's action runs.
    private func pressThroughQueue(_ key: String, isARepeat: Bool, in window: NSWindow) throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: isARepeat, keyCode: 0)!
        NSApp.postEvent(event, atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true))
        XCTAssertEqual(dequeued.isARepeat, isARepeat)
        _ = window.performKeyEquivalent(with: dequeued)
        settle()
    }

    /// SwiftUI runs a button's action for every repeat of a held key, and Refresh Routes turns
    /// active again between refreshes, so a held ⌘R started one refresh after another.
    func testAHeldCommandRStartsOneRefresh() throws {
        for guarded in [false, true] {
            var presses = 0
            let window = host(Button("Refresh Routes") {
                if guarded && DropdownShortcut.isKeyRepeat(NSApp.currentEvent) { return }
                presses += 1
            }.keyboardShortcut(.refreshRoutes))
            try pressThroughQueue("r", isARepeat: false, in: window)
            for _ in 0..<5 { try pressThroughQueue("r", isARepeat: true, in: window) }
            XCTAssertEqual(presses, guarded ? 1 : 6, guarded ? "a held ⌘R refreshed more than once"
                                                             : "control: SwiftUI hands the action every repeat")
            window.orderOut(nil)
        }
    }

    /// `isARepeat` raises on anything but a key event, and the same action runs on a click.
    func testAClickIsNotAKeyRepeat() throws {
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        XCTAssertFalse(DropdownShortcut.isKeyRepeat(click))
        XCTAssertFalse(DropdownShortcut.isKeyRepeat(nil))
    }

    func testCommandFPutsTheCursorInTheServicesSearch() {
        let rm = RouteManager.shared
        let saved = rm.config
        defer { rm.config = saved }
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        rm.config = cfg

        let window = host(ServicesTab().environmentObject(rm).environmentObject(SettingsUndo()).frame(width: 640, height: 720))
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder is NSTextView, "the field had the cursor before ⌘F")
        XCTAssertTrue(press("f", in: window))
        let editor = window.firstResponder as? NSTextView
        XCTAssertNotNil(editor, "⌘F left the cursor in \(String(describing: window.firstResponder))")
        XCTAssertEqual((editor?.delegate as? NSTextField)?.placeholderString, "Search services...")
    }

    /// SwiftUI draws a `.switch` Toggle as an AppKit NSSwitch, so the size it got is readable.
    /// `scaleEffect` left it at the regular size and shrank only the drawing.
    func testTheServicesSwitchesAreTheSmallNativeSwitch() {
        let rm = RouteManager.shared
        let saved = rm.config
        defer { rm.config = saved }
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        rm.config = cfg

        let window = host(ServicesTab().environmentObject(rm).environmentObject(SettingsUndo()).frame(width: 640, height: 720))
        func switches(in view: NSView) -> [NSSwitch] { ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches) }
        let found = switches(in: window.contentView!)
        XCTAssertGreaterThan(found.count, 5, "control: the page shows the catalogue's switches")
        XCTAssertEqual(found.filter { $0.controlSize != .small }.count, 0, "a switch is not the small size")
    }

    // MARK: - Every switch, in the source

    private func sources() throws -> [(name: String, text: String)] {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VPNBypassCore")
        let files = try FileManager.default.contentsOfDirectory(atPath: core.path).filter { $0.hasSuffix(".swift") }
        return try files.map { ($0, try String(contentsOf: core.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// `Toggle("")` reads as "switch, on" with no name, and `scaleEffect` shrinks the drawing but
    /// not the click target. Every switch takes its row's name, hides it and uses the small size.
    func testEverySwitchIsNamedAndNativelySmall() throws {
        var switches = 0
        for (name, text) in try sources() {
            XCTAssertFalse(text.contains("Toggle(\"\""), "\(name) has an unnamed Toggle")
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains(".toggleStyle(.switch)") {
                switches += 1
                let modifiers = lines[i..<min(i + 6, lines.count)].joined(separator: "\n")
                XCTAssertTrue(modifiers.contains(".labelsHidden()"), "\(name):\(i + 1) shows its label")
                XCTAssertTrue(modifiers.contains(".controlSize(.small)"), "\(name):\(i + 1) is not the small switch")
                XCTAssertFalse(modifiers.contains(".scaleEffect"), "\(name):\(i + 1) is scaled")
            }
        }
        XCTAssertGreaterThanOrEqual(switches, 6, "the scan found too few switches; the style moved")
    }

    /// The dropdown puts each shortcut on the visible button and lists it in the "…" menu.
    func testTheDropdownCarriesEveryShortcut() throws {
        let menu = try XCTUnwrap(try sources().first { $0.name == "MenuBarViews.swift" }?.text)
        XCTAssertEqual(menu.components(separatedBy: ".keyboardShortcut(.refreshRoutes)").count - 1, 2,
                       "Refresh Routes and its menu item")
        // Both Refresh Routes controls go through refresh(), which drops a held key's repeats.
        XCTAssertEqual(menu.components(separatedBy: "routeManager.refreshRoutes()").count - 1, 1,
                       "Refresh Routes runs from one place")
        XCTAssertTrue(menu.contains("""
                guard !DropdownShortcut.isKeyRepeat(NSApp.currentEvent) else { return }
                routeManager.refreshRoutes()
        """), "refresh() drops a held ⌘R's repeats")
        XCTAssertEqual(menu.components(separatedBy: "refresh()\n").count - 1 + menu.components(separatedBy: "{ refresh() }").count - 1, 2,
                       "the button and the menu item both call refresh()")
        for shortcut in ["settings", "quit"] {
            XCTAssertTrue(menu.contains("shortcut: .\(shortcut))"), "the footer button for \(shortcut)")
            XCTAssertTrue(menu.contains(".keyboardShortcut(.\(shortcut))"), "the menu item for \(shortcut)")
        }
    }
}
