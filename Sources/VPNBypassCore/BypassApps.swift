// BypassApps.swift
// Bypass mode's Apps list: apps that skip the VPN, without a Custom rule.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, sections 4 and 10 (step 7). An entry names an
// app the way a process rule does (a bundle id or an executable name, `ProcessRule.invalid`), and
// compiles to a Direct matcher in the per-app policy (`FlowPolicySource`). Only per-app routing
// serves it: the kernel engine never sees the list, so with per-app routing off the app keeps
// using the VPN and the Apps page says so. Switching to Custom carries the list into process
// rules (`Config.derive`).

import AppKit
import Foundation
import Security
import VPNBypassPolicy

/// One entry of the Apps list.
struct BypassApp: Codable, Identifiable, Equatable {
    var id: UUID
    /// The app's signing identifier (its bundle id, as a rule matches it) or an executable name.
    var pattern: String
    /// The app's name as the chooser found it; nil for an entry added by its id alone.
    var name: String?
    var enabled: Bool
    /// The app's bundle id, kept only where it differs from the signing identifier in
    /// `pattern`: the icon, the chooser and `vpnb app.rm` find the app by it.
    var bundleID: String?

    init(id: UUID = UUID(), pattern: String, name: String? = nil, enabled: Bool = true, bundleID: String? = nil) {
        self.id = id
        self.pattern = pattern
        self.name = name
        self.enabled = enabled
        self.bundleID = bundleID == pattern ? nil : bundleID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try c.decode(String.self, forKey: .pattern)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
    }

    /// Whether this entry is the app `value` names, by its signing identifier or its bundle id.
    func names(_ value: String) -> Bool { pattern == value || bundleID == value }

    /// `apps` with a fresh id for each repeated one (a hand-edited file), so each row keeps its
    /// own counts and its own switch.
    static func uniqueIDs(_ apps: [BypassApp]) -> [BypassApp] {
        var seen = Set<UUID>()
        return apps.map { app in
            guard !seen.insert(app.id).inserted else { return app }
            var copy = app
            copy.id = UUID()
            return copy
        }
    }

    /// The name a row shows: the app's, or its id when none was found.
    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return pattern }
        return name
    }
}

/// What the app knows about an app on disk: its name, the identifier its code is signed with, and
/// its team, read from the signature.
struct AppIdentity: Equatable {
    var name: String
    var signingID: String
    var team: String?
    /// The bundle's id, when the app has one.
    var bundleID: String?
}

/// Why an app cannot go on the list.
enum BypassAppError: Error, Equatable {
    case invalid(ProcessRule.Invalid)
    /// Already on the list, under this name.
    case alreadyListed(String)
    /// VPN Bypass itself: the extension never claims its own traffic.
    case ownApp
    /// A VPN or network-security client (by team id): it must keep its own path, so the extension
    /// never claims it.
    case vpnClient(String)

    /// The control socket's error code.
    var code: String {
        switch self {
        case .invalid: return "invalid_args"
        case .alreadyListed: return "already_exists"
        case .ownApp, .vpnClient: return "refused"
        }
    }

    /// The control socket's message, in English like the rest of its replies.
    var message: String {
        switch self {
        case .invalid(let invalid): return ProcessRule.message(invalid)
        case .alreadyListed(let name): return "\(name) is already on the Apps list"
        case .ownApp: return "VPN Bypass's own traffic always keeps its normal route"
        case .vpnClient(let name): return "\(name) is a VPN or network security app; per-app routing never takes its traffic out of its own path"
        }
    }

    /// The line the Apps page shows.
    func localizedMessage(in bundle: Bundle = .main) -> String {
        switch self {
        case .invalid: return ProcessRule.localizedMessage(in: bundle)
        case .alreadyListed(let name): return String(localized: "\(name) is already on the list.", bundle: bundle)
        case .ownApp: return String(localized: "VPN Bypass itself always keeps its normal route.", bundle: bundle)
        case .vpnClient(let name): return String(localized: "\(name) is a VPN or network security app, so it keeps its own route.", bundle: bundle)
        }
    }
}

enum BypassApps {
    /// The value an entry would hold for `pattern`, or why it cannot be added to `list`.
    /// `identity` is the app found for it, when one was: its team decides whether it is a VPN
    /// client. The checks are the ones per-app routing would decline the app for anyway
    /// (FlowDecider), so the list never holds an app that could not be served.
    static func check(_ pattern: String, identity: AppIdentity?, in list: [BypassApp]) -> Result<String, BypassAppError> {
        let value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalid = ProcessRule.invalid(value) { return .failure(.invalid(invalid)) }
        if let refusal = refusal(value, identity: identity) { return .failure(refusal) }
        if let listed = list.first(where: { $0.names(value) || (identity?.bundleID).map($0.names) == true }) {
            return .failure(.alreadyListed(listed.displayName))
        }
        return .success(value)
    }

