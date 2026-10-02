// StatusTab.swift
// Settings > Status (proposal 13 of #119): one page that answers "is it working right now?".
// It gathers the live state that used to sit at the bottom of General (Privileged Helper,
// Network Status, Coexistence, the DNS schedule) and at the top of Logs (Route Health).
// The wording is the pure `StatusPage`, so every state's text is unit-tested.

import SwiftUI

// MARK: - Wording

/// What the Status page says, as pure functions of the app's state.
enum StatusPage {
    /// What re-reads the tunnels while the page is open: the VPN coming up, going down or
    /// moving to another interface, and every apply or removal of routes, so the tagged count
    /// and the default route never contradict the Applied row. Never a timer: the read spawns
    /// `ifconfig` and `tailscale status`.
    struct TunnelReadKey: Equatable {
        let vpnInterface: String?
        let isVPNConnected: Bool
        let lastRouteChangeAt: Date?

        @MainActor
        static func current(_ routeManager: RouteManager) -> TunnelReadKey {
            TunnelReadKey(vpnInterface: routeManager.vpnInterface,
                          isVPNConnected: routeManager.isVPNConnected,
                          lastRouteChangeAt: routeManager.lastRouteChange?.at)
        }
    }

    /// The block at the top: a one-word verdict, then the dropdown's own sentence.
    struct Summary: Equatable {
        let title: String
        let sentence: String
        let note: String?
        let tone: DropdownStatus.Tone
    }

    /// One value on the right of a row, and the colour of its dot. A nil tone draws no dot.
    struct Line: Equatable {
        let text: String
        var tone: DropdownStatus.Tone? = nil
    }

    // MARK: Summary

    /// The verdict reuses `DropdownStatus.make`, so the page and the dropdown never disagree:
    /// the title names the state, the sentence is the dropdown's sentence.
    static func summary(_ input: DropdownStatus.Input, now: Date, bundle: Bundle = .main) -> Summary {
        let status = DropdownStatus.make(input, now: now)
        let title: String
        var sentence = status.sentence
        if !input.isVPNConnected {
            title = status.headline
        } else if !input.helperReady {
            title = String(localized: "Not working", bundle: bundle)
        } else if isWaiting(input) {
            // WAITING or HELD BACK: the dropdown's headline already says what the tunnel did.
            title = status.headline
        } else if input.installedRoutes == 0 && input.nothingConfigured {
            title = String(localized: "Not set up", bundle: bundle)
        } else if input.installedRoutes == 0 && !input.everythingElseDirect {
            title = String(localized: "Nothing routed", bundle: bundle)
        } else {
            title = String(localized: "Working", bundle: bundle)
            if let change = DropdownCopy.shownRouteChange(input.lastRouteChange,
                                                          currentRouteCount: input.installedRoutes),
               change.kind == .applied {
                sentence += " " + DropdownCopy.routeChangeLine(change, now: now).text
            }
        }
        return Summary(title: title, sentence: sentence, note: status.note, tone: status.tone)
    }

    /// The same test `DropdownStatus.make` makes before it shows WAITING or HELD BACK: a
    /// pending re-apply that nothing has applied or removed routes since.
    static func isWaiting(_ input: DropdownStatus.Input) -> Bool {
        guard let pending = input.pending else { return false }
        if let change = input.lastRouteChange, change.at > pending.connectedAt { return false }
        return true
    }

    // MARK: Helper

    static func helperLine(_ state: HelperState, version: String?, bundle: Bundle = .main) -> Line {
        switch state {
        case .ready:
            guard let version else { return Line(text: String(localized: "Ready", bundle: bundle), tone: .ok) }
            return Line(text: String(localized: "Ready, version \(version)", bundle: bundle), tone: .ok)
        case .checking, .installing, .outdated:
            return Line(text: state.statusText, tone: .warn)
        case .missing, .failed:
            return Line(text: state.statusText, tone: .bad)
        }
    }

