// ProxyForwarder.swift
// Per-route local chaining proxy (P1, VPN-Bypass-3sc.8).
//
// A ProxyForwarder listens on 127.0.0.1:<port> — the address an app points its
// HTTPS_PROXY at (see HookGenerator). It always speaks HTTP to the LOCAL app (which
// issues a `CONNECT host:port`), but chains each connection through an UPSTREAM proxy
// that is EITHER an HTTP proxy (HTTP CONNECT) OR a SOCKS5 proxy (RFC 1928 `socks5h`,
// selected per route via `Upstream.isSOCKS5`) — e.g. a residential provider at
// `proxy.example.com:8001`. We inject the route's Basic / user-pass auth and, crucially,
// bind the upstream socket to a chosen physical interface (e.g. en0) so that hop leaves
// the box on real Wi-Fi/Ethernet instead of the full-tunnel VPN's utun. TLS is never
// terminated here — for a CONNECT the client's TLS session tunnels end-to-end through
// both proxies, so this process only shuffles opaque bytes and never sees plaintext.
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
        var isSOCKS5: Bool = false  // false → chain via HTTP CONNECT; true → SOCKS5 (RFC 1928) handshake
    }

    enum ProxyForwarderError: Error {
        /// The listener never reached `.ready` within the start timeout.
        case startTimedOut
    }

    let listenPort: UInt16

    // The upstream a NEW tunnel chains through. Mutable so a route can be re-pointed
    // live (e.g. switch a residential proxy's port to change the exit IP) WITHOUT tearing down the
    // listener — the local port (and any app's HTTPS_PROXY) stays put; only connections
    // accepted after the swap use the new exit. Confined to `queue` once started.
    private var upstream: Upstream

    // All listener/connection mutation happens on this serial queue, so the live
    // state below (listener, activeTunnels) needs no extra locking once started.
    private let queue = DispatchQueue(label: "com.vpnbypass.proxy", qos: .userInitiated)
    // Off-queue home for the (occasionally blocking) interface re-resolve on re-point.
    private let interfaceResolveQueue = DispatchQueue(label: "com.vpnbypass.proxy.ifupdate")

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
            if resolvedInterface == nil {
                // The whole point of boundInterface is to make the upstream hop LEAVE on
                // the physical NIC so it escapes a full-tunnel VPN. If it can't resolve,
                // the socket binds nowhere and the OS routes it — potentially through the
                // VPN in cleartext (target hostname + proxy creds exposed). Binding is
                // best-effort by design, but this must NOT be silent — surface it loudly.
                NSLog("VPN Bypass: WARNING — proxy route could not bind upstream to interface '%@'; its hop may traverse the VPN in cleartext. Check that the interface is up.", interfaceName)
            }
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

    /// Re-point this forwarder at a new upstream WITHOUT restarting the listener, so the
    /// local port survives. New tunnels use the new upstream; in-flight ones finish on the
    /// old one. If the bound interface changed (e.g. an internet proxy ⇄ a tailnet peer, or
    /// a Wi-Fi/Ethernet switch), re-resolve it off `queue` since resolution can block.
    func updateUpstream(_ newUpstream: Upstream) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let interfaceChanged = self.upstream.boundInterface != newUpstream.boundInterface
            self.upstream = newUpstream
            guard interfaceChanged else { return }
            let name = newUpstream.boundInterface
            // resolveInterface briefly runs an NWPathMonitor (can block up to 2s) — keep it
            // off the listener/accept queue, then fold the result back on.
            self.interfaceResolveQueue.async { [weak self] in
                let resolved = name.flatMap { Self.resolveInterface(named: $0) }
                self?.queue.async { self?.resolvedInterface = resolved }
            }
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

