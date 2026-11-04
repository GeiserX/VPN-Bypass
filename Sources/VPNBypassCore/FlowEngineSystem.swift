// FlowEngineSystem.swift
// What FlowEngineManager asks of macOS, behind a protocol so the state machine is tested with a
// fake: the system extension request, the transparent proxy configuration, its session and the
// messages to the extension. `LiveFlowEngineSystem` is the real one.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, 3.3 and 5. The policy travels only in
// `sendProviderMessage`, never in `providerConfiguration` (that plist is world-readable).

import Foundation
import NetworkExtension
import Security
import SystemExtensions

/// Whether this Mac and this build can run per-app routing at all.
enum FlowEngineSupport: Equatable {
    case supported
    case unavailable(FlowEngineState.Unavailable)
}

/// How an activation request ended.
enum FlowEngineActivation: Equatable {
    /// Activated, or replaced by this app's version.
    case activated
    case willCompleteAfterReboot
    /// An `OSSystemExtensionError` code (`FlowEngineState.forActivationError`).
    case failed(code: Int)
}

/// The transparent proxy session, as `NEVPNStatus` reports it.
enum FlowEngineSession: Equatable {
    /// No configuration of ours is loaded.
    case none
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// How a deactivation request ended (Remove extension, or turning per-app routing off).
enum FlowEngineDeactivation: Equatable {
    /// Gone, or there was none to remove.
    case removed
    /// macOS removes it after a restart.
    case willCompleteAfterReboot
    /// An `OSSystemExtensionError` code; 1 is also what an administrator password left
    /// unanswered gives.
    case failed(code: Int)
}

enum FlowEngineSaveResult: Equatable {
    case saved
    /// The user answered Don't Allow, or a profile refused it.
    case declined
    case failed(code: Int)
}

@MainActor
protocol FlowEngineSystem: AnyObject {
    var support: FlowEngineSupport { get }
    /// Files the activation (or replacement) request. `onNeedsApproval` runs when macOS waits for
    /// the user, with `true` when the request replaces an installed extension of another version
    /// (an update); `completion` runs once, possibly much later, when the request ends.
    func requestActivation(onNeedsApproval: @escaping @MainActor (_ replacing: Bool) -> Void,
                           completion: @escaping @MainActor (FlowEngineActivation) -> Void)
    /// Our configuration's `isEnabled`, nil when there is none.
    func loadConfiguration() async -> Bool?
    /// Creates the configuration when there is none and sets `isEnabled`. The first enabling save
    /// shows macOS's "would like to add proxy configurations" prompt and returns once it is answered.
    func saveConfiguration(enabled: Bool) async -> FlowEngineSaveResult
    var session: FlowEngineSession { get }
    /// Runs whenever the session's status changes.
    var onSessionChange: (@MainActor () -> Void)? { get set }
    func startSession() -> Bool
    func stopSession()
    /// Sends one message to the extension; nil when no reply came within `timeout`.
    func send(_ data: Data, timeout: TimeInterval) async -> Data?
    /// Removes our proxy configuration from the system's preferences, so no connection passes
    /// through the extension any more; true when it is gone or there was none.
    func removeConfiguration() async -> Bool
    /// Files the deactivation request, which uninstalls the extension (macOS asks for an
    /// administrator password); `completion` runs once, when the request ends.
    func requestDeactivation(completion: @escaping @MainActor (FlowEngineDeactivation) -> Void)
}

// MARK: - The real one

@MainActor
final class LiveFlowEngineSystem: FlowEngineSystem {
    nonisolated static let extensionIdentifier = "com.geiserx.vpn-bypass.proxy"
    /// The entitlement only a signed build with the per-app routing profile carries.
    nonisolated static let installEntitlement = "com.apple.developer.system-extension.install"

    private var manager: NETransparentProxyManager?
    private var observer: NSObjectProtocol?
    private var requestDelegate: ActivationDelegate?
    private var deactivationDelegate: DeactivationDelegate?
    var onSessionChange: (@MainActor () -> Void)?

    let support: FlowEngineSupport

    init(bundle: Bundle = .main) {
        support = Self.support(bundle: bundle)
    }

    /// macOS 15 or later, the extension inside the bundle, and the install entitlement on this
    /// process. A dev or CI build has neither of the last two.
    nonisolated static func support(bundle: Bundle, os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                        entitled: () -> Bool = { hasEntitlement(installEntitlement) }) -> FlowEngineSupport {
        guard os.majorVersion >= 15 else { return .unavailable(.needsMacOS15) }
        let ext = bundle.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(extensionIdentifier).systemextension")
        guard FileManager.default.fileExists(atPath: ext.path), entitled() else { return .unavailable(.notInThisBuild) }
        return .supported
    }