    /// The line under the helper row when it is not ready; nil when it is.
    static func helperHint(_ state: HelperState, bundle: Bundle = .main) -> String? {
        switch state {
        case .ready: return nil
        case .checking: return String(localized: "Verifying helper version...", bundle: bundle)
        case .installing: return String(localized: "Admin authorization required...", bundle: bundle)
        case .outdated: return String(localized: "Helper needs updating for this version", bundle: bundle)
        case .missing: return String(localized: "Install to enable route management", bundle: bundle)
        case .failed: return String(localized: "Helper could not be started", bundle: bundle)
        }
    }

    /// The helper row's button, or nil when there is nothing to do.
    static func helperAction(_ state: HelperState, isInstalling: Bool, bundle: Bundle = .main) -> String? {
        if isInstalling { return String(localized: "Installing...", bundle: bundle) }
        switch state {
        case .missing: return String(localized: "Install", bundle: bundle)
        case .outdated: return String(localized: "Update", bundle: bundle)
        case .failed: return String(localized: "Retry", bundle: bundle)
        case .ready, .checking, .installing: return nil
        }
    }

    // MARK: Connection

    static func vpnLine(isConnected: Bool, name: String?, interface: String?, bundle: Bundle = .main) -> Line {
        guard isConnected else { return Line(text: String(localized: "Not connected", bundle: bundle), tone: .bad) }
        switch (name, interface) {
        case let (name?, iface?): return Line(text: String(localized: "\(name), connected on \(iface)", bundle: bundle), tone: .ok)
        case let (nil, iface?): return Line(text: String(localized: "Connected on \(iface)", bundle: bundle), tone: .ok)
        case let (name?, nil): return Line(text: String(localized: "\(name), connected", bundle: bundle), tone: .ok)
        case (nil, nil): return Line(text: String(localized: "Connected", bundle: bundle), tone: .ok)
        }
    }

    /// The connection traffic takes when it skips the VPN.
    static func normalConnectionLine(ssid: String?, gateway: String?, bundle: Bundle = .main) -> Line {
        switch (ssid, gateway) {
        case let (ssid?, gateway?): return Line(text: String(localized: "Wi-Fi “\(ssid)”, gateway \(gateway)", bundle: bundle))
        case let (nil, gateway?): return Line(text: String(localized: "Gateway \(gateway)", bundle: bundle))
        case let (ssid?, nil): return Line(text: String(localized: "Wi-Fi “\(ssid)”, no gateway found", bundle: bundle), tone: .warn)
        case (nil, nil): return Line(text: String(localized: "No gateway found", bundle: bundle), tone: .warn)
        }
    }

    /// Which interface carries the default route, and what it is to this app. Nil
    /// `snapshot` means the tunnels have not been read yet.
    static func defaultRouteLine(_ snapshot: RouteManager.CoexistenceSnapshot?, bundle: Bundle = .main) -> Line {
        guard let snapshot else { return Line(text: String(localized: "Reading…", bundle: bundle)) }
        guard let iface = snapshot.defaultRouteInterface else {
            return Line(text: String(localized: "Not found", bundle: bundle), tone: .warn)
        }
        if iface == snapshot.selectedInterface {
            return Line(text: String(localized: "\(iface), the VPN", bundle: bundle))
        }
        if let link = snapshot.links.first(where: { $0.interface == iface }) {
            return link.isTailscale
                ? Line(text: String(localized: "\(iface), Tailscale", bundle: bundle))
                : Line(text: String(localized: "\(iface), another tunnel", bundle: bundle))
        }
        return Line(text: String(localized: "\(iface), outside the VPN", bundle: bundle))
    }

    // MARK: Routes

    static func routes(_ n: Int, bundle: Bundle = .main) -> String {
        n == 1 ? String(localized: "1 address", bundle: bundle) : String(localized: "\(n) addresses", bundle: bundle)
    }

