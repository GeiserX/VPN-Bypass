// Components.swift
// The seven shared views of the rework's visual system (section 2 of
// docs/design/APP-REWORK-PROPOSALS.md): GroupSection, ListRow, PageHeader, EmptyState,
// StatusChip, RouteChip and SheetScaffold. Every page that needs one of these jobs uses the
// view here, so the job looks the same everywhere. Built on the tokens in Theme.swift.

import AppKit
import SwiftUI

// MARK: - 1. Group section

/// A `section` label above a box of rows (white 5%, 0.5 pt border, radius 10). Rows inside are
/// divided by an inset hairline: pass the rows as data and the hairlines are drawn for you, or
/// lay them out by hand with `InsetDivider` between them.
struct GroupSection<Content: View, Trailing: View>: View {
    let title: String?
    /// Drawn right after the title, such as a filter chip that belongs to it.
    let titleAccessory: AnyView?
    let trailing: Trailing
    let content: Content

    init(_ title: String? = nil, titleAccessory: AnyView? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.titleAccessory = titleAccessory
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || titleAccessory != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(Theme.Font.section)
                            .foregroundColor(Theme.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let titleAccessory { titleAccessory }
                    Spacer(minLength: Theme.Space.s)
                    trailing
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.group))
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.group)
                    .fill(Theme.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.group)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            )
        }
    }
}

/// The end of a list section's header, the same on Domains and Services: the word
/// "addresses" over the rows' number column, and the section's ⋯ menu (or a spinner while an
/// apply runs) at the trailing edge, over the switches it turns on and off.
struct ListSectionTrailing<Menu: View>: View {
    /// The rows' number column; 0 hides the label, as when no row has a number.
    let numberWidth: CGFloat
    let menu: Menu

    init(numberWidth: CGFloat, @ViewBuilder menu: () -> Menu) {
        self.numberWidth = numberWidth
        self.menu = menu()
    }

    /// From the header's trailing edge to the end of the number column: the small switch
    /// (44 pt measured on the rendered page), the row's spacing and its inset, less the
    /// header's own 2 pt.
    static var labelTrailingPadding: CGFloat { 44 + Theme.Space.s + ListRow.inset - 2 }
    /// From the header's trailing edge to the switches' trailing edge.
    static var menuTrailingPadding: CGFloat { ListRow.inset - 2 }

    var body: some View {
        ZStack(alignment: .trailing) {
            if numberWidth > 0 {
                Text("addresses")
                    .padding(.trailing, Self.labelTrailingPadding)
            }
            menu
                .padding(.trailing, Self.menuTrailingPadding)
        }
    }
}

extension GroupSection where Trailing == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

extension GroupSection {
    /// One row per element, with an inset hairline between two rows and none above the first.
    init<Data: RandomAccessCollection, Row: View>(
        _ title: String? = nil, rows: Data, @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) where Data.Element: Identifiable, Content == ForEach<[(offset: Int, element: Data.Element)], Data.Element.ID, VStack<TupleView<(InsetDivider?, Row)>>> {
        self.init(title, trailing: trailing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, element in
                VStack(spacing: 0) {
                    index > 0 ? InsetDivider() : nil
                    row(element)
                }
            }
        }
    }
}

extension GroupSection where Trailing == EmptyView {
    init<Data: RandomAccessCollection, Row: View>(
        _ title: String? = nil, rows: Data, @ViewBuilder row: @escaping (Data.Element) -> Row
    ) where Data.Element: Identifiable, Content == ForEach<[(offset: Int, element: Data.Element)], Data.Element.ID, VStack<TupleView<(InsetDivider?, Row)>>> {
        self.init(title, rows: rows, trailing: { EmptyView() }, row: row)
    }
}

/// The hairline between two rows of a group box, starting where the row's name starts.
struct InsetDivider: View {
    /// The row inset plus the glyph column and the gap after it.
    static let leading = ListRow.inset + ListRow.glyphColumn + Theme.Space.s

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, Self.leading)
            .padding(.trailing, ListRow.inset)
            .accessibilityHidden(true)
    }
}

// MARK: - 2. List row

