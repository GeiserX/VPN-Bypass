// FlowEngineManager.swift
// Per-app routing's app side: turns the extension on and off, keeps its policy fresh, and
// decides what to do when it fails. The kernel engine never reads anything from here: routes,
// /etc/hosts and the wildcard forwarder run the same whether this is on, off or failing.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, 3.3 (config delivery), 3.7 (failures) and 5
// (states). In short:
// - Off by default. Turning it on files the activation request, saves the configuration
//   enabled (macOS asks twice, once for each), starts the session and pushes the policy.
// - Every change of rules, mode, Pause, the VPN's kill switch or the network pushes the policy
//   again; a 30 s heartbeat renews its 2-minute lease. A push that can stop the extension
//   claiming something counts only once the extension echoes its generation; with no echo
//   within 10 s the session is stopped, so listed apps go into the VPN at once.
// - A stopped or silent extension is started again once; a second failure within 10 minutes
//   turns per-app routing off (a crash stalls every new TCP connection for about 5 s, so it
//   must not loop).
// - Turning it off by hand (the switch, `vpnb engine.off`) or Remove Extension removes the
//   configuration and files the deactivation request, so nothing of it stays on the Mac: off is
//   the old way. A turn-off the app makes by itself (a second failure, a declined
//   configuration, a config.json switched off) only disables the configuration, so no password
//   prompt appears unasked; Remove Extension takes what is left.

import Combine
import Foundation
import VPNBypassPolicy

/// The levels the manager logs at; the app maps them onto its own log.
enum FlowEngineLogLevel {
    case info, warning, error
}

@MainActor
final class FlowEngineManager: ObservableObject {
    static let shared = FlowEngineManager(system: LiveFlowEngineSystem())

    /// How often the policy is pushed again, well inside its lease (3.3).
    static let heartbeatSeconds: TimeInterval = 30
    /// A second failure within this window turns per-app routing off (3.7).
    static let failureWindow: TimeInterval = 600
    /// Tries per heartbeat before the extension counts as silent: one reply can go missing with
    /// the session healthy (spike A3), so a heartbeat retries twice.
    static let heartbeatTries = 3
    /// How long a started session may take to connect.
    static let startTimeout: TimeInterval = 10

    @Published private(set) var state: FlowEngineState
    /// The extension's last reply (counters, version).
    @Published private(set) var reply: FlowEngineReplySummary?
    /// The last removal since launch (nil: none ran).
    @Published private(set) var removal: FlowEngineRemoval?
    /// A configuration of ours exists, so the extension may be installed: Remove Extension shows.
    @Published private(set) var mayBeInstalled = false

    let system: FlowEngineSystem
    /// What the policy is compiled from. Wired to RouteManager by `start(observing:)`
    /// (FlowEngineWiring.swift); this file knows nothing of the rest of the app, so the live
    /// test driver (scripts/ne-live) compiles it as it is.
    var inputs: @MainActor () async -> FlowPolicyCompiler.Input = { FlowPolicyCompiler.Input(mode: .bypass) }
    /// The saved switch, and how to change it (both config.json).
    var isEnabled: @MainActor () -> Bool = { false }
    var saveEnabled: @MainActor (Bool) -> Void = { _ in }
    var log: @MainActor (FlowEngineLogLevel, String) -> Void = { _, _ in }
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    /// The wait between heartbeats (a seam: tests send them by hand).
    var heartbeatWait: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    /// The app's version, to tell an extension whose update waits.
    var appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// The user wants it running and this manager is acting on that.
    private(set) var wantsOn = false
    /// Raised on every turn-on and turn-off, so a late callback of an earlier attempt does nothing.
    private var attempt = 0
    /// The session reached `connected` in this attempt, so its end is a failure, not a start-up.
    private var established = false
    /// The app stopped the session itself; the status change that follows is not a crash.
    private var stoppingOnPurpose = false
    /// The policy the extension last confirmed (nil: unknown, e.g. after a launch).
    private(set) var confirmed: FlowPolicy?
    private var lastGeneration = 0
    private var failures: [Date] = []
    private var heartbeatTask: Task<Void, Never>?
    private var pushing = false
    private var pushAgain = false
    private var forceNext = false
    private var activity: NSObjectProtocol?
    /// The disable or removal a turn-off started; the next turn-on waits for it, so a late disable
    /// cannot land after the enabling read, and a removal cannot take away what a turn-on installs.
    private var pendingTeardown: Task<Void, Never>?
    /// Removals not finished yet (a deactivation can wait minutes for the password).
    private var removalsInFlight = 0
    var subscriptions: Set<AnyCancellable> = []
    private(set) var started = false

