// MenuBarViews.swift
// Menu bar label and dropdown content.

import SwiftUI

// MARK: - Brand Colors

struct BrandColors {
    // Blue from the shield (left side of logo)
    static let blue = Color(red: 0.15, green: 0.40, blue: 0.85)
    static let blueLight = Color(red: 0.25, green: 0.55, blue: 0.95)
    static let blueDark = Color(red: 0.05, green: 0.20, blue: 0.55)
    
    // Silver from the shield (right side - metallic)
    static let silver = Color(red: 0.75, green: 0.78, blue: 0.82)
    static let silverLight = Color(red: 0.88, green: 0.90, blue: 0.92)
    static let silverDark = Color(red: 0.45, green: 0.48, blue: 0.52)
    
    // Arrow blue (cyan-ish)
    static let arrowBlue = Color(red: 0.20, green: 0.65, blue: 0.95)
    
    // Gradients
    static let blueGradient = LinearGradient(
        colors: [blueLight, blue, blueDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let silverGradient = LinearGradient(
        colors: [silverLight, silver, silverDark],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 3) {
            // Shield icon - simple and clear at menu bar size
            ZStack {
                if routeManager.isLoading || routeManager.isApplyingRoutes {
                    // Pulsing shield when loading
                    Image(systemName: "shield.fill")
                        .font(.system(size: 15))
                        .opacity(isAnimating ? 0.4 : 1.0)
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true),
                            value: isAnimating
                        )
                        .onAppear { isAnimating = true }
                        .onDisappear { isAnimating = false }
                } else {
                    Image(systemName: routeManager.isVPNConnected ? "shield.checkered" : "shield")
                        .font(.system(size: 15))
                }
            }
            
            // Active routes count when VPN connected and not loading
            if routeManager.isVPNConnected && !routeManager.activeRoutes.isEmpty && !routeManager.isLoading && !routeManager.isApplyingRoutes {
                Text("\(routeManager.activeRoutes.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
        }
    }
}

// MARK: - Branded App Name View (for use in dropdowns/settings)

struct BrandedAppName: View {
    var fontSize: CGFloat = 15
    
    var body: some View {
        HStack(spacing: 0) {
            Text("VPN")
                .font(.system(size: fontSize, weight: .black, design: .rounded))
                .foregroundStyle(BrandColors.blueGradient)
            
            Text("Bypass")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(BrandColors.silverGradient)
        }
    }
}

// MARK: - Menu Content

struct MenuContent: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @State private var newDomain = ""
    @State private var isAddingDomain = false
    @State private var isVerifying = false
    
    private let accentGradient = LinearGradient(
        colors: [Color(hex: "10B981"), Color(hex: "059669")],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    var body: some View {
        VStack(spacing: 0) {
            // App title
            titleHeader
            
            // Header with VPN status
            headerSection
            
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
    }
    
    // MARK: - Title Header
    
    private var titleHeader: some View {
        HStack(spacing: 8) {
            // Shield icon with brand color
            Image(systemName: "shield.checkered")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BrandColors.blueGradient)
            
            // App name with branded colors
            BrandedAppName(fontSize: 15)
            
            Spacer()
            
            // Live status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(routeManager.isVPNConnected ? Color(hex: "10B981") : Color(hex: "EF4444"))
                    .frame(width: 6, height: 6)
                    .shadow(color: routeManager.isVPNConnected ? Color(hex: "10B981").opacity(0.6) : Color(hex: "EF4444").opacity(0.6), radius: 3)
                
                Text(routeManager.isVPNConnected ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(routeManager.isVPNConnected ? Color(hex: "10B981") : Color(hex: "EF4444"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(routeManager.isVPNConnected ? Color(hex: "10B981").opacity(0.15) : Color(hex: "EF4444").opacity(0.15))
            )
        }
        .padding(.bottom, 12)
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
                Text(routeManager.isVPNConnected ? "VPN Connected" : "VPN Disconnected")
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
                    Text("\(routeManager.activeRoutes.count)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "10B981"))
                    Text("routes")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(hex: "10B981").opacity(0.1))
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
                        .background(Color.primary.opacity(0.05))
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
                        Text("Add Domain to Bypass")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            
            // Active services summary
            activeServicesSummary
            
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
                        Text(isVerifying ? "Verifying..." : "Verify Routes")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
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
            
            // Show enabled services count
            let enabledServices = routeManager.config.services.filter { $0.enabled }
            let enabledDomains = routeManager.config.domains.filter { $0.enabled }
            
            HStack(spacing: 16) {
                StatBadge(value: "\(enabledServices.count)", label: "Services")
                StatBadge(value: "\(enabledDomains.count)", label: "Domains")
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
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
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
                Text("\(routeManager.activeRoutes.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "10B981"))
            }
            
            // Show first few routes
            ForEach(routeManager.activeRoutes.prefix(4)) { route in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: "10B981"))
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
            
            if routeManager.activeRoutes.count > 4 {
                Text("+ \(routeManager.activeRoutes.count - 4) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
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
                    .foregroundColor(passedCount == totalCount ? Color(hex: "10B981") : Color(hex: "F59E0B"))
            }
            
            // Show verification results
            ForEach(Array(routeManager.routeVerificationResults.values.prefix(3))) { result in
                HStack(spacing: 6) {
                    Image(systemName: result.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(result.isReachable ? Color(hex: "10B981") : Color(hex: "EF4444"))
                    
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
                            .foregroundColor(Color(hex: "EF4444"))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
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
        routeManager.isVPNConnected ? Color(hex: "10B981") : Color(hex: "EF4444")
    }
    
    private func addDomainAndClose() {
        guard !newDomain.isEmpty else { return }
        routeManager.addDomain(newDomain)
        newDomain = ""
        isAddingDomain = false
    }
    
    private func openSettings() {
        // Close the MenuBarExtra dropdown window
        // The dropdown is the current key window when clicking inside it
        if let menuWindow = NSApp.keyWindow {
            menuWindow.close()
        }
        
        // Show settings after dropdown closes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            SettingsWindowController.shared.show()
        }
    }
}

// MARK: - Supporting Views

struct StatBadge: View {
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "10B981"))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
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
        .background(Color(hex: "10B981").opacity(0.15))
        .foregroundColor(Color(hex: "10B981"))
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
