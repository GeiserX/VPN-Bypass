// ConfigModel.swift
// The VPN Bypass configuration data model, extracted from RouteManager so the pure CLI/command
// layer and the rule/route builders no longer reach into the @MainActor god class's namespace.
// Pure Codable value types — no RouteManager, no side effects. Behaviour-preserving: identical
// Codable shape (JSON keys + defaults unchanged), so existing configs load exactly as before.

import Foundation

enum RoutingMode: String, Codable {
    case bypass = "bypass"      // Domains bypass VPN (current behavior)
    case vpnOnly = "vpnOnly"    // Only listed domains use VPN, everything else bypasses
    case custom = "custom"      // Per-rule multi-route dispatch (schemaVersion >= 2 only); see RouteCompiler

    var displayName: String {
        switch self {
        case .bypass:  return "Bypass"
        case .vpnOnly: return "VPN Only"
        case .custom:  return "Custom Routes"
        }
    }
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

    // Multi-route model (P0 / VPN-Bypass-3sc.7). Additive + dormant: while
    // schemaVersion == 1 the bypass/vpnOnly engine above stays authoritative;
    // P1 flips schemaVersion to 2 and dispatches per rule. See RouteModel.swift.
    var routes: [Route] = []
    var rules: [Rule] = []
    var defaultRouteId: UUID? = nil
    var schemaVersion: Int = 1
    var multiRouteEnabled: Bool = false  // Opt-in experimental: show Routes tab and start proxy listeners

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

        routes = try container.decodeIfPresent([Route].self, forKey: .routes) ?? []
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        defaultRouteId = try container.decodeIfPresent(UUID.self, forKey: .defaultRouteId)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        multiRouteEnabled = try container.decodeIfPresent(Bool.self, forKey: .multiRouteEnabled) ?? false

