import XCTest
@testable import VPNBypassCore

/// Drift guard for the privileged helper's version.
///
/// `HelperConstants.helperVersion` is a DELIBERATE protocol / upgrade-trigger constant: it is
/// bumped by hand precisely to force already-installed helpers to detect a mismatch, reinstall,
/// and pick up new hardening (see the comment on the constant). It is NOT a user-facing display
/// version, so — unlike the app's `CFBundleShortVersionString`, which CI stamps at build time —
/// it is intentionally a source constant rather than something read from a bundle at runtime.
///
/// This test is the safety net for that decision. It fails if the constant ever drifts from
/// `Helper/Info.plist`'s `CFBundleShortVersionString` (the value the shipped helper actually
/// reports over XPC), which would cause missed or repeated upgrades. Equality is thus enforced
/// at test time — catching drift that a runtime bundle lookup was proposed to prevent — without
/// the fragility of resolving the bundled helper's plist path at runtime.
final class HelperVersionDriftTests: XCTestCase {

    func testHelperConstantMatchesHelperInfoPlist() throws {
        let plistURL = try Self.helperInfoPlistURL()
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any], "Helper/Info.plist is not a dictionary")
        let shortVersion = try XCTUnwrap(
            dict["CFBundleShortVersionString"] as? String,
            "Helper/Info.plist has no CFBundleShortVersionString"
        )
        XCTAssertEqual(
            HelperConstants.helperVersion, shortVersion,
            "HelperConstants.helperVersion (\(HelperConstants.helperVersion)) drifted from "
            + "Helper/Info.plist CFBundleShortVersionString (\(shortVersion)). Bump BOTH together: "
            + "the constant drives the reinstall trigger, the plist is what the shipped helper reports."
        )
    }

    /// Locate `Helper/Info.plist` by walking up from this test's source file to the repo root
    /// (the directory that contains `Helper/Info.plist`). Uses `#filePath` so it resolves from
    /// the SwiftPM build dir without hardcoding an absolute path. Skips (rather than fails) if
    /// the repo layout isn't present — the drift guard is meaningful only against the source tree.
    private static func helperInfoPlistURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Helper/Info.plist")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Helper/Info.plist not found walking up from \(#filePath) — repo layout changed")
    }
}
