// ProxyForwarder.swift
// Per-route local chaining HTTP proxy (P1, VPN-Bypass-3sc.8).
//
// A ProxyForwarder listens on 127.0.0.1:<port> — the address an app points its
// HTTPS_PROXY at (see HookGenerator). Each client connection is tunnelled through
// an UPSTREAM HTTP proxy (e.g. Oxylabs `disp.oxylabs.io:8001`): we inject the
// route's HTTP Basic auth and, crucially, bind the upstream socket to a chosen
// physical interface (e.g. en0) so that hop leaves the box on real Wi-Fi/Ethernet
// instead of the full-tunnel VPN's utun. TLS is never terminated here — for a
// CONNECT request the client's TLS session tunnels end-to-end through both proxies,
// so this process only shuffles opaque bytes and never sees plaintext.
//
// This is a plain `final class` (NOT @MainActor): all Network.framework callbacks
// run on a private serial queue, and a manager owns the instance from the main
// thread via the thread-safe `start()`/`stop()`/`boundPort` surface.

import Foundation
import Network

final class ProxyForwarder {

    /// Description of the upstream proxy a route chains through.
    struct Upstream {
        let host: String
        let port: UInt16
        let username: String        // already template-expanded; may be ""
        let password: String        // may be ""
        let boundInterface: String? // e.g. "en0"; nil = no binding (loopback/tests)
    }

    enum ProxyForwarderError: Error {
        /// The listener never reached `.ready` within the start timeout.
        case startTimedOut
    }

    let listenPort: UInt16

    private let upstream: Upstream

    // All listener/connection mutation happens on this serial queue, so the live
    // state below (listener, activeTunnels) needs no extra locking once started.
    private let queue = DispatchQueue(label: "com.vpnbypass.proxy", qos: .userInitiated)

    private var listener: NWListener?
    private var activeTunnels: [Tunnel] = []

    // The named interface resolved to a concrete NWInterface once at start; nil when
    // no binding was requested or the interface wasn't found (binding is best-effort).
    private var resolvedInterface: NWInterface?

    // `boundPort` is read from arbitrary threads (e.g. the main thread, right after
    // start()), while it is written once on the queue when the listener goes ready.
    private let portLock = NSLock()
    private var _boundPort: UInt16?
    private var pendingStartError: Error?

    private static let startTimeout: TimeInterval = 5.0

    init(listenPort: UInt16, upstream: Upstream) {
        self.listenPort = listenPort
        self.upstream = upstream
    }

    /// Actual bound port — equals `listenPort` unless that was 0, in which case it is
    /// the OS-assigned port. Valid once `start()` has returned successfully.
    var boundPort: UInt16? {
        portLock.lock(); defer { portLock.unlock() }
        return _boundPort
    }

    // MARK: - Lifecycle

    /// Bind an NWListener to 127.0.0.1:listenPort and begin accepting clients. Blocks
    /// until the listener is ready (so `boundPort` is populated) or throws on failure.
    func start() throws {
        // Resolve the bind interface once up front (best-effort, never fatal). Only
        // hits the network when a route actually requests interface binding, so tests
        // with `boundInterface == nil` never block here.
        if let interfaceName = upstream.boundInterface {
            resolvedInterface = Self.resolveInterface(named: interfaceName)
        }

        let parameters = NWParameters.tcp
        // Pin the listener to the loopback address so the proxy is never reachable
        // off-box; a 0 / `.any` port lets the OS assign one, surfaced via `port`.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: listenPort) ?? .any
        )

        let listener = try NWListener(using: parameters)
        self.listener = listener

        // Hand the bound port (or failure) back to the calling thread synchronously.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let port = self.listener?.port?.rawValue { self.setBoundPort(port) }
                ready.signal()
            case .failed(let error):
                self.setPendingStartError(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + Self.startTimeout) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw ProxyForwarderError.startTimedOut
        }
        if let error = takePendingStartError() {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    /// Cancel the listener and tear down every live tunnel.
    func stop() {
        // Hop onto the queue so we read/mutate listener + tunnels on their owning
        // thread. Safe to call from the main thread and idempotent.
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            let tunnels = self.activeTunnels
            self.activeTunnels.removeAll()
            tunnels.forEach { $0.cancel() }
        }
    }

    // MARK: - Connection acceptance

    private func accept(_ connection: NWConnection) {
        // Runs on `queue` (the listener's queue), so touching activeTunnels is safe.
        let tunnel = Tunnel(client: connection,
                            upstream: upstream,
                            boundInterface: resolvedInterface,
                            queue: queue)
        activeTunnels.append(tunnel)
        tunnel.onDone = { [weak self, weak tunnel] in
            guard let self = self, let tunnel = tunnel else { return }
            self.activeTunnels.removeAll { $0 === tunnel }
        }
        tunnel.start()
    }

    // MARK: - Thread-safe state helpers

    private func setBoundPort(_ port: UInt16) {
        portLock.lock(); _boundPort = port; portLock.unlock()
    }

    private func setPendingStartError(_ error: Error) {
        portLock.lock(); pendingStartError = error; portLock.unlock()
    }

    private func takePendingStartError() -> Error? {
        portLock.lock(); defer { pendingStartError = nil; portLock.unlock() }
        return pendingStartError
    }

    // MARK: - Interface resolution

    /// Best-effort lookup of an NWInterface by BSD name (e.g. "en0"). NWInterface
    /// objects can only be obtained from a path, so we briefly run an NWPathMonitor
    /// and grab the first path it reports. Returns nil (→ no binding) if the name
    /// isn't present or no path arrives in time — binding must never be fatal.
    private static func resolveInterface(named name: String) -> NWInterface? {
        let monitor = NWPathMonitor()
        let monitorQueue = DispatchQueue(label: "com.vpnbypass.proxy.ifresolve")
        let done = DispatchSemaphore(value: 0)
        var found: NWInterface?
        var signaled = false
        monitor.pathUpdateHandler = { path in
            guard !signaled else { return }   // only the first path matters
            signaled = true
            found = path.availableInterfaces.first { $0.name == name }
            done.signal()
        }
        monitor.start(queue: monitorQueue)
        _ = done.wait(timeout: .now() + 2.0)
        monitor.cancel()
        return found
    }
}

