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
        let count = routeManager.uniqueRouteCount
        guard !routeManager.activeRoutes.isEmpty else {
            return String(localized: "VPN Bypass: VPN connected but no routes are being enforced")
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

// MARK: - Branded App Name View (for use in dropdowns/settings)

struct BrandedAppName: View {
    var fontSize: CGFloat = 15
    /// Show the mark alongside the type (the full lockup). Off where the mark would repeat
    /// something already on screen.
    var showsMark: Bool = true

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
            Text("VPN")
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.textPrimary)

            Text("Bypass")
                .font(.system(size: fontSize, weight: .light, design: .rounded))
                .foregroundColor(Theme.Brand.sky)
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
    @State private var isVerifying = false
    /// The mode a tap wants to switch to, pending confirmation. Mirrors
    /// RoutingModePicker in SettingsView so both surfaces behave identically —
    /// switching mode changes how ALL traffic routes (and entering Custom
    /// migrates your lists), so it's deliberately a two-step action.
    @State private var pendingMode: RouteManager.RoutingMode?

    private let accentGradient = LinearGradient(
        colors: [Theme.success, Theme.successDark],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    var body: some View {
        VStack(spacing: 0) {
            // App title
            titleHeader
            helperDownBanner
            nothingConfiguredHint
            
            // Header with VPN status
            headerSection

            // Routing mode toggle
            routingModeToggle

            Divider()
                .padding(.vertical, 8)

            // Main content
            if routeManager.isLoading {
                loadingContent
            } else if routeManager.isVPNConnected {
                connectedContent
            } else {
                disconnectedContent
            }
            
            Divider()
                .padding(.vertical, 8)
            
            // Footer actions
            footerActions
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            // Refresh VPN status when menu opens
            routeManager.refreshStatus()
        }
        .alert("Switch routing mode?", isPresented: Binding(
            get: { pendingMode != nil },
            set: { if !$0 { pendingMode = nil } }
        ), presenting: pendingMode) { mode in
            Button("Cancel", role: .cancel) { pendingMode = nil }
            Button("Switch to \(mode.displayName)") {
                routeManager.setRoutingMode(mode)
                pendingMode = nil
            }
        } message: { mode in
            Text(confirmationMessage(for: mode))
        }
    }

    /// Mirrors RoutingModePicker.confirmationMessage(for:) in SettingsView
    /// verbatim (that one is private to SettingsView.swift) so both surfaces
    /// show identical wording for the same transition.
    private func confirmationMessage(for mode: RouteManager.RoutingMode) -> String {
        switch mode {
        case .bypass:
            return "Everything will go through your VPN except the sites you list. Your custom routes stay saved."
        case .vpnOnly:
            return "Only the sites you list will use your VPN; everything else goes direct."
        case .custom:
            return routeManager.config.schemaVersion < 2
                ? "Your listed domains and services become editable rules you can send through any route (a proxy, a Tailscale peer, or a specific VPN). You can switch back anytime."
                : "Switch to your per-rule custom routing. You can switch back to a simple mode anytime."
        }
    }

    // MARK: - Title Header
    
    private var titleHeader: some View {
        HStack(spacing: 8) {
            // App name with branded colors
            BrandedAppName(fontSize: 15)
            
            Spacer()
            
            // Live status indicator.
            //
            // "ON" is a claim about ENFORCEMENT, not about the VPN: with the helper down this
            // app enforces nothing, and showing a green ON next to "VPN Connected" while zero
            // routes were installed is exactly how a broken install looked healthy for weeks.
            HStack(spacing: 4) {
                Circle()
                    .fill(statusPill.color)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusPill.color.opacity(0.6), radius: 3)

                Text(statusPill.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(statusPill.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(statusPill.color.opacity(0.15))
            )
        }
        .padding(.bottom, 12)
    }

    /// What the pill may honestly claim right now.
    private var statusPill: (label: String, color: Color) {
        guard routeManager.isVPNConnected else {
            return (String(localized: "OFF"), Theme.error)
        }
        if !helperManager.helperState.isReady {
            return (String(localized: "NOT ENFORCING"), Theme.warning)
        }
        if routeManager.activeRoutes.isEmpty {
            return (String(localized: "NO ROUTES"), Theme.warning)
        }
        return (String(localized: "ON"), Theme.success)
    }

    /// First-run honesty: a fresh install prompts for an admin password and then routes
    /// NOTHING (empty domain list, every service disabled). Say so, instead of leaving a
    /// silently inert app behind the most intrusive prompt it will ever show.
    @ViewBuilder
    private var nothingConfiguredHint: some View {
        let nothingConfigured = routeManager.config.routingMode != .custom
            && routeManager.config.domains.isEmpty
            && !routeManager.config.services.contains(where: { $0.enabled })
        if nothingConfigured && routeManager.activeRoutes.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(Theme.blue)
                Text(String(localized: "Nothing configured yet — add a domain below or enable a service in Settings to start bypassing."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.blue.opacity(0.08)))
            .padding(.bottom, 8)
        }
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
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.12)))
            .padding(.bottom, 8)
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 10) {
            // Status icon - use VPN type icon if available
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                
                Image(systemName: routeManager.isVPNConnected ? (routeManager.vpnType?.icon ?? "checkmark.shield.fill") : "shield.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(statusColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(routeManager.isVPNConnected ? String(localized: "VPN Connected") : String(localized: "VPN Disconnected"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(statusColor)
                
                if routeManager.isVPNConnected {
                    if let vpnType = routeManager.vpnType {
                        Text(vpnType.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if let vpnIface = routeManager.vpnInterface {
                        Text("via \(vpnIface)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if let gateway = routeManager.localGateway {
                    Text("Gateway: \(gateway)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Active routes badge
            if routeManager.isVPNConnected && !routeManager.activeRoutes.isEmpty {
                VStack(spacing: 1) {
                    Text("\(routeManager.uniqueRouteCount)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.success)
                    Text("routes")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.success.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    // MARK: - Connected Content
    
    private var connectedContent: some View {
        VStack(spacing: 12) {
            // Quick add domain
            if isAddingDomain {
                HStack(spacing: 8) {
                    TextField("domain.com", text: $newDomain)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)
                        .onSubmit {
                            addDomainAndClose()
                        }
                    
                    Button {
                        addDomainAndClose()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(accentGradient)
                    }
                    .buttonStyle(.plain)
                    .disabled(newDomain.isEmpty)
                    
                    Button {
                        isAddingDomain = false
                        newDomain = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
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
            
            // Active services summary (bypass mode) / Routes in use (custom mode)
            if routeManager.config.routingMode == .bypass {
                activeServicesSummary
            } else if routeManager.config.routingMode == .custom {
                routesInUseSummary
            }
            
            // Recent activity
            if !routeManager.activeRoutes.isEmpty {
                recentRoutesSection
            }
            
            // Route verification status
            if !routeManager.routeVerificationResults.isEmpty {
                routeVerificationSection
            }
            
            // Action buttons
            HStack(spacing: 8) {
                Button {
                    routeManager.refreshRoutes()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("Refresh Routes")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(accentGradient)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                
                Button {
                    Task {
                        await routeManager.removeAllRoutes()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            
            // Verify routes button
            if !routeManager.activeRoutes.isEmpty {
                Button {
                    isVerifying = true
                    Task {
                        await routeManager.verifyRoutes()
                        isVerifying = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isVerifying {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 11))
                        }
                        Text(isVerifying ? String(localized: "Verifying...") : String(localized: "Verify Routes"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isVerifying)
            }
        }
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
    
    // MARK: - Active Services Summary
    
    private var activeServicesSummary: some View {
        let enabledServices = routeManager.config.services.filter { $0.enabled }
        let maxVisible = 3
        let visibleServices = Array(enabledServices.prefix(maxVisible))
        let remainingCount = enabledServices.count - maxVisible
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Active Services")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            if enabledServices.isEmpty {
                Text("No services enabled")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(visibleServices) { service in
                        ServiceChip(service: service)
                    }
                    
                    if remainingCount > 0 {
                        Text("+\(remainingCount) more")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
    
    // MARK: - Routes In Use Summary (Custom mode)

    /// Custom mode's analogue of `activeServicesSummary`: enabled routes that at
    /// least one enabled rule actually points at. Named "Routes In Use" (not
    /// "Active Routes" — that title is already used for the kernel-route list
    /// in `recentRoutesSection` and the Logs tab's Route Health card).
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
                        Text(route.friendlyName(vpnName: routeManager.vpnType?.rawValue))
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

    // MARK: - Recent Routes Section
    
    private var recentRoutesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Active Routes")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(routeManager.uniqueRouteCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.success)
            }
            
            // Show first few routes
            ForEach(routeManager.activeRoutes.prefix(4)) { route in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.success)
                        .frame(width: 4, height: 4)
                    Text(route.destination)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(route.source)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            
            if routeManager.uniqueRouteCount > 4 {
                Text("+ \(routeManager.uniqueRouteCount - 4) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
    
    // MARK: - Route Verification Section
    
    private var routeVerificationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Route Verification")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                
                let passedCount = routeManager.routeVerificationResults.values.filter { $0.isReachable }.count
                let totalCount = routeManager.routeVerificationResults.count
                
                Text("\(passedCount)/\(totalCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(passedCount == totalCount ? Theme.success : Theme.warning)
            }
            
            // Show verification results
            ForEach(Array(routeManager.routeVerificationResults.values.prefix(3))) { result in
                HStack(spacing: 6) {
                    Image(systemName: result.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(result.isReachable ? Theme.success : Theme.error)
                    
                    Text(result.destination)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if let latency = result.latency {
                        Text("\(Int(latency))ms")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else if let error = result.error {
                        Text(error)
                            .font(.system(size: 9))
                            .foregroundColor(Theme.error)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
    
    // MARK: - Routing Mode Toggle

    private var routingModeToggle: some View {
        HStack(spacing: 8) {
            Text("Mode")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)

            Spacer()

            if routeManager.config.routingMode == .custom {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text("Custom Routes")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.success.opacity(0.15))
                    .clipShape(Capsule())

                    Button {
                        pendingMode = .bypass
                    } label: {
                        Text("Switch to Bypass")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 0) {
                    modeButton(title: "Bypass", mode: .bypass)
                    modeButton(title: "VPN Only", mode: .vpnOnly)
                }
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
            }
        }
        .padding(.top, 4)
    }

    private func modeButton(title: LocalizedStringKey, mode: RouteManager.RoutingMode) -> some View {
        let isSelected = routeManager.config.routingMode == mode
        return Button {
            // Tapping the current mode is a no-op; a different mode asks first.
            if mode != routeManager.config.routingMode {
                pendingMode = mode
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isSelected ? Theme.success : Color.clear)
                    .overlay(
                        Circle().stroke(isSelected ? Theme.success : Theme.textSecondary, lineWidth: 1.5)
                    )
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.success.opacity(0.15) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack {
            if let lastUpdate = routeManager.lastUpdate {
                Text("Updated \(lastUpdate, style: .relative) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit VPN Bypass")
        }
    }
    
    
    // MARK: - Helpers
    
    private var statusColor: Color {
        routeManager.isVPNConnected ? Theme.success : Theme.error
    }
    
    private func addDomainAndClose() {
        guard !newDomain.isEmpty else { return }
        if routeManager.config.routingMode == .vpnOnly {
            routeManager.addInverseDomain(newDomain)
        } else if RouteManager.usesCustomEngine(schemaVersion: routeManager.config.schemaVersion, routingMode: routeManager.config.routingMode) {
            addDomainRuleToDirect(newDomain)
        } else {
            routeManager.addDomain(newDomain)
        }
        newDomain = ""
        isAddingDomain = false
    }

    /// Custom mode routes from `config.rules`, not `config.domains` (see
    /// `RouteManager.usesCustomEngine`), so the quick-add above would silently do
    /// nothing there. Add a `.domain` rule to the Direct route instead - the same
    /// mapping `RouteManager.Config.derive()` uses for a bypass-mode domain - so
    /// quick-add behaves like "bypass this domain" in Custom mode too. Mirrors
    /// RulesTab.saveRule's append-at-end-of-order for brand-new rules.
    private func addDomainRuleToDirect(_ domain: String) {
        let cleaned = routeManager.cleanDomain(domain)
        guard !cleaned.isEmpty else { return }
        guard let directRouteId = routeManager.config.routes.first(where: { $0.egress == .direct })?.id else {
            routeManager.log(.error, "Cannot add rule for \(cleaned): no Direct route found")
            return
        }
        guard !routeManager.config.rules.contains(where: { $0.matchType == .domain && $0.pattern == cleaned }) else {
            routeManager.log(.warning, "Rule for \(cleaned) already exists")
            return
        }
        let maxOrder = routeManager.config.rules.map(\.order).max() ?? -1
        routeManager.config.rules.append(Rule(matchType: .domain, pattern: cleaned, routeId: directRouteId, order: maxOrder + 1))
        routeManager.saveConfig()
        routeManager.log(.success, "Added rule: \(cleaned) → Direct")
        Task { await routeManager.reconcileAfterConfigChange(reconcileListeners: false, reapplyRoutes: true) }
    }

    private func openSettings() {
        // Close the MenuBarExtra dropdown window
        // The dropdown is the current key window when clicking inside it
        if let menuWindow = NSApp.keyWindow {
            menuWindow.close()
        }
        
        // Activate the app first, then show settings
        // Longer delay on first open helps with initialization
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            SettingsWindowController.shared.show()
        }
    }
}

// MARK: - Supporting Views

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

struct ServiceChip: View {
    let service: RouteManager.ServiceEntry
    
    private var iconName: String {
        switch service.id {
        case "telegram": return "paperplane.fill"
        case "youtube": return "play.rectangle.fill"
        case "whatsapp": return "message.fill"
        case "spotify": return "music.note"
        case "tailscale": return "network"
        case "slack": return "number.square.fill"
        case "discord": return "bubble.left.and.bubble.right.fill"
        case "twitch": return "tv.fill"
        default: return "globe"
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9))
            Text(service.name)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.success.opacity(0.15))
        .foregroundColor(Theme.success)
        .cornerRadius(12)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
