// LearnSiteSection.swift
// Learn a site on the Lookups page (SiteLearning.swift): the countdown while the window is
// open, then the names first seen in it, one row per site domain, the wildcard offer for a
// site with three names or more, and one Add for all of it.

import SwiftUI

struct LearnSiteSection: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var monitor = DNSLookupsMonitor.shared
    let learning: SiteLearning
    /// The page's line for what the last add did.
    @Binding var feedback: AddDomainFeedback?
    /// The wildcards the user chose instead of a site's names.
    @State private var wildcards: Set<String> = []
    @State private var isAdding = false

    private var mode: LookupMode { LookupMode(routeManager) }
    private var groups: [SiteLearning.Group] { learning.groups }
    private var plan: [String] {
        SiteLearning.plan(groups, wildcards: wildcards, isListed: { routeManager.lookupListing($0) != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GroupSection(title, trailing: { trailing }) {
                if groups.isEmpty {
                    EmptyState(systemImage: learning.isOpen ? "arrow.clockwise" : "checkmark.circle",
                               title: learning.isOpen
                                   ? String(localized: "Reload the page that does not work now.")
                                   : String(localized: "No name was looked up in the 60 seconds."))
                } else {
                    let numberWidth = ListRow.numberColumnWidth(for: groups.map { LookupRow.format($0.names.count) })
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        VStack(spacing: 0) {
                            if index > 0 { InsetDivider() }
                            row(group, numberWidth: numberWidth)
                        }
                    }
                }
            }
            if !learning.isOpen, !groups.isEmpty {
                addBar
            }
        }
    }

    /// Learning, with the seconds left, or what the window found.
    private var title: String {
        if learning.isOpen {
            return String(localized: "Learning a site: reload the page now")
        }
        return String(localized: "Learned in 60 s: \(learning.names.count) names")
    }

    @ViewBuilder private var trailing: some View {
        if learning.isOpen {
            HStack(spacing: Theme.Space.s) {
                TimelineView(.periodic(from: learning.started, by: 1)) { context in
                    Text("\(learning.secondsLeft(at: context.date)) s left")
                        .monospacedDigit()
                }
                Button(String(localized: "Stop")) { Task { await monitor.stopLearning() } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(String(localized: "Stop learning now and keep the names seen so far"))
                    .accessibilityLabel(String(localized: "Stop Learning"))
            }
        } else {
            Button(String(localized: "Done")) {
                feedback = nil
                monitor.dismissLearning()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(String(localized: "Forget these names"))
            .accessibilityLabel(String(localized: "Done Learning"))
        }
    }

    /// One site domain: its names in the detail line, how many in the number column, and the
    /// wildcard offer at the end when it has three names or more.
    private func row(_ group: SiteLearning.Group, numberWidth: CGFloat) -> some View {
        let unlisted = group.names.filter { routeManager.lookupListing($0) == nil }
        let wildcardListed = group.wildcard.map { routeManager.lookupListing($0) != nil } ?? false
        return ListRow(
            glyph: unlisted.isEmpty ? "checkmark.circle" : "globe",
            name: group.site,
            detail: group.names.joined(separator: ", "),
            number: LookupRow.format(group.names.count),
            numberWidth: numberWidth,
            accessory: group.wildcard.flatMap { wildcard in
                guard !unlisted.isEmpty, !wildcardListed, !learning.isOpen else { return nil }
                return AnyView(wildcardToggle(wildcard))
            },
            detailLineLimit: nil
        )
        .help(unlisted.isEmpty
              ? String(localized: "Every name of \(group.site) is routed already")
              : group.names.joined(separator: "\n"))
    }

    private func wildcardToggle(_ wildcard: String) -> some View {
        Toggle(isOn: Binding(
            get: { wildcards.contains(wildcard) },
            set: { on in if on { wildcards.insert(wildcard) } else { wildcards.remove(wildcard) } }
        )) {
            Text(wildcard)
                .font(Theme.Font.mono)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .help(String(localized: "Add \(wildcard) instead of these names: it covers every name under the site, now and later"))
        .accessibilityLabel(String(localized: "Add as \(wildcard)"))
    }

    /// The one Add: how many entries it puts on the mode's list, and the button.
    private var addBar: some View {
        HStack(spacing: Theme.Space.m) {
            Text(plan.isEmpty
                 ? String(localized: "Every name here is routed already.")
                 : String(localized: "Entries to add: \(plan.count)"))
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: Theme.Space.s)
            if isAdding { ProgressView().controlSize(.small) }
            Button(mode.addTitle) { add() }
                .controlSize(.small)
                .disabled(plan.isEmpty || isAdding || routeManager.isApplyingRoutes)
                .help(mode.addHelp)
                .accessibilityLabel(String(localized: "\(mode.addTitle), \(plan.count) entries"))
        }
        .padding(.horizontal, 2)
    }

    private func add() {
        let entries = plan
        isAdding = true
        Task { @MainActor in
            feedback = await routeManager.addLearned(entries)
            isAdding = false
        }
    }
}
