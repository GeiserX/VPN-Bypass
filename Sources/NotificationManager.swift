// NotificationManager.swift
// Handles macOS notifications for VPN events using proper UNUserNotificationCenter.

import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    @Published var notificationsEnabled = true
    @Published var silentNotifications = false  // No sound when true
    @Published var notifyOnVPNConnect = true
    @Published var notifyOnVPNDisconnect = true
    @Published var notifyOnRoutesApplied = false  // Default OFF - user can enable for verbose feedback
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
        // Sound is controlled per-notification via content.sound
        completionHandler([.banner, .list])
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
            title: String(localized: "VPN Connected"),
            body: String(localized: "Connected via \(interface). Routes will be applied automatically."),
            identifier: "vpn-connected"
        )
    }
    
    func notifyVPNDisconnected(wasInterface: String?, routesRemaining: Int = 0) {
        guard notificationsEnabled && notifyOnVPNDisconnect else { return }

        let suffix = routesRemaining > 0
            ? String(localized: "\(routesRemaining) route(s) could not be removed.")
            : String(localized: "Routes cleared.")
        let body = wasInterface != nil
            ? String(localized: "Disconnected from \(wasInterface!). \(suffix)")
            : String(localized: "VPN connection lost. \(suffix)")

        sendNotification(
            title: String(localized: "VPN Disconnected"),
            body: body,
            identifier: "vpn-disconnected"
        )
    }
    
    func notifyRoutesApplied(count: Int, failedCount: Int = 0) {
        guard notificationsEnabled && notifyOnRoutesApplied else { return }
        
        // Don't notify if no routes were successfully applied (likely still initializing)
        guard count > 0 else { return }
        
        var body = String(localized: "\(count) route(s) applied successfully.")
        if failedCount > 0 {
            body += " " + String(localized: "\(failedCount) failed.")
        }

        sendNotification(
            title: String(localized: "Routes Applied"),
            body: body,
            identifier: "routes-applied"
        )
    }
    
    func notifyRouteVerificationFailed(route: String, reason: String) {
        guard notificationsEnabled && notifyOnRouteFailure else { return }
        
        sendNotification(
            title: String(localized: "Route Verification Failed"),
            body: "\(route): \(reason)",
            identifier: "route-failed-\(route.hashValue)"
        )
    }
    
    func notifyNetworkChanged(newNetwork: String?) {
        guard notificationsEnabled else { return }
        
        let body = newNetwork != nil
            ? String(localized: "Switched to \(newNetwork!). Checking VPN status...")
            : String(localized: "Network changed. Checking VPN status...")

        sendNotification(
            title: String(localized: "Network Changed"),
            body: body,
            identifier: "network-changed"
        )
    }
    
    /// Send a test notification
    func sendTestNotification() {
        sendNotification(
            title: String(localized: "VPN Bypass"),
            body: String(localized: "Test notification successful!") + " 🎉",
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
        content.sound = silentNotifications ? nil : .default
        
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
        var silentNotifications: Bool
        var notifyOnVPNConnect: Bool
        var notifyOnVPNDisconnect: Bool
        var notifyOnRoutesApplied: Bool
        var notifyOnRouteFailure: Bool
        
        // Migration: provide defaults for new fields
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notificationsEnabled = try container.decode(Bool.self, forKey: .notificationsEnabled)
            silentNotifications = try container.decodeIfPresent(Bool.self, forKey: .silentNotifications) ?? false
            notifyOnVPNConnect = try container.decode(Bool.self, forKey: .notifyOnVPNConnect)
            notifyOnVPNDisconnect = try container.decode(Bool.self, forKey: .notifyOnVPNDisconnect)
            notifyOnRoutesApplied = try container.decode(Bool.self, forKey: .notifyOnRoutesApplied)
            notifyOnRouteFailure = try container.decode(Bool.self, forKey: .notifyOnRouteFailure)
        }
        
        init(notificationsEnabled: Bool, silentNotifications: Bool, notifyOnVPNConnect: Bool,
             notifyOnVPNDisconnect: Bool, notifyOnRoutesApplied: Bool, notifyOnRouteFailure: Bool) {
            self.notificationsEnabled = notificationsEnabled
            self.silentNotifications = silentNotifications
            self.notifyOnVPNConnect = notifyOnVPNConnect
            self.notifyOnVPNDisconnect = notifyOnVPNDisconnect
            self.notifyOnRoutesApplied = notifyOnRoutesApplied
            self.notifyOnRouteFailure = notifyOnRouteFailure
        }
    }
    
    func savePreferences() {
        let prefs = Preferences(
            notificationsEnabled: notificationsEnabled,
            silentNotifications: silentNotifications,
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
        // Check if this is first launch - if so, use defaults
        let hasLaunched = UserDefaults.standard.bool(forKey: hasLaunchedKey)
        if !hasLaunched {
            print("🔔 First launch - using default notification settings (routes OFF)")
            UserDefaults.standard.set(true, forKey: hasLaunchedKey)
            savePreferences()
            return
        }
        
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return
        }
        
        notificationsEnabled = prefs.notificationsEnabled
        silentNotifications = prefs.silentNotifications
        notifyOnVPNConnect = prefs.notifyOnVPNConnect
        notifyOnVPNDisconnect = prefs.notifyOnVPNDisconnect
        notifyOnRoutesApplied = prefs.notifyOnRoutesApplied
        notifyOnRouteFailure = prefs.notifyOnRouteFailure
    }
    
    // MARK: - Additional Notifications
    
    func notifyServiceToggled(service: String, enabled: Bool) {
        guard notificationsEnabled && notifyOnRoutesApplied else { return }
        
        sendNotification(
            title: enabled ? String(localized: "Service Enabled") : String(localized: "Service Disabled"),
            body: service,
            identifier: "service-toggled"
        )
    }
    
    func notifyDomainAdded(domain: String) {
        guard notificationsEnabled && notifyOnRoutesApplied else { return }
        
        sendNotification(
            title: String(localized: "Domain Added"),
            body: domain,
            identifier: "domain-added"
        )
    }
    
    func notifyDomainRemoved(domain: String) {
        guard notificationsEnabled && notifyOnRoutesApplied else { return }
        
        sendNotification(
            title: String(localized: "Domain Removed"),
            body: domain,
            identifier: "domain-removed"
        )
    }
    
    func notifyDNSRefreshCompleted(updatedCount: Int) {
        guard notificationsEnabled && notifyOnRoutesApplied else { return }
        
        sendNotification(
            title: String(localized: "DNS Refresh Complete"),
            body: String(localized: "\(updatedCount) route(s) updated"),
            identifier: "dns-refresh"
        )
    }
}
