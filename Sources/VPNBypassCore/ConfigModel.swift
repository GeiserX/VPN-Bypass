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
    case protonVPN = "Proton VPN"
    case unknown = "Unknown VPN"

    /// The product name to show, or nil for `.unknown`: its raw value is an English
    /// placeholder, so a caller shows its own localized "VPN" instead.
    var knownName: String? { self == .unknown ? nil : rawValue }

    /// A tunnel label to show. A label is `.unknown`'s raw value when the app could not name
    /// the VPN; that English placeholder shows as the localized "VPN". The stored label (and a
    /// route's productHint) keeps the raw value, which other code compares against.
    static func displayLabel(_ label: String, in bundle: Bundle = .main) -> String {
        label == VPNType.unknown.rawValue ? String(localized: "VPN", bundle: bundle) : label
    }
    
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
        case .protonVPN: return "lock.shield.fill"
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
    /// What the path check saw for it: the interface, the source address and the answer.
    var path: PathCheck.Probe? = nil
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
    var verifyRoutesAfterApply: Bool = false  // Off by default: a check opens a connection to each sampled address
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
    /// Shared secret a local client must present to a route's 127.0.0.1 listener before the
    /// forwarder will spend this machine's upstream proxy credentials (GHSA-gm4h-95p9-9w7v).
    /// It lives here because the config file is 0600 — the owner can read it, another local
    /// account cannot, and a TCP listener has no peer uid to check instead. Optional so a
    /// config written before 4.6.3 still decodes; RouteManager mints one on first use.
    var localProxySecret: String? = nil
    /// Tunnels seen previously, so a VPN that is not connected right now can still be chosen
    /// for a route or a pin. Live enumeration only reports tunnels that are UP.
    var rememberedVPNLinks: [RouteManager.RememberedLink] = []
    /// Optional pin: act ONLY on this tunnel when it is up and eligible ("utun9"). Constrains
    /// automatic selection; a stale pin degrades to automatic with a logged warning.
    var pinnedVPNInterface: String? = nil
    /// Durable half of the pin — utun indices renumber across reconnects, so the product label
    /// ("GlobalProtect") re-resolves the pin when the named interface vanishes.
    var pinnedVPNProductHint: String? = nil
    /// The DNS Lookups page's switch (#176). Off until the user turns it on.
    var dnsLookupsEnabled: Bool = false
    /// Domains the user added to a built-in service, by service id. Kept apart from
    /// `services` because `mergeBuiltInServices` resets a built-in service's domains to the
    /// shipped list at every launch; it adds these back after the shipped ones.
    var builtInServiceExtras: [String: [String]] = [:]

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
        // Must be decoded explicitly: this initialiser is hand-written, so a property left
        // out here is encoded to disk and then silently read back as nil. For this one that
        // would mint a fresh secret on every launch and 407 every previously copied export.
        localProxySecret = try container.decodeIfPresent(String.self, forKey: .localProxySecret)
        rememberedVPNLinks = try container.decodeIfPresent([RouteManager.RememberedLink].self, forKey: .rememberedVPNLinks) ?? []
        pinnedVPNInterface = try container.decodeIfPresent(String.self, forKey: .pinnedVPNInterface)
        pinnedVPNProductHint = try container.decodeIfPresent(String.self, forKey: .pinnedVPNProductHint)
        dnsLookupsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dnsLookupsEnabled) ?? false
        builtInServiceExtras = try container.decodeIfPresent([String: [String]].self, forKey: .builtInServiceExtras) ?? [:]

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
                rules.append(rule(for: d, routeId: directRoute.id, order: order))
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
                rules.append(rule(for: d, routeId: vpnRoute.id, order: order))
                order += 1
            }
        }

        return (routes, rules, defaultRouteId)
    }

    /// The Custom-mode rule a list entry becomes: a range a `cidr` rule, a wildcard a `suffix`
    /// rule on its suffix (the form `RuleResolver` matches), anything else a `domain` rule.
    private static func rule(for entry: DomainEntry, routeId: UUID, order: Int) -> Rule {
        if entry.isCIDR {
            return Rule(matchType: .cidr, pattern: entry.domain, routeId: routeId, order: order)
        }
        if entry.isWildcard, let suffix = WildcardDomain.suffix(of: entry.domain) {
            return Rule(matchType: .suffix, pattern: suffix, routeId: routeId, order: order)
        }
        return Rule(matchType: .domain, pattern: entry.domain, routeId: routeId, order: order)
    }

    /// Whether `preparedForCustomMode()` builds rules from the lists: there are no rules yet,
    /// and `derive` makes at least one from the current mode's list (only its entries that are
    /// switched on). The dropdown's question and the Settings sheet word the switch to Custom by
    /// it (through `RoutingModeCopy.lists(from:)`), so what they say matches what the switch does.
    var customModeBuildsRulesFromLists: Bool {
        rules.isEmpty && !Config.derive(domains: domains, services: services, mode: routingMode,
                                        inverseDomains: inverseDomains, proxy: proxyConfig).rules.isEmpty
    }

    /// The test `preparedForCustomMode()` runs before it derives anything: no rules yet, and
    /// some list holds something. Broader than `customModeBuildsRulesFromLists` on purpose, so
    /// a fresh config still adopts the derived routes even when the current list makes no rule.
    private var hasRoutableListsAndNoRules: Bool {
        rules.isEmpty && (!domains.isEmpty
            || services.contains { $0.enabled }
            || inverseDomains.contains { $0.enabled })
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
        // never clobber a user's edited rules). Nothing to route → start Custom empty
        // (a valid choice; don't fabricate a model). Only derive otherwise.
        guard c.hasRoutableListsAndNoRules else { return c }

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
        copy.localProxySecret = nil        // a valid local proxy password — never share it
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
    
    /// The built-in services: the service catalogue (`Resources/catalogue/*.json`), every
    /// one off, in catalogue order. Read once at launch (`ServiceCatalogue.shipped`).
    static var defaultServices: [ServiceEntry] {
        ServiceCatalogue.shipped.map(\.service)
    }

    /// A fresh 256-bit local-hop secret as lowercase hex. Hex, not base64: the secret is
    /// interpolated into a proxy URL's userinfo (`http://vpnb:<secret>@127.0.0.1:port`) and
    /// base64's `/` is not legal there, so it would need escaping at every call site.
    static func makeLocalProxySecret() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
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
        // A "*.suffix" entry is a wildcard however it was made, so no caller can forget the flag.
        self.isWildcard = isWildcard || WildcardDomain.isWildcard(domain)
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
            || WildcardDomain.isWildcard(domain)
    }
}

struct ServiceEntry: Codable, Identifiable {
    let id: String
    var name: String
    var enabled: Bool
    var domains: [String]
    var ipRanges: [String]
    var isCustom: Bool = false

    /// The domains a lookup can resolve: every one but the wildcards, which the helper's
    /// forwarder routes as their names are looked up (see WildcardEngine).
    var resolvableDomains: [String] { domains.filter { !WildcardDomain.isWildcard($0) } }

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
