// WildcardRoutes.swift
// The app's side of always-on wildcard domains, the pure parts: which wildcards the current
// mode serves and through what, the ledger of learned routes, and the two system outputs the
// engine reads (`scutil --dns`, `netstat`). WildcardEngine.swift drives them.
//
// The ledger holds addresses, wildcards and times. It never holds a looked-up name: the helper
// does not report one.

import Foundation

// MARK: - Which wildcards, through what

enum WildcardPlanner {

    /// What the plan needs from the live system. Built by the engine; tests build their own.
    struct Environment {
        var localGateway: String?
        var physicalInterface: String?
        /// The DNS servers of the physical network, the ones Bypass and Direct names go to.
        var physicalDNS: [String]
        var vpnGateway: String?
        var vpnInterface: String?
        /// The tunnel's own DNS servers, for VPN Only names.
        var vpnDNS: [String]
        /// `iface:utunN` for a Custom route pinned to a live tunnel, nil otherwise.
        var pinnedGateway: (Route) -> String? = { _ in nil }
        /// The DNS servers macOS has for an interface.
        var dnsForInterface: (String) -> [String] = { _ in [] }
    }

    /// The wildcards the current mode routes, as suffixes, first one first, each once. Whether
    /// they can be served right now (a VPN up, a DNS server known) is `plan`'s question; this
    /// is the set whose learned routes are kept.
    static func configuredSuffixes(_ config: Config) -> [String] {
        configured(config).map(\.suffix)
    }

    /// One configured wildcard and the route it takes.
    struct Configured: Equatable {
        enum Via: Equatable {
            /// Around the VPN: the Bypass list, its services, a Custom Direct route.
            case physical
            /// Into the primary VPN: the VPN Only list.
            case vpn
            /// Into a Custom route pinned to one tunnel.
            case pinned(Route)
        }
        let suffix: String
        let via: Via
    }

    static func configured(_ config: Config) -> [Configured] {
        var out: [Configured] = []
        var seen: Set<String> = []
        func add(_ entry: String, _ via: Configured.Via) {
            guard let suffix = WildcardDomain.suffix(of: entry), seen.insert(suffix).inserted else { return }
            out.append(Configured(suffix: suffix, via: via))
        }

        if RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            // First match wins, as RuleResolver decides. Only routes a kernel route can carry
            // take part: Direct, and a VPN route pinned to one tunnel. The primary VPN needs no
            // route (the default already goes there), and a proxy or Tailscale Peer route is a
            // listener that a routing table cannot point at.
            let routes = Dictionary(config.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let services = Dictionary(config.services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for rule in config.rules.filter(\.enabled).sorted(by: { $0.order < $1.order }) {
                guard let route = routes[rule.routeId], route.enabled else { continue }
                let via: Configured.Via
                switch route.egress {
                case .direct: via = .physical
                case .vpnDefault where route.vpnSelector?.kind == .interface: via = .pinned(route)
                default: continue
                }
                switch rule.matchType {
                case .suffix:
                    let pattern = WildcardDomain.isWildcard(rule.pattern) ? rule.pattern : WildcardDomain.entry(for: rule.pattern)
                    add(pattern, via)
                case .service:
                    for domain in services[rule.pattern]?.domains ?? [] where WildcardDomain.isWildcard(domain) {
                        add(domain, via)
                    }
                case .domain:
                    if WildcardDomain.isWildcard(rule.pattern) { add(rule.pattern, via) }
                case .ip, .cidr, .process:
                    break
                }
            }
            return out
        }

        switch config.routingMode {
        case .vpnOnly:
            for entry in config.inverseDomains where entry.enabled && entry.isWildcard { add(entry.domain, .vpn) }
        case .bypass, .custom:
            for entry in config.domains where entry.enabled && entry.isWildcard { add(entry.domain, .physical) }
            for service in config.services where service.enabled {
                for domain in service.domains where WildcardDomain.isWildcard(domain) { add(domain, .physical) }
            }
        }
        return out
    }

    /// What the helper should serve now, and why each configured wildcard it leaves out cannot
    /// be served yet (English, for the log; the suffix is the user's own entry).
    static func plan(_ config: Config, env: Environment) -> (specs: [WildcardSpec], skipped: [String: String]) {
        var specs: [WildcardSpec] = []
        var skipped: [String: String] = [:]
        for item in configured(config) {
            let gateway: String?, interface: String?, upstream: [String]
            switch item.via {
            case .physical:
                (gateway, interface, upstream) = (env.localGateway, env.physicalInterface, env.physicalDNS)
            case .vpn:
                (gateway, interface, upstream) = (env.vpnGateway, env.vpnInterface, env.vpnDNS)
            case .pinned(let route):
                let g = env.pinnedGateway(route)
                let iface = g.map { String($0.dropFirst("iface:".count)) }
                (gateway, interface, upstream) = (g, iface, iface.map(env.dnsForInterface) ?? [])
            }
            guard let gateway, let interface else {
                skipped[item.suffix] = "its route is not up"
                continue
            }
            let servers = Array(upstream.filter { WildcardIPv4.parse($0) != nil && !$0.hasPrefix("127.") }.prefix(4))
            guard !servers.isEmpty else {
                skipped[item.suffix] = "no DNS server is known for \(interface)"
                continue
            }
            let spec = WildcardSpec(suffix: item.suffix, gateway: gateway, upstream: servers, interface: interface)
            // Same check the helper makes, so a spec it would refuse is never sent.
            guard WildcardSpec(dictionary: spec.dictionary) != nil else {
                skipped[item.suffix] = "its gateway or interface is not one the helper accepts"
                continue
            }
            specs.append(spec)
        }
        return (specs, skipped)
    }

    /// The addresses no wildcard may learn, on top of the helper's fixed list: our gateways,
    /// every DNS server a wildcard asks, and the VPN Only ranges.
    static func safetyGuard(_ config: Config, env: Environment, specs: [WildcardSpec]) -> WildcardSafetyGuard {
        var hosts = Set(specs.flatMap(\.upstream))
        for gateway in [env.localGateway, env.vpnGateway] + specs.map(\.gateway) {
            if let gateway, WildcardIPv4.parse(gateway) != nil { hosts.insert(gateway) }
        }
        let ranges = config.inverseDomains.filter { $0.enabled && $0.isCIDR }.map(\.domain)
        return WildcardSafetyGuard(excludedHosts: hosts.sorted(), excludedRanges: ranges)
    }
}

// MARK: - Ledger

/// The routes wildcards learned, kept on disk so they survive a restart of the app: the startup
/// sweep must not take them for a crashed run's leftovers, and each one still expires a day
/// after it was last handed out.
struct WildcardLedger: Codable, Equatable {
    static let maxAge: TimeInterval = 24 * 3600

