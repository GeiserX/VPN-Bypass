// HelperManager.swift
// Manages installation and communication with the privileged helper tool.

import AppKit
import Foundation
import ServiceManagement

// MARK: - Helper State

enum HelperState: Equatable {
    case missing
    case checking
    case installing
    case outdated(installed: String, expected: String)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
    var isFailed: Bool { if case .failed = self { return true }; return false }

    var statusText: String {
        switch self {
        case .missing: return String(localized: "Not Installed")
        case .checking: return String(localized: "Checking...")
        case .installing: return String(localized: "Installing...")
        case .outdated(let installed, let expected): return String(localized: "Update Required (v\(installed) → v\(expected))")
        case .ready: return String(localized: "Helper Installed")
        case .failed(let msg): return String(localized: "Error: \(msg)")
        }
    }
}

@MainActor
final class HelperManager: ObservableObject {
    static let shared = HelperManager()

    @Published var helperState: HelperState = .checking
    @Published var helperVersion: String?
    @Published var installationError: String?
    @Published var isInstalling = false

    /// Backwards-compatible computed property used by RouteManager
    var isHelperInstalled: Bool { helperState.isReady }

    private var xpcConnection: NSXPCConnection?

    /// XPC timeout for all helper RPCs (seconds)
    private let xpcTimeout: TimeInterval = 10

    /// Check if the helper daemon is disabled in System Settings → Login Items.
    /// Returns true if the daemon is blocked by the user, meaning we should NOT
    /// attempt reinstall (it would just prompt again next boot).
    @available(macOS 13.0, *)
    private func isDaemonDisabledByUser() -> Bool {
        let service = SMAppService.daemon(plistName: "\(kHelperToolMachServiceName).plist")
        let status = service.status
        // .notRegistered means the user toggled it off in Login Items, or it was never registered
        // .requiresApproval means macOS is blocking it pending user approval
        return status == .notRegistered || status == .requiresApproval
    }

    private init() {
        // Only set initial state — do NOT start route application here.
        // The app must call ensureHelperReady() before using helper RPCs.
        let helperPath = "/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)"
        let plistPath = "/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        if FileManager.default.fileExists(atPath: helperPath) &&
           FileManager.default.fileExists(atPath: plistPath) {
            helperState = .checking
        } else {
            helperState = .missing
        }
    }

    // MARK: - Preflight (must be awaited before any route application)

    /// Verifies the helper is installed, running, and at the expected version.
    /// If outdated, attempts an automatic update. Returns true only when helper
    /// is verified ready. Route application MUST NOT start until this returns true.
    func ensureHelperReady() async -> Bool {
        if helperState.isReady { return true }

        let helperPath = "/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)"
        let plistPath = "/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"

        // Check files exist
        if !FileManager.default.fileExists(atPath: helperPath) ||
           !FileManager.default.fileExists(atPath: plistPath) {
            // First launch or files removed — try to install
            helperState = .missing
            RouteManager.shared.log(.info, "Helper not found, attempting install...")
            let installed = await installHelper()
            if !installed {
                helperState = .failed(installationError ?? String(localized: "Installation failed"))
                return false
            }
            // Install succeeded — drop stale connection before version check
            dropXPCConnection()
        }

        // Files exist — verify version via XPC with timeout
        helperState = .checking
        // Early in boot the helper can take well over one deadline to answer (#174).
        // Reinstalling a healthy-but-slow helper fires an admin-password prompt for
        // nothing, so a timeout is retried with backoff before anything is concluded.
        let probe = await Self.probeVersionRetryingTimeouts(
            probe: { [weak self] in
                guard let self else { return .unreachable }
                return await self.probeVersion()
            },
            beforeRetry: { [weak self] in self?.dropXPCConnection() },
            log: { RouteManager.shared.log(.warning, $0) }
        )
        let expected = HelperConstants.helperVersion
        let verdict = Self.versionCheckVerdict(probe, expected: expected) {
            // A helper from before 2.3.0 still has its cdhash pin file. It refuses this app
            // because of that pin, not because of Login Items, and since it was installed with
            // launchctl, SMAppService reports it as .notRegistered. Reinstall it.
            let preTeamHelper = FileManager.default.fileExists(atPath: HelperConstants.legacyCDHashPinPath)
            // 5.1.0 left its copies quarantined, and on macOS 27 launchd would not start them.
            // That helper is unreachable for the same kind of reason: not Login Items, and
            // SMAppService reports .notRegistered for it too. Reinstalling removes the mark.
            let quarantinedCopy = Self.isQuarantined(path: helperPath) || Self.isQuarantined(path: plistPath)
            // Check if the user disabled the background item in System Settings
            guard #available(macOS 13.0, *) else { return false }
            return Self.unreachableHelperIsUsersChoice(daemonDisabled: self.isDaemonDisabledByUser(),
                                                       preTeamHelper: preTeamHelper,
                                                       quarantinedCopy: quarantinedCopy)
        }

        let version: String
        switch verdict {
        case .ready:
            helperVersion = expected
            helperState = .ready
            return true

        case .loginItemsDisabled:
            RouteManager.shared.log(.warning, "Helper daemon disabled by user in System Settings")
            helperState = .failed(String(localized: "Please enable VPN Bypass in System Settings → General → Login Items"))
            return false

        case .reinstall:
            // XPC unreachable or persistently unresponsive — helper may be corrupted or wrong arch
            RouteManager.shared.log(.warning, "Helper XPC connection failed, attempting reinstall...")
            helperState = .installing
            let reinstalled = await installHelper()
            if reinstalled {
                // Retry version check after reinstall
                dropXPCConnection()
                let retryVersion = await getVersionWithTimeout()
                if retryVersion == HelperConstants.helperVersion {
                    helperVersion = retryVersion
                    helperState = .ready
                    return true
                }
            }
            helperState = .failed(String(localized: "Cannot connect to helper after reinstall"))
            return false

        case .update(let installed):
            version = installed
        }

        RouteManager.shared.log(.info, "🔐 Helper version mismatch: installed=\(version), expected=\(expected)")
        return adoptOlderHelperAndUpdate(installed: version, expected: expected)
    }

