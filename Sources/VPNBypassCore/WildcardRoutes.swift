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
        /// `scutil --dns`, for the other resolvers that serve names under a wildcard.
        var resolvers: [ScutilDNS.Resolver] = []
        /// The running helper answers a Block wildcard (2.10.0 or later). An older one would read
        /// it as a wildcard without a gateway and refuse it, so the plan holds it back and says why.
        var blockSupported = true
    }

    /// The wildcards the current mode routes, as suffixes, first one first, each once. Whether
    /// they can be served right now (a VPN up, a DNS server known) is `plan`'s question; this
    /// is the set whose learned routes are kept.
    static func configuredSuffixes(_ config: Config, includingBlocked: Bool = false) -> [String] {
        // The wildcards that learn routes. A Block wildcard learns none, so it is not in the set whose
        // learned routes are kept: a suffix moved to Block loses the routes it learned before.
        configured(config).filter { includingBlocked || $0.via != .block }.map(\.suffix)
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
            /// To the Block route: the forwarder answers the names NXDOMAIN, no route is learned.
            case block
        }
        let suffix: String
        let via: Via
        /// Names under it an earlier rule claims (`WildcardSpec.excluded`).
        var excluded: [String] = []
    }

    static func configured(_ config: Config, geosite: [String: GeoSiteExpansion]? = nil) -> [Configured] {
        var out: [Configured] = []
        var seen: Set<String> = []
        func add(_ entry: String, _ via: Configured.Via, excluded: [String] = []) {
            guard let suffix = WildcardDomain.suffix(of: entry), seen.insert(suffix).inserted else { return }
            out.append(Configured(suffix: suffix, via: via, excluded: excluded))
        }

        if RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            // First match wins, as RuleResolver decides. Only routes a kernel route can carry
            // take part: Direct, and a VPN route pinned to one tunnel. The primary VPN needs no
            // route (the default already goes there), and a proxy or Tailscale Peer route is a
            // listener that a routing table cannot point at.
            let routes = Dictionary(config.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let services = Dictionary(config.services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Every suffix an earlier rule claims, whatever its route (a proxy too): a name
            // under it goes that way, so a later wildcard below it must not catch the name
            // first through a more specific resolver file.
            // Kept as sets and by parent domain, so a list of thousands of suffixes plans in one
            // pass instead of comparing each suffix with every earlier one.
            var claimedSuffixes: Set<String> = []
            var claimedEntries: Set<String> = []
            // Every exact name an earlier rule claims. A later wildcard over it still gets its
            // resolver file, so the name is excluded there: answered, never routed.
            var claimedNameSet: Set<String> = []
            // The claimed names, and the claimed wildcards (as `*.suffix`), under each parent
            // domain, in the order they were claimed: what a wildcard at that domain must exclude.
            var namesUnder: [String: [String]] = [:]
            var wildcardsUnder: [String: [String]] = [:]
            func domains(of name: String) -> [String] { WildcardDomain.ancestors(of: name) }
            // The domain lists the Site rules name, read once per pass.
            let lists = geosite ?? GeoDataFile.geosite.expansions(
                for: Set(config.rules.filter { $0.enabled && $0.matchType == .geosite }.map { $0.pattern.lowercased() }))
            for rule in config.rules.filter(\.enabled).sorted(by: { $0.order < $1.order }) {
                // A route that is off, gone, or of a type this build does not know is inert: the rule
                // claims nothing, so a later rule decides, as RouteCompiler does.
                guard let route = routes[rule.routeId], route.enabled, route.egress != .unsupported else { continue }
                let (entries, names) = claims(of: rule, services: services, lists: lists)
                let suffixes = entries.compactMap(WildcardDomain.suffix(of:))
                defer {
                    for suffix in suffixes {
                        claimedSuffixes.insert(suffix)
                        guard claimedEntries.insert(suffix).inserted else { continue }
                        let entry = WildcardDomain.entry(for: suffix)
                        for above in domains(of: suffix) { wildcardsUnder[above, default: []].append(entry) }
                    }
                    for name in names.compactMap(WildcardDomain.normalizedSuffix) where claimedNameSet.insert(name).inserted {
                        for above in domains(of: name) { namesUnder[above, default: []].append(name) }
                    }
                }
                let via: Configured.Via
                switch route.egress {
                case .direct: via = .physical
                case .vpnDefault where route.vpnSelector?.kind == .interface: via = .pinned(route)
                case .block: via = .block
                default: continue
                }
                // A blackhole covers an exact name as well, and what is under it: a list of
                // trackers names `ads.example.com`, and its subdomains are the same tracker.
                let blocked = via == .block ? suffixes + names.compactMap(WildcardDomain.normalizedSuffix) : suffixes
                // A blackhole that asks for more wildcards than a list may is left out whole.
                if via == .block, blocked.count > GeoSiteExpansion.maxSuffixes { continue }
                for suffix in blocked where !domains(of: suffix).contains(where: claimedSuffixes.contains) {
                    // Claimed names, then claimed wildcards, at or under this suffix.
                    let excluded = (namesUnder[suffix] ?? []) + (wildcardsUnder[suffix] ?? [])
                    // More than the helper takes: left out, as a wildcard under an earlier
                    // suffix is, rather than route a name first match sends elsewhere.
                    guard excluded.count <= WildcardSpec.maxExcluded else { continue }
                    add(WildcardDomain.entry(for: suffix), via, excluded: excluded)
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

    /// The wildcard entries (`*.suffix`) and exact names a rule names, as a wildcard sees them: a list
    /// too large to route, or missing, names none.
    static func claims(of rule: Rule, services: [String: ServiceEntry], lists: [String: GeoSiteExpansion])
        -> (entries: [String], names: [String]) {
        switch rule.matchType {
        case .suffix:
            return ([WildcardDomain.isWildcard(rule.pattern) ? rule.pattern : WildcardDomain.entry(for: rule.pattern)], [])
        case .service:
            let domains = services[rule.pattern]?.domains ?? []
            return (domains.filter(WildcardDomain.isWildcard), domains.filter { !WildcardDomain.isWildcard($0) })
        case .domain:
            return WildcardDomain.isWildcard(rule.pattern) ? ([rule.pattern], []) : ([], [rule.pattern])
        case .geosite:
            let list = lists[rule.pattern.lowercased()]?.usable ?? GeoSiteExpansion(found: false)
            return (list.suffixes.map(WildcardDomain.entry(for:)), list.names)
        case .ip, .cidr, .geoip, .process, .unsupported:
            return ([], [])
        }
    }

    /// The suffixes Tailscale MagicDNS owns. A wildcard at or under one is not served while
    /// Tailscale is running.
    static let tailscaleSuffixes = ["ts.net"]

    /// Whether macOS has a resolver that asks MagicDNS, which is how a running Tailscale shows.
    static func tailscaleIsAnswering(_ resolvers: [ScutilDNS.Resolver]) -> Bool {
        resolvers.contains { $0.nameservers.contains(ProtectedDestinations.magicDNS) }
    }

    /// What the helper should serve now, and why each configured wildcard it leaves out cannot
    /// be served yet (English, for the log; the suffix is the user's own entry).
    static func plan(_ config: Config, env: Environment) -> (specs: [WildcardSpec], skipped: [String: String]) {
        var specs: [WildcardSpec] = []
        var skipped: [String: String] = [:]
        for item in configured(config) {
            // With Tailscale running, a resolver file for a Tailscale suffix takes its names
            // away from MagicDNS. A domain with its own resolver is handed back (`delegated`),
            // but a machine shared in from another tailnet has none: its name would go to
            // servers that do not know it. The addresses could never be routed anyway
            // (`ProtectedDestinations`), so the wildcard is left out.
            if tailscaleIsAnswering(env.resolvers),
               tailscaleSuffixes.contains(where: { WildcardDomain.matches(item.suffix, suffix: $0) }) {
                skipped[item.suffix] = "Tailscale answers these names itself"
                continue
            }
            if item.via == .block {
                guard env.blockSupported else {
                    skipped[item.suffix] = "the helper needs an update to block names"
                    continue
                }
                // The physical network's resolver, when it is known, answers the names an earlier
                // rule claims; with none, those names get no answer and the rest are blocked.
                let known = env.localGateway != nil && env.physicalInterface != nil
                let servers = Array(env.physicalDNS.filter { WildcardIPv4.parse($0) != nil && !$0.hasPrefix("127.") }.prefix(4))
                let withUpstream = known && !servers.isEmpty
                // Names another resolver serves (Tailscale's MagicDNS, a VPN's split DNS) under a blocked
                // suffix still go to it: the blackhole answers only what is ours to answer. A blackhole
                // asks no upstream of its own, so every resolver for the domain counts.
                let spec = WildcardSpec(suffix: item.suffix, gateway: withUpstream ? env.localGateway! : "",
                                        upstream: withUpstream ? servers : [],
                                        interface: withUpstream ? env.physicalInterface! : "",
                                        excluded: item.excluded,
                                        delegated: ScutilDNS.owners(under: item.suffix, asking: [], in: env.resolvers),
                                        block: true)
                guard WildcardSpec(dictionary: spec.dictionary) != nil else {
                    skipped[item.suffix] = "its gateway or interface is not one the helper accepts"
                    continue
                }
                specs.append(spec)
                continue
            }
            let gateway: String?, interface: String?, upstream: [String]
            switch item.via {
            case .block:
                continue
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
            let spec = WildcardSpec(suffix: item.suffix, gateway: gateway, upstream: servers, interface: interface,
                                    intoTunnel: item.via != .physical, excluded: item.excluded,
                                    delegated: ScutilDNS.owners(under: item.suffix, asking: servers, in: env.resolvers))
            // Same check the helper makes, so a spec it would refuse is never sent.
            guard WildcardSpec(dictionary: spec.dictionary) != nil else {
                skipped[item.suffix] = "its gateway or interface is not one the helper accepts"
                continue
            }
            specs.append(spec)
        }
        return (specs, skipped)
    }

    /// The DNS servers around the VPN: what macOS has for the physical interface now, so a
    /// new network brings its own; `fallback` (Settings) when it has none we can ask.
    static func physicalDNS(interface: String?, resolvers: [ScutilDNS.Resolver], fallback: [String]) -> [String] {
        let usable: (String) -> Bool = { WildcardIPv4.parse($0) != nil && !$0.hasPrefix("127.") }
        let current = interface.map { ScutilDNS.nameservers(forInterface: $0, in: resolvers) }?.filter(usable) ?? []
        return current.isEmpty ? fallback.filter(usable) : current
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
        /// macOS's tie-break between resolvers for the same domain: the lowest goes first.
        var order: Int?
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
                current?.domain = domain(value)
            } else if key.hasPrefix("nameserver[") {
                current?.nameservers.append(value)
            } else if key == "if_index", let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
                current?.interface = String(value[value.index(after: open)..<close])
            } else if key == "port" {
                current?.port = Int(value)
            } else if key == "order" {
                current?.order = Int(value)
            }
        }
        finish()
        return resolvers
    }

    /// A resolver domain as the wildcards write it: lower case, no trailing dot. Tailscale
    /// publishes its tailnet as "example-tailnet.ts.net." and our file says "example-tailnet.ts.net";
    /// both are the same domain. Nil for the root.
    static func domain(_ raw: String) -> String? {
        var d = raw.lowercased()
        while d.hasSuffix(".") { d.removeLast() }
        return d.isEmpty ? nil : d
    }

    /// The IPv4 DNS servers macOS has for `interface`, in order, each once.
    static func nameservers(forInterface interface: String, in resolvers: [Resolver]) -> [String] {
        var out: [String] = []
        for r in resolvers where r.interface == interface && !r.isWildcardForwarder {
            for ns in r.nameservers where WildcardIPv4.parse(ns) != nil && !out.contains(ns) { out.append(ns) }
        }
        return out
    }

    /// The other resolvers that serve names under `suffix`, for the forwarder to ask instead
    /// of `upstream`: each domain-scoped resolver (never the default one, which would take
    /// every name) for a domain at, under or above the suffix, that is not our own file. On
    /// `example-tailnet.ts.net` under `*.ts.net`, Tailscale's 100.100.100.100. Most specific
    /// first, each domain once, at the order macOS would pick.
    ///
    /// A resolver whose servers the wildcard asks anyway is left out: its names already get
    /// that resolver's answer, and stay routed (a VPN's split DNS under a VPN Only wildcard).
    static func owners(under suffix: String, asking upstream: [String], in resolvers: [Resolver]) -> [WildcardDelegation] {
        let suffix = domain(suffix) ?? suffix
        let byOrder = resolvers.enumerated()
            .filter { !$0.element.scoped && !$0.element.isWildcardForwarder }
            .sorted { ($0.element.order ?? Int.max, $0.offset) < ($1.element.order ?? Int.max, $1.offset) }
            .map(\.element)
        var seen: Set<String> = []
        var out: [WildcardDelegation] = []
        for r in byOrder {
            guard let d = r.domain, WildcardDomain.normalizedSuffix(d) == d, seen.insert(d).inserted,
                  let port = UInt16(exactly: r.port ?? 53), port != 0 else { continue }
            let servers = Array(r.nameservers.filter { WildcardDelegation.isUsableServer($0, port: port) }.prefix(4))
            let owner = WildcardDelegation(domain: d, servers: servers, port: port,
                                           interface: r.interface.flatMap { WildcardSpec.isValidInterfaceName($0) ? $0 : nil })
            guard !servers.isEmpty, owner.overlaps(suffix),
                  !(port == 53 && servers.contains(where: upstream.contains)) else { continue }
            out.append(owner)
        }
        return Array(out.sorted { $0.domain.count > $1.domain.count }.prefix(WildcardSpec.maxDelegated))
    }

    /// Resolvers for a name below `suffix` that are not ours: they have more matching labels,
    /// so macOS sends those names to them and the wildcard never sees them. One that our own
    /// file for the same domain comes before (a lower order) hides nothing: macOS picks the
    /// most matching labels, then the lowest order, so those names reach our forwarder.
    /// Sorted, each once.
    ///
    /// `served` are the suffixes the helper says it serves. Its files for them count as ours at
    /// the order they are written with, even when `resolvers` was read before they existed (a
    /// VPN connect: the list is read, then the helper writes the files).
    static func shadowing(_ suffix: String, in resolvers: [Resolver], served: Set<String> = []) -> [String] {
        let suffix = domain(suffix) ?? suffix
        let ours = served.compactMap(domain).map {
            Resolver(domain: $0, nameservers: ["127.0.0.1"], port: Int(WildcardResolverFile.port),
                     order: WildcardResolverFile.searchOrder)
        }
        let live = resolvers.filter { !$0.scoped } + ours
        let domains = live.compactMap { r -> String? in
            guard !r.isWildcardForwarder, let d = r.domain, d != suffix,
                  WildcardDomain.matches(d, suffix: suffix) else { return nil }
            let oursFirst = live.contains { ours in
                guard ours.isWildcardForwarder, ours.domain == d, let mine = ours.order, let theirs = r.order else { return false }
                return mine < theirs
            }
            return oursFirst ? nil : d
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
