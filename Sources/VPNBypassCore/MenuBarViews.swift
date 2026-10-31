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
        } else if routeManager.isVPNConnected && !routeManager.activeRoutes.isEmpty
                    && routeManager.vpnKillSwitch == nil {
            // No arrow under a kill switch: the routes are in, but none of them takes effect.
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
        // Only once every route is out, as the dropdown says Paused only then.
        if routeManager.isPaused && routeManager.activeRoutes.isEmpty && routeManager.isVPNConnected {
            return String(localized: "VPN Bypass: paused, traffic follows the VPN's own routes")
        }
        guard routeManager.isVPNConnected else {
            return String(localized: "VPN Bypass: no VPN detected, nothing is being routed")
        }
        if let killSwitch = routeManager.vpnKillSwitch {
            return Self.killSwitchAccessibilityLabel(killSwitch)
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

    /// The label while a kill switch is on. Only `includeAllNetworks` takes everything, and
    /// `excludeLocalNetworks` lets local-network addresses out of that; `enforceRoutes` takes
    /// only what the VPN's own routes cover, so it never claims that nothing skips the VPN.
    static func killSwitchAccessibilityLabel(_ killSwitch: VPNKillSwitch) -> String {
        guard killSwitch.includeAllNetworks else {
            return String(localized: "VPN Bypass: the VPN's own routes win over this app's, so routes set here have no effect")
        }
        return killSwitch.excludeLocalNetworks
            ? String(localized: "VPN Bypass: the VPN's kill switch sends all traffic through it except local-network addresses")
            : String(localized: "VPN Bypass: the VPN's kill switch sends all traffic through it, so nothing skips it")
    }

    private var menuBarIcon: some View {
        Group {
            if routeManager.isPaused && routeManager.activeRoutes.isEmpty && !helperManager.helperState.isFailed {
                // The paused glyph of the status chip (StatusChip.Kind.paused), as a template.
                Image(systemName: "pause.circle")
                    .font(.system(size: 15))
            } else if let nsImage = currentIcon ?? Self.iconDefault {
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
            //
            // Verbatim: the product name is never translated. "Bypass" is also the mode's name,
            // which French translates, so a looked-up Text read "VPN Contournement".
            Text(verbatim: "VPN")
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .padding(.trailing, fontSize * 0.16)

            Text(verbatim: "Bypass")
                .font(.system(size: fontSize, weight: .light, design: .rounded))
                .foregroundColor(Theme.Brand.sky)
        }
    }
}

// MARK: - Quick add

/// The dropdown's add field, open in every state (flow fix 4): ⌘N puts the cursor in it,
/// Return adds, Esc clears it and gives the focus back. Under it, what the last add did: where
/// it went, or why it saved nothing.
struct QuickAddField: View {
    @Binding var text: String
    /// What the field adds in this mode: "Add a site to bypass…".
    let placeholder: String
    /// An apply is running: as on the Domains page, an add now would save the entry without
    /// routing it, so the field waits.
    var isApplying = false
    let feedback: AddDomainFeedback?
    let onAdd: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .accessibilityHidden(true)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .focused($isFocused)
                    .onSubmit(onAdd)
                    .disabled(isApplying)
                    .accessibilityLabel(placeholder)
                    .help(DropdownShortcut.addSite.help(placeholder))
                if text.isEmpty {
                    Text(verbatim: DropdownShortcut.addSite.symbol)
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 0.5))
                        .accessibilityHidden(true)
                } else {
                    Button(action: onAdd) {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.accentText)
                            .frame(width: 22, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplying)
                    .help(String(localized: "Add"))
                    .accessibilityLabel(String(localized: "Add"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgInput))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(isFocused ? Theme.accentText : Theme.border, lineWidth: isFocused ? 1 : 0.5)
            )
            .background { keys }
            if let feedback {
                AddDomainFeedbackLine(feedback: feedback)
            }
        }
    }

    /// ⌘N, always; Esc only while the field is in use, so an Esc otherwise still closes the
    /// dropdown as it always has.
    @ViewBuilder private var keys: some View {
        ZStack {
            Button("") { isFocused = true }
                .keyboardShortcut(.addSite)
            if isFocused || !text.isEmpty || feedback != nil {
                Button("") {
                    onCancel()
                    isFocused = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Menu Content

struct MenuContent: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject private var helperManager = HelperManager.shared
    @State private var newDomain = ""
    /// What the last add did, under the field: where the entry went, or why nothing was saved.
    @State private var quickAddFeedback: AddDomainFeedback?
    /// Remove All Routes… asks first: it sends the listed traffic back through the VPN.
    @State private var confirmingRemoveAll = false

    var body: some View {
        VStack(spacing: 0) {
            // Ticks once a second so the countdowns and the ages stay true while open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = DropdownStatus.make(statusInput, now: context.date)
                VStack(alignment: .leading, spacing: 12) {
                    titleHeader(status)
                    StatusBlock(status: status) { action in
                        // Both open Status: the helper's row and its Install button, or
                        // Problems with every failure behind the count.
                        switch action {
                        case .fix, .show: openSettings(page: .status)
                        case .resume: resume()
                        case .retryPause: Task { await routeManager.retryPauseRemoval() }
                        }
                    }
                }
            }

            if showsFirstRun {
                // A fresh install: ask what should skip the VPN, in place of the mode control
                // and the route list, which have nothing to show yet.
                FirstRunSetupView(
                    onOpenServices: {
                        // A fresh install has no service on, so the page opens on its catalogue.
                        SettingsPageRequest.shared.openCatalogue = true
                        openSettings(page: .services)
                    },
                    onUseVPNOnly: {
                        // Through the run loop, for the reason given in DropdownModeRow.
                        RunLoop.main.perform(inModes: [.common]) {
                            DropdownModePicker.askAndSwitch(to: .vpnOnly, routeManager: routeManager)
                        }
                    })
                    .padding(.top, 16)
            } else {
                DropdownModeRow()
                    .padding(.top, 12)

                Divider()
                    .padding(.vertical, 8)

                // Open in every state, the first detection and no VPN included: an add is
                // saved either way, and applied when routes can be.
                QuickAddField(text: $newDomain, placeholder: DropdownCopy.quickAddPlaceholder(statusInput.mode),
                              isApplying: routeManager.isApplyingRoutes,
                              feedback: quickAddFeedback, onAdd: addDomain, onCancel: clearQuickAdd)
                    .onChange(of: newDomain) { text in
                        if text != quickAddFeedback?.fieldText { quickAddFeedback = nil }
                    }

                // Main content. Nothing while the first detection runs: the block says Starting.
                if !isStarting {
                    Group {
                        if routeManager.isVPNConnected {
                            connectedContent
                        } else {
                            disconnectedContent
                        }
                    }
                    .padding(.top, 12)
                }
            }

            Divider()
                .padding(.vertical, 8)

            footerActions
        }
        .padding(16)
        .frame(width: DropdownLayout.current)
        // Here, on the view that holds every state: Remove All Routes… is offered connected
        // and disconnected alike, from the ⋯ menu in the footer.
        .alert(removeAllCopy.title, isPresented: $confirmingRemoveAll) {
            Button(String(localized: "Remove Routes"), role: .destructive) {
                Task { await routeManager.removeAllRoutes() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(removeAllCopy.message)
        }
        // Refresh the VPN status on every open. Not `.onAppear`: a MenuBarExtra(.window) keeps
        // one window and one view for the app's life, so `.onAppear` runs on the first open only.
        .background(WindowBecameKeyObserver { routeManager.refreshStatus() })
    }

    /// The app's first detection is still running.
    private var isStarting: Bool {
        routeManager.isLoading && routeManager.lastUpdate == nil
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
        guard !isStarting else { return false }
        return isFresh
    }

    // MARK: - Title Header

    /// The wordmark, and the status chip: the block's only coloured signal.
    private func titleHeader(_ status: DropdownStatus) -> some View {
        HStack(spacing: 8) {
            BrandedAppName(fontSize: 15)
            Spacer()
            StatusChip(state: status.chip)
        }
    }

    /// Everything the status block reads, gathered in one place so the wording lives in the
    /// pure `DropdownStatus.make`.
    private var statusInput: DropdownStatus.Input {
        DropdownStatus.Input.current(routeManager, helperReady: helperManager.helperState.isReady)
    }

    // MARK: - Connected Content

    private var connectedContent: some View {
        VStack(spacing: 12) {
            BlockedSitesLine()

            // Routes in use (custom mode)
            if routeManager.config.routingMode == .custom {
                routesInUseSummary
            }

            // What is routed, one row per entry the user added. The last route check is not
            // here: "Show" opens it on the Status page, with every failure behind the count.
            // Paused, an entry with no addresses is what was asked for: no ▲, no Retry.
            if let routed = RoutedBySource.make(
                mode: statusInput.mode, config: routeManager.config,
                routes: routeManager.installedRoutes,
                busy: routeManager.isPaused || RoutedBySource.emptyEntriesAreExpected(
                    running: isBusy, pending: routeManager.pendingReconnectApply,
                    lastChange: routeManager.lastRouteChange,
                    currentRouteCount: routeManager.routedAddressCount,
                    helperReady: helperManager.helperState.isReady),
                title: routeManager.isPaused ? RoutedBySource.pausedTitle(statusInput.mode) : nil) {
                routedList(routed)
            }
        }
    }

    // MARK: - Actions

    /// Refresh, apply or DNS work is running (the route-operation gate is held, or a refresh
    /// is still detecting the network before it takes the gate).
    private var isBusy: Bool {
        routeManager.isLoading || routeManager.isApplyingRoutes
    }

    /// The "…" menu: what the footer does not show, and the one action that removes every
    /// route. It does not repeat the footer's Refresh or Settings. With no VPN connected it
    /// keeps what still makes sense, Remove All Routes… among it: routes kept for a reconnect,
    /// or left by a removal that failed, must stay removable (A7).
    private var moreActionsMenu: some View {
        Menu {
            if routeManager.isVPNConnected {
                Button(String(localized: "Verify Routes")) { verify() }
                    .disabled(routeManager.isCheckingRoutes || routeManager.activeRoutes.isEmpty)
                Button(String(localized: "Re-resolve DNS Now")) { routeManager.forceDNSRefresh() }
                    .disabled(isBusy || routeManager.isPaused)
            }
            Button(String(localized: "Open Logs")) { openSettings(page: .logs) }
            Divider()
            Button(DropdownShortcut.quit.title) { quit() }
                .keyboardShortcut(.quit)
            Divider()
            Button(String(localized: "Remove All Routes…")) { confirmingRemoveAll = true }
                .disabled(routeManager.activeRoutes.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: DropdownIconButton.hitSize, height: DropdownIconButton.hitSize)
        .contentShape(Rectangle())
        .help(String(localized: "More actions"))
        .accessibilityLabel(String(localized: "More actions"))
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

    /// Refresh, from its button or ⌘R. A held ⌘R sends key repeats and SwiftUI runs the
    /// action for each one; the button turns active again between refreshes, so without this
    /// a held key would start one refresh after another.
    private func refresh() {
        guard !DropdownShortcut.isKeyRepeat(NSApp.currentEvent) else { return }
        routeManager.refreshRoutes()
    }

    private func verify() {
        guard !routeManager.isCheckingRoutes else { return }
        Task { await routeManager.verifyRoutes() }
    }

    // MARK: - Disconnected Content

    /// No VPN: the status block says so and what connecting does. Below it, the routes still
    /// installed: kept for the reconnect in Bypass, or left by a removal that failed. They stay
    /// listed, and removable from the ⋯ menu (A7).
    @ViewBuilder
    private var disconnectedContent: some View {
        let mode = statusInput.mode
        VStack(spacing: 12) {
            BlockedSitesLine()
            if let routed = RoutedBySource.make(mode: mode, config: routeManager.config,
                                                routes: routeManager.installedRoutes,
                                                busy: false, routedOnly: true,
                                                title: RoutedBySource.disconnectedTitle(mode, lastChange: routeManager.lastRouteChange)) {
                routedList(routed)
            }
        }
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

    /// Refresh as a plain bordered button, then Settings and ⋯. Quit, Verify, Re-resolve DNS
    /// and Remove All Routes… are in ⋯. What a script or an agent changed through the control
    /// socket shows above it (proposal 15 of #119).
    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let change = routeManager.lastOutsideChange,
               change.isShown(currentRouteCount: routeManager.routedAddressCount,
                              everythingElseDirect: routeManager.everythingElseDirect) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    OutsideChangeLine(change: change, now: context.date) {
                        SettingsPageRequest.shared.logFilter = change.logFilter
                        openSettings(page: .logs)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    refresh()
                } label: {
                    HStack(spacing: 5) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text(String(localized: "Refresh"))
                    }
                }
                .buttonStyle(.bordered)
                // Paused, nothing applies: Resume, on line 3, is the way back.
                .disabled(isBusy || !routeManager.isVPNConnected || !helperManager.helperState.isReady
                          || routeManager.isPaused)
                .keyboardShortcut(.refreshRoutes)
                .help(DropdownShortcut.refreshRoutes.help(String(localized: "Refresh Routes")))
                .accessibilityLabel(isBusy ? String(localized: "Refreshing routes…") : String(localized: "Refresh Routes"))

                // While paused, Resume is on line 3 of the status block instead.
                if !routeManager.isPaused {
                    pauseMenu
                }

                Spacer(minLength: 0)

                DropdownIconButton(systemImage: "gearshape", name: String(localized: "Settings"),
                                   shortcut: .settings) { openSettings() }

                moreActionsMenu
            }
        }
        // ⌘Q while the dropdown is open: the ⋯ menu's Quit item answers only while it is open.
        // ⌘P likewise, since the Pause menu answers its items' keys only while open.
        .background {
            ZStack {
                Button("") { quit() }
                    .keyboardShortcut(.quit)
                Button("") { pauseShortcut() }
                    .keyboardShortcut(.pause)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    /// Pause, with its four lengths. Greyed when pausing is not safe in this config, with the
    /// one line that says why as the menu's first item, its tooltip and its VoiceOver hint.
    private var pauseMenu: some View {
        let blocker = PauseGate.blocker(routeManager.config)
        let why = blocker.map { PauseGate.message($0) }
        return Menu {
            if let why {
                Text(why)
                Divider()
            }
            ForEach(PauseLength.choices, id: \.self) { length in
                if length == .oneHour {
                    Button(length.title()) { pause(length) }
                        .keyboardShortcut(.pause)
                        .disabled(blocker != nil)
                } else {
                    Button(length.title()) { pause(length) }
                        .disabled(blocker != nil)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "pause")
                    .font(.system(size: 11))
                Text(String(localized: "Pause"))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        // Greyed, yet it still opens: its first line says why it cannot pause, and the four
        // lengths are disabled. A disabled control would hide that line.
        .opacity(blocker == nil ? 1 : 0.45)
        .help(why ?? DropdownShortcut.pause.help(String(localized: "Pause")))
        .accessibilityLabel(String(localized: "Pause"))
        .accessibilityHint(why ?? String(localized: "Takes the app's routes out for a while, so traffic follows the VPN's own routes."))
    }

    private func pause(_ length: PauseLength) {
        Task { await routeManager.pause(for: length) }
    }

    private func resume() {
        routeManager.resume()
    }

    /// ⌘P: Resume while paused, else pause for an hour when Pause is allowed.
    private func pauseShortcut() {
        guard !DropdownShortcut.isKeyRepeat(NSApp.currentEvent) else { return }
        switch PauseShortcut.action(isPaused: routeManager.isPaused,
                                    blocker: PauseGate.blocker(routeManager.config)) {
        case .resume: resume()
        case .pause(let length): pause(length)
        case .nothing: break
        }
    }


    // MARK: - Helpers
    
    private func addDomain() {
        guard !newDomain.isEmpty, !routeManager.isApplyingRoutes else { return }
        let result = routeManager.addForCurrentMode(newDomain)
        let next = Self.quickAdd(after: result, typed: newDomain)
        newDomain = next.text
        quickAddFeedback = next.feedback
    }

    /// The field after an add; it stays open either way. A refused add keeps the text and
    /// says why, as the Domains tab does. A saved one empties the field and says where the
    /// entry went: the list, or for Custom mode's rule its place, since it goes last and an
    /// earlier rule may match first (A5). nil is Custom mode's add when it found no Direct
    /// route, which it logs.
    static func quickAdd(after result: Result<AddedDomain, AddDomainError>?, typed: String) -> QuickAddState {
        guard let result else { return .empty }
        let shown = AddDomainFeedback(result, typed: typed)
        return QuickAddState(text: shown.fieldText, feedback: shown)
    }

    struct QuickAddState: Equatable {
        let text: String
        let feedback: AddDomainFeedback?

        static let empty = QuickAddState(text: "", feedback: nil)
    }

    private func clearQuickAdd() {
        newDomain = ""
        quickAddFeedback = nil
    }

    // MARK: - Rows

    /// An apply can run now: what Retry needs.
    private var canRetry: Bool {
        routeManager.isVPNConnected && helperManager.helperState.isReady && !isBusy
    }

    private func routedList(_ summary: RoutedBySource.Summary) -> some View {
        let mode = statusInput.mode
        let failures = routeManager.lastRouteChange?.failures ?? []
        return RoutedBySourceCard(
            summary: summary,
            reason: { RoutedBySource.problemReason(for: $0, failures: failures) },
            actions: { row in
                let commands = RoutedBySource.commands(for: row, mode: mode, config: routeManager.config,
                                                       canRetry: canRetry)
                let hover = RoutedBySource.hoverCommand(in: commands, isProblem: row.isProblem)
                return (hover.map { rowAction($0, row: row) }, commands.map { rowAction($0, row: row) })
            })
    }

    private func rowAction(_ command: RoutedBySource.Command, row: RoutedBySource.Row) -> RowAction {
        switch command {
        case .turnOff(let target):
            return RowAction(kind: .other, name: ControlNames.turnOff(row.name), systemImage: "minus.circle") {
                turnOff(target)
            }
        case .retry:
            return RowAction(kind: .other, name: ControlNames.retry(row.name), systemImage: "arrow.clockwise") {
                refresh()
            }
        case .showInSettings(let page):
            return RowAction(kind: .other, name: ControlNames.showInSettings(row.name), systemImage: "gearshape") {
                // The page opens filtered to the row; the "Left from earlier" row has no entry.
                if row.icon != .leftover { SettingsPageRequest.shared.search = row.name }
                openSettings(page: page)
            }
        case .copyAddresses:
            return RowAction(kind: .other, name: ControlNames.copyAddresses(row.name), systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.allAddresses.joined(separator: "\n"), forType: .string)
            }
        }
    }

    /// Turns the row's entry off the way its Settings page does, so the routes come out the
    /// same way.
    private func turnOff(_ target: RoutedBySource.Target) {
        switch target {
        case .service(let id): routeManager.toggleService(id)
        case .domain(let id): routeManager.toggleDomain(id)
        case .inverseDomain(let id): routeManager.toggleInverseDomain(id)
        case .rules(let ids):
            for i in routeManager.config.rules.indices where ids.contains(routeManager.config.rules[i].id) {
                routeManager.config.rules[i].enabled = false
            }
            routeManager.saveRulesAndReapply()
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

/// VPN Only's blocks while the VPN is down (or back, before its routes are): how many listed
/// entries are held back, and the way out. It says "listed addresses" because that is all it
/// holds: an IPv6 address or a lookup that skips the app still reaches a listed site.
struct BlockedSitesLine: View {
    @EnvironmentObject var routeManager: RouteManager

    var body: some View {
        if !routeManager.blockedRoutes.isEmpty {
            let count = routeManager.blockedSiteCount
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(Theme.warning)
                    .accessibilityHidden(true)
                Text(routeManager.isVPNConnected
                     ? String(localized: "Waiting for VPN routes: listed addresses blocked for \(count) site(s)")
                     : String(localized: "VPN down: listed addresses blocked for \(count) site(s)"))
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                // Only while the VPN is down: with it up, a release sends the sites wherever the
                // VPN's own routes point, not outside it, and the waiting apply restores them.
                if !routeManager.isVPNConnected {
                    Button(String(localized: "Open them directly")) {
                        routeManager.openBlockedSitesDirectly()
                    }
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Open the blocked sites directly, outside the VPN"))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.12)))
        }
    }
}

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
        .help(change.logsHelp)
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

    /// "1 address", "62 addresses".
    static func addresses(_ count: Int) -> String { routes(count) }

    /// The outcome the result line shows, or nil to show none. A removal is a claim about what
    /// is installed now, so it stops showing once the route count moves: a DNS refresh, a new
    /// domain or a newly enabled service brings routes back without a full apply, and the line
    /// would otherwise keep saying "All routes removed" under a list of live routes.
    ///
    /// With the helper not ready nothing is enforced, so a past apply's "62 addresses routed"
    /// would contradict the banner above it saying nothing is routed (A2). A failed removal is
    /// still shown: those routes did stay.
    static func shownRouteChange(_ outcome: RouteManager.RouteChangeOutcome?,
                                 currentRouteCount: Int,
                                 helperReady: Bool = true) -> RouteManager.RouteChangeOutcome? {
        guard let outcome else { return nil }
        // A removal that failed stays: it says the routes are still in the kernel, which is
        // true with the helper down, and is why Remove All did nothing.
        if !helperReady && !(outcome.kind == .removedAll && outcome.failedCount > 0) { return nil }
        if outcome.kind == .removedAll && outcome.routeCount != currentRouteCount { return nil }
        return outcome
    }

    /// The last change shown is a Remove All Routes: the entries it left empty are what the
    /// user asked for, not a problem for the dropdown's Show or for Status > Problems.
    static func removalStands(_ outcome: RouteManager.RouteChangeOutcome?, currentRouteCount: Int,
                              helperReady: Bool = true) -> Bool {
        shownRouteChange(outcome, currentRouteCount: currentRouteCount, helperReady: helperReady)?.kind == .removedAll
    }

    /// Line 3 while no VPN is connected: what connecting does in this mode (A6).
    static func disconnectedSentence(_ mode: Mode, in bundle: Bundle = .main) -> String {
        switch mode {
        case .bypass:
            return String(localized: "Your list skips the VPN once one connects.", bundle: bundle)
        case .vpnOnly:
            return String(localized: "Your list goes through the VPN once one connects.", bundle: bundle)
        case .custom:
            return String(localized: "Your rules apply once a VPN connects.", bundle: bundle)
        }
    }

    /// The add field's placeholder: the Bypass list, the VPN Only list, or a Custom mode rule
    /// to the Direct route, which is not a list (A5).
    static func quickAddPlaceholder(_ mode: Mode, in bundle: Bundle = .main) -> String {
        switch mode {
        case .bypass: return String(localized: "Add a site to bypass…", bundle: bundle)
        case .vpnOnly: return String(localized: "Add a site for the VPN…", bundle: bundle)
        case .custom: return String(localized: "Add a Direct rule…", bundle: bundle)
        }
    }

    /// What the last apply or removal did, as one sentence: the Status page's summary adds it.
    /// `isProblem` is true when something failed or every route was removed.
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

/// What Verify Routes checks and how its card words the result. Verify path-checks a sample
/// (PathCheck): single addresses only, because a range has no one address to connect to, and at
/// most `sampleSize` of them, the first in sort order. The card says how many of how many routes
/// that was, lists failures first, and keeps the sample's order. Pure, so the scope and the
/// wording are tested.
enum RouteCheck {
    /// Addresses checked per run, so a check stays short: each connection can wait 3 s.
    static let sampleSize = 10
    /// Failures listed in the card before "+ N more".
    static let visibleFailures = 3

    struct Plan: Equatable {
        /// The addresses to check, in the order they are checked.
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
        /// In the order the addresses were checked.
        let results: [RouteVerificationResult]
        let sources: [String: String]
        let singleAddresses: Int
        let routeCount: Int
        /// When the check started logging: its result lines are all at or after this.
        let logsFrom: Date
        let at: Date
        /// The control left the same way as the routed addresses, so the run proves nothing.
        let controlBroken: Bool

        init(plan: Plan, results: [RouteVerificationResult], logsFrom: Date, at: Date,
             controlBroken: Bool = false) {
            self.results = results
            self.controlBroken = controlBroken
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
        /// Addresses the path check saw leave another way than their route says.
        var leftWrongWay: [RouteVerificationResult] { results.filter(\.leftWrongWay) }
    }

    /// What to check. In VPN Only the app's catch-all ranges are left out of the count, as the
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
                ? String(localized: "Nothing to check: the only address is a range, which the path check cannot test")
                : String(localized: "Nothing to check: all \(routeCount) addresses are ranges, which the path check cannot test"),
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
        /// Every destination behind the row, for Copy Addresses.
        var allAddresses: [String] = []

        var countText: String {
            routeCount == 0 ? String(localized: "no addresses") : routes(routeCount)
        }

        /// The number in the row's column; the word "addresses" is said once, above the column.
        var numberText: String { "\(routeCount)" }

        /// What VoiceOver reads for the whole row, as one element: "Telegram, 18 addresses",
        /// and for a problem row its reason too.
        func spokenLabel(reason: String? = nil) -> String {
            ([name, countText] + (reason.map { [$0] } ?? [])).joined(separator: ", ")
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
        /// VPN Only's catch-alls are installed: everything not listed goes direct.
        let everythingElseDirect: Bool
        /// Entries that should have routes and have none, shown or not (`Row.isProblem`).
        var problemCount: Int { problemRows.count }
        /// Those entries, every one, for Status > Problems: `rows` stops at `visibleRows`.
        var problemRows: [Row] = []

        var countText: String { routes(routeCount) }
    }

    struct InstalledRoute: Equatable {
        let destination: String
        let source: String
    }

    /// The rows shown before the list scrolls.
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

    /// The connected dropdown's rows: an entry without routes is not a problem (no ▲, no
    /// Retry) while an apply may still add them, or after a Remove All Routes that still stands,
    /// where the empty entry is what the user asked for, as the status line and Status >
    /// Problems read it.
    static func emptyEntriesAreExpected(running: Bool, pending: RouteManager.PendingReconnectApply?,
                                        lastChange: RouteManager.RouteChangeOutcome?,
                                        currentRouteCount: Int, helperReady: Bool) -> Bool {
        mayStillAddRoutes(running: running, pending: pending)
            || DropdownCopy.removalStands(lastChange, currentRouteCount: currentRouteCount, helperReady: helperReady)
    }

    /// The list's title with no VPN connected: Bypass keeps its routes for the reconnect on
    /// purpose; in the other modes, or after a Remove All Routes that left some, a route still
    /// installed is a removal that failed.
    static func disconnectedTitle(_ mode: DropdownCopy.Mode, lastChange: RouteManager.RouteChangeOutcome? = nil,
                                  in bundle: Bundle = .main) -> String {
        let removalFailed = lastChange?.kind == .removedAll && (lastChange?.failedCount ?? 0) > 0
        return mode == .bypass && !removalFailed ? String(localized: "Kept for when it reconnects", bundle: bundle)
                                                 : String(localized: "Still routed", bundle: bundle)
    }

    /// The list's title while paused: what Resume puts back.
    static func pausedTitle(_ mode: DropdownCopy.Mode, in bundle: Bundle = .main) -> String {
        switch mode {
        case .bypass: return String(localized: "Will skip the VPN again", bundle: bundle)
        case .vpnOnly: return String(localized: "Will go through the VPN again", bundle: bundle)
        case .custom: return String(localized: "Will be routed by your rules again", bundle: bundle)
        }
    }

    static var leftoverName: String { String(localized: "Left from earlier") }
    static var everythingElse: String { String(localized: "Everything else") }
    static var direct: String { String(localized: "direct") }

    /// nil when there is nothing to list: no entry on and no route installed (the status line
    /// above already says so). `routedOnly` lists only entries that have routes, for the
    /// disconnected dropdown, where an entry without any is expected, not a problem.
    static func make(mode: DropdownCopy.Mode, config: RouteManager.Config,
                     routes: [InstalledRoute], busy: Bool, routedOnly: Bool = false,
                     title: String? = nil) -> Summary? {
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

        // A wildcard gets routes only when a lookup under it learns one, so with none yet it is
        // idle, not broken: listed, never a problem. Learned routes are recorded under
        // `*.suffix`, not under a service, so a service of wildcards only is the same.
        var idleAllowed: Set<String> = []
        switch mode {
        case .bypass:
            idleAllowed.formUnion(config.domains.filter { $0.enabled && $0.isWildcard }.map(\.domain))
            idleAllowed.formUnion(config.services.filter {
                $0.enabled && $0.ipRanges.isEmpty && !$0.domains.isEmpty && $0.domains.allSatisfy(WildcardDomain.isWildcard)
            }.map(\.name))
        case .vpnOnly:
            idleAllowed.formUnion(config.inverseDomains.filter { $0.enabled && $0.isWildcard }.map(\.domain))
        case .custom:
            break
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
                isProblem: expectsRoutes && destinations.isEmpty && !busy && !idleAllowed.contains(id),
                addresses: Array(destinations.prefix(tooltipAddresses)),
                hiddenAddresses: max(0, destinations.count - tooltipAddresses),
                allAddresses: destinations)
        }

        var rows: [Row] = []
        var listed: Set<String> = []
        for entry in entries where !listed.contains(entry.source) {
            listed.insert(entry.source)
            let destinations = bySource[entry.source] ?? []
            if destinations.isEmpty && (!entry.expectsRoutes || routedOnly) { continue }
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
        return Summary(title: title ?? Self.title(mode),
                       routeCount: addressCount(routes, vpnOnly: mode == .vpnOnly),
                       rows: rows,
                       everythingElseDirect: everythingElseDirect,
                       problemRows: rows.filter(\.isProblem))
    }

    private static func routes(_ count: Int) -> String {
        count == 1 ? String(localized: "1 address") : String(localized: "\(count) addresses")
    }

    // MARK: Row actions (flow fix 5)

    /// The entry a row's Turn Off switches off. Custom mode can hold several rules with one
    /// pattern, and the row counts them as one, so it turns them all off.
    enum Target: Equatable {
        case service(id: String)
        case domain(UUID)
        case inverseDomain(UUID)
        case rules([UUID])
    }

    /// What a row offers, in the right-click menu's order.
    enum Command: Equatable {
        case turnOff(Target), retry, showInSettings(SettingsView.SettingsTab), copyAddresses
    }

    /// The entry behind a row that is still on, or nil (the "Left from earlier" row, or an
    /// entry turned off since).
    static func target(of row: Row, mode: DropdownCopy.Mode, config: RouteManager.Config) -> Target? {
        switch (mode, row.icon) {
        case (_, .leftover):
            return nil
        case (.custom, _):
            let ids = config.rules.filter { $0.enabled && $0.pattern == row.id }.map(\.id)
            return ids.isEmpty ? nil : .rules(ids)
        case (.bypass, .service(let id)):
            return config.services.contains { $0.id == id && $0.enabled } ? .service(id: id) : nil
        case (.bypass, _):
            return config.domains.first { $0.domain == row.id && $0.enabled }.map { .domain($0.id) }
        case (.vpnOnly, _):
            return config.inverseDomains.first { $0.domain == row.id && $0.enabled }.map { .inverseDomain($0.id) }
        }
    }

    /// The Settings page that lists the row's entry.
    static func settingsPage(for row: Row, mode: DropdownCopy.Mode) -> SettingsView.SettingsTab {
        switch (mode, row.icon) {
        case (_, .leftover): return .status
        case (.custom, _): return .rules
        case (_, .service): return .services
        default: return .domains
        }
    }

    /// The right-click menu: Turn Off, Retry (a problem row, when an apply can run now), Show
    /// in Settings, Copy Addresses (when it has any).
    static func commands(for row: Row, mode: DropdownCopy.Mode, config: RouteManager.Config,
                         canRetry: Bool) -> [Command] {
        var out: [Command] = []
        if let target = target(of: row, mode: mode, config: config) { out.append(.turnOff(target)) }
        if row.isProblem && canRetry { out.append(.retry) }
        out.append(.showInSettings(settingsPage(for: row, mode: mode)))
        if !row.allAddresses.isEmpty { out.append(.copyAddresses) }
        return out
    }

    /// The one action shown at the row's end on hover: Retry on a problem row, Turn Off on a
    /// working one.
    static func hoverCommand(in commands: [Command], isProblem: Bool) -> Command? {
        if isProblem, commands.contains(.retry) { return .retry }
        return commands.first { if case .turnOff = $0 { return true } else { return false } }
    }

    /// A problem row's reason, under its name: what the last apply said for the entry, or
    /// that nothing is routed for it.
    static func problemReason(for row: Row, failures: [RouteManager.RouteFailure],
                              in bundle: Bundle = .main) -> String? {
        guard row.isProblem else { return nil }
        if let failure = failures.first(where: { $0.entry == row.id || ($0.entry.isEmpty && $0.target == row.id) }) {
            let what: String
            switch failure.kind {
            case .notResolved: what = String(localized: "Did not resolve", bundle: bundle)
            case .notRouted: what = String(localized: "Not routed", bundle: bundle)
            case .notRemoved: what = String(localized: "Not removed", bundle: bundle)
            }
            return String(localized: "\(what): \(failure.reason)", bundle: bundle)
        }
        return String(localized: "No address is routed for it.", bundle: bundle)
    }
}

// MARK: - Mode control

/// The Mode row under the status block: the word "Mode", then a popup with all three modes,
/// the same in every mode. Switching mode changes how all traffic routes, and entering Custom
/// migrates the lists into rules, so a pick asks first. The selection reads the saved mode: the
/// popup changes after Switch, and Cancel leaves it where it was.
struct DropdownModeRow: View {
    @EnvironmentObject var routeManager: RouteManager
    /// The mode a pick is asking about while the question is open.
    @State private var asking: RouteManager.RoutingMode?
    /// Bumped on every pick. The popup shows the picked item itself, and SwiftUI does not push
    /// the unchanged saved mode back into it, so it is rebuilt from the saved mode.
    @State private var generation = 0

    var body: some View {
        HStack(spacing: 10) {
            Text("Mode")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textSecondary)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            picker
        }
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
                // After this click is handled, so the popup is rebuilt from the saved mode.
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
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .id(generation)
        .help(DropdownStatus.modeDescription(DropdownModePicker.copyMode(routeManager.config.routingMode)))
        .accessibilityLabel(String(localized: "Mode"))
    }

    /// While the question is open the run loop is in its modal panel mode, so the app's
    /// default-mode timers (the 30 s status refresh, the DNS refresh) wait and fire once it
    /// closes. Main-queue work and main-actor tasks keep running.
    private func ask(_ mode: RouteManager.RoutingMode) {
        DropdownModePicker.askAndSwitch(to: mode, routeManager: routeManager)
        asking = nil
    }
}

// MARK: - Status block

/// The top of the dropdown: three lines at one left edge, in every state. Line 1 says who is
/// connected, line 2 what is routed, line 3 the numbers, or the one problem with its one button.
/// Takes a finished `DropdownStatus`, so any state can be rendered on its own. VoiceOver reads
/// each line as its own element, and the button as a button.
struct StatusBlock: View {
    let status: DropdownStatus
    let onAction: (DropdownStatus.Line3.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(status.headline)
                .font(Theme.Font.strong)
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(status.sentence)
                .font(Theme.Font.body)
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            line3
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var line3: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if status.line3.isProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.attention)
                    .accessibilityHidden(true)
            }
            // A blank line still takes its height, so the block keeps its shape.
            Text(status.line3.text.isEmpty ? " " : status.line3.text)
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(status.line3.isProblem
                    ? String(localized: "Problem: \(status.line3.text)")
                    : status.line3.text)
                .accessibilityHidden(status.line3.text.isEmpty)
            Spacer(minLength: 4)
            if let action = status.line3.action {
                actionButton(action)
            }
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private func actionButton(_ action: DropdownStatus.Line3.Action) -> some View {
        switch action {
        case .fix:
            Button(String(localized: "Fix…")) { onAction(.fix) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .help(DropdownStatus.Line3.spokenName(.fix))
                .accessibilityLabel(DropdownStatus.Line3.spokenName(.fix))
        case .show:
            Button(String(localized: "Show")) { onAction(.show) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(DropdownStatus.Line3.spokenName(.show))
                .accessibilityLabel(DropdownStatus.Line3.spokenName(.show))
        case .resume:
            Button(String(localized: "Resume")) { onAction(.resume) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .keyboardShortcut(.pause)
                .help(DropdownShortcut.pause.help(DropdownStatus.Line3.spokenName(.resume)))
                .accessibilityLabel(DropdownStatus.Line3.spokenName(.resume))
        case .retryPause:
            Button(String(localized: "Retry")) { onAction(.retryPause) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(DropdownStatus.Line3.spokenName(.retryPause))
                .accessibilityLabel(DropdownStatus.Line3.spokenName(.retryPause))
        }
    }
}

/// The dropdown's width: as wide as its language needs, between 340 and 400 pt, so Spanish and
/// French sit on one line where English does.
enum DropdownLayout {
    static let minWidth: CGFloat = 340
    static let maxWidth: CGFloat = 400

    static func width(language: String?) -> CGFloat {
        let extra: CGFloat
        switch language.map({ String($0.prefix(2)) }) {
        case "es": extra = 40
        case "fr": extra = 60
        default: extra = 0
        }
        return min(maxWidth, minWidth + extra)
    }

    /// The width for the language the app runs in.
    static var current: CGFloat { width(language: Bundle.main.preferredLocalizations.first) }
}

/// What the status block says, as a pure function of the app's state, so every state and its
/// wording is unit-tested. The one place that decides the chip, the sentence and line 3.
struct DropdownStatus: Equatable {
    enum Tone: Equatable {
        /// `idle` is NOT SET UP or no VPN: nothing is wrong.
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

    /// The block's third line: the numbers when all is well, or the one problem and the one
    /// button that deals with it.
    struct Line3: Equatable {
        enum Action: Equatable {
            /// Open Status, where the helper's row and its Install button are.
            case fix
            /// Open Status, where Problems lists every failure behind the count.
            case show
            /// End the pause and put the routes back.
            case resume
            /// Try again to remove the routes a pause could not remove.
            case retryPause
        }

        let text: String
        var isProblem = false
        var action: Action?

        static let blank = Line3(text: "")

        /// The button's name for VoiceOver and its tooltip.
        static func spokenName(_ action: Action, in bundle: Bundle = .main) -> String {
            switch action {
            case .fix: return String(localized: "Fix the helper in Settings > Status", bundle: bundle)
            case .show: return String(localized: "Show the problems in Settings > Status", bundle: bundle)
            case .resume: return String(localized: "Resume: put the routes back", bundle: bundle)
            case .retryPause: return String(localized: "Retry removing the routes", bundle: bundle)
            }
        }
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
        /// The connected VPN sends every connection into its tunnel above the routing table
        /// (`VPNKillSwitchReader`), so no route set here takes effect.
        var killSwitch: VPNKillSwitch? = nil
        /// The app's first detection is still running: nothing it would say about the VPN or
        /// the routes is known yet.
        var isStarting: Bool = false
        /// Entries that should have routes and have none, with no apply running or waiting
        /// that could add them (`RoutedBySource.Summary.problemCount`).
        var entriesWithoutAddresses: Int = 0
        /// The last Verify Routes: how many addresses it checked, how many the path check saw
        /// leave the wrong way, and whether its control was broken. An address that only did
        /// not answer on 443 is not counted: a site may block that whatever the route.
        var lastCheckCount: Int = 0
        var lastCheckWrongWay: Int = 0
        var lastCheckBroken: Bool = false
        /// The pause in progress (Pause.swift), nil when not paused.
        var pause: PauseState? = nil
    }

    /// The chip right of the wordmark: the only coloured signal in the block.
    let chip: StatusChip.Kind
    /// The Status page's colour for the same state.
    let tone: Tone
    /// Line 1.
    let headline: String
    /// Line 2.
    let sentence: String
    /// The Status page's line under the sentence.
    let note: String?
    let line3: Line3

    /// Some of it is routed and some is not.
    var isPartial: Bool { chip == .partlyRouted }

    static func make(_ input: Input, now: Date) -> DropdownStatus {
        let name = input.vpnName ?? String(localized: "VPN")

        // Before anything else: at launch the VPN and the routes are not read yet, so "No VPN
        // connected" or "Not routing" would be a guess (A3).
        if input.isStarting {
            return DropdownStatus(chip: .waiting, tone: .idle,
                                  headline: String(localized: "Starting…"),
                                  sentence: String(localized: "Detecting the VPN and applying routes."),
                                  note: nil, line3: .blank)
        }

        // Paused, and every route is out: the state drawn. When some are still in, the block
        // says how many with Retry, and never says Paused (flow fix 2).
        if let pause = input.pause {
            // A helper that is down with a VPN up is shown as the helper's state, with Fix.
            if input.installedRoutes == 0 && !input.everythingElseDirect
                && (input.helperReady || !input.isVPNConnected) {
                return paused(pause, input: input, name: name, now: now)
            }
            if input.helperReady {
                let left = input.installedRoutes == 1
                    ? String(localized: "1 address is still routed.")
                    : String(localized: "\(input.installedRoutes) addresses are still routed.")
                return DropdownStatus(chip: .notRouting, tone: .warn,
                                      headline: input.isVPNConnected ? String(localized: "\(name) connected")
                                                                     : String(localized: "No VPN connected"),
                                      sentence: String(localized: "Pausing could not remove every route."),
                                      note: left, line3: Line3(text: left, isProblem: true, action: .retryPause))
            }
            // The helper is down: its own state below says so, with Fix.
        }

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
            // An ordinary state, grey: no VPN is not a fault.
            return DropdownStatus(chip: .off, tone: .idle,
                                  headline: String(localized: "No VPN connected"),
                                  sentence: sentence, note: nil,
                                  line3: Line3(text: DropdownCopy.disconnectedSentence(input.mode)))
        }

        guard input.helperReady else {
            // Never "nothing is routed": a stopped helper leaves the routes it added in the
            // kernel, so line 3 says how many are still in place.
            let left: String
            switch input.installedRoutes {
            case 0: left = String(localized: "No address is routed.")
            case 1: left = String(localized: "1 address from before is still routed.")
            default: left = String(localized: "\(input.installedRoutes) addresses from before are still routed.")
            }
            return DropdownStatus(chip: .notRouting, tone: .warn,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: String(localized: "The helper is not running, so no route can change."),
                                  note: left, line3: Line3(text: left, isProblem: true, action: .fix))
        }

        // Before WAITING and ON: the routes stay installed, since the kill switch can be turned
        // off at any time, but while it is on none of them changes where traffic goes.
        if let killSwitch = input.killSwitch {
            let note = killSwitchNote(killSwitch)
            return DropdownStatus(chip: .notRouting, tone: .warn,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: killSwitchSentence(killSwitch, fallbackName: name, mode: input.mode),
                                  note: note, line3: Line3(text: note, isProblem: true))
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
                let note = String(localized: "Refresh Routes applies now anyway.")
                return DropdownStatus(
                    chip: .waiting, tone: .warn,
                    headline: String(localized: "\(name) keeps dropping"),
                    sentence: String(localized: "It dropped \(strikes) times right after routes were applied, so the app is not applying again until the tunnel has held for \(minutesLeft(left))."),
                    note: note, line3: Line3(text: note))
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
                    chip: .waiting, tone: .warn,
                    headline: String(localized: "\(name) reconnected \(DropdownCopy.age(since: pending.connectedAt, now: now))"),
                    sentence: sentence, note: note, line3: Line3(text: note))
            }
        }

        if input.installedRoutes == 0 && input.nothingConfigured {
            // Not a fault: nothing has been asked for yet, and the question sits right below.
            return DropdownStatus(chip: .off, tone: .idle,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: String(localized: "Nothing skips the VPN yet."),
                                  note: scheduledNote, line3: Line3(text: scheduledNote ?? ""))
        }
        let problems = partialReasons(input)
        if input.installedRoutes == 0 && !input.everythingElseDirect {
            return DropdownStatus(chip: .notRouting, tone: .warn,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: String(localized: "Nothing is routed right now."),
                                  note: scheduledNote,
                                  line3: Line3(text: numbersLine(input, now: now), isProblem: true,
                                               action: problems.isEmpty ? nil : .show))
        }
        if !problems.isEmpty {
            // Some of it is routed and some is not: amber, never a green ON (A4).
            return DropdownStatus(chip: .partlyRouted, tone: .warn,
                                  headline: String(localized: "\(name) connected"),
                                  sentence: whatIsRouted(input),
                                  note: ([scheduledNote].compactMap { $0 } + problems).joined(separator: " "),
                                  line3: Line3(text: problemLine(input, now: now) ?? problems[0],
                                               isProblem: true, action: .show))
        }
        return DropdownStatus(chip: .on, tone: .ok,
                              headline: String(localized: "\(name) connected"),
                              sentence: whatIsRouted(input), note: scheduledNote,
                              line3: Line3(text: numbersLine(input, now: now)))
    }

    /// Paused with every route out. Bypass and Custom (where it is only offered when every rule
    /// goes Direct) say the same: traffic follows the VPN's own routes, which never claims that
    /// everything goes through the VPN, since a split-tunnel VPN sends some of it outside.
    static func paused(_ pause: PauseState, input: Input, name: String, now: Date) -> DropdownStatus {
        let headline = input.isVPNConnected ? String(localized: "\(name) connected")
                                            : String(localized: "No VPN connected")
        let sentence = input.isVPNConnected
            ? String(localized: "Paused: traffic follows the VPN's own routes.")
            : String(localized: "Paused: the app routes nothing.")
        let when = resumesLine(pause, now: now)
        return DropdownStatus(chip: .paused, tone: .idle, headline: headline, sentence: sentence,
                              note: when, line3: Line3(text: when, action: .resume))
    }

    /// "Resumes at 14:32, in 58 min", "Resumes when the VPN reconnects", "Paused until you resume".
    static func resumesLine(_ pause: PauseState, now: Date) -> String {
        switch pause.length {
        case .minutes:
            guard let until = pause.until else { return "" }
            let left = until.timeIntervalSince(now)
            let when = until.formatted(date: .omitted, time: .shortened)
            return left > 0
                ? String(localized: "Resumes at \(when), in \(countdown(left))")
                : String(localized: "Resuming now.")
        case .untilReconnect:
            return String(localized: "Resumes when the VPN reconnects.")
        case .untilResume:
            return String(localized: "Paused until you resume.")
        }
    }

    /// Line 3 when all is well: "62 addresses · applied 24 s ago · DNS again in 18 min". The
    /// age is left out when no apply or removal is shown, the DNS part when the automatic
    /// check is off.
    static func numbersLine(_ input: Input, now: Date) -> String {
        var parts = [DropdownCopy.addresses(input.installedRoutes)]
        if let change = DropdownCopy.shownRouteChange(input.lastRouteChange, currentRouteCount: input.installedRoutes) {
            let when = DropdownCopy.age(since: change.at, now: now)
            parts.append(change.kind == .applied
                ? String(localized: "applied \(when)")
                : String(localized: "removed \(when)"))
        }
        if input.autoDNSRefresh, let next = input.nextDNSRefresh {
            let left = next.timeIntervalSince(now)
            parts.append(left > 0
                ? String(localized: "DNS again in \(countdown(left))")
                : String(localized: "DNS again now"))
        }
        return parts.joined(separator: " · ")
    }

    /// Line 3 when the last apply failed in part: "62 addresses, 7 failed · 1 min ago". nil
    /// when the last apply had no failures.
    static func problemLine(_ input: Input, now: Date) -> String? {
        guard let change = DropdownCopy.shownRouteChange(input.lastRouteChange, currentRouteCount: input.installedRoutes),
              change.kind == .applied, change.failedCount > 0 else { return nil }
        let routes = DropdownCopy.addresses(input.installedRoutes)
        let when = DropdownCopy.age(since: change.at, now: now)
        return String(localized: "\(routes), \(change.failedCount) failed") + " · " + when
    }

    /// Why ON is only partly true, one sentence per reason: the last apply had failures, an
    /// entry has no addresses, or the last route check saw addresses leave the wrong way or
    /// could not tell the ways apart.
    static func partialReasons(_ input: Input) -> [String] {
        var reasons: [String] = []
        if let change = DropdownCopy.shownRouteChange(input.lastRouteChange, currentRouteCount: input.installedRoutes),
           change.kind == .applied, change.failedCount > 0 {
            reasons.append(change.failedCount == 1
                ? String(localized: "1 failed in the last apply.")
                : String(localized: "\(change.failedCount) failed in the last apply."))
        }
        switch input.entriesWithoutAddresses {
        case 0: break
        case 1: reasons.append(String(localized: "1 entry has no addresses."))
        default: reasons.append(String(localized: "\(input.entriesWithoutAddresses) entries have no addresses."))
        }
        if input.lastCheckBroken {
            reasons.append(String(localized: "The last route check is broken: it cannot tell the two ways apart."))
        } else if input.lastCheckWrongWay > 0 {
            reasons.append(String(localized: "\(input.lastCheckWrongWay) of \(input.lastCheckCount) checked addresses left the wrong way."))
        }
        return reasons
    }

    // MARK: Pieces

    /// What a kill switch does to the app's routes: the cause, then what it means in this mode.
    static func killSwitchSentence(_ killSwitch: VPNKillSwitch, fallbackName: String,
                                   mode: DropdownCopy.Mode) -> String {
        guard killSwitch.includeAllNetworks else {
            // `enforceRoutes` only counts on the tunnel the app acts on, so `fallbackName` is its
            // VPN. It takes only what its own routes cover, which the app does not read, so the
            // sentence cannot say that a given site still goes through it.
            let name = killSwitch.name ?? fallbackName
            return String(localized: "\(name) makes its own routes win over this app's.") + " "
                + String(localized: "Anything its routes cover goes through it, whatever is set here.")
        }
        // `includeAllNetworks` counts on any connected VPN, so an unnamed one may not be the
        // VPN the header names.
        let cause: String
        if let name = killSwitch.name {
            cause = String(localized: "\(name)'s kill switch sends all traffic through the VPN.")
        } else {
            cause = String(localized: "A connected VPN's kill switch sends all traffic through the VPN.")
        }
        let effect: String
        switch mode {
        case .bypass: effect = String(localized: "Sites set to skip it still go through it.")
        case .vpnOnly: effect = String(localized: "Everything meant to skip it still goes through it.")
        case .custom: effect = String(localized: "Rules set to go direct still go through it.")
        }
        return cause + " " + effect
    }

    /// How to get out of it, and what still skips the VPN.
    static func killSwitchNote(_ killSwitch: VPNKillSwitch) -> String {
        let fix = killSwitch.includeAllNetworks
            ? String(localized: "Turn off its kill switch, or use its own split tunnelling.")
            : String(localized: "Turn off that setting in the VPN app, or use its own split tunnelling.")
        guard killSwitch.includeAllNetworks && killSwitch.excludeLocalNetworks else { return fix }
        return fix + " " + String(localized: "Local-network addresses still skip it.")
    }

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

/// The dropdown's Mode control: one popup with all three modes, in every mode.
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
/// page's own switch, a row that opens that page on its catalogue, a row to add a site, and a line that offers
/// VPN Only. Each switch and each add applies at once, through the same RouteManager calls.
struct FirstRunSetupView: View {
    @EnvironmentObject var routeManager: RouteManager
    let onOpenServices: () -> Void
    let onUseVPNOnly: () -> Void
    @State private var site: String
    /// What the last add did, shown under the field (proposal 5's line).
    @State private var feedback: AddDomainFeedback?
    /// ⌘N puts the cursor in the site field, as in the add field it stands in for.
    @FocusState private var siteFocused: Bool

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
                        Text(FirstRunSetup.allServices(Config.defaultServices.count))
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
                        .focused($siteFocused)
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
                .background {
                    Button("") { siteFocused = true }
                        .keyboardShortcut(.addSite)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
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

/// The list `RoutedBySource` describes: what the user added, one `ListRow` each, with its
/// number of addresses in one column (the word is said once, above it). A problem row has ▲
/// and its reason under the name. On hover a row shows one action, Retry or Turn Off; its
/// right-click menu and the VoiceOver rotor have them all. Past eight rows the list scrolls.
struct RoutedBySourceCard: View {
    let summary: RoutedBySource.Summary
    /// The reason under a problem row's name.
    var reason: (RoutedBySource.Row) -> String? = { _ in nil }
    /// The actions a row offers: the hover one and the full menu.
    var actions: (RoutedBySource.Row) -> (hover: RowAction?, menu: [RowAction]) = { _ in (nil, []) }

    /// The doc screenshots draw this row's hover action, as if the pointer were on it.
    static var hoveredRowForScreenshots: String?

    /// The height of the rows shown before the list scrolls.
    static func scrollHeight(_ rows: [RoutedBySource.Row], reasons: [String?]) -> CGFloat? {
        guard rows.count > RoutedBySource.visibleRows else { return nil }
        return zip(rows, reasons).prefix(RoutedBySource.visibleRows).reduce(0) { sum, pair in
            sum + (pair.1 == nil ? ListRow.singleLineHeight : ListRow.twoLineHeight)
        }
    }

    var body: some View {
        let reasons = summary.rows.map(reason)
        let numberWidth = ListRow.numberColumnWidth(for: summary.rows.map(\.numberText) + ["000"])
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(summary.title)
                    .font(Theme.Font.section)
                    .foregroundColor(Theme.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("\(summary.title), \(summary.countText)")
                Spacer()
                if !summary.rows.isEmpty {
                    Text("Addresses")
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, ListRow.inset)

            if !summary.rows.isEmpty {
                let list = VStack(spacing: 0) {
                    ForEach(Array(summary.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, reason: reasons[index], numberWidth: numberWidth)
                    }
                }
                if let height = Self.scrollHeight(summary.rows, reasons: reasons) {
                    ScrollView { list }
                        .frame(height: height)
                } else {
                    list
                }
            }

            if summary.everythingElseDirect {
                ListRow(glyph: "arrow.turn.down.right", name: RoutedBySource.everythingElse,
                        number: RoutedBySource.direct, numberWidth: ListRow.numberColumnWidth(for: [RoutedBySource.direct]))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(RoutedBySource.everythingElse), \(RoutedBySource.direct)")
            }
        }
        .padding(.horizontal, -ListRow.inset)
    }

    private func rowView(_ row: RoutedBySource.Row, reason: String?, numberWidth: CGFloat) -> some View {
        let offered = actions(row)
        return ListRow(glyph: Self.symbol(row.icon), name: row.name, detail: reason,
                       needsAttention: row.isProblem, number: row.numberText, numberWidth: numberWidth,
                       actions: offered.hover.map { [$0] } ?? [], menuActions: offered.menu,
                       showsActions: Self.hoveredRowForScreenshots == row.name)
            .help(row.tooltip)
            // One VoiceOver element per row, its actions in the rotor.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.spokenLabel(reason: reason))
            .accessibilityActions {
                ForEach(offered.menu) { action in
                    Button(action.name, action: action.perform)
                }
            }
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

/// The last Verify Routes, on the Status page: what it checked, the failures first, then one
/// line for the rest.
struct RouteCheckCard: View {
    let run: RouteCheck.Run
    /// False once the log has lost the check's lines, so the link would open a page without them.
    let logsHoldResults: Bool
    let onShowLogs: () -> Void
    /// Takes the card away; nil draws no Dismiss button.
    var onDismiss: (() -> Void)?

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
                if let onDismiss {
                    Button(String(localized: "Dismiss"), action: onDismiss)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Dismiss the route check"))
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
