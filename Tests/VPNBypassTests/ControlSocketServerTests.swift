// ControlSocketServerTests.swift
// End-to-end coverage for the control-socket transport layer using a STUB
// handler — no RouteManager/CommandRouter involved. This proves framing,
// permissions, and lifecycle in isolation from routing logic (VPN-Bypass
// scripting surface, see docs/MULTI-ROUTE-DESIGN.md § Scripting).

import XCTest
@testable import VPNBypassCore
#if canImport(Darwin)
import Darwin
#endif

final class ControlSocketServerTests: XCTestCase {

    private func tempSocketPath() -> String {
        NSTemporaryDirectory() + "vpnb-test-\(UUID().uuidString).sock"
    }

    /// Echoes `{ok:true, result.message:"pong"}` for cmd=="ping", an error otherwise.
    private func stubHandler() -> ControlSocketServer.Handler {
        { request in
            if request.cmd == "ping" {
                return ControlResponse(ok: true, result: ControlResult(message: "pong"))
            }
            return ControlResponse(ok: false, error: ControlError(code: "unknown_command", message: "unknown command: \(request.cmd)"))
        }
    }

    // MARK: - Raw POSIX client helpers
    //
    // This mirrors the sockaddr_un plumbing in ControlSocketServer.start() and
    // vpnb's own connect logic. It's intentionally re-implemented here rather
    // than shared: ControlSocketServer.makeSockaddrUn is `private` (module-
    // internal reuse isn't the point — the point is proving the WIRE PROTOCOL
    // a genuinely independent client sees, the same way vpnb, a different
    // SwiftPM target, will).

