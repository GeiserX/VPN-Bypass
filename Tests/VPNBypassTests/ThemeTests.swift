import XCTest
@testable import VPNBypassCore
import SwiftUI

final class ThemeColorTests: XCTestCase {

    // MARK: - Greys and surfaces

    func testTextGreysAreDistinct() {
        // Secondary text is a mid-grey, distinct from the pure-white text and the tertiary grey.
        XCTAssertNotEqual(Theme.textSecondary, Theme.text)
        XCTAssertNotEqual(Theme.textTertiary, Theme.textSecondary)
    }

    /// An egress gets no colour of its own (rework section 2): the dropdown's Custom-mode
    /// "Routes In Use" summary gave HTTP and SOCKS5 their own blue and purple dots, Tailscale
    /// the live green and the VPN the attention orange. It shows the grey glyph the Rules and
    /// Routes pages use.
    func testAnEgressHasNoColourOfItsOwn() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: ReworkSource.core.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 20)
        let regex = try NSRegularExpression(pattern: #"Theme\.(blue|purple)\b|\.accentColor\b"#)
        for file in files {
            let text = try ReworkSource.read(file)
            let hits = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertTrue(hits.isEmpty, "\(file) gives an egress a colour")
        }
        let dropdown = try ReworkSource.read("MenuBarViews.swift")
        XCTAssertTrue(dropdown.contains("Image(systemName: RouteChip.systemImage(for: route.egress))"),
                      "the summary shows the egress glyph")
    }

    // Several surfaces are Color.white at differing opacities, so some share an alpha
    // (bgInput and bgHover are both 0.08). Translucent members are compared against a solid,
    // opaque anchor (bgPrimary) rather than a possibly-equal sibling.

    func testSurfaces() {
        XCTAssertNotEqual(Theme.bgPrimary, Theme.bgSecondary)
        for surface in [Theme.bgCard, Theme.bgInput, Theme.bgDisabled, Theme.bgHover, Theme.bgElevated,
                        Theme.border, Theme.separator] {
            XCTAssertNotEqual(surface, Theme.bgPrimary)
        }
    }

    // MARK: - Brand Identity

    func testBrandColours() {
        XCTAssertEqual(Theme.Brand.blue, Color(hex: "2563EB"))
        XCTAssertEqual(Theme.Brand.sky, Color(hex: "38BDF8"))
    }

    // MARK: - The migration is over

    /// The names kept for the move to the colour roles (`textPrimary`, `success`, `warning`,
    /// `error`), the five gradients and the colours nothing draws any more are gone, from
    /// `Theme.swift` and from every source file. A new use of one would bring a second name
    /// for the same job back.
    func testTheOldThemeNamesAreGone() throws {
        let old = ["textPrimary", "textDisabled", "success", "successDark", "successLight", "error",
                   "warning", "warningLight", "purpleLight", "blueDark", "blueLight", "cyan",
                   "accentGradient", "warningGradient", "successGradient", "purpleGradient",
                   "blueGradient", "bgCardBorder", "bgInputAlt", "divider", "silver", "silverLight",
                   "silverDark", "arrowBlue", "silverGradient"]
        let theme = try ReworkSource.read("Theme.swift")
        for name in old {
            XCTAssertNil(theme.range(of: "static let \(name) "), "Theme declares \(name) again")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: ReworkSource.core.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 20)
        let pattern = "Theme\\.(Brand\\.)?(" + old.joined(separator: "|") + ")\\b"
        let regex = try NSRegularExpression(pattern: pattern)
        for file in files {
            let source = try ReworkSource.read(file)
            let range = NSRange(source.startIndex..., in: source)
            if let hit = regex.firstMatch(in: source, range: range) {
                XCTFail("\(file) still uses \((source as NSString).substring(with: hit.range))")
            }
        }
    }
}
