import XCTest
@testable import VPNBypassPolicy

final class FlowPolicyCompilerTests: XCTestCase {
    typealias C = FlowPolicyCompiler
    let vpn = C.Route(id: UUID(), kind: .vpnPrimary)
    let direct = C.Route(id: UUID(), kind: .direct)
    let pinned = C.Route(id: UUID(), kind: .vpnPinned)
    let tailscale = C.Route(id: UUID(), kind: .tailscaleExit)
    let proxy = C.Route(id: UUID(), kind: .proxy)
    let directOff = C.Route(id: UUID(), kind: .direct, enabled: false)
    var routes: [C.Route] { [vpn, direct, pinned, tailscale, proxy, directOff] }

    func rule(_ pattern: String, _ route: C.Route, order: Int, enabled: Bool = true) -> C.ProcessRule {
        C.ProcessRule(id: UUID(), pattern: pattern, routeID: route.id, enabled: enabled, order: order)
    }

    func compile(_ input: C.Input) -> FlowPolicy { C.compile(input, generation: 3) }

    func testCustomRoutesCompileToTheirEgress() {
        let rules = [
            rule("com.example.Direct", direct, order: 0),
            rule("com.example.VPN", vpn, order: 1),
            rule("com.example.Pinned", pinned, order: 2),
            rule("com.example.Tailscale", tailscale, order: 3),
            rule("com.example.Proxy", proxy, order: 4),
            rule("ExampleTool", direct, order: 5),
        ]
        let p = compile(C.Input(mode: .custom, processRules: rules, routes: routes, physicalInterface: "en1"))
        XCTAssertEqual(p.matchers, [
            AppMatcher(ruleID: rules[0].id.uuidString, kind: .bundleID, pattern: "com.example.Direct", egress: .direct(interface: "en1")),
            AppMatcher(ruleID: rules[1].id.uuidString, kind: .bundleID, pattern: "com.example.VPN", egress: .vpnDefault),
            AppMatcher(ruleID: rules[2].id.uuidString, kind: .bundleID, pattern: "com.example.Pinned", egress: .unsupported),
            AppMatcher(ruleID: rules[3].id.uuidString, kind: .bundleID, pattern: "com.example.Tailscale", egress: .unsupported),
            AppMatcher(ruleID: rules[4].id.uuidString, kind: .bundleID, pattern: "com.example.Proxy", egress: .unsupported),
            AppMatcher(ruleID: rules[5].id.uuidString, kind: .executableName, pattern: "ExampleTool", egress: .direct(interface: "en1")),
        ])
        XCTAssertEqual(p.generation, 3)
        XCTAssertEqual(p.version, FlowPolicy.currentVersion)
        XCTAssertEqual(p.leaseSeconds, FlowPolicy.defaultLeaseSeconds)
    }

    func testCustomKeepsFirstMatchOrderByOrderThenListPosition() {
        let a = rule("a.a", direct, order: 5)
        let b = rule("b.b", direct, order: 1)
        let c = rule("c.c", direct, order: 5)
        let d = rule("d.d", direct, order: 0)
        let p = compile(C.Input(mode: .custom, processRules: [a, b, c, d], routes: routes))
        XCTAssertEqual(p.matchers.map(\.pattern), ["d.d", "b.b", "a.a", "c.c"])
    }

    func testCustomSkipsRulesThatMatchNothing() {
        let rules = [
            rule("com.example.Off", direct, order: 0, enabled: false),
            rule("com.example.RouteOff", directOff, order: 1),
            C.ProcessRule(id: UUID(), pattern: "com.example.NoRoute", routeID: UUID(), order: 2),
            rule("   ", direct, order: 3),
            rule("  com.example.Kept \n", direct, order: 4),
        ]
        let p = compile(C.Input(mode: .custom, processRules: rules, routes: routes))
        XCTAssertEqual(p.matchers.map(\.pattern), ["com.example.Kept"])
    }

    func testNoPhysicalInterfaceLetsTheExtensionPick() {
        for iface in [nil, ""] as [String?] {
            let p = compile(C.Input(mode: .custom, processRules: [rule("a.b", direct, order: 0)], routes: routes,
                                    physicalInterface: iface))
            XCTAssertEqual(p.matchers.first?.egress, .direct(interface: nil))
        }
    }

