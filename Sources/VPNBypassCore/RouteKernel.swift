// RouteKernel.swift
// Pure construction and parsing of routing-socket (PF_ROUTE) messages, shared between the app
// and the privileged helper, and unit-tested from the app test target.
//
// WHY THIS EXISTS — the traced root cause of the VPN instability this app used to trigger was
// not route *writes* in steady state (the corporate client debounces those and demonstrably
// tolerates hundreds); it was starving the client's periodic gateway-route *read*, whose
// timeout the client misreads as "my gateway route was removed" and tears the tunnel down.
// That starvation has two forms, both closed here:
//   1. SUBPROCESS CONTENTION (v3): every `/sbin/route` invocation is a fork+exec that opens
//      its own routing socket and blocks with no timeout; stacked invocations starved other
//      processes' route operations. Fixed by writing rt_msghdr structs to one owned socket —
//      no forks, one in-flight request, errno straight from write(2).
//   2. RECEIVE-BUFFER OVERFLOW (v4.6 follow-up): every RTM write, failed ones included, is
//      broadcast to every open routing socket, and the kernel silently DROPS messages for a
//      socket whose small receive buffer is full. An uninterrupted several-hundred-message
//      batch can therefore swallow the reply of a concurrent `route -n get` request/reply
//      exchange — observed live as the VPN client's read timing out seconds after our batch,
//      exactly while it was re-checking its gateway after a restore. Fixed by WritePacer
//      (end of this file): a short pause every few dozen writes bounds any listener's
//      backlog to well under one buffer.
//
// Layout notes that differ from other BSDs (the classic porting traps):
//   - sockaddr alignment inside a routing message is FOUR bytes on macOS, not sizeof(long).
//   - the netmask sockaddr is TRIMMED: sa_len covers only up to the last non-zero byte
//     (255.255.255.0 → sa_len 7), and host routes omit the netmask entirely and set RTF_HOST.
//   - sockaddrs follow the header positionally in RTA bit order: DST, GATEWAY, NETMASK.
// All struct layouts and constants come from the SDK via `import Darwin` — nothing is
// hand-computed.

import Foundation
import Darwin

public enum RouteKernel {

    // MARK: - Specs

    /// Where a route sends traffic.
    public enum Gateway: Equatable, Sendable {
        /// Next hop by IPv4 address ("192.168.1.1").
        case address(String)
        /// Direct interface route (`route add -interface`), by kernel interface index.
        case interfaceIndex(UInt16)
    }

    /// One route to install or remove, already validated by the caller.
    public struct Spec: Equatable, Sendable {
        public let destination: String   // "1.2.3.4" or "10.0.0.0/8" when isNetwork
        public let gateway: Gateway
        public let isNetwork: Bool

        public init(destination: String, gateway: Gateway, isNetwork: Bool) {
            self.destination = destination
            self.gateway = gateway
            self.isNetwork = isNetwork
        }
    }

    // MARK: - Message construction

    /// Routing-socket sockaddr alignment on macOS. Four bytes — NOT sizeof(long); copying the
    /// 8-byte ROUNDUP from FreeBSD/OpenBSD examples silently misaligns every sockaddr.
    public static func roundup(_ n: Int) -> Int {
        n > 0 ? (n + 3) & ~3 : 4
    }

