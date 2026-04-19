// RouteManager.swift
// Core routing logic - manages VPN detection, routes, and hosts entries.

import Foundation
import Network
import AppKit
import UniformTypeIdentifiers

/// Dedicated queue for process execution to avoid GCD thread pool exhaustion
/// Global to ensure it's accessible from nonisolated contexts
private let vpnBypassProcessQueue = DispatchQueue(label: "com.vpnbypass.process", qos: .userInitiated, attributes: .concurrent)

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
    private var routeEpoch: UInt64 = 0  // Incremented by removeAllRoutes — lets in-flight applies detect preemption
    private var gatewayDetectedAt: Date?
    private var lastInterfaceReroute: Date?
    private var lastTailscaleSelfFingerprint: String?
    
    
    private var dnsCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VPNBypass/dns-cache.json")
    }
    
    /// Public accessor for UI to display detected DNS server
    var detectedDNSServerDisplay: String? {
        detectedDNSServer
    }
    
    // MARK: - Types

    enum RoutingMode: String, Codable {
        case bypass = "bypass"      // Domains bypass VPN (current behavior)
        case vpnOnly = "vpnOnly"    // Only listed domains use VPN, everything else bypasses
    }

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
        case checkPoint = "Check Point"
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
            case .checkPoint: return "checkmark.shield.fill"
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
        var routingMode: RoutingMode = .bypass  // Bypass = domains bypass VPN, VPN Only = only listed domains use VPN
        var inverseDomains: [DomainEntry] = []  // Domains that should use VPN in VPN Only mode

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
            routingMode = try container.decodeIfPresent(RoutingMode.self, forKey: .routingMode) ?? .bypass
            inverseDomains = try container.decodeIfPresent([DomainEntry].self, forKey: .inverseDomains) ?? []
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
                    "signal.org", "www.signal.org", "updates.signal.org", "chat.signal.org"
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
                    "twitter.com", "x.com", "www.twitter.com", "api.twitter.com", "t.co", "pbs.twimg.com", "abs.twimg.com"
                ], ipRanges: []),
                ServiceEntry(id: "instagram", name: "Instagram", enabled: false, domains: [
                    "instagram.com", "www.instagram.com", "i.instagram.com", "scontent.cdninstagram.com"
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
                    // Core domains
                    "openai.com", "www.openai.com", "chatgpt.com", "www.chatgpt.com", "chat.com", "sora.com", "crixet.com",
                    // OpenAI subdomains
                    "chat.openai.com", "api.openai.com", "platform.openai.com", "platform.api.openai.com",
                    "beta.api.openai.com", "auth.openai.com", "external.auth.openai.com", "auth0.openai.com", "cdn.openai.com",
                    "help.openai.com", "blog.openai.com", "community.openai.com", "labs.openai.com",
                    "arena.openai.com", "beta.openai.com", "sentinel.openai.com", "ab.chatgpt.com", "ws.chatgpt.com", "pay.openai.com",
                    // Static assets and user content CDN
                    "oaistatic.com", "cdn.oaistatic.com", "auth-cdn.oaistatic.com",
                    "oaiusercontent.com", "files.oaiusercontent.com",
                    "openaicom.imgix.net",
                    // Azure CDN infrastructure
                    "openaiapi-site.azureedge.net", "production-openaicom-storage.azureedge.net",
                    "openaicomproductionae4b.blob.core.windows.net",
                    "openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net",
                    // Cloudflare infrastructure
                    "chat.openai.com.cdn.cloudflare.net", "openai.com.cdn.cloudflare.net",
                    // Voice features (LiveKit)
                    "chatgpt.livekit.cloud", "host.livekit.cloud", "turn.livekit.cloud",
                    // Anti-bot (required for login)
                    "openai-api.arkoselabs.com",
                    // Analytics
                    "o33249.ingest.sentry.io"
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
        var isCIDR: Bool

        init(domain: String, enabled: Bool = true, isCIDR: Bool = false) {
            self.id = UUID()
            self.domain = domain
            self.enabled = enabled
            self.isCIDR = isCIDR
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            domain = try container.decode(String.self, forKey: .domain)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            resolvedIP = try container.decodeIfPresent(String.self, forKey: .resolvedIP)
            lastResolved = try container.decodeIfPresent(Date.self, forKey: .lastResolved)
            isCIDR = try container.decodeIfPresent(Bool.self, forKey: .isCIDR) ?? false
        }
    }
    
    struct ServiceEntry: Codable, Identifiable {
        let id: String
        var name: String
        var enabled: Bool
        var domains: [String]
        var ipRanges: [String]
        var isCustom: Bool = false

        init(id: String, name: String, enabled: Bool, domains: [String], ipRanges: [String], isCustom: Bool = false) {
            self.id = id
            self.name = name
            self.enabled = enabled
            self.domains = domains
            self.ipRanges = ipRanges
            self.isCustom = isCustom
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            domains = try container.decode([String].self, forKey: .domains)
            ipRanges = try container.decode([String].self, forKey: .ipRanges)
            isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        }
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
        // Load DNS cache for faster startup / fallback
        loadDNSCache()
        
        guard let data = try? Data(contentsOf: configURL),
              let loaded = try? JSONDecoder().decode(Config.self, from: data) else {
            log(.info, "Using default config")
            return
        }
        config = loaded
        mergeBuiltInServices()
        log(.info, "Config loaded")
    }
    
    /// Merge built-in service definitions with the user's saved config.
    /// Preserves the user's enabled/disabled state while updating domains,
    /// ipRanges, and names from the latest source code definitions.
    /// Also adds any new built-in services that didn't exist when the user last saved.
    private func mergeBuiltInServices() {
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
            saveConfig()
            if updated > 0 { log(.info, "Updated \(updated) built-in service(s) with latest definitions") }
            if added > 0 { log(.info, "Added \(added) new built-in service(s)") }
        } else if config.services.count != merged.count {
            config.services = merged
            saveConfig()
        }
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
    
    // MARK: - DNS Disk Cache
    
    private func loadDNSCache() {
        guard let data = try? Data(contentsOf: dnsCacheURL),
              let cache = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        dnsDiskCache = cache
    }
    
    private func saveDNSCache() {
        guard let data = try? JSONEncoder().encode(dnsDiskCache) else { return }
        try? data.write(to: dnsCacheURL)
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

            // Merge or replace config, then normalize built-in services
            config = exportData.config
            mergeBuiltInServices()
            saveConfig()

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
                let result = Self.runProcessSyncSafe(executablePath, arguments: arguments, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Async process execution for parallel DNS - uses dedicated queue
    private nonisolated static func runProcessParallel(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = 5.0
    ) async -> (output: String, exitCode: Int32)? {
        await withCheckedContinuation { continuation in
            vpnBypassProcessQueue.async {
                let result = runProcessSyncSafe(executablePath, arguments: arguments, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Safe synchronous process execution - avoids semaphore deadlock by using runloop
    private static nonisolated func runProcessSyncSafe(
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
        
        // Use a simple polling approach with deadline instead of nested GCD + semaphore
        // This avoids thread pool exhaustion issues
        let deadline = Date().addingTimeInterval(timeout)
        
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01) // 10ms poll interval
        }
        
        if process.isRunning {
            // Timeout - terminate the process
            process.terminate()
            // Give it a moment to clean up
            Thread.sleep(forTimeInterval: 0.05)
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
        let oldTailscaleFingerprint = lastTailscaleSelfFingerprint
        
        // Detect current network first
        await detectCurrentNetwork()
        
        // Use scutil to detect VPN interfaces with IPv4 addresses
        let (connected, interface, detectedType) = await detectVPNInterface()
        
        isVPNConnected = connected
        vpnInterface = connected ? interface : nil
        vpnType = connected ? detectedType : nil
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
        if isVPNConnected && !wasVPNConnected && config.autoApplyOnVPN && !isLoading && !isApplyingRoutes && HelperManager.shared.isHelperInstalled {
            // Skip if routes were applied very recently (within 5 seconds) - prevents double-triggering
            if let lastUpdate = lastUpdate, Date().timeIntervalSince(lastUpdate) < 5 {
                log(.info, "Skipping duplicate route application (applied \(Int(Date().timeIntervalSince(lastUpdate)))s ago)")
            } else {
                log(.success, "VPN connected via \(interface ?? "unknown") (\(detectedType?.rawValue ?? "unknown type")), applying routes...")
                NotificationManager.shared.notifyVPNConnected(interface: interface ?? "unknown")
                
                // Show loading indicator while applying routes
                isLoading = true
                await applyAllRoutes()
                isLoading = false
            }
        }
        
        // VPN interface switched while still connected — re-route through new gateway
        if isVPNConnected && wasVPNConnected && interface != oldInterface && oldInterface != nil && interface != nil && !isLoading && !isApplyingRoutes && HelperManager.shared.isHelperInstalled {
            if let last = lastInterfaceReroute, Date().timeIntervalSince(last) < 10 {
                log(.info, "Skipping interface re-route (cooldown, last was \(Int(Date().timeIntervalSince(last)))s ago)")
            } else {
                log(.warning, "VPN interface changed: \(oldInterface ?? "?") → \(interface ?? "?")")
                lastInterfaceReroute = Date()
                if localGateway != nil, acquireRouteOperation() {
                    isLoading = true
                    await removeAllRoutes()
                    await applyAllRoutesInternal(sendNotification: false)
                    isLoading = false
                    releaseRouteOperation()
                } else if localGateway == nil {
                    log(.error, "VPN interface changed but no gateway detected")
                }
            }
        }

        // Tailscale account/profile can change while utun interface stays the same.
        // Re-apply routes when active local Tailscale identity changes.
        if isVPNConnected && wasVPNConnected &&
           interface == oldInterface &&
           oldTailscaleFingerprint != nil && newTailscaleFingerprint != nil &&
           oldTailscaleFingerprint != newTailscaleFingerprint &&
           !isLoading && !isApplyingRoutes && HelperManager.shared.isHelperInstalled {
            if let last = lastInterfaceReroute, Date().timeIntervalSince(last) < 10 {
                log(.info, "Skipping Tailscale profile re-route (cooldown, last was \(Int(Date().timeIntervalSince(last)))s ago)")
            } else {
                log(.warning, "Tailscale active account changed, refreshing routes")
                lastInterfaceReroute = Date()
                if localGateway != nil, acquireRouteOperation() {
                    isLoading = true
                    await removeAllRoutes()
                    await applyAllRoutesInternal(sendNotification: false)
                    isLoading = false
                    releaseRouteOperation()
                } else if localGateway == nil {
                    log(.error, "Tailscale account changed but no gateway detected")
                }
            }
        }
        
        if !isVPNConnected && wasVPNConnected {
            log(.warning, "VPN disconnected (was: \(oldInterface ?? "unknown"))")
            cancelAllRetries()
            // Remove kernel routes before clearing in-memory state
            await removeAllRoutes()
            routeVerificationResults.removeAll()
            lastTailscaleSelfFingerprint = nil
            vpnGateway = nil
            // Notify after cleanup so notification reflects actual state
            NotificationManager.shared.notifyVPNDisconnected(wasInterface: oldInterface, routesRemaining: activeRoutes.count)
        }
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
        
        // Second pass: check corporate VPN IPs (async) and find valid VPN
        var vpnCandidates: [(name: String, ip: String, isValid: Bool)] = []
        
        for i in interfaces.indices {
            let isValid = await isCorporateVPNIP(interfaces[i].ip, hintType: hintType)
            interfaces[i].isValidCorporateIP = isValid
            
            // Track VPN candidates for debugging
            if interfaces[i].isVPN {
                vpnCandidates.append((interfaces[i].name, interfaces[i].ip, isValid))
            }
            
            // Check if this is our VPN
            if interfaces[i].isVPN && interfaces[i].hasUpFlag && isValid {
                let vpnType = hintType ?? detectVPNTypeFromInterface(interfaces[i].name)
                return (true, interfaces[i].name, vpnType)
            }
        }
        
        // Debug: log what we found if no VPN detected
        if !vpnCandidates.isEmpty {
            let summary = vpnCandidates.map { "\($0.name):\($0.ip) valid=\($0.isValid)" }.joined(separator: ", ")
            await MainActor.run { log(.info, "VPN candidates (none matched): \(summary)") }
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
    /// hintType comes from process detection -- used to distinguish Zscaler/WARP from Tailscale in the shared CGNAT range.
    private func isCorporateVPNIP(_ ip: String, hintType: VPNType?) async -> Bool {
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
            if await isTailscaleIP(ip) {
                return await isTailscaleExitNodeActive()
            }
            // Non-Tailscale CGNAT IP on a VPN interface → accept as corporate VPN
            return true
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
    
    /// Read tailscale status JSON from any known CLI path.
    private func readTailscaleStatusJSON() async -> [String: Any]? {
        let tailscalePaths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        
        for path in tailscalePaths {
            if FileManager.default.fileExists(atPath: path) {
                guard let result = await runProcessAsync(path, arguments: ["status", "--json", "--self", "--peers=false"], timeout: 3.0) else {
                    continue
                }
                
                if let jsonData = result.output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    return json
                }
            }
        }
        
        return nil
    }
    
    /// Called from startup - no notification
    func detectAndApplyRoutes() {
        Task {
            await detectAndApplyRoutesAsync(sendNotification: false)
        }
    }
    
    /// Called from Refresh button - sends notification
    func refreshRoutes() {
        guard HelperManager.shared.isHelperInstalled else {
            log(.error, "Cannot refresh routes: helper not ready (\(HelperManager.shared.helperState.statusText))")
            return
        }
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
                
                // Background refresh: re-resolve DNS and update routes if changed
                Task.detached { [weak self] in
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
            isLoading = false
        } else if localGateway == nil {
            log(.error, "Could not detect local gateway")
            isLoading = false
        }
    }
    
    func refreshStatus() {
        Task {
            await checkVPNStatus()
        }
    }
    
    /// Apply all routes — acquires exclusive gate, skips if another operation is running
    func applyAllRoutes() async {
        guard acquireRouteOperation() else {
            log(.info, "Apply skipped: route operation in progress")
            return
        }
        defer { releaseRouteOperation() }
        await applyAllRoutesInternal(sendNotification: false)
    }

    /// Apply all routes and send notification (called from Refresh button)
    func applyAllRoutesWithNotification() async {
        guard acquireRouteOperation() else {
            log(.info, "Apply skipped: route operation in progress")
            return
        }
        defer { releaseRouteOperation() }
        await applyAllRoutesInternal(sendNotification: true)
    }

    /// Internal — gate-free, callers must hold the route operation lock.
    /// Checks routeEpoch before committing to detect preemption by removeAllRoutes.
    private func applyAllRoutesInternal(sendNotification: Bool) async {
        let epoch = routeEpoch

        guard let gateway = localGateway else {
            log(.error, "No local gateway available")
            return
        }

        let isInverse = config.routingMode == .vpnOnly

        // VPN Only mode requires the VPN gateway for domain-specific routes
        if isInverse {
            guard let vpnGw = vpnGateway else {
                log(.error, "VPN Only mode requires a VPN gateway (is VPN connected?)")
                return
            }
            log(.info, "VPN Only mode: bypass-all via \(gateway), VPN domains via \(vpnGw)")
        }

        var newRoutes: [ActiveRoute] = []
        var failedCount = 0

        // Clear DNS cache for fresh resolution
        dnsCache.removeAll()

        // Collect all domains to resolve (for parallel resolution)
        var allDomains: [(domain: String, source: String)] = []

        // Collect CIDR entries separately (added to route structures after variable declarations)
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

        // Collect all routes to add (for batch operation)
        var routesToAdd: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = []
        var seenDestinations: Set<String> = []  // Deduplicate kernel operations
        var allSourceEntries: [(destination: String, source: String)] = []  // Track all sources per IP
        var seenSourceDests: Set<String> = []  // Deduplicate (source, destination) pairs

        // VPN Only mode: add catch-all routes through local gateway first
        // 0.0.0.0/1 + 128.0.0.0/1 cover all IPv4 with higher specificity than default route
        if isInverse {
            routesToAdd.append((destination: "0.0.0.0/1", gateway: gateway, isNetwork: true, source: "VPN Only catch-all"))
            routesToAdd.append((destination: "128.0.0.0/1", gateway: gateway, isNetwork: true, source: "VPN Only catch-all"))
            seenDestinations.insert("0.0.0.0/1")
            seenDestinations.insert("128.0.0.0/1")
            allSourceEntries.append((destination: "0.0.0.0/1", source: "VPN Only catch-all"))
            allSourceEntries.append((destination: "128.0.0.0/1", source: "VPN Only catch-all"))
            seenSourceDests.insert("VPN Only catch-all|0.0.0.0/1")
            seenSourceDests.insert("VPN Only catch-all|128.0.0.0/1")

            // Add CIDR entries as network routes through VPN gateway
            for cidr in inverseCIDRs {
                if !seenDestinations.contains(cidr) {
                    seenDestinations.insert(cidr)
                    routesToAdd.append((destination: cidr, gateway: routeGateway, isNetwork: true, source: cidr))
                }
                let key = "\(cidr)|\(cidr)"
                if !seenSourceDests.contains(key) {
                    seenSourceDests.insert(key)
                    allSourceEntries.append((destination: cidr, source: cidr))
                }
            }
        }

        while index < allDomains.count {
            let endIndex = min(index + batchSize, allDomains.count)
            let batch = Array(allDomains[index..<endIndex])
            
            // Resolve DNS in parallel (truly parallel - nonisolated)
            let dnsResults = await withTaskGroup(of: (domain: String, source: String, ips: [String]?).self) { group in
                for item in batch {
                    group.addTask {
                        let ips = await Self.resolveIPsParallel(for: item.domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
                        return (item.domain, item.source, ips)
                    }
                }
                
                var results: [(domain: String, source: String, ips: [String]?)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            
            // Collect routes from DNS results and cache for hosts file
            for result in dnsResults {
                if let ips = result.ips, !ips.isEmpty {
                    // DNS succeeded - use fresh IPs and update disk cache
                    if let firstIP = ips.first {
                        dnsCache[result.domain] = firstIP
                    }
                    dnsDiskCache[result.domain] = ips  // Update persistent cache

                    for ip in ips {
                        // Dedup kernel operations
                        if !seenDestinations.contains(ip) {
                            seenDestinations.insert(ip)
                            routesToAdd.append((destination: ip, gateway: routeGateway, isNetwork: false, source: result.source))
                        }
                        // Dedup (source, destination) ownership pairs
                        let key = "\(result.source)|\(ip)"
                        if !seenSourceDests.contains(key) {
                            seenSourceDests.insert(key)
                            allSourceEntries.append((destination: ip, source: result.source))
                        }
                    }
                } else if let cachedIPs = dnsDiskCache[result.domain], !cachedIPs.isEmpty {
                    // DNS failed but we have cached IPs - use them as fallback
                    log(.info, "Using cached IPs for \(result.domain)")
                    if let firstIP = cachedIPs.first {
                        dnsCache[result.domain] = firstIP
                    }
                    for ip in cachedIPs {
                        if !seenDestinations.contains(ip) {
                            seenDestinations.insert(ip)
                            routesToAdd.append((destination: ip, gateway: routeGateway, isNetwork: false, source: result.source))
                        }
                        let key = "\(result.source)|\(ip)"
                        if !seenSourceDests.contains(key) {
                            seenSourceDests.insert(key)
                            allSourceEntries.append((destination: ip, source: result.source))
                        }
                    }
                } else {
                    failedDomains.insert(result.domain)
                    failedCount += 1
                }
            }
            
            index += batchSize
        }
        
        // Save updated DNS cache to disk
        saveDNSCache()
        
        // Collect IP ranges (bypass mode only — services are not used in VPN Only mode)
        if !isInverse {
            for service in config.services where service.enabled {
                for range in service.ipRanges {
                    let key = "\(service.name)|\(range)"
                    if !seenSourceDests.contains(key) {
                        seenSourceDests.insert(key)
                        allSourceEntries.append((destination: range, source: service.name))
                    }
                    guard !seenDestinations.contains(range) else { continue }
                    seenDestinations.insert(range)
                    routesToAdd.append((destination: range, gateway: gateway, isNetwork: true, source: service.name))
                }
            }
        }
        
        log(.info, "Adding \(routesToAdd.count) routes via batch operation...")
        
        // Apply all routes in batch (single XPC call for massive speedup)
        let routeGwForEntries = routeGateway  // capture for source entries
        var batchFailureCount = 0
        var batchFailedDests: Set<String> = []
        if HelperManager.shared.isHelperInstalled {
            let helperRoutes = routesToAdd.map { (destination: $0.destination, gateway: $0.gateway, isNetwork: $0.isNetwork) }
            let result = await HelperManager.shared.addRoutesBatch(routes: helperRoutes)
            batchFailureCount = result.failureCount
            batchFailedDests = Set(result.failedDestinations)

            if result.failureCount > 0 {
                log(.warning, "Batch route add: \(result.successCount) succeeded, \(result.failureCount) failed (\(result.failedDestinations.prefix(3).joined(separator: ", "))...)")
            }
        } else {
            log(.error, "Cannot add routes: helper not ready (\(HelperManager.shared.helperState.statusText))")
            return
        }

        // Build activeRoutes from allSourceEntries, excluding destinations that failed kernel add
        let appliedDestinations = Set(routesToAdd.map { $0.destination }).subtracting(batchFailedDests)
        for entry in allSourceEntries where appliedDestinations.contains(entry.destination) {
            let gw = routesToAdd.first(where: { $0.destination == entry.destination })?.gateway ?? routeGwForEntries
            newRoutes.append(ActiveRoute(
                destination: entry.destination,
                gateway: gw,
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
        let batchAttemptedDests = Set(routesToAdd.map { $0.destination })
        let allStaleDests = Set(activeRoutes.map { $0.destination }).subtracting(newDestinations)
        let trulyOrphanedDests = Array(allStaleDests.subtracting(batchAttemptedDests))
        let addFailedStaleDests = Array(allStaleDests.intersection(batchAttemptedDests))

        // Truly orphaned: re-attach on failure (route is genuinely still in kernel)
        if !trulyOrphanedDests.isEmpty {
            let result = await HelperManager.shared.removeRoutesBatch(destinations: trulyOrphanedDests)
            if result.failureCount > 0 {
                log(.warning, "Orphan cleanup: \(result.successCount) removed, \(result.failureCount) failed — retaining")
                let failedSet = Set(result.failedDestinations)
                for route in activeRoutes where failedSet.contains(route.destination) && !newDestinations.contains(route.destination) {
                    newRoutes.append(route)
                }
            } else if result.successCount > 0 {
                log(.info, "Orphan cleanup: \(result.successCount) stale kernel routes removed")
            }
        }

        // Add-failed: helper's addRoute does delete-before-add, so the old route is
        // gone after a failed re-add. Don't re-attach — the kernel route doesn't exist.
        if !addFailedStaleDests.isEmpty {
            let result = await HelperManager.shared.removeRoutesBatch(destinations: addFailedStaleDests)
            if result.failureCount > 0 {
                log(.info, "Add-failed cleanup: \(result.failureCount) route(s) already removed by delete-before-add")
            }
        }

        // Preemption check: if removeAllRoutes() ran during our awaits, our results are stale.
        // The epoch check + commit is atomic on @MainActor (no await between them).
        guard routeEpoch == epoch else {
            log(.warning, "Apply aborted: routes were cleared during operation")
            return
        }

        activeRoutes = newRoutes
        lastUpdate = Date()

        // Manage hosts file if enabled
        if config.manageHostsFile {
            await updateHostsFile()
        }

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
    
    /// Remove all routes — always proceeds (critical teardown for disconnect/quit/clear).
    /// Does NOT acquire the route operation gate so it cannot be blocked by a running operation.
    /// Increments routeEpoch so in-flight applies detect preemption and abort before committing.
    func removeAllRoutes() async {
        routeEpoch &+= 1
        let destinations = Array(Set(activeRoutes.map { $0.destination }))

        var failedDests: Set<String> = []
        if !destinations.isEmpty {
            if HelperManager.shared.isHelperInstalled {
                let result = await HelperManager.shared.removeRoutesBatch(destinations: destinations)
                failedDests = Set(result.failedDestinations)
                if result.failureCount > 0 {
                    log(.warning, "Batch route removal: \(result.successCount) succeeded, \(result.failureCount) failed — retaining failed entries in model")
                } else {
                    log(.info, "Batch route removal: \(result.successCount) routes removed")
                }
            } else {
                log(.error, "Cannot remove routes: helper not ready (\(HelperManager.shared.helperState.statusText))")
            }
        }

        cancelAllRetries()
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

        // VPN Only mode needs VPN gateway for domain routes
        if isInverse {
            guard let _ = vpnGateway else {
                log(.error, "Cannot apply cached routes in VPN Only mode: no VPN gateway")
                return false
            }
        }

        let routeGateway = isInverse ? vpnGateway! : gateway

        var newRoutes: [ActiveRoute] = []
        var routesToAdd: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = []
        var seenDestinations: Set<String> = []  // Deduplicate kernel operations
        var allSourceEntries: [(destination: String, gateway: String, source: String)] = []
        var seenSourceDests: Set<String> = []  // Deduplicate (source, destination) pairs

        if isInverse {
            // VPN Only mode: catch-all through local gateway, domain routes through VPN
            routesToAdd.append((destination: "0.0.0.0/1", gateway: gateway, isNetwork: true, source: "VPN Only catch-all"))
            routesToAdd.append((destination: "128.0.0.0/1", gateway: gateway, isNetwork: true, source: "VPN Only catch-all"))
            seenDestinations.insert("0.0.0.0/1")
            seenDestinations.insert("128.0.0.0/1")
            allSourceEntries.append((destination: "0.0.0.0/1", gateway: gateway, source: "VPN Only catch-all"))
            allSourceEntries.append((destination: "128.0.0.0/1", gateway: gateway, source: "VPN Only catch-all"))
            seenSourceDests.insert("VPN Only catch-all|0.0.0.0/1")
            seenSourceDests.insert("VPN Only catch-all|128.0.0.0/1")

            for domain in config.inverseDomains where domain.enabled {
                if domain.isCIDR {
                    // CIDR entries: route directly as network routes, no DNS cache
                    let cidr = domain.domain
                    let key = "\(cidr)|\(cidr)"
                    if !seenSourceDests.contains(key) {
                        seenSourceDests.insert(key)
                        allSourceEntries.append((destination: cidr, gateway: routeGateway, source: cidr))
                    }
                    if !seenDestinations.contains(cidr) {
                        seenDestinations.insert(cidr)
                        routesToAdd.append((destination: cidr, gateway: routeGateway, isNetwork: true, source: cidr))
                    }
                } else if let cachedIPs = dnsDiskCache[domain.domain] {
                    for ip in cachedIPs {
                        let key = "\(domain.domain)|\(ip)"
                        if !seenSourceDests.contains(key) {
                            seenSourceDests.insert(key)
                            allSourceEntries.append((destination: ip, gateway: routeGateway, source: domain.domain))
                        }
                        if !seenDestinations.contains(ip) {
                            seenDestinations.insert(ip)
                            routesToAdd.append((destination: ip, gateway: routeGateway, isNetwork: false, source: domain.domain))
                        }
                    }
                    if let firstIP = cachedIPs.first {
                        dnsCache[domain.domain] = firstIP
                    }
                }
            }
        } else {
            // Bypass mode: services + domains through local gateway
            for service in config.services where service.enabled {
                for domain in service.domains {
                    if let cachedIPs = dnsDiskCache[domain] {
                        for ip in cachedIPs {
                            let key = "\(service.name)|\(ip)"
                            if !seenSourceDests.contains(key) {
                                seenSourceDests.insert(key)
                                allSourceEntries.append((destination: ip, gateway: gateway, source: service.name))
                            }
                            if !seenDestinations.contains(ip) {
                                seenDestinations.insert(ip)
                                routesToAdd.append((destination: ip, gateway: gateway, isNetwork: false, source: service.name))
                            }
                        }
                        if let firstIP = cachedIPs.first {
                            dnsCache[domain] = firstIP
                        }
                    }
                }
                for range in service.ipRanges {
                    let key = "\(service.name)|\(range)"
                    if !seenSourceDests.contains(key) {
                        seenSourceDests.insert(key)
                        allSourceEntries.append((destination: range, gateway: gateway, source: service.name))
                    }
                    if !seenDestinations.contains(range) {
                        seenDestinations.insert(range)
                        routesToAdd.append((destination: range, gateway: gateway, isNetwork: true, source: service.name))
                    }
                }
            }

            for domain in config.domains where domain.enabled {
                if let cachedIPs = dnsDiskCache[domain.domain] {
                    for ip in cachedIPs {
                        let key = "\(domain.domain)|\(ip)"
                        if !seenSourceDests.contains(key) {
                            seenSourceDests.insert(key)
                            allSourceEntries.append((destination: ip, gateway: gateway, source: domain.domain))
                        }
                        if !seenDestinations.contains(ip) {
                            seenDestinations.insert(ip)
                            routesToAdd.append((destination: ip, gateway: gateway, isNetwork: false, source: domain.domain))
                        }
                    }
                    if let firstIP = cachedIPs.first {
                        dnsCache[domain.domain] = firstIP
                    }
                }
            }
        }

        log(.info, "Applying \(routesToAdd.count) routes from cache (\(isInverse ? "VPN Only" : "Bypass") mode)...")

        // Apply routes in batch via helper
        var batchFailureCount = 0
        var batchFailedDests: Set<String> = []
        if !routesToAdd.isEmpty {
            if HelperManager.shared.isHelperInstalled {
                let helperRoutes = routesToAdd.map { (destination: $0.destination, gateway: $0.gateway, isNetwork: $0.isNetwork) }
                let result = await HelperManager.shared.addRoutesBatch(routes: helperRoutes)
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

        // Build activeRoutes from all source entries, excluding failed kernel adds
        for entry in allSourceEntries where !batchFailedDests.contains(entry.destination) {
            newRoutes.append(ActiveRoute(
                destination: entry.destination,
                gateway: entry.gateway,
                source: entry.source,
                timestamp: Date()
            ))
        }

        // Clean up stale routes — same two-population logic as full apply
        let newDestinations = Set(newRoutes.map { $0.destination })
        let batchAttemptedDests = Set(routesToAdd.map { $0.destination })
        let allStaleDests = Set(activeRoutes.map { $0.destination }).subtracting(newDestinations)
        let trulyOrphanedDests = Array(allStaleDests.subtracting(batchAttemptedDests))
        let addFailedStaleDests = Array(allStaleDests.intersection(batchAttemptedDests))

        if !trulyOrphanedDests.isEmpty {
            let result = await HelperManager.shared.removeRoutesBatch(destinations: trulyOrphanedDests)
            if result.failureCount > 0 {
                log(.warning, "Cache orphan cleanup: \(result.successCount) removed, \(result.failureCount) failed — retaining")
                let failedSet = Set(result.failedDestinations)
                for route in activeRoutes where failedSet.contains(route.destination) && !newDestinations.contains(route.destination) {
                    newRoutes.append(route)
                }
            } else if result.successCount > 0 {
                log(.info, "Cache orphan cleanup: \(result.successCount) stale kernel routes removed")
            }
        }

        // Add-failed: delete-before-add already removed the old route (see full apply comment)
        if !addFailedStaleDests.isEmpty {
            let result = await HelperManager.shared.removeRoutesBatch(destinations: addFailedStaleDests)
            if result.failureCount > 0 {
                log(.info, "Cache add-failed cleanup: \(result.failureCount) route(s) already removed by delete-before-add")
            }
        }

        // Preemption check: if removeAllRoutes() ran during our awaits, our results are stale.
        guard routeEpoch == epoch else {
            log(.warning, "Cache apply aborted: routes were cleared during operation")
            return false
        }

        activeRoutes = newRoutes
        lastUpdate = Date()

        // Update hosts file
        if config.manageHostsFile {
            await updateHostsFile()
        }

        if batchFailureCount > 0 {
            log(.warning, "Applied routes from cache (\(batchFailureCount) kernel failures — counts approximate)")
        } else {
            log(.success, "Applied \(uniqueRouteCount) unique routes from cache")
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

        let isInverse = config.routingMode == .vpnOnly
        let routeGateway: String
        if isInverse {
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
                    domainsToResolve.append((domain.domain, domain.domain))
                }
            }
        } else {
            for service in config.services where service.enabled {
                for domain in service.domains {
                    domainsToResolve.append((domain, service.name))
                }
            }
            for domain in config.domains where domain.enabled {
                domainsToResolve.append((domain.domain, domain.domain))
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
                    let ips = await Self.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
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
                let result = await HelperManager.shared.addRoutesBatch(routes: routes)
                addFailedDests = Set(result.failedDestinations)

                // Record ownership for ALL sources whose destinations succeeded
                await MainActor.run {
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
                        // Already repaired by another service — just add ownership
                        await MainActor.run {
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
                        await MainActor.run {
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

        // Preemption check: if removeAllRoutes() ran during our awaits, skip commits
        guard routeEpoch == epoch else {
            await MainActor.run { log(.warning, "Background DNS refresh aborted: routes were cleared during operation") }
            return
        }

        // Update hosts file with any newly resolved domains (only if still connected)
        let shouldUpdateHosts = await MainActor.run { config.manageHostsFile && isVPNConnected }
        if shouldUpdateHosts {
            await updateHostsFile()
            await MainActor.run { log(.info, "Background refresh: hosts file updated") }
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

        let isInverse = config.routingMode == .vpnOnly
        let routeGateway: String
        if isInverse {
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

        // Source-aware tracking: (source, destination) pairs instead of flat IP sets
        struct SourceDest: Hashable { let source: String; let destination: String }
        var expectedEntries: Set<SourceDest> = []
        var addedKernelRoutes: Set<String> = []  // Track new kernel routes added this cycle

        // Preserve catch-all routes in VPN Only mode (they aren't DNS-resolved)
        if isInverse {
            expectedEntries.insert(SourceDest(source: "VPN Only catch-all", destination: "0.0.0.0/1"))
            expectedEntries.insert(SourceDest(source: "VPN Only catch-all", destination: "128.0.0.0/1"))
        }

        // Collect domains based on routing mode
        var domainsToResolve: [(domain: String, source: String)] = []

        if isInverse {
            for domain in config.inverseDomains where domain.enabled {
                if domain.isCIDR {
                    // CIDR entries: preserve as static routes, no DNS resolution
                    expectedEntries.insert(SourceDest(source: domain.domain, destination: domain.domain))
                } else {
                    domainsToResolve.append((domain.domain, domain.domain))
                }
            }
        } else {
            for domain in config.domains where domain.enabled {
                domainsToResolve.append((domain.domain, domain.domain))
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

        // Re-resolve and check for changes
        var resolvedDomainIPs: [String: [String]] = [:]
        for (domain, source) in domainsToResolve {
            if let ips = await resolveIPs(for: domain) {
                resolvedDomainIPs[domain] = ips
                for ip in ips {
                    let entry = SourceDest(source: source, destination: ip)
                    expectedEntries.insert(entry)

                    // Add kernel route if destination is completely new
                    let kernelHasRoute: Bool
                    if !existingDestinations.contains(ip) && !addedKernelRoutes.contains(ip) {
                        if await addRoute(ip, gateway: routeGateway) {
                            addedKernelRoutes.insert(ip)
                            updatedCount += 1
                            kernelHasRoute = true
                            log(.success, "DNS refresh: added new IP \(ip) for \(domain)")
                        } else {
                            kernelHasRoute = false
                        }
                    } else {
                        kernelHasRoute = true  // already exists in kernel
                    }

                    // Only record source entry if kernel actually has the route
                    if kernelHasRoute && !existingSourceDests.contains(entry) {
                        activeRoutes.append(ActiveRoute(
                            destination: ip,
                            gateway: routeGateway,
                            source: source,
                            timestamp: Date()
                        ))
                    }
                }
            } else if let cachedIPs = dnsDiskCache[domain] {
                // DNS failed — preserve cached IPs so they aren't treated as stale
                for ip in cachedIPs {
                    expectedEntries.insert(SourceDest(source: source, destination: ip))
                }
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
                        // Already repaired by another service — just add ownership
                        activeRoutes.append(ActiveRoute(
                            destination: range,
                            gateway: routeGateway,
                            source: service.name,
                            timestamp: Date()
                        ))
                        continue
                    }
                    // Repair missing CIDR route
                    if await addRoute(range, gateway: routeGateway, isNetwork: true) {
                        activeRoutes.append(ActiveRoute(
                            destination: range,
                            gateway: routeGateway,
                            source: service.name,
                            timestamp: Date()
                        ))
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
                    activeRoutes.append(ActiveRoute(
                        destination: cidr,
                        gateway: routeGateway,
                        source: cidr,
                        timestamp: Date()
                    ))
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
            nextDNSRefresh = config.autoDNSRefresh ? Date().addingTimeInterval(config.dnsRefreshInterval) : nil
            return
        }

        // Update hosts file if enabled and still connected
        if config.manageHostsFile && isVPNConnected {
            await updateHostsFile()
            log(.info, "DNS refresh: hosts file updated")
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
        let cleaned = cleanDomain(domain)
        guard !cleaned.isEmpty else { return }
        guard !config.domains.contains(where: { $0.domain == cleaned }) else {
            log(.warning, "Domain \(cleaned) already exists")
            return
        }
        
        config.domains.append(DomainEntry(domain: cleaned))
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
                if let routes = await applyRoutesForDomain(cleaned, gateway: gateway) {
                    guard routeEpoch == epoch else { return }
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
        guard config.domains.contains(where: { $0.domain == domain && $0.enabled }) else { return }
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
        if let routes = await applyRoutesForDomain(domain, gateway: gateway) {
            guard routeEpoch == epoch else { return }
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
                    if let routes = await applyRoutesForDomain(domain.domain, gateway: gateway) {
                        guard routeEpoch == epoch else { return }
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
            let gateway: String? = enabled ? await ensureGateway() : nil
            if enabled && gateway == nil {
                log(.error, "Cannot enable domains: no local gateway detected")
                return
            }
            for domain in domainsToChange {
                guard routeEpoch == epoch else { return }
                if enabled, let gw = gateway {
                    if let routes = await applyRoutesForDomain(domain.domain, gateway: gw, persistCache: false) {
                        guard routeEpoch == epoch else { return }
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
        let entry: String
        if cidr {
            entry = trimmed
        } else {
            entry = cleanDomain(trimmed)
            guard !entry.isEmpty else { return }
        }

        guard !config.inverseDomains.contains(where: { $0.domain == entry }) else {
            log(.warning, "VPN Only entry \(entry) already exists")
            return
        }
        config.inverseDomains.append(DomainEntry(domain: entry, isCIDR: cidr))
        saveConfig()
        log(.success, "Added VPN Only \(cidr ? "CIDR" : "domain"): \(entry)")

        if isVPNConnected && config.routingMode == .vpnOnly && acquireRouteOperation() {
            Task {
                defer { releaseRouteOperation() }
                let epoch = routeEpoch
                guard let gw = vpnGateway else {
                    log(.error, "Cannot route \(entry): no VPN gateway detected")
                    return
                }
                if cidr {
                    // CIDR: add network route directly, no DNS resolution needed
                    if await addRoute(entry, gateway: gw, isNetwork: true) {
                        guard routeEpoch == epoch else { return }
                        activeRoutes.append(ActiveRoute(
                            destination: entry,
                            gateway: gw,
                            source: entry,
                            timestamp: Date()
                        ))
                        log(.success, "Routed CIDR \(entry) through VPN")
                    }
                } else if let routes = await applyRoutesForDomain(entry, gateway: gw) {
                    guard routeEpoch == epoch else { return }
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
                            guard routeEpoch == epoch else { return }
                            activeRoutes.append(ActiveRoute(
                                destination: domain.domain,
                                gateway: gw,
                                source: domain.domain,
                                timestamp: Date()
                            ))
                        }
                    } else if let routes = await applyRoutesForDomain(domain.domain, gateway: gw) {
                        guard routeEpoch == epoch else { return }
                        activeRoutes.append(contentsOf: routes)
                        if config.manageHostsFile { await updateHostsFile() }
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

        config.routingMode = mode
        saveConfig()
        log(.info, "Routing mode changed to \(mode == .bypass ? "Bypass" : "VPN Only")")

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
                    let ips = await Self.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
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
            let result = await HelperManager.shared.addRoutesBatch(routes: routesToAdd)
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
    
    /// Acquire exclusive route operation lock. Returns false if another operation is running.
    /// @MainActor guarantees atomic check-and-set between await suspension points.
    private func acquireRouteOperation() -> Bool {
        guard !isApplyingRoutes else { return false }
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
                if gateway != "none" && !gateway.isEmpty && isValidIP(gateway) {
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
                    let gateway = parts[1].trimmingCharacters(in: .whitespaces)
                    if isValidIP(gateway) {
                        return gateway
                    }
                }
            }
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
    
    private var pendingRetryTasks: [String: Task<Void, Never>] = [:]
    
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
    
    private func applyRouteForRange(_ range: String, gateway: String) async -> Bool {
        return await addRoute(range, gateway: gateway, isNetwork: true)
    }
    
    private func resolveIPs(for domain: String) async -> [String]? {
        // Use nonisolated static method for true parallelism
        let userDNS = detectedDNSServer
        let fallbackDNS = config.fallbackDNS
        return await Self.resolveIPsParallel(for: domain, userDNS: userDNS, fallbackDNS: fallbackDNS)
    }
    
    /// Nonisolated DNS resolution - races dig and DoH in parallel with trust hierarchy.
    /// Dig-based resolvers fire immediately (trusted); DoH fires after a 200ms grace period
    /// so it only wins when VPN blocks UDP DNS. Resolves in ~2s on VPN instead of 8+.
    private nonisolated static func resolveIPsParallel(for domain: String, userDNS: String?, fallbackDNS: [String]) async -> [String]? {
        let dohGraceNs: UInt64 = 200_000_000 // 200ms head start for trusted dig resolvers
        let hardcodedDoH = ["https://cloudflare-dns.com/dns-query", "https://dns.google/dns-query"]
        
        for attempt in 1...2 {
            let result: [String]? = await withTaskGroup(of: [String]?.self) { group in
                // Tier 1: dig-based resolvers fire immediately (trusted, local/fast)
                if let userDNS = userDNS {
                    group.addTask { await resolveWithDNSParallel(domain, dns: userDNS) }
                }
                for dns in fallbackDNS {
                    group.addTask { await resolveWithDNSParallel(domain, dns: dns) }
                }
                
                // Tier 2: DoH fires after grace period — only wins when dig is blocked by VPN
                for doh in hardcodedDoH where !fallbackDNS.contains(doh) {
                    group.addTask {
                        do { try await Task.sleep(nanoseconds: dohGraceNs) } catch { return nil }
                        return await resolveWithDoHParallel(domain, dohURL: doh)
                    }
                }
                
                for await result in group {
                    if let ips = result, !ips.isEmpty {
                        group.cancelAll()
                        return ips
                    }
                }
                return nil
            }
            
            if let result = result {
                return result
            }
            
            if attempt < 2 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return nil }
            }
        }
        
        // System resolver as absolute last resort (uses VPN's DNS, may not bypass)
        return await resolveWithSystemResolver(domain, timeout: 3.0)
    }
    
    /// Resolve using system's getaddrinfo - uses OS-level DNS which may work when dig fails
    /// Note: When VPN is active, this typically uses VPN's DNS servers
    private nonisolated static func resolveWithSystemResolver(_ domain: String, timeout: TimeInterval) async -> [String]? {
        // Race between getaddrinfo and timeout
        return await withTaskGroup(of: [String]?.self) { group in
            // Actual resolution task
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var hints = addrinfo()
                        hints.ai_family = AF_INET  // IPv4 only for routing
                        hints.ai_socktype = SOCK_STREAM
                        
                        var result: UnsafeMutablePointer<addrinfo>?
                        let status = getaddrinfo(domain, nil, &hints, &result)
                        
                        guard status == 0, let addrInfo = result else {
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        defer { freeaddrinfo(addrInfo) }
                        
                        var ips: [String] = []
                        var current: UnsafeMutablePointer<addrinfo>? = addrInfo
                        
                        while let info = current {
                            if info.pointee.ai_family == AF_INET,
                               let sockaddr = info.pointee.ai_addr {
                                sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                                    var inAddr = addr.pointee.sin_addr
                                    if inet_ntop(AF_INET, &inAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                                        let ip = String(cString: ipBuffer)
                                        if !ips.contains(ip) {
                                            ips.append(ip)
                                        }
                                    }
                                }
                            }
                            current = info.pointee.ai_next
                        }
                        
                        continuation.resume(returning: ips.isEmpty ? nil : ips)
                    }
                }
            }
            
            // Timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            
            // Return first result (either success or timeout)
            if let result = await group.next(), let ips = result {
                group.cancelAll()
                return ips
            }
            
            group.cancelAll()
            return nil
        }
    }
    
    private nonisolated static func resolveWithDNSParallel(_ domain: String, dns: String) async -> [String]? {
        // Reject domains that could be interpreted as flags
        guard !domain.isEmpty, !domain.hasPrefix("-") else { return nil }

        // Check protocol type
        if dns.hasPrefix("https://") {
            // DoH (DNS over HTTPS)
            return await resolveWithDoHParallel(domain, dohURL: dns)
        } else if dns.hasPrefix("tls://") {
            // DoT (DNS over TLS) - requires kdig from knot-dns
            let server = String(dns.dropFirst(6)) // Remove "tls://"
            return await resolveWithDoTParallel(domain, server: server)
        } else if dns.contains(":853") {
            // DoT with explicit port
            let server = dns.replacingOccurrences(of: ":853", with: "")
            return await resolveWithDoTParallel(domain, server: server)
        }
        
        // Regular DNS via dig - uses async dispatch to GCD for true parallelism
        // Shorter timeout for local DNS (should respond in <100ms), longer for external
        let isLocalDNS = dns.hasPrefix("192.168.") || dns.hasPrefix("10.") || dns.hasPrefix("172.16.") || dns.hasPrefix("172.17.") || dns.hasPrefix("172.18.") || dns.hasPrefix("172.19.") || dns.hasPrefix("172.2") || dns.hasPrefix("172.30.") || dns.hasPrefix("172.31.")
        let timeout: TimeInterval = isLocalDNS ? 1.0 : 1.5
        let args = ["@\(dns)", "+short", "+time=1", "+tries=1", domain]
        guard let result = await runProcessParallel("/usr/bin/dig", arguments: args, timeout: timeout) else {
            return nil
        }
        
        let ips = result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && isValidIPStatic($0) }
        
        return ips.isEmpty ? nil : ips
    }
    
    private nonisolated static func resolveWithDoTParallel(_ domain: String, server: String) async -> [String]? {
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
            return nil
        }
        
        let args = ["+tls", "+short", "@\(server)", domain]
        guard let result = await runProcessParallel(kdig, arguments: args, timeout: 3.0),
              result.exitCode == 0 else {
            return nil
        }
        
        let ips = result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && isValidIPStatic($0) }
        
        return ips.isEmpty ? nil : ips
    }
    
    private nonisolated static func resolveWithDoHParallel(_ domain: String, dohURL: String) async -> [String]? {
        // DNS-over-HTTPS using JSON API (works with Cloudflare, Google, etc.)
        let url = "\(dohURL)?name=\(domain)&type=A"
        let args = ["-s", "-H", "accept: application/dns-json", url]
        
        guard let result = await runProcessParallel("/usr/bin/curl", arguments: args, timeout: 3.0),
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
                  isValidIPStatic(ip) else {
                return nil
            }
            return ip
        }
        
        return ips.isEmpty ? nil : ips
    }
    
    /// Static version of isValidIP for use in nonisolated methods
    private nonisolated static func isValidIPStatic(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            guard let num = Int($0), num >= 0, num <= 255 else { return false }
            return String(num) == $0
        }
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
    
    private func updateHostsFile() async {
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
            if let ip = firstRoutedIP(for: domain.domain, in: routedDestinations) {
                entries.append((domain.domain, ip))
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
        await modifyHostsFile(entries: entries)
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
    func cleanupOnQuit() async {
        log(.info, "Cleaning up on quit...")
        // Always remove active routes (especially critical for VPN Only catch-alls)
        if !activeRoutes.isEmpty {
            await removeAllRoutes()
        }
        if config.manageHostsFile {
            await cleanHostsFile()
        }
    }
    
    private func modifyHostsFile(entries: [(domain: String, ip: String)]) async {
        guard HelperManager.shared.isHelperInstalled else {
            log(.error, "Cannot modify hosts file: helper not ready (\(HelperManager.shared.helperState.statusText))")
            return
        }
        let result = await HelperManager.shared.updateHostsFile(entries: entries)
        if !result.success {
            log(.error, "Helper hosts update failed: \(result.error ?? "unknown")")
        }
    }
    
    /// Public domain normalization for custom service editor
    func cleanDomainForService(_ input: String) -> String {
        return cleanDomain(input)
    }

    private func cleanDomain(_ input: String) -> String {
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
    
    private func isValidIP(_ string: String) -> Bool {
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
    private func isValidCIDR(_ string: String) -> Bool {
        let parts = string.components(separatedBy: "/")
        guard parts.count == 2,
              isValidIP(parts[0]),
              let mask = Int(parts[1]),
              mask >= 1 && mask <= 32 else {
            return false
        }
        return true
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
