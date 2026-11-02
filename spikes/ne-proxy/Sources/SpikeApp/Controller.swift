import Foundation
import NetworkExtension
import SpikePolicy
import SystemExtensions

/// Owns the system extension request, the proxy configuration and the policy heartbeat.
/// Nothing here runs on its own: every start, stop and push follows a button.
final class Controller: NSObject, OSSystemExtensionRequestDelegate {
    static let extensionID = "com.geiserx.vpn-bypass.spike.proxy"
    static let configName = "VPN Bypass NE spike"
    static let heartbeatSeconds: TimeInterval = 30

    var onLog: (String) -> Void = { _ in }
    /// Called when a system extension request ends: `.completed`, `.willCompleteAfterReboot`,
    /// `.needsApproval` (the owner must click) or `.failed`. The command-line mode waits on it.
    var onRequestEnd: (RequestEnd) -> Void = { _ in }
    enum RequestEnd { case completed, willCompleteAfterReboot, needsApproval, failed }
    private var manager: NETransparentProxyManager?
    private var heartbeat: Timer?
    private var generation = 0
    private var lastPolicy: SpikePolicy?
    private var activity: NSObjectProtocol?

    // MARK: System extension

    func activate() {
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
        onLog("activation requested")
    }

    func deactivate() {
        let r = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
        onLog("deactivation requested")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        onLog("replacing extension \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onLog("waiting for approval: System Settings > General > Login Items & Extensions > Network Extensions")
        onRequestEnd(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        onLog("system extension request finished: \(result == .completed ? "completed" : "completes after reboot")")
        onRequestEnd(result == .completed ? .completed : .willCompleteAfterReboot)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        onLog("system extension request failed: \(error.localizedDescription) (\((error as NSError).code))")
        onRequestEnd(.failed)
    }

    // MARK: Proxy configuration

    private func loadManager(_ done: @escaping (NETransparentProxyManager?) -> Void) {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error { self.onLog("load failed: \(error.localizedDescription)") }
                let m = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionID
                }
                self.manager = m
                done(m)
            }
        }
    }

    /// Saves the configuration enabled (first time: the "would like to add proxy configurations"
    /// prompt), then starts the proxy with the chosen include scope.
    func start(scope: IncludeScope, done: @escaping (Bool) -> Void = { _ in }) {
        loadManager { existing in
            let m = existing ?? NETransparentProxyManager()
            let needsSave = existing == nil || !m.isEnabled
            if existing == nil {
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.extensionID
                proto.serverAddress = "localhost"
                m.protocolConfiguration = proto
                m.localizedDescription = Self.configName
            }
            m.isEnabled = true
            let go = {
                do {
                    try (m.connection as? NETunnelProviderSession)?.startTunnel(options: ["scope": scope.token as NSString])
                    self.onLog("start requested, scope \(scope.token)")
                    done(true)
                } catch {
                    self.onLog("start failed: \(error.localizedDescription)")
                    done(false)
                }
            }
            guard needsSave else { self.manager = m; go(); return }
            m.saveToPreferences { error in
                DispatchQueue.main.async {
                    if let error { self.onLog("save failed: \(error.localizedDescription)"); done(false); return }
                    self.onLog("configuration saved, enabled")
                    // A saved manager must be reloaded before its connection can start.
                    m.loadFromPreferences { _ in DispatchQueue.main.async { self.manager = m; go() } }
                }
            }
        }
    }

    /// Stops the running session only. The configuration stays enabled, so the OS may start the
    /// provider again on its own (wake, reboot).
    func stopSession(done: @escaping () -> Void = {}) {
        loadManager { m in
            m?.connection.stopVPNTunnel()
            self.onLog(m == nil ? "no configuration" : "session stop requested (configuration stays enabled)")
            done()
        }
    }

    /// Disables the configuration: stops the proxy and keeps the OS from restarting it.
    /// `done(false)` when the disable could not be saved.
    func turnOff(done: @escaping (Bool) -> Void = { _ in }) {
        stopHeartbeat()
        loadManager { m in
            guard let m else { self.onLog("no configuration"); done(true); return }
            m.isEnabled = false
            m.saveToPreferences { error in
                DispatchQueue.main.async {
                    self.onLog(error.map { "disable failed: \($0.localizedDescription)" } ?? "configuration disabled")
                    done(error == nil)
                }
            }
        }
    }

    /// Removes the configuration, then asks for the extension's deactivation.
    func remove() {
        stopHeartbeat()
        loadManager { m in
            guard let m else { self.onLog("no configuration to remove"); self.deactivate(); return }
            m.removeFromPreferences { error in
                DispatchQueue.main.async {
                    if let error {
                        // The configuration is still installed: keep the extension it needs.
                        self.onLog("remove failed: \(error.localizedDescription)")
                        self.onRequestEnd(.failed)
                        return
                    }
                    self.onLog("configuration removed")
                    self.manager = nil
                    self.deactivate()
                }
            }
        }
    }

    // MARK: Policy

    /// Sends a policy. `completion(status, accepted)`: `accepted` only when the reply shows this
    /// policy live. Only an accepted policy goes to the heartbeat, so a failed or rejected push never
    /// applies later without a report.
    func push(apps: [String], hostnames: [String], interfaceName: String?,
              completion: @escaping (SpikeStatus?, Bool) -> Void) {
        generation += 1
        let p = SpikePolicy(generation: generation, apps: apps, hostnames: hostnames, interfaceName: interfaceName)
        send(SpikeRequest(policy: p)) { s in
            let accepted = s?.confirms(p) ?? false
            if accepted {
                self.lastPolicy = p
                self.startHeartbeat()
            }
            completion(s, accepted)
        }
    }

    func status(completion: @escaping (SpikeStatus?) -> Void) {
        send(SpikeRequest(policy: nil), completion: completion)
    }

    func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        // Keeps App Nap and timer coalescing from stretching the heartbeat past the lease.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "per-app routing lease")
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatSeconds, repeats: true) { [weak self] _ in
            guard let self, let p = self.lastPolicy else { return }
            self.send(SpikeRequest(policy: p)) { _ in }
        }
    }

    /// Why the last session ended, as macOS recorded it (e.g. a `setTunnelNetworkSettings` refusal).
    func lastDisconnectError(_ done: @escaping (String?) -> Void) {
        loadManager { m in
            guard let m else { done(nil); return }
            m.connection.fetchLastDisconnectError { error in
                DispatchQueue.main.async { done(error.map { $0.localizedDescription }) }
            }
        }
    }

    /// The status pane's text, shared by the window and the command line.
    func describe(_ s: SpikeStatus?) -> [String] {
        var lines = ["proxy: \(connectionState)"]
        if let s {
            lines.append("extension pid \(s.extensionPID), started \(Date(timeIntervalSince1970: TimeInterval(s.startedAt)))")
            lines.append("scope \(s.scope), policy generation \(s.policyGeneration), lease \(s.policyLive ? "live" : "NOT live (declining all)")")
            lines.append("egress interface \(s.interfaceName)")
            for (k, v) in s.counters.sorted(by: { $0.key < $1.key }) { lines.append("  \(k) = \(v)") }
        } else {
            lines.append("(no reply from the extension)")
        }
        return lines
    }

    /// The session's own status, read fresh (the cached manager may be stale).
    var isConnected: Bool { manager?.connection.status == .connected }
    var isSettled: Bool {
        guard let st = manager?.connection.status else { return true }
        return st == .connected || st == .disconnected || st == .invalid
    }

    var connectionState: String {
        guard let m = manager else { return "no configuration" }
        let s: String
        switch m.connection.status {
        case .invalid: s = "invalid"
        case .disconnected: s = "disconnected"
        case .connecting: s = "connecting"
        case .connected: s = "connected"
        case .reasserting: s = "reasserting"
        case .disconnecting: s = "disconnecting"
        @unknown default: s = "unknown"
        }
        return "\(s), configuration \(m.isEnabled ? "enabled" : "disabled")"
    }

    private func send(_ request: SpikeRequest, completion: @escaping (SpikeStatus?) -> Void) {
        let fire = { (m: NETransparentProxyManager?) in
            guard let session = m?.connection as? NETunnelProviderSession, session.status == .connected,
                  let data = try? JSONEncoder().encode(request) else { completion(nil); return }
            do {
                try session.sendProviderMessage(data) { reply in
                    let s = reply.flatMap { try? JSONDecoder().decode(SpikeStatus.self, from: $0) }
                    DispatchQueue.main.async { completion(s) }
                }
            } catch {
                completion(nil)
            }
        }
        if let manager { fire(manager) } else { loadManager(fire) }
    }
}
