// FlowPolicy.swift
// What the app sends the per-app routing extension, and what the extension answers.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, 3.3 (config delivery) and 3.8 (privacy).
// The policy travels in `sendProviderMessage`, never in `providerConfiguration` (that plist is
// world-readable), and the extension holds it in memory only. This target imports Foundation
// only, so it builds and tests on any Mac, and the extension can link it without VPNBypassCore.

import Foundation

/// Where a claimed flow goes. v1 serves `direct` only; the other cases exist so a process rule
/// with another route still takes part in first match and is declined by name, not skipped.
public enum FlowEgress: Codable, Hashable, Sendable {
    /// Out the physical interface, past the VPN. Nil lets the extension pick the most preferred
    /// Wi-Fi or Ethernet interface itself.
    case direct(interface: String?)
    /// The VPN's default route: leaving the flow alone already does that, so it is declined.
    case vpnDefault
    /// A route v1 cannot carry (a pinned tunnel, a proxy, a Tailscale exit). Declined.
    case unsupported
}

/// One process rule as the extension sees it: a pattern and where its flows go.
public struct AppMatcher: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Equal to the flow's signing identifier, or a parent of it on a dot boundary.
        case bundleID
        /// Equal to the last part of the flow's executable path.
        case executableName
    }

    /// The rule's id, so counters land on the rule. A rule UUID, or `bypass-app-<n>` for an
    /// entry of Bypass mode's Apps list. Never an app name: replies carry rule ids only.
    public var ruleID: String
    public var kind: Kind
    public var pattern: String
    public var egress: FlowEgress

    public init(ruleID: String, kind: Kind, pattern: String, egress: FlowEgress) {
        self.ruleID = ruleID
        self.kind = kind
        self.pattern = pattern
        self.egress = egress
    }

    /// The kind a pattern takes: with a dot a bundle id, without one an executable name
    /// (the same split as `ProcessRule.kind(of:)` in the app).
    public static func kind(of pattern: String) -> Kind {
        pattern.contains(".") ? .bundleID : .executableName
    }
}

/// The whole per-app policy. Every decision lives here, so a rule change is one push and never
/// a change of the include rules or a restart of the extension.
public struct FlowPolicy: Codable, Equatable, Sendable {
    /// The shape this build reads. An extension that receives another version declines every flow
    /// and says so in its reply (`FlowPolicyReply.rejectedVersion`).
    public static let currentVersion = 1
    /// Without a fresh push within this many seconds the extension declines every flow.
    public static let defaultLeaseSeconds = 120

    public var version: Int
    /// Raised by the app on every push. The extension echoes the generation it holds, and the app
    /// counts a push that takes matchers away only once that echo arrives (3.3).
    public var generation: Int
    /// In first-match order.
    public var matchers: [AppMatcher]
    /// Team ids whose flows are never claimed, on top of `FlowDecider.protectedTeams`: the teams
    /// of the processes that own the live tunnels.
    public var declinedTeams: [String]
    public var leaseSeconds: Int

    public init(version: Int = FlowPolicy.currentVersion, generation: Int, matchers: [AppMatcher],
                declinedTeams: [String] = [], leaseSeconds: Int = FlowPolicy.defaultLeaseSeconds) {
        self.version = version
        self.generation = generation
        self.matchers = matchers
        self.declinedTeams = declinedTeams
        self.leaseSeconds = leaseSeconds
    }

    /// A policy that claims nothing (Pause, VPN Only, a kill switch). The include rule stays
    /// installed, so every new TCP flow still asks the extension; it just declines them all.
    public var claimsNothing: Bool {
        !matchers.contains { if case .direct = $0.egress { return true } else { return false } }
    }

    /// True when replacing `previous` with this policy can stop the extension claiming a flow it
    /// claims today, or send it out another interface: a Direct matcher removed or changed, a
    /// matcher with another egress put in front of one, or a declined team added. The app shows
    /// such a change only after the extension echoes this generation, and stops the session when
    /// the echo does not come (3.3). Adding or reordering matchers that send flows the same way
    /// does not count: a flow a Direct matcher claimed is then still claimed the same way.
    /// A nil `previous` means the app does not know what the extension holds (its first push
    /// after a launch, while an older lease may still be live), so it counts as a shrink.
    public func shrinksClaims(from previous: FlowPolicy?) -> Bool {
        guard let previous else { return true }
        if !Set(previous.declinedTeams).isSuperset(of: declinedTeams) { return true }
        for (i, claimer) in previous.matchers.enumerated() {
            guard case .direct = claimer.egress else { continue }
            // The flows `claimer` claimed matched nothing in front of it before. They are still
            // claimed the same way if it is still here and everything now in front of it either
            // sends flows the same way or was in front of it before (and so matched none of them).
            guard let j = matchers.firstIndex(of: claimer) else { return true }
            let before = Set(previous.matchers[..<i])
            if matchers[..<j].contains(where: { $0.egress != claimer.egress && !before.contains($0) }) { return true }
        }
        return false
    }
}

/// What the extension answers to a policy push or a status request. Integers and fixed tokens
/// only: no app ids, no addresses, no host names (3.8).
public struct FlowPolicyReply: Codable, Equatable, Sendable {
    /// The generation of the policy the extension holds, 0 when it holds none.
    public var policyGeneration: Int
    /// The policy's lease has not run out.
    public var policyLive: Bool
    /// Set when the last push carried a version this extension does not read.
    public var rejectedVersion: Int?
    /// How many times the lease ran out without a fresh push.
    public var leaseExpiries: Int
    /// Flows declined, by `FlowDecision.Reason` raw value.
    public var declined: [String: Int]
    /// Per rule id: flows claimed.
    public var claimedByRule: [String: Int]
    /// Per rule id: flows declined because they arrived bound to an interface.
    public var boundByRule: [String: Int]

    public init(policyGeneration: Int = 0, policyLive: Bool = false, rejectedVersion: Int? = nil,
                leaseExpiries: Int = 0, declined: [String: Int] = [:], claimedByRule: [String: Int] = [:],
                boundByRule: [String: Int] = [:]) {
        self.policyGeneration = policyGeneration
        self.policyLive = policyLive
        self.rejectedVersion = rejectedVersion
        self.leaseExpiries = leaseExpiries
        self.declined = declined
        self.claimedByRule = claimedByRule
        self.boundByRule = boundByRule
    }

    /// True when this reply shows `policy` live in the extension.
    public func confirms(_ policy: FlowPolicy) -> Bool {
        rejectedVersion == nil && policyLive && policyGeneration == policy.generation
    }
}

/// A policy message as the extension reads it: the version is read first, so a newer app's
/// policy is reported as a version mismatch instead of a decode failure.
public enum FlowPolicyMessage: Equatable, Sendable {
    case policy(FlowPolicy)
    case unknownVersion(Int)
    case malformed

    public static func encode(_ policy: FlowPolicy) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(policy)
    }

    public static func decode(_ data: Data) -> FlowPolicyMessage {
        struct Versioned: Decodable { var version: Int }
        guard let v = try? JSONDecoder().decode(Versioned.self, from: data) else { return .malformed }
        guard v.version == FlowPolicy.currentVersion else { return .unknownVersion(v.version) }
        guard let p = try? JSONDecoder().decode(FlowPolicy.self, from: data) else { return .malformed }
        return .policy(p)
    }
}
