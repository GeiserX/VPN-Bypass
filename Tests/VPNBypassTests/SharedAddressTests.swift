// SharedAddressTests.swift
// The shared CDN address warning (idea 11 of the rework). Routing is per IP, so a listed name
// behind a CDN takes every other site on that address with it, and nothing on screen said so.
// These hold the range match, the bundled list the script writes, and the Domains row's line.

import XCTest
@testable import VPNBypassCore

final class SharedAddressTests: XCTestCase {

    private let sample = SharedAddress.parse([
        (cdn: "Fastly", cidr: "151.101.0.0/16"),
        (cdn: "Cloudflare", cidr: "104.16.0.0/13"),
        (cdn: "Cloudflare", cidr: "1.1.1.0/24"),
    ])

    // MARK: The range match

    func testAnAddressInsideARangeNamesItsCDN() {
        XCTAssertEqual(SharedAddress.cdn(for: "104.18.32.7", in: sample), "Cloudflare")
        XCTAssertEqual(SharedAddress.cdn(for: "151.101.65.140", in: sample), "Fastly")
        XCTAssertEqual(SharedAddress.cdn(for: "1.1.1.1", in: sample), "Cloudflare")
    }

    /// A range's first and last addresses are in it; one past either end is not.
    func testTheEdgesOfARange() {
        XCTAssertEqual(SharedAddress.cdn(for: "104.16.0.0", in: sample), "Cloudflare")
        XCTAssertEqual(SharedAddress.cdn(for: "104.23.255.255", in: sample), "Cloudflare")
        XCTAssertNil(SharedAddress.cdn(for: "104.24.0.0", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "104.15.255.255", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "151.102.0.0", in: sample))
    }

    /// Below the first range, between two, above the last, and anything that is not one IPv4
    /// address: none is a CDN address.
    func testOtherAddressesAndNonAddressesMatchNothing() {
        XCTAssertNil(SharedAddress.cdn(for: "0.0.0.1", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "8.8.8.8", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "203.0.113.9", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "104.16.0.0/16", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "2606:4700::1", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "", in: sample))
        XCTAssertNil(SharedAddress.cdn(for: "1.1.1.1", in: []))
    }

    func testParseSortsByStartAndDropsWhatIsNotARange() {
        let ranges = SharedAddress.parse([(cdn: "B", cidr: "9.0.0.0/8"), (cdn: "A", cidr: "1.2.3.0/24"),
                                          (cdn: "X", cidr: "not a range"), (cdn: "X", cidr: "1.2.3.4")])
        XCTAssertEqual(ranges, [SharedAddress.Range(start: 0x0102_0300, end: 0x0102_03FF, cdn: "A"),
                                SharedAddress.Range(start: 0x0900_0000, end: 0x09FF_FFFF, cdn: "B")])
    }

    func testEachSourceTakesTheCDNOfItsRoutes() {
        let routes = [(source: "example.com", destination: "203.0.113.1"),
                      (source: "example.com", destination: "151.101.1.1"),
                      (source: "*.example.org", destination: "104.17.2.3"),
                      (source: "intranet.example.net", destination: "10.0.0.5")]
        XCTAssertEqual(SharedAddress.cdnBySource(routes, in: sample),
                       ["example.com": "Fastly", "*.example.org": "Cloudflare"])
    }

    // MARK: The bundled list

    /// The script writes the list; every line must parse, the list must be sorted with no
    /// overlap (the binary search relies on it), and each CDN must have ranges.
    func testTheBundledListIsSortedWholeAndCoversEachCDN() {
        XCTAssertEqual(SharedAddress.ranges.count, CDNRangeList.ranges.count, "every bundled line parses")
        for (a, b) in zip(SharedAddress.ranges, SharedAddress.ranges.dropFirst()) {
            XCTAssertLessThan(a.end, b.start, "\(a) overlaps or precedes \(b)")
        }
        XCTAssertEqual(Set(SharedAddress.ranges.map(\.cdn)), ["Cloudflare", "Fastly", "CloudFront"])
        // Well-known addresses each CDN publishes as its own.
        XCTAssertEqual(SharedAddress.cdn(for: "104.16.132.229"), "Cloudflare")
        XCTAssertEqual(SharedAddress.cdn(for: "151.101.1.140"), "Fastly")
        XCTAssertEqual(SharedAddress.cdn(for: "54.192.10.20"), "CloudFront")
        XCTAssertNil(SharedAddress.cdn(for: "192.168.1.10"))
    }

