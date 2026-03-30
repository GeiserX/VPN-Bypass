// HelperManager.swift
// Manages installation and communication with the privileged helper tool.

import Foundation
import ServiceManagement
import Security

@MainActor
final class HelperManager: ObservableObject {
    static let shared = HelperManager()
    
    @Published var isHelperInstalled = false
    @Published var helperVersion: String?
    @Published var installationError: String?
    @Published var isInstalling = false
    
    private var xpcConnection: NSXPCConnection?
    private let hasPromptedKey = "HasPromptedHelperInstall"
    
    private init() {
        checkHelperStatus()
        // Auto-install on first launch after a short delay to let UI load
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task { @MainActor in
                self.autoInstallOnFirstLaunch()
            }
        }
    }
    
    private func autoInstallOnFirstLaunch() {
        let hasPrompted = UserDefaults.standard.bool(forKey: hasPromptedKey)
        if !hasPrompted && !isHelperInstalled {
            print("🔐 First launch - auto-installing privileged helper")
            UserDefaults.standard.set(true, forKey: hasPromptedKey)
            Task {
                _ = await installHelper()
            }
        } else if isHelperInstalled {
            // Check for version mismatch and auto-update if needed
            checkAndUpdateHelperVersion()
        }
    }
    
    private func checkAndUpdateHelperVersion() {
        connectToHelper { [weak self] helper in
            helper.getVersion { installedVersion in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.helperVersion = installedVersion
                    
                    // Compare with expected version
                    let expectedVersion = HelperConstants.helperVersion
                    if installedVersion != expectedVersion {
                        print("🔐 Helper version mismatch: installed=\(installedVersion), expected=\(expectedVersion)")
                        print("🔐 Auto-updating privileged helper...")
                        Task {
                            _ = await self.installHelper()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Status
    
    func checkHelperStatus() {
        // Check if helper is installed (file exists means it's registered with launchd)
        let helperPath = "/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)"
        let plistPath = "/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        
        // If both files exist, the helper is installed and will be launched on-demand by launchd
        if FileManager.default.fileExists(atPath: helperPath) && 
           FileManager.default.fileExists(atPath: plistPath) {
            isHelperInstalled = true
            
            // Try to connect and get version (async, non-blocking)
            connectToHelper { [weak self] helper in
                helper.getVersion { version in
                    Task { @MainActor in
                        self?.helperVersion = version
                    }
                }
            }
        } else {
            isHelperInstalled = false
            helperVersion = nil
        }
    }
    
    // MARK: - Helper Installation
    
    func installHelper() async -> Bool {
        print("🔐 Installing privileged helper...")
        isInstalling = true
        defer { 
            Task { @MainActor in
                self.isInstalling = false 
            }
        }
        
        // First, try the modern SMAppService API (macOS 13+)
        if #available(macOS 13.0, *) {
            return await installHelperModern()
        } else {
            return installHelperLegacy()
        }
    }
    
    @available(macOS 13.0, *)
    private func installHelperModern() async -> Bool {
        do {
            // The plist must be in Contents/Library/LaunchDaemons/
            let service = SMAppService.daemon(plistName: "\(kHelperToolMachServiceName).plist")
            
            print("🔐 Attempting to register daemon service...")
            try await service.register()
            
            await MainActor.run {
                self.isHelperInstalled = true
                self.installationError = nil
            }
            print("✅ Helper registered successfully via SMAppService")
            return true
        } catch {
            print("⚠️ SMAppService failed: \(error.localizedDescription)")
            print("🔐 Falling back to legacy SMJobBless...")
            
            // Fall back to legacy method
            return await MainActor.run {
                return self.installHelperLegacy()
            }
        }
    }
    
    private func installHelperLegacy() -> Bool {
        // For unsigned development builds, use AppleScript to install helper manually
        print("🔐 Attempting manual helper installation via AppleScript...")
        
        guard let bundlePath = Bundle.main.bundlePath as String?,
              bundlePath.hasSuffix(".app") else {
            installationError = "Not running from app bundle"
            return false
        }
        
        // Path to helper binary in the app bundle
        let helperSource = "\(bundlePath)/Contents/MacOS/\(kHelperToolMachServiceName)"
        let plistSource = "\(bundlePath)/Contents/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        
        let helperDest = "/Library/PrivilegedHelperTools/\(kHelperToolMachServiceName)"
        let plistDest = "/Library/LaunchDaemons/\(kHelperToolMachServiceName).plist"
        
        // Check if source files exist
        guard FileManager.default.fileExists(atPath: helperSource) else {
            installationError = "Helper binary not found in app bundle"
            print("❌ Helper not found at: \(helperSource)")
            return false
        }
        
        guard FileManager.default.fileExists(atPath: plistSource) else {
            installationError = "Helper plist not found in app bundle"
            print("❌ Plist not found at: \(plistSource)")
            return false
        }
        
        // Create install script
        let script = """
        do shell script "
            # Create directory if needed
            mkdir -p /Library/PrivilegedHelperTools
            
            # Stop existing helper if running
            launchctl bootout system/\(kHelperToolMachServiceName) 2>/dev/null || true
            
            # Copy helper binary
            cp '\(helperSource)' '\(helperDest)'
            chmod 544 '\(helperDest)'
            chown root:wheel '\(helperDest)'
            
            # Copy launchd plist
            cp '\(plistSource)' '\(plistDest)'
            chmod 644 '\(plistDest)'
            chown root:wheel '\(plistDest)'
            
            # Load the helper
            launchctl bootstrap system '\(plistDest)'
        " with administrator privileges
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            
            if let error = error {
                let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                installationError = errorMessage
                print("❌ AppleScript error: \(errorMessage)")
                return false
            }
            
            print("✅ Helper installed successfully via AppleScript")
            isHelperInstalled = true
            installationError = nil
            
            // Verify installation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.checkHelperStatus()
            }
            
            return true
        }
        
        installationError = "Failed to create AppleScript"
        return false
    }
    
    // MARK: - XPC Connection
    
    private func connectToHelper(completion: @escaping (HelperProtocol) -> Void) {
        if let connection = xpcConnection {
            if let helper = connection.remoteObjectProxy as? HelperProtocol {
                completion(helper)
                return
            }
        }
        
        // Create new connection
        let connection = NSXPCConnection(machServiceName: kHelperToolMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.xpcConnection = nil
            }
        }
        
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.xpcConnection = nil
            }
        }
        
        connection.resume()
        xpcConnection = connection
        
        if let helper = connection.remoteObjectProxy as? HelperProtocol {
            completion(helper)
        }
    }
    
    private func getHelper() async -> HelperProtocol? {
        return await withCheckedContinuation { continuation in
            connectToHelper { helper in
                continuation.resume(returning: helper)
            }
        }
    }
    
    // MARK: - Route Operations
    
    func addRoute(destination: String, gateway: String, isNetwork: Bool = false) async -> (success: Bool, error: String?) {
        guard isHelperInstalled else {
            return (false, "Helper not installed")
        }
        
        return await withCheckedContinuation { continuation in
            connectToHelper { helper in
                helper.addRoute(destination: destination, gateway: gateway, isNetwork: isNetwork) { success, error in
                    continuation.resume(returning: (success, error))
                }
            }
        }
    }
    
    func removeRoute(destination: String) async -> (success: Bool, error: String?) {
        guard isHelperInstalled else {
            return (false, "Helper not installed")
        }
        
        return await withCheckedContinuation { continuation in
            connectToHelper { helper in
                helper.removeRoute(destination: destination) { success, error in
                    continuation.resume(returning: (success, error))
                }
            }
        }
    }
    
    // MARK: - Batch Route Operations (for startup/stop performance)
    
    func addRoutesBatch(routes: [(destination: String, gateway: String, isNetwork: Bool)]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        guard isHelperInstalled else {
            return (0, routes.count, routes.map { $0.destination }, "Helper not installed")
        }

        let dictRoutes = routes.map { route -> [String: Any] in
            return [
                "destination": route.destination,
                "gateway": route.gateway,
                "isNetwork": route.isNetwork
            ]
        }

        return await withCheckedContinuation { continuation in
            connectToHelper { helper in
                helper.addRoutesBatch(routes: dictRoutes) { successCount, failureCount, failedDestinations, error in
                    continuation.resume(returning: (successCount, failureCount, failedDestinations, error))
                }
            }
        }
    }

    func removeRoutesBatch(destinations: [String]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        guard isHelperInstalled else {
            return (0, destinations.count, destinations, "Helper not installed")
        }

        return await withCheckedContinuation { continuation in
            connectToHelper { helper in
                helper.removeRoutesBatch(destinations: destinations) { successCount, failureCount, failedDestinations, error in
                    continuation.resume(returning: (successCount, failureCount, failedDestinations, error))
                }
            }
        }
    }
    
    // MARK: - Hosts File Operations
    
    func updateHostsFile(entries: [(domain: String, ip: String)]) async -> (success: Bool, error: String?) {
        guard isHelperInstalled else {
            return (false, "Helper not installed")
        }
        
        let dictEntries = entries.map { ["domain": $0.domain, "ip": $0.ip] }
        
        return await withCheckedContinuation { continuation in
            connectToHelper { helper in
                helper.updateHostsFile(entries: dictEntries) { success, error in
                    if success {
                        helper.flushDNSCache { _ in
                            continuation.resume(returning: (true, nil))
                        }
                    } else {
                        continuation.resume(returning: (false, error))
                    }
                }
            }
        }
    }
    
    func clearHostsFile() async -> (success: Bool, error: String?) {
        return await updateHostsFile(entries: [])
    }
}
