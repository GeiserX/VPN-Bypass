import Foundation

/// What the app sends the extension. Delivered with `sendProviderMessage`, held in memory only,
/// never written to `providerConfiguration` (that plist is world-readable).
public struct SpikePolicy: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Bumped by the app on every push, echoed back in the status.
    public var generation: Int
    /// Bundle ids (match exactly or on a dot boundary) or bare executable names.
    public var apps: [String]
    /// Hostnames (match exactly or as a parent domain). Only connect-by-name flows carry one.
    public var hostnames: [String]
    /// Without a fresh push within this many seconds the extension declines every flow.
    public var leaseSeconds: Int
    /// Physical interface to egress on; nil picks the most preferred Wi-Fi or Ethernet interface.
    public var interfaceName: String?

    public init(version: Int = SpikePolicy.currentVersion, generation: Int, apps: [String], hostnames: [String],
                leaseSeconds: Int = 120, interfaceName: String? = nil) {
        self.version = version
        self.generation = generation
        self.apps = apps
        self.hostnames = hostnames
        self.leaseSeconds = leaseSeconds
        self.interfaceName = interfaceName
    }

    /// An empty policy: the include rule stays installed, every flow is declined ("pause").
    public var isEmpty: Bool { apps.isEmpty && hostnames.isEmpty }

    /// Normalises what a person typed: trims, lowercases host names, drops blanks and duplicates.
    public static func parseList(_ text: String, lowercase: Bool) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { s -> String in
                var t = s.trimmingCharacters(in: .whitespaces)
                if lowercase { t = t.lowercased() }
                while t.hasSuffix(".") { t.removeLast() }
                return t
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// App to extension. `policy == nil` asks for the status only.
public struct SpikeRequest: Codable, Equatable {
    public var policy: SpikePolicy?
    public init(policy: SpikePolicy?) { self.policy = policy }
}

/// Extension to app. Integers and two fixed tokens only: no app ids, no addresses, no host names.
public struct SpikeStatus: Codable, Equatable {
    public var extensionPID: Int32 = 0
    public var startedAt: Int = 0
    public var scope: String = ""
    public var policyGeneration: Int = 0
    public var policyLive: Bool = false
    public var interfaceName: String = ""
    public var counters: [String: Int] = [:]

    public init() {}
}

/// Which outbound TCP the include rule hands to the extension. Set once at start, never changed at
/// runtime (a change would need `setTunnelNetworkSettings`, which may close flows).
public enum IncludeScope: Equatable {
    /// Every outbound TCP flow except loopback (the v1 design).
    case allTCP
    /// Only outbound TCP to this remote port, over IPv4. Port 80 keeps a VPN client's own TLS
    /// connections (port 443) outside the include rule, for the first, narrow pass.
    case tcpPort(UInt16)

    public init?(_ text: String?) {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        if t == "all" { self = .allTCP; return }
        if t.hasPrefix("port:"), let p = UInt16(t.dropFirst(5)), p > 0 { self = .tcpPort(p); return }
        return nil
    }

    public var token: String {
        switch self {
        case .allTCP: return "all"
        case .tcpPort(let p): return "port:\(p)"
        }
    }
}