    /// Builds a complete RTM_ADD / RTM_DELETE / RTM_CHANGE message for `spec`.
    ///
    /// Every route this app creates is tagged `RTF_PROTO1` — the ownership marker that lets a
    /// startup sweep identify OUR routes in a plain table dump with no journal, and lets any
    /// third party attribute them. (`RTF_PROTO3` must never be used: it is the kernel's own
    /// `RTPRF_OURS` garbage-collection marker and inviting the kernel to expire our routes.)
    ///
    /// Returns nil only for an unparseable destination/gateway (caller validated, so this is
    /// defense in depth).
    public static func message(type: Int32, seq: Int32, spec: Spec) -> Data? {
        let (dstIP, prefix): (UInt32, Int?)
        if spec.isNetwork {
            guard let cidr = RouteCIDR.parse(spec.destination),
                  let net = ipv4ToUInt32(cidr.network) else { return nil }
            (dstIP, prefix) = (net, cidr.prefixLength)
        } else {
            // Accept an accidental "/32" spelling of a host.
            let bare = spec.destination.hasSuffix("/32")
                ? String(spec.destination.dropLast(3)) : spec.destination
            guard let host = ipv4ToUInt32(bare) else { return nil }
            (dstIP, prefix) = (host, nil)
        }

        var flags: Int32 = RTF_UP | RTF_STATIC | RTF_PROTO1
        var addrs: Int32 = RTA_DST | RTA_GATEWAY
        var gatewayData: Data

        switch spec.gateway {
        case .address(let ip):
            guard let gw = ipv4ToUInt32(ip) else { return nil }
            flags |= RTF_GATEWAY
            gatewayData = sockaddrInData(gw)
        case .interfaceIndex(let index):
            // Direct interface route: gateway is an AF_LINK sockaddr naming the interface,
            // and RTF_GATEWAY must NOT be set.
            gatewayData = sockaddrDLData(index: index)
        }

        var maskData: Data? = nil
        if let prefix {
            addrs |= RTA_NETMASK
            maskData = trimmedMaskData(prefix: prefix)
        } else {
            flags |= RTF_HOST
        }

        // RTM_DELETE identifies the route by destination (+mask); a gateway is unnecessary and
        // a mismatched one can make the delete miss.
        if type == RTM_DELETE {
            addrs &= ~RTA_GATEWAY
            gatewayData = Data()
        }

        var hdr = rt_msghdr()
        hdr.rtm_version = u_char(RTM_VERSION)
        hdr.rtm_type = u_char(type)
        hdr.rtm_flags = flags
        hdr.rtm_addrs = addrs
        hdr.rtm_seq = seq
        // rtm_pid is stamped by the kernel; rtm_index only matters for RTF_IFSCOPE (unused here).

        var body = Data()
        body.append(paddedSockaddr(sockaddrInData(dstIP)))
        if !gatewayData.isEmpty { body.append(paddedSockaddr(gatewayData)) }
        if let maskData { body.append(paddedSockaddr(maskData)) }

        hdr.rtm_msglen = u_short(MemoryLayout<rt_msghdr>.size + body.count)
        var out = withUnsafeBytes(of: &hdr) { Data($0) }
        out.append(body)
        return out
    }

    // MARK: - Table parsing (NET_RT_DUMP)

    /// One route as read back from the kernel.
    public struct KernelRoute: Equatable, Sendable {
        public let destination: UInt32       // network byte order host value (big-endian semantics)
        public let prefix: Int?              // nil = host route
        public let gatewayAddress: UInt32?   // set when the gateway is an AF_INET next hop
        public let gatewayInterfaceIndex: UInt16?  // set when the gateway is AF_LINK
        public let flags: Int32

        public var isOurs: Bool { flags & RTF_PROTO1 != 0 }
        public var isHost: Bool { prefix == nil }

        /// Dotted-quad plus optional /prefix, matching the app's destination strings.
        public var destinationString: String {
            let d = dotted(destination)
            if let prefix { return "\(d)/\(prefix)" }
            return d
        }
    }

