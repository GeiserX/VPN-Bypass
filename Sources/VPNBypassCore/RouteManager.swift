// RouteManager.swift
// Core routing logic - manages VPN detection, routes, and hosts entries.

import Foundation
import Network
import AppKit
import UniformTypeIdentifiers

@MainActor
final class RouteManager: ObservableObject {
    static let shared = RouteManager()
    
    // MARK: - Published State
    
    @Published var isVPNConnected = false
    @Published var vpnInterface: String?
    @Published var vpnType: VPNType?
    @Published var localGateway: String?
    @Published var vpnGateway: String?
    @Published var activeRoutes: [ActiveRoute] = []
    /// Unique kernel route count (activeRoutes may have multiple entries per destination for multi-source tracking)
    var uniqueRouteCount: Int { Set(activeRoutes.map { $0.destination }).count }
    @Published var lastUpdate: Date?
    @Published var config: Config = Config()
    @Published var recentLogs: [LogEntry] = []
    @Published var currentNetworkSSID: String?
    @Published var routeVerificationResults: [String: RouteVerificationResult] = [:]
    @Published var isLoading = true
    @Published private(set) var isApplyingRoutes = false
    @Published var isConfigLoadFailed = false

    /// Which process owns each `utun`, as the helper last reported it. Cosmetic only: it names
    /// tunnels, and must never decide which one gets routed. Empty when the helper cannot be
    /// asked, in which case labelling falls back to the interface-prefix guess.
    private(set) var tunnelOwnersByInterface: [String: TunnelOwner] = [:]

    /// True once shutdown has begun. Checked by the operation gate (so no new route
    /// operation can start) and by the tracked batch-add wrapper (so an operation
    /// already past the gate cannot push more routes into the kernel mid-teardown).
    private(set) var isShuttingDown = false

    /// Kernel-visible destinations that may not (yet, or ever) be recorded in
    /// `activeRoutes`. Recorded BEFORE every batch add, so quit teardown can remove
    /// routes the in-memory model never got to track: the epoch guard deliberately
    /// skips the model append after preemption, which once left 93 kernel routes
    /// with no record anywhere (2026-08-07).
    var pendingKernelAdds: Set<String> = []

    /// Handle for the fire-and-forget background DNS refresh, so shutdown can cancel it.
    private var backgroundRefreshTask: Task<Void, Never>?
    @Published var lastDNSRefresh: Date?
    @Published var nextDNSRefresh: Date?
    @Published var isTestingProxy = false
    @Published var proxyTestResult: ProxyTestResult?
    
    struct ProxyTestResult {
        let success: Bool
        let message: String
    }
    
    // MARK: - Private
    
    private var dnsRefreshTimer: Timer?
    private var detectedDNSServer: String?  // User's real DNS (pre-VPN), detected at startup
    private var dnsCache: [String: String] = [:]  // Cache: domain -> first resolved IP (for hosts file)
    private var dnsDiskCache: [String: [String]] = [:]  // Persistent cache: domain -> all resolved IPs
    private var orphanedServiceDomains: [String: [String]] = [:]  // Deleted service name -> its domains (for hosts reconstruction)
    private(set) var routeEpoch: UInt64 = 0  // Incremented by removeAllRoutes — lets in-flight applies detect preemption
    private var gatewayDetectedAt: Date?
    private var lastInterfaceReroute: Date?
    /// A re-route (interface change or Tailscale profile change) that was NEEDED but
    /// couldn't run when it was detected — the route-operation gate was held (e.g. by a
    /// concurrent DNS refresh), the 10s cooldown was active, or no gateway/helper was
    /// ready yet. Latched here so the re-route is NEVER lost: once vpnInterface /
    /// lastTailscaleSelfFingerprint advance in checkVPNStatus the change condition can
    /// never re-fire, so this flag is the only thing that carries the need forward and
    /// closes the silent-leak window. Decided by the pure RerouteDecider; drained by
    /// scheduleRerouteRetry(). Cleared on a successful re-route and on VPN disconnect.
    var pendingReroute = false
    var pendingRerouteReason: String?
    private var lastTailscaleSelfFingerprint: String?
    /// Reconnect settle gate. The moment a VPN tunnel (re)appears is exactly when its client is
    /// most fragile — GlobalProtect re-checks its gateway route repeatedly for the first half
    /// minute after a restore, and a full apply fired into that window (hundreds of broadcast
    /// route events) knocked the tunnel straight back down, turning one external drop into a
    /// minutes-long flap loop (three drops in as many minutes, each seconds after our batch).
    /// Bypass routes are KEPT across a drop, so there is no urgency to re-apply: wait for the
    /// tunnel to hold before touching the kernel. A drop during the wait cancels the pending
    /// apply and counts a deferral, so a flap storm coalesces into ONE apply once things hold;
    /// after `ReconnectSettle.maxDeferrals` the delay shortens so we can never starve.
    private var reconnectSettleTask: Task<Void, Never>?
    private var reconnectDeferrals = 0
    /// First-seen timestamps for routes that dropped out of the desired set during an
    /// auto-triggered apply (DNS rotation, mostly). See `orphanGraceDecision`.
    private var orphanFirstSeen: [String: Date] = [:]
    
    
    /// Set once in init from the SAME directory as `configURL`, so it follows the under-test
    /// redirect. It used to be a computed property that always resolved to the real Application
    /// Support path, which meant every `swift test` run read — and via saveDNSCache could write —
    /// the developer's live DNS cache. `configURL` was already fixed for exactly this reason; this
    /// was the same hole in a sibling property that never got the same treatment.
    private let dnsCacheURL: URL
    
    /// Public accessor for UI to display detected DNS server
    var detectedDNSServerDisplay: String? {
        detectedDNSServer
    }
    
    // MARK: - Types (config model)
    // Config / RoutingMode / VPNType / ProxyConfig / DomainEntry / ServiceEntry now live at top
    // level in ConfigModel.swift (decoupled from this @MainActor class). These aliases preserve
    // the historical `RouteManager.X` spelling used across the codebase.
    typealias Config = VPNBypassCore.Config
    typealias RoutingMode = VPNBypassCore.RoutingMode
    typealias VPNType = VPNBypassCore.VPNType
    typealias ProxyConfig = VPNBypassCore.ProxyConfig
    typealias DomainEntry = VPNBypassCore.DomainEntry
    typealias ServiceEntry = VPNBypassCore.ServiceEntry
    
    struct ActiveRoute: Identifiable {
        let id = UUID()
        let destination: String
        let gateway: String
        let source: String // domain name or service name
        let timestamp: Date
    }
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
        