    // MARK: - Update while the older helper keeps working

    /// A helper update that has not landed yet. The older helper answered the version check,
    /// so it routes, writes resolver files and runs the forwarder meanwhile.
    enum PendingUpdate: Equatable {
        /// The administrator password prompt is open (or about to be).
        case waiting(installed: String, expected: String)
        /// The prompt was cancelled, timed out or the install failed; the older helper still
        /// answers. Tried again on the next launch or when the user clicks Update.
        case notInstalled(installed: String, expected: String, reason: AdminInstallOutcome)

        var expected: String {
            switch self {
            case .waiting(_, let expected), .notInstalled(_, let expected, _): return expected
            }
        }
    }

    @Published var pendingUpdate: PendingUpdate?

    /// The running update (prompt, install, version check); nil when none runs.
    private(set) var updateTask: Task<Void, Never>?

    /// The older helper answered with `installed`: use it for everything it can do, and install
    /// the new one in the background. The administrator password prompt can wait for hours (a
    /// locked screen); routes, resolver files, the forwarder, the control socket and the menu
    /// must not wait with it. Returns true: the helper is usable now.
    func adoptOlderHelperAndUpdate(installed: String, expected: String) -> Bool {
        helperVersion = installed
        helperState = .ready
        startPendingUpdate(installed: installed, expected: expected)
        return true
    }

    /// Asks for the password again after a cancel, a timeout or a failure (the Update button).
    /// Does nothing while a prompt is already open, so one click never opens two.
    func retryPendingUpdate() {
        guard updateTask == nil, case .notInstalled(let installed, let expected, _)? = pendingUpdate else { return }
        startPendingUpdate(installed: installed, expected: expected)
    }

    private func startPendingUpdate(installed: String, expected: String) {
        guard updateTask == nil else { return }
        pendingUpdate = .waiting(installed: installed, expected: expected)
        installationError = nil
        RouteManager.shared.log(.info, "🔐 Updating the helper to v\(expected); v\(installed) keeps working until the administrator password is entered")
        updateTask = Task { [weak self] in
            await self?.runPendingUpdate(installed: installed, expected: expected)
            self?.updateTask = nil
        }
    }

    private func runPendingUpdate(installed: String, expected: String) async {
        NSApp?.activate(ignoringOtherApps: true)
        let outcome = await runAdminInstall()
        // The install script stops the old helper before it starts the new one, and a failed
        // script may have stopped it too: ask whichever helper answers now.
        dropXPCConnection()
        let probe = await probeVersion()
        switch (outcome, probe) {
        case (_, .version(let answered)) where answered == expected:
            helperVersion = answered
            pendingUpdate = nil
            installationError = nil
            RouteManager.shared.log(.success, "✅ Helper updated to v\(answered)")
            // The new helper started without the old one's wildcard list or resolver files.
            RouteManager.shared.wildcards.helperRestarted()
        case (_, .version(let answered)):
            // Still the older helper (cancel, timeout, or an install that changed nothing).
            helperVersion = answered
            let reason: AdminInstallOutcome = outcome == .installed
                ? .failed("v\(answered) still answers after the install") : outcome
            pendingUpdate = .notInstalled(installed: answered, expected: expected, reason: reason)
            if case .failed(let message) = reason { installationError = message }
            RouteManager.shared.log(.warning, "Helper update to v\(expected) not installed (\(reason.logText)); still using v\(answered). Click Update in Settings → Status to try again.")
        case (_, .unreachable), (_, .timedOut):
            // The script stopped the old helper and the new one did not start: nothing routes.
            pendingUpdate = nil
            let detail = outcome.localizedText
            installationError = detail
            helperState = .failed(String(localized: "Helper update failed: \(detail)"))
            RouteManager.shared.log(.error, "❌ Helper update to v\(expected) failed and no helper answers (\(detail))")
        }
    }

