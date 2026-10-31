// DomainsPage.swift
// The Domains page on the shared components (section 3.3 of docs/design/APP-REWORK-PROPOSALS.md):
// the add field as the first row of the list in use, then the other mode's list, read-only.
// The page's title is the window's (SettingsView's PageHeader), so the page has no heading.

import SwiftUI

/// The Domains page's lists name themselves after their mode. It said "Custom Domains", which
/// read as Custom mode's list (proposal 16 of #119).
enum DomainListCopy {
    static func title(isInverse: Bool, bundle: Bundle = .main) -> String {
        isInverse
            ? String(localized: "VPN Only list", bundle: bundle)
            : String(localized: "Bypass list", bundle: bundle)
    }

    /// The other mode's list, shown read-only under the one in use.
    static func otherTitle(isInverse: Bool, bundle: Bundle = .main) -> String {
        isInverse
            ? String(localized: "VPN Only list · used in VPN Only mode", bundle: bundle)
            : String(localized: "Bypass list · used in Bypass mode", bundle: bundle)
    }

    /// The add row's prompt. Only the VPN Only list takes IP ranges.
    static func addPrompt(isInverse: Bool, bundle: Bundle = .main) -> String {
        isInverse
            ? String(localized: "Add a domain, *.wildcard or IP range…", bundle: bundle)
            : String(localized: "Add a domain or *.wildcard…", bundle: bundle)
    }
}

/// The Domains page as data: one section per list, the one the mode uses first and editable,
/// then the other one read-only. Kept apart from the view so tests can read it.
enum DomainsPage {
    struct Section: Equatable {
        let list: DomainList
        let title: String
        let isReadOnly: Bool
        /// Every entry of the list; `rows` is what the search leaves of them.
        let total: Int
        let rows: [Row]
    }

    struct Row: Equatable, Identifiable {
        let entry: DomainEntry
        /// "learned as you browse" for a wildcard, "IP range" for a CIDR, "Off" on a read-only
        /// row that is switched off (it has no switch to show it).
        let detail: String?
        /// The addresses routed for the entry; none on a read-only row or in Custom, where the
        /// list routes nothing, or on a row that is off. A wildcard's are the routes it has learned.
        let number: String?
        var id: UUID { entry.id }
    }

    /// The list `mode` edits on this page: VPN Only's in VPN Only, Bypass's otherwise.
    static func activeList(for mode: RoutingMode) -> DomainList {
        mode == .vpnOnly ? .vpnOnly : .bypass
    }

    /// `routeSources` is the `source` of every installed route: a domain's routes carry its
    /// name, a wildcard's learned routes carry `*.suffix`, as the entry does.
    static func sections(mode: RoutingMode, config: Config, routeSources: [String], search: String,
                         bundle: Bundle = .main) -> [Section] {
        var counts: [String: Int] = [:]
        for source in routeSources { counts[source, default: 0] += 1 }

        let active = activeList(for: mode)
        let other: DomainList = active == .vpnOnly ? .bypass : .vpnOnly

        func entries(_ list: DomainList) -> [DomainEntry] {
            list == .vpnOnly ? config.inverseDomains : config.domains
        }

        func row(_ entry: DomainEntry, readOnly: Bool) -> Row {
            let detail: String?
            if readOnly && !entry.enabled {
                detail = String(localized: "Off", bundle: bundle)
            } else if entry.isWildcard {
                detail = String(localized: "learned as you browse", bundle: bundle)
            } else if entry.isCIDR {
                detail = String(localized: "IP range", bundle: bundle)
            } else {
                detail = nil
            }
            // Custom routes by rules, whose routes may carry the same name; neither list
            // routes anything there.
            let routes = !readOnly && entry.enabled && mode != .custom
            let number = routes ? String(counts[entry.domain] ?? 0) : nil
            return Row(entry: entry, detail: detail, number: number)
        }

        func section(_ list: DomainList, readOnly: Bool) -> Section {
            let all = entries(list)
            let isInverse = list == .vpnOnly
            return Section(
                list: list,
                title: readOnly ? DomainListCopy.otherTitle(isInverse: isInverse, bundle: bundle)
                                : DomainListCopy.title(isInverse: isInverse, bundle: bundle),
                isReadOnly: readOnly,
                total: all.count,
                rows: all.filter { SettingsSidebar.matches($0.domain, search: search) }
                         .map { row($0, readOnly: readOnly) }
            )
        }

        var out = [section(active, readOnly: false)]
        // The other mode's list shows only rows: it is left out when it is empty, and when the
        // search leaves none of it, so it never says "nothing matches" beside a list that does.
        let readOnly = section(other, readOnly: true)
        if !readOnly.rows.isEmpty { out.append(readOnly) }
        return out
    }
}

