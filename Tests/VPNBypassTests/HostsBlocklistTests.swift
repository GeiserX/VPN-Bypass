// HostsBlocklistTests.swift
// The list rules' names in /etc/hosts, end to end against a fake helper that keeps /etc/hosts as a
// string and runs the helper's own text functions (HostsBlockSection, HostsPinSection) on it. Every
// write to the real file stalls every lookup on the Mac for seconds, so these tests count writes:
// what must not write, and what must remove the section. Nothing touches the real /etc/hosts.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

/// /etc/hosts as the helper would leave it, with every write counted.
@MainActor
final class FakeHostsHelper {
    var file = "127.0.0.1 localhost\n"
    /// Every `setBlockedHosts` call, in order.
    var blockedCalls: [[String]] = []
    /// Every write to the file, by either writer.
    var writes = 0

    func setBlocked(_ names: [String]) -> (success: Bool, error: String?) {
        blockedCalls.append(names)
        do {
            guard let updated = try HostsBlockSection.rewritten(file, names: names) else {
                return (true, HelperConstants.hostsUnchanged)
            }
            file = updated
            writes += 1
            return (true, nil)
        } catch {
            return (false, "\(error)")
        }
    }

    func pin(_ entries: [(domain: String, ip: String)]) -> (success: Bool, error: String?) {
        guard let updated = HostsPinSection.rewritten(file, entries: entries, isValid: { _, _ in true }) else {
            return (true, HelperConstants.hostsUnchanged)
        }
        file = updated
        writes += 1
        return (true, nil)
    }

    var blockedNames: Set<String> {
        var names = Set<String>()
        var inSection = false
        for line in file.components(separatedBy: "\n") {
            if line == HostsBlockSection.startMarker { inSection = true; continue }
            if line == HostsBlockSection.endMarker { inSection = false; continue }
            if inSection, let name = line.split(separator: " ").last { names.insert(String(name)) }
        }
        return names
    }

    var hasSection: Bool { file.contains(HostsBlockSection.startMarker) }
}

