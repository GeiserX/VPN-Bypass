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
    private var watchdogTimer: Timer?
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceTypes: Set<NWInterface.InterfaceType> = []
    private var lastInterfaceNames: Set<String> = []
    private var networkDebounceWorkItem: DispatchWorkItem?
    private var hasCompletedInitialStartup = false
    private var appStartTime = Date()
    private var lastSuccessfulVPNCheck = Date()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        
        // Initialize NotificationManager (it sets itself as delegate)
        _ = NotificationManager.shared
        
        // Pre-warm SettingsWindowController so first click is instant
        _ = SettingsWindowController.shared

        // Load config and apply routes on startup
        Task { @MainActor in
            RouteManager.shared.loadConfig()

            // Ensure helper is installed, running, and at the correct version
            // BEFORE any route application. This prevents the "Setting Up" hang
            // when the helper is outdated after a Homebrew upgrade.
            let helperReady = await HelperManager.shared.ensureHelperReady()
            if !helperReady {
                RouteManager.shared.log(.error, "Helper not ready: \(HelperManager.shared.helperState.statusText). Route application skipped.")
            }

            // Small delay to let network interfaces settle
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            // Only attempt route application if helper is verified ready.
            // Without the helper, route operations will fail silently or hang.
            guard helperReady else { return }

            // Detect VPN and apply routes on startup
            await RouteManager.shared.detectAndApplyRoutesAsync()

            // Start the auto DNS refresh timer
            RouteManager.shared.startDNSRefreshTimer()

            // Mark startup as complete
            hasCompletedInitialStartup = true
            lastSuccessfulVPNCheck = Date()
        }
        
        // Start network monitoring for changes (after a delay to avoid duplicate startup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.startNetworkMonitoring()
        }
        
        // Also check periodically (every 30 seconds) as backup
        startPeriodicRefresh()
        
        // Start watchdog timer (every 12 hours) to ensure long-term stability
        startWatchdog()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Hide all UI immediately so quit feels instant
        NSApp.windows.forEach { $0.orderOut(nil) }

        networkMonitor?.cancel()
        refreshTimer?.invalidate()
        watchdogTimer?.invalidate()
        networkDebounceWorkItem?.cancel()
        RouteManager.shared.stopDNSRefreshTimer()

        // Clean up routes and hosts file on quit, then allow termination
        var didReply = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !didReply else { return }
            didReply = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await RouteManager.shared.cleanupOnQuit()
            guard !didReply else { return }
            didReply = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            // All access to networkDebounceWorkItem must happen on the main thread
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                self.networkDebounceWorkItem?.cancel()
                
                let workItem = DispatchWorkItem { [weak self] in
                    self?.handleNetworkChange(path)
                }
                
                self.networkDebounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
            }
        }
        
        networkMonitor?.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
    
    private func handleNetworkChange(_ path: NWPath) {
        let statusChanged = path.status != lastPathStatus
        let interfaceTypes = Set(path.availableInterfaces.map { $0.type })
        let interfaceNames = Set(path.availableInterfaces.map { $0.name })
        let typesChanged = interfaceTypes != lastInterfaceTypes
        let namesChanged = interfaceNames != lastInterfaceNames
        
        let isSignificantChange = statusChanged || typesChanged || namesChanged
        
        if isSignificantChange {
            lastPathStatus = path.status
            lastInterfaceTypes = interfaceTypes
            lastInterfaceNames = interfaceNames
            
            Task { @MainActor in
                let statusStr = path.status == .satisfied ? "connected" : "disconnected"
                let interfaceStr = interfaceNames.sorted().joined(separator: ", ")
                RouteManager.shared.log(.info, "Network change detected: \(statusStr) via \(interfaceStr)")
                
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                RouteManager.shared.refreshStatus()
                self?.lastSuccessfulVPNCheck = Date()
            }
        }
    }
    
    // MARK: - Watchdog (Long-term Stability)
    
    /// Watchdog timer runs every 12 hours to ensure app stays healthy during long uptimes
    private func startWatchdog() {
        let twelveHours: TimeInterval = 12 * 60 * 60  // 43200 seconds
        
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: twelveHours, repeats: true) { [weak self] _ in
            self?.runWatchdog()
        }
    }
    
    private func runWatchdog() {
        Task { @MainActor in
            let uptime = Date().timeIntervalSince(appStartTime)
            let uptimeHours = Int(uptime / 3600)
            let uptimeDays = uptimeHours / 24
            let remainingHours = uptimeHours % 24
            
            let uptimeStr = uptimeDays > 0 ? "\(uptimeDays)d \(remainingHours)h" : "\(uptimeHours)h"
            
            RouteManager.shared.log(.info, "🐕 Watchdog: App uptime \(uptimeStr), restarting network monitor...")
            
            // Restart network monitor to prevent stale state
            restartNetworkMonitor()
            
            // Force a fresh VPN detection
            await RouteManager.shared.checkVPNStatus()
            
            // Log current state
            let vpnStatus = RouteManager.shared.isVPNConnected ? "connected via \(RouteManager.shared.vpnInterface ?? "?")" : "not connected"
            let routeCount = RouteManager.shared.uniqueRouteCount
            RouteManager.shared.log(.info, "🐕 Watchdog complete: VPN \(vpnStatus), \(routeCount) active routes")
        }
    }
    
    private func restartNetworkMonitor() {
        // Cancel existing monitor
        networkMonitor?.cancel()
        networkMonitor = nil
        
        // Reset state
        lastPathStatus = nil
        lastInterfaceTypes = []
        lastInterfaceNames = []
        networkDebounceWorkItem?.cancel()
        networkDebounceWorkItem = nil
        
        // Small delay then restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startNetworkMonitoring()
        }
    }
}
