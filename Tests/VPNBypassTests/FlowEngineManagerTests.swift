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
    /// With `holdSave`, only enabling saves wait (the prompt); a disabling one goes through.
    var holdOnlyEnablingSaves = false
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

    /// removeFromPreferences calls, and whether they succeed.
    var configurationRemovals = 0
    var removeAnswer = true
    var deactivationRequests = 0
    /// Answered at once when set; otherwise `finishDeactivation` answers (the password prompt).
    var deactivationAnswer: FlowEngineDeactivation? = .removed
    private var pendingDeactivation: (@MainActor (FlowEngineDeactivation) -> Void)?
    /// The extension is installed (activated and not yet deactivated).
    var installed = false
    /// What happened, in order: "activate", "removeConfiguration", "deactivate".
    var log: [String] = []

    var calls: Int { activationRequests + saves.count + starts + stops + sent.count + configurationRemovals + deactivationRequests }

    func removeConfiguration() async -> Bool {
        configurationRemovals += 1
        log.append("removeConfiguration")
        guard removeAnswer else { return false }
        configuration = nil
        session = .none
        return true
    }

    func requestDeactivation(completion: @escaping @MainActor (FlowEngineDeactivation) -> Void) {
        deactivationRequests += 1
        log.append("deactivate")
        if let deactivationAnswer { finish(deactivationAnswer, completion) } else { pendingDeactivation = completion }
    }

    func finishDeactivation(_ outcome: FlowEngineDeactivation) {
        if let c = pendingDeactivation { finish(outcome, c) }
        pendingDeactivation = nil
    }

    private func finish(_ outcome: FlowEngineDeactivation, _ completion: @MainActor (FlowEngineDeactivation) -> Void) {
        if outcome == .removed { installed = false }
        completion(outcome)
    }

    func requestActivation(onNeedsApproval: @escaping @MainActor (_ replacing: Bool) -> Void,
                           completion: @escaping @MainActor (FlowEngineActivation) -> Void) {
        activationRequests += 1
        log.append("activate")
        if activationAnswer == .activated { installed = true }
        if asksApproval { onNeedsApproval(replacing) }
        if let activationAnswer { completion(activationAnswer) } else { pendingActivation = completion }
    }

    func finishActivation(_ outcome: FlowEngineActivation) {
        if outcome == .activated { installed = true }
        pendingActivation?(outcome)
        pendingActivation = nil
    }

    /// Reads of the preferences that fail from now on, each one taking one: the read that
    /// starts a save counts too, as the live save reads first.
    var failingReads = 0

    private func read() throws -> Bool? {
        if failingReads > 0 {
            failingReads -= 1
            throw NSError(domain: "NEConfigurationErrorDomain", code: 1)
        }
        return configuration
    }

    func loadConfiguration() async throws -> Bool? { try read() }

    func saveConfiguration(enabled: Bool) async -> FlowEngineSaveResult {
        saves.append(enabled)
        do { _ = try read() } catch { return .failed(code: 1) }
        while holdSave && (enabled || !holdOnlyEnablingSaves) { try? await Task.sleep(nanoseconds: 5_000_000) }
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

    /// Status requests sent, and whether the extension answers them (with its counters now).
    var statusRequests = 0
    var answersStatus = true

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
        let message = FlowPolicyMessage.decode(data)
        if message == .status {
            statusRequests += 1
            guard answersStatus, let last = sent.last else { return nil }
            return Self.echo(last, claimed: claimedByRule, bound: boundByRule, version: extensionVersion)
        }
        guard case .policy(let p) = message else { return nil }
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
    private var activated = false
    private var input = FlowPolicyCompiler.Input(mode: .custom)
    private var clock = Date(timeIntervalSince1970: 2_000_000_000)
    private let ruleID = UUID()
    private let directID = UUID()
    private let vpnID = UUID()

    override func setUp() async throws {
        system = FakeFlowEngineSystem()
        enabled = false
        activated = false
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
        e.wasActivated = { [unowned self] in self.activated }
        e.saveActivated = { [unowned self] in self.activated = $0 }
        e.now = { [unowned self] in self.clock }
        e.sleep = { _ in await Task.yield() }
        e.heartbeatWait = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        e.retryWait = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
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
        XCTAssertEqual(engine.status().updateWaiting, true, "the status says so before any reply")
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

    /// A turn-on right after a turn-off waits for the disabling save, so that save cannot land
    /// after the turn-on read the configuration and leave it off under a switch that says on.
    func testATurnOnRightAfterATurnOffWaitsForTheDisablingSave() async {
        await turnOnToActive()
        system.holdSave = true
        // A config.json that says off (an import): the app's own turn-off only disables.
        enabled = false
        engine.followSwitch()
        engine.setEnabled(true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        system.holdSave = false
        await until("active again") { engine.state == .active && system.saves.count == 3 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(system.saves, [true, false, true])
        XCTAssertEqual(system.configuration, true, "the configuration is on, as the switch says")
    }

    func testAnAlreadyEnabledConfigurationIsNotSavedAgain() async {
        system.configuration = true
        system.session = .connected
        await turnOnToActive()
        XCTAssertEqual(system.saves, [], "re-saving has lost consent elsewhere (3.3)")
        XCTAssertEqual(system.starts, 0, "a connected session is used as it is")
    }

    /// A session that would not connect is tried again on the next change of its inputs, so
    /// listed apps do not stay in the VPN until the switch is flipped.
    func testAFailedStartIsTriedAgainWhenTheInputsChange() async {
        system.connectOnStart = false
        engine.setEnabled(true)
        await until("the start failed") { engine.state == .failed(.startFailed) }
        XCTAssertTrue(engine.wantsOn)
        system.connectOnStart = true
        engine.inputsChanged()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(system.starts, 1, "not tried again within \(FlowEngineManager.startRetrySeconds) s")
        clock = clock.addingTimeInterval(FlowEngineManager.startRetrySeconds)
        engine.inputsChanged()
        await until("active after the retry") { engine.state == .active }
        XCTAssertEqual(system.starts, 2)
    }

    /// After a restart the session is started before the Mac has a network and does not
    /// connect. When the network comes up it is started again at once (no 30 s floor, no other
    /// input), once, and connects; meanwhile status and the log say the retry waits for it.
    func testAStartThatFailsWithNoNetworkRunsAgainWhenTheNetworkComesUp() async {
        var lines: [String] = []
        engine.log = { _, line in lines.append(line) }
        engine.networkChanged(available: false)
        system.connectOnStart = false
        engine.setEnabled(true)
        await until("the start failed") { engine.state == .failed(.startFailed) }
        XCTAssertEqual(engine.status().retry, "waitingForNetwork")
        XCTAssertTrue(engine.status().textLines[0].contains("retry: when the network is up"))
        XCTAssertTrue(lines.contains("Per-app routing: it starts again once the network is up"), "\(lines)")
        XCTAssertEqual(system.starts, 1)

        system.connectOnStart = true
        engine.networkChanged(available: true)
        await until("active after the network came up") { engine.state == .active }
        XCTAssertEqual(system.starts, 2, "one retry")
        XCTAssertNil(engine.status().retry)
        XCTAssertTrue(lines.contains { $0.contains("starting its session again after a failed start (the network is up)") }, "\(lines)")
    }

    /// The live run on macOS 27.2: the start ran at launch, the network was reported up while
    /// it was still waiting to connect, and the start failed 5 s later. The report arrived
    /// before the failure, so the failure itself starts it again, at once.
    func testANetworkThatComesUpDuringAFailingStartStartsItAgainRightAfter() async {
        system.connectOnStart = false
        var reported = false
        engine.sleep = { [unowned self] _ in
            if !reported, self.system.starts == 1 {
                reported = true
                self.engine.networkChanged(available: true)
                self.system.connectOnStart = true
            }
            await Task.yield()
        }
        engine.setEnabled(true)
        await until("active after the retry") { engine.state == .active }
        XCTAssertEqual(system.starts, 2)
    }

    /// A network that keeps coming and going starts the session again at most every 30 s.
    func testAFlappingNetworkRetriesAtMostEveryThirtySeconds() async {
        system.connectOnStart = false
        engine.networkChanged(available: false)
        engine.setEnabled(true)
        await until("the start failed") { engine.state == .failed(.startFailed) }
        engine.networkChanged(available: true)
        await until("the retry failed") { system.starts == 2 && engine.state == .failed(.startFailed) }
        XCTAssertEqual(engine.status().retry, "onNextChange")
        engine.networkChanged(available: false)
        engine.networkChanged(available: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(system.starts, 2, "not again within \(FlowEngineManager.startRetrySeconds) s")
        clock = clock.addingTimeInterval(FlowEngineManager.startRetrySeconds)
        system.connectOnStart = true
        engine.networkChanged(available: true)
        await until("active") { engine.state == .active }
        XCTAssertEqual(system.starts, 3)
    }

    /// A start that fails with the network up schedules one retry at the end of the 30 s floor,
    /// so it does not wait for a later change; that retry's own failure schedules no other.
    func testAFailedStartWithTheNetworkUpIsRetriedOnceAtTheEndOfTheFloor() async {
        var released = false
        engine.retryWait = { _ in
            while !released { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        engine.networkChanged(available: true)
        system.connectOnStart = false
        engine.setEnabled(true)
        await until("the start failed") { engine.state == .failed(.startFailed) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(system.starts, 1, "nothing before the floor ends")

        released = true
        await until("the scheduled retry failed") { system.starts == 2 && engine.state == .failed(.startFailed) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(system.starts, 2, "the scheduled retry schedules no other")

        engine.setEnabled(false)
        await until("off") { !engine.wantsOn }
    }

    /// A scheduled retry does nothing once the switch is turned off.
    func testAScheduledRetryDoesNothingAfterTurnOff() async {
        var released = false
        engine.retryWait = { _ in
            while !released { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        engine.networkChanged(available: true)
        system.connectOnStart = false
        engine.setEnabled(true)
        await until("the start failed") { engine.state == .failed(.startFailed) }
        engine.setEnabled(false)
        await until("off") { !engine.wantsOn }
        released = true
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(system.starts, 1)
    }

    /// `vpnb engine.on` or the switch while it is on but failed starts it over, at once.
    func testTurningOnWhileFailedStartsItOver() async {
        system.connectOnStart = false
        engine.setEnabled(true)
        await until("the start failed") { engine.state == .failed(.startFailed) }
        let activations = system.activationRequests
        system.connectOnStart = true
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        XCTAssertEqual(system.starts, 2)
        XCTAssertEqual(system.activationRequests, activations + 1)
    }

    /// Turned off while macOS's configuration prompt is open, then allowed: the enabling save
    /// that lands after the turn-off is disabled again, so no connection passes through the
    /// extension under a switch that says off.
    func testAnEnablingSaveThatLandsAfterATurnOffIsDisabled() async {
        system.holdSave = true
        system.holdOnlyEnablingSaves = true
        engine.setEnabled(true)
        await until("the configuration prompt") { engine.state == .awaitingConfigApproval }
        enabled = false
        engine.followSwitch()
        XCTAssertEqual(engine.state, .off)
        // The turn-off's own disable finds no configuration yet, so it saves nothing.
        await until("the turn-off's disable ran") { system.saves == [true, false] }
        XCTAssertNil(system.configuration)
        system.holdSave = false
        await until("the late save is disabled after it") { system.saves == [true, false, false] }
        XCTAssertEqual(system.configuration, false)
        XCTAssertEqual(system.starts, 0)
    }

    /// With the switch off, a configuration that cannot be read is disabled anyway: unknown is
    /// not "none", and one left enabled would keep every new connection passing through.
    func testAnUnreadableConfigurationIsDisabledWithTheSwitchOff() async {
        system.configuration = true
        // The launch read fails, and so does the first disabling save's own read.
        system.failingReads = 2
        engine.begin()
        await until("disabled on the second try") { system.configuration == false }
        XCTAssertEqual(system.saves, [false, false])
        XCTAssertTrue(engine.mayBeInstalled)
    }

    /// A configuration that cannot be read when turning on is a failed start, not a prompt
    /// waiting for approval, and no save is attempted.
    func testAnUnreadableConfigurationAtTurnOnIsAFailedStart() async {
        system.failingReads = 1
        engine.setEnabled(true)
        await until("failed start") { engine.state == .failed(.startFailed) }
        XCTAssertEqual(system.saves, [])
    }

    /// Off shows no counters, generation or version of the last session.
    func testTurningOffForgetsTheLastReply() async {
        system.claimedByRule = [ruleID.uuidString: 3]
        await turnOnToActive()
        XCTAssertNotNil(engine.reply)
        engine.setEnabled(false)
        XCTAssertNil(engine.reply)
        XCTAssertNil(engine.status().policyGeneration)
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

    /// Off is the old way: turning it off by hand stops the session, removes the configuration
    /// and files the deactivation request, so nothing of the extension stays on the Mac.
    func testTurningOffByHandRemovesTheConfigurationAndTheExtension() async {
        await turnOnToActive()
        system.deactivationAnswer = nil
        engine.setEnabled(false)
        XCTAssertEqual(engine.state, .off)
        XCTAssertFalse(enabled)
        XCTAssertEqual(system.stops, 1)
        XCTAssertEqual(engine.removal, .removing)
        XCTAssertEqual(engine.status().removal, "removing")
        await until("deactivation filed") { system.deactivationRequests == 1 }
        XCTAssertEqual(system.log.suffix(2), ["removeConfiguration", "deactivate"], "the configuration goes first")
        XCTAssertNil(system.configuration, "removed, not disabled")
        XCTAssertFalse(system.saves.contains(false), "no disabling save on the way")
        system.finishDeactivation(.removed)
        await until("removed") { engine.removal == .removed }
        XCTAssertFalse(system.installed)
        XCTAssertFalse(engine.mayBeInstalled)
        XCTAssertFalse(PerAppRouting.showsRemoveButton(enabled: enabled, state: engine.state,
                                                       mayBeInstalled: engine.mayBeInstalled, removal: engine.removal))
        XCTAssertEqual(engine.state, .off)
    }

    /// A turn-off the app makes by itself never shows a password prompt unasked: it disables
    /// the configuration, and Remove Extension then takes what is left.
    func testAnAutomaticTurnOffOnlyDisablesAndRemoveExtensionTakesTheRest() async {
        await turnOnToActive()
        system.crash()
        await until("restarted") { system.starts == 2 && engine.state == .active }
        system.crash()
        await until("turned off") { engine.state == .failed(.stoppedTwice) }
        await until("disabled") { system.configuration == false }
        XCTAssertEqual(system.deactivationRequests + system.configurationRemovals, 0)
        XCTAssertTrue(engine.mayBeInstalled)
        XCTAssertTrue(PerAppRouting.showsRemoveButton(enabled: enabled, state: engine.state,
                                                      mayBeInstalled: engine.mayBeInstalled, removal: engine.removal))

        engine.removeExtension()
        await until("removed") { engine.removal == .removed }
        XCTAssertNil(system.configuration)
        XCTAssertFalse(system.installed)
        XCTAssertEqual(system.deactivationRequests, 1)
        XCTAssertFalse(enabled)
    }

    /// At launch with the switch off, a configuration left behind shows Remove Extension; with
    /// none, nothing shows and nothing is asked.
    func testRemoveExtensionShowsOnlyWhenSomethingMayBeLeft() async {
        engine.begin()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(engine.mayBeInstalled)
        XCTAssertEqual(system.calls, 0)

        let left = FakeFlowEngineSystem()
        left.configuration = false
        let e = makeEngine(left)
        e.begin()
        await until("left behind") { e.mayBeInstalled }
        XCTAssertEqual(left.deactivationRequests, 0, "a launch never asks for a password")
        XCTAssertFalse(PerAppRouting.showsRemoveButton(enabled: true, state: .active, mayBeInstalled: true, removal: nil),
                       "never while the switch is on")
        XCTAssertFalse(PerAppRouting.showsRemoveButton(enabled: false, state: .unavailable(.notInThisBuild), mayBeInstalled: true, removal: nil))
        XCTAssertFalse(PerAppRouting.showsRemoveButton(enabled: false, state: .off, mayBeInstalled: true, removal: .removing))
    }

    /// A declined configuration leaves the activated extension with no configuration: the next
    /// launch still shows Remove Extension, and a finished removal forgets the activation.
    func testADeclinedConfigurationStillShowsRemoveExtensionAfterARelaunch() async {
        system.saveAnswer = .declined
        engine.setEnabled(true)
        await until("declined") { engine.state == .failed(.configurationDeclined) }
        XCTAssertTrue(activated)
        XCTAssertNil(system.configuration)

        let relaunched = makeEngine(system)
        relaunched.begin()
        await until("left behind") { relaunched.mayBeInstalled }
        XCTAssertEqual(system.deactivationRequests, 0, "a launch never asks for a password")
        relaunched.removeExtension()
        await until("removed") { relaunched.removal == .removed }
        XCTAssertFalse(activated)

        let again = makeEngine(system)
        again.begin()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(again.mayBeInstalled)
    }

    func testARemovalThatFailsOrWaitsForARestartSaysSo() async {
        for (answer, removal, left) in [(FlowEngineDeactivation.failed(code: 1), FlowEngineRemoval.failed, true),
                                        (.willCompleteAfterReboot, .needsRestart, false),
                                        (.failed(code: 4), .removed, false)] {
            let s = FakeFlowEngineSystem()
            s.configuration = false
            s.deactivationAnswer = answer == .failed(code: 4) ? FlowEngineDeactivation.forError(code: 4) : answer
            let e = makeEngine(s)
            e.removeExtension()
            await until("\(answer)") { e.removal == removal }
            XCTAssertEqual(e.mayBeInstalled, left, "\(answer)")
            XCTAssertEqual(e.state, .off)
        }
        let s = FakeFlowEngineSystem()
        s.configuration = false
        s.removeAnswer = false
        let e = makeEngine(s)
        e.removeExtension()
        await until("a configuration that stays is a failed removal") { e.removal == .failed }
    }

    /// A turn-on while the removal still waits for its password files the activation request
    /// only once the removal ended, so the deactivation cannot take away what it installs.
    func testATurnOnDuringARemovalWaitsForIt() async {
        await turnOnToActive()
        system.deactivationAnswer = nil
        engine.setEnabled(false)
        await until("deactivation filed") { system.deactivationRequests == 1 }
        engine.setEnabled(true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(system.activationRequests, 1, "nothing filed while the removal waits")
        XCTAssertNil(engine.removal, "the turn-on reports its own state")
        system.finishDeactivation(.removed)
        await until("active again") { engine.state == .active }
        XCTAssertEqual(system.log.suffix(3), ["removeConfiguration", "deactivate", "activate"])
        XCTAssertTrue(system.installed)
        XCTAssertEqual(system.configuration, true)
        XCTAssertNil(engine.removal)
    }

    func testRemoveExtensionIsRefusedWhereItCannotRun() async {
        let unsupported = FakeFlowEngineSystem()
        unsupported.support = .unavailable(.notInThisBuild)
        let e = makeEngine(unsupported)
        e.removeExtension()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(unsupported.calls, 0)
        XCTAssertNil(e.removal)
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
        XCTAssertNil(engine.reply, "a reply that confirms nothing is not shown as the extension's state")
        XCTAssertNil(engine.status().policyGeneration)
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

    /// The General page's count: the first reply after a turn-on says 0, and connections made
    /// right after it must show without waiting for the next heartbeat (live on the mini,
    /// 2026-11-05). A status request reads them; it pushes nothing.
    func testCountsAreReadBetweenHeartbeats() async {
        await turnOnToActive()
        let pushes = system.sent.count
        XCTAssertEqual(PerAppRouting.countsLine(engine.reply), "0 connections went around the VPN since the extension started.")
        system.claimedByRule = [ruleID.uuidString: 4]
        await engine.refreshCounts()
        XCTAssertEqual(system.statusRequests, 1)
        XCTAssertEqual(system.sent.count, pushes, "no policy push")
        XCTAssertEqual(PerAppRouting.countsLine(engine.reply), "4 connections went around the VPN since the extension started.")
        XCTAssertEqual(engine.counters(forRule: ruleID.uuidString)?.claimed, 4)

        // An answer that is not the confirmed policy's (an extension that restarted) is left to
        // the heartbeat, and so is no answer.
        system.replies = []
        system.answersStatus = false
        system.claimedByRule = [ruleID.uuidString: 9]
        await engine.refreshCounts()
        XCTAssertEqual(engine.counters(forRule: ruleID.uuidString)?.claimed, 4)

        // Off, nothing is asked.
        engine.setEnabled(false)
        await until("off") { engine.state == .off }
        system.answersStatus = true
        let asked = system.statusRequests
        await engine.refreshCounts()
        XCTAssertEqual(system.statusRequests, asked)
    }

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
        // A route deleted or turned off matches nothing (FlowPolicyCompiler drops the rule).
        var directOff = direct
        directOff.enabled = false
        XCTAssertEqual(ProcessRule.serving(app, engine: .active, routes: [directOff]).servedBy, RuleServedBy.none)
        XCTAssertEqual(ProcessRule.serving(app, engine: .active, routes: [directOff]).reason, .routeUnavailable)
        XCTAssertEqual(ProcessRule.serving(app, engine: .active, routes: []).reason, .routeUnavailable)
        XCTAssertEqual(ProcessRule.serving(app, engine: .unavailable(.notInThisBuild), routes: []).reason, .perAppRoutingNotAvailable)
        XCTAssertEqual(RuleRow.detail(for: app, route: nil, engine: .active), "Inactive: this rule's route was deleted or is turned off.")
        // A rule turned off is not served and gets no note: its switch says it.
        var appOff = app
        appOff.enabled = false
        XCTAssertEqual(ProcessRule.serving(appOff, engine: .active, routes: [direct]).servedBy, RuleServedBy.none)
        XCTAssertNil(ProcessRule.serving(appOff, engine: .active, routes: [direct]).reason)
        XCTAssertNil(RuleRow.detail(for: appOff, route: direct, engine: .active))
        XCTAssertNil(RuleRow.detail(for: appOff, route: direct, engine: .off), "no note in any engine state")
        XCTAssertNil(ProcessRule.serving(appOff, engine: .off, routes: []).reason, "nor for a deleted route")
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
        // Active: a rule on another route is named with its real reason, the route.
        let toVPN = Rule(matchType: .process, pattern: "com.example.Other", routeId: vpn.id, order: 1)
        s.rules = [app, toVPN]
        s.routes = [direct, vpn]
        s.flowEngine = .active
        let active = SiteRoute.match(host: "example.org", addresses: ["203.0.113.9"], in: s)
        XCTAssertEqual(active.inactiveAppRules, ["com.example.Other"])
        XCTAssertEqual(SiteRoute.inactiveAppRulesSentence(active.inactiveAppRules, engine: active.appRulesEngine),
                       "Rules for apps (com.example.Other) change nothing now: per-app routing serves only rules whose route is Direct and turned on.")
    }

    /// The VPN client's team must reach the policy: a failed signature read is not kept, and a
    /// binary changed at the same path is read again.
    @MainActor
    func testATunnelOwnersTeamIsReadAgainAfterAFailureOrAChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); TunnelOwnerTeams.read = TunnelOwnerTeams.signingTeam; TunnelOwnerTeams.resetCache() }
        let exe = dir.appendingPathComponent("vpnclient")
        try Data("a".utf8).write(to: exe)
        TunnelOwnerTeams.resetCache()
        var answer: String? = nil
        var reads = 0
        TunnelOwnerTeams.read = { _ in reads += 1; return answer }
        XCTAssertNil(TunnelOwnerTeams.team(ofExecutable: exe.path))
        answer = "TEAMONE111"
        XCTAssertEqual(TunnelOwnerTeams.team(ofExecutable: exe.path), "TEAMONE111", "a failed read is tried again")
        XCTAssertEqual(TunnelOwnerTeams.team(ofExecutable: exe.path), "TEAMONE111")
        XCTAssertEqual(reads, 2, "a found team is cached")
        answer = "TEAMTWO222"
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: exe.path)
        XCTAssertEqual(TunnelOwnerTeams.team(ofExecutable: exe.path), "TEAMTWO222", "a changed binary is read again")
    }

    func testEngineStatusIsAReadVerbAndOnOffAreNot() {
        XCTAssertFalse(CommandRouter.isMutating("engine.status"))
        XCTAssertTrue(CommandRouter.isMutating("engine.on"))
        XCTAssertTrue(CommandRouter.isMutating("engine.off"))
        XCTAssertTrue(CommandRouter.isMutating("engine.remove"))
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
        XCTAssertEqual(FlowEngineRemoval.removed.line(in: es), "La extensión se quitó de este Mac.")
        XCTAssertEqual(FlowEngineRemoval.needsRestart.line(in: fr), "macOS retire l'extension au redémarrage du Mac.")
        XCTAssertNotEqual(PerAppRouting.offNote(in: fr), PerAppRouting.offNote())
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
