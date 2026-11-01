// RoutingModeSwitcher.swift
// The routing mode: the mode control the Settings sidebar and the dropdown share (`ModeControl`),
// and the sheet that explains each mode before anything changes. The sheet opens from the
// sidebar's mode control (`SettingsModeControl`) and from a read-only page's Switch…, so a click
// meant to change the page never changes the mode.

import AppKit
import SwiftUI

// MARK: - Wording

/// The words the mode sheet uses, kept pure so they are unit-tested.
enum RoutingModeCopy {
    /// Sheet order.
    static let order: [RoutingMode] = [.bypass, .vpnOnly, .custom]

    /// What the user's own lists hold, read from the config by `lists(from:)`.
    struct Lists: Equatable {
        var current: RoutingMode
        /// Enabled services and Bypass domains.
        var bypassServices: Int
        var bypassDomains: Int
        /// Enabled entries on the VPN Only list.
        var vpnOnlyEntries: Int
        /// Custom mode's rules, enabled or not.
        var rules: Int
        /// Entering Custom builds rules from the current lists (`Config.preparedForCustomMode`)
        /// only when there are no rules yet and the lists hold something to route. The dropdown's
        /// question reads this too, so both surfaces word the switch to Custom the same way.
        var listsBecomeRules: Bool
    }

    static func lists(from config: Config) -> Lists {
        Lists(
            current: config.routingMode,
            bypassServices: config.services.filter { $0.enabled }.count,
            bypassDomains: config.domains.filter { $0.enabled }.count,
            vpnOnlyEntries: config.inverseDomains.filter { $0.enabled }.count,
            rules: config.rules.count,
            listsBecomeRules: config.routingMode != .custom && config.customModeBuildsRulesFromLists
        )
    }

    static func name(_ mode: RoutingMode) -> String {
        switch mode {
        case .bypass: return String(localized: "Bypass")
        case .vpnOnly: return String(localized: "VPN Only")
        case .custom: return String(localized: "Custom Routes")
        }
    }

    /// The sheet's text for one mode: what it does, then what the user's lists hold for it.
    static func sheetLine(_ mode: RoutingMode, lists: Lists) -> String {
        switch mode {
        case .bypass:
            return String(localized: "Everything uses the VPN except what you list.") + " " + bypassCount(lists)
        case .vpnOnly:
            return String(localized: "Only what you list uses the VPN; everything else goes direct.") + " " + vpnOnlyCount(lists)
        case .custom:
            return String(localized: "Send each destination through a route you pick: direct, a VPN, a proxy or a Tailscale peer.") + " " + customCount(lists)
        }
    }

    private static func bypassCount(_ lists: Lists) -> String {
        let s = lists.bypassServices, d = lists.bypassDomains
        let services = s == 1 ? String(localized: "1 service") : String(localized: "\(s) services")
        let domains = d == 1 ? String(localized: "1 domain") : String(localized: "\(d) domains")
        switch (s > 0, d > 0) {
        case (true, true): return String(localized: "\(services) and \(domains).")
        case (true, false): return String(localized: "\(services).")
        case (false, true): return String(localized: "\(domains).")
        case (false, false): return String(localized: "Nothing listed yet.")
        }
    }

    private static func vpnOnlyCount(_ lists: Lists) -> String {
        switch lists.vpnOnlyEntries {
        case 0: return String(localized: "Nothing listed yet.")
        case 1: return String(localized: "1 entry.")
        default: return String(localized: "\(lists.vpnOnlyEntries) entries.")
        }
    }

    private static func customCount(_ lists: Lists) -> String {
        if lists.listsBecomeRules { return String(localized: "Your lists become rules.") }
        switch lists.rules {
        case 0: return String(localized: "No rules yet.")
        case 1: return String(localized: "1 rule.")
        default: return String(localized: "\(lists.rules) rules.")
        }
    }

    /// A pick in the mode control opens the sheet with that mode selected. Picking the mode
    /// already in use opens nothing.
    static func sheetSelection(forPick picked: RoutingMode, current: RoutingMode) -> RoutingMode? {
        picked == current ? nil : picked
    }

    /// Switch does something only when the selected mode differs from the one in use.
    static func canSwitch(to selected: RoutingMode, from current: RoutingMode) -> Bool {
        selected != current
    }
}

// MARK: - Shared state

/// The mode picked in the sidebar's mode control or a read-only page's Switch…, waiting in the
/// sheet for Switch or Cancel.
@MainActor
final class ModeSwitchRequest: ObservableObject {
    @Published var pickedMode: RoutingMode?
}

// MARK: - Mode sheet

/// Opens with the mode picked in the mode control selected. Nothing changes until Switch, which goes
/// through the same `RouteManager.setRoutingMode` the old confirmation alert used.
struct RoutingModeSheet: View {
    let lists: RoutingModeCopy.Lists
    let onCancel: () -> Void
    let onSwitch: (RoutingMode) -> Void
    @State private var selected: RoutingMode

    init(selected: RoutingMode, lists: RoutingModeCopy.Lists,
         onCancel: @escaping () -> Void, onSwitch: @escaping (RoutingMode) -> Void) {
        self.lists = lists
        self.onCancel = onCancel
        self.onSwitch = onSwitch
        _selected = State(initialValue: selected)
    }

