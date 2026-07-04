import XCTest
import Network
@testable import VPNBypassCore

// End-to-end test for the chaining proxy: stand up a MOCK upstream proxy, point a
// ProxyForwarder at it, then drive a real client NWConnection through the forwarder
// and prove that (a) the upstream received a correctly-authenticated CONNECT and
// (b) bytes relay end-to-end through the tunnel. Everything is driven off
// XCTestExpectations (no sleeps) so it is deterministic.
final class ProxyForwarderTests: XCTestCase {

    private let mockQueue = DispatchQueue(label: "test.proxy.mock-upstream")
    private let clientQueue = DispatchQueue(label: "test.proxy.client")

    private var forwarder: ProxyForwarder?
    private var mockListener: NWListener?
    private var mockConnection: NWConnection?
    private var clientConnection: NWConnection?

    // A second client + two dedicated mock upstreams for the updateUpstream re-point test,
    // which must prove a NEW connection reaches a DIFFERENT upstream than the first.
    private var clientConnection2: NWConnection?
    private let mockQueueA = DispatchQueue(label: "test.proxy.mock-a")
    private let mockQueueB = DispatchQueue(label: "test.proxy.mock-b")
    private var mockListenerA: NWListener?
    private var mockListenerB: NWListener?
    private var mockConnA: NWConnection?
    private var mockConnB: NWConnection?

    // Accumulates everything the client reads back from the forwarder. Mutated only
    // on `clientQueue` (receive completions are serial), so no extra locking needed.
    private var clientBuffer = Data()
    private var sawEstablished = false
    private var headerEndIndex = 0
    private var establishedFulfilled = false
    private var echoFulfilled = false

    override func tearDown() {
        clientConnection?.cancel()
        clientConnection2?.cancel()
        mockConnection?.cancel()
        mockConnA?.cancel()
        mockConnB?.cancel()
        mockListener?.cancel()
        mockListenerA?.cancel()
        mockListenerB?.cancel()
        forwarder?.stop()
        clientConnection = nil
        clientConnection2 = nil
        mockConnection = nil
        mockConnA = nil
        mockConnB = nil
        mockListener = nil
        mockListenerA = nil
        mockListenerB = nil
        forwarder = nil
        super.tearDown()
    }

