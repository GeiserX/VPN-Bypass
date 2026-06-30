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

    // Accumulates everything the client reads back from the forwarder. Mutated only
    // on `clientQueue` (receive completions are serial), so no extra locking needed.
    private var clientBuffer = Data()
    private var sawEstablished = false
    private var headerEndIndex = 0
    private var establishedFulfilled = false
    private var echoFulfilled = false

    override func tearDown() {
        clientConnection?.cancel()
        mockConnection?.cancel()
        mockListener?.cancel()
        forwarder?.stop()
        clientConnection = nil
        mockConnection = nil
        mockListener = nil
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
}
