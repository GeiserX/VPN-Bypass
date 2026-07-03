// RulesTab.swift
// Settings tab for managing routing rules in Custom Routes mode: an ordered,
// first-match list of destination -> route assignments (see RuleResolver).

import SwiftUI

// MARK: - Route display helpers (UI-only; the model/engine stay untouched)

extension Route {
    /// Friendly display name for route pickers/chips. `.direct`/`.vpnDefault`
    /// are the two auto-created system routes, so their name is derived rather
    /// than stored; proxy/Tailscale routes just use their own user-given name.
    func friendlyName(vpnName: String?) -> String {
        switch egress {
        case .direct:      return "Direct"
        case .vpnDefault:
            // A route pinned to a SPECIFIC tunnel is user-created — use its own name so
            // several VPNs are distinguishable. The primary-VPN route derives its label.
            if vpnSelector?.kind == .interface { return name.isEmpty ? "VPN" : name }
            return vpnName ?? "VPN"
        case .proxyHTTP, .proxySOCKS5, .tailscaleExit: return name
        }
    }

    /// Accent color by egress type, used for route chips/dots throughout the
    /// Custom-mode UI (rule rows, the default-route footer, the menu-bar rollup).
    var accentColor: Color {
        switch egress {
        case .direct:       return Theme.textSecondary
        case .proxyHTTP:    return Theme.blue
        case .proxySOCKS5:  return Theme.purple
        case .tailscaleExit: return Theme.success
        case .vpnDefault:   return Theme.warning
        }
    }
}

extension RouteManager {
    /// Add a newly-created route and reconcile its listener. UI-only convenience
    /// so the "New Route…" flow (triggered from a rule/default-route chip) doesn't
    /// duplicate the append+persist+reconcile sequence RoutesTab.saveRoute already
    /// performs for edits made directly in the Routes tab.
    func addRoute(_ route: Route) {
        config.routes.append(route)
        saveConfig()
        Task { await reconcileProxyListeners() }
    }
}

// MARK: - Sheet state wrappers

private enum RuleSheetState: Identifiable {
    case add
    case edit(Rule)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let r): return "edit-\(r.id.uuidString)"
        }
    }

    var rule: Rule? {
        if case .edit(let r) = self { return r }
        return nil
    }
}

// MARK: - RulesTab

