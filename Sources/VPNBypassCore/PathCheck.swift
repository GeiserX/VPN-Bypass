// PathCheck.swift
// Which way the kernel sends an address, and whether the site answers on port 443 that way.
//
// One probe asks the routing table for the address's interface (RouteKernel.lookup, the RTM_GET
// `route -n get` sends), then opens a TCP connection to port 443 and reads the local address
// the kernel bound the socket to (getsockname), which names the interface the connection left
// through. Both read the same routing table, so a probe reports "the route the kernel picks,
// and whether the site answers on 443 that way". It cannot see a packet-filter `route-to`, a
// content filter, or a tunnel that captures traffic below the route table (a VPN's kill switch).
//
// Every run carries a control that must fail: one address the app does not route, which has
// to come back the other way (through the VPN in Bypass, around it in VPN Only). When it does
// not, the probe cannot tell the two ways apart, and the run reads "check broken" instead of
// passing. The decisions are pure and tested; only `probe` touches a socket.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum PathCheck {
    /// The port every probe connects to: what a browser opens for a site.
    public static let port: UInt16 = 443
    /// How long a probe waits for the TCP handshake.
    public static let timeout: TimeInterval = 3
    /// Addresses tried for the control, in order: the documentation ranges (RFC 5737), which no
    /// site uses. The first one the app does not route is the control. The control only needs
    /// its path, so it never waits for an answer from it.
    public static let controlCandidates = ["192.0.2.1", "198.51.100.1", "203.0.113.1"]

    /// How a probe's TCP connection ended.
    public enum Answer: String, Codable, Equatable, Sendable {
        /// The handshake completed: the site answers on 443 that way.
        case connected
        /// A reset came back: something answered that way, with the port closed.
        case refused
        /// No reply before the timeout.
        case noAnswer
        /// The connection could not start (no route, network unreachable, socket error).
        case failed
        /// Not tried: the control needs only its path.
        case notTried

        /// Something came back from the far end, so the way works.
        public var answered: Bool { self == .connected || self == .refused }
    }

    /// What one probe saw.
    public struct Probe: Codable, Equatable, Sendable {
        public var address: String
        /// The interface the routing table names for the address, and its next hop.
        public var routeInterface: String?
        public var gateway: String?
        /// The local address the socket was bound to, and the interface that holds it.
        public var sourceAddress: String?
        public var sourceInterface: String?
        public var answer: Answer
        /// How long the handshake took, when it completed or was refused.
        public var latencyMs: Double?

        public init(address: String, routeInterface: String? = nil, gateway: String? = nil,
                    sourceAddress: String? = nil, sourceInterface: String? = nil,
                    answer: Answer, latencyMs: Double? = nil) {
            self.address = address
            self.routeInterface = routeInterface
            self.gateway = gateway
            self.sourceAddress = sourceAddress
            self.sourceInterface = sourceInterface
            self.answer = answer
            self.latencyMs = latencyMs
        }

        /// The interface the connection left through: the source address's when the socket got
        /// one, else the one the routing table names.
        public var interface: String? { sourceInterface ?? routeInterface }
    }

    /// Which way an address should leave.
    public enum Way: Equatable, Sendable {
        /// Around every tunnel, through the physical interface.
        case physical
        /// Into this tunnel interface.
        case tunnel(String)

        /// "physical", or "tunnel:utun4": the form `vpnb why --json` prints.
        public var code: String {
            switch self {
            case .physical: return "physical"
            case .tunnel(let name): return "tunnel:\(name)"
            }
        }
    }

    /// One address judged against the way it should take.
    public enum Verdict: String, Codable, Equatable, Sendable {
        /// The expected way, and the site answered.
        case ok
        /// The expected way, but nothing answered on 443.
        case noAnswer
        /// Another way than expected.
        case wrongWay
        /// The kernel named no interface, so the way is unknown.
        case unknown
    }

    /// The control's outcome.
    public enum Control: Equatable, Sendable {
        /// It came back the way an unrouted address must take: the check can tell the ways apart.
        case passed
        /// It came back another way, through `interface`: the check cannot be trusted.
        case broken(interface: String?)
        /// Not run: there is only one way out (no VPN), or every candidate is routed.
        case notRun
    }

    // MARK: - Pure decisions

    /// Tunnel interfaces by name, as macOS and the VPN clients name them: the same prefixes
    /// the app's VPN detection accepts (Fortinet's feth, ZeroTier's zt included).
    public static func isTunnel(_ interface: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "gpd", "feth", "zt"].contains { interface.hasPrefix($0) }
    }

    /// Whether `interface` is the way `way` describes. Loopback and other non-tunnel interfaces
    /// count as physical: what matters is that no tunnel took the connection.
    public static func matches(_ interface: String, _ way: Way) -> Bool {
        switch way {
        case .physical: return !isTunnel(interface)
        case .tunnel(let name): return interface == name
        }
    }

    public static func verdict(_ probe: Probe, expected: Way) -> Verdict {
        guard let interface = probe.interface else { return .unknown }
        guard matches(interface, expected) else { return .wrongWay }
        return probe.answer.answered ? .ok : .noAnswer
    }

    /// The control has to come back the way an address the app does not route takes.
    public static func control(_ probe: Probe?, unrouted: Way?) -> Control {
        guard let probe, let unrouted else { return .notRun }
        guard let interface = probe.interface, matches(interface, unrouted) else {
            return .broken(interface: probe.interface)
        }
        return .passed
    }

    /// The way an address on the list takes, and the way every other address takes, in Bypass
    /// and VPN Only. Nil in Custom (each rule's route decides) and when no VPN is connected,
    /// since then there is only one way out and nothing to tell apart.
    public static func ways(mode: String, vpnInterface: String?) -> (listed: Way, unlisted: Way)? {
        guard let vpn = vpnInterface, !vpn.isEmpty else { return nil }
        switch mode {
        case "bypass": return (.physical, .tunnel(vpn))
        case "vpnOnly": return (.tunnel(vpn), .physical)
        default: return nil
        }
    }

    /// The way a route through `gateway` sends its addresses: our `iface:utunX` convention names
    /// the tunnel, the local gateway is physical, and any other next hop is the VPN's.
    public static func way(forGateway gateway: String, localGateway: String?, vpnInterface: String?) -> Way? {
        if gateway.hasPrefix("iface:") {
            let name = String(gateway.dropFirst("iface:".count))
            return isTunnel(name) ? .tunnel(name) : .physical
        }
        if let local = localGateway, gateway == local { return .physical }
        return vpnInterface.map { .tunnel($0) }
    }

    /// The first control candidate no app route covers. `routed` holds the destinations the app
    /// installed, host addresses and ranges alike; leave VPN Only's catch-alls out, since the
    /// control is meant to take them.
    public static func controlAddress(routed: [String]) -> String? {
        controlCandidates.first { candidate in
            !routed.contains { destination in
                destination.contains("/")
                    ? RuleResolver.ipv4(candidate, inCIDR: destination)
                    : destination == candidate
            }
        }
    }

    /// Several addresses judged at once: the worst verdict wins, so one address the wrong way
    /// makes the whole site read wrong.
    public static func worst(_ verdicts: [Verdict]) -> Verdict? {
        let rank: [Verdict: Int] = [.wrongWay: 3, .unknown: 2, .noAnswer: 1, .ok: 0]
        return verdicts.max { rank[$0]! < rank[$1]! }
    }

    // MARK: - Route Verification results

    /// One probe as Verify Routes' card shows it: reachable only when it took the expected way
    /// and answered, with a short reason otherwise (the card's row has room for a few words; the
    /// log line has the detail).
    static func verificationResult(_ probe: Probe, expected: Way?, control: Control,
                                   at date: Date = Date()) -> RouteVerificationResult {
        let error: String?
        if case .broken = control {
            error = brokenReason
        } else if let expected {
            switch verdict(probe, expected: expected) {
            case .ok: error = nil
            case .noAnswer: error = noAnswerReason(probe)
            case .wrongWay: error = wrongWayReason(probe.interface ?? "?", expected: expected)
            case .unknown: error = String(localized: "No interface")
            }
        } else {
            // No VPN: only one way out, so only the answer is checked.
            error = probe.answer.answered ? nil : noAnswerReason(probe)
        }
        return RouteVerificationResult(destination: probe.address, isReachable: error == nil,
                                       latency: error == nil ? probe.latencyMs : nil,
                                       timestamp: date, error: error, path: probe)
    }

    static func noAnswerReason(_ probe: Probe) -> String {
        let via = probe.interface ?? "?"
        return probe.answer == .failed
            ? String(localized: "Could not connect via \(via)")
            : String(localized: "No answer on 443 via \(via)")
    }

    static func wrongWayReason(_ interface: String, expected: Way) -> String {
        switch expected {
        case .physical: return String(localized: "Went into \(interface)")
        case .tunnel(let tunnel): return String(localized: "Went via \(interface), not \(tunnel)")
        }
    }

    /// Short, for the card's row; the notification and `vpnb why` give the whole sentence.
    static var brokenReason: String { String(localized: "Check broken") }

    // MARK: - The probe

    /// Probes off the main thread. Several run at once.
    static func probeAsync(_ address: String, waitForAnswer: Bool = true,
                           timeout: TimeInterval = PathCheck.timeout, port: UInt16 = PathCheck.port) async -> Probe {
        await withCheckedContinuation { continuation in
            vpnBypassProcessQueue.async {
                continuation.resume(returning: probe(address, waitForAnswer: waitForAnswer, timeout: timeout, port: port))
            }
        }
    }

    /// Blocking: asks the routing table, then connects. With `waitForAnswer` false it reads the
    /// source address and closes the socket before the handshake can complete; no packet but
    /// the first SYN leaves.
    public static func probe(_ address: String, waitForAnswer: Bool = true,
                             timeout: TimeInterval = PathCheck.timeout, port: UInt16 = PathCheck.port) -> Probe {
        let lookup = RouteKernel.lookup(address, timeout: 1)
        var result = Probe(address: address, routeInterface: lookup?.interfaceName,
                           gateway: lookup?.gatewayAddress, answer: .failed)

        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { return result }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return result }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let started = DispatchTime.now()
        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let connectErrno = errno
        // The kernel binds the source address when connect starts, before any reply.
        if let source = localAddress(fd) {
            result.sourceAddress = source
            result.sourceInterface = interfaceName(holding: source)
        }

        func elapsed() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        }

        if rc == 0 {
            result.answer = .connected
            result.latencyMs = elapsed()
            return result
        }
        switch connectErrno {
        case EINPROGRESS:
            break
        case ECONNREFUSED:
            result.answer = .refused
            result.latencyMs = elapsed()
            return result
        default:
            result.answer = .failed
            return result
        }
        guard waitForAnswer else {
            result.answer = .notTried
            return result
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { result.answer = .noAnswer; return result }
            let ready = poll(&pfd, 1, Int32(max(1, remaining * 1000)))
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { result.answer = ready == 0 ? .noAnswer : .failed; return result }
            break
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        switch soError {
        case 0:
            result.answer = .connected
            result.latencyMs = elapsed()
        case ECONNREFUSED:
            result.answer = .refused
            result.latencyMs = elapsed()
        case ETIMEDOUT:
            result.answer = .noAnswer
        default:
            result.answer = .failed
        }
        return result
    }

    /// The socket's bound IPv4 address, nil while unbound (0.0.0.0).
    private static func localAddress(_ fd: Int32) -> String? {
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0, local.sin_addr.s_addr != 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }

    /// The interface that holds `address`, from the system's interface list.
    static func interfaceName(holding address: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { continue }
            if String(cString: buf) == address { return String(cString: entry.pointee.ifa_name) }
        }
        return nil
    }
}
