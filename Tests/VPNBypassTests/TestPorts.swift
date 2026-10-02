// TestPorts.swift
// Loopback ports for every test that opens a TCP listener a client then dials.

import Darwin
import Foundation
import Network

enum TestPorts {

    /// A loopback port for one listener: below the ephemeral range, never handed out twice
    /// in a run, and free right now.
    ///
    /// Port 0 made the proxy tests flaky. A port 0 listener gets its port from the ephemeral
    /// range (49152-65535), the same range client sockets take their source ports from.
    /// Every test leaves a TIME_WAIT on its 127.0.0.1 listener/client port pair for 30 s.
    /// Once in a while a later test drew the same pair again. In every case caught it was
    /// reversed: its listener on an earlier client's port, its client on that earlier
    /// listener's port.
    /// connect() then fails with EADDRINUSE, NWConnection waits in `.waiting` without
    /// retrying, and the test runs out its 5 s timeout. A fresh connection does not get
    /// out of it: on macOS it was handed the same source port again.
    ///
    /// A fixed port fails the other way: the test breaks whenever anything else on the
    /// machine holds it, and route listeners fall back to port 0 when their port is taken.
    ///
    /// Production never mixes the two ranges (route listeners use 18000-18999), and the
    /// tests do not either: ports come from 20000-48999, each one once per run, and each is
    /// bound first without SO_REUSEADDR, which also refuses a port that still has a
    /// TIME_WAIT on it.
    static func nextListenPort() -> NWEndpoint.Port {
        lock.lock(); defer { lock.unlock() }
        for _ in 0..<span {
            let candidate = cursor
            cursor = cursor >= first + span - 1 ? first : cursor + 1
            if canBindLoopback(port: candidate) { return NWEndpoint.Port(rawValue: candidate)! }
        }
        fatalError("no free loopback port in \(first)..<\(first + span)")
    }

    static let first: UInt16 = 20_000
    static let span: UInt16 = 29_000          // 20000...48999
    private static let lock = NSLock()
    private static var cursor: UInt16 = first + UInt16.random(in: 0..<span)

    /// Plain BSD bind on 127.0.0.1:port with no SO_REUSEADDR, closed straight away.
    static func canBindLoopback(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
