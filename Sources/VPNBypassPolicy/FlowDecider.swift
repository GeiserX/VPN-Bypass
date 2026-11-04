// FlowDecider.swift
// The extension's verdict on one new flow: claim it (and where it goes) or decline it (and why).
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, 3.4. `handleNewFlow` is synchronous and must
// never block, so this is pure: one in-memory policy, the flow's facts, the clock. The two costly
// facts (the executable path and the team id, both read from the audit token) are closures, run
// only when the verdict needs them, at most once each. A declined flow goes on as if no proxy were
// there, which is the kernel engine's routing: declining is always the safe answer.

import Foundation

/// What the extension knows about a new flow.
public struct FlowFacts {
    public enum Remote: Equatable, Sendable {
        /// Host byte order.
        case ipv4(UInt32)
        case ipv6
        /// A connect-by-name flow whose endpoint is still a host name.
        case name(String)
        case unknown
    }

    public enum Transport: Equatable, Sendable {
        case tcp
        case udp
    }

    /// `NEFlowMetaData.sourceAppSigningIdentifier`.
    public var signingIdentifier: String
    public var remote: Remote
    /// `NEAppProxyFlow.remoteHostname`. Never used to match in v1 (3.4): a host name alone never
    /// claims a flow.
    public var remoteHostname: String?
    /// `NEAppProxyFlow.isBound`: the app bound its socket to an interface.
    public var isBound: Bool
    public var transport: Transport
    /// The flow's executable path (from the audit token), for executable-name matchers.
    public var executablePath: () -> String?
    /// The flow's team id (from its code signature), for the protected-team check.
    public var teamIdentifier: () -> String?

    public init(signingIdentifier: String, remote: Remote, remoteHostname: String? = nil,
                isBound: Bool = false, transport: Transport = .tcp,
                executablePath: @escaping () -> String? = { nil },
                teamIdentifier: @escaping () -> String? = { nil }) {
        self.signingIdentifier = signingIdentifier
        self.remote = remote
        self.remoteHostname = remoteHostname
        self.isBound = isBound
        self.transport = transport
        self.executablePath = executablePath
        self.teamIdentifier = teamIdentifier
    }
}

/// The verdict on one flow.
public enum FlowDecision: Equatable, Sendable {
    public enum Reason: String, CaseIterable, Codable, Sendable {
        /// No policy yet, or the last push carried a version this build does not read.
        case noPolicy
        case unknownVersion
        case leaseExpired
        /// VPN Bypass's own app, CLI, helper or extension.
        case ownProcess
        /// Name resolution, push, captive portal and the Network Extension daemons.
        case systemProcess
        /// The app bound its socket to an interface (seen for NSURLSession HTTPS, spike B4).
        case bound
        /// UDP: v1 claims TCP only (3.6).
        case notTCP
        case ipv6
        /// Private, link-local, loopback, multicast, reserved or Tailscale's range.
        case protectedDestination
        /// The flow's remote endpoint could not be read.
        case unknownDestination
        /// No matcher names the flow's app.
        case noMatch
        /// The first matching rule sends the app to the VPN, which is where it already goes.
        case vpnRoute
        /// The first matching rule's route is one v1 cannot carry.
        case unsupportedRoute
        /// A VPN or network-security client, by team id.
        case protectedTeam
        /// Claimable, but the egress interface is not up (the policy's, or no Wi-Fi or Ethernet
        /// at all). Decided by the extension after the decider, never by `decide`.
        case noInterface
        /// Claimable, but the last connects out the egress interface failed (`EgressHealth`):
        /// left to normal routing, so the app still gets through the VPN instead of failing.
        case egressUnusable
    }

    /// Claim the flow for `ruleID` and send it out `egress`.
    case claim(ruleID: String, egress: FlowEgress)
    /// Leave the flow alone. `ruleID` is the matching rule's, when one matched, so per-rule
    /// counters can say "this app's flows arrive bound".
    case decline(Reason, ruleID: String?)

    public static func decline(_ reason: Reason) -> FlowDecision { .decline(reason, ruleID: nil) }
}

/// The live policy and when it arrived. Not thread-safe; the extension guards it with a lock.
public struct FlowPolicyState: Sendable {
    public private(set) var policy: FlowPolicy?
    public private(set) var receivedAt: Date?
    /// The version of the last push this build could not read, until a readable one arrives.
    public private(set) var rejectedVersion: Int?
    /// How many times a policy's lease ran out before the next push (`expireLease`).
    public private(set) var leaseExpiries = 0

    public init() {}

    /// The extension's watchdog, run on a timer whether flows arrive or not: once the lease has
    /// run out, the policy is dropped, so every flow is declined and the reply shows no policy
    /// (generation 0) instead of a stale one. Returns true on the tick that dropped it.
    public mutating func expireLease(at now: Date) -> Bool {
        guard policy != nil, !isLeaseLive(at: now) else { return false }
        policy = nil
        receivedAt = nil
        leaseExpiries += 1
        return true
    }

