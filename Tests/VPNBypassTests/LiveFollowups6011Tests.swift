// LiveFollowups6011Tests.swift
// Three follow-ups seen live on 6.0.10: the DNS Lookups capture starts again on a new helper,
// `vpnb why` does not call a name the forwarder leaves to its own resolver the wrong way, and
// the "Multiple tunnels up" line is logged on a change only.

import XCTest
@testable import VPNBypassCore

// MARK: - DNS Lookups after a helper restart

@MainActor
final class DNSLookupsHelperRestartTests: XCTestCase {

    private var hm: HelperManager { HelperManager.shared }
    private var rm: RouteManager { RouteManager.shared }
    private var monitor: DNSLookupsMonitor { DNSLookupsMonitor.shared }

    /// A helper whose capture the test controls.
    private final class FakeHelper {
        var ready = true
        /// What each start answers, in order; the last one repeats.
        var startAnswers: [String?] = [nil]
        var starts = 0
        var capturing = false

        func calls() -> DNSLookupsMonitor.HelperCalls {
            DNSLookupsMonitor.HelperCalls(
                isReady: { [unowned self] in self.ready },
                start: { [unowned self] in
                    let answer = self.startAnswers[min(self.starts, self.startAnswers.count - 1)]
                    self.starts += 1
                    self.capturing = answer == nil
                    return answer
                },
                drain: { [unowned self] in self.capturing ? [] : nil },
                stop: { [unowned self] in self.capturing = false })
        }

        /// The helper process was replaced: the new one runs no capture.
        func restart() { capturing = false }
    }

    private var fake: FakeHelper!
    private var saved: (enabled: Bool, logs: [RouteManager.LogEntry], state: HelperState, version: String?,
                        pending: HelperManager.PendingUpdate?, error: String?,
                        plists: () -> (installed: Data?, bundled: Data?))!
    private var savedDelays: [TimeInterval] = []
    private var reapplies = 0

    override func setUp() async throws {
        saved = (rm.config.dnsLookupsEnabled, rm.recentLogs, hm.helperState, hm.helperVersion, hm.pendingUpdate,
                 hm.installationError, hm.launchdPlists)
        fake = FakeHelper()
        monitor.helper = fake.calls()
        monitor.readsSearchDomains = false
        rm.recentLogs = []
        reapplies = 0
        hm.reapplyRoutesAfterUpdate = { [weak self] in self?.reapplies += 1 }
        savedDelays = hm.selfUpdateRestartDelays
        hm.selfUpdateRestartDelays = [0, 0, 0]
    }

    override func tearDown() async throws {
        await hm.updateTask?.value
        rm.config.dnsLookupsEnabled = false
        monitor.followConfig()
        monitor.helper = .live
        monitor.readsSearchDomains = true
        hm.versionProbeOverrideForTests = nil
        hm.selfUpdateOverrideForTests = nil
        hm.selfUpdateRestartDelays = savedDelays
        hm.reapplyRoutesAfterUpdate = { await RouteManager.shared.reapplyAfterHelperUpdate() }
        hm.launchdPlists = saved.plists
        hm.helperState = saved.state
        hm.helperVersion = saved.version
        hm.pendingUpdate = saved.pending
        hm.installationError = saved.error
        rm.config.dnsLookupsEnabled = saved.enabled
        rm.recentLogs = saved.logs
    }

    private func logLines(containing text: String) -> [String] {
        rm.recentLogs.map(\.message).filter { $0.contains(text) }
    }

    /// The page is on and capturing, as before the update.
    private func capturing() async {
        rm.config.dnsLookupsEnabled = true
        monitor.followConfig()
        await monitor.helperRestarted()
        XCTAssertTrue(monitor.isCapturing)
        rm.recentLogs = []
    }

    /// The live case: the helper updated itself (2.8.0 to 2.9.0 here) while the page watched.
    /// The new helper runs no capture; the app starts it again once the new helper answers, in
    /// the same step that sends the wildcards and applies the routes again.
    func testTheCaptureStartsAgainWhenTheUpdatedHelperAnswers() async throws {
        await capturing()
        let startsBefore = fake.starts
        let plist = Data("<plist>shipped</plist>".utf8)
        hm.launchdPlists = { (plist, plist) }
        var installed = false
        hm.versionProbeOverrideForTests = { .version(installed ? "2.9.0" : "2.8.0") }
        hm.selfUpdateOverrideForTests = { [weak self] _ in
            installed = true
            self?.fake.restart()
            return .installing
        }

        XCTAssertTrue(hm.adoptOlderHelperAndUpdate(installed: "2.8.0", expected: "2.9.0"))
        await hm.updateTask?.value

        XCTAssertEqual(hm.helperVersion, "2.9.0")
        XCTAssertEqual(fake.starts, startsBefore + 1, "the capture is started on the new helper")
        XCTAssertTrue(monitor.isCapturing)
        XCTAssertNil(monitor.problem)
        XCTAssertEqual(logLines(containing: "DNS Lookups running again").count, 1)
        XCTAssertTrue(rm.config.dnsLookupsEnabled, "the setting the user chose is kept")
        XCTAssertEqual(reapplies, 1)
    }

