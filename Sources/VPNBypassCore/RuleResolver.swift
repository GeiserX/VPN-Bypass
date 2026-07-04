// RuleResolver.swift
// Pure rule→route resolution for the multi-route engine (P1, VPN-Bypass-3sc.8).
//
// First enabled rule (by ascending `order`) whose matcher matches a destination
// wins; otherwise the default route. No side effects, no actor isolation — the
// matching core is unit-testable in isolation. The engine (RouteManager) decides
// what to DO with the resolved route (kernel route / proxy listener / etc.) and
// whether the route is enabled; the resolver only answers "which route".

import Foundation

enum RuleResolver {

    /// Resolve the route for a hostname (optionally tagged with the service it
    /// belongs to, so `service` rules can match). Returns nil only if there is
    /// no matching rule AND no usable default route.
    static func route(
        forDomain domain: String,
        serviceId: String? = nil,
        rules: [Rule],
        routes: [Route],
        defaultRouteId: UUID?
    ) -> Route? {
        resolve(rules: rules, routes: routes, defaultRouteId: defaultRouteId) { rule in
            switch rule.matchType {
            case .domain:  return rule.pattern.caseInsensitiveCompare(domain) == .orderedSame
            case .suffix:  return domainMatchesSuffix(domain, suffix: rule.pattern)
            case .service: return serviceId != nil && rule.pattern == serviceId
            case .ip, .cidr, .process: return false
            }
        }
    }

    /// Resolve the route for a destination IP (exact `ip` rules + `cidr` containment).
    static func route(
        forIP ip: String,
        rules: [Rule],
        routes: [Route],
        defaultRouteId: UUID?
    ) -> Route? {
        resolve(rules: rules, routes: routes, defaultRouteId: defaultRouteId) { rule in
            switch rule.matchType {
            case .ip:   return rule.pattern == ip
            case .cidr: return ipv4(ip, inCIDR: rule.pattern)
            case .domain, .suffix, .service, .process: return false
            }
        }
    }

    // MARK: - Internals

    private static func resolve(
        rules: [Rule],
        routes: [Route],
        defaultRouteId: UUID?,
        matches: (Rule) -> Bool
    ) -> Route? {
        let byId = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for rule in rules.filter({ $0.enabled }).sorted(by: { $0.order < $1.order }) {
            if matches(rule), let route = byId[rule.routeId] {
                return route
            }
        }
        return defaultRouteId.flatMap { byId[$0] }
    }

    /// True when `domain` equals `suffix` or is a sub-domain of it
    /// (e.g. "api.example.com" matches suffix "example.com").
    static func domainMatchesSuffix(_ domain: String, suffix: String) -> Bool {
        let d = domain.lowercased(), s = suffix.lowercased()
        return d == s || d.hasSuffix("." + s)
    }

    /// IPv4-in-CIDR containment, e.g. "10.1.2.3" ∈ "10.0.0.0/8". IPv6 → false.
    static func ipv4(_ ip: String, inCIDR cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits),
              let ipVal = ipv4ToUInt32(ip), let netVal = ipv4ToUInt32(String(parts[0])) else {
            return false
        }
        if bits == 0 { return true }
        let mask: UInt32 = bits == 32 ? .max : ~(UInt32.max >> bits)
        return (ipVal & mask) == (netVal & mask)
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard let n = UInt32(octet), n <= 255 else { return nil }
            result = (result << 8) | n
        }
        return result
    }
}