    /// The session stopped (`stopProxy`): drop the policy, so a session started again in the same
    /// process declines every flow until the app pushes, instead of claiming with the policy of the
    /// session that was turned off while its lease still runs. Not a lapse, so not counted.
    public mutating func sessionStopped() {
        policy = nil
        receivedAt = nil
    }

    /// Takes in a pushed message. An unreadable one drops the live policy, so every flow is
    /// declined until the app pushes one this build reads (3.3).
    public mutating func receive(_ message: FlowPolicyMessage, at now: Date) {
        switch message {
        case .status:
            // A status read neither renews the lease nor drops the policy.
            return
        case .policy(let p):
            policy = p
            receivedAt = now
            rejectedVersion = nil
        case .unknownVersion(let v):
            policy = nil
            receivedAt = nil
            rejectedVersion = v
        case .malformed:
            policy = nil
            receivedAt = nil
        }
    }

    public func isLeaseLive(at now: Date) -> Bool {
        guard let p = policy, let t = receivedAt else { return false }
        let age = now.timeIntervalSince(t)
        // Capped: a lease is the promise that a quit or crashed app stops per-app routing soon,
        // so a policy cannot ask for a longer one.
        return age >= 0 && age <= TimeInterval(min(p.leaseSeconds, FlowPolicy.maxLeaseSeconds))
    }
}

public enum FlowDecider {
    /// VPN Bypass's own binaries: never claimed, whatever a matcher says.
    public static let ownIdentifiers: Set<String> = [
        "com.geiserx.vpn-bypass",        // the app
        "com.geiserx.vpn-bypass.vpnb",   // the CLI
        "com.geiserx.vpnbypass.helper",  // the helper, whose wildcard forwarder asks upstream DNS
        "com.geiserx.vpn-bypass.proxy",  // the extension itself
    ]

    /// System daemons a transparent proxy must leave alone: name resolution, push, captive
    /// portals, the Network Extension machinery.
    public static let systemIdentifiers: Set<String> = [
        "com.apple.mDNSResponder", "com.apple.mDNSResponderHelper", "com.apple.apsd",
        "com.apple.captiveagent", "com.apple.nesessionmanager", "com.apple.networkserviceproxy",
        "com.apple.symptomsd", "com.apple.configd", "com.apple.neagent",
    ]

    /// VPN and network-security vendors, by team id. A team id, not a signing id: GlobalProtect's
    /// daemon is signed with the bare identifier `PanGPS`, so only its team identifies it. Every id
    /// marked "codesign" was read with `codesign -dv` from the vendor's own signed app (the app and
    /// every bundle and extension inside it carry the same team), downloaded from the vendor's
    /// site and never installed; the others come from the vendor's published MDM system-extension
    /// docs, since their installers sit behind a customer login. A VPN missing here is still
    /// declined while it owns a live tunnel: the app adds that owner's team to
    /// `FlowPolicy.declinedTeams`.
    public static let protectedTeams: Set<String> = [
        "PXPZ95SK77", // Palo Alto Networks (GlobalProtect): codesign 2026-11-04
        "W5364U7YZB", // Tailscale: codesign 2026-11-04
        "94KV3E626L", // AWS VPN Client (AMZN Mobile LLC): codesign 2026-11-04
        "AH4XFXJ7DK", // Fortinet (FortiClient VPN): codesign 2026-11-04
        "68WVV388M8", // Cloudflare (WARP): codesign 2026-11-04
        "ACV7L3WCD8", // OpenVPN Inc. (OpenVPN Connect): codesign 2026-11-04
        "J6S6Q257EK", // Proton VPN: codesign 2026-11-04
        "CKG9MXH72F", // Mullvad VPN: codesign 2026-11-04
        "W5W395V82Y", // NordVPN: codesign 2026-11-04
        "TC292Y5427", // ExpressVPN: codesign 2026-11-04
        "YHUG37CKN8", // Surfshark: codesign 2026-11-04
        "5357M5NW9W", // Private Internet Access: codesign 2026-11-04
        "DE8Y96K9QP", // Cisco (Secure Client, AnyConnect): vendor docs
        "PCBCQZJ7S7", // Zscaler: vendor docs
    ]

