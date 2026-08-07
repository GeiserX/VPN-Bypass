// VPNInterfaceSelectorTests.swift
// Coverage for choosing which tunnel is "the VPN" when several are up at once.
//
// Two tunnels at once is the ordinary case on this kind of machine — a corporate client alongside
// Tailscale, on a Mac showing nine utun interfaces. Selection used to be "first match in ifconfig
// order", which is neither deterministic nor related to which tunnel carries traffic. Because
// Tailscale's utun typically sorts BEFORE a corporate client's, Tailscale won that race whenever an
// exit node made its address look like a VPN — and in VPN Only mode the catch-alls are then
// installed to escape the tunnel the app picked, sending the OTHER tunnel's corporate traffic
// straight out. That is a leak, not a cosmetic misselection.

import XCTest
@testable import VPNBypassCore

final class VPNInterfaceSelectorTests: XCTestCase {

    private func c(_ iface: String, up: Bool = true, corp: Bool = true, ts: Bool = false) -> VPNCandidate {
        VPNCandidate(interface: iface, isUp: up, isTunnel: true, isCorporateAddress: corp, isTailscale: ts)
    }

    // MARK: - Tailscale must never be selected

    /// The leak case, exactly as it occurs live: Tailscale on a LOWER-numbered utun than the
    /// corporate client, so ifconfig order would have handed it the selection.
    func testCorporateTunnelWinsOverLowerNumberedTailscale() {
        let picked = VPNInterfaceSelector.select(
            candidates: [c("utun4", ts: true), c("utun9")],
            defaultRouteInterface: nil, current: nil)
        XCTAssertEqual(picked, "utun9")
    }

    /// Tailscale alone — mesh or exit node — is not "the VPN". Selecting it would make the app
    /// reroute mesh traffic, which is not what any of its modes are for.
    func testTailscaleAloneIsNotAVPN() {
        XCTAssertNil(VPNInterfaceSelector.select(
            candidates: [c("utun4", ts: true)], defaultRouteInterface: nil, current: nil))
    }

    /// Even holding the default route, Tailscale must not be selected — an exit node legitimately
    /// carries the default route, and that still does not make it the tunnel to reroute.
    func testTailscaleIsNotSelectedEvenWhenItHoldsTheDefaultRoute() {
        XCTAssertNil(VPNInterfaceSelector.select(
            candidates: [c("utun4", ts: true)], defaultRouteInterface: "utun4", current: nil))
    }

    // MARK: - Ground truth

    func testTunnelCarryingTheDefaultRouteIsPreferred() {
        let picked = VPNInterfaceSelector.select(
            candidates: [c("utun3"), c("utun9")],
            defaultRouteInterface: "utun9", current: nil)
        XCTAssertEqual(picked, "utun9", "the tunnel actually moving traffic outranks any heuristic")
    }

    /// A default route that moved to a different tunnel is a real change and must override the
    /// previous choice — otherwise routes stay pinned to a tunnel no longer carrying traffic.
    func testDefaultRouteOutranksTheExistingSelection() {
        let picked = VPNInterfaceSelector.select(
            candidates: [c("utun3"), c("utun9")],
            defaultRouteInterface: "utun9", current: "utun3")
        XCTAssertEqual(picked, "utun9")
    }

    /// A default route over ordinary Ethernet (split tunnel — the normal GlobalProtect case) names
    /// no candidate, so selection falls through rather than dropping the VPN.
    func testDefaultRouteOnPhysicalInterfaceDoesNotDeselectTheVPN() {
        let picked = VPNInterfaceSelector.select(
            candidates: [c("utun9")], defaultRouteInterface: "en8", current: nil)
        XCTAssertEqual(picked, "utun9")
    }

    // MARK: - Hysteresis

