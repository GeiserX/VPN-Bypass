// RoutingModeSwitcher.swift
// The routing mode in the Settings window: the sheet that explains each mode before anything
// changes. It opens from the mode popup at the top of the sidebar (`SettingsModePopup`) and from
// a read-only page's Switch…, so a click meant to change the page never changes the mode.

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

    /// A pick in the mode popup opens the sheet with that mode selected. Picking the mode
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

/// The mode picked in the sidebar's mode popup or a read-only page's Switch…, waiting in the
/// sheet for Switch or Cancel.
@MainActor
final class ModeSwitchRequest: ObservableObject {
    @Published var pickedMode: RoutingMode?
}

// MARK: - Mode sheet

/// Opens with the mode picked in the popup selected. Nothing changes until Switch, which goes
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
        let canSwitch = RoutingModeCopy.canSwitch(to: selected, from: lists.current)
        VStack(alignment: .leading, spacing: 0) {
            Text("Routing mode")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .padding(.bottom, 14)

            ForEach(Array(RoutingModeCopy.order.enumerated()), id: \.element) { index, mode in
                if index > 0 {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
                row(mode)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Theme.bgInput)
                    .cornerRadius(7)
                    .keyboardShortcut(.cancelAction)
                Button("Switch") { onSwitch(selected) }
                    .buttonStyle(.plain)
                    .foregroundColor(canSwitch ? .white : Theme.textDisabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(canSwitch ? AnyShapeStyle(Theme.blueGradient) : AnyShapeStyle(Theme.bgDisabled))
                    .cornerRadius(7)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSwitch)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.top, 18)
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.bgSecondary)
    }

    private func row(_ mode: RoutingMode) -> some View {
        let isSelected = selected == mode
        return Button { selected = mode } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? Theme.Brand.blueLight : Theme.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(RoutingModeCopy.name(mode))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(RoutingModeCopy.sheetLine(mode, lists: lists))
                        .font(.system(size: 12))
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