/// An action a row offers: shown on hover, listed in the right-click menu, and on a selected
/// row reachable from the keyboard (Return edits, ⌘⌫ deletes).
struct RowAction: Identifiable {
    enum Kind: Equatable {
        case edit, delete, more, other
    }

    let kind: Kind
    /// The spoken name, also the menu item's title: "Edit Telegram", "Delete en.wikipedia.org".
    let name: String
    let systemImage: String
    let perform: () -> Void
    /// Set, the action is a ⋯ button that opens these actions as a menu, and `perform` is unused.
    var menu: [RowAction]? = nil

    var id: String { name }

    /// The actions VoiceOver and a right-click menu offer: a menu action's items in its place.
    static func flattened(_ actions: [RowAction]) -> [RowAction] {
        actions.flatMap { $0.menu ?? [$0] }
    }

    /// The row's keyboard shortcut for this action, when it has one.
    var shortcut: KeyboardShortcut? {
        switch kind {
        case .edit: return KeyboardShortcut(.return, modifiers: [])
        case .delete: return KeyboardShortcut(.delete, modifiers: .command)
        case .more, .other: return nil
        }
    }

    static func edit(_ rowName: String, in bundle: Bundle = .main, perform: @escaping () -> Void) -> RowAction {
        RowAction(kind: .edit, name: ControlNames.edit(rowName, in: bundle), systemImage: "pencil", perform: perform)
    }

    static func delete(_ rowName: String, in bundle: Bundle = .main, perform: @escaping () -> Void) -> RowAction {
        RowAction(kind: .delete, name: ControlNames.delete(rowName, in: bundle), systemImage: "trash", perform: perform)
    }
}

/// The one row of every list: a leading glyph (▲ when the row needs attention), the name at
/// full width truncated in the middle, an optional detail line, the actions while the pointer
/// is over the row, one number in a column as wide as the widest number on screen, and the
/// switch, always last. A problem is said in the detail line, never in a column of words.
struct ListRow: View {
    static let singleLineHeight: CGFloat = 32
    static let twoLineHeight: CGFloat = 44
    static let inset: CGFloat = Theme.Space.m
    static let glyphColumn: CGFloat = 20
    /// The number's font, measured by `numberColumnWidth`.
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    /// The width of the number column for the numbers on screen: the widest one, so every row's
    /// number lines up (the #183 rule from the Lookups page).
    static func numberColumnWidth(for numbers: [String]) -> CGFloat {
        let widest = numbers.map { ($0 as NSString).size(withAttributes: [.font: numberFont]).width }.max() ?? 0
        return widest == 0 ? 0 : ceil(widest) + 1
    }

    /// The glyph a row shows: its own, or ▲ when it needs attention.
    static func leadingGlyph(_ glyph: String, needsAttention: Bool) -> String {
        needsAttention ? "exclamationmark.triangle.fill" : glyph
    }

    /// What VoiceOver says for a count of addresses in the number column: "18 addresses".
    static func addressesLabel(_ number: String?) -> String? {
        number.flatMap { Int($0) }.map(DropdownCopy.addresses)
    }

    let glyph: String
    let name: String
    var detail: String?
    var needsAttention = false
    var number: String?
    /// From `numberColumnWidth(for:)`, the same on every row of the page.
    var numberWidth: CGFloat = 0
    /// What VoiceOver says for the number, with its noun: "18 addresses". Nil reads the bare
    /// number. The column has no heading VoiceOver reads, so a bare number means nothing.
    var numberLabel: String?
    /// The whole row read as one line, the number included, in place of the name, the
    /// detail and the number (the dropdown's rows: "Telegram, 18 addresses").
    var spokenLabel: String?
    var actions: [RowAction] = []
    /// The right-click menu, when it offers more than the hover actions; nil lists `actions`.
    var menuActions: [RowAction]?
    var isOn: Binding<Bool>?
    /// The switch shows but cannot be flipped, such as a built-in service a custom one holds off.
    var isSwitchDisabled = false
    /// A selected row answers Return, ⌘⌫ and Space.
    var isSelected = false
    /// Draws the actions as if the pointer were over the row, for the doc screenshots.
    var showsActions = false
    /// A view between the actions and the number, such as a route chip.
    var accessory: AnyView?
    /// The detail line's most lines; nil lets a sentence wrap as far as it needs.
    var detailLineLimit: Int? = 1
    /// The detail line is an address (`Theme.Font.mono`), cut in the middle when too long.
    var monoDetail = false

