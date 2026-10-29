// WildcardDNS.swift
// The pure half of always-on wildcard domains (`*.example.com`), compiled into the privileged
// helper too (see the Makefile) and unit-tested from the app target.
//
// How a wildcard works (docs/research/wildcards-and-network-extension.md, option B): the helper
// writes `/etc/resolver/<suffix>`, so macOS sends every lookup under the suffix to the helper's
// forwarder on 127.0.0.1:53530. The forwarder asks the real DNS server, adds a host route for
// each IPv4 address in the answer, and only then replies. The app connects after it has the
// answer, so the route is already there when it does.
//
// This file holds what both sides must agree on and what can be tested without root: the
// wildcard name rules, a minimal DNS message reader and writer, the safety guard that decides
// which addresses may be learned, the resolver file's contents, and the XPC payloads.
// Nothing here logs, and nothing here keeps a looked-up name.

import Foundation

// MARK: - Wildcard names

public enum WildcardDomain {
    /// How a wildcard is written on a list: `*.` and the suffix.
    public static let prefix = "*."

    public static func isWildcard(_ entry: String) -> Bool { entry.hasPrefix(prefix) }

    /// `*.example.com` from `example.com`. Also the `source` of every route a wildcard learns.
    public static func entry(for suffix: String) -> String { prefix + suffix }

    /// The suffix of a wildcard entry, or nil when `entry` is not a usable wildcard.
    public static func suffix(of entry: String) -> String? {
        guard isWildcard(entry) else { return nil }
        return normalizedSuffix(String(entry.dropFirst(prefix.count)))
    }

    /// A suffix in the form the resolver file is named after: lower case, no trailing dot, two
    /// labels at least (`*.com` would send a whole top-level domain through us), DNS characters
    /// only. Nil otherwise. The two-label rule is also what keeps a suffix from naming a path.
    public static func normalizedSuffix(_ raw: String) -> String? {
        var s = raw.lowercased()
        if s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, s.count <= 253 else { return nil }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
        }
        return s
    }

    /// The suffix itself or any name under it, at any depth. Same rule as the resolver file
    /// (`man 5 resolver`) and `RuleResolver.domainMatchesSuffix`.
    public static func matches(_ name: String, suffix: String) -> Bool {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        let s = suffix.lowercased()
        return n == s || n.hasSuffix("." + s)
    }

    /// The longest suffix that covers `name`, as macOS picks the resolver with the most
    /// matching labels: with `*.example.com` and `*.eu.example.com` both listed, a name under
    /// `eu.example.com` belongs to the second.
    public static func mostSpecific(for name: String, among suffixes: [String]) -> String? {
        suffixes.filter { matches(name, suffix: $0) }.max { $0.count < $1.count }
    }
}

// MARK: - IPv4 helpers

enum WildcardIPv4 {
    static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255, String(octet) == part else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    static func dotted(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    /// `(network, mask)` for "a.b.c.d/n", n from 0 to 32.
    static func parseCIDR(_ s: String) -> (network: UInt32, mask: UInt32)? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = parse(String(parts[0])),
              let prefix = Int(parts[1]), String(prefix) == parts[1], (0...32).contains(prefix) else { return nil }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
        return (ip & mask, mask)
    }
}

// MARK: - DNS messages

/// A minimal DNS message reader and writer (RFC 1035), enough for the forwarder: read a query,
/// read an answer, change it, write it back.
///
/// Records are read into owner names and data with every compression pointer expanded, and
/// written back uncompressed. Rewriting compressed bytes in place is not safe: dropping one record
/// or shrinking one HTTPS record moves every byte after it, and a later pointer into the moved
/// range would then name the wrong thing. An uncompressed message is valid DNS, only longer; the
/// forwarder truncates one that no longer fits the client's UDP size, and the client asks again
/// over TCP.
public enum DNSWire {
    public static let typeA: UInt16 = 1
    public static let typeNS: UInt16 = 2
    public static let typeCNAME: UInt16 = 5
    public static let typeSOA: UInt16 = 6
    public static let typePTR: UInt16 = 12
    public static let typeMX: UInt16 = 15
    public static let typeAAAA: UInt16 = 28
    public static let typeSRV: UInt16 = 33
    public static let typeDNAME: UInt16 = 39
    public static let typeOPT: UInt16 = 41
    public static let typeSVCB: UInt16 = 64
    public static let typeHTTPS: UInt16 = 65

    public static let rcodeNoError: UInt16 = 0
    public static let rcodeServFail: UInt16 = 2
    public static let rcodeRefused: UInt16 = 5

    /// SVCB / HTTPS parameter keys (RFC 9460).
    static let svcKeyIPv4Hint: UInt16 = 4
    static let svcKeyIPv6Hint: UInt16 = 6

    /// The name mDNSResponder asks for, type SVCB, when it first talks to a DNS server: Discovery
    /// of Designated Resolvers (RFC 9462), which asks whether the server also offers encrypted
    /// DNS. The forwarder must answer it with nothing, or macOS could move to the upstream's
    /// encrypted endpoint and stop asking us (seen in the 2026-10-29 spike; the bypass itself is
    /// inferred, not observed).
    public static let ddrName = "_dns.resolver.arpa"

