import Foundation
import Network
import NetworkExtension
import Security
import VPNBypassPolicy

/// Per-app routing's transparent proxy (design 3.3 to 3.8). It declines every flow until the
/// app pushes a policy, claims only the TCP flows a live policy's Direct rules name, and carries
/// them out the physical interface, past the VPN. Everything else returns `false` and goes on
/// as if no proxy were there. Without a fresh push within the lease it declines every flow
/// again, so a quit or crashed app never leaves per-app routing behind.
///
/// `@objc(FlowProxy)` fixes the Objective-C name, so `NEProviderClasses` in Proxy/Info.plist is
/// the bare `FlowProxy` whatever the module is called. CI checks the name is in the binary.
@available(macOS 15, *)
@objc(FlowProxy)
final class FlowProxy: NETransparentProxyProvider {
    /// How often the lease watchdog looks, whether flows arrive or not.
    static let watchdogSeconds = 5

    private let queue = DispatchQueue(label: "com.geiserx.vpn-bypass.proxy.relay")
    private let lock = NSLock()
    private var state = FlowPolicyState()
    private var ledger = FlowLedger()
    private var health = EgressHealth()
    private var watchdog: DispatchSourceTimer?
    private lazy var egress = Egress(queue: queue)
    private let teamLock = NSLock()
    private var teamCache: [Data: String] = [:]
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        _ = egress
        startWatchdog()
        // Fixed include rules (design 3.4): all outbound TCP, minus the protected ranges. They never
        // change at runtime; every decision is made per flow. UDP is never included (3.6).
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                                                       localNetworkEndpoint: nil, localPrefix: 0,
                                                       protocol: .TCP, direction: .outbound)]
        let ranges = ProtectedRanges.ipv4RuleCIDRs + ProtectedRanges.ipv6CIDRs
        settings.excludedNetworkRules = ranges.map {
            NENetworkRule(destinationNetworkEndpoint: .hostPort(host: .init($0.address), port: .any),
                          prefix: $0.prefix, protocol: .TCP)
        }
        setTunnelNetworkSettings(settings) { error in
            ProxyLog.event(.started, error == nil ? 1 : 0)
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ProxyLog.event(.stopped, reason.rawValue)
        lock.lock(); state.sessionStopped(); lock.unlock()
        watchdog?.cancel()
        watchdog = nil
        completionHandler()
    }

    /// The lease watchdog (3.3, 3.7): drops a policy whose lease ran out, so a dead app or a
    /// stale policy declines every flow, and counts the lapse even when no flow arrives.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.geiserx.vpn-bypass.proxy.lease"))
        timer.schedule(deadline: .now() + .seconds(Self.watchdogSeconds), repeating: .seconds(Self.watchdogSeconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let expired = self.state.expireLease(at: Date())
            let count = self.state.leaseExpiries
            self.lock.unlock()
            if expired { ProxyLog.event(.leaseExpired, count) }
        }
        timer.resume()
        watchdog = timer
    }

    /// Synchronous and never blocks: no DNS, no I/O, no XPC (3.4). The two costly facts (the
    /// executable path and the team id) are read only when the decider reaches them.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcp = flow as? NEAppProxyTCPFlow else {
            lock.lock(); ledger.record(.decline(.notTCP)); lock.unlock()
            return false
        }
        let meta = flow.metaData
        let token = meta.sourceAppAuditToken
        let remote = tcp.remoteFlowEndpoint
        // `remoteHostname` is never read (3.8): a host name alone never claims a flow in v1.
        let facts = FlowFacts(signingIdentifier: meta.sourceAppSigningIdentifier,
                              remote: Self.remote(of: remote),
                              isBound: flow.isBound,
                              executablePath: { Self.executablePath(token) },
                              teamIdentifier: { [weak self] in self?.teamIdentifier(token) })

        lock.lock()
        let now = Date()
        var verdict = FlowDecider.decide(facts, state: state, now: now)
        var out: (name: String, iface: nw_interface_t)?
        var endpoint: nw_endpoint_t?
        if case .claim(let ruleID, let egressChoice) = verdict {
            if case .direct(let name) = egressChoice { out = egress.pick(name) }
            endpoint = Self.dialEndpoint(remote)
            if out == nil {
                verdict = .decline(.noInterface, ruleID: ruleID)
            } else if endpoint == nil {
                verdict = .decline(.unknownDestination, ruleID: ruleID)
            } else if let out, !health.isUsable(out.name, at: now) {
                verdict = .decline(.egressUnusable, ruleID: ruleID)
            } else if let out {
                health.claimed(out.name, at: now)
            }
        }
        ledger.record(verdict, bound: facts.isBound ? Egress.boundKind(flow.networkInterface) : nil)
        lock.unlock()

        guard case .claim = verdict, let out, let endpoint else {
            if case .decline(.noInterface, _) = verdict { ProxyLog.event(.noInterface) }
            return false
        }
        // Order matters (3.5): the flow's metadata into the parameters, then the connection from them.
        let params = Egress.parameters(on: out.iface)
        flow.setMetadata(params)
        TCPRelay(flow: tcp, endpoint: endpoint, parameters: params, interfaceName: out.name, queue: queue,
                 count: { [weak self] counter, n in
                     guard let self else { return }
                     self.lock.lock(); self.ledger.add(counter, n); self.lock.unlock()
                 },
                 onEgress: { [weak self] ok in
                     guard let self else { return }
                     self.lock.lock(); self.health.record(out.name, succeeded: ok, at: Date()); self.lock.unlock()
                 }).start()
        return true
    }

    /// A policy push replaces the policy (or, with a version this build does not read, drops it
    /// and declines every flow); a status request changes nothing. Both get the reply, which
    /// echoes the generation held, so the app can confirm a push that takes matchers away.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        ProxyLog.event(.appMessage, messageData.count)
        let message = FlowPolicyMessage.decode(messageData)
        let now = Date()
        lock.lock()
        if message != .status { state.receive(message, at: now) }
        let reply = ledger.reply(state: state, now: now, extensionVersion: version)
        lock.unlock()
        switch message {
        case .policy(let p): ProxyLog.event(.policyAccepted, p.generation, p.matchers.count)
        case .unknownVersion(let v): ProxyLog.event(.policyRejected, v)
        case .malformed: ProxyLog.event(.policyRejected, 0)
        case .status: break
        }
        completionHandler?(try? JSONEncoder().encode(reply))
    }

    // MARK: - Flow facts

    static func remote(of endpoint: Network.NWEndpoint) -> FlowFacts.Remote {
        guard case .hostPort(let host, _) = endpoint else { return .unknown }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 4 else { return .unknown }
            return .ipv4(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case .ipv6: return .ipv6
        case .name(let n, _): return .name(n)
        @unknown default: return .unknown
        }
    }

    /// The flow's destination as a C endpoint. A name stays a name, so it resolves on the scoped
    /// interface; it lives only in this connection and is never logged or stored (3.5 step 4).
    static func dialEndpoint(_ endpoint: Network.NWEndpoint) -> nw_endpoint_t? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let p = "\(port.rawValue)"
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 4 else { return nil }
            return nw_endpoint_create_host("\(b[0]).\(b[1]).\(b[2]).\(b[3])", p)
        case .name(let n, _):
            return nw_endpoint_create_host(n, p)
        default:
            return nil
        }
    }

    static func pid(_ token: Data?) -> pid_t? {
        guard let token, token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let t = token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        return pid_t(bitPattern: t.val.5)
    }

    static func executablePath(_ token: Data?) -> String? {
        guard let pid = pid(token) else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Team id of the flow's source process, from its audit token. Cached per token.
    func teamIdentifier(_ token: Data?) -> String? {
        guard let token else { return nil }
        teamLock.lock()
        let hit = teamCache[token]
        teamLock.unlock()
        if let hit { return hit.isEmpty ? nil : hit }
        var code: SecCode?
        var team = ""
        if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &code) == errSecSuccess,
           let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                var info: CFDictionary?
                if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                   let dict = info as? [String: Any] {
                    team = dict[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
                }
            }
        }
        teamLock.lock()
        if teamCache.count > 512 { teamCache.removeAll() }
        teamCache[token] = team
        teamLock.unlock()
        return team.isEmpty ? nil : team
    }
}
