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
                                onAdd: add,
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
                .frame(width: LookupRow.actionWidth, alignment: .trailing)
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

/// One looked-up name: how often, the name, and what the current mode can do with it.
private struct LookupRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let entry: DNSLookupTally.Entry
    /// This name's count over the top count, for the bar beside the number.
    let share: Double
    let striped: Bool
    let listing: LookupListing?
    let onAdd: (String) -> Void
    /// Turns on a switched-off service that lists the name: the name, then the service id.
    let onTurnOn: (String, String) -> Void
    /// What the add panel chose to add (the name or a wildcard over it), then where.
    let onAddChoice: (String, LookupAddTarget) -> Void
    @State private var isHovered = false
    @State private var showingPanel = false

    static let countWidth: CGFloat = 76
    static let actionWidth: CGFloat = 170

    private var mode: LookupMode { LookupMode(routeManager) }

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

            Text(entry.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(listing == nil ? .white : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Group {
                if let listing {
                    status(listing)
                } else {
                    action
                }
            }
            .frame(width: Self.actionWidth, alignment: .trailing)
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .background(isHovered || showingPanel ? Theme.bgHover : (striped ? Color.white.opacity(0.025) : Color.clear))
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingPanel, arrowEdge: .bottom) {
            LookupAddPanel(
                choices: LookupAddChoices(name: entry.name, mode: mode,
                                          services: routeManager.lookupServices(for: entry.name)),
                onAdd: { value, target in
                    showingPanel = false
                    // The New Service sheet opens once the popover has closed.
                    DispatchQueue.main.async { onAddChoice(value, target) }
                },
                onCancel: { showingPanel = false }
            )
        }
    }

    private func status(_ listing: LookupListing) -> some View {
        let (title, detail, help) = Self.describe(listing)
        let isOff = listing == .listedOff
        return HStack(spacing: 5) {
            Image(systemName: isOff ? "pause.circle" : "checkmark.circle.fill")
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundColor(isOff ? Theme.textSecondary : (mode == .vpnOnly ? Theme.warning : Theme.success))
        .help(help)
        .accessibilityElement(children: .combine)
    }

    /// The row's button, which adds the name as it always has, and the chevron beside it,
    /// which opens the add panel for a wildcard or another place.
    private var action: some View {
        // A switched-off service that lists the name is what the button turns on (Bypass mode).
        let offService = mode == .bypass ? routeManager.lookupServiceToTurnOn(entry.name) : nil
        let title = offService.map { String(localized: "Turn on \($0.name)") } ?? mode.addTitle
        let color = mode == .vpnOnly ? Theme.warning : Theme.success
        return HStack(spacing: 2) {
            Button {
                if let offService {
                    onTurnOn(entry.name, offService.id)
                } else {
                    onAdd(entry.name)
                }
            } label: {
                Label(title, systemImage: offService == nil ? "plus" : "power")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(offService.map { String(localized: "\($0.name) on the Services page lists this name and is off. Turn it on to bypass it.") } ?? mode.addHelp)
            .accessibilityLabel(String(localized: "\(title): \(entry.name)"))

            Button {
                showingPanel = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // Only Bypass mode offers other places (a new service, any service).
            .help(mode == .bypass ? String(localized: "Add a wildcard, or add it somewhere else")
                                  : String(localized: "Add a wildcard instead"))
            .accessibilityLabel(String(localized: "More ways to add \(entry.name)"))
        }
        .foregroundColor(color)
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