    func testConnectTunnelRelaysEndToEnd() throws {
        let mockReady = expectation(description: "mock upstream ready")
        let gotConnect = expectation(description: "mock received authenticated CONNECT")
        let established = expectation(description: "client received 200 Connection established")
        let echoed = expectation(description: "client received echoed bytes back through the tunnel")

        // 1. Mock upstream proxy on 127.0.0.1:0.
        var mockPort: UInt16 = 0
        try startMockUpstream(gotConnect: gotConnect) { port in
            mockPort = port
            mockReady.fulfill()
        }
        wait(for: [mockReady], timeout: 5.0)
        XCTAssertNotEqual(mockPort, 0, "mock upstream should have an OS-assigned port")

        // 2. Forwarder chaining through the mock, injecting Basic u:p.
        let forwarder = ProxyForwarder(
            listenPort: 0,
            upstream: .init(host: "127.0.0.1", port: mockPort, username: "u", password: "p", boundInterface: nil)
        )
        try forwarder.start()
        self.forwarder = forwarder
        let listenPort = try XCTUnwrap(forwarder.boundPort)
        XCTAssertNotEqual(listenPort, 0, "forwarder should expose its OS-assigned port")

        // 3. Client points at the forwarder and issues a CONNECT.
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!, using: .tcp)
        self.clientConnection = client
        client.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let request = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"
                client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                self.receiveClient(client, established: established, echoed: echoed)
            }
        }
        client.start(queue: clientQueue)

        // Upstream must see the authenticated CONNECT, and the client must see the 200.
        wait(for: [gotConnect, established], timeout: 5.0)

        // 4. Tunnel is open → send "ping"; the mock echoes it, proving relay both ways.
        client.send(content: Data("ping".utf8), completion: .contentProcessed { _ in })
        wait(for: [echoed], timeout: 5.0)
    }

    // MARK: - Mock upstream proxy

    /// An NWListener that accepts one connection, asserts it received a CONNECT for
    /// example.com:443 carrying `Proxy-Authorization: Basic base64("u:p")`, replies
    /// `200 Connection established`, then echoes any subsequent bytes back.
    private func startMockUpstream(gotConnect: XCTestExpectation, ready: @escaping (UInt16) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.mockListener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = self?.mockListener?.port?.rawValue else { return }
            ready(port)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.mockConnection = connection
            connection.start(queue: self.mockQueue)
            self.readMockRequest(connection, buffer: Data(), gotConnect: gotConnect)
        }
        listener.start(queue: mockQueue)
    }

    private func readMockRequest(_ connection: NWConnection, buffer: Data, gotConnect: XCTestExpectation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buffer.subdata(in: buffer.startIndex..<range.upperBound), encoding: .utf8) ?? ""
                XCTAssertTrue(head.contains("CONNECT example.com:443"), "unexpected CONNECT head: \(head)")
                let expectedAuth = "Proxy-Authorization: Basic " + Data("u:p".utf8).base64EncodedString()
                XCTAssertTrue(head.contains(expectedAuth), "missing/incorrect proxy auth in head: \(head)")
                gotConnect.fulfill()

                let response = "HTTP/1.1 200 Connection established\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                    self?.echoMock(connection)
                })
                return
            }
            if isComplete || error != nil { return }
            self.readMockRequest(connection, buffer: buffer, gotConnect: gotConnect)
        }
    }

    private func echoMock(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil { return }
            self.echoMock(connection)
        }
    }

    // MARK: - Client read loop

    private func receiveClient(_ connection: NWConnection, established: XCTestExpectation, echoed: XCTestExpectation) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.clientBuffer.append(data)
                self.evaluateClientBuffer(established: established, echoed: echoed)
            }
            if isComplete || error != nil { return }
            self.receiveClient(connection, established: established, echoed: echoed)
        }
    }

    private func evaluateClientBuffer(established: XCTestExpectation, echoed: XCTestExpectation) {
        if !sawEstablished, let range = clientBuffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = clientBuffer.subdata(in: clientBuffer.startIndex..<range.upperBound)
            XCTAssertEqual(String(data: header, encoding: .utf8), "HTTP/1.1 200 Connection established\r\n\r\n")
            sawEstablished = true
            headerEndIndex = range.upperBound
            if !establishedFulfilled { establishedFulfilled = true; established.fulfill() }
        }
        if sawEstablished, !echoFulfilled {
            let body = clientBuffer.subdata(in: headerEndIndex..<clientBuffer.endIndex)
            if body == Data("ping".utf8) {
                echoFulfilled = true
                echoed.fulfill()
            }
        }
    }

    // MARK: - SOCKS5 upstream round-trip

    // The forwarder advertises `.proxySOCKS5` as a first-class egress; these prove the
    // UPSTREAM leg actually speaks SOCKS5 (RFC 1928/1929), not HTTP CONNECT. The client
    // still points HTTP `CONNECT` at the local listener exactly as for an HTTP upstream.

    func testSOCKS5NoAuthTunnelRelaysEndToEnd() throws {
        try runSOCKS5RoundTrip(expectAuth: false, user: "", pass: "")
    }

    func testSOCKS5UserPassTunnelRelaysEndToEnd() throws {
        try runSOCKS5RoundTrip(expectAuth: true, user: "u", pass: "p")
    }

    /// Stand up a mock SOCKS5 upstream, point an `isSOCKS5: true` forwarder at it, drive a
    /// client CONNECT, and prove the 200 + a "ping" echo relay end-to-end through the tunnel.
    private func runSOCKS5RoundTrip(expectAuth: Bool, user: String, pass: String) throws {
        let mockReady = expectation(description: "mock SOCKS5 ready")
        let gotConnect = expectation(description: "mock SOCKS5 received CONNECT for example.com:443")
        let established = expectation(description: "client received 200 Connection established")
        let echoed = expectation(description: "client received echoed bytes back through the tunnel")

        var mockPort: UInt16 = 0
        try startMockSOCKS5(expectAuth: expectAuth, expectedUser: user, expectedPass: pass, gotConnect: gotConnect) { port in
            mockPort = port
            mockReady.fulfill()
        }
        wait(for: [mockReady], timeout: 5.0)
        XCTAssertNotEqual(mockPort, 0, "mock SOCKS5 should have an OS-assigned port")

        let forwarder = ProxyForwarder(
            listenPort: 0,
            upstream: .init(host: "127.0.0.1", port: mockPort, username: user, password: pass, boundInterface: nil, isSOCKS5: true)
        )
        try forwarder.start()
        self.forwarder = forwarder
        let listenPort = try XCTUnwrap(forwarder.boundPort)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!, using: .tcp)
        self.clientConnection = client
        client.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let request = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"
                client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                self.receiveClient(client, established: established, echoed: echoed)
            }
        }
        client.start(queue: clientQueue)

        wait(for: [gotConnect, established], timeout: 5.0)
        client.send(content: Data("ping".utf8), completion: .contentProcessed { _ in })
        wait(for: [echoed], timeout: 5.0)
    }

    // MARK: - Malformed CONNECT authority

    /// A CONNECT whose authority has no valid port must be rejected with 400 before the
    /// forwarder ever dials the upstream (exercises the isValidAuthority rejection path).
    func testMalformedConnectAuthorityReturns400() throws {
        let got400 = expectation(description: "client received 400 Bad Request")

        // Upstream (port 1) is never dialed — isValidAuthority rejects first, so this is safe.
        let forwarder = ProxyForwarder(
            listenPort: 0,
            upstream: .init(host: "127.0.0.1", port: 1, username: "", password: "", boundInterface: nil)
        )
        try forwarder.start()
        self.forwarder = forwarder
        let listenPort = try XCTUnwrap(forwarder.boundPort)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!, using: .tcp)
        self.clientConnection = client
        client.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                // Port "http" is non-numeric → isValidAuthority fails → 400 Bad Request.
                let request = "CONNECT example.com:http HTTP/1.1\r\nHost: example.com\r\n\r\n"
                client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                self.receiveStatusHead(client, expected: "HTTP/1.1 400 Bad Request\r\n\r\n", fulfill: got400)
            }
        }
        client.start(queue: clientQueue)
        wait(for: [got400], timeout: 5.0)
    }

    // MARK: - updateUpstream re-points new connections

    /// After updateUpstream, a NEW client connection must egress through the NEW upstream,
    /// not the original one — proving the re-point isn't merely port-stable.
    func testUpdateUpstreamRepointsNewConnections() throws {
        let readyA = expectation(description: "mock A ready")
        let readyB = expectation(description: "mock B ready")
        let gotConnectA = expectation(description: "upstream A received the first CONNECT")
        gotConnectA.assertForOverFulfill = true    // the post-repoint connection must NOT return to A
        let gotConnectB = expectation(description: "upstream B received the second CONNECT after re-point")
        let establishedA = expectation(description: "client1 saw 200 through A")
        let establishedB = expectation(description: "client2 saw 200 through B")

        var portA: UInt16 = 0
        var portB: UInt16 = 0
        try startHTTPConnectMock(on: mockQueueA, storeListener: { self.mockListenerA = $0 },
                                 storeConnection: { self.mockConnA = $0 }, gotConnect: gotConnectA) { portA = $0; readyA.fulfill() }
        try startHTTPConnectMock(on: mockQueueB, storeListener: { self.mockListenerB = $0 },
                                 storeConnection: { self.mockConnB = $0 }, gotConnect: gotConnectB) { portB = $0; readyB.fulfill() }
        wait(for: [readyA, readyB], timeout: 5.0)
        XCTAssertNotEqual(portA, portB, "the two mock upstreams must be distinct")

        let forwarder = ProxyForwarder(
            listenPort: 0,
            upstream: .init(host: "127.0.0.1", port: portA, username: "u", password: "p", boundInterface: nil)
        )
        try forwarder.start()
        self.forwarder = forwarder
        let listenPort = try XCTUnwrap(forwarder.boundPort)

        // Client 1 → must reach A.
        let client1 = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!, using: .tcp)
        self.clientConnection = client1
        client1.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                client1.send(content: Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                self.receiveStatusHead(client1, expected: "HTTP/1.1 200 Connection established\r\n\r\n", fulfill: establishedA)
            }
        }
        client1.start(queue: clientQueue)
        wait(for: [gotConnectA, establishedA], timeout: 5.0)

        // Re-point to B. updateUpstream enqueues on the forwarder's serial queue NOW — before
        // client2's connection can be accepted (also on that queue) — so the new tunnel uses B.
        forwarder.updateUpstream(.init(host: "127.0.0.1", port: portB, username: "u", password: "p", boundInterface: nil))

        // Client 2 → must reach B, never A (gotConnectA.assertForOverFulfill catches a regression).
        let client2 = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!, using: .tcp)
        self.clientConnection2 = client2
        client2.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                client2.send(content: Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                self.receiveStatusHead(client2, expected: "HTTP/1.1 200 Connection established\r\n\r\n", fulfill: establishedB)
            }
        }
        client2.start(queue: clientQueue)
        wait(for: [gotConnectB, establishedB], timeout: 5.0)
    }

    // MARK: - Mock SOCKS5 upstream

    /// A minimal RFC 1928/1929 SOCKS5 server: negotiates method (no-auth, or user/pass when
    /// `expectAuth`), verifies the CONNECT is an ATYP=0x03 DOMAIN request for example.com:443
    /// (socks5h — the domain is resolved server-side), replies success, then echoes.
    private func startMockSOCKS5(expectAuth: Bool, expectedUser: String, expectedPass: String,
                                 gotConnect: XCTestExpectation, ready: @escaping (UInt16) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.mockListener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = self?.mockListener?.port?.rawValue else { return }
            ready(port)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.mockConnection = connection
            connection.start(queue: self.mockQueue)
            self.socks5ReadGreeting(connection, expectAuth: expectAuth,
                                    expectedUser: expectedUser, expectedPass: expectedPass, gotConnect: gotConnect)
        }
        listener.start(queue: mockQueue)
    }

    private func socks5ReadGreeting(_ conn: NWConnection, expectAuth: Bool,
                                    expectedUser: String, expectedPass: String, gotConnect: XCTestExpectation) {
        readExactly(conn, 2) { [weak self] prefix in                       // VER, NMETHODS
            guard let self = self else { return }
            XCTAssertEqual(prefix[0], 0x05, "SOCKS5 greeting version")
            self.readExactly(conn, Int(prefix[1])) { [weak self] methods in // the offered METHODS
                guard let self = self else { return }
                if expectAuth {
                    XCTAssertTrue(methods.contains(0x02), "client must offer user/pass when auth is needed")
                    conn.send(content: Data([0x05, 0x02]), completion: .contentProcessed { [weak self] _ in
                        self?.socks5ReadAuth(conn, expectedUser: expectedUser, expectedPass: expectedPass, gotConnect: gotConnect)
                    })
                } else {
                    XCTAssertTrue(methods.contains(0x00), "client must offer no-auth")
                    conn.send(content: Data([0x05, 0x00]), completion: .contentProcessed { [weak self] _ in
                        self?.socks5ReadConnect(conn, gotConnect: gotConnect)
                    })
                }
            }
        }
    }

    private func socks5ReadAuth(_ conn: NWConnection, expectedUser: String, expectedPass: String, gotConnect: XCTestExpectation) {
        readExactly(conn, 2) { [weak self] prefix in                       // VER(0x01), ULEN
            guard let self = self else { return }
            XCTAssertEqual(prefix[0], 0x01, "auth sub-negotiation version")
            self.readExactly(conn, Int(prefix[1])) { [weak self] userData in
                guard let self = self else { return }
                self.readExactly(conn, 1) { [weak self] plen in
                    guard let self = self else { return }
                    self.readExactly(conn, Int(plen[0])) { [weak self] passData in
                        guard let self = self else { return }
                        XCTAssertEqual(String(data: userData, encoding: .utf8), expectedUser, "SOCKS5 username")
                        XCTAssertEqual(String(data: passData, encoding: .utf8), expectedPass, "SOCKS5 password")
                        conn.send(content: Data([0x01, 0x00]), completion: .contentProcessed { [weak self] _ in  // status 0 = success
                            self?.socks5ReadConnect(conn, gotConnect: gotConnect)
                        })
                    }
                }
            }
        }
    }

    private func socks5ReadConnect(_ conn: NWConnection, gotConnect: XCTestExpectation) {
        readExactly(conn, 4) { [weak self] prefix in                       // VER, CMD, RSV, ATYP
            guard let self = self else { return }
            XCTAssertEqual(prefix[0], 0x05, "connect version")
            XCTAssertEqual(prefix[1], 0x01, "command must be CONNECT")
            XCTAssertEqual(prefix[3], 0x03, "ATYP must be domain (socks5h)")
            self.readExactly(conn, 1) { [weak self] lenByte in             // domain length
                guard let self = self else { return }
                let hostLen = Int(lenByte[0])
                self.readExactly(conn, hostLen + 2) { [weak self] rest in  // domain bytes + DST.PORT
                    guard let self = self else { return }
                    let bytes = [UInt8](rest)
                    XCTAssertEqual(String(bytes: bytes[0..<hostLen], encoding: .utf8), "example.com",
                                   "SOCKS5 must carry the domain for remote resolution")
                    let port = (UInt16(bytes[hostLen]) << 8) | UInt16(bytes[hostLen + 1])
                    XCTAssertEqual(port, 443, "target port")
                    gotConnect.fulfill()
                    // Success, bound address 0.0.0.0:0 as IPv4 (ATYP 0x01).
                    conn.send(content: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                              completion: .contentProcessed { [weak self] _ in self?.echoMock(conn) })
                }
            }
        }
    }

    /// Read EXACTLY `count` bytes off `connection`, accumulating across segments — the
    /// test-side mirror of the forwarder's own exact reader, driving the mock state machines.
    private func readExactly(_ connection: NWConnection, _ count: Int, into accumulated: Data = Data(), completion: @escaping (Data) -> Void) {
        let remaining = count - accumulated.count
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = accumulated
            if let data = data { buffer.append(data) }
            if buffer.count >= count { completion(buffer); return }
            if isComplete || error != nil { return }
            self.readExactly(connection, count, into: buffer, completion: completion)
        }
    }

    // MARK: - Named HTTP CONNECT mock (for the re-point test)

    /// Start an HTTP CONNECT mock upstream on `queue`, handing its listener/connection to the
    /// given closures so the two-upstream re-point test can retain both independently. Reuses
    /// readMockRequest/echoMock (asserts CONNECT example.com:443 with Basic u:p, replies 200).
    private func startHTTPConnectMock(on queue: DispatchQueue,
                                      storeListener: @escaping (NWListener) -> Void,
                                      storeConnection: @escaping (NWConnection) -> Void,
                                      gotConnect: XCTestExpectation, ready: @escaping (UInt16) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        storeListener(listener)
        listener.stateUpdateHandler = { state in
            guard case .ready = state, let port = listener.port?.rawValue else { return }
            ready(port)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            storeConnection(connection)
            connection.start(queue: queue)
            self.readMockRequest(connection, buffer: Data(), gotConnect: gotConnect)
        }
        listener.start(queue: queue)
    }

    // MARK: - Client read helpers

    /// Read a single short HTTP response head off `connection` and assert it EQUALS `expected`.
    /// Uses a local buffer (not the shared clientBuffer) so multiple clients can read at once.
    private func receiveStatusHead(_ connection: NWConnection, expected: String, fulfill: XCTestExpectation, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buffer.subdata(in: buffer.startIndex..<range.upperBound), encoding: .utf8)
                XCTAssertEqual(head, expected)
                fulfill.fulfill()
                return
            }
            if isComplete || error != nil { return }
            self.receiveStatusHead(connection, expected: expected, fulfill: fulfill, buffer: buffer)
        }
    }

    // MARK: - Authority-parsing edge cases (isValidAuthority / splitAuthority)

    // isValidAuthority/splitAuthority are private to a private nested type (Tunnel),
    // so they are only reachable through the forwarder's public start()/CONNECT
    // behavior — these drive that surface directly, exercising the "last colon
    // separates host from port" rule: no colon at all, an empty host before the
    // colon, a numeric-but-overflowing port, and a bracketed IPv6 literal both
    // without and with an explicit port.

    /// No colon anywhere in the authority: `lastIndex(of: ":")` finds nothing, so
    /// isValidAuthority fails closed with 400 before ever dialing upstream.
    func testConnectAuthorityWithNoColonReturns400() throws {
        try assertMalformedConnectAuthorityReturns400(authority: "example.com")
    }

    /// An empty host before the colon (":443") fails the `!host.isEmpty` check.
    func testConnectAuthorityWithEmptyHostReturns400() throws {
        try assertMalformedConnectAuthorityReturns400(authority: ":443")
    }

    /// A numeric but out-of-UInt16-range port (70000 > 65535) fails `UInt16(portText)`.
    func testConnectAuthorityWithPortOutOfUInt16RangeReturns400() throws {
        try assertMalformedConnectAuthorityReturns400(authority: "example.com:70000")
    }

    /// A bracketed IPv6 literal with NO port: the last colon in the string is one of
    /// the address's OWN colons (inside the brackets), so the "port" text captured
    /// after it is non-numeric ("1]") and the CONNECT is rejected — a real consequence
    /// of the "last colon" heuristic when there is no actual port suffix.
    func testConnectAuthorityBracketedIPv6WithoutPortReturns400() throws {
        try assertMalformedConnectAuthorityReturns400(authority: "[2001:db8::1]")
    }

    /// Shared driver for the 400-path tests above: no mock upstream is needed since
    /// isValidAuthority rejects before the forwarder ever dials out (mirrors the
    /// existing testMalformedConnectAuthorityReturns400, which covers a non-numeric port).
    private func assertMalformedConnectAuthorityReturns400(authority: String) throws {
        let got400 = expectation(description: "client received 400 Bad Request for authority '\(authority)'")
        let forwarder = ProxyForwarder(
            listenPort: 0,
            upstream: .init(host: "127.0.0.1", port: 1, username: "", password: "", boundInterface: nil)
        )
        try forwarder.start()
        self.forwarder = forwarder
        let listenPort = try XCTUnwrap(forwarder.boundPort)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!, using: .tcp)
        self.clientConnection = client
        client.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n"
                client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                self.receiveStatusHead(client, expected: "HTTP/1.1 400 Bad Request\r\n\r\n", fulfill: got400)
            }
        }
        client.start(queue: clientQueue)
        wait(for: [got400], timeout: 5.0)
    }

    /// A bracketed IPv6 literal WITH an explicit port ("[2001:db8::1]:443"): the last
    /// colon correctly falls after the closing bracket, so isValidAuthority accepts it
    /// and the forwarder dials upstream carrying the authority VERBATIM, brackets and
    /// all — the documented limitation that a raw IPv6 CONNECT target is sent as a
    /// domain name, not specially unwrapped.
    func testConnectAuthorityBracketedIPv6WithPortIsDialedVerbatimAsHostname() throws {
        let mockReady = expectation(description: "capturing mock ready")
        let gotHead = expectation(description: "mock captured the CONNECT head")

        var mockPort: UInt16 = 0
        try startCapturingHTTPMock(onHead: { head in
            XCTAssertTrue(head.contains("CONNECT [2001:db8::1]:443 HTTP/1.1"),
                          "the bracketed literal must reach the upstream verbatim as the authority: \(head)")
            gotHead.fulfill()
        }, ready: { port in mockPort = port; mockReady.fulfill() })
        wait(for: [mockReady], timeout: 5.0)
        XCTAssertNotEqual(mockPort, 0)

        let forwarder = ProxyForwarder(
            listenPort: 0,
            upstream: .init(host: "127.0.0.1", port: mockPort, username: "", password: "", boundInterface: nil)
        )
        try forwarder.start()
        self.forwarder = forwarder
        let listenPort = try XCTUnwrap(forwarder.boundPort)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenPort)!, using: .tcp)
        self.clientConnection = client
        client.stateUpdateHandler = { state in
            if case .ready = state {
                let request = "CONNECT [2001:db8::1]:443 HTTP/1.1\r\nHost: [2001:db8::1]:443\r\n\r\n"
                client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            }
        }
        client.start(queue: clientQueue)
        wait(for: [gotHead], timeout: 5.0)
    }

    /// A minimal HTTP CONNECT mock that CAPTURES the request head verbatim (no
    /// hardcoded host/auth assertions, unlike startMockUpstream/readMockRequest) so a
    /// test can drive an arbitrary CONNECT authority and inspect exactly what the
    /// forwarder dialed upstream with.
    private func startCapturingHTTPMock(onHead: @escaping (String) -> Void, ready: @escaping (UInt16) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.mockListener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = self?.mockListener?.port?.rawValue else { return }
            ready(port)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.mockConnection = connection
            connection.start(queue: self.mockQueue)
            self.captureHTTPHead(connection, buffer: Data(), onHead: onHead)
        }
        listener.start(queue: mockQueue)
    }

    private func captureHTTPHead(_ connection: NWConnection, buffer: Data, onHead: @escaping (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buffer.subdata(in: buffer.startIndex..<range.upperBound), encoding: .utf8) ?? ""
                onHead(head)
                return   // no response sent — the test only observes what was dialed
            }
            if isComplete || error != nil { return }
            self.captureHTTPHead(connection, buffer: buffer, onHead: onHead)
        }
    }
}
