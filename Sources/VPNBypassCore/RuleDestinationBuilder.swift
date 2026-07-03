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
        resolved: [String: [String]]
    ) -> [(rule: Rule, dests: [(value: String, isNetwork: Bool)])] {
        let orderedRules = rules.filter { $0.enabled }.sorted { $0.order < $1.order }
        let servicesById = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var out: [(rule: Rule, dests: [(value: String, isNetwork: Bool)])] = []
        for rule in orderedRules {
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
                add(rule.pattern, true)
            case .domain:
                for ip in resolved[rule.pattern] ?? [] { add(ip, false) }
            case .service:
                if let service = servicesById[rule.pattern] {
                    for domain in service.domains {
                        for ip in resolved[domain] ?? [] { add(ip, false) }
                    }
                    for range in service.ipRanges { add(range, true) }
                }
            case .suffix, .process:
                break   // not kernel-routable
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
        services: [RouteManager.ServiceEntry]
    ) -> Set<String> {
        let servicesById = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var hosts: Set<String> = []
        for rule in rules where rule.enabled {
            switch rule.matchType {
            case .domain:
                hosts.insert(rule.pattern)
            case .service:
                if let service = servicesById[rule.pattern] {
                    for domain in service.domains { hosts.insert(domain) }
                }
            case .ip, .cidr, .suffix, .process:
                break
            }
        }
        return hosts
    }
}
