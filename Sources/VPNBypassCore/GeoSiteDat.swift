// GeoSiteDat.swift
// Reads the v2ray `geosite.dat` format: a protobuf list of named domain lists ("steam",
// "category-games", "microsoft") that Loyalsoldier/v2ray-rules-dat, MetaCubeX/meta-rules-dat,
// Chocolate4U/Iran-v2ray-rules and OpenWrt Passwall2 publish next to geoip.dat. Pure and I/O-free.
//
//   message Domain   { Type type = 1; string value = 2; repeated Attribute attribute = 3; }
//                      // Type: 0 keyword, 1 regex, 2 domain (the name and everything under it), 3 full
//   message Attribute { string key = 1; ... }                   // "cn", "ads", ...
//   message GeoSite  { string country_code = 1; repeated Domain domain = 2; }
//   message GeoSiteList { repeated GeoSite entry = 1; }
//
// What a list becomes here. A `domain` entry is a wildcard (`*.steampowered.com`, which also
// covers the name itself): the helper's DNS forwarder turns the addresses it answers into routes
// (WildcardDNS). A `full` entry is one name, resolved like a Domains entry. A `keyword` or `regex`
// entry cannot be turned into either, so it is counted and left out. An entry already covered by a
// shorter suffix in the same list is dropped, so `store.steampowered.com` after `steampowered.com`
// costs nothing.

import Foundation

/// A geosite list as the kernel engine can use it.
struct GeoSiteExpansion: Equatable {
    /// Suffixes, lower case, none under another: each becomes one wildcard.
    var suffixes: [String] = []
    /// Exact names not under any suffix: each is resolved like a listed domain.
    var names: [String] = []
    /// Keyword and regex entries, and names that are not valid DNS names: left out.
    var unsupported = 0
    /// False when the file has no list of that name.
    var found = true

    /// A list with more wildcards than this is refused as a whole: a part of a list would send
    /// some of a site's names one way and some another. Each wildcard is a resolver file in
    /// /etc/resolver, so this is the number of files one list may ask for.
    static let maxSuffixes = 10_000
    /// Exact names are looked up like a Domains entry (one DNS query each at every apply), which
    /// is far more work than a wildcard, so fewer are taken.
    static let maxNames = 2_000

    var count: Int { suffixes.count + names.count }
    var isTooLarge: Bool { suffixes.count > Self.maxSuffixes || names.count > Self.maxNames }

    /// `name` is the list's own name or under one of its suffixes.
    func matches(_ host: String) -> Bool {
        let h = host.lowercased()
        if names.contains(h) { return true }
        return suffixes.contains { WildcardDomain.matches(h, suffix: $0) }
    }

    /// What a rule routes: nothing when the list is missing or too large.
    var usable: GeoSiteExpansion {
        found && !isTooLarge ? self : GeoSiteExpansion(suffixes: [], names: [], unsupported: unsupported, found: found)
    }
}

enum GeoSiteDat {

    /// `steam` or `steam@cn`: the list's name and, after `@`, an attribute its entries must carry.
    static func parse(pattern: String) -> (name: String, attribute: String?) {
        let lower = pattern.lowercased()
        guard let at = lower.firstIndex(of: "@") else { return (lower, nil) }
        let attribute = String(lower[lower.index(after: at)...])
        return (String(lower[..<at]), attribute.isEmpty ? nil : attribute)
    }

    /// The expansion of each pattern in `patterns` (`steam`, `category-games@cn`), keyed by the
    /// pattern. A pattern whose list the file lacks comes back with `found` false.
    static func expansions(for patterns: Set<String>, in data: Data) -> [String: GeoSiteExpansion] {
        guard !patterns.isEmpty else { return [:] }
        let wanted = Dictionary(grouping: patterns, by: { parse(pattern: $0).name })
        var out: [String: GeoSiteExpansion] = [:]
        scan(data) { list in
            guard let patterns = wanted[list.name] else { return }
            for pattern in patterns {
                out[pattern] = list.expansion(attribute: parse(pattern: pattern).attribute)
            }
        }
        for pattern in patterns where out[pattern] == nil {
            out[pattern] = GeoSiteExpansion(found: false)
        }
        return out
    }

    /// Every list in the file with its number of suffix and exact-name entries, for the picker.
    /// The count is of the entries as written, before shorter suffixes absorb longer ones.
    static func lists(in data: Data) -> [String: Int] {
        var counts: [String: Int] = [:]
        scan(data) { list in
            let count = list.supportedCount()
            if !list.name.isEmpty, count > 0 { counts[list.name, default: 0] += count }
        }
        return counts
    }

    /// True when `data` reads as a geosite list with at least one list that has a usable entry:
    /// what a download must be before it replaces the copy in use.
    static func isUsable(_ data: Data) -> Bool {
        var usable = false
        scan(data) { list in
            if !usable, !list.name.isEmpty, list.supportedCount() > 0 { usable = true }
        }
        return usable
    }

    // MARK: - Protobuf reading

