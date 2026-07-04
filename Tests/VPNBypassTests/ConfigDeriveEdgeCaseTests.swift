// ConfigDeriveEdgeCaseTests.swift
// Additional edge-case coverage for RouteManager.Config.derive() and
// preparedForCustomMode(), layered on top of RouteModelTests.swift (derive() basics)
// and CustomModeEntryTests.swift (the higher-level setRoutingMode() transition):
// proxy useForServices semantics, vpnOnly ignoring domains/services, disabled entries
// being skipped, idempotent re-application, the empty-lists early-return, and the
// remap-onto-existing-route-ids paths (both the "append a new counterpart" and the
// "partial system routes ⇒ fresh adoption" cases). Both functions are pure (no actor,
// no I/O), so every test here constructs a Config value directly — no RouteManager.shared.

import XCTest
@testable import VPNBypassCore

final class ConfigDeriveEdgeCaseTests: XCTestCase {

    // MARK: - derive(): proxy → service mapping

    /// `useForServices` EMPTY means "all enabled services", not "no services" — every
    /// enabled service must route to the proxy when the list is empty.
    func testDeriveMapsAllServicesToProxyWhenUseForServicesEmpty() {
        var proxy = RouteManager.ProxyConfig()
        proxy.enabled = true
        proxy.server = "proxy.example.com"
        proxy.port = 1080
        proxy.useForServices = []   // empty = all enabled services
        let services = [
            RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: ["t.me"], ipRanges: []),
            RouteManager.ServiceEntry(id: "spotify", name: "Spotify", enabled: true, domains: ["spotify.com"], ipRanges: []),
        ]
        let d = RouteManager.Config.derive(domains: [], services: services, mode: .bypass, inverseDomains: [], proxy: proxy)

