// IPValidationExtendedTests.swift
// Extended edge-case tests for isValidIP() and isValidCIDR() on RouteManager.

import XCTest
@testable import VPNBypassCore

// MARK: - isValidIP Edge Cases

final class IsValidIPEdgeCaseTests: XCTestCase {

    private let rm = RouteManager.shared

    // MARK: - Leading zeros

    func testLeadingZeroSingleOctetRejected() {
        XCTAssertFalse(rm.isValidIP("010.0.0.1"))
    }

    func testLeadingZerosAllOctetsRejected() {
        XCTAssertFalse(rm.isValidIP("01.02.03.04"))
    }

    func testDoubleZeroOctetRejected() {
        XCTAssertFalse(rm.isValidIP("00.0.0.0"))
    }

    func testTripleZeroOctetRejected() {
        XCTAssertFalse(rm.isValidIP("000.0.0.0"))
    }

    func testLeadingZeroLastOctetRejected() {
        XCTAssertFalse(rm.isValidIP("1.2.3.04"))
    }

    // MARK: - Zero and broadcast addresses

    func testAllZerosIsValid() {
        XCTAssertTrue(rm.isValidIP("0.0.0.0"))
    }

    func testAllTwoFiftyFivesIsValid() {
        XCTAssertTrue(rm.isValidIP("255.255.255.255"))
    }

    // MARK: - Boundary values

    func testOctetAt256Rejected() {
        XCTAssertFalse(rm.isValidIP("256.0.0.0"))
    }

    func testLastOctetAt256Rejected() {
        XCTAssertFalse(rm.isValidIP("0.0.0.256"))
    }

    func testOctetAt999Rejected() {
        XCTAssertFalse(rm.isValidIP("999.999.999.999"))
    }

    func testOctetAt1000Rejected() {
        XCTAssertFalse(rm.isValidIP("1000.0.0.0"))
    }

    func testNegativeOctetRejected() {
        XCTAssertFalse(rm.isValidIP("-1.0.0.0"))
    }

    func testNegativeLastOctetRejected() {
        XCTAssertFalse(rm.isValidIP("0.0.0.-1"))
    }

    // MARK: - Wrong number of octets

    func testTooFewOctetsRejected() {
        XCTAssertFalse(rm.isValidIP("1.2.3"))
    }

    func testTooManyOctetsRejected() {
        XCTAssertFalse(rm.isValidIP("1.2.3.4.5"))
    }

    func testSingleOctetRejected() {
        XCTAssertFalse(rm.isValidIP("12345"))
    }

    func testTwoOctetsRejected() {
        XCTAssertFalse(rm.isValidIP("1.2"))
    }

    // MARK: - Empty and whitespace

    func testEmptyStringRejected() {
        XCTAssertFalse(rm.isValidIP(""))
    }

    func testLeadingSpaceRejected() {
        XCTAssertFalse(rm.isValidIP(" 1.2.3.4"))
    }

    func testTrailingSpaceRejected() {
        XCTAssertFalse(rm.isValidIP("1.2.3.4 "))
    }

    func testSpaceBetweenOctetsRejected() {
        XCTAssertFalse(rm.isValidIP("1. 2.3.4"))
    }

    func testTabCharacterRejected() {
        XCTAssertFalse(rm.isValidIP("1.2.3\t.4"))
    }

    func testNewlineInIPRejected() {
        XCTAssertFalse(rm.isValidIP("1.2\n.3.4"))
    }

    func testOnlySpacesRejected() {
        XCTAssertFalse(rm.isValidIP("   "))
    }

    // MARK: - Non-numeric characters

    func testAllLettersRejected() {
        XCTAssertFalse(rm.isValidIP("a.b.c.d"))
    }

    func testMixedLetterInOctetRejected() {
        XCTAssertFalse(rm.isValidIP("192.168.a.1"))
    }

    func testHexadecimalNotationRejected() {
        XCTAssertFalse(rm.isValidIP("0xFF.0.0.1"))
    }

    func testHexInLastOctetRejected() {
        XCTAssertFalse(rm.isValidIP("10.0.0.0x1"))
    }

    // MARK: - Dots and separators

    func testJustDotsRejected() {
        XCTAssertFalse(rm.isValidIP("..."))
    }