@MainActor
final class HostsBlocklistTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, connected: Bool, gateway: String?, helper: HelperState,
                        loading: Bool, store: ListStore)!
    private var kernel: BlockingKernel!
    private var helper: FakeHostsHelper!
    private var directory: URL!
    private var store: ListStore!
    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)
    private let source = "https://lists.example.org/hosts"
    private var listRule: Rule!

    override func setUp() async throws {
        await rm.cancelConfigFollowUps()
        await rm.waitForBackgroundRefreshForTests()
        await rm.waitForBlockedHostsSync()
        if rm.isPaused { rm.endPause(reason: "a blocklist test", apply: false) }
        var waited = 0
        while rm.isApplyingRoutes && waited < 100 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        if rm.isApplyingRoutes { throw XCTSkip("the route-operation gate is held by another test") }
        saved = (rm.config, rm.isVPNConnected, rm.localGateway, HelperManager.shared.helperState, rm.isLoading, rm.listStore)

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("blocklist-\(UUID().uuidString)")
        store = ListStore(directory: directory)
        try await storeCopy(["ads.example.com", "pin.example.com", "track.example.net"])
        rm.listStore = store

        listRule = Rule(matchType: .list, pattern: source, routeId: block.id, order: 1)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.manageHostsFile = true
        cfg.services = []
        cfg.domains = []
        cfg.routes = [direct, block]
        cfg.defaultRouteId = direct.id
        cfg.fallbackDNS = ["1.1.1.1"]
        cfg.rules = [Rule(matchType: .ip, pattern: "198.51.100.77", routeId: direct.id, order: 0), listRule]
        rm.config = cfg
        rm.resetShutdownStateForTests()
        rm.pendingKernelAdds = []
        rm.activeRoutes = []
        rm.blockedRoutes = []
        rm.ruleBlocks = []
        rm.isVPNConnected = false
        rm.isLoading = false
        rm.localGateway = "192.168.1.1"
        HelperManager.shared.helperState = .ready
        kernel = BlockingKernel(installed: [])
        kernel.attach(to: rm)

        helper = FakeHostsHelper()
        rm.setBlockedHostsOverrideForTests = { [unowned self] in self.helper.setBlocked($0) }
        rm.updateHostsFileOverrideForTests = { [unowned self] in self.helper.pin($0) }
        rm.hostsFileOverrideForTests = { [unowned self] in self.helper.file }
        rm.sentBlockedHosts = nil
        rm.confirmedBlockCounts = nil
        rm.pinnedHostAddresses = [:]
        rm.pinnedHostAddressesSeeded = false
        rm.blockedHostsError = nil
        rm.setDNSDiskCacheForTests([:])
    }

    override func tearDown() async throws {
        // setUp skipped before it saved anything: the shared state belongs to whatever holds the
        // route gate, so leave all of it alone.
        guard let saved else { return }
        await rm.cancelConfigFollowUps()
        await rm.waitForBackgroundRefreshForTests()
        await rm.waitForBlockedHostsSync()
        await rm.cancelResumeApplyForTests()
        rm.endPause(reason: "test over", apply: false)
        BlockingKernel.detach(from: rm)
        rm.setBlockedHostsOverrideForTests = nil
        rm.updateHostsFileOverrideForTests = nil
        rm.hostsFileOverrideForTests = nil
        rm.detectVPNInterfaceOverrideForTests = nil
        rm.setDNSCacheForTests([:])
        rm.setDNSDiskCacheForTests([:])
        rm.isConfigLoadFailed = false
        GeoDataStore.autoUpdate = false
        rm.sentBlockedHosts = nil
        rm.confirmedBlockCounts = nil
        rm.pinnedHostAddresses = [:]
        rm.blockedHostsError = nil
        rm.hostsBlockPlan = HostsBlockPlanner.Plan()
        rm.activeRoutes = []
        rm.ruleBlocks = []
        rm.blockedRoutes = []
        rm.pendingKernelAdds = []
        rm.listStore = saved.store
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.localGateway = saved.gateway
        rm.isLoading = saved.loading
        HelperManager.shared.helperState = saved.helper
        rm.resetShutdownStateForTests()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Helpers

    private func storeCopy(_ names: [String]) async throws {
        try await storeCopy(names, at: source)
    }

    private func storeCopy(_ names: [String], at address: String) async throws {
        let body = Data((names.map { "0.0.0.0 \($0)" }.joined(separator: "\n") + "\n").utf8)
        store.fetch = { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try body.write(to: file)
            return file
        }
        let saved = await store.update(from: URL(string: address)!)
        XCTAssertTrue(saved, "the fixture list was not stored")
    }

    private func sync() async {
        rm.requestBlockedHostsSync()
        await rm.waitForBlockedHostsSync()
    }

    /// The section is in, as after a first launch with the list.
    private func blockOnce() async {
        await sync()
        XCTAssertEqual(helper.blockedNames, ["ads.example.com", "pin.example.com", "track.example.net"])
        XCTAssertEqual(helper.blockedCalls.count, 1)
    }

    // MARK: - Sending the set

    func testTheSameSetMakesNoSecondCall() async {
        await blockOnce()
        await sync()
        await sync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "an unchanged set reached the helper again")
        XCTAssertEqual(helper.writes, 1)
    }

    /// Both apply paths send the set: a full apply, then a re-apply that changes no route (the skip
    /// path) after the list itself changed.
    func testBothApplyPathsSendTheSet() async throws {
        await rm.applyAllRoutes()
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "the full apply did not send the list's names")
        XCTAssertTrue(kernel.base.installed.contains("198.51.100.77"))

        try await storeCopy(["ads.example.com", "pin.example.com", "new.example.com"])
        await rm.applyAllRoutes()
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 2, "the re-apply that changed no route did not send the new names")
        XCTAssertEqual(helper.blockedNames, ["ads.example.com", "pin.example.com", "new.example.com"])
    }

    /// A refresh that brings the same names writes nothing.
    func testARefreshWithTheSameNamesWritesNothing() async throws {
        await blockOnce()
        try await storeCopy(["ads.example.com", "pin.example.com", "track.example.net"])
        await rm.updateBlocklist(from: URL(string: source)!)
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 1)
        XCTAssertEqual(helper.writes, 1)
    }

    /// A relaunch with the same list: the app does not know what the file holds, so it sends the set
    /// once, and the helper finds the section already saying it and writes nothing.
    func testARelaunchWithTheSameListWritesNothing() async {
        await blockOnce()
        let file = helper.file
        rm.sentBlockedHosts = nil          // a new process knows nothing
        rm.hostsBlockPlan = HostsBlockPlanner.Plan()
        await sync()
        XCTAssertEqual(helper.blockedCalls.count, 2, "the first sync of a run asks the helper")
        XCTAssertEqual(helper.writes, 1, "the relaunch wrote /etc/hosts")
        XCTAssertEqual(helper.file, file)
        XCTAssertEqual(rm.sentBlockedHosts, ["ads.example.com", "pin.example.com", "track.example.net"])
    }

    /// A Mac that never had a list sends nothing at all at launch.
    func testALaunchWithNoListAndNoSectionMakesNoCall() async {
        rm.config.rules = [rm.config.rules[0]]
        await sync()
        XCTAssertEqual(helper.blockedCalls, [])
        XCTAssertEqual(rm.sentBlockedHosts, [])
    }

    /// A section a stopped run left behind, with the list rule gone: the launch removes it.
    func testALaunchWithNoListRemovesASectionLeftBehind() async {
        await blockOnce()
        rm.config.rules = [rm.config.rules[0]]
        rm.sentBlockedHosts = nil
        await sync()
        XCTAssertFalse(helper.hasSection)
    }

    /// The launch itself sends the set once, VPN or not, and the helper writes nothing when the
    /// file already holds it: the startup routine, not a sync called by hand.
    func testTheLaunchRoutineSendsTheSetOnceAndWritesNothing() async {
        await blockOnce()
        rm.sentBlockedHosts = nil          // a new process knows nothing
        // A secret already saved, as on any Mac after the first launch: minting one saves the
        // config, and that save syncs too, which would hide a launch that never asks.
        rm.config.localProxySecret = "launch-test-secret"
        rm.detectVPNInterfaceOverrideForTests = { (false, nil, nil) }
        await rm.detectAndApplyRoutesAsync()
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 2, "the launch did not ask the helper")
        XCTAssertEqual(helper.writes, 1, "the launch wrote /etc/hosts")
        XCTAssertEqual(rm.sentBlockedHosts, ["ads.example.com", "pin.example.com", "track.example.net"])
    }

    /// A config that failed to load shows no rule, so a section left behind would be a block
    /// nobody can explain from the app: the latch removes it, as it removes routes.
    func testAConfigThatFailedToLoadRemovesTheSection() async {
        await blockOnce()
        rm.sentBlockedHosts = nil
        rm.isConfigLoadFailed = true
        HelperManager.shared.helperState = .missing      // no startup sweep of the real route table
        await rm.detectAndApplyRoutesAsync()
        XCTAssertFalse(helper.hasSection, "the section stayed with no rule to explain it")
    }

    /// The same names in another order (two overlapping lists swapped, or a refresh that moved
    /// names around) block the same names: no call, no write.
    func testTheSameSetInAnotherOrderWritesNothing() async throws {
        await blockOnce()
        try await storeCopy(["track.example.net", "ads.example.com", "pin.example.com"])
        await rm.updateBlocklist(from: URL(string: source)!)
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "a reordered set reached the helper")
        XCTAssertEqual(helper.writes, 1)
    }

    // MARK: - What keeps the section

    /// The quit removes the pins, one of them a blocked name, and still sends nothing: the row the
    /// pin writer dropped comes back at the next launch, which sends the set once.
    func testQuitMakesNoBlocklistWrite() async {
        await blockOnce()
        await rm.modifyHostsFile(entries: [("pin.example.com", "192.0.2.10")])
        await rm.cleanupOnQuit()
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "the quit sent the blocklist")
        XCTAssertTrue(helper.hasSection, "the section must stay while the app is closed")
        rm.resetShutdownStateForTests()
    }

    /// A list rule on Block does not go Direct, so Pause is refused while one blocks, as for any
    /// such rule (PauseGate), and the refusal writes nothing. The removal a pause runs
    /// (`removeAllRoutes()`) leaves the section: see the Remove All test below.
    func testPauseMakesNoBlocklistWrite() async {
        await blockOnce()
        rm.isVPNConnected = true
        rm.activeRoutes = [.init(destination: "198.51.100.77", gateway: "192.168.1.1", source: "198.51.100.77", timestamp: Date())]
        kernel.base.installed = ["198.51.100.77"]
        let result = await rm.pause(for: .untilResume)
        if case .success = result { XCTFail("a pause ran with a list rule blocking") }
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "the pause sent the blocklist")
        XCTAssertTrue(helper.hasSection)
    }

    func testAVPNDropMakesNoBlocklistWrite() async {
        await blockOnce()
        await rm.tearDownAfterDrop()
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "the drop sent the blocklist")
        XCTAssertTrue(helper.hasSection)
    }

    // MARK: - What removes it

    func testRemovingTheLastListRuleRemovesTheSection() async {
        await blockOnce()
        rm.config.rules.removeAll { $0.matchType == .list }
        rm.saveConfig()
        await rm.waitForBlockedHostsSync()
        XCTAssertFalse(helper.hasSection)
    }

    func testTurningTheListRuleOffRemovesTheSection() async {
        await blockOnce()
        rm.config.rules[1].enabled = false
        rm.saveConfig()
        await rm.waitForBlockedHostsSync()
        XCTAssertFalse(helper.hasSection)
    }

    func testTurningPinningOffRemovesTheSection() async {
        await blockOnce()
        rm.config.manageHostsFile = false
        rm.saveConfig()
        await rm.waitForBlockedHostsSync()
        XCTAssertFalse(helper.hasSection, "pinning off must leave no blocklist in /etc/hosts")
        XCTAssertEqual(rm.listRuleState(listRule).kind, .pinningOff)
    }

    func testLeavingCustomModeRemovesTheSection() async {
        await blockOnce()
        rm.setRoutingMode(.bypass)
        await rm.waitForBlockedHostsSync()
        XCTAssertFalse(helper.hasSection)
        XCTAssertEqual(rm.listRuleState(listRule).kind, .notCustomMode)
    }

    func testRemoveAllRoutesRemovesTheSectionAndAPlainRemovalDoesNot() async {
        await blockOnce()
        await rm.removeAllRoutes()
        XCTAssertTrue(helper.hasSection, "only Remove All Routes takes the section out")
        await rm.removeAllRoutes(releasingBlocklist: true)
        XCTAssertFalse(helper.hasSection)
    }

    /// vpnb routes.clear is Remove All Routes: it takes the section out.
    func testRoutesClearRemovesTheSection() async {
        await blockOnce()
        let response = await ControlSurface.handle(ControlRequest(cmd: "routes.clear"))
        XCTAssertTrue(response.ok)
        XCTAssertFalse(helper.hasSection, "routes.clear left the blocklist in /etc/hosts")
    }

    /// An import that brings a list rule syncs the section.
    func testAnImportWithAListRuleSendsTheSet() async throws {
        let url = try XCTUnwrap(rm.exportConfig())
        defer { try? FileManager.default.removeItem(at: url) }
        rm.config.rules.removeAll { $0.matchType == .list }
        rm.sentBlockedHosts = []
        XCTAssertTrue(rm.importConfig(from: url))
        await rm.waitForBlockedHostsSync()
        await rm.cancelConfigFollowUps()
        XCTAssertEqual(helper.blockedCalls.count, 1, "the import did not send the list's names")
        XCTAssertTrue(helper.hasSection)
    }

    /// Lists are downloaded on the GeoIP and GeoSite schedule.
    func testTheGeoScheduleRefreshesADueList() async {
        var fetches = 0
        let body = Data("0.0.0.0 ads.example.com\n0.0.0.0 pin.example.com\n0.0.0.0 track.example.net\n".utf8)
        store.fetch = { _ in
            fetches += 1
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try body.write(to: file)
            return file
        }
        GeoDataStore.autoUpdate = true
        rm.refreshGeoDataIfNeeded(now: Date().addingTimeInterval(400 * 86_400))
        GeoDataStore.autoUpdate = false
        var waited = 0
        while (fetches == 0 || !store.updating.isEmpty) && waited < 200 {
            try? await Task.sleep(nanoseconds: 10_000_000); waited += 1
        }
        XCTAssertEqual(fetches, 1, "the geo sync schedule did not refresh the due list")
        await rm.waitForBlockedHostsSync()
    }

    /// vpnb rule.list fills a list rule's count, state and error.
    func testRuleListFillsTheListFields() async throws {
        await blockOnce()
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        let rule = try XCTUnwrap(response.result?.rules?.first { $0.matchType == .list })
        XCTAssertEqual(rule.listState, "blocked")
        XCTAssertEqual(rule.listNames, 3)
        XCTAssertNil(rule.listError)
    }

    /// A launch with the helper not ready runs no apply: nothing was sent, so neither vpnb nor the
    /// row may say "blocked".
    func testWithTheHelperNotReadyAndNothingSentNothingSaysBlocked() async throws {
        rm.setBlockedHostsOverrideForTests = nil          // the real send path
        HelperManager.shared.helperState = .missing
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        let rule = try XCTUnwrap(response.result?.rules?.first { $0.matchType == .list })
        XCTAssertEqual(rule.listState, "notBlocked")
        XCTAssertEqual(rule.listError, "The helper is not running.")
        XCTAssertEqual(rm.listRuleState(listRule).line(), "Not blocked: The helper is not running.")
        await sync()
        XCTAssertEqual(rm.listRuleState(listRule).line(), "Not blocked: The helper is not running.")
        XCTAssertFalse(helper.hasSection)
    }

    /// One list confirmed, then a second list whose send fails: the second says Not blocked, the
    /// first keeps its confirmed count with the failure.
    func testAListTheHelperNeverConfirmedIsNotBlockedBesideOneItDid() async throws {
        await blockOnce()
        let second = "https://other.example.org/hosts"
        let body = Data("0.0.0.0 more.example.com\n0.0.0.0 extra.example.com\n".utf8)
        store.fetch = { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try body.write(to: file)
            return file
        }
        let stored = await store.update(from: URL(string: second)!)
        XCTAssertTrue(stored)
        let secondRule = Rule(matchType: .list, pattern: second, routeId: block.id, order: 2)
        rm.config.rules.append(secondRule)
        rm.setBlockedHostsOverrideForTests = { _ in (false, "helper stopping") }
        await sync()
        XCTAssertEqual(rm.listRuleState(secondRule).kind, .notBlocked)
        XCTAssertEqual(rm.listRuleState(secondRule).line(), "Not blocked: helper stopping")
        let first = rm.listRuleState(listRule)
        XCTAssertEqual(first.kind, .blocked)
        XCTAssertEqual(first.names, 3)
        XCTAssertTrue(first.line().hasSuffix("\nLast try failed: helper stopping"), first.line())
        XCTAssertEqual(rm.listRuleState(listRule, plan: rm.blocklistPlan(for: rm.config)).names, 3)
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        let listed = try XCTUnwrap(response.result?.rules?.first { $0.id == secondRule.id })
        XCTAssertEqual(listed.listState, "notBlocked")
    }

    /// An edit to another URL keeps the rule's id. The old list's count must not carry over: while
    /// the send is out the row says "Not blocked yet.", and after it fails, "Not blocked".
    func testAListEditedToAnotherURLDoesNotKeepTheOldCount() async throws {
        await blockOnce()
        let other = "https://other.example.org/hosts"
        try await storeCopy(["more.example.com", "extra.example.com"], at: other)
        var edited = try XCTUnwrap(rm.config.rules.first { $0.id == listRule.id })
        edited.pattern = other
        var release = false
        rm.setBlockedHostsOverrideForTests = { _ in
            while !release { try? await Task.sleep(nanoseconds: 5_000_000) }
            return (false, "helper stopping")
        }
        rm.config.rules[1] = edited
        rm.requestBlockedHostsSync()
        var waited = 0
        while rm.hostsBlockPlan.accepted[edited.id] != 2 && waited < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000); waited += 1
        }
        XCTAssertEqual(rm.listRuleState(edited).kind, .pending, "the old list's count showed while the send was out")
        XCTAssertEqual(rm.listRuleState(edited).line(), "Not blocked yet.")
        release = true
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(rm.listRuleState(edited).kind, .notBlocked)
        XCTAssertEqual(rm.listRuleState(edited).line(), "Not blocked: helper stopping")
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        let listed = try XCTUnwrap(response.result?.rules?.first { $0.id == edited.id })
        XCTAssertEqual(listed.listState, "notBlocked")
        XCTAssertEqual(listed.listError, "helper stopping")
        XCTAssertEqual(helper.blockedNames, ["ads.example.com", "pin.example.com", "track.example.net"],
                       "the old list's names are what the file holds")
    }

    /// A second list whose names all sit in the list above it adds none, and the set does not
    /// change: no call, and the row says so instead of waiting for a send that never comes.
    func testAListCoveredByTheListAboveItSaysItAddsNoNames() async throws {
        await blockOnce()
        let other = "https://other.example.org/hosts"
        try await storeCopy(["ads.example.com", "track.example.net"], at: other)
        let covered = Rule(matchType: .list, pattern: other, routeId: block.id, order: 2)
        rm.config.rules.append(covered)
        await sync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "the same set reached the helper again")
        XCTAssertEqual(rm.listRuleState(covered).kind, .blocked)
        XCTAssertEqual(rm.listRuleState(covered).line(), "Adds no names: the rules above it already cover every one.")
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        let listed = try XCTUnwrap(response.result?.rules?.first { $0.id == covered.id })
        XCTAssertEqual(listed.listState, "blocked")
        XCTAssertEqual(listed.listNames, 0)
        XCTAssertTrue(VPNBCLI.textLines(response).contains { $0.hasSuffix("list blocked (adds no names of its own)") },
                      "\(VPNBCLI.textLines(response))")
    }

    /// A list whose only names are hosts no list blocks (the app's download hosts) adds none, and
    /// no rule above it is the reason: neither the row nor vpnb may blame the rules above it.
    func testAListOfProtectedHostsDoesNotBlameTheRulesAboveIt() async throws {
        try await storeCopy(["github.com", "raw.githubusercontent.com"])
        await sync()
        XCTAssertFalse(helper.hasSection)
        XCTAssertEqual(rm.listRuleState(listRule).kind, .blocked)
        XCTAssertEqual(rm.listRuleState(listRule).line(), "Adds no names of its own.")
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        let lines = VPNBCLI.textLines(response)
        XCTAssertTrue(lines.contains { $0.hasSuffix("list blocked (adds no names of its own)") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("rules above") }, "\(lines)")
    }

    /// The plan names a list as covered only when the rules and lists above it hold every one of
    /// its names: not for protected hosts, and not for a mix of the two.
    func testOnlyAListTheRulesAboveHoldWhollyIsCoveredAbove() {
        let second = Rule(matchType: .list, pattern: "https://other.example.org/hosts", routeId: block.id, order: 2)
        rm.config.rules.append(second)
        func plan(_ names: [String]) -> HostsBlockPlanner.Plan {
            HostsBlockPlanner.plan(rm.config, lists: [source: ["ads.example.com", "track.example.net"], second.pattern: names],
                                   geosite: [:])
        }
        XCTAssertEqual(plan(["ads.example.com", "track.example.net", "ads.example.com"]).coveredAbove, [second.id])
        XCTAssertEqual(plan(["github.com"]).coveredAbove, [])
        XCTAssertEqual(plan(["ads.example.com", "github.com"]).coveredAbove, [])
        XCTAssertEqual(plan(["ads.example.com", "new.example.com"]).coveredAbove, [])
        XCTAssertEqual(plan(["ads.example.com"]).accepted[second.id], 0)
    }

    /// A change whose send failed, then undone (the failing list removed): the set is the one the
    /// helper holds, so nothing is sent, and the failure no longer shows on the other rows.
    func testUndoingAChangeWhoseSendFailedClearsTheFailure() async throws {
        await blockOnce()
        let other = "https://other.example.org/hosts"
        try await storeCopy(["more.example.com"], at: other)
        let second = Rule(matchType: .list, pattern: other, routeId: block.id, order: 2)
        rm.config.rules.append(second)
        rm.setBlockedHostsOverrideForTests = { _ in (false, "helper stopping") }
        await sync()
        XCTAssertTrue(rm.listRuleState(listRule).line().hasSuffix("\nLast try failed: helper stopping"), rm.listRuleState(listRule).line())

        rm.setBlockedHostsOverrideForTests = { [unowned self] in self.helper.setBlocked($0) }
        rm.config.rules.removeAll { $0.id == second.id }
        await sync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "undoing the change reached the helper")
        XCTAssertEqual(rm.listRuleState(listRule).kind, .blocked)
        XCTAssertFalse(rm.listRuleState(listRule).line().contains("Last try failed"), rm.listRuleState(listRule).line())
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        XCTAssertNil(try XCTUnwrap(response.result?.rules?.first { $0.id == listRule.id }).listError)
    }

    /// Two overlapping lists swapped block the same names: no call, and each count follows the
    /// new order.
    func testSwappingTwoListsMovesTheirCounts() async throws {
        await blockOnce()
        let other = "https://other.example.org/hosts"
        try await storeCopy(["ads.example.com", "more.example.com"], at: other)
        let second = Rule(matchType: .list, pattern: other, routeId: block.id, order: 2)
        rm.config.rules.append(second)
        await sync()
        XCTAssertEqual(rm.listRuleState(listRule).names, 3)
        XCTAssertEqual(rm.listRuleState(second).names, 1)
        rm.config.rules[1].order = 3
        await sync()
        XCTAssertEqual(helper.blockedCalls.count, 2, "a swap of the same names reached the helper")
        XCTAssertEqual(rm.listRuleState(second).names, 2)
        XCTAssertEqual(rm.listRuleState(listRule).names, 2)
        XCTAssertEqual(rm.listRuleState(listRule).kind, .blocked)
    }

    /// Remove All Routes says it unblocks listed names only when some are blocked or would be.
    func testTheRemoveAllQuestionMentionsListsOnlyWhenNamesAreBlocked() async {
        rm.config.manageHostsFile = false
        await sync()
        XCTAssertFalse(helper.hasSection)
        XCTAssertFalse(rm.removeAllLiftsListBlocks, "pinning is off and nothing is blocked")
        rm.config.manageHostsFile = true
        rm.sentBlockedHosts = nil
        rm.hostsBlockPlan = rm.blocklistPlan(for: rm.config)
        XCTAssertTrue(rm.removeAllLiftsListBlocks, "the rules are about to block names")
        await sync()
        XCTAssertTrue(rm.removeAllLiftsListBlocks)
        await rm.removeAllRoutes(releasingBlocklist: true)
        XCTAssertFalse(helper.hasSection)
        XCTAssertFalse(rm.removeAllLiftsListBlocks, "the section is gone")
    }

    /// With pinning off nothing is in the file, so turning it on and failing the first send must
    /// not show a count from the plan.
    func testPinningTurnedOnWithAFailedSendIsNotBlocked() async throws {
        rm.config.manageHostsFile = false
        await sync()
        XCTAssertEqual(rm.sentBlockedHosts, [])
        XCTAssertEqual(rm.confirmedBlockCounts, [:], "pinning off left counts for names never sent")
        rm.config.manageHostsFile = true
        rm.setBlockedHostsOverrideForTests = { _ in (false, "helper stopping") }
        await sync()
        XCTAssertEqual(rm.listRuleState(listRule).kind, .notBlocked)
        XCTAssertEqual(rm.listRuleState(listRule).line(), "Not blocked: helper stopping")
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        XCTAssertEqual(response.result?.rules?.first { $0.id == listRule.id }?.listState, "notBlocked")
    }

    /// A pin an earlier run left in the file for a name the list blocks goes before the first
    /// send of a launch, so that send writes the name's row and no second send is needed.
    func testTheFirstSyncOfALaunchDropsALeftoverPinFirst() async {
        helper.file = "127.0.0.1 localhost\n\n\(HelperConstants.hostMarkerStart)\n192.0.2.10 pin.example.com\n\(HelperConstants.hostMarkerEnd)\n"
        await sync()
        XCTAssertNil(HostsPinSection.pinnedAddresses(in: helper.file)["pin.example.com"], "the leftover pin stayed")
        XCTAssertEqual(helper.blockedNames, ["ads.example.com", "pin.example.com", "track.example.net"])
        XCTAssertEqual(helper.blockedCalls.count, 1)
    }

    /// The first sync of a launch runs before any route is applied. It drops only the listed
    /// name's pin, in the order the file has the others, so the route apply finds every routed
    /// pin in place and writes nothing: two writes in all, and no routed name loses its pin.
    func testTheFirstSyncOfALaunchKeepsTheOtherPins() async {
        helper.file = "127.0.0.1 localhost\n\n\(HelperConstants.hostMarkerStart)\n203.0.113.9 zz.example.com\n"
            + "192.0.2.10 pin.example.com\n203.0.113.5 cdn.example.com\n\(HelperConstants.hostMarkerEnd)\n"
        await sync()
        XCTAssertEqual(HostsPinSection.pinnedAddresses(in: helper.file), ["zz.example.com": "203.0.113.9", "cdn.example.com": "203.0.113.5"],
                       "the sync dropped the pins of routed names")
        XCTAssertEqual(helper.blockedNames, ["ads.example.com", "pin.example.com", "track.example.net"])
        XCTAssertEqual(helper.writes, 2)

        // The route apply that follows.
        let now = Date()
        rm.activeRoutes = [
            .init(destination: "203.0.113.9", gateway: "192.168.1.1", source: "zz.example.com", timestamp: now),
            .init(destination: "203.0.113.5", gateway: "192.168.1.1", source: "cdn.example.com", timestamp: now),
        ]
        rm.setDNSCacheForTests(["zz.example.com": "203.0.113.9", "cdn.example.com": "203.0.113.5"])
        rm.setDNSDiskCacheForTests(["zz.example.com": ["203.0.113.9"], "cdn.example.com": ["203.0.113.5"]])
        await rm.updateHostsFileForTests()
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.writes, 2, "the route apply wrote /etc/hosts again")
        XCTAssertEqual(helper.blockedCalls.count, 1)
    }

    /// The pin of a listed name cannot be removed: nothing is sent and nothing says blocked, the
    /// row and vpnb say why, and the next sync tries again.
    func testAPinThatCannotGoStopsTheSend() async throws {
        helper.file = "127.0.0.1 localhost\n\n\(HelperConstants.hostMarkerStart)\n192.0.2.10 pin.example.com\n\(HelperConstants.hostMarkerEnd)\n"
        rm.updateHostsFileOverrideForTests = { _ in (false, "helper stopping") }
        await sync()
        XCTAssertEqual(helper.blockedCalls, [], "the set went out with the pin still hiding a name")
        XCTAssertEqual(rm.listRuleState(listRule).kind, .notBlocked)
        XCTAssertEqual(rm.listRuleState(listRule).line(), "Not blocked: A pinned name that a list blocks could not be unpinned.")
        let response = await ControlSurface.handle(ControlRequest(cmd: "rule.list"))
        let listed = try XCTUnwrap(response.result?.rules?.first { $0.id == listRule.id })
        XCTAssertEqual(listed.listState, "notBlocked")
        XCTAssertEqual(listed.listError, "A pinned name that a list blocks could not be unpinned.")
        rm.updateHostsFileOverrideForTests = { [unowned self] in self.helper.pin($0) }
        await sync()
        XCTAssertEqual(helper.blockedNames, ["ads.example.com", "pin.example.com", "track.example.net"])
        XCTAssertEqual(rm.listRuleState(listRule).kind, .blocked)
    }

    // MARK: - What sends it again

    /// A stopping helper removes the section; the restart puts it back.
    func testAHelperRestartSendsTheSetAgain() async throws {
        await blockOnce()
        helper.file = try XCTUnwrap(HostsBlockSection.rewritten(helper.file, names: []))   // SIGTERM
        await HelperManager.shared.restoreAfterHelperRestart(reapplyRoutes: false)
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 2)
        XCTAssertEqual(helper.blockedNames, ["ads.example.com", "pin.example.com", "track.example.net"])
    }

    /// The pin writer drops the blocklist row of a name it pins. When the pin goes, the row comes back.
    func testUnpinningABlockedNameSendsTheSetAgain() async {
        await blockOnce()
        await rm.modifyHostsFile(entries: [("pin.example.com", "192.0.2.10")])
        XCTAssertFalse(helper.blockedNames.contains("pin.example.com"), "the pin wins over the block")
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 1, "a new pin needs no resend")

        await rm.modifyHostsFile(entries: [])
        await rm.waitForBlockedHostsSync()
        XCTAssertEqual(helper.blockedCalls.count, 2)
        XCTAssertTrue(helper.blockedNames.contains("pin.example.com"), "the name is blocked again")
    }

    /// A pin whose address is still routed keeps it when a lookup puts another routed address of
    /// the name first (round robin, or another resolver answering first): no write.
    func testARotatedAnswerKeepsThePinnedAddress() async {
        await blockOnce()
        let now = Date()
        rm.activeRoutes = [
            .init(destination: "203.0.113.5", gateway: "192.168.1.1", source: "cdn.example.com", timestamp: now),
            .init(destination: "203.0.113.6", gateway: "192.168.1.1", source: "cdn.example.com", timestamp: now),
        ]
        rm.setDNSCacheForTests(["cdn.example.com": "203.0.113.5"])
        await rm.updateHostsFileForTests()
        XCTAssertEqual(helper.writes, 2)
        XCTAssertTrue(helper.file.contains("203.0.113.5 cdn.example.com"))

        rm.setDNSCacheForTests(["cdn.example.com": "203.0.113.6"])
        rm.setDNSDiskCacheForTests(["cdn.example.com": ["203.0.113.6", "203.0.113.5"]])
        await rm.updateHostsFileForTests()
        XCTAssertEqual(helper.writes, 2, "a rotated answer rewrote /etc/hosts")
        XCTAssertTrue(helper.file.contains("203.0.113.5 cdn.example.com"))

        // The pinned address lost its route: the pin follows the one still routed.
        rm.activeRoutes.removeFirst()
        await rm.updateHostsFileForTests()
        XCTAssertEqual(helper.writes, 3)
        XCTAssertTrue(helper.file.contains("203.0.113.6 cdn.example.com"))
    }

    /// A relaunch: the pins in /etc/hosts are read before the first pin write, so a rotated answer
    /// for a name whose pinned address is still routed writes nothing.
    func testTheFirstPinWriteAfterALaunchKeepsTheAddressInTheFile() async {
        helper.file = "127.0.0.1 localhost\n\n\(HelperConstants.hostMarkerStart)\n203.0.113.5 cdn.example.com\n\(HelperConstants.hostMarkerEnd)\n"
        await blockOnce()
        let writes = helper.writes
        let now = Date()
        rm.activeRoutes = [
            .init(destination: "203.0.113.5", gateway: "192.168.1.1", source: "cdn.example.com", timestamp: now),
            .init(destination: "203.0.113.6", gateway: "192.168.1.1", source: "cdn.example.com", timestamp: now),
        ]
        rm.setDNSCacheForTests(["cdn.example.com": "203.0.113.6"])
        rm.setDNSDiskCacheForTests(["cdn.example.com": ["203.0.113.6", "203.0.113.5"]])
        await rm.updateHostsFileForTests()
        XCTAssertEqual(helper.writes, writes, "the first pin write after a launch rewrote /etc/hosts")
        XCTAssertTrue(helper.file.contains("203.0.113.5 cdn.example.com"))
        XCTAssertEqual(HostsPinSection.pinnedAddresses(in: helper.file), ["cdn.example.com": "203.0.113.5"])
    }

    /// A pinned address the name no longer answers is dropped, even while another name keeps it
    /// routed; the same goes for a pin read from the file at launch.
    func testAPinTheNameNoLongerAnswersIsDroppedThoughAnotherNameRoutesIt() async {
        helper.file = "127.0.0.1 localhost\n\n\(HelperConstants.hostMarkerStart)\n203.0.113.5 cdn.example.com\n\(HelperConstants.hostMarkerEnd)\n"
        let now = Date()
        rm.activeRoutes = [
            .init(destination: "203.0.113.5", gateway: "192.168.1.1", source: "other.example.com", timestamp: now),
            .init(destination: "203.0.113.9", gateway: "192.168.1.1", source: "cdn.example.com", timestamp: now),
        ]
        rm.setDNSCacheForTests(["cdn.example.com": "203.0.113.9", "other.example.com": "203.0.113.5"])
        rm.setDNSDiskCacheForTests(["cdn.example.com": ["203.0.113.9"], "other.example.com": ["203.0.113.5"]])
        await rm.updateHostsFileForTests()
        XCTAssertEqual(HostsPinSection.pinnedAddresses(in: helper.file)["cdn.example.com"], "203.0.113.9",
                       "the name stayed pinned to an address it no longer answers")
    }

    /// First match holds for pins: a rule below the list does not pin a name the list blocks (the
    /// pin would drop its row), and a list that comes to block a pinned name drops the pin first.
    func testARuleBelowTheListDoesNotPinANameItBlocks() async {
        await blockOnce()
        let now = Date()
        rm.config.rules.append(Rule(matchType: .domain, pattern: "pin.example.com", routeId: direct.id, order: 5))
        rm.activeRoutes = [.init(destination: "192.0.2.10", gateway: "192.168.1.1", source: "pin.example.com", timestamp: now)]
        rm.setDNSCacheForTests(["pin.example.com": "192.0.2.10"])
        rm.setDNSDiskCacheForTests(["pin.example.com": ["192.0.2.10"]])
        await sync()
        await rm.updateHostsFileForTests()
        await rm.waitForBlockedHostsSync()
        XCTAssertTrue(helper.blockedNames.contains("pin.example.com"), "a rule below the list unblocked its name")
        XCTAssertNil(HostsPinSection.pinnedAddresses(in: helper.file)["pin.example.com"])

        // A rule above the list pins the name and unblocks it.
        rm.config.rules[rm.config.rules.count - 1].order = -1
        await sync()
        await rm.updateHostsFileForTests()
        await rm.waitForBlockedHostsSync()
        XCTAssertFalse(helper.blockedNames.contains("pin.example.com"))
        XCTAssertEqual(HostsPinSection.pinnedAddresses(in: helper.file)["pin.example.com"], "192.0.2.10")

        // Back below the list: the sync drops the pin before it sends, so the row comes back.
        rm.config.rules[rm.config.rules.count - 1].order = 5
        await sync()
        XCTAssertNil(HostsPinSection.pinnedAddresses(in: helper.file)["pin.example.com"])
        XCTAssertTrue(helper.blockedNames.contains("pin.example.com"), "the name the list blocks again stayed pinned")
    }

    /// A pin that goes while nothing is confirmed (a send in flight, a helper restart) resends, so
    /// a confirmation of a set the pin had cut short cannot hide the missing row.
    func testAPinThatGoesWithNothingConfirmedSendsTheSetAgain() async {
        await blockOnce()
        await rm.modifyHostsFile(entries: [("pin.example.com", "192.0.2.10")])
        XCTAssertFalse(helper.blockedNames.contains("pin.example.com"))
        rm.sentBlockedHosts = nil
        await rm.modifyHostsFile(entries: [])
        await rm.waitForBlockedHostsSync()
        XCTAssertTrue(helper.blockedNames.contains("pin.example.com"), "the unpinned name was left unblocked")
    }

    /// Pins first, then the section (the first list, a boot, Remove All and back): the next write
    /// of the same pins writes nothing.
    func testTheSamePinsAfterTheSectionCameWriteNothing() async {
        await rm.modifyHostsFile(entries: [("p.example.com", "192.0.2.1")])
        XCTAssertEqual(helper.writes, 1)
        await blockOnce()
        XCTAssertEqual(helper.writes, 2)
        await rm.modifyHostsFile(entries: [("p.example.com", "192.0.2.1")])
        XCTAssertEqual(helper.writes, 2, "the same pins moved their section and rewrote /etc/hosts")
    }

    /// Removing and adding the section again while pins are in the file leaves no extra blank line.
    func testRemovingAndAddingTheSectionAgainKeepsTheFileTheSameSize() throws {
        let pins = [(domain: "p.example.com", ip: "192.0.2.1")]
        var file = try XCTUnwrap(HostsPinSection.rewritten("127.0.0.1 localhost\n", entries: pins, isValid: { _, _ in true }))
        file = try XCTUnwrap(HostsBlockSection.rewritten(file, names: ["ads.example.com"]))
        XCTAssertNil(HostsPinSection.rewritten(file, entries: pins, isValid: { _, _ in true }),
                     "the same pins after the section was added rewrote the file")
        let size = file.components(separatedBy: "\n").count
        for _ in 0..<3 {
            file = try XCTUnwrap(HostsBlockSection.rewritten(file, names: []))
            file = HostsPinSection.rewritten(file, entries: pins, isValid: { _, _ in true }) ?? file
            file = try XCTUnwrap(HostsBlockSection.rewritten(file, names: ["ads.example.com"]))
            file = HostsPinSection.rewritten(file, entries: pins, isValid: { _, _ in true }) ?? file
        }
        XCTAssertEqual(file.components(separatedBy: "\n").count, size, file)
        XCTAssertFalse(file.contains("\n\n\n"), file)
    }

    /// The blank lines an older pin writer piled up in front of the section go with it; one
    /// blank line stays before the lines that came after it.
    func testRemovingTheSectionTakesEveryBlankLineBeforeIt() throws {
        let piled = "127.0.0.1 localhost\n\n\n\n\(HostsBlockSection.startMarker)\n0.0.0.0 ads.example.com\n"
            + "\(HostsBlockSection.endMarker)\n192.0.2.9 after.example.com\n"
        XCTAssertEqual(try HostsBlockSection.rewritten(piled, names: []), "127.0.0.1 localhost\n\n192.0.2.9 after.example.com\n")
    }

    /// The pin writer's "unchanged" reply skips the cache flush; any other success flushes, the
    /// mode-only fix among them (the resolver was ignoring the file).
    func testOnlyAnUnchangedReplySkipsTheFlush() {
        XCTAssertFalse(HelperManager.hostsUpdateNeedsFlush(error: HelperConstants.hostsUnchanged))
        XCTAssertTrue(HelperManager.hostsUpdateNeedsFlush(error: nil))
    }

    // MARK: - What the set holds

    /// An allow rule above the list takes its name out of the section.
    func testAnAllowRuleAboveTheListRemovesItsName() async {
        rm.config.rules.insert(Rule(matchType: .domain, pattern: "ads.example.com", routeId: direct.id, order: -1), at: 0)
        await sync()
        XCTAssertEqual(helper.blockedNames, ["pin.example.com", "track.example.net"])
    }

    /// The hosts the app's downloads redirect to are never blocked, whatever a list says.
    func testTheHostsDownloadsRedirectToAreNeverBlocked() {
        let plan = HostsBlockPlanner.plan(rm.config, lists: [source: [
            "raw.githubusercontent.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
            "github.com", "ads.example.com",
        ]], geosite: [:])
        XCTAssertEqual(plan.names, ["ads.example.com"])
    }

    // MARK: - The pin writer

    /// The pin writer writes nothing when the file already says it: no write, no flush.
    func testThePinWriterWritesNothingWhenTheFileIsUnchanged() throws {
        let entries = [(domain: "a.example.com", ip: "192.0.2.1")]
        let first = try XCTUnwrap(HostsPinSection.rewritten("127.0.0.1 localhost\n", entries: entries, isValid: { _, _ in true }))
        XCTAssertNil(HostsPinSection.rewritten(first, entries: entries, isValid: { _, _ in true }),
                     "the same pins wrote the file again")
        XCTAssertNil(HostsPinSection.rewritten("127.0.0.1 localhost\n", entries: [], isValid: { _, _ in true }),
                     "no pins on a file with none wrote the file")
        XCTAssertNotNil(HostsPinSection.rewritten(first, entries: [(domain: "a.example.com", ip: "192.0.2.2")], isValid: { _, _ in true }))
        XCTAssertNotNil(HostsPinSection.rewritten(first, entries: [], isValid: { _, _ in true }), "removing the pins is a write")
    }
}

