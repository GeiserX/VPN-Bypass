// SettingsView.swift
// Settings window with tabs for Domains, Services, General, and Logs.

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Beautiful gradient header
            headerView
            
            // Tab content with animation
            tabContent
                .animation(.easeInOut(duration: 0.2), value: selectedTab)
        }
        .frame(width: 580, height: 620)
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
            // Tab bar with pill selector
            HStack(spacing: 4) {
                ForEach(0..<5) { index in
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
            .padding(.top, 8)
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
                case 4: InfoTab()
                default: EmptyView()
                }
            }
            .padding(24)
        }
    }
    
    private func tabTitle(for index: Int) -> String {
        ["Domains", "Services", "General", "Logs", "Info"][index]
    }
    
    private func tabIcon(for index: Int) -> String {
        ["globe", "square.grid.2x2.fill", "gearshape.fill", "list.bullet.rectangle", "info.circle.fill"][index]
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
                        .disabled(routeManager.isApplyingRoutes)
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
                
                // Loading indicator or add button
                if routeManager.isApplyingRoutes {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "10B981")))
                        .frame(width: 42, height: 42)
                        .background(Color(hex: "374151"))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
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
            }
            
            // Domain list
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CONFIGURED DOMAINS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "6B7280"))
                        .tracking(1)
                    
                    Spacer()
                    
                    // Loading indicator or All/None buttons
                    if routeManager.isApplyingRoutes {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "10B981")))
                            Text("Applying...")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "6B7280"))
                        }
                    } else if !routeManager.config.domains.isEmpty {
                        HStack(spacing: 6) {
                            Button {
                                routeManager.setAllDomainsEnabled(true)
                            } label: {
                                Text("All")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(hex: "10B981"))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(hex: "10B981").opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            
                            Button {
                                routeManager.setAllDomainsEnabled(false)
                            } label: {
                                Text("None")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(hex: "EF4444"))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(hex: "EF4444").opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    Text("\(routeManager.config.domains.filter { $0.enabled }.count)/\(routeManager.config.domains.count)")
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
            
            // Toggle - disabled during route operations
            Toggle("", isOn: Binding(
                get: { domain.enabled },
                set: { _ in
                    if !routeManager.isApplyingRoutes {
                        routeManager.toggleDomain(domain.id)
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(Color(hex: "10B981"))
            .scaleEffect(0.7)
            .disabled(routeManager.isApplyingRoutes)
            .opacity(routeManager.isApplyingRoutes ? 0.5 : 1)
            
            // Delete button - disabled during route operations
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
            .disabled(routeManager.isApplyingRoutes)
            .opacity(routeManager.isApplyingRoutes ? 0.5 : 1)
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
    @State private var searchText = ""
    
    private var filteredServices: [RouteManager.ServiceEntry] {
        if searchText.isEmpty {
            return routeManager.config.services
        }
        return routeManager.config.services.filter { 
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.domains.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    private var enabledCount: Int {
        routeManager.config.services.filter { $0.enabled }.count
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(hex: "8B5CF6"), Color(hex: "A78BFA")], startPoint: .top, endPoint: .bottom)
                        )
                    Text("Services")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Text("\(enabledCount)/\(routeManager.config.services.count) enabled")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "6B7280"))
            }
            
            // Search and bulk actions
            HStack(spacing: 10) {
                // Search box
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "6B7280"))
                    
                    TextField("Search services...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .disabled(routeManager.isApplyingRoutes)
                    
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "6B7280"))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                
                // Loading indicator
                if routeManager.isApplyingRoutes {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "10B981")))
                        Text("Applying...")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "6B7280"))
                    }
                    .frame(width: 80)
                } else {
                    // Select All button
                    Button {
                        routeManager.setAllServicesEnabled(true)
                    } label: {
                        Text("All")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "10B981"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: "10B981").opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    // Select None button
                    Button {
                        routeManager.setAllServicesEnabled(false)
                    } label: {
                        Text("None")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "EF4444"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: "EF4444").opacity(0.15))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Services list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredServices) { service in
                        ServiceRow(service: service)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.2))
            )
        }
    }
}

