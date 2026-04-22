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
    private let hasPromptedKey = "HasPromptedHelperInstall"

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
            let hasPrompted = UserDefaults.standard.bool(forKey: hasPromptedKey)
            if !hasPrompted {
                UserDefaults.standard.set(true, forKey: hasPromptedKey)
            }
            helperState = .missing
            print("🔐 Helper not found, attempting install...")
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
        let version = await getVersionWithTimeout()

        guard let version = version else {
            // Check if the user disabled the background item in System Settings
            if #available(macOS 13.0, *), isDaemonDisabledByUser() {
                print("🔐 Helper daemon disabled by user in System Settings")
                helperState = .failed(String(localized: "Please enable VPN Bypass in System Settings → General → Login Items"))
                return false
            }

            // XPC connection failed — helper may be corrupted or wrong arch
            print("🔐 Helper XPC connection failed, attempting reinstall...")
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
        print("🔐 Helper version mismatch: installed=\(version), expected=\(expected)")
        helperState = .outdated(installed: version, expected: expected)

        print("🔐 Auto-updating helper...")
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

    private func getVersionWithTimeout() async -> String? {
        let connection = getOrCreateConnection()
        let noVersion: String? = nil
        let result: String? = await withXPCDeadline(seconds: xpcTimeout, fallback: noVersion) { once in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                print("🔐 XPC error during getVersion: \(error.localizedDescription)")
                once.complete(noVersion)
            } as? HelperProtocol

            guard let helper = proxy else {
                once.complete(noVersion)
                return
            }

            helper.getVersion { version in
                once.complete(version)
            }
        }
        return result
    }

    // MARK: - Helper Installation

    func installHelper() async -> Bool {
        print("🔐 Installing privileged helper...")
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
            print("🔐 Helper exists on disk, using legacy path for update...")
            return installHelperLegacy()
        }

        do {
            let service = SMAppService.daemon(plistName: "\(kHelperToolMachServiceName).plist")
            try await service.register()

            print("✅ Helper registered successfully via SMAppService")

            // SMAppService.register() can report success without actually placing the
            // binary/plist on disk (observed with enterprise security tools like Zscaler).
            // Verify both files exist before trusting the registration.
            if !FileManager.default.fileExists(atPath: helperPath) ||
               !FileManager.default.fileExists(atPath: plistPath) {
                print("⚠️ SMAppService reported success but helper files missing on disk, falling back to legacy install...")
                return installHelperLegacy()
            }

            installationError = nil
            return true
        } catch {
            print("⚠️ SMAppService failed: \(error.localizedDescription)")
            print("🔐 Falling back to legacy install...")
            return installHelperLegacy()
        }
    }

    private func installHelperLegacy() -> Bool {
        print("🔐 Attempting manual helper installation via AppleScript...")

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
            print("❌ Helper not found at: \(helperSource)")
            return false
        }

        guard FileManager.default.fileExists(atPath: plistSource) else {
            installationError = "Helper plist not found in app bundle"
            print("❌ Plist not found at: \(plistSource)")
            return false
        }

        let script = """
        do shell script "
            mkdir -p /Library/PrivilegedHelperTools
            launchctl bootout system/\(kHelperToolMachServiceName) 2>/dev/null || true
            cp '\(helperSource)' '\(helperDest)'
            chmod 544 '\(helperDest)'
            chown root:wheel '\(helperDest)'
            cp '\(plistSource)' '\(plistDest)'
            chmod 644 '\(plistDest)'
            chown root:wheel '\(plistDest)'
            launchctl bootstrap system '\(plistDest)'
        " with administrator privileges
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)

            if let error = error {
                let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                installationError = errorMessage
                print("❌ AppleScript error: \(errorMessage)")
                return false
            }

            print("✅ Helper installed successfully via AppleScript")
            installationError = nil
            return true
        }

        installationError = "Failed to create AppleScript"
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
        let timeout = xpcTimeout + Double(routes.count) * 0.1
        let fallback = (0, routes.count, allDests, Optional("XPC timeout"))

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

        if result.3 == "XPC timeout" { dropXPCConnection() }
        return result
    }

    func removeRoutesBatch(destinations: [String]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        guard helperState.isReady else {
            return (0, destinations.count, destinations, "Helper not ready (\(helperState.statusText))")
        }

        let timeout = xpcTimeout + Double(destinations.count) * 0.1
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

    func clearHostsFile() async -> (success: Bool, error: String?) {
        return await updateHostsFile(entries: [])
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
