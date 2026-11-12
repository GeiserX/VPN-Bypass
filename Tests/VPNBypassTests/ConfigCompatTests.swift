// ConfigCompatTests.swift
// A user's rules and routes are never lost to an update. A config written by an earlier version
// loads whole and saves back the same; a config with a match type or route type this version does
// not know loads too, and what it does not know is written back as it was. The fixtures are made
// up (reserved example names); `ConfigCompatTests.testARealConfigLoadsAndSavesBackWithoutLoss` reads
// a real file when `VPNB_CONFIG_FILE` names one, and only reads it.

import XCTest
@testable import VPNBypassCore

final class ConfigCompatTests: XCTestCase {

    private let directID = "11111111-1111-1111-1111-111111111111"
    private let vpnID = "22222222-2222-2222-2222-222222222222"
    private let proxyID = "33333333-3333-3333-3333-333333333333"

    /// A config as version 6.1 wrote it: no GeoIP, GeoSite, Block, source or sync keys.
    private var legacy: String {
        """
        {
          "schemaVersion": 2, "routingMode": "custom", "multiRouteEnabled": true,
          "defaultRouteId": "\(vpnID)",
          "routes": [
            {"id": "\(directID)", "name": "Direct", "egress": "direct", "enabled": true, "sessionMode": "none", "remoteDNS": true},
            {"id": "\(vpnID)", "name": "VPN", "egress": "vpnDefault", "enabled": true, "sessionMode": "none", "remoteDNS": true,
             "vpnSelector": {"kind": "primary"}},
            {"id": "\(proxyID)", "name": "office", "egress": "proxySOCKS5", "enabled": true, "proxyHost": "198.51.100.7",
             "proxyPort": 1080, "sessionMode": "none", "remoteDNS": true, "localListenPort": 18168}
          ],
          "rules": [
            {"id": "aaaaaaaa-0000-0000-0000-000000000001", "matchType": "domain", "pattern": "example.org", "routeId": "\(proxyID)", "enabled": true, "order": 0},
            {"id": "aaaaaaaa-0000-0000-0000-000000000002", "matchType": "cidr", "pattern": "203.0.113.0/24", "routeId": "\(directID)", "enabled": true, "order": 1},
            {"id": "aaaaaaaa-0000-0000-0000-000000000003", "matchType": "service", "pattern": "telegram", "routeId": "\(directID)", "enabled": false, "order": 2},
            {"id": "aaaaaaaa-0000-0000-0000-000000000004", "matchType": "suffix", "pattern": "*.example.net", "routeId": "\(directID)", "enabled": true, "order": 3},
            {"id": "aaaaaaaa-0000-0000-0000-000000000005", "matchType": "process", "pattern": "com.example.App", "routeId": "\(directID)", "enabled": true, "order": 4},
            {"id": "aaaaaaaa-0000-0000-0000-000000000006", "matchType": "ip", "pattern": "198.51.100.9", "routeId": "\(vpnID)", "enabled": true, "order": 5}
          ],
          "domains": [], "inverseDomains": [], "fallbackDNS": ["1.1.1.1", "8.8.8.8"]
        }
        """
    }

    private func decode(_ json: String) throws -> RouteManager.Config {
        try JSONDecoder().decode(RouteManager.Config.self, from: Data(json.utf8))
    }

