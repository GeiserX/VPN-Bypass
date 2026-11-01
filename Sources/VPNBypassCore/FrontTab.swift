// FrontTab.swift
// Idea 3 of the 6.0 rework: the dropdown offers the site open in the browser the user just
// left, with one button that adds it. The address comes from the browser's front tab through
// Apple Events, which Safari and the Chromium browsers answer; Firefox has no scripting for
// tabs, so it gets no row. macOS asks once per browser before the first read
// (NSAppleEventsUsageDescription in Info.plist), and the signed app carries the
// com.apple.security.automation.apple-events entitlement that the hardened runtime needs.

import AppKit
import CoreServices
import SwiftUI

// MARK: - Browsers

/// A browser whose front tab can be read, by the bundle id of the running app.
struct FrontTabBrowser: Equatable {
    /// Which AppleScript dictionary the browser speaks.
    enum Family: Equatable {
        /// `URL of current tab of front window`.
        case safari
        /// `URL of active tab of front window`.
        case chromium
    }

    let bundleID: String
    /// The name the dropdown shows: "Safari", "Google Chrome".
    let name: String
    let family: Family

    static let safariIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    static let chromiumIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
    ]

    /// The family for a bundle id, or nil for anything that is not a browser we can read:
    /// Firefox (no tab scripting), this app, and every other app.
    static func family(forBundleID bundleID: String?) -> Family? {
        guard let bundleID else { return nil }
        if safariIDs.contains(bundleID) { return .safari }
        if chromiumIDs.contains(bundleID) { return .chromium }
        return nil
    }

    /// The browser for a running app's bundle id and name, or nil when it is not one we read.
    static func detect(bundleID: String?, name: String?) -> FrontTabBrowser? {
        guard let bundleID, let family = family(forBundleID: bundleID) else { return nil }
        let shown = name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID
        return FrontTabBrowser(bundleID: bundleID, name: shown, family: family)
    }

    /// The script that returns the front tab's address. The bundle id comes from the fixed
    /// lists above, never from outside, so it is safe inside the source. A hung browser costs
    /// at most the timeout.
    var scriptSource: String {
        let tab = family == .safari ? "current tab" : "active tab"
        return """
        with timeout of 2 seconds
            tell application id "\(bundleID)" to return URL of \(tab) of front window
        end timeout
        """
    }
}

// MARK: - The host

enum FrontTabHost {
    /// The host to offer for a front tab's address: an http or https page on a name with a
    /// dot, as the add field would save it. Nil for a blank or internal page (about:blank,
    /// chrome://newtab, file://), localhost, a single-label name, and an IPv6 literal, which
    /// the app cannot route.
    static func host(fromURL string: String?) -> String? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
              let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              // The host as DNS sees it: an international name stays in its xn-- form.
              var host = (components.encodedHost ?? components.percentEncodedHost)?.lowercased(),
              !host.isEmpty, host.allSatisfy(\.isASCII)
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.contains(":"), !host.hasPrefix("["),
              host != "localhost", !host.hasSuffix(".localhost"),
              host.contains("."), !host.hasPrefix("."), !host.contains("..")
        else { return nil }
        // What the add field would keep of it; anything it would rewrite is not a plain host.
        guard RouteManager.cleanDomain(host) == host else { return nil }
        return host
    }
}

// MARK: - Permission

/// What macOS lets the app do with a browser's Apple Events, without asking.
enum FrontTabPermission: Equatable {
    case granted
    /// The user has not been asked yet; asking shows the Automation prompt.
    case needsConsent
    /// The user said no, in the prompt or in System Settings > Privacy & Security > Automation.
    case denied
    /// The browser is not running, or the check failed: no row.
    case unavailable

    /// System Settings > Privacy & Security > Automation, where a browser is switched back on.
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Opens that pane; a refusal from macOS goes to the log, so a button that did nothing says why.
    @MainActor static func openAutomationSettings() {
        openAutomationSettings(open: { NSWorkspace.shared.open($0) }, log: { RouteManager.shared.log($0, $1) })
    }

