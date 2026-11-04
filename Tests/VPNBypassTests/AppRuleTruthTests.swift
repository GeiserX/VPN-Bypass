// AppRuleTruthTests.swift
// Every place that shows a rule for an app says what per-app routing really does with it: the
// mode it serves process rules in, the replies an older `vpnb` still reads, the Status and
// dropdown sentence, the Apps list's verbs and checks, and Site Check's offer.

import XCTest
@testable import VPNBypassCore
import VPNBypassPolicy

final class AppRuleTruthTests: XCTestCase {
    private let direct = Route(name: "Direct", egress: .direct)

    private func config(mode: RoutingMode, schema: Int = 2) -> Config {
        var c = Config()
        c.schemaVersion = schema
        c.routingMode = mode
        c.routes = [direct]
        return c
    }

    // MARK: - (d) The mode decides whether a process rule can be served

    /// Per-app routing compiles process rules in Custom mode only, so in Bypass mode (and in
    /// Custom on a schema-1 config, which runs as Bypass) none is served, whatever the engine.
    func testAProcessRuleIsServedOnlyWhileCustomRulesRun() {
        let app = Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)
        let custom = config(mode: .custom)
        XCTAssertEqual(ProcessRule.serving(app, engine: .active, config: custom).servedBy, .perAppEngine)
        for other in [config(mode: .bypass), config(mode: .vpnOnly), config(mode: .custom, schema: 1)] {
            let serving = ProcessRule.serving(app, engine: .active, config: other)
            XCTAssertEqual(serving.servedBy, RuleServedBy.none, "\(other.routingMode) schema \(other.schemaVersion)")
            XCTAssertEqual(serving.reason, .notInCustomMode)
            // The compiler agrees: no matcher for the rule in that mode.
            var withRule = other
            withRule.rules = [app]
            let input = FlowPolicyCompiler.Input(config: withRule, paused: false, killSwitchActive: false,
                                                 physicalInterface: "en0", tunnelOwnerTeams: [])
            XCTAssertFalse(FlowPolicyCompiler.compile(input, generation: 1).matchers.contains { $0.ruleID == app.id.uuidString })
        }
        // A build without per-app routing says that first: it is the reason in every mode.
        XCTAssertEqual(ProcessRule.serving(app, engine: .unavailable(.notInThisBuild), config: config(mode: .bypass)).reason,
                       .perAppRoutingNotAvailable)
        // A destination rule stays the kernel's.
        let domain = Rule(matchType: .domain, pattern: "example.com", routeId: direct.id, order: 1)
        XCTAssertEqual(ProcessRule.serving(domain, engine: .active, config: config(mode: .bypass)).servedBy, .kernel)
    }

    func testRuleListAndTheRulesPageNeverSayServedOutsideCustomMode() {
        let app = Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)
        let rule = SanitizedRule(app, engine: .active, routes: [direct], customEngine: false)
        XCTAssertEqual(rule.servedBy, RuleServedBy.none)
        XCTAssertEqual(rule.inactiveReason, "notInCustomMode")
        let line = VPNBCLI.textLines(ControlResponse(ok: true, result: ControlResult(rules: [rule])))[0]
        XCTAssertFalse(line.contains("served by per-app routing"))
        XCTAssertTrue(line.hasSuffix("inactive: rules for apps work in Custom mode"), line)
        XCTAssertEqual(RuleRow.detail(for: app, route: direct, engine: .active, customEngine: false),
                       "Inactive: rules for apps work in Custom mode.")
        XCTAssertEqual(RuleRow.detail(for: app, route: direct, engine: .active, customEngine: true),
                       ProcessRule.rowNote(nil))
    }

    // MARK: - (f) An older vpnb reads a reply from a later app

    func testAnUnknownServedByDecodesAsNilInsteadOfFailingTheReply() throws {
        let id = UUID(), route = UUID()
        let rule = """
            {"id":"\(id)","matchType":"process","pattern":"com.example.App","routeId":"\(route)",
             "enabled":true,"order":0,"servedBy":"someLaterEngine","inactiveReason":"aLaterReason"}
            """
        let decoded = try JSONDecoder().decode(SanitizedRule.self, from: Data(rule.utf8))
        XCTAssertNil(decoded.servedBy)
        XCTAssertEqual(decoded.inactiveReason, "aLaterReason")
        XCTAssertEqual(decoded.pattern, "com.example.App")
        // A known value and a missing one decode as before.
        let known = try JSONDecoder().decode(SanitizedRule.self, from: Data(rule.replacingOccurrences(of: "someLaterEngine", with: "kernel").utf8))
        XCTAssertEqual(known.servedBy, .kernel)
        let old = """
            {"id":"\(id)","matchType":"domain","pattern":"example.com","routeId":"\(route)","enabled":true,"order":0}
            """
        XCTAssertNil(try JSONDecoder().decode(SanitizedRule.self, from: Data(old.utf8)).servedBy)
        // The Apps list's entries too.
        let app = """
            {"id":"\(id)","pattern":"com.example.App","enabled":true,"servedBy":"someLaterEngine"}
            """
        let decodedApp = try JSONDecoder().decode(ControlApp.self, from: Data(app.utf8))
        XCTAssertNil(decodedApp.servedBy)
        XCTAssertEqual(decodedApp.pattern, "com.example.App")
        // And the whole reply survives it.
        let reply = """
            {"v":1,"ok":true,"result":{"rules":[\(rule)]}}
            """
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: Data(reply.utf8)).result?.rules?.count, 1)
        // A round trip keeps every field.
        let original = SanitizedRule(Rule(matchType: .process, pattern: "com.example.App", routeId: route, order: 3),
                                     engine: .active, routes: [Route(id: route, name: "Direct", egress: .direct)])
        XCTAssertEqual(try JSONDecoder().decode(SanitizedRule.self, from: JSONEncoder().encode(original)), original)
    }

    // MARK: - (c) The Status and dropdown sentence counts app rules apart

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func lproj(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(url: Self.root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    private func custom(rules: Int, apps: Int = 0, served: Int = 0, waiting: Int = 0) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(isVPNConnected: true, vpnName: nil, helperReady: true, mode: .custom,
                                     enabledServices: 0, enabledDomains: 0, enabledRules: rules,
                                     installedRoutes: 10, pending: nil, lastRouteChange: nil,
                                     lastDNSRefresh: nil, nextDNSRefresh: nil, autoDNSRefresh: true)
        i.enabledAppRules = apps
        i.servedAppRules = served
        i.waitingAppRules = waiting
        return i
    }

    func testTheSentenceCountsOnlyServedAppRulesAsDecidingAnything() throws {
        let en = try lproj("en")
        func says(_ i: DropdownStatus.Input) -> String { DropdownStatus.whatIsRouted(i, bundle: en) }
        // No app rules: the sentence is the one it always was.
        XCTAssertEqual(says(custom(rules: 0)), "No rules yet.")
        XCTAssertEqual(says(custom(rules: 3)), "3 rules decide where traffic goes.")
        // Two destination rules and one app rule per-app routing does not serve yet.
        XCTAssertEqual(says(custom(rules: 3, apps: 1, waiting: 1)),
                       "2 destination rules decide where traffic goes. 1 app rule waits for per-app routing.")
        // Only app rules, none served: never "No rules yet.", never "decide where traffic goes".
        XCTAssertEqual(says(custom(rules: 2, apps: 2, waiting: 2)), "2 app rules wait for per-app routing.")
        XCTAssertEqual(says(custom(rules: 1, apps: 1)), "1 app rule does nothing: the Rules page says why.")
        // Served app rules count as deciding.
        XCTAssertEqual(says(custom(rules: 3, apps: 2, served: 2)),
                       "1 destination rule and 2 app rules decide where traffic goes.")
        XCTAssertEqual(says(custom(rules: 1, apps: 1, served: 1)), "1 app rule decides where traffic goes.")
        XCTAssertEqual(says(custom(rules: 4, apps: 3, served: 1, waiting: 1)),
                       "1 destination rule and 1 app rule decide where traffic goes. 1 app rule waits for per-app routing. 1 app rule does nothing: the Rules page says why.")
        // Spanish and French too.
        XCTAssertEqual(DropdownStatus.whatIsRouted(custom(rules: 3, apps: 1, waiting: 1), bundle: try lproj("es")),
                       "2 reglas de destino deciden adónde va el tráfico. 1 regla de app espera al enrutamiento por app.")
        XCTAssertEqual(DropdownStatus.whatIsRouted(custom(rules: 2, apps: 2, waiting: 2), bundle: try lproj("fr")),
                       "2 règles d'app attendent le routage par app.")
    }

    /// The counts come from `ProcessRule.serving`, so the sentence and the Rules page agree.
    func testTheCountsFollowWhatTheEngineServes() {
        let vpn = Route(name: "VPN", egress: .vpnDefault)
        var c = config(mode: .custom)
        c.routes = [direct, vpn]
        c.rules = [
            Rule(matchType: .domain, pattern: "example.com", routeId: direct.id, order: 0),
            Rule(matchType: .process, pattern: "com.example.A", routeId: direct.id, order: 1),
            Rule(matchType: .process, pattern: "com.example.B", routeId: vpn.id, order: 2),
            Rule(matchType: .process, pattern: "com.example.Off", routeId: direct.id, enabled: false, order: 3),
        ]
        var input = custom(rules: 3)
        input.countAppRules(c.rules, config: c, engine: .active)
        XCTAssertEqual([input.enabledAppRules, input.servedAppRules, input.waitingAppRules], [2, 1, 0])
        input.countAppRules(c.rules, config: c, engine: .off)
        XCTAssertEqual([input.enabledAppRules, input.servedAppRules, input.waitingAppRules], [2, 0, 1])
        XCTAssertEqual(DropdownStatus.whatIsRouted(input),
                       "1 destination rule decides where traffic goes. 1 app rule waits for per-app routing. 1 app rule does nothing: the Rules page says why.")
    }

    /// Served app rules alone route nothing through the table, yet they are working.
    func testServedAppRulesAloneAreNotNothingRouted() {
        var only = custom(rules: 2, apps: 2, served: 2)
        only.installedRoutes = 0
        XCTAssertNotEqual(DropdownStatus.make(only, now: Date()).chip, .notRouting)
        var waiting = custom(rules: 2, apps: 2, waiting: 2)
        waiting.installedRoutes = 0
        XCTAssertEqual(DropdownStatus.make(waiting, now: Date()).chip, .notRouting)
    }

    // MARK: - (j) Site Check offers Send Direct only where it would change something

    func testSendDirectIsHiddenWhenTheDefaultRouteIsAlreadyDirect() {
        let vpn = Route(name: "Corp VPN", egress: .vpnDefault)
        func answer(default route: Route) -> SiteRouteAnswer {
            let s = SiteRoute.Snapshot(mode: .custom, custom: true, list: [], services: [], rules: [],
                                       routes: [direct, vpn], defaultRouteId: route.id, activeRoutes: [],
                                       localGateway: "192.168.1.1", vpnInterface: "utun4")
            let found = SiteRoute.match(host: "example.org", addresses: ["203.0.113.5"], in: s)
            return SiteRoute.answer(host: "example.org", mode: .custom, addresses: ["203.0.113.5"], found: found,
                                    probes: [], control: nil, vpnConnected: true)
        }
        let goesDirect = answer(default: direct)
        XCTAssertEqual(goesDirect.match, .defaultRoute)
        XCTAssertFalse(goesDirect.canAdd)
        XCTAssertNil(StatusPage.siteAdd(goesDirect, mode: .custom))
        // Everything else into the VPN: Send Direct is the way out, as before.
        let intoVPN = answer(default: vpn)
        XCTAssertTrue(intoVPN.canAdd)
        XCTAssertEqual(StatusPage.siteAdd(intoVPN, mode: .custom)?.title, "Send Direct")
    }

    // MARK: - (e) The dropdown's list joins in the app's language

    func testTheAppsListSentenceJoinsInTheAppsLanguageNotTheSystems() throws {
        var bypass = custom(rules: 0)
        bypass.mode = .bypass
        bypass.enabledServices = 2
        bypass.enabledDomains = 1
        bypass.enabledApps = 3
        bypass.appsServed = true
        // The test runs with an English system locale: the joiner still follows the bundle.
        XCTAssertEqual(DropdownStatus.whatIsRouted(bypass, bundle: try lproj("es")), "2 servicios, 1 dominio y 3 apps evitan la VPN.")
        XCTAssertTrue(DropdownStatus.whatIsRouted(bypass, bundle: try lproj("fr")).contains(" et 3 apps"))
        XCTAssertTrue(DropdownStatus.whatIsRouted(bypass, bundle: try lproj("en")).contains("and 3 apps"))
        XCTAssertEqual(AppLanguage.code(of: try lproj("fr")), "fr")
    }
}