    init(system: FlowEngineSystem) {
        self.system = system
        if case .unavailable(let why) = system.support {
            state = .unavailable(why)
        } else {
            state = .off
        }
        system.onSessionChange = { [weak self] in self?.sessionChanged() }
    }

    // MARK: - Launch and the switch

    /// Marks the manager wired (`start(observing:)` in FlowEngineWiring.swift), then follows
    /// the saved switch; with it off, disables a configuration of ours left enabled.
    func begin() {
        guard !started else { return }
        started = true
        followSwitch()
        if !wantsOn { Task { await disableStaleConfiguration() } }
    }

    /// The switch in Settings or `vpnb engine.on|off`. Turning it on by hand forgets earlier
    /// failures, so a user who saw "stopped twice" can try again. Turning it off by hand removes
    /// the extension too.
    func setEnabled(_ on: Bool) {
        if on { failures.removeAll() }
        if isEnabled() != on { saveEnabled(on) }
        guard on || !wantsOn else {
            turnOff(teardown: .remove)
            return
        }
        followSwitch()
    }

    /// Remove Extension and `vpnb engine.remove`: turns per-app routing off if it is on, removes
    /// its configuration and files the deactivation request.
    func removeExtension() {
        guard case .supported = system.support, removalsInFlight == 0 || wantsOn else { return }
        if isEnabled() { saveEnabled(false) }
        if wantsOn {
            turnOff(teardown: .remove)
        } else {
            startRemoval()
        }
    }

    /// Starts or stops to match the saved switch (also after an import or a profile switch).
    func followSwitch() {
        guard case .supported = system.support else { return }
        let want = isEnabled()
        if want, !wantsOn { turnOn() }
        if !want, wantsOn { turnOff() }
    }

    /// Something the policy is made of changed: the switch, rules, mode, Pause, the kill switch
    /// or the network.
    func inputsChanged() {
        followSwitch()
        if wantsOn, established { requestPush(force: false) }
    }

    private func turnOn() {
        wantsOn = true
        attempt += 1
        let a = attempt
        beginActivity()
        state = .starting
        removal = nil
        // A removal still waiting for its password would take away what this turn-on installs:
        // the activation request is filed once it ended.
        if removalsInFlight > 0, let teardown = pendingTeardown {
            Task { [weak self] in
                await teardown.value
                guard let self, self.attempt == a else { return }
                self.fileActivation(a)
            }
        } else {
            fileActivation(a)
        }
    }

    private func fileActivation(_ a: Int) {
        log(.info, "Per-app routing: turning on (activation request filed)")
        system.requestActivation(onNeedsApproval: { [weak self] replacing in
            guard let self, self.attempt == a else { return }
            // An update whose replacement waits (6.4): the old extension gets no policy from this
            // app, so its lease runs out and listed apps use the VPN until the user allows it.
            self.state = replacing ? .updateWaiting : .awaitingExtensionApproval
            self.log(.info, replacing
                ? "Per-app routing: an update of the extension waits to be allowed in System Settings"
                : "Per-app routing: waiting for the extension to be allowed in System Settings")
        }, completion: { [weak self] outcome in
            guard let self, self.attempt == a else { return }
            switch outcome {
            case .activated:
                self.mayBeInstalled = true
                Task { await self.configureAndStart(a) }
            case .willCompleteAfterReboot:
                self.state = .blocked(.needsRestart)
            case .failed(let code):
                self.log(.warning, "Per-app routing: the activation request failed (code \(code))")
                self.state = FlowEngineState.forActivationError(code: code)
            }
        })
    }

