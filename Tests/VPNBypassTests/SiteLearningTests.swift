// SiteLearningTests.swift
// Learn a site (SiteLearning.swift): the window keeps only the names first seen inside it, the
// names are grouped by the site's own domain, a site with three names or more is offered its
// wildcard, and the one Add skips what the mode already routes.

import XCTest
@testable import VPNBypassCore

final class SiteLearningTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The window

    func testKeepsOnlyNamesDrainedInsideTheWindow() {
        var learning = SiteLearning(started: start)
        learning.record(["before.example.com"], at: start.addingTimeInterval(-1))
        learning.record(["shop.example.com"], at: start)
        learning.record(["cdn.example.net"], at: start.addingTimeInterval(30))
        learning.record(["edge.example.org"], at: learning.ends)
        learning.record(["after.example.com"], at: learning.ends.addingTimeInterval(0.5))
        XCTAssertEqual(learning.names, ["shop.example.com", "cdn.example.net", "edge.example.org"])
    }

    func testANameCountsOnceInTheOrderFirstSeen() {
        var learning = SiteLearning(started: start)
        learning.record(["b.example.com", "a.example.com"], at: start.addingTimeInterval(3))
        learning.record(["a.example.com", "c.example.com", "b.example.com"], at: start.addingTimeInterval(6))
        XCTAssertEqual(learning.names, ["b.example.com", "a.example.com", "c.example.com"])
    }

    func testAClosedWindowTakesNoMoreNames() {
        var learning = SiteLearning(started: start)
        learning.record(["shop.example.com"], at: start.addingTimeInterval(3))
        learning.close()
        learning.record(["late.example.com"], at: start.addingTimeInterval(10))
        XCTAssertFalse(learning.isOpen)
        XCTAssertEqual(learning.names, ["shop.example.com"])
    }

    func testAnEmptyDrainInTheWindowSaysTheCaptureRan() {
        var learning = SiteLearning(started: start)
        learning.record([], at: start.addingTimeInterval(-1))
        XCTAssertFalse(learning.heard, "a drain before the window is not this window's")
        learning.record([], at: start.addingTimeInterval(2))
        XCTAssertTrue(learning.heard)
        XCTAssertEqual(learning.names, [])
    }

    func testTheWindowIsSixtySecondsAndCountsDown() {
        let learning = SiteLearning(started: start)
        XCTAssertEqual(learning.ends.timeIntervalSince(start), 60)
        XCTAssertEqual(learning.secondsLeft(at: start), 60)
        XCTAssertEqual(learning.secondsLeft(at: start.addingTimeInterval(59.2)), 1)
        XCTAssertEqual(learning.secondsLeft(at: start.addingTimeInterval(75)), 0)
    }

    // MARK: - Grouping

    func testGroupsByTheSiteDomainMostNamesFirst() {
        let groups = SiteLearning.groups([
            "www.shop.test", "img.cdn-shop.test", "api.shop.test", "login.shop.test", "static.cdn-shop.test", "localhost",
        ])
        XCTAssertEqual(groups.map(\.site), ["shop.test", "cdn-shop.test", "localhost"])
        XCTAssertEqual(groups[0].names, ["www.shop.test", "api.shop.test", "login.shop.test"])
        XCTAssertEqual(groups[1].names, ["img.cdn-shop.test", "static.cdn-shop.test"])
    }

    func testEqualGroupsKeepTheOrderFirstSeen() {
        let groups = SiteLearning.groups(["a.second.test", "a.first.test"])
        XCTAssertEqual(groups.map(\.site), ["second.test", "first.test"])
    }

    func testCountrySuffixAndHostingNamesGroupUnderTheCustomersOwnDomain() {
        let groups = SiteLearning.groups([
            "www.bbc.co.uk", "static.bbc.co.uk", "news.bbc.co.uk", "d1.cloudfront.net", "d2.cloudfront.net",
            "a.d1.cloudfront.net",
        ])
        XCTAssertEqual(groups.first { $0.site == "bbc.co.uk" }?.wildcard, "*.bbc.co.uk")
        XCTAssertEqual(groups.first { $0.site == "d1.cloudfront.net" }?.names, ["d1.cloudfront.net", "a.d1.cloudfront.net"])
        XCTAssertFalse(groups.contains { $0.site == "co.uk" || $0.site == "cloudfront.net" })
    }

    func testOffersTheWildcardFromThreeNames() {
        let two = SiteLearning.groups(["a.shop.test", "b.shop.test"])
        XCTAssertNil(two[0].wildcard)
        let three = SiteLearning.groups(["a.shop.test", "b.shop.test", "shop.test"])
        XCTAssertEqual(three[0].wildcard, "*.shop.test")
    }

    func testNoWildcardOverANameWithoutASiteDomain() {
        let groups = SiteLearning.groups(["router", "router", "router"])
        XCTAssertEqual(groups.map(\.site), ["router"])
        XCTAssertNil(groups[0].wildcard)
    }

    // MARK: - The one Add

    func testPlanAddsTheUnlistedNamesOrTheChosenWildcard() {
        let groups = SiteLearning.groups(["a.shop.test", "b.shop.test", "c.shop.test", "shop.test", "img.cdn.test", "api.cdn.test"])
        let listed: Set<String> = ["b.shop.test", "api.cdn.test"]
        XCTAssertEqual(SiteLearning.plan(groups, wildcards: [], isListed: listed.contains),
                       ["a.shop.test", "c.shop.test", "shop.test", "img.cdn.test"])
        // The wildcard covers the apex too, so the apex is not added beside it.
        XCTAssertEqual(SiteLearning.plan(groups, wildcards: ["*.shop.test"], isListed: listed.contains),
                       ["*.shop.test", "img.cdn.test"])
    }

    func testPlanSkipsAWildcardAlreadyListedAndIgnoresOneNotOffered() {
        let groups = SiteLearning.groups(["a.shop.test", "b.shop.test", "c.shop.test", "img.cdn.test"])
        XCTAssertEqual(SiteLearning.plan(groups, wildcards: ["*.shop.test", "*.cdn.test"], isListed: { $0 == "*.shop.test" }),
                       ["img.cdn.test"])
    }

    // MARK: - Noise: search-domain retries and other apps

    /// A failed name the resolver retried with each search domain made a group of its own,
    /// `corp.example`, of names no page needs. They are folded as on the Lookups list.
    func testFoldsSearchDomainRetriesOutOfTheGroups() {
        var learning = SiteLearning(started: start)
        learning.record(["www.news.example", "metrics.news.example", "metrics.news.example.corp.example",
                         "metrics.news.example.lab.example", "img.news-cdn.example"], at: start.addingTimeInterval(2))
        let folded = learning.shown(searchDomains: ["corp.example", "lab.example"], showsRetries: false)
        XCTAssertEqual(folded.site.map(\.site), ["news.example", "news-cdn.example"])
        XCTAssertEqual(folded.retries, 2)
        let shown = learning.shown(searchDomains: ["corp.example", "lab.example"], showsRetries: true)
        XCTAssertEqual(shown.site.map(\.site), ["news.example", "corp.example", "lab.example", "news-cdn.example"])
        XCTAssertEqual(shown.retries, 2)
        // With no search domain read, nothing is folded.
        XCTAssertEqual(learning.shown(searchDomains: [], showsRetries: false).retries, 0)
    }

    /// The name a retry came from may have been looked up just before the window opened.
    func testFoldsARetryWhoseNameWasLookedUpBeforeTheWindow() {
        var learning = SiteLearning(started: start, seenBefore: ["host.example.com"])
        learning.record(["host.example.com.corp.example", "www.news.example"], at: start.addingTimeInterval(2))
        let shown = learning.shown(searchDomains: ["corp.example"], showsRetries: false)
        XCTAssertEqual(shown.site.map(\.site), ["news.example"])
        XCTAssertEqual(shown.seenBefore, [])
        XCTAssertEqual(shown.retries, 1)
    }

    /// A music and a call app looking up their names meanwhile: their groups, every name of
    /// which was looked up before the window opened, are set apart and listed after the site's.
    func testSetsApartTheSitesOtherAppsWereAlreadyLookingUp() {
        let before: Set<String> = ["api.music.example", "audio.music.example", "img.music.example",
                                   "sip.voip.example", "www.news.example"]
        var learning = SiteLearning(started: start, seenBefore: before)
        learning.record(["api.music.example", "audio.music.example", "img.music.example", "www.news.example",
                         "sip.voip.example", "api.news.example"], at: start.addingTimeInterval(2))
        let shown = learning.shown(searchDomains: [], showsRetries: false)
        // news.example has a name first seen in the window, so it is the site's.
        XCTAssertEqual(shown.site.map(\.site), ["news.example"])
        XCTAssertEqual(shown.seenBefore.map(\.site), ["music.example", "voip.example"])
        XCTAssertTrue(shown.seenBefore.allSatisfy(\.seenBefore))
        XCTAssertEqual(shown.seenBefore.first?.wildcard, "*.music.example")
    }

    /// Nothing is set apart when the page was not watching before the window.
    func testNothingIsSetApartWithoutEarlierLookups() {
        var learning = SiteLearning(started: start)
        learning.record(["api.music.example"], at: start.addingTimeInterval(2))
        let shown = learning.shown(searchDomains: [], showsRetries: false)
        XCTAssertEqual(shown.site.map(\.site), ["music.example"])
        XCTAssertEqual(shown.seenBefore, [])
    }

    /// "Before" is the five minutes up to the window, from the Lookups count.
    func testSeenBeforeIsTheCountsLastFiveMinutes() {
        var tally = DNSLookupTally()
        tally.record(["old.example.com"], at: start.addingTimeInterval(-301))
        tally.record(["recent.example.com"], at: start.addingTimeInterval(-299))
        tally.record(["now.example.com"], at: start)
        XCTAssertEqual(SiteLearning.seenBefore(in: tally, before: start), ["recent.example.com", "now.example.com"])
        XCTAssertEqual(SiteLearning.seenBefore(in: DNSLookupTally(), before: start), [])
    }
}