    /// The Applied row: what the last apply or removal did, or what is installed.
    static func appliedLine(installed: Int, lastChange: RouteManager.RouteChangeOutcome?, now: Date,
                            bundle: Bundle = .main) -> Line {
        // Same rule as the dropdown: a removal stops being reported once routes are back.
        guard let change = DropdownCopy.shownRouteChange(lastChange, currentRouteCount: installed) else {
            return installed > 0
                ? Line(text: routes(installed, bundle: bundle))
                : Line(text: String(localized: "None yet", bundle: bundle))
        }
        let when = DropdownCopy.age(since: change.at, now: now)
        switch change.kind {
        case .applied:
            let count = routes(change.routeCount, bundle: bundle)
            return change.failedCount == 0
                ? Line(text: String(localized: "\(count), \(when), none failed", bundle: bundle))
                : Line(text: String(localized: "\(count), \(when), \(change.failedCount) failed", bundle: bundle), tone: .warn)
        case .removedAll:
            return change.failedCount == 0
                ? Line(text: String(localized: "All removed \(when)", bundle: bundle), tone: .warn)
                : Line(text: String(localized: "Removed \(when), \(change.failedCount) could not be removed", bundle: bundle), tone: .bad)
        }
    }

    /// The From row: what the user's lists hold for the current mode.
    static func fromLine(_ input: DropdownStatus.Input, bundle: Bundle = .main) -> Line {
        switch input.mode {
        case .bypass:
            let s = input.enabledServices, d = input.enabledDomains
            if s == 0 && d == 0 { return Line(text: String(localized: "No services or domains", bundle: bundle)) }
            let services = s == 1 ? String(localized: "1 service", bundle: bundle) : String(localized: "\(s) services", bundle: bundle)
            let domains = d == 1 ? String(localized: "1 domain", bundle: bundle) : String(localized: "\(d) domains", bundle: bundle)
            if d == 0 { return Line(text: services) }
            if s == 0 { return Line(text: domains) }
            return Line(text: String(localized: "\(services), \(domains)", bundle: bundle))
        case .vpnOnly:
            let d = input.enabledDomains
            if d == 0 { return Line(text: String(localized: "No entries", bundle: bundle)) }
            return Line(text: d == 1 ? String(localized: "1 entry", bundle: bundle) : String(localized: "\(d) entries", bundle: bundle))
        case .custom:
            let r = input.enabledRules
            if r == 0 { return Line(text: String(localized: "No rules", bundle: bundle)) }
            return Line(text: r == 1 ? String(localized: "1 rule", bundle: bundle) : String(localized: "\(r) rules", bundle: bundle))
        }
    }

    /// The Last check row as the page draws it: the line, the spinner and the Verify button.
    struct LastCheck: Equatable {
        let line: Line
        /// A check is pinging now. Drawn as a spinner beside a greyed-out Verify.
        let isChecking: Bool
        let canVerify: Bool
    }

    /// The Last check row from the manager's own state. `isCheckingRoutes` is set by every
    /// check, so the spinner also shows one started by an apply or from the dropdown.
    @MainActor
    static func lastCheck(_ routeManager: RouteManager, now: Date, bundle: Bundle = .main) -> LastCheck {
        let isChecking = routeManager.isCheckingRoutes
        return LastCheck(line: lastCheckLine(Array(routeManager.routeVerificationResults.values),
                                             installed: routeManager.routedAddressCount,
                                             isChecking: isChecking, now: now, bundle: bundle),
                         isChecking: isChecking,
                         canVerify: !isChecking && !routeManager.activeRoutes.isEmpty)
    }

    /// The Last check row, from Verify Routes' results. Verify pings a sample, so the line
    /// says how many of the installed routes it checked. A check clears the last results when
    /// it starts, so while one runs the line says so instead of "Not checked yet".
    static func lastCheckLine(_ results: [RouteVerificationResult], installed: Int, isChecking: Bool = false,
                              now: Date, bundle: Bundle = .main) -> Line {
        if isChecking { return Line(text: String(localized: "Checking now…", bundle: bundle)) }
        guard let at = results.map(\.timestamp).max() else {
            return Line(text: String(localized: "Not checked yet", bundle: bundle))
        }
        let checked = results.count
        let total = max(installed, checked)
        let failed = results.filter { !$0.isReachable }.count
        let when = DropdownCopy.age(since: at, now: now)
        return failed == 0
            ? Line(text: String(localized: "\(checked) of \(total) checked, all reachable, \(when)", bundle: bundle))
            : Line(text: String(localized: "\(checked) of \(total) checked, \(failed) not reachable, \(when)", bundle: bundle), tone: .warn)
    }

    // MARK: DNS