        let proxyRoute = try! XCTUnwrap(d.routes.first { $0.egress == .proxySOCKS5 })
        XCTAssertEqual(d.rules.first { $0.pattern == "telegram" }?.routeId, proxyRoute.id)
        XCTAssertEqual(d.rules.first { $0.pattern == "spotify" }?.routeId, proxyRoute.id, "empty useForServices routes EVERY enabled service to the proxy")
    }

    /// A proxy that is fully CONFIGURED (valid server/port) but not ENABLED must not
    /// produce a proxy route at all — every service falls back to Direct.
    func testDeriveSkipsProxyRouteWhenProxyDisabledEvenIfConfigured() {
        var proxy = RouteManager.ProxyConfig()
        proxy.enabled = false
        proxy.server = "proxy.example.com"
        proxy.port = 1080
        let services = [RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: ["t.me"], ipRanges: [])]
        let d = RouteManager.Config.derive(domains: [], services: services, mode: .bypass, inverseDomains: [], proxy: proxy)

        XCTAssertFalse(d.routes.contains { $0.egress == .proxySOCKS5 }, "disabled proxy must not mint a route")
        let direct = try! XCTUnwrap(d.routes.first { $0.egress == .direct })
        XCTAssertEqual(d.rules.first { $0.pattern == "telegram" }?.routeId, direct.id)
    }

    // MARK: - derive(): vpnOnly ignores domains/services

    /// In `.vpnOnly` mode, ENABLED `domains`/`services` (the bypass-mode lists) are
    /// completely ignored — only `inverseDomains` produce rules.
    func testDeriveVpnOnlyIgnoresDomainsAndServicesOnlyUsesInverseDomains() {
        let domains = [RouteManager.DomainEntry(domain: "ignored.com", enabled: true)]
        let services = [RouteManager.ServiceEntry(id: "ignoredsvc", name: "Ignored", enabled: true, domains: ["x.com"], ipRanges: [])]
        let inverse = [RouteManager.DomainEntry(domain: "work.com", enabled: true)]
        let d = RouteManager.Config.derive(domains: domains, services: services, mode: .vpnOnly, inverseDomains: inverse, proxy: RouteManager.ProxyConfig())

        XCTAssertEqual(d.rules.count, 1, "only the inverse domain becomes a rule")
        XCTAssertEqual(d.rules.first?.pattern, "work.com")
        XCTAssertFalse(d.rules.contains { $0.pattern == "ignored.com" })
        XCTAssertFalse(d.rules.contains { $0.pattern == "ignoredsvc" })
    }

    // MARK: - derive(): disabled entries are skipped

    /// Disabled domains and disabled services contribute NO rules in bypass mode.
    func testDeriveSkipsDisabledDomainsAndServices() {
        let domains = [
            RouteManager.DomainEntry(domain: "on.com", enabled: true),
            RouteManager.DomainEntry(domain: "off.com", enabled: false),
        ]
        let services = [
            RouteManager.ServiceEntry(id: "onsvc", name: "On", enabled: true, domains: ["on.svc"], ipRanges: []),
            RouteManager.ServiceEntry(id: "offsvc", name: "Off", enabled: false, domains: ["off.svc"], ipRanges: []),
        ]
        let d = RouteManager.Config.derive(domains: domains, services: services, mode: .bypass, inverseDomains: [], proxy: RouteManager.ProxyConfig())

        XCTAssertEqual(d.rules.count, 2)
        XCTAssertTrue(d.rules.contains { $0.pattern == "on.com" })
        XCTAssertTrue(d.rules.contains { $0.pattern == "onsvc" })
        XCTAssertFalse(d.rules.contains { $0.pattern == "off.com" })
        XCTAssertFalse(d.rules.contains { $0.pattern == "offsvc" })
    }

    // MARK: - preparedForCustomMode(): idempotent re-entry

    /// Applying preparedForCustomMode() a SECOND time (on its own output, not just a
    /// config that already happened to have rules) is a true no-op: rules are already
    /// non-empty, so the second call hits the early-return guard unchanged.
    func testPreparedForCustomModeIsIdempotentAcrossTwoApplications() {
        var cfg = RouteManager.Config()
        cfg.schemaVersion = 1
        cfg.routingMode = .bypass
        cfg.domains = [RouteManager.DomainEntry(domain: "a.com", enabled: true)]
        cfg.services = []
        cfg.routes = []
        cfg.rules = []

        let once = cfg.preparedForCustomMode()
        let twice = once.preparedForCustomMode()

        XCTAssertEqual(twice.rules, once.rules, "re-applying must not change already-derived rules")
        XCTAssertEqual(twice.routes, once.routes)
        XCTAssertEqual(twice.schemaVersion, once.schemaVersion)
        XCTAssertEqual(twice.defaultRouteId, once.defaultRouteId)
        XCTAssertFalse(once.rules.isEmpty, "sanity: the first application actually derived something")
    }

    // MARK: - preparedForCustomMode(): empty lists

    /// Nothing to route (empty domains/services/inverseDomains) → preparedForCustomMode
    /// bumps schemaVersion but returns EARLY, before ever touching `routes` — it does
    /// NOT fabricate the vpn/direct pair when there was nothing to route.
    func testPreparedForCustomModeWithEmptyListsLeavesRoutesEmptyAndOnlyBumpsSchemaVersion() {
        var cfg = RouteManager.Config()
        cfg.schemaVersion = 1
        cfg.routingMode = .bypass
        cfg.domains = []
        cfg.services = []
        cfg.inverseDomains = []
        cfg.routes = []
        cfg.rules = []
        cfg.defaultRouteId = nil

        let result = cfg.preparedForCustomMode()

        XCTAssertEqual(result.schemaVersion, 2, "schemaVersion still bumps even with nothing to route")
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertTrue(result.routes.isEmpty, "no routes are fabricated when there is nothing to route")
        XCTAssertNil(result.defaultRouteId)
    }

    // MARK: - preparedForCustomMode(): remap onto existing route ids

    /// Routes exist (vpn + direct) but rules are empty AND the legacy proxy has no
    /// existing counterpart in `c.routes`: the remap loop must APPEND the freshly
    /// derived proxy route (rather than drop the service's proxy rule), while the
    /// existing vpn/direct routes are reused (not duplicated).
    func testRemapAppendsDerivedProxyRouteWhenNoExistingCounterpart() {
        var cfg = RouteManager.Config()
        cfg.schemaVersion = 2
        cfg.routingMode = .bypass
        let vpn = Route(name: "Corporate VPN", egress: .vpnDefault)
        let direct = Route(name: "Direct", egress: .direct)
        cfg.routes = [vpn, direct]     // no existing proxy route
        cfg.rules = []
        cfg.domains = []
        cfg.services = [RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: ["t.me"], ipRanges: [])]
        var proxy = RouteManager.ProxyConfig()
        proxy.enabled = true
        proxy.server = "proxy.example.com"
        proxy.port = 1080
        proxy.useForServices = ["telegram"]
        cfg.proxyConfig = proxy

        let result = cfg.preparedForCustomMode()

        XCTAssertEqual(result.routes.count, 3, "existing vpn + direct, plus the newly appended proxy route")
        XCTAssertTrue(result.routes.contains { $0.id == vpn.id }, "existing VPN route reused, not duplicated")
        XCTAssertTrue(result.routes.contains { $0.id == direct.id }, "existing Direct route reused, not duplicated")
        let appendedProxy = try! XCTUnwrap(result.routes.first { $0.egress == .proxySOCKS5 })
        XCTAssertNotEqual(appendedProxy.id, vpn.id)
        XCTAssertNotEqual(appendedProxy.id, direct.id)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules.first?.routeId, appendedProxy.id, "the telegram rule points at the appended proxy route")
        XCTAssertEqual(result.defaultRouteId, vpn.id, "default remaps onto the EXISTING vpn route id")
    }

    /// Only ONE of the two system routes exists (a VPN route but no Direct route) →
    /// `hasSystemRoutes` requires BOTH, so this takes the "fresh adoption" branch: the
    /// pre-existing (differently-named) VPN-only route is replaced by the freshly
    /// derived vpn+direct pair rather than being reused.
    func testPartialSystemRoutesTakesFreshAdoptionPathReplacingRoutes() {
        var cfg = RouteManager.Config()
        cfg.schemaVersion = 2
        cfg.routingMode = .bypass
        let onlyVPN = Route(name: "Custom VPN Only", egress: .vpnDefault)
        cfg.routes = [onlyVPN]   // no .direct route present
        cfg.rules = []
        cfg.domains = [RouteManager.DomainEntry(domain: "a.com", enabled: true)]
        cfg.services = []

        let result = cfg.preparedForCustomMode()

        XCTAssertEqual(result.routes.count, 2, "the fresh-adoption path installs exactly the derived vpn+direct pair")
        XCTAssertFalse(result.routes.contains { $0.name == "Custom VPN Only" }, "the original partial route is NOT preserved")
        XCTAssertTrue(result.routes.allSatisfy { $0.egress == .vpnDefault || $0.egress == .direct })
        XCTAssertEqual(result.rules.count, 1)
        let newDirect = try! XCTUnwrap(result.routes.first { $0.egress == .direct })
        let newVPN = try! XCTUnwrap(result.routes.first { $0.egress == .vpnDefault })
        XCTAssertEqual(result.rules.first?.routeId, newDirect.id)
        XCTAssertEqual(result.defaultRouteId, newVPN.id)
    }
}
