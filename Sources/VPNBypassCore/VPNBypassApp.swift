// VPNBypassApp.swift
// VPN Bypass - macOS Menu Bar App
// Automatically routes specific domains/services around VPN.

import SwiftUI
import Network

public struct VPNBypassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var routeManager = RouteManager.shared
    @StateObject private var notificationManager = NotificationManager.shared
    @StateObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    /// SettingsView reads it; the window from SettingsWindowController is the one users see.
    @StateObject private var modeSwitch = ModeSwitchRequest()
    @StateObject private var settingsUndo = SettingsUndo()

    public init() {}

    public var body: some Scene {
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
                .environmentObject(modeSwitch)
                .environmentObject(settingsUndo)
        }
        // The app menu's Settings… (shown while the Settings window makes the app a regular
        // app) opens the same window as the gear, which carries the Mode menu in its title bar.
        // This scene's own window has no title bar accessory, so it could not change the mode.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlSocketServer?
    private var networkMonitor: NWPathMonitor?
    private(set) var refreshTimer: Timer?
    private(set) var watchdogTimer: Timer?
    /// Retained so the SIGTERM/SIGINT sources stay alive for the process lifetime.
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var lastPathStatus: NWPath.Status?
    private var lastInterfaceTypes: Set<NWInterface.InterfaceType> = []
    private var lastInterfaceNames: Set<String> = []
    /// The interface at the head of `availableInterfaces` — NWPath orders that list by
    /// preference, so this is the path traffic actually takes. Tracked separately because the
    /// three signals above are all SETS or scalars that stay identical when the primary flips
    /// between two connected NICs on one subnet, which is exactly when macOS drops the routes
    /// pinned to the old one (issue #94).
    private var lastPrimaryInterface: String?
    private var networkDebounceWorkItem: DispatchWorkItem?
    private var appStartTime = Date()
    /// The executable this process was launched from, to notice when an update replaces it.
    private var launchedExecutable: AppUpdateRelauncher.FileIdentity?
    private var isRelaunchingForUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard FIRST. Two processes mutating the route table at
        // once is what tore down the GlobalProtect tunnel. If another instance
        // already holds the lock, exit immediately WITHOUT the normal terminate
        // path: applicationShouldTerminate runs cleanupOnQuit(), which would
        // remove the routes owned by the instance that is actually running.
        guard SingleInstanceGuard.acquire() else {
            NSLog("VPN Bypass: another instance is already running — exiting duplicate without touching routes.")
            exit(0)
        }

        launchedExecutable = Bundle.main.executablePath.flatMap(AppUpdateRelauncher.identity(ofFileAt:))

        // Hide dock icon (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        
        // Initialize NotificationManager (it sets itself as delegate)
        _ = NotificationManager.shared
        
        // Pre-warm SettingsWindowController so first click is instant
        _ = SettingsWindowController.shared

        // Start the scripting control socket (a user-only UNIX socket; userspace,
        // so it's independent of the privileged helper and starts unconditionally).
        // Only the instance that won the single-instance lock reaches here, so it
        // is the sole owner of the socket.
        controlServer = ControlSurface.makeServer()
        do {
            try controlServer?.start()
        } catch {
            RouteManager.shared.log(.warning, "Control socket unavailable: \(error)")
        }

        // Load config and apply routes on startup
        Task { @MainActor in
            RouteManager.shared.loadConfig()

            // Ensure helper is installed, running, and at the correct version
            // BEFORE any route application. This prevents the "Setting Up" hang
            // when the helper is outdated after a Homebrew upgrade.
            let helperReady = await HelperManager.shared.ensureHelperReady()
            if !helperReady {
                RouteManager.shared.log(.error, "Helper not ready: \(HelperManager.shared.helperState.statusText). Route application skipped.")
                // This is a FIRST-RUN-reachable state, and it used to be one log line nobody
                // saw: the menu showed a green ON while nothing was enforced. Tell the user.
                NotificationManager.shared.notifyEnforcementFailed(
                    reason: String(localized: "The privileged helper is not running — no routes are being enforced. Open Settings → Status to repair it.")
                )
                // Detect VPN state for display, but skip route mutations that
                // require the helper. This clears the "Setting Up..." spinner
                // instead of hanging on it forever when the helper is absent.
                await RouteManager.shared.detectVPNStateOnly()
                // Proxy-route listeners are userspace and don't need the helper —
                // start them regardless so multi-route works even if the helper is down.
                await RouteManager.shared.reconcileProxyListeners()
                return
            }

            // Small delay to let network interfaces settle
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            // Detect VPN and apply routes on startup
            await RouteManager.shared.detectAndApplyRoutesAsync()

            // Start the auto DNS refresh timer
            RouteManager.shared.startDNSRefreshTimer()
        }
        
        // Start network monitoring for changes (after a delay to avoid duplicate startup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.startNetworkMonitoring()
        }
        
        // Also check periodically (every 30 seconds) as backup
        startPeriodicRefresh()
        
        // Start watchdog timer (every 12 hours) to ensure long-term stability
        startWatchdog()

        installTerminationSignalHandler()
    }

    /// Run the same teardown on SIGTERM that a normal Quit runs.
    ///
    /// `applicationShouldTerminate` is only invoked for the Quit AppleEvent / `NSApp.terminate`.
    /// It is NOT invoked for SIGTERM — and SIGTERM is exactly what the Homebrew cask's preflight
    /// sends (`pkill -x VPNBypass`) on every upgrade. Because `activeRoutes` lives only in memory
    /// and nothing reconciles against the kernel, an upgrade previously left the entire route set
    /// installed but *untracked*: the replacement binary started with an empty model, so no later
    /// cleanup could ever remove them. In VPN Only that strands the bypass-all
    /// catch-alls pointing at the local gateway — every subsequent connection silently leaves the
    /// tunnel while the app reports itself healthy. That is the most likely mechanism behind the
    /// "app is on but my public IP is my real one" reports.
    ///
    /// `signal(SIGTERM, SIG_IGN)` is required: the DispatchSource only observes the signal, it does
    /// not suppress the default terminate-immediately disposition.
    ///
    /// This does not cover `kill -9` or a crash — nothing in-process can. The durable fix is a
    /// helper-side journal swept at RunAtLoad, tracked separately.
    private func installTerminationSignalHandler() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    self.beginAppShutdown()
                    // Same safety deadline as the menu-quit path — this path previously had
                    // none, so a wedged helper XPC could hold the process open indefinitely.
                    let deadline = Self.quitDeadlineSeconds()
                    DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
                        RouteManager.shared.log(.warning, "Signal teardown exceeded \(Int(deadline))s — exiting")
                        exit(0)
                    }
                    await RouteManager.shared.cleanupOnQuit()
                    exit(0)
                }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }


    /// Shared first step of BOTH quit paths — menu quit and SIGTERM/SIGINT (the latter is
    /// what `brew upgrade`'s pkill delivers, and it previously performed none of these stops,
    /// so timers and monitors kept firing route work during teardown).
    @MainActor private func beginAppShutdown() {
        controlServer?.stop()
        networkMonitor?.cancel()
        refreshTimer?.invalidate()
        watchdogTimer?.invalidate()
        networkDebounceWorkItem?.cancel()
        RouteManager.shared.stopDNSRefreshTimer()
        RouteManager.shared.beginShutdown()
    }

    /// The teardown budget. Scales with tracked routes — but a quit that lands MID-APPLY
    /// reads a still-empty model while hundreds of routes are installing; that under-sized
    /// the budget to 8s once while 319 routes landed, so an in-flight apply floors it.
    @MainActor static func quitDeadlineSeconds() -> Double {
        if RouteManager.shared.isApplyingRoutes { return 60.0 }
        let trackedRouteCount = RouteManager.shared.activeRoutes.count
        return min(60.0, 8.0 + Double(trackedRouteCount) * 0.15)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Hide all UI immediately so quit feels instant
        NSApp.windows.forEach { $0.orderOut(nil) }

        // applicationShouldTerminate is delivered on the main thread.
        MainActor.assumeIsolated { beginAppShutdown() }

        // Clean up routes and hosts file on quit, then allow termination.
        //
        // The safety deadline has to scale with the work, not sit at a flat 8s. Teardown removes
        // one route per `/sbin/route` subprocess, and a normal config here installs 300+; at the
        // measured per-route cost that ran well past 8s, so the app replied "go ahead" and was
        // killed mid-teardown. Everything past the cut-off stayed installed — and because route
        // ownership lives only in this process's memory, the next launch started with an empty
        // model and could never remove it. In VPN Only the survivors can include the catch-alls,
        // whose own batch budget (10.5s) already exceeded the old cap on its own.
        //
        // Catch-alls are torn down first (see removeAllRoutes), so the most leak-relevant work is
        // done early; this budget is about not abandoning the remainder.
        let quitDeadline = MainActor.assumeIsolated { Self.quitDeadlineSeconds() }
        var didReply = false
        DispatchQueue.main.asyncAfter(deadline: .now() + quitDeadline) {
            guard !didReply else { return }
            didReply = true
            RouteManager.shared.log(.warning, "Quit teardown exceeded \(Int(quitDeadline))s — some routes may remain installed")
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
        let primaryInterface = path.availableInterfaces.first?.name
        let primaryChanged = primaryInterface != lastPrimaryInterface

        let isSignificantChange = statusChanged || typesChanged || namesChanged || primaryChanged
        
        if isSignificantChange {
            lastPathStatus = path.status
            lastInterfaceTypes = interfaceTypes
            lastInterfaceNames = interfaceNames
            lastPrimaryInterface = primaryInterface
            
            Task { @MainActor in
                let statusStr = path.status == .satisfied ? "connected" : "disconnected"
                let interfaceStr = interfaceNames.sorted().joined(separator: ", ")
                RouteManager.shared.log(.info, "Network change detected: \(statusStr) via \(interfaceStr)")
                
                RouteManager.shared.refreshStatus()
            }
        }
    }
    
    func startPeriodicRefresh() {
        refreshTimer = Timer.scheduledInCommonModes(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                RouteManager.shared.refreshStatus()
                self?.relaunchIfUpdatedOnDisk()
            }
        }
    }

    /// Restart into the new copy once an update has replaced this app's bundle (see
    /// AppUpdateRelauncher). Quitting goes through the normal path, so the routes this process
    /// installed are removed before the new copy starts and applies its own.
    @MainActor private func relaunchIfUpdatedOnDisk() {
        guard !isRelaunchingForUpdate, let launched = launchedExecutable,
              let executablePath = Bundle.main.executablePath else { return }
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return }

        let state = AppUpdateRelauncher.state(launched: launched, executablePath: executablePath) {
            AppUpdateRelauncher.bundleSignatureIsValid(atPath: bundlePath)
        }
        guard state == .replaced else { return }

        let command = AppUpdateRelauncher.relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: bundlePath)
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: command.executable)
        waiter.arguments = command.arguments
        do {
            try waiter.run()
        } catch {
            RouteManager.shared.log(.warning, "VPN Bypass was updated on disk, but the restart could not be scheduled: \(error.localizedDescription)")
            return
        }
        isRelaunchingForUpdate = true
        RouteManager.shared.log(.info, "VPN Bypass was updated on disk. Restarting to run the new version...")
        // Not `NSApp.terminate(nil)` right here. terminate answers .terminateLater and then spins
        // a nested run loop until the teardown replies, and that teardown runs on the main queue.
        // This method is called from a main-actor Task, which is a block of that same queue, and
        // the queue cannot drain while one of its own blocks is still on the stack: the quit
        // would wait for itself forever. The run loop calls its own blocks outside the queue.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
    
    // MARK: - Watchdog (Long-term Stability)
    
    /// Watchdog timer runs every 12 hours to ensure app stays healthy during long uptimes
    func startWatchdog() {
        let twelveHours: TimeInterval = 12 * 60 * 60  // 43200 seconds
        
        watchdogTimer = Timer.scheduledInCommonModes(withTimeInterval: twelveHours, repeats: true) { [weak self] _ in
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
        lastPrimaryInterface = nil
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