    /// The text `vpnb status` shows for the helper: its state, and an update that waits.
    var statusSummary: String {
        guard helperState.isReady, let pendingUpdate, let helperVersion else { return helperState.statusText }
        return String(localized: "Helper v\(helperVersion) running, update to v\(pendingUpdate.expected) pending")
    }

    // MARK: - What an older helper can do

    /// The helper version each XPC method first shipped in. While an update waits, the running
    /// helper can be older than this app, and a call it does not know never gets a reply, only
    /// the deadline. Such a call is answered at once as unavailable instead.
    enum MethodSince {
        static let listTunnelOwners = "2.2.0"
        static let dnsCapture = "2.4.0"
        static let wildcards = "2.5.0"
        static let blockRoutes = "2.6.0"
    }

    /// Whether helper `running` has a method that shipped in `minimum`. An unknown version
    /// counts as new enough: it is only nil before the first version check.
    nonisolated static func helper(_ running: String?, supports minimum: String) -> Bool {
        guard let running else { return true }
        let a = running.split(separator: ".").map { Int($0) ?? 0 }
        let b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    private func runningHelperSupports(_ minimum: String) -> Bool {
        Self.helper(helperVersion, supports: minimum)
    }

    // MARK: - XPC Connection

    private func dropXPCConnection() {
        xpcConnection?.invalidate()
        xpcConnection = nil
    }

    private func getOrCreateConnection() -> NSXPCConnection {
        if let connection = xpcConnection {
            return connection
        }

        let connection = NSXPCConnection(machServiceName: kHelperToolMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)

        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.xpcConnection = nil
            }
        }

        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.xpcConnection = nil
            }
        }

        connection.resume()
        xpcConnection = connection
        return connection
    }

    /// Get a proxy with error handler. On XPC error, the errorHandler fires
    /// instead of the reply block, preventing silent hangs.
    private nonisolated func getProxyWithErrorHandler(
        connection: NSXPCConnection,
        errorHandler: @escaping (Error) -> Void
    ) -> HelperProtocol? {
        return connection.remoteObjectProxyWithErrorHandler { error in
            errorHandler(error)
        } as? HelperProtocol
    }

    // MARK: - Version Check with Timeout

    /// Outcome of a version probe. Distinguishing `timedOut` (the helper may just be
    /// slow under launch load) from `unreachable` (XPC error / no proxy — the helper
    /// is likely broken) lets the caller retry a slow helper instead of firing an
    /// intrusive admin-password reinstall for a perfectly healthy one.
    enum VersionProbe: Sendable, Equatable {
        case version(String)
        case unreachable
        case timedOut
    }

    /// What the launch version check decided.
    enum VersionCheckVerdict: Equatable {
        case ready
        case update(installed: String)
        case reinstall
        case loginItemsDisabled
    }

    /// Decides from a (retried) version probe whether the helper is ready, needs updating,
    /// needs reinstalling, or was turned off by the user. `unreachableIsUsersChoice` is
    /// consulted only when the helper gave no version.
    static func versionCheckVerdict(_ probe: VersionProbe, expected: String,
                                    unreachableIsUsersChoice: () -> Bool) -> VersionCheckVerdict {
        guard case .version(let version) = probe else {
            return unreachableIsUsersChoice() ? .loginItemsDisabled : .reinstall
        }
        return version == expected ? .ready : .update(installed: version)
    }

    /// Waits between version probes after a timeout: with the 10 s deadline per probe,
    /// five probes and these pauses give a slow helper about 60 s to answer (#174).
    nonisolated static let versionRetryDelays: [TimeInterval] = [2, 4, 4, 4]

    /// Probes the helper's version, retrying only timeouts. An answer or an XPC error
    /// returns at once: an error means the helper is really unreachable, and retrying it
    /// would only delay the reinstall. Returns `.timedOut` if every probe timed out.
    static func probeVersionRetryingTimeouts(
        delays: [TimeInterval] = versionRetryDelays,
        probe: () async -> VersionProbe,
        beforeRetry: () -> Void = {},
        sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        log: (String) -> Void
    ) async -> VersionProbe {
        var result = await probe()
        var attempt = 1
        for delay in delays {
            guard case .timedOut = result else { break }
            log("Helper version check timed out (attempt \(attempt) of \(delays.count + 1)); retrying in \(Int(delay)) s before deciding anything")
            await sleep(delay)
            beforeRetry()
            result = await probe()
            attempt += 1
        }
        if attempt > 1 {
            switch result {
            case .version(let v): log("Helper answered the version check on attempt \(attempt) (v\(v)); no reinstall needed")
            case .unreachable: log("Helper became unreachable on attempt \(attempt)")
            case .timedOut: log("Helper did not answer the version check in \(attempt) attempts; treating it as broken")
            }
        }
        return result
    }

    /// Answers the version probe instead of XPC, for tests.
    var versionProbeOverrideForTests: (() async -> VersionProbe)?

    private func probeVersion() async -> VersionProbe {
        if let override = versionProbeOverrideForTests { return await override() }
        let connection = getOrCreateConnection()
        let result = await withXPCDeadline(seconds: xpcTimeout, fallback: VersionProbe.timedOut) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                // After a timeout the retry drops the connection, which fires this
                // handler for the abandoned call; log only an error that decided the check.
                if once.complete(.unreachable) {
                    RouteManager.shared.log(.error, "XPC error during getVersion: \(error.localizedDescription)")
                }
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete(.unreachable)
                return
            }

            helper.getVersion { version in
                once.complete(.version(version))
            }
        }
        return result
    }

    /// Thin string-returning wrapper for the post-reinstall verification callers,
    /// where any non-version outcome equally means "not the version we expect".
    private func getVersionWithTimeout() async -> String? {
        if case .version(let v) = await probeVersion() { return v }
        return nil
    }

    /// Which process owns each `utun`, via the helper.
    ///
    /// `nil` means "could not ask" — helper absent, too old to know the method, or timed out.
    /// An empty array means the sweep ran and found nothing, which is a real answer and must
    /// clear the map: utun numbers are recycled, so holding a departed tunnel's label would
    /// eventually apply it to an unrelated tunnel. Cosmetic either way — this never influences
    /// which tunnel gets routed.
    func tunnelOwners() async -> [TunnelOwner]? {
        guard isHelperInstalled, runningHelperSupports(MethodSince.listTunnelOwners) else { return nil }
        let connection = getOrCreateConnection()
        return await withXPCDeadline(seconds: xpcTimeout, fallback: [TunnelOwner]?.none) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                // An older helper simply has no such method; that is expected during the
                // upgrade window and is not worth an error line on every status pass.
                once.complete(nil)
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete(nil)
                return
            }

            helper.listTunnelOwners { ok, rows in
                once.complete(ok ? rows.compactMap(TunnelOwner.init(dictionary:)) : nil)
            }
        }
    }

    // MARK: - DNS Lookups capture

    /// Starts the helper's DNS capture. `nil` when it runs, otherwise why it does not.
    func startDNSCapture() async -> String? {
        guard isHelperInstalled else { return String(localized: "The privileged helper is not running.") }
        guard runningHelperSupports(MethodSince.dnsCapture) else {
            return String(localized: "This needs a newer helper. Update it in Settings → Status.")
        }
        let connection = getOrCreateConnection()
        return await withXPCDeadline(seconds: xpcTimeout, fallback: String?.some(String(localized: "The privileged helper did not answer."))) { once in
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
                once.complete(String(localized: "The privileged helper did not answer."))
            }) as? HelperProtocol else {
                once.complete(String(localized: "The privileged helper did not answer."))
                return
            }
            helper.startDNSCapture { ok, error in
                once.complete(ok ? nil : (error ?? String(localized: "The capture could not start.")))
            }
        }
    }

    func stopDNSCapture() async {
        guard isHelperInstalled, runningHelperSupports(MethodSince.dnsCapture) else { return }
        let connection = getOrCreateConnection()
        await withXPCDeadline(seconds: xpcTimeout, fallback: ()) { once in
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in once.complete(()) }) as? HelperProtocol else {
                once.complete(())
                return
            }
            helper.stopDNSCapture { once.complete(()) }
        }
    }

    /// The names queried since the last drain; `nil` when the capture is not running or the
    /// helper could not be asked.
    func drainDNSQueries() async -> [String]? {
        guard isHelperInstalled, runningHelperSupports(MethodSince.dnsCapture) else { return nil }
        let connection = getOrCreateConnection()
        return await withXPCDeadline(seconds: xpcTimeout, fallback: [String]?.none) { once in
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in once.complete(nil) }) as? HelperProtocol else {
                once.complete(nil)
                return
            }
            helper.drainDNSQueries { running, names in
                once.complete(running ? names : nil)
            }
        }
    }

    // MARK: - Wildcard domains

    /// Sets the wildcards the helper's forwarder serves; an empty list stops it.
    func setWildcards(_ specs: [WildcardSpec], guard safetyGuard: WildcardSafetyGuard) async -> (ok: Bool, unserved: [String], error: String?) {
        guard isHelperInstalled else { return (false, [], "the privileged helper is not running") }
        guard runningHelperSupports(MethodSince.wildcards) else {
            return (false, [], "helper v\(helperVersion ?? "?") predates wildcards; they start once the helper update is installed")
        }
        let connection = getOrCreateConnection()
        let failed = (ok: false, unserved: [String](), error: Optional("the privileged helper did not answer"))
        // The helper may flush the resolver caches (two bounded children of 3 s each).
        return await withXPCDeadline(seconds: xpcTimeout + 6, fallback: failed) { once in
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in once.complete(failed) }) as? HelperProtocol else {
                once.complete(failed)
                return
            }
            helper.setWildcards(specs: specs.map(\.dictionary), context: safetyGuard.dictionary) { ok, unserved, error in
                once.complete((ok, unserved, error))
            }
        }
    }

    /// The routes the forwarder learned since the last drain; nil when the helper could not be asked.
    func drainWildcardRoutes() async -> (running: Bool, routes: [LearnedWildcardRoute])? {
        guard isHelperInstalled, runningHelperSupports(MethodSince.wildcards) else { return nil }
        let connection = getOrCreateConnection()
        return await withXPCDeadline(seconds: xpcTimeout, fallback: (running: Bool, routes: [LearnedWildcardRoute])?.none) { once in
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in once.complete(nil) }) as? HelperProtocol else {
                once.complete(nil)
                return
            }
            helper.drainWildcardRoutes { running, routes in
                once.complete((running, routes.compactMap(LearnedWildcardRoute.init(dictionary:))))
            }
        }
    }

    // MARK: - Helper Installation

    func installHelper() async -> Bool {
        RouteManager.shared.log(.info, "🔐 Installing privileged helper...")
        isInstalling = true
        helperState = .installing
        defer {
            isInstalling = false
        }

        // Activate the app so the admin prompt appears on top
        NSApp.activate(ignoringOtherApps: true)

        if #available(macOS 13.0, *) {
            return await installHelperModern()
        } else {
            return await installHelperLegacy()
        }
    }

    @available(macOS 13.0, *)
    private func installHelperModern() async -> Bool {
        // SMAppService.register() succeeds even when an older helper is already
        // installed — it re-registers the service but does NOT replace the on-disk
        // binary. For updates we must always go through the legacy path which does
        // the actual file copy. Only use SMAppService for first-time installs.
        let helperPath = "/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)"
        let plistPath = "/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        if FileManager.default.fileExists(atPath: helperPath) {
            RouteManager.shared.log(.info, "🔐 Helper exists on disk, using legacy path for update...")
            return await installHelperLegacy()
        }

        do {
            let service = SMAppService.daemon(plistName: "\(kHelperToolMachServiceName).plist")
            try service.register()   // synchronous throwing API — no await needed

            RouteManager.shared.log(.success, "✅ Helper registered successfully via SMAppService")

            // SMAppService.register() can report success without actually placing the
            // binary/plist on disk (observed with enterprise security tools like Zscaler).
            // Verify both files exist before trusting the registration.
            if !FileManager.default.fileExists(atPath: helperPath) ||
               !FileManager.default.fileExists(atPath: plistPath) {
                RouteManager.shared.log(.warning, "⚠️ SMAppService reported success but helper files missing on disk, falling back to legacy install...")
                return await installHelperLegacy()
            }

            installationError = nil
            return true
        } catch {
            RouteManager.shared.log(.warning, "⚠️ SMAppService failed: \(error.localizedDescription)")
            RouteManager.shared.log(.info, "🔐 Falling back to legacy install...")
            return await installHelperLegacy()
        }
    }

    /// Escape a string for safe inclusion inside a shell single-quoted context (`'…'`):
    /// a literal `'` is closed, backslash-escaped, and reopened (`'\''`).
    private nonisolated static func shSingleQuoteEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Escape a shell command for inclusion inside an AppleScript double-quoted string:
    /// backslashes first (so escapes we add next aren't double-processed), then quotes.
    nonisolated static func appleScriptStringEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Whether an unreachable helper is the user's doing (the background item is off in Login
    /// Items), in which case a reinstall would only prompt again on every launch (#25). Two
    /// known states look the same to SMAppService and are ours to repair: a helper from before
    /// 2.3.0, and copies that still carry the quarantine mark.
    nonisolated static func unreachableHelperIsUsersChoice(daemonDisabled: Bool, preTeamHelper: Bool, quarantinedCopy: Bool) -> Bool {
        daemonDisabled && !preTeamHelper && !quarantinedCopy
    }

    /// Whether the file at `path` carries com.apple.quarantine. False for a missing file.
    nonisolated static func isQuarantined(path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// The root shell script the legacy installer runs: replace the helper and its launchd
    /// plist with the copies from this app bundle, then start the daemon.
    ///
    /// The sources derive from Bundle.main.bundlePath, so a bundle path containing a single
    /// quote (e.g. /Users/o'brien/…/VPN Bypass.app) would otherwise break out of the 'cp …'
    /// single-quoting and inject commands into this ROOT admin script. Every path is escaped
    /// for the shell layer here; the caller escapes the whole command for AppleScript.
    nonisolated static func legacyInstallShellCommand(helperSource: String, plistSource: String) -> String {
        let hs = shSingleQuoteEscaped(helperSource)
        let ps = shSingleQuoteEscaped(plistSource)
        let hd = shSingleQuoteEscaped("/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)")
        let pd = shSingleQuoteEscaped("/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist")
        // Helpers before 2.3.0 authorized the app by a cdhash pinned in this file. The team
        // requirement replaced it, so remove the leftover in the same admin op.
        let oldPin = shSingleQuoteEscaped(HelperConstants.legacyCDHashPinPath)

        // An app that came from Homebrew or a browser download carries com.apple.quarantine,
        // and `cp` copies it onto the helper and the plist. Since macOS 27 launchd refuses a
        // quarantined plist or program (error 155; `launchctl bootstrap` prints "Bootstrap
        // failed: 5"), so the mark comes off both copies before the bootstrap. `cp` onto an existing file
        // keeps that file's own attributes, which is why this is a removal and not `cp -X`:
        // a copy left quarantined by 5.1.0 has to be cleaned too.
        return """
        mkdir -p /Library/PrivilegedHelperTools
        launchctl bootout system/\(kHelperToolMachServiceName) 2>/dev/null || true
        cp '\(hs)' '\(hd)'
        chmod 544 '\(hd)'
        chown root:wheel '\(hd)'
        xattr -d com.apple.quarantine '\(hd)' 2>/dev/null || true
        cp '\(ps)' '\(pd)'
        chmod 644 '\(pd)'
        chown root:wheel '\(pd)'
        xattr -d com.apple.quarantine '\(pd)' 2>/dev/null || true
        rm -f '\(oldPin)'
        launchctl bootstrap system '\(pd)'
        """
    }

    private func installHelperLegacy() async -> Bool {
        let outcome = await runAdminInstall()
        switch outcome {
        case .installed:
            installationError = nil
            return true
        case .cancelled, .timedOut:
            installationError = outcome.localizedText
            return false
        case .failed(let message):
            installationError = message
            return false
        }
    }

    // MARK: - The administrator password prompt, off the main thread

    /// How the admin-password install ended.
    enum AdminInstallOutcome: Equatable, Sendable {
        case installed
        case cancelled
        case timedOut
        case failed(String)

        /// English, for the log and the error line.
        var logText: String {
            switch self {
            case .installed: return "installed"
            case .cancelled: return "the password prompt was cancelled"
            case .timedOut: return "no password was entered in \(Int(HelperManager.adminPromptTimeout / 60)) minutes"
            case .failed(let message): return message
            }
        }

        /// The same, in the user's language, for the Status page.
        var localizedText: String {
            switch self {
            case .installed: return logText
            case .cancelled: return String(localized: "The administrator password prompt was cancelled.")
            case .timedOut: return String(localized: "No administrator password was entered in time.")
            case .failed(let message): return message
            }
        }
    }

    /// How long the password prompt stays open. Past it the prompt closes and the older helper
    /// keeps working; the next launch or the Update button asks again.
    nonisolated static let adminPromptTimeout: TimeInterval = 600

    /// Runs the install behind the administrator password prompt. It blocks until the user
    /// answers, cancels, or the prompt times out, which can be hours on a locked screen, so it
    /// is only ever called through `runOffMain`. Replaced in tests by an installer that waits.
    nonisolated(unsafe) static var adminInstall: @Sendable () -> AdminInstallOutcome = { installFromBundleWithPassword() }

    /// Runs blocking `work` on a global queue, so the main thread (the control socket's
    /// handler, the status passes, the menu) keeps running while it waits.
    nonisolated static func runOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    private func runAdminInstall() async -> AdminInstallOutcome {
        RouteManager.shared.log(.info, "🔐 Asking for the administrator password to install the helper...")
        let outcome = await Self.runOffMain(Self.adminInstall)
        switch outcome {
        case .installed: RouteManager.shared.log(.success, "✅ Helper files installed")
        case .cancelled, .timedOut: break   // the caller says what happens next, once
        case .failed(let message): RouteManager.shared.log(.error, "❌ Helper install failed: \(message)")
        }
        return outcome
    }

    /// The install itself: copy the helper and its launchd plist out of this app bundle as
    /// root, through `osascript` (NSAppleScript belongs on the main thread, and this waits on
    /// the password). Blocking.
    nonisolated static func installFromBundleWithPassword() -> AdminInstallOutcome {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            return .failed(String(localized: "Not running from app bundle"))
        }
        let helperSource = "\(bundlePath)/Contents/MacOS/\(kHelperToolMachServiceName)"
        let plistSource = "\(bundlePath)/Contents/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        guard FileManager.default.fileExists(atPath: helperSource) else {
            return .failed(String(localized: "Helper binary not found in app bundle"))
        }
        guard FileManager.default.fileExists(atPath: plistSource) else {
            return .failed(String(localized: "Helper plist not found in app bundle"))
        }

        let shellCommand = legacyInstallShellCommand(helperSource: helperSource, plistSource: plistSource)
        let prompt = String(localized: "VPN Bypass needs your administrator password to update its helper.")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", adminScript(shellCommand: shellCommand, prompt: prompt)]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        switch ProcessDeadline.run(process, seconds: adminPromptTimeout) {
        case .failedToStart:
            return .failed("osascript could not start")
        case .timedOut:
            return .timedOut
        case .exited(let status):
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return adminScriptOutcome(status: status, stderr: text)
        }
    }

    /// The AppleScript `osascript` runs: the root shell command behind the password prompt.
    nonisolated static func adminScript(shellCommand: String, prompt: String) -> String {
        "do shell script \"\(appleScriptStringEscaped(shellCommand))\" with prompt \"\(appleScriptStringEscaped(prompt))\" with administrator privileges"
    }

    /// Reads how `osascript` ended. A cancelled prompt is AppleScript error -128.
    nonisolated static func adminScriptOutcome(status: Int32, stderr: String) -> AdminInstallOutcome {
        if status == 0 { return .installed }
        if stderr.contains("(-128)") { return .cancelled }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "osascript exited with \(status)" : message)
    }

    // MARK: - Route Operations (all with hard XPC deadline)

    func addRoute(destination: String, gateway: String, isNetwork: Bool = false) async -> (success: Bool, error: String?) {
        guard helperState.isReady else {
            return (false, "Helper not ready (\(helperState.statusText))")
        }

        let connection = getOrCreateConnection()
        let fallback: (Bool, String?) = (false, "XPC timeout after \(Int(xpcTimeout))s")
        let result = await withXPCDeadline(seconds: xpcTimeout, fallback: fallback) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.complete((false, "XPC error: \(error.localizedDescription)"))
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete((false, "Failed to create XPC proxy"))
                return
            }

            helper.addRoute(destination: destination, gateway: gateway, isNetwork: isNetwork) { success, error in
                once.complete((success, error))
            }
        }

        if result == fallback { dropXPCConnection() }
        return result
    }

    func removeRoute(destination: String) async -> (success: Bool, error: String?) {
        guard helperState.isReady else {
            return (false, "Helper not ready (\(helperState.statusText))")
        }

        let connection = getOrCreateConnection()
        let fallback: (Bool, String?) = (false, "XPC timeout after \(Int(xpcTimeout))s")
        let result = await withXPCDeadline(seconds: xpcTimeout, fallback: fallback) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.complete((false, "XPC error: \(error.localizedDescription)"))
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete((false, "Failed to create XPC proxy"))
                return
            }

            helper.removeRoute(destination: destination) { success, error in
                once.complete((success, error))
            }
        }

        if result == fallback { dropXPCConnection() }
        return result
    }

    // MARK: - Batch Route Operations

    func addRoutesBatch(routes: [(destination: String, gateway: String, isNetwork: Bool)]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        guard helperState.isReady else {
            return (0, routes.count, routes.map { $0.destination }, "Helper not ready (\(helperState.statusText))")
        }

        let dictRoutes = routes.map { route -> [String: Any] in
            [
                "destination": route.destination,
                "gateway": route.gateway,
                "isNetwork": route.isNetwork
            ]
        }
        let allDests = routes.map { $0.destination }
        // Budget 0.6s per route. Since 1.10.0 the helper reads before it writes, so the worst
        // realistic path for a route that must actually be installed is THREE subprocesses
        // (`route get` + a failed `route change` + `route add`), not the two the old 0.25s figure
        // assumed. Spawn cost is also far above the 0.07s that figure was calibrated against on
        // machines running endpoint-security agents — which is precisely the population running a
        // corporate VPN. Under-budgeting here does not just slow things down: the batch reports as
        // indeterminate, the connection is dropped, and the retry queues behind the abandoned work.
        // A steady-state re-apply costs one read and no writes, so this ceiling is rarely reached.
let timeout = xpcTimeout + Double(routes.count) * 0.6
        // On a DEADLINE timeout (not an XPC error — the call DID reach the helper), the helper may
        // be slow rather than dead and have installed some/all routes without confirming. Reporting
        // them as failed strands orphaned kernel routes the app never tracks — a leak that survives
        // disconnect and quit. Report an INDETERMINATE result (no confirmed failures) so the caller
        // records the attempted destinations as active; a later teardown then removes them
        // (removeRoutesBatch tolerates already-absent routes). The XPC-error / nil-proxy paths below
        // keep reporting allDests failed — those genuinely never installed.
        let fallback = (0, 0, [String](), Optional("XPC timeout"))

        let connection = getOrCreateConnection()
        let result = await withXPCDeadline(seconds: timeout, fallback: fallback) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.complete((0, routes.count, allDests, Optional("XPC error: \(error.localizedDescription)")))
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete((0, routes.count, allDests, Optional("Failed to create XPC proxy")))
                return
            }

            helper.addRoutesBatch(routes: dictRoutes) { successCount, failureCount, failedDestinations, error in
                once.complete((successCount, failureCount, failedDestinations, error))
            }
        }

        if result.3 == "XPC timeout" {
            RouteManager.shared.log(.warning, "Route batch timed out — recording \(allDests.count) attempted route(s) as active so teardown can remove them")
            dropXPCConnection()
        }
        return result
    }

    func removeRoutesBatch(destinations: [String]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        guard helperState.isReady else {
            return (0, destinations.count, destinations, "Helper not ready (\(helperState.statusText))")
        }

        // Budget 0.25s per route: helper runs one /sbin/route delete per destination
        // at ~0.07s each. Using same budget as addRoutesBatch for consistency.
        let timeout = xpcTimeout + Double(destinations.count) * 0.25
        let fallback = (0, destinations.count, destinations, Optional("XPC timeout"))

        let connection = getOrCreateConnection()
        let result = await withXPCDeadline(seconds: timeout, fallback: fallback) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.complete((0, destinations.count, destinations, Optional("XPC error: \(error.localizedDescription)")))
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete((0, destinations.count, destinations, Optional("Failed to create XPC proxy")))
                return
            }

            helper.removeRoutesBatch(destinations: destinations) { successCount, failureCount, failedDestinations, error in
                once.complete((successCount, failureCount, failedDestinations, error))
            }
        }

        if result.3 == "XPC timeout" { dropXPCConnection() }
        return result
    }

    /// VPN Only blocks (`HelperProtocol.addBlockRoutesBatch`). Two writes per destination at
    /// worst (delete, then add), so the add batch's budget. A deadline timeout reached the
    /// helper, so, as for `addRoutesBatch`, nothing is reported failed: the caller keeps every
    /// destination on its list of blocks and a later removal clears any that never landed.
    func addBlockRoutesBatch(destinations: [String]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        guard helperState.isReady else {
            return (0, destinations.count, destinations, "Helper not ready (\(helperState.statusText))")
        }
        guard runningHelperSupports(MethodSince.blockRoutes) else {
            return (0, destinations.count, destinations, "helper v\(helperVersion ?? "?") predates VPN Only blocks; they start once the helper update is installed")
        }
        let timeout = xpcTimeout + Double(destinations.count) * 0.6
        let fallback = (0, 0, [String](), Optional("XPC timeout"))

        let connection = getOrCreateConnection()
        let result = await withXPCDeadline(seconds: timeout, fallback: fallback) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.complete((0, destinations.count, destinations, Optional("XPC error: \(error.localizedDescription)")))
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete((0, destinations.count, destinations, Optional("Failed to create XPC proxy")))
                return
            }

            helper.addBlockRoutesBatch(destinations: destinations) { successCount, failureCount, failedDestinations, error in
                once.complete((successCount, failureCount, failedDestinations, error))
            }
        }

        if result.3 == "XPC timeout" { dropXPCConnection() }
        return result
    }

    // MARK: - Hosts File Operations

    func updateHostsFile(entries: [(domain: String, ip: String)]) async -> (success: Bool, error: String?) {
        guard helperState.isReady else {
            return (false, "Helper not ready (\(helperState.statusText))")
        }

        let dictEntries = entries.map { ["domain": $0.domain, "ip": $0.ip] }

        let connection = getOrCreateConnection()
        // Hosts updates queue on the helper's serial mutation queue BEHIND any in-flight route
        // batch, and batches are now deliberately paced (a couple of seconds for hundreds of
        // routes) — the flat 10s deadline was observed timing out exactly there. 30s covers the
        // worst paced batch with margin; the helper stays responsive either way.
        let hostsTimeout: TimeInterval = max(xpcTimeout, 30)
        let fallback: (Bool, String?) = (false, "XPC timeout after \(Int(hostsTimeout))s")
        let result = await withXPCDeadline(seconds: hostsTimeout, fallback: fallback) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.complete((false, "XPC error: \(error.localizedDescription)"))
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete((false, "Failed to create XPC proxy"))
                return
            }

            helper.updateHostsFile(entries: dictEntries) { success, error in
                if success {
                    helper.flushDNSCache { _ in
                        once.complete((true, nil))
                    }
                } else {
                    once.complete((false, error))
                }
            }
        }

        if result == fallback { dropXPCConnection() }
        return result
    }
}

// MARK: - XPC Deadline (hard timeout via DispatchQueue timer)

/// Ensures exactly-once delivery of a result to a CheckedContinuation.
/// Either the XPC reply or the DispatchQueue deadline fires — whichever
/// comes first wins, the other is silently dropped.
final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// Returns true when this call delivered the value, false when an earlier
    /// call (the reply or the deadline) already won.
    @discardableResult
    func complete(_ value: sending T) -> Bool {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return false }
        cont.resume(returning: value)
        return true
    }
}

/// Runs a synchronous XPC call block with a hard deadline. The block receives
/// a `OnceGate` that it must call `complete()` on when the XPC reply arrives.
/// If the deadline fires first, the gate delivers `fallback` and subsequent
/// `complete()` calls from the XPC reply are silently dropped.
@MainActor private func withXPCDeadline<T: Sendable>(
    seconds: TimeInterval,
    fallback: T,
    operation: @escaping (OnceGate<T>) -> Void
) async -> T {
    await withCheckedContinuation { continuation in
        let gate = OnceGate(continuation: continuation)

        // Hard deadline — fires on a background queue, does not depend on
        // cooperative task cancellation or the XPC reply ever arriving.
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            gate.complete(fallback)
        }

        operation(gate)
    }
}
