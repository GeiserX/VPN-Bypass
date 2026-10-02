// TestPortsTests.swift
// TestPorts is what keeps the socket tests off ports they can collide on, so its two
// refusals are checked here: a port a listener holds, and a port a closed connection
// left in TIME_WAIT, the case that hung the proxy tests.

import Darwin
import XCTest

final class TestPortsTests: XCTestCase {

    func testRefusesAPortAListenerHolds() throws {
        let port = TestPorts.nextListenPort().rawValue
        let fd = try listenOnLoopback(port: port)
        XCTAssertFalse(TestPorts.canBindLoopback(port: port), "port \(port) is held by a listener")
        close(fd)
        XCTAssertTrue(TestPorts.canBindLoopback(port: port), "port \(port) is free once the listener closes")
    }

    /// The listener side closes first, so the TIME_WAIT sits on the listener's port, as it
    /// did after every proxy test. A listener later bound there and dialled from the
    /// earlier client's port is the pair that failed connect() with EADDRINUSE.
    func testRefusesAPortLeftInTimeWait() throws {
        let port = TestPorts.nextListenPort().rawValue
        let listener = try listenOnLoopback(port: port)
        // Each step throws on failure, so accept() never blocks waiting for a client
        // that did not connect.
        let client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard client >= 0 else {
            let err = errno
            close(listener)
            throw SocketError(call: "socket", errno: err)
        }
        var addr = loopback(port: port)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let err = errno
            close(client); close(listener)
            throw SocketError(call: "connect to \(port)", errno: err)
        }
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else {
            let err = errno
            close(client); close(listener)
            throw SocketError(call: "accept on \(port)", errno: err)
        }
        close(accepted)
        close(listener)
        close(client)

        XCTAssertFalse(TestPorts.canBindLoopback(port: port),
                       "port \(port) still has a TIME_WAIT and must not be handed out")
    }

    func testHandsOutPortsBelowTheEphemeralRangeOnceEach() {
        var ephemeralFirst: Int32 = 0
        var size = MemoryLayout<Int32>.size
        XCTAssertEqual(sysctlbyname("net.inet.ip.portrange.first", &ephemeralFirst, &size, nil, 0), 0)
        var seen = Set<UInt16>()
        for _ in 0..<200 {
            let port = TestPorts.nextListenPort().rawValue
            XCTAssertTrue((20_000...48_999).contains(port), "port \(port) outside 20000-48999")
            XCTAssertLessThan(Int32(port), ephemeralFirst, "port \(port) shares the client source-port range")
            XCTAssertTrue(seen.insert(port).inserted, "port \(port) handed out twice")
        }
    }

    // MARK: - Plain BSD sockets, so nothing here depends on Network.framework timing

    private func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }

    private func listenOnLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError(call: "socket", errno: errno) }
        var addr = loopback(port: port)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let err = errno
            close(fd)
            throw SocketError(call: "bind/listen on \(port)", errno: err)
        }
        return fd
    }

    private struct SocketError: Error { let call: String; let errno: Int32 }
}
