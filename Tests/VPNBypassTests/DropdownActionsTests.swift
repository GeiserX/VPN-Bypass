// DropdownActionsTests.swift
// Coverage for the dropdown's action row: the result line under Refresh Routes, the question
// Remove All Routes… asks, and the outcome RouteManager records for both.
//
// The problems these lock down: Clear removed every route on one click with no question and no
// message after, and the footer then read "Updated 0 sec ago". Refresh Routes said nothing in the
// dropdown about what it did.

import XCTest
@testable import VPNBypassCore

final class DropdownCopyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func applied(_ routes: Int, failed: Int = 0, secondsAgo: TimeInterval = 23) -> RouteManager.RouteChangeOutcome {
        .init(kind: .applied, at: now.addingTimeInterval(-secondsAgo), routeCount: routes, failedCount: failed)
    }

    // MARK: age

    func testAgeBuckets() {
        XCTAssertEqual(DropdownCopy.age(since: now, now: now), "just now")
        XCTAssertEqual(DropdownCopy.age(since: now.addingTimeInterval(-4.9), now: now), "just now")
        XCTAssertEqual(DropdownCopy.age(since: now.addingTimeInterval(-5), now: now), "5 s ago")
        XCTAssertEqual(DropdownCopy.age(since: now.addingTimeInterval(-59), now: now), "59 s ago")
        XCTAssertEqual(DropdownCopy.age(since: now.addingTimeInterval(-60), now: now), "1 min ago")
        XCTAssertEqual(DropdownCopy.age(since: now.addingTimeInterval(-3599), now: now), "59 min ago")
        XCTAssertEqual(DropdownCopy.age(since: now.addingTimeInterval(-7200), now: now), "2 h ago")
    }

    /// A clock moved backwards must not print a negative age.
    func testFutureDateReadsJustNow() {
        XCTAssertEqual(DropdownCopy.age(since: now.addingTimeInterval(120), now: now), "just now")
    }

    // MARK: result line

    func testCleanApplySaysNoneFailed() {
        let line = DropdownCopy.routeChangeLine(applied(62), now: now)
        XCTAssertEqual(line.text, "62 routes applied 23 s ago, none failed.")
        XCTAssertFalse(line.isProblem)
    }

    func testOneRouteIsSingular() {
        XCTAssertEqual(DropdownCopy.routeChangeLine(applied(1), now: now).text,
                       "1 route applied 23 s ago, none failed.")
    }

    func testFailuresAreCountedAndFlagged() {
        let line = DropdownCopy.routeChangeLine(applied(60, failed: 2), now: now)
        XCTAssertEqual(line.text, "60 routes applied 23 s ago, 2 failed.")
        XCTAssertTrue(line.isProblem)
    }

    /// Custom mode with only proxy rules installs no kernel route, and that is not a failure.
    func testNothingToInstallIsNotAFailure() {
        let line = DropdownCopy.routeChangeLine(applied(0), now: now)
        XCTAssertEqual(line.text, "No routes to install, checked 23 s ago.")
        XCTAssertFalse(line.isProblem)
    }

    /// Every domain failing to resolve is zero routes AND a failure: it must say so.
    func testZeroRoutesWithFailuresIsAProblem() {
        let line = DropdownCopy.routeChangeLine(applied(0, failed: 3), now: now)
        XCTAssertEqual(line.text, "0 routes applied 23 s ago, 3 failed.")
        XCTAssertTrue(line.isProblem)
    }

    /// After Remove All, the line says the routes are gone, never that they are fresh.
    func testRemovalSaysRoutesAreGone() {
        let outcome = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now.addingTimeInterval(-3),
                                                      routeCount: 0, failedCount: 0)
        let line = DropdownCopy.routeChangeLine(outcome, now: now)
        XCTAssertEqual(line.text, "All routes removed just now.")
        XCTAssertTrue(line.isProblem)
    }

    func testRemovalWithFailuresCountsThem() {
        let outcome = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now.addingTimeInterval(-90),
                                                      routeCount: 3, failedCount: 3)
        XCTAssertEqual(DropdownCopy.routeChangeLine(outcome, now: now).text,
                       "Routes removed 1 min ago, 3 could not be removed.")
    }

    // MARK: Remove All confirmation

    func testBypassConfirmationNamesServicesAndDomains() {
        let copy = DropdownCopy.removeAllConfirmation(mode: .bypass, routeCount: 62, serviceCount: 4,
                                                      domainCount: 2, autoDNSRefresh: true)
        XCTAssertEqual(copy.title, "Remove all 62 routes?")
        XCTAssertEqual(copy.message, "Your 4 services and 2 domains will go through the VPN until you refresh routes, the VPN reconnects, or DNS is next refreshed.")
    }

    func testBypassConfirmationSingularsAndMissingHalves() {
        XCTAssertEqual(
            DropdownCopy.removeAllConfirmation(mode: .bypass, routeCount: 5, serviceCount: 1, domainCount: 0,
                                               autoDNSRefresh: true).message,
            "Your 1 service will go through the VPN until you refresh routes, the VPN reconnects, or DNS is next refreshed.")
        XCTAssertEqual(
            DropdownCopy.removeAllConfirmation(mode: .bypass, routeCount: 1, serviceCount: 0, domainCount: 1,
                                               autoDNSRefresh: true).message,
            "Your 1 domain will go through the VPN until you refresh routes, the VPN reconnects, or DNS is next refreshed.")
        XCTAssertEqual(
            DropdownCopy.removeAllConfirmation(mode: .bypass, routeCount: 1, serviceCount: 0, domainCount: 0,
                                               autoDNSRefresh: true).title,
            "Remove the 1 route?")
    }

    /// With the automatic DNS refresh off, a DNS refresh never comes, so the message must not promise it.
    func testNoDNSRefreshPromiseWhenAutoRefreshIsOff() {
        let message = DropdownCopy.removeAllConfirmation(mode: .bypass, routeCount: 62, serviceCount: 4,
                                                         domainCount: 2, autoDNSRefresh: false).message
        XCTAssertEqual(message, "Your 4 services and 2 domains will go through the VPN until you refresh routes or the VPN reconnects.")
        XCTAssertFalse(message.contains("DNS"))
    }

    /// VPN Only and Custom do not send "your services" through the VPN; they say what they lose.
    func testVPNOnlyAndCustomSayWhatTheyLose() {
        XCTAssertEqual(
            DropdownCopy.removeAllConfirmation(mode: .vpnOnly, routeCount: 6, serviceCount: 4, domainCount: 2,
                                               autoDNSRefresh: true).message,
            "VPN Only stops: all traffic follows your VPN's own routing until you refresh routes, the VPN reconnects, or DNS is next refreshed.")
        let custom = DropdownCopy.removeAllConfirmation(mode: .custom, routeCount: 6, serviceCount: 0, domainCount: 0,
                                                        autoDNSRefresh: false).message
        XCTAssertTrue(custom.hasPrefix("Traffic your rules send direct or to a specific VPN will follow your VPN's own routing until you refresh routes or the VPN reconnects."))
        XCTAssertTrue(custom.hasSuffix("Rules that use a proxy keep working."))
    }
}

