// MenuBarViews.swift
// Menu bar label and dropdown content.

import SwiftUI

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var helperManager = HelperManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    private static let iconDefault: NSImage? = loadTemplateIcon("menubar-icon")
    private static let iconActive: NSImage? = loadTemplateIcon("menubar-icon-active")
    private static let iconError: NSImage? = loadTemplateIcon("menubar-icon-error")

    private static func loadTemplateIcon(_ name: String) -> NSImage? {
        guard let img = Bundle.main.image(forResource: name) else { return nil }
        img.isTemplate = true
        return img
    }

    private var currentIcon: NSImage? {
        if helperManager.helperState.isFailed {
            return Self.iconError
        } else if routeManager.isVPNConnected && !routeManager.activeRoutes.isEmpty {
            return Self.iconActive
        }
        return Self.iconDefault
    }

    /// States the routing CONTRACT, not just a count.
    ///
    /// Bypass and VPN Only are near-opposites — one sends everything through the VPN except your
    /// list, the other sends everything direct except your list — and the menu bar rendered them
    /// identically: same glyph, same number. A user who changed mode a week ago had no ambient way
    /// to tell which one was running, which is precisely the confusion behind a user reporting that
    /// their public IP was their real one "while the app was on".
    private var iconAccessibilityLabel: String {
        if helperManager.helperState.isFailed {
            return String(localized: "VPN Bypass: helper error, nothing is being routed")
        }
        guard routeManager.isVPNConnected else {
            return String(localized: "VPN Bypass: no VPN detected, nothing is being routed")
        }
        let count = routeManager.routedAddressCount
        guard !routeManager.activeRoutes.isEmpty else {
            return String(localized: "VPN Bypass: VPN connected but nothing is being routed")
        }
        switch routeManager.config.routingMode {
        case .vpnOnly:
            return String(localized: "VPN Bypass — VPN Only: \(count) destinations use the VPN, everything else is direct")
        case .custom:
            return String(localized: "VPN Bypass — Custom: \(count) destinations routed by your rules")
        default:
            return String(localized: "VPN Bypass — Bypass: \(count) destinations skip the VPN, everything else is tunnelled")
        }
    }

    private var menuBarIcon: some View {
        Group {
            if let nsImage = currentIcon ?? Self.iconDefault {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: routeManager.isVPNConnected ? "shield.checkered" : "shield")
                    .font(.system(size: 15))
            }
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                if (routeManager.isLoading || routeManager.isApplyingRoutes) && !reduceMotion {
                    menuBarIcon
                        .opacity(isAnimating ? 0.4 : 1.0)
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true),
                            value: isAnimating
                        )
                        .onAppear { isAnimating = true }
                        .onDisappear { isAnimating = false }
                } else {
                    menuBarIcon
                }
            }

            // No route count in the menu bar: it is noise at a glance (the number changes with
            // DNS churn, not with anything the user did) and the accessibility label + dropdown
            // carry the real state. Removed deliberately — do not reintroduce.
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(iconAccessibilityLabel)
    }
}

// MARK: - Dropdown opens

/// Runs `action` each time the window holding it becomes key. A MenuBarExtra(.window) reuses one
/// window and one view tree for the app's life: `.onAppear` runs on the first open only and
/// `.onDisappear` never runs, but the window becomes key on every open. Use this, not
/// `.onAppear`, for anything the dropdown should do each time it opens.
struct WindowBecameKeyObserver: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.action = action
    }

    final class ObserverView: NSView {
        var action: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.action?() }
            }
            // The first open can make the window key before this view is in it.
            if window.isKeyWindow { action?() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - Branded App Name View (for use in dropdowns/settings)

struct BrandedAppName: View {
    var fontSize: CGFloat = 15
    /// Show the mark alongside the type (the full lockup).
    ///
    /// Defaults OFF. Every surface that shows this wordmark already has the mark nearby — the
    /// app icon above it, or the menu bar icon it hangs from — so showing it again duplicated
    /// the mark AND pushed the type off-centre, because the lockup centres as one unit while
    /// the icon above centres on its own.
    var showsMark: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if showsMark, let mark = Bundle.main.image(forResource: "menubar-icon-active") {
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fontSize * 1.25, height: fontSize * 1.25)
                    .foregroundStyle(Theme.Brand.sky)
                    .padding(.trailing, fontSize * 0.42)
            }
            // Weight contrast, not colour contrast, carries the lockup — the same relationship
            // the banner and app icon use, so the three read as one identity.
            //
            // The gap is required: set solid, "VPN"+"Bypass" reads as one word, "VPNBypass".
            // The banner has always had this gap; the SwiftUI lockup was missing it.
            Text("VPN")
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .padding(.trailing, fontSize * 0.16)

            Text("Bypass")
                .font(.system(size: fontSize, weight: .light, design: .rounded))
                .foregroundColor(Theme.Brand.sky)
        }
    }
}

// MARK: - Quick add

/// The dropdown's quick-add field, with why the last add saved nothing under it.
struct QuickAddField: View {
    @Binding var text: String
    let error: AddDomainFeedback?
    let onAdd: () -> Void
    let onCancel: () -> Void

    private let accentGradient = LinearGradient(
        colors: [Theme.success, Theme.successDark],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("domain.com", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)
                    .onSubmit {
                        onAdd()
                    }

                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(accentGradient)
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
                .accessibilityLabel(String(localized: "Add"))

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Cancel"))
            }
            if let error {
                AddDomainFeedbackLine(feedback: error)
            }
        }
    }
}

// MARK: - Menu Content