// MARK: - A skipped setUp

@MainActor
final class HostsBlocklistSkipTests: XCTestCase {

    /// A setUp that skips because something else holds the route gate leaves that operation's
    /// state alone in tearDown: no detach, no cleared routes.
    func testATearDownAfterASkippedSetUpTouchesNothing() async throws {
        let rm = RouteManager.shared
        guard rm.tryAcquireRouteOperationForTests() else { throw XCTSkip("the route-operation gate is held") }
        let routes = rm.activeRoutes
        let held = RouteManager.ActiveRoute(destination: "198.51.100.200", gateway: "192.168.1.1",
                                            source: "198.51.100.200", timestamp: Date())
        rm.activeRoutes = [held]
        let fixture = HostsBlocklistTests()
        var skipped = false
        do { try await fixture.setUp() } catch is XCTSkip { skipped = true }
        try await fixture.tearDown()
        let after = rm.activeRoutes.map(\.destination)
        rm.activeRoutes = routes
        rm.releaseRouteOperationForTests()
        XCTAssertTrue(skipped, "setUp ran with the gate held")
        XCTAssertEqual(after, ["198.51.100.200"], "tearDown cleared routes it never set up")
    }
}

// MARK: - The row

final class ListRuleStateTests: XCTestCase {

    private let rule = Rule(matchType: .list, pattern: "https://lists.example.org/hosts", routeId: UUID(), order: 0)

