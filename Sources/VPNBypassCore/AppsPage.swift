// AppsPage.swift
// Settings > Apps: Bypass mode's Apps list (BypassApps.swift). Apps are added from a chooser of
// the running apps and those in the Applications folders; each row shows the app's icon, name and
// signing identifier, a switch and a remove with undo. Per-app routing serves the list; while it
// does not, the page says so above the list and the apps keep using the VPN.

import AppKit
import SwiftUI

/// The Apps page as data, so tests read it without a view.
enum AppsPage {
    static func purpose(in bundle: Bundle = .main) -> String {
        String(localized: "The apps on this list skip the VPN, through per-app routing.", bundle: bundle)
    }

    struct Row: Equatable, Identifiable {
        let app: BypassApp
        /// The signing identifier (unless it is the row's name already), then the counts while
        /// per-app routing serves the app.
        let detail: String?
        let isServed: Bool
        var id: UUID { app.id }
    }

    /// The rows the search leaves. `counters` reads a rule id's counts from the extension's
    /// last reply; an entry's rule id is its own id.
    /// `turnedDown` (`BypassApps.isTurnedDown`) marks an entry the extension declines: its row
    /// says so, whatever the engine does.
    static func rows(_ apps: [BypassApp], engine: FlowEngineState, listIsLive: Bool, search: String,
                     counters: (String) -> FlowEngineRuleCounters? = { _ in nil },
                     turnedDown: (BypassApp) -> Bool = { _ in false },
                     bundle: Bundle = .main) -> [Row] {
        apps.filter { SettingsSidebar.matches($0.displayName, search: search) || SettingsSidebar.matches($0.pattern, search: search) }
            .map { app in
                let serving = BypassAppServing.serving(app, engine: engine, listIsLive: listIsLive, turnedDown: turnedDown(app))
                let served = serving.servedBy == .perAppEngine
                var parts = app.displayName == app.pattern ? [] : [app.pattern]
                if serving.reason == .vpnClientApp {
                    parts.append(ProcessRule.rowNote(.vpnClientApp, in: bundle))
                } else if served {
                    let c = counters(app.id.uuidString)
                    parts.append(ProcessRule.rowNote(nil, claimed: c?.claimed ?? 0, bound: c?.bound ?? 0, in: bundle))
                }
                let detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
                return Row(app: app, detail: detail, isServed: served)
            }
    }

    /// The line above the list while per-app routing does not serve it, or nil while it does. In
    /// another mode the page is read-only and its own line says so, so this says nothing more.
    static func notice(engine: FlowEngineState, listIsLive: Bool, bundle: Bundle = .main) -> String? {
        guard listIsLive else { return nil }
        switch engine {
        case .active:
            return nil
        case .off:
            return String(localized: "Per-app routing is off, so the apps on this list still use the VPN. Turn it on in General to let them skip it.", bundle: bundle)
        default:
            return String(localized: "Until per-app routing is active, the apps on this list use the VPN.", bundle: bundle)
                + " " + engine.line(in: bundle)
        }
    }

    /// The notice offers the way to General, except where nothing there can change it.
    static func offersSettings(_ engine: FlowEngineState) -> Bool {
        if case .unavailable = engine { return false }
        return engine != .active
    }
}

