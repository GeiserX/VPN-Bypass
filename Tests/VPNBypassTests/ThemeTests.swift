import XCTest
@testable import VPNBypassCore
import SwiftUI

final class ThemeColorTests: XCTestCase {

    // MARK: - Text Colors

    func testTextPrimaryIsWhite() {
        XCTAssertEqual(Theme.textPrimary, Color.white)
    }

    func testTextSecondaryNotNil() {
        _ = Theme.textSecondary
    }

    func testTextTertiaryNotNil() {
        _ = Theme.textTertiary
    }

    func testTextDisabledNotNil() {
        _ = Theme.textDisabled
    }

    // MARK: - Semantic Status Colors

    func testSuccessColor() {
        _ = Theme.success
    }

    func testSuccessDarkColor() {
        _ = Theme.successDark
    }

    func testSuccessLightColor() {
        _ = Theme.successLight
    }

    func testErrorColor() {
        _ = Theme.error
    }

    func testWarningColor() {
        _ = Theme.warning
    }

    func testWarningLightColor() {
        _ = Theme.warningLight
    }

    func testPurpleColor() {
        _ = Theme.purple
    }

    func testPurpleLightColor() {
        _ = Theme.purpleLight
    }

    func testBlueColor() {
        _ = Theme.blue
    }

    func testBlueDarkColor() {
        _ = Theme.blueDark
    }

    func testBlueLightColor() {
        _ = Theme.blueLight
    }

    func testCyanColor() {
        _ = Theme.cyan
    }

    // MARK: - Gradients

    func testAccentGradient() {
        _ = Theme.accentGradient
    }

    func testWarningGradient() {
        _ = Theme.warningGradient
    }

    func testSuccessGradient() {
        _ = Theme.successGradient
    }

    func testPurpleGradient() {
        _ = Theme.purpleGradient
    }

    func testBlueGradient() {
        _ = Theme.blueGradient
    }

    // MARK: - Backgrounds

    func testBgPrimary() {
        _ = Theme.bgPrimary
    }

    func testBgSecondary() {
        _ = Theme.bgSecondary
    }

    func testBgCard() {
        _ = Theme.bgCard
    }

    func testBgCardBorder() {
        _ = Theme.bgCardBorder
    }

    func testBgInput() {
        _ = Theme.bgInput
    }

    func testBgInputAlt() {
        _ = Theme.bgInputAlt
    }

    func testBgDisabled() {
        _ = Theme.bgDisabled
    }

    func testBgHover() {
        _ = Theme.bgHover
    }

    func testBgElevated() {
        _ = Theme.bgElevated
    }

    // MARK: - Structural

    func testDivider() {
        _ = Theme.divider
    }

    func testBorder() {
        _ = Theme.border
    }

    func testSeparator() {
        _ = Theme.separator
    }

    // MARK: - Brand (fundraising)

    func testGithubSponsors() {
        _ = Theme.githubSponsors
    }

    func testBuyMeACoffee() {
        _ = Theme.buyMeACoffee
    }

    func testPatreon() {
        _ = Theme.patreon
    }

    // MARK: - Brand Identity

    func testBrandBlue() {
        _ = Theme.Brand.blue
    }

    func testBrandBlueLight() {
        _ = Theme.Brand.blueLight
    }

    func testBrandBlueDark() {
        _ = Theme.Brand.blueDark
    }

    func testBrandSilver() {
        _ = Theme.Brand.silver
    }

    func testBrandSilverLight() {
        _ = Theme.Brand.silverLight
    }

    func testBrandSilverDark() {
        _ = Theme.Brand.silverDark
    }

    func testBrandArrowBlue() {
        _ = Theme.Brand.arrowBlue
    }

    func testBrandBlueGradient() {
        _ = Theme.Brand.blueGradient
    }

    func testBrandSilverGradient() {
        _ = Theme.Brand.silverGradient
    }
}