    /// One `GeoSite` message, valid only inside the `scan` call that made it.
    fileprivate struct List {
        let name: String
        fileprivate let body: UnsafeBufferPointer<UInt8>

        private func forEachDomain(_ visit: (_ type: UInt64, _ value: String, _ attributes: [String]) -> Void) {
            var reader = ProtoReader(bytes: body)
            while let (field, wire) = reader.nextTag() {
                if field == 2, wire == 2 {
                    guard let slice = reader.lengthDelimited() else { return }
                    List.domain(in: slice, visit)
                } else if !reader.skip(wire) {
                    return
                }
            }
        }

        private static func domain(in bytes: UnsafeBufferPointer<UInt8>,
                                   _ visit: (UInt64, String, [String]) -> Void) {
            var reader = ProtoReader(bytes: bytes)
            var type: UInt64 = 0
            var value = ""
            var attributes: [String] = []
            while let (field, wire) = reader.nextTag() {
                if field == 1, wire == 0 {
                    guard let t = reader.varint() else { return }
                    type = t
                } else if field == 2, wire == 2 {
                    guard let s = reader.lengthDelimited() else { return }
                    value = String(decoding: s, as: UTF8.self)
                } else if field == 3, wire == 2 {
                    guard let a = reader.lengthDelimited() else { return }
                    var attr = ProtoReader(bytes: a)
                    while let (f, w) = attr.nextTag() {
                        if f == 1, w == 2 {
                            guard let key = attr.lengthDelimited() else { break }
                            attributes.append(String(decoding: key, as: UTF8.self).lowercased())
                        } else if !attr.skip(w) {
                            break
                        }
                    }
                } else if !reader.skip(wire) {
                    return
                }
            }
            visit(type, value, attributes)
        }

        func supportedCount() -> Int {
            var n = 0
            forEachDomain { type, _, _ in if type == 2 || type == 3 { n += 1 } }
            return n
        }

        func expansion(attribute: String?) -> GeoSiteExpansion {
            var suffixes = Set<String>()
            var names = Set<String>()
            var unsupported = 0
            forEachDomain { type, value, attributes in
                if let attribute, !attributes.contains(attribute) { return }
                switch type {
                case 2:
                    if let suffix = WildcardDomain.normalizedSuffix(value) { suffixes.insert(suffix) } else { unsupported += 1 }
                case 3:
                    if let name = WildcardDomain.normalizedSuffix(value) { names.insert(name) } else { unsupported += 1 }
                default:
                    unsupported += 1
                }
            }
            return GeoSiteDat.collapse(suffixes: suffixes, names: names, unsupported: unsupported)
        }
    }

    /// Drops a suffix that sits under a shorter one in the set, and a name that sits under any suffix.
    fileprivate static func collapse(suffixes: Set<String>, names: Set<String>, unsupported: Int) -> GeoSiteExpansion {
        func covered(_ host: String, by set: Set<String>, includingSelf: Bool) -> Bool {
            let labels = host.split(separator: ".")
            guard !labels.isEmpty else { return false }
            for start in (includingSelf ? 0 : 1)..<max(labels.count, 1) where set.contains(labels[start...].joined(separator: ".")) {
                return true
            }
            return false
        }
        // Shortest first, so a parent is kept before its children are looked at.
        var kept = Set<String>()
        for suffix in suffixes.sorted(by: { ($0.split(separator: ".").count, $0) < ($1.split(separator: ".").count, $1) })
        where !covered(suffix, by: kept, includingSelf: false) {
            kept.insert(suffix)
        }
        let remaining = names.filter { !covered($0, by: kept, includingSelf: true) }
        return GeoSiteExpansion(suffixes: kept.sorted(), names: remaining.sorted(), unsupported: unsupported)
    }

    /// Calls `visit` for each `GeoSite` entry in the file.
    private static func scan(_ data: Data, _ visit: (List) -> Void) {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var file = ProtoReader(bytes: bytes)
            while let (field, wire) = file.nextTag() {
                guard field == 1, wire == 2 else {
                    if !file.skip(wire) { return }
                    continue
                }
                guard let body = file.lengthDelimited() else { return }
                var reader = ProtoReader(bytes: body)
                var name = ""
                while let (f, w) = reader.nextTag() {
                    if f == 1, w == 2 {
                        guard let s = reader.lengthDelimited() else { break }
                        name = String(decoding: s, as: UTF8.self).lowercased()
                    } else if !reader.skip(w) {
                        break
                    }
                }
                visit(List(name: name, body: body))
            }
        }
    }
}

/// The pattern of a Site rule: a list's name, and optionally `@attribute`, in lower case.
enum GeoSiteRule {
    /// `input` as a stored pattern, nil when it cannot be a list name. The published lists use
    /// names such as `steam`, `category-games`, `geolocation-!cn` and `microsoft`.
    static func normalized(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let name = parts.first, (2...60).contains(name.count),
              name.allSatisfy(Self.isNameCharacter) else { return nil }
        if parts.count == 2 {
            let attribute = parts[1]
            guard (1...30).contains(attribute.count), attribute.allSatisfy(Self.isNameCharacter) else { return nil }
        }
        return text
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == "!" || c == ".")
    }
}
