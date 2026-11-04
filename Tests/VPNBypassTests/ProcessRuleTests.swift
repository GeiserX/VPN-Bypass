// ProcessRuleTests.swift
// A process rule names an app, and the kernel engine routes destinations only, so until per-app
// routing exists nothing serves it. Every surface says so instead of keeping a silent no-op:
// `rule.add` checks the pattern and says the rule routes nothing yet, `rule.list` carries
// `servedBy` and the reason, the Rules page row has a line, and `why` names the rules.

import XCTest
@testable import VPNBypassCore

final class ProcessRuleTests: XCTestCase {

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VPNBypassCore/Resources")

    private func config(with rules: [Rule] = [], route: Route) -> RouteManager.Config {
        var config = RouteManager.Config()
        config.routes = [route]
        config.rules = rules
        return config
    }

    // MARK: - The pattern (design doc 3.4)

    func testBundleIDsAndExecutableNamesAreAccepted() {
        for pattern in ["com.example.App", "com.example.App.helper", "org.example.my-app", "com.example.App_2", "com.example.app",
                        "Example", "example-agent", "Example Helper"] {
            XCTAssertNil(ProcessRule.invalid(pattern), pattern)
        }
        XCTAssertEqual(ProcessRule.kind(of: "com.example.App"), .bundleID)
        XCTAssertEqual(ProcessRule.kind(of: "Example Helper"), .executableName)
    }

    func testPathsWildcardsAndMalformedPatternsAreRefused() {
        XCTAssertEqual(ProcessRule.invalid(""), .empty)
        XCTAssertEqual(ProcessRule.invalid("/Applications/Example.app/Contents/MacOS/Example"), .path)
        XCTAssertEqual(ProcessRule.invalid("Example/Helper"), .path)
        XCTAssertEqual(ProcessRule.invalid("com.example.*"), .wildcard)
        XCTAssertEqual(ProcessRule.invalid("Exam?le"), .wildcard)
        XCTAssertEqual(ProcessRule.invalid("Example.app"), .appFolder)
        XCTAssertEqual(ProcessRule.invalid("Example Helper.app"), .appFolder)
        XCTAssertEqual(ProcessRule.invalid("com..example"), .badBundleID)
        XCTAssertEqual(ProcessRule.invalid(".example"), .badBundleID)
        XCTAssertEqual(ProcessRule.invalid("com.example."), .badBundleID)
        XCTAssertEqual(ProcessRule.invalid("com.example app.App"), .badBundleID)
        XCTAssertEqual(ProcessRule.invalid(" Example"), .badCharacter)
        XCTAssertEqual(ProcessRule.invalid("Example\n"), .badCharacter)
        XCTAssertEqual(ProcessRule.invalid("Exa\u{7}mple"), .badCharacter)
        XCTAssertEqual(ProcessRule.invalid(String(repeating: "a", count: 256)), .tooLong)
        XCTAssertNil(ProcessRule.invalid(String(repeating: "a", count: 255)), "255 bytes is a file name's limit")
    }

    // MARK: - rule.add

    func testRuleAddRefusesAProcessPathAndDoesNotMutate() {
        let direct = Route(name: "Direct", egress: .direct)
        let config = config(route: direct)
        let (updated, response) = CommandRouter.apply(
            ControlRequest(cmd: "rule.add", args: ["match": "process", "pattern": "/Applications/Example.app",
                                                    "routeId": direct.id.uuidString]), to: config)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_args")
        XCTAssertTrue(response.error?.message.contains("not a path") == true, response.error?.message ?? "")
        XCTAssertTrue(updated.rules.isEmpty)
    }

    func testRuleAddSavesAProcessRuleAndSaysItRoutesNothingYet() throws {
        let direct = Route(name: "Direct", egress: .direct)
        let (updated, response) = CommandRouter.apply(
            ControlRequest(cmd: "rule.add", args: ["match": "process", "pattern": "com.example.App",
                                                    "routeId": direct.id.uuidString]), to: config(route: direct))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(updated.rules.count, 1)
        XCTAssertEqual(response.result?.message, ProcessRule.savedMessage)
        XCTAssertTrue(ProcessRule.savedMessage.contains("only while per-app routing is on and its route is Direct"))
        let rule = try XCTUnwrap(response.result?.rules?.first)
        XCTAssertEqual(rule.servedBy, RuleServedBy.none)
        XCTAssertEqual(rule.inactiveReason, "perAppRoutingNotAvailable")
    }

