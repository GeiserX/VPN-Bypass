import XCTest
@testable import VPNBypassCore

/// Exhaustive tests for the classic DNS-refresh planner — the RECURRING refresh path that a
/// regression would leak. These pin the first-wins kernel-add dedup, the shared-IP two-owner
/// bookkeeping, the "already in kernel → no re-add", the inverse catch-all + CIDR seeding
/// (expected but never added), and the DNS-failed cache fallback (expected but never added) that
/// used to live untested inside the serial resolve+plan loop of `performDNSRefresh`.
final class DNSRefreshPlannerTests: XCTestCase {
    typealias P = DNSRefreshPlanner
    private let local = "192.168.1.1"
    private let vpn = "10.0.0.1"

    private func pr(_ d: String, _ g: String) -> P.PlannedRoute { P.PlannedRoute(destination: d, gateway: g) }
    private func ce(_ d: String, _ g: String, _ s: String) -> P.CandidateEntry { P.CandidateEntry(destination: d, gateway: g, source: s) }
    private func sd(_ s: String, _ d: String) -> P.SourceDest { P.SourceDest(source: s, destination: d) }

    // MARK: - Bypass mode

    /// Two domains share an IP; the shared IP is added to the kernel exactly once (first domain
    /// wins) but every (source, ip) pair is both expected and an ownership candidate.
    func testBypassMultiDomainSharedIPFirstWinsDedup() {
        let plan = P.plan(
            domainsToResolve: [(domain: "a.com", source: "a.com"), (domain: "b.com", source: "b.com")],
            resolvedDomainIPs: ["a.com": ["1.1.1.1", "2.2.2.2"], "b.com": ["2.2.2.2", "3.3.3.3"]],
            cachedDomainIPs: [:],
            existingDestinations: [],
            existingSourceDests: [],
            isInverse: false,
            routeGateway: local,
            inverseCIDRs: []
        )
        // 2.2.2.2 appears in both domains but is scheduled once, by a.com (first-wins), in order.
        XCTAssertEqual(plan.routesToAdd, [
            pr("1.1.1.1", local),
            pr("2.2.2.2", local),
            pr("3.3.3.3", local),
        ])
        // ...but the ownership candidates keep both owners of the shared IP, in iteration order.
        XCTAssertEqual(plan.candidateActiveEntries, [
            ce("1.1.1.1", local, "a.com"),
            ce("2.2.2.2", local, "a.com"),
            ce("2.2.2.2", local, "b.com"),
            ce("3.3.3.3", local, "b.com"),
        ])
        XCTAssertEqual(plan.expectedEntries, [
            sd("a.com", "1.1.1.1"), sd("a.com", "2.2.2.2"),
            sd("b.com", "2.2.2.2"), sd("b.com", "3.3.3.3"),
        ])
    }

    /// An IP already present in the kernel is NOT re-added, but its ownership row is still a
    /// candidate (the caller commits it because the destination is present-in-kernel).
    func testBypassExistingKernelDestinationIsNotReAdded() {
        let plan = P.plan(
            domainsToResolve: [(domain: "a.com", source: "a.com")],
            resolvedDomainIPs: ["a.com": ["1.1.1.1", "2.2.2.2"]],
            cachedDomainIPs: [:],
            existingDestinations: ["1.1.1.1"],   // already in the kernel
            existingSourceDests: [],             // but not yet owned
            isInverse: false,
            routeGateway: local,
            inverseCIDRs: []
        )
        // 1.1.1.1 already exists → only 2.2.2.2 is a new kernel add.
        XCTAssertEqual(plan.routesToAdd, [pr("2.2.2.2", local)])
        // Both remain ownership candidates (1.1.1.1's route already exists, so the caller keeps it).
        XCTAssertEqual(plan.candidateActiveEntries, [
            ce("1.1.1.1", local, "a.com"),
            ce("2.2.2.2", local, "a.com"),
        ])
        XCTAssertEqual(plan.expectedEntries, [sd("a.com", "1.1.1.1"), sd("a.com", "2.2.2.2")])
    }

    /// The not-already-owned gate: an IP whose (source, ip) pair is already tracked emits NO
    /// ownership candidate, yet is still expected (so the stale reconcile never drops it).
    func testBypassAlreadyOwnedPairEmitsNoCandidateButStaysExpected() {
        let plan = P.plan(
            domainsToResolve: [(domain: "a.com", source: "a.com")],
            resolvedDomainIPs: ["a.com": ["1.1.1.1", "2.2.2.2"]],
            cachedDomainIPs: [:],
            existingDestinations: ["1.1.1.1", "2.2.2.2"],   // both already in the kernel
            existingSourceDests: [sd("a.com", "1.1.1.1")],  // 1.1.1.1 already owned by a.com
            isInverse: false,
            routeGateway: local,
            inverseCIDRs: []
        )
        XCTAssertTrue(plan.routesToAdd.isEmpty)                       // nothing new to add
        XCTAssertEqual(plan.candidateActiveEntries, [ce("2.2.2.2", local, "a.com")])  // 1.1.1.1 suppressed
        XCTAssertEqual(plan.expectedEntries, [sd("a.com", "1.1.1.1"), sd("a.com", "2.2.2.2")]) // both expected
    }