    /// The helper confirmed this plan.
    private func state(_ plan: HostsBlockPlanner.Plan, pinning: Bool = true, downloading: Bool = false,
                       status: ListStatus? = nil, helperError: String? = nil) -> ListRuleState {
        ListRuleState(rule: rule, plan: plan, manageHostsFile: pinning, downloading: downloading,
                      status: status, helperError: helperError, confirmed: plan.accepted[rule.id], helperReady: true)
    }

    private func unconfirmed(_ plan: HostsBlockPlanner.Plan, helperError: String? = nil, helperReady: Bool = true) -> ListRuleState {
        ListRuleState(rule: rule, plan: plan, manageHostsFile: true, downloading: false, status: nil,
                      helperError: helperError, confirmed: nil, helperReady: helperReady)
    }

    func testEveryStateHasItsLine() {
        var accepted = HostsBlockPlanner.Plan()
        accepted.accepted[rule.id] = 816
        XCTAssertEqual(state(accepted).line(), "816 names blocked")
        accepted.accepted[rule.id] = 1
        XCTAssertEqual(state(accepted).line(), "1 name blocked")
        accepted.accepted[rule.id] = 0
        XCTAssertEqual(state(accepted, status: ListStatus(names: 2, updated: Date(), checked: Date(), error: nil)).line(),
                       "Adds no names of its own.")
        accepted.coveredAbove = [rule.id]
        XCTAssertEqual(state(accepted, status: ListStatus(names: 2, updated: Date(), checked: Date(), error: nil)).line(),
                       "Adds no names: the rules above it already cover every one.")

        var withDate = HostsBlockPlanner.Plan()
        withDate.accepted[rule.id] = 5
        let updated = state(withDate, status: ListStatus(names: 5, updated: Date(), checked: Date(), error: nil))
        XCTAssertTrue(updated.line().hasPrefix("5 names blocked, updated "), updated.line())

        let failedRefresh = state(withDate, status: ListStatus(names: 5, updated: nil, checked: Date(), error: "This is not a hosts file."))
        XCTAssertEqual(failedRefresh.line(), "5 names blocked\nLast try failed: This is not a hosts file.")
        // A failed send while an earlier set is still in the file: those names stay blocked.
        XCTAssertEqual(state(withDate, helperError: "helper stopping").line(), "5 names blocked\nLast try failed: helper stopping")
        // The helper never confirmed this list's names: nothing is blocked, and the row says so.
        let never = unconfirmed(withDate, helperError: "The helper is not running.")
        XCTAssertEqual(never.kind, .notBlocked)
        XCTAssertEqual(never.line(), "Not blocked: The helper is not running.")
        XCTAssertEqual(unconfirmed(withDate, helperReady: false).line(), "Not blocked: The helper is not running.")
        XCTAssertEqual(unconfirmed(withDate).kind, .pending, "with a ready helper and no failure the set is on its way")
        XCTAssertEqual(unconfirmed(withDate).line(), "Not blocked yet.")
        XCTAssertEqual(unconfirmed(withDate).names, 0)
        // The plan grew past what the helper confirmed: the confirmed count, not the planned one.
        var grown = withDate
        grown.accepted[rule.id] = 9
        XCTAssertEqual(ListRuleState(rule: rule, plan: grown, manageHostsFile: true, downloading: false, status: nil,
                                     helperError: nil, confirmed: 5, helperReady: true).line(), "5 names blocked")

        XCTAssertEqual(state(withDate, pinning: false).kind, .pinningOff)
        XCTAssertEqual(state(withDate, pinning: false).line(),
                       "Blocks nothing while Pin listed names in /etc/hosts is off (General).")

        var refused = HostsBlockPlanner.Plan()
        // Small numbers: a count over 999 is grouped in the Mac's own format.
        refused.refused[rule.id] = .tooLarge(names: 150, limit: 100)
        XCTAssertEqual(state(refused).line(), "Not blocked. It holds 150 names, over the limit of 100.")
        refused.refused[rule.id] = .overTotal(names: 60, limit: 100)
        XCTAssertEqual(state(refused).line(), "Not blocked. Its 60 names would take all lists past the limit of 100.")
        XCTAssertEqual(state(refused).kind, .refused)

        var inactive = HostsBlockPlanner.Plan()
        inactive.inactive[rule.id] = .noCopy
        XCTAssertEqual(state(inactive, downloading: true).line(), "Downloading…")
        XCTAssertEqual(state(inactive).line(), "Not downloaded yet.")
        XCTAssertEqual(state(inactive, status: ListStatus(names: 0, updated: nil, checked: Date(), error: "The server sent a web page, not a list.")).line(),
                       "Not downloaded: The server sent a web page, not a list.")
        inactive.inactive[rule.id] = .notBlockRoute
        XCTAssertEqual(state(inactive).line(), "A list blocks names only on the Block route.")
        inactive.inactive[rule.id] = .routeOff
        XCTAssertEqual(state(inactive).line(), "Its route is off, so this list blocks nothing.")
        inactive.inactive[rule.id] = .notCustomMode
        XCTAssertEqual(state(inactive).line(), "Lists block names only in Custom mode.")

        var off = rule
        off.enabled = false
        XCTAssertEqual(ListRuleState(rule: off, plan: accepted, manageHostsFile: true, downloading: false,
                                     status: nil, helperError: nil, confirmed: nil, helperReady: true).line(), "Off.")
    }