    static func resolverLine(_ detected: String?, bundle: Bundle = .main) -> Line {
        guard let detected else { return Line(text: String(localized: "Not detected", bundle: bundle), tone: .warn) }
        return Line(text: String(localized: "\(detected), outside the VPN", bundle: bundle))
    }

    static func refreshedLine(last: Date?, next: Date?, automatic: Bool, now: Date, bundle: Bundle = .main) -> Line {
        let when = last.map { DropdownCopy.age(since: $0, now: now) }
        guard automatic else {
            return Line(text: when.map { String(localized: "\($0), automatic refresh off", bundle: bundle) }
                ?? String(localized: "Not yet, automatic refresh off", bundle: bundle))
        }
        guard let next else {
            return Line(text: when ?? String(localized: "Not yet", bundle: bundle))
        }
        let left = next.timeIntervalSince(now)
        if left <= 0 {
            return Line(text: when.map { String(localized: "\($0), next one due now", bundle: bundle) }
                ?? String(localized: "Not yet, next one due now", bundle: bundle))
        }
        let countdown = DropdownStatus.countdown(left)
        return Line(text: when.map { String(localized: "\($0), next in \(countdown)", bundle: bundle) }
            ?? String(localized: "Not yet, next in \(countdown)", bundle: bundle))
    }

    // MARK: Tunnels

    /// One plain sentence per tunnel, in place of the old acting on, default route and
    /// Tailscale badges.
    static func tunnelLine(_ link: RouteManager.VPNLink, snapshot: RouteManager.CoexistenceSnapshot,
                           bundle: Bundle = .main) -> String {
        let role: String
        if link.isTailscale {
            role = String(localized: "Never touched.", bundle: bundle)
        } else if link.interface == snapshot.selectedInterface {
            role = String(localized: "The app acts on this one.", bundle: bundle)
        } else {
            role = String(localized: "Not used by the app.", bundle: bundle)
        }
        guard link.interface == snapshot.defaultRouteInterface else { return role }
        return role + " " + String(localized: "It carries the default route.", bundle: bundle)
    }

    /// The Addresses owned row: the kernel's tagged routes, counted by the rule every other
    /// count uses (`RoutedBySource`). In VPN Only the catch-alls are named apart, so while the
    /// kernel holds what the app recorded, the first number is the Routed row's. A tagged
    /// destination the app has no record of counts as an address.
    static func ownedLine(tagged: [String], installed: [RoutedBySource.InstalledRoute], vpnOnly: Bool,
                          bundle: Bundle = .main) -> Line {
        let inKernel = Set(tagged)
        let recorded = installed.filter { inKernel.contains($0.destination) }
        let unrecorded = inKernel.subtracting(recorded.map(\.destination))
            .map { RoutedBySource.InstalledRoute(destination: $0, source: "") }
        let routes = recorded + unrecorded
        let addresses = RoutedBySource.addressCount(routes, vpnOnly: vpnOnly)
        switch RoutedBySource.catchAllCount(routes, vpnOnly: vpnOnly) {
        case 0: return Line(text: "\(addresses)")
        case 1: return Line(text: String(localized: "\(addresses), plus 1 catch-all", bundle: bundle))
        case let n: return Line(text: String(localized: "\(addresses), plus \(n) catch-alls", bundle: bundle))
        }
    }

    // MARK: Recent warnings

    /// The newest warnings and errors, newest first, as the log keeps them.
    static func recentWarnings(_ logs: [RouteManager.LogEntry], limit: Int = 3) -> [RouteManager.LogEntry] {
        Array(logs.filter { LogLevelFilter.warnings.admits($0.level) }.prefix(limit))
    }
}

