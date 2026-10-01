// DropdownModePickerTests.swift
// The dropdown's Mode control (proposal 12): one segmented control with Bypass, VPN Only and
// Custom in every mode, behind a confirmation.
//
// The problems it locks down: the old control showed only Bypass and VPN Only, and in Custom
// mode a capsule plus a "Switch to Bypass" link, so Custom could not be picked from the
// dropdown and VPN Only was out of reach from Custom. A pick must not switch anything until the
// user confirms, and the segment must not move on Cancel.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

final class DropdownModePickerTests: XCTestCase {

    func testAllThreeModesInOrder() {
        XCTAssertEqual(DropdownModePicker.modes, [.bypass, .vpnOnly, .custom])
        XCTAssertEqual(DropdownModePicker.modes.map(DropdownModePicker.label), ["Bypass", "VPN Only", "Custom"])
    }

    /// Every mode is one pick from the other two, and picking the mode in use asks nothing.
    func testAPickAsksOnlyForADifferentMode() {
        for current in DropdownModePicker.modes {
            for picked in DropdownModePicker.modes {
                XCTAssertEqual(DropdownModePicker.pendingSwitch(picked: picked, current: current),
                               picked == current ? nil : picked, "\(current) -> \(picked)")
            }
        }
    }

    /// The question's English wording.
    func testConfirmationWording() {
        XCTAssertEqual(DropdownModePicker.confirmationTitle, "Switch routing mode?")
        let bypass = DropdownModePicker.confirmation(to: .bypass, schemaVersion: 2)
        XCTAssertEqual(bypass.confirm, "Switch to Bypass")
        XCTAssertEqual(bypass.message, "Everything will go through your VPN except the sites you list. Your custom routes stay saved.")
        let vpnOnly = DropdownModePicker.confirmation(to: .vpnOnly, schemaVersion: 2)
        XCTAssertEqual(vpnOnly.confirm, "Switch to VPN Only")
        XCTAssertEqual(vpnOnly.message, "Only the sites you list will use your VPN; everything else goes direct.")
        // First entry into Custom says the lists become rules; a later one does not.
        let firstCustom = DropdownModePicker.confirmation(to: .custom, schemaVersion: 1)
        XCTAssertEqual(firstCustom.confirm, "Switch to Custom Routes")
        XCTAssertTrue(firstCustom.message.hasPrefix("Your listed domains and services become editable rules"))
        XCTAssertEqual(DropdownModePicker.confirmation(to: .custom, schemaVersion: 2).message,
                       "Switch to your per-rule custom routing. You can switch back to a simple mode anytime.")
    }

    /// The tooltip carries the line the old Mode fact showed.
    func testTooltipDescribesTheSavedMode() {
        XCTAssertEqual(DropdownStatus.modeDescription(DropdownModePicker.copyMode(.bypass)), "Bypass: everything else uses the VPN")
        XCTAssertEqual(DropdownStatus.modeDescription(DropdownModePicker.copyMode(.vpnOnly)), "VPN Only: everything else goes direct")
        XCTAssertEqual(DropdownStatus.modeDescription(DropdownModePicker.copyMode(.custom)), "Custom: the first matching rule decides")
    }
}

