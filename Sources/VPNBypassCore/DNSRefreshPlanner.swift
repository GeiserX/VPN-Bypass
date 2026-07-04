// DNSRefreshPlanner.swift
// Pure, side-effect-free planner for the classic Bypass / VPN Only *DNS-refresh* route delta.
//
// This mirrors ClassicRouteCompiler (the full-apply builder) for the RECURRING refresh timer
// path. `performDNSRefresh` used to compute this delta inline, interleaving DNS resolution,
// kernel route-adds, and cache mutation inside one serial `for` loop — which made the
// leak-critical refresh planning impossible to unit-test. Here the impure work (parallel DNS,
// addRoute, cache writes) stays in the caller, which feeds this planner the already-resolved IPs
// plus the current route state and gets back exactly the `routesToAdd` / `candidateActiveEntries`
// / `expectedEntries` the caller then applies.
//
// Byte-identity note: the old serial loop resolved each (domain, source) entry one at a time and
// interleaved `addRoute` with the dedup/append bookkeeping. Every observable — the SET of new
// kernel destinations, the (source, destination) ownership rows committed, and the
// `expectedEntries` the stale reconcile diffs on — is a deterministic function of the resolved
// map and the existing state, independent of resolution ORDER. This planner reproduces the
// identical first-wins dedup (a new destination is scheduled once, by the FIRST domain to claim
// it) and the identical "commit the ownership row iff the kernel route is present AND the pair
// isn't already owned" rule — split so the pure not-already-owned half lives here and the impure
// kernel-presence half stays in the caller. Together they reproduce the old inline condition, so
// the emitted delta is provably the same delta the inline code produced. Resolving each unique
// domain once (the caller's job) only collapses the old per-entry resolves into a single
// consistent view; the planner is order-independent given that map.

import Foundation

enum DNSRefreshPlanner {

    /// A (source, destination) ownership pair — the refresh's unit of expected state and the key
    /// the stale reconcile diffs on. `performDNSRefresh` aliases its local `SourceDest` to this.
    struct SourceDest: Hashable {
        let source: String
        let destination: String
    }

    /// A new host route to install. Every refresh add is a host route through `routeGateway`
    /// (network routes — service ranges / inverse CIDRs — are repaired by the caller separately).
    struct PlannedRoute: Equatable, Hashable {
        let destination: String
        let gateway: String
    }

    /// A candidate ownership row. Its not-already-owned gate is already applied here; the caller
    /// commits it to `activeRoutes` IFF its destination is present in the kernel (already existed
    /// OR was just added this cycle).
    struct CandidateEntry: Equatable, Hashable {
        let destination: String
        let gateway: String
        let source: String
    }

    struct Plan: Equatable {
        /// NEW kernel destinations to add, in first-wins dedup order.
        let routesToAdd: [PlannedRoute]
        /// Ownership rows to commit, gated by the caller on kernel-presence only.
        let candidateActiveEntries: [CandidateEntry]
        /// The full expected (source, destination) set for this refresh: catch-all + inverse CIDRs
        /// + resolved IPs + DNS-failed cache fallback. (Bypass service IP ranges are inserted by
        /// the caller after, matching the old code that seeds them below the resolve loop.)
        let expectedEntries: Set<SourceDest>
    }

    /// Plan the classic DNS-refresh route delta.
    ///
    /// - Parameters:
    ///   - domainsToResolve: the (domain, source) work list, IN ORDER. Order fixes the first-wins
    ///     dedup winner and the candidate order; multiplicity is preserved (matching the old loop,
    ///     where a shared source resolving the same IP from two domains recorded two rows).
    ///   - resolvedDomainIPs: domain → IPs for domains that resolved this cycle. A present-but-empty
    ///     array means "resolved to no IPs" (no fallback); an ABSENT key means DNS failure.
    ///   - cachedDomainIPs: the disk-cache snapshot, consulted only for the DNS-failed fallback.
    ///   - existingDestinations: kernel destinations already present (never re-added).
    ///   - existingSourceDests: ownership pairs already tracked (never re-recorded).
    ///   - isInverse: `true` for VPN Only (seeds the two catch-alls), `false` for Bypass.
    ///   - routeGateway: the gateway every refreshed host route + ownership row rides.
    ///   - inverseCIDRs: enabled inverse CIDR entries (VPN Only). Seeded into `expectedEntries` as
    ///     `(cidr, cidr)`, never DNS-resolved or added here — the caller repairs their kernel route.
    static func plan(
        domainsToResolve: [(domain: String, source: String)],
        resolvedDomainIPs: [String: [String]],
        cachedDomainIPs: [String: [String]],
        existingDestinations: Set<String>,
        existingSourceDests: Set<SourceDest>,
        isInverse: Bool,
        routeGateway: String,
        inverseCIDRs: [String]
    ) -> Plan {
        var expectedEntries: Set<SourceDest> = []
        var routesToAdd: [PlannedRoute] = []
        var addedThisPass: Set<String> = []          // destinations already scheduled to add (dedup)
        var candidateActiveEntries: [CandidateEntry] = []

        // Preserve catch-all routes in VPN Only mode (they aren't DNS-resolved), then seed the
        // static inverse CIDR entries. Both are expected but never added by this planner.
        if isInverse {
            expectedEntries.insert(SourceDest(source: "VPN Only catch-all", destination: "0.0.0.0/1"))
            expectedEntries.insert(SourceDest(source: "VPN Only catch-all", destination: "128.0.0.0/1"))
            for cidr in inverseCIDRs {
                // CIDR entries: preserve as static routes, no DNS resolution.
                expectedEntries.insert(SourceDest(source: cidr, destination: cidr))
            }
        }

        // Walk the work list in order. A resolved domain records every (source, ip) as expected,
        // schedules a first-wins host-route add for any IP not already in the kernel, and emits an
        // ownership candidate (unless the pair is already owned). A DNS-failed domain falls back to
        // its cached IPs, which are expected (so the reconcile doesn't drop them) but neither added
        // nor owned.
        for (domain, source) in domainsToResolve {
            if let ips = resolvedDomainIPs[domain] {
                for ip in ips {
                    let entry = SourceDest(source: source, destination: ip)
                    expectedEntries.insert(entry)

                    // Schedule a kernel add only if the destination is completely new.
                    if !existingDestinations.contains(ip) && !addedThisPass.contains(ip) {
                        addedThisPass.insert(ip)
                        routesToAdd.append(PlannedRoute(destination: ip, gateway: routeGateway))
                    }

                    // Ownership candidate — recorded unless this pair is already owned. The caller
                    // commits it only once the kernel route is present (existed or just added).
                    if !existingSourceDests.contains(entry) {
                        candidateActiveEntries.append(CandidateEntry(destination: ip, gateway: routeGateway, source: source))
                    }
                }
            } else if let cachedIPs = cachedDomainIPs[domain] {
                // DNS failed — preserve cached IPs so they aren't treated as stale.
                for ip in cachedIPs {
                    expectedEntries.insert(SourceDest(source: source, destination: ip))
                }
            }
        }

        return Plan(
            routesToAdd: routesToAdd,
            candidateActiveEntries: candidateActiveEntries,
            expectedEntries: expectedEntries
        )
    }
}
