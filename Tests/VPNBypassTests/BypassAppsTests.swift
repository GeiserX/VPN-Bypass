// BypassAppsTests.swift
// Bypass mode's Apps list (design doc, step 7): the entry and its config field, what it compiles
// to in the per-app policy, the checks on an add, the list methods and their undo, the switch to
// Custom, profiles, `vpnb app.*`, the Apps page's words and the counts in the dropdown and Status.

import XCTest
@testable import VPNBypassCore
import VPNBypassPolicy

@MainActor
final class BypassAppsTests: XCTestCase {
    private var savedConfig: RouteManager.Config!
    private var savedLookup: ((String) -> AppIdentity?)!
    private var savedEngineState: (@MainActor () -> FlowEngineState)!

    override func setUp() async throws {
        let rm = RouteManager.shared
        savedConfig = rm.config
        savedLookup = BypassApps.lookup
        savedEngineState = ClassicControl.engineState
        BypassApps.lookup = { _ in nil }
        ClassicControl.engineState = { .off }
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

    private func compile(_ c: RouteManager.Config) -> FlowPolicy {
        FlowPolicyCompiler.compile(FlowPolicyCompiler.Input(config: c, paused: false, killSwitchActive: false,
                                                             physicalInterface: "en0", tunnelOwnerTeams: []),
                                   generation: 1)
    }

    // MARK: - Config and policy

    func testOldConfigDecodesWithAnEmptyListAndTheListRoundTrips() throws {
        let old = try JSONDecoder().decode(RouteManager.Config.self, from: Data(#"{"routingMode":"bypass"}"#.utf8))
        XCTAssertEqual(old.bypassApps, [])

        var c = RouteManager.Config()
        c.bypassApps = [BypassApp(pattern: "com.example.Browser", name: "Browser"),
                        BypassApp(pattern: "ExampleTool", enabled: false)]
        let again = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again.bypassApps, c.bypassApps)
    }

    /// The list reaches the policy in Bypass mode, each entry Direct under its own id; an entry
    /// that is off claims nothing.
    func testBypassModeCompilesTheListToDirectMatchers() {
        var c = rm.config
        let on = BypassApp(pattern: "com.example.Browser")
        let off = BypassApp(pattern: "com.example.Mail", enabled: false)
        let tool = BypassApp(pattern: "ExampleTool")
        c.bypassApps = [on, off, tool]
        let p = compile(c)
        XCTAssertEqual(p.matchers.map(\.pattern), ["com.example.Browser", "ExampleTool"])
        XCTAssertEqual(p.matchers.map(\.ruleID), [on.id.uuidString, tool.id.uuidString])
        XCTAssertEqual(p.matchers.map(\.egress), [.direct(interface: "en0"), .direct(interface: "en0")])

        c.routingMode = .vpnOnly
        XCTAssertEqual(compile(c).matchers, [], "VPN Only never runs per-app routing")
        c.routingMode = .custom
        c.schemaVersion = 2
        XCTAssertEqual(compile(c).matchers, [], "Custom serves its own rules, not the list")
    }

    // MARK: - Checks on an add

    func testCheckRefusesBadPatternsOwnAppVPNClientsAndDuplicates() {
        let listed = [BypassApp(pattern: "com.example.Browser", name: "Browser")]
        XCTAssertEqual(try? BypassApps.check(" com.example.Mail ", identity: nil, in: listed).get(), "com.example.Mail")
        XCTAssertEqual(BypassApps.check("/Applications/Example.app", identity: nil, in: listed), .failure(.invalid(.path)))
        XCTAssertEqual(BypassApps.check("com.example.*", identity: nil, in: listed), .failure(.invalid(.wildcard)))
        XCTAssertEqual(BypassApps.check("com.geiserx.vpn-bypass", identity: nil, in: listed), .failure(.ownApp))
        XCTAssertEqual(BypassApps.check("com.example.Browser", identity: nil, in: listed), .failure(.alreadyListed("Browser")))
        let vpn = AppIdentity(name: "Example VPN", signingID: "com.example.vpn", team: "PXPZ95SK77")
        XCTAssertEqual(BypassApps.check("com.example.vpn", identity: vpn, in: listed), .failure(.vpnClient("Example VPN")))
    }

    func testAddByIdLooksUpTheInstalledAppForItsNameAndTeam() {
        BypassApps.lookup = { id in
            id == "com.example.Browser" ? AppIdentity(name: "Browser", signingID: id, team: "TEAM000001")
                : id == "com.example.vpn" ? AppIdentity(name: "Example VPN", signingID: id, team: "W5364U7YZB") : nil
        }
        XCTAssertEqual(try rm.addBypassApp("com.example.Browser").get().name, "Browser")
        XCTAssertEqual(rm.addBypassApp("com.example.vpn"), .failure(.vpnClient("Example VPN")))
        XCTAssertNil(try rm.addBypassApp("ExampleTool").get().name, "an executable name has no app to look up")
        XCTAssertEqual(rm.config.bypassApps.map(\.pattern), ["com.example.Browser", "ExampleTool"])
    }

    // MARK: - Remove, switch, undo

    func testRemoveThenUndoPutsTheEntryBackWhereItSat() {
        _ = rm.addBypassApp("com.example.A")
        let b = try! rm.addBypassApp("com.example.B").get()
        _ = rm.addBypassApp("com.example.C")
        let removed = rm.removeBypassApp(b.id)
        XCTAssertEqual(removed?.index, 1)
        XCTAssertEqual(rm.config.bypassApps.map(\.pattern), ["com.example.A", "com.example.C"])

        let change = UndoableChange.bypassApp(removed!.app, index: removed!.index)
        XCTAssertEqual(change.page, .apps)
        XCTAssertEqual(change.message, "Removed com.example.B.")
        XCTAssertTrue(rm.undo(change))
        XCTAssertEqual(rm.config.bypassApps.map(\.pattern), ["com.example.A", "com.example.B", "com.example.C"])
        XCTAssertEqual(rm.config.bypassApps[1].id, b.id)
        XCTAssertFalse(rm.undo(change), "already back: nothing to restore")
    }

    func testSwitchTurnsAnEntryOffAndOn() {
        let a = try! rm.addBypassApp("com.example.A").get()
        rm.setBypassAppEnabled(a.id, false)
        XCTAssertEqual(rm.config.bypassApps.first?.enabled, false)
        XCTAssertEqual(compile(rm.config).matchers, [])
        rm.setBypassAppEnabled(a.id, true)
        XCTAssertEqual(compile(rm.config).matchers.map(\.pattern), ["com.example.A"])
    }

    // MARK: - Custom and profiles

    /// Switching to Custom carries the list into process rules on the Direct route, as it
    /// carries the domain list into domain rules.
    func testSwitchToCustomCarriesTheListIntoDirectProcessRules() {
        var c = RouteManager.Config()
        c.routingMode = .bypass
        c.domains = []
        c.services = []
        c.bypassApps = [BypassApp(pattern: "com.example.Browser"), BypassApp(pattern: "com.example.Off", enabled: false)]
        XCTAssertTrue(c.customModeBuildsRulesFromLists)
        let custom = c.preparedForCustomMode()
        let direct = custom.routes.first { $0.egress == .direct }
        let process = custom.rules.filter { $0.matchType == .process }
        XCTAssertEqual(process.map(\.pattern), ["com.example.Browser"])
        XCTAssertEqual(process.first?.routeId, direct?.id)
    }

    func testAProfileKeepsItsOwnListAndAnOldProfileHasNone() throws {
        var c = RouteManager.Config()
        c.bypassApps = [BypassApp(pattern: "com.example.Browser")]
        let settings = ProfileSettings(capturing: c)
        var other = RouteManager.Config()
        other.bypassApps = [BypassApp(pattern: "com.example.Other")]
        XCTAssertEqual(settings.applied(to: other).bypassApps.map(\.pattern), ["com.example.Browser"])

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json.removeValue(forKey: "bypassApps")
        let old = try JSONDecoder().decode(ProfileSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.applied(to: other).bypassApps, [])
    }

    // MARK: - vpnb app.*

    func testAppVerbsAddListAndRemove() async {
        let add = await send("app.add", ["pattern": "com.example.Browser"])
        XCTAssertTrue(add.ok, "\(String(describing: add.error))")
        XCTAssertEqual(add.result?.apps?.first?.pattern, "com.example.Browser")
        XCTAssertEqual(add.result?.apps?.first?.servedBy, RuleServedBy.none)
        XCTAssertEqual(add.result?.apps?.first?.inactiveReason, "perAppRoutingOff")
        XCTAssertTrue(add.result?.message?.contains("uses the VPN") == true)
        XCTAssertEqual(rm.lastOutsideChange?.kind, .addedDomain("com.example.Browser"))

        let dup = await send("app.add", ["pattern": "com.example.Browser"])
        XCTAssertEqual(dup.error?.code, "already_exists")
        let bad = await send("app.add", ["pattern": "/Applications/Example.app"])
        XCTAssertEqual(bad.error?.code, "invalid_args")
        let own = await send("app.add", ["pattern": "com.geiserx.vpn-bypass"])
        XCTAssertEqual(own.error?.code, "refused")

        ClassicControl.engineState = { .active }
        let list = await send("app.list")
        XCTAssertTrue(list.ok)
        XCTAssertEqual(list.result?.apps?.map(\.pattern), ["com.example.Browser"])
        XCTAssertEqual(list.result?.apps?.first?.servedBy, .perAppEngine)
        XCTAssertTrue(VPNBCLI.textLines(list).contains { $0.contains("com.example.Browser") && $0.contains("served by per-app routing") })

        rm.config.routingMode = .vpnOnly
        let inVPNOnly = await send("app.list")
        XCTAssertEqual(inVPNOnly.result?.apps?.first?.inactiveReason, "notInBypassMode")
        rm.config.routingMode = .bypass

        let rm1 = await send("app.rm", ["pattern": "com.example.Browser"])
        XCTAssertTrue(rm1.ok)
        XCTAssertEqual(rm.config.bypassApps, [])
        XCTAssertEqual(rm.lastOutsideChange?.kind, .removedDomain("com.example.Browser"))
        let gone = await send("app.rm", ["pattern": "com.example.Browser"])
        XCTAssertEqual(gone.error?.code, "not_found")
        XCTAssertFalse(CommandRouter.isMutating("app.list"))
        XCTAssertTrue(CommandRouter.isMutating("app.add"))
    }

    // MARK: - The page

    func testPageSaysWhyTheListDoesNothingWhileTheEngineDoesNotServeIt() throws {
        let en = Bundle.main
        XCTAssertNil(AppsPage.notice(engine: .active, listIsLive: true))
        XCTAssertTrue(try XCTUnwrap(AppsPage.notice(engine: .off, listIsLive: true, bundle: en)).contains("Per-app routing is off"))
        XCTAssertTrue(try XCTUnwrap(AppsPage.notice(engine: .starting, listIsLive: true, bundle: en)).contains("use the VPN"))
        XCTAssertNil(AppsPage.notice(engine: .off, listIsLive: false), "another mode: the read-only line says it")
        XCTAssertFalse(AppsPage.offersSettings(.unavailable(.notInThisBuild)))
        XCTAssertTrue(AppsPage.offersSettings(.off))
        XCTAssertEqual(SettingsSidebar.modes(of: .apps), [.bypass])
        XCTAssertEqual(SettingsSidebar.groups[1].pages, [.domains, .services, .apps, .rules, .routes])
    }

    func testRowsShowTheSigningIdAndCountsOnlyWhileServed() {
        let a = BypassApp(pattern: "com.example.Browser", name: "Browser")
        let b = BypassApp(pattern: "com.example.Mail", name: "Mail", enabled: false)
        let counts: (String) -> FlowEngineRuleCounters? = { id in
            id == a.id.uuidString ? FlowEngineRuleCounters(ruleId: id, claimed: 7, bound: 0) : nil
        }
        let off = AppsPage.rows([a, b], engine: .off, listIsLive: true, search: "", counters: counts)
        XCTAssertEqual(off.map(\.detail), ["com.example.Browser", "com.example.Mail"])
        let on = AppsPage.rows([a, b], engine: .active, listIsLive: true, search: "", counters: counts)
        XCTAssertEqual(on.map(\.isServed), [true, false])
        XCTAssertTrue(on[0].detail?.hasPrefix("com.example.Browser · ") == true)
        XCTAssertTrue(on[0].detail?.contains("7") == true)
        // An entry added by an executable name has no other name: the id is not said twice.
        XCTAssertNil(AppsPage.rows([BypassApp(pattern: "example-sync")], engine: .off, listIsLive: true, search: "").first?.detail)
        XCTAssertEqual(AppsPage.rows([a, b], engine: .active, listIsLive: true, search: "mail").map(\.app.pattern),
                       ["com.example.Mail"])
    }

    func testChooserPutsRunningAppsFirstOnceEachAndLeavesOutListedAndOwnApps() {
        let url = URL(fileURLWithPath: "/Applications/X.app")
        func c(_ name: String, _ id: String, running: Bool) -> BypassApps.Candidate {
            BypassApps.Candidate(url: url, name: name, bundleID: id, isRunning: running)
        }
        let out = BypassApps.candidates(
            running: [c("Zed", "com.example.Zed", running: true), c("Mail", "com.example.Mail", running: true)],
            installed: [c("Mail", "com.example.Mail", running: false), c("Atlas", "com.example.Atlas", running: false),
                        c("Listed", "com.example.Listed", running: false), c("VPN Bypass", "com.geiserx.vpn-bypass", running: false)],
            listed: [BypassApp(pattern: "com.example.Listed")])
        XCTAssertEqual(out.map(\.bundleID), ["com.example.Mail", "com.example.Zed", "com.example.Atlas"])
        XCTAssertEqual(BypassApps.filter(out, search: "atl").map(\.bundleID), ["com.example.Atlas"])
        XCTAssertEqual(BypassApps.filter(out, search: "example.zed").map(\.bundleID), ["com.example.Zed"])
    }

    // MARK: - Counts

    private func input(apps: Int, served: Bool, services: Int = 2, domains: Int = 0) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(isVPNConnected: true, vpnName: nil, helperReady: true, mode: .bypass,
                                     enabledServices: services, enabledDomains: domains, enabledRules: 0,
                                     installedRoutes: 10, pending: nil, lastRouteChange: nil,
                                     lastDNSRefresh: nil, nextDNSRefresh: nil, autoDNSRefresh: true)
        i.enabledApps = apps
        i.appsServed = served
        return i
    }

    func testDropdownAndStatusCountTheApps() {
        XCTAssertEqual(StatusPage.fromLine(input(apps: 3, served: false)).text, "2 services, 3 apps")
        XCTAssertEqual(StatusPage.fromLine(input(apps: 1, served: false, services: 0)).text, "1 app")
        XCTAssertEqual(StatusPage.fromLine(input(apps: 0, served: false)).text, "2 services")
        // Only apps per-app routing serves skip the VPN.
        XCTAssertEqual(DropdownStatus.whatIsRouted(input(apps: 3, served: false)), "2 services skip the VPN.")
        XCTAssertTrue(DropdownStatus.whatIsRouted(input(apps: 3, served: true)).contains("3 apps"))
        XCTAssertEqual(DropdownStatus.whatIsRouted(input(apps: 1, served: true, services: 0)), "1 app skips the VPN.")
        XCTAssertFalse(FirstRunSetup.isFresh(mode: .bypass, domains: [], services: [],
                                             apps: [BypassApp(pattern: "com.example.A")], installedRoutes: 0))
    }

    func testServedAppsAloneAreNotNothingRouted() {
        var only = input(apps: 2, served: true, services: 0)
        only.installedRoutes = 0
        XCTAssertNotEqual(DropdownStatus.make(only, now: Date()).chip, .notRouting)
        XCTAssertNotEqual(StatusPage.summary(only, now: Date()).title, "Nothing routed")
        // Apps that per-app routing does not serve, or services with no address, still warn.
        var unserved = only
        unserved.appsServed = false
        XCTAssertEqual(DropdownStatus.make(unserved, now: Date()).chip, .notRouting)
        var withServices = input(apps: 2, served: true, services: 1)
        withServices.installedRoutes = 0
        XCTAssertEqual(DropdownStatus.make(withServices, now: Date()).chip, .notRouting)
        XCTAssertEqual(StatusPage.summary(withServices, now: Date()).title, "Nothing routed")
    }

    // MARK: - Review fixes

    func testAnEntryThatIsOffHasNoReasonWhateverTheEngine() {
        let off = BypassApp(pattern: "com.example.A", enabled: false)
        for engine: FlowEngineState in [.off, .active, .starting, .unavailable(.notInThisBuild)] {
            XCTAssertNil(BypassAppServing.serving(off, engine: engine).reason, "\(engine)")
        }
        XCTAssertNil(BypassAppServing.serving(off, engine: .active, listIsLive: false).reason)
    }

    func testAddByIdStoresTheSigningIdentifier() {
        BypassApps.lookup = { id in
            id == "com.example.Bundle"
                ? AppIdentity(name: "Example", signingID: "com.example.Signed", team: "TEAM000001", bundleID: id) : nil
        }
        let app = try! rm.addBypassApp("com.example.Bundle").get()
        XCTAssertEqual(app.pattern, "com.example.Signed")
        XCTAssertEqual(app.bundleID, "com.example.Bundle", "kept for the icon, the chooser and app.rm")
        XCTAssertEqual(rm.addBypassApp("com.example.Bundle"), .failure(.alreadyListed("Example")))
        // The chooser leaves it out by its bundle id.
        let url = URL(fileURLWithPath: "/Applications/Example.app")
        XCTAssertEqual(BypassApps.candidates(running: [], installed: [BypassApps.Candidate(url: url, name: "Example", bundleID: "com.example.Bundle", isRunning: false)],
                                             listed: rm.config.bypassApps), [])
        // A plain entry stores no bundle id.
        XCTAssertNil(BypassApp(pattern: "com.example.A", bundleID: "com.example.A").bundleID)
    }

    func testAppRmByBundleIdRemovesAnEntryStoredUnderItsSigningId() async {
        BypassApps.lookup = { id in
            id == "com.example.Bundle"
                ? AppIdentity(name: "Example", signingID: "com.example.Signed", team: "TEAM000001", bundleID: id) : nil
        }
        _ = rm.addBypassApp("com.example.Bundle")
        let gone = await send("app.rm", ["pattern": "com.example.Bundle"])
        XCTAssertTrue(gone.ok, "\(String(describing: gone.error))")
        XCTAssertEqual(rm.config.bypassApps, [])
    }

    func testAProfileWithARepeatedIdGivesTheLiveListFreshOnes() {
        let id = UUID()
        var c = RouteManager.Config()
        c.bypassApps = [BypassApp(id: id, pattern: "com.example.A"), BypassApp(id: id, pattern: "com.example.B")]
        let applied = ProfileSettings(capturing: c).applied(to: RouteManager.Config())
        XCTAssertEqual(Set(applied.bypassApps.map(\.id)).count, 2)
        XCTAssertEqual(applied.bypassApps[0].id, id)
    }

    func testARepeatedIdInTheConfigGetsAFreshOne() throws {
        let id = UUID()
        var c = RouteManager.Config()
        c.bypassApps = [BypassApp(id: id, pattern: "com.example.A"), BypassApp(id: id, pattern: "com.example.B")]
        let again = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again.bypassApps.map(\.pattern), ["com.example.A", "com.example.B"])
        XCTAssertEqual(again.bypassApps[0].id, id)
        XCTAssertNotEqual(again.bypassApps[1].id, id)
    }
}