    @State private var isHovered = false

    private var actionsVisible: Bool { isHovered || isSelected || showsActions }

    /// What VoiceOver offers in the row's Actions rotor: the right-click menu's items, which
    /// hold every hover action, the ⋯ menu's items in its place.
    var spokenActions: [RowAction] { menuActions ?? RowAction.flattened(actions) }

    /// The value VoiceOver reads after the row's name: the number with its noun.
    var spokenNumber: String? {
        guard spokenLabel == nil, let number, !number.isEmpty else { return nil }
        return numberLabel ?? number
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: Self.leadingGlyph(glyph, needsAttention: needsAttention))
                .font(.system(size: 13))
                .foregroundColor(needsAttention ? Theme.attention : Theme.textSecondary)
                .frame(width: Self.glyphColumn)
                // A row read as one line says its problem in that line.
                .accessibilityHidden(!needsAttention || spokenLabel != nil)
                .accessibilityLabel(String(localized: "Needs attention"))

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(Theme.Font.body)
                    .foregroundColor(isOn?.wrappedValue == false ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(monoDetail ? Theme.Font.mono : Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(detailLineLimit)
                        .truncationMode(monoDetail ? .middle : .tail)
                        .fixedSize(horizontal: false, vertical: detailLineLimit == nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One element for the row: its name and detail, the number as its value, and every
            // action in the rotor. The hover buttons are hidden from VoiceOver while the pointer
            // is elsewhere (opacity 0), so the row carries them instead, on every page.
            .rowElement(spokenLabel: spokenLabel)
            .accessibilityValueIfSet(spokenNumber)
            .accessibilityActions {
                ForEach(spokenActions) { action in
                    Button(action.name, action: action.perform)
                }
            }

            if !actions.isEmpty {
                HStack(spacing: 2) {
                    ForEach(actions) { action in
                        if let menu = action.menu {
                            Menu {
                                ForEach(menu) { item in
                                    Button(item.name, action: item.perform)
                                }
                            } label: {
                                actionGlyph(action)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(action.name)
                            .accessibilityLabel(action.name)
                        } else {
                            Button(action: action.perform) {
                                actionGlyph(action)
                            }
                            .buttonStyle(.plain)
                            .help(action.name)
                            .accessibilityLabel(action.name)
                        }
                    }
                }
                .opacity(actionsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: actionsVisible)
                // The row's rotor has them all; shown here too they would be read twice.
                .accessibilityHidden(true)
            }

            if let accessory {
                accessory
            }

            if numberWidth > 0 {
                Text(number ?? "")
                    .font(SwiftUI.Font(Self.numberFont))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: numberWidth, alignment: .trailing)
                    // Read with the row, as its value.
                    .accessibilityHidden(true)
            }

            if let isOn {
                Toggle(name, isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .disabled(isSwitchDisabled)
            }
        }
        .padding(.horizontal, Self.inset)
        // A detail that wraps grows the row past 44 pt; keep its text off the hairlines.
        .padding(.vertical, detail != nil && detailLineLimit == nil ? Theme.Space.xs + 2 : 0)
        .frame(minHeight: detail == nil ? Self.singleLineHeight : Self.twoLineHeight)
        .background(actionsVisible ? Theme.bgHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            ForEach(menuActions ?? RowAction.flattened(actions)) { action in
                if let shortcut = action.shortcut {
                    Button(action.name, action: action.perform).keyboardShortcut(shortcut)
                } else {
                    Button(action.name, action: action.perform)
                }
            }
        }
        .background {
            if isSelected { selectedRowKeys }
        }
    }

    private func actionGlyph(_ action: RowAction) -> some View {
        Image(systemName: action.systemImage)
            .font(.system(size: 12))
            .foregroundColor(Theme.textSecondary)
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
    }

    /// Hidden buttons that give a selected row its keys, the way the dropdown's footer does.
    @ViewBuilder private var selectedRowKeys: some View {
        ZStack {
            ForEach(actions.filter { $0.shortcut != nil }) { action in
                Button("", action: action.perform).keyboardShortcut(action.shortcut!)
            }
            if let isOn, !isSwitchDisabled {
                Button("") { isOn.wrappedValue.toggle() }.keyboardShortcut(.space, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A row's one element: its texts combined, or the line given in their place. Given, the
    /// texts are ignored rather than combined, so the line is the element's label and not
    /// the value of a static text.
    @ViewBuilder fileprivate func rowElement(spokenLabel: String?) -> some View {
        if let spokenLabel {
            accessibilityElement(children: .ignore).accessibilityLabel(spokenLabel)
        } else {
            accessibilityElement(children: .combine)
        }
    }

    /// The value VoiceOver reads after the label, when there is one.
    @ViewBuilder func accessibilityValueIfSet(_ value: String?) -> some View {
        if let value { accessibilityValue(value) } else { self }
    }
}

// MARK: - 3. Page header

/// A page's title, its search field (⌘F) at the trailing end, one + (⌘N) when the page adds
/// through a sheet, and one secondary line under the title that says what the page is for.
struct PageHeader: View {
    let title: String
    let subtitle: String?
    var search: Binding<String>?
    var searchPrompt: String = String(localized: "Search")
    /// The + button's spoken name ("Add Route"); the button shows only with `onAdd`.
    var addName: String = ""
    var onAdd: (() -> Void)?
    /// The page's own primary actions (`PageTitleAction`), after the search.
    var actions: [PageTitleAction] = []
    /// False greys `actions` out, on a page of another mode.
    var actionsEnabled = true

    /// The + button's spoken name: the page's own, or "Add" when the page gave none, never empty.
    static func addButtonName(_ addName: String, in bundle: Bundle = .main) -> String {
        addName.isEmpty ? String(localized: "Add", bundle: bundle) : addName
    }

    /// The header band under the title bar: title and subtitle on the left, the search and
    /// the page's actions on the right, all centred on one line. The sidebar's brand header
    /// takes the same height, so the app name and the page title sit level.
    static let height: CGFloat = 56

    /// The most lines the purpose line takes: two fit under the title within `height`.
    static let subtitleLines = 2

    /// The search field's prompt, which says what it filters: "Search Services".
    static func searchPrompt(for title: String, in bundle: Bundle = .main) -> String {
        String(localized: "Search \(title)", bundle: bundle)
    }

    /// The search field's width: 240 pt, narrowing to 220 pt on a small window so the subtitle
    /// keeps its room. 220 pt holds the longest prompt whole ("Rechercher dans Domaines").
    static let searchWidth: ClosedRange<CGFloat> = 220...240

    /// Bumped by ⌘F: the system search field takes the keyboard focus.
    @State private var searchFocusRequest = 0

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.pageTitle)
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    // Two lines fit the band under the title, so a line the smallest window
                    // cannot hold wraps instead of losing its end.
                    Text(subtitle)
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(Self.subtitleLines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(subtitle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.m)
            HStack(spacing: Theme.Space.m) {
                if let search { searchField(search) }
                pageActions
                if let onAdd {
                    PageAddButton(name: Self.addButtonName(addName), action: onAdd)
                }
            }
        }
    }

    /// The system search field, with its magnifier and clear button, named for the list it
    /// filters ("Search Domains"). It has no focus ring until it is clicked or ⌘F is pressed.
    private func searchField(_ search: Binding<String>) -> some View {
        LogSearchField(text: search, placeholder: searchPrompt, focusRequest: searchFocusRequest)
            .frame(minWidth: Self.searchWidth.lowerBound, idealWidth: Self.searchWidth.upperBound,
                   maxWidth: Self.searchWidth.upperBound)
            .fixedSize(horizontal: false, vertical: true)
            .help(ControlNames.help(searchPrompt, shortcut: "⌘F"))
            .background {
                Button("") { searchFocusRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }
}

extension PageHeader {
    /// The words first, then the +; an add without a button still answers ⌘N.
    @ViewBuilder fileprivate var pageActions: some View {
        ForEach(actions.filter { $0.kind == .button }) { action in
            Button(action.name, action: action.perform)
                .controlSize(.small)
                // Never narrower than its words: the purpose line wraps first.
                .fixedSize()
                .disabled(!action.isEnabled)
                .help(action.help ?? action.name)
                .accessibilityLabel(action.name)
        }
        .disabled(!actionsEnabled)
        if let add = actions.first(where: { $0.kind == .add }) {
            Group {
                if add.showsButton {
                    PageAddButton(name: Self.addButtonName(add.name), action: add.perform)
                } else {
                    Button("", action: add.perform)
                        .keyboardShortcut("n", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .disabled(!actionsEnabled || !add.isEnabled)
        }
    }
}

/// The page's one + (⌘N), named for VoiceOver and in its tooltip: "Add Rule".
struct PageAddButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.bgInput))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
        .help(ControlNames.help(name, shortcut: "⌘N"))
        .accessibilityLabel(name)
    }
}

// MARK: - 4. Empty state

/// What a group box shows with nothing in it: a 26 pt symbol, one sentence, one primary
/// button and at most one link.
struct EmptyState: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let systemImage: String
    let title: String
    var message: String?
    var primary: Action?
    var link: Action?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.textTertiary)
                .padding(.bottom, Theme.Space.xs)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Font.strong)
                .foregroundColor(Theme.text)
            if let message {
                Text(message)
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if primary != nil || link != nil {
                HStack(spacing: Theme.Space.l) {
                    if let primary {
                        Button(primary.title, action: primary.perform)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .controlSize(.regular)
                    }
                    if let link {
                        Button(link.title, action: link.perform)
                            .buttonStyle(.link)
                            .foregroundColor(Theme.accentText)
                    }
                }
                .padding(.top, Theme.Space.s)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, Theme.Space.page)
    }
}

// MARK: - 5. Status chip

/// The state of routing as a shape, then a word, then a colour: ● On, ▲ Not routing or
/// Partly routed, ◐ Waiting, ॥ Paused, ○ Off. Green is used for On only.
struct StatusChip: View {
    enum Kind: CaseIterable {
        case on, notRouting, partlyRouted, waiting, paused, off

        var systemImage: String {
            switch self {
            case .on: return "circle.fill"
            case .notRouting, .partlyRouted: return "triangle.fill"
            case .waiting: return "circle.lefthalf.filled"
            case .paused: return "pause.fill"
            case .off: return "circle"
            }
        }

        var color: Color {
            switch self {
            case .on: return Theme.live
            case .notRouting, .partlyRouted: return Theme.attention
            case .waiting, .paused, .off: return Theme.textSecondary
            }
        }

        func word(in bundle: Bundle = .main) -> String {
            switch self {
            case .on: return String(localized: "On", bundle: bundle)
            case .notRouting: return String(localized: "Not routing", bundle: bundle)
            case .partlyRouted: return String(localized: "Partly routed", bundle: bundle)
            case .waiting: return String(localized: "Waiting", bundle: bundle)
            case .paused: return String(localized: "Paused", bundle: bundle)
            case .off: return String(localized: "Off", bundle: bundle)
            }
        }
    }

    let state: Kind

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.systemImage)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(state.color)
                .accessibilityHidden(true)
            Text(state.word())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, Theme.Space.s)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.bgDisabled)
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.word())
    }
}

