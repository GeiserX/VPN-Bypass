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
            helperState = .ready
            return true
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

    /// Which process owns each `utun`, via the helper.
    ///
    /// `nil` means "could not ask" — helper absent, too old to know the method, or timed out.
    /// An empty array means the sweep ran and found nothing, which is a real answer and must
    /// clear the map: utun numbers are recycled, so holding a departed tunnel's label would
    /// eventually apply it to an unrelated tunnel. Cosmetic either way — this never influences
    /// which tunnel gets routed.
    func tunnelOwners() async -> [TunnelOwner]? {
        guard isHelperInstalled else { return nil }
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

            installationError = nil
            return true
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
            installationError = String(localized: "Not running from app bundle")
            return false
        }

        let helperSource = "\(bundlePath)/Contents/MacOS/\(kHelperToolMachServiceName)"
        let plistSource = "\(bundlePath)/Contents/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        let helperDest = "/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)"
        let plistDest = "/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"

        guard FileManager.default.fileExists(atPath: helperSource) else {
            installationError = String(localized: "Helper binary not found in app bundle")
            RouteManager.shared.log(.error, "❌ Helper not found at: \(helperSource)")
            return false
        }

        guard FileManager.default.fileExists(atPath: plistSource) else {
            installationError = String(localized: "Helper plist not found in app bundle")
            RouteManager.shared.log(.error, "❌ Plist not found at: \(plistSource)")
            return false
        }

        // helperSource/plistSource derive from Bundle.main.bundlePath, so a bundle path
        // containing a single quote (e.g. /Users/o'brien/…/VPN Bypass.app) would otherwise
        // break out of the 'cp …' single-quoting and inject commands into this ROOT admin
        // script. Escape ' as '\'' for the shell layer, then escape the whole command for
        // the AppleScript double-quoted string layer (\ and "). The dest paths are constants,
        // but they go through the same escaping uniformly.
        let hs = Self.shSingleQuoteEscaped(helperSource)
        let ps = Self.shSingleQuoteEscaped(plistSource)
        let hd = Self.shSingleQuoteEscaped(helperDest)
        let pd = Self.shSingleQuoteEscaped(plistDest)
        // Helpers before 2.3.0 authorized the app by a cdhash pinned in this file. The team
        // requirement replaced it, so remove the leftover in the same admin op.
        let oldPin = Self.shSingleQuoteEscaped(HelperConstants.legacyCDHashPinPath)

        let shellCommand = """
        mkdir -p /Library/PrivilegedHelperTools
        launchctl bootout system/\(kHelperToolMachServiceName) 2>/dev/null || true
        cp '\(hs)' '\(hd)'
        chmod 544 '\(hd)'
        chown root:wheel '\(hd)'
        cp '\(ps)' '\(pd)'
        chmod 644 '\(pd)'
        chown root:wheel '\(pd)'
        rm -f '\(oldPin)'
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

            RouteManager.shared.log(.success, "✅ Helper installed successfully via AppleScript")
            installationError = nil
            return true
        }

        installationError = String(localized: "Failed to create AppleScript")
        return false
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
