// FrontTabTests.swift
// Idea 3 of the 6.0 rework: bypass the site open in the front browser tab. No test sends an
// Apple Event: the host parsing, the browser detection, the permission mapping, the row and
// the signing setup are checked offline.

import AppKit
import CoreServices
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class FrontTabTests: XCTestCase {

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    nonisolated private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func lproj(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(url: Self.root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    // MARK: - The host

    func testAPageAddressGivesItsHost() {
        XCTAssertEqual(FrontTabHost.host(fromURL: "https://shop.example.com/cart?id=4#top"), "shop.example.com")
        XCTAssertEqual(FrontTabHost.host(fromURL: "http://example.com"), "example.com")
        XCTAssertEqual(FrontTabHost.host(fromURL: "HTTPS://Shop.Example.COM/"), "shop.example.com")
        XCTAssertEqual(FrontTabHost.host(fromURL: "https://user:pw@shop.example.com:8443/a"), "shop.example.com")
        XCTAssertEqual(FrontTabHost.host(fromURL: "https://shop.example.com./"), "shop.example.com")
        XCTAssertEqual(FrontTabHost.host(fromURL: "  https://xn--bcher-kva.example/  "), "xn--bcher-kva.example")
        XCTAssertEqual(FrontTabHost.host(fromURL: "https://198.51.100.7/"), "198.51.100.7")
    }

    func testPagesThatAreNotASiteGiveNothing() {
        for url in [nil, "", "   ", "about:blank", "chrome://newtab/", "edge://settings", "safari-resource:/x",
                    "file:///Users/me/a.html", "data:text/html,hi", "ftp://files.example.com/",
                    "http://localhost:3000/", "http://app.localhost/", "http://[::1]:8080/",
                    "https://[2001:db8::1]/", "http://intranet/", "not a url", "https:///path"] {
            XCTAssertNil(FrontTabHost.host(fromURL: url), "\(url ?? "nil") is not a site to add")
        }
    }

    // MARK: - The browser

    func testSafariAndTheChromiumBrowsersAreRead() {
        XCTAssertEqual(FrontTabBrowser.family(forBundleID: "com.apple.Safari"), .safari)
        XCTAssertEqual(FrontTabBrowser.family(forBundleID: "com.apple.SafariTechnologyPreview"), .safari)
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser",
                   "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser"] {
            XCTAssertEqual(FrontTabBrowser.family(forBundleID: id), .chromium, id)
        }
    }

    func testFirefoxThisAppAndOtherAppsAreNot() {
        for id in [nil, "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
                   "com.geiserx.vpn-bypass", "com.apple.finder", "com.apple.Terminal", "", "com.apple.safari"] {
            XCTAssertNil(FrontTabBrowser.family(forBundleID: id), id ?? "nil")
            XCTAssertNil(FrontTabBrowser.detect(bundleID: id, name: "X"), id ?? "nil")
        }
    }

    func testTheBrowserIsShownByItsOwnName() throws {
        let chrome = try XCTUnwrap(FrontTabBrowser.detect(bundleID: "com.google.Chrome", name: "Google Chrome"))
        XCTAssertEqual(chrome.name, "Google Chrome")
        XCTAssertEqual(chrome.family, .chromium)
        // No name from the system: the bundle id, never an empty label.
        XCTAssertEqual(FrontTabBrowser.detect(bundleID: "com.apple.Safari", name: "")?.name, "com.apple.Safari")
        XCTAssertEqual(FrontTabBrowser.detect(bundleID: "com.apple.Safari", name: nil)?.name, "com.apple.Safari")
    }

    func testEachFamilyAsksForItsOwnTab() throws {
        let safari = try XCTUnwrap(FrontTabBrowser.detect(bundleID: "com.apple.Safari", name: "Safari")).scriptSource
        XCTAssertTrue(safari.contains("tell application id \"com.apple.Safari\""))
        XCTAssertTrue(safari.contains("URL of current tab of front window"))
        let brave = try XCTUnwrap(FrontTabBrowser.detect(bundleID: "com.brave.Browser", name: "Brave")).scriptSource
        XCTAssertTrue(brave.contains("tell application id \"com.brave.Browser\""))
        XCTAssertTrue(brave.contains("URL of active tab of front window"))
        // A hung browser must not hold the dropdown.
        XCTAssertTrue(safari.contains("with timeout of 2 seconds") && brave.contains("with timeout of 2 seconds"))
        // Compiles as AppleScript (compiling sends nothing).
        var error: NSDictionary?
        XCTAssertTrue(NSAppleScript(source: safari)?.compileAndReturnError(&error) ?? false, "\(String(describing: error))")
    }

    // MARK: - Permission

    func testThePermissionAnswersMapToTheRow() {
        XCTAssertEqual(FrontTabPermission(status: noErr), .granted)
        XCTAssertEqual(FrontTabPermission(status: OSStatus(errAEEventWouldRequireUserConsent)), .needsConsent)
        XCTAssertEqual(FrontTabPermission(status: OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(FrontTabPermission(status: OSStatus(procNotFound)), .unavailable)
        XCTAssertEqual(FrontTabPermission(status: -1), .unavailable)
    }

    func testTestsNeverReadARealTab() {
        XCTAssertFalse(FrontTabWatcher.shared.readsTabs, "under XCTest the watcher must send no Apple Event")
        let before = FrontTabWatcher.shared.suggestion
        FrontTabWatcher.shared.refresh()
        XCTAssertEqual(FrontTabWatcher.shared.suggestion, before)
    }

    func testAnOldSiteIsNotOfferedWhileTheNextReadRuns() {
        let safari = FrontTabBrowser(bundleID: "com.apple.Safari", name: "Safari", family: .safari)
        XCTAssertNil(FrontTabWatcher.whileReading(.site(host: "old.example.com", browser: safari)))
        XCTAssertEqual(FrontTabWatcher.whileReading(.needsConsent(browser: safari)), .needsConsent(browser: safari))
        XCTAssertNil(FrontTabWatcher.whileReading(nil))
    }

    func testAReadIsDroppedWhenTheUserLeftThatBrowser() {
        let watcher = FrontTabWatcher.shared
        let before = watcher.suggestion
        defer { watcher.suggestion = before }
        let safari = FrontTabBrowser(bundleID: "com.apple.Safari", name: "Safari", family: .safari)
        let chrome = FrontTabBrowser(bundleID: "com.google.Chrome", name: "Google Chrome", family: .chromium)

        watcher.suggestion = .site(host: "old.example.com", browser: safari)
        var asked = false
        watcher.finish(safari, permission: .granted, current: chrome) { asked = true; return "https://shop.example.com/" }
        XCTAssertNil(watcher.suggestion, "a read of a browser the user left is not offered")
        XCTAssertFalse(asked, "the tab of a browser the user left is not read")

        watcher.finish(safari, permission: .granted, current: safari) { "https://shop.example.com/" }
        XCTAssertEqual(watcher.suggestion, .site(host: "shop.example.com", browser: safari))
        watcher.finish(safari, permission: .needsConsent, current: safari) { nil }
        XCTAssertEqual(watcher.suggestion, .needsConsent(browser: safari))
        watcher.finish(safari, permission: .denied, current: safari) { "https://shop.example.com/" }
        XCTAssertNil(watcher.suggestion)
    }

    // MARK: - Wording

    func testTheWordsAreTranslated() throws {
        let es = try lproj("es"), fr = try lproj("fr")
        XCTAssertEqual(FrontTabCopy.openIn("Safari"), "open in Safari")
        XCTAssertEqual(FrontTabCopy.openIn("Safari", in: es), "abierto en Safari")
        XCTAssertEqual(FrontTabCopy.openIn("Safari", in: fr), "ouvert dans Safari")
        XCTAssertEqual(FrontTabCopy.addName("shop.example.com", mode: .bypass), "Add shop.example.com to Bypass")
        XCTAssertEqual(FrontTabCopy.addName("shop.example.com", mode: .vpnOnly), "Add shop.example.com to VPN Only")
        XCTAssertEqual(FrontTabCopy.addName("shop.example.com", mode: .custom), "Send shop.example.com Direct")
        XCTAssertEqual(FrontTabCopy.addName("a.example", mode: .bypass, in: es), "Añadir a.example a Bypass")
        XCTAssertEqual(FrontTabCopy.allowTitle(in: fr), "Autoriser…")
        XCTAssertEqual(FrontTabCopy.siteOpenIn("Safari", in: es), "El sitio abierto en Safari")
    }

    // MARK: - The row

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
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

    private func get(_ name: String, of element: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }

    private func elements(in element: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 80, let object = element as? NSObject else { return [] }
        let children = get("accessibilityChildren", of: object) as? [Any] ?? []
        return [object] + children.flatMap { elements(in: $0, depth: depth + 1) }
    }

    /// What VoiceOver reads in the row, with an accessibility client switched on.
    private func labels<V: View>(_ view: V) -> [String] {
        let window = host(view.frame(width: 360))
        let client = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let wasClient = (NSApplication.shared.accessibilityAttributeValue(client) as? Bool) ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: client)
        defer { NSApplication.shared.accessibilitySetValue(wasClient, forAttribute: client) }
        settle()
        // A label, or for static text its value, which is what VoiceOver reads for it.
        return elements(in: window).flatMap { element in
            ["accessibilityLabel", "accessibilityValue"].compactMap { get($0, of: element) as? String }
        }.filter { !$0.isEmpty }
    }

    private let safari = FrontTabBrowser(bundleID: "com.apple.Safari", name: "Safari", family: .safari)

    func testAnUnlistedSiteOffersTheModesAddWithANamedButton() {
        let read = labels(FrontTabRow(suggestion: .site(host: "shop.example.com", browser: safari), mode: .bypass,
                                      listing: nil, onAdd: { _ in }, onAllow: { _ in }))
        XCTAssertTrue(read.contains("shop.example.com, open in Safari"), "read: \(read)")
        XCTAssertTrue(read.contains("Add shop.example.com to Bypass"), "read: \(read)")
    }

    func testAListedSiteSaysWhereInsteadOfOfferingTheAdd() {
        let read = labels(FrontTabRow(suggestion: .site(host: "shop.example.com", browser: safari), mode: .bypass,
                                      listing: .service("Shopping"), onAdd: { _ in }, onAllow: { _ in }))
        XCTAssertTrue(read.contains("Bypassed · Shopping"), "read: \(read)")
        XCTAssertFalse(read.contains("Add shop.example.com to Bypass"), "read: \(read)")
    }

    func testABrowserNotYetAllowedOffersToAsk() {
        let read = labels(FrontTabRow(suggestion: .needsConsent(browser: safari), mode: .vpnOnly,
                                      listing: nil, onAdd: { _ in }, onAllow: { _ in }))
        XCTAssertTrue(read.contains("The site open in Safari"), "read: \(read)")
        XCTAssertTrue(read.contains("Allow Reading the Front Tab in Safari"), "read: \(read)")
    }

    // Outside the first-run screen only: on a fresh install the dropdown shows the first-run
    // block, with its own add field, in place of the normal content and this row.
    func testTheRowSitsUnderTheAddFieldOutsideFirstRun() throws {
        let menu = try ReworkSource.body(of: "struct MenuContent: View", in: "MenuBarViews.swift")
        let field = try XCTUnwrap(menu.range(of: "QuickAddField("))
        let row = try XCTUnwrap(menu.range(of: "FrontTabRow("), "no front tab row in the dropdown")
        let content = try XCTUnwrap(menu.range(of: "if !isStarting {"))
        XCTAssertLessThan(field.lowerBound, row.lowerBound)
        XCTAssertLessThan(row.lowerBound, content.lowerBound, "drawn before the state-dependent content")
        XCTAssertTrue(menu.contains("frontTab.refresh()"), "read again on every open")
    }

    // MARK: - Signing

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheAppIsEntitledToSendAppleEventsAndSaysWhy() throws {
        let entitlements = try plist("VPNBypass.entitlements")
        XCTAssertEqual(entitlements["com.apple.security.automation.apple-events"] as? Bool, true)
        let info = try plist("Info.plist")
        let why = try XCTUnwrap(info["NSAppleEventsUsageDescription"] as? String)
        XCTAssertTrue(why.contains("front tab"))
        XCTAssertFalse(why.lowercased().contains("bypass the site"), "the prompt fits every mode, not Bypass only")
        for language in ["en", "es", "fr"] {
            let strings = try plist("Sources/VPNBypassCore/Resources/\(language).lproj/InfoPlist.strings")
            XCTAssertNotNil(strings["NSAppleEventsUsageDescription"], "\(language) has the prompt's text")
        }
    }

    func testTheReleaseSignsTheAppWithItsEntitlements() throws {
        let makefile = try text("Makefile")
        XCTAssertTrue(makefile.contains("scripts/sign-and-notarize.sh app --entitlements VPNBypass.entitlements"),
                      "make release must pass the entitlements, or the signed app cannot send Apple Events")
        let script = try text("scripts/sign-and-notarize.sh")
        XCTAssertTrue(script.contains("sign --entitlements \"$entitlements\" \"$target\""))
        XCTAssertTrue(script.contains("codesign -d --entitlements - --xml"), "the signed entitlements are read back")
    }

    /// The flag is parsed before anything is signed, so a wrong use fails at once.
    func testTheScriptRefusesABadEntitlementsFlagBeforeSigning() throws {
        func run(_ args: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [Self.root.appendingPathComponent("scripts/sign-and-notarize.sh").path] + args
            process.environment = ["PATH": "/usr/bin:/bin"]
            let err = Pipe()
            process.standardError = err
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, message)
        }
        let target = Self.root.appendingPathComponent("Info.plist").path
        var (status, message) = try run(["app", "--entitlements", "/nonexistent.entitlements", target])
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(message.contains("entitlements file /nonexistent.entitlements does not exist"), message)
        (status, message) = try run(["dmg", "--entitlements", "VPNBypass.entitlements", target])
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(message.contains("--entitlements is for app only"), message)
        // A good flag gets past parsing and stops at the missing identity, signing nothing.
        let entitlements = Self.root.appendingPathComponent("VPNBypass.entitlements").path
        (status, message) = try run(["app", "--entitlements", entitlements, target])
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(message.contains("SIGN_IDENTITY is not set"), message)
    }
}
