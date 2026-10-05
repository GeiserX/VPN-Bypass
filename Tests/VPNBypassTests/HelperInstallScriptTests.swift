import XCTest
@testable import VPNBypassCore

/// Tests for `HelperManager.legacyInstallShellCommand`, the root script that replaces the
/// helper and starts it. The property under test: neither copy is still quarantined when
/// `launchctl bootstrap` runs. An app installed by Homebrew or downloaded in a browser carries
/// `com.apple.quarantine`, `cp` copies it, and since macOS 27 launchd refuses a quarantined plist
/// or program, which left 5.1.0's helper stopped after every such install there.
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

    func testABundlePathWithAQuoteStaysInsideItsQuoting() throws {
        let script = lines(bundle: "/Users/o'brien/Apps/VPN Bypass.app")
        XCTAssertTrue(script.contains(
            "cp '/Users/o'\\''brien/Apps/VPN Bypass.app/Contents/MacOS/com.geiserx.vpnbypass.helper' '\(helperDest)'"
        ))
    }
}
