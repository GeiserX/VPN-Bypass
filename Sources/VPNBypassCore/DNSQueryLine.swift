// DNSQueryLine.swift
// Reads the name out of one line of `tcpdump -n -t` output for an outgoing DNS query.
//
// Compiled into the helper too (see the Makefile), which runs tcpdump as root for the opt-in
// DNS Lookups page (#176) and hands the app only the names this returns.
//
// A query line looks like
//   IP 192.168.10.11.61955 > 1.1.1.1.53: 29302+ [1au] A? apple.com. (38)
//   IP6 fe80::1.52000 > fe80::2.53: 41380+ AAAA? github.com. (39)
// The question type is the token ending in "?", and the name is the token after it.

import Foundation

public enum DNSQueryLine {
    /// The question types a connection starts with. A browser asks A, AAAA and HTTPS (tcpdump
    /// prints "Type65" for it) for every name it opens; PTR, SRV, TXT and the rest are the
    /// system's own housekeeping and never name a site worth routing.
    static let questionTypes: Set<String> = ["A", "AAAA", "Type65", "HTTPS"]

    /// The queried name, lower case and without the trailing dot, or nil when the line is not
    /// a query worth showing.
    public static func name(from line: Substring) -> String? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let index = tokens.firstIndex(where: { $0.count > 1 && $0.last == "?" }),
              questionTypes.contains(String(tokens[index].dropLast())),
              index + 1 < tokens.count else { return nil }
        var name = tokens[index + 1].lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return isShowable(name) ? name : nil
    }

    public static func name(from line: String) -> String? {
        name(from: Substring(line))
    }

    /// Two labels at least, DNS characters only, and not a reverse lookup or a multicast
    /// (Bonjour) name. Company names such as `jira.corp.internal` stay: in VPN Only mode they
    /// are exactly what a user lists.
    static func isShowable(_ name: String) -> Bool {
        guard name.count <= 253, name.contains("."), !name.hasPrefix("."), !name.contains("..") else { return false }
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_") }) else { return false }
        for suffix in [".arpa", ".local", ".localdomain"] where name.hasSuffix(suffix) {
            return false
        }
        return true
    }
}

/// The names read from tcpdump's output since the app last asked for them.
///
/// tcpdump's output arrives in pieces that need not end at a line break, so the tail of a piece
/// waits for the next one. The buffer is capped: if the app stops asking (a hung app, a
/// suspended Mac), it keeps the newest `limit` names instead of growing for as long as the
/// capture runs.
public struct DNSQueryBuffer {
    public let limit: Int
    public private(set) var names: [String] = []
    private var partial = Data()

    public init(limit: Int = 5000) {
        self.limit = limit
    }

    public mutating func append(_ data: Data) {
        partial.append(data)
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            if let text = String(data: line, encoding: .utf8), let name = DNSQueryLine.name(from: text) {
                names.append(name)
            }
        }
        // A line never gets this long; a stream with no line breaks is not tcpdump's.
        if partial.count > 4096 { partial.removeAll() }
        if names.count > limit { names.removeFirst(names.count - limit) }
    }

    /// Every name collected since the last call, oldest first, and empties the buffer.
    public mutating func drain() -> [String] {
        defer { names.removeAll() }
        return names
    }
}
