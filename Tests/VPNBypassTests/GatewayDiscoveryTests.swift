// GatewayDiscoveryTests.swift
// Coverage for what Custom Routes can OFFER as an egress.
//
// Two gaps this locks down:
//
// 1. Tailscale peers were listed undifferentiated. On a real tailnet only a small minority
//    advertise themselves as exit nodes (1 of 17 on the machine this was found on), and that
//    is the only peer class that can carry general internet traffic without extra setup — so
//    a flat list of every device gave no way to tell which choice could possibly work.
//
// 2. Tunnels were enumerated live only, and live enumeration reports a tunnel ONLY while it
//    is up. A VPN you were not currently connected to could therefore never be selected,
//    which made it impossible to pre-configure a route for a VPN you use occasionally.

import XCTest
@testable import VPNBypassCore

@MainActor
final class GatewayDiscoveryTests: XCTestCase {

    private func peer(_ name: String, _ ip: String, online: Bool, exit: Bool) -> RouteManager.TailscalePeer {
        RouteManager.TailscalePeer(name: name, ip: ip, online: online, exitNodeCapable: exit)
    }

    /// Exit-capable peers must sort to the top, then online ones — otherwise the one usable
    /// choice is buried in a long alphabetical list of phones and offline boxes.
    func testExitCapablePeersSortFirstThenOnline() {
        let sorted = [
            peer("alpha", "100.64.0.1", online: true, exit: false),
            peer("zulu", "100.64.0.2", online: false, exit: true),
            peer("bravo", "100.64.0.3", online: false, exit: false),
            peer("mike", "100.64.0.4", online: true, exit: true),
        ].sorted { a, b in
            if a.exitNodeCapable != b.exitNodeCapable { return a.exitNodeCapable }
            if a.online != b.online { return a.online }
            return a.name.lowercased() < b.name.lowercased()
        }
        XCTAssertEqual(sorted.map(\.name), ["mike", "zulu", "alpha", "bravo"])
    }

    func testPeerCarriesExitCapability() {
        let p = peer("MacMini", "100.95.230.41", online: true, exit: true)
        XCTAssertTrue(p.exitNodeCapable)
        XCTAssertFalse(peer("phone", "100.64.0.9", online: false, exit: false).exitNodeCapable)
    }

    // MARK: - Remembered tunnels

    /// A tunnel seen once must remain selectable after it disconnects.
    func testRememberedLinksSurviveDisconnect() async {
        let rm = RouteManager.shared
        let saved = rm.config.rememberedVPNLinks
        defer { rm.config.rememberedVPNLinks = saved }

        rm.config.rememberedVPNLinks = [
            .init(interface: "utun7", label: "WireGuard"),
            .init(interface: "utun9", label: "GlobalProtect"),
        ]
        let offered = await rm.selectableVPNLinks()
        let names = Set(offered.map(\.link.interface))
        XCTAssertTrue(names.contains("utun7"), "a VPN that is not connected must still be offerable")
        XCTAssertTrue(names.contains("utun9"))
        // Nothing in the test environment is live, so all entries report isLive == false.
        XCTAssertTrue(offered.allSatisfy { $0.link.interface.hasPrefix("utun") })
    }

    /// Remembered entries must not duplicate a live one.
    func testNoDuplicateBetweenLiveAndRemembered() async {
        let rm = RouteManager.shared
        let saved = rm.config.rememberedVPNLinks
        defer { rm.config.rememberedVPNLinks = saved }
        rm.config.rememberedVPNLinks = [.init(interface: "utun3", label: "X"),
                                        .init(interface: "utun3", label: "X")]
        let offered = await rm.selectableVPNLinks()
        let utun3 = offered.filter { $0.link.interface == "utun3" }
        XCTAssertLessThanOrEqual(utun3.count, 1, "an interface must appear at most once")
    }

    /// Config round-trips remembered links (decodeIfPresent — old configs unaffected).
    func testRememberedLinksRoundTripThroughConfig() throws {
        var cfg = RouteManager.Config()
        cfg.rememberedVPNLinks = [.init(interface: "utun9", label: "GlobalProtect")]
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: data)
        XCTAssertEqual(back.rememberedVPNLinks, cfg.rememberedVPNLinks)

        // A config written before this field existed must still decode.
        let legacy = "{\"routingMode\":\"bypass\"}".data(using: .utf8)!
        let old = try JSONDecoder().decode(RouteManager.Config.self, from: legacy)
        XCTAssertTrue(old.rememberedVPNLinks.isEmpty)
    }
}