    @MainActor static func openAutomationSettings(open: (URL) -> Bool,
                                                  log: (RouteManager.LogEntry.LogLevel, String) -> Void) {
        if !open(automationSettingsURL) {
            log(.warning, "Front tab: macOS did not open Privacy & Security > Automation in System Settings")
        }
    }

    /// From `AEDeterminePermissionToAutomateTarget`'s result.
    init(status: OSStatus) {
        switch status {
        case noErr: self = .granted
        case OSStatus(errAEEventWouldRequireUserConsent): self = .needsConsent
        case OSStatus(errAEEventNotPermitted): self = .denied
        default: self = .unavailable
        }
    }

    /// Asks macOS. With `ask` it may show the prompt and blocks until the user answers, so it
    /// never runs on the main thread.
    static func check(bundleID: String, ask: Bool) -> FrontTabPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unavailable }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        return FrontTabPermission(status: status)
    }
}

// MARK: - What the dropdown shows

/// The dropdown's row for the browser the user just left.
enum FrontTabSuggestion: Equatable {
    /// The front tab's host, ready to add.
    case site(host: String, browser: FrontTabBrowser)
    /// The browser is in front and macOS has not been asked yet: the row offers to ask.
    case needsConsent(browser: FrontTabBrowser)
    /// The user switched the browser off for this app: the row opens the Automation pane.
    case accessOff(browser: FrontTabBrowser)

    /// The site, once read.
    var host: String? {
        if case .site(let host, _) = self { return host }
        return nil
    }
}

/// Which app the user is in, as the dropdown reads it on each open. The app in front now when
/// it is one the user works in; otherwise the last such app. Only apps with a Dock icon count:
/// a menu bar app (the VPN client's own menu, this app), the Automation prompt and other system
/// agents also become active, and remembering one of them dropped the browser row on every
/// open after the first.
struct FrontAppTracker: Equatable {
    struct App: Equatable {
        let bundleID: String?
        let name: String?
        /// The app shows in the Dock (`NSApplication.ActivationPolicy.regular`).
        let isRegular: Bool
        /// The process, so a quit browser is not stood in for by another copy with its bundle ID.
        var pid: pid_t? = nil
        /// The process's own handle. macOS 27 reports some apps, Safari and Preview among them,
        /// with process id -1, so for those the handle is the only way to tell the process quit.
        var process: NSRunningApplication? = nil
    }

    let ownBundleID: String?
    private(set) var last: App?

    init(ownBundleID: String?) { self.ownBundleID = ownBundleID }

    /// An app the user works in: in the Dock, and not this one.
    func counts(_ app: App?) -> Bool {
        guard let app, app.isRegular else { return false }
        return app.bundleID != ownBundleID
    }

    /// An app became active.
    mutating func activated(_ app: App?) {
        if counts(app) { last = app }
    }

    /// The app the user is in at an open: the one in front, or the last one when the app in
    /// front is a menu bar app or this one.
    mutating func current(frontmost: App?) -> App? {
        activated(frontmost)
        return last
    }
}

/// What one run of the front tab script gave: the address, or AppleScript's error number.
struct FrontTabScriptResult: Equatable {
    var url: String? = nil
    var errorNumber: Int? = nil
}

/// Follows the app the user is in (`FrontAppTracker`) and reads its front tab when the
/// dropdown opens. Reads only that app, and only when it is a browser we know, so a browser in
/// the background is never asked.
@MainActor
final class FrontTabWatcher: ObservableObject {
    static let shared = FrontTabWatcher()

    /// Everything the watcher asks of macOS, so a test can drive a whole open without an Apple
    /// Event: which app is in front, whether a process still runs, the Automation permission,
    /// the script, and the log.
    struct System {
        var frontmost: @MainActor () -> FrontAppTracker.App?
        var isRunning: @MainActor (FrontAppTracker.App) -> Bool
        /// Runs off the main thread: with `ask` it may wait for the user's answer.
        var permission: @Sendable (_ bundleID: String, _ ask: Bool) -> FrontTabPermission
        /// Runs on the main thread, as NSAppleScript requires.
        var runScript: @MainActor (String) -> FrontTabScriptResult
        /// One line in the app's log; a failed script is a warning, so the Warnings filter shows it.
        var log: @MainActor (RouteManager.LogEntry.LogLevel, String) -> Void

