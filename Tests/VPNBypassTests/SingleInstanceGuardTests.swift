// SingleInstanceGuardTests.swift
// Coverage for the single-instance flock guard (VPN-Bypass-3sc.1).
// The duplicate-instance route churn it prevents was the root cause of the
// GlobalProtect tunnel teardown, so the lock contention must actually hold.

import XCTest
@testable import VPNBypassCore
import Foundation

final class SingleInstanceGuardTests: XCTestCase {

    private func makeTempLockPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpnbypass-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("instance.lock").path
    }

    /// The core guarantee: a second process (here, a second open file
    /// description) cannot take the lock while the first holds it, and the lock
    /// frees as soon as the first holder's descriptor closes.
    func testSecondHolderIsBlockedUntilFirstReleases() {
        let path = makeTempLockPath()

        // First holder acquires.
        let first = SingleInstanceGuard.tryLock(path: path)
        guard case .acquired(let fd1) = first else {
            return XCTFail("expected first tryLock to acquire, got \(first)")
        }
        XCTAssertGreaterThanOrEqual(fd1, 0)

        // Second attempt while the first descriptor is open is refused.
        XCTAssertEqual(SingleInstanceGuard.tryLock(path: path), .heldByOther)

        // Releasing the first holder frees the lock.
        close(fd1)

        // A fresh attempt can now acquire again.
        let third = SingleInstanceGuard.tryLock(path: path)
        guard case .acquired(let fd3) = third else {
            return XCTFail("expected re-acquire after release, got \(third)")
        }
        close(fd3)
    }

    /// acquire() on a usable, free path returns true and creates the lock dir.
    func testAcquireSucceedsOnFreePath() {
        let path = makeTempLockPath()
        let url = URL(fileURLWithPath: path)
        XCTAssertTrue(SingleInstanceGuard.acquire(at: url))
        // acquire() intentionally retains its fd for the process lifetime, so a
        // second same-path acquire() is not asserted here — tryLock contention
        // above already proves the mutual-exclusion semantics.
    }
}
