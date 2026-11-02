import Foundation

/// The facts the extension knows about a new flow. The two costly lookups (executable path from the
/// audit token, team id from the code signature) are closures, run only when a verdict needs them.
public struct FlowFacts {
    public enum Remote: Equatable {
        case ipv4(UInt32)      // host byte order
        case ipv6
        case name(String)      // a connect-by-name flow whose endpoint is still a host name
        case unknown
    }

    public var signingIdentifier: String
    public var remote: Remote
    /// `NEAppProxyFlow.remoteHostname`: set for connect-by-name callers only.
    public var remoteHostname: String?
    public var isBound: Bool
    public var executablePath: () -> String?
    public var teamIdentifier: () -> String?

    public init(signingIdentifier: String, remote: Remote, remoteHostname: String? = nil, isBound: Bool = false,
                executablePath: @escaping () -> String? = { nil }, teamIdentifier: @escaping () -> String? = { nil }) {
        self.signingIdentifier = signingIdentifier
        self.remote = remote
        self.remoteHostname = remoteHostname
        self.isBound = isBound
        self.executablePath = executablePath
        self.teamIdentifier = teamIdentifier
    }
}

public enum DeclineReason: String, CaseIterable {
    case noPolicy, leaseExpired, unknownVersion, ownProcess, systemProcess, protectedTeam, bound,
         excludedDestination, ipv6, noMatch, noInterface
}

public enum MatchKind: String, CaseIterable { case app, hostname }

public enum Verdict: Equatable {
    case decline(DeclineReason)
    case claim(MatchKind)
}

/// The live policy and when it arrived. Not thread-safe; the extension guards it with a lock.
public struct PolicyState {
    public private(set) var policy: SpikePolicy?
    public private(set) var receivedAt: Date?

    public init() {}

    public mutating func accept(_ p: SpikePolicy, at now: Date) {
        policy = p
        receivedAt = now
    }

    public func isLeaseLive(at now: Date) -> Bool {
        guard let p = policy, let t = receivedAt else { return false }
        return now.timeIntervalSince(t) <= TimeInterval(p.leaseSeconds)
    }
}

public enum FlowDecider {
    /// Our own binaries: never claimed, whatever a matcher says.
    public static let ownIdentifiers: Set<String> = [
        "com.geiserx.vpn-bypass", "com.geiserx.vpn-bypass.vpnb", "com.geiserx.vpnbypass.helper",
        "com.geiserx.vpn-bypass.spike", "com.geiserx.vpn-bypass.spike.proxy",
    ]

    /// System daemons a transparent proxy must leave alone (name resolution, push, captive portals,
    /// the NE machinery itself).
    public static let systemIdentifiers: Set<String> = [
        "com.apple.mDNSResponder", "com.apple.mDNSResponderHelper", "com.apple.apsd",
        "com.apple.captiveagent", "com.apple.nesessionmanager", "com.apple.networkserviceproxy",
        "com.apple.symptomsd", "com.apple.configd",
    ]

    /// VPN and network-security vendors, by team id: GlobalProtect's daemon is signed with the bare
    /// identifier `PanGPS`, so only the team id identifies it. Both ids read from `systemextensionsctl list`.
    public static let protectedTeams: Set<String> = [
        "PXPZ95SK77", // Palo Alto Networks (GlobalProtect)
        "W5364U7YZB", // Tailscale
    ]

