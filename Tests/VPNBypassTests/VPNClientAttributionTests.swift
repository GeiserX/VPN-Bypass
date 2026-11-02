// VPNClientAttributionTests.swift
// The VPN client is named from the process that owns the live tunnel, not from whichever VPN app
// happens to be open. Seen live on 6.0.2: AWS VPN Client owned the live utun while GlobalProtect
// sat idle (its app, PanGPS and its system extension running, its utun present but not UP), and
// the app logged "VPN connected via utun11 (GlobalProtect)": the process list was checked in a
// fixed order with GlobalProtect first. The name also switches on GlobalProtect-only routing
// (VPN Only refused, the Custom catch-all guard, the Tailscale peer pause).
//
// The `ps -eo comm` fixture is that machine's list of VPN processes, from the live report.

import XCTest
@testable import VPNBypassCore

final class VPNClientAttributionTests: XCTestCase {

    /// GlobalProtect idle and AWS VPN Client connected, as `ps -eo comm` shows them.
    static let idleGlobalProtectAndAWS = """
    /usr/libexec/nesessionmanager
    /Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect
    /Applications/AWS VPN Client/AWS VPN Client.app/Contents/MacOS/AWS VPN Client
    /Applications/AWS VPN Client/AWS VPN Client.app/Contents/Frameworks/AWS VPN Client Helper.app/Contents/MacOS/AWS VPN Client Helper
    /Applications/AWS VPN Client/AWS VPN Client.app/Contents/Helpers/aws-client-vpn-daemon
    /Applications/GlobalProtect.app/Contents/Resources/PanGPS
    /Library/SystemExtensions/0A1B2C3D/com.paloaltonetworks.GlobalProtect.client.extension.systemextension/Contents/MacOS/com.paloaltonetworks.GlobalProtect.client.extension
    """

    static let awsDaemon = TunnelOwner(
        interface: "utun11", pid: 501, processName: "aws-client-vpn-daemon",
        executablePath: "/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Helpers/aws-client-vpn-daemon")

    /// GlobalProtect's network extension. `proc_name` cuts a name at 32 characters, so only the
    /// path carries "GlobalProtect" whole.
    static let globalProtectExtension = TunnelOwner(
        interface: "utun5", pid: 502, processName: "com.paloaltonetworks.GlobalProte",
        executablePath: "/Library/SystemExtensions/0A1B2C3D/com.paloaltonetworks.GlobalProtect.client.extension.systemextension/Contents/MacOS/com.paloaltonetworks.GlobalProtect.client.extension")

    var running: [VPNType] { VPNClientAttribution.runningClients(psOutput: Self.idleGlobalProtectAndAWS) }

    // MARK: - The live report

    func testBothClientsAreSeenRunning() {
        XCTAssertEqual(running, [.globalProtect, .awsVPNClient])
    }

    /// The live report itself: the tunnel is AWS VPN Client's, whatever else is open.
    func testAnIdleGlobalProtectDoesNotNameAnotherClientsTunnel() {
        let type = VPNClientAttribution.type(interface: "utun11", owner: Self.awsDaemon,
                                             ownersKnown: true, runningClients: running)
        XCTAssertEqual(type, .awsVPNClient)
        XCTAssertEqual(type.knownName, "AWS VPN Client")
    }

