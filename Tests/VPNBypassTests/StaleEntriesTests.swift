// StaleEntriesTests.swift
// A listed domain that stopped resolving (idea 6 of the rework): after three failed refreshes
// in a row with the VPN up, its Domains row says since when and the header offers a filter.
//
// The problem it locks down: a dead name stayed on the list looking like any other, and every
// refresh kept asking for it. The rules below say which refreshes count, so an internal name
// asked with the VPN down, or a refresh whose lookups all failed, never marks a row.

import XCTest
@testable import VPNBypassCore

final class StaleEntriesTests: XCTestCase {

    private let day1 = Date(timeIntervalSince1970: 1_791_036_000)   // 3 Oct 2026, 14:00 UTC
    private var day2: Date { day1.addingTimeInterval(86_400) }

    private let dead = DomainEntry(domain: "gone.example.com")
    private let live = DomainEntry(domain: "en.wikipedia.org")

    /// One refresh with the VPN up: `dead` fails, `live` answers.
    private func refresh(_ entries: [DomainEntry], vpnUp: Bool = true, now: Date? = nil) -> [DomainEntry]? {
        StaleEntries.record(entries, attempted: ["gone.example.com", "en.wikipedia.org"],
                            resolved: ["en.wikipedia.org"], vpnUp: vpnUp, now: now ?? day1)
    }

    private func failures(_ entries: [DomainEntry]?, _ name: String) -> ResolveFailures? {
        entries?.first { $0.domain == name }?.resolveFailures
    }

    // MARK: Which refreshes count

    func testAFailureWithTheVPNUpCountsAndKeepsTheDayOfTheFirst() throws {
        let once = try XCTUnwrap(refresh([dead, live], now: day1))
        XCTAssertEqual(failures(once, dead.domain), ResolveFailures(count: 1, since: day1))
        let twice = try XCTUnwrap(refresh(once, now: day2))
        XCTAssertEqual(failures(twice, dead.domain), ResolveFailures(count: 2, since: day1))
        XCTAssertNil(failures(twice, live.domain))
    }

    /// An internal name resolves only through the VPN: with it down, a failure says nothing.
    func testAFailureWithTheVPNDownDoesNotCount() {
        XCTAssertNil(refresh([dead, live], vpnUp: false))
        var counted = dead
        counted.resolveFailures = ResolveFailures(count: 2, since: day1)
        XCTAssertNil(refresh([counted, live], vpnUp: false), "nor does it clear or advance a count")
    }

    /// No name of several answered: the lookups failed, not the names.
    func testARefreshWhereNoNameResolvedCountsForNone() {
        let out = StaleEntries.record([dead, live], attempted: ["gone.example.com", "en.wikipedia.org"],
                                      resolved: [], vpnUp: true, now: day1)
        XCTAssertNil(out)
    }

    /// A refresh that asks one name cannot tell it from a dead network; with the VPN up it counts.
    func testARefreshOfOneNameCounts() {
        let out = StaleEntries.record([dead], attempted: ["gone.example.com"], resolved: [],
                                      vpnUp: true, now: day1)
        XCTAssertEqual(failures(out, dead.domain)?.count, 1)
    }

    func testOneAnswerClearsTheCount() throws {
        var counted = dead
        counted.resolveFailures = ResolveFailures(count: 3, since: day1)
        let out = try XCTUnwrap(StaleEntries.record([counted, live], attempted: [dead.domain, live.domain],
                                                    resolved: [dead.domain, live.domain], vpnUp: true, now: day2))
        XCTAssertNil(failures(out, dead.domain))
    }

    // MARK: When a row says so

    func testTheRowIsStaleAfterThreeFailedRefreshes() throws {
        var entries = [dead, live]
        for n in 1...StaleEntries.threshold {
            XCTAssertFalse(StaleEntries.isStale(entries[0]), "not yet after \(n - 1)")
            entries = try XCTUnwrap(refresh(entries))
        }
        XCTAssertEqual(StaleEntries.threshold, 3)
        XCTAssertTrue(StaleEntries.isStale(entries[0]))
        XCTAssertFalse(StaleEntries.isStale(entries[1]))
    }

    /// The count stops at the threshold, so a name that stays dead stops writing the config.
    func testTheCountStopsAtTheThresholdAndNothingChangesAfter() {
        var counted = dead
        counted.resolveFailures = ResolveFailures(count: StaleEntries.threshold, since: day1)
        XCTAssertNil(refresh([counted, live], now: day2))
    }

    func testARefreshThatChangesNothingReturnsNil() {
        XCTAssertNil(StaleEntries.record([live], attempted: [live.domain, "other.example"],
                                         resolved: [live.domain], vpnUp: true, now: day1))
    }

    // MARK: Which entries are touched

