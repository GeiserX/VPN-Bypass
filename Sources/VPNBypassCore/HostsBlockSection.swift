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
        /// The file has a start marker with no end marker after it. The lines after the marker
        /// may be the user's own, so nothing is written until someone fixes the file.
        case unterminatedSection

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
            case .unterminatedSection:
                return "/etc/hosts has \(HostsBlockSection.startMarker) with no \(HostsBlockSection.endMarker) after it; "
                    + "nothing was written, fix the file by hand"
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
    /// blocked name is not one of them: the pin writer drops its row instead (`removingNames`).
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
    /// sends one. Throws `Refusal.unterminatedSection` for a start marker with no end marker: the
    /// lines after it may be the user's own or the pinned names, and a rewrite would drop them.
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
        guard !inSection else { throw Refusal.unterminatedSection }
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

    /// `lines` without the blocklist rows that map any of `names` (lowercase). The pin writer runs
    /// this with the names it is about to pin, in the same write: a name with a `0.0.0.0` row and
    /// a pinned row gets both addresses from the resolver, so the pin would not win. When no row
    /// is left, the markers go too, with the blank line written before them. Returns `lines`
    /// unchanged when nothing matches, and when the section has no end marker (see
    /// `Refusal.unterminatedSection`).
    static func removingNames(_ names: Set<String>, from lines: [String]) -> [String] {
        guard !names.isEmpty else { return lines }
        let wanted = Set(names.map { Substring($0) })
        let ownRows = Set(names.map { "\(address) \($0)" })
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var inSection = false
        var sectionStart = 0
        var kept = 0
        var changed = false
        for line in lines {
            if isMarker(line, startMarker) {
                inSection = true
                sectionStart = out.count
                kept = 0
                out.append(line)
                continue
            }
            if inSection, isMarker(line, endMarker) {
                inSection = false
                if kept == 0 && changed {
                    out.removeSubrange(sectionStart...)
                    if out.last?.isEmpty == true { out.removeLast() }
                } else {
                    out.append(line)
                }
                continue
            }
            if inSection {
                if ownRows.contains(line) || (!isOwnRow(line) && rowMaps(line, anyOf: wanted)) {
                    changed = true
                    continue
                }
                kept += 1
            }
            out.append(line)
        }
        guard !inSection, changed else { return lines }
        return out
    }

    /// Whether `line` has the form this file writes: `0.0.0.0`, one space, one lowercase name. Such a
    /// row needs no parsing; an exact lookup answers for it. Checked by byte, with no string built.
    private static func isOwnRow(_ line: String) -> Bool {
        var bytes = line.utf8.makeIterator()
        for expected in (address + " ").utf8 where bytes.next() != expected { return false }
        while let byte = bytes.next() {
            if byte == 0x20 || byte == 0x09 || byte == 0x23 || (byte >= 0x41 && byte <= 0x5A) { return false }
        }
        return true
    }

    /// Whether the hosts row `line` maps a name in `names`. Only for rows edited by hand.
    private static func rowMaps(_ line: String, anyOf names: Set<Substring>) -> Bool {
        guard line.utf8.first != 0x23 else { return false }         // #
        for field in line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst() {
            if field.hasPrefix("#") { return false }
            let upper = field.utf8.contains { $0 >= 0x41 && $0 <= 0x5A }
            if names.contains(upper ? Substring(field.lowercased()) : field) { return true }
        }
        return false
    }
}

/// The pinned-name section (`HelperConstants.hostMarkerStart`): the text work of the helper's pin
/// writer, pure so the app's tests can run it. Shared with the helper as `HostsBlockSection` is.
enum HostsPinSection {

    /// `content` with the pinned section replaced by `entries` (`ip name` lines), or without it when
    /// no entry is left; nil when that is the text `content` already is, so the helper writes
    /// nothing and flushes nothing. `isValid(domain, ip)` keeps an entry. A name another line maps
    /// is skipped as another tool's; a blocklist row is not one, and goes for the name pinned in
    /// the same write (`HostsBlockSection.removingNames`), so a pin wins over a block.
    static func rewritten(_ content: String, entries: [(domain: String, ip: String)],
                          isValid: (String, String) -> Bool) -> String? {
        // Remove the existing pinned section
        var lines = content.components(separatedBy: "\n")
        var inSection = false
        lines = lines.filter { line in
            if line.contains(HelperConstants.hostMarkerStart) {
                inSection = true
                return false
            }
            if line.contains(HelperConstants.hostMarkerEnd) {
                inSection = false
                return false
            }
            return !inSection
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        // Names managed by other tools (outside our sections). The blocklist section is ours too:
        // its names are not another tool's, and it can hold 200,000 lines.
        let externalDomains = HostsBlockSection.namesManagedElsewhere(lines)

        var managedEntries: [String] = []
        var pinnedNames = Set<String>()
        for entry in entries where isValid(entry.domain, entry.ip) {
            if externalDomains.contains(entry.domain.lowercased()) { continue }
            managedEntries.append("\(entry.ip) \(entry.domain)")
            pinnedNames.insert(entry.domain.lowercased())
        }
        if !managedEntries.isEmpty {
            // A pin wins over a block. A name with a blocklist row and a pinned row gets both
            // addresses from the resolver, so the blocklist row goes in this same write.
            lines = HostsBlockSection.removingNames(pinnedNames, from: lines)
            while lines.last?.isEmpty == true {
                lines.removeLast()
            }
            lines.append("")
            lines.append(HelperConstants.hostMarkerStart)
            lines.append(contentsOf: managedEntries)
            lines.append(HelperConstants.hostMarkerEnd)
        }

        let updated = lines.joined(separator: "\n") + "\n"
        return updated == content ? nil : updated
    }
}