    public struct Question: Equatable {
        public var labels: [[UInt8]]
        public var type: UInt16
        public var qclass: UInt16
        /// Lower case, dots between labels, no trailing dot.
        public var name: String { DNSWire.text(labels) }
    }

    public struct Record: Equatable {
        public var labels: [[UInt8]]
        public var type: UInt16
        public var rclass: UInt16
        public var ttl: UInt32
        /// The record data, with any names in it already expanded.
        public var data: [UInt8]
        public var name: String { DNSWire.text(labels) }
    }

    public struct Message: Equatable {
        public var id: UInt16
        public var flags: UInt16
        public var questions: [Question]
        public var answers: [Record]
        public var authority: [Record]
        public var additional: [Record]

        public var isResponse: Bool { flags & 0x8000 != 0 }
        public var opcode: UInt16 { (flags >> 11) & 0xF }
        public var isTruncated: Bool { flags & 0x0200 != 0 }
        public var rcode: UInt16 { flags & 0xF }

        /// The largest UDP reply the asker accepts: its EDNS size (RFC 6891), at least 512.
        public var maxUDPSize: Int {
            guard let opt = additional.first(where: { $0.type == DNSWire.typeOPT }) else { return 512 }
            return max(512, Int(opt.rclass))
        }
    }

    static func text(_ labels: [[UInt8]]) -> String {
        labels.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ".").lowercased()
    }

    // MARK: Reading

    public static func parse(_ bytes: [UInt8]) -> Message? {
        guard bytes.count >= 12 else { return nil }
        var r = Reader(bytes: bytes)
        guard let id = r.u16(), let flags = r.u16(), let qd = r.u16(), let an = r.u16(),
              let ns = r.u16(), let ar = r.u16() else { return nil }
        // A question is at least 5 bytes and a record at least 11, so a count larger than the
        // message could hold is a lie; refuse it before allocating anything for it.
        guard Int(qd) * 5 + (Int(an) + Int(ns) + Int(ar)) * 11 <= bytes.count - 12 else { return nil }
        var questions: [Question] = []
        for _ in 0..<qd {
            guard let labels = r.name(), let type = r.u16(), let qclass = r.u16() else { return nil }
            questions.append(Question(labels: labels, type: type, qclass: qclass))
        }
        func records(_ count: UInt16) -> [Record]? {
            var out: [Record] = []
            for _ in 0..<count {
                guard let labels = r.name(), let type = r.u16(), let rclass = r.u16(),
                      let ttl = r.u32(), let length = r.u16() else { return nil }
                let start = r.offset
                guard start + Int(length) <= bytes.count,
                      let data = expandedData(type: type, in: bytes, at: start, length: Int(length)) else { return nil }
                r.offset = start + Int(length)
                out.append(Record(labels: labels, type: type, rclass: rclass, ttl: ttl, data: data))
            }
            return out
        }
        guard let answers = records(an), let authority = records(ns), let additional = records(ar) else { return nil }
        return Message(id: id, flags: flags, questions: questions,
                       answers: answers, authority: authority, additional: additional)
    }

    /// The record data with its names expanded, for the types whose data may hold compressed
    /// names (RFC 1035 and RFC 2782 types). Every other type is copied as it is: RFC 3597 forbids
    /// compression in the data of any type defined later, SVCB and HTTPS included (RFC 9460).
    static func expandedData(type: UInt16, in bytes: [UInt8], at start: Int, length: Int) -> [UInt8]? {
        let end = start + length
        var r = Reader(bytes: bytes)
        r.offset = start
        var out: [UInt8] = []
        func copy(_ n: Int) -> Bool {
            guard r.offset + n <= end else { return false }
            out.append(contentsOf: bytes[r.offset..<(r.offset + n)])
            r.offset += n
            return true
        }
        func name() -> Bool {
            guard let labels = r.name(), r.offset <= end else { return false }
            writeName(labels, into: &out)
            return true
        }
        switch type {
        case typeCNAME, typeNS, typePTR, typeDNAME:
            guard name() else { return nil }
        case typeMX:
            guard copy(2), name() else { return nil }
        case typeSOA:
            guard name(), name(), copy(20) else { return nil }
        case typeSRV:
            guard copy(6), name() else { return nil }
        default:
            return Array(bytes[start..<end])
        }
        return r.offset == end ? out : nil
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u16() -> UInt16? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }

        mutating func u32() -> UInt32? {
            guard let hi = u16(), let lo = u16() else { return nil }
            return UInt32(hi) << 16 | UInt32(lo)
        }

        /// A name, following compression pointers. A pointer may only point backwards, which
        /// also rules out loops; the total length is capped at 255 bytes as RFC 1035 requires.
        mutating func name() -> [[UInt8]]? {
            var labels: [[UInt8]] = []
            var cursor = offset
            var jumped = false
            var total = 0
            while true {
                guard cursor < bytes.count else { return nil }
                let length = Int(bytes[cursor])
                if length & 0xC0 == 0xC0 {
                    guard cursor + 1 < bytes.count else { return nil }
                    let target = (length & 0x3F) << 8 | Int(bytes[cursor + 1])
                    guard target < cursor else { return nil }
                    if !jumped { offset = cursor + 2 }
                    jumped = true
                    cursor = target
                    continue
                }
                guard length & 0xC0 == 0 else { return nil }
                cursor += 1
                if length == 0 { break }
                guard cursor + length <= bytes.count else { return nil }
                total += length + 1
                guard total <= 255 else { return nil }
                labels.append(Array(bytes[cursor..<(cursor + length)]))
                cursor += length
            }
            if !jumped { offset = cursor }
            return labels
        }
    }

    // MARK: Writing

    static func writeName(_ labels: [[UInt8]], into out: inout [UInt8]) {
        for label in labels {
            out.append(UInt8(label.count))
            out.append(contentsOf: label)
        }
        out.append(0)
    }

    static func append(_ v: UInt16, to out: inout [UInt8]) {
        out.append(UInt8(v >> 8))
        out.append(UInt8(v & 0xFF))
    }

    static func append(_ v: UInt32, to out: inout [UInt8]) {
        append(UInt16(v >> 16), to: &out)
        append(UInt16(v & 0xFFFF), to: &out)
    }

    /// The message as bytes, uncompressed. Nil when a record's data is too long for its length field.
    public static func encode(_ m: Message) -> [UInt8]? {
        var out: [UInt8] = []
        append(m.id, to: &out)
        append(m.flags, to: &out)
        for count in [m.questions.count, m.answers.count, m.authority.count, m.additional.count] {
            guard count <= 0xFFFF else { return nil }
            append(UInt16(count), to: &out)
        }
        for q in m.questions {
            writeName(q.labels, into: &out)
            append(q.type, to: &out)
            append(q.qclass, to: &out)
        }
        for record in m.answers + m.authority + m.additional {
            guard record.data.count <= 0xFFFF else { return nil }
            writeName(record.labels, into: &out)
            append(record.type, to: &out)
            append(record.rclass, to: &out)
            append(record.ttl, to: &out)
            append(UInt16(record.data.count), to: &out)
            out.append(contentsOf: record.data)
        }
        return out
    }

    // MARK: Answers the forwarder writes itself

    /// A reply to `query` with no records and `rcode`: NOERROR with nothing in it is "no data"
    /// (the answer for AAAA and the DDR probe); REFUSED and SERVFAIL say what they say.
    public static func reply(to query: Message, rcode: UInt16) -> [UInt8] {
        // QR, the query's opcode and RD, RA, and the code.
        let flags: UInt16 = 0x8000 | (query.flags & 0x7900) | 0x0080 | (rcode & 0xF)
        let m = Message(id: query.id, flags: flags, questions: Array(query.questions.prefix(1)),
                        answers: [], authority: [], additional: [])
        return encode(m) ?? []
    }

    /// `response` cut to its header and question with TC set, for a UDP client whose size it
    /// no longer fits after rewriting. The client then asks again over TCP.
    public static func truncated(_ response: Message) -> [UInt8] {
        let m = Message(id: response.id, flags: response.flags | 0x0200, questions: response.questions,
                        answers: [], authority: [], additional: [])
        return encode(m) ?? []
    }

    /// Whether `response` answers `query`: same id, a response, the same question. The upstream
    /// socket is connected, so only the server can reach it; this is the second check.
    public static func answers(_ response: Message, query: Message) -> Bool {
        guard response.id == query.id, response.isResponse,
              let q = query.questions.first, let a = response.questions.first else { return false }
        return a.name == q.name && a.type == q.type && a.qclass == q.qclass
    }

    // MARK: Wildcard rewriting

    /// Every IPv4 address the answer section hands the client: A records, and the `ipv4hint`
    /// of HTTPS and SVCB records. Glue and other records in the additional section are left out,
    /// because a client does not connect to them.
    public static func addresses(in m: Message) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func add(_ ip: String) { if seen.insert(ip).inserted { out.append(ip) } }
        for record in m.answers {
            if let ip = ipv4(of: record) {
                add(ip)
            } else if record.type == typeHTTPS || record.type == typeSVCB {
                for ip in svcHints(record.data) { add(ip) }
            }
        }
        return out
    }

    /// The address of an A record, nil for any other record.
    static func ipv4(of record: Record) -> String? {
        guard record.type == typeA, record.rclass == 1, record.data.count == 4 else { return nil }
        return WildcardIPv4.dotted(record.data.reduce(0) { $0 << 8 | UInt32($1) })
    }

    /// The answer as the client gets it:
    /// - every AAAA record dropped (the app routes IPv4 only, so an IPv6 answer would carry the
    ///   connection past the route we just added);
    /// - every A record in the answer section whose address `keepAddress` refuses dropped, so
    ///   the client never connects to an address that missed its route;
    /// - every HTTPS and SVCB record without `ipv6hint`, and with only the `ipv4hint` addresses
    ///   `keepAddress` accepts (the key goes when none is left); a record whose data cannot be
    ///   read is dropped rather than passed on with hints we could not check;
    /// - every TTL capped at `ttlCap`, so the client asks again and the route's "last seen" moves.
    /// The OPT record is left alone: its TTL field holds EDNS flags, not a time.
    public static func rewriteForWildcard(_ m: Message, ttlCap: UInt32, keepAddress: (String) -> Bool) -> Message {
        func rewrite(_ records: [Record], filterA: Bool) -> [Record] {
            records.compactMap { record in
                if record.type == typeOPT { return record }
                if record.type == typeAAAA { return nil }
                if filterA, let ip = ipv4(of: record), !keepAddress(ip) { return nil }
                var r = record
                r.ttl = min(r.ttl, ttlCap)
                if r.type == typeHTTPS || r.type == typeSVCB {
                    guard let data = rewriteSVC(r.data, keepHint: keepAddress) else { return nil }
                    r.data = data
                }
                return r
            }
        }
        var out = m
        out.answers = rewrite(m.answers, filterA: true)
        out.authority = rewrite(m.authority, filterA: false)
        out.additional = rewrite(m.additional, filterA: false)
        return out
    }

    // MARK: Following a chain

    /// The labels of the uncompressed name at the start of `data` (record data after `parse`).
    static func leadingName(_ data: [UInt8]) -> [[UInt8]]? {
        var labels: [[UInt8]] = []
        var offset = 0
        while offset < data.count {
            let length = Int(data[offset])
            guard length & 0xC0 == 0 else { return nil }
            offset += 1
            if length == 0 { return labels }
            guard offset + length <= data.count else { return nil }
            labels.append(Array(data[offset..<(offset + length)]))
            offset += length
        }
        return nil
    }

    /// `m` with its CNAME chain folded onto the asked name: the records of the asked type at the
    /// end of the chain, under the asked name, with the shortest TTL along the way; the CNAME and
    /// DNAME records themselves are gone. A chain that leaves the wildcard (`x.example.com` to
    /// `y.cdn.net`) otherwise sends macOS to ask for `y.cdn.net` itself, through the normal
    /// resolver: mDNSResponder does not take the chained records from our answer (seen on macOS
    /// 26.6 on 2026-10-29), so the address the app connects to is one we never routed. A chain
    /// that ends without a record of the type is "no data" for the name, as it was for the target.
    public static func flattened(_ m: Message) -> Message {
        guard let question = m.questions.first,
              question.type != typeCNAME, question.type != typeDNAME, question.type != 255,
              m.answers.contains(where: { $0.type == typeCNAME || $0.type == typeDNAME }) else { return m }
        var name = question.name
        var seen: Set<String> = [name]
        var ttl = UInt32.max
        while let link = m.answers.first(where: { $0.type == typeCNAME && $0.rclass == question.qclass && $0.name == name }) {
            guard let target = leadingName(link.data) else { break }
            ttl = min(ttl, link.ttl)
            name = text(target)
            // A loop, or a chain longer than any resolver follows: nothing at the end of it.
            guard seen.insert(name).inserted, seen.count <= 16 else {
                name = ""
                break
            }
        }
        var out = m
        out.answers = m.answers.compactMap { record in
            guard !name.isEmpty, record.name == name, record.type == question.type, record.rclass == question.qclass else { return nil }
            var r = record
            r.labels = question.labels
            r.ttl = min(r.ttl, ttl)
            return r
        }
        return out
    }

    /// `m` without the HTTPS and SVCB answers that would send the client to a name we do not
    /// answer: AliasMode records (priority 0) and ServiceMode records whose TargetName is
    /// neither "." (the owner, which after `flattened` is the asked name) nor a name
    /// `keepTarget` accepts. With none left the client falls back to A for the asked name,
    /// which comes through us.
    public static func withoutForeignServiceTargets(_ m: Message, keepTarget: (String) -> Bool) -> Message {
        var out = m
        out.answers = m.answers.filter { record in
            guard record.type == typeHTTPS || record.type == typeSVCB else { return true }
            guard record.data.count >= 3, record.data[0] != 0 || record.data[1] != 0,
                  let target = leadingName(Array(record.data.dropFirst(2))) else { return false }
            return target.isEmpty || keepTarget(text(target))
        }
        return out
    }

    /// SVCB / HTTPS data: SvcPriority, TargetName (never compressed), then key, length, value.
    static func svcParams(_ data: [UInt8]) -> (head: [UInt8], params: [(key: UInt16, value: [UInt8])])? {
        guard data.count >= 3 else { return nil }
        var offset = 2
        while true {
            guard offset < data.count else { return nil }
            let length = Int(data[offset])
            guard length & 0xC0 == 0 else { return nil }   // compression is not allowed here
            offset += 1 + length
            if length == 0 { break }
        }
        guard offset <= data.count else { return nil }
        let head = Array(data[0..<offset])
        var params: [(key: UInt16, value: [UInt8])] = []
        while offset < data.count {
            guard offset + 4 <= data.count else { return nil }
            let key = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4
            guard offset + length <= data.count else { return nil }
            params.append((key, Array(data[offset..<(offset + length)])))
            offset += length
        }
        return (head, params)
    }

    static func svcHints(_ data: [UInt8]) -> [String] {
        guard let parsed = svcParams(data),
              let hint = parsed.params.first(where: { $0.key == svcKeyIPv4Hint }),
              hint.value.count % 4 == 0 else { return [] }
        return stride(from: 0, to: hint.value.count, by: 4).map { i in
            WildcardIPv4.dotted(hint.value[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) })
        }
    }

    static func rewriteSVC(_ data: [UInt8], keepHint: (String) -> Bool) -> [UInt8]? {
        guard let parsed = svcParams(data) else { return nil }
        var out = parsed.head
        for param in parsed.params {
            var value = param.value
            switch param.key {
            case svcKeyIPv6Hint:
                continue
            case svcKeyIPv4Hint:
                guard value.count % 4 == 0 else { return nil }
                value = stride(from: 0, to: value.count, by: 4).flatMap { i -> [UInt8] in
                    let chunk = Array(value[i..<(i + 4)])
                    let ip = WildcardIPv4.dotted(chunk.reduce(0) { $0 << 8 | UInt32($1) })
                    return keepHint(ip) ? chunk : []
                }
                if value.isEmpty { continue }
            default:
                break
            }
            append(param.key, to: &out)
            append(UInt16(value.count), to: &out)
            out.append(contentsOf: value)
        }
        return out
    }
}