    /// An entry that is off, a wildcard and an IP range are never asked by a refresh; a name the
    /// refresh did not ask keeps what it had.
    func testOnlyTheNamesTheRefreshAskedAreTouched() {
        let off = DomainEntry(domain: "gone.example.com", enabled: false)
        let wild = DomainEntry(domain: "*.gone.example.com")
        let range = DomainEntry(domain: "10.20.0.0/16", isCIDR: true)
        let unasked = DomainEntry(domain: "unasked.example.com")
        let out = StaleEntries.record([off, wild, range, unasked, live],
                                      attempted: ["gone.example.com", "*.gone.example.com", "10.20.0.0/16", live.domain],
                                      resolved: [live.domain], vpnUp: true, now: day1)
        XCTAssertNil(out)
    }

    // MARK: Saved with the entry

    /// Only the count and the day are saved, and an entry that resolves saves nothing new, so a
    /// config from before this reads the same.
    func testTheFailuresRoundTripAndAreLeftOutWhenNil() throws {
        var counted = dead
        counted.resolveFailures = ResolveFailures(count: 2, since: day1)
        let back = try JSONDecoder().decode(DomainEntry.self, from: JSONEncoder().encode(counted))
        XCTAssertEqual(back.resolveFailures, ResolveFailures(count: 2, since: day1))

        let plain = try XCTUnwrap(String(data: JSONEncoder().encode(live), encoding: .utf8))
        XCTAssertFalse(plain.contains("resolveFailures"), plain)
        let old = #"{"id":"\#(UUID().uuidString)","domain":"a.example","enabled":true}"#
        XCTAssertNil(try JSONDecoder().decode(DomainEntry.self, from: Data(old.utf8)).resolveFailures)
    }

    // MARK: The row's line

    func testTheDetailNamesTheDayOfTheFirstFailure() {
        let en = Locale(identifier: "en_GB")
        XCTAssertEqual(StaleEntries.detail(since: day1, locale: en), "Hasn't resolved since 3 Oct")
    }
}

/// The refresh's hook: it reads the VPN and the mode after the lookups, and touches only the
/// list the refresh resolved.
@MainActor
final class StaleEntriesRefreshHookTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var savedConfig: RouteManager.Config!
    private var savedVPNConnected = false

    override func setUp() async throws {
        savedConfig = rm.config
        savedVPNConnected = rm.isVPNConnected
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "gone.example.com"), DomainEntry(domain: "en.wikipedia.org")]
        cfg.inverseDomains = [DomainEntry(domain: "gone.example.com")]
        rm.config = cfg
    }

    override func tearDown() async throws {
        rm.config = savedConfig
        rm.isVPNConnected = savedVPNConnected
    }

    private func refresh(isInverse: Bool) {
        rm.recordResolveFailures(isInverse: isInverse, attempted: ["gone.example.com", "en.wikipedia.org"],
                                 resolved: ["en.wikipedia.org"])
    }

    func testABypassRefreshWithTheVPNUpCountsOnTheBypassListOnly() {
        rm.isVPNConnected = true
        refresh(isInverse: false)
        XCTAssertEqual(rm.config.domains[0].resolveFailures?.count, 1)
        XCTAssertNil(rm.config.domains[1].resolveFailures)
        XCTAssertNil(rm.config.inverseDomains[0].resolveFailures)
    }

    /// The VPN dropped while the names were asked.
    func testTheVPNDownWhenTheLookupsEndCountsNothing() {
        rm.isVPNConnected = false
        refresh(isInverse: false)
        XCTAssertNil(rm.config.domains[0].resolveFailures)
    }

    /// The mode changed while the names were asked: the result belongs to the other list.
    func testAModeChangeDuringTheLookupsCountsNothing() {
        rm.isVPNConnected = true
        rm.config.routingMode = .vpnOnly
        refresh(isInverse: false)
        XCTAssertNil(rm.config.domains[0].resolveFailures)
        XCTAssertNil(rm.config.inverseDomains[0].resolveFailures)
        rm.config.routingMode = .custom
        refresh(isInverse: false)
        XCTAssertNil(rm.config.domains[0].resolveFailures)
    }

    /// The count is the app's own note, not a settings change: it is saved, and the footer that
    /// names the last `vpnb` change stays.
    func testTheCountIsSavedAndLeavesTheOutsideChangeFooter() throws {
        let savedChange = rm.lastOutsideChange
        defer { rm.lastOutsideChange = savedChange }
        let change = OutsideChange(kind: .addedDomain("x.example"), at: Date())
        rm.lastOutsideChange = change
        rm.isVPNConnected = true
        refresh(isInverse: false)
        XCTAssertEqual(rm.lastOutsideChange, change)
        let onDisk = try JSONDecoder().decode(RouteManager.Config.self, from: Data(contentsOf: rm.configURL))
        XCTAssertEqual(onDisk.domains.first { $0.domain == "gone.example.com" }?.resolveFailures?.count, 1)
    }

    func testAVPNOnlyRefreshCountsOnTheVPNOnlyList() {
        rm.isVPNConnected = true
        rm.config.routingMode = .vpnOnly
        refresh(isInverse: true)
        XCTAssertEqual(rm.config.inverseDomains[0].resolveFailures?.count, 1)
        XCTAssertNil(rm.config.domains[0].resolveFailures)
    }
}
