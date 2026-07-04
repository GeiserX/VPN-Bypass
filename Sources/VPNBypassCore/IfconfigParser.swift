// IfconfigParser.swift
// Pure parsing of `/sbin/ifconfig` output into the VPN-like tunnels it lists.
//
// RouteManager.listVPNLinks shells out to ifconfig and then labels/filters the result
// with live actor state (vpnInterface/vpnType/Tailscale detection). The TEXT PARSING —
// which interfaces exist, in what order, whether each is UP, and its IPv4 inet
// addresses — is pure and has no reason to touch a process or the actor, so it lives
// here and is unit-testable exactly like RouteCompiler / RuleResolver.

import Foundation

enum IfconfigParser {

    /// One VPN-like interface parsed from `ifconfig` output.
    struct ParsedInterface: Equatable {
        let interface: String
        /// IPv4 `inet` addresses, in the order they appear under the interface.
        let addresses: [String]
        /// The `UP` flag was present in the interface's `<...>` flag list.
        let isUp: Bool
        /// At least one address is one of the local node's Tailscale addresses.
        let isTailscale: Bool
    }

    /// Parse raw `ifconfig` output into the VPN-like interfaces it lists.
    ///
    /// - Parameters:
    ///   - output: the full text of `ifconfig`.
    ///   - tailscaleIPs: the local node's Tailscale addresses, so its utun is flagged.
    ///   - isVPNInterface: classifies an interface name (utun/ipsec/ppp/…). Non-VPN
    ///     interfaces (en0, lo0, …) are skipped entirely.
    /// - Returns: EVERY VPN-like interface — UP or not, with or without addresses — in
    ///   first-appearance order. The caller applies its own liveness filter (e.g.
    ///   `isUp && !addresses.isEmpty`) and adds a human label.
    static func parse(
        _ output: String,
        tailscaleIPs: Set<String>,
        isVPNInterface: (String) -> Bool
    ) -> [ParsedInterface] {
        var byIface: [String: (up: Bool, ips: [String])] = [:]
        var order: [String] = []
        var current: String?

        for line in output.components(separatedBy: "\n") {
            // Interface header lines start at column 0 and carry the flags, e.g.
            // "utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400".
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") {
                let name = line.components(separatedBy: ":").first ?? ""
                current = name
                if isVPNInterface(name) {
                    let up = line.contains("<UP,") || line.contains(",UP,") || line.contains(",UP>")
                    if byIface[name] == nil { byIface[name] = (up, []); order.append(name) }
                    else { byIface[name]?.up = up }
                }
            }
            // Indented "inet A.B.C.D ..." lines carry the IPv4 addresses (skip inet6).
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet "), !trimmed.contains("inet6"),
               let c = current, isVPNInterface(c) {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count >= 2 { byIface[c]?.ips.append(parts[1]) }
            }
        }

        return order.map { iface in
            let info = byIface[iface] ?? (up: false, ips: [])
            let isTS = info.ips.contains { tailscaleIPs.contains($0) }
            return ParsedInterface(interface: iface, addresses: info.ips, isUp: info.up, isTailscale: isTS)
        }
    }
}
