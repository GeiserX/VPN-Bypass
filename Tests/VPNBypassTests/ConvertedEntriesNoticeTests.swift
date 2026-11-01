// ConvertedEntriesNoticeTests.swift
// A launch that rewrote entries saved as ".example.com" says which, once: a note on Status
// until dismissed, one notification, and the list in `vpnb status`.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class ConvertedEntriesNoticeTests: RouteManagerTestCase {

    private var notified: [[ConvertedEntry]] = []
    private var savedNotify: (@MainActor ([ConvertedEntry]) -> Void)?

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: rm.convertedEntriesURL)
        rm.dismissConvertedEntries()
        notified = []
        savedNotify = rm.notifyConvertedEntries
        rm.notifyConvertedEntries = { [weak self] in self?.notified.append($0) }
    }

    override func tearDown() {
        rm.dismissConvertedEntries()
        if let savedNotify { rm.notifyConvertedEntries = savedNotify }
        super.tearDown()
    }

    private func writeConfig(domains: [DomainEntry]) throws {
        var cfg = RouteManager.Config()
        cfg.domains = domains
        try JSONEncoder().encode(cfg).write(to: configURL)
    }

    private let changes = [ConvertedEntry(from: ".example.net", to: "*.example.net"),
                           ConvertedEntry(from: ".example.org", to: "*.example.org")]

    func testALaunchThatConvertsListsThemAndNotifiesOnce() throws {
        try writeConfig(domains: [DomainEntry(domain: ".example.net"), DomainEntry(domain: "keep.example.com"),
                                  DomainEntry(domain: ".example.org", enabled: false)])
        rm.loadConfig()
        XCTAssertEqual(rm.convertedEntries, changes)
        XCTAssertEqual(notified, [changes], "one notification, naming both")

        // Relaunch before the note is dismissed: it is still there, and nothing is sent again.
        rm.loadConfig()
        XCTAssertEqual(rm.convertedEntries, changes, "the note outlives a relaunch")
        XCTAssertEqual(notified.count, 1)

        // Dismissed, it is gone, and the next launch does not bring it back.
        rm.dismissConvertedEntries()
        XCTAssertEqual(rm.convertedEntries, [])
        rm.loadConfig()
        XCTAssertEqual(rm.convertedEntries, [])
        XCTAssertEqual(notified.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rm.convertedEntriesURL.path))
    }

    func testNothingConvertedShowsNothing() throws {
        try writeConfig(domains: [DomainEntry(domain: "example.net"), DomainEntry(domain: "*.example.org")])
        rm.loadConfig()
        XCTAssertEqual(rm.convertedEntries, [])
        XCTAssertEqual(notified.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rm.convertedEntriesURL.path))
    }

    /// An import that converts adds to the note, without a notification: the user is in the app.
    func testAnImportThatConvertsAddsToTheNote() throws {
        var cfg = RouteManager.Config()
        cfg.domains = [DomainEntry(domain: ".example.org")]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("converted-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let connected = rm.isVPNConnected
        rm.isVPNConnected = false   // no apply after the import
        defer { rm.isVPNConnected = connected }
        try JSONEncoder().encode(RouteManager.ExportData(version: "2.0", exportDate: Date(), config: cfg)).write(to: file)
        XCTAssertTrue(rm.importConfig(from: file))
        XCTAssertEqual(rm.convertedEntries, [changes[1]])
        XCTAssertEqual(notified.count, 0)
    }

    func testStatusCarriesTheListUntilDismissed() async throws {
        rm.recordConvertedEntries([".example.net", ".example.org"])
        let listed = await ControlSurface.handle(ControlRequest(cmd: "status"))
        XCTAssertEqual(listed.result?.runtime?.convertedEntries, changes)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(listed), encoding: .utf8))
        XCTAssertTrue(json.contains(#""convertedEntries":[{"#), json)
        XCTAssertTrue(VPNBCLI.textLines(listed).contains(
            "updated to wildcards: .example.net is now *.example.net, .example.org is now *.example.org"))

        rm.dismissConvertedEntries()
        let none = await ControlSurface.handle(ControlRequest(cmd: "status"))
        XCTAssertNil(none.result?.runtime?.convertedEntries, "omitted once dismissed")
        XCTAssertFalse(VPNBCLI.textLines(none).contains { $0.hasPrefix("updated to wildcards") })
    }

    func testTheSentenceInEachLanguage() throws {
        let one = [changes[0]]
        XCTAssertEqual(ConvertedEntry.sentence(changes, bundle: try ReworkSource.lproj("en")),
                       "Updated 2 entries to the new wildcard form: .example.net is now *.example.net, .example.org is now *.example.org. They route the same names as before.")
        XCTAssertEqual(ConvertedEntry.sentence(one, bundle: try ReworkSource.lproj("en")),
                       "Updated 1 entry to the new wildcard form: .example.net is now *.example.net. It routes the same names as before.")
        XCTAssertEqual(ConvertedEntry.sentence(one, bundle: try ReworkSource.lproj("es")),
                       "Se ha actualizado 1 entrada a la nueva forma de comodín: .example.net ahora es *.example.net. Enruta los mismos nombres que antes.")
        XCTAssertEqual(ConvertedEntry.sentence(changes, bundle: try ReworkSource.lproj("fr")),
                       "2 entrées sont passées au nouveau format joker : .example.net devient *.example.net, .example.org devient *.example.org. Elles routent les mêmes noms qu'avant.")
    }

    /// The note is on Status with a Dismiss VoiceOver can name, and goes when dismissed.
    func testStatusShowsTheNoteWithANamedDismiss() throws {
        let label = "Dismiss the note about updated entries"
        rm.recordConvertedEntries([".example.net"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: StatusTab(snapshot: RouteManager.CoexistenceSnapshot(
            links: [], selectedInterface: nil, defaultRouteInterface: nil, taggedDestinations: []))
            .environmentObject(rm).frame(width: 560))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(hasElement(labelled: label, in: window))

        rm.dismissConvertedEntries()
        XCTAssertFalse(hasElement(labelled: label, in: window), "gone once dismissed")
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Found the way VoiceOver finds it, as in SettingsShellTests.
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
}