// MARK: - Tunnel

/// One client↔upstream pairing. Owns both NWConnections, performs the CONNECT
/// handshake against the upstream proxy, then relays bytes verbatim in both
/// directions until either side closes. Every callback below is delivered on the
/// forwarder's queue, so the mutable state here is single-threaded by construction.
private final class Tunnel {

    private let client: NWConnection
    private let upstream: ProxyForwarder.Upstream
    private let boundInterface: NWInterface?
    private let queue: DispatchQueue

    private var server: NWConnection?

    // Raw bytes accumulated while we wait for the end of a request/response header.
    private var clientBuffer = Data()
    private var upstreamBuffer = Data()
    // Bytes the client sent after its request head (e.g. an early TLS ClientHello)
    // that must be replayed to the upstream once the tunnel opens.
    private var clientLeftover = Data()

    private var finished = false

    /// Called once when the tunnel is fully torn down so the owner can drop it.
    var onDone: (() -> Void)?

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)
    private static let maxHeaderBytes = 64 * 1024
    private static let relayChunk = 65_536

    init(client: NWConnection,
         upstream: ProxyForwarder.Upstream,
         boundInterface: NWInterface?,
         queue: DispatchQueue) {
        self.client = client
        self.upstream = upstream
        self.boundInterface = boundInterface
        self.queue = queue
    }

    // MARK: Start / teardown

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
        client.start(queue: queue)
        readClientHeader()
    }

    /// Idempotent teardown: cancel both sockets and notify the owner exactly once.
    func cancel() {
        if finished { return }
        finished = true
        client.cancel()
        server?.cancel()
        onDone?()
    }

    // MARK: Read the client's request head

    private func readClientHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.cancel(); return }
            if let data = data, !data.isEmpty { self.clientBuffer.append(data) }

            if let range = self.clientBuffer.range(of: Self.headerTerminator) {
                let head = self.clientBuffer.subdata(in: self.clientBuffer.startIndex..<range.upperBound)
                let leftover = self.clientBuffer.subdata(in: range.upperBound..<self.clientBuffer.endIndex)
                self.processClientHead(head, leftover: leftover)
                return
            }
            if self.clientBuffer.count > Self.maxHeaderBytes { self.sendClient400(); return }
            if isComplete { self.cancel(); return }
            self.readClientHeader()
        }
    }

    private func processClientHead(_ head: Data, leftover: Data) {
        guard let headString = String(data: head, encoding: .utf8) else { sendClient400(); return }
        let requestLine = headString.components(separatedBy: "\r\n").first ?? ""
        let tokens = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { sendClient400(); return }

        let method = tokens[0].uppercased()
        let target = tokens[1]
        if method == "CONNECT" {
            handleConnect(authority: target, leftover: leftover)
        } else {
            handlePlain(head: head, leftover: leftover)
        }
    }

    // MARK: CONNECT tunnelling (the required path)

    private func handleConnect(authority: String, leftover: Data) {
        guard isValidAuthority(authority), let server = makeServerConnection() else {
            sendClient400(); return
        }
        clientLeftover = leftover
        self.server = server
        server.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // Ask the upstream proxy to open a raw tunnel to the target, carrying
                // the route's Basic auth; then read its response to that CONNECT.
                self.send(self.connectRequest(authority: authority), on: server) { [weak self] in
                    self?.readUpstreamConnectResponse()
                }
            case .failed, .cancelled:
                self.cancel()
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    private func readUpstreamConnectResponse() {
        guard let server = server else { cancel(); return }
        server.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.cancel(); return }
            if let data = data, !data.isEmpty { self.upstreamBuffer.append(data) }

            if let range = self.upstreamBuffer.range(of: Self.headerTerminator) {
                self.finishConnectHandshake(headerEnd: range.upperBound)
                return
            }
            if self.upstreamBuffer.count > Self.maxHeaderBytes { self.cancel(); return }
            if isComplete { self.cancel(); return }
            self.readUpstreamConnectResponse()
        }
    }

    private func finishConnectHandshake(headerEnd: Data.Index) {
        let header = upstreamBuffer.subdata(in: upstreamBuffer.startIndex..<headerEnd)
        // Anything past the upstream's response headers is already tunnelled payload.
        let earlyTunnelData = upstreamBuffer.subdata(in: headerEnd..<upstreamBuffer.endIndex)

        let statusLine = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        // "HTTP/1.1 200 Connection established" → the status code is the 2nd token.
        let statusCode = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) }

        guard let statusCode = statusCode, (200...299).contains(statusCode) else {
            // Upstream refused the tunnel: pass its response straight back, then close.
            send(upstreamBuffer, on: client) { [weak self] in self?.cancel() }
            return
        }

        guard let server = server else { cancel(); return }
        // Tell the client the tunnel is open with our OWN clean 200 — we discard
        // whatever headers the upstream returned, as they are not part of the
        // end-to-end (client↔target) stream the client is about to speak over.
        send(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), on: client)
        // NWConnection preserves send ordering, so these land before any relayed
        // bytes: replay the client's early bytes upstream, and the upstream's early
        // payload (if any) down to the client.
        if !clientLeftover.isEmpty { send(clientLeftover, on: server) }
        if !earlyTunnelData.isEmpty { send(earlyTunnelData, on: client) }
        startRelay()
    }

    /// The CONNECT request line + headers we send to the upstream proxy. The Basic
    /// auth header is omitted entirely when no username is configured.
    private func connectRequest(authority: String) -> Data {
        var request = "CONNECT \(authority) HTTP/1.1\r\n"
        request += "Host: \(authority)\r\n"
        if !upstream.username.isEmpty {
            request += "Proxy-Authorization: Basic \(basicAuthToken())\r\n"
        }
        request += "Proxy-Connection: keep-alive\r\n"
        request += "\r\n"
        return Data(request.utf8)
    }

    // MARK: Plain (non-CONNECT) forwarding

    // The upstream is itself an HTTP proxy that accepts absolute-URI requests, so we
    // forward the original head verbatim with the Basic auth header injected after
    // the request line, then relay the response.
    private func handlePlain(head: Data, leftover: Data) {
        guard let server = makeServerConnection() else { cancel(); return }
        self.server = server
        let rewritten = injectProxyAuth(into: head)
        server.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.send(rewritten, on: server)
                if !leftover.isEmpty { self.send(leftover, on: server) }
                self.startRelay()
            case .failed, .cancelled:
                self.cancel()
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    private func injectProxyAuth(into head: Data) -> Data {
        guard !upstream.username.isEmpty, let lineEnd = head.range(of: Self.crlf) else { return head }
        var out = Data()
        out.append(head.subdata(in: head.startIndex..<lineEnd.upperBound))               // request line + CRLF
        out.append(Data("Proxy-Authorization: Basic \(basicAuthToken())\r\n".utf8))
        out.append(head.subdata(in: lineEnd.upperBound..<head.endIndex))                  // remaining headers
        return out
    }

    // MARK: Bidirectional relay

    private func startRelay() {
        guard let server = server else { cancel(); return }
        relay(from: client, to: server)
        relay(from: server, to: client)
    }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: Self.relayChunk) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.cancel(); return }

            if let data = data, !data.isEmpty {
                // Gate the next read on the write completing — natural backpressure so
                // we never buffer faster than the slow side can drain.
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self = self else { return }
                    if sendError != nil { self.cancel(); return }
                    if isComplete { self.cancel(); return }
                    self.relay(from: source, to: destination)
                })
            } else {
                if isComplete { self.cancel(); return }
                self.relay(from: source, to: destination)
            }
        }
    }

    // MARK: Helpers

    private func makeServerConnection() -> NWConnection? {
        guard let port = NWEndpoint.Port(rawValue: upstream.port) else { return nil }
        let parameters = NWParameters.tcp
        // Binding the upstream socket to a physical interface is what lets this hop
        // escape a full-tunnel VPN. If the interface wasn't resolved we simply don't
        // bind (the OS routes normally) rather than failing the connection.
        if let interface = boundInterface { parameters.requiredInterface = interface }
        return NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: parameters)
    }

    private func basicAuthToken() -> String {
        Data("\(upstream.username):\(upstream.password)".utf8).base64EncodedString()
    }

    private func isValidAuthority(_ authority: String) -> Bool {
        guard let colon = authority.lastIndex(of: ":") else { return false }
        let host = authority[..<colon]
        let portText = authority[authority.index(after: colon)...]
        return !host.isEmpty && UInt16(portText) != nil
    }

    private func send(_ data: Data, on connection: NWConnection, then: (() -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if error != nil { self.cancel(); return }
            then?()
        })
    }

    private func sendClient400() {
        send(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8), on: client) { [weak self] in self?.cancel() }
    }
}
