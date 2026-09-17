// LoopbackPeerAuth.swift
// Same-uid gate for the 127.0.0.1 proxy listener.
//
// The control socket uses getpeereid() on AF_UNIX. The proxy is Network.framework
// TCP, so there is no peer credential on the socket. We map the client's
// ephemeral source port to a uid via libproc and require it to match getuid().
// Unknown / conflicting lookups fail closed (same as a getpeereid() error).

import Darwin
import Network
import VPNBypassPeerAuth

enum LoopbackPeerAuth {
    /// Policy used by the accept path. `nil` means "could not identify the peer".
    static func allows(peerUID: uid_t?) -> Bool {
        guard let peerUID else { return false }
        return peerUID == getuid()
    }

    /// Identify the TCP client on `connection` and apply `allows(peerUID:)`.
    /// Call only after the connection is `.ready` so `currentPath` is populated.
    static func allows(connection: NWConnection) -> Bool {
        allows(peerUID: uid(of: connection))
    }

    static func uid(of connection: NWConnection) -> uid_t? {
        guard let clientPort = remoteTCPPort(of: connection) else { return nil }
        // The server's local port is the client's foreign port. Passing it
        // stops an unrelated loopback socket on the same source port from
        // counting as this connection. Missing local port: fail closed
        // instead of skipping that filter.
        guard let foreignPort = localTCPPort(of: connection) else { return nil }
        return uidOwningLocalTCPPort(clientPort, foreignPort: foreignPort)
    }

    static func remoteTCPPort(of connection: NWConnection) -> UInt16? {
        port(of: connection.currentPath?.remoteEndpoint)
    }

    static func localTCPPort(of connection: NWConnection) -> UInt16? {
        port(of: connection.currentPath?.localEndpoint)
    }

    private static func port(of endpoint: NWEndpoint?) -> UInt16? {
        guard let endpoint else { return nil }
        if case .hostPort(_, let port) = endpoint {
            return port.rawValue
        }
        return nil
    }

    /// `foreignPort` 0 skips the far-side filter (a listen socket has none).
    static func uidOwningLocalTCPPort(_ port: UInt16, foreignPort: UInt16 = 0) -> uid_t? {
        var uid: uid_t = 0
        guard loopback_peer_uid_for_tcp_port(port, foreignPort, &uid) == 0 else { return nil }
        return uid
    }
}
