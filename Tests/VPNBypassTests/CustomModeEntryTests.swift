// CustomModeEntryTests.swift
// The Custom-mode entry transition in RouteManager.setRoutingMode: first entry
// (schemaVersion 1) bumps to 2 and derives the bypass/vpnOnly lists into rules
// losslessly (keeping user proxy/Tailscale routes); re-entry keeps edited rules.

import XCTest
@testable import VPNBypassCore

@MainActor
final class CustomModeEntryTests: XCTestCase {

    private var saved: RouteManager.Config!

    override func setUp() async throws { saved = RouteManager.shared.config }
    override func tearDown() async throws { RouteManager.shared.config = saved }

    func testFirstCustomEntryMigratesDomainsAndPreservesUserRoutes() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.schemaVersion = 1
        cfg.domains = [RouteManager.DomainEntry(domain: "a.com")]
        cfg.services = []
        let userProxy = Route(name: "oxy", egress: .proxyHTTP, proxyHost: "h", proxyPort: 8001)
        cfg.routes = [userProxy]
        cfg.rules = []
        cfg.defaultRouteId = nil
        RouteManager.shared.config = cfg

        RouteManager.shared.setRoutingMode(.custom)
        let c = RouteManager.shared.config

        XCTAssertEqual(c.routingMode, .custom)
        XCTAssertEqual(c.schemaVersion, 2, "first Custom entry bumps schemaVersion to 2")
        XCTAssertNotNil(c.defaultRouteId, "a default route is set from the migration")
        XCTAssertTrue(c.routes.contains { $0.id == userProxy.id }, "user proxy route preserved (lossless)")
        XCTAssertTrue(c.routes.contains { $0.egress == .direct }, "derived a Direct route")
        XCTAssertTrue(c.rules.contains { $0.pattern == "a.com" }, "the bypassed domain became a rule")
    }

    func testReenteringCustomDoesNotClobberEditedRules() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass       // came back OUT to bypass, schemaVersion already bumped once
        cfg.schemaVersion = 2
        let r = Route(name: "d", egress: .direct)
        cfg.routes = [r]
        cfg.rules = [Rule(matchType: .domain, pattern: "kept.com", routeId: r.id, order: 0)]
        cfg.defaultRouteId = r.id
        RouteManager.shared.config = cfg

        RouteManager.shared.setRoutingMode(.custom)
        let c = RouteManager.shared.config

        XCTAssertEqual(c.routingMode, .custom)
        XCTAssertEqual(c.rules.count, 1, "re-entering Custom (schemaVersion already 2) does NOT re-derive")
        XCTAssertEqual(c.rules.first?.pattern, "kept.com", "the user's edited rule is untouched")
    }

    // The gap live-testing surfaced: a schemaVersion-2 bypass config that has the system
    // routes but ZERO rules (decoder bumped the version without ruling). The old guard
    // (`schemaVersion < 2`) skipped derivation, so entering Custom dropped every listed
    // domain onto the OS default. It must now derive rules onto the EXISTING routes.
    func testSchemaV2BypassWithoutRulesDerivesRulesOntoExistingRoutes() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.schemaVersion = 2
        let vpn = Route(name: "Corporate VPN", egress: .vpnDefault)
        let direct = Route(name: "Direct", egress: .direct)
        cfg.routes = [vpn, direct]
        cfg.rules = []
        cfg.defaultRouteId = direct.id        // a bypass leftover; custom should flip it to VPN
        cfg.domains = [RouteManager.DomainEntry(domain: "a.com"), RouteManager.DomainEntry(domain: "b.com")]
        cfg.services = []
        RouteManager.shared.config = cfg

        RouteManager.shared.setRoutingMode(.custom)
        let c = RouteManager.shared.config

        XCTAssertEqual(c.routingMode, .custom)
        XCTAssertEqual(c.rules.count, 2, "both bypassed domains became rules (not dropped)")
        XCTAssertTrue(c.rules.allSatisfy { $0.routeId == direct.id },
                      "rules point at the EXISTING Direct route id, not a freshly-minted one")
        XCTAssertTrue(c.routes.contains { $0.id == vpn.id && $0.name == "Corporate VPN" },
                      "existing VPN route id + name preserved (no duplicate minted)")
        XCTAssertEqual(c.routes.count, 2, "no duplicate system routes added")
        XCTAssertEqual(c.defaultRouteId, vpn.id, "default flips to VPN (bypass semantics: unmatched -> VPN)")
    }

    func testCustomEntryStaysEmptyWhenNothingToRoute() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.schemaVersion = 2
        cfg.routes = [Route(name: "Corporate VPN", egress: .vpnDefault), Route(name: "Direct", egress: .direct)]
        cfg.rules = []
        cfg.domains = []
        cfg.services = []
        RouteManager.shared.config = cfg

        RouteManager.shared.setRoutingMode(.custom)
        let c = RouteManager.shared.config
        XCTAssertEqual(c.routingMode, .custom)
        XCTAssertTrue(c.rules.isEmpty, "nothing to route -> Custom starts empty (no fabricated rules)")
    }

    func testVpnOnlyWithoutRulesDerivesInverseDomainsOntoExistingVPNRoute() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .vpnOnly
        cfg.schemaVersion = 2
        let vpn = Route(name: "Corporate VPN", egress: .vpnDefault)
        let direct = Route(name: "Direct", egress: .direct)
        cfg.routes = [vpn, direct]
        cfg.rules = []
        cfg.inverseDomains = [RouteManager.DomainEntry(domain: "work.com")]
        RouteManager.shared.config = cfg

        RouteManager.shared.setRoutingMode(.custom)
        let c = RouteManager.shared.config
        XCTAssertEqual(c.rules.count, 1, "the vpnOnly inverse-domain became a rule")
        XCTAssertEqual(c.rules.first?.routeId, vpn.id, "vpnOnly routes the listed domain via the EXISTING VPN route")
        XCTAssertEqual(c.rules.first?.pattern, "work.com")
        XCTAssertEqual(c.defaultRouteId, direct.id, "vpnOnly default is Direct")
    }

    func testRoutingModeDisplayNames() {
        XCTAssertEqual(RouteManager.RoutingMode.bypass.displayName, "Bypass")
        XCTAssertEqual(RouteManager.RoutingMode.vpnOnly.displayName, "VPN Only")
        XCTAssertEqual(RouteManager.RoutingMode.custom.displayName, "Custom Routes")
    }
}