extension DropdownStatus.Input {
    /// Everything the status sentence reads, from the live app state. The dropdown's header
    /// and the Status page both build their input here, so they read the same facts.
    @MainActor
    static func current(_ routeManager: RouteManager, helperReady: Bool) -> DropdownStatus.Input {
        let config = routeManager.config
        let mode: DropdownCopy.Mode = RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode)
            ? .custom
            : (config.routingMode == .vpnOnly ? .vpnOnly : .bypass)
        return DropdownStatus.Input(
            isVPNConnected: routeManager.isVPNConnected,
            vpnName: routeManager.vpnType.flatMap { $0 == .unknown ? nil : $0.rawValue },
            helperReady: helperReady,
            mode: mode,
            enabledServices: config.services.filter { $0.enabled }.count,
            enabledDomains: mode == .vpnOnly
                ? config.inverseDomains.filter { $0.enabled }.count
                : config.domains.filter { $0.enabled }.count,
            enabledRules: config.rules.filter { $0.enabled }.count,
            installedRoutes: routeManager.routedAddressCount,
            pending: routeManager.pendingReconnectApply,
            lastRouteChange: routeManager.lastRouteChange,
            lastDNSRefresh: routeManager.lastDNSRefresh,
            nextDNSRefresh: routeManager.nextDNSRefresh,
            autoDNSRefresh: config.autoDNSRefresh,
            nothingConfigured: FirstRunSetup.isFresh(mode: config.routingMode,
                                                     domains: config.domains,
                                                     services: config.services,
                                                     installedRoutes: routeManager.routedAddressCount),
            everythingElseDirect: routeManager.everythingElseDirect
        )
    }
}

// MARK: - Page

