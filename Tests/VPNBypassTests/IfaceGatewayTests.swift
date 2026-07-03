// IfaceGatewayTests.swift
// Regression coverage for RouteManager.ifaceGateway's tunnel-matching robustness (M6).
// macOS renumbers utun indices across VPN reconnects/reboots, so the resolver must
// prefer the durable product label over the volatile interface index — otherwise a
// pin can silently hijack whatever DIFFERENT tunnel now occupies the old utun name.
// ifaceGateway is pure w.r.t. its `links` argument, so every case here is a fixture.

import XCTest
@testable import VPNBypassCore

final class IfaceGatewayTests: XCTestCase {

    private func pin(_ iface: String?, _ product: String?) -> Route {
        Route(name: "r", egress: .vpnDefault,
              vpnSelector: VPNSelector(kind: .interface, interfaceName: iface, productHint: product))
    }

    // (a) The product moved to a new utun and a DIFFERENT product took the old index:
    // the durable label wins, so the pin follows the product — not the stale index.
    @MainActor
    func testProductMatchWinsWhenIndexRenumbered() {
        let links = [
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.2"], label: "Zscaler", isTailscale: false),
            RouteManager.VPNLink(interface: "utun8", addresses: ["10.9.9.9"], label: "WireGuard", isTailscale: false),
        ]
        // Pinned as utun6/WireGuard, but WireGuard is now utun8 and utun6 is Zscaler.
        XCTAssertEqual(RouteManager.shared.ifaceGateway(for: pin("utun6", "WireGuard"), links: links), "iface:utun8")
    }

    // (b) The pinned index now hosts a different NAMED product and the pinned product
    // is not up anywhere → refuse (nil). Must NOT hijack the unrelated tunnel.
    @MainActor
    func testDifferentNamedProductAtIndexIsRefusedNotHijacked() {
        let links = [
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.2"], label: "Zscaler", isTailscale: false),
        ]
        XCTAssertNil(RouteManager.shared.ifaceGateway(for: pin("utun6", "WireGuard"), links: links))
    }

    // (c) Interface AND product both still match (nothing moved) — the strongest signal.
    @MainActor
    func testExactInterfaceAndProductMatch() {
        let links = [
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.9.9.9"], label: "WireGuard", isTailscale: false),
        ]
        XCTAssertEqual(RouteManager.shared.ifaceGateway(for: pin("utun6", "WireGuard"), links: links), "iface:utun6")
    }

    // (d) A pin that resolves to the Tailscale utun is refused (Tailscale has its own
    // peer-proxy egress and must never be targeted as a plain VPN).
    @MainActor
    func testTailscaleInterfaceIsRefused() {
        let links = [
            RouteManager.VPNLink(interface: "utun10", addresses: ["100.127.0.1"], label: "Tailscale", isTailscale: true),
        ]
        XCTAssertNil(RouteManager.shared.ifaceGateway(for: pin("utun10", nil), links: links))
    }

    // (e) A productless pin (no durable hint) still resolves by interface index — the
    // only signal available for such a legacy pin.
    @MainActor
    func testProductlessPinMatchesByInterface() {
        let links = [
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.9.9.9"], label: "WireGuard", isTailscale: false),
        ]
        XCTAssertEqual(RouteManager.shared.ifaceGateway(for: pin("utun6", nil), links: links), "iface:utun6")
    }

    // Carve-out: when the pinned product isn't up but the pinned index currently hosts
    // an UNRECOGNIZED/unknown tunnel (generic label — not a different named product),
    // the index-only match is accepted as a last resort.
    @MainActor
    func testIndexOnlyMatchAcceptedForGenericLabel() {
        let genericFallback = [
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.2"], label: "VPN (utun6)", isTailscale: false),
        ]
        XCTAssertEqual(RouteManager.shared.ifaceGateway(for: pin("utun6", "WireGuard"), links: genericFallback), "iface:utun6")

        let unknownType = [
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.2"], label: RouteManager.VPNType.unknown.rawValue, isTailscale: false),
        ]
        XCTAssertEqual(RouteManager.shared.ifaceGateway(for: pin("utun6", "WireGuard"), links: unknownType), "iface:utun6")
    }
}
