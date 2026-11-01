// LeadingDotMigration.swift
// Versions before 6.0 let a list entry or a Custom rule be written ".example.com". 6.0 writes a
// name and everything under it as "*.example.com" (a `.suffix` rule on "example.com" in Custom),
// and reads ".example.com" as a plain host name, which never resolves: the entry routes nothing
// and Status stays on "Partly working". On load, such an entry becomes the wildcard it meant.

import Foundation

enum LeadingDotMigration {
    /// The suffix a legacy ".example.com" entry meant, or nil when `name` is not one (no
    /// leading dot, a "*." wildcard already, or a suffix the wildcard rules refuse, ".com").
    static func suffix(ofLegacy name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("."), !WildcardDomain.isWildcard(trimmed) else { return nil }
        return WildcardDomain.normalizedSuffix(String(trimmed.drop { $0 == "." }))
    }

    /// `entries` with each legacy entry rewritten to "*.suffix" in place, keeping its id and
    /// whether it is on. One whose wildcard is already on the list is dropped: the wildcard
    /// stays as the user set it. `migrated` names each legacy entry that was rewritten or
    /// dropped.
    static func migrate(_ entries: [DomainEntry]) -> (entries: [DomainEntry], migrated: [String]) {
        // Keyed by the normalized suffix, as routing reads a wildcard ("*.Example.net." too).
        var seen = Set(entries.compactMap { WildcardDomain.suffix(of: $0.domain) })
        var out: [DomainEntry] = []
        var migrated: [String] = []
        for entry in entries {
            guard !entry.isCIDR, let suffix = suffix(ofLegacy: entry.domain) else {
                out.append(entry)
                continue
            }
            migrated.append(entry.domain)
            guard seen.insert(suffix).inserted else { continue }
            let wildcard = WildcardDomain.entry(for: suffix)
            var fixed = entry
            fixed.domain = wildcard
            fixed.isWildcard = true
            fixed.resolvedIP = nil
            fixed.lastResolved = nil
            fixed.resolveFailures = nil
            out.append(fixed)
        }
        return (out, migrated)
    }

    /// `rules` with each legacy `.domain` rule on ".suffix" made the `.suffix` rule it meant,
    /// keeping its id, route, order and whether it is on. One whose suffix already has a
    /// `.suffix` rule is dropped: it routed nothing, so the other rule already decided.
    static func migrate(_ rules: [Rule]) -> (rules: [Rule], migrated: [String]) {
        var seen = Set(rules.filter { $0.matchType == .suffix }.map { $0.pattern.lowercased() })
        var out: [Rule] = []
        var migrated: [String] = []
        for rule in rules {
            guard rule.matchType == .domain || rule.matchType == .suffix,
                  let suffix = suffix(ofLegacy: rule.pattern) else {
                out.append(rule)
                continue
            }
            migrated.append(rule.pattern)
            guard seen.insert(suffix).inserted else { continue }
            var fixed = rule
            fixed.matchType = .suffix
            fixed.pattern = suffix
            out.append(fixed)
        }
        return (out, migrated)
    }
}

extension Config {
    /// `self` with every legacy ".example.com" entry made "*.example.com": in both lists, the
    /// Custom rules, and the same three in every network profile and the Other networks
    /// settings. `migrated` lists the legacy names once each, empty when nothing changed.
    func migratingLeadingDotEntries() -> (config: Config, migrated: [String]) {
        var c = self
        var names: [String] = []
        func list(_ entries: inout [DomainEntry]) {
            let r = LeadingDotMigration.migrate(entries)
            entries = r.entries
            names += r.migrated
        }
        func rules(_ rules: inout [Rule]) {
            let r = LeadingDotMigration.migrate(rules)
            rules = r.rules
            names += r.migrated
        }
        func settings(_ s: inout ProfileSettings) {
            list(&s.domains)
            list(&s.inverseDomains)
            rules(&s.rules)
        }
        list(&c.domains)
        list(&c.inverseDomains)
        rules(&c.rules)
        for i in c.profiles.indices { settings(&c.profiles[i].settings) }
        if var other = c.otherNetworksSettings {
            settings(&other)
            c.otherNetworksSettings = other
        }
        var unique: [String] = []
        for n in names where !unique.contains(n) { unique.append(n) }
        return (c, unique)
    }
}

/// One entry the leading-dot migration rewrote: the name as saved, and the wildcard it is now.
/// Status and `vpnb status` list these until the user dismisses them.
public struct ConvertedEntry: Codable, Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// The change for a legacy name `migratingLeadingDotEntries` reported, nil for any other.
    static func of(legacy name: String) -> ConvertedEntry? {
        LeadingDotMigration.suffix(ofLegacy: name).map { ConvertedEntry(from: name, to: WildcardDomain.entry(for: $0)) }
    }

    /// `pending` with the `new` changes it did not hold yet, in order: a name is listed once.
    static func merging(_ pending: [ConvertedEntry], _ new: [ConvertedEntry]) -> [ConvertedEntry] {
        var out = pending
        for change in new where !out.contains(where: { $0.from == change.from }) { out.append(change) }
        return out
    }

    /// "Updated 2 entries to the new wildcard form: .a.io is now *.a.io, .b.io is now *.b.io.
    /// They route the same names as before." Status shows it, and the notification says it.
    static func sentence(_ changes: [ConvertedEntry], bundle: Bundle = .main) -> String {
        let list = changes.map { String(localized: "\($0.from) is now \($0.to)", bundle: bundle) }
            .joined(separator: ", ")
        return changes.count == 1
            ? String(localized: "Updated 1 entry to the new wildcard form: \(list). It routes the same names as before.", bundle: bundle)
            : String(localized: "Updated \(changes.count) entries to the new wildcard form: \(list). They route the same names as before.", bundle: bundle)
    }
}
