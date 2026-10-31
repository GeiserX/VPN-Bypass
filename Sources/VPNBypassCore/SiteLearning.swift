// SiteLearning.swift
// "Learn a site" on the Lookups page (idea 5 of docs/design/APP-REWORK-PROPOSALS.md): for 60
// seconds, while the user reloads a page that does not work, keep every name first looked up
// in that window, then show them grouped by the site's own domain, so the CDN, sign-in and API
// names the page needs can be added in one go.
//
// It reads the same helper capture as the Lookups count (`DNSLookupsMonitor` drains it for
// both), and like the count it lives in memory only: nothing here is written to the log or to
// disk until the user adds a name.

import Foundation

/// One learning window and the names first seen in it.
struct SiteLearning: Equatable {
    /// How long the window stays open.
    static let duration: TimeInterval = 60
    /// A site domain with this many names gets the offer of a wildcard over it.
    static let wildcardMinimum = 3

    let started: Date
    var ends: Date { started.addingTimeInterval(Self.duration) }
    /// Open until the window's time is up or the user stops it; closed, it takes no more names.
    private(set) var isOpen = true
    /// Each name once, in the order it was first seen in the window.
    private(set) var names: [String] = []

    init(started: Date) {
        self.started = started
    }

    /// One drain's names, drained at `date`. Names drained before the window opened or after it
    /// ended, or after it was closed, are not the page's and are left out.
    mutating func record(_ batch: [String], at date: Date) {
        guard isOpen, date >= started, date <= ends else { return }
        for name in batch where !names.contains(name) {
            names.append(name)
        }
    }

    mutating func close() {
        isOpen = false
    }

    /// Whole seconds until the window ends, for the countdown.
    func secondsLeft(at now: Date) -> Int {
        max(0, Int(ceil(ends.timeIntervalSince(now))))
    }

    /// The names under one site domain.
    struct Group: Identifiable, Equatable {
        /// The site's own domain ("example.com", "bbc.co.uk"), or the name itself when it has
        /// none (`localhost`).
        let site: String
        /// In the order first seen.
        let names: [String]
        /// `*.site`, offered when the group has `wildcardMinimum` names or more.
        let wildcard: String?
        var id: String { site }
    }

    var groups: [Group] { Self.groups(names) }

    /// `names` grouped by site domain: the groups with the most names first, and among equals
    /// the one seen first.
    static func groups(_ names: [String]) -> [Group] {
        var order: [String] = []
        var members: [String: [String]] = [:]
        for name in names {
            let site = LookupAddLevels.registrableDomain(name) ?? name.lowercased()
            if members[site] == nil { order.append(site) }
            members[site, default: []].append(name)
        }
        let groups = order.map { site -> Group in
            let names = members[site] ?? []
            // Only over a real site domain: never `*.co.uk` or a wildcard over a bare label.
            let isSite = LookupAddLevels.registrableDomain(site) == site
            let wildcard = names.count >= wildcardMinimum && isSite
                ? WildcardDomain.normalizedSuffix(site).map(WildcardDomain.entry(for:)) : nil
            return Group(site: site, names: names, wildcard: wildcard)
        }
        return groups.enumerated()
            .sorted { $0.element.names.count != $1.element.names.count
                ? $0.element.names.count > $1.element.names.count : $0.offset < $1.offset }
            .map(\.element)
    }

    /// What one Add puts on the mode's list: for each group, its wildcard when the user chose
    /// it, else each of its names the mode does not route yet. Nothing for what is already
    /// listed, so a second Add adds nothing twice.
    static func plan(_ groups: [Group], wildcards chosen: Set<String>, isListed: (String) -> Bool) -> [String] {
        groups.flatMap { group -> [String] in
            if let wildcard = group.wildcard, chosen.contains(wildcard) {
                return isListed(wildcard) ? [] : [wildcard]
            }
            return group.names.filter { !isListed($0) }
        }
    }
}