    /// The churn guard. With several candidates equally valid and no default route to separate
    /// them, the choice must not oscillate: every flip reads as an interface change and re-issues
    /// the entire route set, which is the feedback loop that destabilises the tunnel (#65).
    func testSelectionIsStickyWhenSeveralCandidatesRemainValid() {
        let cands = [c("utun3"), c("utun9")]
        XCTAssertEqual(VPNInterfaceSelector.select(candidates: cands, defaultRouteInterface: nil, current: "utun9"), "utun9")
        XCTAssertEqual(VPNInterfaceSelector.select(candidates: cands, defaultRouteInterface: nil, current: "utun3"), "utun3")
    }

    /// Stickiness must not outlive the interface: once the held tunnel drops, selection moves on.
    func testStickinessEndsWhenTheHeldInterfaceGoesAway() {
        let picked = VPNInterfaceSelector.select(
            candidates: [c("utun3")], defaultRouteInterface: nil, current: "utun9")
        XCTAssertEqual(picked, "utun3")
    }

    /// Repeated evaluation with unchanged inputs must return the same answer — an unstable
    /// selection is itself a source of route churn.
    func testRepeatedEvaluationIsStable() {
        let cands = [c("utun9"), c("utun4", ts: true), c("utun3")]
        var current: String? = nil
        var seen: Set<String> = []
        for _ in 0..<10 {
            current = VPNInterfaceSelector.select(candidates: cands, defaultRouteInterface: nil, current: current)
            seen.insert(current ?? "nil")
        }
        XCTAssertEqual(seen.count, 1, "selection must converge, not oscillate: \(seen)")
    }

    // MARK: - Eligibility

    func testDownAndNonCorporateInterfacesAreIgnored() {
        XCTAssertNil(VPNInterfaceSelector.select(
            candidates: [c("utun3", up: false), c("utun5", corp: false)],
            defaultRouteInterface: nil, current: nil))
    }

    func testNoCandidatesYieldsNoSelection() {
        XCTAssertNil(VPNInterfaceSelector.select(candidates: [], defaultRouteInterface: nil, current: nil))
    }

    // MARK: - Deterministic ordering

    /// Numeric, not lexical: plain string comparison puts "utun10" before "utun9".
    func testTieBreakOrdersNumericallyNotLexically() {
        let picked = VPNInterfaceSelector.select(
            candidates: [c("utun10"), c("utun9")], defaultRouteInterface: nil, current: nil)
        XCTAssertEqual(picked, "utun9")
    }

    /// Order of the input array must not change the answer — otherwise ifconfig ordering leaks
    /// back in as a hidden input.
    func testSelectionIsIndependentOfCandidateOrder() {
        let a = VPNInterfaceSelector.select(candidates: [c("utun3"), c("utun9")], defaultRouteInterface: nil, current: nil)
        let b = VPNInterfaceSelector.select(candidates: [c("utun9"), c("utun3")], defaultRouteInterface: nil, current: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "utun3")
    }

    /// Non-utun tunnel names (ipsec, ppp) must order sanely rather than crash or compare oddly.
    func testMixedInterfaceFamiliesOrderDeterministically() {
        let picked = VPNInterfaceSelector.select(
            candidates: [c("utun9"), c("ipsec0")], defaultRouteInterface: nil, current: nil)
        XCTAssertEqual(picked, "ipsec0")
    }

    // MARK: - Default route parsing

    func testParsesDefaultRouteInterface() {
        let out = """
           route to: default
        destination: default
               mask: default
            gateway: 10.167.222.191
          interface: utun9
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        XCTAssertEqual(VPNInterfaceSelector.parseDefaultRouteInterface(out), "utun9")
    }

    func testParsesInterfaceWhenNoGatewayLineIsPresent() {
        // Cisco-style link routes report an interface and no gateway at all (#26).
        let out = "   route to: default\n  interface: utun4\n      flags: <UP,DONE>"
        XCTAssertEqual(VPNInterfaceSelector.parseDefaultRouteInterface(out), "utun4")
    }

    func testUnparseableRouteOutputYieldsNil() {
        XCTAssertNil(VPNInterfaceSelector.parseDefaultRouteInterface(""))
        XCTAssertNil(VPNInterfaceSelector.parseDefaultRouteInterface("route: writing to routing socket: not in table"))
    }
}