// MARK: - The Apps list from a script and from the chooser

@MainActor
final class AppListVerbTests: XCTestCase {
    private var savedConfig: RouteManager.Config!
    private var savedLookup: ((String) -> AppIdentity?)!
    private var savedEngineState: (@MainActor () -> FlowEngineState)!

    override func setUp() async throws {
        let rm = RouteManager.shared
        savedConfig = rm.config
        savedLookup = BypassApps.lookup
        savedEngineState = ClassicControl.engineState
        BypassApps.lookup = { _ in nil }
        ClassicControl.engineState = { .active }
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.services = []
        rm.config = cfg
    }

    override func tearDown() async throws {
        RouteManager.shared.config = savedConfig
        BypassApps.lookup = savedLookup
        ClassicControl.engineState = savedEngineState
    }

    private var rm: RouteManager { RouteManager.shared }

    private func send(_ cmd: String, _ args: [String: String]? = nil) async -> ControlResponse {
        await ControlSurface.handle(ControlRequest(cmd: cmd, args: args))
    }

    // (g)
    func testAppEnableAndDisableFlipTheRowsSwitch() async {
        let added = await send("app.add", ["pattern": "com.example.Browser"])
        XCTAssertTrue(added.ok)
        let id = try? XCTUnwrap(added.result?.apps?.first?.id)

        let off = await send("app.disable", ["pattern": "com.example.Browser"])
        XCTAssertTrue(off.ok, "\(String(describing: off.error))")
        XCTAssertEqual(rm.config.bypassApps.first?.enabled, false)
        XCTAssertEqual(off.result?.apps?.first?.enabled, false)
        XCTAssertEqual(off.result?.apps?.first?.servedBy, RuleServedBy.none)
        XCTAssertEqual(rm.lastOutsideChange?.kind, .turnedOff("com.example.Browser"))
        // The compiled policy drops it.
        let input = FlowPolicyCompiler.Input(config: rm.config, paused: false, killSwitchActive: false,
                                             physicalInterface: "en0", tunnelOwnerTeams: [])
        XCTAssertTrue(FlowPolicyCompiler.compile(input, generation: 1).matchers.isEmpty)

        let on = await send("app.enable", ["id": id?.uuidString ?? ""])
        XCTAssertTrue(on.ok)
        XCTAssertEqual(rm.config.bypassApps.first?.enabled, true)
        XCTAssertEqual(on.result?.apps?.first?.servedBy, .perAppEngine)
        XCTAssertNil(on.result?.message)
        XCTAssertEqual(rm.lastOutsideChange?.kind, .turnedOn("com.example.Browser"))

        // Turned on while per-app routing is off: the reply says the app still uses the VPN.
        ClassicControl.engineState = { .off }
        _ = await send("app.disable", ["pattern": "com.example.Browser"])
        let waiting = await send("app.enable", ["pattern": "com.example.Browser"])
        XCTAssertTrue(waiting.result?.message?.contains("uses the VPN") == true)

        let missing = await send("app.enable", ["pattern": "com.example.Nothing"])
        XCTAssertEqual(missing.error?.code, "not_found")
        let both = await send("app.disable", ["pattern": "com.example.Browser", "id": UUID().uuidString])
        XCTAssertEqual(both.error?.code, "invalid_args")
        let none = await send("app.enable")
        XCTAssertEqual(none.error?.code, "invalid_args")
        XCTAssertTrue(CommandRouter.isMutating("app.enable"))
        XCTAssertTrue(CommandRouter.isMutating("app.disable"))
        XCTAssertTrue(ClassicControl.verbs.isSuperset(of: ["app.enable", "app.disable"]))
    }

