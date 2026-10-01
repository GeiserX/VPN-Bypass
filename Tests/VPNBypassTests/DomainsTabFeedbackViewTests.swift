// DomainsTabFeedbackViewTests.swift
// The real DomainsTab, hosted in a window: the line under the add field goes away when
// the list changes under a refusal, and stays after a saved add. The VPN is never
// connected here and the config is restored after each test, as in AddDomainOutcomeTests.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class DomainsTabFeedbackViewTests: XCTestCase {

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
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "x.com"), DomainEntry(domain: "y.com")]
        cfg.inverseDomains = []
        rm.config = cfg
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        rm.config = savedConfig
        rm.isVPNConnected = savedVPNConnected
    }

    private func host(_ feedback: AddDomainFeedback) -> NSView {
        let view = NSHostingView(rootView: DomainsTab(newDomain: feedback.fieldText, feedback: feedback).environmentObject(rm).environmentObject(SettingsUndo()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        self.window = window
        settle(view)
        return view
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Whether the line is under the field. SwiftUI builds no accessibility tree for a view
    /// nobody inspects, so compare the height with the same tab, same list and same text
    /// but no line. The line and its spacing add about 24 points; a relayout can leave a
    /// point of rounding, hence the margin.
    private func showsLine(_ view: NSView, fieldText: String) -> Bool {
        let bare = NSHostingView(rootView: DomainsTab(newDomain: fieldText).environmentObject(rm).environmentObject(SettingsUndo()))
        settle(bare)
        return view.fittingSize.height - bare.fittingSize.height > 12
    }

    func testARefusalGoesAwayWhenTheListChanges() {
        let refusal = AddDomainFeedback(.failure(.alreadyListed(value: "x.com", list: .bypass)), typed: "x.com")
        let view = host(refusal)
        XCTAssertTrue(showsLine(view, fieldText: "x.com"), "control: the line is on screen before the change")

        rm.config.domains.removeAll { $0.domain == "x.com" }
        settle(view)
        XCTAssertFalse(showsLine(view, fieldText: "x.com"), "x.com is no longer on the list, so the line is untrue")
    }

    func testASavedLineStaysWhenTheListChanges() {
        let saved = AddDomainFeedback(.success(AddedDomain(entry: DomainEntry(domain: "x.com"), list: .bypass, typed: "x.com")),
                                      typed: "x.com")
        let view = host(saved)
        XCTAssertTrue(showsLine(view, fieldText: ""))

        rm.config.domains.removeAll { $0.domain == "y.com" }
        settle(view)
        XCTAssertTrue(showsLine(view, fieldText: ""), "a saved add changes the list itself, so its line must survive a change")
    }
}
