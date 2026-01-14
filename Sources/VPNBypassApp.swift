// VPNBypassApp.swift
// VPN Bypass - macOS Menu Bar App
// Automatically routes specific domains/services around VPN.

import SwiftUI
import UserNotifications
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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Hide dock icon (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        
        // Start network monitoring
        startNetworkMonitoring()
        
        // Load config and apply routes on launch
        Task { @MainActor in
            RouteManager.shared.loadConfig()
            if RouteManager.shared.config.autoApplyOnVPN {
                RouteManager.shared.detectAndApplyRoutes()
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor?.cancel()
    }
    
    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                RouteManager.shared.updateNetworkStatus(path)
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
