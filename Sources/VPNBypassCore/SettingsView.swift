// SettingsView.swift
// The Settings window: a sidebar (SettingsSidebar.swift) with Status, Domains, Services, Rules,
// Routes, Lookups, Logs, General and About, and the page picked in it.

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    /// The mode picked in the sidebar's mode popup or a read-only page's Switch…; set, it opens the sheet.
    @EnvironmentObject var modeSwitch: ModeSwitchRequest
    /// The last delete or bulk switch, which the page that made it offers to undo.
    @EnvironmentObject var settingsUndo: SettingsUndo
    @Environment(\.undoManager) private var undoManager
    /// Opens on the page shown last time the window was open.
    @State private var selectedTab = SettingsSidebar.restoredPage(UserDefaults.standard.string(forKey: SettingsSidebar.lastPageKey))
    /// The title bar search on a list page; emptied when the page changes.
    @State private var searchText = SettingsView.searchForScreenshots ?? ""
    /// The search a page asked for from outside opens with, set once the page has changed.
    @State private var pendingSearch: String?
    /// The doc screenshots open each page with this in the search.
    static var searchForScreenshots: String?
    /// What the Logs page shows when it opens: All, or Warnings after the Status page's Show in Log.
    @State private var logsFilter = LogFilter()
    /// Bumped when a filter is asked for from outside, so a Logs page already open takes it.
    @State private var logsFilterRequest = 0

    // MARK: - Page model

    enum SettingsTab: String, Hashable, CaseIterable {
        case status, domains, services, rules, routes, lookups, general, logs, about

        /// The page's name, also the window's title.
        var name: String { name(in: .main) }

        func name(in bundle: Bundle) -> String {
            switch self {
            case .status:   return String(localized: "Status", bundle: bundle)
            case .domains:  return String(localized: "Domains", bundle: bundle)
            case .services: return String(localized: "Services", bundle: bundle)
            case .rules:    return String(localized: "Rules", bundle: bundle)
            case .routes:   return String(localized: "Routes", bundle: bundle)
            case .lookups:  return String(localized: "Lookups", bundle: bundle)
            case .general:  return String(localized: "General", bundle: bundle)
            case .logs:     return String(localized: "Logs", bundle: bundle)
            case .about:    return String(localized: "About", bundle: bundle)
            }
        }

        var icon: String {
            switch self {
            case .status:   return "waveform.path.ecg.rectangle"
            case .domains:  return "globe"
            case .services: return "square.grid.2x2"
            case .rules:    return "list.bullet"
            case .routes:   return "arrow.triangle.branch"
            case .lookups:  return "magnifyingglass"
            case .general:  return "slider.horizontal.3"
            case .logs:     return "list.bullet.rectangle"
            case .about:    return "info.circle"
            }
        }
    }

    private var mode: RoutingMode { routeManager.config.routingMode }

    var body: some View {
        // The title bar's height is the top safe area (28 pt, 32 on macOS 26). The sidebar and
        // the page header both start in it, level with the traffic lights.
        GeometryReader { proxy in
            let titleBar = max(proxy.safeAreaInsets.top, 28)
            HStack(spacing: 0) {
                SettingsSidebarView(selection: $selectedTab, topInset: titleBar)
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1)
                detail(titleBar: titleBar)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(WindowTitleSetter(title: selectedTab.name))
        .onAppear {
            settingsUndo.undoManager = undoManager
        }
        // The page stays where it is; a page of the old mode turns read-only.
        .onChange(of: routeManager.config.routingMode) { _ in
            // The change was made to another mode's list, which this page no longer edits.
            settingsUndo.clear()
        }
        // The line belongs to the page that made the change.
        .onChange(of: selectedTab) { tab in
            settingsUndo.clear()
            searchText = pendingSearch ?? Self.searchForScreenshots ?? ""
            pendingSearch = nil
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsSidebar.lastPageKey)
            // The Logs filter resets when the page is left, as it always has.
            if tab != .logs { logsFilter = LogFilter() }
        }
        // A page asked for from outside, such as the dropdown's "All N services…" row. The
        // publisher sends its current value on subscribe, so a fresh window opens on it too.
        .onReceive(SettingsPageRequest.shared.$page) { page in
            guard let page else { return }
            SettingsPageRequest.shared.page = nil
            if let filter = SettingsPageRequest.shared.logFilter {
                SettingsPageRequest.shared.logFilter = nil
                logsFilter = filter
                logsFilterRequest += 1
            }
            let search = SettingsPageRequest.shared.search
            SettingsPageRequest.shared.search = nil
            // Changing page clears the search, so a search for another page waits for it.
            if page == selectedTab {
                if let search { searchText = search }
            } else {
                pendingSearch = search
            }
            selectedTab = page
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

    /// The page: its name and, on a list page, the search field, both in the title bar row
    /// level with the traffic lights, then the page itself in the one scroll view of the window.
    private func detail(titleBar: CGFloat) -> some View {
        VStack(spacing: 0) {
            PageHeader(
                title: selectedTab.name,
                subtitle: nil,
                search: SettingsSidebar.isSearchable(selectedTab) ? $searchText : nil
            )
            .padding(.horizontal, Theme.Space.page)
            .frame(height: titleBar)
            .padding(.bottom, Theme.Space.m)

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if let line = SettingsSidebar.readOnlyLine(selectedTab, in: mode),
                       let target = SettingsSidebar.switchTarget(for: selectedTab) {
                        ReadOnlyPageLine(text: line, target: target) {
                            modeSwitch.pickedMode = RoutingModeCopy.sheetSelection(forPick: target, current: mode)
                        }
                    }
                    // Dimmed as well as disabled: the page's own toggles keep their colours
                    // when disabled, so they would still look live.
                    page
                        .disabled(SettingsSidebar.isReadOnly(selectedTab, in: mode))
                        .opacity(SettingsSidebar.isReadOnly(selectedTab, in: mode) ? 0.55 : 1)
                        .environment(\.settingsSearch, searchText)
                }
                .padding(Theme.Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .status:
            StatusTab(onShowWarnings: {
                logsFilter = LogFilter(level: .warnings)
                selectedTab = .logs
            }, onShowLogs: {
                logsFilter = LogFilter()
                selectedTab = .logs
            })
        case .domains:  DomainsTab()
        case .services: ServicesTab()
        case .rules:    RulesTab()
        case .routes:   RoutesTab()
        case .lookups:  LookupsTab()
        case .general:  GeneralTab()
        case .logs:     LogsTab(filter: logsFilter).id(logsFilterRequest)
        case .about:    AboutTab()
        }
    }
}

// MARK: - Add feedback (Domains page in DomainsPage.swift)

/// The line under the Domains page's add row: what the last add saved, or why it saved
/// nothing. A failed add keeps the text so it can be fixed; a saved one empties the field.
struct AddDomainFeedback: Equatable {
    let isError: Bool
    let message: String
    /// The field's text while this line shows. Typing something else clears the line.
    let fieldText: String

    /// A refusal from another form that shows the same line, such as a taken service name.
    init(refusal message: String, typed: String) {
        isError = true
        self.message = message
        fieldText = typed
    }

    /// A save from another form, such as a name added to a service.
    init(success message: String) {
        isError = false
        self.message = message
        fieldText = ""
    }

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
        .accessibilityLabel(String(localized: "Turn all on or off"))
    }
}

