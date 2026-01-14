// MenuBarViews.swift
// Menu bar label and dropdown content.

import SwiftUI

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    @EnvironmentObject var routeManager: RouteManager
    
    var body: some View {
        HStack(spacing: 4) {
            // Shield icon with status color
            Image(systemName: routeManager.isVPNConnected ? "shield.checkered" : "shield")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
            
            // Active routes count when VPN connected
            if routeManager.isVPNConnected && !routeManager.activeRoutes.isEmpty {
                Text("\(routeManager.activeRoutes.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Menu Content

struct MenuContent: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var newDomain = ""
    @State private var isAddingDomain = false
    
    private let accentGradient = LinearGradient(
        colors: [Color(hex: "10B981"), Color(hex: "059669")],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with VPN status
            headerSection
            
            Divider()
                .padding(.vertical, 8)
            
            // Main content
            if routeManager.isVPNConnected {
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
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 40, height: 40)
                
                Image(systemName: routeManager.isVPNConnected ? "shield.checkered" : "shield.slash")
                    .font(.system(size: 18))
                    .foregroundColor(statusColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(routeManager.isVPNConnected ? "VPN Connected" : "VPN Disconnected")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                
                if let vpnIface = routeManager.vpnInterface {
                    Text("Interface: \(vpnIface)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No tunnel detected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Active routes badge
            if !routeManager.activeRoutes.isEmpty {
                VStack(spacing: 2) {
                    Text("\(routeManager.activeRoutes.count)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "10B981"))
                    Text("bypassed")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
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
            
            // Action buttons
            HStack(spacing: 8) {
                Button {
                    routeManager.detectAndApplyRoutes()
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
        }
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
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Active Services Summary
    
    private var activeServicesSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Active Services")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            let enabledServices = routeManager.config.services.filter { $0.enabled }
            
            if enabledServices.isEmpty {
                Text("No services enabled")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(enabledServices) { service in
                        ServiceChip(service: service)
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
        routeManager.isVPNConnected ? Color(hex: "10B981") : Color(hex: "71717A")
    }
    
    private func addDomainAndClose() {
        guard !newDomain.isEmpty else { return }
        routeManager.addDomain(newDomain)
        newDomain = ""
        isAddingDomain = false
    }
    
    private func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == "Settings…" })?.target?.perform($0.action)
        }
        SettingsWindowController.shared.show()
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