    var version = 1
    /// Suffix, then address, then the last time the forwarder handed the address out.
    var seen: [String: [String: Date]] = [:]

    mutating func record(_ ip: String, suffix: String, at date: Date) {
        seen[suffix, default: [:]][ip] = date
    }

    mutating func remove(_ ip: String, suffix: String) {
        seen[suffix]?[ip] = nil
        if seen[suffix]?.isEmpty == true { seen[suffix] = nil }
    }

    /// Forgets every wildcard not in `suffixes`. Returns whether anything went.
    @discardableResult
    mutating func keep(only suffixes: Set<String>) -> Bool {
        let before = seen.count
        seen = seen.filter { suffixes.contains($0.key) }
        return seen.count != before
    }

    /// Addresses not handed out for `maxAge`, leaving out those with an open TCP connection:
    /// a long download or a websocket keeps its route however old the lookup is.
    func expired(at now: Date, maxAge: TimeInterval = Self.maxAge, openPeers: Set<String>) -> [(ip: String, suffix: String)] {
        seen.flatMap { suffix, ips in
            ips.filter { now.timeIntervalSince($0.value) > maxAge && !openPeers.contains($0.key) }
                .map { (ip: $0.key, suffix: suffix) }
        }.sorted { ($0.suffix, $0.ip) < ($1.suffix, $1.ip) }
    }

    func addresses(for suffixes: Set<String>) -> Set<String> {
        Set(seen.filter { suffixes.contains($0.key) }.flatMap(\.value.keys))
    }

    static func load(from url: URL) -> WildcardLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder.wildcardLedger.decode(WildcardLedger.self, from: data) else {
            return WildcardLedger()
        }
        return ledger
    }

    /// Written atomically and owner-only, like the config.
    func save(to url: URL) throws {
        let data = try JSONEncoder.wildcardLedger.encode(self)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension JSONEncoder {
    static var wildcardLedger: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

private extension JSONDecoder {
    static var wildcardLedger: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - scutil --dns

/// The resolvers in `scutil --dns`, both sections.
enum ScutilDNS {
    struct Resolver: Equatable {
        var domain: String?
        var nameservers: [String] = []
        var interface: String?
        var port: Int?
        /// From the "for scoped queries" section.
        var scoped = false

        /// One of the helper's own resolver files.
        var isWildcardForwarder: Bool {
            nameservers == ["127.0.0.1"] && port == Int(WildcardResolverFile.port)
        }
    }

    static func parse(_ output: String) -> [Resolver] {
        var resolvers: [Resolver] = []
        var current: Resolver?
        var scoped = false
        func finish() {
            if let current { resolvers.append(current) }
            current = nil
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration") {
                finish()
                scoped = line.contains("scoped")
                continue
            }
            if line.hasPrefix("resolver #") {
                finish()
                current = Resolver(scoped: scoped)
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "domain" {
                current?.domain = value.lowercased()
            } else if key.hasPrefix("nameserver[") {
                current?.nameservers.append(value)
            } else if key == "if_index", let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
                current?.interface = String(value[value.index(after: open)..<close])
            } else if key == "port" {
                current?.port = Int(value)
            }
        }
        finish()
        return resolvers
    }

    /// The IPv4 DNS servers macOS has for `interface`, in order, each once.
    static func nameservers(forInterface interface: String, in resolvers: [Resolver]) -> [String] {
        var out: [String] = []
        for r in resolvers where r.interface == interface && !r.isWildcardForwarder {
            for ns in r.nameservers where WildcardIPv4.parse(ns) != nil && !out.contains(ns) { out.append(ns) }
        }
        return out
    }

    /// Resolvers for a name below `suffix` that are not ours: they have more matching labels,
    /// so macOS sends those names to them and the wildcard never sees them. Sorted, each once.
    static func shadowing(_ suffix: String, in resolvers: [Resolver]) -> [String] {
        let domains = resolvers.compactMap { r -> String? in
            guard !r.scoped, !r.isWildcardForwarder, let d = r.domain, d != suffix,
                  WildcardDomain.matches(d, suffix: suffix) else { return nil }
            return d
        }
        return Array(Set(domains)).sorted()
    }
}

// MARK: - Open TCP connections

enum OpenTCPPeers {
    /// The IPv4 addresses with an established TCP connection, from `netstat -an -p tcp`. The
    /// foreign address column ends in ".port".
    static func parse(_ output: String) -> Set<String> {
        var peers: Set<String> = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6, fields[0].hasPrefix("tcp4"), fields[5] == "ESTABLISHED",
                  let dot = fields[4].lastIndex(of: ".") else { continue }
            let ip = String(fields[4][..<dot])
            if WildcardIPv4.parse(ip) != nil { peers.insert(ip) }
        }
        return peers
    }
}
