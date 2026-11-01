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
        let watcher = FrontTabWatcher(system: .init(frontmost: { nil }, isRunning: { _ in true },
                                                    permission: { _, _ in .granted },
                                                    runScript: { _ in .init() }, log: { _, _ in }),
                                      ownBundleID: "com.example.vpnbypass", readsTabs: false)
        let safari = FrontTabBrowser(bundleID: "com.apple.Safari", name: "Safari", family: .safari)
        let chrome = FrontTabBrowser(bundleID: "com.google.Chrome", name: "Google Chrome", family: .chromium)
        let page = FrontTabScriptResult(url: "https://shop.example.com/")

        watcher.suggestion = .site(host: "old.example.com", browser: safari)
        var asked = false
        watcher.finish(safari, permission: .granted, current: chrome) { asked = true; return page }
        XCTAssertNil(watcher.suggestion, "a read of a browser the user left is not offered")
        XCTAssertFalse(asked, "the tab of a browser the user left is not read")

        watcher.finish(safari, permission: .granted, current: safari) { page }
        XCTAssertEqual(watcher.suggestion, .site(host: "shop.example.com", browser: safari))
        watcher.finish(safari, permission: .needsConsent, current: safari) { .init() }
        XCTAssertEqual(watcher.suggestion, .needsConsent(browser: safari))
        watcher.finish(safari, permission: .denied, current: safari) { page }
        XCTAssertEqual(watcher.suggestion, .accessOff(browser: safari), "access switched off says so")
        watcher.finish(safari, permission: .unavailable, current: safari) { page }
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
        XCTAssertEqual(FrontTabCopy.accessOff("Safari"), "Safari access is off")
        XCTAssertEqual(FrontTabCopy.accessOff("Safari", in: es), "El acceso a Safari está desactivado")
        XCTAssertEqual(FrontTabCopy.accessOff("Safari", in: fr), "L’accès à Safari est désactivé")
        XCTAssertEqual(FrontTabCopy.openSettingsTitle(in: es), "Abrir Ajustes")
        XCTAssertEqual(FrontTabCopy.openSettingsTitle(in: fr), "Ouvrir les réglages")
        XCTAssertEqual(FrontTabCopy.openSettingsName("Safari", in: fr), "Ouvrir les réglages d’automatisation pour Safari")
        XCTAssertEqual(FrontTabCopy.openSettingsHelp("Safari", in: es),
                       "Activa Safari bajo VPN Bypass en Privacidad y seguridad > Automatización para que la app pueda leer la pestaña activa.")
        XCTAssertEqual(FrontTabCopy.openSettingsHelp("Safari", in: fr),
                       "Activez Safari sous VPN Bypass dans Confidentialité et sécurité > Automatisation pour que l’app puisse lire l’onglet actif.")
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

    func testOpenSettingsOpensTheAutomationPaneAndLogsARefusal() {
        var opened: [URL] = []
        var logged: [(RouteManager.LogEntry.LogLevel, String)] = []
        FrontTabPermission.openAutomationSettings(open: { opened.append($0); return true }, log: { logged.append(($0, $1)) })
        XCTAssertEqual(opened, [FrontTabPermission.automationSettingsURL])
        XCTAssertTrue(logged.isEmpty, "an opened pane logs nothing")
        FrontTabPermission.openAutomationSettings(open: { _ in false }, log: { logged.append(($0, $1)) })
        XCTAssertEqual(logged.map(\.0), [.warning], "a pane macOS would not open is logged")
    }

    func testAnAccessSwitchedOffOffersTheAutomationPane() {
        var opened = 0
        let read = labels(FrontTabRow(suggestion: .accessOff(browser: safari), mode: .bypass, listing: nil,
                                      onAdd: { _ in }, onAllow: { _ in }, onOpenSettings: { opened += 1 }))
        XCTAssertTrue(read.contains("Safari access is off"), "read: \(read)")
        XCTAssertTrue(read.contains("Open Automation Settings for Safari"), "read: \(read)")
        XCTAssertFalse(read.contains("Allow Reading the Front Tab in Safari"), "read: \(read)")
        XCTAssertEqual(FrontTabPermission.automationSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")

        let button = elements(in: window!).first { (get("accessibilityLabel", of: $0) as? String) == "Open Automation Settings for Safari" }
        XCTAssertNotNil(button)
        _ = button?.perform(NSSelectorFromString("accessibilityPerformPress"))
        settle()
        XCTAssertEqual(opened, 1, "the button opens the pane")
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

/// Live test with GlobalProtect connected: the browser row showed on the first open after
/// launch only. Between two opens a menu bar app became active (the VPN client's own menu,
/// the Automation prompt), the watcher remembered it as the app the user left, and every later
/// open found no browser. Only apps in the Dock are the app the user is in.
final class FrontAppTrackerTests: XCTestCase {

    private let own = "com.example.vpnbypass"
    private let safari = FrontAppTracker.App(bundleID: "com.apple.Safari", name: "Safari", isRegular: true)
    private let vpnMenu = FrontAppTracker.App(bundleID: "com.example.vpnclient", name: "VPN Client", isRegular: false)
    private let prompt = FrontAppTracker.App(bundleID: "com.apple.UserNotificationCenter", name: "UserNotificationCenter",
                                             isRegular: false)
    private var ownWindow: FrontAppTracker.App { .init(bundleID: own, name: "VPN Bypass", isRegular: true) }

    func testTheBrowserIsFoundOnEveryOpenAfterAMenuBarAppWasActive() {
        var tracker = FrontAppTracker(ownBundleID: own)
        tracker.activated(safari)
        XCTAssertEqual(tracker.current(frontmost: safari), safari, "the first open")
        tracker.activated(vpnMenu)
        tracker.activated(prompt)
        XCTAssertEqual(tracker.current(frontmost: vpnMenu), safari, "the second open, with a menu bar app in front")
        XCTAssertEqual(tracker.current(frontmost: nil), safari, "a third open")
    }

    func testThisAppIsNeverTheAppTheUserLeft() {
        var tracker = FrontAppTracker(ownBundleID: own)
        tracker.activated(safari)
        tracker.activated(ownWindow)
        XCTAssertEqual(tracker.current(frontmost: ownWindow), safari, "Settings open in the Dock is still this app")
    }

    func testAnotherDockAppReplacesTheBrowser() {
        var tracker = FrontAppTracker(ownBundleID: own)
        tracker.activated(safari)
        let mail = FrontAppTracker.App(bundleID: "com.apple.mail", name: "Mail", isRegular: true)
        XCTAssertEqual(tracker.current(frontmost: mail), mail, "the user left Safari for Mail: no browser row")
        XCTAssertEqual(tracker.current(frontmost: safari), safari, "the app in front counts even if its activation was missed")
    }

    /// A browser the user was in that has quit is gone, even while another copy with its
    /// bundle ID runs: only that process counts.
    func testOnlyTheTrackedProcessCounts() throws {
        let me = NSRunningApplication.current
        let running = FrontAppTracker.App(bundleID: me.bundleIdentifier, name: me.localizedName, isRegular: true,
                                          pid: me.processIdentifier)
        XCTAssertTrue(FrontTabWatcher.stillRuns(running), "control: this process runs")
        // A process that has exited: a child that ran and was reaped.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        var gone = running
        gone.pid = child.processIdentifier
        XCTAssertFalse(FrontTabWatcher.stillRuns(gone), "the tracked process quit, though its bundle ID still runs")
        gone.pid = nil
        XCTAssertFalse(FrontTabWatcher.stillRuns(gone), "no process recorded")
    }
}

/// Live test on macOS 27: Automation had Safari switched on, Safari was in front on a site,
/// and the dropdown showed no browser row on any open, neither the site nor Allow…. macOS 27
/// reports Safari (and Preview) with process id -1, so the check that the browser the user
/// left still runs looked up process -1, found nothing and dropped the browser before any
/// read. These tests drive the whole open through the watcher, with macOS swapped for seams.
@MainActor
final class FrontTabReadSequenceTests: XCTestCase {

    /// The permission the seam answers; read off the main thread, as the real check is.
    final class PermissionAnswer: @unchecked Sendable {
        var value: FrontTabPermission = .granted
        var asked: [(String, Bool)] = []
    }

    private let own = "com.example.vpnbypass"
    private var front: FrontAppTracker.App?
    private var logs: [String] = []
    private var levels: [RouteManager.LogEntry.LogLevel] = []
    private var scripts: [String] = []
    private var script = FrontTabScriptResult(url: "https://example.com/", errorNumber: nil)
    private let answer = PermissionAnswer()

    /// Safari as macOS 27 hands it over: in the Dock, process id -1, and a handle of a live
    /// process (this test's own, standing in for Safari's).
    private var safari: FrontAppTracker.App {
        .init(bundleID: "com.apple.Safari", name: "Safari", isRegular: true, pid: -1, process: StubProcess(terminated: false))
    }

    /// This app once its status item is clicked: active, with no Dock icon.
    private var ownMenu: FrontAppTracker.App {
        .init(bundleID: own, name: "VPN Bypass", isRegular: false, pid: getpid(), process: StubProcess(terminated: false))
    }

    private let browser = FrontTabBrowser(bundleID: "com.apple.Safari", name: "Safari", family: .safari)

    private func makeWatcher() -> FrontTabWatcher {
        let answer = self.answer
        let system = FrontTabWatcher.System(
            frontmost: { [unowned self] in front },
            // The real check, so the process id macOS gives is what decides.
            isRunning: FrontTabWatcher.stillRuns,
            permission: { bundleID, ask in answer.asked.append((bundleID, ask)); return answer.value },
            runScript: { [unowned self] source in scripts.append(source); return script },
            log: { [unowned self] level, line in logs.append(line); levels.append(level) })
        return FrontTabWatcher(system: system, ownBundleID: own, readsTabs: true)
    }

    /// One dropdown open: the window's two triggers (already key when the view lands in it, and
    /// the key notification) both refresh; the second finds the first's read running.
    private func open(_ watcher: FrontTabWatcher) async {
        watcher.refresh()
        watcher.refresh()
        await watcher.readTask?.value
    }

    func testTheSiteIsReadOnEveryOpenWhenMacOSHidesSafarisProcessID() async {
        let watcher = makeWatcher()
        watcher.activated(safari)       // Safari was activated last,
        front = ownMenu                 // then the status item was clicked.

        await open(watcher)
        XCTAssertEqual(watcher.suggestion, .site(host: "example.com", browser: browser), "first open")
        await open(watcher)
        XCTAssertEqual(watcher.suggestion, .site(host: "example.com", browser: browser), "second open")

        XCTAssertEqual(scripts.count, 2, "one read per open, not one per trigger")
        XCTAssertTrue(answer.asked.allSatisfy { $0 == ("com.apple.Safari", false) }, "an open never shows the prompt")
        XCTAssertEqual(logs, ["Front tab: Safari access on, site read", "Front tab: Safari access on, site read"])
    }

    func testAnAccessSwitchedOffShowsTheRowThatOpensSettings() async {
        answer.value = .denied
        let watcher = makeWatcher()
        watcher.activated(safari)
        front = ownMenu

        await open(watcher)
        XCTAssertEqual(watcher.suggestion, .accessOff(browser: browser))
        XCTAssertTrue(scripts.isEmpty, "no script runs without access")
        XCTAssertEqual(logs, ["Front tab: Safari access is off"])
    }

    func testEachOutcomeLogsOneLineWithoutTheAddress() async {
        let watcher = makeWatcher()
        watcher.activated(safari)
        front = ownMenu

        script = FrontTabScriptResult(url: nil, errorNumber: -1719)
        await open(watcher)
        XCTAssertNil(watcher.suggestion, "a failed script offers nothing")
        script = FrontTabScriptResult(url: "about:blank", errorNumber: nil)
        await open(watcher)
        XCTAssertNil(watcher.suggestion)
        answer.value = .needsConsent
        await open(watcher)
        XCTAssertEqual(watcher.suggestion, .needsConsent(browser: browser))
        answer.value = .unavailable
        await open(watcher)
        XCTAssertNil(watcher.suggestion)

        XCTAssertEqual(logs, ["Front tab: Safari access on, script error -1719",
                              "Front tab: Safari access on, no site in the front tab",
                              "Front tab: Safari access not asked yet",
                              "Front tab: Safari access unknown, nothing read"])
        XCTAssertEqual(levels, [.warning, .info, .info, .info], "a failed script shows under the Warnings filter")
        // A site that was read never reaches the log: hostnames are never logged.
        script = FrontTabScriptResult(url: "https://private.example.org/x", errorNumber: nil)
        answer.value = .granted
        await open(watcher)
        XCTAssertEqual(watcher.suggestion?.host, "private.example.org")
        XCTAssertFalse(logs.joined().contains("example"), "logs: \(logs)")
    }

    func testABrowserWithNoProcessLeftIsNotRead() async {
        let watcher = makeWatcher()
        var gone = safari
        gone.process = nil
        watcher.activated(gone)
        front = ownMenu

        await open(watcher)
        XCTAssertNil(watcher.suggestion)
        XCTAssertTrue(answer.asked.isEmpty, "nothing is asked of a browser that is not running")
        XCTAssertEqual(logs, ["Front tab: Safari is not running, nothing read", "Front tab: Safari is not running, nothing read"],
                       "both triggers of the open say why there is no row")
    }

    /// The process handle is what tells a hidden-id browser that quit from one that runs.
    func testAHiddenProcessIDFallsBackToTheProcessHandle() {
        XCTAssertTrue(FrontTabWatcher.stillRuns(safari), "id -1, live handle: running")
        var gone = safari
        gone.process = nil
        XCTAssertFalse(FrontTabWatcher.stillRuns(gone), "id -1 and no handle: nothing to go on")
        gone.process = StubProcess(terminated: true)
        XCTAssertFalse(FrontTabWatcher.stillRuns(gone), "id -1 and a handle that quit: gone")
        let described = FrontTabWatcher.describe(.current)
        XCTAssertNotNil(described?.process, "the app keeps each process's handle")
    }
}

/// A process handle whose `isTerminated` the test sets. `NSRunningApplication.current` reports
/// itself terminated in an XCTest run that has not started NSApplication yet (a filtered run),
/// so a test that leans on it passes or fails by test order.
final class StubProcess: NSRunningApplication {
    private let stubTerminated: Bool
    init(terminated: Bool) {
        self.stubTerminated = terminated
        super.init()
    }
    override var isTerminated: Bool { stubTerminated }
}