// MARK: - Safety guard

/// Which learned addresses may get a route. Whoever answers DNS for a wildcard's zone now picks
/// addresses we route, so the helper refuses the ones that would hand them the local network,
/// another network service's space, the VPN's own server or our DNS servers.
public struct WildcardSafetyGuard: Equatable {
    public enum Refusal: String, Equatable {
        /// Private, CGNAT, loopback, link-local, multicast, reserved or documentation space.
        case notPublic
        /// `ProtectedDestinations`: Tailscale's range, MagicDNS and kernel space.
        case protected
        /// The VPN server, its gateway, or a DNS server in use.
        case excludedHost
        /// Inside a VPN Only range the user listed.
        case insideExcludedRange
        /// On a network this Mac is directly attached to, other than the wildcard's tunnel.
        case connectedNetwork
    }

    /// Blocks no public address may be learned into: RFC 6890 special-purpose space.
    static let nonPublicBlocks: [(UInt32, UInt32)] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15",
        "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
    ].compactMap { WildcardIPv4.parseCIDR($0).map { ($0.network, $0.mask) } }

    /// What a wildcard into a tunnel still refuses. Its names live on the company network, so
    /// private and CGNAT space is exactly what it must route; this-network, loopback,
    /// link-local, multicast and reserved space never can be.
    static let neverRoutedBlocks: [(UInt32, UInt32)] = [
        "0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
    ].compactMap { WildcardIPv4.parseCIDR($0).map { ($0.network, $0.mask) } }

    public var excludedHosts: Set<UInt32>
    public var excludedRanges: [(network: UInt32, mask: UInt32)]
    /// The IPv4 networks of the Mac's own interfaces, by interface. Filled in by the helper
    /// from the live interfaces, never sent over XPC: a tunnel wildcard must not pull a host
    /// of the local network into the tunnel.
    public var connectedNetworks: [(interface: String, network: UInt32, mask: UInt32)] = []

    public init(excludedHosts: [String] = [], excludedRanges: [String] = []) {
        self.excludedHosts = Set(excludedHosts.compactMap(WildcardIPv4.parse))
        self.excludedRanges = excludedRanges.compactMap(WildcardIPv4.parseCIDR)
    }

    public static func == (a: WildcardSafetyGuard, b: WildcardSafetyGuard) -> Bool {
        a.excludedHosts == b.excludedHosts
            && a.excludedRanges.map { [$0.network, $0.mask] } == b.excludedRanges.map { [$0.network, $0.mask] }
    }

    /// Why `ip` must not be learned for `spec`, or nil when it may. A wildcard around the VPN
    /// learns public addresses only; one into a tunnel may learn private ones too, except on a
    /// network the Mac is attached to by another interface.
    public func refusal(for ip: String, spec: WildcardSpec? = nil) -> Refusal? {
        guard let v = WildcardIPv4.parse(ip) else { return .notPublic }
        if let spec, spec.intoTunnel {
            if Self.neverRoutedBlocks.contains(where: { v & $0.1 == $0.0 }) { return .notPublic }
            if connectedNetworks.contains(where: { $0.interface != spec.interface && v & $0.mask == $0.network }) {
                return .connectedNetwork
            }
        } else if Self.nonPublicBlocks.contains(where: { v & $0.1 == $0.0 }) {
            return .notPublic
        }
        if ProtectedDestinations.isProtected(ip) { return .protected }
        if excludedHosts.contains(v) { return .excludedHost }
        if excludedRanges.contains(where: { v & $0.mask == $0.network }) { return .insideExcludedRange }
        return nil
    }

    /// The payload the app sends with the wildcard list.
    public var dictionary: [String: String] {
        ["excludedHosts": excludedHosts.sorted().map(WildcardIPv4.dotted).joined(separator: ","),
         "excludedRanges": excludedRanges.map {
             "\(WildcardIPv4.dotted($0.network))/\(32 - $0.mask.trailingZeroBitCount)"
         }.joined(separator: ",")]
    }

    public init(dictionary: [String: String]) {
        func list(_ key: String) -> [String] {
            (dictionary[key] ?? "").split(separator: ",").map(String.init)
        }
        self.init(excludedHosts: list("excludedHosts"), excludedRanges: list("excludedRanges"))
    }
}

