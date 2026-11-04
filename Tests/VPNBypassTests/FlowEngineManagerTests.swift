// FlowEngineManagerTests.swift
// Per-app routing's app side (docs/design/NETWORK-EXTENSION-DESIGN.md, 3.3, 3.7 and 5), driven
// through a fake of macOS: the switch, the two approvals, the blocked reasons, the echo rule, the
// heartbeat's retries, the watchdog (one restart, then off), the stand-downs, and the proof that
// the off state changes nothing for the kernel engine.

import Foundation
import XCTest
@testable import VPNBypassCore
import VPNBypassPolicy

@MainActor
final class FakeFlowEngineSystem: FlowEngineSystem {
    var support: FlowEngineSupport = .supported
    var onSessionChange: (@MainActor () -> Void)?

    var activationRequests = 0
    /// Answered at once when set; otherwise `finishActivation` answers.
    var activationAnswer: FlowEngineActivation? = .activated
    var asksApproval = false
    /// The request replaces an installed extension of another version.
    var replacing = false
    private var pendingActivation: (@MainActor (FlowEngineActivation) -> Void)?

    /// Our configuration's isEnabled; nil when there is none.
    var configuration: Bool?
    var saveAnswer: FlowEngineSaveResult = .saved
    /// While true a save waits, as macOS does while its prompt is on screen.
    var holdSave = false
    var saves: [Bool] = []

    var session: FlowEngineSession = .none
    var connectOnStart = true
    var starts = 0
    var stops = 0

    var sent: [FlowPolicy] = []
    /// Replies by send, in order; when empty, the extension echoes the policy.
    var replies: [Data?] = []
    var claimedByRule: [String: Int] = [:]
    var boundByRule: [String: Int] = [:]
    var extensionVersion: String?

    var calls: Int { activationRequests + saves.count + starts + stops + sent.count }

    func requestActivation(onNeedsApproval: @escaping @MainActor (_ replacing: Bool) -> Void,
                           completion: @escaping @MainActor (FlowEngineActivation) -> Void) {
        activationRequests += 1
        if asksApproval { onNeedsApproval(replacing) }
        if let activationAnswer { completion(activationAnswer) } else { pendingActivation = completion }
    }

    func finishActivation(_ outcome: FlowEngineActivation) {
        pendingActivation?(outcome)
        pendingActivation = nil
    }

    func loadConfiguration() async -> Bool? { configuration }

    func saveConfiguration(enabled: Bool) async -> FlowEngineSaveResult {
        saves.append(enabled)
        while holdSave { try? await Task.sleep(nanoseconds: 5_000_000) }
        if saveAnswer == .saved {
            if configuration == nil && !enabled { return .saved }
            configuration = enabled
            if session == .none { session = .disconnected }
        }
        return saveAnswer
    }

    func startSession() -> Bool {
        starts += 1
        if connectOnStart { session = .connected }
        return true
    }

    func stopSession() {
        stops += 1
        if session != .none { session = .disconnected }
        onSessionChange?()
    }

    /// The extension dies (kill -9): the session ends without the app asking.
    func crash() {
        session = .disconnected
        onSessionChange?()
    }

    /// While true a send waits, as a slow extension reply does.
    var holdSend = false
    /// Sends waiting under `holdSend`.
    var heldSends = 0

    func send(_ data: Data, timeout: TimeInterval) async -> Data? {
        if holdSend {
            heldSends += 1
            while holdSend { try? await Task.sleep(nanoseconds: 5_000_000) }
            heldSends -= 1
        }
        guard case .policy(let p) = FlowPolicyMessage.decode(data) else { return nil }
        sent.append(p)
        if !replies.isEmpty { return replies.removeFirst() }
        return Self.echo(p, claimed: claimedByRule, bound: boundByRule, version: extensionVersion)
    }

    static func echo(_ p: FlowPolicy, claimed: [String: Int] = [:], bound: [String: Int] = [:], version: String? = nil) -> Data {
        try! JSONEncoder().encode(FlowPolicyReply(policyGeneration: p.generation, policyLive: true,
                                                  claimedByRule: claimed, boundByRule: bound, extensionVersion: version))
    }
}