struct ServiceRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let service: RouteManager.ServiceEntry
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Status dot
            Circle()
                .fill(service.enabled ? Color(hex: "10B981") : Color(hex: "4B5563"))
                .frame(width: 8, height: 8)
                .shadow(color: service.enabled ? Color(hex: "10B981").opacity(0.5) : .clear, radius: 4)
            
            // Service info
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(service.enabled ? .white : Color(hex: "9CA3AF"))
                
                Text("\(service.domains.count) domains" + (service.ipRanges.isEmpty ? "" : " • \(service.ipRanges.count) IPs"))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "6B7280"))
            }
            
            Spacer()
            
            // Toggle - disabled while routes are being applied
            Toggle("", isOn: Binding(
                get: { service.enabled },
                set: { _ in 
                    if !routeManager.isApplyingRoutes {
                        routeManager.toggleService(service.id)
                    }
                }
            ))
            .toggleStyle(.switch)
            .tint(Color(hex: "10B981"))
            .scaleEffect(0.7)
            .disabled(routeManager.isApplyingRoutes)
            .opacity(routeManager.isApplyingRoutes ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @StateObject private var helperManager = HelperManager.shared
    @State private var showingExportSuccess = false
    @State private var showingImportPicker = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""
    
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
            
            // Startup section
            SettingsCard(title: "Startup", icon: "power", iconColor: Color(hex: "10B981")) {
                SettingsToggleRow(
                    icon: "arrow.clockwise",
                    title: "Launch at Login",
                    subtitle: "Automatically start VPN Bypass when you log in",
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { _ in launchAtLoginManager.toggle() }
                    )
                )
            }
            
            // Privileged Helper section
            SettingsCard(title: "Privileged Helper", icon: "lock.shield.fill", iconColor: Color(hex: "EF4444")) {
                HStack(spacing: 12) {
                    Image(systemName: helperManager.isHelperInstalled ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .font(.system(size: 14))
                        .foregroundColor(helperManager.isHelperInstalled ? Color(hex: "10B981") : Color(hex: "EF4444"))
                        .frame(width: 20)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(helperManager.isHelperInstalled ? "Helper Installed" : "Helper Not Installed")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        if helperManager.isHelperInstalled {
                            Text("No more password prompts for route changes")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "6B7280"))
                        } else {
                            Text("Install to avoid repeated admin prompts")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "6B7280"))
                        }
                    }
                    
                    Spacer()
                    
                    if !helperManager.isHelperInstalled {
                        Button {
                            installHelper()
                        } label: {
                            HStack(spacing: 4) {
                                if helperManager.isInstalling {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 12, height: 12)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 10))
                                }
                                Text(helperManager.isInstalling ? "Installing..." : "Install")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: "10B981"), Color(hex: "059669")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(helperManager.isInstalling)
                    } else if let version = helperManager.helperVersion {
                        Text("v\(version)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "6B7280"))
                    }
                }
                
                if let error = helperManager.installationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "F59E0B"))
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "F59E0B"))
                            .lineLimit(2)
                    }
                }
                
                Text("The helper runs as root and handles route/hosts changes without prompting.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "6B7280"))
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
                
                Divider().background(Color.white.opacity(0.1))
                
                SettingsToggleRow(
                    icon: "checkmark.circle.fill",
                    title: "Verify Routes After Apply",
                    subtitle: "Ping test routes to ensure they're working",
                    isOn: Binding(
                        get: { routeManager.config.verifyRoutesAfterApply },
                        set: { routeManager.config.verifyRoutesAfterApply = $0; routeManager.saveConfig() }
                    )
                )
            }
            
            // DNS Refresh section
            SettingsCard(title: "DNS Refresh", icon: "arrow.triangle.2.circlepath", iconColor: Color(hex: "06B6D4")) {
                SettingsToggleRow(
                    icon: "clock.arrow.circlepath",
                    title: "Auto DNS Refresh",
                    subtitle: "Periodically re-resolve domains and update routes",
                    isOn: Binding(
                        get: { routeManager.config.autoDNSRefresh },
                        set: { 
                            routeManager.config.autoDNSRefresh = $0
                            routeManager.saveConfig()
                            routeManager.startDNSRefreshTimer()
                        }
                    )
                )
                
                if routeManager.config.autoDNSRefresh {
                    Divider().background(Color.white.opacity(0.1))
                    
                    // Interval picker
                    HStack(spacing: 12) {
                        Image(systemName: "timer")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "06B6D4"))
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refresh Interval")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("How often to re-check DNS for changes")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "6B7280"))
                        }
                        
                        Spacer()
                        
                        Picker("", selection: Binding(
                            get: { routeManager.config.dnsRefreshInterval },
                            set: { 
                                routeManager.config.dnsRefreshInterval = $0
                                routeManager.saveConfig()
                                routeManager.startDNSRefreshTimer()
                            }
                        )) {
                            Text("15 min").tag(TimeInterval(900))
                            Text("30 min").tag(TimeInterval(1800))
                            Text("1 hour").tag(TimeInterval(3600))
                            Text("2 hours").tag(TimeInterval(7200))
                            Text("6 hours").tag(TimeInterval(21600))
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    // Status and manual refresh
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let lastRefresh = routeManager.lastDNSRefresh {
                                HStack(spacing: 4) {
                                    Text("Last refresh:")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "6B7280"))
                                    Text(lastRefresh, style: .relative)
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "9CA3AF"))
                                }
                            }
                            if let nextRefresh = routeManager.nextDNSRefresh {
                                HStack(spacing: 4) {
                                    Text("Next refresh:")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "6B7280"))
                                    Text(nextRefresh, style: .relative)
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "10B981"))
                                }
                            }
                        }
                        
                        Spacer()
                        
                        Button {
                            routeManager.forceDNSRefresh()
                        } label: {
                            HStack(spacing: 4) {
                                if routeManager.isApplyingRoutes {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 10, height: 10)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10))
                                }
                                Text("Refresh Now")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(Color(hex: "06B6D4"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(hex: "06B6D4").opacity(0.15))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(routeManager.isApplyingRoutes)
                    }
                }
                
                Text("Re-resolves all domains to catch IP changes and ensure routes stay up to date.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "6B7280"))
            }
            
            // Fallback DNS section
            SettingsCard(title: "Fallback DNS", icon: "server.rack", iconColor: Color(hex: "8B5CF6")) {
                VStack(alignment: .leading, spacing: 12) {
                    // Detected DNS - prominent display
                    if let detected = routeManager.detectedDNSServerDisplay {
                        HStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(Color(hex: "06B6D4"))
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detected Non-VPN DNS")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color(hex: "9CA3AF"))
                                Text(detected)
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(hex: "06B6D4"))
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: "06B6D4").opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(hex: "06B6D4").opacity(0.3), lineWidth: 1)
                                )
                        )
                    }
                    
                    Text("Fallback DNS servers when detected DNS is unavailable.\nSupported formats: IP (1.1.1.1), DoH (https://...), DoT (tls://... or IP:853)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "6B7280"))
                    
                    ForEach(Array(routeManager.config.fallbackDNS.enumerated()), id: \.offset) { index, dns in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "6B7280"))
                                .frame(width: 20)
                            
                            TextField("DNS server", text: Binding(
                                get: { routeManager.config.fallbackDNS[index] },
                                set: { 
                                    routeManager.config.fallbackDNS[index] = $0
                                    routeManager.saveConfig()
                                }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: "1F2937"))
                            .cornerRadius(6)
                            
                            Button {
                                routeManager.config.fallbackDNS.remove(at: index)
                                routeManager.saveConfig()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(Color(hex: "EF4444"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    Button {
                        routeManager.config.fallbackDNS.append("")
                        routeManager.saveConfig()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add DNS Server")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "10B981"))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Notifications section
            SettingsCard(title: "Notifications", icon: "bell.fill", iconColor: Color(hex: "8B5CF6")) {
                SettingsToggleRow(
                    icon: "bell.badge.fill",
                    title: "Enable Notifications",
                    subtitle: "Show alerts for VPN events",
                    isOn: Binding(
                        get: { notificationManager.notificationsEnabled },
                        set: { 
                            notificationManager.notificationsEnabled = $0
                            notificationManager.savePreferences()
                        }
                    )
                )
                
                if notificationManager.notificationsEnabled {
                    Divider().background(Color.white.opacity(0.1))
                    
                    SettingsToggleRow(
                        icon: "speaker.slash.fill",
                        title: "Silent",
                        subtitle: "No sound",
                        isOn: Binding(
                            get: { notificationManager.silentNotifications },
                            set: { 
                                notificationManager.silentNotifications = $0
                                notificationManager.savePreferences()
                            }
                        )
                    )
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    HStack(spacing: 12) {
                        NotificationChip(
                            label: "Connect",
                            isOn: Binding(
                                get: { notificationManager.notifyOnVPNConnect },
                                set: { notificationManager.notifyOnVPNConnect = $0; notificationManager.savePreferences() }
                            )
                        )
                        NotificationChip(
                            label: "Disconnect",
                            isOn: Binding(
                                get: { notificationManager.notifyOnVPNDisconnect },
                                set: { notificationManager.notifyOnVPNDisconnect = $0; notificationManager.savePreferences() }
                            )
                        )
                        NotificationChip(
                            label: "Routes",
                            isOn: Binding(
                                get: { notificationManager.notifyOnRoutesApplied },
                                set: { notificationManager.notifyOnRoutesApplied = $0; notificationManager.savePreferences() }
                            )
                        )
                        NotificationChip(
                            label: "Failures",
                            isOn: Binding(
                                get: { notificationManager.notifyOnRouteFailure },
                                set: { notificationManager.notifyOnRouteFailure = $0; notificationManager.savePreferences() }
                            )
                        )
                    }
                    
                    Text("Routes: services, domains, DNS refresh")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "6B7280"))
                }
            }
            
            // SOCKS5 Proxy section (Aggressive Bypass Mode)
            SettingsCard(title: "SOCKS5 Proxy", icon: "network.badge.shield.half.filled", iconColor: Color(hex: "F59E0B")) {
                VStack(alignment: .leading, spacing: 12) {
                    // Warning/info box
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color(hex: "F59E0B"))
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aggressive Bypass Mode")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(hex: "F59E0B"))
                            Text("For corporate VPNs (Cisco, Zscaler) that block UDP. Requires external SOCKS5 proxy server with UDP support.")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "9CA3AF"))
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "F59E0B").opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(hex: "F59E0B").opacity(0.3), lineWidth: 1)
                            )
                    )
                    
                    SettingsToggleRow(
                        icon: "shield.lefthalf.filled",
                        title: "Enable SOCKS5 Proxy",
                        subtitle: "Route traffic through proxy to bypass UDP blocking",
                        isOn: Binding(
                            get: { routeManager.config.proxyConfig.enabled },
                            set: { 
                                routeManager.config.proxyConfig.enabled = $0
                                routeManager.saveConfig()
                            }
                        )
                    )
                    
                    if routeManager.config.proxyConfig.enabled {
                        Divider().background(Color.white.opacity(0.1))
                        
                        // Server and port
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Proxy Server")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "9CA3AF"))
                            
                            HStack(spacing: 8) {
                                TextField("Server address", text: Binding(
                                    get: { routeManager.config.proxyConfig.server },
                                    set: { 
                                        routeManager.config.proxyConfig.server = $0
                                        routeManager.saveConfig()
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(hex: "1F2937"))
                                .cornerRadius(6)
                                
                                TextField("Port", value: Binding(
                                    get: { routeManager.config.proxyConfig.port },
                                    set: { 
                                        routeManager.config.proxyConfig.port = $0
                                        routeManager.saveConfig()
                                    }
                                ), format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(hex: "1F2937"))
                                .cornerRadius(6)
                                .frame(width: 80)
                            }
                        }
                        
                        // Authentication (optional)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Authentication (optional)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "9CA3AF"))
                            
                            HStack(spacing: 8) {
                                TextField("Username", text: Binding(
                                    get: { routeManager.config.proxyConfig.username },
                                    set: { 
                                        routeManager.config.proxyConfig.username = $0
                                        routeManager.saveConfig()
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(hex: "1F2937"))
                                .cornerRadius(6)
                                
                                SecureField("Password", text: Binding(
                                    get: { routeManager.config.proxyConfig.password },
                                    set: { 
                                        routeManager.config.proxyConfig.password = $0
                                        routeManager.saveConfig()
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(hex: "1F2937"))
                                .cornerRadius(6)
                            }
                        }
                        
                        // Test connection button
                        HStack {
                            Button {
                                Task {
                                    await routeManager.testProxyConnection()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if routeManager.isTestingProxy {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.system(size: 11))
                                    }
                                    Text(routeManager.isTestingProxy ? "Testing..." : "Test Connection")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    routeManager.config.proxyConfig.isConfigured 
                                        ? Color(hex: "F59E0B") 
                                        : Color(hex: "4B5563")
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(!routeManager.config.proxyConfig.isConfigured || routeManager.isTestingProxy)
                            
                            if let result = routeManager.proxyTestResult {
                                HStack(spacing: 4) {
                                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(result.success ? Color(hex: "10B981") : Color(hex: "EF4444"))
                                    Text(result.message)
                                        .font(.system(size: 10))
                                        .foregroundColor(result.success ? Color(hex: "10B981") : Color(hex: "EF4444"))
                                }
                            }
                        }
                        
                        Text("Proxy will be used for services that need UDP (Discord voice, gaming, etc.) when corporate VPN blocks direct UDP traffic.")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "6B7280"))
                    }
                }
            }
            
            // Import/Export section
            SettingsCard(title: "Configuration", icon: "doc.badge.arrow.up.fill", iconColor: Color(hex: "3B82F6")) {
                HStack(spacing: 12) {
                    Button {
                        exportConfig()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                            Text("Export")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "3B82F6"), Color(hex: "2563EB")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        showingImportPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 12))
                            Text("Import")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "3B82F6"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "3B82F6").opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                
                Text("Export your domains and services configuration to a file, or import from a backup.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "6B7280"))
            }
            
            // Network status section
            SettingsCard(title: "Network Status", icon: "network", iconColor: Color(hex: "10B981")) {
                StatusRow(
                    label: "VPN Status",
                    value: routeManager.isVPNConnected ? "Connected" : "Disconnected",
                    valueColor: routeManager.isVPNConnected ? Color(hex: "10B981") : Color(hex: "EF4444"),
                    showDot: true
                )
                
                if let vpnType = routeManager.vpnType {
                    StatusRow(label: "VPN Type", value: vpnType.rawValue)
                }
                
                if let vpnIface = routeManager.vpnInterface {
                    StatusRow(label: "Interface", value: vpnIface)
                }
                
                if let gateway = routeManager.localGateway {
                    StatusRow(label: "Gateway", value: gateway)
                }
                
                if let ssid = routeManager.currentNetworkSSID {
                    StatusRow(label: "WiFi Network", value: ssid)
                }
                
                StatusRow(label: "Active Routes", value: "\(routeManager.activeRoutes.count)")
                
                // Route verification results
                if !routeManager.routeVerificationResults.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    
                    let passedCount = routeManager.routeVerificationResults.values.filter { $0.isReachable }.count
                    let totalCount = routeManager.routeVerificationResults.count
                    
                    HStack {
                        Text("Route Verification")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "9CA3AF"))
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            Image(systemName: passedCount == totalCount ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(passedCount == totalCount ? Color(hex: "10B981") : Color(hex: "F59E0B"))
                            Text("\(passedCount)/\(totalCount) reachable")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(passedCount == totalCount ? Color(hex: "10B981") : Color(hex: "F59E0B"))
                        }
                    }
                }
            }
            
            // About section
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    BrandedAppName(fontSize: 13)
                    Text("Version 1.6.11")
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
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Need to start accessing security-scoped resource
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    
                    if routeManager.importConfig(from: url) {
                        // Success handled by routeManager
                    } else {
                        importErrorMessage = "Failed to import configuration file."
                        showingImportError = true
                    }
                }
            case .failure(let error):
                importErrorMessage = error.localizedDescription
                showingImportError = true
            }
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
    }
    
    private func exportConfig() {
        guard let exportURL = routeManager.exportConfig() else {
            return
        }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = exportURL.lastPathComponent
        savePanel.canCreateDirectories = true
        
        if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            try? FileManager.default.copyItem(at: exportURL, to: destinationURL)
        }
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: exportURL)
    }
    
    private func installHelper() {
        Task {
            _ = await helperManager.installHelper()
        }
    }
}