    nonisolated static func hasEntitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil) else { return false }
        return (value as? Bool) == true
    }

    func requestActivation(onNeedsApproval: @escaping @MainActor (_ replacing: Bool) -> Void,
                           completion: @escaping @MainActor (FlowEngineActivation) -> Void) {
        let delegate = ActivationDelegate(onNeedsApproval: onNeedsApproval) { [weak self] outcome in
            self?.requestDelegate = nil
            completion(outcome)
        }
        requestDelegate = delegate
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func loadConfiguration() async -> Bool? {
        try? await load()?.isEnabled
    }

    /// Ours, nil when there is none. Throws when the preferences could not be read, so a failed
    /// read is never taken for "none" (a save would then add a second configuration).
    private func load() async throws -> NETransparentProxyManager? {
        let (managers, error): ([NETransparentProxyManager]?, Error?) = await withCheckedContinuation { continuation in
            NETransparentProxyManager.loadAllFromPreferences { continuation.resume(returning: ($0, $1)) }
        }
        if let error { throw error }
        let ours = managers?.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionIdentifier
        }
        adopt(ours)
        return ours
    }

    private func adopt(_ m: NETransparentProxyManager?) {
        manager = m
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let m else { return }
        // Delivered on the posting thread, then hopped to the main actor. With `queue: .main` the
        // post waits for an operation on the main queue, and NetworkExtension posts from the main
        // queue: when that queue is not drained by the main thread's run loop (dispatchMain, the
        // live-test driver), the post waited on itself forever.
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: m.connection,
                                                          queue: nil) { [weak self] _ in
            Task { @MainActor in self?.onSessionChange?() }
        }
    }

    func saveConfiguration(enabled: Bool) async -> FlowEngineSaveResult {
        let existing: NETransparentProxyManager?
        do {
            existing = try await load()
        } catch {
            return .failed(code: (error as NSError).code)
        }
        if existing == nil && !enabled { return .saved }
        let m = existing ?? NETransparentProxyManager()
        if existing == nil {
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionIdentifier
            proto.serverAddress = "localhost"
            m.protocolConfiguration = proto
            m.localizedDescription = "VPN Bypass per-app routing"
        }
        // Saved only when the switch changes: re-saving has lost consent elsewhere (3.3).
        if existing != nil, m.isEnabled == enabled { return .saved }
        m.isEnabled = enabled
        let error: Error? = await withCheckedContinuation { continuation in
            m.saveToPreferences { continuation.resume(returning: $0) }
        }
        if let error {
            let ns = error as NSError
            // NEVPNErrorConfigurationReadWriteFailed: the user said Don't Allow, or a profile refused.
            return ns.domain == NEVPNErrorDomain && ns.code == NEVPNError.configurationReadWriteFailed.rawValue
                ? .declined : .failed(code: ns.code)
        }
        // A saved manager must be loaded again before its session starts.
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            m.loadFromPreferences { _ in continuation.resume() }
        }
        adopt(m)
        return .saved
    }

    var session: FlowEngineSession {
        guard let m = manager else { return .none }
        switch m.connection.status {
        case .connected: return .connected
        case .connecting, .reasserting: return .connecting
        case .disconnecting: return .disconnecting
        case .disconnected, .invalid: return .disconnected
        @unknown default: return .disconnected
        }
    }

    func startSession() -> Bool {
        guard let session = manager?.connection as? NETunnelProviderSession else { return false }
        do {
            try session.startTunnel(options: nil)
            return true
        } catch {
            return false
        }
    }

    func stopSession() {
        manager?.connection.stopVPNTunnel()
    }

    func removeConfiguration() async -> Bool {
        let existing: NETransparentProxyManager?
        do {
            existing = try await load()
        } catch {
            return false
        }
        guard let m = existing else { return true }
        let error: Error? = await withCheckedContinuation { continuation in
            m.removeFromPreferences { continuation.resume(returning: $0) }
        }
        guard error == nil else { return false }
        adopt(nil)
        return true
    }

    func requestDeactivation(completion: @escaping @MainActor (FlowEngineDeactivation) -> Void) {
        let delegate = DeactivationDelegate { [weak self] outcome in
            self?.deactivationDelegate = nil
            completion(outcome)
        }
        deactivationDelegate = delegate
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = delegate
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func send(_ data: Data, timeout: TimeInterval) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return nil }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
            do {
                try session.sendProviderMessage(data) { once.resume($0) }
            } catch {
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation the first time only: the reply and the timeout race.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

    func resume(_ value: Data?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// The activation request's delegate. macOS calls it on the main queue (the request's queue).
private final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    let onNeedsApproval: @MainActor (_ replacing: Bool) -> Void
    let completion: @MainActor (FlowEngineActivation) -> Void
    /// macOS asked whether to replace an installed extension of another version: an update.
    private var replacing = false

    init(onNeedsApproval: @escaping @MainActor (_ replacing: Bool) -> Void, completion: @escaping @MainActor (FlowEngineActivation) -> Void) {
        self.onNeedsApproval = onNeedsApproval
        self.completion = completion
    }

    /// An installed extension of another version is replaced by this app's (an update, 6.4).
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        replacing = true
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let replacing = replacing
        Task { @MainActor in self.onNeedsApproval(replacing) }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let outcome: FlowEngineActivation = result == .completed ? .activated : .willCompleteAfterReboot
        Task { @MainActor in self.completion(outcome) }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor in self.completion(.failed(code: code)) }
    }
}

/// The deactivation request's delegate. macOS calls it on the main queue (the request's queue).
private final class DeactivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
    let completion: @MainActor (FlowEngineDeactivation) -> Void

    init(completion: @escaping @MainActor (FlowEngineDeactivation) -> Void) {
        self.completion = completion
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .cancel
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let outcome: FlowEngineDeactivation = result == .completed ? .removed : .willCompleteAfterReboot
        Task { @MainActor in self.completion(outcome) }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let outcome = FlowEngineDeactivation.forError(code: (error as NSError).code)
        Task { @MainActor in self.completion(outcome) }
    }
}

extension FlowEngineDeactivation {
    /// `OSSystemExtensionErrorCode` 4, extension not found: nothing was installed, so there is
    /// nothing left to remove.
    static func forError(code: Int) -> FlowEngineDeactivation {
        code == 4 ? .removed : .failed(code: code)
    }
}
