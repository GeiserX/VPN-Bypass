// StaleEntries.swift
// A listed domain that stopped resolving (idea 6 of docs/design/APP-REWORK-PROPOSALS.md). Its
// row stayed as if it worked and every refresh kept asking for it. After `threshold` refreshes
// in a row with no address, while the VPN is up, the Domains row says since when, and the
// page can show only those rows.
//
// The counting rules live here, apart from RouteManager, so tests can hold them:
// - Only a refresh with the VPN up counts. An internal name resolves only through the VPN, so a
//   failure with the VPN down says nothing about the name.
// - A refresh that asked several names and got no address for any counts for none of them: the
//   lookups failed, not the names.
// - Only the names the refresh asked are touched: an entry that is off, a wildcard and an IP
//   range keep what they had.
// - One answer clears the count.
// The entry keeps only the count and the day of the first failure. The count stops at
// `threshold`, so a name that stays dead writes the config at most `threshold` times.

import Foundation

/// The refreshes in a row that found no address for an entry, and when the first of them ran.
struct ResolveFailures: Codable, Equatable {
    var count: Int
    var since: Date
}

enum StaleEntries {
    /// Failed refreshes in a row before a row says it has stopped resolving: three hours at
    /// the default hourly refresh.
    static let threshold = 3

    static func isStale(_ entry: DomainEntry) -> Bool {
        (entry.resolveFailures?.count ?? 0) >= threshold
    }

    /// One refresh's outcome applied to the list it resolved. `attempted` holds every name the
    /// refresh asked, `resolved` those that came back with an address. Returns nil when no entry
    /// changes, so the caller writes the config only when something did.
    static func record(_ entries: [DomainEntry], attempted: Set<String>, resolved: Set<String>,
                       vpnUp: Bool, now: Date) -> [DomainEntry]? {
        guard vpnUp else { return nil }
        if attempted.count > 1 && resolved.isEmpty { return nil }

        var out = entries
        var changed = false
        for i in out.indices {
            let entry = out[i]
            guard entry.enabled, !entry.isWildcard, !entry.isCIDR, attempted.contains(entry.domain) else { continue }
            let next: ResolveFailures?
            if resolved.contains(entry.domain) {
                next = nil
            } else {
                let previous = entry.resolveFailures
                next = ResolveFailures(count: min((previous?.count ?? 0) + 1, threshold),
                                       since: previous?.since ?? now)
            }
            if next != entry.resolveFailures {
                out[i].resolveFailures = next
                changed = true
            }
        }
        return changed ? out : nil
    }

    /// The row's detail line: "Hasn't resolved since 3 Oct". The month is in the language the
    /// sentence comes in (the bundle's), not the system region's, unless `locale` is given.
    static func detail(since: Date, locale: Locale? = nil, bundle: Bundle = .main) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale ?? Locale(identifier: language(of: bundle))
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        let day = formatter.string(from: since)
        return String(localized: "Hasn't resolved since \(day)", bundle: bundle)
    }

    /// The language a bundle's strings come in: an `xx.lproj` bundle's own, otherwise the one
    /// the bundle picks from the user's languages.
    private static func language(of bundle: Bundle) -> String {
        let url = bundle.bundleURL
        if url.pathExtension == "lproj" { return url.deletingPathExtension().lastPathComponent }
        return bundle.preferredLocalizations.first ?? "en"
    }
}
