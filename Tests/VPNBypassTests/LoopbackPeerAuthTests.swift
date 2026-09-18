import Darwin
import Network
import XCTest
@testable import VPNBypassCore

final class LoopbackPeerAuthTests: XCTestCase {

    func testAllowsRejectsNilPeer() {
        XCTAssertFalse(LoopbackPeerAuth.allows(peerUID: nil),
                       "unknown peer must fail closed")
    }

    func testAllowsAcceptsSameUid() {
        XCTAssertTrue(LoopbackPeerAuth.allows(peerUID: getuid()))
    }

    func testAllowsRejectsOtherUid() {
        let other = getuid() &+ 1
        XCTAssertFalse(LoopbackPeerAuth.allows(peerUID: other),
                       "a different uid must be rejected")
    }

    func testUidLookupFindsOwnListeningPort() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "listener ready")
        var bound: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue {
                bound = port
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { _ in }
        listener.start(queue: DispatchQueue(label: "test.loopback.peer.listener"))
        defer { listener.cancel() }
        wait(for: [ready], timeout: 5.0)
        XCTAssertNotEqual(bound, 0)

        let uid = try XCTUnwrap(LoopbackPeerAuth.uidOwningLocalTCPPort(bound),
                                "libproc must see this process's loopback listen socket")
        XCTAssertEqual(uid, getuid())
    }

    /// A wildcard bind on port P must not satisfy a loopback peer lookup
    /// for P. Matching local port alone would treat a non-loopback socket
    /// as the 127.0.0.1 client.
    func testUidLookupIgnoresNonLoopbackLocalPort() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "wildcard listener ready")
        var bound: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue {
                bound = port
                ready.fulfill()
            }
        }
        listener.newConnectionHandler = { _ in }
        listener.start(queue: DispatchQueue(label: "test.loopback.peer.wildcard"))
        defer { listener.cancel() }
        wait(for: [ready], timeout: 5.0)
        XCTAssertNotEqual(bound, 0)

        XCTAssertNil(LoopbackPeerAuth.uidOwningLocalTCPPort(bound),
                     "a non-loopback bind on \(bound) must not count as a loopback peer")
    }

    /// The production path: a real client connected to a loopback listener, looked up from the
    /// accepted connection at `.ready` exactly as ProxyForwarder.accept does. The listen-socket
    /// tests above skip the foreign-port filter; this one runs with it on, so a byte-order slip
    /// there, or a missing local endpoint at `.ready`, fails here instead of locking every
    /// legitimate client out of the proxy.
    func testUidOfAcceptedLoopbackConnectionIsOurs() throws {
        let (uid, _, _) = try acceptOneLoopbackConnection()
        XCTAssertEqual(try XCTUnwrap(uid, "a same-user loopback client must be identified"), getuid())
    }

    /// Positive control for the foreign-port filter: the same live client socket, asked about
    /// with the WRONG far-side port, is not this connection and must not be attributed.
    func testUidLookupRejectsWrongForeignPort() throws {
        let (_, clientPort, listenerPort) = try acceptOneLoopbackConnection()
        XCTAssertEqual(LoopbackPeerAuth.uidOwningLocalTCPPort(clientPort, foreignPort: listenerPort),
                       getuid())
        let wrong = listenerPort == UInt16.max ? listenerPort - 1 : listenerPort + 1
        XCTAssertNil(LoopbackPeerAuth.uidOwningLocalTCPPort(clientPort, foreignPort: wrong),
                     "a socket connected to another port is not this connection")
    }

    /// Listen on 127.0.0.1, connect one client, and evaluate the accepted connection at `.ready`.
    /// Both ends stay open until the lookups are done: a closed socket is invisible to libproc.
    private var keepAlive: [AnyObject] = []

    private func acceptOneLoopbackConnection() throws -> (uid: uid_t?, clientPort: UInt16, listenerPort: UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "test.loopback.peer.accept")
        let listening = expectation(description: "listener ready")
        let accepted = expectation(description: "accepted connection ready")
        var result: (uid_t?, UInt16) = (nil, 0)

        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { server in
            server.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                result = (LoopbackPeerAuth.uid(of: server),
                          LoopbackPeerAuth.remoteTCPPort(of: server) ?? 0)
                accepted.fulfill()
            }
            self.keepAlive.append(server)
            server.start(queue: queue)
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5.0)
        let listenerPort = try XCTUnwrap(listener.port?.rawValue)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: listenerPort)!, using: .tcp)
        client.start(queue: queue)
        keepAlive += [listener, client]
        wait(for: [accepted], timeout: 5.0)
        XCTAssertNotEqual(result.1, 0)
        return (result.0, result.1, listenerPort)
    }

    override func tearDown() {
        for case let c as NWConnection in keepAlive { c.cancel() }
        for case let l as NWListener in keepAlive { l.cancel() }
        keepAlive.removeAll()
        super.tearDown()
    }

    func testUidLookupReturnsNilForUnusedPort() {
        // Port 1 is TCPMUX and is not bound by this test process. Lookup
        // either finds nothing or (if something else owns it) a uid. The
        // unused-port contract is: if we cannot name a single owner, nil.
        // Bind-and-close a high port then look it up after close is racy,
        // so we only assert that port 0 is rejected by the C helper.
        XCTAssertNil(LoopbackPeerAuth.uidOwningLocalTCPPort(0))
    }
}
