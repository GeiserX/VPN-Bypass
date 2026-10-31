// LookupsTab.swift
// The DNS Lookups page (#176): start watching, then add any name this Mac looks up. Built on the
// shared views of Components.swift. The window's title bar names the page and holds its search
// (⌘F), so the page itself opens with the line that says what it is for.

import AppKit
import SwiftUI

struct LookupsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var monitor = DNSLookupsMonitor.shared
    /// The title bar search (⌘F), which the window owns.
    @Environment(\.settingsSearch) private var query
    @State private var feedback: AddDomainFeedback?
    /// The name the New Service sheet is open for.
    @State private var newServiceFor: NewServiceRequest?

    /// Rows drawn at once. The line under the list says when there are more, and search
    /// reaches them.
    static let shownLimit = 300
    /// The doc screenshots draw this name's row as if the pointer were on it.
    static var hoveredForScreenshots: String?

    /// What the page shows under its first line. Pure, so each state is unit-tested.
    enum Content: Equatable {
        /// Not watching: an empty state whose button is Start Watching.
        case off
        /// Watching, and no name counted yet.
        case waiting
        /// Watching, and the search matches no name.
        case noMatch
        /// The names, most looked up first.
        case names

        static func resolve(isOn: Bool, matching: Int, query: String) -> Content {
            guard isOn else { return .off }
            guard matching == 0 else { return .names }
            return query.trimmingCharacters(in: .whitespaces).isEmpty ? .waiting : .noMatch
        }
    }

    /// The number column for the names shown: as wide as the widest count, the same on every
    /// row (the #183 rule, now `ListRow`'s).
    static func numberWidth(for entries: [DNSLookupTally.Entry]) -> CGFloat {
        ListRow.numberColumnWidth(for: entries.map { LookupRow.format($0.count) })
    }

    private var isOn: Bool { routeManager.config.dnsLookupsEnabled }

    var body: some View {
        let ranked = monitor.tally.ranked(matching: query)
        let content = Content.resolve(isOn: isOn, matching: ranked.count, query: query)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            purposeLine
            if let learning = monitor.learning {
                // A new window starts with no wildcard chosen.
                LearnSiteSection(learning: learning, feedback: $feedback)
                    .id(learning.started)
            }
            if content == .off {
                // Learn a site adds from here too while the page is not watching.
                if let feedback { AddDomainFeedbackLine(feedback: feedback) }
                GroupSection {
                    EmptyState(systemImage: "magnifyingglass",
                               title: String(localized: "DNS lookups are not being watched"),
                               primary: .init(title: String(localized: "Start Watching")) { setWatching(true) })
                }
            } else {
                lookups(ranked, content: content)
            }
            privacyNote
        }
        .sheet(item: $newServiceFor) { request in
            NewServiceSheet(domain: request.domain) { serviceName in
                feedback = routeManager.addLookup(request.domain, toNewService: serviceName)
                newServiceFor = nil
            } onCancel: {
                newServiceFor = nil
            }
        }
        .onChange(of: routeManager.config.routingMode) { _ in feedback = nil }
    }

    /// The page's subtitle, under the title the title bar shows, and Stop Watching beside it
    /// while the page is watching. The switch that sat here is gone: off, the empty state starts.
    private var purposeLine: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Text("See the names this Mac looks up, and add the ones you need.")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button(String(localized: "Learn a Site…")) {
                feedback = nil
                Task { await monitor.startLearning() }
            }
            .controlSize(.small)
            .disabled(monitor.learning?.isOpen == true)
            .help(String(localized: "Watch the lookups for 60 seconds while you reload a page, and see the names it needs"))
            .accessibilityLabel(String(localized: "Learn a Site"))
            if isOn {
                Button(String(localized: "Stop Watching")) { setWatching(false) }
                    .controlSize(.small)
                    .help(String(localized: "Stop reading DNS lookups, and clear the list"))
                    .accessibilityLabel(String(localized: "Stop Watching"))
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Off until you turn it on. Then the helper reads only the DNS questions this Mac sends, never the answers or any other traffic. The list stays in memory and is cleared when you turn this off or quit.")
                if !isOn, monitor.learning?.isOpen == true {
                    Text("Learn a Site has turned the capture on for its 60 seconds only, and keeps the names in memory.")
                }
                Text("Lookups a browser sends over encrypted DNS (Secure DNS, DNS over HTTPS) never show here. To see them, turn Secure DNS off in the browser's settings.")
            }
            .font(Theme.Font.detail)
            .foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func lookups(_ ranked: [DNSLookupTally.Entry], content: Content) -> some View {
        let shown = Array(ranked.prefix(Self.shownLimit))
        let numberWidth = Self.numberWidth(for: shown)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let problem = monitor.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.attention)
            }

            if let feedback {
                AddDomainFeedbackLine(feedback: feedback)
            }

            GroupSection(sectionTitle, trailing: {
                Button(String(localized: "Clear")) {
                    feedback = nil
                    monitor.clear()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(monitor.tally.entries.isEmpty)
                .help(String(localized: "Start counting again from now"))
            }) {
                switch content {
                case .off, .waiting:
                    EmptyState(systemImage: "hourglass", title: String(localized: "Waiting for lookups…"))
                case .noMatch:
                    EmptyState(systemImage: "magnifyingglass", title: String(localized: "No name matches \"\(query)\""))
                case .names:
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                            VStack(spacing: 0) {
                                if index > 0 { InsetDivider() }
                                row(entry, numberWidth: numberWidth)
                            }
                        }
                    }
                }
            }

            if ranked.count > Self.shownLimit {
                Text("Showing the top \(Self.shownLimit). Search to find the rest.")
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.leading, 2)
            }
        }
    }

    /// The section label: how many names, counted since when.
    private var sectionTitle: String? {
        monitor.since.map { since in
            String(localized: "\(monitor.tally.entries.count) names since \(since.formatted(date: .omitted, time: .shortened))")
        }
    }

    private func row(_ entry: DNSLookupTally.Entry, numberWidth: CGFloat) -> some View {
        LookupRow(
            entry: entry,
            numberWidth: numberWidth,
            listing: routeManager.lookupListing(entry.name),
            removal: routeManager.lookupRemoval(entry.name),
            onAdd: add,
            onRemove: { removal in feedback = routeManager.removeLookup(removal, for: entry.name) },
            onTurnOn: { name, serviceId in feedback = routeManager.turnOnLookupService(serviceId, for: name) },
            onAddChoice: { value, target in
                if target == .newService {
                    newServiceFor = NewServiceRequest(domain: value)
                } else {
                    feedback = routeManager.addLookup(value, to: target)
                }
            }
        )
    }

    private func setWatching(_ on: Bool) {
        feedback = nil
        monitor.setEnabled(on)
    }

    private func add(_ name: String) {
        feedback = routeManager.addForCurrentMode(name).map { AddDomainFeedback($0, typed: name) }
    }
}

