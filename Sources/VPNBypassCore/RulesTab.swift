// RulesTab.swift
// Settings tab for managing routing rules in Custom Routes mode: an ordered,
// first-match list of destination -> route assignments (see RuleResolver).

import SwiftUI

// MARK: - Route display helpers (UI-only; the model/engine stay untouched)

extension Route {
    /// Friendly display name for route pickers/chips. `.direct`/`.vpnDefault`
    /// are the two auto-created system routes, so their name is derived rather
    /// than stored; proxy/Tailscale routes just use their own user-given name.
    func friendlyName(vpnName: String?, in bundle: Bundle = .main) -> String {
        switch egress {
        case .direct:      return String(localized: "Direct", bundle: bundle)
        case .vpnDefault:
            // A route pinned to a SPECIFIC tunnel is user-created — use its own name so
            // several VPNs are distinguishable. The primary-VPN route derives its label.
            if vpnSelector?.kind == .interface { return name.isEmpty ? String(localized: "VPN", bundle: bundle) : name }
            return vpnName ?? String(localized: "VPN", bundle: bundle)
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
        Task { await reconcileAfterConfigChange(reconcileListeners: true, reapplyRoutes: false) }
    }

    /// Deletes a rule and re-applies, as the Rules page's trash button does.
    func removeRule(_ id: UUID) {
        config.rules.removeAll { $0.id == id }
        saveRulesAndReapply()
    }

    /// Puts back a rule a delete took out, at its old `order`, and re-applies. A rule that has
    /// since taken that order moves down one, with everything after it, so first match runs
    /// as it did before the delete. Returns false while a rule with that id is listed.
    @discardableResult
    func restoreRule(_ rule: Rule) -> Bool {
        guard !config.rules.contains(where: { $0.id == rule.id }) else { return false }
        config.rules = Self.rules(config.rules, restoring: rule)
        saveRulesAndReapply()
        log(.success, "Restored rule: \(rule.pattern)")
        return true
    }

    /// `rules` with `rule` back at its `order`, the rules from that order on moved down one
    /// when another rule holds it now.
    nonisolated static func rules(_ rules: [Rule], restoring rule: Rule) -> [Rule] {
        var result = rules
        if result.contains(where: { $0.order == rule.order }) {
            for i in result.indices where result[i].order >= rule.order {
                result[i].order += 1
            }
        }
        result.append(rule)
        return result
    }

    /// Custom mode's dropdown quick-add: a rule on the Direct route, appended after the
    /// others as `RulesTab.saveRule` appends a new one. An IP range ("10.0.0.0/24") becomes
    /// a `.cidr` rule, checked by the VPN Only list's range check, which is the Rules
    /// editor's `isValidCIDR`; a name or a pasted link becomes a `.domain` rule for its host,
    /// cleaned as the Bypass list cleans it. Saves but does not re-apply; the caller does.
    /// A rule with the same pattern refuses the add, naming its route: on Direct it is a
    /// repeat, and on another route it matches first, so a second rule would do nothing. A
    /// rule whose route is gone matches nothing, so it does not count. Returns the rule
    /// saved, why the input was refused, or nil when there is no Direct route (logged).
    func addDirectRule(_ input: String) -> Result<Rule, AddDomainError>? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let checked: CheckedDomainInput
        switch checkDomainInput(trimmed, list: Self.looksLikeIPRange(trimmed) ? .vpnOnly : .bypass) {
        case .failure(let error):
            log(.warning, error.message)
            return .failure(error)
        case .success(let value):
            checked = value
        }
        let matchType: MatchType = checked.isCIDR ? .cidr : .domain
        guard let directRouteId = config.routes.first(where: { $0.egress == .direct })?.id else {
            log(.error, "Cannot add rule for \(checked.value): no Direct route found")
            return nil
        }
        let existing = config.rules
            .filter { $0.matchType == matchType && $0.pattern == checked.value }
            .compactMap { rule in config.routes.first(where: { $0.id == rule.routeId }) }
            .first
        if let route = existing {
            let error = AddDomainError.ruleExists(value: checked.value, route: route, vpnName: vpnType?.knownName)
            log(.warning, error.message)
            return .failure(error)
        }
        let maxOrder = config.rules.map(\.order).max() ?? -1
        let rule = Rule(matchType: matchType, pattern: checked.value, routeId: directRouteId, order: maxOrder + 1)
        config.rules.append(rule)
        saveConfig()
        log(.success, "Added rule: \(checked.value) → Direct")
        return .success(rule)
    }

