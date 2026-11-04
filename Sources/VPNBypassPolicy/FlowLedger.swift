// FlowLedger.swift
// The extension's counters, and the two small choices it makes after the decider: which
// interface a claimed flow leaves on, and what kind of interface a bound flow was bound to.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, 3.4 step 3, 3.5 and 3.8. Integers and fixed
// tokens only: a counter key is a reason, a rule id or an interface kind, never an app id, an
// address or a host name. Not thread-safe; the extension guards it with the policy's lock.

import Foundation

/// What kind of interface a flow that arrived bound was bound to (3.4 step 3). Claiming flows
/// bound to the physical interface is a later change, made only on these counts.
public enum BoundInterface: String, CaseIterable, Codable, Sendable {
    /// Wi-Fi or Ethernet.
    case physical
    /// A VPN or other tunnel (`utun`, `ipsec`, `ppp`, ...).
    case tunnel
    /// Anything else: cellular, loopback, a bridge.
    case other
    /// The flow said it was bound but named no interface.
    case unknown

    /// The interface type as Network reports it (`nw_interface_get_type`).
    public enum Kind: Sendable {
        case wifi, wired, cellular, loopback, other
    }

    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "gif", "stf"]

    /// A VPN or other tunnel interface, by its name.
    public static func isTunnelName(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    public static func classify(name: String?, kind: Kind?) -> BoundInterface {
        guard let name, !name.isEmpty else { return .unknown }
        // A tunnel's type is `other`, so the name decides first.
        if isTunnelName(name) { return .tunnel }
        switch kind {
        case .wifi, .wired: return .physical
        default: return .other
        }
    }
}

/// The interface a claimed flow leaves on (3.5). `physical` is the Mac's Wi-Fi and Ethernet
/// interfaces, most preferred first. A policy that names an interface gets that one or none: a
/// flow is never sent out an interface the app did not choose. With no interface named, the
/// most preferred one.
public enum EgressInterface {
    public static func pick(named name: String?, from physical: [String]) -> String? {
        if let name, !name.isEmpty { return physical.contains(name) ? name : nil }
        return physical.first
    }
}

/// Whether the egress interface is worth claiming flows for (3.7). A claimed flow cannot be
/// handed back, so when connects out the interface keep failing every claim breaks the app's
/// connection. That happens when the interface has no interface-scoped default route: a VPN that
/// takes 0/1 and 128/1 without becoming the primary service (wg-quick, many route-only clients)
/// leaves the primary physical interface with an unscoped default only, and a connection
/// required to use it waits with no route (measured on the mini, docs/design/NE-ENGINE-LIVE-RESULTS.md).
/// After `threshold` failures in a row on an interface, flows for it are declined for
/// `cooldown` seconds; then one claim is tried again. A success clears the count.
public struct EgressHealth: Sendable {
    public static let threshold = 2
    public static let cooldown: TimeInterval = 30

    private var failures: [String: Int] = [:]
    private var lastFailure: [String: Date] = [:]

    public init() {}

    public func isUsable(_ interface: String, at now: Date) -> Bool {
        guard (failures[interface] ?? 0) >= Self.threshold, let last = lastFailure[interface] else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown || now < last
    }

    /// A claim was made for `interface`. When it is the retry after a cooldown, the cooldown
    /// starts again from now, so only that one claim tests the interface until it reports back.
    public mutating func claimed(_ interface: String, at now: Date) {
        if (failures[interface] ?? 0) >= Self.threshold { lastFailure[interface] = now }
    }

    /// The interface just got a scoped default route (R12): connects that failed on it before
    /// failed for want of that route, so they no longer count.
    public mutating func forget(_ interface: String) {
        failures[interface] = nil
        lastFailure[interface] = nil
    }

    public mutating func record(_ interface: String, succeeded: Bool, at now: Date) {
        if succeeded {
            failures[interface] = nil
            lastFailure[interface] = nil
        } else {
            failures[interface, default: 0] += 1
            lastFailure[interface] = now
        }
    }
}

public struct FlowLedger: Sendable {
    /// Counters about claimed flows, sent in the reply's `counters`.
    public enum Counter: String, CaseIterable, Sendable {
        /// Flows claimed, all rules together.
        case claimed
        /// The outbound connection never became ready (refused, no route, the 10 s give-up).
        case egressFailed
        /// The outbound connection was ready but not on the policy's interface. Should stay 0.
        case egressOffInterface
        /// A connect-by-name flow whose name resolved, on the physical interface, to a protected
        /// address (a private, link-local, CGNAT, loopback or multicast one, or one in a tunnel's
        /// own network). Closed before anything was dialled (`NameAnswer`, design 3.5 step 4).
        case nameProtected
        /// `flow.open` failed after the outbound connection was ready.
        case flowOpenFailed
        /// A claimed flow whose server side failed after it opened (reset, send or receive error).
        case aborted
        /// A claimed flow the app itself reset (it closed without a clean shutdown, which
        /// clients often do once they have their answer). Not a failure of ours.
        case appReset
        /// Claimed flows open right now.
        case active
        case bytesUp
        case bytesDown
    }

    public private(set) var declined: [String: Int] = [:]
    public private(set) var claimedByRule: [String: Int] = [:]
    public private(set) var boundByRule: [String: Int] = [:]
    public private(set) var boundByInterface: [String: Int] = [:]
    public private(set) var counters: [String: Int] = [:]

    public init() {}

    /// Counts one verdict. `bound` is the kind of interface a bound flow was bound to, read only
    /// for flows declined as bound.
    public mutating func record(_ decision: FlowDecision, bound: BoundInterface? = nil) {
        switch decision {
        case .claim(let ruleID, _):
            claimedByRule[ruleID, default: 0] += 1
            counters[Counter.claimed.rawValue, default: 0] += 1
        case .decline(let reason, let ruleID):
            declined[reason.rawValue, default: 0] += 1
            guard reason == .bound else { return }
            if let ruleID { boundByRule[ruleID, default: 0] += 1 }
            boundByInterface[(bound ?? .unknown).rawValue, default: 0] += 1
        }
    }

    public mutating func add(_ counter: Counter, _ n: Int = 1) {
        counters[counter.rawValue, default: 0] += n
    }

    public func count(_ counter: Counter) -> Int { counters[counter.rawValue] ?? 0 }

    /// The reply to any message: the policy the extension holds, its lease, and the counts.
    public func reply(state: FlowPolicyState, now: Date, extensionVersion: String?) -> FlowPolicyReply {
        FlowPolicyReply(policyGeneration: state.policy?.generation ?? 0,
                        policyLive: state.isLeaseLive(at: now),
                        rejectedVersion: state.rejectedVersion,
                        leaseExpiries: state.leaseExpiries,
                        declined: declined, claimedByRule: claimedByRule, boundByRule: boundByRule,
                        boundByInterface: boundByInterface, counters: counters,
                        extensionVersion: extensionVersion)
    }
}