        static let live = System(
            frontmost: { FrontTabWatcher.describe(NSWorkspace.shared.frontmostApplication) },
            isRunning: FrontTabWatcher.stillRuns,
            permission: { FrontTabPermission.check(bundleID: $0, ask: $1) },
            runScript: FrontTabWatcher.runScript,
            log: { RouteManager.shared.log($0, $1) })
    }

    @Published var suggestion: FrontTabSuggestion?

    /// Off under XCTest, so no test sends a real Apple Event; the screenshot renders set
    /// `suggestion` themselves, and the tests of the read build their own watcher.
    let readsTabs: Bool

    private let system: System
    private var tracker: FrontAppTracker
    private var observer: NSObjectProtocol?
    private var reading = false
    /// The read in flight, for the tests to wait on.
    private(set) var readTask: Task<Void, Never>?
    /// How many times the dropdown asked for a refresh, for the tests of every open.
    private(set) var refreshRequests = 0

    init(system: System = .live, ownBundleID: String? = Bundle.main.bundleIdentifier,
         readsTabs: Bool = !(NSClassFromString("XCTestCase") != nil
                             || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)) {
        self.system = system
        self.tracker = FrontAppTracker(ownBundleID: ownBundleID)
        self.readsTabs = readsTabs
    }

    /// Starts following which app is in front. The app calls it once at launch.
    func start() {
        guard observer == nil else { return }
        activated(system.frontmost())
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(Self.describe(app)) }
        }
    }

    /// An app became active.
    func activated(_ app: FrontAppTracker.App?) {
        tracker.activated(app)
    }

    nonisolated static func describe(_ app: NSRunningApplication?) -> FrontAppTracker.App? {
        app.map { .init(bundleID: $0.bundleIdentifier, name: $0.localizedName,
                        isRegular: $0.activationPolicy == .regular, pid: $0.processIdentifier, process: $0) }
    }

    /// The app the user is in, or was last in. The app in front now is read first, so a missed
    /// activation cannot leave an old app.
    private var currentApp: FrontAppTracker.App? {
        tracker.current(frontmost: system.frontmost())
    }

    /// The browser the user is in, or was last in, or nil when it was another app or has quit.
    /// The process the user was in must still run: another copy of the same browser is not it.
    private var lastBrowser: FrontTabBrowser? {
        guard let app = currentApp, system.isRunning(app) else { return nil }
        return FrontTabBrowser.detect(bundleID: app.bundleID, name: app.name)
    }

    /// The very process the user was in is still running, not another copy of its bundle ID.
    nonisolated static func stillRuns(_ app: FrontAppTracker.App) -> Bool {
        if let pid = app.pid, pid > 0 {
            guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
            return !running.isTerminated && running.bundleIdentifier == app.bundleID
        }
        // No process id from macOS (-1 for Safari on macOS 27): the handle of that process.
        guard let process = app.process else { return false }
        return !process.isTerminated
    }

    /// Called on every dropdown open. Never shows the Automation prompt: a browser not yet
    /// allowed gets the row that asks.
    func refresh() {
        refreshRequests += 1
        guard readsTabs, !reading else { return }
        guard let browser = lastBrowser else {
            // A browser we read that macOS no longer shows running: say so, or a row that never
            // appears leaves nothing to go on.
            if let app = currentApp, let known = FrontTabBrowser.detect(bundleID: app.bundleID, name: app.name) {
                system.log(.info, "Front tab: \(known.name) is not running, nothing read")
            }
            suggestion = nil
            return
        }
        // A site read on an earlier open may be another tab by now: never offer it while the
        // new read runs.
        suggestion = Self.whileReading(suggestion)
        read(browser, ask: false)
    }

    /// The row while a read runs: a site from an earlier read is dropped, the other rows stay.
    static func whileReading(_ suggestion: FrontTabSuggestion?) -> FrontTabSuggestion? {
        if case .site = suggestion { return nil }
        return suggestion
    }

    /// The row's Allow… button: shows macOS's prompt for this browser, then reads.
    func askAndRead(_ browser: FrontTabBrowser) {
        guard readsTabs, !reading else { return }
        read(browser, ask: true)
    }

    private func read(_ browser: FrontTabBrowser, ask: Bool) {
        reading = true
        let check = system.permission
        readTask = Task {
            let bundleID = browser.bundleID
            let permission = await Task.detached { check(bundleID, ask) }.value
            reading = false
            finish(browser, permission: permission, current: lastBrowser) { system.runScript(browser.scriptSource) }
            // The user went to another app while the check ran: read that one instead.
            if lastBrowser != browser, lastBrowser != nil { refresh() }
        }
    }

    /// Publishes a read of `browser`, unless the user has left it for `current` meanwhile:
    /// then the read is dropped and the tab is not read at all. Logs one line per read: the
    /// permission and the script's error number, never the address.
    func finish(_ browser: FrontTabBrowser, permission: FrontTabPermission, current: FrontTabBrowser?,
                readURL: () -> FrontTabScriptResult) {
        let name = browser.name
        guard current == browser else {
            system.log(.info, "Front tab: left \(name) before the read, nothing read")
            suggestion = nil
            return
        }
        switch permission {
        case .granted:
            let result = readURL()
            suggestion = FrontTabHost.host(fromURL: result.url).map { .site(host: $0, browser: browser) }
            if let number = result.errorNumber {
                system.log(.warning, "Front tab: \(name) access on, script error \(number)")
            } else {
                system.log(.info, "Front tab: \(name) access on, " + (suggestion == nil ? "no site in the front tab" : "site read"))
            }
        case .needsConsent:
            suggestion = .needsConsent(browser: browser)
            system.log(.info, "Front tab: \(name) access not asked yet")
        case .denied:
            suggestion = .accessOff(browser: browser)
            system.log(.info, "Front tab: \(name) access is off")
        case .unavailable:
            suggestion = nil
            system.log(.info, "Front tab: \(name) access unknown, nothing read")
        }
    }

    /// Runs on the main thread, as NSAppleScript requires; the script's own timeout bounds it.
    private static func runScript(_ source: String) -> FrontTabScriptResult {
        // A script that cannot even be made is a failed read, not a tab with no site.
        guard let script = NSAppleScript(source: source) else { return FrontTabScriptResult(url: nil, errorNumber: 0) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return FrontTabScriptResult(url: nil, errorNumber: (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0)
        }
        return FrontTabScriptResult(url: result.stringValue, errorNumber: nil)
    }
}