    private func object(_ config: RouteManager.Config) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    }

    // MARK: - An earlier version's config

    func testAConfigFromBeforeTheseFeaturesLoadsWhole() throws {
        let c = try decode(legacy)
        XCTAssertEqual(c.rules.count, 6)
        XCTAssertEqual(c.routes.count, 3)
        XCTAssertEqual(c.rules.map(\.matchType), [.domain, .cidr, .service, .suffix, .process, .ip])
        XCTAssertEqual(c.rules.map(\.pattern), ["example.org", "203.0.113.0/24", "telegram", "*.example.net", "com.example.App", "198.51.100.9"])
        XCTAssertEqual(c.rules.map(\.order), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(c.rules[2].enabled, false, "a rule that was off stays off")
        XCTAssertEqual(c.routes.map(\.egress), [.direct, .vpnDefault, .proxySOCKS5])
        XCTAssertEqual(c.routes[2].localListenPort, 18168)
        XCTAssertEqual(c.routingMode, .custom)
        XCTAssertEqual(c.defaultRouteId, UUID(uuidString: vpnID))
    }

    func testTheNewSettingsTakeTheirDefaultsAndChangeNothingElse() throws {
        let c = try decode(legacy)
        XCTAssertNil(c.geoipSourceURL)
        XCTAssertNil(c.geositeSourceURL)
        XCTAssertEqual(c.geoSyncSchedule, .weekly)
        XCTAssertFalse(c.routes.contains { $0.egress == .block }, "no route is added to a config that never blocks")
        XCTAssertEqual(c.routes.count, 3)
    }

    func testSavingAnOldConfigWritesTheSameRulesAndRoutes() throws {
        let c = try decode(legacy)
        let back = try decode(String(decoding: JSONEncoder().encode(c), as: UTF8.self))
        XCTAssertEqual(back.rules, c.rules)
        XCTAssertEqual(back.routes, c.routes)
        // Field by field, as a file diff would see them.
        let written = try XCTUnwrap(try object(c)["rules"] as? [[String: Any]])
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(legacy.utf8)) as? [String: Any])
        for (a, b) in zip(try XCTUnwrap(original["rules"] as? [[String: Any]]), written) {
            for key in ["id", "matchType", "pattern", "routeId", "enabled", "order"] {
                XCTAssertEqual("\(a[key] ?? "")".lowercased(), "\(b[key] ?? "")".lowercased(), "rule \(a["id"] ?? ""): \(key)")
            }
        }
    }

    // MARK: - A newer version's config

    private var future: String {
        legacy
            .replacingOccurrences(of: "\"matchType\": \"ip\", \"pattern\": \"198.51.100.9\"",
                                  with: "\"matchType\": \"asn\", \"pattern\": \"AS64496\"")
            .replacingOccurrences(of: "{\"id\": \"\(proxyID)\", \"name\": \"office\", \"egress\": \"proxySOCKS5\"",
                                  with: "{\"id\": \"\(proxyID)\", \"name\": \"office\", \"egress\": \"wireguard2\"")
            .replacingOccurrences(of: "\"fallbackDNS\"", with: "\"geoSync\": \"hourly\", \"fallbackDNS\"")
    }

    func testATypeThisVersionDoesNotKnowIsKeptInertAndTheRestLoads() throws {
        let c = try decode(future)
        XCTAssertEqual(c.rules.count, 6, "the unknown rule did not take the others with it")
        let unknownRule = try XCTUnwrap(c.rules.last)
        XCTAssertEqual(unknownRule.matchType, .unsupported)
        XCTAssertEqual(unknownRule.unknownMatchType, "asn")
        XCTAssertEqual(unknownRule.pattern, "AS64496")
        let unknownRoute = try XCTUnwrap(c.routes.last)
        XCTAssertEqual(unknownRoute.egress, .unsupported)
        XCTAssertEqual(unknownRoute.unknownEgress, "wireguard2")
        XCTAssertEqual(unknownRoute.proxyHost, "198.51.100.7", "what the route carried is kept")
        XCTAssertEqual(c.geoSyncSchedule, .weekly, "an unknown schedule is the default")
        XCTAssertEqual(c.rules.first?.matchType, .domain)
    }

    func testWhatItDoesNotKnowIsWrittenBackAsItWas() throws {
        let c = try decode(future)
        let written = try object(c)
        let rules = try XCTUnwrap(written["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.last?["matchType"] as? String, "asn")
        XCTAssertEqual(rules.last?["pattern"] as? String, "AS64496")
        let routes = try XCTUnwrap(written["routes"] as? [[String: Any]])
        XCTAssertEqual(routes.last?["egress"] as? String, "wireguard2")
        XCTAssertEqual(routes.last?["proxyHost"] as? String, "198.51.100.7")
        XCTAssertEqual(routes.last?["localListenPort"] as? Int, 18168)
        // And again: a second open and save changes nothing.
        let again = try object(try decode(String(decoding: JSONSerialization.data(withJSONObject: written), as: UTF8.self)))
        XCTAssertEqual((again["rules"] as? [[String: Any]])?.last?["matchType"] as? String, "asn")
        XCTAssertEqual((again["routes"] as? [[String: Any]])?.last?["egress"] as? String, "wireguard2")
    }

    func testAnUnknownTypeCarriesNoTrafficAndShadowsNothing() throws {
        let c = try decode(future)
        let unknownRule = try XCTUnwrap(c.rules.last)
        XCTAssertTrue(RuleDestinationBuilder.build(rules: [unknownRule], services: [], resolved: [:])[0].dests.isEmpty)
        XCTAssertNil(RuleResolver.route(forIP: "198.51.100.9", rules: [unknownRule], routes: c.routes, defaultRouteId: nil))
        XCTAssertFalse(SiteRoute.ruleMatches(unknownRule, host: "example.org", addresses: ["198.51.100.9"], services: []))
        // A rule on a route of an unknown type claims nothing, so a later rule still decides.
        let unknownRoute = try XCTUnwrap(c.routes.last)
        let direct = Route(name: "Direct", egress: .direct)
        let first = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: unknownRoute.id, order: 0)
        let second = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: direct.id, order: 1)
        let out = RouteCompiler.compile(resolvedRules: [(first, [("203.0.113.0/24", true)]), (second, [("203.0.113.0/24", true)])],
                                        routes: [unknownRoute, direct], localGateway: "192.168.10.1", ifaceGatewayForRoute: { _ in nil })
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.gateway, "192.168.10.1")
    }

    func testTheRowOfAnUnknownRuleSaysWhatItIs() throws {
        let unknown = try XCTUnwrap(decode(future).rules.last)
        XCTAssertEqual(RuleRow.patternDisplay(unknown, services: []), "asn: AS64496")
        XCTAssertEqual(RuleRow.glyph(for: .unsupported), "questionmark.circle")
        XCTAssertEqual(RouteChip.systemImage(for: .unsupported), "questionmark.circle")
    }

    func testARuleThisVersionWritesStillReadsAsItself() throws {
        var c = RouteManager.Config()
        let direct = Route(name: "Direct", egress: .direct)
        c.routes = [direct, Route(name: Route.blockName, egress: .block)]
        c.defaultRouteId = direct.id
        c.schemaVersion = 2
        c.rules = [Rule(matchType: .geoip, pattern: "ir", routeId: direct.id, order: 0),
                   Rule(matchType: .geosite, pattern: "category-games@cn", routeId: direct.id, order: 1)]
        let back = try decode(String(decoding: JSONEncoder().encode(c), as: UTF8.self))
        XCTAssertEqual(back.rules.map(\.matchType), [.geoip, .geosite])
        XCTAssertEqual(back.routes.map(\.egress), [.direct, .block])
        XCTAssertNil(back.rules[0].unknownMatchType)
    }

    // MARK: - A real file

    /// A real config or export, read and never written:
    ///
    ///   VPNB_CONFIG_FILE=~/Library/Application\ Support/VPNBypass/config.json swift test --filter ConfigCompatTests
    func testARealConfigLoadsAndSavesBackWithoutLoss() throws {
        guard let path = ProcessInfo.processInfo.environment["VPNB_CONFIG_FILE"] else {
            throw XCTSkip("Set VPNB_CONFIG_FILE to a config.json or an exported config to check it.")
        }
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let raw = (file["config"] as? [String: Any]) ?? file
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: JSONSerialization.data(withJSONObject: raw))
        let written = try object(config)

        for key in ["rules", "routes", "services", "domains", "inverseDomains"] {
            let before = (raw[key] as? [Any])?.count ?? 0
            let after = (written[key] as? [Any])?.count ?? 0
            XCTAssertEqual(after, before, "\(key): \(before) before, \(after) after")
        }
        let rawRules = raw["rules"] as? [[String: Any]] ?? []
        let newRules = written["rules"] as? [[String: Any]] ?? []
        var changed = 0
        for (a, b) in zip(rawRules, newRules) {
            for key in ["id", "matchType", "pattern", "routeId", "enabled", "order"] where "\(a[key] ?? "")".lowercased() != "\(b[key] ?? "")".lowercased() {
                changed += 1
            }
        }
        XCTAssertEqual(changed, 0, "fields of rules that changed")
        let rawRoutes = raw["routes"] as? [[String: Any]] ?? []
        let newRoutes = written["routes"] as? [[String: Any]] ?? []
        for (a, b) in zip(rawRoutes, newRoutes) {
            for key in ["id", "name", "egress", "enabled"] {
                XCTAssertEqual("\(a[key] ?? "")".lowercased(), "\(b[key] ?? "")".lowercased(), "route \(a["name"] ?? ""): \(key)")
            }
        }
        let again = try JSONDecoder().decode(RouteManager.Config.self, from: JSONSerialization.data(withJSONObject: written))
        XCTAssertEqual(again.rules, config.rules)
        XCTAssertEqual(again.routes, config.routes)
        print("COMPAT rules=\(rawRules.count) routes=\(rawRoutes.count) services=\((raw["services"] as? [Any])?.count ?? 0) unchanged")
    }
}
