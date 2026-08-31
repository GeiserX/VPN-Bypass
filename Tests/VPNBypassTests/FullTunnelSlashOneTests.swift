// FullTunnelSlashOneTests.swift
// #103: a wg-quick / OpenVPN-def1 style VPN owns 0.0.0.0/1 + 128.0.0.0/1 and leaves `default`
// on the physical link. These pin the pure decisions the fix rests on: the /1 owner is
// selection's ground truth, and the structural-shadow predicate stays byte-identical so a
// user's explicit /2 rule remains allowed under GlobalProtect.

import XCTest
import Darwin
@testable import VPNBypassCore

final class FullTunnelSlashOneTests: XCTestCase {

    private func kr(_ destination: UInt32, prefix: Int?, ifIndex: UInt16? = nil,
                    gateway: UInt32? = nil, flags: Int32 = 0) -> RouteKernel.KernelRoute {
        RouteKernel.KernelRoute(destination: destination, prefix: prefix,
                                gatewayAddress: gateway, gatewayInterfaceIndex: ifIndex,
                                flags: flags)
    }

    // MARK: - Who owns the /1 pair

    /// The wg-quick shape: default still on the physical gateway, the /1 pair bound to the
    /// tunnel by interface. The owner is the tunnel's index.
    func testWireGuardStyleSlashOnePairIsAttributedToItsInterface() {
        let table = [
            kr(0, prefix: 0, gateway: 0xC0A8_0A01),      // default via 192.168.10.1
            kr(0, prefix: 1, ifIndex: 24),               // 0.0.0.0/1 -interface utunX
            kr(0x8000_0000, prefix: 1, ifIndex: 24),     // 128.0.0.0/1 -interface utunX
        ]
        XCTAssertEqual(RouteKernel.slashOneTunnelOwnerIndex(table), 24)
    }

    /// Our own VPN Only catch-alls are RTF_PROTO1-tagged; they must never masquerade as a VPN.
    func testOurOwnRoutesNeverCountAsTheSlashOneOwner() {
        let table = [
            kr(0, prefix: 1, ifIndex: 24, flags: RTF_PROTO1),
            kr(0x8000_0000, prefix: 1, ifIndex: 24, flags: RTF_PROTO1),
        ]
        XCTAssertNil(RouteKernel.slashOneTunnelOwnerIndex(table))
    }

    /// An OpenVPN-style /1 with an AF_INET next hop carries no interface index in the dump —
    /// nil here means selection falls back to the default-route interface, today's behaviour.
    func testAddressGatewayedSlashOneIsNotAttributable() {
        let table = [kr(0, prefix: 1, gateway: 0x0A08_0001)]
        XCTAssertNil(RouteKernel.slashOneTunnelOwnerIndex(table))
    }

    /// A /1 covering only half the space plus unrelated routes is not treated as an owner
    /// signature by accident of some other prefix: only prefix == 1 on the two halves counts.
    func testTableWithoutSlashOnesGivesNoOwner() {
        let table = [
            kr(0, prefix: 0, gateway: 0xC0A8_0A01),
            kr(0x0A00_0000, prefix: 8, ifIndex: 24),
            kr(0x8000_0000, prefix: 2, ifIndex: 24),     // a /2 — ours or anyone's — is not a /1
        ]
        XCTAssertNil(RouteKernel.slashOneTunnelOwnerIndex(table))
    }

    /// One attributable half is enough — OpenVPN and WireGuard both install the pair, but a
    /// mid-transition table can momentarily hold only one of them.
    func testASingleAttributableHalfIsEnough() {
        let table = [kr(0x8000_0000, prefix: 1, ifIndex: 7)]
        XCTAssertEqual(RouteKernel.slashOneTunnelOwnerIndex(table), 7)
    }

    // MARK: - Structural-shadow predicate unchanged (custom-engine GP guard)

    /// /2 is additive, not a shadow: a user's explicit /2 rule stays allowed under GP even
    /// though the /2 quartet now lives in catchAllDestinations for cleanup recognition.
    func testSlashTwoIsNotStructurallyCatchAll() {
        for destination in ClassicRouteCompiler.bypassAllCatchAlls {
            XCTAssertFalse(RouteCompiler.isCatchAll(destination),
                           "\(destination) must stay allowed as an explicit custom rule")
        }
    }

    func testSlashZeroAndSlashOneRemainStructurallyCatchAll() {
        XCTAssertTrue(RouteCompiler.isCatchAll("0.0.0.0/0"))
        XCTAssertTrue(RouteCompiler.isCatchAll("0.0.0.0/1"))
        XCTAssertTrue(RouteCompiler.isCatchAll("128.0.0.0/1"))
        XCTAssertTrue(RouteCompiler.isCatchAll("::/0"))
        XCTAssertFalse(RouteCompiler.isCatchAll("10.0.0.0/8"))
        XCTAssertFalse(RouteCompiler.isCatchAll("1.2.3.4"))
    }

    /// The cleanup-recognition set must carry BOTH generations: the quartet installed now and
    /// the /1 pair a build up to 4.8.0 may have stranded.
    func testRecognitionSetCoversBothGenerations() {
        for destination in ClassicRouteCompiler.bypassAllCatchAlls + ["0.0.0.0/1", "128.0.0.0/1", "0.0.0.0/0"] {
            XCTAssertTrue(RouteCompiler.catchAllDestinations.contains(destination), destination)
        }
    }

    /// The quartet actually covers all of IPv4 — four /2s, disjoint, starting at each quarter.
    func testQuartetCoversTheWholeAddressSpace() {
        XCTAssertEqual(ClassicRouteCompiler.bypassAllCatchAlls,
                       ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"])
    }
}
