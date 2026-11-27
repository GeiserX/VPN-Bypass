// HostsListViews.swift
// The Rules page's parts for list rules (HostsBlocklist.swift): the one preset, the list field of the
// rule editor, and the fixed note under the rules that says what a list does and does not block.

import SwiftUI

/// The lists the rule editor offers by name. One: a list everyone can check, in the hosts format.
enum HostsListPreset {
    /// StevenBlack's unified hosts list: ads and malware, about 80,000 names.
    static let stevenBlackURL = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"

    /// The name a row shows for a list's URL: the preset's name, or the URL itself.
    static func name(for pattern: String, in bundle: Bundle = .main) -> String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines) == stevenBlackURL
            ? String(localized: "StevenBlack's unified hosts list", bundle: bundle) : pattern
    }
}

/// The note under the rules while any list rule is listed: what a list blocks, what may skip it, what
/// each change costs, and that the blocks outlive the app.
struct HostsListFootnote: View {
    /// Where the cost of a change was measured.
    static let measurementURL = URL(string: "https://github.com/GeiserX/VPN-Bypass/blob/main/docs/research/hosts-scale.md")!

    static func text(in bundle: Bundle = .main) -> String {
        [
            String(localized: "A list blocks exactly the names in it, not their subdomains.", bundle: bundle),
            String(localized: "A browser that uses its own secure DNS may skip it.", bundle: bundle),
            String(localized: "Each time a list or a pinned address changes, every lookup on this Mac waits a few seconds.", bundle: bundle),
            String(localized: "The blocks stay while VPN Bypass is closed, until the Mac restarts; they come back when it opens.", bundle: bundle),
            String(localized: "To unblock a name, add a rule for it above the list.", bundle: bundle),
        ].joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.text())
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(String(localized: "How the wait was measured"), destination: Self.measurementURL)
                .font(.system(size: 12))
        }
    }
}

/// The rule editor's field for a list: the preset, or an https address typed in.
struct HostsListField: View {
    @Binding var pattern: String
    /// Where the menu's and the note's texts come from: the app's catalog, or one language's in the
    /// sheet width tests.
    var bundle: Bundle = .main

    private enum Choice: Hashable { case preset, custom }

    private var choice: Binding<Choice> {
        Binding(
            get: { pattern == HostsListPreset.stevenBlackURL ? .preset : .custom },
            set: { pattern = $0 == .preset ? HostsListPreset.stevenBlackURL : "" }
        )
    }

    var body: some View {
        SheetField(String(localized: "List", bundle: bundle), required: true) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Picker(String(localized: "List", bundle: bundle), selection: choice) {
                    Text(String(localized: "StevenBlack's unified hosts list", bundle: bundle)).tag(Choice.preset)
                    Text(String(localized: "Another list by its address", bundle: bundle)).tag(Choice.custom)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                if choice.wrappedValue == .custom {
                    TextField("https://example.com/hosts" as String, text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.body)
                        .accessibilityLabel(String(localized: "The list's https address", bundle: bundle))
                }
                Text(String(localized: "A hosts-format list (0.0.0.0 name per line). Adblock and wildcard lists are refused.", bundle: bundle))
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
