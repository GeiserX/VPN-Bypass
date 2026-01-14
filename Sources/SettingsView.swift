// SettingsView.swift
// Settings window with tabs for Domains, Services, and Logs.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                TabButton(title: "Domains", icon: "globe", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                TabButton(title: "Services", icon: "app.connected.to.app.below.fill", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                TabButton(title: "General", icon: "gearshape.fill", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
                TabButton(title: "Logs", icon: "doc.text", isSelected: selectedTab == 3) {
                    selectedTab = 3
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            Divider()
                .padding(.top, 12)
            
            // Content
            ScrollView {
                VStack(spacing: 0) {
                    switch selectedTab {
                    case 0:
                        DomainsTab()
                    case 1:
                        ServicesTab()
                    case 2:
                        GeneralTab()
                    case 3:
                        LogsTab()
                    default:
                        EmptyView()
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 520)
        .background(Color(hex: "1A1B26"))
    }
}

// MARK: - Tab Button

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundColor(isSelected ? Color(hex: "10B981") : Color(hex: "71717A"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color(hex: "10B981").opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Domains Tab

struct DomainsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var newDomain = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Domains")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Add domains that should bypass the VPN. Traffic to these domains will use your regular internet connection.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "71717A"))
            }
            
            // Add new domain
            HStack(spacing: 12) {
                TextField("Enter domain (e.g., example.com)", text: $newDomain)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .onSubmit {
                        addDomain()
                    }
                
                Button {
                    addDomain()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "10B981"))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(newDomain.isEmpty)
            }
            
            // Domain list
            VStack(alignment: .leading, spacing: 8) {
                Text("Configured Domains")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "A1A1AA"))
                
                if routeManager.config.domains.isEmpty {
                    Text("No custom domains configured")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "52525B"))
                        .italic()
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(routeManager.config.domains) { domain in
                        DomainRow(domain: domain)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
            .cornerRadius(12)
            
            // Tips
            VStack(alignment: .leading, spacing: 8) {
                Label("Tips", systemImage: "lightbulb.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "F59E0B"))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("• Use base domains (example.com) to match all subdomains")
                    Text("• Paste full URLs - the domain will be extracted automatically")
                    Text("• Routes are applied immediately when VPN is connected")
                }
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "71717A"))
            }
            .padding(16)
            .background(Color(hex: "F59E0B").opacity(0.1))
            .cornerRadius(12)
            
            Spacer()
        }
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
            .scaleEffect(0.8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.domain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(domain.enabled ? .white : Color(hex: "71717A"))
                
                if let ip = domain.resolvedIP {
                    Text(ip)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "52525B"))
                }
            }
            
            Spacer()
            
            Button {
                routeManager.removeDomain(domain)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "EF4444"))
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.03) : Color.clear)
        .cornerRadius(8)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Services Tab

struct ServicesTab: View {
    @EnvironmentObject var routeManager: RouteManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pre-configured Services")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Enable services to automatically bypass VPN for their traffic. Each service includes known domains and IP ranges.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "71717A"))
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
        case "telegram": return Color(hex: "0088CC")
        case "youtube": return Color(hex: "FF0000")
        case "whatsapp": return Color(hex: "25D366")
        case "spotify": return Color(hex: "1DB954")
        case "tailscale": return Color(hex: "0F172A")
        case "slack": return Color(hex: "4A154B")
        case "discord": return Color(hex: "5865F2")
        case "twitch": return Color(hex: "9146FF")
        default: return Color(hex: "10B981")
        }
    }
    
    var body: some View {
        Button {
            routeManager.toggleService(service.id)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(service.enabled ? brandColor.opacity(0.2) : Color.white.opacity(0.05))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: iconName)
                            .font(.system(size: 18))
                            .foregroundColor(service.enabled ? brandColor : Color(hex: "71717A"))
                    }
                    
                    Spacer()
                    
                    Circle()
                        .fill(service.enabled ? Color(hex: "10B981") : Color(hex: "3F3F46"))
                        .frame(width: 10, height: 10)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(service.enabled ? .white : Color(hex: "71717A"))
                    
                    Text("\(service.domains.count) domains")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "52525B"))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isHovered ? 0.06 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(service.enabled ? brandColor.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var routeManager: RouteManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(title: "Behavior") {
                SettingsToggle(
                    icon: "play.circle.fill",
                    title: "Auto-apply on VPN Connect",
                    description: "Automatically apply bypass routes when VPN connects",
                    isOn: $routeManager.config.autoApplyOnVPN
                )
                .onChange(of: routeManager.config.autoApplyOnVPN) { _, _ in
                    routeManager.saveConfig()
                }
                
                SettingsToggle(
                    icon: "doc.text.fill",
                    title: "Manage /etc/hosts",
                    description: "Add entries to hosts file for DNS bypass (requires admin)",
                    isOn: $routeManager.config.manageHostsFile
                )
                .onChange(of: routeManager.config.manageHostsFile) { _, _ in
                    routeManager.saveConfig()
                }
            }
            
            SettingsSection(title: "Network Info") {
                InfoRow(label: "VPN Status", value: routeManager.isVPNConnected ? "Connected" : "Disconnected", color: routeManager.isVPNConnected ? Color(hex: "10B981") : Color(hex: "EF4444"))
                
                if let vpnIface = routeManager.vpnInterface {
                    InfoRow(label: "VPN Interface", value: vpnIface)
                }
                
                if let gateway = routeManager.localGateway {
                    InfoRow(label: "Local Gateway", value: gateway)
                }
                
                InfoRow(label: "Active Routes", value: "\(routeManager.activeRoutes.count)")
            }
            
            SettingsSection(title: "About") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VPN Bypass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Version 1.0.0")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "71717A"))
                    }
                    
                    Spacer()
                    
                    Link(destination: URL(string: "https://github.com/GeiserX/vpn-macos-bypass")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 11))
                            Text("GitHub")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(Color(hex: "10B981"))
                    }
                }
            }
            
            Spacer()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = .white
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "71717A"))
            
            Spacer()
            
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Logs Tab

struct LogsTab: View {
    @EnvironmentObject var routeManager: RouteManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent Activity")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button {
                    routeManager.recentLogs.removeAll()
                } label: {
                    Text("Clear")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "EF4444"))
                }
                .buttonStyle(.plain)
            }
            
            if routeManager.recentLogs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No logs yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(routeManager.recentLogs) { log in
                            LogRow(entry: log)
                        }
                    }
                }
                .background(Color.black.opacity(0.2))
                .cornerRadius(8)
            }
        }
    }
}

struct LogRow: View {
    let entry: RouteManager.LogEntry
    
    private var levelColor: Color {
        switch entry.level {
        case .info: return Color(hex: "71717A")
        case .success: return Color(hex: "10B981")
        case .warning: return Color(hex: "F59E0B")
        case .error: return Color(hex: "EF4444")
        }
    }
    
    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(dateFormatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "52525B"))
                .frame(width: 60, alignment: .leading)
            
            Text(entry.level.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(levelColor)
                .frame(width: 55, alignment: .leading)
            
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Helper Views

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(Color(hex: "A1A1AA"))
            
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(16)
            .background(Color.white.opacity(0.03))
            .cornerRadius(12)
        }
    }
}

struct SettingsToggle: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "10B981"))
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "71717A"))
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Color(hex: "10B981"))
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.title = "VPN Bypass Settings"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Color(hex: "1A1B26"))
        window.isReleasedWhenClosed = false
        window.center()
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = window
    }
}