@MainActor
final class FlowEngineManagerTests: XCTestCase {
    private var system: FakeFlowEngineSystem!
    private var engine: FlowEngineManager!
    private var enabled = false
    private var input = FlowPolicyCompiler.Input(mode: .custom)
    private var clock = Date(timeIntervalSince1970: 2_000_000_000)
    private let ruleID = UUID()
    private let directID = UUID()
    private let vpnID = UUID()

    override func setUp() async throws {
        system = FakeFlowEngineSystem()
        enabled = false
        clock = Date(timeIntervalSince1970: 2_000_000_000)
        input = FlowPolicyCompiler.Input(
            mode: .custom,
            processRules: [.init(id: ruleID, pattern: "com.example.App", routeID: directID, order: 0)],
            routes: [.init(id: directID, kind: .direct), .init(id: vpnID, kind: .vpnPrimary)],
            physicalInterface: "en0")
        engine = makeEngine(system)
    }

    private func makeEngine(_ system: FakeFlowEngineSystem) -> FlowEngineManager {
        let e = FlowEngineManager(system: system)
        e.inputs = { [unowned self] in self.input }
        e.isEnabled = { [unowned self] in self.enabled }
        e.saveEnabled = { [unowned self] in self.enabled = $0 }
        e.now = { [unowned self] in self.clock }
        e.sleep = { _ in await Task.yield() }
        e.heartbeatWait = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        e.appVersion = "6.1.0"
        return e
    }

    /// Waits until `condition` holds, up to 2 s of real time (the fake answers at once).
    private func until(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    private func turnOnToActive() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
    }

    // MARK: - Off and unavailable

    func testOffByDefaultTouchesNothing() async {
        XCTAssertEqual(engine.state, .off)
        engine.followSwitch()
        engine.inputsChanged()
        input.paused = true
        engine.inputsChanged()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(system.calls, 0, "off files no request, saves nothing, starts nothing, sends nothing")
        XCTAssertEqual(engine.state, .off)
        XCTAssertFalse(enabled)
    }

    func testAConfigWithoutTheKeyIsOff() throws {
        let decoded = try JSONDecoder().decode(RouteManager.Config.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.flowEngine.enabled)
        var on = decoded
        on.flowEngine.enabled = true
        let again = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(again.flowEngine.enabled)
        XCTAssertEqual(try JSONDecoder().decode(FlowEngineSetting.self, from: Data("{}".utf8)), FlowEngineSetting())
    }

