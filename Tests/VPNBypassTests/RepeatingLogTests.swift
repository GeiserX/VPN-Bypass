// RepeatingLogTests.swift
// With no VPN connected, every 30 s status pass logged "VPN candidates (none matched): …" and
// "VPN process hint: …". With 200 lines kept, that pushed everything useful out in about 50
// minutes. Those lines are now logged only when they change.

import XCTest
@testable import VPNBypassCore

@MainActor
final class RepeatingLogTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    private func count(_ prefix: String, since start: Date) -> Int {
        rm.recentLogs.filter { $0.timestamp >= start && $0.message.hasPrefix(prefix) }.count
    }

    override func setUp() async throws {
        // A line an earlier test left behind would hide the first one here.
        rm.logWhenChanged(.processHint, nil)
        rm.logWhenChanged(.unmatchedCandidates, nil)
    }

    func testTheSameLineIsLoggedOnce() {
        let start = Date()
        for _ in 0..<5 {
            rm.logWhenChanged(.unmatchedCandidates, "VPN candidates (none matched): utun10 up=true corp=false tailscale=false")
        }
        XCTAssertEqual(count("VPN candidates (none matched)", since: start), 1)
    }

    func testAChangedLineIsLoggedAgain() {
        let start = Date()
        rm.logWhenChanged(.unmatchedCandidates, "VPN candidates (none matched): utun10 up=true corp=false tailscale=false")
        rm.logWhenChanged(.unmatchedCandidates, "VPN candidates (none matched): utun10 up=false corp=false tailscale=false")
        XCTAssertEqual(count("VPN candidates (none matched)", since: start), 2)
    }

    /// Nil ends the run: a VPN matched, or the client quit. The same line then logs again.
    func testALineLogsAgainAfterItsConditionEnded() {
        let start = Date()
        rm.logWhenChanged(.processHint, "VPN process hint: GlobalProtect")
        rm.logWhenChanged(.processHint, nil)
        rm.logWhenChanged(.processHint, "VPN process hint: GlobalProtect")
        XCTAssertEqual(count("VPN process hint", since: start), 2)
    }

    func testTheTwoLinesAreTrackedApart() {
        let start = Date()
        rm.logWhenChanged(.processHint, "VPN process hint: GlobalProtect")
        rm.logWhenChanged(.unmatchedCandidates, "VPN candidates (none matched): utun10 up=true corp=false tailscale=false")
        rm.logWhenChanged(.processHint, "VPN process hint: GlobalProtect")
        XCTAssertEqual(count("VPN process hint", since: start), 1)
        XCTAssertEqual(count("VPN candidates (none matched)", since: start), 1)
    }

    /// The real detection, run as the status timer runs it, on this Mac's own interfaces.
    /// macOS keeps utun interfaces up for its own services, so with no VPN connected the
    /// candidates line comes on the first pass; the next passes must not repeat it.
    func testRepeatedDetectionPassesDoNotRepeatTheirLines() async throws {
        let start = Date()
        for _ in 0..<3 { await rm.detectVPNStateOnly() }
        let candidates = count("VPN candidates (none matched)", since: start)
        let hints = count("VPN process hint", since: start)
        XCTAssertLessThanOrEqual(candidates, 1, "the candidates line repeated on every pass")
        XCTAssertLessThanOrEqual(hints, 1, "the process hint repeated on every pass")
        if candidates == 0 && hints == 0 {
            throw XCTSkip("this Mac logged neither line, so the passes prove nothing here")
        }
    }
}
