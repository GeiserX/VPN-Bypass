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
        let groups = SiteLearning.groups(["a.shop.test", "b.shop.test", "c.shop.test", "img.cdn.test", "api.cdn.test"])
        let listed: Set<String> = ["b.shop.test", "api.cdn.test"]
        XCTAssertEqual(SiteLearning.plan(groups, wildcards: [], isListed: listed.contains),
                       ["a.shop.test", "c.shop.test", "img.cdn.test"])
        XCTAssertEqual(SiteLearning.plan(groups, wildcards: ["*.shop.test"], isListed: listed.contains),
                       ["*.shop.test", "img.cdn.test"])
    }

    func testPlanSkipsAWildcardAlreadyListedAndIgnoresOneNotOffered() {
        let groups = SiteLearning.groups(["a.shop.test", "b.shop.test", "c.shop.test", "img.cdn.test"])
        XCTAssertEqual(SiteLearning.plan(groups, wildcards: ["*.shop.test", "*.cdn.test"], isListed: { $0 == "*.shop.test" }),
                       ["img.cdn.test"])
    }
}
