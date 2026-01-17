// LaunchAtLoginManager.swift
// Manages Launch at Login via LaunchAgent.

import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()
    
    @Published var isEnabled: Bool = false
    
    private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.geiserx.vpnbypass"
    private let hasSetupKey = "LaunchAtLoginSetup"
    
    private init() {
        checkStatus()
        enableByDefaultOnFirstLaunch()
    }
    
    private func enableByDefaultOnFirstLaunch() {
        let hasSetup = UserDefaults.standard.bool(forKey: hasSetupKey)
        if !hasSetup {
            print("🚀 First launch - enabling Launch at Login by default")
            UserDefaults.standard.set(true, forKey: hasSetupKey)
            // Only enable if not already enabled
            if !isEnabled {
                enable()
            }
        }
    }
    
    // MARK: - Public API
    
    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }
    
    func enable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                isEnabled = true
                print("Launch at login enabled via SMAppService")
            } catch {
                print("Failed to enable launch at login: \(error)")
                // Fallback to LaunchAgent
                enableViaLaunchAgent()
            }
        } else {
            enableViaLaunchAgent()
        }
    }
    
    func disable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                isEnabled = false
                print("Launch at login disabled via SMAppService")
            } catch {
                print("Failed to disable launch at login: \(error)")
                // Fallback to LaunchAgent
                disableViaLaunchAgent()
            }
        } else {
            disableViaLaunchAgent()
        }
    }
    
    func checkStatus() {
        if #available(macOS 13.0, *) {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            isEnabled = launchAgentExists()
        }
    }
    
    // MARK: - LaunchAgent Fallback (for macOS < 13.0)
    
    private var launchAgentURL: URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }
    
    private func launchAgentExists() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }
    
    private func enableViaLaunchAgent() {
        guard let appPath = Bundle.main.bundlePath as String? else {
            print("Could not determine app path")
            return
        }
        
        let launchAgentContent: [String: Any] = [
            "Label": bundleIdentifier,
            "ProgramArguments": [appPath + "/Contents/MacOS/VPNBypass"],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        
        // Ensure LaunchAgents directory exists
        let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        
        // Write plist
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: launchAgentContent,
                format: .xml,
                options: 0
            )
            try data.write(to: launchAgentURL)
            
            // Load the agent
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", launchAgentURL.path]
            try process.run()
            process.waitUntilExit()
            
            isEnabled = true
            print("Launch at login enabled via LaunchAgent")
        } catch {
            print("Failed to create LaunchAgent: \(error)")
        }
    }
    
    private func disableViaLaunchAgent() {
        // Unload the agent first
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", launchAgentURL.path]
        try? process.run()
        process.waitUntilExit()
        
        // Remove the plist file
        try? FileManager.default.removeItem(at: launchAgentURL)
        
        isEnabled = false
        print("Launch at login disabled via LaunchAgent")
    }
}