/// Caps how many addresses each wildcard learns: in total over the last day, and new ones per
/// minute. A zone that answers every lookup with a fresh address can otherwise fill the routing
/// table. An address already learned is always accepted, so a busy wildcard keeps its "last
/// seen" times moving. One not seen for a day is forgotten once the cap is reached, as the app
/// expires its route after a day unused, so a CDN whose addresses rotate keeps learning.
public struct WildcardLearnLimiter {
    public static let maxPerWildcard = 2048
    public static let maxNewPerMinute = 120
    public static let forgetAfterNS: UInt64 = 24 * 3600 * 1_000_000_000

    /// Suffix, then address, then when it was last admitted.
    private var known: [String: [String: UInt64]] = [:]
    private var recent: [String: [UInt64]] = [:]

    public init() {}

    public mutating func admit(_ ip: String, suffix: String, nowNS: UInt64) -> Bool {
        if known[suffix]?[ip] != nil {
            known[suffix]?[ip] = nowNS
            return true
        }
        let minuteAgo = nowNS > 60_000_000_000 ? nowNS - 60_000_000_000 : 0
        var times = (recent[suffix] ?? []).filter { $0 > minuteAgo }
        if (known[suffix]?.count ?? 0) >= Self.maxPerWildcard {
            let dayAgo = nowNS > Self.forgetAfterNS ? nowNS - Self.forgetAfterNS : 0
            known[suffix] = known[suffix]?.filter { $0.value > dayAgo }
        }
        guard (known[suffix]?.count ?? 0) < Self.maxPerWildcard, times.count < Self.maxNewPerMinute else {
            recent[suffix] = times
            return false
        }
        times.append(nowNS)
        recent[suffix] = times
        known[suffix, default: [:]][ip] = nowNS
        return true
    }