    /// Positive control: a destination rule gets no such message and is served by the kernel.
    func testRuleAddOfADomainKeepsItsPlainReply() throws {
        let direct = Route(name: "Direct", egress: .direct)
        let (_, response) = CommandRouter.apply(
            ControlRequest(cmd: "rule.add", args: ["match": "domain", "pattern": "example.com",
                                                    "routeId": direct.id.uuidString]), to: config(route: direct))
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.result?.message)
        XCTAssertEqual(response.result?.rules?.first?.servedBy, .kernel)
        XCTAssertNil(response.result?.rules?.first?.inactiveReason)
    }

    // MARK: - rule.list

    func testRuleListSaysWhichEngineServesEachRule() throws {
        let direct = Route(name: "Direct", egress: .direct)
        let rules = [Rule(matchType: .domain, pattern: "example.com", routeId: direct.id, order: 0),
                     Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 1)]
        let (_, response) = CommandRouter.apply(ControlRequest(cmd: "rule.list"), to: config(with: rules, route: direct))
        let listed = try XCTUnwrap(response.result?.rules)
        XCTAssertEqual(listed.map(\.servedBy), [.kernel, RuleServedBy.none])
        XCTAssertEqual(listed.map(\.inactiveReason), [nil, "perAppRoutingNotAvailable"])

        let json = VPNBCLI.renderJSON(response)
        XCTAssertTrue(json.contains(#""servedBy":"kernel""#), json)
        XCTAssertTrue(json.contains(#""inactiveReason":"perAppRoutingNotAvailable","matchType":"process""#), json)
        XCTAssertTrue(json.contains(#""servedBy":"none""#), json)

        let lines = VPNBCLI.textLines(response)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].contains("inactive"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("enabled  inactive: needs per-app routing, which is not available yet"), lines[1])
    }

    /// A reply from an older app has neither field; it still decodes, and the line has no note.
    func testAnOlderReplyWithoutServedByStillDecodes() throws {
        let id = UUID()
        let json = #"{"v":1,"ok":true,"result":{"rules":[{"id":"\#(id)","matchType":"process","pattern":"Example","routeId":"\#(id)","enabled":true,"order":0}]}}"#
        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.result?.rules?.first?.servedBy)
        XCTAssertFalse(VPNBCLI.textLines(response)[0].contains("inactive"))
    }

    func testAnUnknownReasonIsPrintedAsItCame() {
        XCTAssertEqual(ProcessRule.inactiveNote(reason: "perAppRoutingSomethingNew"), "inactive: perAppRoutingSomethingNew")
        XCTAssertEqual(ProcessRule.inactiveNote(reason: "perAppRoutingOff"), "inactive: per-app routing is off")
        XCTAssertEqual(ProcessRule.inactiveNote(reason: nil), "inactive")
    }

    // MARK: - The Rules page

    func testTheRowOfAProcessRuleSaysItDoesNothing() {
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        let app = Rule(matchType: .process, pattern: "com.example.App", routeId: proxy.id, order: 0)
        XCTAssertEqual(RuleRow.detail(for: app, route: Route(name: "Direct", egress: .direct)),
                       "Needs per-app routing, which is not available yet, so this rule does nothing.")
        XCTAssertEqual(RuleRow.detail(for: app, route: proxy), ProcessRule.rowNote(.perAppRoutingNotAvailable),
                       "a rule that does nothing reaches no app, so the proxy note gives way")
        // Positive controls: a destination rule keeps the proxy note, or no line.
        let domain = Rule(matchType: .domain, pattern: "example.com", routeId: proxy.id, order: 1)
        XCTAssertEqual(RuleRow.detail(for: domain, route: proxy), ProxyReachNote.forRoute(proxy)?.line())
        XCTAssertNil(RuleRow.detail(for: domain, route: Route(name: "Direct", egress: .direct)))
    }

    func testTheNewLinesAreTranslated() throws {
        let es = try XCTUnwrap(Bundle(url: Self.resources.appendingPathComponent("es.lproj")))
        let fr = try XCTUnwrap(Bundle(url: Self.resources.appendingPathComponent("fr.lproj")))
        XCTAssertEqual(ProcessRule.rowNote(.perAppRoutingNotAvailable, in: es),
                       "Necesita el enrutamiento por app, que aún no está disponible, así que esta regla no hace nada.")
        XCTAssertEqual(ProcessRule.localizedMessage(in: fr),
                       "Saisissez l'identifiant de paquet d'une app (com.example.App) ou le nom de son exécutable (Example), sans chemin ni joker.")
        XCTAssertEqual(SiteRoute.inactiveAppRulesSentence(["Example"], in: es),
                       "Las reglas de apps (Example) aún no cambian nada: necesitan el enrutamiento por app, que aún no está disponible.")
    }

    // MARK: - why

    private func customSnapshot(rules: [Rule], routes: [Route], defaultRouteId: UUID?) -> SiteRoute.Snapshot {
        SiteRoute.Snapshot(mode: .custom, custom: true, list: [], services: [], rules: rules, routes: routes,
                           defaultRouteId: defaultRouteId, activeRoutes: [], localGateway: "192.168.1.1",
                           vpnInterface: "utun4")
    }

    /// A host only a process rule is about: it takes the default route, and the answer names the
    /// app rules that change nothing for it yet.
    func testWhyNamesTheProcessRulesThatChangeNothingYet() throws {
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault)
        let rules = [Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0),
                     Rule(matchType: .process, pattern: "Example", routeId: direct.id, enabled: false, order: 1)]
        let s = customSnapshot(rules: rules, routes: [direct, vpn], defaultRouteId: vpn.id)
        let found = SiteRoute.match(host: "app.example.com", addresses: ["203.0.113.7"], in: s)
        XCTAssertEqual(found.match, .defaultRoute)
        XCTAssertEqual(found.inactiveAppRules, ["com.example.App"], "a switched-off rule is not named")

        let probe = PathCheck.Probe(address: "203.0.113.7", routeInterface: "utun4", sourceAddress: "10.8.0.2",
                                    sourceInterface: "utun4", answer: .connected, latencyMs: 20)
        let answer = SiteRoute.answer(host: "app.example.com", mode: .custom, addresses: ["203.0.113.7"],
                                      found: found, probes: [probe], control: nil, vpnConnected: true)
        XCTAssertEqual(answer.inactiveAppRules, ["com.example.App"])
        XCTAssertTrue(answer.summary.hasSuffix(
            "Rules for apps (com.example.App) change nothing yet: they need per-app routing, which is not available yet."),
            answer.summary)
        XCTAssertTrue(VPNBCLI.whyLines(answer).last?.contains("inactive app rules: com.example.App") == true)
    }

    /// Every Custom answer names the app rules, not only the rule and default ones: an installed
    /// route, an unresolved name and a pause decide before the rules loop.
    func testWhyNamesProcessRulesWhateverDecidedTheName() {
        let direct = Route(name: "Direct", egress: .direct)
        let rules = [Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)]
        var s = customSnapshot(rules: rules, routes: [direct], defaultRouteId: direct.id)
        s.activeRoutes = [(destination: "203.0.113.7", gateway: "192.168.1.1", source: "203.0.113.7")]
        let installed = SiteRoute.match(host: "app.example.com", addresses: ["203.0.113.7"], in: s)
        XCTAssertEqual(installed.match, .route)
        XCTAssertEqual(installed.inactiveAppRules, ["com.example.App"])

        let unresolved = SiteRoute.match(host: "app.example.com", addresses: [], in: s)
        XCTAssertEqual(unresolved.match, .unresolved)
        XCTAssertEqual(unresolved.inactiveAppRules, ["com.example.App"])

        var bypass = s
        bypass.custom = false
        XCTAssertEqual(SiteRoute.match(host: "app.example.com", addresses: ["203.0.113.7"], in: bypass).inactiveAppRules, [],
                       "outside Custom no rule is in force, so none is named")
    }

    /// Positive control: with no process rule, the answer carries no such field or sentence.
    func testWhyWithoutProcessRulesSaysNothingAboutApps() {
        let direct = Route(name: "Direct", egress: .direct)
        let s = customSnapshot(rules: [Rule(matchType: .domain, pattern: "example.com", routeId: direct.id, order: 0)],
                               routes: [direct], defaultRouteId: direct.id)
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.7"], in: s)
        XCTAssertEqual(found.match, .rule)
        let answer = SiteRoute.answer(host: "example.com", mode: .custom, addresses: ["203.0.113.7"],
                                      found: found, probes: [], control: nil, vpnConnected: true)
        XCTAssertNil(answer.inactiveAppRules)
        XCTAssertFalse(answer.summary.contains("per-app"), answer.summary)
    }
}