struct NotificationChip: View {
    let label: String
    @Binding var isOn: Bool
    
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? .white : Color(hex: "6B7280"))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isOn ? Color(hex: "8B5CF6").opacity(0.3) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
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
            
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
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
            // Route Health Dashboard
            routeHealthSection
            
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
                        copyLogsToClipboard()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "3B82F6"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "3B82F6").opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    
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
    
    // MARK: - Route Health Dashboard
    
    private var routeHealthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(hex: "10B981"), Color(hex: "34D399")], startPoint: .top, endPoint: .bottom)
                    )
                Text("Route Health")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            
            // Stats grid
            HStack(spacing: 12) {
                // Active routes
                RouteStatCard(
                    icon: "arrow.triangle.branch",
                    title: "Active Routes",
                    value: "\(routeManager.activeRoutes.count)",
                    color: Color(hex: "10B981")
                )
                
                // Enabled services
                RouteStatCard(
                    icon: "square.grid.2x2",
                    title: "Services",
                    value: "\(routeManager.config.services.filter { $0.enabled }.count)",
                    color: Color(hex: "8B5CF6")
                )
                
                // Enabled domains
                RouteStatCard(
                    icon: "globe",
                    title: "Domains",
                    value: "\(routeManager.config.domains.filter { $0.enabled }.count)",
                    color: Color(hex: "3B82F6")
                )
            }
            
            // DNS and timing info
            VStack(alignment: .leading, spacing: 8) {
                if let dnsServer = routeManager.detectedDNSServerDisplay {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "06B6D4"))
                        Text("DNS: \(dnsServer)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "9CA3AF"))
                    }
                }
                
                if let lastUpdate = routeManager.lastUpdate {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "6B7280"))
                        Text("Last update: ")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "6B7280"))
                        Text(lastUpdate, style: .relative)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "9CA3AF"))
                    }
                }
                
                if routeManager.config.autoDNSRefresh, let nextRefresh = routeManager.nextDNSRefresh {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "10B981"))
                        Text("Next refresh: ")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "6B7280"))
                        Text(nextRefresh, style: .relative)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "10B981"))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.2))
            )
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
    
    private func copyLogsToClipboard() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        let logText = routeManager.recentLogs.map { log in
            "[\(formatter.string(from: log.timestamp))] [\(log.level.rawValue.uppercased())] \(log.message)"
        }.joined(separator: "\n")
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }
}