/// The real DropdownModeRow in a window, and the real question: a click on a segment opens it
/// and switches nothing while it is open; Cancel leaves the segment where it was; Switch runs
/// RouteManager.setRoutingMode, the call the Settings switch makes, so entering Custom migrates
/// the lists into rules. The question runs app-modal, so a timer in the modal run loop reads it
/// and presses one of its buttons. The VPN is never connected here, so no route is touched, and
/// the config is restored after each test.
@MainActor
final class DropdownModeRowViewTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedVPNConnected = false
    private var window: NSWindow?

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() async throws {
        savedConfig = rm.config
        savedVPNConnected = rm.isVPNConnected
        rm.isVPNConnected = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.schemaVersion = 1
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "a.com")]
        cfg.services = []
        cfg.inverseDomains = []
        cfg.routes = []
        cfg.rules = []
        cfg.defaultRouteId = nil
        rm.config = cfg
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        rm.config = savedConfig
        rm.isVPNConnected = savedVPNConnected
    }

    private func host() -> NSView {
        let view = NSHostingView(rootView: DropdownModeRow().environmentObject(rm).frame(width: 308))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        self.window = window
        settle(view)
        return view
    }

    private func settle(_ view: NSView) {
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    private func segmented(in view: NSView) throws -> NSSegmentedControl {
        let found = Self.all(NSSegmentedControl.self, in: view)
        XCTAssertEqual(found.count, 1, "one segmented control")
        return try XCTUnwrap(found.first)
    }

    /// What the open question showed, read from inside its modal run loop.
    private struct Question {
        var title = "", message = "", buttons: [String] = []
        var iconName: String?, iconHidden = true
        var isSheet = true
        var segmentWhileOpen: Int?
        /// Whether a DispatchQueue.main block and a main-actor task queued after the click had
        /// run by the time the open question was read.
        var mainQueueRanWhileOpen = false, mainActorRanWhileOpen = false
    }

    /// Clicks a segment the way AppKit delivers it (the control selects the segment, then fires
    /// its action), then answers the question with `answer`, a button title. Returns nil when no
    /// question opened.
    private func pick(segment: Int, answer: String, in view: NSView) throws -> Question? {
        let control = try segmented(in: view)
        final class Seen: @unchecked Sendable { var question: Question?; var queueRan = false; var taskRan = false }
        let seen = Seen()
        let all = { (type: NSView.Type, root: NSView) in Self.all(NSView.self, in: root).filter { $0.isKind(of: type) } }
        let reader = Timer(timeInterval: 0.3, repeats: false) { [view] _ in
            MainActor.assumeIsolated {
                guard let panel = NSApp.modalWindow, let content = panel.contentView else { return }
                var q = Question()
                let texts = all(NSTextField.self, content).compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
                q.title = texts.first ?? ""
                q.message = texts.dropFirst().first ?? ""
                let buttons = all(NSButton.self, content).compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
                q.buttons = buttons.map(\.title)
                if let icon = all(NSImageView.self, content).first as? NSImageView {
                    q.iconName = icon.image?.name()
                    q.iconHidden = icon.isHiddenOrHasHiddenAncestor
                }
                q.isSheet = panel.sheetParent != nil
                q.segmentWhileOpen = (all(NSSegmentedControl.self, view).first as? NSSegmentedControl)?.selectedSegment
                q.mainQueueRanWhileOpen = seen.queueRan
                q.mainActorRanWhileOpen = seen.taskRan
                seen.question = q
                if let button = buttons.first(where: { $0.title == answer }) { button.performClick(nil) }
                else { NSApp.abortModal() }
            }
        }
        // Never hang the suite: a question nobody answered is closed after 5 s.
        let guardTimer = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        }
        RunLoop.main.add(reader, forMode: .modalPanel)
        RunLoop.main.add(guardTimer, forMode: .modalPanel)
        defer { reader.invalidate(); guardTimer.invalidate() }

        control.selectedSegment = segment
        XCTAssertTrue(control.sendAction(control.action, to: control.target), "the control has an action")
        // Queued behind whatever the click queued, the way RouteManager's and the control
        // socket's work reaches the main thread.
        DispatchQueue.main.async { seen.queueRan = true }
        Task { @MainActor in seen.taskRan = true }
        settle(view)
        return seen.question
    }

    func testTheControlListsAllThreeModesInEveryMode() throws {
        for mode in DropdownModePicker.modes {
            var cfg = rm.config
            cfg.routingMode = mode
            rm.config = cfg
            let control = try segmented(in: host())
            XCTAssertEqual(control.segmentCount, 3, "\(mode)")
            XCTAssertEqual((0..<3).map { control.label(forSegment: $0) }, ["Bypass", "VPN Only", "Custom"], "\(mode)")
            XCTAssertEqual(control.selectedSegment, DropdownModePicker.modes.firstIndex(of: mode), "\(mode)")
            window?.orderOut(nil)
        }
    }

    func testCancelLeavesTheModeAndTheSegment() throws {
        let view = host()
        let q = try XCTUnwrap(try pick(segment: 1, answer: "Cancel", in: view), "the question opened")
        XCTAssertEqual(q.title, "Switch routing mode?")
        XCTAssertEqual(q.message, "Only the sites you list will use your VPN; everything else goes direct.")
        XCTAssertEqual(q.buttons, ["Switch to VPN Only", "Cancel"])
        XCTAssertEqual(q.segmentWhileOpen, 0, "the segment waits for the answer")
        XCTAssertEqual(rm.config.routingMode, .bypass, "Cancel switches nothing")
        XCTAssertEqual(try segmented(in: view).selectedSegment, 0, "Cancel leaves Bypass selected")
    }

    /// Entering Custom from the dropdown runs the migration the Settings switch runs.
    func testSwitchToCustomMigratesTheListsAndMovesTheSegment() throws {
        let view = host()
        let q = try XCTUnwrap(try pick(segment: 2, answer: "Switch to Custom Routes", in: view))
        XCTAssertEqual(q.segmentWhileOpen, 0)
        XCTAssertEqual(rm.config.routingMode, .custom)
        XCTAssertEqual(rm.config.schemaVersion, 2, "the Custom migration ran")
        XCTAssertTrue(rm.config.rules.contains { $0.pattern == "a.com" }, "the Bypass domain became a rule")
        XCTAssertEqual(try segmented(in: view).selectedSegment, 2)
    }

    /// The question shows the app's own icon: the image named NSApplicationIcon, which in the
    /// app bundle is AppIcon.icns (the Lanes mark), not an image set in code. It must not be a
    /// sheet, because macOS 26 hides the icon of an alert shown as a sheet.
    func testTheQuestionShowsTheAppIcon() throws {
        let q = try XCTUnwrap(try pick(segment: 1, answer: "Cancel", in: host()))
        XCTAssertFalse(q.isSheet, "a standalone alert, not a sheet")
        XCTAssertEqual(q.iconName, NSImage.applicationIconName, "the icon is the app icon")
        XCTAssertFalse(q.iconHidden, "the icon is shown")
    }

    /// The open question must not hold the main queue: RouteManager, network-change handling
    /// and the control socket all run there, and `vpnb status` times out if it stops.
    func testTheAppKeepsRunningWhileTheQuestionIsOpen() throws {
        let q = try XCTUnwrap(try pick(segment: 1, answer: "Cancel", in: host()))
        XCTAssertTrue(q.mainQueueRanWhileOpen, "a main-queue block runs while the question is open")
        XCTAssertTrue(q.mainActorRanWhileOpen, "a main-actor task runs while the question is open")
    }

    func testPickingTheModeInUseAsksNothing() throws {
        XCTAssertNil(try pick(segment: 0, answer: "Cancel", in: host()))
        XCTAssertEqual(rm.config.routingMode, .bypass)
    }
}
