// HelperVersionRetryTests.swift
// A helper that answers late at boot must not be reinstalled (#174); a missing or
// mismatched one still must be.

import XCTest
@testable import VPNBypassCore

@MainActor
final class HelperVersionRetryTests: XCTestCase {

    private let expected = HelperConstants.helperVersion

    /// A fake helper that returns the given probe outcomes in order, then repeats the last.
    private final class FakeHelper {
        private var outcomes: [HelperManager.VersionProbe]
        private(set) var calls = 0
        init(_ outcomes: [HelperManager.VersionProbe]) { self.outcomes = outcomes }
        func probe() -> HelperManager.VersionProbe {
            calls += 1
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
    }

    private func run(_ helper: FakeHelper, sleeps: inout [TimeInterval], logs: inout [String]) async -> HelperManager.VersionCheckVerdict {
        var slept: [TimeInterval] = []
        var logged: [String] = []
        let probe = await HelperManager.probeVersionRetryingTimeouts(
            probe: { helper.probe() },
            sleep: { slept.append($0) },
            log: { logged.append($0) }
        )
        sleeps = slept
        logs = logged
        return HelperManager.versionCheckVerdict(probe, expected: expected) { false }
    }

    func testHelperThatAnswersAfterTwoTimeoutsIsNotReinstalled() async {
        // The reporter's Mac mini: two 10 s timeouts after a reboot, then a normal answer.
        let helper = FakeHelper([.timedOut, .timedOut, .version(expected)])
        var sleeps: [TimeInterval] = [], logs: [String] = []
        let verdict = await run(helper, sleeps: &sleeps, logs: &logs)
        XCTAssertEqual(verdict, .ready)
        XCTAssertEqual(helper.calls, 3)
        XCTAssertEqual(sleeps, [2, 4])
        XCTAssertEqual(logs.count, 3, "each retry and the late answer are logged: \(logs)")
    }

    func testHelperThatAnswersOnTheLastAttemptIsNotReinstalled() async {
        let timeouts = [HelperManager.VersionProbe](repeating: .timedOut, count: HelperManager.versionRetryDelays.count)
        let helper = FakeHelper(timeouts + [.version(expected)])
        var sleeps: [TimeInterval] = [], logs: [String] = []
        let verdict = await run(helper, sleeps: &sleeps, logs: &logs)
        XCTAssertEqual(verdict, .ready)
    }

    func testRetryBudgetIsAboutAMinute() {
        // Each probe has a 10 s deadline.
        let probes = Double(HelperManager.versionRetryDelays.count + 1)
        let worstCase = probes * 10 + HelperManager.versionRetryDelays.reduce(0, +)
        XCTAssertGreaterThanOrEqual(worstCase, 55)
        XCTAssertLessThanOrEqual(worstCase, 70)
    }

    func testHelperThatNeverAnswersIsReinstalled() async {
        let helper = FakeHelper([.timedOut])
        var sleeps: [TimeInterval] = [], logs: [String] = []
        let verdict = await run(helper, sleeps: &sleeps, logs: &logs)
        XCTAssertEqual(verdict, .reinstall)
        XCTAssertEqual(helper.calls, HelperManager.versionRetryDelays.count + 1)
    }

    func testUnreachableHelperIsReinstalledWithoutWaiting() async {
        // An XPC error (service not registered, connection invalid) is not slowness.
        let helper = FakeHelper([.unreachable])
        var sleeps: [TimeInterval] = [], logs: [String] = []
        let verdict = await run(helper, sleeps: &sleeps, logs: &logs)
        XCTAssertEqual(verdict, .reinstall)
        XCTAssertEqual(helper.calls, 1)
        XCTAssertEqual(sleeps, [])
    }

    func testMismatchedVersionIsUpdated() async {
        let helper = FakeHelper([.version("0.0.1")])
        var sleeps: [TimeInterval] = [], logs: [String] = []
        let verdict = await run(helper, sleeps: &sleeps, logs: &logs)
        XCTAssertEqual(verdict, .update(installed: "0.0.1"))
        XCTAssertEqual(helper.calls, 1)
    }

    func testMismatchedVersionAfterATimeoutIsUpdated() async {
        let helper = FakeHelper([.timedOut, .version("0.0.1")])
        var sleeps: [TimeInterval] = [], logs: [String] = []
        let verdict = await run(helper, sleeps: &sleeps, logs: &logs)
        XCTAssertEqual(verdict, .update(installed: "0.0.1"))
    }

    func testHelperTurnedOffInLoginItemsKeepsTheEnablePrompt() {
        let verdict = HelperManager.versionCheckVerdict(.unreachable, expected: expected) { true }
        XCTAssertEqual(verdict, .loginItemsDisabled)
    }

    func testAnsweringHelperNeverAsksAboutLoginItems() {
        let verdict = HelperManager.versionCheckVerdict(.version(expected), expected: expected) {
            XCTFail("Login Items must not be consulted when the helper answered")
            return true
        }
        XCTAssertEqual(verdict, .ready)
    }
}