    /// Drops what it knows of the suffixes not in `suffixes`.
    public mutating func keep(only suffixes: Set<String>) {
        known = known.filter { suffixes.contains($0.key) }
        recent = recent.filter { suffixes.contains($0.key) }
    }
}

// MARK: - Resolver files

public enum WildcardResolverFile {
    public static let directory = "/etc/resolver"
    public static let port: UInt16 = 53530
    /// The first line of every file the helper writes. A file in /etc/resolver without it
    /// belongs to someone else (a VPN client, Tailscale, a developer tool) and is never touched.
    public static let marker = "# VPN-BYPASS-MANAGED wildcard resolver"

    public static var contents: String {
        """
        \(marker): written by the VPN Bypass helper and removed with the wildcard. Do not edit.
        nameserver 127.0.0.1
        port \(port)
        search_order 1

        """
    }

    public static func isOurs(_ text: String) -> Bool {
        text.hasPrefix(marker)
    }

    public struct SyncResult: Equatable {
        public var changed = false
        /// Suffixes whose file is someone else's, or could not be written.
        public var foreign: Set<String> = []
        /// What went wrong, for the helper's log. Never a suffix or a name.
        public var errors: [String] = []
    }

    /// Writes our file for every suffix in `wanted` and removes our files for every other one.
    /// A file without our marker, or anything that is not a regular file, is someone else's:
    /// it is never written over or removed, and its suffix is reported in `foreign`.
    public static func sync(wanted: Set<String>, in dir: String = directory) -> SyncResult {
        let fm = FileManager.default
        var result = SyncResult()

        // A directory that cannot be read is reported, never taken for an empty one: the files
        // of ours in it are still there, and the next sync tries again.
        var names: [String] = []
        do {
            names = try fm.contentsOfDirectory(atPath: dir)
        } catch CocoaError.fileReadNoSuchFile {
            // No directory, no files of ours.
        } catch {
            result.errors.append("cannot list \(dir): \((error as NSError).localizedFailureReason ?? "unreadable")")
        }
        for name in names where !wanted.contains(name) {
            let path = dir + "/" + name
            guard isRegularFile(path), let text = try? String(contentsOfFile: path, encoding: .utf8),
                  isOurs(text) else { continue }
            if unlink(path) == 0 { result.changed = true }
        }

        guard !wanted.isEmpty else { return result }
        var info = stat()
        if lstat(dir, &info) != 0 {
            guard mkdir(dir, 0o755) == 0 else {
                result.errors.append("cannot create \(dir): \(String(cString: strerror(errno)))")
                result.foreign = wanted
                return result
            }
        } else if info.st_mode & S_IFMT != S_IFDIR {
            result.errors.append("\(dir) is not a directory")
            result.foreign = wanted
            return result
        }

        for suffix in wanted {
            // `WildcardSpec` already refused anything that is not a plain DNS name, so the
            // suffix cannot name a path; the check stays as the last word.
            guard WildcardDomain.normalizedSuffix(suffix) == suffix else { result.foreign.insert(suffix); continue }
            let path = dir + "/" + suffix
            var st = stat()
            if lstat(path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFREG,
                      let text = try? String(contentsOfFile: path, encoding: .utf8),
                      isOurs(text) else {
                    result.foreign.insert(suffix)
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
                result.errors.append("cannot write a resolver file: \(String(cString: strerror(errno)))")
                result.foreign.insert(suffix)
                continue
            }
            result.changed = true
        }
        return result
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }
}

// MARK: - One lookup

/// The forwarder's answer to one query, without its sockets or the kernel, so every branch is
/// tested: the helper passes in how to ask the upstream, how the limiter admits and how the
/// routes go in.
public enum WildcardLookup {
    /// What became of the addresses handed to `install`.
    public struct Install: Equatable {
        /// The addresses that now have their route.
        public var installed: [String]
        /// The route queue did not get to them within the wait. They may still get their route
        /// later, or never.
        public var timedOut: Bool