    var body: some View {
        SheetScaffold(String(localized: "Routing mode"), confirmTitle: String(localized: "Switch"),
                      canConfirm: RoutingModeCopy.canSwitch(to: selected, from: lists.current),
                      onCancel: onCancel, onConfirm: { onSwitch(selected) }) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(RoutingModeCopy.order.enumerated()), id: \.element) { index, mode in
                    if index > 0 {
                        Rectangle().fill(Theme.separator).frame(height: 0.5)
                    }
                    row(mode)
                }
            }
        }
    }

    private func row(_ mode: RoutingMode) -> some View {
        let isSelected = selected == mode
        return Button { selected = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? Theme.accentText : Theme.textSecondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(RoutingModeCopy.name(mode))
                        .font(Theme.Font.strong)
                        .foregroundColor(Theme.text)
                    Text(RoutingModeCopy.sheetLine(mode, lists: lists))
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Mode control

/// The routing mode as the app's main control, the same in the Settings sidebar and in the
/// dropdown: all three modes, each with its name and what it does, the mode in use marked. In
/// the sidebar the modes are stacked cards (glyph, name, meaning, the one in use ringed and
/// checked); in the dropdown they are one track of three segments, the mode in use raised, with
/// its meaning under it. A pick changes nothing by itself: `onPick` asks first (the sheet in
/// Settings, the alert in the dropdown), and the control keeps showing the saved mode.
struct ModeControl: View {
    enum Layout { case cards, track }

    static let modes = DropdownModePicker.modes

    let current: RoutingMode
    let layout: Layout
    let onPick: (RoutingMode) -> Void

    static func glyph(_ mode: RoutingMode) -> String {
        switch mode {
        case .bypass: return "arrow.turn.up.right"
        case .vpnOnly: return "lock.shield"
        case .custom: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// What a mode does, in one sentence: the card's second line, the line under the track and
    /// every mode's VoiceOver hint, so both surfaces say the same thing.
    static func meaning(_ mode: RoutingMode, in bundle: Bundle = .main) -> String {
        switch mode {
        case .bypass: return String(localized: "Your list skips the VPN.", bundle: bundle)
        case .vpnOnly: return String(localized: "Only your list uses the VPN.", bundle: bundle)
        case .custom: return String(localized: "Your rules pick each route.", bundle: bundle)
        }
    }

    /// A card's height in the sidebar: two lines and 4 pt above and below.
    static let cardHeight: CGFloat = 38
    /// A segment's height on the dropdown's track.
    static let segmentHeight: CGFloat = 24

    var body: some View {
        Group {
            switch layout {
            case .cards:
                VStack(spacing: Theme.Space.xs) {
                    ForEach(Self.modes, id: \.self) { card($0) }
                }
            case .track:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(Self.modes, id: \.self) { segment($0) }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).fill(Theme.bgInput))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 2).strokeBorder(Theme.border, lineWidth: 0.5))
                    Text(Self.meaning(current))
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Mode"))
    }

    private func pick(_ mode: RoutingMode) {
        if mode != current { onPick(mode) }
    }

    private func card(_ mode: RoutingMode) -> some View {
        ModeCard(mode: mode, isCurrent: mode == current) { pick(mode) }
            .modeAccessibility(mode, isCurrent: mode == current)
    }

    private func segment(_ mode: RoutingMode) -> some View {
        let isCurrent = mode == current
        return Button { pick(mode) } label: {
            Text(DropdownModePicker.label(mode))
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundColor(isCurrent ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
                .frame(height: Self.segmentHeight)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .fill(isCurrent ? Theme.bgRaised : Color.clear)
                        .shadow(color: .black.opacity(isCurrent ? 0.2 : 0), radius: 1, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modeAccessibility(mode, isCurrent: isCurrent)
    }
}

/// One mode in the sidebar: glyph, name, meaning, on the card ground. The mode in use gets a
/// 1 pt accent ring and a checkmark, no fill, so the selected page stays the sidebar's one
/// filled row.
private struct ModeCard: View {
    let mode: RoutingMode
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: ModeControl.glyph(mode))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isCurrent ? Theme.accentText : Theme.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DropdownModePicker.label(mode))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isCurrent ? Theme.text : Theme.textSecondary)
                        .lineLimit(1)
                    Text(ModeControl.meaning(mode))
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.accentText)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .frame(minHeight: ModeControl.cardHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control + 2)
                    .fill(isHovered && !isCurrent ? Theme.bgHover : Theme.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control + 2)
                    .strokeBorder(isCurrent ? Theme.accent : Theme.border, lineWidth: isCurrent ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private extension View {
    /// Each mode reads as its name, what it does as the hint, and selected when in use.
    func modeAccessibility(_ mode: RoutingMode, isCurrent: Bool) -> some View {
        self
            .help(DropdownStatus.modeDescription(DropdownModePicker.copyMode(mode)))
            .accessibilityLabel(DropdownModePicker.label(mode))
            .accessibilityHint(ModeControl.meaning(mode))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
