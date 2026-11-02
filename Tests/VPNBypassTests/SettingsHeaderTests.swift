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

    // MARK: - The purpose line

    /// Every page says what it is for, in the header under its title and nowhere else, and in
    /// every language (#221 left Status, Logs, General and About without one, and Lookups and
    /// Routes with theirs in the page).
    func testEveryPageHasOnePurposeLineInTheHeader() throws {
        for (mode, pages) in Self.pagesByMode {
            seed(mode)
            let window = open(.status)
            for page in pages {
                let line = expectedPurpose(page, mode: mode)
                XCTAssertFalse(line.isEmpty, "\(page) has no purpose line")
                let found = try purposeElements(line, page: page, in: window)
                XCTAssertEqual(found.inBand, 1, "\(mode) \(page): \"\(line)\" is not under the title")
                XCTAssertEqual(found.total, 1, "\(mode) \(page): \"\(line)\" shows in the page as well")
            }
            window.orderOut(nil)
        }
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for page in SettingsView.SettingsTab.allCases {
                XCTAssertNotEqual(page.purpose(in: bundle), page.purpose(), "\(language) leaves \(page)'s line in English")
            }
            XCTAssertNotEqual(DomainsPage.purpose(isInverse: true, in: bundle), DomainsPage.purpose(isInverse: true))
            XCTAssertNotEqual(RulesTab.purpose(ruleCount: 3, in: bundle), RulesTab.purpose(ruleCount: 3))
        }
    }

    /// No purpose line loses its end, at the default size or the smallest: it fits on one line
    /// or wraps to a second inside the header band. The Domains line ended "use your regular
    /// c…" at 860 pt and the Rules line "… Drag to reorder." at 720 pt. The Spanish and French
    /// lines are measured against the room the English layout gives.
    func testNoPurposeLineIsCutAtTheDefaultOrTheSmallestWidth() throws {
        let font = NSFont.systemFont(ofSize: 11)
        let languages = try ["es", "fr"].map(lproj)
        for (mode, pages) in Self.pagesByMode {
            seed(mode)
            let window = open(.status)
            // Each header button's width at the default size: the smallest window may not
            // squeeze one to make room for the line (Start Watching was cut to a sliver).
            var buttonWidths: [String: CGFloat] = [:]
            for width in [SettingsWindowController.defaultContentSize.width, SettingsWindowController.minimumContentSize.width] {
                window.setContentSize(NSSize(width: width, height: SettingsWindowController.defaultContentSize.height))
                settle(window)
                let titleBarBottom = window.contentLayoutRect.maxY
                let bandBottom = titleBarBottom - PageHeader.height
                for page in pages {
                    let line = expectedPurpose(page, mode: mode)
                    let found = try purposeElements(line, page: page, in: window)
                    let rect = try XCTUnwrap(found.frame, "\(mode) \(page) at \(width): no purpose line")
                    let label = "\(mode) \(page) at \(Int(width)) pt"
                    XCTAssertGreaterThanOrEqual(rect.minY, bandBottom - 0.5, "\(label): the line runs below the header band")
                    XCTAssertLessThanOrEqual(rect.maxY, titleBarBottom + 0.5, "\(label): the line reaches into the title bar")
                    XCTAssertLessThanOrEqual(Self.height(of: line, font: font, width: rect.width), rect.height + 1,
                                             "\(label): \"\(line)\" is cut in \(rect.width) × \(rect.height) pt")
                    for (name, buttonWidth) in headerButtons(in: window) {
                        let key = "\(page)|\(name)"
                        if let wide = buttonWidths[key] {
                            XCTAssertEqual(buttonWidth, wide, accuracy: 1, "\(label): \(name) is squeezed")
                        } else {
                            buttonWidths[key] = buttonWidth
                        }
                    }
                    // The other languages get the room up to the controls on the right.
                    let room = try roomForPurpose(startingAt: rect.minX, page: page, in: window)
                    for bundle in languages {
                        let translated = expectedPurpose(page, mode: mode, in: bundle)
                        XCTAssertLessThanOrEqual(Self.height(of: translated, font: font, width: room),
                                                 Self.height(of: "A", font: font, width: room) * CGFloat(PageHeader.subtitleLines) + 1,
                                                 "\(label): \"\(translated)\" needs more than two lines in \(room) pt")
                    }
                }
            }
            window.orderOut(nil)
        }
    }

    /// The pages each mode renders: every page in Bypass, Domains again in VPN Only, Rules
    /// with its longer line in Custom.
    private static let pagesByMode: [(RoutingMode, [SettingsView.SettingsTab])] = [
        (.bypass, SettingsView.SettingsTab.allCases),
        (.vpnOnly, [.domains]),
        (.custom, [.rules]),
    ]

    private func seed(_ mode: RoutingMode) {
        var config = rm.config
        config.routingMode = mode
        if mode == .custom {
            let direct = Route(name: "Direct", egress: .direct)
            config.routes = [direct]
            config.rules = [
                Rule(matchType: .domain, pattern: "a.example.com", routeId: direct.id, order: 0),
                Rule(matchType: .suffix, pattern: "example.org", routeId: direct.id, order: 1),
            ]
            config.defaultRouteId = direct.id
        }
        rm.config = config
    }

    private func expectedPurpose(_ page: SettingsView.SettingsTab, mode: RoutingMode, in bundle: Bundle = .main) -> String {
        switch page {
        case .domains: return DomainsPage.purpose(isInverse: mode == .vpnOnly, in: bundle)
        case .rules: return RulesTab.purpose(ruleCount: mode == .custom ? rm.config.rules.count : 0, in: bundle)
        default: return page.purpose(in: bundle)
        }
    }

    /// The elements that read `line`: how many in the header band, how many in the window,
    /// and the band's one's frame in window coordinates.
    private func purposeElements(_ line: String, page: SettingsView.SettingsTab,
                                 in window: NSWindow) throws -> (inBand: Int, total: Int, frame: NSRect?) {
        SettingsPageRequest.shared.page = page
        settle(window)
        let titleBarBottom = window.contentLayoutRect.maxY
        let bandBottom = titleBarBottom - PageHeader.height
        let all = AccessibilityTree.elements(under: window) { settle(window) }
        let reading = all.filter {
            reads($0, line) && AccessibilityTree.role($0) == NSAccessibility.Role.staticText.rawValue
        }
        let inBand = reading.compactMap { element -> NSRect? in
            guard let screen = AccessibilityTree.frame(element) else { return nil }
            let rect = window.convertFromScreen(screen)
            return rect.minX >= SettingsSidebarView.width && rect.midY > bandBottom && rect.midY < titleBarBottom ? rect : nil
        }
        return (inBand.count, reading.count, inBand.first)
    }

    /// The width the purpose line may take: from where it starts to the first control on the
    /// right of the header, less the gap between them, with the search at its narrowest.
    private func roomForPurpose(startingAt x: CGFloat, page: SettingsView.SettingsTab, in window: NSWindow) throws -> CGFloat {
        let titleBarBottom = window.contentLayoutRect.maxY
        let bandBottom = titleBarBottom - PageHeader.height
        let all = AccessibilityTree.elements(under: window) { settle(window) }
        var right = window.contentLayoutRect.maxX - Theme.Space.page
        for element in all {
            guard let role = AccessibilityTree.role(element),
                  [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.textField.rawValue,
                   NSAccessibility.Role.checkBox.rawValue, NSAccessibility.Role.popUpButton.rawValue].contains(role),
                  let screen = AccessibilityTree.frame(element) else { continue }
            let rect = window.convertFromScreen(screen)
            guard rect.midY > bandBottom, rect.midY < titleBarBottom, rect.minX > x + 1 else { continue }
            right = min(right, rect.minX)
        }
        let narrower = searchFields(in: window).first.map { $0.frame.width - PageHeader.searchWidth.lowerBound } ?? 0
        return right + max(0, narrower) - Theme.Space.m - x
    }

    /// The header band's buttons on the page shown, by name, with their widths.
    private func headerButtons(in window: NSWindow) -> [(String, CGFloat)] {
        let titleBarBottom = window.contentLayoutRect.maxY
        let bandBottom = titleBarBottom - PageHeader.height
        return AccessibilityTree.elements(under: window) { settle(window) }.compactMap { element in
            guard AccessibilityTree.role(element) == NSAccessibility.Role.button.rawValue,
                  let name = AccessibilityTree.label(element), let screen = AccessibilityTree.frame(element) else { return nil }
            let rect = window.convertFromScreen(screen)
            guard rect.minX >= SettingsSidebarView.width, rect.midY > bandBottom, rect.midY < titleBarBottom else { return nil }
            return (name, rect.width)
        }
    }

    /// The height `text` needs, wrapped at `width`.
    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width + 1, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    // MARK: - The list headers

    /// The Domains list's header had the "Not resolving" chip, the ⋯ menu and "addresses"
    /// crammed together at its right end. The chip follows the list's title, the ⋯ menu sits at
    /// the trailing edge over the switches, and "addresses" ends over the number column; the
    /// Services list's header is laid out the same way.
    func testTheListHeadersPutTheChipLeftTheMenuRightAndTheLabelOverTheNumbers() throws {
        let savedRoutes = rm.activeRoutes
        defer { rm.activeRoutes = savedRoutes }
        var config = rm.config
        var stale = [DomainEntry(domain: "a.example.com"), DomainEntry(domain: "b.example.com")]
        for i in stale.indices { stale[i].resolveFailures = ResolveFailures(count: StaleEntries.threshold, since: Date()) }
        config.domains = [DomainEntry(domain: "example.org")] + stale
        config.services = [ServiceEntry(id: "custom_lab", name: "Lab", enabled: true, domains: [],
                                        ipRanges: ["203.0.113.0/24"], isCustom: true)]
        rm.config = config
        rm.activeRoutes = [
            .init(destination: "192.0.2.10", gateway: "192.168.1.1", source: "example.org", timestamp: Date()),
            .init(destination: "203.0.113.0/24", gateway: "192.168.1.1", source: "Lab", timestamp: Date()),
        ]
        let window = open(.domains)
        let domainsTitle = try XCTUnwrap(DomainsPage.sections(mode: .bypass, config: rm.config,
                                                               routeSources: rm.activeRoutes.map(\.source), search: "").first?.title)
        for (page, title, chip) in [(SettingsView.SettingsTab.domains, domainsTitle, Optional("Not resolving · 2")),
                                    (.services, ServicesPage.listTitle(), nil)] {
            SettingsPageRequest.shared.page = page
            settle(window)
            let all = AccessibilityTree.elements(under: window) { settle(window) }
            func frame(_ label: String) throws -> NSRect {
                let element = try XCTUnwrap(all.first { reads($0, label) && isInContent($0, window) },
                                            "\(page): no \(label)")
                return window.convertFromScreen(try XCTUnwrap(AccessibilityTree.frame(element)))
            }
            let titleFrame = try frame(title)
            let menu = try frame("Turn all on or off")
            let label = try frame("addresses")
            let rightEdge = window.contentLayoutRect.maxX - Theme.Space.page
            XCTAssertEqual(menu.maxX, rightEdge - ListRow.inset, accuracy: 3, "\(page): the ⋯ menu is not at the trailing edge")
            XCTAssertLessThan(label.maxX + Theme.Space.s, menu.minX, "\(page): \"addresses\" runs into the ⋯ menu")
            XCTAssertEqual(label.midY, titleFrame.midY, accuracy: 4, "\(page): the header is not one line")
            // The number column ends past the switch (44 pt) and one space, left of the menu's end.
            XCTAssertEqual(label.maxX, menu.maxX - 44 - Theme.Space.s, accuracy: 3,
                           "\(page): \"addresses\" is not over the number column")
            if let chip {
                let chipFrame = try frame(chip)
                XCTAssertLessThan(chipFrame.minX - titleFrame.maxX, Theme.Space.l, "\(page): the chip is not after the title")
                XCTAssertLessThan(chipFrame.maxX + Theme.Space.s, label.minX, "\(page): the chip runs into \"addresses\"")
            }
        }
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

    /// The element reads `text`: its label, or a static text's value.
    private func reads(_ element: NSObject, _ text: String) -> Bool {
        AccessibilityTree.label(element) == text || (AccessibilityTree.get("accessibilityValue", of: element) as? String) == text
    }

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