        public init(installed: [String], timedOut: Bool = false) {
            self.installed = installed
            self.timedOut = timedOut
        }
    }

    /// The reply to `bytes`, or nil to send nothing (a message that is not a query).
    /// - `forward`: the upstream's raw answer for the spec, nil when none came.
    /// - `routed`: the addresses that already have our route to the spec's gateway. They are
    ///   answered at once, without the limiter or the route queue.
    /// - `admit`: the addresses the limiter lets the suffix learn.
    /// - `install`: what the kernel did with them.
    public static func reply(
        to bytes: [UInt8], overTCP: Bool, specs: [WildcardSpec], guard safetyGuard: WildcardSafetyGuard,
        ttlCap: UInt32,
        forward: (DNSWire.Message, WildcardSpec) -> [UInt8]?,
        routed: ([String], WildcardSpec) -> Set<String> = { _, _ in [] },
        admit: ([String], WildcardSpec) -> [String],
        install: ([String], WildcardSpec) -> Install
    ) -> [UInt8]? {
        guard let query = DNSWire.parse(bytes), !query.isResponse, query.opcode == 0,
              query.questions.count == 1, let question = query.questions.first else { return nil }
        let name = question.name

        // DDR probe: say nothing, so the system has no encrypted endpoint to move to.
        if name == DNSWire.ddrName { return DNSWire.reply(to: query, rcode: DNSWire.rcodeNoError) }

        guard let suffix = WildcardDomain.mostSpecific(for: name, among: specs.map(\.suffix)),
              let spec = specs.first(where: { $0.suffix == suffix }) else {
            return DNSWire.reply(to: query, rcode: DNSWire.rcodeRefused)
        }
        // The routes are IPv4 only; an IPv6 answer would take the connection past them.
        if question.type == DNSWire.typeAAAA { return DNSWire.reply(to: query, rcode: DNSWire.rcodeNoError) }

        guard let raw = forward(query, spec), let upstream = DNSWire.parse(raw) else {
            return DNSWire.reply(to: query, rcode: DNSWire.rcodeServFail)
        }
        // Every address under the asked name, and no name the client would look up elsewhere.
        let response = DNSWire.withoutForeignServiceTargets(DNSWire.flattened(upstream)) {
            WildcardDomain.matches($0, suffix: spec.suffix)
        }

        // Guard, then what is already routed, then the limiter, then the kernel. An address
        // the guard refuses is left to the routing table, as it would be without the wildcard.
        let candidates = DNSWire.addresses(in: response).filter { safetyGuard.refusal(for: $0, spec: spec) == nil }
        let already = candidates.isEmpty ? [] : routed(candidates, spec)
        let rest = candidates.filter { !already.contains($0) }
        let admitted = rest.isEmpty ? [] : admit(rest, spec)
        let outcome = admitted.isEmpty ? Install(installed: []) : install(admitted, spec)
        let withheld = withheldAddresses(candidates: candidates, alreadyRouted: already, admitted: admitted,
                                         outcome: outcome, spec: spec)

        // An address handed out past a busy queue has no route yet: a short TTL makes the
        // client ask again soon, when the route can be in, instead of keeping it for minutes.
        let handedOutUnrouted = outcome.timedOut && admitted.contains { !outcome.installed.contains($0) && !withheld.contains($0) }
        let rewritten = DNSWire.rewriteForWildcard(response, ttlCap: handedOutUnrouted ? min(ttlCap, unroutedTTL) : ttlCap,
                                                   keepAddress: { !withheld.contains($0) })
        // Every address gone: fail the lookup so the client asks again, rather than say the
        // name has none.
        let hadA = response.answers.contains { DNSWire.ipv4(of: $0) != nil }
        if hadA && !rewritten.answers.contains(where: { DNSWire.ipv4(of: $0) != nil }) {
            return DNSWire.reply(to: query, rcode: DNSWire.rcodeServFail)
        }
        guard let out = DNSWire.encode(rewritten) else { return DNSWire.reply(to: query, rcode: DNSWire.rcodeServFail) }
        if !overTCP && out.count > query.maxUDPSize { return DNSWire.truncated(rewritten) }
        return out
    }