    /// Saves and re-applies after a rule change (RulesTab's `persistAndReapply`).
    func saveRulesAndReapply() {
        saveConfig()
        Task { await reconcileAfterConfigChange(reconcileListeners: false, reapplyRoutes: true) }
    }
}

// MARK: - Proxy rule reach

/// What a rule does when its route is served by a local listener (HTTP CONNECT,
/// SOCKS5, Tailscale peer). Those routes emit no kernel route, so the rule only
/// reaches apps set to use the route's 127.0.0.1 address. The rule still claims its
/// hosts first-match (RouteCompiler), so a Direct or VPN rule below it for the same
/// hosts adds no kernel route either. Direct and VPN rules change the routing table
/// and reach every app, so they get no note.
struct ProxyReachNote: Equatable {
    let routeName: String
    /// `127.0.0.1:<port>`, or nil while the route's listener is not up.
    let address: String?
    /// The route is switched off: no listener runs and the compiler skips the rule.
    var routeOff = false

    /// nil for a Direct or VPN route, and for a rule whose route was deleted.
    static func forRoute(_ route: Route?, listenerPort: UInt16?) -> ProxyReachNote? {
        guard let route, ProxyListenerManager.usesLocalListener(route.egress) else { return nil }
        guard route.enabled else { return ProxyReachNote(routeName: route.name, address: nil, routeOff: true) }
        return ProxyReachNote(routeName: route.name,
                              address: listenerPort.map { LocalListenerAddress.string(port: $0) })
    }

    /// The line under the rule. One catalog sentence per case, with the route name as
    /// an argument, so a translation can put the name where its grammar wants it.
    var text: Text {
        let name = Text(verbatim: routeName).foregroundColor(.white).fontWeight(.medium)
        if routeOff {
            return Text("\(name) is off, so this rule does nothing.")
        }
        if let address {
            return Text("Only apps set to use \(name) (\(Text(verbatim: address))) go this way. Other apps take the Mac's normal route to these hosts, even if a rule below also matches them.")
        }
        return Text("Only apps set to use \(name) go this way. Other apps take the Mac's normal route to these hosts, even if a rule below also matches them.")
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
    @EnvironmentObject var settingsUndo: SettingsUndo
    @ObservedObject private var listenerManager = ProxyListenerManager.shared
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

            if let change = settingsUndo.last, change.page == .rules {
                UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
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
                .accessibilityLabel("Add Rule")
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
                        listenerPort: listenerManager.port(for: rule.routeId),
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
        routeManager.removeRule(rule.id)
        settingsUndo.record(.rule(rule, label: RuleRow.patternDisplay(rule, services: routeManager.config.services)))
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
        routeManager.saveRulesAndReapply()
    }
}

// MARK: - RuleRow

struct RuleRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let rule: Rule
    /// Port of the assigned route's local listener, if it is up.
    let listenerPort: UInt16?
    let showDragHandle: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let onReassign: (UUID) -> Void
    let onNewRoute: () -> Void

    private var matchLabel: String { Self.matchLabel(rule.matchType, in: .main) }

    /// The badge beside the rule's pattern. Text(String) shows a String as it is, so each
    /// label is looked up here.
    static func matchLabel(_ type: MatchType, in bundle: Bundle) -> String {
        switch type {
        case .domain:  return String(localized: "DOMAIN", bundle: bundle)
        case .suffix:  return String(localized: "SUFFIX", bundle: bundle)
        case .ip:      return String(localized: "IP", bundle: bundle)
        case .cidr:    return String(localized: "CIDR", bundle: bundle)
        case .service: return String(localized: "SERVICE", bundle: bundle)
        case .process: return String(localized: "PROCESS", bundle: bundle)
        }
    }