// MARK: - Wording

enum FrontTabCopy {
    /// The detail after the host: "open in Safari".
    static func openIn(_ browser: String, in bundle: Bundle = .main) -> String {
        String(localized: "open in \(browser)", bundle: bundle)
    }

    /// The row's text before macOS has been asked.
    static func siteOpenIn(_ browser: String, in bundle: Bundle = .main) -> String {
        String(localized: "The site open in \(browser)", bundle: bundle)
    }

    static func allowTitle(in bundle: Bundle = .main) -> String {
        String(localized: "Allow…", bundle: bundle)
    }

    /// The Allow… button's tooltip and VoiceOver hint.
    static func allowHelp(_ browser: String, in bundle: Bundle = .main) -> String {
        String(localized: "macOS asks once whether VPN Bypass may read the address of the front tab in \(browser).",
               bundle: bundle)
    }

    /// The Allow… button's spoken name.
    static func allowName(_ browser: String, in bundle: Bundle = .main) -> String {
        String(localized: "Allow Reading the Front Tab in \(browser)", bundle: bundle)
    }

    /// The row's text when the user has switched the browser off for this app.
    static func accessOff(_ browser: String, in bundle: Bundle = .main) -> String {
        String(localized: "\(browser) access is off", bundle: bundle)
    }

    static func openSettingsTitle(in bundle: Bundle = .main) -> String {
        String(localized: "Open Settings", bundle: bundle)
    }