    func testABuildWithoutTheExtensionIsUnavailableAndNeverAsks() async {
        let unsupported = FakeFlowEngineSystem()
        unsupported.support = .unavailable(.notInThisBuild)
        let e = makeEngine(unsupported)
        XCTAssertEqual(e.state, .unavailable(.notInThisBuild))
        e.setEnabled(true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(unsupported.calls, 0)
        XCTAssertEqual(e.state, .unavailable(.notInThisBuild))
        XCTAssertFalse(PerAppRouting.switchEnabled(e.state))

        // The checks behind support: macOS 15, the bundled extension, the entitlement.
        let bundle = Bundle(for: FlowEngineManagerTests.self)
        XCTAssertEqual(LiveFlowEngineSystem.support(bundle: bundle, os: .init(majorVersion: 14, minorVersion: 6, patchVersion: 0)),
                       .unavailable(.needsMacOS15))
        XCTAssertEqual(LiveFlowEngineSystem.support(bundle: bundle, os: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                                                    entitled: { true }), .unavailable(.notInThisBuild),
                       "no extension in the bundle")
        XCTAssertFalse(LiveFlowEngineSystem.hasEntitlement(LiveFlowEngineSystem.installEntitlement),
                       "the unsigned test runner has no install entitlement")
    }

    // MARK: - Turning on

    func testTurningOnWalksBothApprovalsThenGoesActive() async {
        system.activationAnswer = nil
        system.asksApproval = true
        system.holdSave = true
        engine.setEnabled(true)
        XCTAssertTrue(enabled, "the switch is saved")
        XCTAssertEqual(engine.state, .awaitingExtensionApproval)
        XCTAssertTrue(engine.state.waitsInSystemSettings)
        XCTAssertEqual(system.starts, 0, "nothing starts before the extension is allowed")

        system.finishActivation(.activated)
        await until("the configuration prompt") { engine.state == .awaitingConfigApproval }
        XCTAssertEqual(system.saves, [true])
        system.holdSave = false
        await until("active") { engine.state == .active }
        XCTAssertEqual(system.starts, 1)
        XCTAssertEqual(system.sent.last?.matchers.map(\.ruleID), [ruleID.uuidString])
        XCTAssertEqual(system.sent.last?.matchers.first?.egress, .direct(interface: "en0"))
        XCTAssertEqual(engine.confirmed, system.sent.last)
    }

    /// 6.4: an update whose replacement waits for approval says so, and the old extension gets
    /// nothing from this app until it is allowed.
    func testAReplacementWaitingForApprovalShowsTheUpdateWaiting() async {
        system.activationAnswer = nil
        system.asksApproval = true
        system.replacing = true
        engine.setEnabled(true)
        XCTAssertEqual(engine.state, .updateWaiting)
        XCTAssertTrue(engine.state.waitsInSystemSettings)
        XCTAssertEqual(engine.state.ruleReason, .perAppRoutingUpdateWaiting)
        XCTAssertEqual(system.starts + system.sent.count, 0, "the old extension gets no policy")
        system.finishActivation(.activated)
        await until("active once the update is allowed") { engine.state == .active }
    }

    /// A push the new attempt asks for while the last attempt's push is still waiting for its
    /// reply runs as soon as that one returns, not at the next heartbeat 30 s later.
    func testAPushRequestedDuringAnOlderAttemptsPushIsNotDropped() async {
        await turnOnToActive()
        system.holdSend = true
        engine.requestPush(force: true)
        await until("the push waits for its reply") { system.heldSends == 1 }
        engine.setEnabled(false)
        engine.setEnabled(true)
        await until("the new session is up") { system.starts == 2 && system.session == .connected }
        try? await Task.sleep(nanoseconds: 20_000_000)
        system.holdSend = false
        await until("the new attempt's push went out and was confirmed") { engine.state == .active }
    }

    func testAnAlreadyEnabledConfigurationIsNotSavedAgain() async {
        system.configuration = true
        system.session = .connected
        await turnOnToActive()
        XCTAssertEqual(system.saves, [], "re-saving has lost consent elsewhere (3.3)")
        XCTAssertEqual(system.starts, 0, "a connected session is used as it is")
    }

    func testBlockedReasonsComeFromTheActivationError() async {
        for (code, state) in [(3, FlowEngineState.blocked(.notInApplications)), (10, .blocked(.forbiddenByPolicy)),
                              (2, .unavailable(.notInThisBuild)), (1, .failed(.activationFailed))] {
            let s = FakeFlowEngineSystem()
            s.activationAnswer = .failed(code: code)
            let e = makeEngine(s)
            enabled = false
            e.setEnabled(true)
            XCTAssertEqual(e.state, state, "code \(code)")
            XCTAssertEqual(s.starts + s.saves.count, 0, "code \(code): nothing is configured")
        }
        let s = FakeFlowEngineSystem()
        s.activationAnswer = .willCompleteAfterReboot
        let e = makeEngine(s)
        enabled = false
        e.setEnabled(true)
        XCTAssertEqual(e.state, .blocked(.needsRestart))
    }

    func testDecliningTheConfigurationTurnsTheSwitchBackOff() async {
        system.saveAnswer = .declined
        engine.setEnabled(true)
        await until("declined") { engine.state == .failed(.configurationDeclined) }
        XCTAssertFalse(enabled)
        XCTAssertEqual(system.starts, 0)
        XCTAssertFalse(engine.wantsOn)
    }

    func testTurningOffStopsTheSessionAndDisablesTheConfiguration() async {
        await turnOnToActive()
        engine.setEnabled(false)
        XCTAssertEqual(engine.state, .off)
        XCTAssertFalse(enabled)
        XCTAssertEqual(system.stops, 1)
        await until("disabled") { system.saves.last == false }
        XCTAssertEqual(system.configuration, false)
    }

    // MARK: - Pushes

    func testRuleAndModeChangesPushAndStandDowns() async {
        await turnOnToActive()
        let pushes = system.sent.count

        input.paused = true
        engine.inputsChanged()
        await until("paused") { engine.state == .paused(.pause) }
        XCTAssertEqual(system.sent.last?.matchers, [], "Pause pushes a policy that claims nothing")

        input.paused = false
        input.killSwitchActive = true
        engine.inputsChanged()
        await until("kill switch") { engine.state == .paused(.killSwitch) }
        XCTAssertEqual(system.sent.last?.matchers, [])

        input.killSwitchActive = false
        input.mode = .vpnOnly
        engine.inputsChanged()
        await until("VPN Only") { engine.state == .paused(.vpnOnly) }
        XCTAssertEqual(system.sent.last?.matchers, [])

        input.mode = .custom
        engine.inputsChanged()
        await until("active again") { engine.state == .active }
        XCTAssertEqual(system.sent.last?.matchers.count, 1)
        XCTAssertGreaterThanOrEqual(system.sent.count, pushes + 2, "the stand-downs claim the same nothing, so they push once")
        let generations = system.sent.map(\.generation)
        XCTAssertEqual(generations, generations.sorted(), "every push raises the generation")
        XCTAssertEqual(Set(generations).count, generations.count)

        // A change that compiles to the same policy pushes nothing.
        let before = system.sent.count
        engine.inputsChanged()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(system.sent.count, before)
    }

    /// 3.3: a push that takes apps out counts only once the extension echoes it; without the
    /// echo the session is stopped at once instead of leaving the old claims for the lease.
    func testAShrinkingPushWithoutAnEchoStopsTheSession() async {
        await turnOnToActive()
        var seen: [(FlowEngineState, Int)] = []
        let watch = engine.$state.sink { [unowned self] in seen.append(($0, self.system.stops)) }
        defer { watch.cancel() }
        system.replies = [nil]
        input.paused = true
        engine.inputsChanged()
        await until("the session stopped, then the restart pushed it again") { engine.state == .paused(.pause) }
        let firstPaused = try? XCTUnwrap(seen.first { $0.0 == .paused(.pause) })
        XCTAssertEqual(firstPaused?.1, 1, "Paused is shown only after the session without an echo was stopped")
        XCTAssertTrue(seen.contains { $0.0 == .failed(.stoppedRestarting) })
        XCTAssertEqual(system.sent.filter { $0.matchers.isEmpty }.count, 2, "one try of the shrinking push, then the restart's push")
        XCTAssertEqual(system.starts, 2)
    }

    /// 3.3: a reply that echoes another generation does not confirm the push. The policy is not
    /// taken as live, the session is stopped and started once, and the restart's push counts.
    func testAReplyWithAnotherGenerationDoesNotConfirmThePush() async {
        await turnOnToActive()
        let before = engine.confirmed
        var seen: [FlowEngineState] = []
        let watch = engine.$state.sink { seen.append($0) }
        defer { watch.cancel() }
        system.replies = [try! JSONEncoder().encode(FlowPolicyReply(policyGeneration: before!.generation, policyLive: true))]
        input.processRules.append(.init(id: UUID(), pattern: "com.example.Other", routeID: directID, order: 1))
        engine.inputsChanged()
        await until("restarted and confirmed by the next push") { system.stops == 1 && engine.state == .active }
        XCTAssertTrue(seen.contains(.failed(.stoppedRestarting)), "a stale echo is not a confirmation")
        XCTAssertEqual(engine.confirmed?.matchers.count, 2)
        XCTAssertGreaterThan(engine.confirmed!.generation, before!.generation + 1)
    }

    func testAHeartbeatRetriesTwiceBeforeTheExtensionIsSilent() async {
        await turnOnToActive()
        system.replies = [nil, nil]
        engine.requestPush(force: true)
        await until("answered on the third try") { system.replies.isEmpty }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(engine.state, .active)
        XCTAssertEqual(system.stops, 0)

        system.replies = [nil, nil, nil]
        engine.requestPush(force: true)
        await until("silent: stopped and started once") { engine.state == .active && system.stops == 1 }
        XCTAssertEqual(system.starts, 2)
    }

    func testAnExtensionThatDoesNotReadThePolicyMeansAnUpdateWaits() async {
        system.replies = [try! JSONEncoder().encode(FlowPolicyReply(rejectedVersion: 1, extensionVersion: "6.0.11"))]
        engine.setEnabled(true)
        await until("update waiting") { engine.state == .updateWaiting }
        XCTAssertTrue(engine.updateWaiting)
        XCTAssertEqual(engine.state.ruleReason, .perAppRoutingUpdateWaiting)
        XCTAssertEqual(engine.status().updateWaiting, true)
    }

    // MARK: - The watchdog (3.7)

    func testACrashRestartsOnceAndASecondWithinTenMinutesTurnsItOff() async {
        await turnOnToActive()
        system.crash()
        await until("restarted") { system.starts == 2 && engine.state == .active }

        clock += 9 * 60
        system.crash()
        await until("turned off") { engine.state == .failed(.stoppedTwice) }
        XCTAssertFalse(enabled, "the switch is off; the user turns it on again by hand")
        XCTAssertEqual(system.starts, 2, "no second restart")
        XCTAssertEqual(system.configuration, false, "isEnabled false removes the include rule")

        // By hand it starts again, and the old failures are forgotten.
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        system.crash()
        await until("restarted once more") { engine.state == .active && system.starts == 4 }
    }

    func testCrashesFurtherApartThanTenMinutesEachRestart() async {
        await turnOnToActive()
        system.crash()
        await until("restarted") { system.starts == 2 && engine.state == .active }
        clock += 11 * 60
        system.crash()
        await until("restarted again") { system.starts == 3 && engine.state == .active }
        XCTAssertTrue(enabled)
    }

    func testStoppingOnPurposeIsNotACrash() async {
        await turnOnToActive()
        engine.setEnabled(false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(engine.state, .off)
        XCTAssertEqual(system.starts, 1)
    }

    // MARK: - Counters and status

    func testCountsLandOnTheRuleAndCarryNoNames() async throws {
        system.claimedByRule = [ruleID.uuidString: 12]
        system.boundByRule = [ruleID.uuidString: 3]
        system.extensionVersion = "6.1.0"
        await turnOnToActive()
        XCTAssertEqual(engine.counters(forRule: ruleID.uuidString),
                       FlowEngineRuleCounters(ruleId: ruleID.uuidString, claimed: 12, bound: 3))
        XCTAssertNil(engine.counters(forRule: UUID().uuidString))
        XCTAssertFalse(engine.updateWaiting)

        let status = engine.status()
        XCTAssertEqual(status.state, "active")
        XCTAssertTrue(status.enabled)
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(json.contains("com.example.App"), "no app names in the status (3.8)")
        XCTAssertFalse(json.contains("en0"))
        XCTAssertEqual(status.textLines.first, "per-app routing: active  switch: on  generation: \(engine.confirmed!.generation)  extension: 6.1.0")
        XCTAssertEqual(status.textLines.last, "  rule \(ruleID.uuidString): 12 around the VPN, 3 bound to an interface (not served)")

        let rule = Rule(id: ruleID, matchType: .process, pattern: "com.example.App", routeId: directID, order: 0)
        XCTAssertEqual(RuleRow.detail(for: rule, route: Route(name: "Direct", egress: .direct), engine: engine.state,
                                      counters: engine.counters(forRule: ruleID.uuidString)),
                       "Served by per-app routing: 12 connections went around the VPN. 3 came bound to a network interface, which per-app routing cannot serve.")
        XCTAssertEqual(PerAppRouting.countsLine(engine.reply),
                       "12 connections went around the VPN since the extension started. 3 came bound to a network interface, which per-app routing cannot serve.")
    }

    func testAnOlderExtensionVersionShowsTheUpdateNote() async {
        system.extensionVersion = "6.0.906"
        await turnOnToActive()
        XCTAssertTrue(engine.updateWaiting)
        XCTAssertEqual(engine.status().updateWaiting, true)
    }
}

// MARK: - Process rules follow the engine

final class ProcessRuleServingTests: XCTestCase {
    private let direct = Route(name: "Direct", egress: .direct)
    private let vpn = Route(name: "VPN", egress: .vpnDefault)

    func testAProcessRuleIsServedOnlyWhileActiveAndDirect() {
        let app = Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)
        XCTAssertEqual(ProcessRule.serving(app, engine: .active, routes: [direct]).servedBy, .perAppEngine)
        XCTAssertNil(ProcessRule.serving(app, engine: .active, routes: [direct]).reason)
        let cases: [(FlowEngineState, ProcessRule.InactiveReason)] = [
            (.off, .perAppRoutingOff), (.awaitingExtensionApproval, .perAppRoutingWaitingForApproval),
            (.awaitingConfigApproval, .perAppRoutingWaitingForApproval), (.blocked(.forbiddenByPolicy), .perAppRoutingBlocked),
            (.starting, .perAppRoutingStarting), (.paused(.killSwitch), .perAppRoutingPaused),
            (.updateWaiting, .perAppRoutingUpdateWaiting), (.failed(.stoppedTwice), .perAppRoutingFailed),
            (.unavailable(.needsMacOS15), .perAppRoutingNotAvailable),
        ]
        for (state, reason) in cases {
            let serving = ProcessRule.serving(app, engine: state, routes: [direct])
            XCTAssertEqual(serving.servedBy, RuleServedBy.none, "\(state)")
            XCTAssertEqual(serving.reason, reason, "\(state)")
        }
        let toVPN = Rule(matchType: .process, pattern: "com.example.App", routeId: vpn.id, order: 0)
        XCTAssertEqual(ProcessRule.serving(toVPN, engine: .active, routes: [vpn]).reason, .routeNotSupported)
        // A destination rule is the kernel engine's in every state.
        let domain = Rule(matchType: .domain, pattern: "example.com", routeId: direct.id, order: 1)
        XCTAssertEqual(ProcessRule.serving(domain, engine: .active, routes: [direct]).servedBy, .kernel)
        XCTAssertEqual(ProcessRule.serving(domain, engine: .off, routes: [direct]).servedBy, .kernel)
    }

    func testRuleListSaysServedWhenTheEngineServesIt() {
        let app = Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)
        let served = SanitizedRule(app, engine: .active, routes: [direct])
        XCTAssertEqual(served.servedBy, .perAppEngine)
        let response = ControlResponse(ok: true, result: ControlResult(rules: [served]))
        XCTAssertTrue(VPNBCLI.textLines(response)[0].hasSuffix("enabled  served by per-app routing"))
        let off = ControlResponse(ok: true, result: ControlResult(rules: [SanitizedRule(app, engine: .off, routes: [direct])]))
        XCTAssertTrue(VPNBCLI.textLines(off)[0].hasSuffix("enabled  inactive: per-app routing is off"))
    }

