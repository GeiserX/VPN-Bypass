// SettingsView.swift
// Settings window with tabs for Status, Domains, Services, Rules, Routes, General, Logs, and Info.

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    /// The mode picked in the title bar's Mode menu; set, it opens the sheet.
    @EnvironmentObject var modeSwitch: ModeSwitchRequest
    /// The last delete or bulk switch, which the page that made it offers to undo.
    @EnvironmentObject var settingsUndo: SettingsUndo
    @Environment(\.undoManager) private var undoManager
    @State private var selectedTab: SettingsTab = .status
    /// What the Logs page shows when it opens: All, or Warnings after the Status page's Show in Log.
    @State private var logsFilter = LogFilter()

    // MARK: - Tab model

    enum SettingsTab: Hashable {
        case status, domains, services, rules, routes, general, logs, info

        var title: LocalizedStringKey {
            switch self {
            case .status:   return "Status"
            case .domains:  return "Domains"
            case .services: return "Services"
            case .rules:    return "Rules"
            case .routes:   return "Routes"
            case .general:  return "General"
            case .logs:     return "Logs"
            case .info:     return "Info"
            }
        }

        var icon: String {
            switch self {
            case .status:   return "waveform.path.ecg.rectangle"
            case .domains:  return "globe"
            case .services: return "square.grid.2x2.fill"
            case .rules:    return "list.bullet.indent"
            case .routes:   return "arrow.triangle.branch"
            case .general:  return "gearshape.fill"
            case .logs:     return "list.bullet.rectangle"
            case .info:     return "info.circle.fill"
            }
        }
    }

    /// Ordered tabs to display, driven by the routing mode (chosen from the Mode menu in the
    /// title bar): Status comes first in every mode; Bypass/VPN Only keep the classic tabs;
    /// Custom Routes swaps Domains/Services for Rules + Routes.
    private var visibleTabs: [SettingsTab] { Self.tabs(for: routeManager.config.routingMode) }

    static func tabs(for mode: RouteManager.RoutingMode) -> [SettingsTab] {
        switch mode {
        case .bypass:  return [.status, .domains, .services, .general, .logs, .info]
        case .vpnOnly: return [.status, .domains, .general, .logs, .info]
        case .custom:  return [.status, .rules, .routes, .general, .logs, .info]
        }
    }

    /// If the selected tab isn't visible under the current mode (e.g. a fresh
    /// window opened while already in Custom mode, or a mode switch while the
    /// window is open), fall back to the first visible tab so the view is never
    /// left showing hidden-tab content with no pill selected in the tab bar.
    private func clampSelectedTabIfNeeded() {
        if !visibleTabs.contains(selectedTab) {
            selectedTab = visibleTabs.first ?? .general
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Beautiful gradient header
            headerView

            // Tab content with animation
            tabContent
                .animation(.easeInOut(duration: 0.2), value: selectedTab)
        }
        .frame(width: 580, height: 680)
        .background(
            LinearGradient(
                colors: [Theme.bgPrimary, Theme.bgSecondary],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            clampSelectedTabIfNeeded()
            settingsUndo.undoManager = undoManager
        }
        .onChange(of: routeManager.config.routingMode) { _ in
            clampSelectedTabIfNeeded()
            // The change was made to another mode's list, which this page no longer shows.
            settingsUndo.clear()
        }
        // The line belongs to the page that made the change.
        .onChange(of: selectedTab) { tab in
            settingsUndo.clear()
            // The Logs filter resets when the page is left, as it always has.
            if tab != .logs { logsFilter = LogFilter() }
        }
        // A page asked for from outside, such as the dropdown's "All 37 services…" row. The
        // publisher sends its current value on subscribe, so a fresh window opens on it too.
        .onReceive(SettingsPageRequest.shared.$page) { page in
            guard let page else { return }
            SettingsPageRequest.shared.page = nil
            selectedTab = page
            clampSelectedTabIfNeeded()
        }
        .sheet(isPresented: Binding(
            get: { modeSwitch.pickedMode != nil },
            set: { if !$0 { modeSwitch.pickedMode = nil } }
        )) {
            RoutingModeSheet(
                selected: modeSwitch.pickedMode ?? routeManager.config.routingMode,
                lists: RoutingModeCopy.lists(from: routeManager.config),
                onCancel: { modeSwitch.pickedMode = nil },
                onSwitch: { mode in
                    routeManager.setRoutingMode(mode)
                    modeSwitch.pickedMode = nil
                }
            )
        }
    }

    /// The page toolbar: icon above label, a plain highlight on the page shown. The routing
    /// mode is not here; it is the Mode menu in the title bar, so no page button changes it.
    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(visibleTabs, id: \.self) { tab in
                    SettingsToolbarItem(
                        title: tab.title,
                        icon: tab.icon,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .frame(maxWidth: .infinity)
            // The hosting view's safe area already starts below the title bar row (traffic
            // lights, app name, Mode menu), so only a small gap is added here.
            .padding(.top, 6)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
        }
        .background(Theme.bgPrimary.opacity(0.8))
    }

    private var tabContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch selectedTab {
                case .status:
                    StatusTab(onShowWarnings: {
                        logsFilter = LogFilter(level: .warnings)
                        selectedTab = .logs
                    })
                case .domains:  DomainsTab()
                case .services: ServicesTab()
                case .rules:    RulesTab()
                case .routes:   RoutesTab()
                case .general:  GeneralTab()
                case .logs:     LogsTab(filter: logsFilter)
                case .info:     InfoTab()
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Toolbar Item

/// One page button in the Settings toolbar, laid out like macOS System Settings: icon above
/// label, and a plain highlight on the page shown rather than the green pill the mode used to wear.
struct SettingsToolbarItem: View {
    let title: LocalizedStringKey
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                    .foregroundColor(isSelected ? Theme.Brand.sky : Theme.textSecondary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 64)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : (isHovered ? Theme.bgCard : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Domains Tab

struct DomainsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var settingsUndo: SettingsUndo
    @State private var newDomain: String
    /// What the last add did, shown under the field.
    @State private var feedback: AddDomainFeedback?
    @FocusState private var isInputFocused: Bool

    /// The arguments seed the field and the line under it, for a rendered screenshot.
    init(newDomain: String = "", feedback: AddDomainFeedback? = nil) {
        _newDomain = State(initialValue: newDomain)
        _feedback = State(initialValue: feedback)
    }

    private var fieldOutline: Color {
        if feedback?.isError == true { return Theme.error.opacity(0.8) }
        return isInputFocused ? Theme.success.opacity(0.5) : Color.clear
    }

    private var isInverse: Bool { routeManager.config.routingMode == .vpnOnly }
    private var activeDomains: [RouteManager.DomainEntry] {
        isInverse ? routeManager.config.inverseDomains : routeManager.config.domains
    }
    private var enabledCount: Int { activeDomains.filter { $0.enabled }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: isInverse ? "lock.shield.fill" : "globe.americas.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(isInverse ? Theme.warningGradient : Theme.successGradient)
                    Text(isInverse ? "VPN Only Domains" : "Custom Domains")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Text(isInverse
                    ? "Only these domains will use the VPN. Everything else bypasses it."
                    : "Add domains that should bypass VPN and use your regular connection.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
            }

            // Add domain input, and what the last add did
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HStack {
                        Image(systemName: "link")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)

                        TextField(isInverse ? "e.g., example.com or 10.0.0.0/24" : "e.g., example.com", text: $newDomain)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($isInputFocused)
                            .onSubmit { addDomain() }
                            .disabled(routeManager.isApplyingRoutes)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.bgInput)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(fieldOutline, lineWidth: 1)
                            )
                    )

                    // Loading indicator or add button
                    if routeManager.isApplyingRoutes {
                        ProgressView()
                            .scaleEffect(0.7)
                            .progressViewStyle(CircularProgressViewStyle(tint: Theme.success))
                            .frame(width: 42, height: 42)
                            .background(Theme.bgDisabled)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Button(action: addDomain) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 42, height: 42)
                                .background(
                                    LinearGradient(
                                        colors: newDomain.isEmpty ? [Theme.textDisabled, Theme.textDisabled] : [Theme.success, Theme.successDark],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: newDomain.isEmpty ? .clear : Theme.success.opacity(0.3), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .disabled(newDomain.isEmpty)
                    }
                }

                if let feedback {
                    AddDomainFeedbackLine(feedback: feedback)
                }
            }
            // Editing the text the line talks about, or switching lists, makes it stale.
            .onChange(of: newDomain) { text in
                if text != feedback?.fieldText { feedback = nil }
            }
            .onChange(of: routeManager.config.routingMode) { _ in feedback = nil }
            // A refusal such as "already on your list" stops being true once the list
            // changes (the trash button below, `vpnb domain.rm`). A saved add changes the
            // list itself, so its line stays.
            .onChange(of: activeDomains.map(\.domain)) { _ in
                if feedback?.isError == true { feedback = nil }
            }

            // Domain list
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CONFIGURED DOMAINS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                        .tracking(1)

                    Spacer()

                    // Loading indicator, or the Turn All On/Off menu after the count
                    if routeManager.isApplyingRoutes {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .progressViewStyle(CircularProgressViewStyle(tint: Theme.success))
                            Text("Applying...")
                                .font(.system(size: 9))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }

                    Text("\(enabledCount)/\(activeDomains.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(isInverse ? Theme.warning : Theme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((isInverse ? Theme.warning : Theme.success).opacity(0.15))
                        .clipShape(Capsule())

                    if !routeManager.isApplyingRoutes && !activeDomains.isEmpty {
                        BulkSwitchMenu(
                            turnAllOnTitle: String(localized: "Turn All On"),
                            canTurnOn: enabledCount < activeDomains.count,
                            canTurnOff: enabledCount > 0,
                            onTurnAllOn: { switchAll(true) },
                            onTurnAllOff: { switchAll(false) }
                        )
                    }
                }

                if activeDomains.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 6) {
                        ForEach(activeDomains) { domain in
                            DomainRow(domain: domain, isInverse: isInverse) { removeDomain(domain) }
                        }
                    }
                }

                if let change = settingsUndo.last, change.page == .domains {
                    UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.bgCardBorder, lineWidth: 1)
                    )
            )

            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isInverse ? "lock.shield" : "globe")
                .font(.system(size: 28))
                .foregroundColor(Theme.textDisabled)
            Text("No entries configured")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
            Text(isInverse ? "Add domains or IP ranges that should use VPN" : "Add a domain above to bypass VPN")
                .font(.system(size: 11))
                .foregroundColor(Theme.textDisabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
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

/// The line under the Domains tab's add field: what the last add saved, or why it saved
/// nothing. A failed add keeps the text so it can be fixed; a saved one empties the field.
struct AddDomainFeedback: Equatable {
    let isError: Bool
    let message: String
    /// The field's text while this line shows. Typing something else clears the line.
    let fieldText: String

    init(_ result: Result<AddedDomain, AddDomainError>, typed: String) {
        switch result {
        case .success(let added):
            isError = false
            message = added.message
            fieldText = ""
        case .failure(let error):
            isError = true
            message = error.message
            fieldText = typed
        }
    }
}

struct AddDomainFeedbackLine: View {
    let feedback: AddDomainFeedback

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: feedback.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            Text(feedback.message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundColor(feedback.isError ? Theme.error : Theme.success)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct DomainRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let domain: RouteManager.DomainEntry
    var isInverse: Bool = false
    /// The trash button. DomainsTab removes the entry and leaves the undo line.
    let onDelete: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(domain.enabled ? Theme.success : Theme.textDisabled)
                .frame(width: 8, height: 8)
                .shadow(color: domain.enabled ? Theme.success.opacity(0.5) : .clear, radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(domain.domain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(domain.enabled ? .white : Theme.textSecondary)
                    if domain.isCIDR {
                        Text("CIDR")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.warning.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            // Toggle - disabled during route operations
            Toggle("", isOn: Binding(
                get: { domain.enabled },
                set: { _ in
                    if !routeManager.isApplyingRoutes {
                        if isInverse { routeManager.toggleInverseDomain(domain.id) }
                        else { routeManager.toggleDomain(domain.id) }
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(isInverse ? Theme.warning : Theme.success)
            .scaleEffect(0.7)
            .disabled(routeManager.isApplyingRoutes)
            .opacity(routeManager.isApplyingRoutes ? 0.5 : 1)

            // Delete button - disabled during route operations
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.error.opacity(isHovered ? 1 : 0.6))
            }
            .buttonStyle(.plain)
            .disabled(routeManager.isApplyingRoutes)
            .opacity(routeManager.isApplyingRoutes ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Theme.bgHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Services Tab

/// How the Services page splits the list: an On section with the services that were on when
/// the page opened, then the custom and the built-in services that were not, each in the
/// catalogue's order. Kept pure so the split, its wording and its edge cases are unit-tested.
///
/// The split follows the switches as they were when the page opened (`pinned`), not as they
/// are now, so a switch flipped on the page leaves its row where it is. The row moves on the
/// next visit, never from under the pointer. A service added since the page opened, such as a
/// custom service just created, goes by its own switch, and the page pins it as soon as it sees
/// it, so flipping its switch does not move it either.
struct ServiceSections {
    enum Kind: CaseIterable {
        case on, custom, builtIn
    }

    var on: [ServiceEntry]
    var custom: [ServiceEntry]
    var builtIn: [ServiceEntry]

    /// Each service's switch as it is now, by id: what the page pins when it opens.
    static func pin(_ services: [ServiceEntry]) -> [String: Bool] {
        Dictionary(services.map { ($0.id, $0.enabled) }, uniquingKeysWith: { first, _ in first })
    }

    /// The pin plus every service it has not seen yet, at its switch as it is now. The services
    /// already pinned keep their pin.
    static func pinNew(_ services: [ServiceEntry], into pinned: [String: Bool]) -> [String: Bool] {
        pinned.merging(pin(services)) { kept, _ in kept }
    }

    /// Whether a service shows for the search text: its name or one of its domains contains
    /// the text, ignoring case. Empty text shows everything.
    static func matches(_ service: ServiceEntry, search: String) -> Bool {
        search.isEmpty
            || service.name.localizedCaseInsensitiveContains(search)
            || service.domains.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    init(services: [ServiceEntry], pinned: [String: Bool], search: String) {
        let shown = services.filter { Self.matches($0, search: search) }
        let isOn = { (service: ServiceEntry) in pinned[service.id] ?? service.enabled }
        on = shown.filter { isOn($0) }
        custom = shown.filter { !isOn($0) && $0.isCustom }
        builtIn = shown.filter { !isOn($0) && !$0.isCustom }
    }

    /// The sections that have rows, top to bottom.
    var nonEmpty: [(kind: Kind, services: [ServiceEntry])] {
        Kind.allCases.compactMap { kind in
            let rows = self[kind]
            return rows.isEmpty ? nil : (kind, rows)
        }
    }

    subscript(kind: Kind) -> [ServiceEntry] {
        switch kind {
        case .on: return on
        case .custom: return custom
        case .builtIn: return builtIn
        }
    }

    /// A section's header. The On header has its own key: the dropdown's "ON" pill says the
    /// app is enforcing, and Spanish and French word the two differently.
    static func title(_ kind: Kind, in bundle: Bundle = .main) -> String {
        switch kind {
        case .on: return String(localized: "services.section.on", defaultValue: "ON", bundle: bundle)
        case .custom: return String(localized: "CUSTOM SERVICES", bundle: bundle)
        case .builtIn: return String(localized: "BUILT-IN SERVICES", bundle: bundle)
        }
    }
}

struct ServicesTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var settingsUndo: SettingsUndo
    @State private var searchText = ""
    /// Set, Turn All On asks this before it runs.
    @State private var turnOnQuestion: ServiceBulkSwitch.Question?
    @State private var showingCustomServiceEditor = false
    @State private var editingService: RouteManager.ServiceEntry?
    /// Each service's switch when the page opened; nil until it appears.
    @State private var pinned: [String: Bool]?

    /// The argument seeds the question Turn All On asks, for a rendered screenshot.
    init(turnOnQuestion: ServiceBulkSwitch.Question? = nil) {
        _turnOnQuestion = State(initialValue: turnOnQuestion)
    }

    private var isVPNOnly: Bool {
        routeManager.config.routingMode == .vpnOnly
    }

    private var sections: ServiceSections {
        let services = routeManager.config.services
        return ServiceSections(services: services,
                               pinned: pinned ?? ServiceSections.pin(services),
                               search: searchText)
    }

    private var enabledCount: Int {
        routeManager.config.services.filter { $0.enabled }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.purpleGradient)
                    Text("Services")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                if !isVPNOnly {
                    Text("\(enabledCount)/\(routeManager.config.services.count) enabled")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)

                    Button {
                        editingService = nil
                        showingCustomServiceEditor = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Theme.purpleLight)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Create Custom Service")
                }
            }

            if isVPNOnly {
                // VPN Only mode banner
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.warning)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Services disabled in VPN Only mode")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.warning)
                        Text("Switch to Bypass mode above to manage services.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.warning.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Theme.warning.opacity(0.2), lineWidth: 1)
                        )
                )

                Spacer()
            } else {
                // Search and bulk actions
                HStack(spacing: 10) {
                    // Search box
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)

                        TextField("Search services...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .disabled(routeManager.isApplyingRoutes)

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.bgInput)
                    .cornerRadius(8)

                    // Loading indicator
                    if routeManager.isApplyingRoutes {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .progressViewStyle(CircularProgressViewStyle(tint: Theme.success))
                            Text("Applying...")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .frame(width: 80)
                    } else {
                        BulkSwitchMenu(
                            turnAllOnTitle: ServiceBulkSwitch.turnAllOnTitle(offCount: offServices.count),
                            canTurnOn: !offServices.isEmpty,
                            canTurnOff: enabledCount > 0,
                            onTurnAllOn: turnAllOn,
                            onTurnAllOff: { switchAll(false) }
                        )
                    }
                }

                if let change = settingsUndo.last, change.page == .services {
                    UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
                }

                // Services list: the services that were on when the page opened, then the rest
                ScrollView {
                    if !sections.nonEmpty.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(sections.nonEmpty.enumerated()), id: \.element.kind) { index, section in
                                if index > 0 {
                                    Rectangle()
                                        .fill(Theme.divider.opacity(0.6))
                                        .frame(height: 1)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 4)
                                }

                                HStack(spacing: 8) {
                                    Text(ServiceSections.title(section.kind))
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundColor(Theme.textSecondary)
                                    Text(verbatim: String(section.services.count))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.top, 8)

                                LazyVStack(spacing: 2) {
                                    ForEach(section.services) { service in
                                        ServiceRow(service: service, onEdit: service.isCustom ? {
                                            editingService = service
                                            showingCustomServiceEditor = true
                                        } : nil, onDelete: { removeCustomService(service) })
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.bgElevated)
                        )
                    }
                }
                .onAppear {
                    pinned = ServiceSections.pin(routeManager.config.services)
                }
                .onChange(of: routeManager.config.services.map(\.id)) { _ in
                    if let current = pinned {
                        pinned = ServiceSections.pinNew(routeManager.config.services, into: current)
                    }
                }
                // An undone Turn All On/Off moves many rows at once, like the switch itself.
                .onChange(of: settingsUndo.undoneCount) { _ in
                    pinned = ServiceSections.pin(routeManager.config.services)
                }
            }
        }
        .sheet(isPresented: $showingCustomServiceEditor) {
            CustomServiceEditor(service: editingService)
                .environmentObject(routeManager)
        }
        .alert(turnOnQuestion?.title ?? "", isPresented: Binding(
            get: { turnOnQuestion != nil },
            set: { if !$0 { turnOnQuestion = nil } }
        )) {
            Button(turnOnQuestion?.confirm ?? "") { switchAll(true) }
            Button(String(localized: "Cancel"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(turnOnQuestion?.message ?? "")
        }
    }

    private var offServices: [RouteManager.ServiceEntry] {
        routeManager.config.services.filter { !$0.enabled }
    }

    private func turnAllOn() {
        if let question = ServiceBulkSwitch.question(turningOn: offServices) {
            turnOnQuestion = question
        } else {
            switchAll(true)
        }
    }

    private func switchAll(_ on: Bool) {
        let changed = routeManager.setAllServicesEnabled(on)
        // The pointer is on the menu, not on a row: show the new split now.
        pinned = ServiceSections.pin(routeManager.config.services)
        if !changed.isEmpty { settingsUndo.record(.servicesSwitched(ids: changed, on: on)) }
    }

    private func removeCustomService(_ service: RouteManager.ServiceEntry) {
        let index = routeManager.config.services.firstIndex(where: { $0.id == service.id }) ?? routeManager.config.services.count
        routeManager.removeCustomService(service.id)
        settingsUndo.record(.customService(service, index: index))
    }
}

/// The ⋯ menu that replaced the All and None chips on the Domains and Services pages.
struct BulkSwitchMenu: View {
    let turnAllOnTitle: String
    let canTurnOn: Bool
    let canTurnOff: Bool
    let onTurnAllOn: () -> Void
    let onTurnAllOff: () -> Void

    var body: some View {
        Menu {
            Button(turnAllOnTitle, action: onTurnAllOn)
                .disabled(!canTurnOn)
            Button(String(localized: "Turn All Off"), action: onTurnAllOff)
                .disabled(!canTurnOff)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Turn all on or off"))
    }
}

struct ServiceRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let service: RouteManager.ServiceEntry
    var onEdit: (() -> Void)?
    /// The trash button of a custom service. ServicesTab removes it and leaves the undo line.
    var onDelete: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(service.enabled ? Theme.success : Theme.textDisabled)
                .frame(width: 8, height: 8)
                .shadow(color: service.enabled ? Theme.success.opacity(0.5) : .clear, radius: 4)

            // Service info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(service.enabled ? .white : Theme.textSecondary)

                    if service.isCustom {
                        Text("Custom")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.purpleLight)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.purple.opacity(0.12))
                            .cornerRadius(4)
                    }
                }

                Text("\(service.domains.count) domains" + (service.ipRanges.isEmpty ? "" : " · \(service.ipRanges.count) IPs"))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            // Edit/delete buttons for custom services
            if service.isCustom {
                Button {
                    onEdit?()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.purple)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.4)

                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.error)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1.0 : 0.4)
            }

            // Toggle
            Toggle("", isOn: Binding(
                get: { service.enabled },
                set: { _ in
                    if !routeManager.isApplyingRoutes {
                        routeManager.toggleService(service.id)
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(Theme.success)
            .scaleEffect(0.7)
            .disabled(routeManager.isApplyingRoutes)
            .opacity(routeManager.isApplyingRoutes ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Theme.bgHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Custom Service Editor

struct CustomServiceEditor: View {
    @EnvironmentObject var routeManager: RouteManager
    @Environment(\.dismiss) private var dismiss
    let service: RouteManager.ServiceEntry?

    @State private var serviceName = ""
    @State private var domains: [String] = [""]
    @State private var ipRanges: [String] = []

    private var isEditing: Bool { service != nil }

    private var canSave: Bool {
        !serviceName.trimmingCharacters(in: .whitespaces).isEmpty &&
        domains.contains(where: { isValidDomainInput($0) })
    }

    private func isValidDomainInput(_ input: String) -> Bool {
        let cleaned = routeManager.cleanDomain(input)
        guard !cleaned.isEmpty else { return false }
        let parts = cleaned.components(separatedBy: ".")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Service" : "Create Custom Service")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider().background(Theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Service Name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Service Name")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)

                        TextField("e.g. My Service", text: $serviceName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(10)
                            .background(Theme.bgInput)
                            .cornerRadius(8)
                    }

                    // Domains
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Domains")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                            Spacer()
                            Button {
                                domains.append("")
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Add")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(Theme.success)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(domains.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                TextField("example.com", text: $domains[index])
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .padding(8)
                                    .background(Theme.bgInput)
                                    .cornerRadius(6)

                                if domains.count > 1 {
                                    Button {
                                        domains.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(Theme.error.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // IP Ranges (optional)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("IP Ranges (optional)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary)
                                Text("CIDR notation, e.g. 192.168.1.0/24")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            Button {
                                ipRanges.append("")
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Add")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(Theme.success)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(ipRanges.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                TextField("10.0.0.0/8", text: $ipRanges[index])
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .padding(8)
                                    .background(Theme.bgInput)
                                    .cornerRadius(6)

                                Button {
                                    ipRanges.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(Theme.error.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if ipRanges.isEmpty {
                            Text("No IP ranges added. Only domain-based routing will be used.")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .italic()
                        }
                    }
                }
                .padding(16)
            }

            Divider().background(Theme.divider)

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Spacer()

                Button {
                    save()
                    dismiss()
                } label: {
                    Text(isEditing ? "Save Changes" : "Create Service")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(canSave ? Theme.purple : Theme.textDisabled)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
        .background(
            LinearGradient(
                colors: [Theme.bgPrimary, Theme.bgSecondary],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            if let service {
                serviceName = service.name
                domains = service.domains.isEmpty ? [""] : service.domains
                ipRanges = service.ipRanges
            }
        }
    }

    private func save() {
        let cleanDomains = domains
            .map { routeManager.cleanDomain($0) }
            .filter { isValidDomainInput($0) }
        let cleanIPs = ipRanges.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name = serviceName.trimmingCharacters(in: .whitespaces)

        if let service {
            routeManager.updateCustomService(id: service.id, name: name, domains: cleanDomains, ipRanges: cleanIPs)
        } else {
            routeManager.addCustomService(name: name, domains: cleanDomains, ipRanges: cleanIPs)
        }
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @State private var showingExportSuccess = false
    @State private var showingImportPicker = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""
    @State private var selectedLanguage: String = UserDefaults.standard.string(forKey: "UserLanguageOverride") ?? "system"
    @State private var showingRestartAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.warningGradient)
                    Text("Settings")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            
            // Language section
            SettingsCard(title: "Language", icon: "globe", iconColor: Theme.blue) {
                HStack(spacing: 12) {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.blue)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Language")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Text("App language (restart required)")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }

                    Spacer()

                    Picker("Language", selection: $selectedLanguage) {
                        Text("System").tag("system")
                        Text("English").tag("en")
                        Text("Español").tag("es")
                        Text("Français").tag("fr")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                    .onChange(of: selectedLanguage) { newValue in
                        if newValue == "system" {
                            UserDefaults.standard.removeObject(forKey: "UserLanguageOverride")
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                        } else {
                            UserDefaults.standard.set(newValue, forKey: "UserLanguageOverride")
                            UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                        }
                        showingRestartAlert = true
                    }
                }
            }

            // Startup section
            SettingsCard(title: "Startup", icon: "power", iconColor: Theme.success) {
                SettingsToggleRow(
                    icon: "arrow.clockwise",
                    title: "Launch at Login",
                    subtitle: "Automatically start VPN Bypass when you log in",
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { _ in launchAtLoginManager.toggle() }
                    )
                )
            }
            
            // Behavior section
            SettingsCard(title: "Behavior", icon: "bolt.fill", iconColor: Theme.warning) {
                SettingsToggleRow(
                    icon: "play.circle.fill",
                    title: "Auto-apply on VPN Connect",
                    subtitle: "Automatically apply routes when VPN connects",
                    isOn: Binding(
                        get: { routeManager.config.autoApplyOnVPN },
                        set: { routeManager.config.autoApplyOnVPN = $0; routeManager.saveConfig() }
                    )
                )
                
                Divider().background(Theme.divider)
                
                SettingsToggleRow(
                    icon: "doc.text.fill",
                    title: "Manage /etc/hosts",
                    subtitle: "Add DNS bypass entries (requires admin)",
                    isOn: Binding(
                        get: { routeManager.config.manageHostsFile },
                        set: { routeManager.config.manageHostsFile = $0; routeManager.saveConfig() }
                    )
                )
                
                Divider().background(Theme.divider)
                
                SettingsToggleRow(
                    icon: "checkmark.circle.fill",
                    title: "Verify Routes After Apply",
                    subtitle: "Ping test routes to ensure they're working",
                    isOn: Binding(
                        get: { routeManager.config.verifyRoutesAfterApply },
                        set: { routeManager.config.verifyRoutesAfterApply = $0; routeManager.saveConfig() }
                    )
                )
            }
            
            // DNS Refresh section
            SettingsCard(title: "DNS Refresh", icon: "arrow.triangle.2.circlepath", iconColor: Theme.cyan) {
                SettingsToggleRow(
                    icon: "clock.arrow.circlepath",
                    title: "Auto DNS Refresh",
                    subtitle: "Periodically re-resolve domains and update routes",
                    isOn: Binding(
                        get: { routeManager.config.autoDNSRefresh },
                        set: { 
                            routeManager.config.autoDNSRefresh = $0
                            routeManager.saveConfig()
                            routeManager.startDNSRefreshTimer()
                        }
                    )
                )
                
                if routeManager.config.autoDNSRefresh {
                    Divider().background(Theme.divider)
                    
                    // Interval picker
                    HStack(spacing: 12) {
                        Image(systemName: "timer")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.cyan)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refresh Interval")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("How often to re-check DNS for changes")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                        }
                        
                        Spacer()
                        
                        Picker("", selection: Binding(
                            get: { routeManager.config.dnsRefreshInterval },
                            set: { 
                                routeManager.config.dnsRefreshInterval = $0
                                routeManager.saveConfig()
                                routeManager.startDNSRefreshTimer()
                            }
                        )) {
                            Text("15 min").tag(TimeInterval(900))
                            Text("30 min").tag(TimeInterval(1800))
                            Text("1 hour").tag(TimeInterval(3600))
                            Text("2 hours").tag(TimeInterval(7200))
                            Text("6 hours").tag(TimeInterval(21600))
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    
                }

                Text("Re-resolves all domains to catch IP changes and ensure routes stay up to date.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            
            // Fallback DNS section
            SettingsCard(title: "Fallback DNS", icon: "server.rack", iconColor: Theme.purple) {
                VStack(alignment: .leading, spacing: 12) {
                    // Detected DNS - prominent display
                    if let detected = routeManager.detectedDNSServerDisplay {
                        HStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(Theme.cyan)
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detected Non-VPN DNS")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Theme.textSecondary)
                                Text(detected)
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.cyan)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.cyan.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Theme.cyan.opacity(0.3), lineWidth: 1)
                                )
                        )
                    }

                    Text("Fallback DNS servers when detected DNS is unavailable.\nSupported formats: IP (1.1.1.1), DoH (https://...), DoT (tls://... or IP:853)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    
                    ForEach(Array(routeManager.config.fallbackDNS.enumerated()), id: \.offset) { index, dns in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 20)

                            TextField("DNS server", text: Binding(
                                get: { routeManager.config.fallbackDNS[index] },
                                set: {
                                    routeManager.config.fallbackDNS[index] = $0
                                    routeManager.saveConfig()
                                }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.bgInputAlt)
                            .cornerRadius(6)

                            Button {
                                routeManager.config.fallbackDNS.remove(at: index)
                                routeManager.saveConfig()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(Theme.error)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        routeManager.config.fallbackDNS.append("")
                        routeManager.saveConfig()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add DNS Server")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.success)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Notifications section
            SettingsCard(title: "Notifications", icon: "bell.fill", iconColor: Theme.purple) {
                SettingsToggleRow(
                    icon: "bell.badge.fill",
                    title: "Enable Notifications",
                    subtitle: "Show alerts for VPN events",
                    isOn: Binding(
                        get: { notificationManager.notificationsEnabled },
                        set: { 
                            notificationManager.notificationsEnabled = $0
                            notificationManager.savePreferences()
                        }
                    )
                )
                
                if notificationManager.notificationsEnabled {
                    Divider().background(Theme.divider)
                    
                    SettingsToggleRow(
                        icon: "speaker.slash.fill",
                        title: "Silent",
                        subtitle: "No sound",
                        isOn: Binding(
                            get: { notificationManager.silentNotifications },
                            set: { 
                                notificationManager.silentNotifications = $0
                                notificationManager.savePreferences()
                            }
                        )
                    )
                    
                    Divider().background(Theme.divider)
                    
                    HStack(spacing: 12) {
                        NotificationChip(
                            label: "Connect",
                            isOn: Binding(
                                get: { notificationManager.notifyOnVPNConnect },
                                set: { notificationManager.notifyOnVPNConnect = $0; notificationManager.savePreferences() }
                            )
                        )
                        NotificationChip(
                            label: "Disconnect",
                            isOn: Binding(
                                get: { notificationManager.notifyOnVPNDisconnect },
                                set: { notificationManager.notifyOnVPNDisconnect = $0; notificationManager.savePreferences() }
                            )
                        )
                        NotificationChip(
                            label: "Routes",
                            isOn: Binding(
                                get: { notificationManager.notifyOnRoutesApplied },
                                set: { notificationManager.notifyOnRoutesApplied = $0; notificationManager.savePreferences() }
                            )
                        )
                        NotificationChip(
                            label: "Failures",
                            isOn: Binding(
                                get: { notificationManager.notifyOnRouteFailure },
                                set: { notificationManager.notifyOnRouteFailure = $0; notificationManager.savePreferences() }
                            )
                        )
                    }
                    
                    Text("Routes: services, domains, DNS refresh")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            
            // SOCKS5 Proxy section (Aggressive Bypass Mode)
            SettingsCard(title: "SOCKS5 Proxy", icon: "network.badge.shield.half.filled", iconColor: Theme.warning) {
                VStack(alignment: .leading, spacing: 12) {
                    // Warning/info box
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.warning)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aggressive Bypass Mode")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.warning)
                            Text("For corporate VPNs (Cisco, Zscaler) that block UDP. Requires external SOCKS5 proxy server with UDP support.")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.warning.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.warning.opacity(0.3), lineWidth: 1)
                            )
                    )
                    
                    SettingsToggleRow(
                        icon: "shield.lefthalf.filled",
                        title: "Enable SOCKS5 Proxy",
                        subtitle: "Route traffic through proxy to bypass UDP blocking",
                        isOn: Binding(
                            get: { routeManager.config.proxyConfig.enabled },
                            set: { 
                                routeManager.config.proxyConfig.enabled = $0
                                routeManager.saveConfig()
                            }
                        )
                    )
                    
                    if routeManager.config.proxyConfig.enabled {
                        Divider().background(Theme.divider)
                        
                        // Server and port
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Proxy Server")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textSecondary)

                            HStack(spacing: 8) {
                                TextField("Server address", text: Binding(
                                    get: { routeManager.config.proxyConfig.server },
                                    set: {
                                        routeManager.config.proxyConfig.server = $0
                                        routeManager.saveConfig()
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.bgInputAlt)
                                .cornerRadius(6)

                                TextField("Port", value: Binding(
                                    get: { routeManager.config.proxyConfig.port },
                                    set: {
                                        routeManager.config.proxyConfig.port = $0
                                        routeManager.saveConfig()
                                    }
                                ), format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.bgInputAlt)
                                .cornerRadius(6)
                                .frame(width: 80)
                            }
                        }

                        // Authentication (optional)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Authentication (optional)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textSecondary)

                            HStack(spacing: 8) {
                                TextField("Username", text: Binding(
                                    get: { routeManager.config.proxyConfig.username },
                                    set: {
                                        routeManager.config.proxyConfig.username = $0
                                        routeManager.saveConfig()
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.bgInputAlt)
                                .cornerRadius(6)

                                SecureField("Password", text: Binding(
                                    get: { routeManager.config.proxyConfig.password },
                                    set: {
                                        routeManager.config.proxyConfig.password = $0
                                        routeManager.saveConfig()
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.bgInputAlt)
                                .cornerRadius(6)
                            }
                        }

                        // Test connection button
                        HStack {
                            Button {
                                Task {
                                    await routeManager.testProxyConnection()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if routeManager.isTestingProxy {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.system(size: 11))
                                    }
                                    Text(routeManager.isTestingProxy ? "Testing..." : "Test Connection")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    routeManager.config.proxyConfig.isConfigured
                                        ? Theme.warning
                                        : Theme.textDisabled
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!routeManager.config.proxyConfig.isConfigured || routeManager.isTestingProxy)

                            if let result = routeManager.proxyTestResult {
                                HStack(spacing: 4) {
                                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(result.success ? Theme.success : Theme.error)
                                    Text(result.message)
                                        .font(.system(size: 10))
                                        .foregroundColor(result.success ? Theme.success : Theme.error)
                                }
                            }
                        }

                        Text("Proxy will be used for services that need UDP (Discord voice, gaming, etc.) when corporate VPN blocks direct UDP traffic.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            
            // Import/Export section
            SettingsCard(title: "Configuration", icon: "doc.badge.arrow.up.fill", iconColor: Theme.blue) {
                HStack(spacing: 12) {
                    Button {
                        exportConfig()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                            Text("Export")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Theme.blue, Theme.blueDark],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showingImportPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12))
                            Text("Import")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(Theme.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                Text("Export your domains and services configuration to a file, or import from a backup.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            
            Spacer()
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Need to start accessing security-scoped resource
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    
                    if routeManager.importConfig(from: url) {
                        // Success handled by routeManager
                    } else {
                        importErrorMessage = "Failed to import configuration file."
                        showingImportError = true
                    }
                }
            case .failure(let error):
                importErrorMessage = error.localizedDescription
                showingImportError = true
            }
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
        .alert(String(localized: "Restart Required"), isPresented: $showingRestartAlert) {
            Button(String(localized: "Restart Now")) {
                let path = Bundle.main.bundlePath
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-n", path]
                do {
                    try task.run()
                    NSApp.terminate(nil)
                } catch {
                    // Fall through — app stays open
                }
            }
            Button(String(localized: "Later"), role: .cancel) { }
        } message: {
            Text("The app needs to restart to apply the language change.")
        }
    }
    
    private func exportConfig() {
        guard let exportURL = routeManager.exportConfig() else {
            return
        }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = exportURL.lastPathComponent
        savePanel.canCreateDirectories = true
        
        if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            try? FileManager.default.copyItem(at: exportURL, to: destinationURL)
        }
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: exportURL)
    }
}

struct NotificationChip: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool
    
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? .white : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isOn ? Theme.purple.opacity(0.3) : Theme.bgCard)
                )
        }
        .buttonStyle(.plain)
    }
}

struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(title)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
                    .tracking(1)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.bgCardBorder, lineWidth: 1)
                )
        )
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Theme.success)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Theme.success)
                .scaleEffect(0.8)
        }
    }
}

// MARK: - Logs Tab

struct LogsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var filter: LogFilter

    init(filter: LogFilter = LogFilter()) {
        _filter = State(initialValue: filter)
    }

    var body: some View {
        let shown = filter.apply(routeManager.recentLogs)
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                if routeManager.recentLogs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 36))
                            .foregroundColor(Theme.textDisabled)
                        Text("No activity yet")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                        Text("Logs will appear here when routes are applied")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textDisabled)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 10)
                } else {
                    filterBar(shown: shown)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(filter.countLine(shown: shown.count, total: routeManager.recentLogs.count))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                            .padding(.leading, 2)

                        if let empty = filter.emptyLine(shown: shown.count) {
                            Text(empty)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Theme.bgElevated)
                                )
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 1) {
                                    ForEach(shown) { log in
                                        LogRow(entry: log, highlight: filter.term)
                                    }
                                }
                                .padding(4)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Theme.bgElevated)
                            )
                        }
                    }
                }
            }
        }
    }

    /// The level filter, the search field, and Copy and Clear, as in proposal 14 of #119.
    private func filterBar(shown: [RouteManager.LogEntry]) -> some View {
        HStack(spacing: 10) {
            Picker(LogLevelFilter.controlName, selection: $filter.level) {
                ForEach(LogLevelFilter.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(LogLevelFilter.controlHelp)

            LogSearchField(text: $filter.query, placeholder: String(localized: "Search"))
                .frame(minWidth: 110, maxWidth: 190)

            Spacer(minLength: 0)

            Button("Copy") {
                copyLogsToClipboard(shown)
            }
            .disabled(shown.isEmpty)
            .help(String(localized: "Copy the entries shown"))

            Button("Clear") {
                withAnimation { routeManager.recentLogs.removeAll() }
            }
            .help(String(localized: "Remove every entry, including any the filter hides"))
        }
        .controlSize(.regular)
    }

    private func copyLogsToClipboard(_ entries: [RouteManager.LogEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogFilter.clipboardText(entries), forType: .string)
    }
}

// MARK: - Info Tab

struct InfoTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App info header
            appInfoSection
            
            // Author section
            authorSection
            
            // Support section
            supportSection
            
            // Links section
            linksSection
            
            // License section
            licenseSection
            
            Spacer()
        }
    }
    
    private var appInfoSection: some View {
        VStack(alignment: .center, spacing: 10) {
            // App logo from bundle
            if let logoPath = Bundle.main.path(forResource: "VPNBypass", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: logoPath) {
                Image(nsImage: nsImage)
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 21.6, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            } else {
                Image(systemName: "arrow.right")
                    .font(.system(size: 48))
                    .foregroundColor(Theme.Brand.sky)
            }

            // Type only — the icon directly above IS the mark. Repeating it here duplicated
            // the mark and, because a mark+type lockup centres as one unit, left the type
            // visibly off-centre under the icon.
            BrandedAppName(fontSize: 26)
                .padding(.top, 2)

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.textTertiary)

            Text("Route specific traffic around your corporate VPN")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
    
    private var authorSection: some View {
        SettingsCard(title: "Author", icon: "person.fill", iconColor: Theme.purple) {
            HStack(spacing: 16) {
                // Avatar from GitHub
                if let avatarPath = Bundle.main.path(forResource: "author-avatar", ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: avatarPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                } else {
                    // Fallback
                    Circle()
                        .fill(
                            Theme.purpleGradient
                        )
                        .frame(width: 50, height: 50)
                        .overlay(
                            Text("SF")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sergio Fernández")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text("Your 100x Engineer, with ❤️")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                
                Spacer()
            }
        }
    }
    
    private var supportSection: some View {
        SettingsCard(title: "Support the Project", icon: "heart.fill", iconColor: Theme.error) {
            VStack(alignment: .leading, spacing: 12) {
                Text("If you find VPN Bypass useful, consider supporting its development!")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                
                // First row
                HStack(spacing: 10) {
                    LinkButton(
                        title: "GitHub Sponsors",
                        icon: "heart.fill",
                        color: Theme.githubSponsors,
                        url: "https://github.com/sponsors/GeiserX"
                    )

                    LinkButton(
                        title: "Buy Me a Coffee",
                        icon: "cup.and.saucer.fill",
                        color: Theme.buyMeACoffee,
                        url: "https://buymeacoffee.com/geiser"
                    )
                }

                // Second row
                HStack(spacing: 10) {
                    LinkButton(
                        title: "Patreon",
                        icon: "paintpalette.fill",
                        color: Theme.patreon,
                        url: "https://patreon.com/geiser"
                    )

                    LinkButton(
                        title: "Thanks.dev",
                        icon: "hands.clap.fill",
                        color: Theme.success,
                        url: "https://thanks.dev/u/gh/geiserx"
                    )
                }
            }
        }
    }
    
    private var linksSection: some View {
        SettingsCard(title: "Links", icon: "link", iconColor: Theme.blue) {
            VStack(spacing: 8) {
                LinkRow(icon: "globe", title: "Blog", subtitle: "geiser.cloud", url: "https://geiser.cloud")
                Divider().background(Theme.divider)
                LinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "GitHub", subtitle: "github.com/GeiserX", url: "https://github.com/GeiserX")
                Divider().background(Theme.divider)
                LinkRow(icon: "doc.text", title: "Source Code", subtitle: "VPN Bypass", url: "https://github.com/GeiserX/VPN-Bypass")
                Divider().background(Theme.divider)
                LinkRow(icon: "exclamationmark.bubble", title: "Report Issue", subtitle: "GitHub Issues", url: "https://github.com/GeiserX/VPN-Bypass/issues")
            }
        }
    }
    
    private var licenseSection: some View {
        SettingsCard(title: "License", icon: "doc.badge.gearshape", iconColor: Theme.warning) {
            VStack(alignment: .leading, spacing: 8) {
                Text("GPL-3.0 License")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                Text("This software is free and open source under the GNU General Public License v3.0. You are free to use, modify, and distribute it under the same license terms.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)

                Text("© 2026 Sergio Fernández (GeiserX)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Info Tab Components

struct LinkButton: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color
    let url: String
    
    var body: some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(color == Theme.buyMeACoffee ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct LinkRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let url: String
    
    var body: some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.blue)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LogRow: View {
    let entry: RouteManager.LogEntry
    /// The search term to mark in the message; empty marks nothing.
    var highlight: String = ""

    private var message: AttributedString {
        var text = AttributedString(entry.message)
        for range in LogFilter.ranges(of: highlight, in: entry.message) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].backgroundColor = Color(hex: "FACC15").opacity(0.35)
        }
        return text
    }
    
    private var levelColor: Color {
        switch entry.level {
        case .info: return Theme.textTertiary
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .error: return Theme.error
        }
    }
    
    private var levelIcon: String {
        switch entry.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: levelIcon)
                .font(.system(size: 10))
                .foregroundColor(levelColor)
            
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 70, alignment: .leading)
            
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// The Logs page's search field: a native NSSearchField, with its magnifier and clear button.
struct LogSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func searchFieldDidEndSearching(_ field: NSSearchField) {
            text.wrappedValue = ""
        }
    }
}

// MARK: - Settings Window Controller

/// The page the Settings window should show next. Set before the window opens or while it is
/// open; the window takes it and clears it.
@MainActor
final class SettingsPageRequest: ObservableObject {
    static let shared = SettingsPageRequest()
    @Published var page: SettingsView.SettingsTab?
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    /// The open window's undo line, dropped when the window closes.
    private var settingsUndo: SettingsUndo?

    /// Shows the window, on `page` when one is given.
    func show(page: SettingsView.SettingsTab? = nil) {
        if let page { SettingsPageRequest.shared.page = page }
        showWindow()
    }

    private func showWindow() {
        // If window exists (visible, minimized, or offscreen), reuse it
        if let window = window {
            NSApp.setActivationPolicy(.regular)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsUndo = SettingsUndo()
        let window = Self.makeWindow(settingsUndo: settingsUndo)
        window.delegate = self
        self.settingsUndo = settingsUndo

        // Show Dock icon so minimize works
        NSApp.setActivationPolicy(.regular)

        // Bring to front (normal level — not floating/screenSaver)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    /// The Settings window, built without showing it. The title bar's Mode menu and the
    /// content's mode sheet share one `ModeSwitchRequest`.
    static func makeWindow(settingsUndo: SettingsUndo? = nil) -> NSWindow {
        let modeSwitch = ModeSwitchRequest()
        let settingsView = SettingsView()
            .environmentObject(RouteManager.shared)
            .environmentObject(NotificationManager.shared)
            .environmentObject(LaunchAtLoginManager.shared)
            .environmentObject(modeSwitch)
            .environmentObject(settingsUndo ?? SettingsUndo())
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = "VPN Bypass"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Theme.bgPrimary)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 580, height: 680)
        window.contentMaxSize = NSSize(width: 580, height: 680)
        window.center()

        // Branded title bar, with the Mode menu at its right end
        addBrandedTitlebar(to: window, modeSwitch: modeSwitch)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        settingsUndo?.clear()
        settingsUndo = nil
        // Hide Dock icon when settings window closes
        NSApp.setActivationPolicy(.accessory)
    }

    private static func addBrandedTitlebar(to window: NSWindow, modeSwitch: ModeSwitchRequest) {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: window.frame.width, height: 28))

        let titleView = NSHostingView(rootView: BrandedTitlebarView()
            .environmentObject(RouteManager.shared)
            .environmentObject(modeSwitch))
        titleView.frame = containerView.bounds
        titleView.autoresizingMask = [.width, .height]
        containerView.addSubview(titleView)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = containerView
        accessory.layoutAttribute = .right

        window.addTitlebarAccessoryViewController(accessory)
    }
}

// MARK: - Branded Titlebar View

struct BrandedTitlebarView: View {
    var body: some View {
        ZStack {
            brand
            HStack {
                Spacer()
                RoutingModeTitlebarButton()
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var brand: some View {
        HStack {
            Spacer()

            // The FLAT mark, tinted — not the squircle app icon scaled to 18px, which turns to
            // mud at that size because its gradient ground and rounded shape carry no detail
            // there. The title bar is exactly what the template glyph is drawn for.
            HStack(spacing: 7) {
                if let mark = Bundle.main.image(forResource: "menubar-icon-active") {
                    Image(nsImage: mark)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                        .foregroundColor(Theme.Brand.sky)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Brand.sky)
                }

                BrandedAppName(fontSize: 13)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