    /// What a turn-off does to the configuration: nothing (a declined save left none), disable
    /// it (a turn-off the app makes by itself), or remove it with the extension (by hand).
    private enum Teardown { case none, disable, remove }

    private func turnOff(teardown: Teardown = .disable) {
        wantsOn = false
        attempt += 1
        established = false
        confirmed = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        endActivity()
        stoppingOnPurpose = true
        system.stopSession()
        state = .off
        log(.info, "Per-app routing: turned off; every app follows the routes again")
        switch teardown {
        case .none: break
        case .disable: disableConfiguration()
        case .remove: startRemoval()
        }
    }

    /// With the switch off, a configuration of ours left enabled (a config.json replaced while it
    /// ran) would keep every new TCP connection passing through the extension: disable it.
    private func disableStaleConfiguration() async {
        guard case .supported = system.support, !wantsOn else { return }
        let existing = await system.loadConfiguration()
        if existing != nil { mayBeInstalled = true }
        guard existing == true, !wantsOn else { return }
        log(.info, "Per-app routing is off, so its configuration left enabled is turned off")
        disableConfiguration()
    }

    /// Saves the configuration disabled, after any disable still in flight.
    private func disableConfiguration() {
        let previous = pendingTeardown
        pendingTeardown = Task { [system] in
            await previous?.value
            _ = await system.saveConfiguration(enabled: false)
        }
    }

    /// Removes the configuration, then files the deactivation request, after any teardown still
    /// in flight. The session was stopped by the turn-off, or was not running.
    private func startRemoval() {
        removal = .removing
        removalsInFlight += 1
        log(.info, "Per-app routing: removing its configuration and the extension (macOS asks for an administrator password)")
        let previous = pendingTeardown
        pendingTeardown = Task { [weak self, system] in
            await previous?.value
            let configurationRemoved = await system.removeConfiguration()
            let outcome: FlowEngineDeactivation = await withCheckedContinuation { continuation in
                system.requestDeactivation { continuation.resume(returning: $0) }
            }
            self?.finishRemoval(configurationRemoved: configurationRemoved, outcome)
        }
    }

    private func finishRemoval(configurationRemoved: Bool, _ outcome: FlowEngineDeactivation) {
        removalsInFlight -= 1
        let result: FlowEngineRemoval
        switch outcome {
        case .removed:
            result = configurationRemoved ? .removed : .failed
        case .willCompleteAfterReboot:
            result = configurationRemoved ? .needsRestart : .failed
        case .failed(let code):
            log(.warning, "Per-app routing: the extension could not be removed (code \(code))")
            result = .failed
        }
        if !configurationRemoved { log(.warning, "Per-app routing: its configuration could not be removed") }
        if result != .failed { log(.info, result == .removed
            ? "Per-app routing: the extension and its configuration are removed"
            : "Per-app routing: its configuration is removed; macOS removes the extension at the next restart") }
        // A turn-on that waited for this removal reports its own state; the removal stays
        // visible only while per-app routing is off.
        guard !wantsOn else { return }
        removal = result
        mayBeInstalled = result == .failed
    }

    private func configureAndStart(_ a: Int) async {
        await pendingTeardown?.value
        guard attempt == a else { return }
        if await system.loadConfiguration() != true {
            guard attempt == a else { return }
            state = .awaitingConfigApproval
            let saved = await system.saveConfiguration(enabled: true)
            guard attempt == a else { return }
            switch saved {
            case .saved:
                break
            case .declined:
                log(.info, "Per-app routing: the proxy configuration was not allowed, so it is off again")
                turnOff(teardown: .none)
                saveEnabled(false)
                state = .failed(.configurationDeclined)
                return
            case .failed(let code):
                log(.warning, "Per-app routing: the configuration could not be saved (code \(code))")
                state = .failed(.startFailed)
                return
            }
        }
        guard attempt == a else { return }
        await startSession(a)
    }