    // (h) The chooser takes a typed executable name.
    func testTheChooserHandsBackATypedNameOrThePickedApp() {
        let app = BypassApps.Candidate(url: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example",
                                       bundleID: "com.example.Example", isRunning: false)
        XCTAssertEqual(AppChooserSheet.pick(row: app, typed: ""), .app(app))
        XCTAssertEqual(AppChooserSheet.pick(row: nil, typed: "  example-tool "), .name("example-tool"))
        XCTAssertEqual(AppChooserSheet.pick(row: app, typed: "example-tool"), .name("example-tool"))
        XCTAssertNil(AppChooserSheet.pick(row: nil, typed: ""))
        // A name a rule cannot match is never handed back, and the field says why.
        XCTAssertNil(AppChooserSheet.pick(row: app, typed: "/usr/bin/example-tool"))
        XCTAssertNil(AppChooserSheet.pick(row: nil, typed: "example*"))
        XCTAssertEqual(AppChooserSheet.typedError("/usr/bin/example-tool"), ProcessRule.localizedMessage())
        XCTAssertNil(AppChooserSheet.typedError("example-tool"))
        XCTAssertNil(AppChooserSheet.typedError(""))
    }

    // (a) The Rules page's App match: the Apps list's validation and refusals.
    func testTheRuleEditorChecksAnAppRuleAsTheAppsListDoes() throws {
        let vpnApp = AppIdentity(name: "Example VPN", signingID: "com.example.vpn", team: "PXPZ95SK77", bundleID: "com.example.vpn")
        let mail = AppIdentity(name: "Mail", signingID: "com.example.Mail", team: "ABCDE12345", bundleID: "com.example.mail")
        BypassApps.lookup = { id in
            switch id.lowercased() {
            case "com.example.vpn": return vpnApp
            case "com.example.mail": return mail
            default: return nil
            }
        }
        func save(_ p: String, chosen: AppIdentity? = nil, previous: String? = nil) -> ProcessRule.EditorValue {
            ProcessRule.editorValue(p, chosen: chosen, previous: previous)
        }
        // An executable name and an app picked in the chooser are saved as they are.
        XCTAssertEqual(save("example-tool"), .save("example-tool"))
        XCTAssertEqual(save("com.example.Mail", chosen: mail), .save("com.example.Mail"))
        // A bundle id typed in another case is stored as the app's signing id.
        XCTAssertEqual(save("com.example.mail"), .save("com.example.Mail"))
        // Not a pattern a rule can match.
        XCTAssertEqual(save("/Applications/Mail.app"), .refuse(ProcessRule.localizedMessage()))
        XCTAssertEqual(save("Mail.app"), .refuse(ProcessRule.localizedMessage()))
        // A VPN client, picked or typed, and VPN Bypass itself are refused with the Apps list's line.
        XCTAssertEqual(save("com.example.vpn", chosen: vpnApp), .refuse(BypassAppError.vpnClient("Example VPN").localizedMessage()))
        XCTAssertEqual(save("com.example.vpn"), .refuse(BypassAppError.vpnClient("Example VPN").localizedMessage()))
        XCTAssertEqual(save("com.geiserx.vpn-bypass"), .refuse(BypassAppError.ownApp.localizedMessage()))
        // A pick edited by hand afterwards is checked as what was typed.
        XCTAssertEqual(save("example-tool", chosen: vpnApp), .save("example-tool"))
    }

