// NetworkServiceOrderTests.swift
// Coverage for enumerating the machine's real network services.
//
// Why this matters far more than it looks: gateway detection used to try a HARDCODED list of
// service names — "Wi-Fi", "Ethernet", "USB 10/100/1000 LAN", "Thunderbolt Ethernet", "USB-C LAN".
// A Mac whose active link is named anything else matched nothing, which is the ordinary case for
// docks ("USB3.0 5K Graphic Docking", "Dell Universal Dock D6000"). Detection then fell through to
// `route -n get default` — and once a VPN is connected, the default route's gateway is the VPN's
// OWN tunnel gateway.
//
// The consequences were severe and quiet: every "bypass" route was installed pointing INTO the
// tunnel, so bypassing silently did nothing; and because the gateway moved whenever the VPN changed
// state, the entire route set was torn down and rebuilt on every flap (measured: 362 routes, 286
// deletes in 60 seconds).

import XCTest
@testable import VPNBypassCore

final class NetworkServiceOrderTests: XCTestCase {

    /// Real `networksetup -listnetworkserviceorder` output from a machine with a dock — the exact
    /// configuration whose service names the old hardcoded list could never match.
    private let realOutput = """
    An asterisk (*) denotes that a network service is disabled.
    (1) Dell Universal Dock D6000
    (Hardware Port: Dell Universal Dock D6000, Device: en5)

    (2) USB3.0 5K Graphic Docking
    (Hardware Port: USB3.0 5K Graphic Docking, Device: en8)

    (3) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    """

    func testParsesServicesInOrder() {
        XCTAssertEqual(NetworkServiceOrder.parse(realOutput),
                       ["Dell Universal Dock D6000", "USB3.0 5K Graphic Docking", "Wi-Fi"])
    }

    /// The heading lines name services; the "(Hardware Port: …)" lines must not be mistaken for one.
    func testHardwarePortLinesAreNotTreatedAsServices() {
        XCTAssertFalse(NetworkServiceOrder.parse(realOutput).contains { $0.hasPrefix("Hardware Port") })
    }

    /// macOS marks a disabled service with a leading asterisk; using one would query a service that
    /// cannot supply a gateway.
    func testDisabledServicesAreSkipped() {
        let output = """
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        (*2) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        (3) Ethernet
        (Hardware Port: Ethernet, Device: en1)
        """
        XCTAssertEqual(NetworkServiceOrder.parse(output), ["Wi-Fi", "Ethernet"])
    }

    /// Order is the whole point — macOS lists services in priority order and the first one that
    /// answers with a router is the one actually carrying traffic.
    func testOrderIsPreservedNotSorted() {
        let output = "(1) Zeta\n(2) Alpha\n(3) Mu"
        XCTAssertEqual(NetworkServiceOrder.parse(output), ["Zeta", "Alpha", "Mu"])
    }

    func testEmptyAndGarbageInputYieldNoServices() {
        XCTAssertTrue(NetworkServiceOrder.parse("").isEmpty)
        XCTAssertTrue(NetworkServiceOrder.parse("no parenthesised headings here").isEmpty)
        XCTAssertTrue(NetworkServiceOrder.parse("An asterisk (*) denotes that a network service is disabled.").isEmpty)
    }

    /// A dock-only machine must still produce a usable service — this is precisely the case that
    /// the hardcoded list failed and that sent gateway detection to the VPN's tunnel.
    func testDockOnlyMachineStillYieldsAService() {
        let output = "(1) USB3.0 5K Graphic Docking\n(Hardware Port: USB3.0 5K Graphic Docking, Device: en8)"
        XCTAssertEqual(NetworkServiceOrder.parse(output), ["USB3.0 5K Graphic Docking"])
    }
}