struct StatusTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var helperManager = HelperManager.shared
    /// Opens the Logs page with Warnings selected.
    private let onShowWarnings: () -> Void
    /// False when a snapshot was handed in: the page shows it as given, so a test or a render
    /// can show any tunnel state, until Refresh reads the real one.
    private let readsTunnelsOnChange: Bool

    @State private var snapshot: RouteManager.CoexistenceSnapshot?
    @State private var isReadingTunnels = false

    init(onShowWarnings: @escaping () -> Void = {}, snapshot: RouteManager.CoexistenceSnapshot? = nil) {
        self.onShowWarnings = onShowWarnings
        _snapshot = State(initialValue: snapshot)
        readsTunnelsOnChange = snapshot == nil
    }

    var body: some View {
        // Ticks once a second so the ages and the DNS countdown stay true while the page is open.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .task { if readsTunnelsOnChange { await readTunnels() } }
        .onChange(of: StatusPage.TunnelReadKey.current(routeManager)) { _ in
            if readsTunnelsOnChange { Task { await readTunnels() } }
        }
    }

    private func content(now: Date) -> some View {
        let input = DropdownStatus.Input.current(routeManager, helperReady: helperManager.helperState.isReady)
        return VStack(alignment: .leading, spacing: 18) {
            summaryView(StatusPage.summary(input, now: now))
            helperSection
            connectionSection
            routesSection(input, now: now)
            dnsSection(now: now)
            tunnelsSection
            warningsSection
        }
    }

    // MARK: Summary

    private func summaryView(_ summary: StatusPage.Summary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(summary.tone.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: summaryIcon(summary.tone))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(summary.tone.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(summary.sentence)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = summary.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryIcon(_ tone: DropdownStatus.Tone) -> String {
        switch tone {
        case .ok: return "checkmark"
        case .warn: return "exclamationmark"
        case .bad: return "xmark"
        case .idle: return "minus"
        }
    }

    // MARK: Sections

    private var helperSection: some View {
        let state = helperManager.helperState
        let line = StatusPage.helperLine(state, version: helperManager.helperVersion)
        // A helper that is not ready is why nothing is routed: its box turns red.
        return StatusSection(String(localized: "Helper"), isAlert: !state.isReady) {
            StatusLineRow(label: String(localized: "Privileged helper"), line: line) {
                if let action = StatusPage.helperAction(state, isInstalling: helperManager.isInstalling) {
                    Button(action) { installHelper() }
                        .disabled(helperManager.isInstalling)
                }
            }
            .help(String(localized: "The helper runs as root and handles route/hosts changes without prompting."))
            if let hint = StatusPage.helperHint(state) {
                StatusNote(text: hint)
            }
            if let error = helperManager.installationError {
                StatusNote(text: error, color: Theme.warning)
            }
        }
    }

    private var connectionSection: some View {
        StatusSection(String(localized: "Connection")) {
            StatusLineRow(label: String(localized: "VPN"),
                          line: StatusPage.vpnLine(isConnected: routeManager.isVPNConnected,
                                                   name: routeManager.vpnType.flatMap { $0 == .unknown ? nil : $0.rawValue },
                                                   interface: routeManager.vpnInterface))
            StatusDivider()
            StatusLineRow(label: String(localized: "Normal connection"),
                          line: StatusPage.normalConnectionLine(ssid: routeManager.currentNetworkSSID,
                                                                gateway: routeManager.localGateway))
            StatusDivider()
            StatusLineRow(label: String(localized: "Default route"), line: StatusPage.defaultRouteLine(snapshot))
        }
    }

    private func routesSection(_ input: DropdownStatus.Input, now: Date) -> some View {
        StatusSection(String(localized: "Addresses")) {
            StatusLineRow(label: String(localized: "Routed"),
                          line: StatusPage.appliedLine(installed: routeManager.routedAddressCount,
                                                       lastChange: routeManager.lastRouteChange, now: now))
            StatusDivider()
            StatusLineRow(label: String(localized: "From"), line: StatusPage.fromLine(input))
            StatusDivider()
            let check = StatusPage.lastCheck(routeManager, now: now)
            StatusLineRow(label: String(localized: "Last check"), line: check.line) {
                HStack(spacing: 6) {
                    if check.isChecking {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                    Button(String(localized: "Verify")) { verify() }
                        .disabled(!check.canVerify)
                }
            }
        }
    }

    private func dnsSection(now: Date) -> some View {
        StatusSection(String(localized: "DNS")) {
            StatusLineRow(label: String(localized: "Resolver"),
                          line: StatusPage.resolverLine(routeManager.detectedDNSServerDisplay))
            StatusDivider()
            StatusLineRow(label: String(localized: "Refreshed"),
                          line: StatusPage.refreshedLine(last: routeManager.lastDNSRefresh,
                                                         next: routeManager.nextDNSRefresh,
                                                         automatic: routeManager.config.autoDNSRefresh,
                                                         now: now)) {
                Button(String(localized: "Refresh Now")) { routeManager.forceDNSRefresh() }
                    .disabled(routeManager.isApplyingRoutes)
            }
        }
    }

    private var tunnelsSection: some View {
        StatusSection(String(localized: "Tunnels"), trailing: {
            Button(String(localized: "Refresh")) { Task { await readTunnels() } }
                .buttonStyle(.link)
                .disabled(isReadingTunnels)
        }) {
            if let snapshot {
                if snapshot.links.isEmpty {
                    StatusPlainRow(text: String(localized: "No VPN tunnels are up."))
                } else {
                    ForEach(snapshot.links) { link in
                        HStack(spacing: 10) {
                            Text(link.interface)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            Text(VPNType.displayLabel(link.label))
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(StatusPage.tunnelLine(link, snapshot: snapshot))
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        StatusDivider()
                    }
                }
                actOnRow(snapshot)
                if let pinned = routeManager.config.pinnedVPNInterface,
                   let selected = snapshot.selectedInterface, pinned != selected {
                    StatusNote(text: String(localized: "Pinned tunnel \(pinned) is not eligible right now — acting on \(selected) automatically."),
                               color: Theme.warning)
                }
                StatusDivider()
                StatusLineRow(label: String(localized: "Addresses owned (kernel-tagged)"),
                              line: StatusPage.ownedLine(tagged: snapshot.taggedDestinations,
                                                         installed: routeManager.installedRoutes,
                                                         vpnOnly: routeManager.config.routingMode == .vpnOnly))
            } else {
                StatusPlainRow(text: String(localized: "Reading network state…"))
            }
        }
    }

    /// The pin: act only on one tunnel. A stale pin degrades to automatic with a logged
    /// warning, never to a silent no-op.
    private func actOnRow(_ snapshot: RouteManager.CoexistenceSnapshot) -> some View {
        HStack {
            Text(String(localized: "Act on"))
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Picker(String(localized: "Act on"), selection: Binding(
                get: { routeManager.config.pinnedVPNInterface ?? "" },
                set: { iface in
                    routeManager.config.pinnedVPNInterface = iface.isEmpty ? nil : iface
                    routeManager.config.pinnedVPNProductHint = iface.isEmpty ? nil
                        : snapshot.links.first(where: { $0.interface == iface })?.label
                    routeManager.saveConfig()
                    Task {
                        await routeManager.reconcileAfterConfigChange(reconcileListeners: false, reapplyRoutes: true)
                        await readTunnels()
                    }
                }
            )) {
                Text(String(localized: "Automatic (recommended)")).tag("")
                ForEach(snapshot.links.filter { !$0.isTailscale }) { link in
                    Text("\(VPNType.displayLabel(link.label)) · \(link.interface)").tag(link.interface)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var warningsSection: some View {
        let warnings = StatusPage.recentWarnings(routeManager.recentLogs)
        return StatusSection(String(localized: "Recent warnings"), trailing: {
            Button(String(localized: "Show in Log")) { onShowWarnings() }
                .buttonStyle(.link)
        }) {
            if warnings.isEmpty {
                StatusPlainRow(text: String(localized: "No warnings or errors."))
            } else {
                ForEach(Array(warnings.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { StatusDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.level == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(entry.level == .error ? Theme.error : Theme.warning)
                        Text(entry.timestamp, format: .dateTime.hour().minute())
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                        Text(entry.message)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    // MARK: Actions

    /// On appear, on a `TunnelReadKey` change and on Refresh only: the read spawns `ifconfig`
    /// and `tailscale status`, which must never sit on a timer.
    private func readTunnels() async {
        isReadingTunnels = true
        snapshot = await routeManager.coexistenceSnapshot()
        isReadingTunnels = false
    }

    /// The spinner and the greyed-out button follow `isCheckingRoutes`, the flag every check
    /// sets, so this page never starts a second check over one an apply or the dropdown began.
    private func verify() {
        guard !routeManager.isCheckingRoutes else { return }
        Task { await routeManager.verifyRoutes() }
    }

    private func installHelper() {
        Task {
            let ready = await helperManager.ensureHelperReady()
            if ready && routeManager.isVPNConnected && routeManager.activeRoutes.isEmpty {
                // Helper just became ready and VPN is connected but no routes: the initial
                // startup was skipped because the helper wasn't ready. Apply routes and start
                // the DNS refresh lifecycle.
                await routeManager.detectAndApplyRoutesAsync()
                routeManager.startDNSRefreshTimer()
            }
        }
    }
}

// MARK: - Building blocks

/// A heading and a rounded box of rows, laid out like a grouped form in System Settings.
struct StatusSection<Content: View, Trailing: View>: View {
    let title: String
    /// Outlines the box in red, for the row that explains why nothing works.
    let isAlert: Bool
    let trailing: Trailing
    let content: Content

    init(_ title: String, isAlert: Bool = false, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.isAlert = isAlert
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                trailing
                    .font(.system(size: 12))
            }
            .frame(minHeight: 16)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isAlert ? Theme.error.opacity(0.7) : Theme.bgCardBorder, lineWidth: 1)
                    )
            )
        }
    }
}

extension StatusSection where Trailing == EmptyView {
    init(_ title: String, isAlert: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title, isAlert: isAlert, trailing: { EmptyView() }, content: content)
    }
}

/// A label on the left, a value on the right with an optional dot, and an optional button.
struct StatusLineRow<Accessory: View>: View {
    let label: String
    let line: StatusPage.Line
    let accessory: Accessory

    init(label: String, line: StatusPage.Line, @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        self.line = line
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if let tone = line.tone {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 7, height: 7)
                }
                Text(line.text)
                    .font(.system(size: 13))
                    // A fault reads in its colour; a healthy value stays grey beside its green dot.
                    .foregroundColor(line.tone.flatMap { $0 == .warn || $0 == .bad ? $0.color : nil } ?? Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            accessory
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

extension StatusLineRow where Accessory == EmptyView {
    init(label: String, line: StatusPage.Line) {
        self.init(label: label, line: line, accessory: { EmptyView() })
    }
}

/// A row that is one sentence, such as "No VPN tunnels are up."
struct StatusPlainRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
    }
}

/// A small line under a row: why the helper is not ready, a stale pin.
struct StatusNote: View {
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
    }
}

struct StatusDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .padding(.leading, 14)
    }
}