    /// DNS fails for one domain: its cached IPs are expected (protected from the reconcile) but are
    /// NEVER added to the kernel and NEVER become ownership candidates.
    func testBypassDNSFailedFallsBackToCacheExpectedButNotAdded() {
        let plan = P.plan(
            domainsToResolve: [(domain: "a.com", source: "a.com"), (domain: "b.com", source: "b.com")],
            resolvedDomainIPs: ["a.com": ["1.1.1.1"]],   // b.com absent → DNS failed
            cachedDomainIPs: ["b.com": ["9.9.9.9", "8.8.8.8"]],
            existingDestinations: [],
            existingSourceDests: [],
            isInverse: false,
            routeGateway: local,
            inverseCIDRs: []
        )
        // Only the successfully-resolved IP is added; the cached fallback IPs are not.
        XCTAssertEqual(plan.routesToAdd, [pr("1.1.1.1", local)])
        XCTAssertEqual(plan.candidateActiveEntries, [ce("1.1.1.1", local, "a.com")])
        // ...but the cached IPs ARE expected, so the reconcile won't tear them out.
        XCTAssertEqual(plan.expectedEntries, [
            sd("a.com", "1.1.1.1"),
            sd("b.com", "9.9.9.9"), sd("b.com", "8.8.8.8"),
        ])
    }

    // MARK: - VPN Only (inverse) mode

    /// Inverse mode injects the two catch-alls as expected (never added), seeds each CIDR as a
    /// static expected entry (never added), and adds only the resolved domain IP via the VPN gateway.
    func testInverseSeedsCatchAllsAndCIDRsWhichAreExpectedNotAdded() {
        let plan = P.plan(
            domainsToResolve: [(domain: "x.com", source: "x.com")],
            resolvedDomainIPs: ["x.com": ["3.3.3.3"]],
            cachedDomainIPs: [:],
            existingDestinations: [],
            existingSourceDests: [],
            isInverse: true,
            routeGateway: vpn,
            inverseCIDRs: ["172.16.0.0/12"]
        )
        // Only the resolved host IP is a kernel add — NOT the catch-alls, NOT the CIDR.
        XCTAssertEqual(plan.routesToAdd, [pr("3.3.3.3", vpn)])
        XCTAssertEqual(plan.candidateActiveEntries, [ce("3.3.3.3", vpn, "x.com")])
        // Catch-alls + CIDR + resolved IP are all expected.
        XCTAssertEqual(plan.expectedEntries, [
            sd("VPN Only catch-all", "0.0.0.0/1"),
            sd("VPN Only catch-all", "128.0.0.0/1"),
            sd("172.16.0.0/12", "172.16.0.0/12"),
            sd("x.com", "3.3.3.3"),
        ])
        // The CIDR must never be scheduled for a host add here.
        XCTAssertFalse(plan.routesToAdd.contains { $0.destination == "172.16.0.0/12" })
    }

    /// Inverse mode with no resolvable domains: catch-alls + every CIDR are expected, nothing is
    /// added, and there are no ownership candidates.
    func testInverseEmptyDomainsIsCatchAllsAndCIDRsOnly() {
        let plan = P.plan(
            domainsToResolve: [],
            resolvedDomainIPs: [:],
            cachedDomainIPs: [:],
            existingDestinations: [],
            existingSourceDests: [],
            isInverse: true,
            routeGateway: vpn,
            inverseCIDRs: ["172.16.0.0/12", "10.0.0.0/8"]
        )
        XCTAssertTrue(plan.routesToAdd.isEmpty)
        XCTAssertTrue(plan.candidateActiveEntries.isEmpty)
        XCTAssertEqual(plan.expectedEntries, [
            sd("VPN Only catch-all", "0.0.0.0/1"),
            sd("VPN Only catch-all", "128.0.0.0/1"),
            sd("172.16.0.0/12", "172.16.0.0/12"),
            sd("10.0.0.0/8", "10.0.0.0/8"),
        ])
    }

    // MARK: - Invariant that guards against a dropped ownership row

