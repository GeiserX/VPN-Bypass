// Theme.swift
// The app's design tokens: colour roles, type, spacing and radii (rework section 2,
// docs/design/APP-REWORK-PROPOSALS.md). The shared views built on them are in Components.swift.
// The older colour names below the roles stay until the last page moves over (rework step 11).

import SwiftUI

enum Theme {
    // MARK: - Colour roles: each colour has one job

    /// Names, values, headlines.
    static let text = Color.white
    /// Something is routed right now: the status chip's dot, a passed path check. Nothing else.
    static let live = Color(hex: "10B981")
    /// The user needs to look: the ▲ glyph and its line.
    static let attention = Color(hex: "F59E0B")
    /// A write that failed; destructive confirm buttons.
    static let failure = Color(hex: "EF4444")
    /// The one primary button, a switch that is on, the selected sidebar row.
    static let accent = Brand.blue
    /// Links, the focus ring, a selected glyph.
    static let accentText = Brand.sky

    // MARK: - Type: five steps and one monospaced style

    enum Font {
        /// Page and sheet titles: 17 semibold.
        static let title = SwiftUI.Font.system(size: 17, weight: .semibold)
        /// Names and sentences: 13 regular.
        static let body = SwiftUI.Font.system(size: 13)
        /// Headlines: 13 medium.
        static let strong = SwiftUI.Font.system(size: 13, weight: .medium)
        /// The label above a group of rows, in title case: 11 semibold, drawn in `textSecondary`.
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// Second lines, notes, counts: 11 regular, drawn in `textSecondary`.
        static let detail = SwiftUI.Font.system(size: 11)
        /// IP addresses, ports and CIDR only, never domain names: 12 monospaced.
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }

    // MARK: - Spacing and radii

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        /// Page margins.
        static let page: CGFloat = 24
    }

    enum Radius {
        /// Buttons, fields, chips.
        static let control: CGFloat = 6
        /// Group boxes.
        static let group: CGFloat = 10
        /// Sheets.
        static let sheet: CGFloat = 14
    }

    // MARK: - Text Colors (on dark backgrounds ~#0F0F14)

    /// Old name of `text`.
    static let textPrimary = text
    static let textSecondary = Color(hex: "9CA3AF")     // ~7.2:1 contrast
    static let textTertiary = Color(hex: "6B7280")       // ~3.8:1 - decorative only
    static let textDisabled = Color(hex: "7D8491")       // ~4.6:1 WCAG AA compliant

    // MARK: - Semantic Status Colors

    // Old names, kept until rework step 11: `success` is `live`, `error` is `failure`,
    // `warning` is `attention`. New code uses the roles above.
    static let success = live
    static let successDark = Color(hex: "059669")
    static let error = failure
    static let warning = attention
    static let warningLight = Color(hex: "FBBF24")
    static let purple = Color(hex: "8B5CF6")
    static let purpleLight = Color(hex: "A78BFA")
    static let blue = Color(hex: "3B82F6")
    static let blueDark = Color(hex: "2563EB")
    static let blueLight = Color(hex: "60A5FA")
    static let cyan = Color(hex: "06B6D4")

    // MARK: - Gradients

    static let accentGradient = LinearGradient(
        colors: [success, successDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let warningGradient = LinearGradient(
        colors: [warning, warningLight],
        startPoint: .top,
        endPoint: .bottom
    )

    static let successLight = Color(hex: "34D399")

    static let successGradient = LinearGradient(
        colors: [success, successLight],
        startPoint: .top,
        endPoint: .bottom
    )

    static let purpleGradient = LinearGradient(
        colors: [purple, purpleLight],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let blueGradient = LinearGradient(
        colors: [blue, blueLight],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Backgrounds

    static let bgPrimary = Color(hex: "0F0F14")
    static let bgSecondary = Color(hex: "1A1B26")
    static let bgCard = Color.white.opacity(0.05)        // was 0.03 (invisible)
    static let bgCardBorder = Color.white.opacity(0.10)   // was 0.06 (invisible)
    static let bgInput = Color.white.opacity(0.08)        // was 0.06
    static let bgInputAlt = Color(hex: "1F2937")
    static let bgDisabled = Color.white.opacity(0.10)     // was #374151 (~1.8:1)
    static let bgHover = Color.white.opacity(0.08)        // was 0.05 (invisible)
    static let bgElevated = Color.white.opacity(0.04)     // for lists, log areas

    // MARK: - Structural

    static let divider = Color.white.opacity(0.12)        // was 0.1 (~1.1:1 invisible)
    static let border = Color.white.opacity(0.10)
    static let separator = Color.white.opacity(0.08)

    // MARK: - Brand Identity

    /// The "Lanes" identity (2026-08). Electric blue on deep navy, with a sky accent that
    /// matches the arrow in the mark. Kept in sync with docs/design/generate.py — the same
    /// values generate the icon, wordmark and banner, so nothing drifts between code and art.
    enum Brand {
        static let blue = Color(hex: "2563EB")        // #2563EB — primary
        static let blueLight = Color(hex: "60A5FA")
        static let blueDark = Color(hex: "1E40AF")    // #1E40AF — secondary type

        /// The mark's arrow / accent, and the highlight in the icon gradient.
        static let sky = Color(hex: "38BDF8")         // #38BDF8

        static let silver = Color(hex: "CBD5E1")
        static let silverLight = Color(hex: "E2E8F0")
        static let silverDark = Color(hex: "64748B")

        static let arrowBlue = sky

        static let blueGradient = LinearGradient(
            colors: [blueLight, blue, blueDark],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let silverGradient = LinearGradient(
            colors: [silverLight, silver, silverDark],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