struct AppsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var settingsUndo: SettingsUndo
    @ObservedObject private var engine = FlowEngineManager.shared
    @Environment(\.settingsSearch) private var searchText
    @State private var showingChooser = AppsTab.chooserForScreenshots
    /// Why the last pick was refused.
    @State private var refusal: String?

    /// The doc screenshots open the chooser on this list.
    static var chooserForScreenshots = false
    /// The doc screenshots draw this app's row as if the pointer were on it.
    static var hoveredForScreenshots: String?

    private var listIsLive: Bool { BypassAppServing.listIsLive(routeManager.config) }

    var body: some View {
        let apps = routeManager.config.bypassApps
        let declined = engine.confirmed?.declinedTeams ?? []
        let rows = AppsPage.rows(apps, engine: engine.state, listIsLive: listIsLive, search: searchText,
                                 counters: { engine.counters(forRule: $0) },
                                 turnedDown: { BypassApps.isTurnedDown($0, declinedTeams: declined) })
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let notice = AppsPage.notice(engine: engine.state, listIsLive: listIsLive) {
                noticeLine(notice)
            }
            GroupSection(String(localized: "Apps list")) {
                if apps.isEmpty {
                    EmptyState(systemImage: "app.badge",
                               title: String(localized: "No apps yet"),
                               message: String(localized: "Add an app to let it skip the VPN."),
                               primary: .init(title: String(localized: "Add App…")) { showingChooser = true })
                } else if rows.isEmpty {
                    SettingsSearchMiss(search: searchText)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { InsetDivider() }
                        ListRow(glyph: "app", name: row.app.displayName, detail: row.detail,
                                icon: BypassApps.icon(row.app),
                                actions: [RowAction.delete(row.app.displayName) { remove(row.app) }],
                                isOn: Binding(get: { row.app.enabled },
                                              set: { routeManager.setBypassAppEnabled(row.app.id, $0) }),
                                showsActions: Self.hoveredForScreenshots == row.app.pattern,
                                detailLineLimit: nil)
                    }
                }
            }
            if let refusal {
                AddDomainFeedbackLine(feedback: AddDomainFeedback(refusal: refusal, typed: ""))
            }
            if let change = settingsUndo.last, change.page == .apps {
                UndoLine(message: change.message) { settingsUndo.undoLast() }
            }
        }
        .pageTitleActions([.add(String(localized: "Add App…")) { showingChooser = true }])
        .onChange(of: apps.map(\.pattern)) { _ in refusal = nil }
        .sheet(isPresented: $showingChooser) {
            AppChooserSheet(listed: apps, onCancel: { showingChooser = false }, onPick: { pick in
                showingChooser = false
                switch pick {
                case .app(let candidate): add(candidate)
                case .name(let name): add(name)
                }
            })
        }
    }

    private func noticeLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .foregroundColor(Theme.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(text)
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if AppsPage.offersSettings(engine.state) {
                    Button(String(localized: "Per-App Routing Settings…")) {
                        SettingsPageRequest.shared.page = .general
                    }
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Open the per-app routing settings in General"))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func remove(_ app: BypassApp) {
        withAnimation(.easeOut(duration: 0.2)) {
            guard let removed = routeManager.removeBypassApp(app.id) else { return }
            settingsUndo.record(.bypassApp(removed.app, index: removed.index))
        }
    }

    private func add(_ candidate: BypassApps.Candidate) {
        let identity = BypassApps.identity(ofAppAt: candidate.url)
            ?? AppIdentity(name: candidate.name, signingID: candidate.bundleID, team: nil, bundleID: candidate.bundleID)
        switch routeManager.addBypassApp(identity.signingID, identity: identity) {
        case .failure(let error): refusal = error.localizedMessage()
        case .success: refusal = nil
        }
    }

    /// An executable name (or a bundle id) typed in the chooser: added as `vpnb app.add` adds it.
    private func add(_ name: String) {
        switch routeManager.addBypassApp(name) {
        case .failure(let error): refusal = error.localizedMessage()
        case .success: refusal = nil
        }
    }
}

/// The chooser: the running apps, then those in the Applications folders, with a search, and a
/// field for an executable name (a command-line tool has no app to pick).
struct AppChooserSheet: View {
    let listed: [BypassApp]
    var title = String(localized: "Add an App")
    var confirmTitle = String(localized: "Add")
    let onCancel: () -> Void
    let onPick: (Pick) -> Void

    /// What the chooser hands back: an app from the list, or a name typed in the field.
    enum Pick: Equatable {
        case app(BypassApps.Candidate)
        case name(String)
    }