/// The outcome RouteManager records for the result line.
@MainActor
final class RouteChangeOutcomeTests: XCTestCase {

    private var savedRoutes: [RouteManager.ActiveRoute] = []
    private var savedChange: RouteManager.RouteChangeOutcome?

    override func setUp() {
        super.setUp()
        savedRoutes = RouteManager.shared.activeRoutes
        savedChange = RouteManager.shared.lastRouteChange
    }

    override func tearDown() {
        RouteManager.shared.activeRoutes = savedRoutes
        RouteManager.shared.lastRouteChange = savedChange
        super.tearDown()
    }

    private func route(_ dest: String) -> RouteManager.ActiveRoute {
        RouteManager.ActiveRoute(destination: dest, gateway: "192.168.1.1", source: "s", timestamp: Date())
    }

    /// With no helper nothing can be removed, and the outcome must say so rather than "removed".
    func testRemovalThatCouldNotRunIsRecordedAsFailed() async throws {
        let rm = RouteManager.shared
        try XCTSkipIf(HelperManager.shared.isHelperInstalled,
                      "this test exercises the helper-unavailable path; a real helper is installed here")
        rm.activeRoutes = [route("1.1.1.1"), route("2.2.2.2")]
        rm.lastRouteChange = nil

        await rm.removeAllRoutes()

        let outcome = try XCTUnwrap(rm.lastRouteChange)
        XCTAssertEqual(outcome.kind, .removedAll)
        XCTAssertEqual(outcome.failedCount, 2)
        XCTAssertEqual(outcome.routeCount, 2, "both routes are still installed and still in the model")
    }

    /// A removal with nothing installed (a disconnect, a quit) must not replace the last apply's result.
    func testNoOpRemovalKeepsTheLastApplyResult() async {
        let rm = RouteManager.shared
        rm.activeRoutes = []
        let earlier = RouteManager.RouteChangeOutcome(kind: .applied, at: Date(timeIntervalSince1970: 1_000),
                                                      routeCount: 62, failedCount: 0)
        rm.lastRouteChange = earlier

        await rm.removeAllRoutes()

        XCTAssertEqual(rm.lastRouteChange, earlier)
    }
}