// MARK: - 6. Route chip

/// Where a rule's traffic goes, as a grey glyph and the route's name: ↗ Direct, a key and the
/// VPN's name, a branch and the proxy's name. No colour per egress.
struct RouteChip: View {
    let systemImage: String
    let name: String
    /// Draws our own chevron, for the chip used as a menu's label.
    var showsChevron = false

    static func systemImage(for egress: Egress) -> String {
        switch egress {
        case .direct: return "arrow.up.right"
        case .vpnDefault: return "key"
        case .proxyHTTP, .proxySOCKS5: return "arrow.triangle.branch"
        case .tailscaleExit: return "network"
        }
    }

    /// The widest a chip gets in a row; a longer route name truncates in the middle.
    static let rowMaxWidth: CGFloat = 180

    /// The spoken name: "Route: Direct".
    static func spokenName(_ name: String, in bundle: Bundle = .main) -> String {
        String(localized: "Route: \(name)", bundle: bundle)
    }

    init(systemImage: String, name: String, showsChevron: Bool = false) {
        self.systemImage = systemImage
        self.name = name
        self.showsChevron = showsChevron
    }

    init(route: Route, vpnName: String?, showsChevron: Bool = false) {
        self.init(systemImage: Self.systemImage(for: route.egress), name: route.friendlyName(vpnName: vpnName),
                  showsChevron: showsChevron)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
                .fill(Theme.bgDisabled)
        )
        // Ideal width when there is room, narrower (the name truncates in the middle) when not.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenName(name))
    }
}

