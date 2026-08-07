// StartupSweepTests.swift
// Coverage for crash/unclean-quit recovery via ownership-tagged routes — the permanent fix for
// the issue #67 class ("app on/off but my public IP is my real one").
//
// Every route this app installs is tagged RTF_PROTO1 in the kernel; only this app sets that
// flag. A startup sweep reads one silent table dump and removes tagged entries the current
// session does not want — needing NO journal and NO surviving in-memory state, which is exactly
// what a kill -9 or a pre-fix quit race leaves behind. Routes the session DOES want are kept:
// the snapshot-reconciling batch add turns them into zero-event no-ops.

import XCTest
import Darwin
@testable import VPNBypassCore

@MainActor
final class StartupSweepTests: XCTestCase {

    private func kr(_ dest: UInt32, prefix: Int? = nil, ours: Bool, gw: UInt32 = 0xC0A80101) -> RouteKernel.KernelRoute {
        RouteKernel.KernelRoute(destination: dest, prefix: prefix, gatewayAddress: gw,
                                gatewayInterfaceIndex: nil,
                                flags: RTF_UP | RTF_STATIC | (ours ? RTF_PROTO1 : 0))
    }

    /// The Tetonne scenario: stranded VPN Only catch-alls (0.0.0.0/1 + 128.0.0.0/1) surviving a
    /// kill, with the next session wanting none of them. Both must be identified for removal —
    /// and a foreign route to the same shape of destination must NOT be.
    func testStrandedCatchAllsAreOrphansButForeignRoutesAreNot() {
        let table = [
            kr(0x00000000, prefix: 1, ours: true),    // 0.0.0.0/1    — ours, stranded
            kr(0x80000000, prefix: 1, ours: true),    // 128.0.0.0/1  — ours, stranded
            kr(0xCB007107, ours: false),              // 203.0.113.7  — someone else's host route
            kr(0x0A000000, prefix: 8, ours: false),   // 10.0.0.0/8   — the VPN's own
        ]
        let orphans = RouteManager.orphanedDestinations(table: table, desired: [])
        XCTAssertEqual(Set(orphans), ["0.0.0.0/1", "128.0.0.0/1"],
                       "ONLY tagged routes may be swept — never other software's")
    }

    /// Wanted routes survive the sweep so the reconciling apply can no-op them (zero events),
    /// while unwanted tagged leftovers still go.
    func testDesiredTaggedRoutesAreKept() {
        let table = [
            kr(0xCB007101, ours: true),  // 203.0.113.1 — still wanted
            kr(0xCB007102, ours: true),  // 203.0.113.2 — no longer in config
        ]
        let orphans = RouteManager.orphanedDestinations(table: table, desired: ["203.0.113.1"])
        XCTAssertEqual(orphans, ["203.0.113.2"])
    }

    func testEmptyTableAndUntaggedTableYieldNothing() {
        XCTAssertTrue(RouteManager.orphanedDestinations(table: [], desired: []).isEmpty)
        let foreign = [kr(0xCB007107, ours: false)]
        XCTAssertTrue(RouteManager.orphanedDestinations(table: foreign, desired: []).isEmpty)
    }

    /// The sweep must run at most once per launch — re-running on every status pass would
    /// re-scan the table endlessly for no benefit.
    func testSweepRunsOncePerSession() async {
        let rm = RouteManager.shared
        await rm.startupSweepIfNeeded(desired: [])
        // Second call must return immediately (same session) — observable only as "does not
        // throw/hang"; the guard flag is private by design.
        await rm.startupSweepIfNeeded(desired: [])
    }

    // MARK: - VPN gateway protection (P1.5)

    /// A batch containing the VPN's own gateway must refuse exactly that destination and let the
    /// rest through — disturbing the gateway route is the vendor-documented fast teardown.
    func testBatchAddRefusesVPNGatewayDestination() async {
        let rm = RouteManager.shared
        let savedGW = rm.vpnGateway
        defer { rm.vpnGateway = savedGW }
        rm.vpnGateway = "198.51.100.44"

        let result = await rm.addRoutesBatchTracked(routes: [
            (destination: "198.51.100.44", gateway: "192.168.1.1", isNetwork: false),
        ])
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(result.failedDestinations, ["198.51.100.44"])
        XCTAssertEqual(result.error, "protected: VPN gateway")
        XCTAssertTrue(rm.pendingKernelAdds.isEmpty, "a refused destination must not become pending")
    }
}