struct DomainsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var settingsUndo: SettingsUndo
    @State private var newDomain: String
    /// What the last add did, shown under the list.
    @State private var feedback: AddDomainFeedback?
    @FocusState private var isInputFocused: Bool
    /// The title bar search (⌘F), which the window owns.
    @Environment(\.settingsSearch) private var searchText

    /// The doc screenshots draw this name's row as if the pointer were on it.
    static var hoveredForScreenshots: String?

    /// The arguments seed the field and the line under the list, for a rendered screenshot.
    init(newDomain: String = "", feedback: AddDomainFeedback? = nil) {
        _newDomain = State(initialValue: newDomain)
        _feedback = State(initialValue: feedback)
    }

    private var isInverse: Bool { routeManager.config.routingMode == .vpnOnly }
    private var activeDomains: [RouteManager.DomainEntry] {
        isInverse ? routeManager.config.inverseDomains : routeManager.config.domains
    }
    private var enabledCount: Int { activeDomains.filter { $0.enabled }.count }

    private var sections: [DomainsPage.Section] {
        DomainsPage.sections(mode: routeManager.config.routingMode, config: routeManager.config,
                             routeSources: routeManager.activeRoutes.map(\.source), search: searchText)
    }

    var body: some View {
        let sections = sections
        // One width for every number on the page, so the column lines up across both lists.
        let numberWidth = ListRow.numberColumnWidth(for: sections.flatMap { $0.rows.compactMap(\.number) })
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(isInverse
                ? "Only these domains will use the VPN. Everything else bypasses it."
                : "Add domains that should bypass VPN and use your regular connection.")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(sections, id: \.list) { section in
                if section.isReadOnly {
                    readOnlySection(section, numberWidth: numberWidth)
                } else {
                    activeSection(section, numberWidth: numberWidth,
                                  pageHasNoMatch: sections.allSatisfy { $0.rows.isEmpty })
                }
            }
        }
        // Editing the text the line talks about, or switching lists, makes it stale.
        .onChange(of: newDomain) { text in
            if text != feedback?.fieldText { feedback = nil }
        }
        .onChange(of: routeManager.config.routingMode) { _ in feedback = nil }
        // A refusal such as "already on your list" stops being true once the list changes
        // (a row's delete, `vpnb domain.rm`). A saved add changes the list itself, so its
        // line stays.
        .onChange(of: activeDomains.map(\.domain)) { _ in
            if feedback?.isError == true { feedback = nil }
        }
    }

    // MARK: - The list in use

    @ViewBuilder
    private func activeSection(_ section: DomainsPage.Section, numberWidth: CGFloat, pageHasNoMatch: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GroupSection(section.title, trailing: { activeTrailing(numberWidth: numberWidth) }) {
                addRow
                if section.total == 0 {
                    InsetDivider()
                    EmptyState(systemImage: isInverse ? "lock.shield" : "globe",
                               title: String(localized: "No entries configured"),
                               message: isInverse
                                   ? String(localized: "Add domains or IP ranges that should use VPN")
                                   : String(localized: "Add a domain above to bypass VPN"))
                } else {
                    ForEach(section.rows) { row in
                        InsetDivider()
                        ListRow(glyph: glyph(for: row.entry), name: row.entry.domain, detail: row.detail,
                                number: row.number, numberWidth: numberWidth,
                                actions: [RowAction.delete(row.entry.domain) { removeDomain(row.entry) }],
                                isOn: switchBinding(for: row.entry),
                                showsActions: Self.hoveredForScreenshots == row.entry.domain)
                            .disabled(routeManager.isApplyingRoutes)
                    }
                    // Only when nothing on the page matches: the other list may hold the match.
                    if pageHasNoMatch {
                        InsetDivider()
                        SettingsSearchMiss(search: searchText)
                    }
                }
            }

            if let feedback {
                AddDomainFeedbackLine(feedback: feedback)
            }

            if let change = settingsUndo.last, change.page == .domains {
                UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
            }
        }
    }

    /// Turn All On / Off, then the label over the number column.
    private func activeTrailing(numberWidth: CGFloat) -> some View {
        HStack(spacing: Theme.Space.s) {
            if !routeManager.isApplyingRoutes && !activeDomains.isEmpty {
                BulkSwitchMenu(
                    turnAllOnTitle: String(localized: "Turn All On"),
                    canTurnOn: enabledCount < activeDomains.count,
                    canTurnOff: enabledCount > 0,
                    onTurnAllOn: { switchAll(true) },
                    onTurnAllOff: { switchAll(false) }
                )
            }
            if numberWidth > 0 {
                Text("addresses")
                    // Ends over the number column: past it come the small switch (44 pt
                    // measured on the rendered page), the row's spacing and its inset, less
                    // the header's own 2 pt.
                    .padding(.trailing, 44 + Theme.Space.s + ListRow.inset - 2)
            }
        }
    }

    /// The first row of the list: type a name, Return adds it.
    private var addRow: some View {
        let prompt = DomainListCopy.addPrompt(isInverse: isInverse)
        return HStack(spacing: Theme.Space.s) {
            Image(systemName: "plus")
                .font(.system(size: 13))
                .foregroundColor(feedback?.isError == true ? Theme.error : Theme.textSecondary)
                .frame(width: ListRow.glyphColumn)
                .accessibilityHidden(true)
            TextField(prompt, text: $newDomain)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($isInputFocused)
                .onSubmit { addDomain() }
                .disabled(routeManager.isApplyingRoutes)
                .accessibilityLabel(prompt)
            if routeManager.isApplyingRoutes {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Applying..."))
            }
        }
        .padding(.horizontal, ListRow.inset)
        .frame(minHeight: ListRow.singleLineHeight)
        .contentShape(Rectangle())
        .onTapGesture { isInputFocused = true }
    }

    // MARK: - The other mode's list

    private func readOnlySection(_ section: DomainsPage.Section, numberWidth: CGFloat) -> some View {
        GroupSection(section.title) {
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { InsetDivider() }
                ListRow(glyph: glyph(for: row.entry), name: row.entry.domain, detail: row.detail,
                        number: nil, numberWidth: numberWidth)
                    .opacity(row.entry.enabled ? 1 : 0.6)
            }
        }
    }

    // MARK: - Rows

    private func glyph(for entry: DomainEntry) -> String {
        entry.isCIDR ? "network" : "globe"
    }

    private func switchBinding(for entry: DomainEntry) -> Binding<Bool> {
        Binding(
            get: { entry.enabled },
            set: { _ in
                guard !routeManager.isApplyingRoutes else { return }
                if isInverse { routeManager.toggleInverseDomain(entry.id) }
                else { routeManager.toggleDomain(entry.id) }
            }
        )
    }

    /// Turn All On / Turn All Off. Neither asks: the list is the user's own, and the undo
    /// line switches back exactly the entries this switched.
    private func switchAll(_ on: Bool) {
        let list: DomainList = isInverse ? .vpnOnly : .bypass
        let changed = isInverse ? routeManager.setAllInverseDomainsEnabled(on) : routeManager.setAllDomainsEnabled(on)
        if !changed.isEmpty { settingsUndo.record(.domainsSwitched(ids: changed, on: on, list: list)) }
    }

    private func removeDomain(_ domain: RouteManager.DomainEntry) {
        let list: DomainList = isInverse ? .vpnOnly : .bypass
        let index = activeDomains.firstIndex(where: { $0.id == domain.id }) ?? activeDomains.count
        withAnimation(.easeOut(duration: 0.2)) {
            if isInverse { routeManager.removeInverseDomain(domain) }
            else { routeManager.removeDomain(domain) }
        }
        settingsUndo.record(.domain(domain, index: index, list: list))
    }

    private func addDomain() {
        guard !newDomain.isEmpty else { return }
        let result = isInverse ? routeManager.addInverseDomain(newDomain) : routeManager.addDomain(newDomain)
        let shown = AddDomainFeedback(result, typed: newDomain)
        feedback = shown
        newDomain = shown.fieldText
    }
}