    /// Why per-app routing would turn down an app named `value` whatever its rule says: VPN
    /// Bypass itself, or an app signed by a VPN or network-security team (`identity`'s, when one
    /// was found). The Apps list and the Rules page refuse those; nil when neither applies.
    static func refusal(_ value: String, identity: AppIdentity?) -> BypassAppError? {
        if FlowDecider.ownIdentifiers.contains(where: { $0 == value || $0.hasPrefix(value + ".") }) {
            return .ownApp
        }
        if let team = identity?.team, FlowDecider.protectedTeams.contains(team) {
            return .vpnClient(identity?.name ?? value)
        }
        return nil
    }

    /// Whether the extension turns `app` down when it connects (FlowDecider step 6): the
    /// installed app it names is signed by a VPN or network-security team, or by the team of a
    /// process that owns a live tunnel (`declinedTeams`, from the last confirmed policy). An
    /// entry added by its id before the app was installed passes the add, so this is read when
    /// the entry is shown. An executable name names no app to read a team from: the extension
    /// still turns a VPN client's process down, but only the connection can tell.
    static func isTurnedDown(_ app: BypassApp, declinedTeams: [String] = []) -> Bool {
        let id = app.bundleID ?? app.pattern
        if FlowDecider.ownIdentifiers.contains(app.pattern) { return true }
        guard ProcessRule.kind(of: id) == .bundleID, let team = lookup(id)?.team else { return false }
        return FlowDecider.protectedTeams.contains(team) || declinedTeams.contains(team)
    }

    /// The installed app signed `signingID`, for an add by id (`vpnb app.add`). A seam for tests.
    static var lookup: (String) -> AppIdentity? = { signingID in
        guard ProcessRule.kind(of: signingID) == .bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: signingID) else { return nil }
        return identity(ofAppAt: url)
    }

    /// The app at `url`: its name, and the identifier and team its code is signed with. An
    /// unsigned app is matched by its bundle id, which is what macOS reports for it.
    static func identity(ofAppAt url: URL) -> AppIdentity? {
        let bundle = Bundle(url: url)
        let signing = signingInfo(url)
        guard let id = signing.identifier ?? bundle?.bundleIdentifier, !id.isEmpty else { return nil }
        return AppIdentity(name: displayName(url, bundle: bundle),
                           signingID: matchable(id, executableName: bundle?.executableURL?.lastPathComponent),
                           team: signing.team, bundleID: bundle?.bundleIdentifier)
    }

    /// The pattern that matches an app signed `signingID`. A dotless pattern is matched by the
    /// process's executable file name, not its signing identifier (FlowPolicy's kind is the
    /// pattern's shape), so an app signed with a dotless identifier is stored by its executable's
    /// name; a dotless executable name that is, otherwise the identifier as it is.
    static func matchable(_ signingID: String, executableName: String?) -> String {
        guard ProcessRule.kind(of: signingID) == .executableName, let executableName, !executableName.isEmpty,
              ProcessRule.kind(of: executableName) == .executableName, ProcessRule.invalid(executableName) == nil else {
            return signingID
        }
        return executableName
    }

    private static func signingInfo(_ url: URL) -> (identifier: String?, team: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return (nil, nil) }
        return (dict[kSecCodeInfoIdentifier as String] as? String, dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    private static func displayName(_ url: URL, bundle: Bundle?) -> String {
        let fromBundle = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] ?? bundle?.infoDictionary?["CFBundleDisplayName"]
            ?? bundle?.infoDictionary?["CFBundleName"]) as? String
        if let fromBundle, !fromBundle.isEmpty { return fromBundle }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The icon a row shows: the installed app's, found by its id. Nil for an executable name or
    /// an app not installed; the row shows a plain glyph then. A seam for the screenshots.
    static var icon: (BypassApp) -> NSImage? = { app in
        let id = app.bundleID ?? app.pattern
        guard ProcessRule.kind(of: id) == .bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - The chooser

    /// An app the chooser offers.
    struct Candidate: Identifiable, Equatable {
        let url: URL
        let name: String
        let bundleID: String
        var isRunning: Bool
        var id: String { bundleID }
    }

    /// The running apps first, then those in the Applications folders, each once (by bundle id),
    /// by name within each part. Apps already listed are left out.
    static func candidates(running: [Candidate], installed: [Candidate], listed: [BypassApp]) -> [Candidate] {
        let taken = Set(listed.flatMap { [$0.pattern] + ($0.bundleID.map { [$0] } ?? []) })
        var seen = Set<String>()
        func take(_ list: [Candidate]) -> [Candidate] {
            list.filter { !taken.contains($0.bundleID) && !FlowDecider.ownIdentifiers.contains($0.bundleID) && seen.insert($0.bundleID).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return take(running) + take(installed)
    }

    /// The candidates on this Mac. Reads every app's Info.plist in /Applications, the system's
    /// apps in /System/Applications, both Utilities folders and ~/Applications, so call it off
    /// the main thread.
    static func loadCandidates(listed: [BypassApp]) async -> [Candidate] {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> Candidate? in
                guard app.activationPolicy == .regular, let url = app.bundleURL, let id = app.bundleIdentifier else { return nil }
                return Candidate(url: url, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                 bundleID: id, isRunning: true)
            }
        }
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var installed: [Candidate] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                installed.append(Candidate(url: url, name: displayName(url, bundle: bundle), bundleID: id, isRunning: false))
            }
        }
        return candidates(running: running, installed: installed, listed: listed)
    }

    /// The chooser's filter: by name or bundle id, ignoring case and accents.
    static func filter(_ candidates: [Candidate], search: String) -> [Candidate] {
        candidates.filter { SettingsSidebar.matches($0.name, search: search) || SettingsSidebar.matches($0.bundleID, search: search) }
    }
}

