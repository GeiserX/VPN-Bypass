// ComponentsTests.swift
// The rework's tokens (Theme.Font, Space, Radius, the colour roles) and the seven shared
// components in Components.swift: each colour keeps one job, the rows line their numbers up,
// every control has a spoken name in en, es and fr, and the keys do what section 2 says.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class ComponentsTests: XCTestCase {

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Tokens

    func testColourRolesKeepTodaysValues() {
        XCTAssertEqual(Theme.text, Color.white)
        XCTAssertEqual(Theme.live, Color(hex: "10B981"))
        XCTAssertEqual(Theme.attention, Color(hex: "F59E0B"))
        XCTAssertEqual(Theme.failure, Color(hex: "EF4444"))
        XCTAssertEqual(Theme.accent, Color(hex: "2563EB"))
        XCTAssertEqual(Theme.accentText, Color(hex: "38BDF8"))
        XCTAssertEqual(Theme.textSecondary, Color(hex: "9CA3AF"))
        XCTAssertEqual(Theme.textTertiary, Color(hex: "6B7280"))
        let roles = [Theme.text, Theme.textSecondary, Theme.textTertiary, Theme.live, Theme.attention,
                     Theme.failure, Theme.accent, Theme.accentText]
        XCTAssertEqual(Set(roles.map { "\($0)" }).count, roles.count, "two roles share a colour")
    }

    /// The old names stay, as the same colours, until the last page moves over (step 11).
    func testOldNamesAreAliasesOfTheRoles() {
        XCTAssertEqual(Theme.textPrimary, Theme.text)
        XCTAssertEqual(Theme.success, Theme.live)
        XCTAssertEqual(Theme.warning, Theme.attention)
        XCTAssertEqual(Theme.error, Theme.failure)
        XCTAssertEqual(Theme.accent, Theme.Brand.blue)
        XCTAssertEqual(Theme.accentText, Theme.Brand.sky)
    }

    func testTypeScale() {
        XCTAssertEqual(Theme.Font.title, .system(size: 17, weight: .semibold))
        XCTAssertEqual(Theme.Font.body, .system(size: 13))
        XCTAssertEqual(Theme.Font.strong, .system(size: 13, weight: .medium))
        XCTAssertEqual(Theme.Font.section, .system(size: 11, weight: .semibold))
        XCTAssertEqual(Theme.Font.detail, .system(size: 11))
        XCTAssertEqual(Theme.Font.mono, .system(size: 12, design: .monospaced))
    }

    func testSpacingRadiiAndRowMetrics() {
        XCTAssertEqual([Theme.Space.xs, Theme.Space.s, Theme.Space.m, Theme.Space.l, Theme.Space.page], [4, 8, 12, 16, 24])
        XCTAssertEqual([Theme.Radius.control, Theme.Radius.group, Theme.Radius.sheet], [6, 10, 14])
        XCTAssertEqual(ListRow.singleLineHeight, 32)
        XCTAssertEqual(ListRow.twoLineHeight, 44)
        XCTAssertEqual(ListRow.inset, 12)
        XCTAssertEqual(ListRow.glyphColumn, 20)
        // The hairline starts where the name starts: inset, glyph column, gap.
        XCTAssertEqual(InsetDivider.leading, 40)
        XCTAssertEqual(SheetScaffold<EmptyView>.width, 420)
    }

    // MARK: - Status chip: shape, word, then colour

    func testGreenMeansOnAndNothingElse() {
        for kind in StatusChip.Kind.allCases {
            XCTAssertEqual(kind.color == Theme.live, kind == .on, "\(kind)")
            XCTAssertEqual(kind.color == Theme.attention, [.notRouting, .partlyRouted].contains(kind), "\(kind)")
            XCTAssertNotEqual(kind.color, Theme.failure, "\(kind): no state of routing is a failure colour")
        }
    }

    func testEachStateHasItsOwnShapeAndWord() {
        let expected: [StatusChip.Kind: (String, String)] = [
            .on: ("circle.fill", "On"), .notRouting: ("triangle.fill", "Not routing"),
            .partlyRouted: ("triangle.fill", "Partly routed"), .waiting: ("circle.lefthalf.filled", "Waiting"),
            .paused: ("pause.fill", "Paused"), .off: ("circle", "Off"),
        ]
        for kind in StatusChip.Kind.allCases {
            XCTAssertEqual(kind.systemImage, expected[kind]?.0, "\(kind)")
            XCTAssertEqual(kind.word(), expected[kind]?.1, "\(kind)")
            XCTAssertNotNil(NSImage(systemSymbolName: kind.systemImage, accessibilityDescription: nil), kind.systemImage)
        }
        XCTAssertEqual(Set(StatusChip.Kind.allCases.map { $0.word() }).count, StatusChip.Kind.allCases.count)
    }

    // MARK: - Route chip: a grey glyph and a word

    func testRouteChipGlyphs() {
        XCTAssertEqual(RouteChip.systemImage(for: .direct), "arrow.up.right")
        XCTAssertEqual(RouteChip.systemImage(for: .vpnDefault), "key")
        XCTAssertEqual(RouteChip.systemImage(for: .proxyHTTP), "arrow.triangle.branch")
        XCTAssertEqual(RouteChip.systemImage(for: .proxySOCKS5), "arrow.triangle.branch")
        for egress in [Egress.direct, .vpnDefault, .proxyHTTP, .proxySOCKS5, .tailscaleExit] {
            let symbol = RouteChip.systemImage(for: egress)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testRouteChipNamesTheRoute() {
        let direct = RouteChip(route: Route(name: "", egress: .direct), vpnName: "WireGuard")
        XCTAssertEqual(direct.name, "Direct")
        XCTAssertEqual(direct.systemImage, "arrow.up.right")
        let vpn = RouteChip(route: Route(name: "", egress: .vpnDefault), vpnName: "WireGuard")
        XCTAssertEqual(vpn.name, "WireGuard")
        XCTAssertEqual(RouteChip.spokenName("Direct"), "Route: Direct")
    }

    /// A chip keeps its own width when there is room and gets narrower when there is not, so a
    /// long route name truncates inside a narrow sheet instead of running past its edge.
    func testRouteChipFitsTheWidthItIsGiven() {
        let long = String(repeating: "Office proxy through the second building ", count: 4)
        let short = RouteChip(systemImage: "arrow.up.right", name: "Direct")
        for (label, chip) in [("chip", AnyView(RouteChip(systemImage: "key", name: long))),
                              ("menu", AnyView(RouteChipMenu(RouteChip(systemImage: "key", name: long)) { Text("x") }))] {
            let width = NSHostingController(rootView: chip).sizeThatFits(in: CGSize(width: 150, height: 100)).width
            XCTAssertLessThanOrEqual(width, 150, "\(label) runs past the width it was given")
        }
        for (label, chip) in [("chip", AnyView(short)), ("menu", AnyView(RouteChipMenu(short) { Text("x") }))] {
            let width = NSHostingController(rootView: chip).sizeThatFits(in: CGSize(width: 1000, height: 100)).width
            XCTAssertLessThan(width, 120, "\(label) stretches past its own width")
            XCTAssertGreaterThan(width, 40, "\(label) collapsed")
        }
    }

    /// The + is never silent: a page that gives no name gets "Add".
    func testTheAddButtonAlwaysHasAName() throws {
        XCTAssertEqual(PageHeader.addButtonName("Add Route"), "Add Route")
        XCTAssertEqual(PageHeader.addButtonName(""), "Add")
        XCTAssertEqual(PageHeader.addButtonName("", in: try lproj("es")), "Añadir")
    }

    // MARK: - List row

    /// The #183 rule: the column is as wide as the widest number on screen, on every row.
    func testNumberColumnIsAsWideAsTheWidestNumber() {
        let font = ListRow.numberFont
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) + 1 }
        XCTAssertEqual(ListRow.numberColumnWidth(for: ["4", "1,203", "0", "–"]), width("1,203"))
        XCTAssertGreaterThan(ListRow.numberColumnWidth(for: ["1,203"]), ListRow.numberColumnWidth(for: ["4"]))
        XCTAssertEqual(ListRow.numberColumnWidth(for: []), 0)
        // Digits are monospaced, so any two numbers of one length take one width.
        XCTAssertEqual(ListRow.numberColumnWidth(for: ["111"]), ListRow.numberColumnWidth(for: ["888"]))
    }

    func testARowThatNeedsAttentionLeadsWithTheTriangle() {
        XCTAssertEqual(ListRow.leadingGlyph("globe", needsAttention: false), "globe")
        XCTAssertEqual(ListRow.leadingGlyph("globe", needsAttention: true), "exclamationmark.triangle.fill")
    }

    func testRowActionsNameTheirRowAndCarryTheirKeys() {
        let edit = RowAction.edit("Telegram") {}
        let delete = RowAction.delete("en.wikipedia.org") {}
        XCTAssertEqual(edit.name, "Edit Telegram")
        XCTAssertEqual(delete.name, "Delete en.wikipedia.org")
        XCTAssertEqual(edit.shortcut?.key, .return)
        XCTAssertEqual(edit.shortcut?.modifiers, [])
        XCTAssertEqual(delete.shortcut?.key, .delete)
        XCTAssertEqual(delete.shortcut?.modifiers, .command)
        XCTAssertNil(RowAction(kind: .more, name: "More actions", systemImage: "ellipsis") {}.shortcut)
    }

    // MARK: - Keys, pressed

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
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
    private func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        let handled = window.performKeyEquivalent(with: event)
        settle()
        return handled
    }

    private final class Counts { var edits = 0, deletes = 0 }

    private struct RowHost: View {
        let counts: Counts
        let isSelected: Bool
        @State var isOn = true
        let onToggle: (Bool) -> Void

        var body: some View {
            ListRow(glyph: "globe", name: "en.wikipedia.org", detail: "4 addresses",
                    actions: [.edit("en.wikipedia.org") { counts.edits += 1 },
                              .delete("en.wikipedia.org") { counts.deletes += 1 }],
                    isOn: $isOn, isSelected: isSelected)
                .onChange(of: isOn, perform: onToggle)
        }
    }

    /// A selected row: Return edits, ⌘⌫ deletes, Space toggles. A row that is not selected
    /// answers none of them, or every row on a page would.
    func testASelectedRowAnswersItsKeys() {
        for selected in [false, true] {
            let counts = Counts()
            var toggles: [Bool] = []
            let window = host(RowHost(counts: counts, isSelected: selected) { toggles.append($0) })
            press("\r", [], keyCode: 36, in: window)
            press("\u{8}", .command, keyCode: 51, in: window)
            press(" ", [], keyCode: 49, in: window)
            XCTAssertEqual(counts.edits, selected ? 1 : 0, "Return, selected: \(selected)")
            XCTAssertEqual(counts.deletes, selected ? 1 : 0, "⌘⌫, selected: \(selected)")
            XCTAssertEqual(toggles, selected ? [false] : [], "Space, selected: \(selected)")
            window.orderOut(nil)
        }
    }

    /// Esc cancels and Return confirms, in every sheet; a sheet that cannot confirm yet ignores Return.
    func testSheetKeys() {
        for (canConfirm, destructive) in [(true, false), (false, false), (true, true), (false, true)] {
            var cancels = 0, confirms = 0
            let window = host(SheetScaffold("New Rule", confirmTitle: "Add Rule", isDestructive: destructive,
                                            canConfirm: canConfirm,
                                            onCancel: { cancels += 1 }, onConfirm: { confirms += 1 }) {
                Text("content")
            })
            press("\u{1b}", [], keyCode: 53, in: window)
            press("\r", [], keyCode: 36, in: window)
            XCTAssertEqual(cancels, 1, "Esc, canConfirm: \(canConfirm)")
            XCTAssertEqual(confirms, canConfirm ? 1 : 0, "Return, canConfirm: \(canConfirm)")
            window.orderOut(nil)
        }
    }

    func testTheConfirmButtonIsAccentOrFailure() {
        XCTAssertEqual(SheetScaffold<EmptyView>.confirmColor(isDestructive: false), Theme.accent)
        XCTAssertEqual(SheetScaffold<EmptyView>.confirmColor(isDestructive: true), Theme.failure)
        XCTAssertNil(SheetScaffold<EmptyView>.confirmRole(isDestructive: false))
        XCTAssertEqual(SheetScaffold<EmptyView>.confirmRole(isDestructive: true), .destructive)
    }

    /// ⌘F puts the cursor in the page's search field.
    func testCommandFFocusesSearch() {
        struct Host: View {
            @State var text = ""
            var body: some View {
                PageHeader(title: "Routes", subtitle: "Where traffic can go.", search: $text,
                           addName: "Add Route", onAdd: {})
                    .padding()
            }
        }
        let window = host(Host())
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder is NSText, "control: nothing is focused before ⌘F")
        XCTAssertTrue(press("f", .command, keyCode: 3, in: window), "⌘F was not handled")
        XCTAssertTrue(window.firstResponder is NSText, "⌘F left the focus on \(String(describing: window.firstResponder))")
    }

    // MARK: - Words, in every language

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testTheComponentWordsAreTranslated() throws {
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for kind in StatusChip.Kind.allCases {
                XCTAssertNotEqual(kind.word(in: bundle), kind.word(in: .main), "\(language): \(kind)")
            }
            XCTAssertNotEqual(RouteChip.spokenName("Direct", in: bundle), "Route: Direct", language)
            XCTAssertTrue(RouteChip.spokenName("Direct", in: bundle).hasSuffix("Direct"), language)
            XCTAssertNotEqual(bundle.localizedString(forKey: "Needs attention", value: nil, table: nil), "Needs attention", language)
        }
    }
}
