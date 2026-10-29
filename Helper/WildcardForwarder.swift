// WildcardForwarder.swift
// Always-on wildcard domains: the DNS forwarder on 127.0.0.1:53530 and the resolver files that
// send lookups to it. Design: docs/research/wildcards-and-network-extension.md, option B.
//
// For each wildcard the app sets, `/etc/resolver/<suffix>` names this forwarder, so macOS sends
// every lookup under the suffix here. A lookup goes to the DNS server the wildcard's route
// would have used anyway (`WildcardSpec.upstream`, over a socket bound to `interface`); the
// IPv4 addresses in the answer pass the safety guard and the limiter, get their host route on
// `HelperTool.routeQueue` through the same install path and pacer as every other route, and
// only then does the answer go back, without any address that missed its route. AAAA gets an
// empty answer and HTTPS loses its `ipv6hint`, because the routes are IPv4 only. The decision
// itself is `WildcardLookup.reply`, tested from the app target; this file is its sockets.
//
// Runs only while the app has at least one wildcard set, and on a lease like DNSCapture: with
// no set or drain for `leaseSeconds` (the app quit, crashed or hung) it stops and removes its
// files, so lookups go back to the normal resolver instead of to a port nobody answers. At
// helper start, and on SIGTERM (`launchctl bootout` for an upgrade or an uninstall), the files
// are removed for the same reason.
//
// Names stay in memory for the length of one lookup and are never logged or kept.

import Darwin
import Foundation

final class WildcardForwarder {
    static let shared = WildcardForwarder()

    static let leaseSeconds: TimeInterval = 120
    /// Matched answers live at most this long in caches, so a name in use is asked again and
    /// its route's "last seen" keeps moving.
    static let ttlCap: UInt32 = 300
    static let upstreamTimeout: TimeInterval = 2
    /// The longest a reply waits for its routes. Past it the answer goes out without the
    /// addresses that wait, and their install is called off if it has not started.
    static let routeWait: TimeInterval = 1.5
    static let maxInFlight = 64
    static let maxTCPConnections = 16

    private let queue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.wildcards")
    private let ioQueue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.wildcards.io")
    private let workQueue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.wildcards.work", attributes: .concurrent)
    private let inFlight = DispatchSemaphore(value: WildcardForwarder.maxInFlight)
    private let tcpSlots = DispatchSemaphore(value: WildcardForwarder.maxTCPConnections)
    /// Resolver cache flushes run here, off `queue`: each one can take seconds, and lookups
    /// and drains wait on `queue`.
    private static let flushQueue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.wildcards.flush")
    /// Its own routing socket; the writes still go one at a time through `routeQueue` and the
    /// shared pacer.
    private let routeWriter = HelperTool()

    // State below is only touched on `queue`.
    private var specs: [WildcardSpec] = []
    private var safetyGuard = WildcardSafetyGuard()
    private var limiter = WildcardLearnLimiter()
    private var learned: [LearnedWildcardRoute] = []
    private var learnedSet: Set<LearnedWildcardRoute> = []
    private var lastRenew = DispatchTime.now()
    /// Moves on every stop and every change of the served list. A lookup that started under an
    /// older one installs nothing: the app has already stopped listening for its routes.
    private var generation: UInt64 = 0
    private var lastLimitLog: UInt64 = 0
    private var leaseTimer: DispatchSourceTimer?
    private var udpListener: UDPListener?
    private var tcpFD: Int32 = -1
    private var udpSource: DispatchSourceRead?
    private var tcpSource: DispatchSourceRead?

    // MARK: - App calls

    struct ConfigureResult {
        let ok: Bool
        let unserved: [String]
        let error: String?
    }

