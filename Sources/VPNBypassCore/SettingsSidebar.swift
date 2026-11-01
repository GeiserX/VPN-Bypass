// SettingsSidebar.swift
// The Settings window's shell (section 3.2 B of docs/design/APP-REWORK-PROPOSALS.md): a sidebar
// that lists every page in every mode, the mode popup at its top, and the line a page of
// another mode opens with. A mode change only greys other items; no page moves or vanishes.

import AppKit
import SwiftUI

// MARK: - Model

/// Which pages the sidebar shows, in which group, and what each mode makes of them. Pure, so
/// the rules are unit-tested.
enum SettingsSidebar {
    typealias Page = SettingsView.SettingsTab

    struct Group: Equatable {
        enum Kind: Equatable { case top, routing, insight, app }
        let kind: Kind
        let pages: [Page]

        /// The group's heading; the top group (Status) has none.
        func title(in bundle: Bundle = .main) -> String? {
            switch kind {
            case .top: return nil
            case .routing: return String(localized: "Routing", bundle: bundle)
            case .insight: return String(localized: "Insight", bundle: bundle)
            case .app: return String(localized: "App", bundle: bundle)
            }
        }
    }

    /// The same groups in every mode.
    static let groups: [Group] = [
        Group(kind: .top, pages: [.status]),
        Group(kind: .routing, pages: [.domains, .services, .rules, .routes]),
        Group(kind: .insight, pages: [.lookups, .logs]),
        Group(kind: .app, pages: [.general, .about]),
    ]

    static var pages: [Page] { groups.flatMap(\.pages) }

    /// The modes whose routing a page edits; nil for a page that works the same in every mode.
    static func modes(of page: Page) -> [RoutingMode]? {
        switch page {
        case .domains: return [.bypass, .vpnOnly]
        case .services: return [.bypass]
        case .rules, .routes: return [.custom]
        case .status, .lookups, .logs, .general, .about: return nil
        }
    }

    /// A page of another mode stays listed, greyed, and opens read-only.
    static func isReadOnly(_ page: Page, in mode: RoutingMode) -> Bool {
        guard let modes = modes(of: page) else { return false }
        return !modes.contains(mode)
    }

    /// The mode Switch… offers from a read-only page: the first mode the page belongs to. The
    /// sheet opens on it, and the user can still pick another before switching.
    static func switchTarget(for page: Page) -> RoutingMode? {
        modes(of: page)?.first
    }

    /// The one line a read-only page opens with: "Rules apply in Custom mode. You are in Bypass."
    static func readOnlyLine(_ page: Page, in mode: RoutingMode, bundle: Bundle = .main) -> String? {
        guard isReadOnly(page, in: mode) else { return nil }
        let current = DropdownModePicker.label(mode, in: bundle)
        switch page {
        case .domains: return String(localized: "Domains apply in Bypass and VPN Only modes. You are in \(current).", bundle: bundle)
        case .services: return String(localized: "Services apply in Bypass mode. You are in \(current).", bundle: bundle)
        case .rules: return String(localized: "Rules apply in Custom mode. You are in \(current).", bundle: bundle)
        case .routes: return String(localized: "Routes apply in Custom mode. You are in \(current).", bundle: bundle)
        case .status, .lookups, .logs, .general, .about: return nil
        }
    }

    /// The list pages and Logs, which get the search field in the title bar (⌘F).
    static func isSearchable(_ page: Page) -> Bool {
        switch page {
        case .domains, .services, .rules, .routes, .lookups, .logs: return true
        case .status, .general, .about: return false
        }
    }

    /// The page ↑ or ↓ moves to from `page`, in the order the sidebar lists them, read-only
    /// pages included (they open read-only). It stops at the first and the last page.
    static func page(after page: Page, movingUp: Bool) -> Page {
        guard let index = pages.firstIndex(of: page) else { return page }
        let next = movingUp ? index - 1 : index + 1
        return pages.indices.contains(next) ? pages[next] : page
    }

    /// Where the last page is kept, so the window reopens on it.
    static let lastPageKey = "settingsLastPage"

    /// The page the window opens on: the one saved last, or Status.
    static func restoredPage(_ saved: String?) -> Page {
        saved.flatMap(Page.init(rawValue:)) ?? .status
    }

    /// A row matches the title bar search when its name contains the text, ignoring case and
    /// accents. An empty search matches every row.
    static func matches(_ name: String, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

// MARK: - Environment

private struct SettingsSearchKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The text in the title bar search, for the list page on screen.
    var settingsSearch: String {
        get { self[SettingsSearchKey.self] }
        set { self[SettingsSearchKey.self] = newValue }
    }
}

// MARK: - Sidebar

/// The sidebar: the mode popup, then Status, then Routing, Insight and App. Items of another
/// mode are grey and italic, and VoiceOver says they are read-only. Drawn with plain views on
/// the window's own ground, so it looks and renders the same on every macOS the app supports.
struct SettingsSidebarView: View {
    static let width: CGFloat = 200