    /// Remove All Routes also takes the blocklist section out: its question says so when a list blocks.
    func testTheRemoveAllQuestionSaysTheListBlocksGoToo() {
        func message(_ lifts: Bool) -> String {
            DropdownCopy.removeAllConfirmation(mode: .custom, routeCount: 3, serviceCount: 0, domainCount: 0,
                                               autoApplyOnVPN: true, autoDNSRefresh: false, liftsListBlocks: lifts).message
        }
        XCTAssertTrue(message(true).hasSuffix(" It also unblocks the names your lists block, until routes are applied again."), message(true))
        XCTAssertFalse(message(false).contains("lists block"))
    }

    func testTheFootnoteSaysWhatAListDoesNotDo() {
        let text = HostsListFootnote.text()
        XCTAssertTrue(text.contains("not their subdomains"))
        XCTAssertTrue(text.contains("secure DNS"))
        XCTAssertTrue(text.contains("waits a few seconds"))
        XCTAssertTrue(text.contains("stay while VPN Bypass is closed, until the Mac restarts"))
        XCTAssertTrue(text.contains("above the list"))
        XCTAssertTrue(HostsListFootnote.measurementURL.absoluteString.hasSuffix("docs/research/hosts-scale.md"))
        XCTAssertEqual(HostsListPreset.name(for: HostsListPreset.stevenBlackURL), "StevenBlack's unified hosts list")
        XCTAssertEqual(HostsListPreset.stevenBlackURL, "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")
    }

