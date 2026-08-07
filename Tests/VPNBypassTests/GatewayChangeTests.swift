// GatewayChangeTests.swift
// Regression coverage: a change of NOTATION must never be mistaken for a change of gateway.
//
// `detectVPNGateway` reports the next-hop IP when it can read one and falls back to `iface:<name>`
// when it cannot, so an unchanged tunnel alternates between the two forms from pass to pass.
// Treating that as a real change fires a re-route that re-issues the ENTIRE route set. Observed
// live: `VPN gateway changed on utun9: 10.167.222.191 → iface:utun9` followed immediately by
// `Adding 317 routes` — roughly ten seconds after GlobalProtect reconnected. Those hundreds of
// route-change events went straight into the tunnel monitor that had just come up, and tore it
// down again.

import XCTest
@testable import VPNBypassCore

final class GatewayChangeTests: XCTestCase {

    /// The exact regression, in both directions.
    func testNotationFlipIsNotAGatewayChange() {
        XCTAssertFalse(RouteManager.isRealGatewayChange(from: "10.167.222.191", to: "iface:utun9"),
                       "IP → iface form is the same gateway written differently, not a change")
        XCTAssertFalse(RouteManager.isRealGatewayChange(from: "iface:utun9", to: "10.167.222.191"),
                       "iface → IP form is the same gateway written differently, not a change")
    }

    /// A genuine next-hop change must still be acted on — the detector exists because a tunnel that
    /// renegotiates onto a new gateway would otherwise leave routes pinned to a dead next-hop.
    func testRealAddressChangeIsStillDetected() {
        XCTAssertTrue(RouteManager.isRealGatewayChange(from: "10.167.222.191", to: "10.167.222.250"))
    }

    func testUnchangedAddressIsNotAChange() {
        XCTAssertFalse(RouteManager.isRealGatewayChange(from: "10.167.222.191", to: "10.167.222.191"))
    }

    func testInterfaceFormToDifferentInterfaceFormIsNotActedOn() {
        // The caller already requires the interface to be unchanged, so this cannot represent a
        // real change; and neither side is an address we could compare meaningfully.
        XCTAssertFalse(RouteManager.isRealGatewayChange(from: "iface:utun9", to: "iface:utun4"))
    }

    func testMissingEitherSideIsNotAChange() {
        XCTAssertFalse(RouteManager.isRealGatewayChange(from: nil, to: "10.0.0.1"))
        XCTAssertFalse(RouteManager.isRealGatewayChange(from: "10.0.0.1", to: nil))
        XCTAssertFalse(RouteManager.isRealGatewayChange(from: nil, to: nil))
    }
}
