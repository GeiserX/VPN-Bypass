// SharedAddress.swift
// A listed name served from a shared CDN address (idea 11 of docs/design/APP-REWORK-PROPOSALS.md).
// Routing is per IP: a route for a name behind Cloudflare, Fastly or CloudFront is a route for
// every other site on that address, which then takes the same way. The Domains row says so in
// its detail line. It is information only: nothing is routed differently.
//
// The ranges are the CDNs' own published lists, in CDNRangeList.swift, which
// scripts/update-cdn-ranges.py writes. They go stale between refreshes, and a CDN that publishes
// no list (Akamai) is not recognised, so a row without the line may still share its address.

import Foundation

enum SharedAddress {
    struct Range: Equatable {
        let start: UInt32
        let end: UInt32
        let cdn: String
    }

    /// Sorted by start, none overlapping (the script checks both; a test holds them).
    static let ranges: [Range] = parse(CDNRangeList.ranges)

    static func parse(_ list: [(cdn: String, cidr: String)]) -> [Range] {
        list.compactMap { item -> Range? in
            guard let cidr = RouteCIDR.parse(item.cidr),
                  let network = RouteKernel.ipv4ToUInt32(cidr.network) else { return nil }
            let size: UInt32 = cidr.prefixLength == 0 ? .max : (UInt32(1) << (32 - UInt32(cidr.prefixLength))) - 1
            return Range(start: network, end: network + size, cdn: item.cdn)
        }
        .sorted { $0.start < $1.start }
    }

    /// The CDN whose published range holds `address`, or nil for any other address, a range
    /// ("10.20.0.0/16") and anything that is not IPv4.
    static func cdn(for address: String, in ranges: [Range] = ranges) -> String? {
        guard let ip = RouteKernel.ipv4ToUInt32(address) else { return nil }
        // The last range that starts at or before the address is the only one that can hold it.
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].start <= ip { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let range = ranges[low - 1]
        return ip <= range.end ? range.cdn : nil
    }

    /// For each route source (a listed name, or `*.suffix` for a wildcard's learned routes) whose
    /// routes reach a CDN address, that CDN's name; the first such route decides.
    static func cdnBySource(_ routes: [(source: String, destination: String)],
                            in ranges: [Range] = ranges) -> [String: String] {
        var out: [String: String] = [:]
        for route in routes where out[route.source] == nil {
            if let cdn = cdn(for: route.destination, in: ranges) { out[route.source] = cdn }
        }
        return out
    }

    /// The row's detail line. Which way the other sites go depends on the list: around the VPN
    /// for the Bypass list, into it for the VPN Only list.
    static func detail(cdn: String, isInverse: Bool, bundle: Bundle = .main) -> String {
        isInverse
            ? String(localized: "Shared CDN address (\(cdn)): other sites on it use the VPN too", bundle: bundle)
            : String(localized: "Shared CDN address (\(cdn)): other sites on it bypass the VPN too", bundle: bundle)
    }
}
