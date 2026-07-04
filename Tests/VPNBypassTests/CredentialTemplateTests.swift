// CredentialTemplateTests.swift
// Coverage for per-route proxy credential template expansion (VPN-Bypass-3sc.8).

import XCTest
@testable import VPNBypassCore

final class CredentialTemplateTests: XCTestCase {

    func testNilOrEmptyTemplateReturnsRawValue() {
        XCTAssertEqual(CredentialTemplate.expand(template: nil, rawValue: "user-sp", user: "sp", pass: "pw", sessionId: "x", ttlMinutes: 1), "user-sp")
        XCTAssertEqual(CredentialTemplate.expand(template: "", rawValue: "user-sp", user: "sp", pass: "pw", sessionId: "x", ttlMinutes: 1), "user-sp")
    }

    func testOxylabsStickyUsernameTemplate() {
        let result = CredentialTemplate.expand(
            template: "customer-{user}-sessid-{id}-sesstime-{ttl}",
            rawValue: "ignored",
            user: "sp123", pass: "pw", sessionId: "abc12345", ttlMinutes: 30
        )
        XCTAssertEqual(result, "customer-sp123-sessid-abc12345-sesstime-30")
    }

    func testIPRoyalPasswordTemplate() {
        let result = CredentialTemplate.expand(
            template: "{pass}_session-{id}",
            rawValue: "ignored",
            user: "u", pass: "secretpw", sessionId: "abc12345", ttlMinutes: nil
        )
        XCTAssertEqual(result, "secretpw_session-abc12345")
    }

    func testMissingSessionAndTtlExpandToEmpty() {
        let result = CredentialTemplate.expand(
            template: "{user}-sessid-{id}-sesstime-{ttl}",
            rawValue: "ignored",
            user: "u", pass: "p", sessionId: nil, ttlMinutes: nil
        )
        XCTAssertEqual(result, "u-sessid--sesstime-")
    }

    func testMakeSessionIdLengthAndCharset() {
        let id = CredentialTemplate.makeSessionId(length: 10, from: "abc")
        XCTAssertEqual(id.count, 10)
        XCTAssertTrue(id.allSatisfy { "abc".contains($0) })
        XCTAssertEqual(CredentialTemplate.makeSessionId(length: 0).count, 0)
    }
}