/// Gives its view the width it asks for, up to `max`, and less when less is offered: a long
/// route name truncates inside the chip instead of taking the row's width from its name.
struct CappedWidth: Layout {
    let max: CGFloat

    private func proposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? max, max), height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(self.proposal(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A route chip that opens a menu: our chevron, the system indicator hidden, so it shows one
/// chevron and keeps the chip's look (the B1 fix, kept in one place).
struct RouteChipMenu<Content: View>: View {
    let chip: RouteChip
    /// What VoiceOver says for the menu: "Route: Direct" unless the row names its own,
    /// such as "Route for en.wikipedia.org: Direct".
    let spokenName: String
    let content: Content

    init(_ chip: RouteChip, spokenName: String? = nil, @ViewBuilder content: () -> Content) {
        self.chip = RouteChip(systemImage: chip.systemImage, name: chip.name, showsChevron: true)
        self.spokenName = spokenName ?? RouteChip.spokenName(chip.name)
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            chip
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(spokenName)
    }
}

// MARK: - 7. Sheet scaffold

/// The one sheet frame: a title, the content, then Cancel and a default button on the right,
/// with no divider and no close button. Esc cancels, Return confirms. Width 420, height fits.
struct SheetScaffold<Content: View>: View {
    static var width: CGFloat { 420 }

    let title: String
    let confirmTitle: String
    var isDestructive = false
    var canConfirm = true
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let content: Content

    init(_ title: String, confirmTitle: String, isDestructive: Bool = false, canConfirm: Bool = true,
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.canConfirm = canConfirm
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.content = content()
    }

    /// The confirm button's colour: `failure` for a destructive confirm, `accent` otherwise.
    static func confirmColor(isDestructive: Bool) -> Color {
        isDestructive ? Theme.failure : Theme.accent
    }

    /// The confirm button's role, so a destructive confirm is destructive beyond its colour.
    static func confirmRole(isDestructive: Bool) -> ButtonRole? {
        isDestructive ? .destructive : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title)
                .font(Theme.Font.title)
                .foregroundColor(Theme.text)
                .accessibilityAddTraits(.isHeader)
            content
            HStack(spacing: Theme.Space.s) {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: Self.confirmRole(isDestructive: isDestructive), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Self.confirmColor(isDestructive: isDestructive))
                    .disabled(!canConfirm)
            }
        }
        .padding(Theme.Space.page - 4)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bgSecondary)
    }
}

/// A labelled field inside a `SheetScaffold`: the label in `section` type, a * when the field
/// is required, then the control. Every editor sheet lays its fields out with it.
struct SheetField<Field: View>: View {
    let label: String
    var required = false
    let field: Field

    init(_ label: String, required: Bool = false, @ViewBuilder field: () -> Field) {
        self.label = label
        self.required = required
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            HStack(spacing: 3) {
                Text(label)
                    .font(Theme.Font.section)
                    .foregroundColor(Theme.textSecondary)
                if required {
                    Text(verbatim: "*")
                        .font(Theme.Font.section)
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            field
        }
    }
}

/// Why a sheet's confirm did not save, said in one line above the buttons.
struct SheetError: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.xs + 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.failure)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Font.detail)
                .foregroundColor(Theme.failure)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
