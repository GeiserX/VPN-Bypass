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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        networkMonitor?.pathUpdateHandler = { _ in
            DispatchQueue.main.async {
                Task { @MainActor in
                    let path = NWPathMonitor().currentPath
                    RouteManager.shared.updateNetworkStatus(path)
                }
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }
}
