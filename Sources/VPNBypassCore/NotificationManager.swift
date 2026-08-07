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
    
    /// Nil under XCTest. `UNUserNotificationCenter.current()` traps when the process has no app
    /// bundle ("bundleProxyForCurrentProcess is nil"), so merely *touching* this singleton from a
    /// test aborts the entire suite with signal 6. Guarding here, rather than at each call site,
    /// means any code path is free to notify without knowing whether it is running under test —
    /// which matters because the paths that most need to notify are error paths, and those are
    /// exactly the ones tests drive. Mirrors the `underTests` redirect already used for config
    /// storage in RouteManager.
    private static let isUnderTests = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private let notificationCenter: UNUserNotificationCenter? =
        NotificationManager.isUnderTests ? nil : .current()
    
    private override init() {
        super.init()
        
        // Set ourselves as delegate to handle foreground notifications
        notificationCenter?.delegate = self
        
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
            guard let notificationCenter else { return }
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            
            if granted {
                RouteManager.shared.log(.success, "Notification authorization granted")
            } else {
                RouteManager.shared.log(.warning, "Notification authorization denied")
            }
        } catch {
            RouteManager.shared.log(.error, "Notification authorization error: \(error.localizedDescription)")
            isAuthorized = false
        }
        
        // Also check current status
        await updateAuthorizationStatus()
    }
    
    func updateAuthorizationStatus() async {
        guard let notificationCenter else { return }
        let settings = await notificationCenter.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }
    
    func checkAuthorizationStatus() async -> Bool {
        guard let notificationCenter else { return false }
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

    /// Nothing at all could be enforced — the app is configured but not doing anything.
    ///
    /// This is the failure a user most needs to hear about, and it was the ONE case guaranteed to be
    /// silent: `notifyRoutesApplied` is gated both on a non-zero success count and on
    /// `notifyOnRoutesApplied`, which defaults OFF — so a total failure notified nothing, while
    /// *partial* failures did get through. Every early return in the apply paths (no gateway, helper
    /// not ready, VPN Only without a VPN gateway, VPN Only refused under GlobalProtect) now lands
    /// here instead of only writing a log line the user has no reason to open.
    ///
    /// Gated on `notifyOnRouteFailure`, which defaults ON. The identifier is stable per reason so a
    /// repeating condition coalesces into one notification rather than nagging on every retry.
    func notifyEnforcementFailed(reason: String) {
        guard notificationsEnabled && notifyOnRouteFailure else { return }

        sendNotification(
            title: String(localized: "VPN Bypass isn't routing anything"),
            body: reason,
            identifier: "enforcement-failed-\(reason.hashValue)"
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
        
        guard let notificationCenter else { return }
        notificationCenter.add(request) { error in
            if let error = error {
                // The completion runs off the main actor; hop back to log (and pre-format
                // the message so no non-Sendable Error crosses the boundary).
                let msg = "Failed to send notification: \(error.localizedDescription)"
                Task { @MainActor in RouteManager.shared.log(.error, msg) }
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
            RouteManager.shared.log(.info, "First launch - using default notification settings (routes OFF)")
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
    
    func notifyDNSRefreshCompleted(updatedCount: Int) {
        guard notificationsEnabled && notifyOnRoutesApplied else { return }
        
        sendNotification(
            title: String(localized: "DNS Refresh Complete"),
            body: String(localized: "\(updatedCount) route(s) updated"),
            identifier: "dns-refresh"
        )
    }
}
