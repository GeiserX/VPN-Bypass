// PerAppRoutingGroup.swift
// Settings > General > Per-app routing: the opt-in switch for the Network Extension engine, what
// it does and what macOS will ask before any system prompt, its state, and its counts.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, section 5. Off by default; off is the old way.

import AppKit
import SwiftUI

/// The group's words, pure so they are tested.
enum PerAppRouting {
    /// What it does and what it leaves alone, shown before anything is turned on.
    static func explanation(in bundle: Bundle = .main) -> String {
        String(localized: "Apps on the Apps list (Bypass mode), or named in a rule with the Direct route (Custom mode), skip the VPN for their TCP connections to public IPv4 addresses. Everything else keeps its normal route, which may be the VPN: IPv6, connections an app binds to a network interface itself, local and private addresses, and the VPN client's own traffic. Domain, service and IP rules keep working as before, for every app.", bundle: bundle)
    }

    /// The two approvals, said before the first system prompt.
    static func approvals(in bundle: Bundle = .main) -> String {
        String(localized: "Turning it on asks twice: first allow the extension in System Settings > General > Login Items & Extensions > Network Extensions (with your password), then allow VPN Bypass to add a proxy configuration. If you say no, nothing else changes. Turning it on or off resets the open connections of the apps you named.", bundle: bundle)
    }

    /// While on: what Pause does and does not do (3.7).
    static func pauseNote(in bundle: Bundle = .main) -> String {
        String(localized: "Pause stands it down too, but new connections still pass through the extension; only turning it off takes it out of the way.", bundle: bundle)
    }

    /// Bypass mode serves the Apps list and Custom its rules for apps; VPN Only has nothing for it.
    static func modeNote(_ mode: RouteManager.RoutingMode, in bundle: Bundle = .main) -> String? {
        mode == .vpnOnly
            ? String(localized: "It does not run in VPN Only mode. In Bypass mode it serves the Apps list, in Custom mode the rules for apps.", bundle: bundle)
            : nil
    }

    /// The counts since the extension started, nil before the first reply.
    static func countsLine(_ reply: FlowEngineReplySummary?, in bundle: Bundle = .main) -> String? {
        guard let reply else { return nil }
        let claimed = reply.claimedByRule.values.reduce(0, +)
        let bound = reply.boundByRule.values.reduce(0, +)
        var line = String(localized: "\(claimed) connections went around the VPN since the extension started.", bundle: bundle)
        if bound > 0 {
            line += " " + String(localized: "\(bound) came bound to a network interface, which per-app routing cannot serve.", bundle: bundle)
        }
        return line
    }

    /// While on: turning it off is the old way, and takes the extension off the Mac.
    static func offNote(in bundle: Bundle = .main) -> String {
        String(localized: "Turning it off removes the extension and its configuration from this Mac, so every app follows your routes as before. macOS asks for an administrator password, and turning it on again asks for both approvals again.", bundle: bundle)
    }

    /// Remove Extension shows while the switch is off and something of it may be left: after
    /// a turn-off the app made by itself, a declined configuration, or a removal that failed.
    static func showsRemoveButton(enabled: Bool, state: FlowEngineState, mayBeInstalled: Bool, removal: FlowEngineRemoval?) -> Bool {
        guard !enabled, switchEnabled(state), removal != .removing else { return false }
        return mayBeInstalled
    }

    /// The extension runs another version than the app while the state still serves.
    static func updateNote(in bundle: Bundle = .main) -> String {
        String(localized: "An update of the extension is waiting for approval in System Settings.", bundle: bundle)
    }

    /// The switch can be used in every state but unavailable.
    static func switchEnabled(_ state: FlowEngineState) -> Bool {
        if case .unavailable = state { return false }
        return true
    }

    /// System Settings, Login Items & Extensions, where the extension switch is.
    static let extensionsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}

struct PerAppRoutingGroup: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject var engine: FlowEngineManager = .shared

    var body: some View {
        GroupSection(GeneralPage.Group.perAppRouting.title()) {
            GeneralRow(String(localized: "Use per-app routing"), detail: engine.state.line(), detailLines: nil) {
                Toggle(String(localized: "Use per-app routing"), isOn: Binding(
                    get: { routeManager.config.flowEngine.enabled },
                    set: { engine.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.accent)
                .disabled(!PerAppRouting.switchEnabled(engine.state))
                .accessibilityLabel(String(localized: "Use per-app routing"))
            }
            InsetDivider.plain
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                note(PerAppRouting.explanation())
                if !routeManager.config.flowEngine.enabled || engine.state.waitsInSystemSettings
                    || engine.state == .awaitingConfigApproval {
                    note(PerAppRouting.approvals())
                }
                if routeManager.config.flowEngine.enabled {
                    if let mode = PerAppRouting.modeNote(routeManager.config.routingMode) { note(mode) }
                    if engine.state == .active, let counts = PerAppRouting.countsLine(engine.reply) { note(counts) }
                    if engine.updateWaiting, engine.state != .updateWaiting { note(PerAppRouting.updateNote()) }
                    note(PerAppRouting.pauseNote())
                    note(PerAppRouting.offNote())
                }
                if !routeManager.config.flowEngine.enabled, let removal = engine.removal {
                    note(removal.line())
                }
                if engine.state.waitsInSystemSettings {
                    Button(String(localized: "Open System Settings")) {
                        NSWorkspace.shared.open(PerAppRouting.extensionsSettingsURL)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Open System Settings to allow per-app routing"))
                }
                if PerAppRouting.showsRemoveButton(enabled: routeManager.config.flowEngine.enabled, state: engine.state,
                                                   mayBeInstalled: engine.mayBeInstalled, removal: engine.removal) {
                    Button(String(localized: "Remove Extension")) {
                        engine.removeExtension()
                    }
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Remove the per-app routing extension from this Mac"))
                }
            }
            .padding(.horizontal, ListRow.inset)
            .padding(.vertical, Theme.Space.s)
        }
        // The counts line reads the extension while it shows, not only at the heartbeat.
        .task(id: engine.state == .active) {
            guard engine.state == .active else { return }
            while !Task.isCancelled {
                await engine.refreshCounts()
                try? await Task.sleep(nanoseconds: UInt64(FlowEngineManager.countsRefreshSeconds * 1_000_000_000))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.detail)
            .foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
