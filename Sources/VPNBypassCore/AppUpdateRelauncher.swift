// AppUpdateRelauncher.swift
// Restarts the app when its bundle is replaced on disk.
//
// Why this exists: an update (Homebrew, or a new copy dragged over the old one) replaces the
// bundle while the old process keeps running the old code. Homebrew cannot reopen the app for
// us: it runs a cask's install steps in a sandbox that forbids launching apps (`deny lsopen`),
// so a cask that quits the app before an upgrade leaves it closed, with every route removed.
// The running app notices the replacement itself and restarts into the new copy.

import Foundation
import Security

enum AppUpdateRelauncher {
    /// What identifies a file on disk. A replaced file has another inode, even at the same path.
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    enum State: Equatable {
        /// The executable this process was launched from is still the one at its path.
        case unchanged
        /// Nothing is at the path: an update is in the middle of its move, or the app was removed.
        case missing
        /// Another executable is there, but the bundle around it is not whole yet.
        case incomplete
        /// Another, complete bundle is in place.
        case replaced
    }

    static func identity(ofFileAt path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    static func state(launched: FileIdentity, executablePath: String, bundleIsComplete: () -> Bool) -> State {
        guard let current = identity(ofFileAt: executablePath) else { return .missing }
        if current == launched { return .unchanged }
        return bundleIsComplete() ? .replaced : .incomplete
    }

    /// Whether the bundle passes its code signature check. The signature seals every file in the
    /// bundle, so a copy that is still being written fails, and the caller waits for the next look.
    static func bundleSignatureIsValid(atPath path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }

    /// The command that waits for `pid` to exit and then opens the bundle.
    ///
    /// It waits because a copy that starts while the old process still holds the single-instance
    /// lock exits at once (see SingleInstanceGuard), and quitting takes as long as removing the
    /// routes does. The wait is capped at two minutes, past the app's own quit deadline. The pid,
    /// the opener and the path are positional arguments, so the shell never interprets them.
    static func relaunchCommand(pid: Int32, bundlePath: String, opener: String = "/usr/bin/open") -> (executable: String, arguments: [String]) {
        let script = #"i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 240 ]; do /bin/sleep 0.5; i=$((i+1)); done; exec "$2" "$3""#
        return ("/bin/sh", ["-c", script, "sh", String(pid), opener, bundlePath])
    }
}
