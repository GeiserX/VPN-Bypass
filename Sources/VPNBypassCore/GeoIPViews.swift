// GeoIPViews.swift
// What Country (GeoIP) rules show: the name and the line under a row, the status line under the
// Rules list, and the country field of the Add Rule sheet. The wording lives in `GeoIPDisplay`
// as pure functions so the tests can read it without a window.

import SwiftUI

enum GeoIPDisplay {

    /// A rule's code as its row names it: "Iran (IR)" for a country, "PRIVATE" for a list that
    /// is not one.
    static func name(for code: String, locale: Locale = .current) -> String {
        let upper = code.uppercased()
        if upper.count == 2, let region = locale.localizedString(forRegionCode: upper) {
            return "\(region) (\(upper))"
        }
        return upper
    }

    /// The line under a Country rule's row: what it holds, or why it holds nothing yet.
    static func detail(count: Int?, hasData: Bool, in bundle: Bundle = .main) -> String {
        guard hasData else { return String(localized: "Country list not downloaded yet.", bundle: bundle) }
        switch count ?? 0 {
        case 0: return String(localized: "Not in the country list.", bundle: bundle)
        case 1: return String(localized: "1 range", bundle: bundle)
        case let n: return String(localized: "\(n) ranges", bundle: bundle)
        }
    }

    /// The Rules page's line about the list: where it came from and how old it is.
    static func status(updated: Date?, host: String?, phase: GeoIPStore.Phase, now: Date = Date(),
                       in bundle: Bundle = .main) -> String {
        switch phase {
        case .updating:
            return String(localized: "Downloading the country list…", bundle: bundle)
        case .failed(let reason):
            return reason
        case .idle:
            guard let updated else { return String(localized: "The country list is not downloaded yet.", bundle: bundle) }
            let age = RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: now)
            if let host { return String(localized: "Country list from \(host), updated \(age).", bundle: bundle) }
            return String(localized: "Country list updated \(age).", bundle: bundle)
        }
    }
}

/// The line under the Rules list while a Country rule is on: the list's source and age, and Update.
struct GeoIPStatusLine: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var store = GeoIPStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(GeoIPDisplay.status(updated: store.updated,
                                     host: GeoIPStore.source(from: routeManager.config.geoipSourceURL)?.host,
                                     phase: store.phase))
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await routeManager.updateGeoIPData() }
            } label: {
                Text("Update")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Theme.bgDisabled)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .disabled(store.phase == .updating)
            .opacity(store.phase == .updating ? 0.5 : 1)
            .accessibilityLabel(String(localized: "Update the country list"))
        }
    }
}

/// The Country field of the Add Rule sheet: a code typed, or a country chosen from the list once
/// it has been downloaded.
struct GeoIPEditorField: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var store = GeoIPStore.shared
    @Binding var code: String
    /// A code as the field shows one. A `String`, so it is not looked up as a translation.
    private static let example: String = "ir"

    var body: some View {
        SheetField(String(localized: "Country"), required: true) {
            VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                HStack(spacing: Theme.Space.s) {
                    TextField(Self.example, text: $code)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.mono)
                        .accessibilityLabel(String(localized: "Country code"))
                    if store.hasData {
                        Menu(String(localized: "Choose…")) {
                            ForEach(store.countries(), id: \.code) { country in
                                Button("\(GeoIPDisplay.name(for: country.code))  ·  \(country.count)") {
                                    code = country.code
                                }
                            }
                        }
                        .fixedSize()
                        .accessibilityLabel(String(localized: "Choose a country from the list"))
                    }
                }
                Text(GeoIPDisplay.status(updated: store.updated,
                                         host: GeoIPStore.source(from: routeManager.config.geoipSourceURL)?.host,
                                         phase: store.phase))
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.hasData {
                    Text("It downloads when you add the rule.")
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }
}
