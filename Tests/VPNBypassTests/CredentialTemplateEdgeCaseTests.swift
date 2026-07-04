// CredentialTemplateEdgeCaseTests.swift
// Additional edge-case coverage for CredentialTemplate.expand(), layered on top of
// CredentialTemplateTests.swift: the single-pass cross-contamination guarantee (a
// substituted value that itself looks like a token must not be re-expanded), unknown
// tokens, an unclosed brace, back-to-back tokens with no separator, an empty token
// name, and isolating nil session/ttl independently (not just both together).

import XCTest
@testable import VPNBypassCore

final class CredentialTemplateEdgeCaseTests: XCTestCase {

    /// THE key guarantee documented on `expand`: a credential value that itself
    /// contains a literal `{id}` must NOT be re-scanned once substituted in — only the
    /// template's OWN `{id}` token (the second one here) gets the real session id.
    func testCrossContaminationLiteralBraceInPassNotReExpanded() {
        let result = CredentialTemplate.expand(
            template: "{pass}_{id}",
            rawValue: "ignored",
            user: "u", pass: "{id}", sessionId: "XYZ999", ttlMinutes: nil
        )
        XCTAssertEqual(result, "{id}_XYZ999", "the pass value's literal {id} must stay verbatim, not be re-expanded into the session id")
    }

    /// A `{token}` that is not one of user/pass/id/ttl is left exactly as written.
    func testUnknownTokenLeftVerbatim() {
        let result = CredentialTemplate.expand(
            template: "{user}-{foo}-{pass}",
            rawValue: "ignored",
            user: "ALICE", pass: "SECRET", sessionId: nil, ttlMinutes: nil
        )
        XCTAssertEqual(result, "ALICE-{foo}-SECRET")
    }

    /// An unterminated `{` (no matching `}` before the end of the string) is not
    /// treated as a token at all — it and everything after it is copied through as
    /// literal text, character by character.
    func testUnclosedBraceKeptLiteral() {
        let result = CredentialTemplate.expand(
            template: "{user}-{oops",
            rawValue: "ignored",
            user: "ALICE", pass: "SECRET", sessionId: nil, ttlMinutes: nil
        )
        XCTAssertEqual(result, "ALICE-{oops")
    }

    /// Back-to-back tokens with no literal separator between them must concatenate
    /// correctly — the cursor jump after each substitution must land exactly on the
    /// next `{`, never skipping or duplicating a character.
    func testAdjacentTokensWithNoSeparatorConcatenateCorrectly() {
        let result = CredentialTemplate.expand(
            template: "{user}{pass}{id}",
            rawValue: "ignored",
            user: "A", pass: "B", sessionId: "C", ttlMinutes: nil
        )
        XCTAssertEqual(result, "ABC")
    }

    /// `{}` (empty token name) is not a recognized key, so — like any unknown token —
    /// it is reconstructed verbatim rather than expanding to anything.
    func testEmptyBracesTokenLeftVerbatim() {
        let result = CredentialTemplate.expand(
            template: "{}", rawValue: "ignored", user: "u", pass: "p", sessionId: nil, ttlMinutes: nil
        )
        XCTAssertEqual(result, "{}")
    }

    /// A nil session id expands to "" even when ttl IS provided (isolating the {id}
    /// field from the {ttl} field, unlike the existing test that leaves both nil).
    func testNilSessionIdOnlyExpandsToEmptyStringWhenTTLPresent() {
        let result = CredentialTemplate.expand(
            template: "[{id}]", rawValue: "ignored", user: "u", pass: "p", sessionId: nil, ttlMinutes: 45
        )
        XCTAssertEqual(result, "[]")
    }

    /// A nil ttl expands to "" even when a session id IS provided.
    func testNilTTLOnlyExpandsToEmptyStringWhenSessionPresent() {
        let result = CredentialTemplate.expand(
            template: "[{ttl}]", rawValue: "ignored", user: "u", pass: "p", sessionId: "abc12345", ttlMinutes: nil
        )
        XCTAssertEqual(result, "[]")
    }
}
