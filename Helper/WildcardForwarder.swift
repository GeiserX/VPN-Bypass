// WildcardForwarder.swift
// Always-on wildcard domains: the DNS forwarder on 127.0.0.1:53530 and the resolver files that
// send lookups to it. Design: docs/research/wildcards-and-network-extension.md, option B.
//
// For each wildcard the app sets, `/etc/resolver/<suffix>` names this forwarder, so macOS sends
// every lookup under the suffix here. A lookup goes to the DNS server the wildcard's route
// would have used anyway (`WildcardSpec.upstream`, over a socket bound to `interface`); the
// IPv4 addresses in the answer pass the safety guard and the limiter, get their host route on
// `HelperTool.routeQueue` through the same install path and pacer as every other route, and
// only then does the answer go back. AAAA gets an empty answer and HTTPS loses its `ipv6hint`,
// because the routes are IPv4 only.
//
// Runs only while the app has at least one wildcard set, and on a lease like DNSCapture: with
// no set or drain for `leaseSeconds` (the app quit, crashed or hung) it stops and removes its
// files, so lookups go back to the normal resolver instead of to a port nobody answers. At
// helper start the files of a previous run are removed for the same reason.
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
    /// The longest a reply waits for its routes. Past it the answer goes out anyway and the
    /// routes land when `routeQueue` gets to them: a late route beats a failed lookup.
    static let routeWait: TimeInterval = 1.5
    static let maxInFlight = 64
    static let maxTCPConnections = 16

    private let queue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.wildcards")
    private let ioQueue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.wildcards.io")
    private let workQueue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.wildcards.work", attributes: .concurrent)
    private let inFlight = DispatchSemaphore(value: WildcardForwarder.maxInFlight)
    private let tcpSlots = DispatchSemaphore(value: WildcardForwarder.maxTCPConnections)
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
    private var leaseTimer: DispatchSourceTimer?
    private var udpFD: Int32 = -1
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
            limiter.keep(only: Set(specs.map(\.suffix)))
            guard !specs.isEmpty else {
                stopLocked(reason: "no wildcard left")
                return ConfigureResult(ok: true, unserved: [], error: nil)
            }
            // Listeners first: a resolver file pointing at a port nobody answers would break
            // every lookup under its suffix.
            if udpFD < 0 {
                if let error = startListenersLocked() {
                    stopLocked(reason: "listener failed")
                    return ConfigureResult(ok: false, unserved: [], error: error)
                }
            }
            self.specs = specs
            let result = Self.syncResolverFiles(wanted: Set(specs.map(\.suffix)))
            // A suffix whose file is someone else's is not ours to answer.
            self.specs = specs.filter { !result.foreign.contains($0.suffix) }
            if self.specs.isEmpty {
                stopLocked(reason: "every resolver file belongs to someone else")
            } else {
                armLease()
            }
            if result.changed { HelperTool.flushResolverCaches() }
            helperLog.info("wildcard: serving \(self.specs.count, privacy: .public), \(result.foreign.count, privacy: .public) left to another resolver file")
            return ConfigureResult(ok: true, unserved: result.foreign.sorted(), error: nil)
        }
    }

    /// The routes learned since the last drain, and whether the forwarder runs. Renews the lease.
    func drain() -> (Bool, [LearnedWildcardRoute]) {
        queue.sync {
            lastRenew = .now()
            defer {
                learned.removeAll()
                learnedSet.removeAll()
            }
            return (udpFD >= 0, learned)
        }
    }

    /// Removes every resolver file a previous run left. Called once at helper start: the
    /// forwarder they point at is not running yet, so each one would break its suffix.
    static func removeLeftoverResolverFiles() {
        let result = syncResolverFiles(wanted: [])
        if result.changed { HelperTool.flushResolverCaches() }
    }

    // MARK: - Lease

    private func armLease() {
        guard leaseTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastRenew.uptimeNanoseconds) / 1_000_000_000
            if idle > Self.leaseSeconds { self.stopLocked(reason: "stopped: the app stopped asking") }
        }
        leaseTimer = timer
        timer.resume()
    }

    private func stopLocked(reason: String) {
        leaseTimer?.cancel()
        leaseTimer = nil
        let wasRunning = udpFD >= 0 || !specs.isEmpty
        specs = []
        udpSource?.cancel()
        tcpSource?.cancel()
        udpSource = nil
        tcpSource = nil
        udpFD = -1
        tcpFD = -1
        let result = Self.syncResolverFiles(wanted: [])
        if result.changed { HelperTool.flushResolverCaches() }
        if wasRunning { helperLog.info("wildcard forwarder \(reason, privacy: .public)") }
    }

    // MARK: - Resolver files

    /// Writes our file for every suffix in `wanted` and removes our files for every other one.
    /// A file without our marker, or anything that is not a regular file, is someone else's:
    /// it is never written over or removed, and its suffix is reported in `foreign`.
    static func syncResolverFiles(wanted: Set<String>) -> (changed: Bool, foreign: Set<String>) {
        let dir = WildcardResolverFile.directory
        let fm = FileManager.default
        var changed = false
        var foreign: Set<String> = []

        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !wanted.contains(name) {
            let path = dir + "/" + name
            guard isRegularFile(path), let text = try? String(contentsOfFile: path, encoding: .utf8),
                  WildcardResolverFile.isOurs(text) else { continue }
            if unlink(path) == 0 { changed = true }
        }

        guard !wanted.isEmpty else { return (changed, foreign) }
        var info = stat()
        if lstat(dir, &info) != 0 {
            guard mkdir(dir, 0o755) == 0 else {
                helperLog.error("wildcard: cannot create \(dir, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
                return (changed, wanted)
            }
        } else if info.st_mode & S_IFMT != S_IFDIR {
            helperLog.error("wildcard: \(dir, privacy: .public) is not a directory")
            return (changed, wanted)
        }

        let contents = WildcardResolverFile.contents
        for suffix in wanted {
            // `WildcardSpec` already refused anything that is not a plain DNS name, so the
            // suffix cannot name a path; the check stays as the last word.
            guard WildcardDomain.normalizedSuffix(suffix) == suffix else { foreign.insert(suffix); continue }
            let path = dir + "/" + suffix
            var st = stat()
            if lstat(path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFREG,
                      let text = try? String(contentsOfFile: path, encoding: .utf8),
                      WildcardResolverFile.isOurs(text) else {
                    foreign.insert(suffix)
                    continue
                }
                if text == contents { continue }
            }
            // Write beside it, then rename over: the resolver never sees half a file.
            let temp = dir + "/.vpnbypass-" + suffix
            unlink(temp)
            guard fm.createFile(atPath: temp, contents: Data(contents.utf8),
                                attributes: [.posixPermissions: 0o644]),
                  rename(temp, path) == 0 else {
                unlink(temp)
                helperLog.error("wildcard: cannot write a resolver file: \(String(cString: strerror(errno)), privacy: .public)")
                foreign.insert(suffix)
                continue
            }
            changed = true
        }
        return (changed, foreign)
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
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
        udpFD = udp
        tcpFD = tcp

        let us = DispatchSource.makeReadSource(fileDescriptor: udp, queue: ioQueue)
        us.setEventHandler { [weak self] in self?.readUDP(udp) }
        us.setCancelHandler { close(udp) }
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

    private func readUDP(_ fd: Int32) {
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
            workQueue.async { [weak self] in
                defer { self?.inFlight.signal() }
                guard let self, let reply = self.answer(query, overTCP: false) else { return }
                var to = from
                _ = withUnsafePointer(to: &to) { sp in
                    sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, fromLen) }
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
        guard let query = DNSWire.parse(bytes), !query.isResponse, query.opcode == 0,
              query.questions.count == 1, let question = query.questions.first else { return nil }
        let name = question.name

        // DDR probe: say nothing, so the system has no encrypted endpoint to move to.
        if name == DNSWire.ddrName { return DNSWire.reply(to: query, rcode: DNSWire.rcodeNoError) }

        let (specs, safetyGuard) = queue.sync { (self.specs, self.safetyGuard) }
        guard let suffix = WildcardDomain.mostSpecific(for: name, among: specs.map(\.suffix)),
              let spec = specs.first(where: { $0.suffix == suffix }) else {
            return DNSWire.reply(to: query, rcode: DNSWire.rcodeRefused)
        }
        // The routes are IPv4 only; an IPv6 answer would take the connection past them.
        if question.type == DNSWire.typeAAAA { return DNSWire.reply(to: query, rcode: DNSWire.rcodeNoError) }

        guard let raw = Self.forward(bytes, query: query, spec: spec, overTCP: overTCP),
              let response = DNSWire.parse(raw) else {
            return DNSWire.reply(to: query, rcode: DNSWire.rcodeServFail)
        }

        // Guard, then limiter, then the kernel; only what got its route is kept as a hint.
        let candidates = DNSWire.addresses(in: response).filter { safetyGuard.refusal(for: $0) == nil }
        let now = DispatchTime.now().uptimeNanoseconds
        let admitted = queue.sync { candidates.filter { limiter.admit($0, suffix: suffix, nowNS: now) } }
        let routed = Set(installRoutes(admitted, gateway: spec.gateway, suffix: suffix))

        let rewritten = DNSWire.rewriteForWildcard(response, ttlCap: Self.ttlCap, keepHint: { routed.contains($0) })
        guard let out = DNSWire.encode(rewritten) else { return DNSWire.reply(to: query, rcode: DNSWire.rcodeServFail) }
        if !overTCP && out.count > query.maxUDPSize { return DNSWire.truncated(rewritten) }
        return out
    }

    /// Adds the routes on `routeQueue` and waits for them, at most `routeWait`.
    private func installRoutes(_ ips: [String], gateway: String, suffix: String) -> [String] {
        guard !ips.isEmpty else { return [] }
        let done = DispatchSemaphore(value: 0)
        var installed: [String] = []
        let lock = NSLock()
        HelperTool.routeQueue.async { [routeWriter, weak self] in
            let result = routeWriter.installLearnedRoutes(ips, gateway: gateway)
            lock.lock()
            installed = result
            lock.unlock()
            self?.record(result, suffix: suffix, gateway: gateway)
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.routeWait) == .success else {
            helperLog.info("wildcard: replied before \(ips.count, privacy: .public) route(s) were in; the route queue was busy")
            return []
        }
        lock.lock()
        defer { lock.unlock() }
        return installed
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