    func testWhyNamesOnlyTheRulesTheEngineDoesNotServe() {
        let app = Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0)
        var s = SiteRoute.Snapshot(mode: .custom, custom: true, list: [], services: [], rules: [app], routes: [direct],
                                   defaultRouteId: direct.id, activeRoutes: [], localGateway: "192.168.1.1", vpnInterface: "utun4")
        s.flowEngine = .active
        XCTAssertEqual(SiteRoute.match(host: "example.org", addresses: ["203.0.113.9"], in: s).inactiveAppRules, [])
        s.flowEngine = .off
        let found = SiteRoute.match(host: "example.org", addresses: ["203.0.113.9"], in: s)
        XCTAssertEqual(found.inactiveAppRules, ["com.example.App"])
        XCTAssertEqual(SiteRoute.inactiveAppRulesSentence(found.inactiveAppRules, engine: found.appRulesEngine),
                       "Rules for apps (com.example.App) change nothing now: per-app routing does not serve them (Settings > General says why).")
    }

    func testEngineStatusIsAReadVerbAndOnOffAreNot() {
        XCTAssertFalse(CommandRouter.isMutating("engine.status"))
        XCTAssertTrue(CommandRouter.isMutating("engine.on"))
        XCTAssertTrue(CommandRouter.isMutating("engine.off"))
    }

    func testTheNewLinesAreTranslated() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/VPNBypassCore/Resources")
        let es = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("es.lproj")))
        let fr = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("fr.lproj")))
        XCTAssertEqual(FlowEngineState.active.line(in: es), "Activado. Las apps de tus reglas evitan la VPN.")
        XCTAssertEqual(GeneralPage.Group.perAppRouting.title(in: fr), "Routage par app")
        XCTAssertEqual(ProcessRule.rowNote(.perAppRoutingOff, in: fr), "Inactive : le routage par app est désactivé (Réglages > Général).")
        XCTAssertNotEqual(PerAppRouting.approvals(in: es), PerAppRouting.approvals())
    }
}