    /// With the page off the restart starts nothing, and the setting stays off.
    func testARestartStartsNothingWhenThePageIsOff() async {
        rm.config.dnsLookupsEnabled = false
        monitor.followConfig()
        await hm.restoreAfterHelperRestart(reapplyRoutes: false)
        XCTAssertEqual(fake.starts, 0)
        XCTAssertFalse(monitor.isCapturing)
        XCTAssertFalse(rm.config.dnsLookupsEnabled)
        XCTAssertTrue(logLines(containing: "DNS Lookups").isEmpty)
    }

    /// The live log: the start during the switch found no helper answering. That is not the
    /// end: when the new helper answers the capture starts, and the log says so.
    func testAStartThatFoundNoHelperIsTriedAgainWhenItComesBack() async {
        fake.startAnswers = ["The privileged helper did not answer.", nil]
        rm.config.dnsLookupsEnabled = true
        monitor.followConfig()
        await monitor.helperRestarted()
        XCTAssertFalse(monitor.isCapturing)
        XCTAssertEqual(logLines(containing: "DNS Lookups could not start: The privileged helper did not answer.").count, 1)

        await hm.restoreAfterHelperRestart(reapplyRoutes: false)
        XCTAssertEqual(fake.starts, 2)
        XCTAssertTrue(monitor.isCapturing)
        XCTAssertNil(monitor.problem)
        XCTAssertEqual(logLines(containing: "DNS Lookups running again").count, 1)
        XCTAssertTrue(rm.config.dnsLookupsEnabled)
    }
}

// MARK: - `vpnb why` for a name the forwarder leaves to its own resolver

final class WhyDelegatedNameTests: XCTestCase {

    private let local = "192.168.1.1"

    /// `*.ts.net` on the Bypass list, served by the forwarder, with Tailscale's MagicDNS
    /// published for the tailnet, as `ScutilDNS.owners` puts it in the spec.
    private func snapshot(mode: RoutingMode = .bypass, served: Bool = true) -> SiteRoute.Snapshot {
        let owner = WildcardDelegation(domain: "example-tailnet.ts.net", servers: ["100.100.100.100"], port: 53, interface: nil)
        let spec = WildcardSpec(suffix: "ts.net", gateway: local, upstream: ["192.168.1.53"], interface: "en0",
                                delegated: [owner])
        var s = SiteRoute.Snapshot(mode: mode, custom: false, list: [DomainEntry(domain: "*.ts.net")], services: [],
                                   rules: [], routes: [], defaultRouteId: nil, activeRoutes: [],
                                   localGateway: local, vpnInterface: "utun5")
        if served { s.wildcardSpecs = [spec] }
        return s
    }

    private func probe(_ address: String, via interface: String, _ answer: PathCheck.Answer = .connected) -> PathCheck.Probe {
        PathCheck.Probe(address: address, routeInterface: interface, answer: answer, latencyMs: answer.answered ? 12 : nil)
    }

    private func why(_ host: String, _ address: String, via interface: String, in s: SiteRoute.Snapshot,
                     _ answer: PathCheck.Answer = .connected) -> SiteRouteAnswer {
        let found = SiteRoute.match(host: host, addresses: [address], in: s)
        let control = probe("192.0.2.1", via: "utun5", .notTried)
        return SiteRoute.answer(host: host, mode: s.mode, addresses: [address], found: found,
                                probes: [probe(address, via: interface, answer)],
                                control: (control, PathCheck.control(control, unrouted: .tunnel("utun5"))),
                                vpnConnected: true)
    }