    /// The doc screenshots fill the chooser with these instead of the Mac's apps.
    static var candidatesForScreenshots: [BypassApps.Candidate]?
    /// The doc screenshots draw this app picked.
    static var pickedForScreenshots: String?
    /// The doc screenshots type this in the name field.
    static var typedForScreenshots = ""

    @State private var candidates: [BypassApps.Candidate]? = AppChooserSheet.candidatesForScreenshots
    @State private var search = ""
    @State private var picked: String? = AppChooserSheet.pickedForScreenshots
    @State private var typed = AppChooserSheet.typedForScreenshots
    @FocusState private var isSearchFocused: Bool

    /// The pick the confirm button hands back: a typed name wins over a row, since typing
    /// clears the row and picking a row clears the name. Nil while the name is not one a rule
    /// can match (`ProcessRule.invalid`) or nothing is picked.
    static func pick(row: BypassApps.Candidate?, typed: String) -> Pick? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return ProcessRule.invalid(name) == nil ? .name(name) : nil }
        return row.map(Pick.app)
    }

    /// The line under the name field while what is typed cannot be matched; nil otherwise.
    static func typedError(_ typed: String, in bundle: Bundle = .main) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, ProcessRule.invalid(name) != nil else { return nil }
        return ProcessRule.localizedMessage(in: bundle)
    }

    var body: some View {
        let shown = BypassApps.filter(candidates ?? [], search: search)
        let row = shown.first { $0.bundleID == picked }
        let pick = Self.pick(row: row, typed: typed)
        SheetScaffold(title, confirmTitle: confirmTitle,
                      canConfirm: pick != nil, onCancel: onCancel, onConfirm: { if let pick { onPick(pick) } }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "Search by name or bundle ID"), text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .accessibilityLabel(String(localized: "Search by name or bundle ID"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.bgInput)
            .cornerRadius(8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if candidates == nil {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.l)
                            .accessibilityLabel(String(localized: "Looking for apps…"))
                    } else if shown.isEmpty {
                        Text(String(localized: "No app matches."))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.l)
                    } else {
                        section(String(localized: "Running"), shown.filter(\.isRunning))
                        section(String(localized: "Applications"), shown.filter { !$0.isRunning })
                    }
                }
            }
            .frame(height: 260)

            SheetField(String(localized: "Or an executable name")) {
                TextField(String(localized: "Example"), text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.body)
                    .accessibilityLabel(String(localized: "Executable name"))
                    .help(String(localized: "For a program with no app to pick, such as a command-line tool: the last part of its path."))
                    .onChange(of: typed) { value in
                        if !value.isEmpty { picked = nil }
                    }
            }
            if let error = Self.typedError(typed) {
                SheetError(message: error)
            }
        }
        .frame(width: SheetScaffold<EmptyView>.width)
        .task {
            isSearchFocused = true
            guard candidates == nil else { return }
            candidates = await BypassApps.loadCandidates(listed: listed)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [BypassApps.Candidate]) -> some View {
        if !list.isEmpty {
            Text(title)
                .font(Theme.Font.section)
                .foregroundColor(Theme.textSecondary)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.xs)
                .accessibilityAddTraits(.isHeader)
            ForEach(list) { candidate in
                row(candidate)
            }
        }
    }

    private func row(_ c: BypassApps.Candidate) -> some View {
        let selected = picked == c.bundleID
        return Button {
            picked = c.bundleID
            typed = ""
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(nsImage: AppChooserSheet.icon(c))
                    .resizable()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name)
                        .font(Theme.Font.body)
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text(c.bundleID)
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(c.name), \(c.bundleID)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The app's icon; a seam for the screenshots, whose apps are not on the Mac.
    static var icon: (BypassApps.Candidate) -> NSImage = { NSWorkspace.shared.icon(forFile: $0.url.path) }
}
