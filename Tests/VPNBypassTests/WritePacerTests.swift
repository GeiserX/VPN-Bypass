// WritePacerTests.swift
// Coverage for the routing-socket write pacer (RouteKernel.WritePacer).
//
// Why this matters: every RTM write is broadcast to every open routing socket, and the kernel
// silently drops messages for a socket whose receive buffer is full. An uninterrupted batch of
// several hundred writes was observed swallowing the reply of GlobalProtect's concurrent
// gateway-route read — which it misreads as "my gateway route was removed" and tears the
// tunnel down. The pacer's contract: pause exactly at chunk boundaries within a burst, never
// for sparse interactive writes, and start a fresh chunk after an idle gap.

import XCTest
@testable import VPNBypassCore

final class WritePacerTests: XCTestCase {

    private let second: UInt64 = 1_000_000_000

    /// Within one dense burst, the pause must fire exactly every `chunkSize` writes —
    /// bounding any listener's backlog to one chunk.
    func testPausesExactlyAtChunkBoundaries() {
        var pacer = RouteKernel.WritePacer(chunkSize: 4)
        var pauses: [Int] = []
        for i in 1...12 {
            if pacer.recordWrite(nowNS: UInt64(i) * 1_000) { pauses.append(i) }
        }
        XCTAssertEqual(pauses, [4, 8, 12])
    }

    /// Sparse interactive operations (single route add from the UI) must never pause.
    func testSparseWritesNeverPause() {
        var pacer = RouteKernel.WritePacer(chunkSize: 4)
        for i in 1...10 {
            // Each write more than the idle-reset gap after the previous one.
            XCTAssertFalse(pacer.recordWrite(nowNS: UInt64(i) * 2 * second))
        }
    }

    /// An idle gap longer than the reset window starts a fresh chunk count: a new batch is a
    /// new burst, not a continuation of the last one.
    func testIdleGapResetsBurst() {
        var pacer = RouteKernel.WritePacer(chunkSize: 4)
        XCTAssertFalse(pacer.recordWrite(nowNS: 1_000))
        XCTAssertFalse(pacer.recordWrite(nowNS: 2_000))
        XCTAssertFalse(pacer.recordWrite(nowNS: 3_000))
        // Gap > 1s: the count restarts, so the next write is #1, not the pausing #4.
        let afterGap = 3_000 + 2 * second
        XCTAssertFalse(pacer.recordWrite(nowNS: afterGap))
        XCTAssertFalse(pacer.recordWrite(nowNS: afterGap + 1_000))
        XCTAssertFalse(pacer.recordWrite(nowNS: afterGap + 2_000))
        XCTAssertTrue(pacer.recordWrite(nowNS: afterGap + 3_000))
    }

    /// Defaults: a chunk stays well under one 8KB routing-socket receive buffer
    /// (~50 messages), and the pause is long enough to be a real drain window.
    func testDefaultsAreBufferSafe() {
        let pacer = RouteKernel.WritePacer()
        XCTAssertLessThanOrEqual(pacer.chunkSize, 40)
        XCTAssertGreaterThanOrEqual(pacer.pauseMicroseconds, 100_000)
    }
}
