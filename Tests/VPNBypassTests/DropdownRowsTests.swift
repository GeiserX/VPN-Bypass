// DropdownRowsTests.swift
// Section 6 step 11 of docs/design/APP-REWORK-PROPOSALS.md, flow fixes 4, 5, 7 and 8.
//
// The problems these lock down: the dropdown's add field had to be opened first, never took the
// focus, did not answer Esc, and did not exist with no VPN. A row could not be acted on: turning
// one service off meant opening Settings, and VoiceOver read each row as two stops. The Settings
// sidebar did not answer the arrow keys. With the menu bar icon hidden, opening the app again
// did nothing.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class DropdownRowsTests: XCTestCase {

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Fixtures

    private func route(_ destination: String, _ source: String) -> RoutedBySource.InstalledRoute {
        .init(destination: destination, source: source)
    }

    private func config(_ edit: (inout RouteManager.Config) -> Void) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.services = []
        c.domains = []
        c.inverseDomains = []
        c.rules = []
        edit(&c)
        return c
    }

    private func telegram(enabled: Bool = true) -> RouteManager.ServiceEntry {
        RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: enabled, domains: [], ipRanges: [])
    }

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    // MARK: - Row actions (flow fix 5)

    func testAWorkingServiceRowOffersTurnOffOnHoverAndTheFullMenu() throws {
        let c = config { $0.services = [telegram()] }
        let routes = (1...18).map { route("192.0.2.\($0)", "Telegram") }
        let row = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false)?.rows.first)
        let commands = RoutedBySource.commands(for: row, mode: .bypass, config: c, canRetry: true)
        XCTAssertEqual(commands, [.turnOff(.service(id: "telegram")), .showInSettings(.services), .copyAddresses])
        XCTAssertEqual(RoutedBySource.hoverCommand(in: commands, isProblem: row.isProblem), .turnOff(.service(id: "telegram")))
        XCTAssertEqual(row.allAddresses.count, 18, "Copy Addresses copies every address, not the tooltip's ten")
        XCTAssertEqual(row.numberText, "18")
        XCTAssertEqual(row.spokenLabel(), "Telegram, 18 addresses")
    }

    func testAProblemRowOffersRetryOnlyWhenAnApplyCanRun() throws {
        let entry = DomainEntry(domain: "zoom.us", enabled: true)
        let c = config { $0.domains = [entry] }
        let row = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: [], busy: false)?.rows.first)
        XCTAssertTrue(row.isProblem)

        let ready = RoutedBySource.commands(for: row, mode: .bypass, config: c, canRetry: true)
        XCTAssertEqual(ready, [.turnOff(.domain(entry.id)), .retry, .showInSettings(.domains)], "no addresses to copy")
        XCTAssertEqual(RoutedBySource.hoverCommand(in: ready, isProblem: true), .retry)

        let busy = RoutedBySource.commands(for: row, mode: .bypass, config: c, canRetry: false)
        XCTAssertFalse(busy.contains(.retry))
        XCTAssertEqual(RoutedBySource.hoverCommand(in: busy, isProblem: true), .turnOff(.domain(entry.id)))
    }

    func testEachModeTurnsOffItsOwnEntry() throws {
        let inverse = DomainEntry(domain: "intranet.example.com", enabled: true)
        let vpnOnly = config { $0.inverseDomains = [inverse] }
        let vRow = try XCTUnwrap(RoutedBySource.make(mode: .vpnOnly, config: vpnOnly,
                                                     routes: [route("10.0.0.5", "intranet.example.com")], busy: false)?.rows.first)
        XCTAssertEqual(RoutedBySource.target(of: vRow, mode: .vpnOnly, config: vpnOnly), .inverseDomain(inverse.id))
        XCTAssertEqual(RoutedBySource.settingsPage(for: vRow, mode: .vpnOnly), .domains)

        // Two Custom rules with one pattern are one row, and Turn Off turns both off.
        let direct = Route(name: "Direct", egress: .direct)
        let a = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: direct.id, order: 0)
        let b = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: direct.id, order: 1)
        let off = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: direct.id, enabled: false, order: 2)
        let custom = config { $0.routes = [direct]; $0.rules = [a, b, off] }
        let cRow = try XCTUnwrap(RoutedBySource.make(mode: .custom, config: custom,
                                                     routes: [route("203.0.113.0/24", "203.0.113.0/24")], busy: false)?.rows.first)
        XCTAssertEqual(RoutedBySource.target(of: cRow, mode: .custom, config: custom), .rules([a.id, b.id]))
        XCTAssertEqual(RoutedBySource.settingsPage(for: cRow, mode: .custom), .rules)
    }

    /// The "Left from earlier" row has no entry to turn off; its addresses can still be copied.
    func testTheLeftoverRowCanOnlyBeShownAndCopied() throws {
        let c = config { _ in }
        let row = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c,
                                                    routes: [route("192.0.2.9", "gone.example")], busy: false)?.rows.first)
        XCTAssertEqual(row.icon, .leftover)
        XCTAssertEqual(RoutedBySource.commands(for: row, mode: .bypass, config: c, canRetry: true),
                       [.showInSettings(.status), .copyAddresses])
        XCTAssertNil(RoutedBySource.hoverCommand(in: [.showInSettings(.status), .copyAddresses], isProblem: false))
    }

    /// An entry turned off since the list was drawn offers no Turn Off.
    func testAnEntryAlreadyOffHasNoTurnOff() throws {
        let row = RoutedBySource.Row(id: "Telegram", name: "Telegram", icon: .service(id: "telegram"), routeCount: 3,
                                     isProblem: false, addresses: [], hiddenAddresses: 0, allAddresses: ["192.0.2.1"])
        XCTAssertNil(RoutedBySource.target(of: row, mode: .bypass, config: config { $0.services = [telegram(enabled: false)] }))
    }

    // MARK: - The reason in a problem row

    func testAProblemRowSaysWhatTheLastApplySaidForIt() throws {
        let c = config { $0.domains = [DomainEntry(domain: "zoom.us", enabled: true)] }
        let row = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: [], busy: false)?.rows.first)
        let failures = RouteManager.RouteFailure.unresolved([("zoom.us", "zoom.us")])
        let reason = try XCTUnwrap(RoutedBySource.problemReason(for: row, failures: failures))
        XCTAssertTrue(reason.hasPrefix("Did not resolve: "), reason)
        XCTAssertEqual(RoutedBySource.problemReason(for: row, failures: []), "No address is routed for it.")
        XCTAssertEqual(row.spokenLabel(reason: "No address is routed for it."),
                       "zoom.us, no addresses, No address is routed for it.")

        let working = RoutedBySource.Row(id: "a", name: "a", icon: .domain, routeCount: 1, isProblem: false,
                                         addresses: [], hiddenAddresses: 0)
        XCTAssertNil(RoutedBySource.problemReason(for: working, failures: failures), "only a problem row has a reason")
    }

    // MARK: - Wording

    func testTheActionNamesSayWhichRowAndAreTranslated() throws {
        XCTAssertEqual(ControlNames.turnOff("Telegram"), "Turn Off Telegram")
        XCTAssertEqual(ControlNames.retry("Zoom"), "Retry Zoom")
        XCTAssertEqual(ControlNames.showInSettings("Telegram"), "Show Telegram in Settings")
        XCTAssertEqual(ControlNames.copyAddresses("Telegram"), "Copy the Addresses of Telegram")
        let es = try lproj("es"), fr = try lproj("fr")
        XCTAssertEqual(ControlNames.turnOff("Telegram", in: es), "Desactivar Telegram")
        XCTAssertEqual(ControlNames.showInSettings("Telegram", in: fr), "Afficher Telegram dans les Réglages")
        XCTAssertEqual(DropdownCopy.quickAddPlaceholder(.bypass, in: es), "Añadir un sitio que evite la VPN…")
        XCTAssertEqual(DropdownShortcut.addSite.symbol, "⌘N")
    }

    // MARK: - The add field (flow fix 4)

    private final class Box: ObservableObject {
        @Published var text = ""
        var adds = 0
        var cancels = 0
    }

    private struct FieldHost: View {
        @ObservedObject var box: Box
        var body: some View {
            VStack {
                Button("Other") {}
                QuickAddField(text: $box.text, placeholder: "Add a site to bypass…", feedback: nil,
                              onAdd: { box.adds += 1 }, onCancel: { box.text = ""; box.cancels += 1 })
            }
            .frame(width: 340)
        }
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        settle()
        return window
    }

    private func settle() {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        settle()
    }

    private func fieldHasFocus(_ window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    func testCommandNPutsTheCursorInTheFieldAndEscClearsIt() {
        let box = Box()
        let window = host(FieldHost(box: box))
        window.makeFirstResponder(nil)
        settle()
        XCTAssertFalse(fieldHasFocus(window))

        key("n", keyCode: 45, modifiers: .command, in: window)
        XCTAssertTrue(fieldHasFocus(window), "⌘N focuses the field")

        box.text = "shop.example.com"
        settle()
        key("\u{1b}", keyCode: 53, modifiers: [], in: window)
        XCTAssertEqual(box.cancels, 1, "Esc cancels")
        XCTAssertEqual(box.text, "")
        XCTAssertFalse(fieldHasFocus(window), "and gives the focus back")
    }

    /// With the field empty and unused, Esc is left alone, so it still closes the dropdown.
    func testEscIsLeftAloneWhileTheFieldIsUnused() {
        let box = Box()
        let window = host(FieldHost(box: box))
        window.makeFirstResponder(nil)
        settle()
        key("\u{1b}", keyCode: 53, modifiers: [], in: window)
        XCTAssertEqual(box.cancels, 0)
    }

    /// The field sits in the part of the dropdown every state shows, not in the connected
    /// content, where it was the only way to add.
    func testTheFieldIsOpenWithAndWithoutAVPN() throws {
        let menu = try ReworkSource.body(of: "struct MenuContent: View", in: "MenuBarViews.swift")
        let connected = try ReworkSource.body(of: "private var connectedContent: some View", in: "MenuBarViews.swift")
        let disconnected = try ReworkSource.body(of: "private var disconnectedContent: some View", in: "MenuBarViews.swift")
        let field = try XCTUnwrap(menu.range(of: "QuickAddField("), "no add field in the dropdown")
        let content = try XCTUnwrap(menu.range(of: "if !isStarting {"))
        XCTAssertLessThan(field.lowerBound, content.lowerBound, "drawn before the state-dependent content")
        XCTAssertFalse(connected.contains("QuickAddField") || connected.contains("isAddingDomain"))
        XCTAssertFalse(disconnected.contains("QuickAddField"))
    }

    // MARK: - One VoiceOver element per row (flow fix 7)

    /// SwiftUI's nodes are found the way VoiceOver finds them: with an accessibility client
    /// switched on, and each getter sent by name (as in SettingsShellTests).
    private func get(_ name: String, of element: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }

    private func elements(in element: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 80, let object = element as? NSObject else { return [] }
        let children = get("accessibilityChildren", of: object) as? [Any] ?? []
        return [object] + children.flatMap { elements(in: $0, depth: depth + 1) }
    }

    private func label(_ object: NSObject) -> String? { get("accessibilityLabel", of: object) as? String }

    func testEachRowIsOneElementWithItsActionsInTheRotor() throws {
        let c = config { $0.services = [telegram()] }
        let routes = (1...18).map { route("192.0.2.\($0)", "Telegram") }
        let summary = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: c, routes: routes, busy: false))
        var turnedOff = 0
        let card = RoutedBySourceCard(summary: summary, actions: { row in
            let off = RowAction(kind: .other, name: ControlNames.turnOff(row.name), systemImage: "minus.circle") { turnedOff += 1 }
            let copy = RowAction(kind: .other, name: ControlNames.copyAddresses(row.name), systemImage: "doc.on.doc") {}
            return (off, [off, copy])
        })
        let window = host(card.frame(width: 340))
        let client = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasClient = (NSApplication.shared.accessibilityAttributeValue(client) as? Bool) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: client)
        defer { NSApplication.shared.accessibilitySetValue(wasClient, forAttribute: client) }
        settle()
        let all = elements(in: window)
        let rows = all.filter { label($0) == "Telegram, 18 addresses" }
        XCTAssertEqual(rows.count, 1, "the row is read once, as one element; read: \(all.compactMap(label))")
        XCTAssertFalse(all.contains { label($0) == "Telegram" }, "its name is not a stop of its own")
        let row = try XCTUnwrap(rows.first)
        let actions = get("accessibilityCustomActions", of: row) as? [NSAccessibilityCustomAction] ?? []
        XCTAssertEqual(Set(actions.map(\.name)), ["Turn Off Telegram", "Copy the Addresses of Telegram"])
        let off = try XCTUnwrap(actions.first { $0.name == "Turn Off Telegram" })
        if let handler = off.handler { _ = handler() } else if let target = off.target as? NSObject, let selector = off.selector {
            _ = target.perform(selector, with: off)
        }
        settle()
        XCTAssertEqual(turnedOff, 1, "the rotor action runs the row's action")
    }

    // MARK: - Settings sidebar arrow keys (flow fix 7)

    func testArrowKeysWalkTheSidebarAndStopAtItsEnds() {
        XCTAssertEqual(SettingsSidebar.page(after: .status, movingUp: false), .domains)
        XCTAssertEqual(SettingsSidebar.page(after: .routes, movingUp: false), .lookups, "across a group heading")
        XCTAssertEqual(SettingsSidebar.page(after: .lookups, movingUp: true), .routes)
        XCTAssertEqual(SettingsSidebar.page(after: .status, movingUp: true), .status, "stops at the first page")
        XCTAssertEqual(SettingsSidebar.page(after: .about, movingUp: false), .about, "stops at the last page")
        // Every page is reached going down, read-only ones included.
        var page = SettingsSidebar.Page.status
        var seen = [page]
        while case let next = SettingsSidebar.page(after: page, movingUp: false), next != page,
              seen.count <= SettingsSidebar.pages.count {
            seen.append(next)
            page = next
        }
        XCTAssertEqual(seen, SettingsSidebar.pages)
    }

    // MARK: - Reopen and the hidden icon (flow fix 8)

    func testReopeningOpensStatusUnlessSettingsIsOpen() {
        XCTAssertEqual(AppReopen.page(settingsShown: false), .status)
        XCTAssertNil(AppReopen.page(settingsShown: true), "an open window keeps its page")
    }

    func testTheIconIsHiddenOnlyWhenTheMenuBarShowsAndTheIconDoesNot() {
        XCTAssertFalse(MenuBarIconVisibility.isHidden(statusWindowsVisible: [true], menuBarVisible: true))
        XCTAssertTrue(MenuBarIconVisibility.isHidden(statusWindowsVisible: [false], menuBarVisible: true), "behind the notch")
        XCTAssertTrue(MenuBarIconVisibility.isHidden(statusWindowsVisible: [], menuBarVisible: true), "switched off")
        XCTAssertFalse(MenuBarIconVisibility.isHidden(statusWindowsVisible: [false], menuBarVisible: false),
                       "a menu bar that hides itself proves nothing")
        let defaults = UserDefaults(suiteName: "vpnb-menubar-autohide-test")!
        defaults.removePersistentDomain(forName: "vpnb-menubar-autohide-test")
        XCTAssertFalse(MenuBarIconVisibility.menuBarAutoHides(defaults))
        defaults.set(true, forKey: "_HIHideMenuBar")
        XCTAssertTrue(MenuBarIconVisibility.menuBarAutoHides(defaults), "auto-hidden menu bar")
        defaults.removePersistentDomain(forName: "vpnb-menubar-autohide-test")
        XCTAssertEqual(MenuBarIconVisibility.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
    }
}