    /// The live case: a tailnet name under `*.ts.net` left through Tailscale's tunnel. The
    /// forwarder hands it to MagicDNS and routes nothing, so that way is right.
    func testATailnetNameLeavingThroughTailscaleIsOK() {
        let a = why("host.example-tailnet.ts.net", "100.64.0.10", via: "utun4", in: snapshot())
        XCTAssertEqual(a.match, .wildcard)
        XCTAssertEqual(a.entry, "*.ts.net")
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertEqual(a.checks.first?.verdict, .ok)
        XCTAssertNil(a.expected)
        XCTAssertEqual(a.notRouted, .ownResolver)
        XCTAssertEqual(a.resolverDomain, "example-tailnet.ts.net")
        XCTAssertTrue(a.summary.contains("example-tailnet.ts.net has its own resolver"), a.summary)
        XCTAssertFalse(a.summary.contains("adds its routes"), a.summary)
        let facts = VPNBCLI.whyLines(a).last ?? ""
        XCTAssertTrue(facts.contains("not routed: ownResolver (example-tailnet.ts.net)"), facts)
        // An unanswered 443 is still its own result.
        XCTAssertEqual(why("host.example-tailnet.ts.net", "100.64.0.10", via: "utun4", in: snapshot(), .noAnswer).verdict, .noAnswer)
    }

    /// A public name under the same wildcard is still routed around the VPN, and one that went
    /// into the VPN is still the wrong way.
    func testAnOrdinaryWildcardNameThroughTheVPNIsStillWrongWay() {
        let a = why("public.ts.net", "93.184.216.34", via: "utun5", in: snapshot())
        XCTAssertEqual(a.match, .wildcard)
        XCTAssertNil(a.notRouted)
        XCTAssertEqual(a.expected, "physical")
        XCTAssertEqual(a.verdict, .wrongWay)
        XCTAssertEqual(why("public.ts.net", "93.184.216.34", via: "en0", in: snapshot()).verdict, .ok)
    }

    /// An address the guard refuses (100.64.0.0/10 here, with no resolver of its own) is never
    /// learned, so the name follows the system's routing and is not called the wrong way.
    func testANameOnAnAddressTheGuardRefusesIsNotWrongWay() {
        let a = why("other.ts.net", "100.64.0.20", via: "utun4", in: snapshot())
        XCTAssertEqual(a.notRouted, .addressNotRoutable)
        XCTAssertNil(a.resolverDomain)
        XCTAssertEqual(a.verdict, .ok)
    }

    /// While the forwarder serves nothing, nothing is delegated: the answer is as before.
    func testWithTheForwarderNotServingTheAnswerIsUnchanged() {
        let a = why("host.example-tailnet.ts.net", "100.64.0.10", via: "utun4", in: snapshot(served: false))
        XCTAssertNil(a.notRouted)
        XCTAssertEqual(a.expected, "physical")
    }

    /// A Custom wildcard rule reaches its names through the same forwarder.
    func testACustomWildcardRuleUsesTheSameRule() {
        let direct = Route(name: "Direct", egress: .direct)
        let rule = Rule(matchType: .domain, pattern: "*.ts.net", routeId: direct.id, order: 0)
        var s = snapshot(mode: .custom)
        s.custom = true
        s.routes = [direct]
        s.rules = [rule]
        let a = why("host.example-tailnet.ts.net", "100.64.0.10", via: "utun4", in: s)
        XCTAssertEqual(a.match, .rule)
        XCTAssertEqual(a.notRouted, .ownResolver)
        XCTAssertEqual(a.verdict, .ok)
    }
}

// MARK: - The "Multiple tunnels up" line

final class MultiTunnelNoticeTests: XCTestCase {
    /// Seen live: the line every 30 s pushed every other line out of the log window. It is
    /// logged once per set of tunnels and chosen one.
    func testTheLineIsLoggedOncePerSetAndAgainOnAChange() {
        var notice = MultiTunnelNotice()
        let set = ["utun4", "utun5", "utun10"]
        var lines: [String] = []
        for _ in 0..<10 {
            if let line = notice.line(tunnels: set, selected: "utun5", carriesTraffic: true) { lines.append(line) }
        }
        XCTAssertEqual(lines, ["Multiple tunnels up (utun4, utun5, utun10) — using utun5 (carries the traffic)"])

        // Another tunnel comes up: logged again, once.
        for _ in 0..<3 {
            if let line = notice.line(tunnels: set + ["utun11"], selected: "utun5", carriesTraffic: true) { lines.append(line) }
        }
        XCTAssertEqual(lines.count, 2)
        // Another tunnel is chosen.
        XCTAssertNotNil(notice.line(tunnels: set + ["utun11"], selected: "utun11", carriesTraffic: false))
        XCTAssertNil(notice.line(tunnels: set + ["utun11"], selected: "utun11", carriesTraffic: false))
        // Down to one tunnel and back: the line says so again.
        XCTAssertNil(notice.line(tunnels: [], selected: "utun11", carriesTraffic: true))
        XCTAssertNotNil(notice.line(tunnels: set + ["utun11"], selected: "utun11", carriesTraffic: false))
    }
}