/// One client↔upstream pairing. Owns both NWConnections, performs the upstream
/// handshake (HTTP CONNECT or, when `upstream.isSOCKS5`, a SOCKS5/RFC 1928 client
/// handshake), then relays bytes verbatim in both directions until either side closes.
/// Every callback below is delivered on the forwarder's queue, so the mutable state
/// here is single-threaded by construction.
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
                if self.upstream.isSOCKS5 {
                    // SOCKS5 upstream: run the RFC 1928 client handshake, then relay.
                    self.startSOCKS5Handshake(authority: authority, on: server)
                } else {
                    // HTTP upstream: ask it to open a raw tunnel to the target, carrying
                    // the route's Basic auth; then read its response to that CONNECT.
                    self.send(self.connectRequest(authority: authority), on: server) { [weak self] in
                        self?.readUpstreamConnectResponse()
                    }
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

    // MARK: SOCKS5 upstream handshake (RFC 1928 + RFC 1929)

    // The client already spoke HTTP `CONNECT host:port` to US; only the UPSTREAM leg is
    // SOCKS5. We greet, optionally do user/pass auth, then issue a CONNECT carrying the
    // target as a DOMAIN NAME (ATYP 0x03) so the SOCKS5 server resolves it remotely
    // (socks5h — no local DNS lookup, matching the route's DNS-leak-safe design). On
    // success the client gets the SAME clean `200 Connection established` the HTTP path
    // sends; on any failure it gets `502 Bad Gateway` and the tunnel is torn down.

    /// Step 1 — the method-negotiation greeting: offer no-auth, plus user/pass when we
    /// hold a username, then read the server's single-method choice.
    private func startSOCKS5Handshake(authority: String, on server: NWConnection) {
        let greeting: Data = upstream.username.isEmpty
            ? Data([0x05, 0x01, 0x00])              // VER=5, 1 method: no-auth
            : Data([0x05, 0x02, 0x00, 0x02])        // VER=5, 2 methods: no-auth + user/pass
        send(greeting, on: server) { [weak self] in
            self?.readSOCKS5MethodSelection(authority: authority, on: server)
        }
    }

    private func readSOCKS5MethodSelection(authority: String, on server: NWConnection) {
        receiveExactly(2, on: server) { [weak self] bytes in
            guard let self = self else { return }
            guard bytes[0] == 0x05 else { self.failSOCKS5(); return }   // not a SOCKS5 server
            switch bytes[1] {
            case 0x00:
                // No authentication required → straight to CONNECT.
                self.sendSOCKS5Connect(authority: authority, on: server)
            case 0x02:
                // Server demands user/pass. We can only satisfy it with a username; if we
                // have none (so we never even offered method 0x02) this is unusable → fail.
                guard !self.upstream.username.isEmpty else { self.failSOCKS5(); return }
                self.sendSOCKS5UserPassAuth(authority: authority, on: server)
            default:
                // 0xFF = "no acceptable methods", or any method we did not offer.
                self.failSOCKS5()
            }
        }
    }

    /// Step 2 (optional) — RFC 1929 username/password sub-negotiation.
    private func sendSOCKS5UserPassAuth(authority: String, on server: NWConnection) {
        let user = Data(upstream.username.utf8)
        let pass = Data(upstream.password.utf8)
        // Each field is length-prefixed with a single byte, so neither may exceed 255.
        guard user.count <= 255, pass.count <= 255 else { failSOCKS5(); return }
        var msg = Data([0x01])                      // auth sub-negotiation version
        msg.append(UInt8(user.count)); msg.append(user)
        msg.append(UInt8(pass.count)); msg.append(pass)
        send(msg, on: server) { [weak self] in
            self?.readSOCKS5AuthResponse(authority: authority, on: server)
        }
    }

    private func readSOCKS5AuthResponse(authority: String, on server: NWConnection) {
        receiveExactly(2, on: server) { [weak self] bytes in
            guard let self = self else { return }
            // RFC 1929 reply is [VER, STATUS]; STATUS 0x00 == success. Key off the status
            // byte alone (some servers echo VER 0x05 rather than the sub-negotiation's 0x01).
            guard bytes[1] == 0x00 else { self.failSOCKS5(); return }
            self.sendSOCKS5Connect(authority: authority, on: server)
        }
    }

    /// Step 3 — the CONNECT request. ATYP 0x03 (domain) sends the hostname verbatim so the
    /// SOCKS5 server performs the DNS resolution (socks5h), never this process.
    ///
    /// Known limitation: a bracketed IPv6-literal target (e.g. `CONNECT [2001:db8::1]:443`)
    /// is sent as a domain name too, which a strict SOCKS5 server will fail to resolve. This
    /// is deliberately not special-cased (ATYP 0x04): the app is DNS-name/IPv4 oriented, the
    /// deployment is IPv6-off, and a client rarely CONNECTs to a raw IPv6 literal through a
    /// residential proxy. If that ever matters, detect the `[...]` literal here and emit
    /// ATYP 0x04 with the 16 packed bytes via inet_pton(AF_INET6).
    private func sendSOCKS5Connect(authority: String, on server: NWConnection) {
        guard let (host, port) = Self.splitAuthority(authority) else { failSOCKS5(); return }
        let hostBytes = Data(host.utf8)
        guard !hostBytes.isEmpty, hostBytes.count <= 255 else { failSOCKS5(); return }
        var request = Data([0x05, 0x01, 0x00, 0x03])   // VER=5, CMD=CONNECT, RSV, ATYP=domain
        request.append(UInt8(hostBytes.count)); request.append(hostBytes)
        request.append(UInt8(port >> 8)); request.append(UInt8(port & 0xFF))   // DST.PORT, big-endian
        send(request, on: server) { [weak self] in
            self?.readSOCKS5ConnectReplyHead(on: server)
        }
    }

    /// Step 4 — the CONNECT reply: fixed [VER, REP, RSV, ATYP] followed by a variable-length
    /// bound address we must consume EXACTLY (so any early tunnel payload stays queued for
    /// the relay). REP 0x00 == success; anything else means the upstream refused.
    private func readSOCKS5ConnectReplyHead(on server: NWConnection) {
        receiveExactly(4, on: server) { [weak self] bytes in
            guard let self = self else { return }
            guard bytes[0] == 0x05, bytes[1] == 0x00 else { self.failSOCKS5(); return }
            switch bytes[3] {
            case 0x01: self.consumeSOCKS5ReplyAddress(byteCount: 4 + 2, on: server)    // IPv4 + port
            case 0x04: self.consumeSOCKS5ReplyAddress(byteCount: 16 + 2, on: server)   // IPv6 + port
            case 0x03:
                // Domain: a single length byte precedes the address; read it, then the rest.
                self.receiveExactly(1, on: server) { [weak self] lenByte in
                    guard let self = self else { return }
                    self.consumeSOCKS5ReplyAddress(byteCount: Int(lenByte[0]) + 2, on: server)
                }
            default:
                self.failSOCKS5()   // unknown ATYP → malformed reply
            }
        }
    }

    private func consumeSOCKS5ReplyAddress(byteCount: Int, on server: NWConnection) {
        receiveExactly(byteCount, on: server) { [weak self] _ in
            self?.openTunnelToClient()
        }
    }

    /// Handshake done: hand the client the same clean 200 the HTTP path emits, replay its
    /// early bytes upstream, and start the bidirectional relay. Nothing was over-read from
    /// the server, so any early tunnel bytes remain queued and the relay picks them up.
    private func openTunnelToClient() {
        guard let server = server else { cancel(); return }
        send(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), on: client)
        if !clientLeftover.isEmpty { send(clientLeftover, on: server) }
        startRelay()
    }

    /// Read EXACTLY `count` bytes from `connection`, accumulating across partial segments,
    /// then invoke `then`. A short close (isComplete) or error tears the tunnel down. Uses
    /// `maximumLength: remaining` so it never over-reads past `count` — surplus bytes stay
    /// buffered in the NWConnection for the next receive.
    private func receiveExactly(_ count: Int, on connection: NWConnection, accumulated: Data = Data(), then: @escaping (Data) -> Void) {
        let remaining = count - accumulated.count
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.cancel(); return }
            var buffer = accumulated
            if let data = data, !data.isEmpty { buffer.append(data) }
            if buffer.count >= count { then(buffer); return }
            if isComplete { self.cancel(); return }   // peer closed before the full reply arrived
            self.receiveExactly(count, on: connection, accumulated: buffer, then: then)
        }
    }

    /// Tell the client the upstream tunnel could not be opened, then tear down. The client
    /// only ever speaks HTTP to us, so failures surface as a 502 (mirrors the HTTP path).
    private func failSOCKS5() {
        send(Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8), on: client) { [weak self] in self?.cancel() }
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

    /// Split a "host:port" authority into its parts using the SAME rule as isValidAuthority
    /// (the LAST colon separates host from port). Returns nil when it isn't well-formed; the
    /// SOCKS5 path calls this only after isValidAuthority has already passed.
    private static func splitAuthority(_ authority: String) -> (host: String, port: UInt16)? {
        guard let colon = authority.lastIndex(of: ":") else { return nil }
        let host = String(authority[..<colon])
        guard !host.isEmpty, let port = UInt16(authority[authority.index(after: colon)...]) else { return nil }
        return (host, port)
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