// MARK: - Info Tab

struct InfoTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App info header
            appInfoSection
            
            // Author section
            authorSection
            
            // Support section
            supportSection
            
            // Links section
            linksSection
            
            // License section
            licenseSection
            
            Spacer()
        }
    }
    
    private var appInfoSection: some View {
        VStack(alignment: .center, spacing: 12) {
            // App logo from bundle
            if let logoPath = Bundle.main.path(forResource: "VPNBypass", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: logoPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
            } else {
                // Fallback to SF Symbol if logo not found
                Image(systemName: "shield.checkered")
                    .font(.system(size: 48))
                    .foregroundStyle(BrandColors.blueGradient)
            }
            
            // App name with branded colors
            BrandedAppName(fontSize: 24)
            
            Text("v1.6.11")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "6B7280"))
            
            Text("Route specific traffic around your corporate VPN")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "9CA3AF"))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
    
    private var authorSection: some View {
        SettingsCard(title: "Author", icon: "person.fill", iconColor: Color(hex: "8B5CF6")) {
            HStack(spacing: 16) {
                // Avatar from GitHub
                if let avatarPath = Bundle.main.path(forResource: "author-avatar", ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: avatarPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                } else {
                    // Fallback
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color(hex: "8B5CF6"), Color(hex: "A78BFA")], startPoint: .top, endPoint: .bottom)
                        )
                        .frame(width: 50, height: 50)
                        .overlay(
                            Text("SF")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sergio Fernández")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text("DevOps Engineer")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "9CA3AF"))
                }
                
                Spacer()
            }
        }
    }
    
    private var supportSection: some View {
        SettingsCard(title: "Support the Project", icon: "heart.fill", iconColor: Color(hex: "EF4444")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("If you find VPN Bypass useful, consider supporting its development!")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "9CA3AF"))
                
                // First row
                HStack(spacing: 10) {
                    LinkButton(
                        title: "GitHub Sponsors",
                        icon: "heart.fill",
                        color: Color(hex: "DB61A2"),
                        url: "https://github.com/sponsors/GeiserX"
                    )
                    
                    LinkButton(
                        title: "Buy Me a Coffee",
                        icon: "cup.and.saucer.fill",
                        color: Color(hex: "FFDD00"),
                        url: "https://buymeacoffee.com/geiser"
                    )
                }
                
                // Second row
                HStack(spacing: 10) {
                    LinkButton(
                        title: "Patreon",
                        icon: "paintpalette.fill",
                        color: Color(hex: "FF424D"),
                        url: "https://patreon.com/geiser"
                    )
                    
                    LinkButton(
                        title: "Thanks.dev",
                        icon: "hands.clap.fill",
                        color: Color(hex: "10B981"),
                        url: "https://thanks.dev/u/gh/geiserx"
                    )
                }
            }
        }
    }
    
    private var linksSection: some View {
        SettingsCard(title: "Links", icon: "link", iconColor: Color(hex: "3B82F6")) {
            VStack(spacing: 8) {
                LinkRow(icon: "globe", title: "Blog", subtitle: "geiser.cloud", url: "https://geiser.cloud")
                Divider().background(Color.white.opacity(0.1))
                LinkRow(icon: "chevron.left.forwardslash.chevron.right", title: "GitHub", subtitle: "github.com/GeiserX", url: "https://github.com/GeiserX")
                Divider().background(Color.white.opacity(0.1))
                LinkRow(icon: "doc.text", title: "Source Code", subtitle: "VPN Bypass", url: "https://github.com/GeiserX/VPN-Bypass")
                Divider().background(Color.white.opacity(0.1))
                LinkRow(icon: "exclamationmark.bubble", title: "Report Issue", subtitle: "GitHub Issues", url: "https://github.com/GeiserX/VPN-Bypass/issues")
            }
        }
    }
    
    private var licenseSection: some View {
        SettingsCard(title: "License", icon: "doc.badge.gearshape", iconColor: Color(hex: "F59E0B")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("GPL-3.0 License")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                
                Text("This software is free and open source under the GNU General Public License v3.0. You are free to use, modify, and distribute it under the same license terms.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "9CA3AF"))
                
                Text("© 2026 Sergio Fernández (GeiserX)")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "6B7280"))
            }
        }
    }
}

