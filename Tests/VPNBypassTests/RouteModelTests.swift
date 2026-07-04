// RouteModelTests.swift
// Coverage for the multi-route model + back-compat migration (VPN-Bypass-3sc.7).
// The migration must populate routes/rules from the legacy model WITHOUT
// changing behaviour — schemaVersion stays 1 until P1 switches the engine.

import XCTest
@testable import VPNBypassCore

final class RouteModelTests: XCTestCase {

    // MARK: - Codable round-trips

    func testRouteCodableRoundTrip() throws {
        let r = Route(
            name: "US-Oxylabs", egress: .proxySOCKS5,
            proxyHost: "disp.oxylabs.io", proxyPort: 8001,
            proxyUser: "user", proxyPass: "pass",
            sessionMode: .sticky, sessionTTLMinutes: 30
        )
        let back = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(r, back)
    }

    func testRuleCodableRoundTrip() throws {
        let rule = Rule(matchType: .domain, pattern: "x.com", routeId: UUID(), order: 3)
        let back = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(rule, back)
    }

    /// Forward/back compat: a Route with only the core keys decodes with defaults.
    func testRouteDecodesFromPartialJSON() throws {
        let json = #"{"name":"Direct","egress":"direct"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(Route.self, from: json)
        XCTAssertEqual(r.name, "Direct")
        XCTAssertEqual(r.egress, .direct)
        XCTAssertTrue(r.enabled)
        XCTAssertTrue(r.remoteDNS)
        XCTAssertEqual(r.sessionMode, .none)
        XCTAssertNil(r.proxyHost)
    }

    // MARK: - derive()

    func testDeriveBypassMapsListedToDirectWithVPNDefault() {
        let domains = [RouteManager.DomainEntry(domain: "x.com", enabled: true)]
        let services = [RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: ["t.me"], ipRanges: [])]
        let d = RouteManager.Config.derive(domains: domains, services: services, mode: .bypass, inverseDomains: [], proxy: RouteManager.ProxyConfig())

        let vpn = d.routes.first { $0.egress == .vpnDefault }!
        let direct = d.routes.first { $0.egress == .direct }!
        XCTAssertEqual(d.defaultRouteId, vpn.id, "bypass default is the VPN")
        XCTAssertEqual(d.rules.count, 2)
        XCTAssertTrue(d.rules.allSatisfy { $0.routeId == direct.id }, "listed entries go Direct")
        XCTAssertTrue(d.rules.contains { $0.matchType == .domain && $0.pattern == "x.com" })
        XCTAssertTrue(d.rules.contains { $0.matchType == .service && $0.pattern == "telegram" })
        // first-match ordering is stable and contiguous
        XCTAssertEqual(d.rules.map(\.order).sorted(), Array(0..<d.rules.count))
    }

    func testDeriveVPNOnlyMapsInverseToVPNWithDirectDefault() {
        let inverse = [RouteManager.DomainEntry(domain: "intranet.corp", enabled: true)]
        let d = RouteManager.Config.derive(domains: [], services: [], mode: .vpnOnly, inverseDomains: inverse, proxy: RouteManager.ProxyConfig())

        let vpn = d.routes.first { $0.egress == .vpnDefault }!
        let direct = d.routes.first { $0.egress == .direct }!
        XCTAssertEqual(d.defaultRouteId, direct.id, "VPN Only default is Direct")
        XCTAssertEqual(d.rules.count, 1)
        XCTAssertEqual(d.rules.first?.routeId, vpn.id)
        XCTAssertEqual(d.rules.first?.pattern, "intranet.corp")
    }

    func testDeriveProxyCreatesRouteAndRoutesOnlyItsServices() {
        var proxy = RouteManager.ProxyConfig()
        proxy.enabled = true
        proxy.server = "disp.oxylabs.io"
        proxy.port = 8001
        proxy.username = "u"
        proxy.password = "p"
        proxy.useForServices = ["telegram"]
        let services = [
            RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: ["t.me"], ipRanges: []),
            RouteManager.ServiceEntry(id: "spotify", name: "Spotify", enabled: true, domains: ["spotify.com"], ipRanges: [])
        ]
        let d = RouteManager.Config.derive(domains: [], services: services, mode: .bypass, inverseDomains: [], proxy: proxy)

        let proxyRoute = d.routes.first { $0.egress == .proxySOCKS5 }!
        let direct = d.routes.first { $0.egress == .direct }!
        XCTAssertEqual(proxyRoute.proxyHost, "disp.oxylabs.io")
        XCTAssertEqual(proxyRoute.proxyPort, 8001)
        XCTAssertEqual(d.rules.first { $0.pattern == "telegram" }?.routeId, proxyRoute.id, "listed service → proxy")
        XCTAssertEqual(d.rules.first { $0.pattern == "spotify" }?.routeId, direct.id, "unlisted service → Direct")
    }

    // MARK: - Config migration on decode

    func testLegacyConfigDecodePopulatesRoutesAtSchemaV1() throws {
        // Legacy config: one domain, bypass mode, NO routes/rules/schemaVersion keys.
        let json = #"{"domains":[{"id":"11111111-1111-1111-1111-111111111111","domain":"x.com","enabled":true,"isCIDR":false,"isWildcard":false}],"services":[],"routingMode":"bypass"}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertEqual(cfg.schemaVersion, 1, "migration must NOT change behaviour")
        XCTAssertTrue(cfg.routes.contains { $0.egress == .vpnDefault })
        XCTAssertTrue(cfg.routes.contains { $0.egress == .direct })
        XCTAssertNotNil(cfg.defaultRouteId)
        XCTAssertTrue(cfg.rules.contains { $0.pattern == "x.com" }, "legacy domain became a rule")
    }

    /// When routes already exist, decode must NOT re-derive (explicit model wins).
    func testConfigWithRoutesRoundTripsWithoutRederiving() throws {
        var cfg = RouteManager.Config()
        let custom = Route(name: "Only", egress: .direct)
        cfg.routes = [custom]
        cfg.schemaVersion = 2
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.schemaVersion, 2)
        XCTAssertEqual(back.routes.count, 1)
        XCTAssertEqual(back.routes.first?.id, custom.id, "explicit routes survive; derive() must not run")
    }
}
