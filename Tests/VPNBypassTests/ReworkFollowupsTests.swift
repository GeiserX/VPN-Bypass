// ReworkFollowupsTests.swift
// The leftovers the rework's step reviews found: every ListRow action reachable by VoiceOver
// from the row itself with its number spoken with its noun, the pages' primary actions in the
// title bar row with ⌘N on every list page, Copy on a Lookups row, the privacy note in the
// words of its buttons, a capped route chip, an undoable Duplicate, the profile in use on the
// dropdown and Status with Rename, and the greyed switch of a held-off built-in service.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class ReworkFollowupsTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var window: NSWindow?
    private var savedConfig: RouteManager.Config!
    private var savedLogs: [RouteManager.LogEntry] = []
    private var savedLastPage: String?

    override func setUp() async throws {
        savedConfig = rm.config
        savedLogs = rm.recentLogs
        savedLastPage = UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        // A route duplicate starts a reapply; it must end here, not in the next test.
        await rm.cancelConfigFollowUps()
        rm.config = savedConfig
        rm.recentLogs = savedLogs
        DNSLookupsMonitor.shared.tally = DNSLookupTally()
        DNSLookupsMonitor.shared.since = nil
        UserDefaults.standard.set(savedLastPage, forKey: SettingsSidebar.lastPageKey)
        SettingsPageRequest.shared.page = nil
    }

    // MARK: - 1. ListRow: every action and the number reach VoiceOver

    private struct RowHost: View {
        let counts: Counts
        var isSwitchDisabled = false
        var isSelected = false
        @State var isOn = true
        var onToggle: (Bool) -> Void = { _ in }

        var body: some View {
            ListRow(glyph: "globe", name: "en.wikipedia.org", detail: "Bypassed", number: "18",
                    numberWidth: ListRow.numberColumnWidth(for: ["18"]),
                    numberLabel: ListRow.addressesLabel("18"),
                    actions: [.edit("en.wikipedia.org") { counts.edits += 1 },
                              RowAction(kind: .more, name: "More actions", systemImage: "ellipsis", perform: {},
                                        menu: [.delete("en.wikipedia.org") { counts.deletes += 1 }])],
                    isOn: $isOn, isSwitchDisabled: isSwitchDisabled, isSelected: isSelected)
                .onChange(of: isOn, perform: onToggle)
                .frame(width: 480)
        }
    }

    private final class Counts { var edits = 0, deletes = 0 }

    /// Nobody hovers the row, so its buttons are drawn at opacity 0 and VoiceOver skips them.
    /// The row itself offers each one, the ⋯ menu's items included, and says its number with
    /// its noun, from ListRow, whatever page uses it.
    func testARowNobodyHoversOffersEveryActionAndSaysItsNumber() throws {
        let counts = Counts()
        let window = host(RowHost(counts: counts))
        let all = elements(in: window, client: true)
        let row = try XCTUnwrap(all.first { label($0)?.hasPrefix("en.wikipedia.org") == true },
                                "no row element: \(all.compactMap(label))")
        XCTAssertEqual(value(row), "18 addresses", "the number is read bare, or not at all")
        let actions = customActions(row)
        XCTAssertEqual(Set(actions.map(\.name)), ["Edit en.wikipedia.org", "Delete en.wikipedia.org"],
                       "VoiceOver cannot reach the row's actions")
        try run(XCTUnwrap(actions.first { $0.name == "Delete en.wikipedia.org" }))
        XCTAssertEqual(counts.deletes, 1, "the rotor's Delete does not run the row's delete")
        XCTAssertFalse(all.contains { label($0) == "18" }, "the bare number is still a stop of its own")
    }

    /// The Domains page had no workaround of its own, so its delete was out of VoiceOver's reach.
    func testTheDomainsPageDeleteIsReachableWithoutThePointer() {
        var config = rm.config
        config.routingMode = .bypass
        config.domains = [DomainEntry(domain: "probe-row.example")]
        rm.config = config
        let texts = texts(on: .domains)
        XCTAssertTrue(texts.contains("Delete probe-row.example"), "VoiceOver cannot reach the delete: \(texts.sorted())")
    }

    func testTheSpokenNumbersAreTranslated() throws {
        XCTAssertEqual(ListRow.addressesLabel("1"), "1 address")
        XCTAssertEqual(ListRow.addressesLabel("18"), "18 addresses")
        XCTAssertNil(ListRow.addressesLabel(nil))
        XCTAssertEqual(LookupRow.lookupsLabel(1), "1 lookup")
        XCTAssertEqual(LookupRow.lookupsLabel(7), "7 lookups")
        XCTAssertEqual(LookupRow.namesLabel(3), "3 names")
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            XCTAssertNotEqual(LookupRow.lookupsLabel(7, in: bundle), "7 lookups", language)
            XCTAssertNotEqual(LookupRow.namesLabel(1, in: bundle), "1 name", language)
            XCTAssertNotEqual(ControlNames.copy("x", in: bundle), "Copy x", language)
        }
    }

    // MARK: - 8. A disabled switch

    /// A held-off built-in service shows its switch, greyed: Space on the selected row and a
    /// click do nothing. The positive control is the same row with the switch enabled.
    func testADisabledSwitchIgnoresSpace() {
        for disabled in [false, true] {
            var toggles: [Bool] = []
            let window = host(RowHost(counts: Counts(), isSwitchDisabled: disabled, isSelected: true) { toggles.append($0) })
            press(" ", [], keyCode: 49, in: window)
            XCTAssertEqual(toggles, disabled ? [] : [false], "Space, disabled: \(disabled)")
            let toggle = elements(in: window, client: true).first { role($0) == NSAccessibility.Role.checkBox.rawValue }
            XCTAssertEqual(toggle.map(isEnabled), !disabled, "the switch's enabled state, disabled: \(disabled)")
            window.orderOut(nil)
        }
    }

    func testABuiltInServiceHeldOffByACustomOneHasItsSwitchGreyed() {
        let builtIn = ServiceEntry(id: "telegram", name: "Telegram", enabled: false, domains: ["telegram.org"], ipRanges: [])
        var custom = ServiceEntry(id: "custom-telegram", name: "Telegram", enabled: true, domains: ["t.me"], ipRanges: [])
        custom.isCustom = true
        let held = ServicesPage.rows([builtIn, custom], mode: .bypass, routeSources: [], added: { _ in [] },
                                     clash: { $0.isCustom ? nil : "Rename the custom Telegram to turn this one on." })
        XCTAssertTrue(held[0].isHeldOff, "the held-off built-in service can be switched")
        XCTAssertFalse(held[1].isHeldOff, "the custom service holding the name is greyed too")
        var on = builtIn
        on.enabled = true
        let switchedOn = ServicesPage.rows([on], mode: .bypass, routeSources: [], added: { _ in [] },
                                           clash: { _ in "Rename the custom Telegram to turn this one on." })
        XCTAssertFalse(switchedOn[0].isHeldOff, "a held service that is on must still turn off")
        let free = ServicesPage.rows([builtIn], mode: .bypass, routeSources: [], added: { _ in [] }, clash: { _ in nil })
        XCTAssertFalse(free[0].isHeldOff, "positive control: a service nothing holds keeps its switch")
    }

    // MARK: - 2. Title bar actions and ⌘N

    /// The page's primary actions sit in the page header band under the title bar, beside the
    /// title, not in the title bar row and not in the page under the band.
    func testPrimaryActionsSitInThePageHeader() throws {
        var config = rm.config
        config.routingMode = .custom
        config.schemaVersion = 2
        config.dnsLookupsEnabled = true
        rm.config = config
        rm.recentLogs = [RouteManager.LogEntry(timestamp: Date(), level: .info, message: "probe line")]
        for (page, names) in [(SettingsView.SettingsTab.rules, ["Add Rule"]), (.routes, ["Add Route"]),
                              (.services, ["Create Custom Service"]), (.lookups, ["Stop Watching"]),
                              (.logs, ["Copy", "Clear"])] {
            let window = open(page)
            let all = elements(in: window, client: true)
            for name in names {
                let element = try XCTUnwrap(all.first { label($0) == name || title($0) == name },
                                            "\(page): no \(name): \(all.compactMap(label))")
                let frame = try XCTUnwrap(frame(element))
                let fromTop = window.frame.maxY - frame.midY
                let titleBar = window.frame.height - window.contentLayoutRect.height
                XCTAssertGreaterThan(fromTop, titleBar, "\(page): \(name) sits \(fromTop) pt under the window's top, in the title bar")
                XCTAssertLessThan(fromTop, titleBar + PageHeader.height,
                                  "\(page): \(name) sits \(fromTop) pt under the window's top, in the page")
            }
            window.orderOut(nil)
        }
    }

    /// ⌘N runs the page's add: the sheet on Rules, Routes and Services, the field on Domains.
    /// On a page of another mode it does nothing, as the page's own controls do nothing.
    private func assertCommandNOpensASheet(on page: SettingsView.SettingsTab, in mode: RoutingMode) {
        var config = rm.config
        config.routingMode = mode
        config.schemaVersion = 2
        rm.config = config
        let window = open(page)
        XCTAssertNil(window.attachedSheet, "\(page): a sheet before ⌘N")
        XCTAssertTrue(press("n", .command, keyCode: 45, in: window), "\(page): ⌘N was not handled")
        XCTAssertNotNil(window.attachedSheet, "\(page): ⌘N opened no sheet")
        if let sheet = window.attachedSheet {
            press("\u{1b}", [], keyCode: 53, in: sheet)
        }
    }

    func testCommandNAddsARule() { assertCommandNOpensASheet(on: .rules, in: .custom) }
    func testCommandNAddsARoute() { assertCommandNOpensASheet(on: .routes, in: .custom) }
    func testCommandNCreatesAService() { assertCommandNOpensASheet(on: .services, in: .bypass) }

    func testCommandNFocusesTheDomainsFieldAndNothingOnAReadOnlyPage() throws {
        var config = rm.config
        // Rules is read-only in Bypass: its + and ⌘N are greyed with the page.
        config.routingMode = .bypass
        rm.config = config
        let readOnly = open(.rules)
        press("n", .command, keyCode: 45, in: readOnly)
        XCTAssertNil(readOnly.attachedSheet, "⌘N added a rule on a read-only page")
        readOnly.orderOut(nil)

        let domains = open(.domains)
        domains.makeFirstResponder(nil)
        XCTAssertFalse(domains.firstResponder is NSText, "control: nothing is focused before ⌘N")
        XCTAssertTrue(press("n", .command, keyCode: 45, in: domains), "Domains: ⌘N was not handled")
        XCTAssertTrue(domains.firstResponder is NSText, "Domains: ⌘N left the focus on \(String(describing: domains.firstResponder))")
    }

    func testTheWatchingActionTurnsThePageTheOtherWay() throws {
        XCTAssertEqual(LookupsTab.watchingAction(isOn: true) {}.name, "Stop Watching")
        XCTAssertEqual(LookupsTab.watchingAction(isOn: false) {}.name, "Start Watching")
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            XCTAssertNotEqual(LookupsTab.watchingAction(isOn: false, in: bundle) {}.help,
                              LookupsTab.watchingAction(isOn: false) {}.help, language)
        }
    }

    // MARK: - 3 and 4. Lookups: Copy, and the privacy note's words

    func testALookupRowOffersCopyAndThePrivacyNoteSaysStartAndStopWatching() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vpnb-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let copy = LookupRow.copyAction("copy-probe.example", pasteboard: pasteboard)
        XCTAssertEqual(copy.name, "Copy copy-probe.example")
        copy.perform()
        XCTAssertEqual(pasteboard.string(forType: .string), "copy-probe.example")

        var config = rm.config
        config.routingMode = .bypass
        config.dnsLookupsEnabled = true
        rm.config = config
        var tally = DNSLookupTally()
        tally.record(["copy-probe.example"], at: Date())
        DNSLookupsMonitor.shared.tally = tally
        DNSLookupsMonitor.shared.since = Date()
        let texts = texts(on: .lookups)
        XCTAssertTrue(texts.contains("Copy copy-probe.example"), "the row offers no Copy: \(texts.sorted())")
        XCTAssertTrue(texts.contains("1 lookup"), "the count is not read with its noun")
        XCTAssertTrue(texts.contains { $0.hasPrefix("Off until you start watching.") && $0.contains("when you stop watching or quit") },
                      "the privacy note does not use the buttons' words")
    }

    // MARK: - 5. A long route name truncates in the chip

    func testALongRouteNameDoesNotWidenTheRuleChip() {
        var config = rm.config
        let long = Route(name: String(repeating: "office proxy through the second building ", count: 3), egress: .proxySOCKS5,
                         proxyHost: "198.51.100.7", proxyPort: 1080)
        let short = Route(name: "Direct", egress: .direct)
        config.routes = [short, long]
        rm.config = config
        func width(_ route: Route, offered: CGFloat) -> CGFloat {
            let chip = RulesRouteChipMenu(selectedRouteId: route.id, rowName: "x.example", onSelect: { _ in }, onNewRoute: {})
                .environmentObject(rm)
            return NSHostingController(rootView: chip).sizeThatFits(in: CGSize(width: offered, height: 100)).width
        }
        XCTAssertLessThanOrEqual(width(long, offered: 1000), RouteChip.rowMaxWidth, "the chip keeps the long name's full width")
        XCTAssertLessThanOrEqual(width(long, offered: 120), 120, "the chip runs past a narrow width")
        let direct = width(short, offered: 1000)
        XCTAssertLessThan(direct, 120, "a short chip stretches to the cap")
        XCTAssertGreaterThan(direct, 40, "a short chip collapsed")
    }

    // MARK: - 6. Duplicate leaves an undo line

    func testDuplicateIsUndoneLikeADelete() throws {
        var config = rm.config
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        config.routes = [Route(name: "Direct", egress: .direct), proxy]
        config.routingMode = .custom
        config.schemaVersion = 2
        rm.config = config
        let copy = try XCTUnwrap(rm.duplicateRoute(proxy.id))
        let change = UndoableChange.routeDuplicated(copy, original: proxy.name)
        XCTAssertEqual(change.page, .routes)
        XCTAssertEqual(change.message, "Duplicated office-proxy as office-proxy copy.")
        XCTAssertNotEqual(change.message(in: try lproj("es")), change.message)
        XCTAssertNotEqual(change.message(in: try lproj("fr")), change.message)
        XCTAssertTrue(rm.undo(change))
        XCTAssertEqual(rm.config.routes.map(\.id), config.routes.map(\.id), "the copy is still listed")
        XCTAssertFalse(rm.undo(change), "a second undo removed something")
    }

    /// Undo of a Duplicate removes the copy by id, so editing the copy drops the line; an edit
    /// of another route keeps it.
    func testEditingTheCopyDropsTheDuplicateLine() {
        let copy = Route(name: "office-proxy copy", egress: .direct)
        let undo = SettingsUndo(routeManager: rm)
        undo.record(.routeDuplicated(copy, original: "office-proxy"))
        undo.routeSaved(UUID())
        XCTAssertNotNil(undo.last, "an edit of another route dropped the line")
        undo.routeSaved(copy.id)
        XCTAssertNil(undo.last, "Undo would still throw away the edited copy")
    }

    /// An Undo of a Duplicate that waits for a route operation is cancelled by an edit of the
    /// copy meanwhile; without the edit it goes through once the gate frees (the control).
    func testEditingTheCopyCancelsAWaitingDuplicateUndo() throws {
        for edits in [false, true] {
            var config = rm.config
            config.routes = [Route(name: "Direct", egress: .direct), Route(name: "wait-probe", egress: .direct)]
            config.routingMode = .custom
            config.schemaVersion = 2
            rm.config = config
            let copy = try XCTUnwrap(rm.duplicateRoute(config.routes[1].id))
            let undo = SettingsUndo(routeManager: rm)
            undo.gateWaitPolls = 20
            undo.record(.routeDuplicated(copy, original: "wait-probe"))
            XCTAssertTrue(rm.tryAcquireRouteOperationForTests())
            undo.undoLast()
            if edits { undo.routeSaved(copy.id) }
            rm.releaseRouteOperationForTests()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            XCTAssertEqual(rm.config.routes.contains { $0.id == copy.id }, edits,
                           edits ? "the waiting undo removed the edited copy" : "the waiting undo never ran")
        }
    }

    /// A stored name with spaces around it still takes its name.
    func testAStoredNameWithSpacesIsTaken() {
        let padded = profile("Home ")
        XCTAssertFalse(NetworkProfiles.nameIsFree("home", in: [padded, profile("Office")]))
        XCTAssertTrue(NetworkProfiles.nameIsFree("home", in: [padded], excluding: padded.id))
    }

    /// The Routes page's Duplicate, run from the rotor, leaves the line that says what it did
    /// (the line every undoable change leaves, with its Undo).
    func testTheRoutesPageDuplicateLeavesItsLine() throws {
        var config = rm.config
        let proxy = Route(name: "dup-probe", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        config.routes = [Route(name: "Direct", egress: .direct), proxy]
        config.routingMode = .custom
        config.schemaVersion = 2
        rm.config = config
        let window = open(.routes)
        let duplicate = try XCTUnwrap(elements(in: window, client: true).flatMap(customActions).first { $0.name == "Duplicate dup-probe" },
                                      "no Duplicate in the rotor")
        try run(duplicate)
        settle(window)
        let texts = Set(elements(in: window, client: true).flatMap { [label($0), title($0), value($0)].compactMap { $0 } })
        XCTAssertTrue(texts.contains { $0.contains("Duplicated dup-probe as dup-probe copy.") }, "no confirmation line: \(texts.sorted())")
    }

    // MARK: - 7. The profile in use, and Rename

    private func profile(_ name: String) -> NetworkProfile {
        NetworkProfile(id: UUID(), name: name, networks: [], settings: ProfileSettings(capturing: rm.config))
    }

    func testTheProfileInUseIsNamedOnlyOnceAProfileExists() {
        var config = rm.config
        config.profiles = []
        config.activeProfileId = nil
        XCTAssertNil(NetworkProfiles.inUseName(config), "no profile, nothing to tell apart")
        let home = profile("Home")
        config.profiles = [home]
        XCTAssertEqual(NetworkProfiles.inUseName(config), "Other networks")
        config.activeProfileId = home.id
        XCTAssertEqual(NetworkProfiles.inUseName(config), "Home")
        XCTAssertEqual(NetworkProfiles.inUseLine("Home"), "Profile: Home")
    }

    func testAProfileIsRenamedAndKeepsEverythingElse() {
        var config = rm.config
        let home = profile("Home"), office = profile("Office")
        config.profiles = [home, office]
        config.activeProfileId = home.id
        let renamed = NetworkProfiles.renaming(home.id, to: "  Casa ", in: config)
        XCTAssertEqual(renamed.profiles.map(\.name), ["Casa", "Office"])
        XCTAssertEqual(renamed.activeProfileId, home.id)
        XCTAssertEqual(renamed.profiles[0].settings, home.settings)
        XCTAssertEqual(NetworkProfiles.renaming(home.id, to: "office", in: config).profiles.map(\.name), ["Home", "Office"],
                       "renamed onto a taken name")
        XCTAssertEqual(NetworkProfiles.renaming(home.id, to: "HOME", in: config).profiles.map(\.name), ["HOME", "Office"],
                       "its own name in another case is free")
        XCTAssertEqual(NetworkProfiles.renaming(home.id, to: "Other networks", in: config).profiles.map(\.name), ["Home", "Office"])
        XCTAssertFalse(NewProfileSheet.canSave("Home", profiles: config.profiles, renaming: home, networkKnown: true),
                       "Rename offered for the name it already has")
        XCTAssertTrue(NewProfileSheet.canSave("Casa", profiles: config.profiles, renaming: home, networkKnown: false),
                      "a rename needs no identified network")
        rm.config = config
        XCTAssertTrue(rm.renameProfile(office.id, to: "Oficina"))
        XCTAssertEqual(rm.config.profiles.map(\.name), ["Home", "Oficina"])
        XCTAssertFalse(rm.renameProfile(office.id, to: "home"))
    }

    func testTheDropdownAndStatusNameTheProfileInUse() throws {
        let status = DropdownStatus(chip: .on, tone: .ok, headline: "WireGuard connected", sentence: "Routing.",
                                    note: nil, line3: .blank)
        for profile in [nil, "Office"] as [String?] {
            let window = host(StatusBlock(status: status, profile: profile) { _ in }.frame(width: 340))
            let labels = elements(in: window, client: true).flatMap { [label($0), value($0)].compactMap { $0 } }
            XCTAssertEqual(labels.contains("Profile: Office"), profile != nil, "dropdown, profile \(String(describing: profile)): \(labels)")
            window.orderOut(nil)
        }
        var config = rm.config
        let home = profile("Home")
        config.profiles = [home]
        config.activeProfileId = home.id
        rm.config = config
        let texts = texts(on: .status)
        XCTAssertTrue(texts.contains { $0.contains("Profile") && $0.contains("Home") }, "Status does not name the profile: \(texts.sorted())")
    }

    func testTheProfileWordsAreTranslated() throws {
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            XCTAssertNotEqual(NetworkProfiles.inUseLine("Home", in: bundle), "Profile: Home", language)
            XCTAssertNotEqual(NetworkProfiles.renameName("Home", in: bundle), "Rename Home", language)
        }
    }

    // MARK: - Helpers

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 520, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.environmentObject(rm))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        settle(window)
        return window
    }

    private func open(_ page: SettingsView.SettingsTab) -> NSWindow {
        SettingsPageRequest.shared.page = page
        let window = SettingsWindowController.makeWindow()
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        settle(window)
        XCTAssertEqual(window.title, page.name)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @discardableResult
    private func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        let handled = window.performKeyEquivalent(with: event)
        settle(window)
        return handled
    }

    private func get(_ name: String, of element: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }

    private func label(_ object: NSObject) -> String? { (get("accessibilityLabel", of: object) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private func title(_ object: NSObject) -> String? { (get("accessibilityTitle", of: object) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private func value(_ object: NSObject) -> String? { get("accessibilityValue", of: object) as? String }
    private func role(_ object: NSObject) -> String? { get("accessibilityRole", of: object) as? String }
    private func frame(_ object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }
    private func isEnabled(_ object: NSObject) -> Bool {
        guard object.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return true }
        return (object.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? true
    }
    private func customActions(_ object: NSObject) -> [NSAccessibilityCustomAction] {
        get("accessibilityCustomActions", of: object) as? [NSAccessibilityCustomAction] ?? []
    }

    private func run(_ action: NSAccessibilityCustomAction) throws {
        if let handler = action.handler {
            _ = handler()
        } else if let target = action.target as? NSObject, let selector = action.selector {
            _ = target.perform(selector, with: action)
        } else {
            XCTFail("the action \(action.name) runs nothing")
        }
        window.map(settle)
    }

    /// Every element in the window, found with an accessibility client switched on, the way
    /// VoiceOver finds them (as in SettingsShellTests).
    private func elements(in window: NSWindow, client: Bool) -> [NSObject] {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasClient = (NSApplication.shared.accessibilityAttributeValue(attribute) as? Bool) ?? false
        NSApplication.shared.accessibilitySetValue(client, forAttribute: attribute)
        defer { NSApplication.shared.accessibilitySetValue(wasClient, forAttribute: attribute) }
        settle(window)
        var found: [NSObject] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 80, let object = element as? NSObject else { return }
            found.append(object)
            (get("accessibilityChildren", of: object) as? [Any] ?? []).forEach { walk($0, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }

    /// Every label, title, value and rotor action name on the page.
    private func texts(on page: SettingsView.SettingsTab) -> Set<String> {
        let window = open(page)
        var found = Set<String>()
        for element in elements(in: window, client: true) {
            for text in [label(element), title(element), value(element)].compactMap({ $0 }) where !text.isEmpty {
                found.insert(text)
            }
            customActions(element).forEach { found.insert($0.name) }
        }
        return found
    }
}
