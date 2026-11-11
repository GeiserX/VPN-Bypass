// HostsBlockSection.swift
// The list of blocked names in /etc/hosts: Custom mode's Block route for a list too large for
// wildcards (a GeoSite list of tens or hundreds of thousands of entries, such as an ad list). The
// helper's DNS forwarder needs a resolver file per suffix, which stops being practical past a few
// thousand; a hosts line per name does not.
//
// A name here is blocked exactly, not its subdomains: a hosts file has no wildcards. The names are
// written as `0.0.0.0 name`, so a connection to one fails at once.
//
// This file is shared by the helper, which rewrites /etc/hosts as root, and the app and its tests,
// so the text work is one pure function with no file access. It is its own section with its own
// markers, apart from the one the app keeps for pinned names (`HelperConstants.hostMarkerStart`),
// because that one is rewritten often and this one only when the blocked set changes.
//
// What it will not write, whatever it is given: a line that is not one name (a space, a newline, a
// comment would smuggle in another mapping), a name with no dot (`localhost`, `broadcasthost`), a
// numeric top-level label (an IP), anything over DNS's own limits, and a name that another line of
// the file already maps, which stays as that line says.

import Foundation

public enum HostsBlockSection {
    public static let startMarker = "# VPN-BYPASS-BLOCKLIST - START"
    public static let endMarker = "# VPN-BYPASS-BLOCKLIST - END"
    /// Where a blocked name points: this host, which refuses the connection at once.
    public static let address = "0.0.0.0"
    /// More names than this are refused whole; the section is megabytes long well before it.
    public static let maxNames = 500_000
    /// The most text one update may carry over XPC.
    public static let maxBytes = 48 << 20

    /// A host name the section may hold: letters, digits and hyphens in labels of 1 to 63 characters
    /// that do not start or end with a hyphen, at least two labels, 253 characters at most, and a
    /// last label that is not all digits. Scanned by byte, not by pattern: this runs hundreds of
    /// thousands of times.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (3...253).contains(bytes.count) else { return false }
        var labels = 0
        var length = 0
        var last: UInt8 = 0
        var lastLabelAllDigits = true
        for byte in bytes {
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

    public static func hasSection(_ content: String) -> Bool {
        content.contains(startMarker)
    }

    /// The names the section holds in `content`, in order.
    public static func names(in content: String) -> [String] {
        var inSection = false
        var out: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains(startMarker) { inSection = true; continue }
            if line.contains(endMarker) { inSection = false; continue }
            guard inSection else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2, fields[0] == address { out.append(String(fields[1])) }
        }
        return out
    }

    /// `content` with the section replaced by one for `names`, or with no section when `names` is
    /// empty. Nil when the result would be the text it is already: nothing to write. The rest of the
    /// file, the app's pinned-name section included, is left as it is, and a name any of it already
    /// maps is not blocked here.
    public static func rewritten(_ content: String, names: [String]) -> String? {
        var lines = content.components(separatedBy: "\n")
        var inSection = false
        var hadSection = false
        lines = lines.filter { line in
            if line.contains(startMarker) { inSection = true; hadSection = true; return false }
            if line.contains(endMarker) { inSection = false; return false }
            return !inSection
        }
        if names.isEmpty && !hadSection { return nil }

        while lines.last?.isEmpty == true { lines.removeLast() }

        var managed: [String] = []
        if !names.isEmpty {
            // What the rest of the file maps already (the first line for a name wins in a hosts file).
            var external = Set<String>()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                var fields = trimmed.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 2 else { continue }
                fields.removeFirst()
                for field in fields {
                    if field.hasPrefix("#") { break }
                    external.insert(field.lowercased())
                }
            }
            var seen = Set<String>()
            managed.reserveCapacity(names.count)
            for name in names {
                let lower = name.lowercased()
                guard isValidName(lower), !external.contains(lower), seen.insert(lower).inserted else { continue }
                managed.append("\(address) \(lower)")
            }
        }
        if !managed.isEmpty {
            lines.append("")
            lines.append(startMarker)
            lines.append(contentsOf: managed)
            lines.append(endMarker)
        }
        let result = lines.joined(separator: "\n") + "\n"
        return result == content ? nil : result
    }
}
