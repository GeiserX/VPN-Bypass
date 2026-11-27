// HostsList.swift
// Reads a hosts-format blocklist (StevenBlack's and the like): `0.0.0.0 ads.example.com` per line.
// Each name it keeps is blocked as that exact name, never as a suffix, so only the hosts format is
// read: its meaning is exactly what a hosts line does. An adblock list (`||x^`) or a bare-domain list
// means "the name and everything under it", which an exact-name line would under-deliver, so such a
// body is refused whole instead of read in part.
//
// A list comes from a server, so it may only blackhole a name, never redirect one: a row whose
// address is not a blackhole address is skipped. Names the Mac needs (the localhost family, mDNS,
// reverse lookups, the hosts the app downloads from) are skipped too.

import Foundation

enum HostsList {

    /// The addresses a row may map a name to: each one means "do not connect". A row with any other
    /// address would send the name somewhere, so it is skipped and counted.
    static let blackholeAddresses: Set<String> = ["0.0.0.0", "127.0.0.1", "::", "::1", "0"]

    /// A line longer than this is skipped: no real hosts row is near it, and a name is at most 253.
    static let maxLineBytes = 1_023

    /// Names a list never blocks, whatever it says: the local host's own names.
    static let localNames: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost", "ip6-loopback",
        "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters", "ip6-allhosts",
    ]
    /// Domains whose names a list never blocks: loopback names, mDNS (`.local`) and reverse lookups.
    static let localSuffixes = ["localhost", "local", "arpa"]

    /// Why a whole body is refused. Said in the list's status.
    enum Refusal: Error, Equatable {
        /// The first thing in the body is `<`: an error page or a login page, not a list.
        case webPage
        /// Under half of its lines are hosts rows: an adblock list, a bare-domain list, or something else.
        case notHostsFormat

        var message: String {
            switch self {
            case .webPage: return String(localized: "The server sent a web page, not a list.")
            case .notHostsFormat: return String(localized: "This is not a hosts file.")
            }
        }
    }

    /// What a list holds, as read.
    struct Parsed: Equatable {
        /// The names to block, lower case, each once, in the order the list gives them.
        var names: [String] = []
        /// Lines that are hosts rows: an address, then names.
        var rows = 0
        /// Rows skipped because their address is not a blackhole address.
        var redirects = 0
        /// Names skipped: not a valid name, a local one, or one the app downloads from.
        var skippedNames = 0
        /// Lines skipped for being longer than `maxLineBytes`.
        var longLines = 0
    }

    /// Reads `data` as a hosts file. `skipping` holds names never to block (lower case), such as the
    /// host the list is downloaded from.
    static func parse(_ data: Data, skipping: Set<String> = []) -> Result<Parsed, Refusal> {
        let bytes = [UInt8](data)
        if startsLikeAWebPage(bytes) { return .failure(.webPage) }

        var out = Parsed()
        var seen: Set<String> = []
        // Lines that are not blank and not only a comment: the base of the hosts-row share.
        var contentLines = 0
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            let next = end + 1
            var lineEnd = end
            if lineEnd > start, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            defer { start = next }
            guard lineEnd - start <= maxLineBytes else {
                out.longLines += 1
                contentLines += 1
                continue
            }
            // An inline `#` ends the line.
            var cut = start
            while cut < lineEnd, bytes[cut] != 0x23 { cut += 1 }
            let tokens = Self.tokens(bytes, start, cut)
            guard let address = tokens.first else { continue }
            contentLines += 1
            guard isAddress(address) else { continue }
            out.rows += 1
            guard blackholeAddresses.contains(address) else {
                out.redirects += 1
                continue
            }
            for raw in tokens.dropFirst() {
                guard let name = blockableName(raw), !isSkipped(name, skipping: skipping) else {
                    out.skippedNames += 1
                    continue
                }
                if seen.insert(name).inserted { out.names.append(name) }
            }
        }
        // Under half the lines are hosts rows: what was read is not what the list means.
        if contentLines > 0, out.rows * 2 < contentLines { return .failure(.notHostsFormat) }
        return .success(out)
    }

    /// `raw` as a name a hosts line can block: the wildcard code's name rule (ASCII DNS labels, two
    /// at least, lower case, no trailing dot) and a last label that is not a number, so an address
    /// (`0.0.0.0`, `10.1.2.3`) is never a name. Nil otherwise.
    static func blockableName(_ raw: String) -> String? {
        guard let name = WildcardDomain.normalizedSuffix(raw), let last = name.split(separator: ".").last,
              !last.allSatisfy(\.isNumber) else { return nil }
        return name
    }

    /// A name a list never blocks: a local name, a name under a local domain, or one in `skipping`.
    static func isSkipped(_ name: String, skipping: Set<String> = []) -> Bool {
        if localNames.contains(name) || skipping.contains(name) { return true }
        return localSuffixes.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    // MARK: - Internals

    /// The first byte that is not white space (after a UTF-8 byte order mark) is `<`.
    private static func startsLikeAWebPage(_ bytes: [UInt8]) -> Bool {
        var i = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        return i < bytes.count && bytes[i] == 0x3C
    }

    /// The space- or tab-separated words of `bytes[start..<end]`.
    private static func tokens(_ bytes: [UInt8], _ start: Int, _ end: Int) -> [String] {
        var out: [String] = []
        var i = start
        while i < end {
            while i < end, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
            let wordStart = i
            while i < end, bytes[i] != 0x20, bytes[i] != 0x09 { i += 1 }
            if i > wordStart { out.append(String(decoding: bytes[wordStart..<i], as: UTF8.self)) }
        }
        return out
    }

    /// An IPv4 or IPv6 literal, or `0` (which some lists use for 0.0.0.0): what starts a hosts row.
    static func isAddress(_ token: String) -> Bool {
        if token == "0" { return true }
        var v4 = in_addr()
        var v6 = in6_addr()
        return token.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