struct RulesTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var sheetState: RuleSheetState?
    @State private var showingNewRouteSheet = false
    @State private var pendingNewRouteCompletion: ((Route) -> Void)?

    private var sortedRules: [Rule] {
        routeManager.config.rules.sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if sortedRules.count >= 2 {
                reorderHint
            }

            if sortedRules.isEmpty {
                emptyState
            } else {
                ruleList
            }

            defaultRouteFooter
        }
        .sheet(item: $sheetState) { state in
            RuleEditorSheet(editingRule: state.rule, services: routeManager.config.services) { rule in
                saveRule(rule)
                sheetState = nil
            } onCancel: {
                sheetState = nil
            }
        }
        .sheet(isPresented: $showingNewRouteSheet) {
            RouteEditorSheet(editingRoute: nil) { newRoute in
                routeManager.addRoute(newRoute)
                pendingNewRouteCompletion?(newRoute)
                pendingNewRouteCompletion = nil
                showingNewRouteSheet = false
            } onCancel: {
                pendingNewRouteCompletion = nil
                showingNewRouteSheet = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.blueGradient)
                    Text("Routing Rules")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                Button {
                    sheetState = .add
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.blueLight)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Add Rule")
            }

            Text("Send specific destinations through specific routes. Rules are checked in order — the first match wins.")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var reorderHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
            Text("Drag to reorder — earlier rules win.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 44))
                .foregroundColor(Theme.textDisabled)
            Text("No rules yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text("Add a rule to send a domain, service, or IP range through a specific route.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button {
                sheetState = .add
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                    Text("Add Rule")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Theme.blueGradient)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: - Rule list

    private var ruleList: some View {
        SettingsCard(title: "Rules", icon: "list.bullet.indent", iconColor: Theme.blue) {
            VStack(spacing: 0) {
                ForEach(Array(sortedRules.enumerated()), id: \.element.id) { idx, rule in
                    RuleRow(
                        rule: rule,
                        showDragHandle: sortedRules.count >= 2,
                        onEdit: { sheetState = .edit(rule) },
                        onDelete: { deleteRule(rule) },
                        onToggle: { enabled in toggleRule(rule.id, enabled: enabled) },
                        onReassign: { newRouteId in reassignRule(rule.id, to: newRouteId) },
                        onNewRoute: {
                            pendingNewRouteCompletion = { newRoute in reassignRule(rule.id, to: newRoute.id) }
                            showingNewRouteSheet = true
                        }
                    )
                    .draggable(rule.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let draggedIdString = items.first, let draggedId = UUID(uuidString: draggedIdString) else { return false }
                        moveRule(draggedId: draggedId, to: rule.id)
                        return true
                    }
                    if idx < sortedRules.count - 1 {
                        Divider()
                            .background(Theme.divider)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - Default route footer

    private var defaultRouteFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Everything else")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                RouteChipMenu(
                    selectedRouteId: routeManager.config.defaultRouteId,
                    onSelect: { newId in setDefaultRoute(newId) },
                    onNewRoute: {
                        pendingNewRouteCompletion = { newRoute in setDefaultRoute(newRoute.id) }
                        showingNewRouteSheet = true
                    }
                )
                Spacer()
            }
            Text("Destinations that don't match any rule above use this route.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.bgCard)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.bgCardBorder, lineWidth: 1))
        )
    }

    // MARK: - Mutations

    private func saveRule(_ rule: Rule) {
        if let idx = routeManager.config.rules.firstIndex(where: { $0.id == rule.id }) {
            routeManager.config.rules[idx] = rule
        } else {
            let maxOrder = routeManager.config.rules.map(\.order).max() ?? -1
            var newRule = rule
            newRule.order = maxOrder + 1
            routeManager.config.rules.append(newRule)
        }
        persistAndReapply()
    }

    private func deleteRule(_ rule: Rule) {
        routeManager.config.rules.removeAll { $0.id == rule.id }
        persistAndReapply()
    }

    private func toggleRule(_ id: UUID, enabled: Bool) {
        guard let idx = routeManager.config.rules.firstIndex(where: { $0.id == id }) else { return }
        routeManager.config.rules[idx].enabled = enabled
        persistAndReapply()
    }

    private func reassignRule(_ id: UUID, to routeId: UUID) {
        guard let idx = routeManager.config.rules.firstIndex(where: { $0.id == id }) else { return }
        routeManager.config.rules[idx].routeId = routeId
        persistAndReapply()
    }

    private func setDefaultRoute(_ routeId: UUID) {
        routeManager.config.defaultRouteId = routeId
        persistAndReapply()
    }

    /// Reorders `sortedRules` (dragged rule moves to the target's position) and
    /// renumbers every rule's `order` to its new index, so future appends
    /// (`(max order)+1`) stay consistent.
    private func moveRule(draggedId: UUID, to targetId: UUID) {
        guard draggedId != targetId else { return }
        var ordered = sortedRules
        guard let fromIndex = ordered.firstIndex(where: { $0.id == draggedId }),
              let toIndex = ordered.firstIndex(where: { $0.id == targetId }) else { return }
        let moved = ordered.remove(at: fromIndex)
        ordered.insert(moved, at: toIndex)
        for (newOrder, rule) in ordered.enumerated() {
            if let idx = routeManager.config.rules.firstIndex(where: { $0.id == rule.id }) {
                routeManager.config.rules[idx].order = newOrder
            }
        }
        persistAndReapply()
    }

    private func persistAndReapply() {
        routeManager.saveConfig()
        Task { await routeManager.detectAndApplyRoutesAsync(sendNotification: false) }
    }
}

// MARK: - RuleRow

struct RuleRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let rule: Rule
    let showDragHandle: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let onReassign: (UUID) -> Void
    let onNewRoute: () -> Void

    private var matchLabel: String {
        switch rule.matchType {
        case .domain:  return "DOMAIN"
        case .suffix:  return "SUFFIX"
        case .ip:      return "IP"
        case .cidr:    return "CIDR"
        case .service: return "SERVICE"
        case .process: return "PROCESS"
        }
    }

    private var patternDisplay: String {
        if rule.matchType == .service {
            return routeManager.config.services.first(where: { $0.id == rule.pattern })?.name ?? rule.pattern
        }
        return rule.pattern
    }

    var body: some View {
        HStack(spacing: 10) {
            if showDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: onToggle
            ))
            .toggleStyle(.switch)
            .tint(Theme.success)
            .scaleEffect(0.75)
            .frame(width: 34)

            Button(action: onEdit) {
                HStack(spacing: 6) {
                    Text(patternDisplay)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(rule.enabled ? .white : Theme.textSecondary)
                        .lineLimit(1)
                    Text(matchLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.warning.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .buttonStyle(.plain)
            .help("Edit rule")

            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)

            Spacer()

            RouteChipMenu(selectedRouteId: rule.routeId, onSelect: onReassign, onNewRoute: onNewRoute)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.error)
                    .frame(width: 26, height: 26)
                    .background(Theme.error.opacity(0.1))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Delete rule")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Route chip + grouped picker (System / Your Routes / New Route…)

struct RouteChipMenu: View {
    @EnvironmentObject var routeManager: RouteManager
    let selectedRouteId: UUID?
    let onSelect: (UUID) -> Void
    let onNewRoute: () -> Void

    /// Direct first, then the PRIMARY VPN — the two auto-created system routes. A
    /// VPN route pinned to a specific tunnel is user-created, so it lives in Your Routes.
    private var systemRoutes: [Route] {
        routeManager.config.routes
            .filter { $0.egress == .direct || ($0.egress == .vpnDefault && $0.vpnSelector?.kind != .interface) }
            .sorted { ($0.egress == .direct ? 0 : 1) < ($1.egress == .direct ? 0 : 1) }
    }

    private var userRoutes: [Route] {
        routeManager.config.routes.filter {
            ProxyListenerManager.usesLocalListener($0.egress)
                || ($0.egress == .vpnDefault && $0.vpnSelector?.kind == .interface)
        }
    }

    private var selectedRoute: Route? {
        guard let selectedRouteId else { return nil }
        return routeManager.config.routes.first(where: { $0.id == selectedRouteId })
    }

    var body: some View {
        Menu {
            Section("System") {
                ForEach(systemRoutes) { route in
                    routeButton(route)
                }
            }
            if !userRoutes.isEmpty {
                Section("Your Routes") {
                    ForEach(userRoutes) { route in
                        routeButton(route)
                    }
                }
            }
            Divider()
            Button {
                onNewRoute()
            } label: {
                Label("New Route…", systemImage: "plus")
            }
        } label: {
            RouteChip(route: selectedRoute, vpnName: routeManager.vpnType?.rawValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func routeButton(_ route: Route) -> some View {
        Button {
            onSelect(route.id)
        } label: {
            if selectedRouteId == route.id {
                Label(route.friendlyName(vpnName: routeManager.vpnType?.rawValue), systemImage: "checkmark")
            } else {
                Text(route.friendlyName(vpnName: routeManager.vpnType?.rawValue))
            }
        }
    }
}

struct RouteChip: View {
    let route: Route?
    let vpnName: String?

    private var displayName: String {
        route?.friendlyName(vpnName: vpnName) ?? "Choose Route"
    }

    private var color: Color {
        route?.accentColor ?? Theme.textDisabled
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(6)
    }
}

// MARK: - Rule editor sheet

struct RuleEditorSheet: View {
    @EnvironmentObject var routeManager: RouteManager
    let editingRule: Rule?
    let services: [RouteManager.ServiceEntry]
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    @State private var matchType: MatchType
    @State private var pattern: String
    @State private var selectedServiceId: String
    @State private var routeId: UUID?
    @State private var validationError: String?
    @State private var showingNewRouteSheet = false

    init(
        editingRule: Rule?,
        services: [RouteManager.ServiceEntry],
        onSave: @escaping (Rule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.editingRule = editingRule
        self.services = services
        self.onSave = onSave
        self.onCancel = onCancel
        _matchType = State(initialValue: editingRule?.matchType ?? .domain)
        _pattern = State(initialValue: editingRule?.matchType == .service ? "" : (editingRule?.pattern ?? ""))
        _selectedServiceId = State(initialValue: editingRule?.matchType == .service ? (editingRule?.pattern ?? "") : (services.first?.id ?? ""))
        _routeId = State(initialValue: editingRule?.routeId)
    }

    private var isEditing: Bool { editingRule != nil }

    private var patternPlaceholder: String {
        switch matchType {
        case .domain:  return "example.com"
        case .suffix:  return "*.example.com"
        case .ip:      return "10.0.0.5"
        case .cidr:    return "10.0.0.0/8"
        case .service, .process: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text(isEditing ? "Edit Rule" : "Add Rule")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formField(label: "Match", required: true) {
                        Picker("", selection: $matchType) {
                            Text("Domain").tag(MatchType.domain)
                            Text("Suffix").tag(MatchType.suffix)
                            Text("Service").tag(MatchType.service)
                            Text("IP").tag(MatchType.ip)
                            Text("CIDR").tag(MatchType.cidr)
                        }
                        .pickerStyle(.segmented)
                    }

                    if matchType == .service {
                        formField(label: "Service", required: true) {
                            if services.isEmpty {
                                Text("No services configured. Add one in the Services tab first.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                            } else {
                                Picker("", selection: $selectedServiceId) {
                                    ForEach(services) { service in
                                        Text(service.name).tag(service.id)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    } else {
                        formField(label: "Pattern", required: true) {
                            TextField(patternPlaceholder, text: $pattern)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.bgInput)
                                .cornerRadius(8)
                        }
                    }

                    formField(label: "Route", required: true) {
                        RouteChipMenu(
                            selectedRouteId: routeId,
                            onSelect: { routeId = $0 },
                            onNewRoute: { showingNewRouteSheet = true }
                        )
                    }

                    if let error = validationError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.error)
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.error)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.error.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding(20)
            }

            Divider().background(Theme.divider)

            // Action buttons
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.bgInput)
                    .cornerRadius(8)

                Spacer()

                Button(isEditing ? "Save Changes" : "Add Rule") {
                    attemptSave()
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.blueGradient)
                .cornerRadius(8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 400)
        .background(Theme.bgSecondary)
        .sheet(isPresented: $showingNewRouteSheet) {
            RouteEditorSheet(editingRoute: nil) { newRoute in
                routeManager.addRoute(newRoute)
                routeId = newRoute.id
                showingNewRouteSheet = false
            } onCancel: {
                showingNewRouteSheet = false
            }
        }
    }

    @ViewBuilder
    private func formField<F: View>(
        label: String,
        required: Bool,
        @ViewBuilder field: () -> F
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                if required {
                    Text("*")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.error)
                }
            }
            field()
        }
    }

    private func attemptSave() {
        let effectivePattern = matchType == .service ? selectedServiceId : pattern.trimmingCharacters(in: .whitespaces)
        guard !effectivePattern.isEmpty else {
            validationError = matchType == .service ? "Select a service." : "Pattern is required."
            return
        }
        guard let routeId else {
            validationError = "Select a route."
            return
        }
        let rule = Rule(
            id: editingRule?.id ?? UUID(),
            matchType: matchType,
            pattern: effectivePattern,
            routeId: routeId,
            enabled: editingRule?.enabled ?? true,
            order: editingRule?.order ?? 0 // new rules: RulesTab.saveRule overwrites this to (max order)+1
        )
        onSave(rule)
    }
}
