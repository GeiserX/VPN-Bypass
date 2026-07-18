import XCTest
@testable import VPNBypassCore

/// Tests for `HelperAuthPolicy`, the pure/testable seam that decides the privileged
/// helper's XPC-caller authorization requirement. The security property under test is
/// FAIL-CLOSED: with no valid cdhash pin the helper must reject the caller (nil
/// requirement) rather than fall back to the forgeable identifier-only requirement.
final class HelperAuthPolicyTests: XCTestCase {

    private let identifier = "com.geiserx.vpn-bypass"
    // A well-formed 20-byte code-directory hash (40 lowercase hex chars).
    private let pin40 = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    // A well-formed 32-byte (SHA-256) cdhash form (64 lowercase hex chars).
    private let pin64 = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678a1b2c3d4e5f60718293a4b5c"

    // MARK: - requirementString: fail-closed on absent pin

    func testRequirementStringNilPinRejects() {
        // The core of the fix: a nil pin yields NO requirement → caller must reject.
        XCTAssertNil(HelperAuthPolicy.requirementString(pinnedCDHash: nil, appSigningIdentifier: identifier))
    }

    func testRequirementStringNeverIdentifierOnly() {
        // Regression guard: the requirement must never be the identifier-only string that a
        // locally forged ad-hoc binary could satisfy. Either it is nil (reject) or it binds
        // the cdhash.
        let identifierOnly = "identifier \"\(identifier)\""
        XCTAssertNotEqual(HelperAuthPolicy.requirementString(pinnedCDHash: nil, appSigningIdentifier: identifier), identifierOnly)
        XCTAssertNotEqual(HelperAuthPolicy.requirementString(pinnedCDHash: pin40, appSigningIdentifier: identifier), identifierOnly)
    }

    // MARK: - requirementString: pinned requirement when present

    func testRequirementStringWith40HexPin() {
        let expected = "identifier \"\(identifier)\" and cdhash H\"\(pin40)\""
        XCTAssertEqual(HelperAuthPolicy.requirementString(pinnedCDHash: pin40, appSigningIdentifier: identifier), expected)
    }

    func testRequirementStringWith64HexPin() {
        let expected = "identifier \"\(identifier)\" and cdhash H\"\(pin64)\""
        XCTAssertEqual(HelperAuthPolicy.requirementString(pinnedCDHash: pin64, appSigningIdentifier: identifier), expected)
    }

    func testRequirementStringInterpolatesGivenIdentifier() {
        let other = "com.example.other"
        let expected = "identifier \"\(other)\" and cdhash H\"\(pin40)\""
        XCTAssertEqual(HelperAuthPolicy.requirementString(pinnedCDHash: pin40, appSigningIdentifier: other), expected)
    }

    func testRequirementStringContainsBothPredicates() {
        let req = HelperAuthPolicy.requirementString(pinnedCDHash: pin40, appSigningIdentifier: identifier)
        XCTAssertNotNil(req)
        XCTAssertTrue(req?.contains("identifier \"\(identifier)\"") == true)
        XCTAssertTrue(req?.contains("cdhash H\"\(pin40)\"") == true)
        XCTAssertTrue(req?.contains(" and ") == true)
    }

    // MARK: - validatedCDHash: accepts whole cdhashes

    func testValidatedCDHashAccepts40Hex() {
        XCTAssertEqual(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: pin40), pin40)
    }

    func testValidatedCDHashAccepts64Hex() {
        XCTAssertEqual(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: pin64), pin64)
    }

    func testValidatedCDHashLowercasesUppercaseHex() {
        XCTAssertEqual(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: pin40.uppercased()), pin40)
    }

    func testValidatedCDHashTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: "  \(pin40)\n"), pin40)
    }

    // MARK: - validatedCDHash: rejects everything that is not a whole cdhash

    func testValidatedCDHashRejectsNil() {
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: nil))
    }

    func testValidatedCDHashRejectsEmpty() {
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: ""))
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: "   \n"))
    }

    func testValidatedCDHashRejectsShortHex() {
        // A partial/truncated write ("ab") is even-length valid hex but is NOT a cdhash.
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: "ab"))
    }

    func testValidatedCDHashRejectsWrongLength() {
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: String(repeating: "a", count: 39)))
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: String(repeating: "a", count: 41)))
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: String(repeating: "a", count: 63)))
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: String(repeating: "a", count: 65)))
    }

    func testValidatedCDHashRejectsNonHex() {
        // 40 chars but 'g' is not a hex digit.
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: String(repeating: "g", count: 40)))
        // Correct length with a single non-hex character.
        var almost = pin40
        almost.removeLast()
        almost.append("z")
        XCTAssertNil(HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: almost))
    }

    // MARK: - End-to-end: validation feeds the fail-closed decision

    func testValidPinFileYieldsPinnedRequirement() {
        // Raw file contents → validated pin → pinned requirement (the real app is accepted).
        let validated = HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: "\(pin40)\n")
        let req = HelperAuthPolicy.requirementString(pinnedCDHash: validated, appSigningIdentifier: identifier)
        XCTAssertEqual(req, "identifier \"\(identifier)\" and cdhash H\"\(pin40)\"")
    }

    func testMalformedPinFileYieldsRejection() {
        // Raw garbage → nil validated pin → nil requirement (reject; NOT identifier-only).
        let validated = HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: "not-a-real-cdhash")
        XCTAssertNil(validated)
        XCTAssertNil(HelperAuthPolicy.requirementString(pinnedCDHash: validated, appSigningIdentifier: identifier))
    }

    func testAbsentPinFileYieldsRejection() {
        // No file (nil contents) → nil validated pin → nil requirement (reject).
        let validated = HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: nil)
        XCTAssertNil(validated)
        XCTAssertNil(HelperAuthPolicy.requirementString(pinnedCDHash: validated, appSigningIdentifier: identifier))
    }
}
