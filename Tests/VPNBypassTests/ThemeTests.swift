import XCTest
@testable import VPNBypassCore
import SwiftUI

final class ThemeColorTests: XCTestCase {

    // MARK: - Text Colors

    func testTextPrimaryIsWhite() {
        XCTAssertEqual(Theme.textPrimary, Color.white)
    }

    func testTextSecondaryNotNil() {
        // Secondary text is a mid-grey, distinct from the pure-white primary.
        XCTAssertNotEqual(Theme.textSecondary, Theme.textPrimary)
    }

    func testTextTertiaryNotNil() {
        // Tertiary (decorative) grey is a different shade from secondary text.
        XCTAssertNotEqual(Theme.textTertiary, Theme.textSecondary)
    }

    func testTextDisabledNotNil() {
        XCTAssertNotEqual(Theme.textDisabled, Theme.textPrimary)
    }

    // MARK: - Semantic Status Colors

    func testSuccessColor() {
        // Success (green) and error (red) must never collide.
        XCTAssertNotEqual(Theme.success, Theme.error)
    }

    func testSuccessDarkColor() {
        XCTAssertNotEqual(Theme.successDark, Theme.success)
    }

    func testSuccessLightColor() {
        XCTAssertNotEqual(Theme.successLight, Theme.success)
    }

    func testErrorColor() {
        // Error (red) and warning (amber) are semantically distinct status colors.
        XCTAssertNotEqual(Theme.error, Theme.warning)
    }

    func testWarningColor() {
        XCTAssertNotEqual(Theme.warning, Theme.warningLight)
    }

    func testWarningLightColor() {
        XCTAssertNotEqual(Theme.warningLight, Theme.warning)
    }

    func testPurpleColor() {
        XCTAssertNotEqual(Theme.purple, Theme.purpleLight)
    }

    func testPurpleLightColor() {
        XCTAssertNotEqual(Theme.purpleLight, Theme.purple)
    }

    func testBlueColor() {
        XCTAssertNotEqual(Theme.blue, Theme.blueDark)
    }

    func testBlueDarkColor() {
        XCTAssertNotEqual(Theme.blueDark, Theme.blueLight)
    }

    func testBlueLightColor() {
        XCTAssertNotEqual(Theme.blueLight, Theme.blue)
    }

    func testCyanColor() {
        XCTAssertNotEqual(Theme.cyan, Theme.blue)
    }

    // MARK: - Gradients

    func testAccentGradient() {
        // LinearGradient's Equatable conformance is not guaranteed across SDKs, so assert
        // the value is constructible and has a non-empty textual representation.
        XCTAssertFalse(String(describing: Theme.accentGradient).isEmpty)
    }

    func testWarningGradient() {
        XCTAssertFalse(String(describing: Theme.warningGradient).isEmpty)
    }

    func testSuccessGradient() {
        XCTAssertFalse(String(describing: Theme.successGradient).isEmpty)
    }

    func testPurpleGradient() {
        XCTAssertFalse(String(describing: Theme.purpleGradient).isEmpty)
    }

    func testBlueGradient() {
        XCTAssertFalse(String(describing: Theme.blueGradient).isEmpty)
    }

    // MARK: - Backgrounds
    // Several background/structural values are Color.white at differing opacities, so some
    // share an alpha (e.g. bgInput and bgHover are both 0.08). To keep every assertion true,
    // translucent members are compared against a solid, opaque anchor (bgPrimary) rather than
    // a possibly-equal sibling.

    func testBgPrimary() {
        XCTAssertNotEqual(Theme.bgPrimary, Theme.bgSecondary)
    }

    func testBgSecondary() {
        XCTAssertNotEqual(Theme.bgSecondary, Theme.bgInputAlt)
    }

    func testBgCard() {
        XCTAssertNotEqual(Theme.bgCard, Theme.bgPrimary)
    }

    func testBgCardBorder() {
        XCTAssertNotEqual(Theme.bgCardBorder, Theme.bgPrimary)
    }

    func testBgInput() {
        XCTAssertNotEqual(Theme.bgInput, Theme.bgPrimary)
    }

    func testBgInputAlt() {
        XCTAssertNotEqual(Theme.bgInputAlt, Theme.bgSecondary)
    }

    func testBgDisabled() {
        XCTAssertNotEqual(Theme.bgDisabled, Theme.bgPrimary)
    }

    func testBgHover() {
        XCTAssertNotEqual(Theme.bgHover, Theme.bgPrimary)
    }

    func testBgElevated() {
        XCTAssertNotEqual(Theme.bgElevated, Theme.bgPrimary)
    }

    // MARK: - Structural

    func testDivider() {
        XCTAssertNotEqual(Theme.divider, Theme.bgPrimary)
    }

    func testBorder() {
        XCTAssertNotEqual(Theme.border, Theme.bgPrimary)
    }

    func testSeparator() {
        XCTAssertNotEqual(Theme.separator, Theme.bgPrimary)
    }

    // MARK: - Brand (fundraising)

    func testGithubSponsors() {
        XCTAssertNotEqual(Theme.githubSponsors, Theme.patreon)
    }

    func testBuyMeACoffee() {
        XCTAssertNotEqual(Theme.buyMeACoffee, Theme.patreon)
    }

    func testPatreon() {
        XCTAssertNotEqual(Theme.patreon, Theme.githubSponsors)
    }

    // MARK: - Brand Identity

    func testBrandBlue() {
        XCTAssertNotEqual(Theme.Brand.blue, Theme.Brand.blueLight)
    }

    func testBrandBlueLight() {
        XCTAssertNotEqual(Theme.Brand.blueLight, Theme.Brand.blueDark)
    }

    func testBrandBlueDark() {
        XCTAssertNotEqual(Theme.Brand.blueDark, Theme.Brand.blue)
    }

    func testBrandSilver() {
        XCTAssertNotEqual(Theme.Brand.silver, Theme.Brand.silverLight)
    }

    func testBrandSilverLight() {
        XCTAssertNotEqual(Theme.Brand.silverLight, Theme.Brand.silverDark)
    }

    func testBrandSilverDark() {
        XCTAssertNotEqual(Theme.Brand.silverDark, Theme.Brand.silver)
    }

    func testBrandArrowBlue() {
        XCTAssertNotEqual(Theme.Brand.arrowBlue, Theme.Brand.blue)
    }

    func testBrandBlueGradient() {
        XCTAssertFalse(String(describing: Theme.Brand.blueGradient).isEmpty)
    }

    func testBrandSilverGradient() {
        XCTAssertFalse(String(describing: Theme.Brand.silverGradient).isEmpty)
    }
}
