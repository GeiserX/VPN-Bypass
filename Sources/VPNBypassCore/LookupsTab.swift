// LookupsTab.swift
// The DNS Lookups page (#176): turn the capture on, then add any name this Mac looks up.

import SwiftUI

struct LookupsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var monitor = DNSLookupsMonitor.shared
    @State private var query = ""
    @State private var feedback: AddDomainFeedback?
    /// The name the New Group sheet is open for.
    @State private var newGroupFor: NewGroupRequest?

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
        .sheet(item: $newGroupFor) { request in
            NewGroupSheet(domain: request.domain) { groupName in
                feedback = routeManager.addLookup(request.domain, toNewGroup: groupName)
                newGroupFor = nil
            } onCancel: {
                newGroupFor = nil
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
                                onAddToGroup: { name, groupId in feedback = routeManager.addLookup(name, toGroup: groupId) },
                                onNewGroup: { name in newGroupFor = NewGroupRequest(domain: name) }
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

private struct NewGroupRequest: Identifiable {
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
    let onAddToGroup: (String, String) -> Void
    let onNewGroup: (String) -> Void
    @State private var isHovered = false

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
        .background(isHovered ? Theme.bgHover : (striped ? Color.white.opacity(0.025) : Color.clear))
        .onHover { isHovered = $0 }
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

    @ViewBuilder
    private var action: some View {
        let title = mode.addTitle
        if mode == .bypass {
            let groups = routeManager.lookupGroups
            Menu {
                Button(String(localized: "Bypass list")) { onAdd(entry.name) }
                Divider()
                if !groups.isEmpty {
                    Section(String(localized: "Add to a group")) {
                        ForEach(groups) { group in
                            Button(group.enabled ? group.name : String(localized: "\(group.name) (off)")) {
                                onAddToGroup(entry.name, group.id)
                            }
                        }
                    }
                }
                Button(String(localized: "New Group…")) { onNewGroup(entry.name) }
            } label: {
                Label(title, systemImage: "plus")
            } primaryAction: {
                onAdd(entry.name)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .tint(Theme.success)
            .disabled(routeManager.isApplyingRoutes)
            .help(String(localized: "Add to the Bypass list. The arrow adds it to a group instead."))
            .accessibilityLabel(String(localized: "\(title): \(entry.name)"))
        } else {
            Button {
                onAdd(entry.name)
            } label: {
                Label(title, systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(mode == .vpnOnly ? Theme.warning : Theme.success)
            .disabled(routeManager.isApplyingRoutes)
            .help(mode.addHelp)
            .accessibilityLabel(String(localized: "\(title): \(entry.name)"))
        }
    }

    /// The column title over the status and action column.
    static func statusHeader(_ routeManager: RouteManager) -> String {
        switch LookupMode(routeManager) {
        case .bypass: return String(localized: "BYPASS")
        case .vpnOnly: return String(localized: "VPN ONLY")
        case .custom: return String(localized: "RULE")
        }
    }

    /// The word for a listed name, the group or route beside it, and the tooltip.
    static func describe(_ listing: LookupListing) -> (String, String?, String) {
        switch listing {
        case .bypassList:
            return (String(localized: "Bypassed"), nil, String(localized: "On the Bypass list"))
        case .group(let name):
            return (String(localized: "Bypassed"), name, String(localized: "In the group \(name)"))
        case .vpnOnlyList:
            return (String(localized: "Via VPN"), nil, String(localized: "On the VPN Only list"))
        case .rule(let routeName):
            return (routeName, nil, String(localized: "A rule on the Rules page sends it to this route"))
        case .listedOff:
            return (String(localized: "Off"), nil, String(localized: "On the Domains page, switched off. Turn it on there."))
        }
    }
}

/// The three ways the page can add a name, one per routing mode.
private enum LookupMode {
    case bypass, vpnOnly, custom

    @MainActor init(_ routeManager: RouteManager) {
        let config = routeManager.config
        if config.routingMode == .vpnOnly {
            self = .vpnOnly
        } else if RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            self = .custom
        } else {
            self = .bypass
        }
    }

    var addTitle: String {
        switch self {
        case .bypass: return String(localized: "Add to Bypass")
        case .vpnOnly: return String(localized: "Add to VPN Only")
        case .custom: return String(localized: "Send Direct")
        }
    }

    var addHelp: String {
        switch self {
        case .bypass: return String(localized: "Add to the Bypass list")
        case .vpnOnly: return String(localized: "Add to the VPN Only list")
        case .custom: return String(localized: "Add a rule that sends it Direct")
        }
    }
}

/// Names a new group (a custom service) whose first domain is the looked-up name.
private struct NewGroupSheet: View {
    let domain: String
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(domain: String, onCreate: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.domain = domain
        self.onCreate = onCreate
        self.onCancel = onCancel
        _name = State(initialValue: NewGroupSheet.suggestedName(for: domain))
    }

    /// The label before the top-level domain, capitalized: "Datadoghq" for
    /// "http-intake.logs.us5.datadoghq.com". The user edits it before saving.
    static func suggestedName(for domain: String) -> String {
        let labels = domain.split(separator: ".")
        guard labels.count >= 2 else { return domain }
        return labels[labels.count - 2].prefix(1).uppercased() + labels[labels.count - 2].dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Group")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("A group is a custom service on the Services page: one name for a set of domains, turned on and off together. \(domain) will be its first domain.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Group name"), text: $name)
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
