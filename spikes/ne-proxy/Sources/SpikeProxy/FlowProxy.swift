import Foundation
import Network
import NetworkExtension
import Security
import SpikePolicy

/// The spike's transparent proxy. Declines everything until the app pushes a policy, claims only
/// flows the policy matches, and re-emits them on the physical interface.
///
/// `@objc(FlowProxy)` fixes the Objective-C name, so `NEProviderClasses` in Info.plist is the bare
/// `FlowProxy` whatever the module is called.
@objc(FlowProxy)
final class FlowProxy: NETransparentProxyProvider {
    private let queue = DispatchQueue(label: "spike.proxy")
    private let lock = NSLock()
    private var state = PolicyState()
    private var leaseExpiryCounted = false
    private var scope = IncludeScope.narrow
    private var startedAt = 0
    private let counters = Counters()
    private lazy var egress = Egress(queue: queue)
    private var teamCache: [Data: String] = [:]

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Options come only from a start the app makes. A start by the OS (boot, crash, wake) has
        // none and gets the narrow scope (port 80), never `all`.
        scope = IncludeScope.atStart(options?["scope"] as? String)
        startedAt = Int(Date().timeIntervalSince1970)
        _ = egress

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        switch scope {
        case .allTCP:
            settings.includedNetworkRules = [NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                                                           localNetworkEndpoint: nil, localPrefix: 0,
                                                           protocol: .TCP, direction: .outbound)]
        case .tcpPort(let port):
            settings.includedNetworkRules = [NENetworkRule(remoteNetworkEndpoint: Self.endpoint("0.0.0.0", port),
                                                           remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                                                           protocol: .TCP, direction: .outbound)]
        }
        var excluded = AddressRanges.excludedIPv4CIDRs.map {
            NENetworkRule(destinationNetworkEndpoint: Self.endpoint($0.address, 0), prefix: $0.prefix, protocol: .TCP)
        }
        for (address, prefix) in [("fc00::", 7), ("fe80::", 10), ("ff00::", 8)] {
            excluded.append(NENetworkRule(destinationNetworkEndpoint: Self.endpoint(address, 0), prefix: prefix, protocol: .TCP))
        }
        settings.excludedNetworkRules = excluded

        setTunnelNetworkSettings(settings) { error in
            if error != nil { SpikeLog.event(.settingsFailed) }
            if case .tcpPort(let p) = self.scope { SpikeLog.event(.started, Int(p)) } else { SpikeLog.event(.started, 0) }
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        SpikeLog.event(.stopped, reason.rawValue)
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        counters.add("flowsSeen")
        guard let tcp = flow as? NEAppProxyTCPFlow else {
            counters.add("declined.notTCP")
            return false
        }
        let meta = flow.metaData
        let token = meta.sourceAppAuditToken
        let facts = FlowFacts(
            signingIdentifier: meta.sourceAppSigningIdentifier,
            remote: Self.remote(of: tcp.remoteFlowEndpoint),
            remoteHostname: flow.remoteHostname,
            isBound: flow.isBound,
            executablePath: { Self.executablePath(token) },
            teamIdentifier: { [weak self] in self?.teamIdentifier(token) }
        )

        lock.lock()
        let now = Date()
        let verdict = FlowDecider.decide(facts, state: state, now: now)
        let policy = state.policy
        if case .decline(.leaseExpired) = verdict, !leaseExpiryCounted {
            leaseExpiryCounted = true
            counters.add("leaseExpiries")
            SpikeLog.event(.leaseExpired, policy?.generation ?? 0)
        }
        lock.unlock()

        guard case .claim(let kind) = verdict, let policy else {
            if case .decline(let reason) = verdict { counters.add("declined.\(reason.rawValue)") }
            return false
        }
        guard let out = egress.pick(policy.interfaceName),
              let endpoint = Self.dialEndpoint(tcp.remoteFlowEndpoint) else {
            counters.add("declined.\(DeclineReason.noInterface.rawValue)")
            SpikeLog.event(.noInterface)
            return false
        }

        // Order matters: metadata into the parameters, then the connection from them.
        let params = Egress.parameters(on: out.iface)
        flow.setMetadata(params)
        counters.add("claimed.\(kind.rawValue)")
        SpikeLog.event(.claimed, kind == .app ? 0 : 1)
        TCPRelay(flow: tcp, endpoint: endpoint, parameters: params, interfaceName: out.name,
                 queue: queue, counters: counters).start()
        return true
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let request = try? JSONDecoder().decode(SpikeRequest.self, from: messageData)
        lock.lock()
        if let policy = request?.policy {
            if policy.version == SpikePolicy.currentVersion {
                state.accept(policy, at: Date())
                leaseExpiryCounted = false
                SpikeLog.event(.policyAccepted, policy.generation, policy.apps.count + policy.hostnames.count)
            } else {
                // Unknown version: behave as if there were no policy.
                state = PolicyState()
                counters.add("policyVersionRejected")
                SpikeLog.event(.policyRejected, policy.version)
            }
        }
        var status = SpikeStatus()
        status.extensionPID = getpid()
        status.startedAt = startedAt
        status.scope = scope.token
        status.policyGeneration = state.policy?.generation ?? 0
        status.policyLive = state.isLeaseLive(at: Date())
        let interfaceName = state.policy?.interfaceName
        lock.unlock()
        status.interfaceName = egress.pick(interfaceName)?.name ?? "none"
        status.counters = counters.snapshot()
        completionHandler?(try? JSONEncoder().encode(status))
    }

    static func endpoint(_ address: String, _ port: UInt16) -> Network.NWEndpoint {
        .hostPort(host: Network.NWEndpoint.Host(address), port: Network.NWEndpoint.Port(rawValue: port) ?? .any)
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
    /// interface; it lives only in this connection and is never logged.
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
        if let hit = teamCache[token] { return hit.isEmpty ? nil : hit }
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
        if teamCache.count > 512 { teamCache.removeAll() }
        teamCache[token] = team
        return team.isEmpty ? nil : team
    }
}
