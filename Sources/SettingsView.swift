// SettingsView.swift
// Settings window with tabs for Domains, Services, and Logs.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Beautiful gradient header
            headerView
            
            // Tab content with animation
            tabContent
                .animation(.easeInOut(duration: 0.2), value: selectedTab)
        }
        .frame(width: 580, height: 560)
        .background(
            LinearGradient(
                colors: [Color(hex: "0F0F14"), Color(hex: "1A1B26")],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    private var headerView: some View {
        VStack(spacing: 0) {
            // Title bar area
            HStack {
                Text("VPN Bypass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "71717A"))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            // Tab bar with pill selector
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    TabItem(
                        index: index,
                        title: tabTitle(for: index),
                        icon: tabIcon(for: index),
                        isSelected: selectedTab == index
                    ) {
                        selectedTab = index
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            
            // Subtle separator
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.clear, Color(hex: "10B981").opacity(0.3), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .background(Color(hex: "0F0F14").opacity(0.8))
    }
    
    private var tabContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch selectedTab {
                case 0: DomainsTab()
                case 1: ServicesTab()
                case 2: GeneralTab()
                case 3: LogsTab()
                default: EmptyView()
                }
            }
            .padding(24)
        }
    }
    
    private func tabTitle(for index: Int) -> String {
        ["Domains", "Services", "General", "Logs"][index]
    }
    
    private func tabIcon(for index: Int) -> String {
        ["globe", "square.grid.2x2.fill", "gearshape.fill", "list.bullet.rectangle"][index]
    }
}

// MARK: - Tab Item

struct TabItem: View {
    let index: Int
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : Color(hex: "71717A"))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isSelected {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "10B981"), Color(hex: "059669")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: Color(hex: "10B981").opacity(0.4), radius: 8, y: 2)
                    } else if isHovered {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    }
                }
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Domains Tab

struct DomainsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var newDomain = ""
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(hex: "10B981"), Color(hex: "34D399")], startPoint: .top, endPoint: .bottom)
                        )
                    Text("Custom Domains")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Text("Add domains that should bypass VPN and use your regular connection.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "9CA3AF"))
            }
            
            // Add domain input
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "6B7280"))
                    
                    TextField("Enter domain (e.g., example.com)", text: $newDomain)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isInputFocused)
                        .onSubmit { addDomain() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isInputFocused ? Color(hex: "10B981").opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                )
                
                Button(action: addDomain) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(
                            LinearGradient(
                                colors: newDomain.isEmpty ? [Color(hex: "374151"), Color(hex: "374151")] : [Color(hex: "10B981"), Color(hex: "059669")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: newDomain.isEmpty ? .clear : Color(hex: "10B981").opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(newDomain.isEmpty)
            }
            
            // Domain list
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CONFIGURED DOMAINS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "6B7280"))
                        .tracking(1)
                    
                    Spacer()
                    
                    Text("\(routeManager.config.domains.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "10B981"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "10B981").opacity(0.15))
                        .clipShape(Capsule())
                }
                
                if routeManager.config.domains.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 6) {
                        ForEach(routeManager.config.domains) { domain in
                            DomainRow(domain: domain)
                        }
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
            
            Spacer()
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 28))
                .foregroundColor(Color(hex: "374151"))
            Text("No domains configured")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "6B7280"))
            Text("Add a domain above to bypass VPN")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "4B5563"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
    
    private func addDomain() {
        guard !newDomain.isEmpty else { return }
        routeManager.addDomain(newDomain)
        newDomain = ""
    }
}

struct DomainRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let domain: RouteManager.DomainEntry
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(domain.enabled ? Color(hex: "10B981") : Color(hex: "4B5563"))
                .frame(width: 8, height: 8)
                .shadow(color: domain.enabled ? Color(hex: "10B981").opacity(0.5) : .clear, radius: 4)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.domain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(domain.enabled ? .white : Color(hex: "9CA3AF"))
            }
            
            Spacer()
            
            // Toggle
            Toggle("", isOn: Binding(
                get: { domain.enabled },
                set: { newValue in
                    if let index = routeManager.config.domains.firstIndex(where: { $0.id == domain.id }) {
                        routeManager.config.domains[index].enabled = newValue
                        routeManager.saveConfig()
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(Color(hex: "10B981"))
            .scaleEffect(0.7)
            
            // Delete button
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    routeManager.removeDomain(domain)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "EF4444").opacity(isHovered ? 1 : 0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Services Tab

struct ServicesTab: View {
    @EnvironmentObject var routeManager: RouteManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(hex: "8B5CF6"), Color(hex: "A78BFA")], startPoint: .top, endPoint: .bottom)
                        )
                    Text("Services")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                Text("Toggle pre-configured services to bypass VPN automatically.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "9CA3AF"))
            }
            
            // Services grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(routeManager.config.services) { service in
                    ServiceCard(service: service)
                }
            }
            
            Spacer()
        }
    }
}

struct ServiceCard: View {
    @EnvironmentObject var routeManager: RouteManager
    let service: RouteManager.ServiceEntry
    @State private var isHovered = false
    @State private var isPressed = false
    
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
    
    private var brandColor: Color {
        switch service.id {
        case "telegram": return Color(hex: "26A5E4")
        case "youtube": return Color(hex: "FF0000")
        case "whatsapp": return Color(hex: "25D366")
        case "spotify": return Color(hex: "1DB954")
        case "tailscale": return Color(hex: "4F46E5")
        case "slack": return Color(hex: "E01E5A")
        case "discord": return Color(hex: "5865F2")
        case "twitch": return Color(hex: "9146FF")
        default: return Color(hex: "10B981")
        }
    }
    
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                routeManager.toggleService(service.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    // Icon with glow effect
                    ZStack {
                        if service.enabled {
                            Circle()
                                .fill(brandColor.opacity(0.3))
                                .frame(width: 48, height: 48)
                                .blur(radius: 8)
                        }
                        
                        Circle()
                            .fill(service.enabled ? brandColor.opacity(0.2) : Color.white.opacity(0.06))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: iconName)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(service.enabled ? brandColor : Color(hex: "6B7280"))
                    }
                    
