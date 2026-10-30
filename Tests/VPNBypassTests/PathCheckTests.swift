// PathCheckTests.swift
// The path check that replaced Verify Routes' ping (PathCheck).
//
// The problem: Verify pinged each address, so it said whether a site answered, not which way it
// went, and a site that blocks ping failed with its route right. The check now reads the
// interface the kernel picks for the address and the source address of a TCP connection to 443,
// and a control address the app does not route must come back the other way, or the run reads
// "check broken" instead of passing. These tests pin the decisions, then run a real probe over
// loopback, so the socket code is exercised without the network.

import XCTest
@testable import VPNBypassCore

final class PathCheckTests: XCTestCase {

    private func probe(_ address: String = "203.0.113.5", via interface: String?, _ answer: PathCheck.Answer = .connected,
                       ms: Double? = 20) -> PathCheck.Probe {
        PathCheck.Probe(address: address, routeInterface: interface, answer: answer,
                        latencyMs: answer.answered ? ms : nil)
    }

    // MARK: Verdicts

    func testBypassAddressAroundTheVPNThatAnswersIsOK() {
        XCTAssertEqual(PathCheck.verdict(probe(via: "en0"), expected: .physical), .ok)
    }

    func testBypassAddressThatWentIntoTheTunnelIsTheWrongWay() {
        XCTAssertEqual(PathCheck.verdict(probe(via: "utun4"), expected: .physical), .wrongWay)
        XCTAssertEqual(PathCheck.verdict(probe(via: "ipsec0"), expected: .physical), .wrongWay)
    }

    func testVPNOnlyAddressMustBeInThatTunnelNotAnother() {
        XCTAssertEqual(PathCheck.verdict(probe(via: "utun4"), expected: .tunnel("utun4")), .ok)
        XCTAssertEqual(PathCheck.verdict(probe(via: "utun7"), expected: .tunnel("utun4")), .wrongWay)
        XCTAssertEqual(PathCheck.verdict(probe(via: "en0"), expected: .tunnel("utun4")), .wrongWay)
    }

    /// The right way without an answer is not the same failure as the wrong way: it is a site
    /// that does not answer on 443, which the old ping check could not tell from a bad route.
    func testRightWayWithoutAnAnswerIsNoAnswer() {
        XCTAssertEqual(PathCheck.verdict(probe(via: "en0", .noAnswer), expected: .physical), .noAnswer)
        XCTAssertEqual(PathCheck.verdict(probe(via: "en0", .failed), expected: .physical), .noAnswer)
    }

    /// A reset came back that way, so the way works even with the port closed.
    func testARefusedConnectionStillProvesTheWay() {
        XCTAssertEqual(PathCheck.verdict(probe(via: "en0", .refused), expected: .physical), .ok)
    }

    func testNoInterfaceIsUnknown() {
        XCTAssertEqual(PathCheck.verdict(probe(via: nil), expected: .physical), .unknown)
    }

    /// The source address's interface is what the connection used; it wins over the lookup.
    func testTheSourceInterfaceWinsOverTheRouteLookup() {
        let p = PathCheck.Probe(address: "203.0.113.5", routeInterface: "en0", sourceAddress: "10.8.0.2",
                                sourceInterface: "utun4", answer: .connected, latencyMs: 9)
        XCTAssertEqual(p.interface, "utun4")
        XCTAssertEqual(PathCheck.verdict(p, expected: .physical), .wrongWay)
    }

    func testWorstVerdictWins() {
        XCTAssertEqual(PathCheck.worst([.ok, .noAnswer, .ok]), .noAnswer)
        XCTAssertEqual(PathCheck.worst([.ok, .wrongWay, .noAnswer]), .wrongWay)
        XCTAssertEqual(PathCheck.worst([.ok]), .ok)
        XCTAssertNil(PathCheck.worst([]))
    }

    // MARK: The control

    /// In Bypass an address the app does not route goes through the VPN. If it comes back
    /// around the VPN too, the check cannot tell the ways apart and must not pass.
    func testBypassControlMustComeBackThroughTheVPN() throws {
        let ways = try XCTUnwrap(PathCheck.ways(mode: "bypass", vpnInterface: "utun4"))
        XCTAssertEqual(ways.listed, .physical)
        XCTAssertEqual(PathCheck.control(probe("192.0.2.1", via: "utun4", .notTried), unrouted: ways.unlisted), .passed)
        XCTAssertEqual(PathCheck.control(probe("192.0.2.1", via: "en0", .notTried), unrouted: ways.unlisted),
                       .broken(interface: "en0"))
    }

    /// VPN Only is the mirror: the control must leave around the VPN, through the catch-alls.
    func testVPNOnlyControlIsTheMirror() throws {
        let ways = try XCTUnwrap(PathCheck.ways(mode: "vpnOnly", vpnInterface: "utun4"))
        XCTAssertEqual(ways.listed, .tunnel("utun4"))
        XCTAssertEqual(PathCheck.control(probe("192.0.2.1", via: "en0", .notTried), unrouted: ways.unlisted), .passed)
        XCTAssertEqual(PathCheck.control(probe("192.0.2.1", via: "utun4", .notTried), unrouted: ways.unlisted),
                       .broken(interface: "utun4"))
    }

