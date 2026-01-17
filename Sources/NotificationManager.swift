// NotificationManager.swift
// Handles macOS notifications for VPN events using proper UNUserNotificationCenter.

import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    @Published var notificationsEnabled = true
    @Published var notifyOnVPNConnect = true
    @Published var notifyOnVPNDisconnect = true
    @Published var notifyOnRoutesApplied = true
    @Published var notifyOnRouteFailure = true
    @Published var isAuthorized = false
    
    private let notificationCenter = UNUserNotificationCenter.current()
    
    private override init() {
        super.init()
        
        // Set ourselves as delegate to handle foreground notifications
        notificationCenter.delegate = self
        
        // Load saved preferences
        loadPreferences()
        
        // Request authorization on init
        Task {
            await requestAuthorization()
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground
        completionHandler([.banner, .sound, .list])
    }
    
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle notification tap
        Task { @MainActor in
            SettingsWindowController.shared.show()
        }
        completionHandler()
    }
    
    // MARK: - Authorization
    
    func requestAuthorization() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            
            if granted {
                print("✅ Notification authorization granted")
            } else {
                print("⚠️ Notification authorization denied")
            }
        } catch {
            print("❌ Notification authorization error: \(error)")
            isAuthorized = false
        }
        
        // Also check current status
        await updateAuthorizationStatus()
    }
    
    func updateAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }
    
    func checkAuthorizationStatus() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
        isAuthorized = authorized
        return authorized
    }
    
    // MARK: - Notifications
    
    func notifyVPNConnected(interface: String) {
        guard notificationsEnabled && notifyOnVPNConnect else { return }
        
        sendNotification(
            title: "VPN Connected",
            body: "Connected via \(interface). Routes will be applied automatically.",
            identifier: "vpn-connected"
        )
    }
    
    func notifyVPNDisconnected(wasInterface: String?) {
        guard notificationsEnabled && notifyOnVPNDisconnect else { return }
        
        let body = wasInterface != nil 
            ? "Disconnected from \(wasInterface!). Routes cleared."
            : "VPN connection lost. Routes cleared."
        
        sendNotification(
            title: "VPN Disconnected",
            body: body,
            identifier: "vpn-disconnected"
        )
    }
    
    func notifyRoutesApplied(count: Int, failedCount: Int = 0) {
        guard notificationsEnabled && notifyOnRoutesApplied else { return }
        
        // Don't notify if no routes were successfully applied (likely still initializing)
        guard count > 0 else { return }
        
        var body = "\(count) route\(count == 1 ? "" : "s") applied successfully."
        if failedCount > 0 {
            body += " \(failedCount) failed."
        }
        
        sendNotification(
            title: "Routes Applied",
            body: body,
            identifier: "routes-applied"
        )
    }
    
    func notifyRouteVerificationFailed(route: String, reason: String) {
        guard notificationsEnabled && notifyOnRouteFailure else { return }
        
        sendNotification(
            title: "Route Verification Failed",
            body: "\(route): \(reason)",
            identifier: "route-failed-\(route.hashValue)"
        )
    }
    
    func notifyNetworkChanged(newNetwork: String?) {
        guard notificationsEnabled else { return }
        
        let body = newNetwork != nil 
            ? "Switched to \(newNetwork!). Checking VPN status..."
            : "Network changed. Checking VPN status..."
        
        sendNotification(
            title: "Network Changed",
            body: body,
            identifier: "network-changed"
        )
    }
    
    /// Send a test notification
    func sendTestNotification() {
        sendNotification(
            title: "VPN Bypass",
            body: "Test notification successful! 🎉",
            identifier: "test-notification"
        )
    }
    
    /// Open System Settings to Notifications pane
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Private
    
    private func sendNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        // Use a unique identifier to allow multiple notifications
        let uniqueId = "\(identifier)-\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(identifier: uniqueId, content: content, trigger: nil)
        
        notificationCenter.add(request) { error in
            if let error = error {
                print("❌ Failed to send notification: \(error)")
            }
        }
    }
    
    // MARK: - Preferences
    
    private let prefsKey = "NotificationPreferences"
    private let hasLaunchedKey = "HasLaunchedBefore"
    
    struct Preferences: Codable {
        var notificationsEnabled: Bool
        var notifyOnVPNConnect: Bool
        var notifyOnVPNDisconnect: Bool
        var notifyOnRoutesApplied: Bool
        var notifyOnRouteFailure: Bool
    }
    
    func savePreferences() {
        let prefs = Preferences(
            notificationsEnabled: notificationsEnabled,
            notifyOnVPNConnect: notifyOnVPNConnect,
            notifyOnVPNDisconnect: notifyOnVPNDisconnect,
            notifyOnRoutesApplied: notifyOnRoutesApplied,
            notifyOnRouteFailure: notifyOnRouteFailure
        )
        
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }
    
    private func loadPreferences() {
        // Check if this is first launch - if so, use defaults (all enabled)
        let hasLaunched = UserDefaults.standard.bool(forKey: hasLaunchedKey)
        if !hasLaunched {
            print("🔔 First launch - using default notification settings (all enabled)")
            UserDefaults.standard.set(true, forKey: hasLaunchedKey)
            savePreferences()
            return
        }
        
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return
        }
        
        notificationsEnabled = prefs.notificationsEnabled
        notifyOnVPNConnect = prefs.notifyOnVPNConnect
        notifyOnVPNDisconnect = prefs.notifyOnVPNDisconnect
        notifyOnRoutesApplied = prefs.notifyOnRoutesApplied
        notifyOnRouteFailure = prefs.notifyOnRouteFailure
    }
}