    @EnvironmentObject var routeManager: RouteManager
    @Binding var selection: SettingsView.SettingsTab
    /// The title bar's height: the popup starts under the traffic lights.
    let topInset: CGFloat
    /// The list has the keyboard focus, so ↑ and ↓ change page, as in a native sidebar. A click
    /// on a row gives it the focus; Tab reaches it with full keyboard access.
    @FocusState private var listFocused: Bool

    var body: some View {
        let mode = routeManager.config.routingMode
        VStack(alignment: .leading, spacing: 0) {
            SettingsModePopup()
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, topInset + Theme.Space.s)
                .padding(.bottom, Theme.Space.m)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSidebar.groups, id: \.kind) { group in
                        if let title = group.title() {
                            Text(title)
                                .font(Theme.Font.section)
                                .foregroundColor(Theme.textSecondary)
                                .padding(.horizontal, Theme.Space.s)
                                .padding(.top, Theme.Space.m)
                                .padding(.bottom, Theme.Space.xs)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.pages, id: \.self) { page in
                            SettingsSidebarRow(page: page,
                                               isSelected: page == selection,
                                               isReadOnly: SettingsSidebar.isReadOnly(page, in: mode)) {
                                selection = page
                                listFocused = true
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, Theme.Space.m)
                .sidebarListFocusable()
                .focused($listFocused)
                .sidebarFocusRingHidden()
                .onMoveCommand { direction in
                    switch direction {
                    case .up: selection = SettingsSidebar.page(after: selection, movingUp: true)
                    case .down: selection = SettingsSidebar.page(after: selection, movingUp: false)
                    default: break
                    }
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSecondary)
        // A page opens with the focus on the list, never in the title bar search: on a page of
        // another mode every control is disabled, so the search was the first field to take it.
        .onAppear { listFocused = true }
        .onChange(of: selection) { _ in listFocused = true }
    }
}

/// One page in the sidebar: its glyph and name, the accent ground when it is the page shown.
struct SettingsSidebarRow: View {
    let page: SettingsView.SettingsTab
    let isSelected: Bool
    let isReadOnly: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: page.icon)
                    .frame(width: 18)
                    .foregroundColor(isSelected ? Theme.text : (isReadOnly ? Theme.textTertiary : Theme.textSecondary))
                Text(page.name)
                    .italic(isReadOnly)
                    .foregroundColor(isSelected ? Theme.text : (isReadOnly ? Theme.textTertiary : Theme.text))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.body)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(isSelected ? Theme.accent : (isHovered ? Theme.bgHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(page.name)
        .accessibilityValue(isReadOnly ? String(localized: "Read-only in this mode") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Mode popup

/// "Mode" over a native popup with the three modes, at the top of the sidebar. A pick changes
/// nothing yet: it opens the mode sheet on the picked mode, and the mode changes on Switch. The
/// popup reads the saved mode, so after Cancel it shows the mode in use again.
struct SettingsModePopup: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var modeSwitch: ModeSwitchRequest
    /// Bumped on every pick: the popup shows the picked item itself, and SwiftUI does not push
    /// the unchanged saved mode back into it, so it is rebuilt from the saved mode.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Mode")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
                .accessibilityHidden(true)
            Picker("Mode", selection: Binding(
                get: { routeManager.config.routingMode },
                set: { picked in
                    modeSwitch.pickedMode = RoutingModeCopy.sheetSelection(forPick: picked, current: routeManager.config.routingMode)
                    generation += 1
                }
            )) {
                ForEach(DropdownModePicker.modes, id: \.self) { mode in
                    Text(DropdownModePicker.label(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .id(generation)
            .help(DropdownStatus.modeDescription(DropdownModePicker.copyMode(routeManager.config.routingMode)))
            .accessibilityLabel(String(localized: "Mode"))
        }
    }
}

// MARK: - Read-only line

/// The line at the top of a page of another mode: what mode the page applies in, the mode in
/// use, and Switch…, which opens the mode sheet on the page's mode.
struct ReadOnlyPageLine: View {
    let text: String
    let target: RoutingMode
    let onSwitch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .foregroundColor(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Font.body)
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button(String(localized: "Switch…"), action: onSwitch)
                .accessibilityLabel(String(localized: "Switch to \(DropdownModePicker.label(target))…"))
        }
        .padding(Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.group)
                .fill(Theme.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.group)
                .strokeBorder(Theme.border, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Window title

/// Sets the hosting window's title, which the title bar does not draw (the page header does)
/// but Mission Control, the Window menu and VoiceOver read.
struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { TitleView(title: title) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TitleView)?.title = title
    }

    final class TitleView: NSView {
        var title: String { didSet { window?.title = title } }
        init(title: String) {
            self.title = title
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.title = title
        }
    }
}

private extension View {
    /// The focused list moves with ↑ and ↓; the selected row shows where it is, so the ring
    /// macOS draws around a focusable view would only frame the whole sidebar.
    /// The list takes the focus on a click and from code, as a native sidebar does. A plain
    /// `focusable()` on macOS 14 and later takes it only with full keyboard access on.
    @ViewBuilder func sidebarListFocusable() -> some View {
        if #available(macOS 14.0, *) {
            focusable(true, interactions: .edit)
        } else {
            focusable()
        }
    }

    @ViewBuilder func sidebarFocusRingHidden() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}