private struct NewServiceRequest: Identifiable {
    let domain: String
    var id: String { domain }
}

/// One looked-up name, as a `ListRow`: a glyph that says whether the mode routes it, the name,
/// where it is listed in the detail line, the actions under the pointer, and the count.
struct LookupRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let entry: DNSLookupTally.Entry
    /// The number column's width, the same on every row.
    let numberWidth: CGFloat
    let listing: LookupListing?
    /// What un-routes a listed name, or nil when the page offers nothing for it.
    let removal: LookupRemoval?
    let onAdd: (String) -> Void
    let onRemove: (LookupRemoval) -> Void
    /// Turns on a switched-off service that lists the name: the name, then the service id.
    let onTurnOn: (String, String) -> Void
    /// What the add panel chose to add (the name or a wildcard over it), then where.
    let onAddChoice: (String, LookupAddTarget) -> Void
    @State private var showingPanel = false
    /// The mode the panel was opened in. A choice made for one mode is never added in another.
    @State private var panelMode: LookupMode?

    /// How long, in tenths of a second, a panel add waits for a running apply.
    static let applyWaitPolls = 300

    static func format(_ count: Int) -> String { count.formatted(.number) }

    /// What a row offers under the pointer, in order. Pure, so the rules are unit-tested.
    enum Offer: Equatable {
        /// The mode's add: Add to Bypass, Add to VPN Only, Send Direct, or Turn on a service.
        case add
        /// The add panel: a wildcard, or another place.
        case moreWays
        /// Takes the name out of what lists it.
        case remove
    }

    /// An unlisted name offers its add and the panel; a listed one its remove, when the page has
    /// one. Nothing while routes are being applied: each action would change them meanwhile.
    static func offers(listed: Bool, canRemove: Bool, isApplying: Bool) -> [Offer] {
        guard !isApplying else { return [] }
        guard listed else { return [.add, .moreWays] }
        return canRemove ? [.remove] : []
    }

    /// The leading glyph: a check when the mode routes the name, a pause when its entry is off.
    static func glyph(for listing: LookupListing?) -> String {
        switch listing {
        case nil: return "globe"
        case .listedOff: return "pause.circle"
        default: return "checkmark.circle"
        }
    }

    /// Where the name is listed, as the row's detail line: "Bypassed · Meetings". Nil for a
    /// name the mode does not route, so the row is one line.
    static func detail(for listing: LookupListing?) -> String? {
        guard let listing else { return nil }
        let (title, detail, _) = describe(listing)
        return detail.map { "\(title) · \($0)" } ?? title
    }

    private var mode: LookupMode { LookupMode(routeManager) }
    /// A switched-off service that lists the name is what the add turns on (Bypass mode).
    private var offService: ServiceEntry? { mode == .bypass ? routeManager.lookupServiceToTurnOn(entry.name) : nil }
    private var addTitle: String { offService.map { String(localized: "Turn on \($0.name)") } ?? mode.addTitle }

    /// The row's tooltip: where the name is listed and what the remove takes out, or what the
    /// add does in this mode.
    private var tooltip: String {
        if let listing {
            return removal?.help(for: entry.name) ?? Self.describe(listing).2
        }
        return offService.map { String(localized: "\($0.name) on the Services page lists this name and is off. Turn it on to bypass it.") } ?? mode.addHelp
    }

    private var actions: [RowAction] {
        Self.offers(listed: listing != nil, canRemove: removal != nil, isApplying: routeManager.isApplyingRoutes).map { offer in
            switch offer {
            case .add:
                return RowAction(kind: .other, name: addTitle, systemImage: offService == nil ? "plus" : "power", perform: add)
            case .moreWays:
                return RowAction(kind: .more, name: String(localized: "More ways to add \(entry.name)"),
                                 systemImage: "ellipsis", perform: openPanel)
            case .remove:
                let turnsOff = { if case .turnOffService = removal { return true } else { return false } }()
                return RowAction(kind: .other, name: removal?.title(for: entry.name) ?? "",
                                 systemImage: turnsOff ? "power" : "minus.circle") { if let removal { onRemove(removal) } }
            }
        }
    }

    var body: some View {
        ListRow(
            glyph: Self.glyph(for: listing),
            name: entry.name,
            detail: Self.detail(for: listing),
            number: Self.format(entry.count),
            numberWidth: numberWidth,
            actions: actions,
            // The panel open keeps the row's actions in view, as the pointer does.
            showsActions: showingPanel || LookupsTab.hoveredForScreenshots == entry.name
        )
        .help(tooltip)
        // The buttons show only under the pointer, and a hidden button is hidden from VoiceOver
        // too, so the row itself carries every action, as it did before ListRow.
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.name, action: action.perform)
            }
        }
        .popover(isPresented: $showingPanel, arrowEdge: .bottom) {
            LookupAddPanel(
                choices: LookupAddChoices(name: entry.name, mode: mode,
                                          services: routeManager.lookupServices(for: entry.name)),
                isBusy: routeManager.isApplyingRoutes,
                onAdd: { value, target in
                    showingPanel = false
                    let opened = panelMode
                    // The New Service sheet opens once the popover has closed. An apply that
                    // started meanwhile would skip the new entry's routes, so the add waits for it.
                    DispatchQueue.main.async { Task { @MainActor in
                        var polls = 0
                        while routeManager.isApplyingRoutes && polls < Self.applyWaitPolls {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            polls += 1
                        }
                        guard opened == LookupMode(routeManager) else { return }
                        onAddChoice(value, target)
                    } }
                },
                onCancel: { showingPanel = false }
            )
        }
    }

    private func add() {
        if let offService {
            onTurnOn(entry.name, offService.id)
        } else {
            onAdd(entry.name)
        }
    }

    private func openPanel() {
        panelMode = mode
        showingPanel = true
    }

    /// The word for a listed name, the service or route beside it, and the tooltip.
    static func describe(_ listing: LookupListing) -> (String, String?, String) {
        switch listing {
        case .bypassList:
            return (String(localized: "Bypassed"), nil, String(localized: "On the Bypass list"))
        case .service(let name):
            return (String(localized: "Bypassed"), name, String(localized: "In the service \(name)"))
        case .vpnOnlyList:
            return (String(localized: "Via VPN"), nil, String(localized: "On the VPN Only list"))
        case .rule(let routeName):
            return (routeName, nil, String(localized: "A rule on the Rules page sends it to this route"))
        case .listedOff:
            return (String(localized: "Off"), nil, String(localized: "On the Domains page, switched off. Turn it on there."))
        }
    }
}


/// Names a new custom service whose first domain is the looked-up name.
struct NewServiceSheet: View {
    let domain: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(domain: String, onCreate: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.domain = domain
        self.onCreate = onCreate
        self.onCancel = onCancel
        _name = State(initialValue: NewServiceSheet.suggestedName(for: domain))
    }

    /// The first label of the site's own domain, capitalized: "Datadoghq" for
    /// "http-intake.logs.us5.datadoghq.com", "Bbc" for "*.bbc.co.uk". The user edits it before
    /// saving.
    static func suggestedName(for domain: String) -> String {
        guard let site = LookupAddLevels.registrableDomain(domain), let first = site.split(separator: ".").first else { return domain }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Service")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("This adds a custom service to the Services page, with \(domain) as its first domain. You can add more domains to it later.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Service name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCreate(name)
    }
}
