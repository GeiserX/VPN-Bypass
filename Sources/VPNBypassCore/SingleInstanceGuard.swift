// SingleInstanceGuard.swift
// Process-wide single-instance guard backed by an advisory flock() lock.
//
// Why this exists: two VPN Bypass processes mutating the kernel route table at
// the same time produce a burst of route add/delete churn. A full-tunnel
// corporate VPN (GlobalProtect) watches the routing socket and tears down its
// OWN tunnel when that churn saturates its change-detection window. The live
// incident that motivated this guard was a stale dev build launched alongside
// the installed app. LSMultipleInstancesProhibited in Info.plist stops a second
// LaunchServices `open`, but it does NOT stop a binary run directly — this lock
// does, covering every launch path.
//
// The lock is held for the lifetime of the process via a retained file
// descriptor and released automatically by the kernel when the process exits
// (even on crash). That is the key advantage over a pidfile: there is no stale
// lock to reap after an unclean exit.

import Foundation

enum SingleInstanceGuard {
    /// Retained for the process lifetime once acquired. The kernel drops the
    /// flock when this fd is closed at process exit. Never closed deliberately.
    private static var lockFD: Int32 = -1

    /// Default lock file — same directory as config.json.
    static var defaultLockURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VPNBypass/instance.lock")
    }

    /// Result of a low-level lock attempt.
    enum LockResult: Equatable {
        case acquired(fd: Int32)  // we now hold the lock
        case heldByOther          // another process holds it
        case openFailed           // could not open the lock file (caller should fail open)
    }

    /// Low-level, side-effect-light lock attempt against an explicit path.
    /// Exposed for tests; the app uses `acquire()`.
    static func tryLock(path: String) -> LockResult {
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return .openFailed }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return .heldByOther
        }
        return .acquired(fd: fd)
    }

    /// Attempt to become the sole instance.
    ///
    /// Returns `true` if this process now holds the lock (or fails open because
    /// the lock file is unusable — a missing lock must never brick the app), and
    /// `false` only when another live instance already holds it. On `false` the
    /// caller MUST exit without running normal quit cleanup, otherwise it would
    /// remove the routes owned by the instance that is actually running.
    @discardableResult
    static func acquire(at url: URL = defaultLockURL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        switch tryLock(path: url.path) {
        case .acquired(let fd):
            lockFD = fd  // retain for process lifetime
            return true
        case .heldByOther:
            return false
        case .openFailed:
            return true  // fail open
        }
    }
}