struct MenuContent: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject private var helperManager = HelperManager.shared
    @State private var newDomain = ""
    @State private var isAddingDomain = false
    /// Why the last quick-add saved nothing, shown under the field, which stays open.
    @State private var quickAddError: AddDomainFeedback?
    /// Remove All Routes… asks first: it sends the listed traffic back through the VPN.
    @State private var confirmingRemoveAll = false

    private let accentGradient = LinearGradient(
        colors: [Theme.success, Theme.successDark],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    var body: some View {
        VStack(spacing: 0) {
            // Ticks once a second so the WAITING countdown and the ages stay true while open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = DropdownStatus.make(statusInput, now: context.date)
                VStack(spacing: 0) {
                    titleHeader(status)
                    helperDownBanner
                    StatusHeader(status: status, iconName: statusIconName)
                }
            }

            if showsFirstRun {
                // A fresh install: ask what should skip the VPN, in place of the mode control
                // and the route actions, which have nothing to act on yet.
                FirstRunSetupView(
                    onOpenServices: { openSettings(page: .services) },
                    onUseVPNOnly: {
                        // Through the run loop, for the reason given in DropdownModeRow.
                        RunLoop.main.perform(inModes: [.common]) {
                            DropdownModePicker.askAndSwitch(to: .vpnOnly, routeManager: routeManager)
                        }
                    })
                    .padding(.top, 16)
            } else {
                DropdownModeRow()

                Divider()
                    .padding(.vertical, 8)

                // Main content
                if routeManager.isLoading && routeManager.lastUpdate == nil {
                    loadingContent
                } else if routeManager.isVPNConnected {
                    connectedContent
                } else {
                    disconnectedContent
                }
            }

            Divider()
                .padding(.vertical, 8)
            
            // Footer actions
            footerActions
        }
        .padding(16)
        .frame(width: 340)
        // Refresh the VPN status on every open. Not `.onAppear`: a MenuBarExtra(.window) keeps
        // one window and one view for the app's life, so `.onAppear` runs on the first open only.
        .background(WindowBecameKeyObserver { routeManager.refreshStatus() })
    }

    /// Nothing configured yet (`FirstRunSetup.isFresh`), read now.
    private var isFresh: Bool {
        FirstRunSetup.isFresh(mode: routeManager.config.routingMode,
                              domains: routeManager.config.domains,
                              services: routeManager.config.services,
                              installedRoutes: routeManager.routedAddressCount)
    }

    /// The first-run question shows once the app has finished its first detection, while
    /// nothing is configured, read live. A MenuBarExtra(.window) runs `.onAppear` on its first
    /// open only and never runs `.onDisappear`, so a value latched on open would never reset.
    private var showsFirstRun: Bool {
        guard !(routeManager.isLoading && routeManager.lastUpdate == nil) else { return false }
        return isFresh
    }

    // MARK: - Title Header
    
    private func titleHeader(_ status: DropdownStatus) -> some View {
        HStack(spacing: 8) {
            // App name with branded colors
            BrandedAppName(fontSize: 15)

            Spacer()

            StatusPill(status: status)
        }
        .padding(.bottom, 12)
    }

    /// Everything the status header reads, gathered in one place so the wording lives in the
    /// pure `DropdownStatus.make`.
    private var statusInput: DropdownStatus.Input {
        DropdownStatus.Input.current(routeManager, helperReady: helperManager.helperState.isReady)
    }

    private var statusIconName: String {
        routeManager.isVPNConnected ? (routeManager.vpnType?.icon ?? "checkmark.shield.fill") : "shield.slash.fill"
    }

    /// Shown at the top of the dropdown whenever the helper cannot enforce anything while a
    /// VPN is connected — the state that used to be one log line nobody saw.
    @ViewBuilder
    private var helperDownBanner: some View {
        if routeManager.isVPNConnected && !helperManager.helperState.isReady {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Helper not running — nothing is being routed"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(helperManager.helperState.statusText)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(String(localized: "Fix…")) {
                    // The Status page holds the helper's row and its Install button.
                    openSettings(page: .status)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.12)))
            .padding(.bottom, 8)
        }
    }
    
    // MARK: - Connected Content
    
    private var connectedContent: some View {
        VStack(spacing: 12) {
            // Quick add domain
            if isAddingDomain {
                QuickAddField(text: $newDomain, error: quickAddError, onAdd: addDomainAndClose, onCancel: closeQuickAdd)
                    .onChange(of: newDomain) { text in
                        if text != quickAddError?.fieldText { quickAddError = nil }
                    }
            } else {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        isAddingDomain = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                        Text(routeManager.config.routingMode == .vpnOnly ? String(localized: "Add Domain to VPN") : String(localized: "Add Domain to Bypass"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            
            // Routes in use (custom mode)
            if routeManager.config.routingMode == .custom {
                routesInUseSummary
            }

            // What is routed, one row per entry the user added
            if let routed = RoutedBySource.make(
                mode: statusInput.mode, config: routeManager.config,
                routes: routeManager.installedRoutes,
                busy: RoutedBySource.mayStillAddRoutes(running: isBusy, pending: routeManager.pendingReconnectApply)) {
                RoutedBySourceCard(summary: routed)
            }
            
            // The last Verify Routes: what it checked, failures first
            if let run = routeManager.lastRouteCheck {
                RouteCheckCard(run: run,
                               logsHoldResults: run.logsHoldResults(oldestLogAt: routeManager.recentLogs.last?.timestamp),
                               onShowLogs: { openSettings(page: .logs) })
            }
            
            actionButtons
        }
        .alert(removeAllCopy.title, isPresented: $confirmingRemoveAll) {
            Button(String(localized: "Remove Routes"), role: .destructive) {
                Task { await routeManager.removeAllRoutes() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(removeAllCopy.message)
        }
    }

    // MARK: - Actions

    /// Refresh, apply or DNS work is running (the route-operation gate is held, or a refresh
    /// is still detecting the network before it takes the gate).
    private var isBusy: Bool {
        routeManager.isLoading || routeManager.isApplyingRoutes
    }

    /// One primary action. Verify sits next to it as an icon; everything else, and the one
    /// action that removes every route, lives behind the "…" menu.
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    refresh()
                } label: {
                    HStack(spacing: 6) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text(isBusy ? String(localized: "Refreshing routes…") : String(localized: "Refresh Routes"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(accentGradient)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .opacity(isBusy ? 0.85 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .keyboardShortcut(.refreshRoutes)
                .help(DropdownShortcut.refreshRoutes.help(String(localized: "Refresh Routes")))

                Button {
                    verify()
                } label: {
                    Group {
                        if routeManager.isCheckingRoutes {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 13))
                        }
                    }
                    .frame(width: 34, height: 30)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(routeManager.isCheckingRoutes || routeManager.activeRoutes.isEmpty)
                .help(String(localized: "Verify Routes"))
                .accessibilityLabel(String(localized: "Verify Routes"))

                // The shortcuts here only answer while the menu is open; the buttons that do
                // the same thing (Refresh Routes, the gear, the power button) carry them too.
                Menu {
                    Button(DropdownShortcut.refreshRoutes.title) { refresh() }
                        .keyboardShortcut(.refreshRoutes)
                        .disabled(isBusy)
                    Button(String(localized: "Verify Routes")) { verify() }
                        .disabled(routeManager.isCheckingRoutes || routeManager.activeRoutes.isEmpty)
                    Button(String(localized: "Re-resolve DNS Now")) { routeManager.forceDNSRefresh() }
                        .disabled(isBusy)
                    Button(String(localized: "Open Logs")) { openSettings(page: .logs) }
                    Divider()
                    Button(DropdownShortcut.settings.title) { openSettings() }
                        .keyboardShortcut(.settings)
                    Button(DropdownShortcut.quit.title) { quit() }
                        .keyboardShortcut(.quit)
                    Divider()
                    Button(String(localized: "Remove All Routes…")) { confirmingRemoveAll = true }
                        .disabled(routeManager.activeRoutes.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34, height: 30)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
                .help(String(localized: "More actions"))
                .accessibilityLabel(String(localized: "More actions"))
            }

            routeChangeLine
        }
    }

    /// The result of the last apply (or Remove All), under the buttons. Ticks once a second so
    /// the age stays true while the dropdown is open.
    @ViewBuilder
    private var routeChangeLine: some View {
        if let outcome = DropdownCopy.shownRouteChange(routeManager.lastRouteChange,
                                                       currentRouteCount: routeManager.routedAddressCount) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let line = DropdownCopy.routeChangeLine(outcome, now: context.date)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: line.isProblem ? "exclamationmark.triangle.fill" : "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(line.isProblem ? Theme.warning : Theme.success)
                    Text(line.text)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .help(DropdownCopy.routeChangeHelp)
        }
    }

    private var removeAllCopy: (title: String, message: String) {
        let config = routeManager.config
        return DropdownCopy.removeAllConfirmation(
            mode: RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) ? .custom : (config.routingMode == .vpnOnly ? .vpnOnly : .bypass),
            routeCount: routeManager.routedAddressCount,
            serviceCount: config.services.filter { $0.enabled }.count,
            domainCount: config.routingMode == .vpnOnly
                ? config.inverseDomains.filter { $0.enabled }.count
                : config.domains.filter { $0.enabled }.count,
            autoApplyOnVPN: config.autoApplyOnVPN,
            autoDNSRefresh: config.autoDNSRefresh
        )
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Refresh Routes, from its button, its menu item or ⌘R. A held ⌘R sends key repeats and
    /// SwiftUI runs the action for each one; the button turns active again between refreshes,
    /// so without this a held key would start one refresh after another.
    private func refresh() {
        guard !DropdownShortcut.isKeyRepeat(NSApp.currentEvent) else { return }
        routeManager.refreshRoutes()
    }

    private func verify() {
        guard !routeManager.isCheckingRoutes else { return }
        Task { await routeManager.verifyRoutes() }
    }

    // MARK: - Loading Content
    
    private var loadingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .progressViewStyle(CircularProgressViewStyle())
            
            VStack(spacing: 4) {
                Text("Setting Up...")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                
                Text("Detecting VPN and applying routes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    
    // MARK: - Disconnected Content
    
    private var disconnectedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 4) {
                Text("No VPN Connection")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                
                Text("Connect to a VPN to start bypassing\ntraffic for configured services.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Show enabled counts (mode-aware)
            if routeManager.config.routingMode == .vpnOnly {
                let enabledDomains = routeManager.config.inverseDomains.filter { $0.enabled }
                HStack(spacing: 16) {
                    StatBadge(value: "\(enabledDomains.count)", label: "VPN Entries")
                }
            } else {
                let enabledServices = routeManager.config.services.filter { $0.enabled }
                let enabledDomains = routeManager.config.domains.filter { $0.enabled }
                HStack(spacing: 16) {
                    StatBadge(value: "\(enabledServices.count)", label: "Services")
                    StatBadge(value: "\(enabledDomains.count)", label: "Domains")
                }
            }
            
            // Network info
            if let ssid = routeManager.currentNetworkSSID {
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(ssid)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Routes In Use Summary (Custom mode)

    /// Custom mode: enabled routes that at least one enabled rule actually points at. On screen
    /// "route" means only these ways out (proposal 16 of #119); the kernel entries the app
    /// installs are "addresses".
    private var routesInUseSummary: some View {
        let routesWithRules = routeManager.config.routes.filter { route in
            route.enabled && routeManager.config.rules.contains { $0.enabled && $0.routeId == route.id }
        }
        let maxVisible = 4
        let visibleRoutes = Array(routesWithRules.prefix(maxVisible))
        let remainingCount = routesWithRules.count - maxVisible

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Routes In Use")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(routesWithRules.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.success)
            }

            if routesWithRules.isEmpty {
                Text("No rules configured")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(visibleRoutes) { route in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(route.accentColor)
                            .frame(width: 4, height: 4)
                        Text(route.friendlyName(vpnName: routeManager.vpnType?.knownName))
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }

                if remainingCount > 0 {
                    Text("+\(remainingCount) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 8) {
            // No "Updated … ago" here: it did not say what was updated, and Clear stamped it
            // too, so it read fresh right after every route was removed. The result line under
            // Refresh Routes says what the last apply did. What a script or an agent changed
            // through the control socket shows here instead (proposal 15 of #119).
            if let change = routeManager.lastOutsideChange,
               change.isShown(currentRouteCount: routeManager.routedAddressCount,
                              everythingElseDirect: routeManager.everythingElseDirect) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    OutsideChangeLine(change: change, now: context.date) {
                        SettingsPageRequest.shared.logFilter = LogFilter(onlyControlSocket: true)
                        openSettings(page: .logs)
                    }
                }
            }

            Spacer(minLength: 0)
            
            DropdownIconButton(systemImage: "gearshape.fill", name: String(localized: "Settings"),
                               shortcut: .settings) { openSettings() }

            DropdownIconButton(systemImage: "power", name: String(localized: "Quit VPN Bypass"),
                               shortcut: .quit) { quit() }
        }
    }
    
    
    // MARK: - Helpers
    
    private func addDomainAndClose() {
        guard !newDomain.isEmpty else { return }
        let result: Result<AddedDomain, AddDomainError>?
        if routeManager.config.routingMode == .vpnOnly {
            result = routeManager.addInverseDomain(newDomain)
        } else if RouteManager.usesCustomEngine(schemaVersion: routeManager.config.schemaVersion, routingMode: routeManager.config.routingMode) {
            result = addDomainRuleToDirect(newDomain).map { .failure($0) }
        } else {
            result = routeManager.addDomain(newDomain)
        }
        let next = Self.quickAdd(after: result, typed: newDomain)
        newDomain = next.text
        quickAddError = next.error
        isAddingDomain = next.isOpen
    }

    /// The quick-add after an add. A refused one stays open with the text and says why,
    /// as the Domains tab does, because closing would look like it worked. A saved one
    /// closes. nil is Custom mode's rule add when it saved, which says nothing back.
    static func quickAdd(after result: Result<AddedDomain, AddDomainError>?, typed: String) -> QuickAddState {
        guard let result else { return .closed }
        let shown = AddDomainFeedback(result, typed: typed)
        return shown.isError ? QuickAddState(text: shown.fieldText, isOpen: true, error: shown) : .closed
    }

    struct QuickAddState: Equatable {
        let text: String
        let isOpen: Bool
        let error: AddDomainFeedback?

        static let closed = QuickAddState(text: "", isOpen: false, error: nil)
    }

    private func closeQuickAdd() {
        newDomain = ""
        quickAddError = nil
        isAddingDomain = false
    }

    /// Custom mode routes from `config.rules`, not `config.domains` (see
    /// `RouteManager.usesCustomEngine`), so the quick-add above would silently do
    /// nothing there. Add a rule to the Direct route instead - the same mapping
    /// `RouteManager.Config.derive()` uses for a bypass-mode domain - so quick-add
    /// behaves like "bypass this" in Custom mode too: a range becomes a `.cidr` rule,
    /// anything else a `.domain` rule (see `RouteManager.addDirectRule`). Returns why
    /// the input was refused, nil otherwise.
    private func addDomainRuleToDirect(_ input: String) -> AddDomainError? {
        switch routeManager.addDirectRule(input) {
        case .success?:
            Task { await routeManager.reconcileAfterConfigChange(reconcileListeners: false, reapplyRoutes: true) }
            return nil
        case .failure(let error)?:
            return error
        case nil:
            return nil
        }
    }

    private func openSettings(page: SettingsView.SettingsTab? = nil) {
        // Close the MenuBarExtra dropdown window
        // The dropdown is the current key window when clicking inside it
        if let menuWindow = NSApp.keyWindow {
            menuWindow.close()
        }
        
        // Activate the app first, then show settings
        // Longer delay on first open helps with initialization
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            SettingsWindowController.shared.show(page: page)
        }
    }
}

// MARK: - Last outside change

/// The footer's "Last change: added en.wikipedia.org via the command line, 2 min ago". A click
/// opens Logs at the lines that came through the control socket.
struct OutsideChangeLine: View {
    let change: OutsideChange
    let now: Date
    let onShowLogs: () -> Void

    private var text: AttributedString {
        let line = change.line(now: now)
        var text = AttributedString(line.text)
        if let subject = line.subject, let range = text.range(of: subject) {
            text[range].foregroundColor = .primary
            text[range].font = .system(size: 11, weight: .medium)
        }
        return text
    }

    var body: some View {
        Button(action: onShowLogs) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(OutsideChange.help)
    }
}

// MARK: - Dropdown copy

/// The dropdown's sentences, kept pure so the wording and its edge cases are unit-tested.
enum DropdownCopy {
    enum Mode: Equatable {
        case bypass, vpnOnly, custom
    }

    /// A short age: "just now", "23 s ago", "4 min ago", "2 h ago". A date in the future
    /// (clock moved back) reads as "just now" rather than a negative age.
    static func age(since date: Date, now: Date) -> String { age(since: date, now: now, in: .main) }

    static func age(since date: Date, now: Date, in bundle: Bundle) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return String(localized: "just now", bundle: bundle) }
        if seconds < 60 { return String(localized: "\(seconds) s ago", bundle: bundle) }
        if seconds < 3600 { return String(localized: "\(seconds / 60) min ago", bundle: bundle) }
        return String(localized: "\(seconds / 3600) h ago", bundle: bundle)
    }

    private static func routes(_ count: Int) -> String {
        count == 1 ? String(localized: "1 address") : String(localized: "\(count) addresses")
    }

    /// The outcome the result line shows, or nil to show none. A removal is a claim about what
    /// is installed now, so it stops showing once the route count moves: a DNS refresh, a new
    /// domain or a newly enabled service brings routes back without a full apply, and the line
    /// would otherwise keep saying "All routes removed" under a list of live routes.
    static func shownRouteChange(_ outcome: RouteManager.RouteChangeOutcome?,
                                 currentRouteCount: Int) -> RouteManager.RouteChangeOutcome? {
        guard let outcome else { return nil }
        if outcome.kind == .removedAll && outcome.routeCount != currentRouteCount { return nil }
        return outcome
    }

    /// The tooltip on the result line. Its failed count counts addresses, so the tooltip says so.
    static var routeChangeHelp: String {
        String(localized: "Failures are addresses the system refused and, on an apply that resolved DNS, domains that did not resolve. Settings > Logs has the details.")
    }

    /// The line under Refresh Routes. `isProblem` turns its mark amber.
    static func routeChangeLine(_ outcome: RouteManager.RouteChangeOutcome, now: Date) -> (text: String, isProblem: Bool) {
        let when = age(since: outcome.at, now: now)
        switch outcome.kind {
        case .applied:
            if outcome.routeCount == 0 && outcome.failedCount == 0 {
                return (String(localized: "No addresses to route, checked \(when)."), false)
            }
            if outcome.failedCount == 0 {
                return (String(localized: "\(routes(outcome.routeCount)) routed \(when), none failed."), false)
            }
            return (String(localized: "\(routes(outcome.routeCount)) routed \(when), \(outcome.failedCount) failed."), true)
        case .removedAll:
            if outcome.failedCount == 0 {
                // No promise that Refresh brings them back: when the removal came from a mode
                // switch or re-route whose apply was then refused (VPN Only under GlobalProtect),
                // Refresh is refused the same way.
                return (String(localized: "Removed all routed addresses \(when)."), true)
            }
            return (String(localized: "Removed routed addresses \(when), \(outcome.failedCount) could not be removed."), true)
        }
    }

    /// Remove All Routes… asks this before it runs. The message says what the removal costs in
    /// the user's own terms: which of their entries lose their route, and until when.
    ///
    /// The until-clause names only the recoveries that will happen: a reconnect re-applies only
    /// with auto-apply on VPN connect on, and a DNS refresh only with the automatic refresh on
    /// and never in VPN Only, where it does not reinstall the catch-all routes.
    static func removeAllConfirmation(mode: Mode, routeCount: Int, serviceCount: Int, domainCount: Int,
                                      autoApplyOnVPN: Bool, autoDNSRefresh: Bool) -> (title: String, message: String) {
        let title: String
        if routeCount == 0 && mode == .vpnOnly {
            // Only the catch-alls are installed (the item is off with nothing installed), and
            // the count leaves them out.
            title = String(localized: "Stop sending everything else direct?")
        } else if routeCount == 1 {
            title = String(localized: "Stop routing the 1 address?")
        } else {
            title = String(localized: "Stop routing all \(routeCount) addresses?")
        }
        let until: String
        switch (autoApplyOnVPN, autoDNSRefresh && mode != .vpnOnly) {
        case (true, true):
            until = String(localized: "until you refresh routes, the VPN reconnects, or DNS is next refreshed")
        case (true, false):
            until = String(localized: "until you refresh routes or the VPN reconnects")
        case (false, true):
            until = String(localized: "until you refresh routes or DNS is next refreshed")
        case (false, false):
            until = String(localized: "until you refresh routes")
        }
        let message: String
        switch mode {
        case .bypass:
            let services = serviceCount == 1 ? String(localized: "1 service") : String(localized: "\(serviceCount) services")
            let domains = domainCount == 1 ? String(localized: "1 domain") : String(localized: "\(domainCount) domains")
            let what: String
            switch (serviceCount > 0, domainCount > 0) {
            case (true, true): what = String(localized: "Your \(services) and \(domains)")
            case (true, false): what = String(localized: "Your \(services)")
            case (false, true): what = String(localized: "Your \(domains)")
            case (false, false): what = String(localized: "Everything this app sends around the VPN")
            }
            message = String(localized: "\(what) will go through the VPN \(until).")
        case .vpnOnly:
            message = String(localized: "VPN Only stops: all traffic follows your VPN's own routing \(until).")
        case .custom:
            message = String(localized: "Traffic your rules send direct or to a specific VPN will follow your VPN's own routing \(until). Rules that use a proxy keep working.")
        }
        return (title, message)
    }
}

// MARK: - Route check

/// What Verify Routes checks and how its card words the result. Verify pings a sample: single
/// addresses only, because ping cannot test a range, and at most `sampleSize` of them, the first
/// in sort order. The card says how many of how many routes that was, lists failures first, and
/// keeps the order the addresses were pinged in. Pure, so the scope and the wording are tested.
enum RouteCheck {
    /// Addresses pinged per check, so a check stays short: each ping can wait 4 s.
    static let sampleSize = 10
    /// Failures listed in the card before "+ N more".
    static let visibleFailures = 3

    struct Plan: Equatable {
        /// The addresses to ping, in the order they are pinged.
        let destinations: [String]
        /// What each of them is routed for: the service, domain or rule that added its route.
        let sources: [String: String]
        /// Routed single addresses, the pool the sample is taken from.
        let singleAddresses: Int
        /// Unique routed destinations, counted as the dropdown's list counts them.
        let routeCount: Int
    }

    /// The result of one check, as the card shows it.
    struct Run {
        /// In the order the addresses were pinged.
        let results: [RouteVerificationResult]
        let sources: [String: String]
        let singleAddresses: Int
        let routeCount: Int
        /// When the check started logging: its result lines are all at or after this.
        let logsFrom: Date
        let at: Date

        init(plan: Plan, results: [RouteVerificationResult], logsFrom: Date, at: Date) {
            self.results = results
            self.sources = plan.sources
            self.singleAddresses = plan.singleAddresses
            self.routeCount = plan.routeCount
            self.logsFrom = logsFrom
            self.at = at
        }

        /// Whether the log still has every result line. It keeps the newest 200 lines and the
        /// Logs page can empty it, and both drop the oldest lines first, so the lines are all
        /// there while the oldest line left is no newer than the check.
        func logsHoldResults(oldestLogAt: Date?) -> Bool {
            guard let oldest = oldestLogAt else { return false }
            return oldest <= logsFrom
        }

        var failures: [RouteVerificationResult] { results.filter { !$0.isReachable } }
        var reachable: [RouteVerificationResult] { results.filter(\.isReachable) }
    }

    /// What to ping. In VPN Only the app's catch-all ranges are left out of the count, as the
    /// list above the card leaves them out. A destination recorded under several sources reads
    /// as the first one.
    static func plan(routes: [RoutedBySource.InstalledRoute], vpnOnly: Bool,
                     isSingleAddress: (String) -> Bool) -> Plan {
        let counted = RoutedBySource.counted(routes, vpnOnly: vpnOnly)
        var sources: [String: String] = [:]
        for route in counted where sources[route.destination] == nil {
            sources[route.destination] = route.source
        }
        let singles = sources.keys.filter(isSingleAddress).sorted()
        let sample = Array(singles.prefix(sampleSize))
        return Plan(destinations: sample,
                    sources: sources.filter { sample.contains($0.key) },
                    singleAddresses: singles.count,
                    routeCount: sources.count)
    }

    /// The card's first sentence. `qualifier` is drawn dimmer, between `main` and the full stop.
    struct Scope: Equatable {
        let main: String
        let qualifier: String?
        var text: String { main + (qualifier.map { " " + $0 } ?? "") + "." }
    }

    static func scope(checked: Int, singleAddresses: Int, routeCount: Int) -> Scope {
        if checked == 0 {
            return Scope(main: routeCount == 1
                ? String(localized: "Nothing to check: the only address is a range, which ping cannot test")
                : String(localized: "Nothing to check: all \(routeCount) addresses are ranges, which ping cannot test"),
                         qualifier: nil)
        }
        if checked >= routeCount {
            return Scope(main: checked == 1
                ? String(localized: "Checked the only address")
                : String(localized: "Checked all \(routeCount) addresses"),
                         qualifier: nil)
        }
        // Ranges were left out only when there are fewer single addresses than routes; when the
        // sample size alone cut the list, the two numbers already say so.
        return Scope(main: checked == 1
                        ? String(localized: "Checked 1 of \(routeCount) addresses")
                        : String(localized: "Checked \(checked) of \(routeCount) addresses"),
                     qualifier: singleAddresses < routeCount ? String(localized: "(single addresses only)") : nil)
    }

    static var title: String { String(localized: "Route check") }
    static var allReachable: String { String(localized: "All reachable.") }

    static func notReachable(_ count: Int) -> String {
        count == 1 ? String(localized: "1 not reachable") : String(localized: "\(count) not reachable")
    }

    static func reachable(_ count: Int) -> String {
        count == 1 ? String(localized: "1 reachable") : String(localized: "\(count) reachable")
    }

    /// "24 to 118 ms", "24 ms", or nil when no reachable address reported a time.
    static func latencyRange(_ results: [RouteVerificationResult]) -> String? {
        let times = results.filter(\.isReachable).compactMap(\.latency).map { Int($0.rounded()) }
        guard let low = times.min(), let high = times.max() else { return nil }
        return low == high ? String(localized: "\(low) ms") : String(localized: "\(low) to \(high) ms")
    }

    static func logsLink(_ checked: Int) -> String {
        checked == 1 ? String(localized: "Show the result in Logs") : String(localized: "Show all \(checked) results in Logs")
    }
}

// MARK: - What is routed, by what the user added

/// The dropdown's list of what is routed: one row per service, domain, IP range or rule the
/// user added, with its route count, in the order Settings lists them. A pure function of the
/// config and the installed routes, so the grouping and the wording are unit-tested. It only
/// reads: nothing here decides what gets routed.
enum RoutedBySource {
    enum Icon: Equatable {
        case service(id: String), domain, ipRange, rule, leftover
    }

    struct Row: Equatable, Identifiable {
        /// The route `source` the row counts.
        let id: String
        let name: String
        let icon: Icon
        let routeCount: Int
        /// An entry that should have routes has none, and no apply is running or waiting that
        /// could add them.
        let isProblem: Bool
        /// The first destinations behind the row, for its tooltip.
        let addresses: [String]
        let hiddenAddresses: Int

        var countText: String {
            routeCount == 0 ? String(localized: "no addresses") : routes(routeCount)
        }

        var tooltip: String {
            let more = hiddenAddresses > 0 ? [String(localized: "+ \(hiddenAddresses) more")] : []
            return (addresses + more).joined(separator: "\n")
        }
    }

    struct Summary: Equatable {
        let title: String
        /// Unique destinations, without the VPN Only catch-alls.
        let routeCount: Int
        let rows: [Row]
        /// Rows past `visibleRows`, shown as "+ N more".
        let hiddenRows: Int
        /// VPN Only's catch-alls are installed: everything not listed goes direct.
        let everythingElseDirect: Bool

        var countText: String { routes(routeCount) }
    }

    struct InstalledRoute: Equatable {
        let destination: String
        let source: String
    }

    static let visibleRows = 8
    static let tooltipAddresses = 10

    /// One of the app's own VPN Only catch-alls, matched the way stale-route cleanup matches
    /// them: by destination and by the source they are recorded under.
    static func isCatchAll(_ route: InstalledRoute) -> Bool {
        route.source == ClassicRouteCompiler.catchAllSource
            && RouteCompiler.catchAllDestinations.contains(route.destination)
    }

    /// The routes every count on screen counts: in VPN Only, all but the catch-alls, which show
    /// only as the "Everything else" line. Left installed in another mode (a switch whose
    /// clean-up has not run yet), they are routes like any other.
    static func counted(_ routes: [InstalledRoute], vpnOnly: Bool) -> [InstalledRoute] {
        vpnOnly ? routes.filter { !isCatchAll($0) } : routes
    }

    /// How many addresses the app routes, as the card, the header, the result line, the
    /// status sentence and the Status page all show it: each destination once, without VPN
    /// Only's catch-alls.
    static func addressCount(_ routes: [InstalledRoute], vpnOnly: Bool) -> Int {
        Set(counted(routes, vpnOnly: vpnOnly).map(\.destination)).count
    }

    /// How many of VPN Only's catch-alls are installed: the routes `addressCount` leaves out.
    /// In another mode `addressCount` counts them as addresses, so this is 0.
    static func catchAllCount(_ routes: [InstalledRoute], vpnOnly: Bool) -> Int {
        vpnOnly ? Set(routes.filter(isCatchAll).map(\.destination)).count : 0
    }

    /// VPN Only's catch-alls are installed: everything not listed goes direct.
    static func everythingElseDirect(_ routes: [InstalledRoute], vpnOnly: Bool) -> Bool {
        catchAllCount(routes, vpnOnly: vpnOnly) > 0
    }

    static func title(_ mode: DropdownCopy.Mode) -> String {
        switch mode {
        case .bypass: return String(localized: "Skipping the VPN")
        case .vpnOnly: return String(localized: "Through the VPN")
        case .custom: return String(localized: "Routed by your rules")
        }
    }

    /// An apply is running, or one is waiting after a reconnect (WAITING / HELD BACK): either
    /// can still add the routes an entry is missing, so the missing routes are not a warning yet.
    static func mayStillAddRoutes(running: Bool, pending: RouteManager.PendingReconnectApply?) -> Bool {
        running || pending != nil
    }

    static var leftoverName: String { String(localized: "Left from earlier") }
    static var everythingElse: String { String(localized: "Everything else") }
    static var direct: String { String(localized: "direct") }

    /// nil when there is nothing to list: no entry on and no route installed (the status line
    /// above already says so).
    static func make(mode: DropdownCopy.Mode, config: RouteManager.Config,
                     routes: [InstalledRoute], busy: Bool) -> Summary? {
        // Each entry's route `source` (what its routes are recorded under) and how it reads.
        // Custom rules that use a proxy or the primary VPN install no kernel route, so a rule
        // with none is normal and is not listed.
        var entries: [(source: String, name: String, icon: Icon, expectsRoutes: Bool)] = []
        switch mode {
        case .bypass:
            entries += config.services.filter(\.enabled).map { ($0.name, $0.name, .service(id: $0.id), true) }
            entries += config.domains.filter(\.enabled).map { ($0.domain, $0.domain, $0.isCIDR ? .ipRange : .domain, true) }
        case .vpnOnly:
            entries += config.inverseDomains.filter(\.enabled).map { ($0.domain, $0.domain, $0.isCIDR ? .ipRange : .domain, true) }
        case .custom:
            for rule in config.rules.filter(\.enabled).sorted(by: { $0.order < $1.order }) {
                // A service rule's pattern is the service id; show the service's name.
                if rule.matchType == .service, let service = config.services.first(where: { $0.id == rule.pattern }) {
                    entries.append((rule.pattern, service.name, .service(id: service.id), false))
                } else {
                    entries.append((rule.pattern, rule.pattern, rule.matchType == .cidr ? .ipRange : .rule, false))
                }
            }
        }

        // Only VPN Only shows its catch-alls, as the "Everything else" line.
        let counted = Self.counted(routes, vpnOnly: mode == .vpnOnly)
        // A destination can be recorded more than once for a source; count it once.
        var bySource: [String: [String]] = [:]
        var seen: Set<String> = []
        for route in counted where seen.insert("\(route.source)|\(route.destination)").inserted {
            bySource[route.source, default: []].append(route.destination)
        }

        func row(id: String, name: String, icon: Icon, destinations: [String], expectsRoutes: Bool) -> Row {
            Row(id: id, name: name, icon: icon, routeCount: destinations.count,
                isProblem: expectsRoutes && destinations.isEmpty && !busy,
                addresses: Array(destinations.prefix(tooltipAddresses)),
                hiddenAddresses: max(0, destinations.count - tooltipAddresses))
        }

        var rows: [Row] = []
        var listed: Set<String> = []
        for entry in entries where !listed.contains(entry.source) {
            listed.insert(entry.source)
            let destinations = bySource[entry.source] ?? []
            if destinations.isEmpty && !entry.expectsRoutes { continue }
            rows.append(row(id: entry.source, name: entry.name, icon: entry.icon,
                            destinations: destinations, expectsRoutes: entry.expectsRoutes))
        }
        // Routes no listed entry owns: an entry removed or switched off while its routes wait
        // for cleanup, or a removal the app retries.
        var leftover: [String] = []
        var seenLeftover: Set<String> = []
        for route in counted where !listed.contains(route.source) && seenLeftover.insert(route.destination).inserted {
            leftover.append(route.destination)
        }
        if !leftover.isEmpty {
            rows.append(row(id: "\u{0}leftover", name: leftoverName, icon: .leftover,
                            destinations: leftover, expectsRoutes: false))
        }

        let everythingElseDirect = Self.everythingElseDirect(routes, vpnOnly: mode == .vpnOnly)
        if rows.isEmpty && !everythingElseDirect { return nil }
        return Summary(title: title(mode),
                       routeCount: addressCount(routes, vpnOnly: mode == .vpnOnly),
                       rows: Array(rows.prefix(visibleRows)),
                       hiddenRows: max(0, rows.count - visibleRows),
                       everythingElseDirect: everythingElseDirect)
    }

    private static func routes(_ count: Int) -> String {
        count == 1 ? String(localized: "1 address") : String(localized: "\(count) addresses")
    }
}

// MARK: - Mode control

/// The Mode row under the status header: one native segmented control with all three modes,
/// the same in every mode. Switching mode changes how all traffic routes, and entering Custom
/// migrates the lists into rules, so a pick asks first. The selection reads the saved mode: the
/// segment moves after Switch, and Cancel leaves it where it was.
struct DropdownModeRow: View {
    @EnvironmentObject var routeManager: RouteManager
    /// The mode a pick is asking about while the question is open.
    @State private var asking: RouteManager.RoutingMode?
    /// Bumped on every pick. The control selects the clicked segment itself, and SwiftUI does
    /// not push the unchanged saved mode back into it, so it is rebuilt from the saved mode.
    @State private var generation = 0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                modeLabel
                picker
                    // A segmented control keeps its own width; line its right edge up with the rows below.
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // The Spanish and French mode names do not fit beside the label: the control takes
            // its own line, at the small size.
            VStack(alignment: .leading, spacing: 6) {
                modeLabel
                picker
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 4)
    }

    private var modeLabel: some View {
        Text("Mode")
            .font(.system(size: 12))
            .foregroundColor(Theme.textSecondary)
    }

    private var picker: some View {
        Picker("Mode", selection: Binding(
            get: { routeManager.config.routingMode },
            set: { picked in
                guard asking == nil,
                      let mode = DropdownModePicker.pendingSwitch(picked: picked, current: routeManager.config.routingMode)
                else { return }
                asking = mode
                generation += 1
                // After this click is handled, so the control is rebuilt from the saved mode.
                // Through the run loop, not DispatchQueue.main: a modal opened inside a
                // main-queue block holds that serial queue for as long as it is open, which
                // stops every main-actor task, the control socket and network-change handling.
                RunLoop.main.perform(inModes: [.common]) { ask(mode) }
            }
        )) {
            ForEach(DropdownModePicker.modes, id: \.self) { mode in
                Text(DropdownModePicker.label(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .id(generation)
        .help(DropdownStatus.modeDescription(DropdownModePicker.copyMode(routeManager.config.routingMode)))
    }

    /// While the question is open the run loop is in its modal panel mode, so the app's
    /// default-mode timers (the 30 s status refresh, the DNS refresh) wait and fire once it
    /// closes. Main-queue work and main-actor tasks keep running.
    private func ask(_ mode: RouteManager.RoutingMode) {
        DropdownModePicker.askAndSwitch(to: mode, routeManager: routeManager)
        asking = nil
    }
}

// MARK: - Status header

/// The top of the dropdown: who is connected, one sentence on what is routed, and a short
/// list of facts. Takes a finished `DropdownStatus`, so any state can be rendered on its own.
struct StatusHeader: View {
    let status: DropdownStatus
    let iconName: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(status.headerTone.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundColor(status.headerTone.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(status.headline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(status.headerTone.color)
                Text(status.sentence)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = status.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !status.facts.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                        ForEach(status.facts, id: \.label) { fact in
                            GridRow {
                                Text(fact.label)
                                    .foregroundColor(Theme.textTertiary)
                                Text(fact.value)
                                    .foregroundColor(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The pill in the title row.
///
/// "ON" is a claim about ENFORCEMENT, not about the VPN: with the helper down this app enforces
/// nothing, and showing a green ON next to "VPN Connected" while zero routes were installed is
/// exactly how a broken install looked healthy for weeks.
struct StatusPill: View {
    let status: DropdownStatus

    var body: some View {
        let color = status.tone.color
        HStack(spacing: 4) {
            if status.tone == .idle {
                Circle()
                    .strokeBorder(color, lineWidth: 1.3)
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .shadow(color: color.opacity(0.6), radius: 3)
            }
            Text(status.pill)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// What the status header says, as a pure function of the app's state, so every state and its
/// wording is unit-tested.
struct DropdownStatus: Equatable {
    enum Tone: Equatable {
        /// `idle` is NOT SET UP: nothing is wrong, nothing is configured yet.
        case ok, warn, bad, idle

        var color: Color {
            switch self {
            case .ok: return Theme.success
            case .warn: return Theme.warning
            case .bad: return Theme.error
            case .idle: return Theme.textSecondary
            }
        }
    }

    /// The header's colour. NOT SET UP is about the lists, not the connection: the VPN is up
    /// and fine, so the header stays green and only the pill goes grey.
    var headerTone: Tone { tone == .idle ? .ok : tone }

    struct Fact: Equatable {
        let label: String
        let value: String
    }

    struct Input: Equatable {
        var isVPNConnected: Bool
        /// The VPN's product name ("WireGuard"), nil when unknown.
        var vpnName: String?
        var helperReady: Bool
        var mode: DropdownCopy.Mode
        var enabledServices: Int
        /// Enabled entries on the list the mode routes: Bypass domains, or VPN Only entries.
        var enabledDomains: Int
        var enabledRules: Int
        /// Addresses routed now, counted as the routes card counts them
        /// (`RoutedBySource.addressCount`): VPN Only's catch-alls are not in it.
        var installedRoutes: Int
        var pending: RouteManager.PendingReconnectApply?
        var lastRouteChange: RouteManager.RouteChangeOutcome?
        var lastDNSRefresh: Date?
        var nextDNSRefresh: Date?
        var autoDNSRefresh: Bool
        /// A fresh install: Bypass mode, an empty domain list and every service off
        /// (`FirstRunSetup.isFresh`). The dropdown asks what should skip the VPN.
        var nothingConfigured: Bool = false
        /// VPN Only's catch-alls are installed. They are not counted, but they are routed, so
        /// with them in place the app is routing even when `installedRoutes` is 0.
        var everythingElseDirect: Bool = false
    }

    let pill: String
    let tone: Tone
    let headline: String
    let sentence: String
    let note: String?
    let facts: [Fact]

    static func make(_ input: Input, now: Date) -> DropdownStatus {
        let name = input.vpnName ?? String(localized: "VPN")

        guard input.isVPNConnected else {
            // Only Bypass keeps its routes across a drop on purpose. VPN Only and Custom tear
            // everything down, so anything still installed is a removal that failed.
            let sentence: String
            if input.installedRoutes == 0 && input.everythingElseDirect {
                sentence = String(localized: "Everything else still goes direct: removing that failed.")
            } else if input.installedRoutes == 0 {
                sentence = String(localized: "Nothing is routed until a VPN connects.")
            } else if input.mode == .bypass {
                sentence = input.installedRoutes == 1
                    ? String(localized: "1 address stays routed for when it reconnects.")
                    : String(localized: "\(input.installedRoutes) addresses stay routed for when it reconnects.")
            } else {
                sentence = input.installedRoutes == 1
                    ? String(localized: "1 address is still routed: removing it failed.")
                    : String(localized: "\(input.installedRoutes) addresses are still routed: removing them failed.")
            }
            return DropdownStatus(pill: String(localized: "OFF"), tone: .bad,
                                  headline: String(localized: "No VPN connected"),
                                  sentence: sentence, note: nil, facts: [])
        }

        guard input.helperReady else {
            return DropdownStatus(pill: String(localized: "NOT ENFORCING"), tone: .warn,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: String(localized: "Nothing is routed while the privileged helper is not running."),
                                  note: nil, facts: [])
        }

        // Once something applied or removed routes after the reconnect (Refresh Routes, a mode
        // switch, a re-route), the WAITING / HELD BACK wording is out of date: show the normal
        // state and only mention that the scheduled apply still runs.
        var scheduledNote: String?
        if let pending = input.pending,
           let change = input.lastRouteChange, change.at > pending.connectedAt {
            let left = pending.appliesAt.timeIntervalSince(now)
            scheduledNote = left > 0
                ? String(localized: "The scheduled re-apply still runs in \(countdown(left)).")
                : String(localized: "The scheduled re-apply runs now.")
        } else if let pending = input.pending {
            let left = pending.appliesAt.timeIntervalSince(now)
            switch pending.reason {
            case .heldBack(let strikes):
                return DropdownStatus(
                    pill: String(localized: "HELD BACK"), tone: .warn,
                    headline: String(localized: "\(name) keeps dropping"),
                    sentence: String(localized: "It dropped \(strikes) times right after routes were applied, so the app is not applying again until the tunnel has held for \(minutesLeft(left))."),
                    note: String(localized: "Refresh Routes applies now anyway."),
                    facts: [])
            case .settling:
                let sentence = left > 0
                    ? String(localized: "Waiting for the tunnel to hold before re-applying routes, in \(countdown(left)).")
                    : String(localized: "Re-applying routes now.")
                let note: String
                switch input.installedRoutes {
                case 0 where input.everythingElseDirect:
                    note = String(localized: "Everything else still goes direct, as before the drop.")
                case 0: note = String(localized: "Nothing is routed until then.")
                case 1: note = String(localized: "The 1 address routed before the drop stays routed.")
                default: note = String(localized: "The \(input.installedRoutes) addresses routed before the drop stay routed.")
                }
                return DropdownStatus(
                    pill: String(localized: "WAITING"), tone: .warn,
                    headline: String(localized: "\(name) reconnected \(DropdownCopy.age(since: pending.connectedAt, now: now))"),
                    sentence: sentence, note: note, facts: [])
            }
        }

        // No Mode fact: the Mode control sits right under the header.
        let facts = [Fact(label: String(localized: "Addresses"), value: routesFact(input, now: now)),
                     Fact(label: String(localized: "DNS"), value: dnsFact(input, now: now))]
        if input.installedRoutes == 0 && input.nothingConfigured {
            // Not a fault: nothing has been asked for yet, and the question sits right below.
            return DropdownStatus(pill: String(localized: "NOT SET UP"), tone: .idle,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: String(localized: "Nothing skips the VPN yet."),
                                  note: scheduledNote, facts: [])
        }
        if input.installedRoutes == 0 && !input.everythingElseDirect {
            return DropdownStatus(pill: String(localized: "NOTHING ROUTED"), tone: .warn,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: String(localized: "Nothing is routed right now."),
                                  note: scheduledNote, facts: facts)
        }
        return DropdownStatus(pill: String(localized: "ON"), tone: .ok,
                              headline: String(localized: "\(name) connected"),
                              sentence: whatIsRouted(input), note: scheduledNote, facts: facts)
    }

    // MARK: Pieces

    /// What a mode does, in one line. The Mode control shows it as its tooltip.
    static func modeDescription(_ mode: DropdownCopy.Mode) -> String {
        switch mode {
        case .bypass: return String(localized: "Bypass: everything else uses the VPN")
        case .vpnOnly: return String(localized: "VPN Only: everything else goes direct")
        case .custom: return String(localized: "Custom: the first matching rule decides")
        }
    }

    /// One sentence on what the user's own lists route.
    static func whatIsRouted(_ input: Input) -> String {
        switch input.mode {
        case .bypass:
            let s = input.enabledServices, d = input.enabledDomains
            let services = s == 1 ? String(localized: "1 service") : String(localized: "\(s) services")
            let domains = d == 1 ? String(localized: "1 domain") : String(localized: "\(d) domains")
            switch (s, d) {
            case (0, 0): return String(localized: "Nothing skips the VPN yet.")
            case (_, 0): return s == 1 ? String(localized: "1 service skips the VPN.") : String(localized: "\(services) skip the VPN.")
            case (0, _): return d == 1 ? String(localized: "1 domain skips the VPN.") : String(localized: "\(domains) skip the VPN.")
            default: return String(localized: "\(services) and \(domains) skip the VPN.")
            }
        case .vpnOnly:
            let d = input.enabledDomains
            if d == 0 { return String(localized: "Nothing is sent through the VPN yet.") }
            return d == 1 ? String(localized: "1 entry uses the VPN.") : String(localized: "\(d) entries use the VPN.")
        case .custom:
            let r = input.enabledRules
            if r == 0 { return String(localized: "No rules yet.") }
            return r == 1 ? String(localized: "1 rule decides where traffic goes.") : String(localized: "\(r) rules decide where traffic goes.")
        }
    }

    static func routesFact(_ input: Input, now: Date) -> String {
        // Same rule as the line under Refresh Routes: a removal stops being reported once
        // routes are back, so the two never disagree.
        guard let change = DropdownCopy.shownRouteChange(input.lastRouteChange,
                                                         currentRouteCount: input.installedRoutes) else {
            return input.installedRoutes > 0
                ? String(localized: "\(input.installedRoutes) routed")
                : String(localized: "none routed yet")
        }
        let when = DropdownCopy.age(since: change.at, now: now)
        switch change.kind {
        case .applied:
            return change.failedCount == 0
                ? String(localized: "\(change.routeCount) routed \(when), none failed")
                : String(localized: "\(change.routeCount) routed \(when), \(change.failedCount) failed")
        case .removedAll:
            return change.failedCount == 0
                ? String(localized: "all removed \(when)")
                : String(localized: "removed \(when), \(change.failedCount) could not be")
        }
    }

    static func dnsFact(_ input: Input, now: Date) -> String {
        let checked = input.lastDNSRefresh.map { String(localized: "checked \(DropdownCopy.age(since: $0, now: now))") }
            ?? String(localized: "not checked yet")
        guard input.autoDNSRefresh else {
            return String(localized: "\(checked), automatic check off")
        }
        guard let next = input.nextDNSRefresh else { return checked }
        let left = next.timeIntervalSince(now)
        return left > 0
            ? String(localized: "\(checked), next in \(countdown(left))")
            : String(localized: "\(checked), next one due now")
    }

    /// "38 s", "18 min", "1 h", "1 h 20 min". Minutes round up, so "1 min" never means 1 s.
    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return String(localized: "\(max(s, 1)) s") }
        let minutes = (s + 59) / 60
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
    }

    /// "6 more minutes", "1 more minute", "less than a minute".
    static func minutesLeft(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(localized: "less than a minute") }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes == 1 ? String(localized: "1 more minute") : String(localized: "\(minutes) more minutes")
    }
}

/// The dropdown's Mode control: one segmented control with all three modes, in every mode.
/// What it shows and asks is pure, so the wording and the pick rule are unit-tested.
enum DropdownModePicker {
    static let modes: [RouteManager.RoutingMode] = [.bypass, .vpnOnly, .custom]

    static func label(_ mode: RouteManager.RoutingMode) -> String { label(mode, in: .main) }

    static func label(_ mode: RouteManager.RoutingMode, in bundle: Bundle) -> String {
        switch mode {
        case .bypass: return String(localized: "Bypass", bundle: bundle)
        case .vpnOnly: return String(localized: "VPN Only", bundle: bundle)
        case .custom: return String(localized: "Custom", bundle: bundle)
        }
    }

    static func copyMode(_ mode: RouteManager.RoutingMode) -> DropdownCopy.Mode {
        switch mode {
        case .bypass: return .bypass
        case .vpnOnly: return .vpnOnly
        case .custom: return .custom
        }
    }

    /// The switch a pick asks to confirm, or nil when the picked mode is already in use.
    /// Nothing switches here: the mode changes only when the user confirms.
    static func pendingSwitch(picked: RouteManager.RoutingMode,
                              current: RouteManager.RoutingMode) -> RouteManager.RoutingMode? {
        picked == current ? nil : picked
    }

    static var confirmationTitle: String { String(localized: "Switch routing mode?") }

    /// The question, as a standalone alert rather than a sheet on the dropdown: macOS 26 hides
    /// the icon of an alert shown as a sheet, and this one should show the app's logo. No icon
    /// is set here, so NSAlert shows the app icon, AppIcon.icns.
    @MainActor static func confirmationAlert(to mode: RouteManager.RoutingMode, config: RouteManager.Config) -> NSAlert {
        let copy = confirmation(to: mode, listsBecomeRules: RoutingModeCopy.lists(from: config).listsBecomeRules)
        let alert = NSAlert()
        alert.messageText = confirmationTitle
        alert.informativeText = copy.message
        alert.addButton(withTitle: copy.confirm)                  // Return
        alert.addButton(withTitle: String(localized: "Cancel"))   // Escape
        return alert
    }

    /// Asks the question and, on Switch, changes the mode. Call it through the run loop, not
    /// from inside a click handler or a main-queue block (see `DropdownModeRow`).
    @MainActor static func askAndSwitch(to mode: RouteManager.RoutingMode, routeManager: RouteManager) {
        let alert = confirmationAlert(to: mode, config: routeManager.config)
        if alert.runModal() == .alertFirstButtonReturn {
            // The call the Settings switch makes, so entering Custom runs the same migration
            // of the Bypass and VPN Only lists into rules.
            routeManager.setRoutingMode(mode)
        }
    }

    /// The question asked before a switch, in English. (The Settings window now asks in a sheet
    /// with its own wording, in RoutingModeSwitcher.swift.) `listsBecomeRules` comes from
    /// `RoutingModeCopy.lists(from:)`, the answer the Settings sheet shows, so the two never
    /// disagree about whether the switch to Custom turns the lists into rules.
    static func confirmation(to mode: RouteManager.RoutingMode, listsBecomeRules: Bool) -> (message: String, confirm: String) {
        switch mode {
        case .bypass:
            return (String(localized: "Everything will go through your VPN except the sites you list. Your custom routes stay saved."),
                    String(localized: "Switch to Bypass"))
        case .vpnOnly:
            return (String(localized: "Only the sites you list will use your VPN; everything else goes direct."),
                    String(localized: "Switch to VPN Only"))
        case .custom:
            let message = listsBecomeRules
                ? String(localized: "Your listed domains and services become editable rules you can send through any route (a proxy, a Tailscale peer, or a specific VPN). You can switch back anytime.")
                : String(localized: "Switch to your per-rule custom routing. You can switch back to a simple mode anytime.")
            return (message, String(localized: "Switch to Custom Routes"))
        }
    }
}

// MARK: - First run

/// What the dropdown asks on a fresh install, kept pure so the rule for when it shows, the
/// services it offers and its wording are unit-tested.
enum FirstRunSetup {
    /// The six services the question offers, in this order. The rest are one row away.
    static let commonServiceIDs = ["telegram", "whatsapp", "youtube", "zoom", "teams", "spotify"]

    /// Nothing has been asked for yet: Bypass mode, no domain on its list (on or off), every
    /// service off, and no route installed. VPN Only always installs its catch-all routes and
    /// Custom has its own pages, so the question is asked in Bypass only.
    static func isFresh(mode: RouteManager.RoutingMode, domains: [DomainEntry],
                        services: [ServiceEntry], installedRoutes: Int) -> Bool {
        mode == .bypass
            && domains.isEmpty
            && !services.contains(where: { $0.enabled })
            && installedRoutes == 0
    }

    /// The common services found in the catalogue, in the order above.
    static func commonServices(in services: [ServiceEntry]) -> [ServiceEntry] {
        commonServiceIDs.compactMap { id in services.first { $0.id == id } }
    }

    static var title: String { String(localized: "What should skip the VPN?") }
    static var subtitle: String { String(localized: "Switched-on services use your normal connection.") }
    static var sitePlaceholder: String { String(localized: "Add a site, like example.com") }
    static var addSite: String { String(localized: "Add Site") }
    static var modeLine: String { String(localized: "Mode: Bypass. Want only a few sites on the VPN and everything else direct?") }
    static var useVPNOnly: String { String(localized: "Use VPN Only instead…") }

    static func domainCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 domain") : String(localized: "\(n) domains")
    }

    static func allServices(_ count: Int) -> String {
        String(localized: "All \(count) services…")
    }
}

/// The question a fresh install asks, as a grouped list: six common services with the Services
/// page's own switch, a row that opens that page, a row to add a site, and a line that offers
/// VPN Only. Each switch and each add applies at once, through the same RouteManager calls.
struct FirstRunSetupView: View {
    @EnvironmentObject var routeManager: RouteManager
    let onOpenServices: () -> Void
    let onUseVPNOnly: () -> Void
    @State private var site: String
    /// What the last add did, shown under the field (proposal 5's line).
    @State private var feedback: AddDomainFeedback?

    /// The arguments seed the field and the line under it, for a rendered screenshot.
    init(site: String = "", feedback: AddDomainFeedback? = nil,
         onOpenServices: @escaping () -> Void, onUseVPNOnly: @escaping () -> Void) {
        _site = State(initialValue: site)
        _feedback = State(initialValue: feedback)
        self.onOpenServices = onOpenServices
        self.onUseVPNOnly = onUseVPNOnly
    }

    private static let vpnOnlyURL = URL(string: "vpnbypass-dropdown://use-vpn-only")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(FirstRunSetup.title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)
            Text(FirstRunSetup.subtitle)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
                .padding(.top, 2)
                .padding(.bottom, 8)

            group {
                ForEach(FirstRunSetup.commonServices(in: routeManager.config.services)) { service in
                    serviceRow(service)
                    rowSeparator
                }
                Button(action: onOpenServices) {
                    HStack(spacing: 9) {
                        tile("magnifyingglass", Self.gray)
                        Text(FirstRunSetup.allServices(routeManager.config.services.count))
                            .font(.system(size: 12.5))
                            .foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(height: 34)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            group {
                HStack(spacing: 9) {
                    tile("globe", Self.gray)
                    TextField(FirstRunSetup.sitePlaceholder, text: $site)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .onSubmit(addSite)
                        // As on the Domains page: an add during an apply would save the site
                        // without routing it.
                        .disabled(routeManager.isApplyingRoutes)
                    Button(action: addSite) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(Color.secondary.opacity(0.18))
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .disabled(site.isEmpty || routeManager.isApplyingRoutes)
                    .help(FirstRunSetup.addSite)
                    .accessibilityLabel(FirstRunSetup.addSite)
                }
                .frame(height: 34)
                .padding(.horizontal, 10)
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(feedback?.isError == true ? Theme.error.opacity(0.8) : Color.clear, lineWidth: 1))
            .padding(.top, 8)
            // Editing the text the line talks about makes it stale.
            .onChange(of: site) { text in
                if text != feedback?.fieldText { feedback = nil }
            }

            if let feedback {
                AddDomainFeedbackLine(feedback: feedback)
                    .padding(.top, 6)
            }

            Divider()
                .padding(.top, 14)
                .padding(.bottom, 8)

            Text(modeLineText)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard url == Self.vpnOnlyURL else { return .systemAction }
                    onUseVPNOnly()
                    return .handled
                })
        }
    }

    /// The mode line with "Use VPN Only instead…" as a link inside it, so it wraps as one sentence.
    private var modeLineText: AttributedString {
        var line = AttributedString(FirstRunSetup.modeLine + " ")
        var link = AttributedString(FirstRunSetup.useVPNOnly)
        link.link = Self.vpnOnlyURL
        link.foregroundColor = Theme.Brand.sky
        line.append(link)
        return line
    }

    /// A built-in service a custom one keeps off by having its name (see ServiceRow).
    private func switchLocked(_ service: ServiceEntry) -> Bool {
        !service.enabled && routeManager.customServiceHolding(nameOf: service) != nil
    }

    private func serviceRow(_ service: ServiceEntry) -> some View {
        HStack(spacing: 9) {
            tile(ServiceChip.iconName(for: service.id), Self.tileColor(service.id))
            Text(service.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(FirstRunSetup.domainCount(service.domains.count))
                .font(.system(size: 10.5))
                .foregroundColor(Theme.textTertiary)
            // The Services page's switch (ServiceRow), and the same call behind it.
            Toggle(service.name, isOn: Binding(
                get: { service.enabled },
                set: { _ in
                    if !routeManager.isApplyingRoutes {
                        routeManager.toggleService(service.id)
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(Theme.success)
            .labelsHidden()
            .controlSize(.small)
            .disabled(routeManager.isApplyingRoutes || switchLocked(service))
            .opacity(routeManager.isApplyingRoutes || switchLocked(service) ? 0.5 : 1)
            .help(routeManager.customServiceHolding(nameOf: service).map { ServiceNameClash.builtInOffMessage(custom: $0.name) } ?? "")
        }
        .frame(height: 34)
        .padding(.horizontal, 10)
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.leading, 39)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
    }

    private func tile(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }

    private static let gray = Color(hex: "48484A")

    /// Each service's own colour behind its symbol, as System Settings draws its rows.
    static func tileColor(_ serviceID: String) -> Color {
        switch serviceID {
        case "telegram": return Color(hex: "2AABEE")
        case "whatsapp": return Color(hex: "25D366")
        case "youtube": return Color(hex: "FF3B30")
        case "zoom": return Color(hex: "0B5CFF")
        case "teams": return Color(hex: "5B5FC7")
        case "spotify": return Color(hex: "1DB954")
        default: return gray
        }
    }

    /// The Bypass add, as on the Domains page: a refused add keeps the text and says why, a
    /// saved one empties the field and names what went in.
    private func addSite() {
        guard !site.isEmpty, !routeManager.isApplyingRoutes else { return }
        let shown = AddDomainFeedback(routeManager.addDomain(site), typed: site)
        feedback = shown
        site = shown.fieldText
    }
}

// MARK: - Supporting Views

/// The card `RoutedBySource` describes: what the user added, with how many routes each has.
/// A row's tooltip lists the addresses behind it.
struct RoutedBySourceCard: View {
    let summary: RoutedBySource.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(summary.title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(summary.countText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)

            if !summary.rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.rows) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.isProblem ? "exclamationmark.triangle.fill" : Self.symbol(row.icon))
                                .font(.system(size: 11))
                                .frame(width: 14)
                                .foregroundColor(row.isProblem ? Theme.warning : .secondary)
                            Text(row.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(row.icon == .leftover ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(row.countText)
                                .font(.system(size: 10.5))
                                .foregroundColor(row.isProblem ? Theme.warning : .secondary)
                        }
                        .help(row.tooltip)
                    }
                    if summary.hiddenRows > 0 {
                        Text("+ \(summary.hiddenRows) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if summary.everythingElseDirect {
                if !summary.rows.isEmpty { Divider() }
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11))
                        .frame(width: 14)
                    Text(RoutedBySource.everythingElse)
                        .font(.system(size: 11.5))
                    Spacer(minLength: 8)
                    Text(RoutedBySource.direct)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    static func symbol(_ icon: RoutedBySource.Icon) -> String {
        switch icon {
        case .service(let id): return ServiceChip.iconName(for: id)
        case .domain: return "globe"
        case .ipRange: return "point.3.connected.trianglepath.dotted"
        case .rule: return "list.bullet.indent"
        case .leftover: return "clock.arrow.circlepath"
        }
    }
}

/// The last Verify Routes: what it checked, the failures first, then one line for the rest.
struct RouteCheckCard: View {
    let run: RouteCheck.Run
    /// False once the log has lost the check's lines, so the link would open a page without them.
    let logsHoldResults: Bool
    let onShowLogs: () -> Void

    var body: some View {
        let failures = run.failures
        let reachable = run.reachable
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                Text(RouteCheck.title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                // Ticks so the age stays true while the dropdown is open.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DropdownCopy.age(since: run.at, now: context.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)

            scopeText
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            if !failures.isEmpty {
                Text(RouteCheck.notReachable(failures.count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.error)
                    .padding(.top, 2)
                ForEach(failures.prefix(RouteCheck.visibleFailures)) { result in
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.error)
                        Text(result.destination)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(1)
                        if let source = run.sources[result.destination] {
                            Text(source)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 6)
                        if let error = result.error {
                            Text(error)
                                .font(.system(size: 10.5))
                                .foregroundColor(Theme.error)
                                .lineLimit(1)
                        }
                    }
                }
                if failures.count > RouteCheck.visibleFailures {
                    Text("+ \(failures.count - RouteCheck.visibleFailures) more")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if !reachable.isEmpty {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.success)
                        Text(RouteCheck.reachable(reachable.count))
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                        Spacer(minLength: 6)
                        if let range = RouteCheck.latencyRange(reachable) {
                            Text(range)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Every result is one line in Settings > Logs, until the log drops them.
            if !run.results.isEmpty && logsHoldResults {
                Button(action: onShowLogs) {
                    Text(RouteCheck.logsLink(run.results.count))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Brand.sky)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    /// "Checked 10 of 62 routes (single addresses only)." with the qualifier dimmer, and
    /// "All reachable." after it when nothing failed.
    private var scopeText: Text {
        let scope = RouteCheck.scope(checked: run.results.count, singleAddresses: run.singleAddresses,
                                     routeCount: run.routeCount)
        var text = Text(scope.main).foregroundColor(Theme.textPrimary)
        if let qualifier = scope.qualifier {
            text = text + Text(" " + qualifier).foregroundColor(Theme.textSecondary)
        }
        text = text + Text(".").foregroundColor(Theme.textPrimary)
        if !run.results.isEmpty && run.failures.isEmpty {
            text = text + Text(" " + RouteCheck.allReachable).foregroundColor(Theme.textPrimary)
        }
        return text
    }
}

struct StatBadge: View {
    let value: String
    let label: LocalizedStringKey
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Theme.success)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

/// The SF Symbol each service draws in the dropdown's list and in the first-run question.
enum ServiceChip {
    static func iconName(for serviceID: String) -> String {
        switch serviceID {
        case "telegram": return "paperplane.fill"
        case "youtube": return "play.rectangle.fill"
        case "whatsapp": return "message.fill"
        case "spotify": return "music.note"
        case "tailscale": return "network"
        case "slack": return "number.square.fill"
        case "discord": return "bubble.left.and.bubble.right.fill"
        case "twitch": return "tv.fill"
        case "zoom": return "video.fill"
        case "teams": return "person.2.fill"
        default: return "globe"
        }
    }
}