    // (i) An entry the extension will turn down says so on its row and in app.list.
    func testAnEntryTheExtensionTurnsDownSaysSo() async throws {
        // Added by id while the app was not installed: no team to check, so the add passes.
        let added = await send("app.add", ["pattern": "com.example.vpn"])
        XCTAssertTrue(added.ok)
        XCTAssertEqual(added.result?.apps?.first?.servedBy, .perAppEngine)
        // Installed now, signed by a VPN vendor's team.
        BypassApps.lookup = { id in
            id == "com.example.vpn" ? AppIdentity(name: "Example VPN", signingID: "com.example.vpn", team: "PXPZ95SK77",
                                                  bundleID: "com.example.vpn") : nil
        }
        let list = await send("app.list")
        XCTAssertEqual(list.result?.apps?.first?.servedBy, RuleServedBy.none)
        XCTAssertEqual(list.result?.apps?.first?.inactiveReason, "vpnClientApp")
        let line = try XCTUnwrap(VPNBCLI.textLines(list).first { $0.contains("com.example.vpn") })
        XCTAssertFalse(line.contains("served by per-app routing"))
        XCTAssertTrue(line.contains("turned down: a VPN or network security app keeps its own path"), line)
        let entry = try XCTUnwrap(rm.config.bypassApps.first)
        XCTAssertTrue(BypassApps.isTurnedDown(entry))
        let row = try XCTUnwrap(AppsPage.rows([entry], engine: .active, listIsLive: true, search: "",
                                              turnedDown: { BypassApps.isTurnedDown($0) }).first)
        XCTAssertFalse(row.isServed)
        XCTAssertTrue(row.detail?.contains(ProcessRule.rowNote(.vpnClientApp)) == true)

        // The add by id checks the team when the app is installed.
        _ = await send("app.rm", ["pattern": "com.example.vpn"])
        let refused = await send("app.add", ["pattern": "com.example.vpn"])
        XCTAssertEqual(refused.error?.code, "refused")

        // A team that owns a live tunnel is turned down too (FlowPolicy.declinedTeams).
        BypassApps.lookup = { id in
            id == "com.example.Tunnel" ? AppIdentity(name: "Tunnel", signingID: id, team: "TUNNEL1234", bundleID: id) : nil
        }
        let tunnelApp = BypassApp(pattern: "com.example.Tunnel")
        XCTAssertFalse(BypassApps.isTurnedDown(tunnelApp))
        XCTAssertTrue(BypassApps.isTurnedDown(tunnelApp, declinedTeams: ["TUNNEL1234"]))
        ClassicControl.declinedTeams = { ["TUNNEL1234"] }
        defer { ClassicControl.declinedTeams = { FlowEngineManager.shared.confirmed?.declinedTeams ?? [] } }
        rm.config.bypassApps = [tunnelApp]
        let withTunnel = await send("app.list")
        XCTAssertEqual(withTunnel.result?.apps?.first?.inactiveReason, "vpnClientApp")
        // An executable name names no app: nothing to read, so it is not marked.
        XCTAssertFalse(BypassApps.isTurnedDown(BypassApp(pattern: "example-tool"), declinedTeams: ["TUNNEL1234"]))
    }
}

