// LearnSiteSection.swift
// Learn a site on the Lookups page (SiteLearning.swift): the countdown while the window is
// open, then the names first seen in it, one row per site domain, the wildcard offer for a
// site with three names or more, and one Add for all of it. The search-domain retries are
// folded as on the Lookups list, and the sites whose names other apps were already looking up
// before the window opened are listed apart, last, and added only when the user says so.

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
    /// The search-domain retries are listed too.
    @State private var showsRetries = false
    /// The one Add takes the sites seen before the window too.
    @State private var addsSeenBefore = false

    private var mode: LookupMode { LookupMode(routeManager) }
    private var shown: SiteLearning.Shown {
        learning.shown(searchDomains: monitor.searchDomains, showsRetries: showsRetries)
    }
    /// What the one Add covers.
    private var added: [SiteLearning.Group] {
        let shown = self.shown
        return shown.site + (addsSeenBefore ? shown.seenBefore : [])
    }
    private var plan: [String] {
        SiteLearning.plan(added, wildcards: wildcards, isListed: { routeManager.lookupListing($0) != nil })
    }
    /// Sites seen before that the Add leaves out and that have a name the mode does not route.
    private var leavesOutSeenBefore: Bool {
        !addsSeenBefore && shown.seenBefore.contains { $0.names.contains { routeManager.lookupListing($0) == nil } }
    }
    /// Routed by the mode: listed and on. A name whose own entry is switched off is not routed,
    /// and adding it again is refused, so it is turned on from the Domains page instead.
    private func isRouted(_ name: String) -> Bool {
        guard let listing = routeManager.lookupListing(name) else { return false }
        return listing != .listedOff
    }
    private var hasSwitchedOff: Bool {
        learning.names.contains { routeManager.lookupListing($0) == .listedOff }
    }
    /// A name the Add covers is switched off: that comes before the sites it leaves out, since
    /// ticking them would not turn the name on.
    private var addedHasSwitchedOff: Bool {
        added.contains { $0.names.contains { routeManager.lookupListing($0) == .listedOff } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            // The page shows the capture's problem only while it watches; the window needs it too.
            if learning.isOpen, let problem = monitor.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.attention)
            }
            let shown = self.shown
            let numberWidth = ListRow.numberColumnWidth(
                for: (shown.site + shown.seenBefore).map { LookupRow.format($0.names.count) })
            GroupSection(title, trailing: { trailing }) {
                if shown.site.isEmpty {
                    EmptyState(systemImage: learning.isOpen ? "arrow.clockwise"
                                   : learning.heard ? "checkmark.circle" : "exclamationmark.triangle",
                               title: learning.isOpen
                                   ? String(localized: "Reload the page that does not work now.")
                                   : !shown.seenBefore.isEmpty
                                   ? String(localized: "Every name was looked up before you started too.")
                                   : shown.retries > 0
                                   ? String(localized: "Only search-domain retries were looked up while learning.")
                                   : learning.heard
                                   ? String(localized: "No name was looked up while learning.")
                                   : String(localized: "The helper read no lookups in this window, so nothing was learned."))
                } else {
                    rows(shown.site, numberWidth: numberWidth)
                }
            }
            if shown.retries > 0 {
                let title = LookupsTab.retriesToggleTitle(count: shown.retries, showing: showsRetries)
                Button(title) { showsRetries.toggle() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(String(localized: "Names that are another looked-up name with a domain appended, as the resolver or a VPN client asks when a name gets no answer"))
                    .accessibilityLabel(title)
                    .padding(.leading, 2)
            }
            if !shown.seenBefore.isEmpty {
                GroupSection(String(localized: "Seen before you started"), trailing: { seenBeforeTrailing }) {
                    rows(shown.seenBefore, numberWidth: numberWidth)
                }
                .help(String(localized: "Every name of these sites was looked up in the 5 minutes before learning started, so another app may have asked for them"))
            }
            if !learning.isOpen, !(shown.site + shown.seenBefore).isEmpty {
                addBar
            }
        }
    }

    private func rows(_ groups: [SiteLearning.Group], numberWidth: CGFloat) -> some View {
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            VStack(spacing: 0) {
                if index > 0 { InsetDivider() }
                row(group, numberWidth: numberWidth)
            }
        }
    }

    /// Once the window is closed, the choice to add the sites seen before too.
    @ViewBuilder private var seenBeforeTrailing: some View {
        if !learning.isOpen {
            Toggle(isOn: $addsSeenBefore) {
                Text("Add these too")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(String(localized: "Add these sites with the rest: leave this off when another app asked for them"))
            .accessibilityLabel(String(localized: "Add the sites seen before you started too"))
        }
    }

    /// Learning, with the seconds left, or what the window found.
    private var title: String {
        if learning.isOpen {
            return String(localized: "Learning a site: reload the page now")
        }
        return String(localized: "Learned: \(learning.names.count) names")
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
        let unlisted = group.names.filter { !isRouted($0) }
        let wildcardListed = group.wildcard.map { routeManager.lookupListing($0) != nil } ?? false
        return ListRow(
            glyph: unlisted.isEmpty ? "checkmark.circle" : "globe",
            name: group.site,
            detail: group.names.joined(separator: ", "),
            number: LookupRow.format(group.names.count),
            numberWidth: numberWidth,
            numberLabel: LookupRow.namesLabel(group.names.count),
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
            Text(!plan.isEmpty
                 ? String(localized: "Entries to add: \(plan.count)")
                 : addedHasSwitchedOff
                 ? String(localized: "A name here is on the list but switched off. Turn it on from the Domains page.")
                 : leavesOutSeenBefore
                 ? String(localized: "Nothing to add from this window. Tick Add these too to add the sites seen before.")
                 : hasSwitchedOff
                 ? String(localized: "A name here is on the list but switched off. Turn it on from the Domains page.")
                 : String(localized: "Every name here is routed already."))
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
        let chosenMode = mode
        let session = learning.started
        isAdding = true
        Task { @MainActor in
            let result = await routeManager.addLearned(entries, mode: chosenMode)
            isAdding = false
            // Done or a new window meanwhile: the line would describe names no longer shown.
            guard monitor.learning?.started == session else { return }
            feedback = result
        }
    }
}
