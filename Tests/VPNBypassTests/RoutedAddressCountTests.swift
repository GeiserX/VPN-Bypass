// RoutedAddressCountTests.swift
// Coverage for the one address count every screen shows (RoutedBySource.addressCount, read
// through RouteManager.routedAddressCount).
//
// The problem it locks down: in VPN Only the routes card listed 2 addresses and an
// "Everything else: direct" line, while the header's Addresses fact, the line under Refresh
// Routes and the Status page said "6 routed": they counted the 4 catch-alls the app installs.
// Every count now follows the card: the user's own destinations, never the catch-alls.

import XCTest
@testable import VPNBypassCore

final class RoutedAddressCountTests: XCTestCase {

    private func route(_ destination: String, _ source: String) -> RoutedBySource.InstalledRoute {
        .init(destination: destination, source: source)
    }

    private let catchAlls = ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"]
    private var catchAllRoutes: [RoutedBySource.InstalledRoute] {
        catchAlls.map { route($0, ClassicRouteCompiler.catchAllSource) }
    }

    func testVPNOnlyLeavesTheCatchAllsOut() {
        let routes = [route("10.20.0.0/16", "10.20.0.0/16"), route("140.82.112.4", "github.com")] + catchAllRoutes
        XCTAssertEqual(RoutedBySource.addressCount(routes, vpnOnly: true), 2)
        XCTAssertTrue(RoutedBySource.everythingElseDirect(routes, vpnOnly: true))
        XCTAssertEqual(RoutedBySource.addressCount(catchAllRoutes, vpnOnly: true), 0)
    }

    /// Bypass has no catch-alls; left installed after a switch they are routes like any other,
    /// as the card lists them under "Left from earlier".
    func testBypassCountsEveryDestinationOnce() {
        let routes = [route("91.108.4.0/22", "Telegram"), route("91.108.4.0/22", "telegram.org"),
                      route("142.250.1.1", "YouTube")]
        XCTAssertEqual(RoutedBySource.addressCount(routes, vpnOnly: false), 2)
        XCTAssertEqual(RoutedBySource.addressCount(routes + catchAllRoutes, vpnOnly: false), 6)
        XCTAssertFalse(RoutedBySource.everythingElseDirect(routes + catchAllRoutes, vpnOnly: false))
    }

    func testCustomCountsWhatItsRulesInstalled() {
        let routes = [route("10.9.0.0/16", "10.9.0.0/16"), route("1.2.3.4", "b.example")]
        XCTAssertEqual(RoutedBySource.addressCount(routes, vpnOnly: false), 2)
    }

    /// A catch-all is the app's own only when it is recorded under the catch-all source. The
    /// same range on the user's own list is one of the user's destinations, and counts.
    func testTheSameRangeOnTheUsersListCounts() {
        XCTAssertEqual(RoutedBySource.addressCount([route("0.0.0.0/2", "0.0.0.0/2")], vpnOnly: true), 1)
    }

    /// The card's own count is this function, in every mode.
    func testTheCardCountsTheSameWay() throws {
        var c = RouteManager.Config()
        c.services = []
        c.domains = []
        c.rules = []
        c.inverseDomains = [DomainEntry(domain: "github.com")]
        let routes = [route("140.82.112.4", "github.com"), route("140.82.112.3", "github.com")] + catchAllRoutes
        for (mode, vpnOnly) in [(DropdownCopy.Mode.vpnOnly, true), (.bypass, false), (.custom, false)] {
            let card = try XCTUnwrap(RoutedBySource.make(mode: mode, config: c, routes: routes, busy: false), "\(mode)")
            XCTAssertEqual(card.routeCount, RoutedBySource.addressCount(routes, vpnOnly: vpnOnly), "\(mode)")
        }
    }
}