    private func startSession(_ a: Int) async {
        if state != .failed(.stoppedRestarting) { state = .starting }
        established = false
        stoppingOnPurpose = false
        confirmed = nil
        if system.session != .connected {
            guard system.startSession() else {
                log(.warning, "Per-app routing: the session would not start")
                state = .failed(.startFailed)
                return
            }
            var waited: TimeInterval = 0
            while system.session != .connected, waited < Self.startTimeout {
                await sleep(0.25)
                waited += 0.25
                guard attempt == a else { return }
            }
            guard system.session == .connected else {
                log(.warning, "Per-app routing: the session did not connect within \(Int(Self.startTimeout)) s")
                stoppingOnPurpose = true
                system.stopSession()
                state = .failed(.startFailed)
                return
            }
        }
        established = true
        startHeartbeat(a)
        requestPush(force: true)
    }

    // MARK: - Policy push

    /// Pushes now, or right after the push in flight, so pushes never overlap.
    func requestPush(force: Bool) {
        if force { forceNext = true }
        if pushing { pushAgain = true; return }
        pushing = true
        Task {
            // The attempt is read on every round: a push requested by a new attempt while an
            // older attempt's push was still in flight runs here, instead of being dropped until
            // the next heartbeat.
            repeat {
                pushAgain = false
                let f = forceNext
                forceNext = false
                await push(attempt, force: f)
            } while pushAgain && established
            pushing = false
        }
    }

    /// A generation that rises across launches too, so an extension still holding the last
    /// launch's policy never sees an older number.
    private func nextGeneration() -> Int {
        lastGeneration = max(lastGeneration + 1, Int(now().timeIntervalSince1970 * 10))
        return lastGeneration
    }

    private func push(_ a: Int, force: Bool) async {
        let input = await inputs()
        guard attempt == a, established else { return }
        let policy = FlowPolicyCompiler.compile(input, generation: nextGeneration())
        if !force, let confirmed, confirmed.matchers == policy.matchers, confirmed.declinedTeams == policy.declinedTeams {
            state = Self.state(after: input)
            return
        }
        let shrinks = policy.shrinksClaims(from: confirmed)
        guard let data = try? FlowPolicyMessage.encode(policy) else { return }
        // A push that can stop a claim gets one try of 10 s (3.3); the others retry like the
        // heartbeat before the extension counts as silent.
        let tries = shrinks ? 1 : Self.heartbeatTries
        var answer: FlowPolicyReply?
        for _ in 0..<tries {
            let raw = await system.send(data, timeout: TimeInterval(FlowPolicy.echoTimeoutSeconds))
            guard attempt == a, established else { return }
            if let raw, let decoded = try? JSONDecoder().decode(FlowPolicyReply.self, from: raw) {
                answer = decoded
                break
            }
        }
        guard let answer else {
            log(.warning, shrinks
                ? "Per-app routing: no echo within \(FlowPolicy.echoTimeoutSeconds) s for a change that takes apps out, so its session is stopped"
                : "Per-app routing: the extension did not answer \(tries) times")
            await failed(a)
            return
        }
        if answer.rejectedVersion != nil {
            if state != .updateWaiting { log(.warning, "Per-app routing: the running extension does not read this app's policy; its update waits for approval") }
            state = .updateWaiting
            return
        }
        guard answer.confirms(policy) else {
            log(.warning, "Per-app routing: the extension did not confirm policy \(policy.generation)")
            await failed(a)
            return
        }
        // Published only once confirmed: `policyGeneration` in the status is the confirmed one.
        reply = Self.summary(answer)
        confirmed = policy
        let next = Self.state(after: input)
        if next != state { log(.info, "Per-app routing: \(next.code)\(next.reasonCode.map { " (\($0))" } ?? ""), policy \(policy.generation), \(policy.matchers.count) app rule(s)") }
        state = next
    }