        // One-time migration: derive the routes/rules representation from the
        // legacy bypass list + single proxy so the new model is populated for
        // the UI and P1. schemaVersion stays 1, so routing behaviour is
        // unchanged until P1 switches the engine explicitly.
        if routes.isEmpty {
            let derived = Config.derive(
                domains: domains, services: services,
                mode: routingMode, inverseDomains: inverseDomains, proxy: proxyConfig
            )
            routes = derived.routes
            rules = derived.rules
            defaultRouteId = derived.defaultRouteId
        }
    }

    // Default initializer
    init() {}

    /// Derive the multi-route representation from the legacy model on first
    /// decode, so routes/rules are populated without changing behaviour
    /// (schemaVersion stays 1). Mapping:
    ///  - bypass  → default = Corporate VPN; each enabled domain/service → a rule to Direct
    ///  - vpnOnly → default = Direct; each enabled inverse domain → a rule to Corporate VPN
    ///  - an enabled legacy proxy → one SOCKS5 proxy route, with its services routed to it
    static func derive(
        domains: [DomainEntry],
        services: [ServiceEntry],
        mode: RoutingMode,
        inverseDomains: [DomainEntry],
        proxy: ProxyConfig
    ) -> (routes: [Route], rules: [Rule], defaultRouteId: UUID?) {
        let vpnRoute = Route(name: "Corporate VPN", egress: .vpnDefault)
        let directRoute = Route(name: "Direct", egress: .direct)
        var routes: [Route] = [vpnRoute, directRoute]
        var rules: [Rule] = []
        var order = 0

        var proxyRoute: Route?
        if proxy.enabled && proxy.isConfigured {
            let r = Route(
                name: "Proxy",
                egress: .proxySOCKS5,
                proxyHost: proxy.server,
                proxyPort: proxy.port,
                proxyUser: proxy.username,
                proxyPass: proxy.password
            )
            proxyRoute = r
            routes.append(r)
        }

        let defaultRouteId: UUID
        switch mode {
        // .custom migrates like .bypass: default = VPN, listed entries → Direct.
        // In practice derive() runs while mode is still bypass/vpnOnly (the visible
        // switch-into-Custom migration); this case only fires for the odd config that
        // is already .custom with no explicit routes, where a VPN-default map is the
        // safe (non-leaking) fallback until the user authors rules.
        case .bypass, .custom:
            defaultRouteId = vpnRoute.id
            for d in domains where d.enabled {
                rules.append(Rule(matchType: d.isCIDR ? .cidr : .domain, pattern: d.domain, routeId: directRoute.id, order: order))
                order += 1
            }
            for s in services where s.enabled {
                let target = proxyRouteId(forService: s.id, proxy: proxy, proxyRoute: proxyRoute) ?? directRoute.id
                rules.append(Rule(matchType: .service, pattern: s.id, routeId: target, order: order))
                order += 1
            }
        case .vpnOnly:
            defaultRouteId = directRoute.id
            for d in inverseDomains where d.enabled {
                rules.append(Rule(matchType: d.isCIDR ? .cidr : .domain, pattern: d.domain, routeId: vpnRoute.id, order: order))
                order += 1
            }
        }

        return (routes, rules, defaultRouteId)
    }

    /// Prepare THIS config for Custom mode, purely (no actor, no I/O) so the GUI
    /// (`setRoutingMode`) and the CLI (`CommandRouter`) migrate identically.
    ///
    /// Guarantees the rule model exists so a classic bypass/vpnOnly user's listed
    /// domains keep routing after the switch. Two cases:
    ///   • No route model yet (fresh schemaVersion-1 config) → adopt derive()'s
    ///     routes/rules/default wholesale, preserving any user proxy/Tailscale routes.
    ///   • Routes exist but rules are EMPTY while there ARE domains/services to route
    ///     (a schemaVersion-2 bypass config the decoder bumped but never ruled — which
    ///     would otherwise enter Custom with zero rules and silently drop every listed
    ///     domain onto the OS default). Derive rules and REMAP their routeId onto the
    ///     routes the config already has (by egress), so existing route ids/names
    ///     (e.g. a renamed VPN) are preserved and no rule dangles.
    /// Idempotent: a config that already has rules (or nothing to route) is unchanged.
    /// Does NOT set routingMode — the caller flips that after (derive reads the
    /// pre-switch mode to pick bypass-vs-vpnOnly rule semantics).
    func preparedForCustomMode() -> Config {
        var c = self
        if c.schemaVersion < 2 { c.schemaVersion = 2 }

        // Already has a rule model → leave it entirely untouched (idempotent re-entry;
        // never clobber a user's edited rules). Only derive when rules are EMPTY.
        guard c.rules.isEmpty else { return c }
        // Nothing to route → start Custom empty (a valid choice; don't fabricate a model).
        let hasRoutableLists = !c.domains.isEmpty
            || c.services.contains { $0.enabled }
            || c.inverseDomains.contains { $0.enabled }
        guard hasRoutableLists else { return c }

        let hasSystemRoutes = c.routes.contains { $0.egress == .vpnDefault }
            && c.routes.contains { $0.egress == .direct }

        let derived = Config.derive(
            domains: c.domains, services: c.services,
            mode: c.routingMode, inverseDomains: c.inverseDomains, proxy: c.proxyConfig
        )

        if !hasSystemRoutes {
            // Fresh config — adopt the derived model, keeping user proxy/Tailscale routes.
            let userRoutes = c.routes.filter {
                $0.egress == .proxyHTTP || $0.egress == .proxySOCKS5 || $0.egress == .tailscaleExit
            }
            c.routes = derived.routes + userRoutes
            c.rules = derived.rules
            c.defaultRouteId = derived.defaultRouteId
            return c
        }

        // Routes exist, rules are empty: remap derived rules onto existing route ids.
        var idMap: [UUID: UUID] = [:]
        for dr in derived.routes {
            if let existing = c.routes.first(where: { $0.egress == dr.egress }) {
                idMap[dr.id] = existing.id
            } else {
                c.routes.append(dr)     // no existing counterpart (e.g. a proxy route) — keep it
                idMap[dr.id] = dr.id
            }
        }
        c.rules = derived.rules.map { rule in
            var r = rule
            if let mapped = idMap[rule.routeId] { r.routeId = mapped }
            return r
        }
        // Adopt the derived default (VPN for bypass, Direct for vpnOnly), remapped onto
        // an existing route — the classic-mode default the user actually had.
        c.defaultRouteId = derived.defaultRouteId.flatMap { idMap[$0] } ?? c.defaultRouteId
        return c
    }

    /// The proxy route a service maps to under the legacy single-proxy model,
    /// or nil if the service is not proxied (caller routes it Direct).
    /// useForServices empty means "all enabled services" (legacy semantics).
    private static func proxyRouteId(forService serviceId: String, proxy: ProxyConfig, proxyRoute: Route?) -> UUID? {
        guard let proxyRoute, proxy.enabled, proxy.isConfigured else { return nil }
        return (proxy.useForServices.isEmpty || proxy.useForServices.contains(serviceId)) ? proxyRoute.id : nil
    }

    /// A copy with all credentials cleared, for the shareable Export file.
    /// Exports are routinely attached to bug reports, so proxy username/
    /// password and any per-route proxy creds must never travel in them. The
    /// in-app config keeps the live values; Import re-prompts for secrets.
    func sanitizedForExport() -> Config {
        var copy = self
        copy.proxyConfig.username = ""
        copy.proxyConfig.password = ""
        copy.routes = copy.routes.map { route in
            var r = route
            r.proxyUser = nil
            r.proxyPass = nil
            return r
        }
        return copy
    }

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
    var isWildcard: Bool

    init(domain: String, enabled: Bool = true, isCIDR: Bool = false, isWildcard: Bool = false) {
        self.id = UUID()
        self.domain = domain
        self.enabled = enabled
        self.isCIDR = isCIDR
        self.isWildcard = isWildcard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        domain = try container.decode(String.self, forKey: .domain)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        resolvedIP = try container.decodeIfPresent(String.self, forKey: .resolvedIP)
        lastResolved = try container.decodeIfPresent(Date.self, forKey: .lastResolved)
        isCIDR = try container.decodeIfPresent(Bool.self, forKey: .isCIDR) ?? false
        isWildcard = try container.decodeIfPresent(Bool.self, forKey: .isWildcard) ?? false
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