// MARK: - The kernel engine does not depend on the switch

/// The owner's rule: with Per-app routing off the app behaves as 6.0.x did. The kernel engine
/// (routes, /etc/hosts names, the wildcard forwarder's specs) is compiled from the config by pure
/// code; the same config with the switch on and off compiles to the same thing, and no file on
/// the kernel path reads the engine at all.
final class FlowEngineKernelIsolationTests: XCTestCase {

    private func custom(engineOn: Bool) -> RouteManager.Config {
        var c = RouteManager.Config()
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "VPN", egress: .vpnDefault)
        c.routes = [direct, vpn]
        c.rules = [
            Rule(matchType: .process, pattern: "com.example.App", routeId: direct.id, order: 0),
            Rule(matchType: .domain, pattern: "example.com", routeId: direct.id, order: 1),
            Rule(matchType: .cidr, pattern: "198.51.100.0/24", routeId: direct.id, order: 2),
            Rule(matchType: .ip, pattern: "203.0.113.7", routeId: vpn.id, order: 3),
        ]
        c.domains = [DomainEntry(domain: "*.wild.example.com"), DomainEntry(domain: "plain.example.net")]
        c.routingMode = .custom
        c.schemaVersion = 2
        c.flowEngine.enabled = engineOn
        return c
    }

    func testRoutesHostsAndWildcardsAreTheSameWithTheSwitchOnOrOff() {
        let env = WildcardPlanner.Environment(localGateway: "192.168.10.1", physicalInterface: "en0", physicalDNS: ["192.168.10.1"],
                                              vpnGateway: "10.20.0.1", vpnInterface: "utun4", vpnDNS: ["10.20.0.53"])
        func kernel(_ c: RouteManager.Config) -> (hosts: Set<String>, routes: [RouteCompiler.DesiredRoute], wildcards: [WildcardSpec]) {
            let resolved = ["example.com": ["93.184.215.14"]]
            let built = RuleDestinationBuilder.build(rules: c.rules, services: c.services, resolved: resolved)
            let routes = RouteCompiler.compile(resolvedRules: built, routes: c.routes, localGateway: "192.168.10.1",
                                               ifaceGatewayForRoute: { _ in nil })
            return (RuleDestinationBuilder.hostsToResolve(rules: c.rules, services: c.services), routes,
                    WildcardPlanner.plan(c, env: env).specs)
        }
        for mode in [RouteManager.RoutingMode.custom, .bypass, .vpnOnly] {
            var off = custom(engineOn: false)
            var on = custom(engineOn: true)
            off.routingMode = mode
            on.routingMode = mode
            let a = kernel(off), b = kernel(on)
            XCTAssertEqual(a.hosts, b.hosts, "\(mode)")
            XCTAssertEqual(a.routes, b.routes, "\(mode)")
            XCTAssertEqual(a.wildcards, b.wildcards, "\(mode)")
        }
        // Positive control: the compile does see a change that matters.
        var changed = custom(engineOn: false)
        changed.rules.remove(at: 2)
        XCTAssertNotEqual(kernel(changed).routes, kernel(custom(engineOn: false)).routes)
    }

    /// The kernel path never reads per-app routing: not the routing and hosts code, not the
    /// wildcard planner or forwarder, not the helper.
    func testNoKernelFileReadsTheEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files = ["RouteManager.swift", "RouteCompiler.swift", "RuleResolver.swift", "RuleDestinationBuilder.swift",
                     "WildcardRoutes.swift", "WildcardDNS.swift", "WildcardEngine.swift", "ClassicRouteCompiler.swift",
                     "RouteKernel.swift", "HelperManager.swift", "Pause.swift"]
            .map { root.appendingPathComponent("Sources/VPNBypassCore/\($0)") }
        let helper = root.appendingPathComponent("Helper")
        for name in try FileManager.default.contentsOfDirectory(atPath: helper.path) where name.hasSuffix(".swift") {
            files.append(helper.appendingPathComponent(name))
        }
        XCTAssertGreaterThan(files.count, 12)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["FlowEngine", "flowEngine", "FlowPolicy", "import NetworkExtension"] {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) reads \(word)")
            }
        }
    }
}
