// HostsBlockSection.swift
// The blocklist section of /etc/hosts: names the Block route blocks exactly, one `0.0.0.0 name`
// line each, between its own markers. It is apart from the section of pinned names
// (`HelperConstants.hostMarkerStart`), which is rewritten often; this one changes only when the
// blocked set does.
//
// Once written, macOS enforces the section by itself: if the app or the helper stops, DNS keeps
// working and the names stay blocked. A hosts line blocks one exact name, never its subdomains.
//
// This file is shared by the helper, which rewrites /etc/hosts as root, and by the app and its
// tests, so the text work is pure functions with no file access. The caller sends names only;
// every line is built here, so nothing the caller sends can become another mapping.
//
// Only `0.0.0.0` rows are written. With such a row alone, an IPv6 lookup of the name answers
// ::ffff:0.0.0.0 and no query leaves the Mac (an Apple silicon Mac on macOS 26.6.1), so a `::` row
// would only double the records.

import Foundation

enum HostsBlockSection {
    static let startMarker = "# VPN-BYPASS-BLOCKLIST - START"
    static let endMarker = "# VPN-BYPASS-BLOCKLIST - END"
    /// Where a blocked name points. A connection to it fails at once.
    static let address = "0.0.0.0"
    /// The helper refuses a larger set whole. It is a safety ceiling, not the app's cap: on an Apple
    /// silicon Mac on macOS 26.6.1, mDNSResponder held 363 MB at 200,000 names and did not give it
    /// back when the section went.
    static let maxNames = 200_000

    /// Why a set of names was refused. Nothing is written then.
    enum Refusal: Error, Equatable {
        case tooManyNames(Int)
        case invalidName(String)

        var message: String {
            switch self {
            case .tooManyNames(let count):
                return "Too many blocked names (\(count), the limit is \(HostsBlockSection.maxNames))"
            case .invalidName(let name):
                // The name can hold any byte; show only a safe prefix of it.
                let shown = String(name.unicodeScalars.prefix(64).map {
                    $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F ? Character($0) : "?"
                })
                return "Not a host name: \(shown)"
            }
        }
    }

    /// A host name the section may hold: ASCII letters, digits and hyphens in labels of 1 to 63
    /// characters that do not start or end with a hyphen, at least two labels, 253 characters at
    /// most, and a last label that is not all digits (so no IPv4 address; an IPv6 address has a
    /// colon). No whitespace, control byte or non-ASCII byte gets through. Scanned by byte, not by
    /// pattern: this runs once per name, hundreds of thousands of times.
    static func isValidName(_ name: String) -> Bool {
        var labels = 0
        var length = 0
        var count = 0
        var last: UInt8 = 0
        var lastLabelAllDigits = true
        for byte in name.utf8 {
            count += 1
            guard count <= 253 else { return false }
            if byte == 0x2E {                                   // .
                guard length > 0, last != 0x2D else { return false }
                labels += 1
                length = 0
                lastLabelAllDigits = true
            } else {
                let digit = byte >= 0x30 && byte <= 0x39
                let letter = (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
                guard digit || letter || byte == 0x2D else { return false }
                if byte == 0x2D, length == 0 { return false }  // a label does not start with a hyphen
                length += 1
                guard length <= 63 else { return false }
                if !digit { lastLabelAllDigits = false }
            }
            last = byte
        }
        guard length > 0, last != 0x2D else { return false }
        return labels + 1 >= 2 && !lastLabelAllDigits
    }

    /// Whether `line` is a marker line (we write them at the start of a line). The first byte is
    /// checked before the text: the section's own lines start with a digit, and a full text search
    /// over 100,000 of them cost the pin writer about 120 ms more on every write.
    private static func isMarker(_ line: String, _ marker: String) -> Bool {
        line.utf8.first == 0x23 && line.contains(marker)          // #
    }

    /// `lines` without the blocklist section and its markers.
    static func linesOutsideSection(_ lines: [String]) -> [String] {
        var inSection = false
        return lines.filter { line in
            if isMarker(line, startMarker) { inSection = true; return false }
            if isMarker(line, endMarker) { inSection = false; return false }
            return !inSection
        }
    }

    /// The names that hosts `lines` map, lowercased. Comment lines, and the comment at the end of a
    /// line, are not read.
    static func mappedNames<S: Sequence>(in lines: S) -> Set<String> where S.Element == String {
        var names = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let fields = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2 else { continue }
            for field in fields.dropFirst() {
                if field.hasPrefix("#") { break }
                names.insert(field.lowercased())
            }
        }
        return names
    }

    /// The names that `lines` (a hosts file with the pinned-name section already taken out) map
    /// outside the blocklist section. The pin writer skips these, as names another tool manages; a
    /// blocked name is not one of them.
    static func namesManagedElsewhere(_ lines: [String]) -> Set<String> {
        mappedNames(in: linesOutsideSection(lines))
    }

    /// `content` with the blocklist section replaced by one line per name in `names`, or with no
    /// section when no name is left. Nil when the result is the text `content` already is, so the
    /// caller writes nothing and flushes nothing.
    ///
    /// Every other line, the pinned-name section included, stays byte for byte. A section already
    /// in the file is replaced where it is, so the pin writer, which appends its own section at the
    /// end, and this one never push blank lines into each other. A new section goes at the end,
    /// after one blank line. A name that any line outside the section maps is skipped, so the
    /// user's own mapping or a pin always wins. Names are lowercased and written once each, in the
    /// order given.
    ///
    /// Throws `Refusal` for more than `maxNames` names or for any name `isValidName` refuses; a
    /// set with one bad name is refused whole, because the app validates every name before it
    /// sends one.
    static func rewritten(_ content: String, names: [String]) throws -> String? {
        guard names.count <= maxNames else { throw Refusal.tooManyNames(names.count) }
        for name in names where !isValidName(name) { throw Refusal.invalidName(name) }

        // The file around the section: what comes before it and what comes after it.
        var before: [String] = []
        var after: [String] = []
        var hadSection = false
        var inSection = false
        for line in content.components(separatedBy: "\n") {
            if isMarker(line, startMarker) { inSection = true; hadSection = true; continue }
            if isMarker(line, endMarker) { inSection = false; continue }
            if inSection { continue }
            if hadSection { after.append(line) } else { before.append(line) }
        }
        if names.isEmpty && !hadSection { return nil }

        var entries: [String] = []
        if !names.isEmpty {
            let external = mappedNames(in: before).union(mappedNames(in: after))
            var seen = Set<String>()
            entries.reserveCapacity(names.count)
            for name in names {
                let lower = name.lowercased()
                guard !external.contains(lower), seen.insert(lower).inserted else { continue }
                entries.append("\(address) \(lower)")
            }
        }
        if entries.isEmpty && !hadSection { return nil }

        var lines: [String]
        if hadSection {
            // The blank line written before the section goes with it.
            if entries.isEmpty, before.last?.isEmpty == true { before.removeLast() }
            lines = before
            if !entries.isEmpty {
                lines.append(startMarker)
                lines.append(contentsOf: entries)
                lines.append(endMarker)
            }
            lines.append(contentsOf: after)
        } else {
            lines = before
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines.append("")
            lines.append(startMarker)
            lines.append(contentsOf: entries)
            lines.append(endMarker)
        }
        // A file that ends in a newline splits into a last empty element; one newline at the end.
        while lines.last?.isEmpty == true { lines.removeLast() }
        let result = lines.joined(separator: "\n") + "\n"
        return result == content ? nil : result
    }
}
