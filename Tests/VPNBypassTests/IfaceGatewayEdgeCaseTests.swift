// IfaceGatewayEdgeCaseTests.swift
// Additional edge-case coverage for RouteManager.ifaceGateway, layered on top of the
// already-thorough IfaceGatewayTests.swift + MultiVPNTests.swift (which cover the five
// named scenarios: product-hint-survives-renumbering, refused-different-named-product,
// exact both-match, Tailscale refusal, and productless pin). These add: tie-breaking
// when several links share one product label, a completely empty links array, a fully
// empty selector, an empty-STRING product hint (vs nil), and label case-sensitivity.

import XCTest
@testable import VPNBypassCore

final class IfaceGatewayEdgeCaseTests: XCTestCase {

    private func pin(_ iface: String?, _ product: String?) -> Route {
        Route(name: "r", egress: .vpnDefault,
              vpnSelector: VPNSelector(kind: .interface, interfaceName: iface, productHint: product))
    }

    /// When the pinned interface is gone and TWO live links share the same product
    /// label (e.g. two WireGuard tunnels up at once), the label-only fallback picks
    /// the FIRST match in the links array — a deterministic, if arbitrary, tie-break.
    @MainActor
    func testMultipleLinksWithSameProductLabelPicksFirstMatch() {
        let links = [
            RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.1"], label: "WireGuard", isTailscale: false),
            RouteManager.VPNLink(interface: "utun8", addresses: ["10.0.0.2"], label: "WireGuard", isTailscale: false),
        ]
        XCTAssertEqual(RouteManager.shared.ifaceGateway(for: pin("utunGONE", "WireGuard"), links: links), "iface:utun6")
    }

    /// No live tunnels at all → nil, whether or not the pin carries a product hint.
    @MainActor
    func testEmptyLinksArrayAlwaysReturnsNil() {
        XCTAssertNil(RouteManager.shared.ifaceGateway(for: pin("utun6", "WireGuard"), links: []))
        XCTAssertNil(RouteManager.shared.ifaceGateway(for: pin("utun6", nil), links: []))
    }

    /// A selector with BOTH interfaceName and productHint nil (fully empty) never
    /// matches any link — the productless branch compares each link's non-optional
    /// interface name against nil, which is never equal.
    @MainActor
    func testCompletelyEmptySelectorFieldsReturnsNil() {
        let links = [RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.1"], label: "WireGuard", isTailscale: false)]
        XCTAssertNil(RouteManager.shared.ifaceGateway(for: pin(nil, nil), links: links))
    }

    /// An empty-STRING product hint (as opposed to nil) is treated the SAME as no hint
    /// at all — `!hint.isEmpty` gates the hint-driven branch, so this falls through to
    /// the plain interface-only match rather than failing to match anything.
    @MainActor
    func testEmptyStringProductHintTreatedAsNoHint() {
        let links = [RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.1"], label: "AnyLabel", isTailscale: false)]
        XCTAssertEqual(RouteManager.shared.ifaceGateway(for: pin("utun6", ""), links: links), "iface:utun6")
    }

    /// Product-hint matching is a plain, case-SENSITIVE string comparison: a link
    /// labelled "wireguard" does not satisfy a pin hinting "WireGuard", and it is not a
    /// generic/unknown label either, so the whole resolution refuses (nil).
    @MainActor
    func testProductHintMatchIsCaseSensitive() {
        let links = [RouteManager.VPNLink(interface: "utun6", addresses: ["10.0.0.1"], label: "wireguard", isTailscale: false)]
        XCTAssertNil(RouteManager.shared.ifaceGateway(for: pin("utun6", "WireGuard"), links: links))
    }
}
