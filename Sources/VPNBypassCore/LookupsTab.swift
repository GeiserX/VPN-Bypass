// LookupsTab.swift
// The DNS Lookups page (#176): turn the capture on, then add any name this Mac looks up.

import SwiftUI

struct LookupsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var monitor = DNSLookupsMonitor.shared
    @State private var query = ""
    @State private var feedback: AddDomainFeedback?
    /// The name the New Service sheet is open for.
    @State private var newServiceFor: NewServiceRequest?

    /// Rows drawn at once. The line under the table says when there are more, and search
    /// reaches them.
    static let shownLimit = 300
    /// The doc screenshots draw this name's row as if the pointer were on it.
    static var hoveredForScreenshots: String?

    private var isOn: Bool { routeManager.config.dnsLookupsEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            privacyNote
            if isOn {
                lookups
            }
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.blueGradient)
                    Text("DNS Lookups")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Text("See the names this Mac looks up, and add the ones you need.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Toggle("Watch DNS Lookups", isOn: Binding(
                get: { isOn },
                set: { on in
                    feedback = nil
                    monitor.setEnabled(on)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.success)
            .labelsHidden()
            .help(String(localized: "Watch DNS Lookups"))
            .padding(.top, 2)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Off until you turn it on. Then the helper reads only the DNS questions this Mac sends, never the answers or any other traffic. The list stays in memory and is cleared when you turn this off or quit.")
                    .foregroundColor(Theme.textSecondary)
                Text("Lookups a browser sends over encrypted DNS (Secure DNS, DNS over HTTPS) never show here. To see them, turn Secure DNS off in the browser's settings.")
                    .foregroundColor(Theme.textTertiary)
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.bgElevated)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bgCardBorder, lineWidth: 1))
        )
    }

    @ViewBuilder
    private var lookups: some View {
        let ranked = monitor.tally.ranked(matching: query)
        let top = ranked.first?.count ?? 1
        VStack(alignment: .leading, spacing: 10) {
            if let problem = monitor.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.warning)
            }

            HStack(spacing: 10) {
                LogSearchField(text: $query, placeholder: String(localized: "Search"))
                    .frame(minWidth: 110, maxWidth: 240)
                if let since = monitor.since {
                    Text("\(monitor.tally.entries.count) names since \(since.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Clear") {
                    feedback = nil
                    monitor.clear()
                }
                .disabled(monitor.tally.entries.isEmpty)
                .help(String(localized: "Start counting again from now"))
            }

            if let feedback {
                AddDomainFeedbackLine(feedback: feedback)
            }

            VStack(spacing: 0) {
                tableHeader
                Rectangle().fill(Theme.divider).frame(height: 1)
                if ranked.isEmpty {
                    Text(query.isEmpty ? String(localized: "Waiting for lookups…") : String(localized: "No name matches \"\(query)\""))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(ranked.prefix(Self.shownLimit).enumerated()), id: \.element.id) { index, entry in
                            LookupRow(
                                entry: entry,
                                share: Double(entry.count) / Double(max(top, 1)),
                                striped: index % 2 == 1,
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
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.bgCardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if ranked.count > Self.shownLimit {
                Text("Showing the top \(Self.shownLimit). Search to find the rest.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.leading, 2)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("LOOKUPS")
                .frame(width: LookupRow.countWidth, alignment: .trailing)
            Text("NAME")
            Spacer(minLength: 8)
            Text(LookupRow.statusHeader(routeManager))
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .tracking(1)
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func add(_ name: String) {
        feedback = routeManager.addForCurrentMode(name).map { AddDomainFeedback($0, typed: name) }
    }
}

private struct NewServiceRequest: Identifiable {
    let domain: String
    var id: String { domain }
}

/// What a row shows at its right end. Pure, so the rest and hover rules are unit-tested.
enum LookupRowTrailing: Equatable {
    /// Nothing: an unlisted name at rest gives the whole row to the name.
    case none
    /// The quiet word for where the name is listed.
    case status
    /// The add action and its chevron.
    case add
    /// The remove action.
    case remove

    /// `active` is the pointer on the row or its add panel open.
    static func resolve(listed: Bool, canRemove: Bool, active: Bool) -> LookupRowTrailing {
        guard listed else { return active ? .add : .none }
        return active && canRemove ? .remove : .status
    }
}

/// One looked-up name: how often, the name, and what the current mode can do with it.
private struct LookupRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let entry: DNSLookupTally.Entry
    /// This name's count over the top count, for the bar beside the number.
    let share: Double
    let striped: Bool
    let listing: LookupListing?
    /// What un-routes a listed name, or nil when the page offers nothing for it.
    let removal: LookupRemoval?
    let onAdd: (String) -> Void
    let onRemove: (LookupRemoval) -> Void
    /// Turns on a switched-off service that lists the name: the name, then the service id.
    let onTurnOn: (String, String) -> Void
    /// What the add panel chose to add (the name or a wildcard over it), then where.
    let onAddChoice: (String, LookupAddTarget) -> Void
    @State private var isHovered = false
    @State private var showingPanel = false
    /// The mode the panel was opened in. A choice made for one mode is never added in another.
    @State private var panelMode: LookupMode?

    static let countWidth: CGFloat = 76
    /// The most a listed row's service name takes beside its status.
    static let statusDetailWidth: CGFloat = 120
    /// How long, in tenths of a second, a panel add waits for a running apply.
    static let applyWaitPolls = 300
    private var mode: LookupMode { LookupMode(routeManager) }
    private var modeColor: Color { mode == .vpnOnly ? Theme.warning : Theme.success }
    /// A switched-off service that lists the name is what the add turns on (Bypass mode).
    private var offService: ServiceEntry? { mode == .bypass ? routeManager.lookupServiceToTurnOn(entry.name) : nil }
    private var addTitle: String { offService.map { String(localized: "Turn on \($0.name)") } ?? mode.addTitle }
    /// The pointer on the row, or its add panel open.
    private var isActive: Bool { isHovered || showingPanel || LookupsTab.hoveredForScreenshots == entry.name }
    private var trailing: LookupRowTrailing {
        LookupRowTrailing.resolve(listed: listing != nil, canRemove: removal != nil, active: isActive)
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Theme.cyan.opacity(0.18))
                    .frame(width: 30, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.cyan.opacity(0.8)).frame(width: max(3, 30 * share), height: 4)
                    }
                Text("\(entry.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .frame(minWidth: 26, alignment: .trailing)
            }
            .frame(width: Self.countWidth, alignment: .trailing)
            .help(String(localized: "Times looked up"))

            // The name takes every point the right end does not use right now.
            Text(entry.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(listing == nil ? .white : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch trailing {
            case .none:
                EmptyView()
            case .status:
                if let listing { status(listing) }
            case .add:
                addAction
            case .remove:
                if let removal { removeAction(removal) }
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .background(isActive ? Theme.bgHover : (striped ? Color.white.opacity(0.025) : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // The actions show only under the pointer, so VoiceOver reaches them on the row itself.
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if routeManager.isApplyingRoutes {
                EmptyView()
            } else if listing == nil {
                Button(addTitle, action: add)
                Button(String(localized: "More ways to add \(entry.name)"), action: openPanel)
            } else if let removal {
                Button(removal.title(for: entry.name)) { onRemove(removal) }
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

    /// Where the name is listed, small and grey: the content is the name, not the status.
    private func status(_ listing: LookupListing) -> some View {
        let (title, detail, help) = Self.describe(listing)
        let isOff = listing == .listedOff
        return HStack(spacing: 4) {
            Image(systemName: isOff ? "pause.circle" : "checkmark.circle")
                .font(.system(size: 10))
            // Capped like the detail: in Custom mode the title is a route name of any length.
            Text(title)
                .truncationMode(.tail)
                .frame(maxWidth: Self.statusDetailWidth, alignment: .leading)
            if let detail {
                // Capped, so a long service name truncates instead of squeezing the domain.
                Text(detail)
                    .foregroundColor(Theme.textTertiary)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.statusDetailWidth, alignment: .leading)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .foregroundColor(Theme.textSecondary)
        .fixedSize()
        .help(help)
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

    /// The row's button, which adds the name as it always has, and the chevron beside it,
    /// which opens the add panel for a wildcard or another place.
    private var addAction: some View {
        HStack(spacing: 2) {
            Button(action: add) {
                Label(addTitle, systemImage: offService == nil ? "plus" : "power")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(offService.map { String(localized: "\($0.name) on the Services page lists this name and is off. Turn it on to bypass it.") } ?? mode.addHelp)

            Button(action: openPanel) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // Only Bypass mode offers other places (a new service, any service).
            .help(mode == .bypass ? String(localized: "Add a wildcard, or add it somewhere else")
                                  : String(localized: "Add a wildcard instead"))
        }
        .foregroundColor(modeColor)
        .fixedSize()
        .disabled(routeManager.isApplyingRoutes)
    }

    /// Takes the name out of what lists it, saying which: the list, a wildcard, a service.
    private func removeAction(_ removal: LookupRemoval) -> some View {
        let turnsOff = { if case .turnOffService = removal { return true } else { return false } }()
        return Button {
            onRemove(removal)
        } label: {
            Label(removal.title(for: entry.name), systemImage: turnsOff ? "power" : "minus.circle")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundColor(.white)
        .fixedSize()
        .help(removal.help(for: entry.name))
        .disabled(routeManager.isApplyingRoutes)
    }

    /// The column title over the status and action column.
    static func statusHeader(_ routeManager: RouteManager) -> String {
        switch LookupMode(routeManager) {
        case .bypass: return String(localized: "BYPASS")
        case .vpnOnly: return String(localized: "VPN ONLY")
        case .custom: return String(localized: "RULE")
        }
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
