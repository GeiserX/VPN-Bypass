// LookupsTab.swift
// The DNS Lookups page (#176): turn the capture on, then add any name this Mac looks up.

import SwiftUI

struct LookupsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var monitor = DNSLookupsMonitor.shared
    @State private var query = ""
    @State private var feedback: AddDomainFeedback?

    /// Rows drawn at once. The count line says when there are more, and search reaches them.
    static let shownLimit = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "DNS Lookups", icon: "magnifyingglass", iconColor: Theme.cyan) {
                SettingsToggleRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Watch DNS Lookups",
                    subtitle: "List the names this Mac looks up, to pick what to add",
                    isOn: Binding(
                        get: { routeManager.config.dnsLookupsEnabled },
                        set: { on in
                            feedback = nil
                            monitor.setEnabled(on)
                        }
                    )
                )

                Text("When this is on, the helper runs tcpdump to read the DNS questions this Mac sends, never their answers or any other traffic. The list stays in memory and is cleared when you turn this off or quit.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Lookups a browser sends over encrypted DNS (Secure DNS, DNS over HTTPS) never show here. To see them, turn Secure DNS off in the browser's settings.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if routeManager.config.dnsLookupsEnabled {
                lookups
            }
        }
    }

    @ViewBuilder
    private var lookups: some View {
        let ranked = monitor.tally.ranked(matching: query)
        VStack(alignment: .leading, spacing: 10) {
            if let problem = monitor.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.warning)
            }

            HStack(spacing: 10) {
                LogSearchField(text: $query, placeholder: String(localized: "Search"))
                    .frame(minWidth: 110, maxWidth: 220)
                Spacer(minLength: 0)
                Button("Clear") {
                    feedback = nil
                    monitor.clear()
                }
                .disabled(monitor.tally.entries.isEmpty)
                .help(String(localized: "Start counting again from now"))
            }

            if let since = monitor.since {
                Text("\(monitor.tally.entries.count) names, counting since \(since.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, 2)
            }

            if let feedback {
                AddDomainFeedbackLine(feedback: feedback)
            }

            if ranked.isEmpty {
                Text(query.isEmpty ? String(localized: "Waiting for lookups…") : String(localized: "No name matches \"\(query)\""))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgElevated))
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(ranked.prefix(Self.shownLimit)) { entry in
                        row(entry)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgElevated))

                if ranked.count > Self.shownLimit {
                    Text("Showing the top \(Self.shownLimit). Search to find the rest.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.leading, 2)
                }
            }
        }
    }

    private func row(_ entry: DNSLookupTally.Entry) -> some View {
        HStack(spacing: 10) {
            Text("\(entry.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 44, alignment: .trailing)
                .help(String(localized: "Times looked up"))
            Text(entry.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if routeManager.isListedInCurrentMode(entry.name) {
                Text("Listed")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.success)
            } else {
                Button("Add") { add(entry.name) }
                    .controlSize(.small)
                    .help(addHelp)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var addHelp: String {
        if routeManager.config.routingMode == .vpnOnly { return String(localized: "Add to the VPN Only list") }
        if RouteManager.usesCustomEngine(schemaVersion: routeManager.config.schemaVersion, routingMode: routeManager.config.routingMode) {
            return String(localized: "Add a rule that sends it Direct")
        }
        return String(localized: "Add to the Bypass list")
    }

    private func add(_ name: String) {
        feedback = routeManager.addForCurrentMode(name).map { AddDomainFeedback($0, typed: name) }
    }
}
