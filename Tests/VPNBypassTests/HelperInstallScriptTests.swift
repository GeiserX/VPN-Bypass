import XCTest
@testable import VPNBypassCore

/// Tests for `HelperManager.legacyInstallShellCommand`, the root script that replaces the
/// helper and starts it. The property under test: neither copy is still quarantined when
/// `launchctl bootstrap` runs. An app installed by Homebrew or downloaded in a browser carries
/// `com.apple.quarantine`, `cp` copies it, and since macOS 27 launchd refuses a quarantined plist
/// or program, which left 5.1.0's helper stopped after every such install there.
/// A Mac in that state must also get past the Login Items guard, or the fixed script never runs.
@MainActor
final class HelperInstallScriptTests: XCTestCase {

    private let helperDest = "/Library/PrivilegedHelperTools/com.geiserx.vpnbypass.helper"
    private let plistDest = "/Library/LaunchDaemons/com.geiserx.vpnbypass.helper.plist"

    private func lines(bundle: String = "/Applications/VPN Bypass.app") -> [String] {
        HelperManager.legacyInstallShellCommand(
            helperSource: "\(bundle)/Contents/MacOS/com.geiserx.vpnbypass.helper",
            plistSource: "\(bundle)/Contents/Library/LaunchDaemons/com.geiserx.vpnbypass.helper.plist"
        )
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func index(of line: String, in lines: [String], file: StaticString = #filePath, line l: UInt = #line) throws -> Int {
        try XCTUnwrap(lines.firstIndex(of: line), "missing line: \(line)", file: file, line: l)
    }

    func testQuarantineComesOffBothCopiesBeforeTheBootstrap() throws {
        let script = lines()
        let bootstrap = try index(of: "launchctl bootstrap system '\(plistDest)'", in: script)
        XCTAssertEqual(bootstrap, script.count - 1, "bootstrap must stay last: `do shell script` reports the last command's status")

        for dest in [helperDest, plistDest] {
            let copy = try XCTUnwrap(script.firstIndex { $0.hasPrefix("cp ") && $0.hasSuffix(" '\(dest)'") }, "no cp onto \(dest)")
            let strip = try index(of: "xattr -d com.apple.quarantine '\(dest)' 2>/dev/null || true", in: script)
            XCTAssertGreaterThan(strip, copy, "the mark must come off after the copy that brings it: \(dest)")
            XCTAssertLessThan(strip, bootstrap, "the mark must be gone before launchd reads \(dest)")
        }
    }

    func testAMissingMarkDoesNotStopTheInstall() throws {
        // `xattr -d` exits 1 when the attribute is absent, which is the normal case for an app
        // that was never quarantined. The script has no `set -e`, and the removal ends in
        // `|| true`, so the bootstrap still decides the result.
        let script = lines()
        XCTAssertFalse(script.contains { $0.hasPrefix("set -e") })
        XCTAssertEqual(script.filter { $0.hasPrefix("xattr -d com.apple.quarantine ") && $0.hasSuffix(" 2>/dev/null || true") }.count, 2)
    }

    // MARK: - Repairing what 5.1.0 left

    func testAQuarantinedCopyIsRepairedEvenWhenTheDaemonLooksDisabled() {
        // 5.1.0 deleted the cdhash pin and then failed to start the helper, so the pin is gone
        // and SMAppService says .notRegistered: without the quarantine check this reads as
        // "disabled in Login Items" and the app never reinstalls.
        XCTAssertFalse(HelperManager.unreachableHelperIsUsersChoice(daemonDisabled: true, preTeamHelper: false, quarantinedCopy: true))
        XCTAssertFalse(HelperManager.unreachableHelperIsUsersChoice(daemonDisabled: true, preTeamHelper: true, quarantinedCopy: false))
        // #25: a clean, current helper the user turned off is left alone.
        XCTAssertTrue(HelperManager.unreachableHelperIsUsersChoice(daemonDisabled: true, preTeamHelper: false, quarantinedCopy: false))
        XCTAssertFalse(HelperManager.unreachableHelperIsUsersChoice(daemonDisabled: false, preTeamHelper: false, quarantinedCopy: false))
    }

    func testIsQuarantinedReadsTheMarkFromTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vpnb-quarantine-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(HelperManager.isQuarantined(path: file.path))

        let mark = "0181;6ac35e90;;7725F5A0-B21A-4265-ACA0-94885026C4E7"
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0), 0, "setxattr failed: errno \(errno)")
        XCTAssertTrue(HelperManager.isQuarantined(path: file.path))

        XCTAssertEqual(removexattr(file.path, "com.apple.quarantine", 0), 0)
        XCTAssertFalse(HelperManager.isQuarantined(path: file.path))
        XCTAssertFalse(HelperManager.isQuarantined(path: file.path + ".missing"))
    }

    func testABundlePathWithAQuoteStaysInsideItsQuoting() throws {
        let script = lines(bundle: "/Users/o'brien/Apps/VPN Bypass.app")
        XCTAssertTrue(script.contains(
            "cp '/Users/o'\\''brien/Apps/VPN Bypass.app/Contents/MacOS/com.geiserx.vpnbypass.helper' '\(helperDest)'"
        ))
    }
}