    private func connectClient(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            buf.initialize(repeating: 0)
            for (i, byte) in bytes.enumerated() {
                buf[i] = byte
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { rawAddr in
            rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }
        guard rc == 0 else {
            close(fd)
            return nil
        }

        // Bound every blocking read in these tests so a transport bug fails
        // fast with a clear timeout instead of hanging the suite.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // The server closes the connection after rejecting an oversized request;
        // a client still writing into that closed pipe would otherwise take a
        // SIGPIPE and kill the whole test runner. Suppress it like vpnb would.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func send(_ fd: Int32, _ text: String) {
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress, data.count)
        }
    }

    /// Writes every byte, looping over partial writes — needed for payloads
    /// larger than the socket send buffer (the oversized-line test).
    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }  // peer closed (server hit the cap) or error
                offset += n
            }
        }
    }

    private func readOneLine(_ fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer.subdata(in: buffer.startIndex..<idx), encoding: .utf8)
            }
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 { return nil }  // EOF, error, or the SO_RCVTIMEO above firing.
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    // MARK: - Round trip

    /// Same-uid connections succeeding is exactly what this proves: the test
    /// process connects to its own server, so getpeereid()'s uid check is
    /// exercised on the accept path (and passes) on every run. A REJECTED
    /// cross-uid connection isn't practically testable in-process — it would
    /// need a second real OS user — so that branch is covered by code
    /// inspection (ControlSocketServer.acceptLoop) rather than a unit test.
    func testPingRoundTrip() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: stubHandler())
        try server.start()
        defer { server.stop() }

        let expectation = expectation(description: "ping round trip")
        var response: ControlResponse?

        DispatchQueue.global().async {
            defer { expectation.fulfill() }
            guard let fd = self.connectClient(path: path) else { return }
            defer { close(fd) }
            self.send(fd, "{\"v\":1,\"cmd\":\"ping\"}\n")
            guard let line = self.readOneLine(fd) else { return }
            response = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(response?.ok, true)
        XCTAssertEqual(response?.result?.message, "pong")
    }

    func testUnknownCommandReturnsStructuredError() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: stubHandler())
        try server.start()
        defer { server.stop() }

        let expectation = expectation(description: "unknown command")
        var response: ControlResponse?

        DispatchQueue.global().async {
            defer { expectation.fulfill() }
            guard let fd = self.connectClient(path: path) else { return }
            defer { close(fd) }
            self.send(fd, "{\"v\":1,\"cmd\":\"nope\"}\n")
            guard let line = self.readOneLine(fd) else { return }
            response = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, "unknown_command")
    }

    /// Malformed JSON gets a bad_request error AND the connection is kept open
    /// (the design decision made in ControlSocketServer.processLine) — proven
    /// here by sending a valid "ping" right after and getting "pong" back on
    /// the SAME fd, with no reconnect.
    func testMalformedLineGetsBadRequestAndConnectionStaysOpen() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: stubHandler())
        try server.start()
        defer { server.stop() }

        let expectation = expectation(description: "malformed line then follow-up ping")
        var badRequest: ControlResponse?
        var followUp: ControlResponse?

        DispatchQueue.global().async {
            defer { expectation.fulfill() }
            guard let fd = self.connectClient(path: path) else { return }
            defer { close(fd) }

            self.send(fd, "{not valid json\n")
            if let line = self.readOneLine(fd) {
                badRequest = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
            }

            self.send(fd, "{\"v\":1,\"cmd\":\"ping\"}\n")
            if let line = self.readOneLine(fd) {
                followUp = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
            }
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(badRequest?.ok, false)
        XCTAssertEqual(badRequest?.error?.code, "bad_request")
        XCTAssertEqual(followUp?.ok, true, "connection must stay usable after a malformed line")
        XCTAssertEqual(followUp?.result?.message, "pong")
    }

    // MARK: - Permissions

    func testSocketFileHasOwnerOnlyPermissionsAfterStart() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: stubHandler())
        try server.start()
        defer { server.stop() }

        var st = stat()
        XCTAssertEqual(stat(path, &st), 0, "socket file should exist on disk after start()")
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "socket file must be owner-read-write-only (0600)")
    }

    // MARK: - Lifecycle

    func testStopRemovesSocketFile() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: stubHandler())
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "socket file should exist after start()")

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop() must unlink the socket path")
    }

    func testStopIsIdempotent() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: stubHandler())
        try server.start()
        server.stop()
        server.stop()  // must not crash or throw
    }

    func testStartThrowsForPathExceedingSunPathCapacity() {
        // sun_path is ~104 bytes on Darwin; this comfortably exceeds it.
        let tooLong = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        let server = ControlSocketServer(socketPath: tooLong, handler: stubHandler())
        XCTAssertThrowsError(try server.start()) { error in
            guard case ControlSocketServer.ServerError.pathTooLong = error else {
                XCTFail("expected ServerError.pathTooLong, got \(error)")
                return
            }
        }
    }

    // MARK: - defaultSocketPath()

    func testDefaultSocketPathShapeAndDirectoryCreation() {
        let path = ControlSocketServer.defaultSocketPath()
        XCTAssertTrue(path.hasSuffix("VPNBypass/control.sock"))

        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir), "defaultSocketPath() must create its parent directory")
    }

    // MARK: - Request-size cap

    /// A client that streams a huge request line and never sends a newline must
    /// not grow the server's read buffer without bound: past the 64 KiB cap the
    /// server answers `request_too_large` and closes the connection.
    func testOversizedRequestLineIsRejected() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: stubHandler())
        try server.start()
        defer { server.stop() }

        let expectation = expectation(description: "oversized line rejected")
        var response: ControlResponse?

        DispatchQueue.global().async {
            defer { expectation.fulfill() }
            guard let fd = self.connectClient(path: path) else { return }
            defer { close(fd) }

            // Well past the 64 KiB cap, with NO newline — a single unframed line.
            let flood = [UInt8](repeating: UInt8(ascii: "x"), count: 70 * 1024)
            self.sendAll(fd, flood)

            guard let line = self.readOneLine(fd) else { return }
            response = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, "request_too_large")
    }

    // MARK: - Handler wait policy (read vs mutating)

    /// A handler that answers `{ok:true, result.message:"done:<cmd>"}` only after
    /// sleeping — lets a test make the handler outlast the read-path timeout.
    private func delayingHandler(seconds: Double) -> ControlSocketServer.Handler {
        { request in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ControlResponse(ok: true, result: ControlResult(message: "done:\(request.cmd)"))
        }
    }

    /// A MUTATING command must never be answered with `timeout` while its handler
    /// can still commit the mutation afterward. The handler here runs far longer
    /// than the (tiny) read-path timeout; because `route.add` is mutating, the
    /// server waits for the real result instead of racing the timeout — so a
    /// client can't see `timeout`, retry, and cause a phantom double-apply.
    func testMutatingCommandWaitsForCompletionInsteadOfTimingOut() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: delayingHandler(seconds: 0.5), handlerTimeout: 0.05)
        try server.start()
        defer { server.stop() }

        let expectation = expectation(description: "mutating command awaits real completion")
        var response: ControlResponse?

        DispatchQueue.global().async {
            defer { expectation.fulfill() }
            guard let fd = self.connectClient(path: path) else { return }
            defer { close(fd) }
            self.send(fd, "{\"v\":1,\"cmd\":\"route.add\"}\n")
            guard let line = self.readOneLine(fd) else { return }
            response = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(response?.ok, true, "mutating command must return the handler's real result, not a timeout")
        XCTAssertNil(response?.error, "mutating command must not report a timeout error")
        XCTAssertEqual(response?.result?.message, "done:route.add")
    }

    /// Read (non-mutating) commands keep the bounded timeout: a wedged handler
    /// must not hang `vpnb` forever. `status` is a read verb, so a handler slower
    /// than the timeout yields a structured `timeout` error.
    func testReadCommandStillTimesOutWhenHandlerWedges() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path, handler: delayingHandler(seconds: 2.0), handlerTimeout: 0.2)
        try server.start()
        defer { server.stop() }

        let expectation = expectation(description: "read command times out")
        var response: ControlResponse?

        DispatchQueue.global().async {
            defer { expectation.fulfill() }
            guard let fd = self.connectClient(path: path) else { return }
            defer { close(fd) }
            self.send(fd, "{\"v\":1,\"cmd\":\"status\"}\n")
            guard let line = self.readOneLine(fd) else { return }
            response = try? JSONDecoder().decode(ControlResponse.self, from: Data(line.utf8))
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.error?.code, "timeout")
    }
}
