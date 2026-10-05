import Security
import XCTest
@testable import VPNBypassCore

/// Tests for `HelperAuthPolicy.callerRequirement`, the code-signing requirement the privileged
/// helper enforces on every XPC caller. The security property under test: only the app's
/// identifier signed by our Developer ID team passes, so an ad-hoc binary that copies the
/// identifier does not.
final class HelperAuthPolicyTests: XCTestCase {

    private let requirement = HelperAuthPolicy.callerRequirement

    func testRequirementIsExactlyIdentifierAndTeam() {
        XCTAssertEqual(
            requirement,
            "anchor apple generic and identifier \"com.geiserx.vpn-bypass\" and certificate leaf[subject.OU] = \"624WUVM8B4\""
        )
    }

    func testRequirementIsNeverIdentifierOnly() {
        // The identifier alone is what `codesign -s - -i com.geiserx.vpn-bypass` forges.
        XCTAssertNotEqual(requirement, "identifier \"\(HelperConstants.appSigningIdentifier)\"")
        XCTAssertTrue(requirement.hasPrefix("anchor apple generic and "))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"\(HelperConstants.teamIdentifier)\""))
    }

    func testRequirementCompiles() {
        // The helper rejects every caller when the string does not compile, so a typo here
        // would lock the app out of its own helper.
        var req: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &req), errSecSuccess)
        XCTAssertNotNil(req)
    }

    func testForgedIdentifierFailsRequirement() throws {
        // A binary ad-hoc signed with the app's identifier: the forgery the team check exists for.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let forged = dir.appendingPathComponent("forged")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: forged)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", HelperConstants.appSigningIdentifier, forged.path]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)

        var staticCode: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(forged as CFURL, [], &staticCode), errSecSuccess)
        let code = try XCTUnwrap(staticCode)

        // Control: the forgery does carry the identifier, so an identifier-only check passes it.
        var identifierOnly: SecRequirement?
        SecRequirementCreateWithString("identifier \"\(HelperConstants.appSigningIdentifier)\"" as CFString, [], &identifierOnly)
        XCTAssertEqual(SecStaticCodeCheckValidity(code, [], try XCTUnwrap(identifierOnly)), errSecSuccess)

        var req: SecRequirement?
        SecRequirementCreateWithString(requirement as CFString, [], &req)
        XCTAssertNotEqual(SecStaticCodeCheckValidity(code, [], try XCTUnwrap(req)), errSecSuccess)
    }

    func testReleaseScriptChecksTheSameRequirement() throws {
        // scripts/sign-and-notarize.sh refuses a release whose app fails this requirement, so
        // the two strings must stay equal.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let script = dir.appendingPathComponent("scripts/sign-and-notarize.sh")
            if FileManager.default.fileExists(atPath: script.path) {
                let text = try String(contentsOf: script, encoding: .utf8)
                XCTAssertTrue(text.contains("helper_requirement='\(requirement)'"),
                              "scripts/sign-and-notarize.sh does not check HelperAuthPolicy.callerRequirement")
                return
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("scripts/sign-and-notarize.sh not found walking up from \(#filePath)")
    }
}
