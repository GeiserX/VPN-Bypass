// ClassicRouteCompiler.swift
// Pure, side-effect-free builder for the classic Bypass / VPN Only kernel-route set.
//
// This mirrors RouteCompiler (the custom-mode engine) so the DEFAULT routing modes —
// the ones a regression would leak — finally have a testable seam. `applyAllRoutesInternal`
// used to build this route set inline, interleaved with DNS resolution and cache mutation;
// that made the leak-critical apply path impossible to unit-test. Here the impure work
// (DNS, cache, the helper) stays in the caller, which feeds this builder the already-resolved
// IPs and gets back exactly the `routesToAdd` / `allSourceEntries` the caller then applies.
//
// Byte-identity note: the old inline loop collected domain IPs in TaskGroup *completion*
// order (non-deterministic run-to-run), and everything downstream (the helper batch-add and
// the `activeRoutes` tracking set) is order-independent — only the deduplicated route SET is
// observable. This builder emits a deterministic order (catch-all → inverse CIDRs → resolved
// domain IPs → service ranges) with the identical first-wins dedup, so the emitted set is
// provably the same set the inline code produced.

import Foundation

enum ClassicRouteCompiler {

    /// A kernel route to install (matches the caller's `routesToAdd` tuple, as a testable value).
    struct Route: Equatable, Hashable {
        let destination: String
        let gateway: String
        let isNetwork: Bool
        let source: String
    }

    /// An ownership row (matches the caller's `allSourceEntries` tuple).
    struct SourceEntry: Equatable, Hashable {
        let destination: String
        let gateway: String
        let source: String
    }

    struct Build: Equatable {
        let routesToAdd: [Route]
        let allSourceEntries: [SourceEntry]
    }

    /// One resolved matcher: its ownership `source` and the IPs to route for it. The caller
    /// has already applied its DNS + cache-fallback policy, so an entry here always has ≥1 IP
    /// (failed domains are simply omitted upstream).
    struct ResolvedGroup: Equatable {
        let source: String
        let ips: [String]
    }

    /// Build the classic route set.
    ///
    /// - Parameters:
    ///   - isInverse: `true` for VPN Only, `false` for Bypass.
    ///   - localGateway: the direct/local gateway — carries the VPN-Only catch-all and (Bypass) service ranges.
    ///   - routeGateway: the gateway domain IPs and inverse CIDRs ride (VPN gateway in inverse mode, local otherwise).
    ///   - inverseCIDRs: enabled inverse CIDR entries, in config order (VPN Only only).
    ///   - resolvedGroups: enabled domains/services with their resolved IPs, in a deterministic order.
    ///   - serviceRanges: enabled service IP ranges as `(source, range)`, in config order (Bypass only).
    static func build(
        isInverse: Bool,
        localGateway: String,
        routeGateway: String,
        inverseCIDRs: [String],
        resolvedGroups: [ResolvedGroup],
        serviceRanges: [(source: String, range: String)]
    ) -> Build {
        var routesToAdd: [Route] = []
        var seenDestinations: Set<String> = []      // dedup kernel operations
        var allSourceEntries: [SourceEntry] = []
        var seenSourceDests: Set<String> = []        // dedup (source, destination) ownership pairs

        // VPN Only: catch-all through the local gateway (0.0.0.0/1 + 128.0.0.0/1 cover all IPv4
        // with higher specificity than the default route), then inverse CIDRs through the VPN.
        if isInverse {
            routesToAdd.append(Route(destination: "0.0.0.0/1", gateway: localGateway, isNetwork: true, source: "VPN Only catch-all"))
            routesToAdd.append(Route(destination: "128.0.0.0/1", gateway: localGateway, isNetwork: true, source: "VPN Only catch-all"))
            seenDestinations.insert("0.0.0.0/1")
            seenDestinations.insert("128.0.0.0/1")
            allSourceEntries.append(SourceEntry(destination: "0.0.0.0/1", gateway: localGateway, source: "VPN Only catch-all"))
            allSourceEntries.append(SourceEntry(destination: "128.0.0.0/1", gateway: localGateway, source: "VPN Only catch-all"))
            seenSourceDests.insert("VPN Only catch-all|0.0.0.0/1")
            seenSourceDests.insert("VPN Only catch-all|128.0.0.0/1")

            for cidr in inverseCIDRs {
                if !seenDestinations.contains(cidr) {
                    seenDestinations.insert(cidr)
                    routesToAdd.append(Route(destination: cidr, gateway: routeGateway, isNetwork: true, source: cidr))
                }
                let key = "\(cidr)|\(cidr)"
                if !seenSourceDests.contains(key) {
                    seenSourceDests.insert(key)
                    allSourceEntries.append(SourceEntry(destination: cidr, gateway: routeGateway, source: cidr))
                }
            }
        }

        // Resolved domain / service-domain IPs (host routes) through the route gateway.
        for group in resolvedGroups {
            for ip in group.ips {
                if !seenDestinations.contains(ip) {
                    seenDestinations.insert(ip)
                    routesToAdd.append(Route(destination: ip, gateway: routeGateway, isNetwork: false, source: group.source))
                }
                let key = "\(group.source)|\(ip)"
                if !seenSourceDests.contains(key) {
                    seenSourceDests.insert(key)
                    allSourceEntries.append(SourceEntry(destination: ip, gateway: routeGateway, source: group.source))
                }
            }
        }

        // Bypass mode: service IP ranges (network routes) through the local gateway. VPN Only
        // does not use services. Note the original quirk: the ownership pair is recorded even
        // when the destination is a dup — preserved exactly.
        if !isInverse {
            for sr in serviceRanges {
                let key = "\(sr.source)|\(sr.range)"
                if !seenSourceDests.contains(key) {
                    seenSourceDests.insert(key)
                    allSourceEntries.append(SourceEntry(destination: sr.range, gateway: localGateway, source: sr.source))
                }
                guard !seenDestinations.contains(sr.range) else { continue }
                seenDestinations.insert(sr.range)
                routesToAdd.append(Route(destination: sr.range, gateway: localGateway, isNetwork: true, source: sr.source))
            }
        }

        return Build(routesToAdd: routesToAdd, allSourceEntries: allSourceEntries)
    }
}