    func testBypassAppsCompileToTheSameMatchersAsCustomDirectRules() {
        let apps = ["com.example.App", "ExampleTool"]
        let bypass = compile(C.Input(mode: .bypass, bypassApps: apps, physicalInterface: "en0"))
        let custom = compile(C.Input(mode: .custom, processRules: apps.enumerated().map { rule($1, direct, order: $0) },
                                     routes: routes, physicalInterface: "en0"))
        XCTAssertEqual(bypass.matchers.map { [$0.pattern, "\($0.kind)", "\($0.egress)"] },
                       custom.matchers.map { [$0.pattern, "\($0.kind)", "\($0.egress)"] })
        XCTAssertEqual(bypass.matchers.map(\.ruleID), ["bypass-app-0", "bypass-app-1"])
    }

    func testBypassAppsTrimmedAndDeduplicated() {
        let p = compile(C.Input(mode: .bypass, bypassApps: [" com.example.App", "", "com.example.App", "Tool"]))
        XCTAssertEqual(p.matchers.map(\.pattern), ["com.example.App", "Tool"])
    }

    func testBypassIgnoresCustomRulesAndCustomIgnoresBypassApps() {
        let r = [rule("com.example.Custom", direct, order: 0)]
        XCTAssertEqual(compile(C.Input(mode: .bypass, processRules: r, routes: routes)).matchers, [])
        XCTAssertEqual(compile(C.Input(mode: .custom, routes: routes, bypassApps: ["com.example.App"])).matchers, [])
    }

    func testStandDownStatesCompileToNoMatchers() {
        let r = [rule("com.example.App", direct, order: 0)]
        let apps = ["com.example.App"]
        let table: [(C.Input, String)] = [
            (C.Input(mode: .vpnOnly, processRules: r, routes: routes, bypassApps: apps), "VPN Only"),
            (C.Input(mode: .custom, processRules: r, routes: routes, paused: true), "Pause, Custom"),
            (C.Input(mode: .bypass, bypassApps: apps, paused: true), "Pause, Bypass"),
            (C.Input(mode: .custom, processRules: r, routes: routes, killSwitchActive: true), "kill switch, Custom"),
            (C.Input(mode: .bypass, bypassApps: apps, killSwitchActive: true), "kill switch, Bypass"),
        ]
        for (input, label) in table {
            let p = compile(input)
            XCTAssertEqual(p.matchers, [], label)
            XCTAssertTrue(p.claimsNothing, label)
        }
    }

    func testTunnelOwnerTeamsCarriedOnceEach() {
        let p = compile(C.Input(mode: .vpnOnly, tunnelOwnerTeams: ["TEAM000001", " ", "TEAM000002", "TEAM000001"]))
        XCTAssertEqual(p.declinedTeams, ["TEAM000001", "TEAM000002"])
    }

    func testCompiledPolicyDecidesEndToEnd() {
        // A VPN rule for the parent app in front of a Direct rule for its helper: the helper stays in
        // the VPN, as first match says; a Direct rule further down still serves its own app.
        let rules = [rule("com.example.App", vpn, order: 0), rule("com.example.App.helper", direct, order: 1),
                     rule("com.example.Other", direct, order: 2)]
        let p = compile(C.Input(mode: .custom, processRules: rules, routes: routes, physicalInterface: "en0"))
        var s = FlowPolicyState()
        let now = Date()
        s.receive(FlowPolicyMessage.decode(try! FlowPolicyMessage.encode(p)), at: now)
        let ip = FlowFacts.Remote.ipv4(ProtectedRanges.parse("93.184.216.34")!)
        XCTAssertEqual(FlowDecider.decide(FlowFacts(signingIdentifier: "com.example.App.helper", remote: ip), state: s, now: now),
                       .decline(.vpnRoute, ruleID: rules[0].id.uuidString))
        XCTAssertEqual(FlowDecider.decide(FlowFacts(signingIdentifier: "com.example.Other", remote: ip), state: s, now: now),
                       .claim(ruleID: rules[2].id.uuidString, egress: .direct(interface: "en0")))
    }
}