    /// The TTL of an answer that holds an address handed out without its route.
    public static let unroutedTTL: UInt32 = 10

    /// The addresses taken out of the answer: those that passed the guard and have no route.
    /// A connection opened before its route lands goes the wrong way, and breaks or leaks
    /// when the route arrives, so the limiter's refusals and failed installs always go.
    /// A busy route queue is decided by direction: around the VPN (Bypass, Direct) the address
    /// is handed out anyway and the connection takes the VPN, as it did before wildcards,
    /// rather than fail the lookup; into a tunnel (VPN Only, a pinned VPN) it is withheld,
    /// because the same connection would leave by the physical interface.
    public static func withheldAddresses(candidates: [String], alreadyRouted: Set<String>, admitted: [String],
                                         outcome: Install, spec: WildcardSpec) -> Set<String> {
        var withheld = Set(candidates).subtracting(alreadyRouted).subtracting(outcome.installed)
        if outcome.timedOut && !spec.intoTunnel {
            withheld.subtract(admitted)
        }
        return withheld
    }

    /// The addresses among `ips` that already carry our host route (`RTF_PROTO1`) to `gateway`
    /// in `table` (a `RouteKernel.currentTable()` read, which is silent). `interfaceIndex`
    /// resolves an `iface:` gateway; nil when the interface is gone.
    public static func alreadyRouted(_ ips: [String], gateway: String, table: [RouteKernel.KernelRoute],
                                     interfaceIndex: (String) -> UInt16?) -> Set<String> {
        let wanted = Set(ips)
        var wantIndex: UInt16?
        var wantAddress: UInt32?
        if gateway.hasPrefix("iface:") {
            guard let index = interfaceIndex(String(gateway.dropFirst(6))) else { return [] }
            wantIndex = index
        } else {
            guard let address = WildcardIPv4.parse(gateway) else { return [] }
            wantAddress = address
        }
        var out: Set<String> = []
        for route in table where route.isHost && route.isOurs && RouteKernel.isComparableEntry(route.flags) {
            let ip = route.destinationString
            guard wanted.contains(ip) else { continue }
            if let wantIndex, route.gatewayInterfaceIndex == wantIndex, route.gatewayAddress == nil { out.insert(ip) }
            if let wantAddress, route.gatewayAddress == wantAddress { out.insert(ip) }
        }
        return out
    }
}

// MARK: - XPC payloads

/// One wildcard as the app hands it to the helper.
public struct WildcardSpec: Equatable, Sendable {
    public let suffix: String
    /// Where learned routes go: an IPv4 next hop, or `iface:utunN`.
    public let gateway: String
    /// The DNS servers asked for names under the suffix, in order.
    public let upstream: [String]
    /// The interface those queries leave by (`IP_BOUND_IF`): the physical one for Bypass and
    /// Direct, the tunnel for VPN Only and a pinned VPN.
    public let interface: String
    /// The route goes into a tunnel (VPN Only, a pinned VPN), whose names may resolve to
    /// private addresses on the company network. See `WildcardSafetyGuard.refusal`.
    public let intoTunnel: Bool

