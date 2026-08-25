// MissingRouteReconcileTests.swift
// Coverage for restoring routes the kernel dropped underneath us — issue #94.
//
// macOS purges an interface's routes when the effective physical path changes. With Wi-Fi and
// Ethernet both up on one subnet, switching primary keeps NWPath `.satisfied`, keeps the same
// gateway, and keeps both interfaces in `availableInterfaces` — so every signal the app watches
// compares equal while the routes are gone. `shouldSkipReapply` then compares the desired set
// against the app's OWN bookkeeping, which still claims they are installed, and nothing happens.
//
// The kernel is the only witness that disagrees. `missingDestinations` is the mirror of
// `orphanedDestinations` in StartupSweepTests: same table dump, opposite question.

import XCTest
import Darwin
@testable import VPNBypassCore

@MainActor
final class MissingRouteReconcileTests: XCTestCase {

    private func kr(_ dest: UInt32, prefix: Int? = nil, ours: Bool, gw: UInt32 = 0xC0A80101) -> RouteKernel.KernelRoute {
        RouteKernel.KernelRoute(destination: dest, prefix: prefix, gatewayAddress: gw,
                                gatewayInterfaceIndex: nil,
                                flags: RTF_UP | RTF_STATIC | (ours ? RTF_PROTO1 : 0))
    }

    /// The reported scenario: the primary physical interface changed, the kernel took its routes
    /// with it, and the app still wants them. Every wanted destination absent from the table must
    /// be reported so the reconcile can put it back.
    func testRoutesPurgedByAPathChangeAreReportedMissing() {
        // 203.0.113.1 survived; .2 and .3 went with the old interface.
        let table = [kr(0xCB007101, ours: true)]
        let missing = RouteManager.missingDestinations(
            table: table, desired: ["203.0.113.1", "203.0.113.2", "203.0.113.3"]
        )
        XCTAssertEqual(missing, ["203.0.113.2", "203.0.113.3"],
                       "a wanted destination with no route at all is the failure being fixed")
    }

    /// Nothing to do when the table already holds everything wanted — the common case on every
    /// 30s tick, and it must cost zero writes.
    func testNothingIsMissingWhenTheTableIsComplete() {
        let table = [kr(0xCB007101, ours: true), kr(0x0A000000, prefix: 8, ours: true)]
        XCTAssertTrue(RouteManager.missingDestinations(
            table: table, desired: ["203.0.113.1", "10.0.0.0/8"]
        ).isEmpty)
    }

    /// Presence is destination-only, NOT tag-gated, and this pins why. The helper skips the write
    /// when a correct route already exists, leaving that destination untagged while the app still
    /// lists it active. Requiring RTF_PROTO1 would report it missing on every pass, restore it as
    /// a no-op, and repeat every 30 seconds forever.
    func testAnUntaggedRouteCountsAsPresentSoTheReconcileCannotLoop() {
        let table = [kr(0xCB007101, ours: false)]
        XCTAssertTrue(RouteManager.missingDestinations(table: table, desired: ["203.0.113.1"]).isEmpty,
                      "an untagged route at the destination must not be restored on a loop")
    }

    /// Network routes are matched on their CIDR string, exactly as the table renders them, so a
    /// prefix route is not confused with the bare host address at the same network address.
    func testNetworkAndHostRoutesAreMatchedSeparately() {
        let table = [kr(0x0A000000, prefix: 8, ours: true)]   // 10.0.0.0/8 present
        XCTAssertEqual(
            RouteManager.missingDestinations(table: table, desired: ["10.0.0.0/8", "10.0.0.0"]),
            ["10.0.0.0"],
            "the /8 is present; the host route at the same address is not"
        )
    }

    /// An empty desired set can never produce work, whatever the table holds — the app has
    /// nothing installed, so nothing was dropped.
    func testEmptyDesiredSetYieldsNothing() {
        XCTAssertTrue(RouteManager.missingDestinations(
            table: [kr(0xCB007101, ours: true)], desired: []
        ).isEmpty)
        XCTAssertTrue(RouteManager.missingDestinations(table: [], desired: []).isEmpty)
    }

    /// Output is sorted, so a log line and a batch are stable between passes rather than
    /// reordering with Set iteration.
    func testMissingDestinationsAreOrderedDeterministically() {
        let desired: Set<String> = ["203.0.113.9", "203.0.113.1", "203.0.113.5"]
        let first = RouteManager.missingDestinations(table: [], desired: desired)
        XCTAssertEqual(first, ["203.0.113.1", "203.0.113.5", "203.0.113.9"])
        XCTAssertEqual(RouteManager.missingDestinations(table: [], desired: desired), first)
    }
}