    /// The verdict on one flow, in the order of design 3.4. The matching runs before the team
    /// check because the team check reads a code signature: only a flow that would otherwise be
    /// claimed pays for it.
    public static func decide(_ f: FlowFacts, state: FlowPolicyState, now: Date) -> FlowDecision {
        // 1. A live policy this build reads.
        guard let policy = state.policy else {
            return .decline(state.rejectedVersion == nil ? .noPolicy : .unknownVersion)
        }
        guard policy.version == FlowPolicy.currentVersion else { return .decline(.unknownVersion) }
        guard state.isLeaseLive(at: now) else { return .decline(.leaseExpired) }

        // 2. Our own processes and the system's.
        if ownIdentifiers.contains(f.signingIdentifier) { return .decline(.ownProcess) }
        if systemIdentifiers.contains(f.signingIdentifier) { return .decline(.systemProcess) }

        // 3. Bound flows. Still matched (a string compare), so the count lands on the rule.
        if f.isBound {
            return .decline(.bound, ruleID: firstMatch(policy.matchers, f)?.ruleID)
        }

        // 4. What the flow is and where it goes.
        guard f.transport == .tcp else { return .decline(.notTCP) }
        switch ProtectedRanges.literal(f.remote) {
        case .ipv6: return .decline(.ipv6)
        case .ipv4(let a) where ProtectedRanges.contains(a): return .decline(.protectedDestination)
        case .name(let n) where ProtectedRanges.isLocalName(n): return .decline(.protectedDestination)
        case .unknown: return .decline(.unknownDestination)
        case .ipv4, .name: break
        }

        // 5. The first matching process rule, and its route.
        guard let m = firstMatch(policy.matchers, f) else { return .decline(.noMatch) }
        switch m.egress {
        case .vpnDefault: return .decline(.vpnRoute, ruleID: m.ruleID)
        case .unsupported: return .decline(.unsupportedRoute, ruleID: m.ruleID)
        case .direct: break
        }

        // 6. VPN and security clients, by team: the fixed list and the live tunnels' owners.
        if let team = f.teamIdentifier(), protectedTeams.contains(team) || policy.declinedTeams.contains(team) {
            return .decline(.protectedTeam, ruleID: m.ruleID)
        }

        // 7. Claim it.
        return .claim(ruleID: m.ruleID, egress: m.egress)
    }

    /// The first matcher that names the flow's app. The executable path is read at most once,
    /// and only when an executable-name matcher is reached.
    static func firstMatch(_ matchers: [AppMatcher], _ f: FlowFacts) -> AppMatcher? {
        var path: String??
        for m in matchers where !m.pattern.isEmpty {
            switch m.kind {
            case .bundleID:
                if f.signingIdentifier == m.pattern || f.signingIdentifier.hasPrefix(m.pattern + ".") { return m }
            case .executableName:
                if path == nil { path = .some(f.executablePath()) }
                if let p = path ?? nil, (p as NSString).lastPathComponent == m.pattern { return m }
            }
        }
        return nil
    }
}

/// Destinations never claimed, whatever the rule: the same ranges `excludedNetworkRules` carries,
/// checked again here because excluded rules have been reported ignored (FB14453214).
public enum ProtectedRanges {
    public static let ipv4: [(network: UInt32, prefix: Int)] = [
        (0x0000_0000, 8),   // 0/8
        (0x0A00_0000, 8),   // 10/8
        (0x6440_0000, 10),  // 100.64/10 (CGNAT: Tailscale, MagicDNS)
        (0x7F00_0000, 8),   // 127/8
        (0xA9FE_0000, 16),  // 169.254/16
        (0xAC10_0000, 12),  // 172.16/12
        (0xC0A8_0000, 16),  // 192.168/16
        (0xE000_0000, 4),   // 224/4 multicast
        (0xF000_0000, 4),   // 240/4 reserved and broadcast
    ]

    /// The IPv6 ranges for `excludedNetworkRules`. Every IPv6 flow is declined anyway (v1 routes
    /// IPv4 only), so these matter only for keeping such flows out of the extension at all.
    public static let ipv6CIDRs: [(address: String, prefix: Int)] = [
        ("fc00::", 7), ("fe80::", 10), ("ff00::", 8), ("fd7a:115c:a1e0::", 48),
    ]

    /// A connect-by-name endpoint whose name is an address literal, read as that address, so the
    /// range and IPv6 checks still apply (`.name("10.0.0.5")` is 10/8, `.name("::1")` is IPv6).
    /// A real name stays a name: its answer is checked where it is resolved (3.5 step 4).
    public static func literal(_ remote: FlowFacts.Remote) -> FlowFacts.Remote {
        guard case .name(let n) = remote else { return remote }
        if let a = parse(n) { return .ipv4(a) }
        if n.contains(":") { return .ipv6 }
        return remote
    }

    /// Names that never leave the Mac or the local link: `localhost` and mDNS `.local` names.
    public static func isLocalName(_ name: String) -> Bool {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        return n == "localhost" || n.hasSuffix(".localhost") || n == "local" || n.hasSuffix(".local")
    }

    public static func contains(_ a: UInt32) -> Bool {
        ipv4.contains { r in
            let mask: UInt32 = r.prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - r.prefix)
            return a & mask == r.network
        }
    }

    /// The IPv4 ranges `excludedNetworkRules` can carry. Leaves out 0/8: an excluded rule on
    /// 0.0.0.0 with port 0 is a wildcard address and port, which macOS rejects, so the proxy would
    /// never start (spike 0.1.1). `contains` still declines 0/8.
    public static var ipv4RuleCIDRs: [(address: String, prefix: Int)] {
        ipv4.filter { $0.network != 0 }.map { (dotted($0.network), $0.prefix) }
    }

    /// A dotted-quad IPv4 address in host byte order, nil for anything else.
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ ("0"..."9").contains($0) }), let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    public static func dotted(_ a: UInt32) -> String {
        "\(a >> 24 & 0xFF).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
    }
}