// MARK: - Custom Service Editor

struct CustomServiceEditor: View {
    @EnvironmentObject var routeManager: RouteManager
    @Environment(\.dismiss) private var dismiss
    let service: RouteManager.ServiceEntry?

    @State private var serviceName: String
    @State private var domains: [String] = [""]
    @State private var ipRanges: [String] = []

    /// `name` seeds the Service Name field of a new service, for a rendered screenshot.
    init(service: RouteManager.ServiceEntry?, name: String = "") {
        self.service = service
        _serviceName = State(initialValue: service?.name ?? name)
        if let service {
            _domains = State(initialValue: service.domains.isEmpty ? [""] : service.domains)
            _ipRanges = State(initialValue: service.ipRanges)
        }
    }

    /// Past this many rows the Domains and IP Ranges fields scroll, so a long service keeps
    /// the sheet on screen and its buttons in reach.
    static let rowsBeforeScrolling = 8

    private var isEditing: Bool { service != nil }

    /// The service or Bypass list entry the typed name would share its routes with.
    private var nameClash: ServiceNameClash? {
        routeManager.customServiceNameClash(serviceName, excluding: service?.id)
    }

    private var canSave: Bool {
        !serviceName.trimmingCharacters(in: .whitespaces).isEmpty &&
        nameClash == nil &&
        domains.contains(where: { isValidDomainInput($0) })
    }

