// ScopedDefaultRoute.swift
// Per-app routing's scoped default route on the physical interface (R12, design 3.5). Compiled
// into the app and the privileged helper, so the helper's decisions are tested from the app target.
//
// A VPN that covers the internet with two half routes (`0/1` and `128/1`, as wg-quick does) and
// does not become the primary service leaves the primary physical interface with an unscoped
// default only. A connection required to leave on that interface (the extension's scoped connect
// for a listed app) then finds no route: `route -n get -ifscope en0 1.1.1.1` answers "not in
// table" and `curl --interface en0` fails at once (mini, 2026-11-04). One route fixes it:
// `route -n add -ifscope <iface> default <router>`. It serves only connections scoped to that
// interface; the half routes still win for everything else, so unlisted apps stay in the VPN.
//
// The helper adds it only while per-app routing claims flows and the VPN is up, only when the
// interface has no scoped default already, and only next to the interface's own unscoped default
// through the same router. It tags it `RTF_PROTO1` like every route of ours, and never touches
// the unscoped default or the VPN's routes.

import Darwin
import Foundation

/// The route the app asks the helper for: a default scoped to `interface`, through `gateway`.
public struct ScopedDefaultRequest: Equatable, Sendable {
    public let interface: String
    public let gateway: String

    public init(interface: String, gateway: String) {
        self.interface = interface
        self.gateway = gateway
    }
}

/// What a request left in the table, as the helper answers it. Fixed tokens, no addresses.
public enum ScopedDefaultOutcome: String, Equatable, Sendable {
    /// The helper added ours.
    case added
    /// Ours was already there, through the same router.
    case kept
    /// The interface already has a scoped default that is not ours (a VPN that became the
    /// primary service leaves one): nothing to add.
    case systemRoute
    /// Ours was removed.
    case removed
    /// Nothing of ours was there to remove.
    case absent
    /// Ours stays because the interface stopped carrying the unscoped default: macOS keeps a
    /// scoped default for a non-primary interface and may rely on this one (a VPN client binds
    /// its own tunnel to it), so removing it could cut that VPN. The helper forgets it; the
    /// kernel drops it with the interface's address.
    case leftInPlace
    /// Refused: the interface does not carry an unscoped default through that router, so the
    /// request does not describe this Mac's network (a stale gateway, a wrong interface).
    case refused
    /// The kernel refused the write, or the table could not be read.
    case failed

    /// The interface has a scoped default now, so a scoped connect for a listed app can leave on it.
    public var interfaceHasRoute: Bool { self == .added || self == .kept || self == .systemRoute }
}

public enum ScopedDefaultRoute {
    // MARK: - App side

    /// The route per-app routing wants, nil for none. Wanted only while the engine claims
    /// flows (on, its session up, and a policy with app rules: Pause, VPN Only and a kill switch
    /// claim nothing), the VPN is up, and both the physical interface and its router are known.
    /// The helper decides whether the interface already has one.
    public static func want(engineClaims: Bool, vpnConnected: Bool, interface: String?, gateway: String?) -> ScopedDefaultRequest? {
        guard engineClaims, vpnConnected, let interface, let gateway,
              isValidInterface(interface), isValidGateway(gateway) else { return nil }
        return ScopedDefaultRequest(interface: interface, gateway: gateway)
    }

    // MARK: - Validation (the helper checks again at its boundary)

    /// A physical interface name: `en` and up to three digits. A tunnel (`utun`, `ipsec`,
    /// `ppp`), a bridge or anything else is refused, so the helper can never scope a default to
    /// the VPN or to an interface it does not understand.
    public static func isValidInterface(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let digits = name.dropFirst(2)
        return (1...3).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A router address: a canonical dotted IPv4 (no leading zeros, which `route` would read as
    /// octal), unicast, not in 0/8, loopback, link-local or multicast. IPv6 is out of scope:
    /// per-app routing dials IPv4 only.
    public static func isValidGateway(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for p in parts {
            guard let n = Int(p), (0...255).contains(n), String(n) == p else { return false }
            octets.append(n)
        }
        if octets[0] == 0 || octets[0] == 127 || octets[0] >= 224 { return false }
        if octets[0] == 169 && octets[1] == 254 { return false }
        return true
    }

    // MARK: - Helper side

    /// What the helper writes for one request, read from one table dump.
    public struct Plan: Equatable, Sendable {
        /// Our scoped defaults to delete, by the interface index each is scoped to.
        public var delete: [UInt16]
        /// Add ours on the request's interface.
        public var add: Bool
        /// What the request leaves, once the writes succeeded.
        public var outcome: ScopedDefaultOutcome
    }

    /// Our scoped defaults in `table`: default, scoped, tagged by us, not a clone.
    public static func ours(in table: [RouteKernel.KernelRoute]) -> [RouteKernel.KernelRoute] {
        table.filter { $0.isDefault && $0.isScoped && $0.isOurs && $0.flags & RTF_WASCLONED == 0 }
    }

    /// Whether our scoped default on `index` may go. Not when the unscoped default moved to
    /// another interface: macOS keeps a scoped default for every non-primary interface, and when
    /// ours was there first it may be the one the system now relies on (see `leftInPlace`).
    public static func mayRemove(scopedTo index: UInt16, table: [RouteKernel.KernelRoute]) -> Bool {
        let unscoped = table.filter { $0.isDefault && !$0.isScoped && $0.flags & RTF_UP != 0 && $0.flags & RTF_WASCLONED == 0 }
        return unscoped.isEmpty || unscoped.contains { $0.interfaceIndex == index }
    }

    /// The plan for `request` (nil: remove ours). `interfaceIndex` is the request's interface
    /// resolved by the caller, nil when it does not exist.
    public static func plan(_ request: ScopedDefaultRequest?, interfaceIndex: UInt16?,
                            table: [RouteKernel.KernelRoute]) -> Plan {
        let mine = ours(in: table)
        let removable = mine.filter { mayRemove(scopedTo: $0.interfaceIndex, table: table) }.map(\.interfaceIndex)
        let stays = mine.count > removable.count
        /// Every one of ours goes (or stays, by `mayRemove`), with this outcome.
        func clear(_ outcome: ScopedDefaultOutcome) -> Plan {
            Plan(delete: removable, add: false, outcome: outcome)
        }
        guard let request else {
            if removable.isEmpty { return clear(stays ? .leftInPlace : .absent) }
            return clear(.removed)
        }
        guard let index = interfaceIndex, let gateway = RouteKernel.ipv4ToUInt32(request.gateway) else { return clear(.refused) }
        // The interface has a scoped default that is not ours: nothing to add.
        if table.contains(where: { $0.isDefault && $0.isScoped && !$0.isOurs && $0.interfaceIndex == index
                                   && $0.flags & RTF_UP != 0 && $0.flags & RTF_WASCLONED == 0 }) {
            return clear(.systemRoute)
        }
        let others = removable.filter { $0 != index }
        if mine.contains(where: { $0.interfaceIndex == index && $0.gatewayAddress == gateway }) {
            return Plan(delete: others, add: false, outcome: .kept)
        }
        // Only next to the interface's own unscoped default through the same router.
        guard table.contains(where: { $0.isDefault && !$0.isScoped && $0.interfaceIndex == index
                                      && $0.gatewayAddress == gateway && $0.flags & RTF_UP != 0
                                      && $0.flags & RTF_WASCLONED == 0 }) else {
            return clear(.refused)
        }
        // Ours on this interface through another router goes first; the add puts the new one in.
        return Plan(delete: removable, add: true, outcome: .added)
    }
}
