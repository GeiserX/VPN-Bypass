import XCTest
@testable import VPNBypassCore

/// Tests for `AppUpdateRelauncher`, which restarts the app after an update replaces its bundle.
/// Homebrew cannot reopen the app (its sandbox forbids launching one), so this is the only
/// thing that brings the app back after `brew upgrade`.
final class AppUpdateRelauncherTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vpnb-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Noticing the replacement

    func testStateFollowsTheFileAtTheExecutablePath() throws {
        let executable = dir.appendingPathComponent("VPNBypass")
        try Data("old".utf8).write(to: executable)
        let launched = try XCTUnwrap(AppUpdateRelauncher.identity(ofFileAt: executable.path))

        XCTAssertEqual(AppUpdateRelauncher.state(launched: launched, executablePath: executable.path) { true }, .unchanged)

        // An update moves the old bundle away before the new one arrives.
        let aside = dir.appendingPathComponent("VPNBypass.old")
        try FileManager.default.moveItem(at: executable, to: aside)
        XCTAssertEqual(AppUpdateRelauncher.state(launched: launched, executablePath: executable.path) { true }, .missing)

        // The new copy is another file at the same path.
        try Data("new".utf8).write(to: executable)
        XCTAssertEqual(AppUpdateRelauncher.state(launched: launched, executablePath: executable.path) { false }, .incomplete,
                       "a bundle that is still being copied must not be opened")
        XCTAssertEqual(AppUpdateRelauncher.state(launched: launched, executablePath: executable.path) { true }, .replaced)
    }

    func testAnUnchangedExecutableNeverAsksAboutTheBundle() throws {
        let executable = dir.appendingPathComponent("VPNBypass")
        try Data("old".utf8).write(to: executable)
        let launched = try XCTUnwrap(AppUpdateRelauncher.identity(ofFileAt: executable.path))
        // The signature check hashes the whole bundle, so it must run only after a replacement.
        _ = AppUpdateRelauncher.state(launched: launched, executablePath: executable.path) {
            XCTFail("the bundle was checked although nothing changed")
            return true
        }
    }

    func testBundleSignatureCheck() {
        XCTAssertTrue(AppUpdateRelauncher.bundleSignatureIsValid(atPath: "/System/Applications/Calculator.app"))
        XCTAssertFalse(AppUpdateRelauncher.bundleSignatureIsValid(atPath: dir.appendingPathComponent("Missing.app").path))
        XCTAssertFalse(AppUpdateRelauncher.bundleSignatureIsValid(atPath: dir.path), "an unsigned directory is not a complete bundle")
    }

    // MARK: - Reopening

    func testTheBundleIsOpenedOnlyAfterTheOldProcessExits() throws {
        // A process stands in for the old app, and `touch` for `open`: the marker it creates is
        // the "bundle" path, with a space and a quote in it to prove the shell does not read it.
        let oldApp = Process()
        oldApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldApp.arguments = ["2"]
        try oldApp.run()

        let marker = dir.appendingPathComponent("VPN Bypass's copy.app")
        let command = AppUpdateRelauncher.relaunchCommand(pid: oldApp.processIdentifier, bundlePath: marker.path, opener: "/usr/bin/touch")
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: command.executable)
        waiter.arguments = command.arguments
        try waiter.run()

        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(oldApp.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "opened while the old process was still running")

        oldApp.waitUntilExit()
        waiter.waitUntilExit()
        XCTAssertEqual(waiter.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "never opened after the old process exited")
    }

    func testTheRealCommandOpensWithOpen() {
        let command = AppUpdateRelauncher.relaunchCommand(pid: 4242, bundlePath: "/Applications/VPN Bypass.app")
        XCTAssertEqual(command.executable, "/bin/sh")
        XCTAssertEqual(Array(command.arguments.suffix(3)), ["4242", "/usr/bin/open", "/Applications/VPN Bypass.app"])
    }
}