/// The live state: what the header, the result line, the status sentence and the Status page
/// read from RouteManager.
@MainActor
final class RoutedAddressCountLiveTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedRoutes: [RouteManager.ActiveRoute] = []
    private var savedChange: RouteManager.RouteChangeOutcome?
    private var savedCheck: RouteCheck.Run?
    private let rm = RouteManager.shared

    override func setUp() {
        super.setUp()
        savedConfig = rm.config
        savedRoutes = rm.activeRoutes
        savedChange = rm.lastRouteChange
        savedCheck = rm.lastRouteCheck
    }

    override func tearDown() {
        rm.config = savedConfig
        rm.activeRoutes = savedRoutes
        rm.lastRouteChange = savedChange
        rm.lastRouteCheck = savedCheck
        super.tearDown()
    }

    private func active(_ destination: String, _ source: String) -> RouteManager.ActiveRoute {
        RouteManager.ActiveRoute(destination: destination, gateway: "192.168.1.1", source: source, timestamp: Date())
    }

    private var catchAlls: [RouteManager.ActiveRoute] {
        ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"].map { active($0, ClassicRouteCompiler.catchAllSource) }
    }

    private func setMode(_ mode: RouteManager.RoutingMode) {
        var c = RouteManager.Config()
        c.routingMode = mode
        c.schemaVersion = mode == .custom ? 2 : 1
        c.manageHostsFile = false
        c.services = []
        c.domains = []
        c.rules = []
        c.inverseDomains = [DomainEntry(domain: "github.com"), DomainEntry(domain: "10.20.0.0/16", isCIDR: true)]
        rm.config = c
    }

    /// The reported case: VPN Only with two entries routed. The header and the Status page
    /// read 2, as the card does, not 6.
    func testVPNOnlyStatusInputCountsWhatTheCardCounts() throws {
        setMode(.vpnOnly)
        rm.activeRoutes = [active("140.82.112.4", "github.com"), active("10.20.0.0/16", "10.20.0.0/16")] + catchAlls
        XCTAssertEqual(rm.uniqueRouteCount, 6, "the kernel count, for logs and the socket, keeps the catch-alls")
        XCTAssertEqual(rm.routedAddressCount, 2)

        let input = DropdownStatus.Input.current(rm, helperReady: true)
        XCTAssertEqual(input.installedRoutes, 2)
        XCTAssertTrue(input.everythingElseDirect)
        let card = try XCTUnwrap(RoutedBySource.make(mode: input.mode, config: rm.config,
                                                     routes: rm.installedRoutes, busy: false))
        XCTAssertEqual(card.routeCount, input.installedRoutes)
    }

    /// Bypass and Custom have no catch-alls to leave out: the count is every destination once.
    func testBypassAndCustomCountEveryDestination() {
        for mode in [RouteManager.RoutingMode.bypass, .custom] {
            setMode(mode)
            rm.activeRoutes = [active("1.1.1.1", "a"), active("1.1.1.1", "b"), active("2.2.2.2", "b")]
            XCTAssertEqual(rm.routedAddressCount, 2, "\(mode)")
            XCTAssertEqual(DropdownStatus.Input.current(rm, helperReady: true).installedRoutes, 2, "\(mode)")
            XCTAssertFalse(rm.everythingElseDirect, "\(mode)")
        }
    }

    /// The result line keeps the count a removal recorded, so the removal has to record the
    /// same count the screen shows. With no helper nothing is removed, and VPN Only's 2
    /// addresses (not 6) are what is still routed.
    func testARemovalRecordsTheShownCount() async throws {
        try XCTSkipIf(HelperManager.shared.isHelperInstalled,
                      "this test exercises the helper-unavailable path; a real helper is installed here")
        setMode(.vpnOnly)
        rm.activeRoutes = [active("140.82.112.4", "github.com"), active("10.20.0.0/16", "10.20.0.0/16")] + catchAlls
        rm.lastRouteChange = nil

        await rm.removeAllRoutes()

        let outcome = try XCTUnwrap(rm.lastRouteChange)
        XCTAssertEqual(outcome.kind, .removedAll)
        XCTAssertEqual(outcome.routeCount, 2)
        XCTAssertNotNil(DropdownCopy.shownRouteChange(outcome, currentRouteCount: rm.routedAddressCount),
                        "the line and the header compare the same count, so the removal line stays")
    }

    /// The Status page's Last check row says "1 of N checked" with the card's count too.
    func testTheLastCheckRowCountsWhatTheCardCounts() {
        setMode(.vpnOnly)
        rm.activeRoutes = [active("140.82.112.4", "github.com"), active("10.20.0.0/16", "10.20.0.0/16")] + catchAlls
        let plan = RouteCheck.Plan(destinations: ["140.82.112.4"], sources: ["140.82.112.4": "github.com"],
                                   singleAddresses: 1, routeCount: 2)
        let result = RouteVerificationResult(destination: "140.82.112.4", isReachable: true, latency: 5,
                                             timestamp: Date(), error: nil)
        rm.lastRouteCheck = RouteCheck.Run(plan: plan, results: [result], logsFrom: Date(), at: Date())
        let text = StatusPage.lastCheck(rm, now: Date()).line.text
        XCTAssertTrue(text.hasPrefix("1 of 2 checked"), text)
    }
}

/// The sentences for VPN Only's catch-alls alone are translated.
final class RoutedAddressCountStringsTests: XCTestCase {
    func testTheCatchAllSentencesAreTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let keys = ["Stop sending everything else direct?", "Everything else still goes direct, as before the drop."]
        for language in ["es", "fr"] {
            let url = root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
            for key in keys {
                let value = try XCTUnwrap(table[key], "\(language): \(key)")
                XCTAssertNotEqual(value, key, "\(language): \(key)")
            }
        }
    }
}
