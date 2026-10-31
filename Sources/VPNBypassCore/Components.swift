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
    let trailing: Trailing
    let content: Content

    init(_ title: String? = nil, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(Theme.Font.section)
                            .foregroundColor(Theme.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                    }
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

    var id: String { name }

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

    let glyph: String
    let name: String
    var detail: String?
    var needsAttention = false
    var number: String?
    /// From `numberColumnWidth(for:)`, the same on every row of the page.
    var numberWidth: CGFloat = 0
    var actions: [RowAction] = []
    var isOn: Binding<Bool>?
    /// A selected row answers Return, ⌘⌫ and Space.
    var isSelected = false
    /// Draws the actions as if the pointer were over the row, for the doc screenshots.
    var showsActions = false

    @State private var isHovered = false

    private var actionsVisible: Bool { isHovered || isSelected || showsActions }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: Self.leadingGlyph(glyph, needsAttention: needsAttention))
                .font(.system(size: 13))
                .foregroundColor(needsAttention ? Theme.attention : Theme.textSecondary)
                .frame(width: Self.glyphColumn)
                .accessibilityHidden(!needsAttention)
                .accessibilityLabel(String(localized: "Needs attention"))

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(Theme.Font.body)
                    .foregroundColor(isOn?.wrappedValue == false ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if !actions.isEmpty {
                HStack(spacing: 2) {
                    ForEach(actions) { action in
                        Button(action: action.perform) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 22, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(action.name)
                        .accessibilityLabel(action.name)
                    }
                }
                .opacity(actionsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: actionsVisible)
            }

            if numberWidth > 0 {
                Text(number ?? "")
                    .font(SwiftUI.Font(Self.numberFont))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: numberWidth, alignment: .trailing)
            }

            if let isOn {
                Toggle(name, isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, Self.inset)
        .frame(minHeight: detail == nil ? Self.singleLineHeight : Self.twoLineHeight)
        .background(actionsVisible ? Theme.bgHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            ForEach(actions) { action in
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

    /// Hidden buttons that give a selected row its keys, the way the dropdown's footer does.
    @ViewBuilder private var selectedRowKeys: some View {
        ZStack {
            ForEach(actions.filter { $0.shortcut != nil }) { action in
                Button("", action: action.perform).keyboardShortcut(action.shortcut!)
            }
            if let isOn {
                Button("") { isOn.wrappedValue.toggle() }.keyboardShortcut(.space, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - 3. Page header

/// A page's title, its search field (⌘F) at the trailing end, one + when the page adds
/// through a sheet, and one secondary line under the title that says what the page is for.
struct PageHeader: View {
    let title: String
    let subtitle: String?
    var search: Binding<String>?
    var searchPrompt: String = String(localized: "Search")
    /// The + button's spoken name ("Add Route"); the button shows only with `onAdd`.
    var addName: String = ""
    var onAdd: (() -> Void)?

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(Theme.Font.title)
                    .foregroundColor(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.m)
                if let search {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                            .accessibilityHidden(true)
                        TextField(searchPrompt, text: search)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.body)
                            .focused($searchFocused)
                            .accessibilityLabel(searchPrompt)
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, Theme.Space.xs)
                    .frame(width: 180)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .fill(Theme.bgInput)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .strokeBorder(searchFocused ? Theme.accentText : Theme.border, lineWidth: searchFocused ? 1 : 0.5)
                    )
                    .help(ControlNames.help(searchPrompt, shortcut: "⌘F"))
                    .background {
                        Button("") { searchFocused = true }
                            .keyboardShortcut("f", modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }
                }
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(addName)
                    .accessibilityLabel(addName)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenName(name))
    }
}

/// A route chip that opens a menu: our chevron, the system indicator hidden, so it shows one
/// chevron and keeps the chip's look (the B1 fix, kept in one place).
struct RouteChipMenu<Content: View>: View {
    let chip: RouteChip
    let content: Content

    init(_ chip: RouteChip, @ViewBuilder content: () -> Content) {
        self.chip = RouteChip(systemImage: chip.systemImage, name: chip.name, showsChevron: true)
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
        .fixedSize()
        .accessibilityLabel(RouteChip.spokenName(chip.name))
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
    }
}