    /// When GlobalProtect's tunnel is the live one it stays GlobalProtect, with AWS open too.
    func testGlobalProtectsOwnTunnelStaysGlobalProtect() {
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun5", owner: Self.globalProtectExtension,
                                                 ownersKnown: true, runningClients: running), .globalProtect)
        let panGPS = TunnelOwner(interface: "utun4", pid: 77, processName: "PanGPS",
                                 executablePath: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun4", owner: panGPS,
                                                 ownersKnown: true, runningClients: running), .globalProtect)
    }

    // MARK: - When the owner cannot be told

    /// An owner nobody knows gets the generic label, not the first app in the process list.
    func testAnUnknownOwnerIsGenericNotGuessed() {
        let owner = TunnelOwner(interface: "utun8", pid: 90, processName: "acme-tunneld",
                                executablePath: "/usr/local/sbin/acme-tunneld")
        let type = VPNClientAttribution.type(interface: "utun8", owner: owner,
                                             ownersKnown: true, runningClients: running)
        XCTAssertEqual(type, .unknown)
        XCTAssertNil(type.knownName)
        XCTAssertEqual(VPNType.displayLabel(type.rawValue), "VPN")
    }

    /// A tunnel with no owner the helper can see (an ipsec or ppp interface) and two clients
    /// running: either could be it, so neither is named.
    func testNoOwnerAndTwoClientsRunningIsGeneric() {
        XCTAssertEqual(VPNClientAttribution.type(interface: "ipsec0", owner: nil,
                                                 ownersKnown: true, runningClients: running), .unknown)
    }

    /// One client running and no owner: its name is shown, unless it is GlobalProtect, whose name
    /// changes routing and is taken only from its owner or its own gpd interface.
    func testNoOwnerAndOneClientRunning() {
        XCTAssertEqual(VPNClientAttribution.type(interface: "ppp0", owner: nil,
                                                 ownersKnown: true, runningClients: [.fortinet]), .fortinet)
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun9", owner: nil,
                                                 ownersKnown: true, runningClients: [.globalProtect]), .unknown)
        XCTAssertEqual(VPNClientAttribution.type(interface: "gpd0", owner: nil,
                                                 ownersKnown: true, runningClients: running), .globalProtect)
    }

    /// The NetworkExtension broker alone is no owner: it holds every NE client's tunnel.
    func testTheBrokerAloneIsNoOwner() {
        let broker = TunnelOwner(interface: "utun6", pid: 411, processName: "nesessionmanager",
                                 executablePath: "/usr/libexec/nesessionmanager")
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun6", owner: broker,
                                                 ownersKnown: true, runningClients: running), .unknown)
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun6", owner: broker,
                                                 ownersKnown: true, runningClients: [.wireGuard]), .wireGuard)
    }

    /// A mesh VPN's tunnel (Tailscale as exit node) is no client of the list, even with
    /// GlobalProtect open.
    func testAMeshOwnerIsNotNamedAfterAnOpenClient() {
        let tailscale = TunnelOwner(interface: "utun3", pid: 543, processName: "io.tailscale.ipn.macsys.network",
                                    executablePath: "/Library/SystemExtensions/X/io.tailscale.ipn.macsys.network-extension")
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun3", owner: tailscale,
                                                 ownersKnown: true, runningClients: running), .unknown)
    }

    // MARK: - An older helper

    /// A helper without the owner sweep never answers it: the old rule stands, first running
    /// client, then the gpd prefix.
    func testAnOlderHelperKeepsTheOldRule() {
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun11", owner: nil,
                                                 ownersKnown: false, runningClients: running), .globalProtect)
        XCTAssertEqual(VPNClientAttribution.type(interface: "gpd0", owner: nil,
                                                 ownersKnown: false, runningClients: []), .globalProtect)
        XCTAssertEqual(VPNClientAttribution.type(interface: "utun11", owner: nil,
                                                 ownersKnown: false, runningClients: []), .unknown)
    }

    // MARK: - AWS VPN Client as a known client

    func testAWSVPNClientIsAKnownClient() {
        XCTAssertEqual(TunnelOwnership.displayLabel(for: Self.awsDaemon), "AWS VPN Client")
        XCTAssertEqual(VPNType(rawValue: "AWS VPN Client"), .awsVPNClient)
        XCTAssertFalse(VPNType.awsVPNClient.icon.isEmpty)
        // Its app alone, without the daemon line, is still seen.
        XCTAssertEqual(VPNClientAttribution.runningClients(
            psOutput: "/Applications/AWS VPN Client/AWS VPN Client.app/Contents/MacOS/AWS VPN Client"), [.awsVPNClient])
        // An OpenVPN binary inside its bundle is AWS VPN Client's, not plain OpenVPN.
        XCTAssertEqual(TunnelOwnership.productLabel(
            processName: "acvc-openvpn",
            executablePath: "/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"),
            "AWS VPN Client")
    }
}

/// The GlobalProtect-only behaviours follow the attributed client.
@MainActor
final class GlobalProtectOnlyPathsTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, type: VPNType?)!

    override func setUp() async throws {
        saved = (rm.config, rm.vpnType)
    }

    override func tearDown() async throws {
        rm.config = saved.config
        rm.vpnType = saved.type
    }

    private func attributed(owner: TunnelOwner) -> VPNType {
        VPNClientAttribution.type(interface: owner.interface, owner: owner, ownersKnown: true,
                                  runningClients: VPNClientAttribution.runningClients(
                                    psOutput: VPNClientAttributionTests.idleGlobalProtectAndAWS))
    }

    /// A Tailscale peer inside 100.112.0.0/12 is paused only under GlobalProtect.
    func testTheTailscalePeerPauseFollowsTheTunnelsOwner() {
        var cfg = RouteManager.Config()
        cfg.routes = [Route(name: "peer", egress: .tailscaleExit, proxyHost: "100.120.0.1", proxyPort: 8888)]
        rm.config = cfg

        rm.vpnType = attributed(owner: VPNClientAttributionTests.awsDaemon)
        XCTAssertEqual(rm.listenerRoutesRespectingGPShadow().count, 1, "paused under an idle GlobalProtect")

        rm.vpnType = attributed(owner: TunnelOwner(interface: "utun8", pid: 90, processName: "acme-tunneld",
                                                   executablePath: "/usr/local/sbin/acme-tunneld"))
        XCTAssertEqual(rm.listenerRoutesRespectingGPShadow().count, 1, "paused on a guess")

        rm.vpnType = attributed(owner: VPNClientAttributionTests.globalProtectExtension)
        XCTAssertEqual(rm.listenerRoutesRespectingGPShadow().count, 0, "not paused under GlobalProtect")
    }

    /// The Custom catch-all guard takes `vpnType == .globalProtect`, as RouteManager passes it.
    func testTheCustomCatchAllGuardFollowsTheTunnelsOwner() {
        let catchAll = RouteCompiler.DesiredRoute(destination: "0.0.0.0/1", gateway: "192.0.2.1",
                                                  isNetwork: true, source: "rule")
        let unknown = attributed(owner: TunnelOwner(interface: "utun8", pid: 90, processName: "acme-tunneld",
                                                    executablePath: "/usr/local/sbin/acme-tunneld"))
        XCTAssertTrue(RouteCompiler.guardCatchAllUnderGlobalProtect([catchAll], isGlobalProtect: unknown == .globalProtect).refused.isEmpty)
        let gp = attributed(owner: VPNClientAttributionTests.globalProtectExtension)
        XCTAssertEqual(RouteCompiler.guardCatchAllUnderGlobalProtect([catchAll], isGlobalProtect: gp == .globalProtect).refused.count, 1)
    }
}
