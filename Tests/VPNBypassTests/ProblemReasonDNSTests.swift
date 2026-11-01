// ProblemReasonDNSTests.swift
// A real Mac showed Status > Problems saying "No address is routed for it." for entries whose
// names did not resolve: the last apply did not name the failure (it came from the DNS cache,
// found the routes already current, or the entry was added on its own), so the page fell back
// to the vaguer reason. The DNS failure now wins, in Problems and in the dropdown's Show.

import XCTest
@testable import VPNBypassCore

// MARK: - Pure parts

final class ProblemReasonDNSTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func empty(_ id: String, _ icon: RoutedBySource.Icon) -> RoutedBySource.Row {
        .init(id: id, name: id, icon: icon, routeCount: 0, isProblem: true, addresses: [], hiddenAddresses: 0)
    }

    private func staleDomain(_ name: String) -> RouteManager.DomainEntry {
        var entry = RouteManager.DomainEntry(domain: name)
        entry.resolveFailures = ResolveFailures(count: StaleEntries.threshold, since: now)
        return entry
    }

    func testTheDNSFailuresAreTheLookupsThenTheDomainsThatStoppedResolving() {
        let failures = RouteManager.dnsFailures(
            lookups: ["Zoom": ["zoom.us", "zoomgov.com"], "intranet.example": ["intranet.example"]],
            domains: [staleDomain("intranet.example"), staleDomain("old.example"), RouteManager.DomainEntry(domain: "fine.example")])
        XCTAssertEqual(failures.map(\.entry), ["Zoom", "Zoom", "intranet.example", "old.example"],
                       "each entry once, a stale domain the lookups already name not twice")
        XCTAssertEqual(failures.map(\.target), ["zoom.us", "zoomgov.com", "intranet.example", "old.example"])
        XCTAssertTrue(failures.allSatisfy { $0.kind == .notResolved && $0.reason == "no answer from DNS" })
    }

    /// The last apply named nothing (an apply from the DNS cache counts no failure), yet the
    /// lookups and the stale count say these names did not resolve.
    func testAnEntryThatDidNotResolveSaysSoWhenTheApplyDoesNotNameIt() {
        let fromCache = RouteManager.RouteChangeOutcome(kind: .applied, at: now, routeCount: 60, failedCount: 0)
        let dns = RouteManager.dnsFailures(lookups: ["Zoom": ["zoom.us"]], domains: [staleDomain("intranet.example")])
        let problems = StatusPage.problems(lastChange: fromCache, installed: 60, helperReady: true,
                                           withoutAddresses: [empty("Zoom", .service(id: "zoom")),
                                                              empty("intranet.example", .domain),
                                                              empty("b.example", .domain)],
                                           dnsFailures: dns)
        XCTAssertEqual(problems.map(\.title), ["zoom.us", "intranet.example", "b.example"])
        XCTAssertEqual(problems.map(\.detail), [
            "Did not resolve, for Zoom: no answer from DNS",
            "Did not resolve: no answer from DNS",
            "No address is routed for it.",
        ])
        XCTAssertEqual(problems.map(\.kind), [.notResolved, .notResolved, .noAddresses])
    }

    /// A failure the apply names keeps its own row; the lookups do not list the entry again.
    func testAnEntryTheApplyNamesIsNotListedAgainFromTheLookups() {
        let change = RouteManager.RouteChangeOutcome(kind: .applied, at: now, routeCount: 60, failedCount: 1, failures: [
            .init(kind: .notResolved, target: "zoom.us", entry: "Zoom", reason: "no answer from DNS"),
        ])
        let problems = StatusPage.problems(lastChange: change, installed: 60, helperReady: true,
                                           withoutAddresses: [empty("Zoom", .service(id: "zoom"))],
                                           dnsFailures: RouteManager.dnsFailures(lookups: ["Zoom": ["zoom.us"]], domains: []))
        XCTAssertEqual(problems.map(\.detail), ["Did not resolve, for Zoom: no answer from DNS"])
    }

    /// The dropdown's Show: a DNS failure wins over a refused route and over no reason at all.
    func testTheDropdownRowSaysItDidNotResolve() throws {
        let row = empty("zoom.us", .domain)
        let refused = RouteManager.RouteFailure(kind: .notRouted, target: "192.0.2.7", entry: "zoom.us", reason: "File exists")
        let dns = RouteManager.dnsFailures(lookups: ["zoom.us": ["zoom.us"]], domains: [])
        XCTAssertEqual(RoutedBySource.problemReason(for: row, failures: [refused] + dns), "Did not resolve: no answer from DNS")
        XCTAssertEqual(RoutedBySource.problemReason(for: row, failures: dns), "Did not resolve: no answer from DNS")
        XCTAssertEqual(RoutedBySource.problemReason(for: row, failures: [refused]), "Not routed: File exists")
        XCTAssertEqual(RoutedBySource.problemReason(for: row, failures: []), "No address is routed for it.")
    }

    /// A disabled entry keeps its old stale count; it is not the reason for a same-named entry
    /// in the other list.
    func testADisabledEntrysOldFailureIsNoReason() {
        var off = staleDomain("shared.example")
        off.enabled = false
        XCTAssertEqual(RouteManager.dnsFailures(lookups: [:], domains: [off]), [])
        XCTAssertEqual(RouteManager.dnsFailures(lookups: [:], domains: [off, staleDomain("old.example")]).map(\.entry),
                       ["old.example"])
    }

    /// A route refusal an earlier apply recorded does not hide that the entry's names no longer
    /// resolve: Problems says what the dropdown's Show says.
    func testADNSFailureReplacesAnOlderRouteRefusalForAnEmptyEntry() {
        let change = RouteManager.RouteChangeOutcome(kind: .applied, at: now, routeCount: 60, failedCount: 2, failures: [
            .init(kind: .notRouted, target: "192.0.2.7", entry: "Zoom", reason: "File exists"),
            .init(kind: .notRouted, target: "192.0.2.9", entry: "shop.example", reason: "File exists"),
        ])
        let dns = RouteManager.dnsFailures(lookups: ["Zoom": ["zoom.us"]], domains: [])
        let problems = StatusPage.problems(lastChange: change, installed: 60, helperReady: true,
                                           withoutAddresses: [empty("Zoom", .service(id: "zoom"))], dnsFailures: dns)
        XCTAssertEqual(problems.map(\.detail), ["Not routed, for shop.example: File exists",
                                                "Did not resolve, for Zoom: no answer from DNS"])
        let row = empty("Zoom", .service(id: "zoom"))
        XCTAssertEqual(RoutedBySource.problemReason(for: row, failures: change.failures + dns),
                       "Did not resolve: no answer from DNS")
    }

    /// A DNS refresh looks up every entry again, so it replaces the record as a full apply does:
    /// a name that answers now is cleared, one that stopped answering is recorded.
    func testARefreshReplacesTheLookupRecord() {
        let looked: [(domain: String, source: String)] = [("zoom.us", "Zoom"), ("zoomgov.com", "Zoom"),
                                                          ("a.example", "a.example"), ("b.example", "b.example")]
        let record = RouteManager.lookupRecord(looked: looked, answers: ["zoom.us": ["192.0.2.1"], "zoomgov.com": [],
                                                                          "a.example": ["192.0.2.2"]])
        XCTAssertEqual(record, ["Zoom": ["zoomgov.com"], "b.example": ["b.example"]])
        XCTAssertEqual(RouteManager.lookupRecord(looked: looked, answers: ["zoom.us": ["192.0.2.1"], "zoomgov.com": ["192.0.2.3"],
                                                                            "a.example": ["192.0.2.2"], "b.example": ["192.0.2.4"]]),
                       [:])
    }
}

