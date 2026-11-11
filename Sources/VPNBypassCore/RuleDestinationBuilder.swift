// RuleDestinationBuilder.swift
// Pure rule→destination matching for the custom-mode kernel engine (P1+).
//
// The engine (RouteManager.resolveRuleDestinations) resolves every hostname the
// enabled rules reference ONCE, in parallel, into a `[host: [IP]]` map, then hands
// that map here. This function is the matcher: it maps each enabled rule (in
// first-match / ascending-`order` order) onto the concrete kernel destinations its
// matcher claims, using ONLY the pre-resolved map — no async, no DNS, no I/O, no
// singletons — so it is unit-testable in isolation exactly like RuleResolver /
// RouteCompiler / HookGenerator. RouteCompiler consumes the result and decides which
// destinations actually get a kernel route.
//
//   • .ip      → the address itself (host route).
//   • .cidr    → the block itself (network route).
//   • .domain  → the resolved IPs from the map (empty when unresolved).
//   • .service → each of the service's domains resolved from the map + its static
//                ipRanges (network routes).
//   • .geosite → the exact names of a geosite list, resolved from the map. Its suffixes are
//                wildcards for the DNS forwarder (WildcardPlanner), not routes here.
//   • .geoip   → the country's IPv4 ranges from the geoip list (network routes), each held
//                to the same install policy as a .cidr rule. No list, or a country the list
//                lacks, gives nothing.
//   • .suffix / .process → nothing (not kernel-routable — a listener / NE engine owns
//                those, not the routing table).
//
// Per-rule destinations are de-duplicated (a service that lists the same IP twice, or
// two of its domains resolving to a shared IP, yields one entry); RouteCompiler dedups
// again globally, so this only trims obvious repeats. Cross-rule first-match ordering
// is RouteCompiler's job — this preserves rule order so the compiler can honour it.

import Foundation

enum RuleDestinationBuilder {

    /// Build each enabled rule's concrete destinations from a pre-resolved DNS map,
    /// in ascending-`order` (first-match) order.
    ///
    /// - Parameters:
    ///   - rules: the routing rules (any order/enabled state; filtered + sorted here).
    ///   - services: the available services a `.service` rule can expand.
    ///   - resolved: host → resolved IPs, produced up front by the engine. A host absent
    ///     from the map (or mapped to `[]`) contributes no destinations for that rule.
    /// - Returns: one `(rule, dests)` pair per ENABLED rule, in evaluation order — the
    ///   exact shape RouteCompiler.compile expects.
    static func build(
        rules: [Rule],
        services: [RouteManager.ServiceEntry],
        resolved: [String: [String]],
        geoip: [String: [String]] = [:],
        geosite: [String: GeoSiteExpansion] = [:],
        routes: [Route] = []
    ) -> [(rule: Rule, dests: [(value: String, isNetwork: Bool)])] {
        let orderedRules = rules.filter { $0.enabled }.sorted { $0.order < $1.order }
        let blockRoutes = Set(routes.filter { $0.egress == .block }.map(\.id))
        let servicesById = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var out: [(rule: Rule, dests: [(value: String, isNetwork: Bool)])] = []
        for rule in orderedRules {
            // A name sent to Block is answered NXDOMAIN by the DNS forwarder, and its addresses are
            // not used: nothing is looked up for it (a lookup would only tell a DNS server which names a
            // blocked list holds). The rules that name addresses are the compiler's.
            if blockRoutes.contains(rule.routeId), [.domain, .suffix, .service, .geosite].contains(rule.matchType) {
                out.append((rule: rule, dests: rule.matchType == .service ? Self.serviceRanges(of: rule, in: servicesById) : []))
                continue
            }
            var dests: [(value: String, isNetwork: Bool)] = []
            var seen: Set<String> = []
            func add(_ value: String, _ isNetwork: Bool) {
                guard seen.insert(value).inserted else { return }
                dests.append((value: value, isNetwork: isNetwork))
            }

            switch rule.matchType {
            case .ip:
                add(rule.pattern, false)
            case .cidr:
                if !DestinationInstallPolicy.refusesInstall(rule.pattern) {
                    add(rule.pattern, true)
                }
            case .geoip:
                for range in geoip[rule.pattern.lowercased()] ?? [] where !DestinationInstallPolicy.refusesInstall(range) {
                    add(range, true)
                }
            case .geosite:
                for name in geosite[rule.pattern.lowercased()]?.usable.names ?? [] {
                    for ip in resolved[name] ?? [] { add(ip, false) }
                }
            case .domain:
                for ip in resolved[rule.pattern] ?? [] { add(ip, false) }
            case .service:
                if let service = servicesById[rule.pattern] {
                    for domain in service.domains {
                        for ip in resolved[domain] ?? [] { add(ip, false) }
                    }
                    for range in service.ipRanges { add(range, true) }
                }
            case .suffix, .process, .unsupported:
                break   // not kernel-routable (an unsupported type matches nothing)
            }
            out.append((rule: rule, dests: dests))
        }
        return out
    }

    /// The de-duplicated set of hostnames the ENABLED rules require DNS for (domain
    /// patterns + every domain of a referenced service). The engine resolves exactly
    /// this set in parallel, so the same host reachable via two rules resolves once.
    /// Pure counterpart to `build`, sharing its rule semantics.
    static func hostsToResolve(
        rules: [Rule],
        services: [RouteManager.ServiceEntry],
        geosite: [String: GeoSiteExpansion] = [:],
        routes: [Route] = []
    ) -> Set<String> {
        let servicesById = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let blockRoutes = Set(routes.filter { $0.egress == .block }.map(\.id))
        var hosts: Set<String> = []
        // A name sent to Block is never looked up (see `build`).
        for rule in rules where rule.enabled && !blockRoutes.contains(rule.routeId) {
            switch rule.matchType {
            case .domain:
                hosts.insert(rule.pattern)
            case .service:
                if let service = servicesById[rule.pattern] {
                    for domain in service.domains { hosts.insert(domain) }
                }
            case .geosite:
                for name in geosite[rule.pattern.lowercased()]?.usable.names ?? [] { hosts.insert(name) }
            case .ip, .cidr, .geoip, .suffix, .process, .unsupported:
                break
            }
        }
        return hosts
    }

    /// The ranges of the service a rule names, which the compiler turns into blocks on the Block route
    /// (the names of the service are answered by the DNS forwarder instead).
    private static func serviceRanges(of rule: Rule, in services: [String: RouteManager.ServiceEntry]) -> [(value: String, isNetwork: Bool)] {
        (services[rule.pattern]?.ipRanges ?? []).map { (value: $0, isNetwork: true) }
    }
}
