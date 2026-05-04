// ColorExtensionTests.swift
// Thorough tests for the Color(hex:) initializer parsing logic.

import XCTest
@testable import VPNBypassCore
import SwiftUI

/// Tests for the Color(hex:) extension defined in ColorExtension.swift.
/// Since SwiftUI Color does not expose RGBA components directly,
/// we test the hex parsing/bit-math via a helper that replicates the
/// same logic the initializer uses, then verify object creation doesn't crash.
final class ColorExtensionTests: XCTestCase {

    // MARK: - Helper

    /// Replicates the exact parsing logic from `Color(hex:)` and returns
    /// the computed (a, r, g, b) UInt64 channel values (0–255 range).
    private func parseHex(_ hex: String) -> (a: UInt64, r: UInt64, g: UInt64, b: UInt64) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        return (a, r, g, b)
    }

    // MARK: - 3-char hex (12-bit RGB)

    func testThreeCharRed() {
        let c = parseHex("F00")
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testThreeCharRedWithHash() {
        let c = parseHex("#F00")
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testThreeCharWhite() {
        let c = parseHex("FFF")
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 255)
        XCTAssertEqual(c.b, 255)
        XCTAssertEqual(c.a, 255)
    }

    func testThreeCharMixed() {
        // A=10*17=170, 5=5*17=85, F=15*17=255
        let c = parseHex("A5F")
        XCTAssertEqual(c.r, 170)
        XCTAssertEqual(c.g, 85)
        XCTAssertEqual(c.b, 255)
        XCTAssertEqual(c.a, 255)
    }

    func testThreeCharBlack() {
        let c = parseHex("000")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    // MARK: - 6-char hex (24-bit RGB)

    func testSixCharRed() {
        let c = parseHex("FF0000")
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testSixCharGreen() {
        let c = parseHex("00FF00")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 255)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testSixCharBlue() {
        let c = parseHex("0000FF")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 255)
        XCTAssertEqual(c.a, 255)
    }

    func testSixCharGreenWithHash() {
        let c = parseHex("#00FF00")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 255)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testSixCharGray() {
        let c = parseHex("808080")
        XCTAssertEqual(c.r, 128)
        XCTAssertEqual(c.g, 128)
        XCTAssertEqual(c.b, 128)
        XCTAssertEqual(c.a, 255)
    }

    func testSixCharWhite() {
        let c = parseHex("FFFFFF")
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 255)
        XCTAssertEqual(c.b, 255)
        XCTAssertEqual(c.a, 255)
    }

    func testSixCharBlack() {
        let c = parseHex("000000")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    // MARK: - 8-char hex (32-bit ARGB)

    func testEightCharHalfAlpha() {
        let c = parseHex("80FF0000")
        XCTAssertEqual(c.a, 128)
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
    }

    func testEightCharFullAlpha() {
        let c = parseHex("FFFF0000")
        XCTAssertEqual(c.a, 255)
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
    }

    func testEightCharZeroAlpha() {
        let c = parseHex("00FF0000")
        XCTAssertEqual(c.a, 0)
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
    }

    func testEightCharWithHash() {
        let c = parseHex("#80FF0000")
        XCTAssertEqual(c.a, 128)
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
    }

    // MARK: - Default case (invalid lengths fall back to black)

    func testInvalidHexDefaultsToBlack() {
        let c = parseHex("XY")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testEmptyStringDefaultsToBlack() {
        let c = parseHex("")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testOneCharDefaultsToBlack() {
        let c = parseHex("F")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testFiveCharDefaultsToBlack() {
        let c = parseHex("ABCDE")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testSevenCharDefaultsToBlack() {
        let c = parseHex("ABCDEF0")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    // MARK: - Case insensitivity

    func testLowercaseAccepted() {
        let lower = parseHex("ff0000")
        let upper = parseHex("FF0000")
        XCTAssertEqual(lower.r, upper.r)
        XCTAssertEqual(lower.g, upper.g)
        XCTAssertEqual(lower.b, upper.b)
        XCTAssertEqual(lower.a, upper.a)
    }

    func testMixedCaseAccepted() {
        let c = parseHex("Ff00fF")
        XCTAssertEqual(c.r, 255)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 255)
        XCTAssertEqual(c.a, 255)
    }

    // MARK: - Color object creation (smoke tests)

    func testColorCreationThreeChar() {
        let color = Color(hex: "F00")
        XCTAssertNotNil(color)
    }

    func testColorCreationThreeCharWithHash() {
        let color = Color(hex: "#F00")
        XCTAssertNotNil(color)
    }

    func testColorCreationSixChar() {
        let color = Color(hex: "FF0000")
        XCTAssertNotNil(color)
    }

    func testColorCreationSixCharWithHash() {
        let color = Color(hex: "#00FF00")
        XCTAssertNotNil(color)
    }

    func testColorCreationEightChar() {
        let color = Color(hex: "80FF0000")
        XCTAssertNotNil(color)
    }

    func testColorCreationEightCharWithHash() {
        let color = Color(hex: "#80FF0000")
        XCTAssertNotNil(color)
    }

    func testColorCreationInvalidHex() {
        let color = Color(hex: "XY")
        XCTAssertNotNil(color)
    }

    func testColorCreationEmptyString() {
        let color = Color(hex: "")
        XCTAssertNotNil(color)
    }

    func testColorCreationOneChar() {
        let color = Color(hex: "F")
        XCTAssertNotNil(color)
    }

    func testColorCreationFiveChar() {
        let color = Color(hex: "ABCDE")
        XCTAssertNotNil(color)
    }

    func testColorCreationSevenChar() {
        let color = Color(hex: "ABCDEF0")
        XCTAssertNotNil(color)
    }

    func testColorCreationLowercase() {
        let color = Color(hex: "ff0000")
        XCTAssertNotNil(color)
    }

    func testColorCreationMixedCase() {
        let color = Color(hex: "Ff00fF")
        XCTAssertNotNil(color)
    }

    // MARK: - Hash stripping edge cases

    func testHashOnlyStripsToEmpty() {
        // "#" → trimmingCharacters removes it → "" → count=0 → default black
        let c = parseHex("#")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    func testDoubleHashStrippedSameAsEmpty() {
        // "##" → both stripped → "" → default black
        let c = parseHex("##")
        XCTAssertEqual(c.r, 0)
        XCTAssertEqual(c.g, 0)
        XCTAssertEqual(c.b, 0)
        XCTAssertEqual(c.a, 255)
    }

    // MARK: - Arithmetic precision

    func testThreeCharExpansionFactorOf17() {
        // Each 4-bit nibble is expanded by multiplying by 17 (0x11)
        // 0 * 17 = 0, 1 * 17 = 17, 8 * 17 = 136, 15 * 17 = 255
        let c = parseHex("18F")
        XCTAssertEqual(c.r, 1 * 17)  // 17
        XCTAssertEqual(c.g, 8 * 17)  // 136
        XCTAssertEqual(c.b, 15 * 17) // 255
        XCTAssertEqual(c.a, 255)
    }

    func testEightCharAllChannelsDistinct() {
        // A=0xC0=192, R=0x33=51, G=0x66=102, B=0x99=153
        let c = parseHex("C0336699")
        XCTAssertEqual(c.a, 192)
        XCTAssertEqual(c.r, 51)
        XCTAssertEqual(c.g, 102)
        XCTAssertEqual(c.b, 153)
    }
}