    // MARK: The Domains row

    private func config(bypass: [DomainEntry], vpnOnly: [DomainEntry] = []) -> Config {
        var c = Config()
        c.domains = bypass
        c.inverseDomains = vpnOnly
        return c
    }

    func testABypassRowOnACDNAddressSaysOtherSitesBypassToo() throws {
        let s = DomainsPage.sections(mode: .bypass,
                                     config: config(bypass: [DomainEntry(domain: "news.example.com"),
                                                             DomainEntry(domain: "own.example.net")]),
                                     routeSources: ["news.example.com", "own.example.net"], search: "",
                                     sharedCDNs: ["news.example.com": "Cloudflare"])
        XCTAssertEqual(try XCTUnwrap(s.first).rows.map(\.detail),
                       ["Shared CDN address (Cloudflare): other sites on it bypass the VPN too", nil])
    }

    func testAVPNOnlyRowSaysOtherSitesUseTheVPNToo() throws {
        let s = DomainsPage.sections(mode: .vpnOnly, config: config(bypass: [], vpnOnly: [DomainEntry(domain: "app.example.com")]),
                                     routeSources: ["app.example.com"], search: "",
                                     sharedCDNs: ["app.example.com": "Fastly"])
        XCTAssertEqual(try XCTUnwrap(s.first).rows.map(\.detail),
                       ["Shared CDN address (Fastly): other sites on it use the VPN too"])
    }

    /// A wildcard keeps its own words and adds the warning after them.
    func testAWildcardKeepsItsWordsFirst() throws {
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [DomainEntry(domain: "*.example.com")]),
                                     routeSources: ["*.example.com"], search: "",
                                     sharedCDNs: ["*.example.com": "CloudFront"])
        XCTAssertEqual(try XCTUnwrap(s.first).rows.first?.detail,
                       "learned as you browse · Shared CDN address (CloudFront): other sites on it bypass the VPN too")
    }

    /// Only a row that routes says it: not one that is off, not the read-only list, not Custom
    /// (neither list routes there), not a range the user typed, not a stale row.
    func testRowsThatRouteNothingOrAreTheUsersOwnRangeSayNothing() throws {
        let off = DomainEntry(domain: "off.example.com", enabled: false)
        let range = DomainEntry(domain: "104.16.0.0/13", isCIDR: true)
        var dead = DomainEntry(domain: "dead.example.com")
        dead.resolveFailures = ResolveFailures(count: StaleEntries.threshold, since: Date(timeIntervalSince1970: 0))
        let all = ["off.example.com": "Cloudflare", "104.16.0.0/13": "Cloudflare",
                   "dead.example.com": "Cloudflare", "intranet.example.org": "Cloudflare"]
        let bypass = DomainsPage.sections(mode: .bypass,
                                          config: config(bypass: [off, dead], vpnOnly: [DomainEntry(domain: "intranet.example.org")]),
                                          routeSources: [], search: "", sharedCDNs: all)
        XCTAssertEqual(bypass[0].rows.map(\.detail).map { $0?.contains("Shared") ?? false }, [false, false])
        XCTAssertEqual(bypass[1].rows.map(\.detail), [nil])
        let vpnOnly = DomainsPage.sections(mode: .vpnOnly, config: config(bypass: [], vpnOnly: [range]),
                                           routeSources: ["104.16.0.0/13"], search: "", sharedCDNs: all)
        XCTAssertEqual(vpnOnly[0].rows.map(\.detail), ["IP range"])
        let custom = DomainsPage.sections(mode: .custom, config: config(bypass: [DomainEntry(domain: "intranet.example.org")]),
                                          routeSources: ["intranet.example.org"], search: "", sharedCDNs: all)
        XCTAssertEqual(custom[0].rows.map(\.detail), [nil])
    }

    func testTheLineIsTranslated() throws {
        let es = try XCTUnwrap(Self.lproj("es"))
        let fr = try XCTUnwrap(Self.lproj("fr"))
        XCTAssertEqual(SharedAddress.detail(cdn: "Cloudflare", isInverse: false, bundle: es),
                       "Dirección de CDN compartida (Cloudflare): los demás sitios en ella también evitan la VPN")
        XCTAssertEqual(SharedAddress.detail(cdn: "Fastly", isInverse: true, bundle: fr),
                       "Adresse CDN partagée (Fastly) : les autres sites qui y sont hébergés passent aussi par le VPN")
    }

    private static func lproj(_ language: String) -> Bundle? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj"))
    }
}