    /// Every ownership candidate's destination must be present-or-schedulable — i.e. it is either
    /// already in the kernel OR scheduled in routesToAdd. Otherwise the caller's kernel-presence
    /// gate would silently drop the ownership row (a leak of the route's ownership tracking).
    func testEveryCandidateDestinationIsExistingOrScheduled() {
        let existing: Set<String> = ["1.1.1.1"]
        let plan = P.plan(
            domainsToResolve: [(domain: "a.com", source: "a.com"),
                               (domain: "b.com", source: "svc"),
                               (domain: "c.com", source: "svc")],
            resolvedDomainIPs: ["a.com": ["1.1.1.1", "4.4.4.4"],
                                "b.com": ["4.4.4.4"],
                                "c.com": ["5.5.5.5"]],
            cachedDomainIPs: [:],
            existingDestinations: existing,
            existingSourceDests: [],
            isInverse: false,
            routeGateway: local,
            inverseCIDRs: []
        )
        let scheduled = Set(plan.routesToAdd.map { $0.destination })
        for candidate in plan.candidateActiveEntries {
            XCTAssertTrue(
                existing.contains(candidate.destination) || scheduled.contains(candidate.destination),
                "candidate dest \(candidate.destination) is neither already-present nor scheduled"
            )
        }
        // 4.4.4.4 is shared by a.com and b.com but scheduled exactly once (first-wins).
        XCTAssertEqual(plan.routesToAdd.filter { $0.destination == "4.4.4.4" }.count, 1)
    }

    // MARK: - Additional leak-path coverage

    /// The VPN-Only leak path: an inverse domain whose DNS fails falls back to its cached IPs.
    /// Those cached IPs must be expected (reconcile-protected) but NEVER added to the kernel and
    /// NEVER become ownership candidates — and the two catch-alls are still seeded.
    func testInverseDNSFailedFallsBackToCacheExpectedButNotAdded() {
        let plan = P.plan(
            domainsToResolve: [(domain: "v.com", source: "v.com")],
            resolvedDomainIPs: [:],                       // v.com absent → DNS failed
            cachedDomainIPs: ["v.com": ["7.7.7.7", "6.6.6.6"]],
            existingDestinations: [],
            existingSourceDests: [],
            isInverse: true,
            routeGateway: vpn,
            inverseCIDRs: []
        )
        // Cached IPs are neither added nor owned in VPN-Only mode either.
        XCTAssertTrue(plan.routesToAdd.isEmpty)
        XCTAssertTrue(plan.candidateActiveEntries.isEmpty)
        XCTAssertFalse(plan.routesToAdd.contains { $0.destination == "7.7.7.7" || $0.destination == "6.6.6.6" })
        // ...but they ARE expected, alongside the always-seeded catch-alls.
        XCTAssertEqual(plan.expectedEntries, [
            sd("VPN Only catch-all", "0.0.0.0/1"),
            sd("VPN Only catch-all", "128.0.0.0/1"),
            sd("v.com", "7.7.7.7"), sd("v.com", "6.6.6.6"),
        ])
    }

    /// The SAME source owns the SAME IP via two different domains. The IP is added to the kernel
    /// exactly once (first-wins), but BOTH ownership rows are kept — proving the planner preserves
    /// the per-iteration multiplicity the old inline loop produced (existingSourceDests is a fixed
    /// snapshot, so the second occurrence is not deduped away).
    func testDuplicateSameSourceSameIPKeepsTwoOwnershipRows() {
        let plan = P.plan(
            domainsToResolve: [(domain: "a.com", source: "svc"), (domain: "b.com", source: "svc")],
            resolvedDomainIPs: ["a.com": ["1.1.1.1"], "b.com": ["1.1.1.1"]],
            cachedDomainIPs: [:],
            existingDestinations: [],
            existingSourceDests: [],
            isInverse: false,
            routeGateway: local,
            inverseCIDRs: []
        )
        // Added once...
        XCTAssertEqual(plan.routesToAdd, [pr("1.1.1.1", local)])
        // ...but two ownership rows for the same (source, IP), in iteration order.
        XCTAssertEqual(plan.candidateActiveEntries, [
            ce("1.1.1.1", local, "svc"),
            ce("1.1.1.1", local, "svc"),
        ])
        XCTAssertEqual(plan.expectedEntries, [sd("svc", "1.1.1.1")])
    }

    /// Pins the "present-but-empty ≠ absent" contract. A domain mapped to an EMPTY array resolved
    /// to no IPs — it contributes nothing and its cache is NOT consulted. A domain ABSENT from the
    /// map is a DNS failure — its cache IS consulted and lands in expectedEntries only.
    func testEmptyResolvedArrayContributesNothingWhileAbsentDomainUsesCache() {
        let plan = P.plan(
            domainsToResolve: [(domain: "e.com", source: "e.com"), (domain: "f.com", source: "f.com")],
            resolvedDomainIPs: ["e.com": []],                    // resolved to no IPs (no fallback)
            cachedDomainIPs: ["e.com": ["5.5.5.5"], "f.com": ["4.4.4.4"]],  // f.com absent → uses cache
            existingDestinations: [],
            existingSourceDests: [],
            isInverse: false,
            routeGateway: local,
            inverseCIDRs: []
        )
        XCTAssertTrue(plan.routesToAdd.isEmpty)
        XCTAssertTrue(plan.candidateActiveEntries.isEmpty)
        // Only the ABSENT domain's cache is consulted; the empty-array domain's cache is ignored.
        XCTAssertEqual(plan.expectedEntries, [sd("f.com", "4.4.4.4")])
        XCTAssertFalse(plan.expectedEntries.contains(sd("e.com", "5.5.5.5")))
    }
}