    // MARK: Translations

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func lproj(_ language: String) throws -> Bundle {
        try XCTUnwrap(Bundle(url: Self.root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    /// Every line this feature adds, as its catalog key.
    static let keys = [
        "The helper is not running.", "The helper did not answer.", "A pinned name that a list blocks could not be unpinned.",
        "It holds %lld names, over the limit of %lld.", "Its %lld names would take all lists past the limit of %lld.",
        "Off.", "A list blocks names only on the Block route.", "Its route is off, so this list blocks nothing.",
        "Lists block names only in Custom mode.", "Downloading…", "Not downloaded yet.", "Not downloaded: %@",
        "Not blocked. %@", "Not blocked: %@", "Blocks nothing while Pin listed names in /etc/hosts is off (General).",
        "1 name blocked", "%lld names blocked", "Adds no names: the rules above it already cover every one.", "Adds no names of its own.", "%@, updated %@", "Last try failed: %@",
        "StevenBlack's unified hosts list", "A list blocks exactly the names in it, not their subdomains.",
        "A browser that uses its own secure DNS may skip it.",
        "Each time a list or a pinned address changes, every lookup on this Mac waits a few seconds.",
        "The blocks stay while VPN Bypass is closed, until the Mac restarts; they come back when it opens.", "To unblock a name, add a rule for it above the list.",
        "How the wait was measured", "Another list by its address", "The list's https address",
        "A hosts-format list (0.0.0.0 name per line). Adblock and wildcard lists are refused.",
        "Enter the https address of a hosts-format list.", "Add List…", "Block the names of a hosts-format list",
        "List", "Not blocked yet.", "It also unblocks the names your lists block, until routes are applied again.",
    ]

    func testEveryNewLineIsInEnglishSpanishAndFrench() throws {
        for language in ["en", "es", "fr"] {
            let bundle = try lproj(language)
            for key in Self.keys {
                let value = bundle.localizedString(forKey: key, value: "\u{0}MISSING", table: nil)
                XCTAssertNotEqual(value, "\u{0}MISSING", "\(language) has no entry for \"\(key)\"")
            }
        }
        // A whole line, in Spanish, through the row.
        var plan = HostsBlockPlanner.Plan()
        plan.inactive[rule.id] = .notBlockRoute
        let es = try lproj("es")
        XCTAssertEqual(ListRuleState(rule: rule, plan: plan, manageHostsFile: true, downloading: false, status: nil,
                                     helperError: nil, confirmed: nil, helperReady: true, in: es).line(in: es),
                       "Una lista solo bloquea nombres en la ruta Bloquear.")
    }
}

// MARK: - vpnb

final class ListRuleControlTests: XCTestCase {

    private func config() -> (RouteManager.Config, Route) {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        let block = Route(name: Route.blockName, egress: .block)
        c.routes = [block]
        return (c, block)
    }

    func testRuleAddTakesAListByItsHTTPSAddress() {
        let (c, block) = config()
        let added = CommandRouter.apply(ControlRequest(cmd: "rule.add", args: [
            "match": "list", "pattern": HostsListPreset.stevenBlackURL, "routeId": block.id.uuidString,
        ]), to: c)
        XCTAssertTrue(added.response.ok, "\(String(describing: added.response.error))")
        XCTAssertEqual(added.config.rules.first?.matchType, .list)
        XCTAssertEqual(added.config.rules.first?.pattern, HostsListPreset.stevenBlackURL)

        let plain = CommandRouter.apply(ControlRequest(cmd: "rule.add", args: [
            "match": "list", "pattern": "http://lists.example.org/hosts", "routeId": block.id.uuidString,
        ]), to: c)
        XCTAssertFalse(plain.response.ok, "a list over plain http was added")
        XCTAssertEqual(plain.response.error?.code, "invalid_args")
    }

    /// The list fields are optional: a reply from an older app decodes, and a filled one round-trips.
    func testTheListFieldsRoundTripAndAreOptional() throws {
        let rule = Rule(matchType: .list, pattern: HostsListPreset.stevenBlackURL, routeId: UUID(), order: 0)
        let filled = SanitizedRule(rule).withList(ListRuleState(kind: .refused, names: 150_000, error: "too many"))
        let decoded = try JSONDecoder().decode(SanitizedRule.self, from: JSONEncoder().encode(filled))
        XCTAssertEqual(decoded.listState, "refused")
        XCTAssertEqual(decoded.listNames, 150_000)
        XCTAssertEqual(decoded.listError, "too many")

        let bare = try JSONDecoder().decode(SanitizedRule.self, from: JSONEncoder().encode(SanitizedRule(rule)))
        XCTAssertNil(bare.listState)
        XCTAssertNil(bare.listNames)
    }
}