    private func isValidDomainInput(_ input: String) -> Bool {
        let cleaned = routeManager.cleanDomain(input)
        guard !cleaned.isEmpty else { return false }
        let parts = cleaned.components(separatedBy: ".")
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        SheetScaffold(isEditing ? String(localized: "Edit Service") : String(localized: "Create Custom Service"),
                      confirmTitle: isEditing ? String(localized: "Save Changes") : String(localized: "Create Service"),
                      canConfirm: canSave,
                      onCancel: { dismiss() }, onConfirm: { if save() { dismiss() } }) {
            SheetField(String(localized: "Service Name")) {
                TextField("e.g. My Service", text: $serviceName)
                    .textFieldStyle(.roundedBorder)
                if let nameClash {
                    AddDomainFeedbackLine(feedback: AddDomainFeedback(refusal: nameClash.message, typed: serviceName))
                }
            }

            if domains.count + ipRanges.count > Self.rowsBeforeScrolling {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) { listFields }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, Theme.Space.m)
                }
                .frame(height: 340)
            } else {
                listFields
            }
        }
    }

    @ViewBuilder
    private var listFields: some View {
        SheetField(String(localized: "Domains")) {
            ForEach(domains.indices, id: \.self) { index in
                HStack(spacing: Theme.Space.s) {
                    TextField("example.com", text: $domains[index])
                        .textFieldStyle(.roundedBorder)
                    if domains.count > 1 {
                        removeButton(name: domains[index]) { domains.remove(at: index) }
                    }
                }
            }
            addButton { domains.append("") }
        }

        SheetField(String(localized: "IP Ranges (optional)")) {
            ForEach(ipRanges.indices, id: \.self) { index in
                HStack(spacing: Theme.Space.s) {
                    TextField("10.0.0.0/8", text: $ipRanges[index])
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Font.mono)
                    removeButton(name: ipRanges[index]) { ipRanges.remove(at: index) }
                }
            }
            Text(ipRanges.isEmpty
                 ? "No IP ranges added. Only domain-based routing will be used."
                 : "CIDR notation, e.g. 192.168.1.0/24")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
            addButton { ipRanges.append("") }
        }
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Add")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.accentText)
        }
        .buttonStyle(.plain)
    }

    private func removeButton(name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(ControlNames.delete(name))
        .accessibilityLabel(ControlNames.delete(name))
    }

    /// False when the service was refused and nothing saved; the field then says why.
    private func save() -> Bool {
        let cleanDomains = domains
            .map { routeManager.cleanDomain($0) }
            .filter { isValidDomainInput($0) }
        let cleanIPs = ipRanges.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name = serviceName.trimmingCharacters(in: .whitespaces)

        let clash: ServiceNameClash?
        if let service {
            clash = routeManager.updateCustomService(id: service.id, name: name, domains: cleanDomains, ipRanges: cleanIPs)
        } else {
            clash = routeManager.addCustomService(name: name, domains: cleanDomains, ipRanges: cleanIPs)
        }
        return clash == nil
    }
}

// MARK: - Logs Tab

struct LogsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    /// The title bar search (⌘F), the page's search term.
    @Environment(\.settingsSearch) private var search
    @State private var filter: LogFilter

    init(filter: LogFilter = LogFilter()) {
        _filter = State(initialValue: filter)
    }

    /// The filter the page applies: its level and source, and the title bar's search.
    static func effectiveFilter(_ filter: LogFilter, search: String) -> LogFilter {
        var effective = filter
        effective.query = search
        return effective
    }

    var body: some View {
        let filter = Self.effectiveFilter(self.filter, search: search)
        let shown = filter.apply(routeManager.recentLogs)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if routeManager.recentLogs.isEmpty {
                GroupSection {
                    EmptyState(systemImage: "doc.text",
                               title: String(localized: "No activity yet"),
                               message: String(localized: "Logs will appear here when routes are applied"))
                }
            } else {
                filterBar(filter, shown: shown)

                GroupSection {
                    if let empty = filter.emptyLine(shown: shown.count) {
                        Text(empty)
                            .font(Theme.Font.body)
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Theme.Space.page)
                    } else {
                        // The window's scroll view scrolls the lines; the page has none of its own.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { log in
                                LogRow(entry: log, highlight: filter.term)
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
            }
        }
    }

    /// Shown while only the control socket's lines show (proposal 15 of #119); a click shows
    /// every line again.
    private var sourceToken: some View {
        Button {
            filter.onlySource = nil
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: filter.sourceToken.symbol)
                Text(filter.sourceToken.title)
                Image(systemName: "xmark.circle.fill")
            }
            .font(Theme.Font.detail)
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgDisabled))
        }
        .buttonStyle(.plain)
        .help(LogFilter.sourceTokenHelp)
    }

    /// The page's top line: the level filter, how many entries show, and Copy and Clear. The
    /// search is the title bar's.
    private func filterBar(_ filter: LogFilter, shown: [RouteManager.LogEntry]) -> some View {
        HStack(spacing: Theme.Space.m) {
            Picker(LogLevelFilter.controlName, selection: $filter.level) {
                ForEach(LogLevelFilter.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(LogLevelFilter.controlHelp)
            .accessibilityLabel(LogLevelFilter.controlName)

            Text(filter.countLine(shown: shown.count, total: routeManager.recentLogs.count))
                .font(Theme.Font.detail)
                .monospacedDigit()
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            if filter.onlySource != nil {
                sourceToken
            }

            Spacer(minLength: 0)

            Button(String(localized: "Copy")) {
                copyLogsToClipboard(shown)
            }
            .disabled(shown.isEmpty)
            .help(String(localized: "Copy the entries shown"))

            Button(String(localized: "Clear")) {
                withAnimation { routeManager.recentLogs.removeAll() }
            }
            .help(String(localized: "Remove every entry, including any the filter hides"))
        }
        .controlSize(.small)
    }

    private func copyLogsToClipboard(_ entries: [RouteManager.LogEntry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogFilter.clipboardText(entries), forType: .string)
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
            text[lower..<upper].backgroundColor = Theme.attention.opacity(0.35)
        }
        return text
    }

    /// Colour only for what needs a look: amber for a warning, red for an error. Green is for
    /// live routing, so a success line is grey like the rest.
    static func levelColor(_ level: RouteManager.LogEntry.LogLevel) -> Color {
        switch level {
        case .info, .success: return Theme.textSecondary
        case .warning: return Theme.attention
        case .error: return Theme.failure
        }
    }

    /// The level as VoiceOver says it, so a warning or an error does not sound like an info line.
    static func levelName(_ level: RouteManager.LogEntry.LogLevel, bundle: Bundle = .main) -> String {
        switch level {
        case .info: return String(localized: "Info", bundle: bundle)
        case .success: return String(localized: "Success", bundle: bundle)
        case .warning: return String(localized: "Warning", bundle: bundle)
        case .error: return String(localized: "Error", bundle: bundle)
        }
    }

    static func levelIcon(_ level: RouteManager.LogEntry.LogLevel) -> String {
        switch level {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: Self.levelIcon(entry.level))
                .font(.system(size: 10))
                .foregroundColor(Self.levelColor(entry.level))
                .frame(width: ListRow.glyphColumn)
                .accessibilityLabel(Self.levelName(entry.level))

            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(Theme.Font.mono)
                .monospacedDigit()
                .foregroundColor(Theme.textSecondary)
                .fixedSize()

            Text(message)
                .font(Theme.Font.mono)
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if let tag = entry.source.tag {
                Text(tag)
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(entry.source.helpText)
            }
        }
        .padding(.horizontal, ListRow.inset)
        .padding(.vertical, 5)
        .help(entry.message)
    }
}