    /// The state a confirmed policy compiled from `input` puts the engine in.
    static func state(after input: FlowPolicyCompiler.Input) -> FlowEngineState {
        if input.paused { return .paused(.pause) }
        if input.killSwitchActive { return .paused(.killSwitch) }
        if input.mode == .vpnOnly { return .paused(.vpnOnly) }
        return .active
    }

    static func summary(_ r: FlowPolicyReply) -> FlowEngineReplySummary {
        FlowEngineReplySummary(policyGeneration: r.policyGeneration, extensionVersion: r.extensionVersion,
                               claimedByRule: r.claimedByRule, boundByRule: r.boundByRule,
                               declined: r.declined, leaseExpiries: r.leaseExpiries)
    }

    private func startHeartbeat(_ a: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while true {
                guard let wait = self?.heartbeatWait else { return }
                await wait(Self.heartbeatSeconds)
                guard let self, !Task.isCancelled, self.attempt == a, self.established else { return }
                self.requestPush(force: true)
            }
        }
    }

    // MARK: - Failures

    private func sessionChanged() {
        guard wantsOn, established, !stoppingOnPurpose else { return }
        guard system.session == .disconnected || system.session == .none else { return }
        log(.warning, "Per-app routing: the extension's session ended on its own")
        let a = attempt
        Task { await failed(a) }
    }

    /// The extension stopped, went silent or did not confirm: stop what is left of the session,
    /// start it once, and turn per-app routing off on a second failure within 10 minutes.
    private func failed(_ a: Int) async {
        guard attempt == a, established else { return }
        established = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stoppingOnPurpose = true
        system.stopSession()
        let t = now()
        failures = failures.filter { t.timeIntervalSince($0) < Self.failureWindow } + [t]
        if failures.count >= 2 {
            log(.error, "Per-app routing stopped twice within 10 minutes, so it is turned off; listed apps use the VPN")
            turnOff()
            saveEnabled(false)
            state = .failed(.stoppedTwice)
            return
        }
        log(.warning, "Per-app routing stopped; listed apps use the VPN. Starting it again once")
        state = .failed(.stoppedRestarting)
        await sleep(1)
        guard attempt == a else { return }
        await startSession(a)
    }

    // MARK: - App Nap

    /// While it is on, timers must not be delayed past the lease (3.3).
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Per-app routing renews its policy every 30 seconds")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: - Reading

    /// A rule's counters from the last reply, nil when it has none.
    func counters(forRule id: String) -> FlowEngineRuleCounters? {
        guard let reply, reply.claimedByRule[id] != nil || reply.boundByRule[id] != nil else { return nil }
        return FlowEngineRuleCounters(ruleId: id, claimed: reply.claimedByRule[id] ?? 0, bound: reply.boundByRule[id] ?? 0)
    }

    /// The `status` and `engine.status` field.
    func status() -> FlowEngineStatus {
        FlowEngineStatus(enabled: isEnabled(), state: state, reply: reply, appVersion: appVersion, removal: removal)
    }

    /// An extension of another version than the app answers: its update waits for approval.
    var updateWaiting: Bool {
        if state == .updateWaiting { return true }
        guard let ext = reply?.extensionVersion, let appVersion else { return false }
        return ext != appVersion
    }

    /// For the doc screenshots: shows a state and counters without an extension.
    func showForScreenshots(_ state: FlowEngineState?, reply: FlowEngineReplySummary? = nil,
                            removal: FlowEngineRemoval? = nil, mayBeInstalled: Bool = false) {
        self.removal = removal
        self.mayBeInstalled = mayBeInstalled
        if let state {
            self.state = state
        } else if case .unavailable(let why) = system.support {
            self.state = .unavailable(why)
        } else {
            self.state = .off
        }
        self.reply = reply
    }
}

