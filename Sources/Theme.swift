// Theme.swift
// Centralized semantic color system for consistent dark mode contrast.

import SwiftUI

enum Theme {
    // MARK: - Text Colors (on dark backgrounds ~#0F0F14)

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "9CA3AF")     // ~5.7:1 contrast
    static let textTertiary = Color(hex: "6B7280")       // ~4.2:1 - decorative only
    static let textDisabled = Color(hex: "6B7280")       // was #4B5563 (~2.7:1 FAIL)

    // MARK: - Semantic Status Colors

    static let success = Color(hex: "10B981")
    static let successDark = Color(hex: "059669")
    static let error = Color(hex: "EF4444")
    static let warning = Color(hex: "F59E0B")
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

    static let successGradient = LinearGradient(
        colors: [success, Color(hex: "34D399")],
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

    // MARK: - Brand

    static let githubSponsors = Color(hex: "DB61A2")
    static let buyMeACoffee = Color(hex: "FFDD00")
    static let patreon = Color(hex: "FF424D")
}