/// A native NSSearchField, with its magnifier and clear button (the Lookups add panel's service search).
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

// MARK: - Search

/// What a list page shows when the title bar search leaves none of its rows.
struct SettingsSearchMiss: View {
    let search: String

    var body: some View {
        Text(String(localized: "Nothing on this page matches \u{201C}\(search)\u{201D}."))
            .font(Theme.Font.body)
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Theme.Space.l)
    }
}

// MARK: - Settings Window Controller

/// The page the Settings window should show next. Set before the window opens or while it is
/// open; the window takes it and clears it.
@MainActor
final class SettingsPageRequest: ObservableObject {
    static let shared = SettingsPageRequest()
    @Published var page: SettingsView.SettingsTab?
    /// The filter the Logs page opens with, read together with `page`.
    var logFilter: LogFilter?
    /// The Services page opens its catalogue sheet; the page takes it and clears it.
    @Published var openCatalogue = false
    /// The country the catalogue sheet opens on, read together with `openCatalogue`.
    var catalogueRegion: String?
    /// The title bar search the page opens with, read together with `page`: the dropdown's
    /// Show in Settings opens the page filtered to the row's entry.
    var search: String?
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    /// The open window's undo line, dropped when the window closes.
    private var settingsUndo: SettingsUndo?

    /// The window is open on screen (not closed, not minimized).
    var isShown: Bool { window?.isVisible == true && window?.isMiniaturized == false }

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

    /// The window's size when it first opens, and the smallest it can be made.
    static let defaultContentSize = NSSize(width: 860, height: 620)
    static let minimumContentSize = NSSize(width: 720, height: 480)

    /// The Settings window, built without showing it. The sidebar's mode popup and the
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
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = "VPN Bypass"
        window.titlebarAppearsTransparent = true
        // The page header draws the page name; the window keeps it as its title for the
        // Window menu, Mission Control and VoiceOver (`WindowTitleSetter`).
        window.titleVisibility = .hidden
        // No toolbar: a toolbar's title view would take the clicks meant for the search field
        // drawn under it. The page header sits in the transparent title bar instead.
        window.backgroundColor = NSColor(Theme.bgPrimary)
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumContentSize
        window.center()
        // A size the user gave the window comes back next time.
        window.setFrameAutosaveName("VPNBypassSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        settingsUndo?.clear()
        settingsUndo = nil
        // Hide Dock icon when settings window closes
        NSApp.setActivationPolicy(.accessory)
    }
}

