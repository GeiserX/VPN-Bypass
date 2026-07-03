// IfconfigParserTests.swift
// Coverage for the pure ifconfig-text parser behind RouteManager.listVPNLinks:
// VPN-interface filtering + order, UP-flag detection, IPv4 inet extraction (skipping
// inet6), and Tailscale-IP marking.

import XCTest
@testable import VPNBypassCore

final class IfconfigParserTests: XCTestCase {

    // A realistic `ifconfig` excerpt: loopback + a physical NIC (both non-VPN → skipped),
    // two UP tunnels (one is Tailscale by IP), and a DOWN tunnel with no address.
    private let sample = [
        "lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384",
        "\tinet 127.0.0.1 netmask 0xff000000",
        "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500",
        "\tinet 192.168.1.10 netmask 0xffffff00 broadcast 192.168.1.255",
        "utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400",
        "\tinet6 fe80::abcd prefixlen 64 scopeid 0x12",
        "\tinet 10.9.9.9 --> 10.9.9.9 netmask 0xffffffff",
        "utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280",
        "\tinet 100.127.0.1 --> 100.127.0.1 netmask 0xffffffff",
        "utun7: flags=8010<POINTOPOINT,MULTICAST> mtu 1500",
    ].joined(separator: "\n")

    private let isVPN: (String) -> Bool = { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp") }

    func testParsesVPNInterfacesInOrderSkippingPhysical() {
        let parsed = IfconfigParser.parse(sample, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertEqual(parsed.map(\.interface), ["utun3", "utun5", "utun7"], "VPN ifaces only, in first-appearance order")
    }

    func testUPFlagDetection() {
        let parsed = IfconfigParser.parse(sample, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertTrue(parsed.first { $0.interface == "utun3" }!.isUp)
        XCTAssertTrue(parsed.first { $0.interface == "utun5" }!.isUp)
        XCTAssertFalse(parsed.first { $0.interface == "utun7" }!.isUp, "no UP in its flags → down")
    }

    func testInetExtractionIPv4OnlySkipsInet6() {
        let parsed = IfconfigParser.parse(sample, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertEqual(parsed.first { $0.interface == "utun3" }!.addresses, ["10.9.9.9"], "inet6 line ignored")
        XCTAssertEqual(parsed.first { $0.interface == "utun5" }!.addresses, ["100.127.0.1"])
        XCTAssertEqual(parsed.first { $0.interface == "utun7" }!.addresses, [], "down iface has no inet")
    }

    func testTailscaleIPMarksInterface() {
        let parsed = IfconfigParser.parse(sample, tailscaleIPs: ["100.127.0.1"], isVPNInterface: isVPN)
        XCTAssertTrue(parsed.first { $0.interface == "utun5" }!.isTailscale, "its address is a Tailscale self-IP")
        XCTAssertFalse(parsed.first { $0.interface == "utun3" }!.isTailscale)
        XCTAssertFalse(parsed.first { $0.interface == "utun7" }!.isTailscale)
    }

    func testNoTailscaleIPsMarksNothing() {
        let parsed = IfconfigParser.parse(sample, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertTrue(parsed.allSatisfy { !$0.isTailscale })
    }

    func testEmptyOutputYieldsNoInterfaces() {
        XCTAssertTrue(IfconfigParser.parse("", tailscaleIPs: [], isVPNInterface: isVPN).isEmpty)
    }
}
