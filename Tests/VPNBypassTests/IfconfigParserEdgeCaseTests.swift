// IfconfigParserEdgeCaseTests.swift
// Additional edge-case coverage for IfconfigParser.parse(), layered on top of
// IfconfigParserTests.swift: the other two UP-flag substring positions, an
// inet6-only interface, multiple inet addresses on one interface, a non-VPN header's
// inet line not leaking into a preceding VPN interface's address list, Tailscale
// marking with multiple addresses where only one matches, and a repeated interface
// header updating the UP flag without duplicating the order list.

import XCTest
@testable import VPNBypassCore

final class IfconfigParserEdgeCaseTests: XCTestCase {

    private let isVPN: (String) -> Bool = { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp") }

    // MARK: - UP flag substring position variants

    func testUPFlagDetectedInMiddlePosition() {
        let output = "utun3: flags=8051<POINTOPOINT,UP,RUNNING,MULTICAST> mtu 1400"
        let parsed = IfconfigParser.parse(output, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertTrue(parsed.first { $0.interface == "utun3" }!.isUp, "\",UP,\" in the middle of the flag list must be detected")
    }

    func testUPFlagDetectedAtEndPosition() {
        let output = "utun3: flags=8051<POINTOPOINT,RUNNING,UP> mtu 1400"
        let parsed = IfconfigParser.parse(output, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertTrue(parsed.first { $0.interface == "utun3" }!.isUp, "\",UP>\" as the last flag must be detected")
    }

    // MARK: - inet6-only interface

    func testInterfaceWithOnlyInet6HasEmptyAddresses() {
        let output = [
            "utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400",
            "\tinet6 fe80::abcd prefixlen 64 scopeid 0x4",
        ].joined(separator: "\n")
        let parsed = IfconfigParser.parse(output, tailscaleIPs: [], isVPNInterface: isVPN)
        let iface = parsed.first { $0.interface == "utun3" }!
        XCTAssertTrue(iface.isUp)
        XCTAssertEqual(iface.addresses, [], "an interface with only inet6 has no IPv4 addresses, not a crash")
    }

    // MARK: - multiple inet addresses on one interface

    func testMultipleInetAddressesOnSameInterfacePreservedInOrder() {
        let output = [
            "utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400",
            "\tinet 10.1.1.1 --> 10.1.1.1 netmask 0xffffffff",
            "\tinet 10.1.1.2 --> 10.1.1.2 netmask 0xffffffff",
        ].joined(separator: "\n")
        let parsed = IfconfigParser.parse(output, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertEqual(parsed.first { $0.interface == "utun3" }!.addresses, ["10.1.1.1", "10.1.1.2"])
    }

    // MARK: - non-VPN header's inet line does not leak into a prior VPN interface

    func testInetLineAfterNonVPNHeaderDoesNotLeakIntoPriorVPNInterface() {
        let output = [
            "utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400",   // VPN, no inet line of its own yet
            "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500",
            "\tinet 192.168.1.5 netmask 0xffffff00 broadcast 192.168.1.255",   // en0's own address
        ].joined(separator: "\n")
        let parsed = IfconfigParser.parse(output, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertEqual(parsed.map(\.interface), ["utun3"], "en0 is not VPN-like and must not appear at all")
        XCTAssertEqual(parsed.first!.addresses, [], "en0's address must not be misattributed to the preceding utun3")
    }

    // MARK: - Tailscale marking with multiple addresses

    func testTailscaleMarkedTrueWhenOnlyOneOfMultipleAddressesMatches() {
        let output = [
            "utun5: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280",
            "\tinet 100.64.0.1 --> 100.64.0.1 netmask 0xffffffff",     // not a Tailscale IP
            "\tinet 100.127.0.1 --> 100.127.0.1 netmask 0xffffffff",   // IS a Tailscale IP
        ].joined(separator: "\n")
        let parsed = IfconfigParser.parse(output, tailscaleIPs: ["100.127.0.1"], isVPNInterface: isVPN)
        let iface = parsed.first { $0.interface == "utun5" }!
        XCTAssertEqual(iface.addresses, ["100.64.0.1", "100.127.0.1"])
        XCTAssertTrue(iface.isTailscale, "at least one matching address is enough to mark the whole interface")
    }

    // MARK: - repeated interface header

    /// A repeated header for the SAME interface name (e.g. a re-emitted stanza) must
    /// update the UP flag to the LAST occurrence seen, without duplicating its entry
    /// in the first-appearance order list.
    func testDuplicateInterfaceHeaderUpdatesUpFlagWithoutDuplicatingOrder() {
        let output = [
            "utun3: flags=8010<POINTOPOINT,MULTICAST> mtu 1400",                      // first: DOWN
            "utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1400",           // second: UP
        ].joined(separator: "\n")
        let parsed = IfconfigParser.parse(output, tailscaleIPs: [], isVPNInterface: isVPN)
        XCTAssertEqual(parsed.map(\.interface), ["utun3"], "the interface appears exactly once in the order list")
        XCTAssertTrue(parsed.first!.isUp, "the flag reflects the LAST header occurrence (UP)")
    }
}
