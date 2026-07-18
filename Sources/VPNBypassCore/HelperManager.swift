// HelperManager.swift
// Manages installation and communication with the privileged helper tool.

import AppKit
import Foundation
import ServiceManagement
import Security

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
        // Fast path: already verified
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
        var probe = await probeVersion()
        if case .timedOut = probe {
            // The helper may just be slow under launch load — retry once before
            // concluding it needs reinstalling. Reinstalling a healthy-but-busy
            // helper would fire an intrusive admin-password prompt for nothing.
            RouteManager.shared.log(.warning, "Helper version probe timed out; retrying before reinstall")
            probe = await probeVersion()
        }
        let version: String? = { if case .version(let v) = probe { return v } else { return nil } }()

        guard let version = version else {
            // Check if the user disabled the background item in System Settings
            if #available(macOS 13.0, *), isDaemonDisabledByUser() {
                RouteManager.shared.log(.warning, "Helper daemon disabled by user in System Settings")
                helperState = .failed(String(localized: "Please enable VPN Bypass in System Settings → General → Login Items"))
                return false
            }

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
        }

        helperVersion = version
        let expected = HelperConstants.helperVersion

        if version == expected {
            // Fail-closed readiness gate: the 1.8.0 helper rejects XPC callers without a
            // matching cdhash pin, so a *successful* version probe already implies the pin is
            // present and matches this app. Re-check the pin file here as defense-in-depth and
            // to self-heal a stale pin: if we can compute our own cdhash and the pin file is
            // absent/stale, reinstall (re-writes the pin) rather than marking ready.
            if readinessPinSatisfied() {
                helperState = .ready
                return true
            }
            RouteManager.shared.log(.warning, "🔐 Helper \(version) present but cdhash pin missing/stale; reinstalling to restore fail-closed auth")
            helperState = .installing
            let repinned = await installHelper()
            if repinned {
                dropXPCConnection()
                if await getVersionWithTimeout() == expected, readinessPinSatisfied() {
                    helperVersion = expected
                    helperState = .ready
                    return true
                }
            }
            helperState = .failed(String(localized: "Helper security pin could not be restored"))
            return false
        }

        // Version mismatch — update
        RouteManager.shared.log(.info, "🔐 Helper version mismatch: installed=\(version), expected=\(expected)")
        helperState = .outdated(installed: version, expected: expected)

        RouteManager.shared.log(.info, "🔐 Auto-updating helper...")
        let updated = await installHelper()
        if !updated {
            helperState = .failed(String(localized: "Helper update failed: \(installationError ?? String(localized: "unknown"))"))
            return false
        }

        // Verify the update succeeded
        dropXPCConnection()
        let newVersion = await getVersionWithTimeout()
        if newVersion == expected {
            helperVersion = newVersion
            helperState = .ready
            return true
        }

        helperState = .failed(String(localized: "Helper update did not take effect (got \(newVersion ?? "nil"), expected \(expected))"))
        return false
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
    private enum VersionProbe: Sendable {
        case version(String)
        case unreachable
        case timedOut
    }

    private func probeVersion() async -> VersionProbe {
        let connection = getOrCreateConnection()
        let result = await withXPCDeadline(seconds: xpcTimeout, fallback: VersionProbe.timedOut) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                RouteManager.shared.log(.error, "XPC error during getVersion: \(error.localizedDescription)")
                once.complete(.unreachable)
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
            return installHelperLegacy()
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
            return installHelperLegacy()
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
                return installHelperLegacy()
            }

            // The legacy path writes the cdhash pin inline; SMAppService doesn't. The 1.8.0
            // helper is FAIL-CLOSED on the pin, so a pin-less helper is unusable (it rejects
            // every caller), not merely degraded — we must GUARANTEE the pin here. If we can
            // confirm it landed, the modern install is complete; otherwise fall back to the
            // legacy installer, which writes helper+pin atomically in one admin op.
            if ensureCDHashPinned() {
                installationError = nil
                return true
            }

            RouteManager.shared.log(.warning, "⚠️ cdhash pin not confirmed after SMAppService register; falling back to legacy install to guarantee it")
            if installHelperLegacy() {
                return true
            }

            // Anti-brick invariant: never leave a helper installed without a valid pin.
            // Neither the modern-pin nor the legacy path secured it, so boot the helper out —
            // the app then sees no live helper and prompts for a clean reinstall (recoverable),
            // rather than a wedged fail-closed helper masquerading as "installed".
            RouteManager.shared.log(.error, "❌ Could not secure the cdhash pin via modern or legacy install; booting out the unpinned helper")
            bootOutHelper()
            // If bootOutHelper() itself also fails, a pin-less fail-closed helper may be left
            // running — but that is recoverable, NOT a brick: we return false so isHelperInstalled
            // stays false (never .ready), and the next ensureHelperReady finds the fail-closed
            // helper rejects its XPC probe (unreachable) and reinstalls + re-pins.
            if installationError == nil {
                installationError = String(localized: "Could not secure the helper. Please try installing again.")
            }
            return false
        } catch {
            RouteManager.shared.log(.warning, "⚠️ SMAppService failed: \(error.localizedDescription)")
            RouteManager.shared.log(.info, "🔐 Falling back to legacy install...")
            return installHelperLegacy()
        }
    }

    /// Escape a string for safe inclusion inside a shell single-quoted context (`'…'`):
    /// a literal `'` is closed, backslash-escaped, and reopened (`'\''`).
    private static func shSingleQuoteEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Escape a shell command for inclusion inside an AppleScript double-quoted string:
    /// backslashes first (so escapes we add next aren't double-processed), then quotes.
    private static func appleScriptStringEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func installHelperLegacy() -> Bool {
        RouteManager.shared.log(.info, "🔐 Attempting manual helper installation via AppleScript...")

        guard let bundlePath = Bundle.main.bundlePath as String?,
              bundlePath.hasSuffix(".app") else {
            installationError = "Not running from app bundle"
            return false
        }

        let helperSource = "\(bundlePath)/Contents/MacOS/\(kHelperToolMachServiceName)"
        let plistSource = "\(bundlePath)/Contents/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        let helperDest = "/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)"
        let plistDest = "/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"

        guard FileManager.default.fileExists(atPath: helperSource) else {
            installationError = "Helper binary not found in app bundle"
            RouteManager.shared.log(.error, "❌ Helper not found at: \(helperSource)")
            return false
        }

        guard FileManager.default.fileExists(atPath: plistSource) else {
            installationError = "Helper plist not found in app bundle"
            RouteManager.shared.log(.error, "❌ Plist not found at: \(plistSource)")
            return false
        }

        // helperSource/plistSource derive from Bundle.main.bundlePath, so a bundle path
        // containing a single quote (e.g. /Users/o'brien/…/VPN Bypass.app) would otherwise
        // break out of the 'cp …' single-quoting and inject commands into this ROOT admin
        // script. Escape ' as '\'' for the shell layer, then escape the whole command for
        // the AppleScript double-quoted string layer (\ and "). The dest/pin paths are
        // constants and cdhash is [0-9a-f], but they go through the same escaping uniformly.
        let hs = Self.shSingleQuoteEscaped(helperSource)
        let ps = Self.shSingleQuoteEscaped(plistSource)
        let hd = Self.shSingleQuoteEscaped(helperDest)
        let pd = Self.shSingleQuoteEscaped(plistDest)
        let pinPath = Self.shSingleQuoteEscaped(HelperConstants.cdhashPinPath)

        // Pin this app's cdhash so the freshly-installed helper accepts ONLY this binary
        // (see Helper/HelperTool.swift verifyCallerCode). Written in the SAME admin op as the
        // copy — no extra prompt, and it lands BEFORE `launchctl bootstrap` so the helper
        // never runs without it. The 1.8.0 helper is FAIL-CLOSED on the pin, so if our cdhash
        // can't be computed we must NOT install: a pin-less helper would reject every caller
        // (unusable). Fail the install with a clear, recoverable error instead of leaving a
        // broken helper behind.
        guard let cdhash = ownCDHash() else {
            installationError = String(localized: "Cannot secure the helper: this app has no computable code signature (cdhash). Reinstall the app from the official DMG.")
            RouteManager.shared.log(.error, "❌ Could not compute app cdhash — refusing to install a pin-less (fail-closed = unusable) helper")
            return false
        }
        let pinCommands = """
        printf '%s' '\(cdhash)' > '\(pinPath)'
            chmod 644 '\(pinPath)'
            chown root:wheel '\(pinPath)'
        """

        let shellCommand = """
        mkdir -p /Library/PrivilegedHelperTools
        launchctl bootout system/\(kHelperToolMachServiceName) 2>/dev/null || true
        cp '\(hs)' '\(hd)'
        chmod 544 '\(hd)'
        chown root:wheel '\(hd)'
        cp '\(ps)' '\(pd)'
        chmod 644 '\(pd)'
        chown root:wheel '\(pd)'
        \(pinCommands)
        launchctl bootstrap system '\(pd)'
        """
        let script = "do shell script \"\(Self.appleScriptStringEscaped(shellCommand))\" with administrator privileges"

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)

            if let error = error {
                let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                installationError = errorMessage
                RouteManager.shared.log(.error, "❌ AppleScript error: \(errorMessage)")
                return false
            }

            // Defense-in-depth: `do shell script` has no `set -e`, so it reports success based
            // on the LAST command (`launchctl bootstrap`). If the `printf … > pinPath` step
            // silently failed while bootstrap succeeded, we'd leave a pin-less fail-closed 1.8.0
            // helper running (rejects everyone). Confirm the pin actually landed before trusting
            // the install — mirrors the modern path. `cdhash` is non-nil here (we fail the
            // install above when it can't be computed).
            guard currentPinnedCDHash() == cdhash else {
                installationError = String(localized: "Helper installed but its security pin did not persist. Please try installing again.")
                RouteManager.shared.log(.error, "❌ Helper installed but cdhash pin did not land — treating install as failed")
                return false
            }

            RouteManager.shared.log(.success, "✅ Helper installed successfully via AppleScript")
            installationError = nil
            return true
        }

        installationError = "Failed to create AppleScript"
        return false
    }

    // MARK: - cdhash pinning

    /// This app's own code-directory hash as lowercase hex, or nil if it can't be
    /// determined. `kSecCodeInfoUnique` is the value the `cdhash` requirement predicate
    /// matches, so pinning it lets the helper require exactly this binary. nil on any
    /// failure; because the 1.8.0 helper is fail-closed, callers treat nil as "cannot secure
    /// the helper" and fail the install rather than pinning junk or installing pin-less.
    private func ownCDHash() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let staticCode = staticRef else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              let cdhash = info[kSecCodeInfoUnique as String] as? Data,
              !cdhash.isEmpty else { return nil }
        return cdhash.map { String(format: "%02x", $0) }.joined()
    }

    /// The cdhash currently written to the root-only pin file (validated lowercase hex), or
    /// nil if the file is absent/unreadable/malformed. Uses the same validation the helper
    /// applies (`HelperAuthPolicy.validatedCDHash`) so "is the pin correct?" means the same
    /// thing on both sides of the trust boundary.
    private func currentPinnedCDHash() -> String? {
        guard let data = FileManager.default.contents(atPath: HelperConstants.cdhashPinPath),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: raw)
    }

    /// Ensure the root-only cdhash pin matches this app, returning whether the pin is correct
    /// on disk AFTER this call. The legacy install writes the pin inline (so this no-ops
    /// there); the modern SMAppService path does NOT, so this covers a clean first install.
    /// `installHelperModern` uses the return value to decide whether the modern install is
    /// safe or must fall back to the atomic legacy installer — the 1.8.0 helper is
    /// fail-closed, so an unconfirmed pin is not acceptable. Returns false if the cdhash
    /// can't be computed, or the admin write failed / was cancelled / didn't land.
    private func ensureCDHashPinned() -> Bool {
        guard let cdhash = ownCDHash() else { return false }
        if currentPinnedCDHash() == cdhash { return true }   // already correct
        // Escape uniformly through the same shell → AppleScript layers the legacy
        // installer uses, so the trust boundary is consistent even though cdhash is
        // [0-9a-f] and the pin path is currently a constant.
        let pin = Self.shSingleQuoteEscaped(HelperConstants.cdhashPinPath)
        let shellCommand = """
        printf '%s' '\(cdhash)' > '\(pin)'
        chmod 644 '\(pin)'
        chown root:wheel '\(pin)'
        """
        let script = "do shell script \"\(Self.appleScriptStringEscaped(shellCommand))\" with administrator privileges"
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            RouteManager.shared.log(.warning, "cdhash pin write (modern path): failed to create AppleScript")
            return false
        }
        appleScript.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            RouteManager.shared.log(.warning, "cdhash pin write (modern path) failed: \(msg)")
            return false
        }
        // Confirm the write actually landed with the right value before trusting it.
        return currentPinnedCDHash() == cdhash
    }

    /// Boot the helper daemon out of launchd via an admin AppleScript op. Used ONLY to avoid
    /// leaving a helper running without a valid cdhash pin: the 1.8.0 helper is fail-closed
    /// and would reject every caller anyway, so removing it lets the app see "not installed"
    /// and prompt for a clean reinstall (which re-writes the pin) instead of surfacing a
    /// wedged helper. Best-effort — the state is already recoverable even if this can't run.
    private func bootOutHelper() {
        let shellCommand = "launchctl bootout system/\(kHelperToolMachServiceName) 2>/dev/null || true"
        let script = "do shell script \"\(Self.appleScriptStringEscaped(shellCommand))\" with administrator privileges"
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return }
        appleScript.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
            RouteManager.shared.log(.warning, "helper bootout failed: \(msg)")
        }
    }

    /// Whether the readiness pin invariant holds. The 1.8.0 helper is fail-closed on the
    /// cdhash pin, so a successful version probe already implies a matching pin — this is
    /// defense-in-depth plus stale-pin self-heal. Returns true when we can't compute our own
    /// cdhash (trust the probe: the helper only answered a caller whose cdhash it accepted),
    /// or when the pin file is present and equals our cdhash.
    private func readinessPinSatisfied() -> Bool {
        guard let own = ownCDHash() else { return true }
        return currentPinnedCDHash() == own
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
        // Budget 0.25s per route: helper does delete-before-add (2 subprocess calls
        // at ~0.07s each ≈ 0.14s/route). 0.1s/route was too tight and caused timeouts
        // for batches above ~250 routes, dropping all routes as failed.
        let timeout = xpcTimeout + Double(routes.count) * 0.25
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

    // MARK: - Hosts File Operations

    func updateHostsFile(entries: [(domain: String, ip: String)]) async -> (success: Bool, error: String?) {
        guard helperState.isReady else {
            return (false, "Helper not ready (\(helperState.statusText))")
        }

        let dictEntries = entries.map { ["domain": $0.domain, "ip": $0.ip] }

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

    func complete(_ value: sending T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
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