    func testAControlWithNoInterfaceIsBroken() {
        XCTAssertEqual(PathCheck.control(probe(via: nil), unrouted: .tunnel("utun4")), .broken(interface: nil))
    }

    func testNoVPNMeansNoControl() {
        XCTAssertNil(PathCheck.ways(mode: "bypass", vpnInterface: nil))
        XCTAssertNil(PathCheck.ways(mode: "custom", vpnInterface: "utun4"), "Custom: the rules decide")
        XCTAssertEqual(PathCheck.control(probe(via: "en0"), unrouted: nil), .notRun)
    }

    /// The control is an address no route of the app covers, host route or range.
    func testTheControlSkipsRoutedCandidates() {
        XCTAssertEqual(PathCheck.controlAddress(routed: []), "192.0.2.1")
        XCTAssertEqual(PathCheck.controlAddress(routed: ["192.0.2.1"]), "198.51.100.1")
        XCTAssertEqual(PathCheck.controlAddress(routed: ["192.0.2.0/24", "198.51.100.0/22"]), "203.0.113.1")
        XCTAssertNil(PathCheck.controlAddress(routed: ["192.0.0.0/2"]), "one range can cover every candidate")
    }

    // MARK: Ways from a route's gateway

    func testTheWayARouteSends() {
        XCTAssertEqual(PathCheck.way(forGateway: "192.168.1.1", localGateway: "192.168.1.1", vpnInterface: "utun4"), .physical)
        XCTAssertEqual(PathCheck.way(forGateway: "10.0.0.1", localGateway: "192.168.1.1", vpnInterface: "utun4"), .tunnel("utun4"))
        XCTAssertEqual(PathCheck.way(forGateway: "iface:utun6", localGateway: "192.168.1.1", vpnInterface: "utun4"), .tunnel("utun6"))
        XCTAssertNil(PathCheck.way(forGateway: "10.0.0.1", localGateway: "192.168.1.1", vpnInterface: nil))
    }

    // MARK: The card's results

    func testCardResultSaysWhyItFailed() {
        let ok = PathCheck.verificationResult(probe(via: "en0"), expected: .physical, control: .passed)
        XCTAssertTrue(ok.isReachable)
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.latency, 20)
        XCTAssertEqual(ok.path?.interface, "en0")

        let wrong = PathCheck.verificationResult(probe(via: "utun4"), expected: .physical, control: .passed)
        XCTAssertFalse(wrong.isReachable)
        XCTAssertNil(wrong.latency, "a time for the wrong way would read as a pass")
        XCTAssertTrue(wrong.error?.contains("utun4") == true, wrong.error ?? "")

        let silent = PathCheck.verificationResult(probe(via: "en0", .noAnswer), expected: .physical, control: .passed)
        XCTAssertFalse(silent.isReachable)
        XCTAssertTrue(silent.error?.contains("443") == true, silent.error ?? "")
    }

    /// A broken control fails every result, even one that looked right: the check proved nothing.
    func testBrokenControlFailsEveryResult() {
        let result = PathCheck.verificationResult(probe(via: "en0"), expected: .physical,
                                                  control: .broken(interface: "en0"))
        XCTAssertFalse(result.isReachable)
        XCTAssertTrue(result.error?.hasPrefix("Check broken") == true, result.error ?? "")
    }

    /// With no VPN there is one way out, so only the answer counts.
    func testWithoutAWayOnlyTheAnswerCounts() {
        XCTAssertTrue(PathCheck.verificationResult(probe(via: "en0"), expected: nil, control: .notRun).isReachable)
        XCTAssertFalse(PathCheck.verificationResult(probe(via: "en0", .noAnswer), expected: nil, control: .notRun).isReachable)
    }

    // MARK: A real probe, over loopback

    /// A listener on 127.0.0.1: the probe connects, reads its source address, and names lo0.
    func testProbeConnectsAndReadsItsSourceAddress() throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        let p = PathCheck.probe("127.0.0.1", port: port)
        XCTAssertEqual(p.answer, .connected)
        XCTAssertEqual(p.sourceAddress, "127.0.0.1")
        XCTAssertEqual(p.sourceInterface, "lo0")
        XCTAssertEqual(p.routeInterface, "lo0")
        XCTAssertNotNil(p.latencyMs)
        XCTAssertEqual(PathCheck.verdict(p, expected: .physical), .ok)
        XCTAssertEqual(PathCheck.verdict(p, expected: .tunnel("utun4")), .wrongWay)
    }

    /// A closed port answers with a reset: refused, still on lo0.
    func testProbeOfAClosedPortIsRefused() throws {
        let (fd, port) = try listen()
        close(fd)
        let p = PathCheck.probe("127.0.0.1", port: port)
        XCTAssertEqual(p.answer, .refused)
        XCTAssertEqual(p.interface, "lo0")
    }

    func testProbeOfANonAddressFails() {
        let p = PathCheck.probe("not-an-address")
        XCTAssertEqual(p.answer, .failed)
        XCTAssertNil(p.sourceAddress)
    }

    /// A listening TCP socket on 127.0.0.1 and its port.
    private func listen() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) }
        }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }
}