    func testFourDotsRejected() {
        XCTAssertFalse(rm.isValidIP("...."))
    }

    func testLeadingDotRejected() {
        XCTAssertFalse(rm.isValidIP(".1.2.3.4"))
    }

    func testTrailingDotRejected() {
        XCTAssertFalse(rm.isValidIP("1.2.3.4."))
    }

    func testDoubleDotsRejected() {
        XCTAssertFalse(rm.isValidIP("1..2.3"))
    }

    func testDoubleDotMiddleRejected() {
        XCTAssertFalse(rm.isValidIP("1.2..3"))
    }

    // MARK: - Slash in IP (not CIDR)

    func testIPWithSlashRejectedByIsValidIP() {
        // "10.0.0.0/8" splits by "." into ["10", "0", "0", "0/8"]
        // Int("0/8") is nil, so it should be rejected
        XCTAssertFalse(rm.isValidIP("10.0.0.0/8"))
    }

    func testIPWithSlash32RejectedByIsValidIP() {
        XCTAssertFalse(rm.isValidIP("1.2.3.4/32"))
    }

    // MARK: - IPv6 rejected

    func testIPv6LoopbackRejected() {
        XCTAssertFalse(rm.isValidIP("::1"))
    }

    func testIPv6FullRejected() {
        XCTAssertFalse(rm.isValidIP("2001:0db8:85a3:0000:0000:8a2e:0370:7334"))
    }

    func testIPv6MappedV4Rejected() {
        XCTAssertFalse(rm.isValidIP("::ffff:192.168.1.1"))
    }

    // MARK: - Valid common addresses

    func testCGNATRangeValid() {
        XCTAssertTrue(rm.isValidIP("100.64.0.1"))
    }

    func testLoopbackValid() {
        XCTAssertTrue(rm.isValidIP("127.0.0.1"))
    }

    func testOctalLookingButValidIP() {
        // "10.0.0.1" has no leading zeros, so it's valid
        XCTAssertTrue(rm.isValidIP("10.0.0.1"))
    }

    func testLinkLocalValid() {
        XCTAssertTrue(rm.isValidIP("169.254.1.1"))
    }

    func testClassCPrivateValid() {
        XCTAssertTrue(rm.isValidIP("192.168.0.1"))
    }

    // MARK: - Miscellaneous malformed input

    func testCommaInsteadOfDotRejected() {
        XCTAssertFalse(rm.isValidIP("1,2,3,4"))
    }

    func testColonSeparatedRejected() {
        XCTAssertFalse(rm.isValidIP("1:2:3:4"))
    }

    func testUnicodeDigitsRejected() {
        // Arabic-Indic digit zero: U+0660
        XCTAssertFalse(rm.isValidIP("\u{0660}.0.0.0"))
    }

    func testPlusSignInOctetRejected() {
        // Int("+1") = 1, but String(1) = "1" != "+1", so rejected
        XCTAssertFalse(rm.isValidIP("+1.0.0.0"))
    }

    func testDecimalPointInOctetRejected() {
        XCTAssertFalse(rm.isValidIP("1.2.3.4.5"))
    }

    func testDomainStringRejected() {
        XCTAssertFalse(rm.isValidIP("example.com"))
    }

    func testURLStringRejected() {
        XCTAssertFalse(rm.isValidIP("http://1.2.3.4"))
    }

    func testMaxIntOctetRejected() {
        XCTAssertFalse(rm.isValidIP("2147483647.0.0.0"))
    }
}

// MARK: - isValidCIDR Edge Cases

final class IsValidCIDREdgeCaseTests: XCTestCase {

    private let rm = RouteManager.shared

    // MARK: - /0 rejected (default route protection)

    func testSlashZeroDefaultRouteRejected() {
        XCTAssertFalse(rm.isValidCIDR("0.0.0.0/0"))
    }

    func testSlashZeroNonDefaultIPRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/0"))
    }

    func testSlashZeroBroadcastIPRejected() {
        XCTAssertFalse(rm.isValidCIDR("255.255.255.255/0"))
    }

    // MARK: - Boundary masks

    func testSlash1Accepted() {
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/1"))
    }

    func testSlash32Accepted() {
        XCTAssertTrue(rm.isValidCIDR("1.2.3.4/32"))
    }

    func testSlash31Accepted() {
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/31"))
    }

    func testSlash33Rejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/33"))
    }

    func testSlash64Rejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/64"))
    }

    func testSlash128Rejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/128"))
    }

    // MARK: - Leading zero in mask

    func testLeadingZeroInMaskBehavior() {
        // Int("08") = 8, which is valid (1..32), so this should be true
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/08"))
    }

    func testLeadingZeroInMaskZeroOne() {
        // Int("01") = 1, which is valid (1..32)
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/01"))
    }

    func testLeadingZeroInMaskDouble() {
        // Int("024") = 24, valid
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/024"))
    }

    // MARK: - Negative and non-numeric masks

    func testNegativeMaskRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/-1"))
    }

    func testNegativeLargeMaskRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/-32"))
    }

    func testAlphabeticMaskRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/abc"))
    }

    func testEmptyMaskRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/"))
    }

    func testFloatMaskRejected() {
        // Int("8.5") = nil
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/8.5"))
    }

    func testSpaceMaskRejected() {
        // Int(" 8") = nil with default Swift behavior
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/ 8"))
    }

    // MARK: - Multiple slashes

    func testDoubleSlashRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0//8"))
    }

    func testTripleSlashRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0///8"))
    }

    func testTwoMasksRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/8/16"))
    }

    // MARK: - Invalid IP part

    func testInvalidIPOctetInCIDR() {
        XCTAssertFalse(rm.isValidCIDR("256.0.0.0/24"))
    }

    func testLeadingZerosIPInCIDR() {
        XCTAssertFalse(rm.isValidCIDR("010.0.0.0/8"))
    }

    func testTooFewOctetsInCIDR() {
        XCTAssertFalse(rm.isValidCIDR("1.2.3/24"))
    }

    func testLettersInIPPartOfCIDR() {
        XCTAssertFalse(rm.isValidCIDR("not.an.ip.addr/24"))
    }

    func testDomainWithMaskRejected() {
        XCTAssertFalse(rm.isValidCIDR("example.com/24"))
    }

    func testSubDomainWithMaskRejected() {
        XCTAssertFalse(rm.isValidCIDR("sub.domain.org/16"))
    }

    // MARK: - No slash (plain IP)

    func testPlainIPRejectedByCIDRValidator() {
        XCTAssertFalse(rm.isValidCIDR("192.168.1.1"))
    }

    func testPlainIPBroadcastRejected() {
        XCTAssertFalse(rm.isValidCIDR("255.255.255.255"))
    }

    // MARK: - Whitespace

    func testLeadingSpaceInCIDRRejected() {
        XCTAssertFalse(rm.isValidCIDR(" 10.0.0.0/8"))
    }

    func testTrailingSpaceInCIDRRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/8 "))
    }

    func testSpaceAroundSlashRejected() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0 /8"))
    }

    // MARK: - Empty and garbage

    func testEmptyStringRejected() {
        XCTAssertFalse(rm.isValidCIDR(""))
    }

    func testOnlySlashRejected() {
        XCTAssertFalse(rm.isValidCIDR("/"))
    }

    func testOnlySlashAndNumberRejected() {
        XCTAssertFalse(rm.isValidCIDR("/24"))
    }

    func testProtocolPrefixRejected() {
        XCTAssertFalse(rm.isValidCIDR("http://10.0.0.0/8"))
    }

    func testGarbageStringRejected() {
        XCTAssertFalse(rm.isValidCIDR("hello world"))
    }

    // MARK: - Valid common CIDRs

    func testClassAPrivate() {
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/8"))
    }

    func testClassBPrivate() {
        XCTAssertTrue(rm.isValidCIDR("172.16.0.0/12"))
    }

    func testClassCPrivate() {
        XCTAssertTrue(rm.isValidCIDR("192.168.0.0/16"))
    }

    func testSlash24Subnet() {
        XCTAssertTrue(rm.isValidCIDR("192.168.1.0/24"))
    }

    func testCGNATRange() {
        XCTAssertTrue(rm.isValidCIDR("100.64.0.0/10"))
    }

    func testHostRouteAsCIDR() {
        XCTAssertTrue(rm.isValidCIDR("8.8.8.8/32"))
    }
}
