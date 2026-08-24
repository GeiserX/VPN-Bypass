import XCTest
@testable import VPNBypassCore

/// Coverage for `ProcessDeadline`, the helper's bounded `Process` wait.
///
/// `flushDNSCache` used to call `waitUntilExit()` with no deadline. A wedged
/// `dscacheutil` or `killall` parked the XPC thread for the life of the daemon
/// after the app had already dropped the 30s hosts-update connection. This
/// seam is compiled into both the helper and the test target (same reason as
/// `HelperAuthPolicy` / `RouteCIDR`).
final class ProcessDeadlineTests: XCTestCase {

    func testFinishedProcessReturnsTrue() {
        XCTAssertEqual(ProcessDeadline.run(path: "/usr/bin/true", seconds: 2), .exited(0))
    }

    func testNonzeroExitIsReported() {
        XCTAssertEqual(ProcessDeadline.run(path: "/usr/bin/false", seconds: 2), .exited(1))
    }

    /// A child that outlives the deadline must be killed and reported as a
    /// timeout. Without a deadline this returns true after the sleep exits.
    func testLongChildIsKilledAndReportedAsTimeout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["8"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        XCTAssertEqual(
            ProcessDeadline.run(process, seconds: 0.25),
            .timedOut,
            "a child that outlives the deadline must time out, not wait it out"
        )
        XCTAssertFalse(process.isRunning, "timed-out child must not be left running")
    }

    func testMissingExecutableReturnsFalse() {
        XCTAssertEqual(ProcessDeadline.run(path: "/no/such/vpnb-deadline-binary", seconds: 1), .failedToStart)
    }

    /// SIGTERM is ignorable. The deadline path must escalate to SIGKILL so a
    /// child that traps TERM cannot recreate the unbounded wait.
    func testTermIgnoringChildIsKilled() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 8"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        XCTAssertEqual(ProcessDeadline.run(process, seconds: 0.25), .timedOut)
        XCTAssertFalse(process.isRunning, "TERM-ignoring child must be SIGKILL'd")
    }
}