    private var patternDisplay: String {
        Self.patternDisplay(rule, services: routeManager.config.services)
    }

    /// The rule's pattern as its row shows it: a service rule shows the service's name.
    static func patternDisplay(_ rule: Rule, services: [ServiceEntry]) -> String {
        if rule.matchType == .service {
            return services.first(where: { $0.id == rule.pattern })?.name ?? rule.pattern
        }
        return rule.pattern
    }

    /// The route this rule is assigned to, resolved live so a rename/edit in the
    /// Routes tab is reflected immediately. nil if routeId is dangling (its route
    /// was deleted out from under the rule).
    private var assignedRoute: Route? {
        routeManager.config.routes.first { $0.id == rule.routeId }
    }

    /// Set when the assigned route is served by a local listener, so the rule only
    /// reaches apps pointed at that listener. Drawn as a line under the row.
    private var reachNote: ProxyReachNote? {
        ProxyReachNote.forRoute(assignedRoute, listenerPort: listenerPort)
    }

    /// Lines the reach note up with the pattern: drag handle + toggle + spacing.
    private var noteIndent: CGFloat { showDragHandle ? 68 : 44 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ruleLine
            if let reachNote {
                reachNote.text
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, noteIndent)
                    .padding(.trailing, 36)
                    .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var ruleLine: some View {
        HStack(spacing: 10) {
            if showDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 14)
            }

            Toggle(patternDisplay, isOn: Binding(
                get: { rule.enabled },
                set: onToggle
            ))
            .toggleStyle(.switch)
            .tint(Theme.success)
            .labelsHidden()
            .controlSize(.small)
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
            .accessibilityLabel(ControlNames.delete(patternDisplay))
        }
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
            RouteChip(route: selectedRoute, vpnName: routeManager.vpnType?.knownName)
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
                Label(route.friendlyName(vpnName: routeManager.vpnType?.knownName), systemImage: "checkmark")
            } else {
                Text(route.friendlyName(vpnName: routeManager.vpnType?.knownName))
            }
        }
    }
}

struct RouteChip: View {
    let route: Route?
    let vpnName: String?

    private var displayName: String { Self.displayName(route, vpnName: vpnName, in: .main) }

    /// The chip's text: the route's name, or "Choose Route" when the rule has none.
    static func displayName(_ route: Route?, vpnName: String?, in bundle: Bundle) -> String {
        route?.friendlyName(vpnName: vpnName, in: bundle) ?? String(localized: "Choose Route", bundle: bundle)
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
                .accessibilityLabel(String(localized: "Cancel"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formField(label: "Match", required: true) {
                        Picker(String(localized: "Match"), selection: $matchType) {
                            Text("Domain").tag(MatchType.domain)
                            Text("Service").tag(MatchType.service)
                            Text("IP").tag(MatchType.ip)
                            Text("CIDR").tag(MatchType.cidr)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if matchType == .service {
                        formField(label: "Service", required: true) {
                            if services.isEmpty {
                                Text("No services configured. Add one in the Services tab first.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                            } else {
                                Picker(String(localized: "Service"), selection: $selectedServiceId) {
                                    ForEach(services) { service in
                                        Text(service.name).tag(service.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
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
        label: LocalizedStringKey,
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
            validationError = matchType == .service ? String(localized: "Select a service.") : String(localized: "Pattern is required.")
            return
        }
        // Same validators RouteManager already uses for inverse-domain/CIDR entry
        // (see addInverseDomain) — reused here rather than duplicated, so a malformed
        // IP/CIDR can't be saved as an inert rule.
        guard matchType != .ip || routeManager.isValidIP(effectivePattern) else {
            validationError = String(localized: "Enter a valid IPv4 address (e.g. 10.0.0.5).")
            return
        }
        guard matchType != .cidr || routeManager.isValidCIDR(effectivePattern) else {
            validationError = String(localized: "Enter a valid IPv4 CIDR range (e.g. 10.0.0.0/8).")
            return
        }
        guard let routeId else {
            validationError = String(localized: "Select a route.")
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
