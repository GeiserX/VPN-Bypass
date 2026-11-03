// HelperUpdatePendingTests.swift
// A helper update waits for the administrator password, which can take hours on a locked
// screen. Meanwhile the older helper still answers, so the app keeps using it: the control
// socket answers, routes stay, and a cancel or a timeout leaves the app working on the old
// helper, logged once, with no prompt loop.

import XCTest
@testable import VPNBypassCore

@MainActor
final class HelperUpdatePendingTests: XCTestCase {

    private var hm: HelperManager { HelperManager.shared }
    private var rm: RouteManager { RouteManager.shared }
    private var saved: (state: HelperState, version: String?, pending: HelperManager.PendingUpdate?, error: String?,
                        install: @Sendable () -> HelperManager.AdminInstallOutcome,
                        routes: [RouteManager.ActiveRoute], logs: [RouteManager.LogEntry])!

    /// Counts installer calls from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    override func setUp() async throws {
        saved = (hm.helperState, hm.helperVersion, hm.pendingUpdate, hm.installationError, HelperManager.adminInstall,
                 rm.activeRoutes, rm.recentLogs)
        hm.pendingUpdate = nil
        hm.helperState = .checking
        rm.recentLogs = []
    }

    override func tearDown() async throws {
        await hm.updateTask?.value
        HelperManager.adminInstall = saved.install
        hm.versionProbeOverrideForTests = nil
        hm.helperState = saved.state
        hm.helperVersion = saved.version
        hm.pendingUpdate = saved.pending
        hm.installationError = saved.error
        rm.activeRoutes = saved.routes
        rm.recentLogs = saved.logs
    }

    /// Waits up to 5 s for the installer to start, off the main actor.
    nonisolated private static func reached(_ entered: DispatchSemaphore) -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    private func logLines(containing text: String) -> [String] {
        rm.recentLogs.map(\.message).filter { $0.contains(text) }
    }

    /// The password prompt never returns here (it is released after the check). `vpnb status`
    /// must still answer within a second: the prompt runs off the main thread, which serves the
    /// control socket's handler.
    func testAPendingUpdateDoesNotBlockTheControlSocket() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        HelperManager.adminInstall = {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return .cancelled
        }
        hm.versionProbeOverrideForTests = { .version("2.6.0") }

        XCTAssertTrue(hm.adoptOlderHelperAndUpdate(installed: "2.6.0", expected: "2.7.0"))

        let (reached, elapsed, response) = await Task.detached { () -> (Bool, TimeInterval, ControlResponse?) in
            guard Self.reached(entered) else { return (false, 0, nil) }
            let start = Date()
            let response = await ControlSurface.handle(ControlRequest(cmd: "status"))
            return (true, Date().timeIntervalSince(start), response)
        }.value
        release.signal()

        XCTAssertTrue(reached, "the update reached the password prompt")
        XCTAssertLessThan(elapsed, 1, "status answered while the password prompt was open")
        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.result?.runtime?.helperReady, true, "the older helper counts as ready")
        XCTAssertEqual(response?.result?.runtime?.helperState, "Helper v2.6.0 running, update to v2.7.0 pending")
    }

    /// While the prompt waits, the older helper is the helper: route, resolver and forwarder
    /// work goes on through it, and nothing already applied is removed.
    func testRoutesStayAppliedWhileTheUpdateWaits() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        HelperManager.adminInstall = {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return .cancelled
        }
        hm.versionProbeOverrideForTests = { .version("2.6.0") }
        let routes = [RouteManager.ActiveRoute(destination: "198.51.100.7", gateway: "192.0.2.1", source: "example.com", timestamp: Date()),
                      RouteManager.ActiveRoute(destination: "198.51.100.8", gateway: "192.0.2.1", source: "*.example.net", timestamp: Date())]
        rm.activeRoutes = routes

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.6.0", expected: "2.7.0")
        let reached = await Task.detached { Self.reached(entered) }.value

        XCTAssertTrue(reached)
        XCTAssertTrue(hm.isHelperInstalled, "every route, hosts and wildcard path checks this gate")
        XCTAssertEqual(hm.helperVersion, "2.6.0")
        XCTAssertEqual(hm.pendingUpdate, .waiting(installed: "2.6.0", expected: "2.7.0"))
        XCTAssertEqual(rm.activeRoutes.map(\.destination), routes.map(\.destination), "nothing applied is removed")
        release.signal()
        await hm.updateTask?.value
        XCTAssertEqual(rm.activeRoutes.map(\.destination), routes.map(\.destination), "nor after the cancel")
    }

    /// A cancelled prompt: the old helper keeps working, one log line says so, and nothing asks
    /// again until the user clicks Update (or the next launch).
    func testCancelKeepsTheOldHelperWithOneLogLineAndNoPromptLoop() async throws {
        let calls = Counter()
        HelperManager.adminInstall = { calls.increment(); return .cancelled }
        hm.versionProbeOverrideForTests = { .version("2.6.0") }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.6.0", expected: "2.7.0")
        await hm.updateTask?.value

        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(hm.helperState.isReady)
        XCTAssertEqual(hm.helperVersion, "2.6.0")
        XCTAssertEqual(hm.pendingUpdate, .notInstalled(installed: "2.6.0", expected: "2.7.0", reason: .cancelled))
        XCTAssertEqual(logLines(containing: "not installed").count, 1, rm.recentLogs.map(\.message).joined(separator: "\n"))

        // Nothing asks again by itself, and a later readiness check does not prompt.
        try await Task.sleep(nanoseconds: 300_000_000)
        let ready = await hm.ensureHelperReady()
        XCTAssertTrue(ready)
        XCTAssertNil(hm.updateTask)
        XCTAssertEqual(calls.count, 1, "no prompt loop")
        XCTAssertEqual(logLines(containing: "not installed").count, 1)

        // The Update button asks once; a second click while that prompt is open does nothing.
        hm.retryPendingUpdate()
        hm.retryPendingUpdate()
        await hm.updateTask?.value
        XCTAssertEqual(calls.count, 2)
    }

    func testATimedOutPromptKeepsTheOldHelper() async throws {
        HelperManager.adminInstall = { .timedOut }
        hm.versionProbeOverrideForTests = { .version("2.6.0") }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.6.0", expected: "2.7.0")
        await hm.updateTask?.value

        XCTAssertTrue(hm.helperState.isReady)
        XCTAssertEqual(hm.pendingUpdate, .notInstalled(installed: "2.6.0", expected: "2.7.0", reason: .timedOut))
        XCTAssertEqual(logLines(containing: "no password was entered").count, 1)
    }

    func testAnInstalledUpdateIsUsedAtOnce() async throws {
        HelperManager.adminInstall = { .installed }
        hm.versionProbeOverrideForTests = { .version("2.7.0") }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.6.0", expected: "2.7.0")
        await hm.updateTask?.value

        XCTAssertTrue(hm.helperState.isReady)
        XCTAssertEqual(hm.helperVersion, "2.7.0")
        XCTAssertNil(hm.pendingUpdate)
        XCTAssertNil(hm.installationError)
    }

    /// The script stopped the old helper and the new one never answered: nothing routes, and
    /// the state must say so instead of claiming the old helper still works.
    func testAnUpdateThatLeftNoHelperFails() async throws {
        HelperManager.adminInstall = { .failed("Bootstrap failed: 5") }
        hm.versionProbeOverrideForTests = { .unreachable }

        _ = hm.adoptOlderHelperAndUpdate(installed: "2.6.0", expected: "2.7.0")
        await hm.updateTask?.value

        XCTAssertTrue(hm.helperState.isFailed)
        XCTAssertNil(hm.pendingUpdate)
        XCTAssertEqual(hm.installationError, "Bootstrap failed: 5")
    }

    /// The Status page shows a cancel or a timeout in the user's language, never the English
    /// log text.
    func testACancelReachesTheStatusPageTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/VPNBypassCore/Resources/es.lproj/Localizable.strings").path
        let es = try XCTUnwrap(NSDictionary(contentsOfFile: file) as? [String: String])
        for outcome in [HelperManager.AdminInstallOutcome.cancelled, .timedOut] {
            XCTAssertNotEqual(outcome.localizedText, outcome.logText, "\(outcome)")
            XCTAssertNotNil(es[outcome.localizedText], "\(outcome) has a Spanish string")
        }
    }

    // MARK: - An older helper and the methods it lacks

    func testVersionGateComparesNumerically() {
        XCTAssertTrue(HelperManager.helper("2.6.0", supports: "2.5.0"))
        XCTAssertTrue(HelperManager.helper("2.5.0", supports: "2.5.0"))
        XCTAssertTrue(HelperManager.helper("2.10.0", supports: "2.6.0"))
        XCTAssertFalse(HelperManager.helper("2.4.9", supports: "2.5.0"))
        XCTAssertFalse(HelperManager.helper("1.9", supports: "2.2.0"))
        XCTAssertTrue(HelperManager.helper(nil, supports: "2.6.0"), "unknown version: try the call")
    }

    /// A helper older than wildcards answers the wildcard and capture calls at once as
    /// unavailable, instead of each waiting out the XPC deadline.
    func testAnOlderHelperDegradesOneFeatureWithoutWaiting() async throws {
        hm.helperState = .ready
        hm.helperVersion = "2.4.0"
        hm.pendingUpdate = .waiting(installed: "2.4.0", expected: "2.7.0")

        let start = Date()
        let wildcards = await hm.setWildcards([], guard: WildcardSafetyGuard())
        let drained = await hm.drainWildcardRoutes()
        let blocks = await hm.addBlockRoutesBatch(destinations: ["198.51.100.9"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)

        XCTAssertFalse(wildcards.ok)
        XCTAssertTrue(wildcards.error?.contains("predates wildcards") ?? false, wildcards.error ?? "nil")
        XCTAssertNil(drained)
        XCTAssertEqual(blocks.failedDestinations, ["198.51.100.9"])
        XCTAssertTrue(hm.isHelperInstalled, "the rest still goes through the older helper")
    }

    // MARK: - The prompt itself

    func testOsascriptOutcomes() {
        XCTAssertEqual(HelperManager.adminScriptOutcome(status: 0, stderr: ""), .installed)
        XCTAssertEqual(HelperManager.adminScriptOutcome(status: 1, stderr: "0:120: execution error: User canceled. (-128)\n"), .cancelled)
        XCTAssertEqual(HelperManager.adminScriptOutcome(status: 1, stderr: "0:50: execution error: Bootstrap failed: 5 (5)\n"),
                       .failed("0:50: execution error: Bootstrap failed: 5 (5)"))
        XCTAssertEqual(HelperManager.adminScriptOutcome(status: 1, stderr: ""), .failed("osascript exited with 1"))
    }

    func testAdminScriptQuotesTheCommandAndThePrompt() {
        let script = HelperManager.adminScript(shellCommand: "cp '/a \"b\"' /c", prompt: "Say \"hi\"")
        XCTAssertEqual(script, #"do shell script "cp '/a \"b\"' /c" with prompt "Say \"hi\"" with administrator privileges"#)
    }

    // MARK: - Status page

    func testStatusPageSaysTheUpdateWaitsAndOffersARetryAfterACancel() {
        let waiting = HelperManager.PendingUpdate.waiting(installed: "2.6.0", expected: "2.7.0")
        let cancelled = HelperManager.PendingUpdate.notInstalled(installed: "2.6.0", expected: "2.7.0", reason: .cancelled)
        let timedOut = HelperManager.PendingUpdate.notInstalled(installed: "2.6.0", expected: "2.7.0", reason: .timedOut)

        XCTAssertEqual(StatusPage.helperLine(.ready, version: "2.6.0", pending: waiting).tone, .warn)
        XCTAssertEqual(StatusPage.helperLine(.ready, version: "2.7.0").tone, .ok)
        XCTAssertEqual(StatusPage.helperHint(.ready, pending: waiting),
                       "Helper update to version 2.7.0 waiting for your password. The installed helper keeps routing until then.")
        XCTAssertNil(StatusPage.helperAction(.ready, isInstalling: false, pending: waiting), "no second prompt while one is open")
        XCTAssertEqual(StatusPage.helperHint(.ready, pending: cancelled),
                       "Helper update to version 2.7.0 was cancelled. The installed helper keeps routing; click Update to try again.")
        XCTAssertEqual(StatusPage.helperAction(.ready, isInstalling: false, pending: cancelled), "Update")
        XCTAssertTrue(StatusPage.helperHint(.ready, pending: timedOut)?.contains("timed out") ?? false)
        XCTAssertNil(StatusPage.helperHint(.ready))
    }
}
