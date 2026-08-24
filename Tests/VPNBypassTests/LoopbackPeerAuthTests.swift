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
        let listener = try NWListener(using: .tcp)
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
                                "libproc must see this process's listen socket")
        XCTAssertEqual(uid, getuid())
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