    public init(suffix: String, gateway: String, upstream: [String], interface: String, intoTunnel: Bool = false) {
        self.suffix = suffix
        self.gateway = gateway
        self.upstream = upstream
        self.interface = interface
        self.intoTunnel = intoTunnel
    }

    public var dictionary: [String: String] {
        var d = ["suffix": suffix, "gateway": gateway, "upstream": upstream.joined(separator: ","), "interface": interface]
        if intoTunnel { d["tunnel"] = "1" }
        return d
    }

    /// Nil unless every field is something the helper may act on. The helper re-checks the
    /// gateway at install time like every other route.
    public init?(dictionary d: [String: String]) {
        guard let suffix = d["suffix"], WildcardDomain.normalizedSuffix(suffix) == suffix,
              let gateway = d["gateway"], Self.isValidGateway(gateway),
              let interface = d["interface"], Self.isValidInterfaceName(interface) else { return nil }
        let upstream = (d["upstream"] ?? "").split(separator: ",").map(String.init)
        // Loopback upstreams are refused: one pointing back at the forwarder would loop.
        guard !upstream.isEmpty, upstream.count <= 4,
              upstream.allSatisfy({ WildcardIPv4.parse($0) != nil && !$0.hasPrefix("127.") && $0 != "0.0.0.0" })
        else { return nil }
        self.init(suffix: suffix, gateway: gateway, upstream: upstream, interface: interface, intoTunnel: d["tunnel"] == "1")
    }

    static func isValidGateway(_ g: String) -> Bool {
        if g.hasPrefix("iface:") { return isValidInterfaceName(String(g.dropFirst(6))) }
        return WildcardIPv4.parse(g) != nil
    }

    static func isValidInterfaceName(_ name: String) -> Bool {
        !name.isEmpty && name.count < 16 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// A route the helper added for a wildcard, as it reports it to the app. No name: the app
/// needs the address, the wildcard and the gateway, and nothing more crosses the boundary.
public struct LearnedWildcardRoute: Equatable, Hashable, Sendable {
    public let ip: String
    public let suffix: String
    public let gateway: String

    public init(ip: String, suffix: String, gateway: String) {
        self.ip = ip
        self.suffix = suffix
        self.gateway = gateway
    }

    public var dictionary: [String: String] { ["ip": ip, "suffix": suffix, "gateway": gateway] }

    public init?(dictionary d: [String: String]) {
        guard let ip = d["ip"], WildcardIPv4.parse(ip) != nil,
              let suffix = d["suffix"], WildcardDomain.normalizedSuffix(suffix) == suffix,
              let gateway = d["gateway"], WildcardSpec.isValidGateway(gateway) else { return nil }
        self.init(ip: ip, suffix: suffix, gateway: gateway)
    }
}
