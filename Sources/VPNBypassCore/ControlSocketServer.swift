// ControlSocketServer.swift
// The transport layer for the scripting/control surface (multi-route P1 — see
// docs/MULTI-ROUTE-DESIGN.md, "Scripting / automation surface"). A user-only
// UNIX-domain socket server that frames newline-delimited JSON requests and
// delegates ALL command logic to an injected handler closure.
//
// RouteManager-FREE and I/O-generic by design: this file knows nothing about
// routes or rules — it only frames bytes and calls `handler`. Its one nod to
// command semantics is CommandRouter.isMutating(cmd), used purely to pick the
// per-verb wait policy (see processLine) so a mutating command is never
// answered with a premature `timeout`. That keeps it unit-testable with a stub
// (see ControlSocketServerTests) and keeps the privilege/locking story owned
// entirely by whatever wires the real handler up later (CommandRouter.apply +
// RouteManager, on @MainActor).
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

    /// How long a READ (non-mutating) request waits for the injected handler
    /// before giving up and returning a `timeout` error. Bounds a `vpnb`
    /// invocation's worst case if the (possibly @MainActor) handler wedges —
    /// e.g. stuck behind a slow synchronous operation on the main thread.
    /// MUTATING requests deliberately IGNORE this and wait for the handler's
    /// real completion (see processLine): answering a mutating command with
    /// `timeout` while its saveConfig + route reapply can still land later would
    /// race the client into a retry and a phantom double-apply, so we never do it.
    private let handlerTimeout: TimeInterval

    /// Default read-path timeout the public initializer uses. The
    /// timeout-taking initializer is a test seam so tests can exercise the
    /// read-path timeout without a 30s wait.
    private static let defaultHandlerTimeout: TimeInterval = 30

    /// Hard cap on a single un-framed request line. Control requests are tiny
    /// JSON lines; a client that never sends a newline (or floods one enormous
    /// line) must not grow the per-connection read buffer without bound. 64 KiB
    /// is orders of magnitude above any real request — on overflow the
    /// connection is answered with `request_too_large` and closed (the framing
    /// is broken, so the pipe can't be safely reused).
    private static let maxRequestLineBytes = 64 * 1024

    /// Backoff after an unexpected (non-EINTR/EBADF/EINVAL) accept() error,
    /// e.g. EMFILE/ENFILE under fd exhaustion — keeps the accept loop from
    /// tight-looping at 100% CPU retrying an error that won't clear instantly.
    private static let acceptErrorBackoffMicroseconds: useconds_t = 10_000

    /// Guards `listenFD`/`isRunning`, written from the caller's thread
    /// (start/stop). The accept loop only ever touches its own captured local
    /// copy of the fd, so it never needs this lock.
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning = false

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
        self.handlerTimeout = Self.defaultHandlerTimeout
    }

    /// Test seam (module-internal): identical to the public initializer but lets
    /// a test drive the read-path timeout directly instead of waiting the full
    /// default. Not part of the public API.
    init(socketPath: String, handler: @escaping Handler, handlerTimeout: TimeInterval) {
        self.socketPath = socketPath
        self.handler = handler
        self.handlerTimeout = handlerTimeout
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
                if err == EINTR {
                    continue   // interrupted syscall — retry immediately
                }
                // Decide whether to exit by STATE, not by errno. stop() closes
                // listenFD (and sets isRunning=false) out from under a blocked
                // accept(), which unblocks with EBADF/ECONNABORTED (and a recycled
                // fd may then surface ENOTSOCK). But those SAME errnos also occur
                // transiently on a HEALTHY server — most importantly ECONNABORTED,
                // the POSIX code for a client that aborts in the window before
                // accept() returns. Bucketing ECONNABORTED as a quiet exit would
                // let one aborted CLI connection kill the control server until the
                // app restarts. So the only reliable "we are shutting down" signal
                // is our own isRunning flag — check it instead of guessing.
                stateLock.lock()
                let stopping = !isRunning
                stateLock.unlock()
                if stopping {
                    return   // stop() asked us to exit; the fd is gone
                }
                // Still running: a transient accept() error (client abort before
                // accept, or fd exhaustion like EMFILE/ENFILE). Log, back off so we
                // don't tight-loop at 100% CPU, and keep serving.
                NSLog("VPNBypass: control socket accept() error: %@", String(cString: strerror(err)))
                usleep(Self.acceptErrorBackoffMicroseconds)
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

            // With every complete line drained above, whatever remains is a
            // single partial line still waiting for its newline. If that alone
            // blows past the cap, a client is flooding us without ever framing a
            // request — answer once with `request_too_large` and hang up rather
            // than letting the read buffer grow without bound.
            if buffer.count > Self.maxRequestLineBytes {
                let response = ControlResponse(ok: false, error: ControlError(code: "request_too_large", message: "request line exceeded \(Self.maxRequestLineBytes)-byte limit"))
                if let responseData = try? JSONEncoder().encode(response) {
                    var out = responseData
                    out.append(0x0A)
                    _ = writeAll(fd: fd, data: out)
                }
                return
            }
        }
    }

    /// Decodes one line and awaits the handler synchronously from this
    /// (non-async) read-loop thread via a semaphore-gated Task, so the next
    /// line's decode/handler never starts until this one's response is ready.
    /// A malformed line gets a `bad_request` error, and the connection is
    /// KEPT OPEN — a scripted client can retry on the same pipe instead of
    /// having to reconnect after one bad line.
    ///
    /// The wait policy depends on whether the verb mutates state:
    ///   - READ verbs (CommandRouter.isMutating == false) use a bounded wait:
    ///     if the (possibly @MainActor) handler wedges, a `vpnb` invocation
    ///     still gets an answer and exits rather than hanging forever. On
    ///     timeout the handler's eventual result — if it ever arrives — is
    ///     simply discarded; `box` isn't read again after this call returns.
    ///   - MUTATING verbs wait for the handler's ACTUAL completion, with no
    ///     timeout. Reporting `timeout` for a mutation that can still commit
    ///     later (saveConfig + reapply routes) would race the client into a
    ///     retry and a phantom double-apply (e.g. route.add appending a second
    ///     route on the retry). A truly wedged app therefore blocks just this
    ///     one CLI connection — strictly better than a duplicate mutation.
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
        // Mutating verbs must not race a premature timeout against a commit that
        // can still land (see the doc comment above): wait for real completion.
        // Read verbs keep the bounded wait so a stuck app can't hang `vpnb`.
        if CommandRouter.isMutating(request.cmd) {
            semaphore.wait()
        } else if semaphore.wait(timeout: .now() + handlerTimeout) != .success {
            return ControlResponse(ok: false, error: ControlError(code: "timeout", message: "handler did not respond in time"))
        }
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
/// once (inside the Task, before `semaphore.signal()`) and read at most once
/// (after a successful `semaphore.wait()` on the caller side — on a timeout
/// the caller returns without ever reading `response`, and a late write from
/// the still-running Task is simply discarded), so the semaphore itself is
/// the synchronization — mirrors `OnceGate` in HelperManager.swift.
private final class ResponseBox: @unchecked Sendable {
    var response: ControlResponse?
}
