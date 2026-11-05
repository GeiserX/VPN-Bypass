// NameAnswer.swift
// What a claimed connect-by-name flow does with the answer to its lookup on the physical interface.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, 3.5 step 4. `handleNewFlow` cannot resolve a
// name (3.4: no DNS), so the decider checks only names that are address literals or local names.
// A real name is resolved in the re-emit path, scoped to the physical interface, and its answer
// is checked here before anything is dialled: an answer in the protected ranges or in a tunnel's
// own network must never leave the physical interface. Such a flow is already claimed and cannot
// be handed back, so it is closed (the app sees a failed connect) and counted as `nameProtected`.

import Foundation

/// An IPv4 network as an address and a netmask, host byte order.
public struct IPv4Network: Equatable, Sendable {
    public var address: UInt32
    public var netmask: UInt32

    public init(address: UInt32, netmask: UInt32) {
        self.address = address & netmask
        self.netmask = netmask
    }

    public func contains(_ a: UInt32) -> Bool { a & netmask == address }
}

/// One IPv4 address of an interface, as `getifaddrs` reports it.
public struct InterfaceAddress: Equatable, Sendable {
    public var name: String
    public var address: UInt32
    public var netmask: UInt32
    /// The far end of a point-to-point link (`ifa_dstaddr` on an `IFF_POINTOPOINT` interface).
    public var destination: UInt32?

    public init(name: String, address: UInt32, netmask: UInt32, destination: UInt32? = nil) {
        self.name = name
        self.address = address
        self.netmask = netmask
        self.destination = destination
    }
}

public enum NameAnswer: Equatable, Sendable {
    /// Dial these addresses out the physical interface, in the order they came and each once:
    /// the first, then the next when a connect fails. All of them passed the check.
    case dial([UInt32])
    /// An answer is protected: close the flow.
    case protected
    /// No IPv4 answer: close the flow as unreachable.
    case noAnswer

    /// The networks of the VPN's own interfaces (`utun`, `ipsec`, `ppp`, ...): each tunnel
    /// address's network, and the far end of a point-to-point tunnel. Physical interfaces are left
    /// out: their networks are private ranges, which `ProtectedRanges` covers already.
    public static func tunnelNetworks(_ addresses: [InterfaceAddress]) -> [IPv4Network] {
        addresses.filter { BoundInterface.isTunnelName($0.name) }.flatMap { a -> [IPv4Network] in
            var nets = [IPv4Network(address: a.address, netmask: a.netmask)]
            if let d = a.destination, d != 0 { nets.append(IPv4Network(address: d, netmask: ~0)) }
            return nets
        }
    }

    /// The verdict on a lookup's IPv4 answers. Any protected answer refuses the whole name, not
    /// just that address: the name points into a network the VPN or the local link owns, so the
    /// app expects to reach it there, never past the VPN.
    public static func check(_ answers: [UInt32], tunnelNetworks: [IPv4Network]) -> NameAnswer {
        guard !answers.isEmpty else { return .noAnswer }
        let isProtected = answers.contains { a in
            ProtectedRanges.contains(a) || tunnelNetworks.contains { $0.contains(a) }
        }
        guard !isProtected else { return .protected }
        var seen = Set<UInt32>()
        return .dial(answers.filter { seen.insert($0).inserted })
    }
}
