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
    @Published var activeRoutes: [ActiveRoute] = []
    @Published var lastUpdate: Date?
    @Published var config: Config = Config()
    @Published var recentLogs: [LogEntry] = []
    @Published var currentNetworkSSID: String?
    @Published var routeVerificationResults: [String: RouteVerificationResult] = [:]
    @Published var isLoading = true
    @Published var isApplyingRoutes = false  // True during incremental route changes (blocks UI)
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
    
    /// Public accessor for UI to display detected DNS server
    var detectedDNSServerDisplay: String? {
        detectedDNSServer
    }
    
    // MARK: - Types
    
    enum VPNType: String, Codable {
        case globalProtect = "GlobalProtect"
        case ciscoAnyConnect = "Cisco AnyConnect"
        case openVPN = "OpenVPN"
        case wireGuard = "WireGuard"
        case tailscale = "Tailscale (Exit Node)"
        case fortinet = "Fortinet FortiClient"
        case zscaler = "Zscaler"
        case cloudflareWARP = "Cloudflare WARP"
        case paloAlto = "Palo Alto"
        case pulseSecure = "Pulse Secure"
        case unknown = "Unknown VPN"
        
        var icon: String {
            switch self {
            case .globalProtect, .paloAlto: return "shield.lefthalf.filled"
            case .ciscoAnyConnect: return "network.badge.shield.half.filled"
            case .openVPN: return "lock.shield"
            case .wireGuard: return "key.fill"
            case .tailscale: return "link.circle.fill"
            case .fortinet: return "shield.checkered"
            case .zscaler: return "cloud.fill"
            case .cloudflareWARP: return "cloud.bolt.fill"
            case .pulseSecure: return "bolt.shield.fill"
            case .unknown: return "shield.fill"
            }
        }
    }
    
    struct RouteVerificationResult: Identifiable {
        let id = UUID()
        let destination: String
        let isReachable: Bool
        let latency: Double? // in milliseconds
        let timestamp: Date
        let error: String?
    }
    
    // SOCKS5 Proxy configuration for aggressive VPN bypass (corporate VPNs that block UDP)
    struct ProxyConfig: Codable, Equatable {
        var enabled: Bool = false
        var server: String = ""
        var port: Int = 1080
        var username: String = ""
        var password: String = ""
        var useForServices: [String] = []  // Service IDs that should use proxy (empty = all enabled services)
        
        var isConfigured: Bool {
            !server.isEmpty && port > 0 && port < 65536
        }
    }
    
    struct Config: Codable {
        var domains: [DomainEntry] = defaultDomains
        var services: [ServiceEntry] = defaultServices
        var autoApplyOnVPN: Bool = true
        var manageHostsFile: Bool = true
        var checkInterval: TimeInterval = 300 // 5 minutes
        var verifyRoutesAfterApply: Bool = false  // Disabled by default - many servers block ping
        var autoDNSRefresh: Bool = true  // Periodically re-resolve DNS and update routes
        var dnsRefreshInterval: TimeInterval = 3600  // 1 hour default
        var fallbackDNS: [String] = ["1.1.1.1", "8.8.8.8"]  // Fallback DNS servers (IP or DoH URL)
        var proxyConfig: ProxyConfig = ProxyConfig()  // SOCKS5 proxy for aggressive bypass mode
        
        // Custom decoder for backward compatibility with configs missing new fields
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            domains = try container.decodeIfPresent([DomainEntry].self, forKey: .domains) ?? Config.defaultDomains
            services = try container.decodeIfPresent([ServiceEntry].self, forKey: .services) ?? Config.defaultServices
            autoApplyOnVPN = try container.decodeIfPresent(Bool.self, forKey: .autoApplyOnVPN) ?? true
            manageHostsFile = try container.decodeIfPresent(Bool.self, forKey: .manageHostsFile) ?? true
            checkInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .checkInterval) ?? 300
            verifyRoutesAfterApply = try container.decodeIfPresent(Bool.self, forKey: .verifyRoutesAfterApply) ?? false
            autoDNSRefresh = try container.decodeIfPresent(Bool.self, forKey: .autoDNSRefresh) ?? true
            dnsRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .dnsRefreshInterval) ?? 3600
            fallbackDNS = try container.decodeIfPresent([String].self, forKey: .fallbackDNS) ?? ["1.1.1.1", "8.8.8.8"]
            proxyConfig = try container.decodeIfPresent(ProxyConfig.self, forKey: .proxyConfig) ?? ProxyConfig()
        }
        
        // Default initializer
        init() {}
        
        static var defaultDomains: [DomainEntry] {
            []  // User adds their own domains in Settings
        }
        
        static var defaultServices: [ServiceEntry] {
            [
                // Messaging
                ServiceEntry(id: "telegram", name: "Telegram", enabled: false, domains: [
                    "telegram.org", "t.me", "telegram.me", "core.telegram.org", "api.telegram.org", "web.telegram.org"
                ], ipRanges: ["91.108.56.0/22", "91.108.4.0/22", "91.108.8.0/22", "91.108.16.0/22", "91.108.12.0/22", "149.154.160.0/20", "91.105.192.0/23", "185.76.151.0/24"]),
                ServiceEntry(id: "whatsapp", name: "WhatsApp", enabled: false, domains: [
                    "whatsapp.com", "web.whatsapp.com", "whatsapp.net", "wa.me"
                ], ipRanges: ["3.33.221.0/24", "15.197.206.0/24", "52.26.198.0/24"]),
                ServiceEntry(id: "signal", name: "Signal", enabled: false, domains: [
                    "signal.org", "www.signal.org", "updates.signal.org", "api.signal.org"
                ], ipRanges: []),
                
                // Streaming - Video
                ServiceEntry(id: "youtube", name: "YouTube", enabled: false, domains: [
                    "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "youtube-nocookie.com", "www.googlevideo.com", "i.ytimg.com", "s.ytimg.com"
                ], ipRanges: []),
                ServiceEntry(id: "netflix", name: "Netflix", enabled: false, domains: [
                    "netflix.com", "www.netflix.com", "assets.nflxext.com", "api-global.netflix.com"
                ], ipRanges: []),
                ServiceEntry(id: "primevideo", name: "Amazon Prime Video", enabled: false, domains: [
                    "primevideo.com", "www.primevideo.com", "amazon.com", "www.amazon.com", "atv-ps.amazon.com"
                ], ipRanges: []),
                ServiceEntry(id: "disneyplus", name: "Disney+", enabled: false, domains: [
                    "disneyplus.com", "www.disneyplus.com", "disney-plus.net", "bamgrid.com", "dssott.com"
                ], ipRanges: []),
                ServiceEntry(id: "hbomax", name: "HBO Max", enabled: false, domains: [
                    "max.com", "www.max.com", "hbomax.com", "www.hbomax.com"
                ], ipRanges: []),
                ServiceEntry(id: "twitch", name: "Twitch", enabled: false, domains: [
                    "twitch.tv", "www.twitch.tv", "static.twitchcdn.net", "vod-secure.twitch.tv", "usher.ttvnw.net"
                ], ipRanges: []),
                
                // Streaming - Music
                ServiceEntry(id: "spotify", name: "Spotify", enabled: false, domains: [
                    "spotify.com", "www.spotify.com", "open.spotify.com", "i.scdn.co"
                ], ipRanges: []),
                ServiceEntry(id: "applemusic", name: "Apple Music", enabled: false, domains: [
                    "music.apple.com", "itunes.apple.com", "amp-api.music.apple.com"
                ], ipRanges: []),
                ServiceEntry(id: "soundcloud", name: "SoundCloud", enabled: false, domains: [
                    "soundcloud.com", "www.soundcloud.com", "api.soundcloud.com"
                ], ipRanges: []),
                
                // Social Media
                ServiceEntry(id: "twitter", name: "X (Twitter)", enabled: false, domains: [
                    "twitter.com", "x.com", "www.twitter.com", "api.twitter.com", "t.co", "twimg.com", "pbs.twimg.com"
                ], ipRanges: []),
                ServiceEntry(id: "instagram", name: "Instagram", enabled: false, domains: [
                    "instagram.com", "www.instagram.com", "i.instagram.com", "cdninstagram.com"
                ], ipRanges: []),
                ServiceEntry(id: "tiktok", name: "TikTok", enabled: false, domains: [
                    "tiktok.com", "www.tiktok.com", "vm.tiktok.com", "m.tiktok.com"
                ], ipRanges: []),
                ServiceEntry(id: "reddit", name: "Reddit", enabled: false, domains: [
                    "reddit.com", "www.reddit.com", "old.reddit.com", "i.redd.it", "v.redd.it"
                ], ipRanges: []),
                ServiceEntry(id: "facebook", name: "Facebook", enabled: false, domains: [
                    "facebook.com", "www.facebook.com", "m.facebook.com", "fb.com", "fbcdn.net"
                ], ipRanges: []),
                ServiceEntry(id: "linkedin", name: "LinkedIn", enabled: false, domains: [
                    "linkedin.com", "www.linkedin.com", "media.licdn.com"
                ], ipRanges: []),
                
                // Work & Communication
                ServiceEntry(id: "slack", name: "Slack", enabled: false, domains: [
                    "slack.com", "www.slack.com", "app.slack.com", "files.slack.com", "a.slack-edge.com"
                ], ipRanges: []),
                ServiceEntry(id: "discord", name: "Discord", enabled: false, domains: [
                    // Main domains
                    "discord.com", "discord.gg", "discordapp.com", "discord.media", "cdn.discordapp.com",
                    // Voice/WebRTC specific
                    "discordapp.net", "gateway.discord.gg", "router.discordapp.net",
                    "media.discordapp.net", "images-ext-1.discordapp.net", "images-ext-2.discordapp.net"
                ], ipRanges: []),
                ServiceEntry(id: "zoom", name: "Zoom", enabled: false, domains: [
                    "zoom.us", "www.zoom.us", "us02web.zoom.us", "us04web.zoom.us", "us05web.zoom.us"
                ], ipRanges: []),
                ServiceEntry(id: "teams", name: "Microsoft Teams", enabled: false, domains: [
                    "teams.microsoft.com", "teams.live.com", "statics.teams.cdn.office.net"
                ], ipRanges: []),
                ServiceEntry(id: "googlemeet", name: "Google Meet", enabled: false, domains: [
                    "meet.google.com"
                ], ipRanges: []),
                
                // Cloud & Storage
                ServiceEntry(id: "dropbox", name: "Dropbox", enabled: false, domains: [
                    "dropbox.com", "www.dropbox.com", "dl.dropboxusercontent.com"
                ], ipRanges: []),
                ServiceEntry(id: "gdrive", name: "Google Drive", enabled: false, domains: [
                    "drive.google.com", "docs.google.com", "sheets.google.com", "slides.google.com"
                ], ipRanges: []),
                ServiceEntry(id: "icloud", name: "iCloud", enabled: false, domains: [
                    "icloud.com", "www.icloud.com", "apple-cloudkit.com"
                ], ipRanges: []),
                
                // Gaming
                ServiceEntry(id: "steam", name: "Steam", enabled: false, domains: [
                    "steampowered.com", "store.steampowered.com", "steamcommunity.com", "steamcdn-a.akamaihd.net"
                ], ipRanges: []),
                ServiceEntry(id: "epicgames", name: "Epic Games", enabled: false, domains: [
                    "epicgames.com", "www.epicgames.com", "launcher-public-service-prod.ol.epicgames.com"
                ], ipRanges: []),
                ServiceEntry(id: "playstation", name: "PlayStation Network", enabled: false, domains: [
                    "playstation.com", "www.playstation.com", "store.playstation.com"
                ], ipRanges: []),
                ServiceEntry(id: "xbox", name: "Xbox Live", enabled: false, domains: [
                    "xbox.com", "www.xbox.com", "xboxlive.com"
                ], ipRanges: []),
                
                // Developer & Utilities
                ServiceEntry(id: "github", name: "GitHub", enabled: false, domains: [
                    "github.com", "www.github.com", "api.github.com", "raw.githubusercontent.com", "gist.github.com"
                ], ipRanges: []),
                ServiceEntry(id: "gitlab", name: "GitLab", enabled: false, domains: [
                    "gitlab.com", "www.gitlab.com", "registry.gitlab.com"
                ], ipRanges: []),
                ServiceEntry(id: "stackoverflow", name: "Stack Overflow", enabled: false, domains: [
                    "stackoverflow.com", "www.stackoverflow.com", "stackexchange.com"
                ], ipRanges: []),
                ServiceEntry(id: "tailscale", name: "Tailscale", enabled: false, domains: [
                    "login.tailscale.com", "controlplane.tailscale.com", "tailscale.com", "pkgs.tailscale.com"
                ], ipRanges: []),
                
                // AI Services
                ServiceEntry(id: "openai", name: "OpenAI / ChatGPT", enabled: false, domains: [
                    "openai.com", "chat.openai.com", "api.openai.com", "platform.openai.com"
                ], ipRanges: []),
                ServiceEntry(id: "anthropic", name: "Anthropic / Claude", enabled: false, domains: [
                    "anthropic.com", "www.anthropic.com", "claude.ai", "api.anthropic.com"
                ], ipRanges: []),
                ServiceEntry(id: "perplexity", name: "Perplexity", enabled: false, domains: [
                    "perplexity.ai", "www.perplexity.ai"
                ], ipRanges: [])
            ]
        }
    }
    
    struct DomainEntry: Codable, Identifiable, Equatable {
        let id: UUID
        var domain: String
        var enabled: Bool
        var resolvedIP: String?
        var lastResolved: Date?
        
        init(domain: String, enabled: Bool = true) {
            self.id = UUID()
            self.domain = domain
            self.enabled = enabled
        }
    }
    
    struct ServiceEntry: Codable, Identifiable {
        let id: String
        var name: String
        var enabled: Bool
        var domains: [String]
        var ipRanges: [String]
    }
    
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
    
    private let configURL: URL
    private var refreshTimer: Timer?
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("VPNBypass", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("config.json")
    }
    
    // MARK: - Public API
    
    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let loaded = try? JSONDecoder().decode(Config.self, from: data) else {
            log(.info, "Using default config")
            return
        }
        config = loaded
        log(.info, "Config loaded")
    }
    
    func saveConfig() {
        // Daily backup - overwrite if older than 24 hours
        createDailyBackupIfNeeded()
        
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL)
        log(.info, "Config saved")
    }
    
    private func createDailyBackupIfNeeded() {
        let backupURL = configURL.deletingLastPathComponent().appendingPathComponent("config.json.bak")
        
        // Check if backup exists and is less than 24 hours old
        if let attrs = try? FileManager.default.attributesOfItem(atPath: backupURL.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < 86400 {
            return // Backup is recent enough
        }
        
        // Create/overwrite backup
        if FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: configURL, to: backupURL)
            log(.info, "Daily config backup created")
        }
    }
    
    // MARK: - Import/Export Config
    
    func exportConfig() -> URL? {
        let exportData = ExportData(
            version: "1.1",
            exportDate: Date(),
            config: config
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
            
            // Merge or replace config
            config = exportData.config
            saveConfig()
            
            log(.success, "Config imported: \(exportData.config.domains.count) domains, \(exportData.config.services.filter { $0.enabled }.count) services enabled")
            return true
        } catch {
            log(.error, "Failed to import config: \(error.localizedDescription)")
            return false
        }
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
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.runProcessSync(executablePath, arguments: arguments, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Synchronous process execution - ONLY call from background thread
    private static nonisolated func runProcessSync(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = 5.0
    ) -> (output: String, exitCode: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
        } catch {
            return nil
        }
        
        // Use DispatchSemaphore for proper timeout handling
        let semaphore = DispatchSemaphore(value: 0)
        var didTimeout = false
        
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }
        
        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            process.terminate()
            didTimeout = true
        }
        
        if didTimeout {
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
    
    // MARK: - Network Status
    
    func updateNetworkStatus(_ path: NWPath) {
        Task {
            await checkVPNStatus()
        }
    }
    
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
    
    func checkVPNStatus() async {
        let wasVPNConnected = isVPNConnected
        let oldInterface = vpnInterface
        
        // Detect current network first
        await detectCurrentNetwork()
        
        // Use scutil to detect VPN interfaces with IPv4 addresses
        let (connected, interface, detectedType) = await detectVPNInterface()
        
        isVPNConnected = connected
        vpnInterface = connected ? interface : nil
        vpnType = connected ? detectedType : nil
        
        // Detect local gateway
        localGateway = await detectLocalGateway()
        
        // Auto-apply routes when VPN connects
        if isVPNConnected && !wasVPNConnected && config.autoApplyOnVPN {
            log(.success, "VPN connected via \(interface ?? "unknown") (\(detectedType?.rawValue ?? "unknown type")), applying routes...")
            NotificationManager.shared.notifyVPNConnected(interface: interface ?? "unknown")
            
            // Show loading indicator while applying routes
            isLoading = true
            await applyAllRoutes()
            isLoading = false
        }
        
        // Log disconnection - only if we're confident (interface actually changed)
        if !isVPNConnected && wasVPNConnected && vpnInterface != oldInterface {
            log(.warning, "VPN disconnected (was: \(oldInterface ?? "unknown"))")
            NotificationManager.shared.notifyVPNDisconnected(wasInterface: oldInterface)
            // Clear routes when VPN disconnects
            activeRoutes.removeAll()
            routeVerificationResults.removeAll()
        }
    }
    
    private func detectVPNInterface() async -> (connected: Bool, interface: String?, type: VPNType?) {
        // First check for specific VPN processes to help identify type
        let runningVPNType = await detectRunningVPNProcess()
        
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
        if output.contains("vpnagent") || output.contains("cisco") || output.contains("anyconnect") {
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
        if output.contains("zscaler") || output.contains("zstunnel") || output.contains("zsatunnel") {
            return .zscaler
        }
        if output.contains("cloudflare") || output.contains("warp-cli") || output.contains("warp-svc") {
            return .cloudflareWARP
        }
        if output.contains("pulsesecure") || output.contains("dsaccessservice") || output.contains("pulseuisvc") {
            return .pulseSecure
        }
        // Tailscale is handled separately via exit node detection
        
        return nil
    }
    
    private func detectVPNViaIfconfig(hintType: VPNType?) async -> (connected: Bool, interface: String?, type: VPNType?) {
        guard let result = await runProcessAsync("/sbin/ifconfig", timeout: 5.0) else {
            // Command failed/timed out - don't change VPN status (return current state)
            return (isVPNConnected, vpnInterface, vpnType)
        }
        
        let output = result.output
        
        // Parse ifconfig output looking for VPN interfaces with inet addresses
        var currentInterface: String?
        var hasValidIP = false
        var hasUpFlag = false
        
        for line in output.components(separatedBy: "\n") {
            // New interface starts with interface name (no leading whitespace)
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") {
                // Check if previous interface was a VPN
                if let iface = currentInterface, hasValidIP, hasUpFlag,
                   isVPNInterface(iface) {
                    let vpnType = hintType ?? detectVPNTypeFromInterface(iface)
                    return (true, iface, vpnType)
                }
                // Start new interface
                currentInterface = line.components(separatedBy: ":").first
                hasValidIP = false
                // Check for UP flag in the flags line
                hasUpFlag = line.contains("<UP,") || line.contains(",UP,") || line.contains(",UP>")
            }
            
            // Check for inet (IPv4) address - indicates active VPN
            if line.contains("inet ") && !line.contains("inet6") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet ") {
                    // Extract IP to verify it's a corporate VPN address
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 2 {
                        let ip = parts[1]
                        if await isCorporateVPNIP(ip) {
                            hasValidIP = true
                        }
                    }
                }
            }
        }
        
        // Check last interface
        if let iface = currentInterface, hasValidIP, hasUpFlag,
           isVPNInterface(iface) {
            let vpnType = hintType ?? detectVPNTypeFromInterface(iface)
            return (true, iface, vpnType)
        }
        
        return (false, nil, nil)
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
    private func detectVPNTypeFromInterface(_ iface: String) -> VPNType {
        // GlobalProtect typically uses gpd0 or specific utun
        if iface.hasPrefix("gpd") {
            return .globalProtect
        }
        
        // Generic fallback
        return .unknown
    }
    
    /// Check if IP is likely a corporate VPN (not Tailscale mesh, not localhost, etc.)
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
        
        // Tailscale CGNAT range (100.64.0.0/10 = 100.64-127.x.x)
        // Only consider Tailscale as VPN if it's using an exit node (routing all traffic)
        if first == 100 && second >= 64 && second <= 127 {
            return await isTailscaleExitNodeActive()
        }
        
        // Cloudflare WARP range (check for WARP-specific IPs)
        // WARP uses 100.96.0.0/12 range
        if first == 100 && second >= 96 && second <= 111 {
            return true // WARP is active
        }
        
        // Zscaler typically uses 100.64.x.x or custom ranges
        // Already covered by CGNAT check above
        
        // Corporate VPNs typically use private ranges
        // 10.0.0.0/8 - Most corporate VPNs use this
        if first == 10 { return true }
        
        // 172.16.0.0/12 (172.16-31.x.x)
        if first == 172 && second >= 16 && second <= 31 { return true }
        
        // 192.168.0.0/16 - Less common for VPN but possible
        if first == 192 && second == 168 { return true }
        
        return false
    }
    
    /// Check if Tailscale is using an exit node (routing all traffic through Tailscale)
    private func isTailscaleExitNodeActive() async -> Bool {
        // Try multiple paths for tailscale CLI
        let tailscalePaths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        
        for path in tailscalePaths {
            if FileManager.default.fileExists(atPath: path) {
                guard let result = await runProcessAsync(path, arguments: ["status", "--json"], timeout: 3.0) else {
                    continue
                }
                
                let output = result.output
                if let jsonData = output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    // Check ExitNodeStatus - if present and has IP, we're using exit node
                    if let exitNodeStatus = json["ExitNodeStatus"] as? [String: Any],
                       exitNodeStatus["Online"] as? Bool == true {
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    /// Called from startup - no notification
    func detectAndApplyRoutes() {
        Task {
            await detectAndApplyRoutesAsync(sendNotification: false)
        }
    }
    
    /// Called from Refresh button - sends notification
    func refreshRoutes() {
        Task {
            await detectAndApplyRoutesAsync(sendNotification: true)
        }
    }
    
    func detectAndApplyRoutesAsync(sendNotification: Bool = false) async {
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
        
        // Check helper status
        log(.info, "Helper installed: \(HelperManager.shared.isHelperInstalled)")
        
        // Apply routes if VPN is connected
        if isVPNConnected && localGateway != nil {
            log(.success, "VPN detected via \(interface ?? "unknown") (\(detectedType?.rawValue ?? "unknown")), applying routes...")
            if sendNotification {
                await applyAllRoutesWithNotification()
            } else {
                await applyAllRoutes()
            }
        } else if !isVPNConnected {
            log(.info, "No VPN connection detected")
        } else if localGateway == nil {
            log(.error, "Could not detect local gateway")
        }
        
        isLoading = false
        log(.info, "Startup complete. Routes: \(activeRoutes.count)")
    }
    
    func refreshStatus() {
        Task {
            await checkVPNStatus()
        }
    }
    
    /// Apply all routes (internal, no notification)
    func applyAllRoutes() async {
        await applyAllRoutesInternal(sendNotification: false)
    }
    
    /// Apply all routes and send notification (called from Refresh button)
    func applyAllRoutesWithNotification() async {
        await applyAllRoutesInternal(sendNotification: true)
    }
    
    private func applyAllRoutesInternal(sendNotification: Bool) async {
        guard let gateway = localGateway else {
            log(.error, "No local gateway available")
            return
        }
        
        var newRoutes: [ActiveRoute] = []
        var failedCount = 0
        
        // Collect all domains to resolve (for parallel resolution)
        var allDomains: [(domain: String, source: String)] = []
        
        // Add custom domains
        for domain in config.domains where domain.enabled {
            allDomains.append((domain.domain, domain.domain))
        }
        
        // Add service domains
        for service in config.services where service.enabled {
            for domain in service.domains {
                allDomains.append((domain, service.name))
            }
        }
        
        // Resolve domains in batches to avoid overwhelming DNS server through VPN
        log(.info, "Resolving \(allDomains.count) domains...")
        
        let batchSize = 5  // Process 5 domains at a time to avoid DNS rate limiting
        var index = 0
        
        while index < allDomains.count {
            let endIndex = min(index + batchSize, allDomains.count)
            let batch = Array(allDomains[index..<endIndex])
            
            // Process batch in parallel
            let batchResults = await withTaskGroup(of: [ActiveRoute]?.self, returning: [[ActiveRoute]?].self) { group in
                for item in batch {
                    group.addTask {
                        await self.applyRoutesForDomain(item.domain, gateway: gateway, source: item.source)
                    }
                }
                
                var results: [[ActiveRoute]?] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            
            // Collect batch results
            for result in batchResults {
                if let routes = result {
                    newRoutes.append(contentsOf: routes)
                } else {
                    failedCount += 1
                }
            }
            
            index += batchSize
        }
        
        // Apply IP ranges (these don't need DNS resolution)
        for service in config.services where service.enabled {
            for range in service.ipRanges {
                if await applyRouteForRange(range, gateway: gateway) {
                    newRoutes.append(ActiveRoute(
                        destination: range,
                        gateway: gateway,
                        source: service.name,
                        timestamp: Date()
                    ))
                }
            }
        }
        
        activeRoutes = newRoutes
        lastUpdate = Date()
        
        // Manage hosts file if enabled
        if config.manageHostsFile {
            await updateHostsFile()
        }
        
        if failedCount > 0 {
            log(.warning, "Applied \(newRoutes.count) routes (\(failedCount) domains failed)")
            for domain in failedDomains {
                log(.warning, "  ✗ \(domain)")
            }
            failedDomains.removeAll()
        } else {
            log(.success, "Applied \(newRoutes.count) routes")
            failedDomains.removeAll()
        }
        
        // Only send notification when explicitly requested (Refresh button)
        if sendNotification && newRoutes.count > 0 {
            NotificationManager.shared.notifyRoutesApplied(count: newRoutes.count, failedCount: failedCount)
        }
        
        // Verify routes if enabled
        if config.verifyRoutesAfterApply {
            await verifyRoutes()
        }
    }
    
    func removeAllRoutes() async {
        for route in activeRoutes {
            _ = await removeRoute(route.destination)
        }
        activeRoutes.removeAll()
        routeVerificationResults.removeAll()
        lastUpdate = Date()
        
        if config.manageHostsFile {
            await cleanHostsFile()
        }
        
        log(.info, "All routes removed")
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
        guard isVPNConnected, let gateway = localGateway else {
            log(.info, "DNS refresh skipped: VPN not connected")
            nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
            return
        }
        
        log(.info, "Auto DNS refresh: re-resolving domains...")
        isApplyingRoutes = true
        
        var updatedCount = 0
        var newIPs: Set<String> = []
        let oldIPs = Set(activeRoutes.map { $0.destination })
        
        // Collect all domains to refresh
        var domainsToResolve: [(domain: String, source: String)] = []
        
        for domain in config.domains where domain.enabled {
            domainsToResolve.append((domain.domain, domain.domain))
        }
        
        for service in config.services where service.enabled {
            for domain in service.domains {
                domainsToResolve.append((domain, service.name))
            }
        }
        
        // Re-resolve and check for changes
        for (domain, source) in domainsToResolve {
            if let ips = await resolveIPs(for: domain) {
                for ip in ips {
                    newIPs.insert(ip)
                    if !oldIPs.contains(ip) {
                        // New IP found - add route
                        if await addRoute(ip, gateway: gateway) {
                            activeRoutes.append(ActiveRoute(
                                destination: ip,
                                gateway: gateway,
                                source: source,
                                timestamp: Date()
                            ))
                            updatedCount += 1
                            log(.success, "DNS refresh: added new IP \(ip) for \(domain)")
                        }
                    }
                }
            }
        }
        
        // Also add IP ranges (these don't change via DNS but ensure they're present)
        for service in config.services where service.enabled {
            for range in service.ipRanges {
                newIPs.insert(range)
            }
        }
        
        // Always update hosts file if enabled - keeps IPs fresh even if routes didn't change
        if config.manageHostsFile {
            await updateHostsFile()
            log(.info, "DNS refresh: hosts file updated")
        }
        
        lastDNSRefresh = Date()
        nextDNSRefresh = Date().addingTimeInterval(config.dnsRefreshInterval)
        isApplyingRoutes = false
        
        if updatedCount > 0 {
            log(.success, "DNS refresh complete: \(updatedCount) new routes added")
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
        let cleaned = cleanDomain(domain)
        guard !cleaned.isEmpty else { return }
        guard !config.domains.contains(where: { $0.domain == cleaned }) else {
            log(.warning, "Domain \(cleaned) already exists")
            return
        }
        
        config.domains.append(DomainEntry(domain: cleaned))
        saveConfig()
        log(.success, "Added domain: \(cleaned)")
        
        // Apply route immediately if VPN connected
        if isVPNConnected, let gateway = localGateway {
            isApplyingRoutes = true
            Task {
                if let routes = await applyRoutesForDomain(cleaned, gateway: gateway) {
                    await MainActor.run {
                        activeRoutes.append(contentsOf: routes)
                    }
                }
                await MainActor.run {
                    isApplyingRoutes = false
                }
            }
        }
    }
    
    func removeDomain(_ domain: DomainEntry) {
        isApplyingRoutes = true
        
        // Actually remove system routes for this domain
        Task {
            await removeRoutesForSource(domain.domain)
            
            await MainActor.run {
                config.domains.removeAll { $0.id == domain.id }
                saveConfig()
                log(.info, "Removed domain: \(domain.domain)")
                isApplyingRoutes = false
            }
        }
    }
    
    /// Toggle a domain's enabled state and update routes
    func toggleDomain(_ domainId: UUID) {
        guard let index = config.domains.firstIndex(where: { $0.id == domainId }) else { return }
        config.domains[index].enabled.toggle()
        saveConfig()
        
        let domain = config.domains[index]
        log(.info, "\(domain.domain) \(domain.enabled ? "enabled" : "disabled")")
        
        // Apply or remove routes
        if isVPNConnected, let gateway = localGateway {
            isApplyingRoutes = true
            Task {
                if domain.enabled {
                    // Domain was just enabled - add its routes
                    if let routes = await applyRoutesForDomain(domain.domain, gateway: gateway) {
                        await MainActor.run {
                            activeRoutes.append(contentsOf: routes)
                        }
                    }
                } else {
                    // Domain was just disabled - remove its routes
                    await removeRoutesForSource(domain.domain)
                }
                await MainActor.run {
                    isApplyingRoutes = false
                }
            }
        }
    }
    
    /// Bulk enable/disable all domains with loading state (incremental)
    func setAllDomainsEnabled(_ enabled: Bool) {
        isApplyingRoutes = true
        
        // Get domains that need to change
        let domainsToChange = config.domains.filter { $0.enabled != enabled }
        
        // Update config
        for i in config.domains.indices {
            config.domains[i].enabled = enabled
        }
        saveConfig()
        
        log(.info, enabled ? "Enabled all domains" : "Disabled all domains")
        
        // Incrementally apply/remove routes for changed domains only
        if isVPNConnected, let gateway = localGateway {
            Task {
                for domain in domainsToChange {
                    if enabled {
                        if let routes = await applyRoutesForDomain(domain.domain, gateway: gateway) {
                            await MainActor.run {
                                activeRoutes.append(contentsOf: routes)
                            }
                        }
                    } else {
                        await removeRoutesForSource(domain.domain)
                    }
                }
                await MainActor.run {
                    isApplyingRoutes = false
                }
            }
        } else {
            isApplyingRoutes = false
        }
    }
    
    /// Remove all routes matching a source (domain name or service name)
    private func removeRoutesForSource(_ source: String) async {
        let routesToRemove = activeRoutes.filter { $0.source == source }
        
        for route in routesToRemove {
            _ = await removeRoute(route.destination)
        }
        
        await MainActor.run {
            activeRoutes.removeAll { $0.source == source }
        }
        
        if !routesToRemove.isEmpty {
            log(.info, "Removed \(routesToRemove.count) routes for \(source)")
        }
    }
    
    func toggleService(_ serviceId: String) {
        guard let index = config.services.firstIndex(where: { $0.id == serviceId }) else { return }
        config.services[index].enabled.toggle()
        saveConfig()
        
        let service = config.services[index]
        log(.info, "\(service.name) \(service.enabled ? "enabled" : "disabled")")
        
        // Incremental route apply/remove
        if isVPNConnected, let gateway = localGateway {
            isApplyingRoutes = true
            Task {
                if service.enabled {
                    // Service was just enabled - add its routes
                    await applyRoutesForService(service, gateway: gateway)
                } else {
                    // Service was just disabled - remove its routes
                    await removeRoutesForSource(service.name)
                }
                await MainActor.run {
                    isApplyingRoutes = false
                }
            }
        }
    }
    
    /// Apply routes for a single service (incremental add)
    private func applyRoutesForService(_ service: ServiceEntry, gateway: String) async {
        var newRoutes: [ActiveRoute] = []
        
        // Apply domain routes
        for domain in service.domains {
            if let routes = await applyRoutesForDomain(domain, gateway: gateway, source: service.name) {
                newRoutes.append(contentsOf: routes)
            }
        }
        
        // Apply IP ranges
        for range in service.ipRanges {
            if await applyRouteForRange(range, gateway: gateway) {
                newRoutes.append(ActiveRoute(
                    destination: range,
                    gateway: gateway,
                    source: service.name,
                    timestamp: Date()
                ))
            }
        }
        
        await MainActor.run {
            activeRoutes.append(contentsOf: newRoutes)
        }
        
        if !newRoutes.isEmpty {
            log(.success, "Added \(newRoutes.count) routes for \(service.name)")
        }
    }
    
    /// Bulk enable/disable all services with loading state (incremental)
    func setAllServicesEnabled(_ enabled: Bool) {
        isApplyingRoutes = true
        
        // Get services that need to change
        let servicesToChange = config.services.filter { $0.enabled != enabled }
        
        // Update config
        for i in config.services.indices {
            config.services[i].enabled = enabled
        }
        saveConfig()
        
        log(.info, enabled ? "Enabled all services" : "Disabled all services")
        
        // Incrementally apply/remove routes for changed services only
        if isVPNConnected, let gateway = localGateway {
            Task {
                for service in servicesToChange {
                    if enabled {
                        await applyRoutesForService(service, gateway: gateway)
                    } else {
                        await removeRoutesForSource(service.name)
                    }
                }
                await MainActor.run {
                    isApplyingRoutes = false
                }
            }
        } else {
            isApplyingRoutes = false
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
        
        for destination in destinationsToVerify.prefix(10) { // Limit to 10 to avoid too many pings
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
        
        if failedCount > 0 {
            log(.warning, "Route verification: \(failedCount) of \(destinationsToVerify.count) routes failed")
        } else if !destinationsToVerify.isEmpty {
            log(.success, "Route verification: All \(min(destinationsToVerify.count, 10)) tested routes are reachable")
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
    
    private func detectLocalGateway() async -> String? {
        // Try common network services
        let services = ["Wi-Fi", "Ethernet", "USB 10/100/1000 LAN", "Thunderbolt Ethernet", "USB-C LAN"]
        
        for service in services {
            if let gateway = await getGatewayForService(service) {
                return gateway
            }
        }
        
        // Fallback: parse route table
        return await parseDefaultGateway()
    }
    
    private func getGatewayForService(_ service: String) async -> String? {
        guard let result = await runProcessAsync("/usr/sbin/networksetup", arguments: ["-getinfo", service], timeout: 3.0) else {
            return nil
        }
        
        for line in result.output.components(separatedBy: "\n") {
            if line.hasPrefix("Router:") {
                let gateway = line.replacingOccurrences(of: "Router:", with: "").trimmingCharacters(in: .whitespaces)
                if gateway != "none" && !gateway.isEmpty {
                    return gateway
                }
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
                // Extract IP: "nameserver[0] : 192.168.10.102"
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
        
        for line in result.output.components(separatedBy: "\n") {
            if line.contains("gateway:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        return nil
    }
    
    private var failedDomains: [String] = []  // Track failed domains for debugging
    
    private func applyRoutesForDomain(_ domain: String, gateway: String, source: String? = nil) async -> [ActiveRoute]? {
        // Resolve domain IPs
        guard let ips = await resolveIPs(for: domain) else {
            failedDomains.append(domain)
            return nil
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
    
    private func applyRouteForRange(_ range: String, gateway: String) async -> Bool {
        return await addRoute(range, gateway: gateway, isNetwork: true)
    }
    
    private func resolveIPs(for domain: String) async -> [String]? {
        // 1. Try detected non-VPN DNS first (user's original DNS before VPN)
        if let userDNS = detectedDNSServer {
            if let ips = await resolveWithDNS(domain, dns: userDNS) {
                return ips
            }
        }
        
        // 2. Fall back to configured DNS servers
        for dns in config.fallbackDNS {
            if let ips = await resolveWithDNS(domain, dns: dns) {
                return ips
            }
        }
        
        return nil
    }
    
    private func resolveWithDNS(_ domain: String, dns: String) async -> [String]? {
        // Check protocol type
        if dns.hasPrefix("https://") {
            // DoH (DNS over HTTPS)
            return await resolveWithDoH(domain, dohURL: dns)
        } else if dns.hasPrefix("tls://") {
            // DoT (DNS over TLS) - requires kdig from knot-dns
            let server = String(dns.dropFirst(6)) // Remove "tls://"
            return await resolveWithDoT(domain, server: server)
        } else if dns.contains(":853") {
            // DoT with explicit port
            let server = dns.replacingOccurrences(of: ":853", with: "")
            return await resolveWithDoT(domain, server: server)
        }
        
        // Regular DNS via dig
        let args = ["@\(dns)", "+short", "+time=2", "+tries=1", domain]
        guard let result = await runProcessAsync("/usr/bin/dig", arguments: args, timeout: 4.0) else {
            return nil
        }
        
        let ips = result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && isValidIP($0) }
        
        return ips.isEmpty ? nil : ips
    }
    
    private func resolveWithDoT(_ domain: String, server: String) async -> [String]? {
        // DNS-over-TLS using kdig (from knot-dns package)
        // Install with: brew install knot
        
        // Check if kdig is available
        let kdigPaths = ["/opt/homebrew/bin/kdig", "/usr/local/bin/kdig"]
        var kdigPath: String?
        for path in kdigPaths {
            if FileManager.default.fileExists(atPath: path) {
                kdigPath = path
                break
            }
        }
        
        guard let kdig = kdigPath else {
            // kdig not installed, fall back to other DNS methods
            log(.warning, "DoT requires kdig (brew install knot)")
            return nil
        }
        
        let args = ["+tls", "+short", "@\(server)", domain]
        guard let result = await runProcessAsync(kdig, arguments: args, timeout: 5.0),
              result.exitCode == 0 else {
            return nil
        }
        
        let ips = result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && isValidIP($0) }
        
        return ips.isEmpty ? nil : ips
    }
    
    private func resolveWithDoH(_ domain: String, dohURL: String) async -> [String]? {
        // DNS-over-HTTPS using JSON API (works with Cloudflare, Google, etc.)
        let url = "\(dohURL)?name=\(domain)&type=A"
        let args = ["-s", "-H", "accept: application/dns-json", url]
        
        guard let result = await runProcessAsync("/usr/bin/curl", arguments: args, timeout: 5.0),
              result.exitCode == 0 else {
            return nil
        }
        
        // Parse JSON response for A records
        // Format: {"Answer":[{"data":"1.2.3.4"},...]}
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else {
            return nil
        }
        
        let ips = answers.compactMap { answer -> String? in
            guard let type = answer["type"] as? Int, type == 1,  // Type 1 = A record
                  let ip = answer["data"] as? String,
                  isValidIP(ip) else {
                return nil
            }
            return ip
        }
        
        return ips.isEmpty ? nil : ips
    }
    
    private func addRoute(_ destination: String, gateway: String, isNetwork: Bool = false) async -> Bool {
        // Use privileged helper if installed
        if HelperManager.shared.isHelperInstalled {
            let result = await HelperManager.shared.addRoute(destination: destination, gateway: gateway, isNetwork: isNetwork)
            if !result.success {
                log(.warning, "Helper route add failed: \(result.error ?? "unknown")")
            }
            return result.success
        }
        
        // Fallback: direct command (may require sudo)
        // First try to delete existing route
        _ = await removeRoute(destination)
        
        let args = isNetwork 
            ? ["-n", "add", "-net", destination, gateway]
            : ["-n", "add", "-host", destination, gateway]
        
        guard let result = await runProcessAsync("/sbin/route", arguments: args, timeout: 5.0) else {
            return false
        }
        
        return result.exitCode == 0
    }
    
    private func removeRoute(_ destination: String) async -> Bool {
        // Use privileged helper if installed
        if HelperManager.shared.isHelperInstalled {
            let result = await HelperManager.shared.removeRoute(destination: destination)
            return result.success
        }
        
        // Fallback: direct command with timeout
        _ = await runProcessAsync("/sbin/route", arguments: ["-n", "delete", destination], timeout: 3.0)
        return true // Route delete can fail if route doesn't exist, that's ok
    }
    
    private func updateHostsFile() async {
        // Collect all domain -> IP mappings
        var entries: [(domain: String, ip: String)] = []
        
        for domain in config.domains where domain.enabled {
            if let ips = await resolveIPs(for: domain.domain), let firstIP = ips.first {
                entries.append((domain.domain, firstIP))
            }
        }
        
        for service in config.services where service.enabled {
            for domain in service.domains {
                if let ips = await resolveIPs(for: domain), let firstIP = ips.first {
                    entries.append((domain, firstIP))
                }
            }
        }
        
        // Update /etc/hosts (requires sudo)
        await modifyHostsFile(entries: entries)
    }
    
    private func cleanHostsFile() async {
        await modifyHostsFile(entries: [])
    }
    
    /// Called when app is quitting - clean up hosts file
    func cleanupOnQuit() async {
        log(.info, "Cleaning up /etc/hosts on quit...")
        await cleanHostsFile()
    }
    
    private func modifyHostsFile(entries: [(domain: String, ip: String)]) async {
        // Use privileged helper if installed
        if HelperManager.shared.isHelperInstalled {
            let result = await HelperManager.shared.updateHostsFile(entries: entries)
            if !result.success {
                log(.error, "Helper hosts update failed: \(result.error ?? "unknown")")
            }
            return
        }
        
        // Fallback: AppleScript with admin privileges (prompts each time)
        let marker = "# VPN-BYPASS-MANAGED"
        let hostsPath = "/etc/hosts"
        
        // Read current hosts file
        guard let currentContent = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            log(.error, "Could not read /etc/hosts")
            return
        }
        
        // Remove existing VPN-BYPASS section
        var lines = currentContent.components(separatedBy: "\n")
        var inSection = false
        lines = lines.filter { line in
            if line.contains("\(marker) - START") {
                inSection = true
                return false
            }
            if line.contains("\(marker) - END") {
                inSection = false
                return false
            }
            return !inSection
        }
        
        // Add new section if we have entries
        if !entries.isEmpty {
            lines.append("")
            lines.append("\(marker) - START")
            for entry in entries {
                lines.append("\(entry.ip) \(entry.domain)")
            }
            lines.append("\(marker) - END")
        }
        
        // Write back (this will fail without sudo - user needs to grant permission)
        let newContent = lines.joined(separator: "\n")
        
        // Use AppleScript to write with admin privileges
        let script = """
        do shell script "cat > /etc/hosts << 'VPNBYPASS_EOF'
        \(newContent)
        VPNBYPASS_EOF" with administrator privileges
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                // Flush DNS cache
                let flush = Process()
                flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
                flush.arguments = ["-flushcache"]
                try? flush.run()
            }
        }
    }
    
    private func cleanDomain(_ input: String) -> String {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove protocol
        if let url = URL(string: domain), let host = url.host {
            domain = host
        } else {
            domain = domain
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
        }
        // Remove path
        if let slashIndex = domain.firstIndex(of: "/") {
            domain = String(domain[..<slashIndex])
        }
        return domain.lowercased()
    }
    
    private func isValidIP(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0) != nil && Int($0)! >= 0 && Int($0)! <= 255 }
    }
    
    func log(_ level: LogEntry.LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        recentLogs.insert(entry, at: 0)
        if recentLogs.count > 200 {
            recentLogs.removeLast()
        }
        
        // Log to file
        let logLine = "[\(ISO8601DateFormatter().string(from: Date()))] [\(level.rawValue)] \(message)\n"
        let logPath = "/tmp/vpnbypass.log"
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }
}
