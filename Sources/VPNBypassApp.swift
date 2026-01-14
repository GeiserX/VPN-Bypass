// VPNBypassApp.swift
// VPN Bypass - macOS Menu Bar App
// Automatically routes specific domains/services around VPN.

import SwiftUI
import Network

@main
struct VPNBypassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var routeManager = RouteManager.shared
    
    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(routeManager)
        } label: {
            MenuBarLabel()
                .environmentObject(routeManager)
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            SettingsView()
                .environmentObject(routeManager)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var networkMonitor: NWPathMonitor?
    private var refreshTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        
        // Load config
        Task { @MainActor in
            RouteManager.shared.loadConfig()
        }
        
        // Initial VPN check after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                RouteManager.shared.refreshStatus()
            }
        }
        
        // Start network monitoring for changes
        startNetworkMonitoring()
        
        // Also check periodically (every 30 seconds) as backup
        startPeriodicRefresh()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor?.cancel()
        refreshTimer?.invalidate()
    }
    
    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { _ in
            // Network changed, refresh VPN status
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    RouteManager.shared.refreshStatus()
                }
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
    
    private func startPeriodicRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { @MainActor in
                RouteManager.shared.refreshStatus()
            }
        }
    }
}