                    Spacer()
                    
                    // Status indicator
                    ZStack {
                        Circle()
                            .fill(service.enabled ? Color(hex: "10B981") : Color(hex: "374151"))
                            .frame(width: 12, height: 12)
                        
                        if service.enabled {
                            Circle()
                                .fill(Color(hex: "10B981"))
                                .frame(width: 12, height: 12)
                                .blur(radius: 4)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(service.enabled ? .white : Color(hex: "9CA3AF"))
                    
                    Text("\(service.domains.count) domains • \(service.ipRanges.count) IP ranges")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "6B7280"))
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(isHovered ? 0.07 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                service.enabled ? brandColor.opacity(0.4) : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var routeManager: RouteManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(hex: "F59E0B"), Color(hex: "FBBF24")], startPoint: .top, endPoint: .bottom)
                        )
                    Text("Settings")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            
            // Behavior section
            SettingsCard(title: "Behavior", icon: "bolt.fill", iconColor: Color(hex: "F59E0B")) {
                SettingsToggleRow(
                    icon: "play.circle.fill",
                    title: "Auto-apply on VPN Connect",
                    subtitle: "Automatically apply routes when VPN connects",
                    isOn: Binding(
                        get: { routeManager.config.autoApplyOnVPN },
                        set: { routeManager.config.autoApplyOnVPN = $0; routeManager.saveConfig() }
                    )
                )
                
                Divider().background(Color.white.opacity(0.1))
                
                SettingsToggleRow(
                    icon: "doc.text.fill",
                    title: "Manage /etc/hosts",
                    subtitle: "Add DNS bypass entries (requires admin)",
                    isOn: Binding(
                        get: { routeManager.config.manageHostsFile },
                        set: { routeManager.config.manageHostsFile = $0; routeManager.saveConfig() }
                    )
                )
            }
            
            // Network status section
            SettingsCard(title: "Network Status", icon: "network", iconColor: Color(hex: "10B981")) {
                StatusRow(
                    label: "VPN Status",
                    value: routeManager.isVPNConnected ? "Connected" : "Disconnected",
                    valueColor: routeManager.isVPNConnected ? Color(hex: "10B981") : Color(hex: "EF4444"),
                    showDot: true
                )
                
                if let vpnIface = routeManager.vpnInterface {
                    StatusRow(label: "Interface", value: vpnIface)
                }
                
                if let gateway = routeManager.localGateway {
                    StatusRow(label: "Gateway", value: gateway)
                }
                
                StatusRow(label: "Active Routes", value: "\(routeManager.activeRoutes.count)")
            }
            
            // About section
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN Bypass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Version 1.0.0")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "6B7280"))
                }
                
                Spacer()
                
                Link(destination: URL(string: "https://github.com/GeiserX/vpn-macos-bypass")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                        Text("GitHub")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(Color(hex: "10B981"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "10B981").opacity(0.15))
                    .clipShape(Capsule())
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.03))
            )
            
            Spacer()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconColor)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "6B7280"))
                    .tracking(1)
            }
            
            VStack(spacing: 12) {
                content
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "10B981"))
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "6B7280"))
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Color(hex: "10B981"))
                .scaleEffect(0.8)
        }
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    var valueColor: Color = .white
    var showDot: Bool = false
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "9CA3AF"))
            
            Spacer()
            
            HStack(spacing: 6) {
                if showDot {
                    Circle()
                        .fill(valueColor)
                        .frame(width: 6, height: 6)
                }
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(valueColor)
            }
        }
    }
}

// MARK: - Logs Tab

struct LogsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(hex: "3B82F6"), Color(hex: "60A5FA")], startPoint: .top, endPoint: .bottom)
                        )
                    Text("Activity Log")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                if !routeManager.recentLogs.isEmpty {
                    Button {
                        withAnimation { routeManager.recentLogs.removeAll() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("Clear")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "EF4444"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "EF4444").opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Log content
            if routeManager.recentLogs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 36))
                        .foregroundColor(Color(hex: "374151"))
                    Text("No activity yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "6B7280"))
                    Text("Logs will appear here when routes are applied")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "4B5563"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(routeManager.recentLogs) { log in
                            LogRow(entry: log)
                        }
                    }
                    .padding(4)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.3))
                )
            }
        }
    }
}

struct LogRow: View {
    let entry: RouteManager.LogEntry
    
    private var levelColor: Color {
        switch entry.level {
        case .info: return Color(hex: "6B7280")
        case .success: return Color(hex: "10B981")
        case .warning: return Color(hex: "F59E0B")
        case .error: return Color(hex: "EF4444")
        }
    }
    
    private var levelIcon: String {
        switch entry.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: levelIcon)
                .font(.system(size: 10))
                .foregroundColor(levelColor)
            
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "6B7280"))
                .frame(width: 70, alignment: .leading)
            
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    
    private var window: NSWindow?
    
    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let settingsView = SettingsView()
            .environmentObject(RouteManager.shared)
        let hostingView = NSHostingView(rootView: settingsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.title = "VPN Bypass"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Color(hex: "0F0F14"))
        window.isReleasedWhenClosed = false
        window.center()
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = window
    }
}