    /// Parses the raw bytes of a `sysctl NET_RT_DUMP` (AF_INET) into routes.
    ///
    /// This read is SILENT — it broadcasts nothing to routing-socket listeners and forks
    /// nothing, unlike `route -n get`, which does both once per destination. One dump replaces
    /// hundreds of per-route reads.
    public static func parseTable(_ data: Data) -> [KernelRoute] {
        var routes: [KernelRoute] = []
        var offset = 0
        let hdrSize = MemoryLayout<rt_msghdr>.size

        while offset + hdrSize <= data.count {
            let hdr: rt_msghdr = data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
            }
            let msglen = Int(hdr.rtm_msglen)
            guard msglen >= hdrSize, offset + msglen <= data.count else { break }
            defer { offset += msglen }

            guard hdr.rtm_version == u_char(RTM_VERSION) else { continue }

            var cursor = offset + hdrSize
            let end = offset + msglen
            var dst: UInt32? = nil
            var gwAddr: UInt32? = nil
            var gwIndex: UInt16? = nil
            var maskPrefix: Int? = nil
            var sawMask = false

            // Sockaddrs are positional in RTA bit order.
            for bit in 0..<31 {
                let rta = Int32(1) << bit
                guard hdr.rtm_addrs & rta != 0 else { continue }
                guard cursor < end else { break }
                let saLen = Int(data[cursor])
                let family = cursor + 1 < end ? data[cursor + 1] : 0
                let advance = roundup(saLen)

                switch rta {
                case RTA_DST:
                    dst = readIPv4(data, at: cursor, saLen: saLen)
                case RTA_GATEWAY:
                    if family == u_char(AF_INET) {
                        gwAddr = readIPv4(data, at: cursor, saLen: saLen)
                    } else if family == u_char(AF_LINK), saLen >= 4 {
                        // sockaddr_dl: sdl_index at offset 2 (little-endian in memory).
                        gwIndex = UInt16(data[cursor + 2]) | (UInt16(data[cursor + 3]) << 8)
                    }
                case RTA_NETMASK:
                    sawMask = true
                    maskPrefix = prefixFromTrimmedMask(data, at: cursor, saLen: saLen)
                default:
                    break
                }
                cursor += advance
            }

            guard let dst else { continue }
            let isHost = hdr.rtm_flags & RTF_HOST != 0 || !sawMask
            routes.append(KernelRoute(
                destination: dst,
                prefix: isHost ? nil : maskPrefix,
                gatewayAddress: gwAddr,
                gatewayInterfaceIndex: gwIndex,
                flags: hdr.rtm_flags
            ))
        }
        return routes
    }

    /// Whether a table entry may be compared against a route we are about to install.
    ///
    /// Every exclusion here is a way the snapshot could otherwise answer "already correct"
    /// about a DIFFERENT route than the one being installed — which silently skips a needed
    /// write and leaves the bypass not working, with no error anywhere.
    ///
    /// - `RTF_WASCLONED`: kernel-minted clone of a parent route, expires on its own.
    /// - `RTF_LLINFO`: an ARP entry, not a route. It carries an AF_LINK gateway and shares a
    ///   destination with real routes, so it can shadow one in a destination-keyed index.
    /// - `RTF_IFSCOPE`: bound to one interface, so it does NOT serve ordinary unbound traffic
    ///   and is invisible to the lookups our routes must win. It shares the destination string
    ///   with the unscoped route (this machine carries a scoped default alongside the real
    ///   one), so without this it would overwrite the entry we actually needed to compare.
    /// - `RTF_REJECT` / `RTF_BLACKHOLE`: placeholders that drop traffic rather than carry it.
    /// - not `RTF_UP`: a down route carries nothing.
    public static func isComparableEntry(_ flags: Int32) -> Bool {
        flags & RTF_UP != 0
            && flags & RTF_WASCLONED == 0
            && flags & RTF_LLINFO == 0
            && flags & RTF_IFSCOPE == 0
            && flags & RTF_REJECT == 0
            && flags & RTF_BLACKHOLE == 0
    }

    /// Reads the live IPv4 routing table via sysctl — silent and unprivileged.
    public static func currentTable() -> [KernelRoute]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        // The table can grow between the size probe and the read — retry with headroom.
        for slack in [0, needed / 2, needed] {
            var size = needed + slack
            var buf = Data(count: size)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0) == 0
            }
            if ok {
                return parseTable(buf.prefix(size))
            }
        }
        return nil
    }

    // MARK: - Sockaddr builders (internal for tests)

    static func sockaddrInData(_ ip: UInt32) -> Data {
        var sin = sockaddr_in()
        sin.sin_len = u_char(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr = in_addr(s_addr: ip.bigEndian)
        return withUnsafeBytes(of: &sin) { Data($0) }
    }

    /// The trimmed netmask sockaddr: sa_len reaches only the last non-zero byte.
    /// 255.255.255.0 → sa_len 7 · 255.255.0.0 → 6 · 255.0.0.0 → 5 · 128.0.0.0 → 5.
    static func trimmedMaskData(prefix: Int) -> Data {
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        var bytes: [UInt8] = [0, u_char(AF_INET), 0, 0,
                              UInt8((mask >> 24) & 0xff), UInt8((mask >> 16) & 0xff),
                              UInt8((mask >> 8) & 0xff), UInt8(mask & 0xff)]
        var last = 0
        for i in 1..<bytes.count where bytes[i] != 0 { last = i }
        let saLen = last + 1
        bytes[0] = UInt8(saLen)
        return Data(bytes.prefix(saLen))
    }

    static func sockaddrDLData(index: UInt16) -> Data {
        var sdl = sockaddr_dl()
        sdl.sdl_len = u_char(MemoryLayout<sockaddr_dl>.size)
        sdl.sdl_family = sa_family_t(AF_LINK)
        sdl.sdl_index = index
        return withUnsafeBytes(of: &sdl) { Data($0) }
    }

    static func paddedSockaddr(_ sa: Data) -> Data {
        let target = roundup(sa.count)
        guard sa.count < target else { return sa }
        return sa + Data(count: target - sa.count)
    }

    // MARK: - Small helpers

    static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            value = (value << 8) | UInt32(b)
        }
        return value
    }

    static func dotted(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xff).\((ip >> 16) & 0xff).\((ip >> 8) & 0xff).\(ip & 0xff)"
    }

    static func readIPv4(_ data: Data, at cursor: Int, saLen: Int) -> UInt32? {
        // sockaddr_in: sin_addr at offset 4. A trimmed sockaddr may end early — missing
        // trailing bytes are zero by definition.
        var value: UInt32 = 0
        for i in 0..<4 {
            let idx = cursor + 4 + i
            let byte: UInt8 = (i + 4) < saLen && idx < data.count ? data[idx] : 0
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    static func prefixFromTrimmedMask(_ data: Data, at cursor: Int, saLen: Int) -> Int {
        var mask: UInt32 = 0
        for i in 0..<4 {
            let idx = cursor + 4 + i
            let byte: UInt8 = (i + 4) < saLen && idx < data.count ? data[idx] : 0
            mask = (mask << 8) | UInt32(byte)
        }
        return mask.nonzeroBitCount
    }
}

// MARK: - Write pacing

extension RouteKernel {
    /// Paces bursts of routing-socket writes so concurrent readers never lose messages.
    ///
    /// Every RTM write is broadcast to every open routing socket on the system, and a routing
    /// socket's receive buffer is small (8 KB by default — roughly fifty messages). When a
    /// socket's buffer is full the kernel silently drops further messages for it, which breaks
    /// any process mid request/reply on its own routing socket: most critically the corporate
    /// VPN client's forked gateway-route read, whose lost reply it misreads as "my gateway
    /// route was removed" and tears the tunnel down (the #65 failure, resurfacing via bursts
    /// instead of forks). Pausing after every `chunkSize` writes keeps any listener's backlog
    /// well under one buffer and gives readers a drain window. Single interactive operations
    /// never reach the chunk boundary, so they stay instant; a burst separated by more than
    /// `idleResetNanoseconds` from the previous write starts a fresh chunk count.
    ///
    /// Pure value type — the caller supplies monotonic timestamps and performs the actual
    /// sleep, so the pacing decision is unit-testable.
    public struct WritePacer {
        public let chunkSize: Int
        public let pauseMicroseconds: UInt32
        public let idleResetNanoseconds: UInt64
        private var burstCount = 0
        private var lastWriteNS: UInt64 = 0

        public init(chunkSize: Int = 32,
                    pauseMicroseconds: UInt32 = 200_000,
                    idleResetNanoseconds: UInt64 = 1_000_000_000) {
            // recordWrite computes `burstCount % chunkSize` — a non-positive chunk would trap
            // (or never pause); this is a programmer-error boundary, not runtime input.
            precondition(chunkSize > 0, "WritePacer chunkSize must be positive")
            self.chunkSize = chunkSize
            self.pauseMicroseconds = pauseMicroseconds
            self.idleResetNanoseconds = idleResetNanoseconds
        }

        /// Record one write occurring at `nowNS` (monotonic clock). Returns true when the
        /// caller should pause for `pauseMicroseconds` before issuing the next write.
        public mutating func recordWrite(nowNS: UInt64) -> Bool {
            if lastWriteNS != 0 && nowNS &- lastWriteNS > idleResetNanoseconds {
                burstCount = 0
            }
            lastWriteNS = nowNS
            burstCount += 1
            return burstCount % chunkSize == 0
        }
    }
}