    public static func decide(_ f: FlowFacts, state: PolicyState, now: Date) -> Verdict {
        guard let policy = state.policy else { return .decline(.noPolicy) }
        guard policy.version == SpikePolicy.currentVersion else { return .decline(.unknownVersion) }
        guard state.isLeaseLive(at: now) else { return .decline(.leaseExpired) }
        if ownIdentifiers.contains(f.signingIdentifier) { return .decline(.ownProcess) }
        if systemIdentifiers.contains(f.signingIdentifier) { return .decline(.systemProcess) }
        if f.isBound { return .decline(.bound) }
        switch f.remote {
        case .ipv6: return .decline(.ipv6)
        case .ipv4(let a) where AddressRanges.isExcluded(a): return .decline(.excludedDestination)
        case .unknown: return .decline(.excludedDestination)
        default: break
        }

        let kind: MatchKind
        if Matching.appMatches(policy.apps, signingIdentifier: f.signingIdentifier, executablePath: f.executablePath) {
            kind = .app
        } else if let host = hostname(of: f), Matching.hostMatches(policy.hostnames, host: host) {
            kind = .hostname
        } else {
            return .decline(.noMatch)
        }

        // Checked last, only for a flow we would otherwise claim: it reads the code signature.
        if let team = f.teamIdentifier(), protectedTeams.contains(team) { return .decline(.protectedTeam) }
        return .claim(kind)
    }

    static func hostname(of f: FlowFacts) -> String? {
        if let h = f.remoteHostname, !h.isEmpty { return h }
        if case .name(let n) = f.remote { return n }
        return nil
    }
}

public enum Matching {
    /// A matcher with a dot is a bundle id: equal, or a parent on a dot boundary
    /// (`com.google.Chrome` covers `com.google.Chrome.helper`, not `com.google.ChromeX`).
    /// A matcher without a dot is an executable name, compared with the path's last component.
    public static func appMatches(_ matchers: [String], signingIdentifier: String, executablePath: () -> String?) -> Bool {
        var path: String??
        for m in matchers where !m.isEmpty {
            if m.contains(".") {
                if signingIdentifier == m || signingIdentifier.hasPrefix(m + ".") { return true }
            } else {
                if path == nil { path = .some(executablePath()) }
                if let p = path!, (p as NSString).lastPathComponent == m { return true }
            }
        }
        return false
    }

    /// Exact host, or the host is under the matcher (`example.com` covers `api.example.com`, not
    /// `badexample.com`). Case and a trailing dot are ignored.
    public static func hostMatches(_ matchers: [String], host: String) -> Bool {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return false }
        for m in matchers where !m.isEmpty {
            if h == m || h.hasSuffix("." + m) { return true }
        }
        return false
    }
}

/// Destinations never claimed: private, link-local, multicast and the Tailscale range. Repeated here
/// because excluded network rules have been reported ignored (FB14453214).
public enum AddressRanges {
    public static let excludedIPv4: [(network: UInt32, prefix: Int)] = [
        (0x0000_0000, 8),   // 0/8
        (0x0A00_0000, 8),   // 10/8
        (0x6440_0000, 10),  // 100.64/10 (Tailscale CGNAT)
        (0x7F00_0000, 8),   // 127/8
        (0xA9FE_0000, 16),  // 169.254/16
        (0xAC10_0000, 12),  // 172.16/12
        (0xC0A8_0000, 16),  // 192.168/16
        (0xE000_0000, 4),   // 224/4 multicast
        (0xF000_0000, 4),   // 240/4 reserved and broadcast
    ]

    /// The same list as text, for `excludedNetworkRules`.
    public static var excludedIPv4CIDRs: [(address: String, prefix: Int)] {
        excludedIPv4.map { (dotted($0.network), $0.prefix) }
    }

    /// The ranges `excludedNetworkRules` can carry. Leaves out 0/8: its network address is 0.0.0.0,
    /// and an excluded rule (port 0, any) on 0.0.0.0 is wildcard address plus wildcard port, which
    /// macOS rejects ("Either a non-wildcard port or a non-wildcard address must be specified"), so
    /// `setTunnelNetworkSettings` fails and the proxy never starts. `isExcluded` still declines 0/8.
    public static var excludedRuleCIDRs: [(address: String, prefix: Int)] {
        excludedIPv4.filter { $0.network != 0 }.map { (dotted($0.network), $0.prefix) }
    }

    public static func isExcluded(_ a: UInt32) -> Bool {
        excludedIPv4.contains { r in
            let mask: UInt32 = r.prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - r.prefix)
            return a & mask == r.network
        }
    }

    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    public static func dotted(_ a: UInt32) -> String {
        "\(a >> 24 & 0xFF).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
    }
}
