// VPNBypassApp.swift
// VPN Bypass - macOS Menu Bar App
// Automatically routes specific domains/services around VPN.

import SwiftUI
import Network
import UserNotifications

@main
struct VPNBypassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var routeManager = RouteManager.shared
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(routeManager)
                .environmentObject(notificationManager)
                .environmentObject(launchAtLoginManager)
        } label: {
            MenuBarLabel()
                .environmentObject(routeManager)
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            SettingsView()
                .environmentObject(routeManager)
                .environmentObject(notificationManager)
                .environmentObject(launchAtLoginManager)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var networkMonitor: NWPathMonitor?
    private var refreshTimer: Timer?
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceTypes: Set<NWInterface.InterfaceType> = []
    private var networkDebounceWorkItem: DispatchWorkItem?
    private var hasCompletedInitialStartup = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        
        // Initialize NotificationManager (it sets itself as delegate)
        _ = NotificationManager.shared
        
        // Load config and apply routes on startup
        Task { @MainActor in
            RouteManager.shared.loadConfig()
            
            // Small delay to let network interfaces settle
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            // Detect VPN and apply routes on startup
            await RouteManager.shared.detectAndApplyRoutesAsync()
            
            // Start the auto DNS refresh timer
            RouteManager.shared.startDNSRefreshTimer()
            
            // Mark startup as complete
            hasCompletedInitialStartup = true
        }
        
        // Start network monitoring for changes (after a delay to avoid duplicate startup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.startNetworkMonitoring()
        }
        
        // Also check periodically (every 30 seconds) as backup
        startPeriodicRefresh()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor?.cancel()
        refreshTimer?.invalidate()
        networkDebounceWorkItem?.cancel()
        RouteManager.shared.stopDNSRefreshTimer()
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            // Debounce rapid network changes
            self.networkDebounceWorkItem?.cancel()
            
            let workItem = DispatchWorkItem { [weak self] in
                self?.handleNetworkChange(path)
            }
            
            self.networkDebounceWorkItem = workItem
            
            // Wait 1 second before processing to avoid rapid fire during network transitions
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
        
        networkMonitor?.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
    
    private func handleNetworkChange(_ path: NWPath) {
        let statusChanged = path.status != lastPathStatus
        let interfaceTypes = Set(path.availableInterfaces.map { $0.type })
        let interfacesChanged = interfaceTypes != lastInterfaceTypes
        
        // Detect significant network changes
        let isSignificantChange = statusChanged || interfacesChanged
        
        if isSignificantChange {
            lastPathStatus = path.status
            lastInterfaceTypes = interfaceTypes
            
            Task { @MainActor in
                // Log the network change
                let statusStr = path.status == .satisfied ? "connected" : "disconnected"
                let interfaceStr = interfaceTypes.map { interfaceTypeName($0) }.joined(separator: ", ")
                RouteManager.shared.log(.info, "Network change detected: \(statusStr) via \(interfaceStr)")
                
                // Refresh VPN status
                RouteManager.shared.refreshStatus()
            }
        }
    }
    
    private func interfaceTypeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "WiFi"
        case .cellular: return "Cellular"
        case .wiredEthernet: return "Ethernet"
        case .loopback: return "Loopback"
        case .other: return "Other"
        @unknown default: return "Unknown"
        }
    }
    
    private func startPeriodicRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { @MainActor in
                RouteManager.shared.refreshStatus()
            }
        }
    }
}
