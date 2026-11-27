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
        rm.pinnedHostNames = []
        rm.blockedHostsError = nil
    }

    override func tearDown() async throws {
        await rm.cancelConfigFollowUps()
        await rm.waitForBackgroundRefreshForTests()
        await rm.waitForBlockedHostsSync()
        await rm.cancelResumeApplyForTests()
        rm.endPause(reason: "test over", apply: false)
        BlockingKernel.detach(from: rm)
        rm.setBlockedHostsOverrideForTests = nil
        rm.updateHostsFileOverrideForTests = nil
        rm.hostsFileOverrideForTests = nil
        rm.sentBlockedHosts = nil
        rm.pinnedHostNames = []
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
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func storeCopy(_ names: [String]) async throws {
        let body = Data((names.map { "0.0.0.0 \($0)" }.joined(separator: "\n") + "\n").utf8)
        store.fetch = { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try body.write(to: file)
            return file
        }
        let saved = await store.update(from: URL(string: source)!)
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

// MARK: - The row

final class ListRuleStateTests: XCTestCase {

    private let rule = Rule(matchType: .list, pattern: "https://lists.example.org/hosts", routeId: UUID(), order: 0)

    private func state(_ plan: HostsBlockPlanner.Plan, pinning: Bool = true, downloading: Bool = false,
                       status: ListStatus? = nil, helperError: String? = nil) -> ListRuleState {
        ListRuleState(rule: rule, plan: plan, manageHostsFile: pinning, downloading: downloading,
                      status: status, helperError: helperError)
    }

    func testEveryStateHasItsLine() {
        var accepted = HostsBlockPlanner.Plan()
        accepted.accepted[rule.id] = 816
        XCTAssertEqual(state(accepted).line(), "816 names blocked")
        accepted.accepted[rule.id] = 1
        XCTAssertEqual(state(accepted).line(), "1 name blocked")

        var withDate = HostsBlockPlanner.Plan()
        withDate.accepted[rule.id] = 5
        let updated = state(withDate, status: ListStatus(names: 5, updated: Date(), checked: Date(), error: nil))
        XCTAssertTrue(updated.line().hasPrefix("5 names blocked, updated "), updated.line())

        let failedRefresh = state(withDate, status: ListStatus(names: 5, updated: nil, checked: Date(), error: "This is not a hosts file."))
        XCTAssertEqual(failedRefresh.line(), "5 names blocked\nLast try failed: This is not a hosts file.")
        XCTAssertEqual(state(withDate, helperError: "helper stopping").line(), "5 names blocked\nLast try failed: helper stopping")

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
                                     status: nil, helperError: nil).line(), "Off.")
    }

    func testTheFootnoteSaysWhatAListDoesNotDo() {
        let text = HostsListFootnote.text()
        XCTAssertTrue(text.contains("not their subdomains"))
        XCTAssertTrue(text.contains("secure DNS"))
        XCTAssertTrue(text.contains("waits a few seconds"))
        XCTAssertTrue(text.contains("stay while VPN Bypass is closed"))
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
        "The helper is not running.", "The helper did not answer.",
        "It holds %lld names, over the limit of %lld.", "Its %lld names would take all lists past the limit of %lld.",
        "Off.", "A list blocks names only on the Block route.", "Its route is off, so this list blocks nothing.",
        "Lists block names only in Custom mode.", "Downloading…", "Not downloaded yet.", "Not downloaded: %@",
        "Not blocked. %@", "Blocks nothing while Pin listed names in /etc/hosts is off (General).",
        "1 name blocked", "%lld names blocked", "%@, updated %@", "Last try failed: %@",
        "StevenBlack's unified hosts list", "A list blocks exactly the names in it, not their subdomains.",
        "A browser that uses its own secure DNS may skip it.",
        "Each time a list or a pinned address changes, every lookup on this Mac waits a few seconds.",
        "The blocks stay while VPN Bypass is closed.", "To unblock a name, add a rule for it above the list.",
        "How the wait was measured", "Another list by its address", "The list's https address",
        "A hosts-format list (0.0.0.0 name per line). Adblock and wildcard lists are refused.",
        "Enter the https address of a hosts-format list.", "Add List…", "Block the names of a hosts-format list",
        "List",
    ]

    func testEveryNewLineIsInSpanishAndFrench() throws {
        for language in ["es", "fr"] {
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
                                     helperError: nil, in: es).line(in: es),
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
