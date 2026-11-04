import XCTest
@testable import VPNBypassPolicy

/// A claimed connect-by-name flow's lookup on the physical interface (design 3.5 step 4): a name
/// that answers with a protected address is never dialled past the VPN.
final class NameAnswerTests: XCTestCase {
    func ip(_ s: String) -> UInt32 { ProtectedRanges.parse(s)! }

    func testAPublicAnswerIsDialled() {
        XCTAssertEqual(NameAnswer.check([ip("93.184.216.34"), ip("93.184.216.35")], tunnelNetworks: []),
                       .dial(ip("93.184.216.34")))
    }

    func testAnyProtectedAnswerRefusesTheName() {
        for bad in ["10.1.2.3", "172.16.0.9", "192.168.1.1", "100.64.0.1", "100.100.100.100", "127.0.0.1",
                    "169.254.10.10", "224.0.0.251", "0.0.0.0", "255.255.255.255"] {
            XCTAssertEqual(NameAnswer.check([ip(bad)], tunnelNetworks: []), .protected, bad)
            // Even behind a public answer: the name points into a network the VPN or the link owns.
            XCTAssertEqual(NameAnswer.check([ip("93.184.216.34"), ip(bad)], tunnelNetworks: []), .protected, bad)
        }
    }

    func testNoAnswerIsNotDialled() {
        XCTAssertEqual(NameAnswer.check([], tunnelNetworks: []), .noAnswer)
    }

    func testAnAnswerInsideATunnelsOwnNetworkIsProtected() {
        // A VPN that numbers its tunnel from public space: its own network stays the VPN's.
        let addrs = [
            InterfaceAddress(name: "en0", address: ip("192.168.1.20"), netmask: ip("255.255.255.0")),
            InterfaceAddress(name: "utun4", address: ip("198.51.100.7"), netmask: ip("255.255.255.0")),
            InterfaceAddress(name: "ppp0", address: ip("203.0.113.9"), netmask: ~0, destination: ip("203.0.113.1")),
        ]
        let nets = NameAnswer.tunnelNetworks(addrs)
        XCTAssertEqual(nets, [IPv4Network(address: ip("198.51.100.0"), netmask: ip("255.255.255.0")),
                              IPv4Network(address: ip("203.0.113.9"), netmask: ~0),
                              IPv4Network(address: ip("203.0.113.1"), netmask: ~0)])
        XCTAssertEqual(NameAnswer.check([ip("198.51.100.200")], tunnelNetworks: nets), .protected)
        XCTAssertEqual(NameAnswer.check([ip("203.0.113.1")], tunnelNetworks: nets), .protected)
        XCTAssertEqual(NameAnswer.check([ip("198.51.101.1")], tunnelNetworks: nets), .dial(ip("198.51.101.1")))
        XCTAssertEqual(NameAnswer.check([ip("203.0.113.2")], tunnelNetworks: nets), .dial(ip("203.0.113.2")))
    }

    func testPhysicalInterfacesAddNoNetwork() {
        let addrs = [InterfaceAddress(name: "en0", address: ip("198.51.100.7"), netmask: ip("255.255.255.0")),
                     InterfaceAddress(name: "lo0", address: ip("127.0.0.1"), netmask: ip("255.0.0.0"))]
        XCTAssertEqual(NameAnswer.tunnelNetworks(addrs), [])
    }

    func testTheCounterHasItsOwnKey() {
        var ledger = FlowLedger()
        ledger.add(.nameProtected)
        XCTAssertEqual(ledger.count(.nameProtected), 1)
        XCTAssertEqual(ledger.counters, ["nameProtected": 1])
        XCTAssertEqual(ledger.count(.egressFailed), 0, "not counted as a failed connect")
    }
}
