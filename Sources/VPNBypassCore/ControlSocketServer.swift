// ControlSocketServer.swift
// The transport layer for the scripting/control surface (multi-route P1 — see
// docs/MULTI-ROUTE-DESIGN.md, "Scripting / automation surface"). A user-only
// UNIX-domain socket server that frames newline-delimited JSON requests and
// delegates ALL command logic to an injected handler closure.
//
// RouteManager-FREE and I/O-generic by design: this file knows nothing about
// routes, rules, or CommandRouter — it only frames bytes and calls `handler`.
// That keeps it unit-testable with a stub (see ControlSocketServerTests) and
// keeps the privilege/locking story owned entirely by whatever wires the real
// handler up later (CommandRouter.apply + RouteManager, on @MainActor).
//
// Raw POSIX sockets, not Network.framework: NWListener's AF_UNIX support
// (NWEndpoint.unix) has proven unreliable in practice, so this talks to the
// BSD socket API directly (socket/bind/listen/accept/read/write) — the same
// layer XPC and every other UNIX-domain server ultimately sits on.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class ControlSocketServer {

    /// Maps one decoded request to a response. Runs on whatever executor the
    /// caller chooses (e.g. @MainActor, to serialize with RouteManager) — the
    /// server just `await`s it once per request line.
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public enum ServerError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case systemError(String)

        public var description: String {
            switch self {
            case .pathTooLong(let path):
                return "control socket path too long for sun_path (max ~104 bytes): \(path)"
            case .systemError(let message):
                return message
            }
        }
    }

    private let socketPath: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.vpnbypass.controlsocket.accept", qos: .userInitiated)

    /// Guards `listenFD`/`isRunning`, written from the caller's thread
    /// (start/stop). The accept loop only ever touches its own captured local
    /// copy of the fd, so it never needs this lock.
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning = false

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// `~/Library/Application Support/VPNBypass/control.sock`. Creates the
    /// containing directory (owner-only, 0700) if it doesn't exist yet.
    public static func defaultSocketPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VPNBypass", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir.appendingPathComponent("control.sock").path
    }

    // MARK: - Lifecycle

    /// Creates, binds, chmods, and listens on the UNIX socket, then starts the
    /// accept loop on a background queue. Idempotent: a second call while
    /// already running is a no-op.
    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }

        // Defensive: create the parent directory even if the caller passed a
        // custom path rather than defaultSocketPath(). Owner-only.
        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        // A stale socket file from a previous crashed run must not block bind().
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.systemError("socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr: sockaddr_un
        do {
            addr = try Self.makeSockaddrUn(path: socketPath)
        } catch {
            close(fd)
            throw error
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { rawAddr in
            rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw ServerError.systemError("bind() failed: \(String(cString: strerror(err)))")
        }

        // SECURITY (mandatory): owner-only, set immediately after bind, before
        // listen. No TCP, ever — the socket file's 0600/dir 0700 permissions
        // plus the per-connection uid check in acceptLoop() are the entire
        // auth model, since this control surface can reconfigure routing.
        guard chmod(socketPath, 0o600) == 0 else {
            let err = errno
            close(fd)
            unlink(socketPath)
            throw ServerError.systemError("chmod() failed: \(String(cString: strerror(err)))")
        }

        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            unlink(socketPath)
            throw ServerError.systemError("listen() failed: \(String(cString: strerror(err)))")
        }

        listenFD = fd
        isRunning = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
    }

    /// Stops accepting new connections and removes the socket file. Safe to
    /// call more than once, or before start(). Does not forcibly close
    /// connections already in flight; each finishes its current read/write
    /// and exits on its own once it hits EOF or a write error.
    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning else { return }
        isRunning = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Accept loop

    private func acceptLoop(listenFD: Int32) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                let err = errno
                // stop() closed the listening fd out from under us — exit quietly.
                if err == EBADF || err == EINVAL {
                    return
                }
                if err == EINTR {
                    continue
                }
                // Unexpected but non-fatal accept() error — keep serving.
                continue
            }

            // SECURITY (mandatory, defense in depth beyond the 0600 socket file
            // / 0700 directory perms): reject any peer that isn't the same
            // local user, before reading a single byte from it.
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                close(clientFD)
                continue
            }

            // Darwin has no MSG_NOSIGNAL; without SO_NOSIGPIPE, a client that
            // disconnects mid-write delivers SIGPIPE to this process, which
            // terminates it by default. This runs embedded in the menu-bar
            // app, so a CLI client going away must not crash the whole app.
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            // Each connection gets its own queue so one slow/idle client can't
            // stall the accept loop or other connections.
            let connectionQueue = DispatchQueue(label: "com.vpnbypass.controlsocket.connection")
            connectionQueue.async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    // MARK: - Per-connection framing

    /// Reads newline-delimited JSON requests until EOF/error. Processes one
    /// request at a time — the next line isn't read until the handler for the
    /// current one has returned — so responses on this connection can never
    /// interleave. Never logs or prints a request body; `secrets` may be in it.
    private func handleConnection(fd: Int32) {
        defer { close(fd) }

        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, chunkSize)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 {
                return  // EOF: client closed its write side.
            }
            buffer.append(contentsOf: chunk[0..<n])

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)

                let response = processLine(lineData)
                guard let responseData = try? JSONEncoder().encode(response) else {
                    continue  // Should be unreachable; never crash the server over it.
                }
                var out = responseData
                out.append(0x0A)
                if !writeAll(fd: fd, data: out) {
                    return  // Peer gone — stop servicing this connection.
                }
            }
        }
    }

    /// Decodes one line and awaits the handler synchronously from this
    /// (non-async) read-loop thread via a semaphore-gated Task, so the next
    /// line's decode/handler never starts until this one's response is ready.
    /// A malformed line gets a `bad_request` error, and the connection is
    /// KEPT OPEN — a scripted client can retry on the same pipe instead of
    /// having to reconnect after one bad line.
    private func processLine(_ lineData: Data) -> ControlResponse {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: lineData) else {
            return ControlResponse(ok: false, error: ControlError(code: "bad_request", message: "malformed JSON"))
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let handler = self.handler
        Task {
            box.response = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()
        return box.response ?? ControlResponse(ok: false, error: ControlError(code: "internal_error", message: "handler did not return a response"))
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, remaining.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            remaining.removeFirst(n)
        }
        return true
    }

    // MARK: - sockaddr_un construction

    private static func makeSockaddrUn(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        // Reserve one byte for the NUL terminator.
        guard bytes.count < maxLen else {
            throw ServerError.pathTooLong(path)
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            buf.initialize(repeating: 0)
            for (i, byte) in bytes.enumerated() {
                buf[i] = byte
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}

/// A single-slot box to hand an async handler's result back to the blocking
/// read-loop thread. `@unchecked Sendable`: `response` is written exactly
/// once (inside the Task, before `semaphore.signal()`) and read exactly once
/// (after `semaphore.wait()` returns on the caller side), so the semaphore
/// itself is the synchronization — mirrors `OnceGate` in HelperManager.swift.
private final class ResponseBox: @unchecked Sendable {
    var response: ControlResponse?
}