// MARK: - Info Tab Components

struct LinkButton: View {
    let title: String
    let icon: String
    let color: Color
    let url: String
    
    var body: some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(color == Color(hex: "FFDD00") ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct LinkRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let url: String
    
    var body: some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "3B82F6"))
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "6B7280"))
                }
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "6B7280"))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Route Stat Card

struct RouteStatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)
            
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "6B7280"))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.1))
        )
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
    
    private var panel: NSPanel?
    
    func show() {
        showPanel()
    }
    
    func showOnTop() {
        showPanel()
    }
    
    private func showPanel() {
        // If panel exists and is visible, just bring it to front
        if let panel = panel, panel.isVisible {
            panel.level = .screenSaver
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // If panel was closed, remove it so we create a fresh one
        if panel != nil && !panel!.isVisible {
            panel = nil
        }
        
        let settingsView = SettingsView()
            .environmentObject(RouteManager.shared)
            .environmentObject(NotificationManager.shared)
            .environmentObject(LaunchAtLoginManager.shared)
        let hostingView = NSHostingView(rootView: settingsView)
        
        // Use NSPanel which can float above other windows
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        
        panel.contentView = hostingView
        panel.title = "" // Empty title, we use custom view
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = NSColor(Color(hex: "0F0F14"))
        panel.isReleasedWhenClosed = false
        panel.center()
        
        // Add branded title to titlebar
        addBrandedTitlebar(to: panel)
        
        // Make it float above EVERYTHING - use screenSaver level (highest)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        
        self.panel = panel
    }
    
    private func addBrandedTitlebar(to window: NSWindow) {
        // Create a container view that spans the full titlebar width
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: window.frame.width, height: 28))
        
        // Create the branded title view
        let titleView = NSHostingView(rootView: BrandedTitlebarView())
        titleView.frame = containerView.bounds
        titleView.autoresizingMask = [.width, .height]
        containerView.addSubview(titleView)
        
        // Create accessory view controller - use .right to stay in titlebar row
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = containerView
        accessory.layoutAttribute = .right
        
        window.addTitlebarAccessoryViewController(accessory)
    }
}

// MARK: - Branded Titlebar View

struct BrandedTitlebarView: View {
    var body: some View {
        HStack {
            Spacer()
            
            HStack(spacing: 5) {
                // Shield icon
                Image(systemName: "shield.checkered")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColors.blueGradient)
                
                // Branded name
                HStack(spacing: 0) {
                    Text("VPN")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(BrandColors.blueGradient)
                    
                    Text("Bypass")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(BrandColors.silverGradient)
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
