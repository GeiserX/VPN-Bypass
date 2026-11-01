// Theme.swift
// The app's design tokens: colour roles, type, spacing and radii (rework section 2,
// docs/design/APP-REWORK-PROPOSALS.md). The shared views built on them are in Components.swift.

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

    // MARK: - Greys and surfaces (on dark backgrounds ~#0F0F14)

    /// Every secondary word, count, label and placeholder: ~7.2:1 contrast.
    static let textSecondary = Color(hex: "9CA3AF")
    /// Disabled text and decoration only: ~3.8:1, too faint for words a user must read.
    static let textTertiary = Color(hex: "6B7280")

    static let bgPrimary = Color(hex: "0F0F14")
    static let bgSecondary = Color(hex: "1A1B26")
    static let bgCard = Color.white.opacity(0.05)
    static let bgInput = Color.white.opacity(0.08)
    static let bgDisabled = Color.white.opacity(0.10)
    static let bgHover = Color.white.opacity(0.08)
    /// Lists and log areas.
    static let bgElevated = Color.white.opacity(0.04)

    static let border = Color.white.opacity(0.10)
    static let separator = Color.white.opacity(0.08)

    // MARK: - Brand Identity

    /// The "Lanes" identity (2026-08). Electric blue on deep navy, with a sky accent that
    /// matches the arrow in the mark. Kept in sync with docs/design/generate.py — the same
    /// values generate the icon, wordmark and banner, so nothing drifts between code and art.
    enum Brand {
        static let blue = Color(hex: "2563EB")        // #2563EB — primary
        /// The mark's arrow / accent, and the highlight in the icon gradient.
        static let sky = Color(hex: "38BDF8")         // #38BDF8
    }
}
