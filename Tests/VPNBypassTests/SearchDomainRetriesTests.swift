// SearchDomainRetriesTests.swift
// The Lookups page listed every search-domain retry of a failed name as its own row
// (host.example.com.corp.example, host.example.com.lab.example, ...). The search domains come
// from `scutil --dns`; a name that is an observed name plus one of them is folded away.

import XCTest
@testable import VPNBypassCore

final class SearchDomainRetriesTests: XCTestCase {

    /// `scutil --dns` as macOS prints it, trimmed: two resolvers repeat the search list, and a
    /// scoped one adds its own.
    private let fixture = """
    DNS configuration

    resolver #1
      search domain[0] : corp.example
      search domain[1] : lab.example.
      nameserver[0] : 192.0.2.53
      if_index : 15 (en0)
      flags    : Request A records
      reach    : 0x00020002 (Reachable,Directly Reachable Address)

    resolver #2
      domain   : local
      options  : mdns
      timeout  : 5

    DNS configuration (for scoped queries)

    resolver #1
      search domain[0] : Corp.Example
      search domain[1] : vpn.example
      nameserver[0] : 198.51.100.53
      if_index : 22 (utun4)
    """

    func testTheSearchDomainsAreReadFromScutilEachOnce() {
        XCTAssertEqual(SearchDomainRetries.searchDomains(fromScutilDNS: fixture), ["corp.example", "lab.example", "vpn.example"])
        XCTAssertEqual(SearchDomainRetries.searchDomains(fromScutilDNS: "DNS configuration\n\nresolver #1\n  nameserver[0] : 192.0.2.53\n"), [])
    }

    /// A read that fails leaves no search domain, so the last network's domains hide nothing.
    func testAFailedReadLeavesNoSearchDomain() {
        XCTAssertEqual(SearchDomainRetries.searchDomains(afterRead: nil), [])
        XCTAssertEqual(SearchDomainRetries.searchDomains(afterRead: fixture), ["corp.example", "lab.example", "vpn.example"])
    }

    /// A search lists every name it matches: a retry the user searches for is shown, and the
    /// page never says no name matches while it holds one.
    func testASearchListsTheRetriesItMatches() {
        var tally = DNSLookupTally()
        tally.record(["host.example.com", "host.example.com.corp.example"], at: Date())
        let found = LookupsTab.listed(tally, matching: "corp", searchDomains: ["corp.example"], showsRetries: false)
        XCTAssertEqual(found.names.map(\.name), ["host.example.com.corp.example"])
        XCTAssertEqual(found.retries, 0)
        XCTAssertEqual(LookupsTab.Content.resolve(isOn: true, matching: found.names.count, query: "corp"), .names)
    }

    func testANameWithASearchDomainAppendedIsARetry() {
        let domains = SearchDomainRetries.searchDomains(fromScutilDNS: fixture)
        let names = ["host.example.com", "host.example.com.corp.example", "host.example.com.lab.example",
                     "host.example.com.vpn.example", "github.com",
                     // Not retries: the base was never looked up, a single label's expansion is
                     // the name meant, and a suffix that is not a whole label.
                     "other.example.org.corp.example", "intranet", "intranet.corp.example", "host.example.comcorp.example"]
        XCTAssertEqual(SearchDomainRetries.retries(among: names, searchDomains: domains),
                       ["host.example.com.corp.example", "host.example.com.lab.example", "host.example.com.vpn.example"])
        // `.lab.example` style suffixes are found by shape too, so only the one-label one needs scutil.
        XCTAssertEqual(SearchDomainRetries.retries(among: ["host.example.com", "host.example.com.lan"], searchDomains: ["lan"]),
                       ["host.example.com.lan"])
        XCTAssertEqual(SearchDomainRetries.retries(among: ["host.example.com", "host.example.com.lan"], searchDomains: []), [])
    }

    /// A VPN client appended its own list of company domains, which `scutil --dns` never shows:
    /// one failed name became twenty rows, each looked up again and again.
    private let clientSuffixes = (1...20).map { "corp\($0).example.\(["net", "co", "media", "com", "org"][$0 % 5])" }

    func testRetriesWithSuffixesNoResolverListsAreFoldedByShape() {
        let retries = clientSuffixes.map { "host.example.com.\($0)" }
        let names = ["host.example.com", "github.com"] + retries
        XCTAssertEqual(SearchDomainRetries.retries(among: names, searchDomains: []), Set(retries))
        XCTAssertEqual(SearchDomainRetries.retries(among: names, searchDomains: ["tail.example.ts.net"]), Set(retries))
    }

    func testACountryOrPublicSuffixTailIsNeverARetry() {
        let names = ["example.com", "example.com.cn", "www.example.com", "www.example.com.cn",
                     "www.example", "www.example.co", "www.example.co.uk", "example.co", "example.co.uk",
                     "host.example.com", "host.example.com.co.uk",
                     "host.example.com.github.io", "www.example.com.s3.amazonaws.com"]
        XCTAssertEqual(SearchDomainRetries.retries(among: names, searchDomains: []), [])
    }

    func testARetryWhoseBaseWasNeverLookedUpIsNotFolded() {
        let names = ["github.com"] + clientSuffixes.map { "host.example.com.\($0)" }
        XCTAssertEqual(SearchDomainRetries.retries(among: names, searchDomains: []), [])
    }

    /// The Lookups list folds them under its toggle with no search domain read.
    func testTheListFoldsShapeRetriesWithNoSearchDomain() {
        var tally = DNSLookupTally()
        tally.record(["host.example.com", "github.com"] + clientSuffixes.map { "host.example.com.\($0)" }, at: Date())
        let listed = LookupsTab.listed(tally, matching: "", searchDomains: [], showsRetries: false)
        XCTAssertEqual(Set(listed.names.map(\.name)), ["host.example.com", "github.com"])
        XCTAssertEqual(listed.retries, 20)
    }

    func testThePageHidesTheRetriesUntilAskedAndCountsThem() throws {
        var tally = DNSLookupTally()
        tally.record(["host.example.com", "host.example.com.corp.example", "host.example.com.lab.example", "github.com"], at: Date())
        let hidden = LookupsTab.listed(tally, matching: "", searchDomains: ["corp.example", "lab.example"], showsRetries: false)
        XCTAssertEqual(Set(hidden.names.map(\.name)), ["host.example.com", "github.com"])
        XCTAssertEqual(hidden.retries, 2)
        let shown = LookupsTab.listed(tally, matching: "", searchDomains: ["corp.example", "lab.example"], showsRetries: true)
        XCTAssertEqual(shown.names.count, 4)
        XCTAssertEqual(LookupsTab.listed(tally, matching: "github", searchDomains: ["corp.example"], showsRetries: false).retries, 0,
                       "the toggle counts the retries the search matches")

        XCTAssertEqual(LookupsTab.retriesToggleTitle(count: 2, showing: false), "Show 2 search-domain retries")
        XCTAssertEqual(LookupsTab.retriesToggleTitle(count: 1, showing: false), "Show 1 search-domain retry")
        XCTAssertEqual(LookupsTab.retriesToggleTitle(count: 2, showing: true), "Hide search-domain retries")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["es", "fr"] {
            let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
            for (count, showing) in [(2, false), (1, false), (2, true)] {
                XCTAssertNotEqual(LookupsTab.retriesToggleTitle(count: count, showing: showing, in: bundle),
                                  LookupsTab.retriesToggleTitle(count: count, showing: showing), "\(language)")
            }
        }
    }
}
