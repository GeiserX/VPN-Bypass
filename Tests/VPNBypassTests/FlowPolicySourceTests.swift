// FlowPolicySourceTests.swift
// The app's config, compiled into the per-app routing policy (design doc 3.3): process rules
// become app matchers, the rest stays with the kernel engine, and nothing but the rule ids and
// app patterns reaches the policy blob.

import XCTest
@testable import VPNBypassCore
import VPNBypassPolicy

final class FlowPolicySourceTests: XCTestCase {
    let vpn = Route(name: "Corporate VPN", egress: .vpnDefault)
    let pinned = Route(name: "Second VPN", egress: .vpnDefault,
                       vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun7", productHint: "WireGuard"))
    let direct = Route(name: "Direct", egress: .direct)
    let proxy = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "proxy.example.net", proxyPort: 1080,
                      proxyUser: "proxy-user", proxyPass: "proxy-secret-pass")
    let exit = Route(name: "Exit", egress: .tailscaleExit, tailscaleExitNode: "exit-node.example")

    func customConfig(_ rules: [Rule]) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [vpn, pinned, direct, proxy, exit]
        c.defaultRouteId = vpn.id
        c.rules = rules
        return c
    }

    func compile(_ c: RouteManager.Config, paused: Bool = false, killSwitch: Bool = false) -> FlowPolicy {
        FlowPolicyCompiler.compile(
            FlowPolicyCompiler.Input(config: c, paused: paused, killSwitchActive: killSwitch,
                                     physicalInterface: "en0", tunnelOwnerTeams: ["TEAM000001"]),
            generation: 1)
    }

    func testCustomProcessRulesBecomeMatchersInOrder() {
        let rules = [
            Rule(matchType: .domain, pattern: "intranet.example.com", routeId: direct.id, order: 0),
            Rule(matchType: .process, pattern: "com.example.Browser", routeId: direct.id, order: 3),
            Rule(matchType: .process, pattern: "ExampleTool", routeId: vpn.id, order: 1),
            Rule(matchType: .process, pattern: "com.example.Pinned", routeId: pinned.id, order: 2),
            Rule(matchType: .process, pattern: "com.example.Proxied", routeId: proxy.id, order: 4),
            Rule(matchType: .process, pattern: "com.example.Exit", routeId: exit.id, order: 5),
            Rule(matchType: .process, pattern: "com.example.Off", routeId: direct.id, enabled: false, order: 6),
            Rule(matchType: .service, pattern: "slack", routeId: direct.id, order: 7),
        ]
        let p = compile(customConfig(rules))
        XCTAssertEqual(p.matchers.map(\.pattern),
                       ["ExampleTool", "com.example.Pinned", "com.example.Browser", "com.example.Proxied", "com.example.Exit"])
        XCTAssertEqual(p.matchers.map(\.egress),
                       [.vpnDefault, .unsupported, .direct(interface: "en0"), .unsupported, .unsupported])
        XCTAssertEqual(p.matchers.map(\.ruleID), [rules[2], rules[3], rules[1], rules[4], rules[5]].map(\.id.uuidString))
        XCTAssertEqual(p.declinedTeams, ["TEAM000001"])
    }

    func testDisabledRouteSkipsItsRules() {
        var c = customConfig([Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)])
        c.routes = c.routes.map { var r = $0; if r.id == direct.id { r.enabled = false }; return r }
        XCTAssertEqual(compile(c).matchers, [])
    }

    func testModesAndStandDowns() {
        let rules = [Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)]
        XCTAssertEqual(compile(customConfig(rules)).matchers.count, 1)
        XCTAssertEqual(compile(customConfig(rules), paused: true).matchers, [])
        XCTAssertEqual(compile(customConfig(rules), killSwitch: true).matchers, [])

        var vpnOnly = customConfig(rules)
        vpnOnly.routingMode = .vpnOnly
        XCTAssertEqual(FlowPolicyCompiler.Input(config: vpnOnly, paused: false, killSwitchActive: false,
                                                physicalInterface: nil, tunnelOwnerTeams: []).mode, .vpnOnly)
        XCTAssertEqual(compile(vpnOnly).matchers, [])

        // Custom on a schema-1 config runs the Bypass engine, so it compiles as Bypass, whose Apps
        // list does not exist yet: nothing is claimed.
        var schema1 = customConfig(rules)
        schema1.schemaVersion = 1
        XCTAssertEqual(FlowPolicyCompiler.Input(config: schema1, paused: false, killSwitchActive: false,
                                                physicalInterface: nil, tunnelOwnerTeams: []).mode, .bypass)
        XCTAssertEqual(compile(schema1).matchers, [])

        var bypass = customConfig(rules)
        bypass.routingMode = .bypass
        XCTAssertEqual(compile(bypass).matchers, [])
    }

    func testPolicyBlobCarriesNoHostNamesOrCredentials() throws {
        let rules = [
            Rule(matchType: .domain, pattern: "intranet.example.com", routeId: direct.id, order: 0),
            Rule(matchType: .process, pattern: "com.example.App", routeId: proxy.id, order: 1),
            Rule(matchType: .process, pattern: "com.example.Other", routeId: exit.id, order: 2),
        ]
        var c = customConfig(rules)
        c.localProxySecret = "local-secret-value"
        let text = String(decoding: try FlowPolicyMessage.encode(compile(c)), as: UTF8.self)
        for secret in ["intranet.example.com", "proxy.example.net", "proxy-user", "proxy-secret-pass",
                       "exit-node.example", "local-secret-value", "utun7", "WireGuard", "Corporate VPN", "Proxy"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into \(text)")
        }
        XCTAssertTrue(text.contains("com.example.App"), text)
    }
}