// MARK: - Which engine serves an entry

enum BypassAppServing {
    /// Whether `config` compiles the Apps list into the policy: Bypass mode, as
    /// `FlowPolicyCompiler.Input(config:)` reads it (Custom on a schema-1 config runs as Bypass).
    static func listIsLive(_ config: Config) -> Bool {
        config.routingMode != .vpnOnly
            && !RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode)
    }

    /// Per-app routing serves an entry that is on while it is active and the list is live. An
    /// entry that is off has no reason: its own switch says why.
    /// `turnedDown` (`BypassApps.isTurnedDown`): the extension declines the app's connections,
    /// so it is never served, whatever the engine does.
    static func serving(_ app: BypassApp, engine: FlowEngineState, listIsLive: Bool = true, turnedDown: Bool = false)
        -> (servedBy: RuleServedBy, reason: ProcessRule.InactiveReason?) {
        guard app.enabled else { return (.none, nil) }
        if turnedDown { return (.none, .vpnClientApp) }
        if case .unavailable = engine { return (.none, .perAppRoutingNotAvailable) }
        guard listIsLive else { return (.none, .notInBypassMode) }
        if let reason = engine.ruleReason { return (.none, reason) }
        return (.perAppEngine, nil)
    }

    /// `vpnb`'s note for an entry nothing serves.
    static func inactiveNote(reason: String?) -> String {
        guard reason != nil else { return "the app is turned off" }
        if reason == ProcessRule.InactiveReason.vpnClientApp.rawValue { return ProcessRule.inactiveNote(reason: reason) }
        return ProcessRule.inactiveNote(reason: reason) + "; until then the app uses the VPN"
    }
}

// MARK: - The list

extension RouteManager {
    /// Adds an app to the list. `identity` is the app the chooser picked, and the entry holds the
    /// identifier its code is signed with, which is what flows report. Without one (an add by
    /// id), the installed app with that id is looked up, so its name and team are known; the
    /// entry takes its signing identifier only when that differs from the id typed in case
    /// (`ProcessRule.storedPattern`), so a shorter one never widens the entry to sibling apps.
    /// Only the config changes: per-app routing picks it up with its next policy push.
    @discardableResult
    func addBypassApp(_ pattern: String, identity: AppIdentity? = nil) -> Result<BypassApp, BypassAppError> {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = identity ?? (ProcessRule.invalid(trimmed) == nil ? BypassApps.lookup(trimmed) : nil)
        let value = identity?.signingID ?? found.map { ProcessRule.storedPattern(trimmed, signingID: $0.signingID) } ?? trimmed
        switch BypassApps.check(value, identity: found, in: config.bypassApps) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            let app = BypassApp(pattern: value, name: found?.name, bundleID: found?.bundleID)
            config.bypassApps.append(app)
            saveConfig()
            log(.info, "Added app: \(app.displayName) (\(value))")
            return .success(app)
        }
    }

    /// Takes an app off the list, and returns it with where it sat, for the undo line.
    @discardableResult
    func removeBypassApp(_ id: UUID) -> (app: BypassApp, index: Int)? {
        guard let index = config.bypassApps.firstIndex(where: { $0.id == id }) else { return nil }
        let app = config.bypassApps.remove(at: index)
        saveConfig()
        log(.info, "Removed app: \(app.displayName) (\(app.pattern))")
        return (app, index)
    }

    func setBypassAppEnabled(_ id: UUID, _ on: Bool) {
        guard let index = config.bypassApps.firstIndex(where: { $0.id == id }), config.bypassApps[index].enabled != on else { return }
        config.bypassApps[index].enabled = on
        saveConfig()
        log(.info, "\(config.bypassApps[index].displayName) \(on ? "enabled" : "disabled")")
    }

    /// Puts a removed app back where it sat. False when it is listed again meanwhile.
    func restoreBypassApp(_ app: BypassApp, at index: Int) -> Bool {
        guard !config.bypassApps.contains(where: { $0.id == app.id || $0.names(app.pattern) || app.bundleID.map($0.names) == true })
        else { return false }
        config.bypassApps.insert(app, at: min(max(index, 0), config.bypassApps.count))
        saveConfig()
        log(.success, "Restored app: \(app.displayName)")
        return true
    }
}