    /// Serves exactly `specs`: starts or stops the listeners, writes and removes resolver files.
    func configure(_ specs: [WildcardSpec], guard newGuard: WildcardSafetyGuard) -> ConfigureResult {
        queue.sync {
            lastRenew = .now()
            safetyGuard = newGuard
            safetyGuard.connectedNetworks = Self.connectedNetworks()
            limiter.keep(only: Set(specs.map(\.suffix)))
            guard !specs.isEmpty else {
                if stopLocked(reason: "no wildcard left") { Self.flushLater() }
                return ConfigureResult(ok: true, unserved: [], error: nil)
            }
            // Listeners first: a resolver file pointing at a port nobody answers would break
            // every lookup under its suffix.
            if udpListener == nil {
                if let error = startListenersLocked() {
                    if stopLocked(reason: "listener failed") { Self.flushLater() }
                    return ConfigureResult(ok: false, unserved: [], error: error)
                }
            }
            let result = Self.syncResolverFiles(wanted: Set(specs.map(\.suffix)))
            // A suffix whose file is someone else's is not ours to answer.
            let served = specs.filter { !result.foreign.contains($0.suffix) }
            if served != self.specs { generation &+= 1 }
            self.specs = served
            var changed = result.changed
            if self.specs.isEmpty {
                changed = stopLocked(reason: "every resolver file belongs to someone else") || changed
            } else {
                armLease()
            }
            if changed { Self.flushLater() }
            helperLog.info("wildcard: serving \(self.specs.count, privacy: .public), \(result.foreign.count, privacy: .public) left to another resolver file")
            return ConfigureResult(ok: true, unserved: result.foreign.sorted(), error: nil)
        }
    }

    /// Stops serving and removes the resolver files, for SIGTERM. Flushes before it returns,
    /// because the process exits next.
    func shutdown() {
        let changed = queue.sync { stopLocked(reason: "stopped: the helper is quitting") }
        if changed { HelperTool.flushResolverCaches() }
    }

    /// The routes learned since the last drain, and whether the forwarder runs. Renews the lease.
    func drain() -> (Bool, [LearnedWildcardRoute]) {
        queue.sync {
            lastRenew = .now()
            defer {
                learned.removeAll()
                learnedSet.removeAll()
            }
            return (udpListener != nil, learned)
        }
    }

    /// Removes every resolver file a previous run left. Called once at helper start: the
    /// forwarder they point at is not running yet, so each one would break its suffix.
    static func removeLeftoverResolverFiles() {
        let result = syncResolverFiles(wanted: [])
        if result.changed { HelperTool.flushResolverCaches() }
    }

    private static func flushLater() {
        flushQueue.async { HelperTool.flushResolverCaches() }
    }

    // MARK: - Lease

