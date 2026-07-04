// MultiVPNTests.swift
// Multi-VPN "4th way" (Slice 4): the VPNSelector model + RouteManager.ifaceGateway,
// which resolves a route pinned to a specific tunnel → an `iface:utunX` kernel-route
// token (or nil = fall back to the default). Forward-compat: an old config with no
// vpnSelector decodes to nil → the primary VPN (today's behaviour).

import XCTest
@testable import VPNBypassCore

final class MultiVPNTests: XCTestCase {

    func testVPNSelectorCodableRoundTripAndDefaults() throws {
        let s = VPNSelector(kind: .interface, interfaceName: "utun6", productHint: "WireGuard")
        let back = try JSONDecoder().decode(VPNSelector.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)

        // A partial payload missing `kind` degrades to .primary (forward-compat).
        let partial = try JSONDecoder().decode(VPNSelector.self, from: Data(#"{"interfaceName":"utun6"}"#.utf8))
        XCTAssertEqual(partial.kind, .primary)
        XCTAssertEqual(partial.interfaceName, "utun6")
    }

    func testRouteWithoutVPNSelectorDecodesToNil() throws {
        // An old config's route (no vpnSelector key) → nil → primary VPN behaviour.
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"vpn","egress":"vpnDefault","enabled":true}"#
        let r = try JSONDecoder().decode(Route.self, from: Data(json.utf8))
        XCTAssertNil(r.vpnSelector)
        XCTAssertEqual(r.egress, .vpnDefault)
    }

    @MainActor
    func testIfaceGatewayResolution() {
        let links = [
            RouteManager.VPNLink(interface: "utun5", addresses: ["10.1.2.3"], label: "GlobalProtect", isTailscale: false),
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.9.9.9"], label: "WireGuard", isTailscale: false),
            RouteManager.VPNLink(interface: "utun10", addresses: ["100.127.0.1"], label: "Tailscale", isTailscale: true),
        ]
        let rm = RouteManager.shared

        // No selector / primary → nil (stays on the OS default, unchanged behaviour).
        XCTAssertNil(rm.ifaceGateway(for: Route(name: "p", egress: .vpnDefault), links: links))
        XCTAssertNil(rm.ifaceGateway(for: Route(name: "p", egress: .vpnDefault,
                                                vpnSelector: VPNSelector(kind: .primary)), links: links))

        // Exact interface match → its iface token.
        XCTAssertEqual(rm.ifaceGateway(for: Route(name: "wg", egress: .vpnDefault,
                                                  vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun6")),
                                       links: links), "iface:utun6")

        // Interface renumbered → productHint fallback still finds it.
        XCTAssertEqual(rm.ifaceGateway(for: Route(name: "wg", egress: .vpnDefault,
                                                  vpnSelector: VPNSelector(kind: .interface, interfaceName: "utunGONE", productHint: "WireGuard")),
                                       links: links), "iface:utun6")

        // Pinned tunnel gone → nil (route falls back to the default, no dead-utun push).
        XCTAssertNil(rm.ifaceGateway(for: Route(name: "x", egress: .vpnDefault,
                                                vpnSelector: VPNSelector(kind: .interface, interfaceName: "utunGONE", productHint: "Nope")),
                                     links: links))

        // The Tailscale interface is refused as a VPN egress.
        XCTAssertNil(rm.ifaceGateway(for: Route(name: "ts", egress: .vpnDefault,
                                                vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun10")),
                                     links: links))

        // A non-vpnDefault route ignores the selector entirely.
        XCTAssertNil(rm.ifaceGateway(for: Route(name: "d", egress: .direct,
                                                vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun6")),
                                     links: links))
    }
}
