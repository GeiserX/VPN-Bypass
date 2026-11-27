// HostsBlockPlanner.swift
// Which names the list rules block, the pure part: the set the helper would write as exact-name
// blackhole lines into its own /etc/hosts section.
//
// First match holds as everywhere else: a name an earlier rule claims (a domain, a suffix, a Site list,
// a service) goes that rule's way, so a list below it does not block it, and a rule above a list is how
// a user unblocks one of its names. A name is counted once however many lists hold it, and all lists
// together may block at most `maxNames`: a list that would pass it is refused whole, never cut, and the
// reason is recorded for its row. Only a list rule on the Block route blocks anything.

import Foundation

enum HostsBlockPlanner {

    /// The most names all list rules together may block. Each one is a line mDNSResponder holds in
    /// memory and parses again on every change: on an Apple silicon Mac on macOS 26.6.1 it grew from
    /// 19 MB to 105 MB at 50,000 names and 363 MB at 200,000, and did not give the memory back.
    static let maxNames = 100_000

    /// Why a list rule blocks nothing although its route is Block.
    enum Refusal: Equatable {
        /// The list alone holds more new names than all lists together may block.
        case tooLarge(names: Int, limit: Int)
        /// Its new names would take all lists together past the limit. Lists count in rule order.
        case overTotal(names: Int, limit: Int)
    }

    /// Why a list rule takes no part at all.
    enum Inactive: Equatable {
        /// Lists block names only on the Block route.
        case notBlockRoute
        /// Its route is off, gone, or of a type this build does not know.
        case routeOff
        /// Rules apply only in Custom mode.
        case notCustomMode
        /// No good copy of the list has been downloaded yet.
        case noCopy
    }

    struct Plan: Equatable {
        /// The names to block, each once, in rule order.
        var names: [String] = []
        /// How many names each accepted list rule adds (names an earlier list holds are not counted again).
        var accepted: [UUID: Int] = [:]
        var refused: [UUID: Refusal] = [:]
        var inactive: [UUID: Inactive] = [:]
        /// Accepted list rules that add no names because a rule or a list above holds every one of
        /// theirs. A list can add none for other reasons too (its names are the protected download
        /// hosts), and its row must not blame the rules above it then.
        var coveredAbove: Set<UUID> = []
    }

    /// `lists` holds the names of each list's copy in use, keyed by the rule's pattern (its URL).
    /// `geosite` is the Site lists' expansions, read from the file when nil.
    static func plan(_ config: Config, lists: [String: [String]], geosite: [String: GeoSiteExpansion]? = nil,
                     limit: Int = maxNames) -> Plan {
        var out = Plan()
        let ordered = config.rules.filter(\.enabled).sorted(by: { $0.order < $1.order })
        guard RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) else {
            for rule in ordered where rule.matchType == .list { out.inactive[rule.id] = .notCustomMode }
            return out
        }
        let routes = Dictionary(config.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let services = Dictionary(config.services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let siteLists = geosite ?? GeoDataFile.geosite.expansions(
            for: Set(config.rules.filter { $0.enabled && $0.matchType == .geosite }.map { $0.pattern.lowercased() }))
        // A Site rule the wildcard planner leaves out whole serves nothing, so it claims nothing here either.
        let leftOut = Set(WildcardPlanner.selection(config, geosite: siteLists).refused.compactMap { id, refusal in
            if case .overTotal = refusal { return id } else { return nil }
        })
        let protected = protectedHosts(config)

        var claimedNames: Set<String> = []
        var claimedSuffixes: Set<String> = []
        var taken: Set<String> = []
        func claimed(_ name: String) -> Bool {
            claimedNames.contains(name)
                || (!claimedSuffixes.isEmpty && WildcardDomain.ancestors(of: name).contains(where: claimedSuffixes.contains))
        }

        for rule in ordered {
            guard let route = routes[rule.routeId], route.enabled, route.egress != .unsupported else {
                if rule.matchType == .list { out.inactive[rule.id] = .routeOff }
                continue
            }
            guard rule.matchType == .list else {
                guard !leftOut.contains(rule.id) else { continue }
                if rule.matchType == .geosite, route.egress == .block,
                   siteLists[rule.pattern.lowercased()]?.exceedsWildcards(onBlock: true) == true { continue }
                let (entries, names) = WildcardPlanner.claims(of: rule, services: services, lists: siteLists)
                let normalizedNames = names.compactMap(WildcardDomain.normalizedSuffix)
                claimedSuffixes.formUnion(entries.compactMap(WildcardDomain.suffix(of:)))
                claimedNames.formUnion(normalizedNames)
                // On Block an exact name is a blackhole for everything under it too (WildcardPlanner).
                if route.egress == .block { claimedSuffixes.formUnion(normalizedNames) }
                continue
            }
            guard route.egress == .block else {
                out.inactive[rule.id] = .notBlockRoute
                continue
            }
            guard let names = lists[rule.pattern] else {
                out.inactive[rule.id] = .noCopy
                continue
            }
            var fresh: [String] = []
            var seen: Set<String> = []
            var covered = 0
            for name in names where seen.insert(name).inserted && !protected.contains(name) {
                if taken.contains(name) || claimed(name) { covered += 1 } else { fresh.append(name) }
            }
            if fresh.count > limit {
                out.refused[rule.id] = .tooLarge(names: fresh.count, limit: limit)
                continue
            }
            guard out.names.count + fresh.count <= limit else {
                out.refused[rule.id] = .overTotal(names: fresh.count, limit: limit)
                continue
            }
            out.names.append(contentsOf: fresh)
            taken.formUnion(fresh)
            out.accepted[rule.id] = fresh.count
            if fresh.isEmpty, covered > 0, covered == seen.count { out.coveredAbove.insert(rule.id) }
        }
        return out
    }

    /// The hosts GitHub sends the app's downloads on to: a release asset (the GeoIP and GeoSite files,
    /// the app's own updates) redirects from github.com to one of these, and the preset list is on raw.
    static let downloadRedirectHosts: Set<String> = [
        "github.com", "raw.githubusercontent.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// The hosts the app downloads from, which no list may block: every list rule's own host, the
    /// GeoIP and GeoSite sources in use, and the hosts GitHub redirects those downloads to. Blocking
    /// one would stop the next update that could undo it.
    static func protectedHosts(_ config: Config) -> Set<String> {
        var hosts = Set(config.rules.filter { $0.matchType == .list }.compactMap {
            ListStore.source(from: $0.pattern)?.host?.lowercased()
        }).union(downloadRedirectHosts)
        for kind in GeoKind.allCases {
            let address = kind == .ip ? config.geoipSourceURL : config.geositeSourceURL
            if let host = GeoDataStore.source(from: address, kind: kind)?.host?.lowercased() { hosts.insert(host) }
        }
        return hosts
    }
}
