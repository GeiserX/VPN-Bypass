// VPNClientAttribution.swift
// Which VPN client the tunnel the app acts on belongs to.
//
// A VPN client's app and daemons keep running while it is disconnected: GlobalProtect idle
// leaves GlobalProtect, PanGPS and its system extension up, with its utun present but not UP.
// So "which VPN processes are running" says what is installed, not which one owns the tunnel,
// and taking the first match named an idle GlobalProtect for another client's live tunnel. That
// name is not cosmetic: VPN Only's cache refusal, the Custom catch-all guard and the Tailscale
// peer pause all run only under GlobalProtect.
//
// The owner of the tunnel comes from the helper's sweep (`TunnelOwnership`), which names the
// process holding the utun's control socket. The process list is kept only as a fallback.

import Foundation

enum VPNClientAttribution {

    /// Known VPN clients with a process running, in the order the app has always checked them.
    /// `psOutput` is the output of `ps -eo comm` (full executable paths).
    static func runningClients(psOutput: String) -> [VPNType] {
        let output = psOutput.lowercased()
        var found: [VPNType] = []
        if output.contains("globalprotect") || output.contains("pangpa") || output.contains("pangps") {
            found.append(.globalProtect)
        }
        if output.contains("vpnagent") || output.contains("cisco") || output.contains("anyconnect") || output.contains("secureclient") {
            found.append(.ciscoAnyConnect)
        }
        // Before OpenVPN and WireGuard: Proton's tunnel extension carries the protocol's name.
        // Only the extension, which runs while a tunnel is up; the Proton app stays open when
        // disconnected and must not rename another VPN.
        if output.split(separator: "\n").contains(where: { $0.contains("protonvpn") && $0.contains("extension") }) {
            found.append(.protonVPN)
        }
        // Before OpenVPN: the AWS client is OpenVPN-based and may carry its name in a path.
        if output.contains("aws-client-vpn") || output.contains("aws vpn client") {
            found.append(.awsVPNClient)
        }
        if output.contains("openvpn") {
            found.append(.openVPN)
        }
        if output.contains("wireguard") || output.contains("wg-go") {
            found.append(.wireGuard)
        }
        if output.contains("forticlient") || output.contains("fortitray") || output.contains("fctservctl") {
            found.append(.fortinet)
        }
        if output.contains("zscaler") || output.contains("zstunnel") || output.contains("zsatunnel") ||
           output.contains("trptunnel") || output.contains("upmservicecontroller") {
            found.append(.zscaler)
        }
        if output.contains("cloudflare") || output.contains("warp-cli") || output.contains("warp-svc") {
            found.append(.cloudflareWARP)
        }
        if output.contains("pulsesecure") || output.contains("dsaccessservice") || output.contains("pulseuisvc") {
            found.append(.pulseSecure)
        }
        if output.contains("endpoint_security_vpn") || output.contains("tracsrvwrapper") ||
           output.contains("cpdaapp") || output.contains("cpefrd") {
            found.append(.checkPoint)
        }
        // Tailscale is handled separately via exit node detection
        return found
    }

    /// The client of the tunnel on `interface`.
    ///
    /// - `owner`: the process holding the tunnel, from the helper's sweep, if it has one.
    /// - `ownersKnown`: the helper answered the sweep. When it did not (no helper yet, or one
    ///   too old to know the call), the first running client is used, as before the sweep.
    /// - `runningClients`: `runningClients(psOutput:)`.
    ///
    /// With the sweep, the owner names the client. A tunnel with no owner (an `ipsec` or `ppp`
    /// interface has no utun socket) takes the one running client when exactly one is running,
    /// never GlobalProtect: GlobalProtect changes routing, so it is named only from its owner or
    /// its own `gpd` interface. Anything else is `.unknown`, shown as "VPN".
    static func type(interface: String, owner: TunnelOwner?, ownersKnown: Bool,
                     runningClients: [VPNType]) -> VPNType {
        let namedByInterface: VPNType = interface.hasPrefix("gpd") ? .globalProtect : .unknown
        guard ownersKnown else { return runningClients.first ?? namedByInterface }

        if let owner, !TunnelOwnership.brokerProcessNames.contains(owner.processName) {
            guard let label = TunnelOwnership.productLabel(processName: owner.processName,
                                                           executablePath: owner.executablePath) else {
                return .unknown
            }
            // Mesh VPNs (Tailscale, NetBird...) have a label but no case: their tunnel is not a
            // client the app adapts to, and the link list shows the owner's label anyway.
            return VPNType(rawValue: label) ?? .unknown
        }
        if namedByInterface != .unknown { return namedByInterface }
        var distinct: [VPNType] = []
        for client in runningClients where !distinct.contains(client) { distinct.append(client) }
        if distinct.count == 1, let only = distinct.first, only != .globalProtect { return only }
        return .unknown
    }
}
