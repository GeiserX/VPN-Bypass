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

    /// The bypass-all routes VPN Only installs: four /2s covering all of IPv4 via the local
    /// gateway. NOT the classic 0.0.0.0/1 + 128.0.0.0/1 pair, deliberately: wg-quick and
    /// OpenVPN's redirect-gateway def1 capture traffic by installing that exact pair
    /// themselves, so claiming it did not add routes — it REPOINTED the VPN's own routes to
    /// the local gateway (the helper converges an existing destination in place) and teardown
    /// then DELETED them out from under the VPN (#103: VPN Only under WireGuard inverted, and
    /// WireGuard could not connect while the app ran, both sides fighting over the same two
    /// kernel entries). The /2 quartet is additive: longest-prefix beats the VPN's /1s without
    /// touching them, listed destinations still win over /2 with their /32s and CIDRs, and
    /// removing the quartet hands traffic straight back to the tunnel.
    static let bypassAllCatchAlls: [String] = [
        "0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2",
    ]

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

        // VPN Only: bypass-all through the local gateway (the /2 quartet covers all IPv4 with
        // higher specificity than both a default route AND a /1-pair full tunnel — see
        // bypassAllCatchAlls), then inverse CIDRs through the VPN.
        //
        // INSTALL ORDER IS LEAK-CRITICAL. The helper writes this array strictly in order, so the
        // catch-alls are deferred to the very END rather than emitted here. Installing them first
        // — as this did originally — pointed ALL traffic at the local gateway before any of the
        // listed destinations had their VPN route yet, so for the length of the apply (hundreds of
        // routes, each a subprocess) the exact destinations the user asked to protect fell through
        // to the clear. The apply made things worse before it made them better. Emitting them last
        // means the VPN routes are already in place the instant the catch-alls take effect.
        //
        // This mirrors teardown, which already removes catch-alls FIRST (see removeAllRoutes and
        // destinationsToUnstrand) so that traffic falls back to the VPN default, not out of it.
        // Same principle, opposite end: the catch-alls are the last thing on and the first thing off.
        var deferredCatchAlls: [Route] = []
        if isInverse {
            for catchAll in bypassAllCatchAlls {
                deferredCatchAlls.append(Route(destination: catchAll, gateway: localGateway, isNetwork: true, source: "VPN Only catch-all"))
                seenDestinations.insert(catchAll)
                allSourceEntries.append(SourceEntry(destination: catchAll, gateway: localGateway, source: "VPN Only catch-all"))
                seenSourceDests.insert("VPN Only catch-all|\(catchAll)")
            }

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

        // Catch-alls last (see the comment where they are built): the VPN routes must already be
        // installed before all remaining traffic is pointed at the local gateway.
        routesToAdd.append(contentsOf: deferredCatchAlls)

        return Build(routesToAdd: routesToAdd, allSourceEntries: allSourceEntries)
    }
}