        enum LogLevel: String {
            case info = "INFO"
            case success = "SUCCESS"
            case warning = "WARNING"
            case error = "ERROR"
        }
    }
    
    // MARK: - Private
    
    let configURL: URL
    private var refreshTimer: Timer?
    
    private init() {
        // Isolate the test suite from the user's real config: under XCTest, point at a
        // throwaway temp dir so saveConfig() (reached via setRoutingMode / the control
        // surface in tests) can never clobber ~/Library/.../VPNBypass/config.json.
        // NSClassFromString("XCTestCase") is the reliable signal under `swift test`
        // (the XCTest framework is linked into the test binary but not the app); the
        // env var is Xcode-only, so it's just a belt-and-suspenders fallback.
        let appDir: URL
        let underTests = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if underTests {
            appDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("VPNBypassTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            appDir = appSupport.appendingPathComponent("VPNBypass", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("config.json")
        dnsCacheURL = appDir.appendingPathComponent("dns-cache.json")
    }
    
    // MARK: - Public API
    
    func loadConfig() {
        // Load DNS cache for faster startup / fallback
        loadDNSCache()
        
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            isConfigLoadFailed = false
            log(.info, "Config file absent, using default config")
            config = Config()
            // Config's DECODER is the only place that derives the Direct and primary-VPN
            // system routes, so a brand-new install — which never decodes anything — had an
            // empty Rules route picker for its whole first session and only healed on the
            // next launch. Seed the same two routes here.
            seedSystemRoutesIfEmpty()
            ensurePrimaryVPNRoute()
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            let loaded = try JSONDecoder().decode(Config.self, from: data)
            config = loaded
            isConfigLoadFailed = false
            seedSystemRoutesIfEmpty()
            ensurePrimaryVPNRoute()
            mergeBuiltInServices()
            log(.info, "Config loaded")
        } catch {
            isConfigLoadFailed = true
            log(.error, "Failed to load config from \(configURL.path): \(error.localizedDescription). Preserving file on disk.")
            // The latch below blocks every save and every route application, so without this
            // the menu bar shows a healthy app that quietly enforces nothing — the same trap
            // the helper-not-ready notification exists to close.
            NotificationManager.shared.notifyEnforcementFailed(
                reason: String(localized: "Your configuration file could not be read, so no routes are being enforced. It has been left untouched at ~/Library/Application Support/VPNBypass/config.json — repair it, or import a saved configuration from Settings.")
            )
        }
    }
    
    /// Merge built-in service definitions with the user's saved config.
    /// Preserves the user's enabled/disabled state while updating domains,
    /// ipRanges, and names from the latest source code definitions.
    /// Also adds any new built-in services that didn't exist when the user last saved.
    private func mergeBuiltInServices(autoSave: Bool = true) {
        let defaults = Config.defaultServices
        let savedById = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })
        let defaultById = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
        
        var merged: [ServiceEntry] = []
        var updated = 0
        var added = 0
        
        // Walk the default list to preserve ordering from source code
        for builtIn in defaults {
            if let saved = savedById[builtIn.id] {
                let domainsChanged = Set(saved.domains) != Set(builtIn.domains)
                let ipRangesChanged = Set(saved.ipRanges) != Set(builtIn.ipRanges)
                if domainsChanged || ipRangesChanged || saved.name != builtIn.name {
                    updated += 1
                }
                merged.append(ServiceEntry(
                    id: builtIn.id,
                    name: builtIn.name,
                    enabled: saved.enabled,
                    domains: builtIn.domains,
                    ipRanges: builtIn.ipRanges
                ))
            } else {
                added += 1
                merged.append(builtIn)
            }
        }
        
        // Keep any services from the saved config that aren't in defaults (future-proofing)
        for saved in config.services where defaultById[saved.id] == nil {
            merged.append(saved)
        }
        
        if updated > 0 || added > 0 {
            config.services = merged
            if autoSave {
                saveConfig()
            }
            if updated > 0 { log(.info, "Updated \(updated) built-in service(s) with latest definitions") }
            if added > 0 { log(.info, "Added \(added) new built-in service(s)") }
        } else if config.services.count != merged.count {
            config.services = merged
            if autoSave {
                saveConfig()
            }
        }
    }
    
    /// The local-hop secret every proxy listener demands, minted and persisted on first
    /// use so the listener and the generated exports agree on it across restarts.
    @discardableResult
    func ensureLocalProxySecret() -> String {
        if let existing = config.localProxySecret, !existing.isEmpty { return existing }
        let minted = Config.makeLocalProxySecret()
        config.localProxySecret = minted
        saveConfig()
        return minted
    }

    func saveConfig() {
        guard !isConfigLoadFailed else {
            log(.warning, "Config save blocked: config.json failed to load and is preserved on disk")
            return
        }
        do {
            try saveConfigThrowing()
        } catch {
            log(.error, "Failed to save configuration: \(error.localizedDescription)")
        }
    }

    /// - Parameter recoveringFromLoadFailure: set only by `importConfig`, which is replacing an
    ///   unreadable config.json. It bypasses the save block WITHOUT clearing the latch, so the
    ///   daily backup — which copies FROM the on-disk config.json — still skips itself and does
    ///   not overwrite the last known-good `config.json.bak` with the corruption being escaped.
    func saveConfigThrowing(recoveringFromLoadFailure: Bool = false) throws {
        guard recoveringFromLoadFailure || !isConfigLoadFailed else {
            log(.warning, "Config save blocked: config.json failed to load and is preserved on disk")
            throw NSError(domain: "VPNBypass", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Configuration save blocked due to load failure"])
        }

        // Daily backup - overwrite if older than 24 hours. Best-effort on purpose: the
        // backup is a convenience, and letting it fail the save would lose the user's
        // actual change over a stale copy.
        do {
            try createDailyBackupIfNeededThrowing()
        } catch {
            log(.warning, "Daily config backup skipped: \(error.localizedDescription)")
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let dir = configURL.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent("config.json.tmp-\(UUID().uuidString)")
        // Every throw below leaves the temp behind otherwise, and these accumulate in
        // ~/Library/Application Support/VPNBypass/ forever.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Create the temp file 0600 in one step. Writing first and chmod'ing after leaves a
        // window where a file holding localProxySecret and proxy passwords is umask-default
        // 0644 inside a 0755 directory. `replaceItemAt` then keeps the DESTINATION's mode,
        // not the source's, so the mode that matters is the one set after the replace.
        guard FileManager.default.createFile(
            atPath: tempURL.path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(domain: "VPNBypass", code: 1002,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the temporary config file"])
        }

        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: configURL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        log(.info, "Config saved")
    }

    /// Ensure Rules has a real, persisted route for the primary VPN, the way `Config.derive()`
    /// already does for every config that has been decoded from disk. A nil selector is the
    /// legacy representation of the same thing, so an existing "Corporate VPN" counts.
    ///
    /// Called only from `loadConfig()`. It used to run from the VPN-status path, which the
    /// 30s refresh timer drives (VPNBypassApp.swift:289) — so a user who deleted this route
    /// got it back, plus a config.json write, every half minute with no way to decline.
    @discardableResult
    func ensurePrimaryVPNRoute() -> Bool {
        guard !isConfigLoadFailed else { return false }
        let hasPrimaryVPN = config.routes.contains {
            $0.egress == .vpnDefault
                && ($0.vpnSelector == nil || $0.vpnSelector?.kind == .primary)
        }
        guard !hasPrimaryVPN else { return false }

        config.routes.append(Route(
            name: "Primary VPN",
            egress: .vpnDefault,
            vpnSelector: VPNSelector(kind: .primary)
        ))
        saveConfig()
        return true
    }

    /// Populate the two auto-created system routes (Direct + the primary VPN) when a config
    /// has none. Mirrors `Config.derive()`, which only ever runs inside `Config.init(from:)`.
    private func seedSystemRoutesIfEmpty() {
        guard config.routes.isEmpty else { return }
        let derived = Config.derive(
            domains: config.domains, services: config.services, mode: config.routingMode,
            inverseDomains: config.inverseDomains, proxy: config.proxyConfig
        )
        config.routes = derived.routes
        config.rules = derived.rules
        config.defaultRouteId = derived.defaultRouteId
    }
    
    private func createDailyBackupIfNeededThrowing() throws {
        guard !isConfigLoadFailed else { return }
        let backupURL = configURL.deletingLastPathComponent().appendingPathComponent("config.json.bak")
        
        // Check if backup exists and is less than 24 hours old
        if let attrs = try? FileManager.default.attributesOfItem(atPath: backupURL.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < 86400 {
            return // Backup is recent enough
        }
        
        // Create/overwrite backup safely
        if FileManager.default.fileExists(atPath: configURL.path) {
            let dir = configURL.deletingLastPathComponent()
            let tempBackupURL = dir.appendingPathComponent("config.json.bak.tmp-\(UUID().uuidString)")
            
            try FileManager.default.copyItem(at: configURL, to: tempBackupURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempBackupURL.path)
            
            let attrs = try FileManager.default.attributesOfItem(atPath: tempBackupURL.path)
            guard let permissions = attrs[.posixPermissions] as? NSNumber, permissions.uint16Value == 0o600 else {
                try? FileManager.default.removeItem(at: tempBackupURL)
                throw NSError(domain: "VPNBypass", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Failed to verify 0600 permissions on temporary backup file"])
            }

            if FileManager.default.fileExists(atPath: backupURL.path) {
                _ = try FileManager.default.replaceItemAt(backupURL, withItemAt: tempBackupURL)
            } else {
                try FileManager.default.moveItem(at: tempBackupURL, to: backupURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            log(.info, "Daily config backup created")
        }
    }
    
    // MARK: - DNS Disk Cache
    
    private func loadDNSCache() {
        // A missing cache is normal (first run) — stay silent. A present-but-corrupt
        // cache should surface, otherwise the fast-start / preserve-cached-IPs safety
        // nets that read it silently degrade with no way to notice.
        guard FileManager.default.fileExists(atPath: dnsCacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: dnsCacheURL)
            dnsDiskCache = try JSONDecoder().decode([String: [String]].self, from: data)
        } catch {
            log(.warning, "DNS cache unreadable/corrupt, ignoring: \(error.localizedDescription)")
        }
    }

    private func saveDNSCache() {
        do {
            let data = try JSONEncoder().encode(dnsDiskCache)
            try data.write(to: dnsCacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dnsCacheURL.path)
        } catch {
            log(.error, "Failed to persist DNS cache: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Import/Export Config
    
    func exportConfig() -> URL? {
        // Never write credentials into the shareable export (see sanitizedForExport).
        let exportData = ExportData(
            version: "2.0",
            exportDate: Date(),
            config: config.sanitizedForExport()
        )
        
        guard let data = try? JSONEncoder().encode(exportData) else {
            log(.error, "Failed to encode config for export")
            return nil
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let exportURL = tempDir.appendingPathComponent("VPNBypass-Config-\(formattedDate()).json")
        
        do {
            try data.write(to: exportURL)
            log(.success, "Config exported successfully")
            return exportURL
        } catch {
            log(.error, "Failed to write export file: \(error.localizedDescription)")
            return nil
        }
    }
    
    func importConfig(from url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let exportData = try JSONDecoder().decode(ExportData.self, from: data)

            // Save previous state for transactional rollback
            let previousConfig = config
            let previousLoadFailed = isConfigLoadFailed
            let previousDiskData: Data?
            let previousDiskPermissions: UInt16?
            if FileManager.default.fileExists(atPath: configURL.path) {
                previousDiskData = try Data(contentsOf: configURL)
                let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
                previousDiskPermissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            } else {
                previousDiskData = nil
                previousDiskPermissions = nil
            }

            config = exportData.config
            mergeBuiltInServices(autoSave: false)

            // Keep the latch SET across the write. Clearing it here to get past the save guard
            // also defeated the backup guard, so recovering from a corrupt config.json copied
            // that corruption over config.json.bak — destroying the user's only other copy with
            // the one action they take to recover. The latch is cleared once the write lands.
            do {
                try saveConfigThrowing(recoveringFromLoadFailure: true)
                isConfigLoadFailed = false
            } catch {
                // Rollback in-memory state
                config = previousConfig
                isConfigLoadFailed = previousLoadFailed

                // Roll back on-disk state, including restoring a previously missing file.
                do {
                    try restoreConfigOnDisk(data: previousDiskData, permissions: previousDiskPermissions)
                } catch {
                    log(.error, "Failed to restore previous config.json on disk: \(error.localizedDescription)")
                }

                log(.error, "Failed to persist imported config: \(error.localizedDescription)")
                return false
            }

            log(.success, "Config imported: \(exportData.config.domains.count) domains, \(exportData.config.services.filter { $0.enabled }.count) services enabled")

            // Reconcile live routes if VPN is connected
            if isVPNConnected && acquireRouteOperation() {
                Task {
                    defer { releaseRouteOperation() }
                    await removeAllRoutes()
                    await applyAllRoutesInternal(sendNotification: false)
                }
            }

            return true
        } catch {
            log(.error, "Failed to import config: \(error.localizedDescription)")
            return false
        }
    }

    private func restoreConfigOnDisk(data: Data?, permissions: UInt16?) throws {
        let fileManager = FileManager.default

        guard let data else {
            if fileManager.fileExists(atPath: configURL.path) {
                try fileManager.removeItem(at: configURL)
            }
            return
        }

        let directory = configURL.deletingLastPathComponent()
        let rollbackURL = directory.appendingPathComponent("config.json.rollback-\(UUID().uuidString)")
        // Never restore a looser mode than we enforce. A config that was somehow 0644 must
        // come back 0600, the same way every save tightens it (GHSA-gm4h-95p9-9w7v).
        let restoredPermissions: UInt16 = min(permissions ?? 0o600, 0o600)

        try data.write(to: rollbackURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: restoredPermissions], ofItemAtPath: rollbackURL.path)

        let attributes = try fileManager.attributesOfItem(atPath: rollbackURL.path)
        guard let actualPermissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              actualPermissions == restoredPermissions else {
            throw NSError(
                domain: "VPNBypass",
                code: 1004,
                userInfo: [NSLocalizedDescriptionKey: "Failed to verify restored config file permissions"]
            )
        }

        if fileManager.fileExists(atPath: configURL.path) {
            _ = try fileManager.replaceItemAt(configURL, withItemAt: rollbackURL)
        } else {
            try fileManager.moveItem(at: rollbackURL, to: configURL)
        }
        try fileManager.setAttributes([.posixPermissions: restoredPermissions], ofItemAtPath: configURL.path)
    }
    
    struct ExportData: Codable {
        let version: String
        let exportDate: Date
        let config: Config
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
    
    // MARK: - Process Helper
    
    /// Runs a process asynchronously on a background thread with timeout to prevent UI freezing
    private func runProcessAsync(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = 5.0
    ) async -> (output: String, exitCode: Int32)? {
        // Use dedicated queue to avoid GCD thread pool exhaustion
        await withCheckedContinuation { continuation in
            vpnBypassProcessQueue.async {
                let result = DNSResolver.runProcessSyncSafe(executablePath, arguments: arguments, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }
    
    // MARK: - Network Status

    func detectCurrentNetwork() async {
        // Get current WiFi SSID using helper with timeout
        guard let result = await runProcessAsync(
            "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport",
            arguments: ["-I"],
            timeout: 3.0
        ) else {
            return
        }
        
        let output = result.output
        
        for line in output.components(separatedBy: "\n") {
            if line.contains("SSID:") && !line.contains("BSSID") {
                let ssid = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if ssid != currentNetworkSSID {
                    let oldSSID = currentNetworkSSID
                    currentNetworkSSID = ssid
                    if oldSSID != nil {
                        log(.info, "Network changed: \(oldSSID ?? "none") → \(ssid)")
                    }
                }
                return
            }
        }
        
        // No WiFi connected
        if currentNetworkSSID != nil {
            currentNetworkSSID = nil
            log(.info, "WiFi disconnected")
        }
    }
    
    /// Single-flight gate for `checkVPNStatusCore`. The core awaits freely (detection passes,
    /// a 1.5s flap recheck, route teardown), and it is triggered from several sources at once
    /// during churn — the path monitor, the process poller, refreshStatus. Overlapping runs
    /// each captured the same `wasVPNConnected` and each committed the same transition:
    /// observed live as THREE "VPN disconnected" teardowns and three notifications for one
    /// disconnect, four seconds apart. One run at a time; anything that fires mid-run queues
    /// exactly one trailing re-check so a state change during the run is never missed.
    private var vpnStatusCheckInFlight = false
    private var vpnStatusRecheckQueued = false

    func checkVPNStatus() async {
        if vpnStatusCheckInFlight {
            vpnStatusRecheckQueued = true
            return
        }
        vpnStatusCheckInFlight = true
        defer { vpnStatusCheckInFlight = false }
        repeat {
            vpnStatusRecheckQueued = false
            await checkVPNStatusCore()
        } while vpnStatusRecheckQueued
    }

    private func checkVPNStatusCore() async {
        let wasVPNConnected = isVPNConnected
        let oldInterface = vpnInterface
        // Captured BEFORE re-detection below overwrites it, so a same-interface gateway change is
        // detectable at all — see `gatewayChanged` further down.
        let oldVPNGateway = vpnGateway
        let oldTailscaleFingerprint = lastTailscaleSelfFingerprint

        // Detect current network first
        await detectCurrentNetwork()

        // Use scutil to detect VPN interfaces with IPv4 addresses
        var (connected, interface, detectedType) = await detectVPNInterface()

        // Guard against transient VPN interface flaps: if VPN was connected but
        // now appears disconnected, recheck after a short delay before committing.
        // NWPathMonitor and ifconfig can momentarily miss the interface during
        // network transitions, causing spurious disconnect→reconnect notifications.
        if wasVPNConnected && !connected {
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let (recheckConnected, recheckInterface, recheckType) = await detectVPNInterface()
                if recheckConnected {
                    log(.info, "VPN flap suppressed — interface reappeared after recheck")
                    connected = recheckConnected
                    interface = recheckInterface
                    detectedType = recheckType
                }
            } catch {
                // Cancelled during the flap-recheck window — skip the recheck rather
                // than running it a beat early on a torn-down detection pass.
            }
        }

        isVPNConnected = connected
        vpnInterface = connected ? interface : nil
        vpnType = connected ? detectedType : nil
        await refreshTunnelOwners()
        let fetchedTailscaleFingerprint = isVPNConnected ? await currentTailscaleSelfFingerprintIfExitNode() : nil
        // Preserve last fingerprint if a single CLI read fails while VPN remains connected.
        let newTailscaleFingerprint = fetchedTailscaleFingerprint ?? (isVPNConnected ? oldTailscaleFingerprint : nil)
        lastTailscaleSelfFingerprint = newTailscaleFingerprint
        
        // Detect local gateway
        localGateway = await detectLocalGateway()
        gatewayDetectedAt = localGateway != nil ? Date() : nil

        // Detect VPN gateway (default route when VPN is connected)
        if connected {
            vpnGateway = await detectVPNGateway()
        } else {
            vpnGateway = nil
        }
        
        // Auto-apply routes when VPN connects (skip if already applying or recently applied)
        // Also skip if helper is not ready — no point attempting routes that will all fail
        if isVPNConnected && !wasVPNConnected && config.autoApplyOnVPN && !isLoading && !isApplyingRoutes && HelperManager.shared.isHelperInstalled && !isConfigLoadFailed {
            // Skip if routes were applied very recently (within 5 seconds) - prevents double-triggering
            if let lastUpdate = lastUpdate, Date().timeIntervalSince(lastUpdate) < 5 {
                log(.info, "Skipping duplicate route application (applied \(Int(Date().timeIntervalSince(lastUpdate)))s ago)")
            } else {
                // Settle gate: never fire the apply into the tunnel's fragile post-(re)connect
                // window — see reconnectSettleTask. The notification still goes out now (the
                // VPN *is* connected); only our kernel writes wait.
                let delay = ReconnectSettle.delay(deferrals: reconnectDeferrals,
                                                  hasInstalledRoutes: !activeRoutes.isEmpty)
                log(.success, "VPN connected via \(interface ?? "unknown") (\(detectedType?.rawValue ?? "unknown type")) — applying routes in \(Int(delay))s once the tunnel settles")
                NotificationManager.shared.notifyVPNConnected(interface: interface ?? "unknown")
                reconnectSettleTask?.cancel()
                reconnectSettleTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    await self.runSettledApply()
                }
            }
        }
        
        // VPN interface switched, OR the Tailscale profile changed while the utun
        // stayed the same — either way the installed routes are now pinned to the wrong
        // egress and must be re-applied. The route-operation gate (held by a concurrent
        // DNS refresh) or the 10s cooldown can block the re-route; when it does we must
        // NOT drop it — vpnInterface / lastTailscaleSelfFingerprint already advanced
        // above, so `interfaceChanged` can never re-fire, and a dropped re-route becomes
        // a silent VPN leak. Instead we LATCH it (pendingReroute) and drain it via a
        // bounded retry. RerouteDecider is the single, pure authority for the
        // needed? / run-now? / defer? decision. Guarded by isVPNConnected so a latched
        // re-route is never acted on after the VPN is gone (the disconnect block below
        // clears the latch on the transition).
        if isVPNConnected {
            let interfaceChanged = isVPNConnected && wasVPNConnected
                && interface != oldInterface && oldInterface != nil && interface != nil
            let tailscaleChanged = isVPNConnected && wasVPNConnected
                && interface == oldInterface
                && oldTailscaleFingerprint != nil && newTailscaleFingerprint != nil
                && oldTailscaleFingerprint != newTailscaleFingerprint
            // A local gateway AND a ready helper are both hard prerequisites for
            // actually installing routes; without either we can't re-route now but must
            // still latch (never drop) so it heals once they're available.
            let canApplyRoutes = localGateway != nil && HelperManager.shared.isHelperInstalled
            // Reason for logging; nil when this pass only drains an existing latch
            // (interfaceChanged / tailscaleChanged already false), in which case the
            // reason captured when the latch was set is reused.
            // Same interface, different next-hop. A tunnel that renegotiates keeps utunN but can
            // return on a new gateway; nothing else notices, because interfaceChanged compares
            // names and the DNS refresh only schedules destinations it does not already track. The
            // routes would stay pinned to a gateway that no longer exists.
            // Only a change of ADDRESS counts, never a change of NOTATION.
            //
            // detectVPNGateway returns the next-hop IP when it can read one and falls back to the
            // `iface:<name>` form when it cannot — so the same unchanged tunnel is reported as
            // "10.167.222.191" on one pass and "iface:utun9" on the next. Comparing those as
            // strings makes that flip look like a real gateway change, and the re-route it triggers
            // re-issues the ENTIRE route set: observed as `VPN gateway changed on utun9:
            // 10.167.222.191 → iface:utun9` followed immediately by `Adding 317 routes`, roughly
            // ten seconds after GlobalProtect reconnected — hundreds of route-change events fired
            // straight into the tunnel monitor that had just come up, which tore it down again.
            //
            // Both forms are only ever produced for the SAME interface, and `interface ==
            // oldInterface` is already required above, so when either side is the `iface:` fallback
            // the two are by construction the same gateway. Requiring both to be real addresses
            // means we act on a genuine next-hop change and ignore the notation flip.
            let gatewayChanged = isVPNConnected && wasVPNConnected
                && interface == oldInterface
                && Self.isRealGatewayChange(from: oldVPNGateway, to: vpnGateway)

            let rerouteReason: String? = interfaceChanged
                ? "VPN interface changed: \(oldInterface ?? "?") → \(interface ?? "?")"
                : (gatewayChanged
                    ? "VPN gateway changed on \(interface ?? "?"): \(oldVPNGateway ?? "?") → \(vpnGateway ?? "?")"
                    : (tailscaleChanged ? "Tailscale active account changed, refreshing routes" : nil))

            switch RerouteDecider.decide(
                interfaceChanged: interfaceChanged,
                tailscaleChanged: tailscaleChanged,
                pending: pendingReroute,
                isLoading: isLoading,
                isApplyingRoutes: isApplyingRoutes,
                cooldownActive: rerouteCooldownActive(),
                hasGateway: canApplyRoutes,
                gatewayChanged: gatewayChanged
            ) {
            case .reroute:
                if let rerouteReason { pendingRerouteReason = rerouteReason }
                log(.warning, pendingRerouteReason ?? "Re-routing through current gateway")
                await performReroute()
            case .latch:
                if let rerouteReason { pendingRerouteReason = rerouteReason }
                pendingReroute = true
                log(.info, "Re-route deferred (\(pendingRerouteReason ?? "pending")) — route op busy / cooldown / not ready; will retry until applied")
                scheduleRerouteRetry()
            case .none:
                break
            }
        }
        
        if !isVPNConnected && wasVPNConnected {
            log(.warning, "VPN disconnected (was: \(oldInterface ?? "unknown"))")
            // The tunnel dropped during a settle wait: cancel the pending apply (routes are
            // kept, nothing is lost) and count the deferral so a long flap storm eventually
            // shortens the wait instead of starving forever.
            if reconnectSettleTask != nil {
                reconnectSettleTask?.cancel()
                reconnectSettleTask = nil
                reconnectDeferrals += 1
                log(.info, "Settle-gated apply cancelled — VPN dropped during the wait (deferral \(reconnectDeferrals))")
            }
            cancelAllRetries()
            // Drop any latched re-route and stop its retry chain — there's nothing to
            // re-route once the VPN is gone. Prevents an orphaned retry Task and a
            // double-apply on the way out.
            pendingReroute = false
            pendingRerouteReason = nil
            rerouteRetryTask?.cancel()
            rerouteRetryTask = nil
            // Remove only what actually went stale.
            //
            // In Bypass mode every route egresses via the LOCAL gateway, so a VPN disconnect leaves
            // them all still correct — those destinations were already going direct and continue to.
            // Tearing the whole set down and rebuilding it on reconnect was the dominant source of
            // churn once a tunnel started flapping: 15 disconnects produced 8 full 342-route
            // rebuilds in one day here, and each rebuild fires hundreds of kernel route-change
            // events that the VPN client then reacts to — feeding the very instability that caused
            // the disconnect. Keeping the still-valid routes means a reconnect finds them already
            // correct and costs zero mutations.
            //
            // VPN Only keeps the full teardown: its catch-alls are leak-critical and its listed
            // destinations point at a gateway that is now gone, so there is nothing worth keeping.
            var keptCount = 0
            var failedCount = 0
            if config.routingMode == .bypass {
                let stale = Self.vpnBoundDestinations(
                    activeRoutes: activeRoutes,
                    localGateway: localGateway,
                    catchAlls: RouteCompiler.catchAllDestinations
                )
                if stale.isEmpty {
                    log(.info, "VPN gone; \(activeRoutes.count) bypass route(s) still egress the local gateway — keeping them")
                    keptCount = activeRoutes.count
                } else {
                    log(.info, "VPN gone; removing \(stale.count) VPN-bound route(s), keeping \(activeRoutes.count - stale.count) local-gateway route(s)")
                    let result = await removeRoutesBatchVia(stale)
                    let removed = Set(stale).subtracting(result.failedDestinations)
                    activeRoutes.removeAll { removed.contains($0.destination) }
                    failedCount = result.failedDestinations.count
                    keptCount = activeRoutes.count - failedCount
                }
            } else {
                await removeAllRoutes()
                // Whatever teardown retained is a genuine failed removal (see removeAllRoutes).
                failedCount = activeRoutes.count
            }
            routeVerificationResults.removeAll()
            lastTailscaleSelfFingerprint = nil
            vpnGateway = nil
            // Notify after cleanup so the notification reflects the ACTUAL state — and names
            // kept-by-design separately from failed-removal.
            NotificationManager.shared.notifyVPNDisconnected(wasInterface: oldInterface,
                                                             routesKept: keptCount,
                                                             routesFailed: failedCount)
        }
    }
    
    /// The settle-gated apply scheduled by checkVPNStatusCore. Every precondition is
    /// re-validated at fire time — the world may have moved during the wait. The cancellation
    /// re-check closes a supersede race: an old task that passed its post-sleep check right as
    /// a disconnect cancelled it must not run, and must not clear a newer task's reference.
    private func runSettledApply() async {
        guard !Task.isCancelled else { return }
        reconnectSettleTask = nil
        guard isVPNConnected, config.autoApplyOnVPN, !isLoading, !isApplyingRoutes,
              HelperManager.shared.isHelperInstalled else {
            log(.info, "Settle-gated apply skipped — preconditions changed during the wait")
            return
        }
        reconnectDeferrals = 0
        isLoading = true
        await applyAllRoutes(orphanGrace: true)
        isLoading = false
    }

    private func detectVPNInterface() async -> (connected: Bool, interface: String?, type: VPNType?) {
        // First check for specific VPN processes to help identify type
        let runningVPNType = await detectRunningVPNProcess()

        if let hint = runningVPNType {
            await MainActor.run { log(.info, "VPN process hint: \(hint.rawValue)") }
        }

        // Use ifconfig to detect VPN
        return await detectVPNViaIfconfig(hintType: runningVPNType)
    }
    
    /// Detect which VPN client process is running
    private func detectRunningVPNProcess() async -> VPNType? {
        guard let result = await runProcessAsync("/bin/ps", arguments: ["-eo", "comm"], timeout: 5.0) else {
            return vpnType  // Keep existing type if command fails
        }
        
        let output = result.output.lowercased()
        
        // Check for known VPN processes
        if output.contains("globalprotect") || output.contains("pangpa") || output.contains("pangps") {
            return .globalProtect
        }
        if output.contains("vpnagent") || output.contains("cisco") || output.contains("anyconnect") || output.contains("secureclient") {
            return .ciscoAnyConnect
        }
        if output.contains("openvpn") {
            return .openVPN
        }
        if output.contains("wireguard") || output.contains("wg-go") {
            return .wireGuard
        }
        if output.contains("forticlient") || output.contains("fortitray") || output.contains("fctservctl") {
            return .fortinet
        }
        if output.contains("zscaler") || output.contains("zstunnel") || output.contains("zsatunnel") ||
           output.contains("trptunnel") || output.contains("upmservicecontroller") {
            return .zscaler
        }
        if output.contains("cloudflare") || output.contains("warp-cli") || output.contains("warp-svc") {
            return .cloudflareWARP
        }
        if output.contains("pulsesecure") || output.contains("dsaccessservice") || output.contains("pulseuisvc") {
            return .pulseSecure
        }
        if output.contains("endpoint_security_vpn") || output.contains("tracsrvwrapper") ||
           output.contains("cpdaapp") || output.contains("cpefrd") {
            return .checkPoint
        }
        // Tailscale is handled separately via exit node detection
        
        return nil
    }
    
    private func detectVPNViaIfconfig(hintType: VPNType?) async -> (connected: Bool, interface: String?, type: VPNType?) {
        guard let result = await runProcessAsync("/sbin/ifconfig", timeout: 5.0) else {
            // Command failed/timed out - don't change VPN status (return current state)
            await MainActor.run { log(.warning, "ifconfig command failed/timed out") }
            return (isVPNConnected, vpnInterface, vpnType)
        }
        
        let output = result.output
        
        // Two-pass approach: collect ALL interfaces first, then find VPN
        // This is more robust than the single-pass approach that could miss interfaces
        struct InterfaceInfo {
            let name: String
            let ip: String
            let hasUpFlag: Bool
            let isVPN: Bool
            var isValidCorporateIP: Bool = false
        }
        
        var interfaces: [InterfaceInfo] = []
        var currentInterface: String?
        var currentHasUpFlag = false
        
        // First pass: collect interface info
        for line in output.components(separatedBy: "\n") {
            // New interface starts with interface name (no leading whitespace)
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") {
                currentInterface = line.components(separatedBy: ":").first
                currentHasUpFlag = line.contains("<UP,") || line.contains(",UP,") || line.contains(",UP>")
            }
            
            // Check for inet (IPv4) address
            if line.contains("inet ") && !line.contains("inet6") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet "), let iface = currentInterface {
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 2 {
                        let ip = parts[1]
                        interfaces.append(InterfaceInfo(
                            name: iface,
                            ip: ip,
                            hasUpFlag: currentHasUpFlag,
                            isVPN: isVPNInterface(iface)
                        ))
                    }
                }
            }
        }
        
        // Second pass: build the full candidate set, then choose deliberately.
        //
        // This used to return the FIRST interface that matched, in ifconfig order. Several tunnels
        // being up at once is the ordinary case, not a corner case — a corporate client alongside
        // Tailscale — and ifconfig order has nothing to do with which one carries traffic. Since
        // Tailscale's utun usually sorts before a corporate client's, it won that race whenever an
        // exit node made its address look like a VPN, and in VPN Only mode the catch-alls would
        // then be installed to escape the WRONG tunnel, sending corporate traffic direct.
        let tsIPs = await tailscaleSelfIPs()
        var candidates: [VPNCandidate] = []
        for i in interfaces.indices {
            let isValid = await isCorporateVPNIP(interfaces[i].ip)
            interfaces[i].isValidCorporateIP = isValid
            guard interfaces[i].isVPN else { continue }
            candidates.append(VPNCandidate(
                interface: interfaces[i].name,
                isUp: interfaces[i].hasUpFlag,
                isTunnel: true,
                isCorporateAddress: isValid,
                isTailscale: tsIPs.contains(interfaces[i].ip)
            ))
        }

        let defaultRouteInterface = await currentDefaultRouteInterface()

        // Resolve the user's pin, if any. utun indices renumber across reconnects, so when the
        // pinned NAME is gone but a product label was stored, re-resolve by label against the
        // live links — the same durable-label strategy ifaceGateway uses for route pins.
        var pin = config.pinnedVPNInterface
        if let pinned = pin, !candidates.contains(where: { $0.interface == pinned }),
           let hint = config.pinnedVPNProductHint, !hint.isEmpty {
            let links = await listVPNLinks()
            if let relabelled = links.first(where: { !$0.isTailscale && $0.label == hint }) {
                await MainActor.run {
                    log(.info, "Pinned tunnel \(pinned) is gone; re-resolved by label '\(hint)' to \(relabelled.interface)")
                }
                pin = relabelled.interface
                config.pinnedVPNInterface = relabelled.interface
            }
        }

        let selected = VPNInterfaceSelector.select(
            candidates: candidates,
            defaultRouteInterface: defaultRouteInterface,
            current: vpnInterface,
            pinnedInterface: pin
        )

        // Say so when the pin and reality disagree — a pin must never silently change what
        // the app acts on relative to what the user believes.
        if let pinned = pin, let selected, selected != pinned {
            await MainActor.run {
                log(.warning, "Pinned tunnel \(pinned) is not eligible right now — acting on \(selected) (automatic)")
            }
        } else if let pinned = pin, selected == nil {
            await MainActor.run {
                log(.warning, "Pinned tunnel \(pinned) is not available and no other VPN is eligible")
            }
        }

        if let selected {
            if candidates.filter({ $0.isUp && $0.isCorporateAddress && !$0.isTailscale }).count > 1 {
                let all = candidates.map(\.interface).joined(separator: ", ")
                await MainActor.run {
                    log(.info, "Multiple tunnels up (\(all)) — using \(selected)" +
                        (defaultRouteInterface == selected ? " (carries the default route)" : ""))
                }
            }
            let type = hintType ?? detectVPNTypeFromInterface(selected)
            return (true, selected, type)
        }

        // Debug: log what we found if no VPN detected
        if !candidates.isEmpty {
            let summary = candidates.map {
                "\($0.interface) up=\($0.isUp) corp=\($0.isCorporateAddress) tailscale=\($0.isTailscale)"
            }.joined(separator: ", ")
            await MainActor.run { log(.info, "VPN candidates (none matched): \(summary)") }
        }

        return (false, nil, nil)
    }
    
    /// Which interface the default route currently exits through, or nil if unreadable.
    /// This is the only direct evidence of which tunnel is actually carrying traffic.
    func currentDefaultRouteInterface() async -> String? {
        guard let result = await runProcessAsync("/sbin/route", arguments: ["-n", "get", "default"], timeout: 5.0) else {
            return nil
        }
        return VPNInterfaceSelector.parseDefaultRouteInterface(result.output)
    }

    /// Check if interface name suggests it's a VPN interface
    private func isVPNInterface(_ iface: String) -> Bool {
        // Common VPN interface prefixes
        let vpnPrefixes = [
            "utun",      // Universal TUN - used by most VPNs on macOS
            "ipsec",     // IPSec VPN
            "ppp",       // Point-to-Point Protocol
            "gpd",       // GlobalProtect specific
            "tun",       // Generic TUN
            "tap",       // TAP interface
            "feth",      // Fortinet ethernet
            "zt"         // ZeroTier (sometimes used with VPNs)
        ]
        
        return vpnPrefixes.contains { iface.hasPrefix($0) }
    }
    
    /// Try to detect VPN type from interface characteristics
    /// Refresh the tunnel→owner map from the helper. Never clears a good map on a failed
    /// call: an empty reply means "could not ask", and forgetting who owns a tunnel would make
    /// labels flicker between polls.
    private func refreshTunnelOwners() async {
        let owners = await HelperManager.shared.tunnelOwners()
        guard !owners.isEmpty else { return }
        tunnelOwnersByInterface = Dictionary(owners.map { ($0.interface, $0) },
                                             uniquingKeysWith: { first, _ in first })
    }

    private func detectVPNTypeFromInterface(_ iface: String) -> VPNType {
        // Ask the OS who owns the tunnel before guessing from its name. Several product labels
        // are already VPNType raw values, so a recognised owner names the type outright; the
        // mesh VPNs have no case and stay .unknown, but their display label is still correct.
        if let owner = tunnelOwnersByInterface[iface],
           let label = TunnelOwnership.productLabel(processName: owner.processName,
                                                    executablePath: owner.executablePath),
           let known = VPNType(rawValue: label) {
            return known
        }

        // GlobalProtect typically uses gpd0 or specific utun
        if iface.hasPrefix("gpd") {
            return .globalProtect
        }
        
        // Generic fallback
        return .unknown
    }
    
    // MARK: - Multi-VPN link enumeration (Slice 4)

    /// One live VPN-like tunnel, for the multi-VPN route picker + System Routes UI.
    struct VPNLink: Identifiable, Equatable {
        let interface: String
        let addresses: [String]
        let label: String
        let isTailscale: Bool   // the Tailscale utun — NOT offered as a "VPN" egress
        var id: String { interface }
    }

    /// Enumerate EVERY live tunnel (utun/ipsec/ppp/… that is UP and has an inet
    /// address), attributed best-effort. Purely additive to the single-VPN detection
    /// (`vpnInterface`/`vpnType`) that classic modes rely on — that path is untouched.
    /// The Tailscale utun is flagged so it isn't offered as a plain VPN egress
    /// (Tailscale egress has its own peer-proxy route type).
    /// A tunnel seen at some point on this machine. Kept so a route or a pin can name a VPN
    /// that is not connected at this moment — live enumeration only ever reports tunnels that
    /// are UP, which made it impossible to pre-configure a VPN you were not currently using.
    struct RememberedLink: Codable, Equatable, Identifiable {
        let interface: String
        let label: String
        var id: String { interface }
    }

    /// Live tunnels merged with previously-seen ones (deduplicated, live first). `isLive`
    /// tells the UI which are connected right now.
    func selectableVPNLinks() async -> [(link: RememberedLink, isLive: Bool)] {
        let live = await listVPNLinks().filter { !$0.isTailscale }
        var out = live.map { (RememberedLink(interface: $0.interface, label: $0.label), true) }
        // Record what we just saw, so it stays offerable after the VPN disconnects.
        var remembered = config.rememberedVPNLinks
        for l in live where !remembered.contains(where: { $0.interface == l.interface && $0.label == l.label }) {
            remembered.removeAll { $0.interface == l.interface }
            remembered.append(RememberedLink(interface: l.interface, label: l.label))
        }
        if remembered != config.rememberedVPNLinks {
            config.rememberedVPNLinks = remembered
            saveConfig()
        }
        for r in remembered where !out.contains(where: { $0.0.interface == r.interface }) {
            out.append((r, false))
        }
        return out
    }

    /// Everything the coexistence diagnostics card shows, gathered in one pass.
    struct CoexistenceSnapshot: Equatable {
        let links: [VPNLink]
        let selectedInterface: String?
        let defaultRouteInterface: String?
        /// Kernel routes carrying OUR ownership tag (RTF_PROTO1) — ground truth of what this
        /// app currently owns, read silently from the table itself.
        let taggedRouteCount: Int
    }

    /// On-demand only — never call from a timer. `listVPNLinks` spawns `ifconfig` and
    /// `tailscale status`, which the hot paths deliberately avoid (see the needsLinks guard).
    func coexistenceSnapshot() async -> CoexistenceSnapshot {
        let links = await listVPNLinks()
        let defaultIface = await currentDefaultRouteInterface()
        let tagged = RouteKernel.currentTable()?.filter { $0.isOurs }.count ?? 0
        return CoexistenceSnapshot(links: links,
                                   selectedInterface: vpnInterface,
                                   defaultRouteInterface: defaultIface,
                                   taggedRouteCount: tagged)
    }

    func listVPNLinks() async -> [VPNLink] {
        guard let result = await runProcessAsync("/sbin/ifconfig", timeout: 5.0) else { return [] }

        // Pure parse of the ifconfig text (order + UP flag + inet addresses + Tailscale
        // marking) is delegated to IfconfigParser; only the labelling below needs live
        // actor state (vpnInterface/vpnType), and only UP interfaces with an address are
        // offered as egresses.
        let tsIPs = await tailscaleSelfIPs()
        let parsed = IfconfigParser.parse(result.output, tailscaleIPs: tsIPs, isVPNInterface: { self.isVPNInterface($0) })

        var links: [VPNLink] = []
        for p in parsed {
            guard p.isUp, !p.addresses.isEmpty else { continue }
            let label: String
            if let owner = tunnelOwnersByInterface[p.interface] {
                // The kernel knows who created this tunnel; that beats every heuristic below,
                // and is the only thing that can name a mesh VPN like NetBird at all.
                label = TunnelOwnership.displayLabel(for: owner)
            } else if p.isTailscale {
                label = "Tailscale"
            } else if vpnInterface == p.interface, let t = vpnType {
                label = t.rawValue
            } else {
                let t = detectVPNTypeFromInterface(p.interface)
                label = t == .unknown ? "VPN (\(p.interface))" : t.rawValue
            }
            links.append(VPNLink(interface: p.interface, addresses: p.addresses, label: label, isTailscale: p.isTailscale))
        }
        return links
    }

    /// The current node's Tailscale IPs (so we can spot which utun is Tailscale's).
    private func tailscaleSelfIPs() async -> Set<String> {
        guard let json = await readTailscaleStatusJSON() else { return [] }
        if let selfNode = json["Self"] as? [String: Any], let ips = selfNode["TailscaleIPs"] as? [String] {
            return Set(ips)
        }
        if let ips = json["TailscaleIPs"] as? [String] { return Set(ips) }
        return []
    }

    /// Resolve a route's VPN selector to a helper gateway token for RouteCompiler:
    /// nil (the primary VPN ⇒ no kernel route, unchanged) or `"iface:utunX"` for a
    /// specific, currently-live, non-Tailscale tunnel. Returns nil (the route falls
    /// back to the default) if the pinned tunnel is gone, or refuses if it resolves to
    /// the Tailscale utun. Pure w.r.t. `links` (pass them in) so it's unit-testable.
    func ifaceGateway(for route: Route, links: [VPNLink]) -> String? {
        guard route.egress == .vpnDefault, let sel = route.vpnSelector, sel.kind == .interface else {
            return nil   // primary VPN (or a non-VPN route) — no kernel route
        }
        // Prefer the durable product label over the volatile utun index: macOS
        // renumbers utun indices across VPN reconnects/reboots, so a bare-index match
        // can silently pin a *different* tunnel than the one the user picked. When a
        // product hint exists we trust it first, and only accept an index-only match if
        // that index isn't currently a *different* named product.
        let match: VPNLink?
        if let hint = sel.productHint, !hint.isEmpty {
            // A label is "generic/unknown" when the app couldn't name the product — the
            // "VPN (utunX)" fallback or the "Unknown VPN" type (see listVPNLinks). Such a
            // link is safe to accept on an index-only match; one that clearly names some
            // OTHER product is the wrong tunnel and must not be hijacked.
            let isGenericLabel: (VPNLink) -> Bool = { link in
                link.label.hasPrefix("VPN (") || link.label == VPNType.unknown.rawValue
            }
            match = links.first(where: { $0.interface == sel.interfaceName && $0.label == hint })  // same product AND index — strongest
                ?? links.first(where: { $0.label == hint })                                         // same product, index renumbered — the fix
                ?? links.first(where: { $0.interface == sel.interfaceName && isGenericLabel($0) })  // index only, and not a different named product
        } else {
            match = links.first(where: { $0.interface == sel.interfaceName })  // productless pin — the index is the only signal
        }
        guard let link = match else {
            log(.warning, "Route '\(route.name)': its pinned VPN (\(sel.interfaceName ?? sel.productHint ?? "?")) isn't up — falling back to the default route.")
            return nil
        }
        if link.isTailscale {
            log(.warning, "Route '\(route.name)': can't target the Tailscale interface as a VPN egress — use a Tailscale Peer route instead.")
            return nil
        }
        return "iface:\(link.interface)"
    }

    /// Check if IP is likely a corporate VPN (not Tailscale mesh, not localhost, etc.)
    /// (CGNAT disambiguation — Tailscale vs Zscaler/WARP — is done by classifyCGNATAddress,
    /// not by the process hint: a machine-wide process match cannot attribute an ADDRESS.)
    private func isCorporateVPNIP(_ ip: String) async -> Bool {
        let parts = ip.components(separatedBy: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]) else {
            return false
        }
        
        // Skip localhost
        if first == 127 { return false }
        
        // Skip link-local
        if first == 169 && second == 254 { return false }
        
        // CGNAT range (100.64.0.0/10 = 100.64-127.x.x)
        // Shared by Tailscale, Zscaler, Cloudflare WARP, and other VPNs.
        // Always check if this specific IP belongs to Tailscale first —
        // Tailscale mesh-only (no exit node) should NOT be treated as corporate VPN.
        // Any non-Tailscale CGNAT IP on a utun interface is virtually always a VPN
        // (Zscaler, WARP, etc.) so we accept it without requiring a process hint.
        // This fixes detection when VPN process names don't match known patterns (#18).
        if first == 100 && second >= 64 && second <= 127 {
            // CGNAT (100.64/10) is shared ground: Tailscale, Zscaler and Cloudflare WARP all live
            // here, so an address alone proves nothing and we have to ask Tailscale directly.
            //
            // FAIL CLOSED when that question cannot be answered. This used to collapse two very
            // different outcomes into one: `isTailscaleIP` returns false both when the address is
            // confirmed NOT Tailscale's and when the status query could not run at all (CLI absent,
            // or the 3s subprocess timeout hit — and it is queried on every status pass with no
            // memoisation, so load is exactly when it fails). Both fell through to "accept as
            // corporate VPN", meaning a failed lookup silently promoted Tailscale's own tunnel to
            // being treated as the corporate VPN — after which this app would re-route around a
            // mesh network it has no business touching, and flip-flop between the two tunnels as
            // the answer changed from poll to poll.
            //
            // Claiming another tool's tunnel is never the safe default. If we cannot prove a CGNAT
            // address is not Tailscale's, we decline it.
            switch await classifyCGNATAddress(ip) {
            case .tailscale:
                // Tailscale is only "the VPN" when it is actually carrying traffic as an exit node;
                // in ordinary mesh mode it must be left entirely alone.
                return await isTailscaleExitNodeActive()
            case .notTailscale:
                // Confirmed a different CGNAT VPN (Zscaler, WARP) — that one really is the tunnel.
                return true
            case .undetermined:
                log(.warning, "Could not determine whether \(ip) belongs to Tailscale — not treating it as the VPN")
                return false
            }
        }
        
        // Corporate VPNs typically use private ranges
        if first == 10 { return true }
        if first == 172 && second >= 16 && second <= 31 { return true }
        if first == 192 && second == 168 { return true }
        
        return false
    }

    /// Returns a stable fingerprint of the active local Tailscale identity.
    /// Fingerprint is available only when Tailscale exit node is online.
    private func currentTailscaleSelfFingerprintIfExitNode() async -> String? {
        guard let json = await readTailscaleStatusJSON() else {
            return nil
        }
        
        guard let exitNodeStatus = json["ExitNodeStatus"] as? [String: Any],
              exitNodeStatus["Online"] as? Bool == true,
              let selfStatus = json["Self"] as? [String: Any] else {
            return nil
        }
        
        let id = String(describing: selfStatus["ID"] ?? "")
        let userID = String(describing: selfStatus["UserID"] ?? "")
        let dnsName = String(describing: selfStatus["DNSName"] ?? "")
        let ips = (selfStatus["TailscaleIPs"] as? [String] ?? []).sorted().joined(separator: ",")
        let fingerprint = [id, userID, dnsName, ips].joined(separator: "|")
        
        return fingerprint == "|||" ? nil : fingerprint
    }
    
    /// Check if this IP is the local Tailscale node's address
    /// True only when the VPN's next-hop ADDRESS genuinely changed — never when its NOTATION did.
    ///
    /// Callers must already have established that the interface is unchanged.
    ///
    /// `detectVPNGateway` reports the next-hop IP when it can read one and falls back to the
    /// `iface:<name>` form when it cannot, so an unchanged tunnel alternates between
    /// "10.167.222.191" and "iface:utun9" from pass to pass. Treating that as a change triggers a
    /// re-route that re-issues the entire route set — observed live as 317 route writes ten seconds
    /// after GlobalProtect reconnected, which tore the freshly-established tunnel down again.
    ///
    /// Since both forms describe the same interface, and the caller has already required the
    /// interface to be unchanged, either side being the fallback form means the gateway is by
    /// construction the same. Only two real addresses can express a real change.
    nonisolated static func isRealGatewayChange(from old: String?, to new: String?) -> Bool {
        guard let old, let new else { return false }
        guard !old.hasPrefix("iface:"), !new.hasPrefix("iface:") else { return false }
        return old != new
    }

    /// Whether a CGNAT (100.64/10) address belongs to Tailscale — keeping "could not tell" DISTINCT
    /// from "confirmed it does not".
    ///
    /// That distinction is the entire point. Collapsing the two is what allowed a failed status
    /// query to promote Tailscale's own tunnel to "corporate VPN" (see isCorporateVPNIP).
    enum CGNATIdentity: Equatable { case tailscale, notTailscale, undetermined }

    /// Who owns a CGNAT address, decided from the only two things we can observe: whether
    /// Tailscale is running on this machine at all, and what its status query said if it
    /// answered.
    ///
    /// The third input is the whole point. "The status query did not answer" used to be the
    /// only negative signal, and it was reached BOTH when Tailscale could not be asked AND
    /// when there is no Tailscale here to ask — the CLI lookup only tries paths that exist.
    /// So on a machine with no Tailscale, every 100.64/10 tunnel was declined as
    /// undetermined, and NetBird / Netmaker / Twingate / self-hosted WireGuard meshes were
    /// never detected at all (#99).
    ///
    /// A machine with no Tailscale process cannot own a Tailscale address. That is a
    /// definitive answer, not an unknown. When Tailscale IS running and the query still
    /// could not answer, we keep failing closed exactly as before — claiming another tool's
    /// tunnel is never the safe default (#61).
    nonisolated static func classifyCGNAT(
        tailscaleRunning: Bool,
        statusAnswered: Bool,
        statusClaimsAddress: Bool
    ) -> CGNATIdentity {
        if statusAnswered { return statusClaimsAddress ? .tailscale : .notTailscale }
        return tailscaleRunning ? .undetermined : .notTailscale
    }

    private func classifyCGNATAddress(_ ip: String) async -> CGNATIdentity {
        let json = await readTailscaleStatusJSON()
        let claims: Bool = {
            guard let json else { return false }
            if let selfStatus = json["Self"] as? [String: Any],
               let selfIPs = selfStatus["TailscaleIPs"] as? [String],
               selfIPs.contains(ip) {
                return true
            }
            if let topLevelIPs = json["TailscaleIPs"] as? [String],
               topLevelIPs.contains(ip) {
                return true
            }
            return false
        }()
        // Only pay for the process scan when the status query came back empty — on a machine
        // with a working Tailscale CLI this costs nothing.
        let running = json != nil ? true : await isTailscaleProcessRunning()
        return Self.classifyCGNAT(
            tailscaleRunning: running, statusAnswered: json != nil, statusClaimsAddress: claims
        )
    }

    /// Whether any Tailscale process is live, across all three macOS distributions:
    /// `tailscaled` (open source / Homebrew), `io.tailscale.ipn.macsys.*` (standalone app)
    /// and `io.tailscale.ipn.macos.*` (App Store). Deliberately a process check rather than a
    /// file check: the App Store build ships no CLI at any of `tailscaleCLIPaths`, and a
    /// leftover CLI can outlive an uninstalled Tailscale. `ps` reports processes owned by
    /// root without any privilege of our own, which is what makes this workable — every one
    /// of these daemons runs as uid 0.
    private func isTailscaleProcessRunning() async -> Bool {
        let result = await runProcessAsync("/bin/ps", arguments: ["-eo", "comm"], timeout: 5.0)
        return Self.tailscaleAppearsRunning(psOutput: result?.output, psExitCode: result?.exitCode)
    }

    /// Read a process listing for any sign of Tailscale, failing CLOSED on a bad read.
    ///
    /// "ps did not mention Tailscale" is only a negative when ps actually succeeded. A listing
    /// that was truncated, killed or timed out mentions nothing either, and treating that as
    /// "Tailscale is absent" would let an unverified CGNAT tunnel — possibly Tailscale's own —
    /// be adopted as the corporate VPN. So a nil result or a nonzero exit means "could not
    /// look", which is reported as running and keeps the caller on the undetermined path.
    nonisolated static func tailscaleAppearsRunning(psOutput: String?, psExitCode: Int32?) -> Bool {
        guard let psOutput, psExitCode == 0 else { return true }
        return psOutput.lowercased().contains("tailscale")
    }

    private func isTailscaleIP(_ ip: String) async -> Bool {
        guard let json = await readTailscaleStatusJSON() else {
            return false
        }
        
        if let selfStatus = json["Self"] as? [String: Any],
           let selfIPs = selfStatus["TailscaleIPs"] as? [String],
           selfIPs.contains(ip) {
            return true
        }
        
        if let topLevelIPs = json["TailscaleIPs"] as? [String],
           topLevelIPs.contains(ip) {
            return true
        }
        
        return false
    }
    
    /// Check if Tailscale is using an exit node (routing all traffic through Tailscale)
    private func isTailscaleExitNodeActive() async -> Bool {
        guard let json = await readTailscaleStatusJSON() else {
            return false
        }
        
        // Check ExitNodeStatus - if present and online, we're using exit node
        if let exitNodeStatus = json["ExitNodeStatus"] as? [String: Any],
           exitNodeStatus["Online"] as? Bool == true {
            return true
        }
        
        return false
    }
    
    /// Known Tailscale CLI locations (Homebrew, standalone, and the App bundle).
    nonisolated static let tailscaleCLIPaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    ]

    /// Read tailscale status JSON (self only, no peers) from any known CLI path.
    private func readTailscaleStatusJSON() async -> [String: Any]? {
        for path in Self.tailscaleCLIPaths where FileManager.default.fileExists(atPath: path) {
            guard let result = await runProcessAsync(path, arguments: ["status", "--json", "--self", "--peers=false"], timeout: 3.0) else {
                continue
            }
            if let jsonData = result.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                return json
            }
        }
        return nil
    }
    
    /// Called from Refresh button - sends notification
    func refreshRoutes() {
        guard HelperManager.shared.isHelperInstalled else {
            log(.error, "Cannot refresh routes: helper not ready (\(HelperManager.shared.helperState.statusText))")
            // The most prominent button in the menu must never fail silently — this was a
            // click that did nothing, with the only evidence in a log nobody reads.
            NotificationManager.shared.notifyEnforcementFailed(
                reason: String(localized: "Can't refresh: the privileged helper is not running. Open Settings → General to repair it.")
            )
            return
        }
        Task {
            await detectAndApplyRoutesAsync(sendNotification: true)
        }
    }
    
    /// Detects VPN/network state for display only, without applying or mutating
    /// any routes. Used when the privileged helper is not ready so the UI can
    /// show real status instead of hanging on the "Setting Up..." spinner.
    ///
    /// Startup-only: this deliberately runs without a ready helper to refresh
    /// display state. It must NEVER apply routes or touch /etc/hosts — all
    /// mutation stays gated on `HelperManager.shared.isHelperInstalled`.
    ///
    /// The detect sequence below mirrors the one in `detectAndApplyRoutesAsync()`;
    /// keep them in sync if VPN/gateway detection changes.
    func detectVPNStateOnly() async {
        await detectCurrentNetwork()
        let (connected, interface, detectedType) = await detectVPNInterface()
        isVPNConnected = connected
        vpnInterface = connected ? interface : nil
        vpnType = connected ? detectedType : nil
        localGateway = await detectLocalGateway()
        gatewayDetectedAt = localGateway != nil ? Date() : nil
        isLoading = false
        log(.info, "VPN state detected (display only): connected=\(connected), interface=\(interface ?? "none")")
    }

    func detectAndApplyRoutesAsync(sendNotification: Bool = false) async {
        guard !isConfigLoadFailed else {
            isLoading = false
            log(.warning, "Config failed to load — enforcing nothing, and removing anything this app left behind")
            // The latch blocks APPLY, never TEARDOWN. This method is the only caller of the
            // no-VPN startup sweep (:1535), which is what heals a killed previous run's
            // leftovers — VPN Only's 0.0.0.0/1 + 128.0.0.0/1 catch-alls included. Returning
            // early here left those in the kernel with nothing able to remove them, so an
            // unreadable config.json turned a recoverable state into a broken network.
            if HelperManager.shared.isHelperInstalled {
                await startupSweepIfNeeded(desired: [])
            }
            return
        }
        isLoading = true
        log(.info, "Starting VPN detection and route application...")
        
        // Detect user's DNS server (respects pre-VPN DNS configuration)
        await detectUserDNSServer()
        
        // Detect current network
        await detectCurrentNetwork()
        
        // Detect VPN interface
        let (connected, interface, detectedType) = await detectVPNInterface()
        isVPNConnected = connected
        vpnInterface = connected ? interface : nil
        vpnType = connected ? detectedType : nil
        
        log(.info, "VPN detection result: connected=\(connected), interface=\(interface ?? "none")")
        
        // Detect local gateway
        localGateway = await detectLocalGateway()
        log(.info, "Gateway detected: \(localGateway ?? "none")")

        // Detect VPN gateway (needed for VPN Only mode)
        if connected {
            vpnGateway = await detectVPNGateway()
            log(.info, "VPN gateway detected: \(vpnGateway ?? "none")")
        } else {
            vpnGateway = nil
        }

        // Check helper status
        log(.info, "Helper installed: \(HelperManager.shared.isHelperInstalled)")

        // Apply routes if VPN is connected
        if isVPNConnected && localGateway != nil {
            log(.success, "VPN detected via \(interface ?? "unknown") (\(detectedType?.rawValue ?? "unknown")), applying routes...")
            
            // Fast path: if we have DNS cache, apply instantly then refresh in background
            if !dnsDiskCache.isEmpty {
                log(.info, "Using cached DNS for instant startup...")
                let cacheApplied = await applyRoutesFromCache()
                isLoading = false
                if cacheApplied {
                    log(.info, "Routes applied from cache. Refreshing DNS in background...")
                }
                
                // Background refresh: re-resolve DNS and update routes if changed.
                // The handle is stored so beginShutdown() can cancel it — unowned, this
                // task once raced quit teardown and re-added 93 routes after removal.
                backgroundRefreshTask = Task.detached { [weak self] in
                    await self?.backgroundDNSRefresh(sendNotification: sendNotification)
                }
            } else {
                // No cache: do full DNS resolution (first run)
                if sendNotification {
                    await applyAllRoutesWithNotification()
                } else {
                    await applyAllRoutes()
                }
                isLoading = false
                log(.info, "Startup complete. Routes: \(activeRoutes.count)")
            }
        } else if !isVPNConnected {
            log(.info, "No VPN connection detected")
            // With no VPN there is nothing this app should be routing — remove ANY tagged
            // leftovers from a crashed/killed previous run, catch-alls included. This is the
            // path that heals the "app off, public IP still wrong" report class on its own.
            await startupSweepIfNeeded(desired: [])
            isLoading = false
        } else if localGateway == nil {
            log(.error, "Could not detect local gateway")
            isLoading = false
        }

        // P1: start/stop proxy-route listeners to match config (no-op without proxy routes).
        await reconcileProxyListeners()
    }
    
    func refreshStatus() {
        Task {
            await checkVPNStatus()
            // After, not before: checkVPNStatus may itself re-route, and this only has to
            // catch what the kernel dropped without any signal the app can otherwise see.
            await reconcileMissingRoutes()
        }
    }
    
    /// True when the desired route set (destination+gateway pairs) already
    /// matches the active set, so a re-apply would be pure churn. forceReassert
    /// (the Refresh button) always returns false so it re-asserts; an empty
    /// desired set never skips.
    nonisolated static func shouldSkipReapply(desiredPairs: Set<String>, activePairs: Set<String>, forceReassert: Bool) -> Bool {
        !forceReassert && !desiredPairs.isEmpty && desiredPairs == activePairs
    }

    /// The single dispatch predicate for the custom-mode rule engine: it runs ONLY at
    /// schemaVersion >= 2 AND routingMode == .custom. A schemaVersion-1 config (even one
    /// whose mode says .custom) is the FAIL-SAFE case — it must take the legacy
    /// bypass/vpnOnly path, never the rule engine, because its routes/rules were not
    /// migrated. Extracted as a pure static so every apply path shares one definition
    /// and the fail-safe is unit-testable without driving the actor.
    nonisolated static func usesCustomEngine(schemaVersion: Int, routingMode: RoutingMode) -> Bool {
        schemaVersion >= 2 && routingMode == .custom
    }

    /// Apply all routes — acquires exclusive gate, skips if another operation is running.
    /// `orphanGrace` is passed by AUTO-triggered applies only (the reconnect settle path):
    /// it defers deleting routes that merely rotated out of DNS. User-initiated applies keep
    /// immediate deletion so an explicit removal takes effect at once.
    func applyAllRoutes(orphanGrace: Bool = false) async {
        guard acquireRouteOperation() else {
            log(.info, "Apply skipped: route operation in progress")
            return
        }
        defer { releaseRouteOperation() }
        await applyAllRoutesInternal(sendNotification: false, orphanGrace: orphanGrace)
    }

    /// Apply all routes and send notification (called from Refresh button)
    func applyAllRoutesWithNotification() async {
        guard acquireRouteOperation() else {
            log(.info, "Apply skipped: route operation in progress")
            return
        }
        defer { releaseRouteOperation() }
        // Refresh button: force a full re-assert (re-install every route) so the
        // user always has a way to recover from silent kernel-route clobbering.
        await applyAllRoutesInternal(sendNotification: true, forceReassert: true)
    }

    /// VPN Only mode installs 0.0.0.0/1 + 128.0.0.0/1 catch-all routes that
    /// structurally defeat a full-tunnel VPN. Under GlobalProtect that trips its
    /// route monitor and tears the tunnel down (the original incident), so EVERY
    /// route-applying path must refuse it. Returns true (and logs) when the apply
    /// should be skipped.
    /// Destinations whose route becomes STALE when the VPN goes away: anything egressing via the
    /// VPN gateway or bound to a tunnel interface, plus the VPN-Only catch-alls.
    ///
    /// Pure so it can be tested without a helper, a kernel, or a live VPN.
    ///
    /// The point of the split: in Bypass mode every route egresses via the LOCAL gateway, so a VPN
    /// disconnect leaves them all perfectly valid — those domains were already going direct, and
    /// they continue to. Tearing the whole set down and rebuilding it on reconnect was pure churn,
    /// and with a tunnel that reconnects often it dominated everything: one machine logged 15
    /// disconnects and 8 full 342-route rebuilds in a day, each rebuild firing hundreds of kernel
    /// route-change events that the VPN client itself then reacts to.
    nonisolated static func vpnBoundDestinations(
        activeRoutes: [ActiveRoute],
        localGateway: String?,
        catchAlls: Set<String>
    ) -> [String] {
        activeRoutes.compactMap { route in
            if catchAlls.contains(route.destination) { return route.destination }
            // Interface-scoped routes name a tunnel that is going away.
            if route.gateway.hasPrefix("iface:") { return route.destination }
            // Anything not egressing via the local gateway is VPN-bound.
            if let local = localGateway, route.gateway == local { return nil }
            return route.destination
        }
    }

    /// Catch-alls this app currently believes it owns. Used by the GlobalProtect refusal so it can
    /// remove what is already installed rather than only declining to add more.
    private var installedCatchAllDestinations: [String] {
        let catchAlls = Set(RouteCompiler.catchAllDestinations)
        return activeRoutes.map { $0.destination }.filter { catchAlls.contains($0) }
    }

    private func refuseVPNOnlyUnderGlobalProtect() -> Bool {
        guard config.routingMode == .vpnOnly, vpnType == .globalProtect else { return false }
        log(.error, "VPN Only mode is disabled under GlobalProtect — its catch-all routes would tear down the GP tunnel. Use Bypass mode instead.")

        // Refusing to ADD is not enough on its own. GlobalProtect can come up *after* VPN Only has
        // already installed its catch-alls (vpnType is detected from running processes, so it flips
        // mid-session), and the flap suppressor can turn a VPN swap into "still connected, new
        // interface" so the disconnect teardown never runs. The refusal then returned early and left
        // `0.0.0.0/1` + `128.0.0.0/1` pointing at the LOCAL gateway — more specific than GP's
        // default, so 100% of traffic silently left the tunnel while the app reported itself
        // healthy, and nothing would ever remove them. A guard that declines to add but tolerates
        // what is already there is not a guard.
        let stranded = installedCatchAllDestinations
        if !stranded.isEmpty {
            log(.warning, "Removing \(stranded.count) stranded VPN Only catch-all route(s) — they would route all traffic around GlobalProtect")
            Task { @MainActor in
                let result = await self.removeRoutesBatchVia(stranded)
                let removed = Set(stranded).subtracting(result.failedDestinations)
                self.activeRoutes.removeAll { removed.contains($0.destination) }
                NotificationManager.shared.notifyEnforcementFailed(
                    reason: String(localized: "VPN Only isn't available while GlobalProtect is connected. Its catch-all routes were removed so your traffic stays in the tunnel. Switch to Bypass mode.")
                )
            }
        }
        return true
    }

    /// Internal — gate-free, callers must hold the route operation lock.
    /// Checks routeEpoch before committing to detect preemption by removeAllRoutes.
    private func applyAllRoutesInternal(sendNotification: Bool, forceReassert: Bool = false,
                                        orphanGrace: Bool = false) async {
        let epoch = routeEpoch

        guard let gateway = localGateway else {
            log(.error, "No local gateway available")
            NotificationManager.shared.notifyEnforcementFailed(
                reason: String(localized: "No network gateway was detected, so no routes could be applied.")
            )
            return
        }

        // Refuse VPN Only under GlobalProtect on every apply path (see method).
        if refuseVPNOnlyUnderGlobalProtect() { return }

        // Custom mode: dispatch per rule via RouteCompiler, then return — the legacy
        // bypass/vpnOnly builder below is untouched (classic modes stay byte-identical).
        if Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            await applyCustomRoutesInternal(useCacheOnly: false, sendNotification: sendNotification, forceReassert: forceReassert)
            return
        }

        let isInverse = config.routingMode == .vpnOnly

        // VPN Only mode requires the VPN gateway for domain-specific routes
        if isInverse {
            guard let vpnGw = vpnGateway else {
                log(.error, "VPN Only mode requires a VPN gateway (is VPN connected?)")
                NotificationManager.shared.notifyEnforcementFailed(
                    reason: String(localized: "VPN Only needs a connected VPN. Nothing is being routed through the VPN right now.")
                )
                return
            }
            log(.info, "VPN Only mode: bypass-all via \(gateway), VPN domains via \(vpnGw)")
        }

        var failedCount = 0

        // Clear DNS cache for fresh resolution
        dnsCache.removeAll()

        // Collect all domains to resolve (for parallel resolution)
        var allDomains: [(domain: String, source: String)] = []

        // Collect CIDR entries separately (routed directly, not DNS-resolved)
        var inverseCIDRs: [String] = []

        if isInverse {
            // VPN Only mode: resolve inverse domains (these go through VPN)
            // CIDR entries are routed directly as network routes, not DNS-resolved
            for domain in config.inverseDomains where domain.enabled {
                if domain.isCIDR {
                    inverseCIDRs.append(domain.domain)
                } else {
                    allDomains.append((domain.domain, domain.domain))
                }
            }
        } else {
            // Bypass mode: resolve bypass domains + service domains
            for domain in config.domains where domain.enabled {
                allDomains.append((domain.domain, domain.domain))
            }
            for service in config.services where service.enabled {
                for domain in service.domains {
                    allDomains.append((domain, service.name))
                }
            }
        }

        // Resolve domains in parallel batches (truly parallel now with nonisolated DNS)
        log(.info, "Resolving \(allDomains.count) domains...")

        let batchSize = 100  // Large batch size - DNS resolution is truly parallel via GCD
        var index = 0

        // Capture values for nonisolated access
        let userDNS = detectedDNSServer
        let fallbackDNS = config.fallbackDNS

        // In VPN Only mode, domain-specific routes go through VPN gateway
        let routeGateway = isInverse ? (vpnGateway ?? gateway) : gateway

        // Resolve every matcher (impure: DNS + cache + failed tracking), then hand the
        // already-resolved data to the pure ClassicRouteCompiler which builds the route set.
        // Groups are assembled in input order (a domain may appear under several sources, so we
        // carry the batch index rather than key by domain) — deterministic, and the emitted
        // route SET is identical to the old inline collection (see ClassicRouteCompiler).
        var resolvedGroups: [ClassicRouteCompiler.ResolvedGroup] = []
        while index < allDomains.count {
            let endIndex = min(index + batchSize, allDomains.count)
            let batch = Array(allDomains[index..<endIndex])

            // Sliding-window resolve: cap in-flight domain resolutions. Each domain fans out to
            // ~5 dig/curl subprocesses, so an unbounded 100-wide batch could spawn ~500 concurrent
            // processes — a fork storm that oversubscribes the GCD pool. Bound the in-flight count
            // so subprocess concurrency stays ~80. Results are reassembled in input order.
            let maxConcurrentResolves = 16
            let dnsResults = await withTaskGroup(of: (idx: Int, ips: [String]?).self) { group in
                var next = 0
                while next < batch.count && next < maxConcurrentResolves {
                    let i = next, item = batch[i]
                    group.addTask { (i, await DNSResolver.resolveIPsParallel(for: item.domain, userDNS: userDNS, fallbackDNS: fallbackDNS)) }
                    next += 1
                }
                var results: [(idx: Int, ips: [String]?)] = []
                while let result = await group.next() {
                    results.append(result)
                    if next < batch.count {
                        let i = next, item = batch[i]
                        group.addTask { (i, await DNSResolver.resolveIPsParallel(for: item.domain, userDNS: userDNS, fallbackDNS: fallbackDNS)) }
                        next += 1
                    }
                }
                return results.sorted { $0.idx < $1.idx }
            }

            for result in dnsResults {
                let item = batch[result.idx]
                if let ips = result.ips, !ips.isEmpty {
                    // DNS succeeded - use fresh IPs and update caches
                    if let firstIP = ips.first {
                        dnsCache[item.domain] = firstIP
                    }
                    dnsDiskCache[item.domain] = ips  // Update persistent cache
                    resolvedGroups.append(ClassicRouteCompiler.ResolvedGroup(source: item.source, ips: ips))
                } else if let cachedIPs = dnsDiskCache[item.domain], !cachedIPs.isEmpty {
                    // DNS failed but we have cached IPs - use them as fallback
                    log(.info, "Using cached IPs for \(item.domain)")
                    if let firstIP = cachedIPs.first {
                        dnsCache[item.domain] = firstIP
                    }
                    resolvedGroups.append(ClassicRouteCompiler.ResolvedGroup(source: item.source, ips: cachedIPs))
                } else {
                    failedDomains.insert(item.domain)
                    failedCount += 1
                }
            }

            index += batchSize
        }

        // Save updated DNS cache to disk
        saveDNSCache()

        // Service IP ranges (bypass mode only — services are not used in VPN Only mode)
        var serviceRanges: [(source: String, range: String)] = []
        if !isInverse {
            for service in config.services where service.enabled {
                for range in service.ipRanges {
                    serviceRanges.append((service.name, range))
                }
            }
        }

        // Build the classic route set from the resolved data (pure + unit-tested).
        let build = ClassicRouteCompiler.build(
            isInverse: isInverse,
            localGateway: gateway,
            routeGateway: routeGateway,
            inverseCIDRs: inverseCIDRs,
            resolvedGroups: resolvedGroups,
            serviceRanges: serviceRanges
        )
        let routesToAdd: [(destination: String, gateway: String, isNetwork: Bool, source: String)] =
            build.routesToAdd.map { ($0.destination, $0.gateway, $0.isNetwork, $0.source) }
        let allSourceEntries: [(destination: String, gateway: String, source: String)] =
            build.allSourceEntries.map { ($0.destination, $0.gateway, $0.source) }

        // Diff-before-mutate (VPN-Bypass-3sc.2): if the desired route set already
        // matches what is active (same destination+gateway pairs), re-running
        // delete-before-add for every route is pure churn that pressures the VPN's
        // route monitor — the GlobalProtect teardown trigger — for no benefit. Skip
        // it on automatic applies. The Refresh button forces a re-assert; the
        // interface-change and import paths clear activeRoutes first, so this never
        // blocks a genuine change.
        let desiredPairs = Set(routesToAdd.map { "\($0.destination)|\($0.gateway)" })
        let activePairs = Set(activeRoutes.map { "\($0.destination)|\($0.gateway)" })
        if Self.shouldSkipReapply(desiredPairs: desiredPairs, activePairs: activePairs, forceReassert: forceReassert) {
            // active == desired means no graced orphan is outstanding, so any grace history
            // left in the map belongs to destinations that are desired again (or gone) and
            // must be forgiven here — this return skips commitAppliedRoutes, where that
            // forgiveness normally happens. Without it, a retain → restore → rotate-out
            // sequence would age the route from its ORIGINAL timestamp and delete it
            // immediately instead of granting a fresh TTL.
            orphanFirstSeen.removeAll()
            log(.info, "Routes already current (\(activePairs.count)) — skipping re-apply to avoid route-table churn")
            lastUpdate = Date()
            return
        }

        log(.info, "Adding \(routesToAdd.count) routes via batch operation...")
        
        // Apply all routes in batch (single XPC call for massive speedup)
        var batchFailureCount = 0
        var batchFailedDests: Set<String> = []
        if HelperManager.shared.isHelperInstalled {
            let helperRoutes = routesToAdd.map { (destination: $0.destination, gateway: $0.gateway, isNetwork: $0.isNetwork) }
            let result = await addRoutesBatchTracked(routes: helperRoutes)
            batchFailureCount = result.failureCount
            batchFailedDests = Set(result.failedDestinations)

            if result.failureCount > 0 {
                log(.warning, "Batch route add: \(result.successCount) succeeded, \(result.failureCount) failed (\(result.failedDestinations.prefix(3).joined(separator: ", "))...)")
            }
        } else {
            log(.error, "Cannot add routes: helper not ready (\(HelperManager.shared.helperState.statusText))")
            NotificationManager.shared.notifyEnforcementFailed(
                reason: String(localized: "The privileged helper isn't ready, so no routes could be applied.")
            )
            return
        }

        let committed = await commitAppliedRoutes(routesToAdd: routesToAdd, allSourceEntries: allSourceEntries, batchFailedDests: batchFailedDests, epoch: epoch, logLabel: "", orphanGrace: orphanGrace)
        guard committed else { return }

        let confirmedUniqueCount = uniqueRouteCount
        let totalFailures = failedCount + batchFailureCount

        if failedCount > 0 {
            log(.warning, "Applied \(confirmedUniqueCount) unique routes (\(failedCount) domains failed DNS)")
            for domain in failedDomains {
                log(.warning, "  ✗ \(domain)")
            }
            failedDomains.removeAll()
        } else if batchFailureCount > 0 {
            log(.warning, "Applied routes (\(batchFailureCount) kernel failures — counts approximate until verified)")
            failedDomains.removeAll()
        } else {
            log(.success, "Applied \(confirmedUniqueCount) unique routes")
            failedDomains.removeAll()
        }

        // Only send notification when explicitly requested (Refresh button)
        if sendNotification && confirmedUniqueCount > 0 {
            NotificationManager.shared.notifyRoutesApplied(count: confirmedUniqueCount, failedCount: totalFailures)
        }

        // Verify routes — always when batch had failures, otherwise per config
        if config.verifyRoutesAfterApply || batchFailureCount > 0 {
            await verifyRoutes()
        }
    }
    
    // MARK: - Custom-mode engine (schemaVersion >= 2 && routingMode == .custom)

    /// Custom-mode apply. Resolves each enabled rule's matcher to concrete destinations,
    /// compiles them to a kernel-route batch via RouteCompiler, and installs it with the
    /// SAME batch-add + orphan-cleanup + epoch/commit/hosts discipline as the legacy full
    /// apply — so the hard-won GP-teardown guards are inherited, not re-derived. Kernel
    /// routes are emitted only for egresses that need them; proxy/tailscale/primary-VPN
    /// destinations are served by their loopback listeners and emit nothing here.
    ///
    /// Gate-free: callers already hold the route-operation lock (matches
    /// applyAllRoutesInternal). `useCacheOnly` mirrors applyRoutesFromCache — domains
    /// resolve from dnsDiskCache with no live DNS, for instant startup. Returns true when
    /// an apply was attempted (false on missing gateway / preemption).
    @discardableResult
    private func applyCustomRoutesInternal(useCacheOnly: Bool, sendNotification: Bool, forceReassert: Bool = false) async -> Bool {
        let epoch = routeEpoch

        guard let gateway = localGateway else {
            log(.error, "Custom routing: no local gateway available")
            return false
        }

        // Resolve every enabled rule's matcher to concrete kernel destinations.
        let resolved = await resolveRuleDestinations(useCacheOnly: useCacheOnly)

        // Multi-VPN: enumerate the live tunnels once so a route pinned to a SPECIFIC
        // VPN resolves to an `iface:utunX` kernel route. A `.vpnDefault`/primary route
        // still emits nothing (stays on the OS default); proxy/tailscale egresses are
        // served by loopback listeners, not kernel routes.
        //
        // listVPNLinks() shells out to ifconfig + tailscale status. Only a route that
        // both is reachable from an ENABLED rule AND pins a specific tunnel (egress
        // .vpnDefault + a .interface selector — exactly when ifaceGateway can return a
        // non-nil token) ever consumes the link set. When none do — the common case with
        // no multi-VPN pinning — skip the enumeration entirely and spawn zero extra
        // processes; the compiler then sees an empty link set and every .vpnDefault route
        // stays on the OS default, unchanged.
        let referencedRouteIds = Set(config.rules.filter { $0.enabled }.map { $0.routeId })
        let needsLinks = config.routes.contains { route in
            referencedRouteIds.contains(route.id)
                && route.egress == .vpnDefault
                && route.vpnSelector?.kind == .interface
        }
        let links = needsLinks ? await listVPNLinks() : []
        var compiled = RouteCompiler.compile(
            resolvedRules: resolved,
            routes: config.routes,
            localGateway: gateway,
            ifaceGatewayForRoute: { route in self.ifaceGateway(for: route, links: links) }
        )

        // Generalized GlobalProtect guard: never install a catch-all into a non-primary
        // egress while GP is up (every compiled kernel route is non-primary). Custom mode
        // is per-rule and shouldn't produce catch-alls, but refuse defensively — this is
        // the custom-engine analog of refuseVPNOnlyUnderGlobalProtect().
        let guarded = RouteCompiler.guardCatchAllUnderGlobalProtect(compiled, isGlobalProtect: vpnType == .globalProtect)
        if !guarded.refused.isEmpty {
            for r in guarded.refused {
                log(.error, "Custom routing: refusing catch-all \(r.destination) into a non-primary egress under GlobalProtect — it would tear down the GP tunnel.")
            }
            compiled = guarded.kept
        }

        var routesToAdd: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = []
        var allSourceEntries: [(destination: String, gateway: String, source: String)] = []
        for r in compiled {
            routesToAdd.append((destination: r.destination, gateway: r.gateway, isNetwork: r.isNetwork, source: r.source))
            allSourceEntries.append((destination: r.destination, gateway: r.gateway, source: r.source))
        }

        // Diff-before-mutate: skip a no-op re-apply to avoid route-table churn that
        // pressures a VPN's route monitor (same guard the legacy full apply uses).
        let desiredPairs = Set(routesToAdd.map { "\($0.destination)|\($0.gateway)" })
        let activePairs = Set(activeRoutes.map { "\($0.destination)|\($0.gateway)" })
        if Self.shouldSkipReapply(desiredPairs: desiredPairs, activePairs: activePairs, forceReassert: forceReassert) {
            // Same grace-history forgiveness as the classic skip path (see there for why).
            orphanFirstSeen.removeAll()
            log(.info, "Custom routes already current (\(activePairs.count)) — skipping re-apply to avoid route-table churn")
            lastUpdate = Date()
            return true
        }

        log(.info, "Custom routing: applying \(routesToAdd.count) kernel route(s) from \(resolved.count) rule(s)...")

        var batchFailureCount = 0
        var batchFailedDests: Set<String> = []
        if !routesToAdd.isEmpty {
            if HelperManager.shared.isHelperInstalled {
                let helperRoutes = routesToAdd.map { (destination: $0.destination, gateway: $0.gateway, isNetwork: $0.isNetwork) }
                let result = await addRoutesBatchTracked(routes: helperRoutes)
                batchFailureCount = result.failureCount
                batchFailedDests = Set(result.failedDestinations)
                if result.failureCount > 0 {
                    log(.warning, "Custom route batch: \(result.successCount) succeeded, \(result.failureCount) failed (\(result.failedDestinations.prefix(3).joined(separator: ", "))...)")
                }
            } else {
                log(.error, "Cannot add custom routes: helper not ready (\(HelperManager.shared.helperState.statusText))")
                return false
            }
        }

        let committed = await commitAppliedRoutes(routesToAdd: routesToAdd, allSourceEntries: allSourceEntries, batchFailedDests: batchFailedDests, epoch: epoch, logLabel: "Custom ")
        guard committed else { return false }

        let confirmedUniqueCount = uniqueRouteCount
        if batchFailureCount > 0 {
            log(.warning, "Applied custom routes (\(batchFailureCount) kernel failures — counts approximate until verified)")
        } else {
            log(.success, "Applied \(confirmedUniqueCount) unique custom route(s)")
        }

        if sendNotification && confirmedUniqueCount > 0 {
            NotificationManager.shared.notifyRoutesApplied(count: confirmedUniqueCount, failedCount: batchFailureCount)
        }

        if config.verifyRoutesAfterApply || batchFailureCount > 0 {
            await verifyRoutes()
        }
        return true
    }

    /// Resolve each enabled rule's matcher to concrete kernel destinations for the custom
    /// engine, in first-match (ascending `order`) order:
    ///   • .ip      → the address itself (host route).
    ///   • .cidr    → the block itself (network route).
    ///   • .domain  → resolved IPs (live, or dnsDiskCache when useCacheOnly / on failure).
    ///   • .service → its domains resolved to IPs + its static ipRanges.
    ///   • .suffix / .process → nothing (not kernel-routable — a listener/NE engine
    ///     handles those, not the routing table; skipped with no error).
    ///
    /// DNS is resolved for the WHOLE rule set up front, de-duplicated and IN PARALLEL
    /// (the same withTaskGroup + resolveIPsParallel machinery the legacy full-apply uses),
    /// so a domain/service-heavy rule set applies in ~one DNS round-trip instead of one
    /// per domain serially. The matching itself is delegated to the pure
    /// `RuleDestinationBuilder` (unit-testable in isolation). Live resolution refreshes
    /// dnsCache/dnsDiskCache so the hosts file + cache stay consistent, mirroring legacy;
    /// a host that resolves to NOTHING (no live IPs, no cache) is surfaced like legacy —
    /// logged, tracked in failedDomains, and retried in 15s via `scheduleRetry`.
    private func resolveRuleDestinations(useCacheOnly: Bool) async -> [(rule: Rule, dests: [(value: String, isNetwork: Bool)])] {
        // The full de-duplicated hostname set across ALL enabled rules — resolved once,
        // even when the same host is reachable via two rules.
        let hosts = RuleDestinationBuilder.hostsToResolve(rules: config.rules, services: config.services)

        // Build the host→IPs map. Cache-only (instant startup) reads the disk cache with
        // no live DNS and never flags failures (a live apply follows). The live path
        // resolves in parallel and reports the hosts that resolved to nothing.
        let resolvedMap: [String: [String]]
        if useCacheOnly {
            var m: [String: [String]] = [:]
            for host in hosts { m[host] = dnsDiskCache[host] ?? [] }
            resolvedMap = m
        } else {
            let (map, failed, cacheDirty) = await resolveHostsParallel(Array(hosts))
            resolvedMap = map
            if cacheDirty { saveDNSCache() }
            // Fix: custom-mode DNS failures were fully silent. Surface them exactly like
            // the legacy path — the ✗ log line, a failedDomains entry, and the same 15s
            // retry — so a domain that can't resolve doesn't just silently drop its route.
            // Clear the ones that resolved this round first, so failedDomains tracks only
            // the currently-failing hosts (it's shared with the legacy path, which logs +
            // clears it, so stale entries must not leak across a mode switch).
            let failedSet = Set(failed)
            for host in hosts where !failedSet.contains(host) { failedDomains.remove(host) }
            for host in failed {
                failedDomains.insert(host)
                log(.warning, "  ✗ \(host)")
                scheduleRetry(for: host)
            }
        }

        return RuleDestinationBuilder.build(rules: config.rules, services: config.services, resolved: resolvedMap)
    }

    /// Resolve a de-duplicated host list in parallel, reusing the SAME withTaskGroup +
    /// resolveIPsParallel machinery (up to 100 concurrent) the legacy full-apply uses —
    /// no second resolver. Returns: the host→IPs map (live IPs, or the disk-cache
    /// fallback when live resolution fails), the hosts that resolved to NOTHING (neither
    /// live nor cache — the caller logs + retries them), and whether the disk cache
    /// changed. Cache-update semantics match the custom path's former serial resolver: a
    /// live hit refreshes dnsDiskCache + dnsCache; a miss falls back to the disk cache
    /// for the value without touching dnsCache.
    private func resolveHostsParallel(_ hosts: [String]) async -> (resolved: [String: [String]], failed: [String], cacheDirty: Bool) {
        guard !hosts.isEmpty else { return ([:], [], false) }
        let userDNS = detectedDNSServer
        let fallbackDNS = config.fallbackDNS
        let batchSize = 100  // DNS resolution is truly parallel via GCD (nonisolated)

        var resolved: [String: [String]] = [:]
        var failed: [String] = []
        var cacheDirty = false

        var index = 0
        while index < hosts.count {
            let endIndex = min(index + batchSize, hosts.count)
            let batch = Array(hosts[index..<endIndex])
            let dnsResults = await withTaskGroup(of: (host: String, ips: [String]?).self) { group in
                for host in batch {
                    group.addTask {
                        let ips = await DNSResolver.resolveIPsParallel(for: host, userDNS: userDNS, fallbackDNS: fallbackDNS)
                        return (host, ips)
                    }
                }
                var results: [(host: String, ips: [String]?)] = []
                for await r in group { results.append(r) }
                return results
            }
            for r in dnsResults {
                if let ips = r.ips, !ips.isEmpty {
                    resolved[r.host] = ips
                    dnsDiskCache[r.host] = ips
                    if let first = ips.first { dnsCache[r.host] = first }
                    cacheDirty = true
                } else if let cached = dnsDiskCache[r.host], !cached.isEmpty {
                    resolved[r.host] = cached
                } else {
                    resolved[r.host] = []
                    failed.append(r.host)
                }
            }
            index += batchSize
        }
        return (resolved, failed, cacheDirty)
    }

    /// Remove all routes — always proceeds (critical teardown for disconnect/quit/clear).
    /// Does NOT acquire the route operation gate so it cannot be blocked by a running operation.
    /// Increments routeEpoch so in-flight applies detect preemption and abort before committing.
    func removeAllRoutes() async {
        routeEpoch &+= 1
        // Sweep the union of what the model tracks AND what was pushed to the kernel but
        // never committed (pendingKernelAdds) — the latter is invisible to the model by
        // design of the epoch guard, and was the strand mechanism on 2026-08-07.
        let destinations = Array(Set(activeRoutes.map { $0.destination }).union(pendingKernelAdds))

        var failedDests: Set<String> = []
        if !destinations.isEmpty {
            if HelperManager.shared.isHelperInstalled {
                // Remove the catch-all routes (0.0.0.0/1 + 128.0.0.0/1, or a custom 0.0.0.0/0)
                // FIRST, in their own fast batch. If a time-capped quit cuts teardown short,
                // the full-tunnel-defeating catch-alls are already gone rather than stranded
                // (leaving the machine forcing all traffic at a now-dead gateway).
                let catchAlls = destinations.filter { RouteCompiler.catchAllDestinations.contains($0) }
                let rest = destinations.filter { !RouteCompiler.catchAllDestinations.contains($0) }
                if !catchAlls.isEmpty {
                    let r = await HelperManager.shared.removeRoutesBatch(destinations: catchAlls)
                    failedDests.formUnion(r.failedDestinations)
                }
                if !rest.isEmpty {
                    let result = await HelperManager.shared.removeRoutesBatch(destinations: rest)
                    failedDests.formUnion(result.failedDestinations)
                    if result.failureCount > 0 {
                        log(.warning, "Batch route removal: \(result.successCount) succeeded, \(result.failureCount) failed — retaining failed entries in model")
                    } else {
                        log(.info, "Batch route removal: \(result.successCount) routes removed")
                    }
                }
            } else {
                log(.error, "Cannot remove routes: helper not ready (\(HelperManager.shared.helperState.statusText)) — retaining \(destinations.count) route(s) in the model so they can still be removed later")
                // Every destination is still installed in the kernel: the helper never ran, so
                // nothing was removed. Treat them ALL as failed.
                //
                // Falling through with an empty `failedDests` reached `activeRoutes.removeAll()`
                // below, which stranded the routes AND destroyed the only record that they are
                // ours — route ownership lives nowhere else. That is reachable on an ordinary
                // quit (the helper can be booted out, or simply not ready), and it strands
                // silently, immediately after logging that cleanup was impossible. In VPN Only
                // the survivors can include the catch-alls, which then steer every connection
                // around the tunnel with nothing left able to identify or remove them.
                failedDests.formUnion(destinations)
            }
        }

        cancelAllRetries()
        // A failed removal must keep its record. The retention filter below only keeps entries
        // already in activeRoutes — a pending-only destination (pushed to the kernel but never
        // committed to the model) would lose its record here, so append one first.
        let trackedBeforeRetention = Set(activeRoutes.map { $0.destination })
        for dest in failedDests where !trackedBeforeRetention.contains(dest) && pendingKernelAdds.contains(dest) {
            activeRoutes.append(ActiveRoute(destination: dest, gateway: localGateway ?? "", source: "pending-sweep-retry", timestamp: Date()))
        }
        pendingKernelAdds.removeAll()
        if !failedDests.isEmpty {
            // Retain entries for destinations that failed kernel removal — they're still live
            activeRoutes.removeAll { !failedDests.contains($0.destination) }
        } else {
            activeRoutes.removeAll()
        }
        routeVerificationResults.removeAll()
        dnsCache.removeAll()
        lastUpdate = Date()

        if config.manageHostsFile {
            if activeRoutes.isEmpty {
                await cleanHostsFile()
            } else {
                // Some routes retained due to failed removal — keep hosts in sync
                await updateHostsFile()
            }
        }

        log(.info, activeRoutes.isEmpty ? "All routes removed" : "Routes removed (\(activeRoutes.count) entries retained from failed kernel removals)")
    }
    
    // MARK: - Instant Startup (Cache-based)
    
    /// Apply routes using cached IPs only (no DNS resolution) - used for instant startup
    /// Returns false if apply was skipped (no gateway, gate held, preempted, etc.)
    private func applyRoutesFromCache() async -> Bool {
        let epoch = routeEpoch
        guard acquireRouteOperation() else {
            log(.info, "Cache apply skipped: route operation in progress")
            return false
        }
        defer { releaseRouteOperation() }

        guard let gateway = localGateway else {
            log(.error, "Cannot apply cached routes: no local gateway")
            return false
        }

        let isInverse = config.routingMode == .vpnOnly

        // Refuse VPN Only under GlobalProtect on this startup fast-path too — it
        // installs the same 0.0.0.0/1 + 128.0.0.0/1 catch-all and would tear down
        // the GP tunnel on the common cached-launch path.
        if refuseVPNOnlyUnderGlobalProtect() { return false }

        // Custom mode: compile from cached IPs (no live DNS) for instant startup.
        if Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            return await applyCustomRoutesInternal(useCacheOnly: true, sendNotification: false, forceReassert: false)
        }

        // VPN Only mode needs VPN gateway for domain routes
        if isInverse {
            guard let _ = vpnGateway else {
                log(.error, "Cannot apply cached routes in VPN Only mode: no VPN gateway")
                return false
            }
        }

        let routeGateway = isInverse ? vpnGateway! : gateway

        // Collect from the DNS disk cache (no live resolution), then hand the resolved data to
        // the same pure ClassicRouteCompiler the live path uses. Set-equivalent to the old inline
        // collection: CIDR ranges and host IPs never string-collide, and services-before-domains
        // first-wins is preserved by the collection order below.
        var inverseCIDRs: [String] = []
        var resolvedGroups: [ClassicRouteCompiler.ResolvedGroup] = []
        var serviceRanges: [(source: String, range: String)] = []

        if isInverse {
            for domain in config.inverseDomains where domain.enabled {
                if domain.isCIDR {
                    inverseCIDRs.append(domain.domain)
                } else if let cachedIPs = dnsDiskCache[domain.domain] {
                    resolvedGroups.append(ClassicRouteCompiler.ResolvedGroup(source: domain.domain, ips: cachedIPs))
                    if let firstIP = cachedIPs.first { dnsCache[domain.domain] = firstIP }
                }
            }
        } else {
            for service in config.services where service.enabled {
                for domain in service.domains {
                    if let cachedIPs = dnsDiskCache[domain] {
                        resolvedGroups.append(ClassicRouteCompiler.ResolvedGroup(source: service.name, ips: cachedIPs))
                        if let firstIP = cachedIPs.first { dnsCache[domain] = firstIP }
                    }
                }
                for range in service.ipRanges {
                    serviceRanges.append((service.name, range))
                }
            }
            for domain in config.domains where domain.enabled {
                if let cachedIPs = dnsDiskCache[domain.domain] {
                    resolvedGroups.append(ClassicRouteCompiler.ResolvedGroup(source: domain.domain, ips: cachedIPs))
                    if let firstIP = cachedIPs.first { dnsCache[domain.domain] = firstIP }
                }
            }
        }

        let build = ClassicRouteCompiler.build(
            isInverse: isInverse,
            localGateway: gateway,
            routeGateway: routeGateway,
            inverseCIDRs: inverseCIDRs,
            resolvedGroups: resolvedGroups,
            serviceRanges: serviceRanges
        )
        let routesToAdd: [(destination: String, gateway: String, isNetwork: Bool, source: String)] =
            build.routesToAdd.map { ($0.destination, $0.gateway, $0.isNetwork, $0.source) }
        let allSourceEntries: [(destination: String, gateway: String, source: String)] =
            build.allSourceEntries.map { ($0.destination, $0.gateway, $0.source) }

        // Crash recovery first: clear tagged leftovers a previous run stranded, keeping what
        // this apply wants (those become zero-event no-ops in the reconciling batch below).
        await startupSweepIfNeeded(desired: routesToAdd.map { $0.destination })

        log(.info, "Applying \(routesToAdd.count) routes from cache (\(isInverse ? "VPN Only" : "Bypass") mode)...")

        // Apply routes in batch via helper
        var batchFailureCount = 0
        var batchFailedDests: Set<String> = []
        if !routesToAdd.isEmpty {
            if HelperManager.shared.isHelperInstalled {
                let helperRoutes = routesToAdd.map { (destination: $0.destination, gateway: $0.gateway, isNetwork: $0.isNetwork) }
                let result = await addRoutesBatchTracked(routes: helperRoutes)
                batchFailureCount = result.failureCount
                batchFailedDests = Set(result.failedDestinations)
                if result.failureCount > 0 {
                    log(.warning, "Cache route batch: \(result.successCount) succeeded, \(result.failureCount) failed — will reconcile on DNS refresh")
                }
            } else {
                log(.error, "Cannot apply cached routes: helper not ready (\(HelperManager.shared.helperState.statusText))")
                return false
            }
        }

        let committed = await commitAppliedRoutes(routesToAdd: routesToAdd, allSourceEntries: allSourceEntries, batchFailedDests: batchFailedDests, epoch: epoch, logLabel: "Cache ")
        guard committed else { return false }

        if batchFailureCount > 0 {
            log(.warning, "Applied routes from cache (\(batchFailureCount) kernel failures — counts approximate)")
        } else {
            log(.success, "Applied \(uniqueRouteCount) unique routes from cache")
        }
        return true
    }

    /// Partition the stale kernel routes (active destinations no longer in the new set)
    /// into the two cleanup populations: `orphaned` (never in this batch → a failed remove
    /// means the route is still installed, re-attach) vs `addFailed` (in the batch but the
    /// add failed → delete-before-add already removed it, don't re-attach). Pure set algebra.
    nonisolated static func partitionStaleRoutes(active: Set<String>, applied newDestinations: Set<String>, attempted: Set<String>) -> (orphaned: Set<String>, addFailed: Set<String>) {
        let stale = active.subtracting(newDestinations)
        return (orphaned: stale.subtracting(attempted), addFailed: stale.intersection(attempted))
    }

    /// Destinations an aborting apply must remove from the kernel to avoid stranding them (#61).
    /// A preempted apply already added `attempted` to the kernel but will NOT record them in
    /// activeRoutes, so a later removeAllRoutes() (tracked-only) can never clean them. Returns
    /// exactly what THIS apply added and must self-remove — `attempted − addFailed` (add-failed
    /// dests are already gone via delete-before-add) — split with the VPN-Only catch-alls FIRST
    /// (leak-critical) then the rest, each sorted (deterministic for tests). Pure set algebra.
    nonisolated static func destinationsToUnstrand(attempted: Set<String>, addFailed: Set<String>) -> (catchAlls: [String], rest: [String]) {
        let applied = attempted.subtracting(addFailed)
        let catchAlls = applied.filter { RouteCompiler.catchAllDestinations.contains($0) }.sorted()
        let rest = applied.subtracting(RouteCompiler.catchAllDestinations).sorted()
        return (catchAlls: catchAlls, rest: rest)
    }

    /// removeRoutesBatch routed through the test override when set (so tests observe kernel
    /// removals without a real helper), else the privileged helper. Return shape matches
    /// HelperManager.removeRoutesBatch.
    private func removeRoutesBatchVia(_ destinations: [String]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        if let override = removeRoutesBatchOverrideForTests { return await override(destinations) }
        return await HelperManager.shared.removeRoutesBatch(destinations: destinations)
    }

    /// #61 self-remediation: on epoch-preemption abort, remove from the kernel exactly the
    /// destinations this apply just added (catch-alls FIRST for leak safety) so nothing is left
    /// installed-but-untracked. MUST run while the route-operation gate is still held — never move
    /// into a defer-after-release or a detached Task.
    ///
    /// If a kernel removal itself FAILS (or times out), the route is still installed, so dropping it
    /// would recreate the very strand this prevents. Instead it is retained in `activeRoutes` — the
    /// same failed-removal discipline `removeAllRoutes()` and the DNS-refresh stale-removal use — so
    /// the next teardown removes it (removal is by destination, so a minimal entry is enough). A
    /// timeout with no explicit failed list is treated conservatively as "all failed" (over-retaining
    /// is a harmless no-op next teardown; under-retaining would strand).
    private func unstrandRoutes(attempted: Set<String>, addFailed: Set<String>) async {
        let split = RouteManager.destinationsToUnstrand(attempted: attempted, addFailed: addFailed)
        if split.catchAlls.isEmpty && split.rest.isEmpty { return }
        guard HelperManager.shared.isHelperInstalled || removeRoutesBatchOverrideForTests != nil else { return }
        log(.warning, "🔧 Apply preempted — removing \(split.catchAlls.count + split.rest.count) route(s) added before preemption to avoid a strand (#61)")
        var failed: [String] = []
        for batch in [split.catchAlls, split.rest] where !batch.isEmpty {
            let r = await removeRoutesBatchVia(batch)
            // Explicit failed list when present; a bare error (e.g. XPC timeout) ⇒ treat the whole
            // batch as failed so nothing installed is left untracked.
            failed += (r.error != nil && r.failedDestinations.isEmpty) ? batch : r.failedDestinations
        }
        if !failed.isEmpty {
            let tracked = Set(activeRoutes.map { $0.destination })
            for dest in failed where !tracked.contains(dest) {
                activeRoutes.append(ActiveRoute(destination: dest, gateway: localGateway ?? "", source: "#61 cleanup-retry", timestamp: Date()))
            }
            log(.warning, "🔧 \(failed.count) route(s) failed kernel removal during unstrand — retained in activeRoutes so the next teardown removes them")
        }
        // Every attempted destination is now either out of the kernel or retained in
        // activeRoutes — either way it is no longer pending.
        pendingKernelAdds.subtract(attempted)
    }

    /// Shared install-epilogue for the two full-replace apply paths
    /// (applyAllRoutesInternal + applyRoutesFromCache): segments B–F of the apply
    /// tail. Builds activeRoutes from the ownership entries (minus destinations that
    /// failed the kernel batch add), runs the two-population orphan cleanup, then —
    /// in an await-free window — re-checks the epoch guard and commits
    /// activeRoutes/lastUpdate before updating the hosts file. Returns false when
    /// preempted (removeAllRoutes() bumped the epoch mid-flight): the caller must
    /// abort without any further commit. `logLabel` is "" for the full apply and
    /// "Cache " for the cached fast-path (log prefixing only). Runs on the class
    /// @MainActor; the epoch-guard→commit window stays await-free (updateHostsFile
    /// awaits only after the commit).
    /// Orphan-grace tuning: how long a route that fell out of the desired set is kept before
    /// deletion (rotating CDN answers usually return well within this) and a hard cap on how
    /// many graced routes may accumulate (oldest evicted first past the cap).
    static let orphanGraceTTL: TimeInterval = 30 * 60
    static let orphanGraceCap = 400

    struct OrphanGraceOutcome: Equatable {
        var deleteNow: [String]
        var retained: [String]
        var updatedFirstSeen: [String: Date]
    }

    /// Pure grace decision for orphaned routes. An orphan is deleted only once it has stayed
    /// out of the desired set for `ttl`; until then it is retained (still installed, still
    /// tracked). History for a destination that is desired again — or gone from the orphan set
    /// entirely — is dropped, so rotation-back costs zero kernel events. Past `cap` retained
    /// entries, the oldest are evicted to deleteNow so the graced set stays bounded. Outputs
    /// are sorted for determinism.
    nonisolated static func orphanGraceDecision(orphaned: Set<String>, applied: Set<String>,
                                                firstSeen: [String: Date], now: Date,
                                                ttl: TimeInterval, cap: Int) -> OrphanGraceOutcome {
        var seen = firstSeen.filter { !applied.contains($0.key) && orphaned.contains($0.key) }
        var deleteNow: [String] = []
        var retained: [String] = []
        for dest in orphaned {
            let first = seen[dest] ?? now
            if now.timeIntervalSince(first) >= ttl {
                deleteNow.append(dest)
                seen.removeValue(forKey: dest)
            } else {
                seen[dest] = first
                retained.append(dest)
            }
        }
        if retained.count > cap {
            let oldestFirst = retained.sorted { (seen[$0] ?? now, $0) < (seen[$1] ?? now, $1) }
            for dest in oldestFirst.prefix(retained.count - cap) {
                seen.removeValue(forKey: dest)
                deleteNow.append(dest)
            }
            retained = Array(oldestFirst.dropFirst(retained.count - cap))
        }
        return OrphanGraceOutcome(deleteNow: deleteNow.sorted(), retained: retained.sorted(),
                                  updatedFirstSeen: seen)
    }

    func commitAppliedRoutes(
        routesToAdd: [(destination: String, gateway: String, isNetwork: Bool, source: String)],
        allSourceEntries: [(destination: String, gateway: String, source: String)],
        batchFailedDests: Set<String>,
        epoch: UInt64,
        logLabel: String,
        orphanGrace: Bool = false
    ) async -> Bool {
        var newRoutes: [ActiveRoute] = []

        // Build activeRoutes from allSourceEntries, excluding destinations that failed kernel add
        let appliedDestinations = Set(routesToAdd.map { $0.destination }).subtracting(batchFailedDests)
        for entry in allSourceEntries where appliedDestinations.contains(entry.destination) {
            newRoutes.append(ActiveRoute(
                destination: entry.destination,
                gateway: entry.gateway,
                source: entry.source,
                timestamp: Date()
            ))
        }

        // Clean up stale kernel routes. Two populations:
        // 1. Truly orphaned: not in batch add input — delete-before-add never touched
        //    them, so a failed delete means the route IS still in the kernel.
        // 2. Add-failed: were in batch add input but failed — delete-before-add already
        //    removed the old route, so a failed delete means "already gone."
        let newDestinations = Set(newRoutes.map { $0.destination })
        let stalePartition = RouteManager.partitionStaleRoutes(
            active: Set(activeRoutes.map { $0.destination }),
            applied: newDestinations,
            attempted: Set(routesToAdd.map { $0.destination })
        )
        var trulyOrphanedDests = Array(stalePartition.orphaned)
        let addFailedStaleDests = Array(stalePartition.addFailed)

        // Orphan grace (auto-triggered applies in classic bypass mode only): most "orphans"
        // are CDN IPs that merely rotated out of this resolve — 100–150 per cycle observed —
        // and deleting then re-adding them when rotation swings back doubles the broadcast
        // burst the tunnel client has to sit through. Deferring the delete until an IP has
        // stayed gone for the TTL removes that churn; graced routes keep working meanwhile
        // (they egress the stable local gateway). User-initiated applies pass
        // orphanGrace=false, so an explicit removal still takes effect immediately.
        if orphanGrace && config.routingMode == .bypass {
            let outcome = Self.orphanGraceDecision(orphaned: stalePartition.orphaned,
                                                   applied: newDestinations,
                                                   firstSeen: orphanFirstSeen,
                                                   now: Date(),
                                                   ttl: Self.orphanGraceTTL,
                                                   cap: Self.orphanGraceCap)
            orphanFirstSeen = outcome.updatedFirstSeen
            trulyOrphanedDests = outcome.deleteNow
            if !outcome.retained.isEmpty {
                let retainSet = Set(outcome.retained)
                for route in activeRoutes where retainSet.contains(route.destination) && !newDestinations.contains(route.destination) {
                    newRoutes.append(route)
                }
                log(.info, "\(logLabel)Orphan grace: \(outcome.retained.count) recently-rotated route(s) kept, delete deferred")
            }
        } else {
            // Immediate-delete path: any grace history is moot once the deletes go through.
            orphanFirstSeen.removeAll()
        }

        // Truly orphaned: re-attach on failure (route is genuinely still in kernel)
        if !trulyOrphanedDests.isEmpty {
            let result = await removeRoutesBatchVia(trulyOrphanedDests)
            if result.failureCount > 0 {
                log(.warning, "\(logLabel)Orphan cleanup: \(result.successCount) removed, \(result.failureCount) failed — retaining")
                let failedSet = Set(result.failedDestinations)
                for route in activeRoutes where failedSet.contains(route.destination) && !newDestinations.contains(route.destination) {
                    newRoutes.append(route)
                }
            } else if result.successCount > 0 {
                log(.info, "\(logLabel)Orphan cleanup: \(result.successCount) stale kernel routes removed")
            }
        }

        // Add-failed: helper's addRoute does delete-before-add, so the old route is
        // gone after a failed re-add. Don't re-attach — the kernel route doesn't exist.
        if !addFailedStaleDests.isEmpty {
            let result = await removeRoutesBatchVia(addFailedStaleDests)
            if result.failureCount > 0 {
                log(.info, "\(logLabel)Add-failed cleanup: \(result.failureCount) route(s) already removed by delete-before-add")
            }
        }

        // Preemption check: if removeAllRoutes() ran during our awaits, our results are stale.
        // The epoch check + commit is atomic on @MainActor (no await between them).
        guard routeEpoch == epoch else {
            log(.warning, "\(logLabel)Apply aborted: routes were cleared during operation")
            await unstrandRoutes(attempted: Set(routesToAdd.map { $0.destination }), addFailed: batchFailedDests)
            return false
        }

        activeRoutes = newRoutes
        // Committed destinations are tracked in activeRoutes now — no longer pending.
        pendingKernelAdds.subtract(newRoutes.map { $0.destination })
        lastUpdate = Date()

        // Manage hosts file if enabled
        if config.manageHostsFile {
            await updateHostsFile()
        }

        return true
    }

    /// Background DNS refresh - re-resolves all domains and updates routes if IPs changed
    private func backgroundDNSRefresh(sendNotification: Bool) async {
        let epoch = routeEpoch
        guard acquireRouteOperation() else {
            log(.info, "Background DNS refresh skipped: another route operation is in progress")
            return
        }
        defer { releaseRouteOperation() }

        guard let gateway = localGateway else {
            log(.warning, "Background DNS refresh skipped: no local gateway")
            return
        }

        // Custom mode: re-resolve rules + recompile + reconcile (full replace), then
        // refresh the timestamps. The legacy incremental diff below is untouched.
        if config.schemaVersion >= 2 && config.routingMode == .custom {
            _ = await applyCustomRoutesInternal(useCacheOnly: false, sendNotification: false)
            lastDNSRefresh = Date()
            nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
            return
        }

        let isInverse = config.routingMode == .vpnOnly
        let routeGateway: String
        if isInverse {
            // VPN Only under GlobalProtect is refused on every apply path (see method).
            if refuseVPNOnlyUnderGlobalProtect() { return }
            guard let vpnGw = vpnGateway else {
                log(.warning, "Background DNS refresh skipped: VPN Only mode but no VPN gateway")
                return
            }
            routeGateway = vpnGw
        } else {
            routeGateway = gateway
        }

        // Collect domains to resolve based on routing mode
        var domainsToResolve: [(domain: String, source: String)] = []
        if isInverse {
            for domain in config.inverseDomains where domain.enabled {
                if !domain.isCIDR {
                    let resolvable = domain.domain
                    domainsToResolve.append((resolvable, domain.domain))
                }
            }
        } else {
            for service in config.services where service.enabled {
                for domain in service.domains {
                    domainsToResolve.append((domain, service.name))
                }
            }
            for domain in config.domains where domain.enabled {
                let resolvable = domain.domain
                domainsToResolve.append((resolvable, domain.domain))
            }
        }
        
        // Resolve DNS in parallel
        let userDNS = detectedDNSServer
        let fallbackDNS = config.fallbackDNS
        
        var newIPs: [String: [String]] = [:]
        var routeChanges: [(add: Bool, destination: String, gateway: String, isNetwork: Bool, source: String)] = []
        
        let results = await withTaskGroup(of: (String, String, [String]?).self) { group in
            for (domain, source) in domainsToResolve {
                group.addTask {
                    let ips = await DNSResolver.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
                    return (domain, source, ips)
                }
            }
            
            var results: [(String, String, [String]?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        
        // Update per-domain caches first
        for (domain, _, ips) in results {
            guard let ips = ips, !ips.isEmpty else { continue }
            newIPs[domain] = ips
            if let firstIP = ips.first {
                await MainActor.run { dnsCache[domain] = firstIP }
            }
        }

        // Build route changes at the SOURCE level, not per-domain, so that
        // when two domains in the same service share an IP and one drops it
        // while the other keeps it, we don't incorrectly remove the route.
        let resultsBySource = Dictionary(grouping: results, by: { $0.1 })
        for (source, sourceResults) in resultsBySource {
            var aggregateOldIPs: Set<String> = []
            var aggregateNewIPs: Set<String> = []

            for (domain, _, ips) in sourceResults {
                let oldCached = Set(dnsDiskCache[domain] ?? [])
                aggregateOldIPs.formUnion(oldCached)

                if let ips = ips, !ips.isEmpty {
                    aggregateNewIPs.formUnion(ips)
                } else {
                    // Failed resolution — treat old cached IPs as unchanged
                    aggregateNewIPs.formUnion(oldCached)
                }
            }

            let toAdd = aggregateNewIPs.subtracting(aggregateOldIPs)
            let toRemove = aggregateOldIPs.subtracting(aggregateNewIPs)

            for ip in toAdd {
                routeChanges.append((add: true, destination: ip, gateway: routeGateway, isNetwork: false, source: source))
            }
            for ip in toRemove {
                routeChanges.append((add: false, destination: ip, gateway: routeGateway, isNetwork: false, source: source))
            }
        }
        
        // Update disk cache
        await MainActor.run {
            for (domain, ips) in newIPs {
                dnsDiskCache[domain] = ips
            }
            saveDNSCache()
        }
        
        // Apply route changes if any (re-check VPN state to avoid racing with disconnect)
        let stillConnected = await MainActor.run { isVPNConnected }
        var passAddedDests: Set<String> = []  // #61: kernel dests this pass added, for unstrand-on-preempt
        if !routeChanges.isEmpty && stillConnected {
            let additions = routeChanges.filter { $0.add }
            let removals = routeChanges.filter { !$0.add }
            
            if !removals.isEmpty {
                // Only remove kernel routes if no other source still needs the destination
                let removalSources = Dictionary(grouping: removals, by: { $0.source })
                var kernelRemovalDests: [String] = []

                await MainActor.run {
                    for (source, sourceRemovals) in removalSources {
                        for removal in sourceRemovals {
                            // Remove the activeRoute entry for this specific source
                            activeRoutes.removeAll { $0.destination == removal.destination && $0.source == source }
                            // Only remove from kernel if no other source still references it
                            let stillNeeded = activeRoutes.contains { $0.destination == removal.destination }
                            if !stillNeeded {
                                kernelRemovalDests.append(removal.destination)
                            }
                        }
                    }
                }

                if !kernelRemovalDests.isEmpty {
                    let result = await HelperManager.shared.removeRoutesBatch(destinations: kernelRemovalDests)
                    if result.failureCount > 0 {
                        // Re-add activeRoute entries for destinations that failed kernel removal
                        let failedSet = Set(result.failedDestinations)
                        await MainActor.run {
                            for removal in removals where failedSet.contains(removal.destination) {
                                activeRoutes.append(ActiveRoute(
                                    destination: removal.destination,
                                    gateway: removal.gateway,
                                    source: removal.source,
                                    timestamp: Date()
                                ))
                            }
                        }
                    }
                }
            }

            if !additions.isEmpty {
                var addFailedDests: Set<String> = []
                // Deduplicate by destination for kernel operations — same IP from
                // different sources must only be sent once to avoid delete-before-add
                // destroying a just-added route on the second pass
                var seenAddDests: Set<String> = []
                let routes = additions.compactMap { add -> (destination: String, gateway: String, isNetwork: Bool)? in
                    guard seenAddDests.insert(add.destination).inserted else { return nil }
                    return (destination: add.destination, gateway: add.gateway, isNetwork: add.isNetwork)
                }
                let result = await addRoutesBatchTracked(routes: routes)
                addFailedDests = Set(result.failedDestinations)
                passAddedDests.formUnion(Set(routes.map { $0.destination }).subtracting(addFailedDests))

                // Record ownership for ALL sources whose destinations succeeded — but only while
                // the epoch still matches. A concurrent removeAllRoutes() means these kernel adds
                // must be unstranded at the guard below, not tracked (guard→append is await-free). #61
                await MainActor.run {
                    guard routeEpoch == epoch else { return }
                    for add in additions where !addFailedDests.contains(add.destination) {
                        activeRoutes.append(ActiveRoute(
                            destination: add.destination,
                            gateway: add.gateway,
                            source: add.source,
                            timestamp: Date()
                        ))
                    }
                }
            }
            
            await MainActor.run {
                log(.info, "Background refresh: \(additions.count) routes added, \(removals.count) removed")
            }
        } else {
            await MainActor.run {
                log(.info, "Background refresh complete (no changes)")
            }
        }
        
        // Repair missing CIDR routes for service ipRanges (bypass mode only)
        var cidrRepaired = 0
        if !isInverse && stillConnected {
            let existingDests = await MainActor.run { Set(activeRoutes.map { $0.destination }) }
            var repairedRanges: Set<String> = []
            for service in config.services where service.enabled {
                for range in service.ipRanges {
                    if existingDests.contains(range) { continue }
                    if repairedRanges.contains(range) {
                        // Already repaired by another service — just add ownership (epoch-gated). #61
                        await MainActor.run {
                            guard routeEpoch == epoch else { return }
                            activeRoutes.append(ActiveRoute(
                                destination: range,
                                gateway: routeGateway,
                                source: service.name,
                                timestamp: Date()
                            ))
                        }
                        continue
                    }
                    if await addRoute(range, gateway: routeGateway, isNetwork: true) {
                        repairedRanges.insert(range)
                        passAddedDests.insert(range)
                        await MainActor.run {
                            guard routeEpoch == epoch else { return }
                            activeRoutes.append(ActiveRoute(
                                destination: range,
                                gateway: routeGateway,
                                source: service.name,
                                timestamp: Date()
                            ))
                        }
                        cidrRepaired += 1
                    }
                }
            }
            if cidrRepaired > 0 {
                await MainActor.run { log(.info, "Background refresh: repaired \(cidrRepaired) missing CIDR route(s)") }
            }
        }

        // Preemption check: if removeAllRoutes() ran during our awaits, skip commits and
        // unstrand any kernel routes this pass added before the epoch diverged. #61
        guard routeEpoch == epoch else {
            await MainActor.run { log(.warning, "Background DNS refresh aborted: routes were cleared during operation") }
            await unstrandRoutes(attempted: passAddedDests, addFailed: [])
            return
        }

        // Update hosts file with any newly resolved domains (only if still connected)
        let shouldUpdateHosts = await MainActor.run { config.manageHostsFile && isVPNConnected }
        if shouldUpdateHosts {
            let hostsOK = await updateHostsFile()
            await MainActor.run {
                if hostsOK { log(.info, "Background refresh: hosts file updated") }
                else { log(.warning, "Background refresh: hosts file update FAILED — /etc/hosts may be stale") }
            }
        }

        // Update UI refresh timestamps
        await MainActor.run {
            lastDNSRefresh = Date()
            nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
        }

        // Send notification if requested (include both DNS changes and CIDR repairs)
        let totalChanges = routeChanges.count + cidrRepaired
        if sendNotification && totalChanges > 0 {
            NotificationManager.shared.notifyDNSRefreshCompleted(updatedCount: totalChanges)
        }
    }
    
    // MARK: - Auto DNS Refresh
    
    /// Start or restart the DNS refresh timer based on config
    func startDNSRefreshTimer() {
        stopDNSRefreshTimer()
        
        guard config.autoDNSRefresh else {
            log(.info, "Auto DNS refresh disabled")
            nextDNSRefresh = nil
            return
        }
        
        let interval = config.dnsRefreshInterval
        log(.info, "Auto DNS refresh enabled: every \(Int(interval / 60)) minutes")
        
        nextDNSRefresh = Date().addingTimeInterval(interval)
        
        dnsRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performDNSRefresh()
            }
        }
    }
    
    /// Stop the DNS refresh timer
    func stopDNSRefreshTimer() {
        dnsRefreshTimer?.invalidate()
        dnsRefreshTimer = nil
    }
    
    /// Perform DNS refresh - re-resolve all domains and update routes
    private func performDNSRefresh() async {
        let epoch = routeEpoch
        guard acquireRouteOperation() else {
            log(.info, "DNS refresh skipped: another route operation is in progress")
            return
        }
        defer { releaseRouteOperation() }

        guard isVPNConnected, let gateway = localGateway else {
            log(.info, "DNS refresh skipped: \(!isVPNConnected ? "VPN not connected" : "no local gateway")")
            nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
            return
        }

        // Custom mode: re-resolve rules + recompile + reconcile (full replace), then
        // refresh the timestamps. The legacy incremental diff below is untouched.
        if config.schemaVersion >= 2 && config.routingMode == .custom {
            _ = await applyCustomRoutesInternal(useCacheOnly: false, sendNotification: false)
            lastDNSRefresh = Date()
            nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
            return
        }

        let isInverse = config.routingMode == .vpnOnly
        let routeGateway: String
        if isInverse {
            // VPN Only under GlobalProtect is refused on every apply path (see method).
            if refuseVPNOnlyUnderGlobalProtect() {
                nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
                return
            }
            guard let vpnGw = vpnGateway else {
                log(.info, "DNS refresh skipped: VPN Only mode but no VPN gateway")
                nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
                return
            }
            routeGateway = vpnGw
        } else {
            routeGateway = gateway
        }

        log(.info, "Auto DNS refresh (\(isInverse ? "VPN Only" : "Bypass") mode): re-resolving domains...")

        var updatedCount = 0

        // Source-aware tracking: (source, destination) pairs instead of flat IP sets. SourceDest
        // now lives on DNSRefreshPlanner (the pure planner that owns the refresh route-delta
        // logic); alias it so the rest of this method reads unchanged.
        typealias SourceDest = DNSRefreshPlanner.SourceDest
        var addedKernelRoutes: Set<String> = []  // Track new kernel routes added this cycle

        // Collect domains based on routing mode. Inverse CIDR entries are preserved as static
        // routes (no DNS resolution) and handed to the planner to seed expectedEntries.
        var domainsToResolve: [(domain: String, source: String)] = []
        var inverseCIDRs: [String] = []

        if isInverse {
            for domain in config.inverseDomains where domain.enabled {
                if domain.isCIDR {
                    inverseCIDRs.append(domain.domain)
                } else {
                    let resolvable = domain.domain
                    domainsToResolve.append((resolvable, domain.domain))
                }
            }
        } else {
            for domain in config.domains where domain.enabled {
                let resolvable = domain.domain
                domainsToResolve.append((resolvable, domain.domain))
            }
            for service in config.services where service.enabled {
                for domain in service.domains {
                    domainsToResolve.append((domain, service.name))
                }
            }
        }

        // Snapshot current state for comparison
        let existingDestinations = Set(activeRoutes.map { $0.destination })
        let existingSourceDests = Set(activeRoutes.map { SourceDest(source: $0.source, destination: $0.destination) })

        // Re-resolve every UNIQUE domain — same withTaskGroup + resolveIPsParallel machinery the
        // full-apply path uses, including its 16-wide sliding window. Resolving once per domain
        // (vs. the old serial per-(domain,source) loop) only collapses duplicate work into one
        // consistent view; the planner below is order-independent given the resolved map, so the
        // route SET is identical.
        let userDNS = detectedDNSServer
        let fallbackDNS = config.fallbackDNS
        let uniqueDomains = Array(Set(domainsToResolve.map { $0.domain }))
        // Sliding-window resolve: cap in-flight domain resolutions (mirrors applyAllRoutesInternal).
        // Each domain fans out to ~5 dig/curl subprocesses, so adding a task per domain up front
        // could spawn a fork storm for large domain sets. Bound the in-flight count; every unique
        // domain is still resolved and lands in resolvedDomainIPs below (order-independent).
        let maxConcurrentResolves = 16
        let domainResults = await withTaskGroup(of: (String, [String]?).self) { group in
            var next = 0
            while next < uniqueDomains.count && next < maxConcurrentResolves {
                let domain = uniqueDomains[next]
                group.addTask {
                    let ips = await DNSResolver.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
                    return (domain, ips)
                }
                next += 1
            }
            var results: [(String, [String]?)] = []
            while let result = await group.next() {
                results.append(result)
                if next < uniqueDomains.count {
                    let domain = uniqueDomains[next]
                    group.addTask {
                        let ips = await DNSResolver.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
                        return (domain, ips)
                    }
                    next += 1
                }
            }
            return results
        }
        var resolvedDomainIPs: [String: [String]] = [:]
        for (domain, ips) in domainResults {
            if let ips = ips { resolvedDomainIPs[domain] = ips }
        }

        // Plan the route delta purely (see DNSRefreshPlanner): which new kernel routes to add,
        // which ownership rows to commit once their route is present, and the full expected set.
        let plan = DNSRefreshPlanner.plan(
            domainsToResolve: domainsToResolve,
            resolvedDomainIPs: resolvedDomainIPs,
            cachedDomainIPs: dnsDiskCache,
            existingDestinations: existingDestinations,
            existingSourceDests: existingSourceDests,
            isInverse: isInverse,
            routeGateway: routeGateway,
            inverseCIDRs: inverseCIDRs
        )
        var expectedEntries = plan.expectedEntries

        // Apply: add each new kernel route (host route through the route gateway), tracking
        // successes. This is the same addRoute call the serial loop made.
        for plannedRoute in plan.routesToAdd {
            if await addRoute(plannedRoute.destination, gateway: routeGateway) {
                addedKernelRoutes.insert(plannedRoute.destination)
                updatedCount += 1
                log(.success, "DNS refresh: added new IP \(plannedRoute.destination)")
            }
        }

        // Commit ownership rows whose kernel route is present (already existed OR just added). The
        // not-already-owned gate was applied by the planner; this is the kernelHasRoute half of the
        // old inline condition, so together they reproduce it exactly. Epoch-gated (await-free): a
        // concurrent removeAllRoutes() means these rows must NOT be tracked — the kernel routes this
        // pass added are unstranded at the guard below instead. #61
        if routeEpoch == epoch {
            for candidate in plan.candidateActiveEntries {
                guard existingDestinations.contains(candidate.destination) || addedKernelRoutes.contains(candidate.destination) else { continue }
                activeRoutes.append(ActiveRoute(
                    destination: candidate.destination,
                    gateway: candidate.gateway,
                    source: candidate.source,
                    timestamp: Date()
                ))
            }
        }

        // Update DNS caches only for successfully resolved domains
        for (domain, ips) in resolvedDomainIPs {
            dnsDiskCache[domain] = ips
            if let firstIP = ips.first {
                dnsCache[domain] = firstIP
            }
        }
        if !resolvedDomainIPs.isEmpty {
            saveDNSCache()
        }

        // IP ranges (bypass mode): track as expected AND repair missing CIDR routes
        if !isInverse {
            for service in config.services where service.enabled {
                for range in service.ipRanges {
                    expectedEntries.insert(SourceDest(source: service.name, destination: range))

                    if existingDestinations.contains(range) { continue }
                    if addedKernelRoutes.contains(range) {
                        // Already repaired by another service — just add ownership (epoch-gated) #61
                        if routeEpoch == epoch {
                            activeRoutes.append(ActiveRoute(
                                destination: range,
                                gateway: routeGateway,
                                source: service.name,
                                timestamp: Date()
                            ))
                        }
                        continue
                    }
                    // Repair missing CIDR route
                    if await addRoute(range, gateway: routeGateway, isNetwork: true) {
                        if routeEpoch == epoch {
                            activeRoutes.append(ActiveRoute(
                                destination: range,
                                gateway: routeGateway,
                                source: service.name,
                                timestamp: Date()
                            ))
                        }
                        addedKernelRoutes.insert(range)
                        updatedCount += 1
                        log(.success, "DNS refresh: repaired missing CIDR route \(range) for \(service.name)")
                    }
                }
            }
        }

        // VPN Only CIDR entries: repair missing network routes
        if isInverse {
            for domain in config.inverseDomains where domain.enabled && domain.isCIDR {
                let cidr = domain.domain
                // Already tracked in expectedEntries above
                if existingDestinations.contains(cidr) { continue }
                if addedKernelRoutes.contains(cidr) { continue }
                if await addRoute(cidr, gateway: routeGateway, isNetwork: true) {
                    if routeEpoch == epoch {
                        activeRoutes.append(ActiveRoute(
                            destination: cidr,
                            gateway: routeGateway,
                            source: cidr,
                            timestamp: Date()
                        ))
                    }
                    addedKernelRoutes.insert(cidr)
                    updatedCount += 1
                    log(.success, "DNS refresh: repaired missing CIDR route \(cidr)")
                }
            }
        }

        // Source-aware stale entry removal
        let currentEntries = Set(activeRoutes.map { SourceDest(source: $0.source, destination: $0.destination) })
        let staleEntries = currentEntries.subtracting(expectedEntries)
        var removedCount = 0
        if !staleEntries.isEmpty {
            // Compute kernel removals BEFORE mutating activeRoutes
            let staleDestinations = Set(staleEntries.map { $0.destination })
            let remainingAfterRemoval = activeRoutes.filter { route in
                !staleEntries.contains(SourceDest(source: route.source, destination: route.destination))
            }
            let stillNeeded = Set(remainingAfterRemoval.map { $0.destination })
            let kernelRemovals = Array(staleDestinations.subtracting(stillNeeded))

            // Attempt kernel removal first
            var failedKernelRemovals: Set<String> = []
            if !kernelRemovals.isEmpty {
                let result = await HelperManager.shared.removeRoutesBatch(destinations: kernelRemovals)
                failedKernelRemovals = Set(result.failedDestinations)
            }

            // Now remove stale entries, but retain those whose kernel removal failed
            activeRoutes.removeAll { route in
                let entry = SourceDest(source: route.source, destination: route.destination)
                guard staleEntries.contains(entry) else { return false }  // not stale, keep
                if failedKernelRemovals.contains(route.destination) { return false }  // kernel removal failed, keep
                return true
            }

            removedCount = kernelRemovals.count - failedKernelRemovals.count
            for entry in staleEntries.prefix(5) {
                log(.info, "DNS refresh: removed stale \(entry.destination) (source: \(entry.source))")
            }
            if staleEntries.count > 5 {
                log(.info, "DNS refresh: ... and \(staleEntries.count - 5) more stale entries removed")
            }
            if !failedKernelRemovals.isEmpty {
                log(.warning, "DNS refresh: \(failedKernelRemovals.count) kernel removals failed — entries retained")
            }
        }

        // Preemption check: if removeAllRoutes() ran during our awaits, skip commits
        guard routeEpoch == epoch else {
            log(.warning, "DNS refresh aborted: routes were cleared during operation")
            await unstrandRoutes(attempted: addedKernelRoutes, addFailed: [])
            nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
            return
        }

        // Update hosts file if enabled and still connected
        if config.manageHostsFile && isVPNConnected {
            if await updateHostsFile() { log(.info, "DNS refresh: hosts file updated") }
            else { log(.warning, "DNS refresh: hosts file update FAILED — /etc/hosts may be stale") }
        }

        lastDNSRefresh = Date()
        nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil

        if updatedCount > 0 || removedCount > 0 {
            log(.success, "DNS refresh complete: \(updatedCount) added, \(removedCount) removed")
        } else {
            log(.info, "DNS refresh complete: routes up to date")
        }
    }
    
    /// Force an immediate DNS refresh
    func forceDNSRefresh() {
        Task {
            await performDNSRefresh()
        }
    }
    
    /// Test SOCKS5 proxy connection
    func testProxyConnection() async {
        guard config.proxyConfig.isConfigured else {
            await MainActor.run {
                proxyTestResult = ProxyTestResult(success: false, message: "Proxy not configured")
            }
            return
        }
        
        await MainActor.run {
            isTestingProxy = true
            proxyTestResult = nil
        }
        
        defer {
            Task { @MainActor in
                isTestingProxy = false
            }
        }
        
        // Test TCP connection to proxy server
        let server = config.proxyConfig.server
        let port = config.proxyConfig.port

        // Validate server is a valid hostname/IP (reject flag injection)
        guard !server.isEmpty,
              !server.hasPrefix("-"),
              server.range(of: #"^[a-zA-Z0-9]([a-zA-Z0-9.\-]*[a-zA-Z0-9])?$"#, options: .regularExpression) != nil,
              port > 0, port < 65536 else {
            await MainActor.run {
                proxyTestResult = ProxyTestResult(success: false, message: "Invalid server or port")
            }
            return
        }

        // Use nc (netcat) to test connection
        let args = ["-z", "-w", "5", server, String(port)]
        guard let result = await runProcessAsync("/usr/bin/nc", arguments: args, timeout: 6.0) else {
            await MainActor.run {
                proxyTestResult = ProxyTestResult(success: false, message: "Connection timeout")
            }
            return
        }
        
        if result.exitCode == 0 {
            await MainActor.run {
                proxyTestResult = ProxyTestResult(success: true, message: "Connected to \(server):\(port)")
                log(.success, "SOCKS5 proxy test successful: \(server):\(port)")
            }
        } else {
            await MainActor.run {
                proxyTestResult = ProxyTestResult(success: false, message: "Cannot connect to \(server):\(port)")
                log(.warning, "SOCKS5 proxy test failed: \(server):\(port)")
            }
        }
    }
    
    func addDomain(_ domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = cleanDomain(trimmed)
        guard !cleaned.isEmpty else { return }
        guard !config.domains.contains(where: { $0.domain == cleaned }) else {
            log(.warning, "Domain \(cleaned) already exists")
            return
        }

        let entry = DomainEntry(domain: cleaned)
        config.domains.append(entry)
        saveConfig()
        log(.success, "Added domain: \(cleaned)")

        if isVPNConnected && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                let epoch = routeEpoch
                guard let gateway = await ensureGateway() else {
                    log(.error, "Cannot route \(cleaned): no local gateway detected. Try Refresh Routes.")
                    return
                }
                if let routes = await applyRoutesForDomain(entry.domain, gateway: gateway, source: cleaned) {
                    guard routeEpoch == epoch else {
                        await unstrandRoutes(attempted: Set(routes.map { $0.destination }), addFailed: [])
                        return
                    }
                    activeRoutes.append(contentsOf: routes)
                    if config.manageHostsFile {
                        await updateHostsFile()
                    }
                } else {
                    log(.warning, "DNS resolution failed for \(cleaned), retrying in 15s...")
                    scheduleRetry(for: cleaned)
                }
            }
        }
    }

    private func scheduleRetry(for domain: String) {
        pendingRetryTasks[domain]?.cancel()
        pendingRetryTasks[domain] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.retryDelayNs)
            } catch {
                return
            }
            guard let self else { return }
            await self.retryFailedDomain(domain)
            self.pendingRetryTasks.removeValue(forKey: domain)
        }
    }
    
    private func retryFailedDomain(_ domain: String) async {
        // Custom mode: a rule-domain that failed DNS re-triggers a full custom re-apply
        // (re-resolving every rule against live DNS), reusing scheduleRetry's per-domain
        // timer/dedup machinery. applyCustomRoutesInternal is gate-free, so we take the
        // route lock here (exactly as applyAllRoutes does); the diff-before-mutate guard
        // makes a redundant re-apply cheap, and when several domains failed together only
        // the first retry does real work (the rest find the gate held and skip). The
        // legacy per-domain path below is untouched — this branch never runs in classic
        // modes (usesCustomEngine is false there).
        if Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            guard isVPNConnected else { return }
            guard !activeRoutes.contains(where: { $0.source == domain }) else {
                log(.info, "Skipping retry for \(domain) — routes already exist")
                return
            }
            guard acquireRouteOperation() else {
                log(.info, "Retry skipped for \(domain): route operation in progress")
                return
            }
            defer { releaseRouteOperation() }
            log(.info, "Retrying custom DNS for \(domain)...")
            await applyCustomRoutesInternal(useCacheOnly: false, sendNotification: false)
            return
        }

        guard let entry = config.domains.first(where: { $0.domain == domain && $0.enabled }) else { return }
        guard isVPNConnected else { return }
        guard let gateway = await ensureGateway() else {
            log(.error, "Retry skipped for \(domain): no local gateway detected")
            return
        }
        guard !activeRoutes.contains(where: { $0.source == domain }) else {
            log(.info, "Skipping retry for \(domain) — routes already exist")
            return
        }

        guard acquireRouteOperation() else {
            log(.info, "Retry skipped for \(domain): route operation in progress")
            return
        }
        defer { releaseRouteOperation() }
        let epoch = routeEpoch

        log(.info, "Retrying DNS for \(domain)...")
        if let routes = await applyRoutesForDomain(entry.domain, gateway: gateway, source: domain) {
            guard routeEpoch == epoch else {
                await unstrandRoutes(attempted: Set(routes.map { $0.destination }), addFailed: [])
                return
            }
            activeRoutes.append(contentsOf: routes)
            if config.manageHostsFile {
                await updateHostsFile()
            }
            log(.success, "Retry succeeded for \(domain): \(routes.count) routes added")
        } else {
            log(.warning, "Retry failed for \(domain) — will resolve on next DNS refresh")
        }
    }
    
    private func cancelAllRetries() {
        pendingRetryTasks.values.forEach { $0.cancel() }
        pendingRetryTasks.removeAll()
    }

    // MARK: - Re-route latch (leak-critical: never drop a needed re-route)

    /// The 10s re-route cooldown: true while a re-route ran within the last 10s.
    /// Preserves the original cooldown semantics — a change during the window is
    /// deferred (latched), not dropped, and applies as soon as the window elapses.
    private func rerouteCooldownActive() -> Bool {
        guard let last = lastInterfaceReroute else { return false }
        return Date().timeIntervalSince(last) < 10
    }

    /// The re-route action itself: RECONCILE the installed routes against the desired set
    /// for the current gateway. The resulting kernel route SET is the same one the old
    /// teardown-then-rebuild produced — only the mutations taken to reach it changed.
    /// Callers must already have decided (via RerouteDecider) that a re-route is warranted
    /// and runnable.
    func performReroute() async {
        lastInterfaceReroute = Date()
        if localGateway != nil, acquireRouteOperation() {
            // Clear the latch HERE — at the START of the re-route, synchronously after
            // acquiring the gate and BEFORE the multi-second apply below. This ordering
            // is leak-critical: two checkVPNStatus passes can interleave on @MainActor
            // (refreshStatus spawns independent Tasks), so a concurrent pass that sees a
            // NEWER interface change while this apply is in flight finds the gate held
            // (isApplyingRoutes == true) and .latches it. Clearing at the END would wipe
            // that fresh latch and strand the routes on the now-stale interface — the
            // exact silent leak this fix exists to prevent. Clearing first lets the
            // fresh latch survive; the retry chain then drains it to the newest
            // interface. It also means the clear runs ONLY when a re-route actually runs,
            // never on the no-gateway / gate-not-acquired no-op branches.
            pendingReroute = false
            pendingRerouteReason = nil
            // Release via defer, like every other gate holder in this file. The body below
            // suspends (a full apply resolves DNS and awaits the helper), and an unwind at any
            // of those suspension points — task cancellation on quit, for instance — would skip
            // a trailing release and leak the gate. A leaked gate is silent and permanent:
            // acquireRouteOperation() try-acquires, so every later apply, re-route and DNS
            // refresh would give up without a word for the rest of the process's life.
            defer {
                isLoading = false
                releaseRouteOperation()
            }
            isLoading = true
            if let overrideApply = rerouteApplyOverrideForTests {
                // Test-only seam (nil in production): exercises the latch-clear timing
                // without touching the helper, kernel routes, or /etc/hosts.
                await overrideApply()
            } else {
                // #65: reconcile, do NOT tear down first.
                //
                // The old `removeAllRoutes()` + `applyAllRoutesInternal()` pair emptied
                // activeRoutes (removeAllRoutes clears it), which left `shouldSkipReapply`
                // structurally unable to fire on this path — activePairs was always empty, so
                // it never equalled desiredPairs. Every re-route therefore re-issued the ENTIRE
                // route set: N deletes from the teardown plus N delete-before-adds from the
                // re-apply, i.e. ~3N kernel mutations.
                //
                // In Bypass mode those routes egress via the LOCAL gateway, so a VPN interface
                // renumber (the usual trigger) changes no destination|gateway pair at all —
                // the entire storm rebuilt routes to the values they already had. Every one of
                // those mutations raises a kernel route-change event, and GlobalProtect's
                // connection monitor re-validates its own gateway route on each one; when that
                // lookup transiently fails it tears down and re-negotiates the tunnel.
                //
                // applyAllRoutesInternal already does the right thing on its own: it computes
                // the desired set, skips entirely when it matches what we hold (zero mutations),
                // and drops genuinely stale destinations via commitAppliedRoutes' orphan
                // cleanup. A real gateway change is still applied — in place, without a window
                // where the route is absent, which also removes a brief VPN-Only leak window
                // the teardown used to open.
                // forceReassert: re-assert every route against the KERNEL, not just against our
                // in-memory model.
                //
                // 3.1.7 removed `removeAllRoutes()` from this path to stop the churn, but that
                // teardown had a second, unnoticed job: it re-issued every route unconditionally,
                // so any divergence between our model and the actual routing table self-healed on
                // every interface change — exactly the event during which the kernel purges routes
                // bound to a departing utun. Without it, `shouldSkipReapply` compares desired
                // against our own bookkeeping, sees them equal, and performs ZERO kernel operations
                // while the kernel no longer holds the routes at all. The only remaining recovery
                // was the manual Refresh button.
                //
                // forceReassert restores that self-healing, and since 1.10.0 it is nearly free:
                // the helper reads each route first and writes only the ones that actually differ,
                // so a fully-correct set costs N reads and zero mutations — no route-change events,
                // nothing for a coexisting VPN client to react to. This is what makes the 3.1.7 and
                // 3.1.8 changes compose instead of cancelling each other out.
                await applyAllRoutesInternal(sendNotification: false, forceReassert: true)
            }
        } else if localGateway == nil {
            log(.error, "Re-route needed but no gateway detected")
        }
    }

    /// Drain a latched (deferred) re-route without waiting for the 30s status timer.
    /// Bounded and single-flight: at most one chain runs, it sleeps between attempts,
    /// and it stops as soon as the latch clears or after `rerouteRetryMaxAttempts`.
    /// If it gives up while still pending (e.g. a very long DNS refresh), the periodic
    /// checkVPNStatus re-latches and reschedules, so the re-route is never permanently
    /// lost. Matches the scheduleRetry(for:) idiom used for failed-domain retries.
    private func scheduleRerouteRetry() {
        guard rerouteRetryTask == nil else { return }   // a chain is already draining the latch
        rerouteRetryTask = Task { [weak self] in
            var attempts = 0
            while attempts < Self.rerouteRetryMaxAttempts {
                attempts += 1
                do {
                    try await Task.sleep(nanoseconds: Self.rerouteRetryDelayNs)
                } catch {
                    break   // cancelled (e.g. VPN disconnected)
                }
                guard let self else { return }
                if await self.attemptPendingReroute() { break }   // latch resolved
            }
            guard let self else { return }
            self.rerouteRetryTask = nil
            // Bounded on purpose: we STOP here even if the latch is still set (e.g. the
            // gateway or helper is persistently unavailable). Re-kicking a fresh chain from
            // inside this one would busy-loop every `rerouteRetryDelayNs` forever — a battery
            // drain, not a drain of the latch. The latch stays set; the periodic
            // checkVPNStatus() (30s status timer + network-change events) re-runs the SAME
            // RerouteDecider, which returns .latch while (pending && !canRunNow) and calls
            // scheduleRerouteRetry() again — a fresh bounded chain on the next pass. So a
            // still-blocked re-route is retried on the next status tick, never permanently
            // lost, and never in a tight loop.
        }
    }

    /// One attempt to satisfy a latched re-route against freshly-detected state.
    /// Returns true when the retry chain should STOP (re-routed, disconnected, or the
    /// latch was already cleared by checkVPNStatus); false to keep retrying. Re-runs
    /// the SAME pure RerouteDecider so the retry and the timer share one decision.
    private func attemptPendingReroute() async -> Bool {
        guard pendingReroute else { return true }   // already handled elsewhere
        guard isVPNConnected else {                 // disconnected during the wait — drop it
            pendingReroute = false
            pendingRerouteReason = nil
            return true
        }
        // Re-detect the gateway — it may have been missing when we latched.
        let gateway = await ensureGateway()
        let canApplyRoutes = gateway != nil && HelperManager.shared.isHelperInstalled
        switch RerouteDecider.decide(
            interfaceChanged: false,
            tailscaleChanged: false,
            pending: pendingReroute,
            isLoading: isLoading,
            isApplyingRoutes: isApplyingRoutes,
            cooldownActive: rerouteCooldownActive(),
            hasGateway: canApplyRoutes
        ) {
        case .reroute:
            log(.warning, pendingRerouteReason ?? "Re-routing through current gateway (deferred)")
            await performReroute()
            // performReroute cleared the latch at its START; if a concurrent
            // checkVPNStatus re-latched a NEWER change during the apply, pendingReroute
            // is true again — keep looping to drain it rather than exiting the chain.
            return !pendingReroute
        case .latch:
            return false   // still blocked (gate held / cooldown / not ready) — retry
        case .none:
            pendingReroute = false
            pendingRerouteReason = nil
            return true
        }
    }
    
    func removeDomain(_ domain: DomainEntry) {
        pendingRetryTasks[domain.domain]?.cancel()
        pendingRetryTasks.removeValue(forKey: domain.domain)

        guard acquireRouteOperation() else {
            // Config still updated even if routes can't be removed right now
            config.domains.removeAll { $0.id == domain.id }
            saveConfig()
            log(.info, "Removed domain: \(domain.domain) (route cleanup deferred)")
            return
        }
        Task {
            defer { releaseRouteOperation() }
            await removeRoutesForSource(domain.domain)
            config.domains.removeAll { $0.id == domain.id }
            saveConfig()
            if config.manageHostsFile { await updateHostsFile() }
            log(.info, "Removed domain: \(domain.domain)")
        }
    }
    
    /// Toggle a domain's enabled state and update routes
    func toggleDomain(_ domainId: UUID) {
        guard let index = config.domains.firstIndex(where: { $0.id == domainId }) else { return }
        config.domains[index].enabled.toggle()
        saveConfig()
        
        let domain = config.domains[index]
        log(.info, "\(domain.domain) \(domain.enabled ? "enabled" : "disabled")")
        
        if isVPNConnected && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                let epoch = routeEpoch
                if domain.enabled {
                    guard let gateway = await ensureGateway() else {
                        log(.error, "Cannot route \(domain.domain): no local gateway detected")
                        return
                    }
                    let resolvable = domain.domain
                    if let routes = await applyRoutesForDomain(resolvable, gateway: gateway, source: domain.domain) {
                        guard routeEpoch == epoch else {
                            await unstrandRoutes(attempted: Set(routes.map { $0.destination }), addFailed: [])
                            return
                        }
                        activeRoutes.append(contentsOf: routes)
                        if config.manageHostsFile {
                            await updateHostsFile()
                        }
                    }
                } else {
                    await removeRoutesForSource(domain.domain)
                    if config.manageHostsFile { await updateHostsFile() }
                }
            }
        }
    }

    /// Bulk enable/disable all domains with loading state (incremental)
    func setAllDomainsEnabled(_ enabled: Bool) {
        // Get domains that need to change
        let domainsToChange = config.domains.filter { $0.enabled != enabled }

        // Update config
        for i in config.domains.indices {
            config.domains[i].enabled = enabled
        }
        saveConfig()

        log(.info, enabled ? "Enabled all domains" : "Disabled all domains")

        guard isVPNConnected, acquireRouteOperation() else { return }
        Task {
            defer { releaseRouteOperation() }
            let epoch = routeEpoch
            var passAdded: Set<String> = []  // #61: kernel dests added across this pass, for unstrand-on-preempt
            let gateway: String? = enabled ? await ensureGateway() : nil
            if enabled && gateway == nil {
                log(.error, "Cannot enable domains: no local gateway detected")
                return
            }
            for domain in domainsToChange {
                guard routeEpoch == epoch else {
                    await unstrandRoutes(attempted: passAdded, addFailed: [])
                    return
                }
                if enabled, let gw = gateway {
                    let resolvable = domain.domain
                    if let routes = await applyRoutesForDomain(resolvable, gateway: gw, source: domain.domain, persistCache: false) {
                        passAdded.formUnion(routes.map { $0.destination })
                        guard routeEpoch == epoch else {
                            await unstrandRoutes(attempted: passAdded, addFailed: [])
                            return
                        }
                        activeRoutes.append(contentsOf: routes)
                    }
                } else if !enabled {
                    await removeRoutesForSource(domain.domain)
                }
            }
            saveDNSCache()
            if config.manageHostsFile {
                await updateHostsFile()
            }
        }
    }
    
    /// Remove all routes matching a source (domain name or service name)
    /// Only removes kernel routes if no other source shares the same destination
    private func removeRoutesForSource(_ source: String) async {
        let routesToRemove = activeRoutes.filter { $0.source == source }
        let destinationsStillNeeded = Set(activeRoutes.filter { $0.source != source }.map { $0.destination })

        // Deduplicate destinations to avoid attempting the same kernel removal twice
        var seenDestinations: Set<String> = []
        var kernelRemoved = 0
        var failedKernelRemovals: Set<String> = []
        for route in routesToRemove {
            guard seenDestinations.insert(route.destination).inserted else { continue }
            if !destinationsStillNeeded.contains(route.destination) {
                if await removeRoute(route.destination) {
                    kernelRemoved += 1
                } else {
                    failedKernelRemovals.insert(route.destination)
                }
            }
        }

        await MainActor.run {
            // Remove entries for this source, but retain entries whose kernel removal failed
            activeRoutes.removeAll { route in
                route.source == source && !failedKernelRemovals.contains(route.destination)
            }
        }

        if !routesToRemove.isEmpty {
            if failedKernelRemovals.isEmpty {
                log(.info, "Removed \(routesToRemove.count) route entries for \(source) (\(kernelRemoved) kernel routes)")
            } else {
                log(.warning, "Removed routes for \(source): \(kernelRemoved) kernel routes removed, \(failedKernelRemovals.count) retained (kernel removal failed)")
            }
        }
    }
    
    /// Apply routes for a single service (used when adding/editing custom services while VPN is connected)
    private func applyRoutesForService(_ service: ServiceEntry) async {
        guard let gateway = localGateway else { return }
        await applyRoutesForService(service, gateway: gateway)
    }

    // MARK: - Inverse Domain Management

    func addInverseDomain(_ domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect CIDR input (e.g., "192.168.1.0/24") — bypass domain cleaning
        let cidr = isValidCIDR(trimmed)
        let cleaned: String
        if cidr {
            cleaned = trimmed
        } else if trimmed.contains("/") {
            log(.warning, "Invalid CIDR notation: \(trimmed)")
            return
        } else {
            cleaned = cleanDomain(trimmed)
            guard !cleaned.isEmpty else { return }
        }

        guard !config.inverseDomains.contains(where: { $0.domain == cleaned }) else {
            log(.warning, "VPN Only entry \(cleaned) already exists")
            return
        }
        let inverseEntry = DomainEntry(domain: cleaned, isCIDR: cidr)
        config.inverseDomains.append(inverseEntry)
        saveConfig()
        log(.success, "Added VPN Only \(cidr ? "CIDR" : "")domain: \(cleaned)")

        if isVPNConnected && config.routingMode == .vpnOnly && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                let epoch = routeEpoch
                guard let gw = vpnGateway else {
                    log(.error, "Cannot route \(cleaned): no VPN gateway detected")
                    return
                }
                if cidr {
                    if await addRoute(cleaned, gateway: gw, isNetwork: true) {
                        guard routeEpoch == epoch else {
                            await unstrandRoutes(attempted: [cleaned], addFailed: [])
                            return
                        }
                        activeRoutes.append(ActiveRoute(
                            destination: cleaned,
                            gateway: gw,
                            source: cleaned,
                            timestamp: Date()
                        ))
                        log(.success, "Routed CIDR \(cleaned) through VPN")
                    }
                } else if let routes = await applyRoutesForDomain(inverseEntry.domain, gateway: gw, source: cleaned) {
                    guard routeEpoch == epoch else {
                        await unstrandRoutes(attempted: Set(routes.map { $0.destination }), addFailed: [])
                        return
                    }
                    activeRoutes.append(contentsOf: routes)
                    if config.manageHostsFile { await updateHostsFile() }
                }
            }
        }
    }

    func removeInverseDomain(_ domain: DomainEntry) {
        guard acquireRouteOperation() else {
            config.inverseDomains.removeAll { $0.id == domain.id }
            saveConfig()
            log(.info, "Removed VPN Only \(domain.isCIDR ? "CIDR" : "domain"): \(domain.domain) (route cleanup deferred)")
            return
        }
        Task {
            defer { releaseRouteOperation() }
            await removeRoutesForSource(domain.domain)
            config.inverseDomains.removeAll { $0.id == domain.id }
            saveConfig()
            if config.manageHostsFile { await updateHostsFile() }
            log(.info, "Removed VPN Only \(domain.isCIDR ? "CIDR" : "domain"): \(domain.domain)")
        }
    }

    func toggleInverseDomain(_ domainId: UUID) {
        guard let index = config.inverseDomains.firstIndex(where: { $0.id == domainId }) else { return }
        config.inverseDomains[index].enabled.toggle()
        saveConfig()

        let domain = config.inverseDomains[index]
        log(.info, "VPN Only: \(domain.domain) \(domain.enabled ? "enabled" : "disabled")")

        if isVPNConnected && config.routingMode == .vpnOnly && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                let epoch = routeEpoch
                if domain.enabled {
                    guard let gw = vpnGateway else { return }
                    if domain.isCIDR {
                        // CIDR: add network route directly
                        if await addRoute(domain.domain, gateway: gw, isNetwork: true) {
                            guard routeEpoch == epoch else {
                                await unstrandRoutes(attempted: [domain.domain], addFailed: [])
                                return
                            }
                            activeRoutes.append(ActiveRoute(
                                destination: domain.domain,
                                gateway: gw,
                                source: domain.domain,
                                timestamp: Date()
                            ))
                        }
                    } else {
                        let resolvable = domain.domain
                        if let routes = await applyRoutesForDomain(resolvable, gateway: gw, source: domain.domain) {
                            guard routeEpoch == epoch else {
                                await unstrandRoutes(attempted: Set(routes.map { $0.destination }), addFailed: [])
                                return
                            }
                            activeRoutes.append(contentsOf: routes)
                            if config.manageHostsFile { await updateHostsFile() }
                        }
                    }
                } else {
                    await removeRoutesForSource(domain.domain)
                    if config.manageHostsFile { await updateHostsFile() }
                }
            }
        }
    }

    func setAllInverseDomainsEnabled(_ enabled: Bool) {
        for i in config.inverseDomains.indices {
            config.inverseDomains[i].enabled = enabled
        }
        saveConfig()
        log(.info, enabled ? "Enabled all VPN Only domains" : "Disabled all VPN Only domains")

        if isVPNConnected && config.routingMode == .vpnOnly && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                await removeAllRoutes()
                await applyAllRoutesInternal(sendNotification: false)
                if config.manageHostsFile { await updateHostsFile() }
            }
        }
    }

    /// Switch routing mode and re-apply routes
    func setRoutingMode(_ mode: RoutingMode) {
        guard config.routingMode != mode else { return }

        // Entering Custom mode: ensure the routes/rules model exists so the user's
        // bypass/vpnOnly lists keep routing after the switch. This is a pure migration
        // (Config.preparedForCustomMode) shared with the CLI so both surfaces behave
        // identically. It supersedes the old `schemaVersion < 2` guard, which let a
        // schemaVersion-2-but-unruled config enter Custom with zero rules and silently
        // drop every listed domain onto the OS default.
        if mode == .custom {
            config = config.preparedForCustomMode()
        }

        config.routingMode = mode
        saveConfig()
        log(.info, "Routing mode changed to \(mode.displayName)")

        if isVPNConnected && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                // Re-detect VPN gateway when switching to VPN Only
                // (initial detection may be stale if VPN routing wasn't ready yet)
                if mode == .vpnOnly {
                    vpnGateway = await detectVPNGateway()
                }
                await removeAllRoutes()
                await applyAllRoutesInternal(sendNotification: false)
                if activeRoutes.isEmpty {
                    log(.warning, "No routes applied after mode switch — DNS refresh will retry")
                }
            }
        }
    }

    // MARK: - Custom Service Management

    func addCustomService(name: String, domains: [String], ipRanges: [String]) {
        let id = "custom_\(UUID().uuidString.prefix(8).lowercased())"
        let service = ServiceEntry(id: id, name: name, enabled: true, domains: domains, ipRanges: ipRanges, isCustom: true)
        config.services.append(service)
        saveConfig()
        log(.success, "Added custom service: \(name)")

        // Apply routes immediately if VPN is connected and in bypass mode
        if isVPNConnected && config.routingMode == .bypass && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                await applyRoutesForService(service)
                if config.manageHostsFile { await updateHostsFile() }
            }
        }
    }

    func updateCustomService(id: String, name: String, domains: [String], ipRanges: [String]) {
        guard let index = config.services.firstIndex(where: { $0.id == id && $0.isCustom }) else { return }
        let oldName = config.services[index].name
        let wasEnabled = config.services[index].enabled
        config.services[index] = ServiceEntry(id: id, name: name, enabled: wasEnabled, domains: domains, ipRanges: ipRanges, isCustom: true)
        saveConfig()
        log(.info, "Updated custom service: \(name)")

        // Reconcile live routes: remove old, add new if enabled
        if isVPNConnected && wasEnabled && config.routingMode == .bypass && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                await removeRoutesForSource(oldName)
                // Re-tag any retained entries from failed kernel removals to new name,
                // so they don't orphan under the old source and block future cleanup
                if oldName != name {
                    activeRoutes = activeRoutes.map { route in
                        guard route.source == oldName else { return route }
                        return ActiveRoute(destination: route.destination, gateway: route.gateway, source: name, timestamp: route.timestamp)
                    }
                }
                await applyRoutesForService(config.services[index])
                if config.manageHostsFile { await updateHostsFile() }
            }
        }
    }

    func removeCustomService(_ serviceId: String) {
        guard let index = config.services.firstIndex(where: { $0.id == serviceId && $0.isCustom }) else { return }
        let name = config.services[index].name
        let serviceDomains = config.services[index].domains
        guard acquireRouteOperation() else {
            // Config still updated even if routes can't be removed right now
            config.services.remove(at: index)
            saveConfig()
            log(.info, "Removed custom service: \(name) (route cleanup deferred)")
            return
        }
        Task {
            defer { releaseRouteOperation() }
            await removeRoutesForSource(name)
            // If routes were retained (kernel removal failed), save the domain list
            // so updateHostsFile can reconstruct hosts entries for this orphaned source
            if activeRoutes.contains(where: { $0.source == name }) {
                orphanedServiceDomains[name] = serviceDomains
            }
            config.services.remove(at: index)
            saveConfig()
            if config.manageHostsFile { await updateHostsFile() }
            log(.info, "Removed custom service: \(name)")
        }
    }

    func toggleService(_ serviceId: String) {
        guard let index = config.services.firstIndex(where: { $0.id == serviceId }) else { return }
        config.services[index].enabled.toggle()
        saveConfig()
        
        let service = config.services[index]
        log(.info, "\(service.name) \(service.enabled ? "enabled" : "disabled")")
        
        // Incremental route apply/remove
        if isVPNConnected && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                if service.enabled {
                    guard let gateway = await ensureGateway() else {
                        log(.error, "Cannot route \(service.name): no local gateway detected")
                        return
                    }
                    await applyRoutesForService(service, gateway: gateway)
                } else {
                    await removeRoutesForSource(service.name)
                }
                if config.manageHostsFile { await updateHostsFile() }
            }
        }
    }
    
    /// Apply routes for a single service (incremental add) - parallel DNS + batch routes
    private func applyRoutesForService(_ service: ServiceEntry, gateway: String) async {
        let epoch = routeEpoch
        var newRoutes: [ActiveRoute] = []
        var routesToAdd: [(destination: String, gateway: String, isNetwork: Bool)] = []

        // Track existing destinations (for kernel-add dedup) and existing ownership (for source dedup)
        let existingDestinations = Set(activeRoutes.map { $0.destination })
        let existingOwnership = Set(activeRoutes.map { "\($0.source)|\($0.destination)" })
        var kernelAddedDests: Set<String> = []

        // Capture DNS settings for parallel resolution
        let userDNS = detectedDNSServer
        let fallbackDNS = config.fallbackDNS

        // Resolve ALL domains in parallel (not sequentially)
        let domainResults = await withTaskGroup(of: (String, [String]?).self) { group in
            for domain in service.domains {
                group.addTask {
                    let ips = await DNSResolver.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
                    return (domain, ips)
                }
            }

            var results: [(String, [String]?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        // Collect routes from resolved domains
        var cacheUpdated = false
        for (domain, ips) in domainResults {
            guard let ips = ips else { continue }

            // Cache all IPs (disk) and first IP (memory) for hosts file and startup
            dnsDiskCache[domain] = ips
            cacheUpdated = true
            if let firstIP = ips.first {
                dnsCache[domain] = firstIP
            }

            for ip in ips {
                // Only add kernel route if destination is new (not already in kernel)
                if !existingDestinations.contains(ip) && !kernelAddedDests.contains(ip) {
                    kernelAddedDests.insert(ip)
                    routesToAdd.append((destination: ip, gateway: gateway, isNetwork: false))
                }
                // Always record ownership entry if this service doesn't already own this destination
                let ownershipKey = "\(service.name)|\(ip)"
                if !existingOwnership.contains(ownershipKey) {
                    newRoutes.append(ActiveRoute(destination: ip, gateway: gateway, source: service.name, timestamp: Date()))
                }
            }
        }

        // Add IP ranges (no DNS needed)
        for range in service.ipRanges {
            if !existingDestinations.contains(range) && !kernelAddedDests.contains(range) {
                kernelAddedDests.insert(range)
                routesToAdd.append((destination: range, gateway: gateway, isNetwork: true))
            }
            let ownershipKey = "\(service.name)|\(range)"
            if !existingOwnership.contains(ownershipKey) {
                newRoutes.append(ActiveRoute(destination: range, gateway: gateway, source: service.name, timestamp: Date()))
            }
        }

        // Persist DNS cache so cache-based startup can use these IPs
        if cacheUpdated { saveDNSCache() }

        // Apply new kernel routes in single batch, exclude failed destinations from ownership
        var failedDests: Set<String> = []
        if !routesToAdd.isEmpty && HelperManager.shared.isHelperInstalled {
            let result = await addRoutesBatchTracked(routes: routesToAdd)
            failedDests = Set(result.failedDestinations)
            if result.failureCount > 0 {
                log(.warning, "Batch route add for \(service.name): \(result.successCount) succeeded, \(result.failureCount) failed")
            }
        }

        // Only record ownership for destinations confirmed in kernel
        let confirmedRoutes = newRoutes.filter { route in
            // If it was a new kernel route that failed, exclude it
            if failedDests.contains(route.destination) && !existingDestinations.contains(route.destination) {
                return false
            }
            return true
        }

        // Preemption check before committing
        guard routeEpoch == epoch else {
            log(.info, "Service apply aborted for \(service.name): routes were cleared during operation")
            await unstrandRoutes(attempted: Set(routesToAdd.map { $0.destination }), addFailed: failedDests)
            return
        }

        await MainActor.run {
            activeRoutes.append(contentsOf: confirmedRoutes)
        }

        if !confirmedRoutes.isEmpty {
            log(.success, "Added \(confirmedRoutes.count) route entries for \(service.name) (\(routesToAdd.count - failedDests.count) kernel routes)")
        }
    }
    
    /// Bulk enable/disable all services with loading state (incremental)
    func setAllServicesEnabled(_ enabled: Bool) {
        // Get services that need to change
        let servicesToChange = config.services.filter { $0.enabled != enabled }

        // Update config
        for i in config.services.indices {
            config.services[i].enabled = enabled
        }
        saveConfig()

        log(.info, enabled ? "Enabled all services" : "Disabled all services")

        guard isVPNConnected, acquireRouteOperation() else { return }
        Task {
            defer { releaseRouteOperation() }
            let epoch = routeEpoch
            let gateway: String? = enabled ? await ensureGateway() : nil
            if enabled && gateway == nil {
                log(.error, "Cannot enable services: no local gateway detected")
                return
            }
            for service in servicesToChange {
                guard routeEpoch == epoch else { return }
                if enabled, let gw = gateway {
                    await applyRoutesForService(service, gateway: gw)
                } else if !enabled {
                    await removeRoutesForSource(service.name)
                }
            }
            if config.manageHostsFile { await updateHostsFile() }
        }
    }
    
    // MARK: - Route Verification
    
    func verifyRoutes() async {
        log(.info, "Verifying routes...")
        routeVerificationResults.removeAll()
        
        // Get unique destinations to verify
        var destinationsToVerify: Set<String> = []
        for route in activeRoutes {
            // Only verify actual IPs, not CIDR ranges
            if isValidIP(route.destination) {
                destinationsToVerify.insert(route.destination)
            }
        }
        
        var failedCount = 0
        let sortedDestinations = destinationsToVerify.sorted()

        for destination in sortedDestinations.prefix(10) { // Limit to 10 to avoid too many pings
            let result = await verifyRoute(destination)
            routeVerificationResults[destination] = result
            
            if !result.isReachable {
                failedCount += 1
                NotificationManager.shared.notifyRouteVerificationFailed(
                    route: destination,
                    reason: result.error ?? "Unreachable"
                )
            }
        }
        
        let testedCount = min(destinationsToVerify.count, 10)
        if failedCount > 0 {
            log(.warning, "Route verification: \(failedCount) of \(testedCount) tested routes failed\(destinationsToVerify.count > 10 ? " (\(destinationsToVerify.count) total, sampled 10)" : "")")
        } else if testedCount > 0 {
            log(.success, "Route verification: All \(testedCount) tested routes are reachable\(destinationsToVerify.count > 10 ? " (\(destinationsToVerify.count) total)" : "")")
        }
    }
    
    func verifyRoute(_ destination: String) async -> RouteVerificationResult {
        let startTime = Date()
        
        // Use helper with timeout - ping itself has 3s timeout, we add 1s buffer
        guard let result = await runProcessAsync("/sbin/ping", arguments: ["-c", "1", "-t", "3", destination], timeout: 4.0) else {
            return RouteVerificationResult(
                destination: destination,
                isReachable: false,
                latency: nil,
                timestamp: Date(),
                error: "Ping timed out"
            )
        }
        
        let elapsed = Date().timeIntervalSince(startTime) * 1000 // Convert to ms
        let output = result.output
        
        // Parse ping output for round-trip time
        var latency: Double? = nil
        if let timeRange = output.range(of: "time=") {
            let timeStr = output[timeRange.upperBound...]
            if let endRange = timeStr.range(of: " ms") {
                let msStr = String(timeStr[..<endRange.lowerBound])
                latency = Double(msStr)
            }
        }
        
        let isReachable = result.exitCode == 0
        
        return RouteVerificationResult(
            destination: destination,
            isReachable: isReachable,
            latency: latency ?? (isReachable ? elapsed : nil),
            timestamp: Date(),
            error: isReachable ? nil : "Host unreachable"
        )
    }
    
    // MARK: - Private Methods
    
    /// One sweep per launch: has the orphan sweep already run this session?
    private var didStartupSweep = false

    /// Which table entries are OUR orphans: tagged RTF_PROTO1 (only this app sets it) yet not
    /// wanted by the current session. Pure so it can be unit-tested against synthetic tables.
    nonisolated static func orphanedDestinations(
        table: [RouteKernel.KernelRoute], desired: Set<String>
    ) -> [String] {
        table.filter { $0.isOurs }.map(\.destinationString).filter { !desired.contains($0) }
    }

    /// The MIRROR of `orphanedDestinations`: destinations this session still wants that are no
    /// longer in the kernel table. macOS drops an interface's routes when the effective physical
    /// path changes, and nothing the app already watches survives that (issue #94): with Wi-Fi and
    /// Ethernet both up on one subnet, switching primary keeps `NWPath.status` `.satisfied`, keeps
    /// the same gateway, and keeps both interfaces in `availableInterfaces`, so the VPN interface,
    /// the Tailscale profile and the gateway all compare equal and `RerouteDecider` correctly says
    /// there is nothing to do. `shouldSkipReapply` then compares the desired set against the app's
    /// OWN bookkeeping, which still claims the routes are installed.
    ///
    /// The kernel is the only witness that disagrees, so ask it. RTF_PROTO1 marks ours, exactly as
    /// the startup sweep relies on, which makes this the same question asked the other way round.
    /// Presence is tested by destination alone, deliberately NOT by the RTF_PROTO1 tag the
    /// startup sweep uses, and not by gateway. Two reasons, both about not making things worse:
    ///
    /// - The helper skips the write when a correct route already exists, which leaves that
    ///   destination UNTAGGED while the app still lists it as active. Requiring the tag would
    ///   then report it missing on every pass, restore it as a no-op, and repeat every 30s
    ///   forever.
    /// - A destination that has any route at all is not the failure being fixed here. This
    ///   restores routes that VANISHED; a route present but pointing at the wrong next hop is
    ///   the reroute path's job, and duplicating that here would have the two fighting.
    nonisolated static func missingDestinations(
        table: [RouteKernel.KernelRoute], desired: Set<String>
    ) -> [String] {
        let present = Set(table.map(\.destinationString))
        return desired.subtracting(present).sorted()
    }

    /// Re-install routes the kernel dropped underneath us, e.g. after the primary physical
    /// interface changed. Runs on every status refresh (the 30s timer and each network change),
    /// so recovery does not depend on correctly classifying WHY they went missing.
    ///
    /// Cheap when there is nothing to do: `currentTable()` is one silent NET_RT_DUMP — it forks
    /// nothing and broadcasts nothing to routing-socket listeners, which is what makes it safe to
    /// run on a timer next to a VPN client that reads its own gateway route. Zero missing routes
    /// means zero writes.
    func reconcileMissingRoutes() async {
        guard !isShuttingDown, !activeRoutes.isEmpty, HelperManager.shared.isHelperInstalled else { return }
        guard let table = RouteKernel.currentTable() else { return }

        // Deduplicate first: activeRoutes can hold several entries for one destination when
        // more than one domain resolves to the same address.
        var gatewayFor: [String: String] = [:]
        for r in activeRoutes where gatewayFor[r.destination] == nil { gatewayFor[r.destination] = r.gateway }
        let missing = Self.missingDestinations(table: table, desired: Set(gatewayFor.keys))
        guard !missing.isEmpty else { return }

        // Take the gate only once there is real work, so a no-op reconcile never blocks an apply.
        guard acquireRouteOperation() else { return }
        defer { releaseRouteOperation() }
        // removeAllRoutes() does NOT take that gate — it bumps routeEpoch instead, so a teardown
        // can complete while the batch below is in flight. Captured before the await, checked
        // after, exactly as every other apply path does: without it a quit could clear
        // activeRoutes and this add would then re-install routes the app no longer has any record
        // of, which is the strand class of #61 and #67.
        let epoch = routeEpoch

        // Restoring is an apply path like any other, so it takes the same refusal: in VPN Only
        // under GlobalProtect the desired set IS the catch-alls, and putting those back would
        // route every packet around the tunnel and tear GP down. The guard also sweeps any
        // catch-alls already stranded, so reaching it is useful rather than merely defensive.
        if refuseVPNOnlyUnderGlobalProtect() { return }

        log(.warning, "\(missing.count) route(s) vanished from the routing table — restoring")
        let batch = missing.compactMap { destination -> (destination: String, gateway: String, isNetwork: Bool)? in
            guard let gateway = gatewayFor[destination] else { return nil }
            return (destination: destination, gateway: gateway, isNetwork: destination.contains("/"))
        }
        let result = await addRoutesBatchTracked(routes: batch)

        // Epoch check and bookkeeping are atomic on @MainActor — no await between them.
        guard routeEpoch == epoch else {
            log(.warning, "Route restore aborted: routes were cleared during the operation")
            await unstrandRoutes(attempted: Set(batch.map(\.destination)),
                                 addFailed: Set(result.failedDestinations))
            return
        }
        // These destinations were already in activeRoutes — restoring them only had to put them
        // back in the kernel, so all that is left is to clear them from the pending set.
        // addRoutesBatchTracked already removed the failures.
        pendingKernelAdds.subtract(batch.map(\.destination))

        if result.failureCount > 0 {
            log(.error, "Restored \(result.successCount) of \(batch.count) vanished route(s); \(result.failureCount) failed")
        } else {
            log(.success, "Restored \(result.successCount) vanished route(s)")
        }
    }

    /// Startup crash/unclean-quit recovery — the permanent fix for the issue #67 class.
    ///
    /// Every route this app installs is tagged RTF_PROTO1 in the kernel, so a plain silent
    /// table dump identifies ours with no journal and no prior state ("no other state needs to
    /// be instantiated before this runs" — the property that makes this recovery reliable).
    /// Anything tagged but not wanted by THIS session — including VPN Only catch-alls stranded
    /// by a kill — is removed before the first apply. Wanted routes are left in place: the
    /// snapshot-reconciling batch add makes them zero-event no-ops.
    func startupSweepIfNeeded(desired: [String]) async {
        guard !didStartupSweep else { return }
        didStartupSweep = true
        guard let table = RouteKernel.currentTable() else { return }
        let orphans = Self.orphanedDestinations(table: table, desired: Set(desired))
        guard !orphans.isEmpty else { return }
        log(.warning, "Startup sweep: removing \(orphans.count) route(s) left by a previous run")
        _ = await removeRoutesBatchVia(orphans)
    }

    /// The only sanctioned way to batch-add routes to the kernel. Records destinations as
    /// pending BEFORE the write (so teardown can always find them) and refuses outright once
    /// shutdown has begun (so nothing lands mid-teardown).
    func addRoutesBatchTracked(
        routes: [(destination: String, gateway: String, isNetwork: Bool)]
    ) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        guard !isShuttingDown else {
            log(.warning, "Refusing batch add of \(routes.count) route(s): shutdown in progress")
            return (0, routes.count, routes.map { $0.destination }, "shutdown in progress")
        }
        // Never touch the route to the VPN's own gateway. Its client keeps the tunnel alive by
        // reaching that address via the PHYSICAL interface; vendor documentation describes
        // connect-then-flap-within-a-minute when that stops being true.
        var routes = routes
        if let gw = vpnGateway, !gw.hasPrefix("iface:") {
            let protected = routes.filter { $0.destination == gw || $0.destination == gw + "/32" }
            if !protected.isEmpty {
                log(.warning, "Refusing \(protected.count) route(s) targeting the VPN gateway \(gw) — protected")
                routes.removeAll { $0.destination == gw || $0.destination == gw + "/32" }
                if routes.isEmpty { return (0, protected.count, protected.map { $0.destination }, "protected: VPN gateway") }
            }
        }
        pendingKernelAdds.formUnion(routes.map { $0.destination })
        let result = await HelperManager.shared.addRoutesBatch(routes: routes)
        // Failed destinations never reached the kernel — nothing to sweep for them.
        pendingKernelAdds.subtract(result.failedDestinations)
        return result
    }

    /// Acquire exclusive route operation lock. Returns false if another operation is running.
    /// @MainActor guarantees atomic check-and-set between await suspension points.
    private func acquireRouteOperation() -> Bool {
        guard !isShuttingDown, !isApplyingRoutes else { return false }
        isApplyingRoutes = true
        return true
    }

    /// Release exclusive route operation lock.
    private func releaseRouteOperation() {
        isApplyingRoutes = false
    }
    
    private func ensureGateway() async -> String? {
        if let gw = localGateway,
           let detected = gatewayDetectedAt,
           Date().timeIntervalSince(detected) < 10 {
            return gw
        }
        localGateway = await detectLocalGateway()
        gatewayDetectedAt = localGateway != nil ? Date() : nil
        if let gw = localGateway {
            log(.info, "Gateway re-detected: \(gw)")
        }
        return localGateway
    }
    
    private func detectLocalGateway() async -> String? {
        // Enumerate the machine's ACTUAL network services, in macOS's own order.
        //
        // This used to try a hardcoded list — "Wi-Fi", "Ethernet", "USB 10/100/1000 LAN",
        // "Thunderbolt Ethernet", "USB-C LAN". Any Mac whose active link is named something else
        // matched nothing, which is the common case for docks: "USB3.0 5K Graphic Docking",
        // "Dell Universal Dock D6000". Detection then fell through to the route table, and once a
        // VPN is connected the default route's gateway is the VPN'S OWN tunnel gateway. Every
        // "bypass" route was then installed pointing INTO the tunnel — bypassing nothing — and
        // every VPN state change moved the gateway, so the whole route set was torn down and
        // rebuilt on each flap. Enumerating the real services removes the guesswork entirely.
        if let listing = await runProcessAsync("/usr/sbin/networksetup", arguments: ["-listnetworkserviceorder"], timeout: 5.0) {
            for service in NetworkServiceOrder.parse(listing.output) {
                if let gateway = await getGatewayForService(service) {
                    return gateway
                }
            }
        }

        // Fallback: parse the route table, refusing a tunnel (see parseDefaultGateway).
        return await parseDefaultGateway()
    }
    
    private func getGatewayForService(_ service: String) async -> String? {
        guard let result = await runProcessAsync("/usr/sbin/networksetup", arguments: ["-getinfo", service], timeout: 3.0) else {
            return nil
        }
        
        for line in result.output.components(separatedBy: "\n") {
            if line.hasPrefix("Router:") {
                let gateway = line.replacingOccurrences(of: "Router:", with: "").trimmingCharacters(in: .whitespaces)
                if gateway != "none" && !gateway.isEmpty && isValidIP(gateway) {
                    return gateway
                }
            }
        }
        
        return nil
    }

    /// Make an in-memory config change live: reconcile proxy listeners and/or reapply the
    /// custom-engine kernel routes, per the caller's policy. The caller persists (saveConfig)
    /// and mutates config BEFORE calling this. Strictly a plumbing dedup of the tail that was
    /// copied across the mutation surfaces — every per-site policy is an explicit argument.
    func reconcileAfterConfigChange(reconcileListeners: Bool, reapplyRoutes: Bool, sendNotification: Bool = false) async {
        if reconcileListeners { await reconcileProxyListeners() }
        if reapplyRoutes { await detectAndApplyRoutesAsync(sendNotification: sendNotification) }
    }

    /// Start/stop proxy-route listeners to match the current config (P1,
    /// VPN-Bypass-3sc.8). Safe to call any time; a no-op when there are no
    /// enabled proxy routes, so it changes nothing for existing users.
    func reconcileProxyListeners() async {
        // Custom mode implies the multi-route surface, so its proxy/tailscale routes get
        // loopback listeners too — not only the legacy opt-in multiRouteEnabled flag.
        guard config.multiRouteEnabled || config.routingMode == .custom else {
            ProxyListenerManager.shared.stopAll()
            return
        }
        let iface = await detectPhysicalInterface()
        ProxyListenerManager.shared.reconcile(routes: listenerRoutesRespectingGPShadow(),
                                             boundInterface: iface,
                                             localSecret: ensureLocalProxySecret())
    }

    /// `config.routes` with any Tailscale-peer route whose IP is inside GlobalProtect's
    /// 100.112.0.0/12 capture range dropped WHILE GP is up: a listener there would dial
    /// a peer address the GP tunnel hijacks (longest-prefix match), so the hop would
    /// silently leave via GP instead of the tailnet. The route stays in config and its
    /// listener returns as soon as GP disconnects. (Tailnet-probe research, 2026-07-03 — see the guardCatchAllUnderGlobalProtect rationale.)
    func listenerRoutesRespectingGPShadow() -> [Route] {
        guard vpnType == .globalProtect else { return config.routes }
        return config.routes.filter { route in
            guard let host = route.proxyHost,
                  ProxyListenerManager.isTailnetHostShadowedByGlobalProtect(host) else { return true }
            log(.warning, "Route '\(route.name)' targets a Tailscale peer (\(host)) inside GlobalProtect's 100.112.0.0/12 range — pausing its listener to avoid a hijack. Pick a peer outside that range.")
            return false
        }
    }

    // MARK: - Tailscale peers (for the Routes UI picker)

    /// A tailnet peer surfaced for the Routes editor: friendly name + its 100.x IP.
    struct TailscalePeer: Identifiable, Equatable {
        let name: String
        let ip: String
        let online: Bool
        /// The peer advertises itself as a Tailscale exit node (`ExitNodeOption`). Worth
        /// showing because it is usually a tiny minority of a tailnet, and because it is the
        /// only peer class that can carry general internet traffic without extra setup.
        let exitNodeCapable: Bool
        var id: String { ip }
    }

    /// Enumerate tailnet peers (name + 100.x IPv4 + online) so a Tailscale-peer route can
    /// be created by picking a peer instead of typing an IP. Empty if Tailscale isn't
    /// installed/running. Online peers first, then alphabetical.
    func listTailscalePeers() async -> [TailscalePeer] {
        guard let json = await readTailscaleStatusJSONWithPeers(),
              let peers = json["Peer"] as? [String: [String: Any]] else { return [] }
        var out: [TailscalePeer] = []
        for (_, peer) in peers {
            guard let ips = peer["TailscaleIPs"] as? [String],
                  let ip4 = ips.first(where: { ProxyListenerManager.isTailnetHost($0) }) else { continue }
            let host = (peer["HostName"] as? String)
                ?? (peer["DNSName"] as? String)?.components(separatedBy: ".").first
                ?? ip4
            let online = (peer["Online"] as? Bool) ?? false
            let exitCapable = (peer["ExitNodeOption"] as? Bool) ?? false
            out.append(TailscalePeer(name: host, ip: ip4, online: online, exitNodeCapable: exitCapable))
        }
        // Exit-capable first, then online, then alphabetical — the ordering that puts the
        // peers that can actually carry traffic at the top of a 17-device list.
        return out.sorted { a, b in
            if a.exitNodeCapable != b.exitNodeCapable { return a.exitNodeCapable }
            if a.online != b.online { return a.online }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    /// Like `readTailscaleStatusJSON` but WITH peers (the self-only reader omits them).
    private func readTailscaleStatusJSONWithPeers() async -> [String: Any]? {
        for path in Self.tailscaleCLIPaths where FileManager.default.fileExists(atPath: path) {
            guard let result = await runProcessAsync(path, arguments: ["status", "--json"], timeout: 3.0) else { continue }
            if let data = result.output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        return nil
    }

    /// The physical interface (e.g. "en0") whose route reaches the local gateway.
    /// Proxy upstream sockets bind to it so their hop leaves on real Wi-Fi/Ethernet
    /// instead of a full-tunnel VPN's utun.
    private func detectPhysicalInterface() async -> String? {
        guard let gateway = localGateway else { return nil }
        guard let result = await runProcessAsync("/sbin/route", arguments: ["-n", "get", gateway], timeout: 3.0) else { return nil }
        for line in result.output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let iface = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                return iface.isEmpty ? nil : iface
            }
        }
        return nil
    }

    /// Detect user's real DNS server (from primary non-VPN interface)
    /// This respects whatever DNS the user had configured before VPN connected
    private func detectUserDNSServer() async {
        guard let result = await runProcessAsync("/usr/sbin/scutil", arguments: ["--dns"], timeout: 3.0) else {
            log(.warning, "Could not detect DNS configuration")
            return
        }
        
        // Parse scutil --dns output to find DNS servers on non-VPN interfaces
        // VPN interfaces are typically utun*, ppp*, gpd*, ipsec*
        let vpnInterfacePrefixes = ["utun", "ppp", "gpd", "ipsec", "tun", "tap"]
        
        var currentResolver: (nameserver: String?, interface: String?) = (nil, nil)
        var foundDNS: String? = nil
        
        for line in result.output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Track interface for current resolver
            if trimmed.hasPrefix("if_index") {
                // Extract interface name: "if_index : 13 (en8)"
                if let match = trimmed.range(of: "\\(([^)]+)\\)", options: .regularExpression) {
                    let iface = String(trimmed[match]).dropFirst().dropLast()
                    currentResolver.interface = String(iface)
                }
            }
            
            // Track nameserver
            if trimmed.hasPrefix("nameserver[0]") {
                // Extract IP from a line like: "nameserver[0] : 192.168.1.1"
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let dns = parts[1].trimmingCharacters(in: .whitespaces)
                    if isValidIP(dns) {
                        currentResolver.nameserver = dns
                    }
                }
            }
            
            // End of resolver block - check if this is a non-VPN interface
            if trimmed.isEmpty || trimmed.hasPrefix("resolver #") {
                if let dns = currentResolver.nameserver,
                   let iface = currentResolver.interface {
                    // Check if this is NOT a VPN interface
                    let isVPNInterface = vpnInterfacePrefixes.contains { iface.hasPrefix($0) }
                    if !isVPNInterface && foundDNS == nil {
                        foundDNS = dns
                    }
                }
                currentResolver = (nil, nil)
            }
        }
        
        if let dns = foundDNS {
            detectedDNSServer = dns
            log(.info, "🔍 Detected non-VPN DNS: \(dns)")
        } else {
            log(.warning, "Could not detect user's DNS server, will use fallback DNS")
        }
    }
    
    private func parseDefaultGateway() async -> String? {
        guard let result = await runProcessAsync("/sbin/route", arguments: ["-n", "get", "default"], timeout: 3.0) else {
            return nil
        }

        // Refuse a default route that exits through a TUNNEL. Once a VPN is connected it owns the
        // default route, so this would hand back the VPN's own gateway as our "local" gateway —
        // and every bypass route built on it would be routed straight back into the tunnel it is
        // supposed to avoid. Returning nil is the safe answer: the apply paths already refuse to
        // install without a gateway and say so, which is a visible failure rather than a silent
        // one that quietly stops bypassing while reporting success.
        var iface: String?
        var gateway: String?
        for line in result.output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                iface = String(trimmed.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("gateway:") {
                gateway = String(trimmed.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        if let iface, isVPNInterface(iface) {
            log(.warning, "Default route exits via \(iface) (a tunnel) — not using it as the local gateway")
            return nil
        }
        if let gateway, isValidIP(gateway) {
            return gateway
        }

        return nil
    }

    /// Detect VPN gateway for VPN Only mode routing.
    /// Parses `route -n get default` for both gateway IP and interface.
    /// Falls back to interface-based routing when no IP gateway is available
    /// (e.g., Cisco Secure Client routes via link# without setting an IP gateway).
    private func detectVPNGateway() async -> String? {
        guard let result = await runProcessAsync("/sbin/route", arguments: ["-n", "get", "default"], timeout: 3.0) else {
            if let iface = vpnInterface { return "iface:\(iface)" }
            return nil
        }

        var gateway: String?
        var routeInterface: String?

        for line in result.output.components(separatedBy: "\n") {
            if line.contains("gateway:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    let gw = parts[1].trimmingCharacters(in: .whitespaces)
                    if isValidIP(gw) { gateway = gw }
                }
            }
            if line.contains("interface:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    routeInterface = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Prefer IP gateway when available and different from local gateway
        // (same IP means route -n get default still shows pre-VPN default — race condition)
        if let gw = gateway, gw != localGateway { return gw }

        // No IP gateway — use interface from route output when it still looks
        // like a VPN/tunnel device. This preserves the multi-VPN fix without
        // turning an odd physical default interface into an invalid helper
        // gateway like `iface:en0`.
        if let iface = routeInterface, isVPNInterface(iface) { return "iface:\(iface)" }

        // Last resort: use detected VPN interface from ifconfig
        if let iface = vpnInterface { return "iface:\(iface)" }

        return nil
    }
    
    private var failedDomains: Set<String> = []
    
    private static let retryDelayNs: UInt64 = 15_000_000_000 // 15 seconds

    /// Bounded fast-retry for a latched re-route: re-check every 2s, up to ~30s, so a
    /// deferred re-route heals quickly instead of waiting for the 30s status timer.
    private static let rerouteRetryDelayNs: UInt64 = 2_000_000_000 // 2 seconds
    private static let rerouteRetryMaxAttempts = 15

    private var pendingRetryTasks: [String: Task<Void, Never>] = [:]
    /// Single in-flight retry chain draining a latched re-route (never more than one).
    private var rerouteRetryTask: Task<Void, Never>?
    /// Test-only override for the re-route apply body (nil in production). When set,
    /// performReroute() runs it INSTEAD of removeAllRoutes()+applyAllRoutesInternal(),
    /// so the leak-critical latch-clear timing is unit-testable without the helper,
    /// kernel routes, or /etc/hosts. See RerouteLatchTimingTests.
    var rerouteApplyOverrideForTests: (() async -> Void)?

    /// #61 test-only seams (nil in production). `removeRoutesBatchOverrideForTests` lets the strand
    /// repro observe kernel removals (incl. unstrandRoutes) without a real helper; `routeEpochForTests`
    /// exposes the private preemption epoch so the test can capture it before forcing a teardown.
    var removeRoutesBatchOverrideForTests: (([String]) async -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?))?
    var routeEpochForTests: UInt64 { routeEpoch }

    private func applyRoutesForDomain(_ domain: String, gateway: String, source: String? = nil, persistCache: Bool = true) async -> [ActiveRoute]? {
        guard let ips = await resolveIPs(for: domain) else {
            failedDomains.insert(domain)
            return nil
        }
        
        if let firstIP = ips.first {
            dnsCache[domain] = firstIP
        }
        dnsDiskCache[domain] = ips
        if persistCache {
            saveDNSCache()
        }
        
        var routes: [ActiveRoute] = []
        
        for ip in ips {
            if await addRoute(ip, gateway: gateway) {
                routes.append(ActiveRoute(
                    destination: ip,
                    gateway: gateway,
                    source: source ?? domain,
                    timestamp: Date()
                ))
            }
        }
        
        return routes.isEmpty ? nil : routes
    }
    
    private func resolveIPs(for domain: String) async -> [String]? {
        // Use nonisolated static method for true parallelism
        let userDNS = detectedDNSServer
        let fallbackDNS = config.fallbackDNS
        return await DNSResolver.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
    }
    
    private func addRoute(_ destination: String, gateway: String, isNetwork: Bool = false) async -> Bool {
        guard HelperManager.shared.isHelperInstalled else {
            log(.error, "Cannot add route: helper not ready")
            return false
        }
        let result = await HelperManager.shared.addRoute(destination: destination, gateway: gateway, isNetwork: isNetwork)
        if !result.success {
            log(.warning, "Helper route add failed: \(result.error ?? "unknown")")
        }
        return result.success
    }

    private func removeRoute(_ destination: String) async -> Bool {
        guard HelperManager.shared.isHelperInstalled else {
            log(.error, "Cannot remove route: helper not ready")
            return false
        }
        let result = await HelperManager.shared.removeRoute(destination: destination)
        return result.success
    }
    
    @discardableResult
    private func updateHostsFile() async -> Bool {
        // Collect domain -> IP mappings, filtered against activeRoutes so hosts
        // only contains entries for domains that actually have installed kernel routes.
        // Checks all cached IPs (not just first) to find a routed one.
        let routedDestinations = Set(activeRoutes.map { $0.destination })
        var entries: [(domain: String, ip: String)] = []

        let activeDomains: [DomainEntry] = config.routingMode == .vpnOnly ? config.inverseDomains : config.domains

        for domain in activeDomains {
            // CIDR entries don't have domain names to map in hosts file
            guard !domain.isCIDR else { continue }
            // Include enabled domains AND disabled domains that still have active kernel routes
            guard domain.enabled || activeRoutes.contains(where: { $0.source == domain.domain }) else { continue }
            let lookupDomain = domain.domain
            if let ip = firstRoutedIP(for: lookupDomain, in: routedDestinations) {
                entries.append((lookupDomain, ip))
            }
        }

        // Services only apply in bypass mode
        if config.routingMode == .bypass {
            for service in config.services {
                guard service.enabled || activeRoutes.contains(where: { $0.source == service.name }) else { continue }
                for domain in service.domains {
                    if let ip = firstRoutedIP(for: domain, in: routedDestinations) {
                        entries.append((domain, ip))
                    }
                }
            }
        }

        // Defense in depth: scan activeRoutes for orphaned sources (deleted/renamed)
        // that aren't in config but still have live kernel routes
        let configSources: Set<String> = {
            var sources = Set(activeDomains.map { $0.domain })
            if config.routingMode == .bypass {
                sources.formUnion(config.services.map { $0.name })
            }
            return sources
        }()
        var coveredDomains = Set(entries.map { $0.domain })
        var orphanedSourcesSeen: Set<String> = []
        for route in activeRoutes where !configSources.contains(route.source) {
            // Domain-name source: direct DNS cache lookup
            if !coveredDomains.contains(route.source) {
                if let ip = firstRoutedIP(for: route.source, in: routedDestinations) {
                    entries.append((route.source, ip))
                    coveredDomains.insert(route.source)
                    continue
                }
            }
            // Service-name source: use saved domain list from deletion
            if !orphanedSourcesSeen.contains(route.source),
               let domains = orphanedServiceDomains[route.source] {
                orphanedSourcesSeen.insert(route.source)
                for domain in domains {
                    if !coveredDomains.contains(domain) {
                        if let ip = firstRoutedIP(for: domain, in: routedDestinations) {
                            entries.append((domain, ip))
                            coveredDomains.insert(domain)
                        }
                    }
                }
            }
        }

        // Clean up orphanedServiceDomains for sources with no remaining routes
        orphanedServiceDomains = orphanedServiceDomains.filter { name, _ in
            activeRoutes.contains { $0.source == name }
        }

        // Update /etc/hosts (requires sudo)
        return await modifyHostsFile(entries: entries)
    }

    /// Find the first cached IP for a domain that has a confirmed kernel route
    private func firstRoutedIP(for domain: String, in routedDestinations: Set<String>) -> String? {
        // Check memory cache first
        if let cachedIP = dnsCache[domain], routedDestinations.contains(cachedIP) {
            return cachedIP
        }
        // Fall back to disk cache — check ALL IPs, not just first
        if let diskCachedIPs = dnsDiskCache[domain] {
            for ip in diskCachedIPs {
                if routedDestinations.contains(ip) {
                    return ip
                }
            }
        }
        return nil
    }
    
    private func cleanHostsFile() async {
        await modifyHostsFile(entries: [])
    }
    
    /// Called when app is quitting - clean up routes and hosts file
    /// Synchronously flips the shutdown flag and cancels every background task that could
    /// mutate routes. Must be the FIRST thing both quit paths do — before any `await`.
    /// Test-only: reverses beginShutdown so shared-singleton tests can restore state.
    func resetShutdownStateForTests() {
        isShuttingDown = false
    }

    /// Test-only seams for the operation gate (it is private by design).
    func tryAcquireRouteOperationForTests() -> Bool { acquireRouteOperation() }
    func releaseRouteOperationForTests() { releaseRouteOperation() }

    func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        backgroundRefreshTask?.cancel()
        rerouteRetryTask?.cancel()
        rerouteRetryTask = nil
        cancelAllRetries()
    }

    func cleanupOnQuit() async {
        beginShutdown()
        log(.info, "Cleaning up on quit...")
        ProxyListenerManager.shared.stopAll()
        // ALWAYS run teardown — even with an empty model. Its epoch bump is what preempts
        // an in-flight apply; skipping it when `activeRoutes` was empty let a quit that
        // landed mid-apply finish installing its full set after "cleanup" had completed.
        await removeAllRoutes()
        // An operation that was already past the gate may still be draining. Wait briefly
        // (bounded — never blocks quit), then sweep anything it pushed into the kernel.
        var polls = 0
        while isApplyingRoutes && polls < 30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            polls += 1
        }
        if !pendingKernelAdds.isEmpty {
            let residual = Array(pendingKernelAdds)
            log(.warning, "Quit sweep: removing \(residual.count) route(s) installed during teardown")
            _ = await removeRoutesBatchVia(residual)
            pendingKernelAdds.removeAll()
        }
        if config.manageHostsFile {
            await cleanHostsFile()
        }
    }
    
    @discardableResult
    private func modifyHostsFile(entries: [(domain: String, ip: String)]) async -> Bool {
        guard HelperManager.shared.isHelperInstalled else {
            log(.error, "Cannot modify hosts file: helper not ready (\(HelperManager.shared.helperState.statusText))")
            return false
        }
        let result = await HelperManager.shared.updateHostsFile(entries: entries)
        if !result.success {
            log(.error, "Helper hosts update failed: \(result.error ?? "unknown")")
        }
        return result.success
    }
    
    nonisolated func cleanDomain(_ input: String) -> String {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove any protocol scheme (http, https, ssh, ftp, etc.) using regex
        if let schemeRange = domain.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) {
            domain = String(domain[schemeRange.upperBound...])
        }

        // Remove userinfo (user:pass@) if present
        if let atIndex = domain.firstIndex(of: "@") {
            domain = String(domain[domain.index(after: atIndex)...])
        }

        // Remove port number if present (e.g., :443, :8080)
        if let colonIndex = domain.firstIndex(of: ":") {
            domain = String(domain[..<colonIndex])
        }

        // Remove path and query string
        if let slashIndex = domain.firstIndex(of: "/") {
            domain = String(domain[..<slashIndex])
        }
        if let queryIndex = domain.firstIndex(of: "?") {
            domain = String(domain[..<queryIndex])
        }

        // Reject characters that are invalid in domain names (prevents shell injection)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        domain = String(domain.unicodeScalars.filter { allowed.contains($0) })

        return domain.lowercased()
    }
    
    nonisolated func isValidIP(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            guard let num = Int($0), num >= 0, num <= 255 else { return false }
            // Reject leading zeros (e.g., "010") — route interprets them as octal
            return String(num) == $0
        }
    }

    /// Validate CIDR notation (e.g., "192.168.1.0/24")
    /// Rejects /0 which would conflict with VPN Only catch-all routes.
    nonisolated func isValidCIDR(_ string: String) -> Bool {
        let parts = string.components(separatedBy: "/")
        guard parts.count == 2,
              isValidIP(parts[0]),
              let mask = Int(parts[1]),
              mask >= 1 && mask <= 32 else {
            return false
        }
        return true
    }
    
    /// One shared timestamp formatter — allocating a fresh `ISO8601DateFormatter`
    /// per log line is measurably expensive and this is a hot path (hundreds of
    /// lines per apply/refresh).
    private static let logFormatter = ISO8601DateFormatter()

    /// Owner-only log file under the per-user, `0700`-protected `~/Library/Logs`
    /// (never the world-writable, symlink-plantable `/tmp`). Computed once.
    private lazy var logFileURL: URL? = {
        guard let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Logs/VPNBypass", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("vpnbypass.log")
    }()

    /// Persistent append handle so we don't open/seek/close on every line.
    /// Safe to cache: `RouteManager` is `@MainActor`, so `log()` is serialized.
    private var logFileHandle: FileHandle?

    func log(_ level: LogEntry.LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        recentLogs.insert(entry, at: 0)
        if recentLogs.count > 200 {
            recentLogs.removeLast()
        }

        // Log to file (owner-only, never following a planted symlink).
        guard let url = logFileURL,
              let data = "[\(Self.logFormatter.string(from: entry.timestamp))] [\(level.rawValue)] \(message)\n".data(using: .utf8)
        else { return }

        if logFileHandle == nil {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
            if fd >= 0 {
                logFileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
        }
        guard let handle = logFileHandle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // Handle went stale (file rotated/deleted) — drop it; the next call reopens.
            try? handle.close()
            logFileHandle = nil
        }
    }
}