    /// The Open Settings button's spoken name.
    static func openSettingsName(_ browser: String, in bundle: Bundle = .main) -> String {
        String(localized: "Open Automation Settings for \(browser)", bundle: bundle)
    }

    /// The Open Settings button's tooltip and VoiceOver hint.
    static func openSettingsHelp(_ browser: String, in bundle: Bundle = .main) -> String {
        String(localized: "Switch on \(browser) under VPN Bypass in Privacy & Security > Automation, so the app can read the front tab.",
               bundle: bundle)
    }

    /// The add button's spoken name and tooltip, naming the site.
    static func addName(_ host: String, mode: LookupMode, in bundle: Bundle = .main) -> String {
        switch mode {
        case .bypass: return String(localized: "Add \(host) to Bypass", bundle: bundle)
        case .vpnOnly: return String(localized: "Add \(host) to VPN Only", bundle: bundle)
        case .custom: return String(localized: "Send \(host) Direct", bundle: bundle)
        }
    }
}

// MARK: - The row

/// "shop.example.com · open in Safari  [Add to Bypass]", under the add field. A site already
/// listed shows where instead of the button, in the Lookups page's words.
struct FrontTabRow: View {
    let suggestion: FrontTabSuggestion
    let mode: LookupMode
    /// Where the host is listed now, nil when the mode does not route it.
    let listing: LookupListing?
    var isApplying = false
    let onAdd: (String) -> Void
    let onAllow: (FrontTabBrowser) -> Void
    /// The access-off row's button: the Automation pane of System Settings.
    var onOpenSettings: () -> Void = FrontTabPermission.openAutomationSettings

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: glyph)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .frame(width: ListRow.glyphColumn)
                .accessibilityHidden(true)
            label
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .frame(minHeight: 24)
    }

    private var browser: FrontTabBrowser {
        switch suggestion {
        case .site(_, let browser), .needsConsent(let browser), .accessOff(let browser): return browser
        }
    }

    private var glyph: String { browser.family == .safari ? "safari" : "globe" }

    @ViewBuilder private var label: some View {
        switch suggestion {
        case .site(let host, let browser):
            // The host keeps its room; "open in Safari" gives way first.
            HStack(spacing: 0) {
                Text(verbatim: host)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(verbatim: " · " + FrontTabCopy.openIn(browser.name))
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(Text(verbatim: "\(host) · \(FrontTabCopy.openIn(browser.name))"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(host), \(FrontTabCopy.openIn(browser.name))"))
        case .needsConsent(let browser):
            Text(verbatim: FrontTabCopy.siteOpenIn(browser.name))
                .font(Theme.Font.body)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        case .accessOff(let browser):
            Text(verbatim: FrontTabCopy.accessOff(browser.name))
                .font(Theme.Font.body)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch suggestion {
        case .site(let host, _):
            if let listing {
                Text(verbatim: LookupRow.detail(for: listing) ?? "")
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Button(mode.addTitle) { onAdd(host) }
                    .controlSize(.small)
                    .disabled(isApplying)
                    .fixedSize()
                    .help(FrontTabCopy.addName(host, mode: mode))
                    .accessibilityLabel(FrontTabCopy.addName(host, mode: mode))
            }
        case .needsConsent(let browser):
            Button(FrontTabCopy.allowTitle()) { onAllow(browser) }
                .controlSize(.small)
                .fixedSize()
                .help(FrontTabCopy.allowHelp(browser.name))
                .accessibilityLabel(FrontTabCopy.allowName(browser.name))
                .accessibilityHint(FrontTabCopy.allowHelp(browser.name))
        case .accessOff(let browser):
            Button(FrontTabCopy.openSettingsTitle()) { onOpenSettings() }
                .controlSize(.small)
                .fixedSize()
                .help(FrontTabCopy.openSettingsHelp(browser.name))
                .accessibilityLabel(FrontTabCopy.openSettingsName(browser.name))
                .accessibilityHint(FrontTabCopy.openSettingsHelp(browser.name))
        }
    }
}