    private func armLease() {
        guard leaseTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastRenew.uptimeNanoseconds) / 1_000_000_000
            if idle > Self.leaseSeconds, self.stopLocked(reason: "stopped: the app stopped asking") { Self.flushLater() }
        }
        leaseTimer = timer
        timer.resume()
    }

    /// Stops serving and removes our resolver files. Returns whether a file went, so the
    /// caller flushes the resolver caches, outside `queue`.
    @discardableResult
    private func stopLocked(reason: String) -> Bool {
        leaseTimer?.cancel()
        leaseTimer = nil
        let wasRunning = udpListener != nil || !specs.isEmpty
        specs = []
        generation &+= 1
        udpSource?.cancel()
        tcpSource?.cancel()
        udpSource = nil
        tcpSource = nil
        udpListener = nil
        tcpFD = -1
        let result = Self.syncResolverFiles(wanted: [])
        if wasRunning { helperLog.info("wildcard forwarder \(reason, privacy: .public)") }
        return result.changed
    }

    // MARK: - Resolver files

    /// `WildcardResolverFile.sync` on /etc/resolver, with its errors logged.
    static func syncResolverFiles(wanted: Set<String>) -> WildcardResolverFile.SyncResult {
        let result = WildcardResolverFile.sync(wanted: wanted)
        for error in result.errors { helperLog.error("wildcard: \(error, privacy: .public)") }
        return result
    }

    /// The IPv4 network of every interface that is up, loopback aside.
    static func connectedNetworks() -> [(interface: String, network: UInt32, mask: UInt32)] {
        var out: [(interface: String, network: UInt32, mask: UInt32)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = ifa.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            out.append((String(cString: ifa.pointee.ifa_name), ip & mask, mask))
        }
        return out
    }

    // MARK: - Listeners

    private func startListenersLocked() -> String? {
        let udp = Self.bindLoopback(type: SOCK_DGRAM)
        guard udp >= 0 else { return "the DNS forwarder could not listen on UDP port \(WildcardResolverFile.port)" }
        let tcp = Self.bindLoopback(type: SOCK_STREAM)
        guard tcp >= 0, listen(tcp, 16) == 0 else {
            close(udp)
            if tcp >= 0 { close(tcp) }
            return "the DNS forwarder could not listen on TCP port \(WildcardResolverFile.port)"
        }
        let listener = UDPListener(fd: udp)
        udpListener = listener
        tcpFD = tcp

        let us = DispatchSource.makeReadSource(fileDescriptor: udp, queue: ioQueue)
        us.setEventHandler { [weak self] in self?.readUDP(listener) }
        // On `ioQueue`, like every reply's `sendto`: a reply that comes later sees `closed`
        // and is dropped, never sent on a number the system has handed to another socket.
        us.setCancelHandler {
            listener.closed = true
            close(udp)
        }
        let ts = DispatchSource.makeReadSource(fileDescriptor: tcp, queue: ioQueue)
        ts.setEventHandler { [weak self] in self?.acceptTCP(tcp) }
        ts.setCancelHandler { close(tcp) }
        udpSource = us
        tcpSource = ts
        us.resume()
        ts.resume()
        helperLog.info("wildcard forwarder listening on 127.0.0.1:\(WildcardResolverFile.port, privacy: .public)")
        return nil
    }

    private static func bindLoopback(type: Int32) -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = WildcardResolverFile.port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// The UDP socket and whether it has been closed. Only touched on `ioQueue`.
    private final class UDPListener {
        let fd: Int32
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    private func readUDP(_ listener: UDPListener) {
        let fd = listener.fd
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_storage()
            var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { sp in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            guard n > 0 else { return }
            let query = Array(buffer[0..<n])
            // Over the cap the query is dropped; the client retries in a second.
            guard inFlight.wait(timeout: .now()) == .success else { continue }
            workQueue.async { [weak self, ioQueue] in
                defer { self?.inFlight.signal() }
                guard let self, let reply = self.answer(query, overTCP: false) else { return }
                ioQueue.async {
                    guard !listener.closed else { return }
                    var to = from
                    _ = withUnsafePointer(to: &to) { sp in
                        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, fromLen) }
                    }
                }
            }
        }
    }

    private func acceptTCP(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard tcpSlots.wait(timeout: .now()) == .success else { close(client); continue }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            Self.setTimeouts(client, seconds: 5)
            workQueue.async { [weak self] in
                defer {
                    close(client)
                    self?.tcpSlots.signal()
                }
                // One connection may carry several queries; it ends at EOF, an error or 5 s idle.
                while let self, let query = Self.readFramed(client),
                      let reply = self.answer(query, overTCP: true),
                      Self.writeFramed(client, reply) {}
            }
        }
    }

    // MARK: - One lookup

    /// The reply to one query, or nil to send nothing (a message that is not a query).
    func answer(_ bytes: [UInt8], overTCP: Bool) -> [UInt8]? {
        let (specs, safetyGuard, generation) = queue.sync { (self.specs, self.safetyGuard, self.generation) }
        return WildcardLookup.reply(
            to: bytes, overTCP: overTCP, specs: specs, guard: safetyGuard, ttlCap: Self.ttlCap,
            forward: { query, spec in Self.forward(bytes, query: query, spec: spec, overTCP: overTCP) },
            admit: { candidates, spec in
                let now = DispatchTime.now().uptimeNanoseconds
                return self.queue.sync {
                    let admitted = candidates.filter { self.limiter.admit($0, suffix: spec.suffix, nowNS: now) }
                    // Count only, at most once a minute: a zone at its cap refuses every lookup.
                    if admitted.count < candidates.count, now &- self.lastLimitLog > 60_000_000_000 {
                        self.lastLimitLog = now
                        helperLog.info("wildcard: the limiter refused \(candidates.count - admitted.count, privacy: .public) new address(es)")
                    }
                    return admitted
                }
            },
            install: { ips, spec in self.installRoutes(ips, spec: spec, generation: generation) }
        )
    }

    /// One install handed to `routeQueue`. The lookup gives up on it after `routeWait`; if it
    /// has not started by then it never does.
    private final class PendingInstall {
        let lock = NSLock()
        var started = false
        var abandoned = false
        var installed: [String] = []
    }

    /// Adds the routes on `routeQueue` and waits for them, at most `routeWait`.
    private func installRoutes(_ ips: [String], spec: WildcardSpec, generation: UInt64) -> [String] {
        guard !ips.isEmpty else { return [] }
        let done = DispatchSemaphore(value: 0)
        let pending = PendingInstall()
        HelperTool.routeQueue.async { [routeWriter, weak self] in
            defer { done.signal() }
            guard let self else { return }
            pending.lock.lock()
            let go = !pending.abandoned
            pending.started = go
            pending.lock.unlock()
            // A stop or a new list since the lookup began: the app no longer takes these routes.
            guard go, self.queue.sync(execute: { self.generation == generation }) else { return }
            let result = routeWriter.installLearnedRoutes(ips, gateway: spec.gateway)
            pending.lock.lock()
            pending.installed = result
            pending.lock.unlock()
            self.record(result, suffix: spec.suffix, gateway: spec.gateway)
        }
        guard done.wait(timeout: .now() + Self.routeWait) == .success else {
            pending.lock.lock()
            let started = pending.started
            pending.abandoned = true
            pending.lock.unlock()
            helperLog.info("wildcard: replied without \(ips.count, privacy: .public) address(es); the route queue was busy\(started ? "" : ", install called off", privacy: .public)")
            return []
        }
        pending.lock.lock()
        defer { pending.lock.unlock() }
        return pending.installed
    }

    private func record(_ ips: [String], suffix: String, gateway: String) {
        queue.async {
            for ip in ips {
                let route = LearnedWildcardRoute(ip: ip, suffix: suffix, gateway: gateway)
                if self.learnedSet.insert(route).inserted { self.learned.append(route) }
            }
        }
    }

    // MARK: - Upstream

    /// The upstream's answer: each server in turn over UDP, and over TCP when the client asked
    /// over TCP or the UDP answer came back truncated.
    static func forward(_ bytes: [UInt8], query: DNSWire.Message, spec: WildcardSpec, overTCP: Bool) -> [UInt8]? {
        let index = if_nametoindex(spec.interface)
        guard index != 0 else { return nil }
        for server in spec.upstream {
            if !overTCP, let reply = udpExchange(bytes, query: query, server: server, ifIndex: index),
               let parsed = DNSWire.parse(reply), !parsed.isTruncated {
                return reply
            }
            if let reply = tcpExchange(bytes, query: query, server: server, ifIndex: index) {
                return reply
            }
        }
        return nil
    }

    private static func serverAddress(_ server: String) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    /// A socket that leaves by `ifIndex` whatever the routing table says: never through the
    /// forwarder again, and never into a tunnel the wildcard's route avoids.
    private static func boundSocket(type: Int32, ifIndex: UInt32) -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return -1 }
        var index = ifIndex
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connect(_ fd: Int32, to server: String) -> Bool {
        guard var addr = serverAddress(server) else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func udpExchange(_ bytes: [UInt8], query: DNSWire.Message, server: String, ifIndex: UInt32) -> [UInt8]? {
        let fd = boundSocket(type: SOCK_DGRAM, ifIndex: ifIndex)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        setTimeouts(fd, seconds: upstreamTimeout)
        guard connect(fd, to: server), send(fd, bytes, bytes.count, 0) == bytes.count else { return nil }
        let deadline = DispatchTime.now() + upstreamTimeout
        var buffer = [UInt8](repeating: 0, count: 65535)
        while DispatchTime.now() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            let reply = Array(buffer[0..<n])
            if let parsed = DNSWire.parse(reply), DNSWire.answers(parsed, query: query) { return reply }
        }
        return nil
    }

    static func tcpExchange(_ bytes: [UInt8], query: DNSWire.Message, server: String, ifIndex: UInt32) -> [UInt8]? {
        let fd = boundSocket(type: SOCK_STREAM, ifIndex: ifIndex)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // SO_SNDTIMEO also bounds a blocking connect on Darwin.
        setTimeouts(fd, seconds: upstreamTimeout)
        guard connect(fd, to: server), writeFramed(fd, bytes), let reply = readFramed(fd),
              let parsed = DNSWire.parse(reply), DNSWire.answers(parsed, query: query) else { return nil }
        return reply
    }

    /// One message with its two-byte length (RFC 1035 4.2.2).
    static func readFramed(_ fd: Int32) -> [UInt8]? {
        guard let head = readExactly(fd, 2) else { return nil }
        let length = Int(head[0]) << 8 | Int(head[1])
        guard length >= 12 else { return nil }
        return readExactly(fd, length)
    }

    static func writeFramed(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        guard bytes.count <= 0xFFFF else { return false }
        let framed = [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
        var sent = 0
        while sent < framed.count {
            let n = framed[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out[got...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }
            got += n
        }
        return out
    }
}