// MARK: - Against a fake kernel

@MainActor
final class UnresolvedLookupsTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, gateway: String?, loading: Bool)!
    private var kernel: FakeKernel!

    override func setUp() async throws {
        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.localGateway, rm.isLoading)
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.services = []
        rm.config = cfg
        rm.resetShutdownStateForTests()
        rm.isVPNConnected = true
        rm.vpnInterface = "utun4"
        rm.localGateway = "192.168.1.1"
        rm.isLoading = false
        rm.activeRoutes = []
        clearLookups()
        kernel = FakeKernel(installed: [])
        kernel.attach(to: rm)
    }

    override func tearDown() async throws {
        rm.cancelAllRetries()
        FakeKernel.detach(from: rm)
        clearLookups()
        rm.activeRoutes = []
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.localGateway = saved.gateway
        rm.isLoading = saved.loading
        rm.resetShutdownStateForTests()
    }

    private func clearLookups() {
        for source in rm.unresolvedLookups.keys { rm.noteLookups(for: source, unresolved: []) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A name removed and added again while its lookup cannot run (here, no VPN) does not show
    /// the removed entry's DNS failure.
    func testAReAddedEntryDropsTheRemovedEntrysRecord() throws {
        rm.isVPNConnected = false
        rm.noteLookups(for: "gone.example.com", unresolved: ["gone.example.com"])
        _ = try rm.addDomain("gone.example.com").get()
        XCTAssertNil(rm.unresolvedLookups["gone.example.com"], "the removed entry's failure is still the reason")
    }

    /// Only the list the mode routes gives a stale reason: the other list keeps the count from
    /// when it was in use.
    func testOnlyTheModesListGivesAStaleReason() {
        var stale = RouteManager.DomainEntry(domain: "shared.example.com")
        stale.resolveFailures = ResolveFailures(count: StaleEntries.threshold, since: Date())
        var config = rm.config
        config.domains = [RouteManager.DomainEntry(domain: "shared.example.com")]
        config.inverseDomains = [stale]
        rm.config = config
        XCTAssertEqual(rm.currentDNSFailures, [], "Bypass took the VPN Only entry's stale count")
        config.routingMode = .vpnOnly
        rm.config = config
        XCTAssertEqual(rm.currentDNSFailures.map(\.entry), ["shared.example.com"])
    }

    /// A domain added on its own that gets no answer: its row says it did not resolve, and the
    /// record goes once the name answers.
    func testAnAddedDomainThatGetsNoAnswerIsRecordedThenClearedWhenItAnswers() async throws {
        _ = try rm.addDomain("dead.example.com").get()
        await waitUntil { rm.unresolvedLookups["dead.example.com"] != nil }
        XCTAssertEqual(rm.unresolvedLookups["dead.example.com"], ["dead.example.com"])
        let row = try XCTUnwrap(RoutedBySource.make(mode: .bypass, config: rm.config, routes: [], busy: false)?.problemRows.first)
        XCTAssertEqual(RoutedBySource.problemReason(for: row, failures: rm.currentDNSFailures), "Did not resolve: no answer from DNS")
        XCTAssertEqual(StatusPage.problems(lastChange: nil, installed: 0, helperReady: true, withoutAddresses: [row],
                                           dnsFailures: rm.currentDNSFailures).map(\.detail),
                       ["Did not resolve: no answer from DNS"])

        // Turned off and on again once DNS answers, the name is no longer recorded.
        rm.cancelAllRetries()
        kernel.dns["dead.example.com"] = ["192.0.2.44"]
        let entry = try XCTUnwrap(rm.config.domains.first)
        _ = rm.removeDomain(entry)
        await waitUntil { rm.config.domains.isEmpty && !rm.isApplyingRoutes }
        _ = try rm.addDomain("dead.example.com").get()
        await waitUntil { rm.unresolvedLookups["dead.example.com"] == nil }
        XCTAssertNil(rm.unresolvedLookups["dead.example.com"], "a name that answers is still recorded as failing")
    }
}
