// TunnelSwitchFromCacheTests.swift
// When the VPN moves to another tunnel (a second VPN connects, or the selected one comes back on
// another utun), the routes are put back from the addresses already resolved, then DNS is looked
// up again in the background, as a fresh connect does since 6.0.1. On 6.0.5 a switch looked every
// name up first: with two VPNs on one Mac, each switch logged "Resolving 204 domains..." and the
// routes followed about 50 s later. Driven through `checkVPNStatus` against a fake kernel and a
// slow fake DNS (SlowDNS, from ConnectFromCacheTests).

import XCTest
@testable import VPNBypassCore

@MainActor
final class TunnelSwitchFromCacheTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, gateway: String?,
                        vpnGateway: String?, loading: Bool, helper: HelperState, update: Date?, refresh: Date?)!
    private var kernel: FakeKernel!
    /// Kernel writes per destination. The helper reads each route first and writes only one
    /// that is missing or points elsewhere, so a re-sent route that is already right is no write.
    private var writes: [String: Int] = [:]
    private var startedAt = Date()

    private let settle: TimeInterval = 0.2
    private let a = "198.51.100.20"

    override func setUp() async throws {
        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.localGateway, rm.vpnGateway, rm.isLoading,
                 HelperManager.shared.helperState, rm.lastUpdate, rm.lastDNSRefresh)
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.autoApplyOnVPN = true
        cfg.services = []
        cfg.domains = [DomainEntry(domain: "listed.example.com")]
        rm.config = cfg
        rm.resetShutdownStateForTests()
        rm.resetSettleStateForTests()
        rm.resetRerouteStateForTests()
        rm.pendingKernelAdds = []
        rm.activeRoutes = []
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.isLoading = false
        rm.lastUpdate = nil
        rm.lastDNSRefresh = nil
        HelperManager.shared.helperState = .ready
        rm.settleDelayOverrideForTests = settle
        kernel = FakeKernel(installed: [])
        kernel.attach(to: rm)
        writes = [:]
        rm.addRoutesBatchOverrideForTests = { [unowned self] routes in
            for r in routes where !self.kernel.installed.contains(r.destination) || self.kernel.gateways[r.destination] != r.gateway {
                self.writes[r.destination, default: 0] += 1
            }
            return self.kernel.add(routes)
        }
        startedAt = Date()
    }

    override func tearDown() async throws {
        await rm.waitForBackgroundRefreshForTests()
        DNSResolver.resolveOverrideForTests = nil
        rm.settleDelayOverrideForTests = nil
        rm.rerouteCooldownOverrideForTests = nil
        rm.listVPNLinksOverrideForTests = nil
        rm.detectVPNInterfaceOverrideForTests = nil
        rm.resetRerouteStateForTests()
        rm.setDNSDiskCacheForTests([:])
        FakeKernel.detach(from: rm)
        rm.activeRoutes = []
        rm.pendingKernelAdds = []
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.localGateway = saved.gateway
        rm.vpnGateway = saved.vpnGateway
        rm.isLoading = saved.loading
        rm.lastUpdate = saved.update
        rm.lastDNSRefresh = saved.refresh
        HelperManager.shared.helperState = saved.helper
        rm.resetSettleStateForTests()
        rm.resetShutdownStateForTests()
    }

    private func useDNS(_ dns: SlowDNS) {
        DNSResolver.resolveOverrideForTests = { await dns.resolve($0) }
        rm.resolveIPsOverrideForTests = { await dns.resolve($0) }
    }

    private func logs(_ message: String) -> Int {
        rm.recentLogs.filter { $0.timestamp >= startedAt && $0.message == message }.count
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private static let connectFromCache = "Routes put back from the DNS cache; refreshing DNS in the background"
    private static let switchFromCache = "Routes put back from the DNS cache after the tunnel switch; refreshing DNS in the background"

    /// The VPN comes up on `iface`, the connect apply puts the routes in from the cache and its
    /// background refresh ends. Lookups answer at once here; each test then sets its own DNS.
    private func connectAndSettle(_ iface: String = "utun11", cached: [String]) async throws {
        let quick = SlowDNS(delay: 0)
        quick.set("listed.example.com", cached)
        useDNS(quick)
        rm.setDNSDiskCacheForTests(["listed.example.com": cached])
        rm.lastUpdate = nil
        HelperManager.shared.helperState = .ready
        rm.detectVPNInterfaceOverrideForTests = { (true, iface, .wireGuard) }
        await rm.checkVPNStatus()
        XCTAssertTrue(rm.isVPNConnected)
        try await waitUntil(settle + 5) { logs(Self.connectFromCache) == 1 }
        XCTAssertEqual(logs(Self.connectFromCache), 1, "the connect did not apply from the cache")
        await rm.waitForBackgroundRefreshForTests()
        startedAt = Date()
    }

    /// The selected tunnel moves to `iface` on this status pass. Returns how long the pass took:
    /// the re-route runs inside it.
    @discardableResult
    private func switchTunnel(to iface: String) async -> TimeInterval {
        HelperManager.shared.helperState = .ready
        rm.detectVPNInterfaceOverrideForTests = { (true, iface, .wireGuard) }
        let began = Date()
        await rm.checkVPNStatus()
        return Date().timeIntervalSince(began)
    }

    private var trail: String {
        rm.recentLogs.filter { $0.timestamp >= startedAt }.map(\.message).joined(separator: " | ")
    }

    /// The live report: every switch looked 204 names up before a route moved. With the names
    /// resolved before, the switch's apply is done within 2 s while every lookup takes 4 s.
    func testASwitchAppliesFromTheCacheWithinTwoSeconds() async throws {
        try await connectAndSettle(cached: [a])
        let slow = SlowDNS(delay: 4)
        slow.set("listed.example.com", [a])
        useDNS(slow)

        let took = await switchTunnel(to: "utun5")
        XCTAssertEqual(logs("VPN interface changed: utun11 → utun5"), 1, trail)
        XCTAssertLessThan(took, 2, "the switch waited for DNS: " + trail)
        XCTAssertEqual(logs(Self.switchFromCache), 1, trail)
        XCTAssertEqual(logs("Resolving 1 domains..."), 0, "the switch ran the full apply")
        XCTAssertTrue(kernel.installed.contains(a))
        XCTAssertEqual(writes[a], 1, "a Bypass route to the same local gateway was written again")
    }

    /// The refresh after the switch adds an address DNS now gives and removes one it no longer
    /// gives; the cache apply before it changed nothing.
    func testTheRefreshAfterASwitchAddsANewAddressAndRemovesAGoneOne() async throws {
        try await connectAndSettle(cached: [a, "198.51.100.21"])
        XCTAssertEqual(kernel.installed, [a, "198.51.100.21"])
        let dns = SlowDNS(delay: 0.5)
        dns.set("listed.example.com", [a, "198.51.100.22"])
        useDNS(dns)

        await switchTunnel(to: "utun5")
        XCTAssertEqual(logs(Self.switchFromCache), 1, trail)
        XCTAssertEqual(kernel.installed, [a, "198.51.100.21"], "the cache apply put back what was cached")
        await rm.waitForBackgroundRefreshForTests()
        XCTAssertEqual(kernel.installed, [a, "198.51.100.22"], trail)
        XCTAssertEqual(Set(rm.activeRoutes.map(\.destination)), [a, "198.51.100.22"])
        XCTAssertEqual(writes[a], 1, "an unchanged address was written twice")
        XCTAssertEqual(writes["198.51.100.22"], 1)
    }

    /// Nothing resolved before: the switch resolves every name, as before.
    func testAnEmptyCacheStillRunsTheFullApplyOnASwitch() async throws {
        try await connectAndSettle(cached: [a])
        rm.setDNSDiskCacheForTests([:])
        let dns = SlowDNS(delay: 0.1)
        dns.set("listed.example.com", [a])
        useDNS(dns)

        await switchTunnel(to: "utun5")
        XCTAssertEqual(logs("Resolving 1 domains..."), 1, trail)
        XCTAssertEqual(logs(Self.switchFromCache), 0)
        XCTAssertEqual(kernel.installed, [a])
    }

    /// The live pattern: the second VPN drops and returns every minute or two, so the tunnel
    /// switches back while the refresh of the last switch still resolves. The switch back stops
    /// that refresh and starts its own; nothing is written twice and the new address goes in once.
    func testASwitchBackDuringTheRefreshCancelsItAndWritesEachAddressOnce() async throws {
        rm.rerouteCooldownOverrideForTests = 0.5
        try await connectAndSettle(cached: [a])
        let slow = SlowDNS(delay: 6)
        slow.set("listed.example.com", [a, "198.51.100.23"])
        useDNS(slow)

        let first = await switchTunnel(to: "utun5")
        XCTAssertLessThan(first, 2, "the switch waited for DNS: " + trail)
        try await Task.sleep(nanoseconds: 1_000_000_000)   // past the cooldown, inside the refresh
        XCTAssertEqual(logs("Background refresh: 1 routes added, 0 removed"), 0, "the refresh ended before the switch back")
        let back = await switchTunnel(to: "utun11")
        XCTAssertLessThan(back, 2, "the switch back waited for the cancelled refresh: " + trail)
        XCTAssertEqual(logs("VPN interface changed: utun5 → utun11"), 1, trail)
        XCTAssertEqual(logs("Background DNS refresh cancelled: a newer apply replaces it"), 1, trail)
        XCTAssertEqual(logs(Self.switchFromCache), 2, trail)
        await rm.waitForBackgroundRefreshForTests()

        XCTAssertEqual(kernel.installed, [a, "198.51.100.23"], trail)
        XCTAssertEqual(writes[a], 1, "the cached address was written twice")
        XCTAssertEqual(writes["198.51.100.23"], 1, "the new address was added twice")
        XCTAssertEqual(rm.activeRoutes.filter { $0.destination == "198.51.100.23" }.count, 1)
        XCTAssertFalse(rm.pendingReroute, "a re-route is still latched")
    }

    /// VPN Only routes point into the tunnel. After a switch none may stay on the old one, where
    /// the listed sites would go nowhere (or, once it is gone, around the VPN).
    func testVPNOnlyRoutesMoveToTheNewTunnel() async throws {
        rm.config.routingMode = .vpnOnly
        rm.config.inverseDomains = [DomainEntry(domain: "listed.example.com")]
        try await connectAndSettle(cached: [a])
        let before = try XCTUnwrap(rm.vpnGateway)
        XCTAssertEqual(kernel.gateways[a], before, trail)
        let slow = SlowDNS(delay: 4)
        slow.set("listed.example.com", [a])
        useDNS(slow)

        let took = await switchTunnel(to: "utun5")
        let after = try XCTUnwrap(rm.vpnGateway)
        try XCTSkipIf(before == after, "this Mac reports one VPN gateway for both tunnels (\(before)); nothing to re-point")
        XCTAssertLessThan(took, 2, "the switch waited for DNS: " + trail)
        XCTAssertEqual(logs(Self.switchFromCache), 1, trail)
        XCTAssertEqual(kernel.gateways[a], after, "the listed route still points at the old tunnel")
        XCTAssertFalse(kernel.gateways.values.contains(before), "a route still points at \(before)")
        await rm.waitForBackgroundRefreshForTests()
        XCTAssertEqual(kernel.gateways[a], after)
        XCTAssertFalse(kernel.gateways.values.contains(before), "a route still points at \(before)")
    }

    /// A Custom route pinned to one VPN follows it when it comes back on another utun, and keeps
    /// no route on the old one.
    func testACustomPinnedRouteMovesWithItsTunnel() async throws {
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.manageHostsFile = false
        cfg.autoApplyOnVPN = true
        let direct = Route(name: "Direct", egress: .direct)
        let pinned = Route(name: "Office", egress: .vpnDefault,
                           vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun11", productHint: "WireGuard"))
        cfg.routes = [direct, pinned]
        cfg.rules = [Rule(matchType: .domain, pattern: "listed.example.com", routeId: pinned.id, order: 0)]
        cfg.defaultRouteId = direct.id
        rm.config = cfg
        var links = [RouteManager.VPNLink(interface: "utun11", addresses: ["198.18.0.2"], label: "WireGuard", isTailscale: false)]
        rm.listVPNLinksOverrideForTests = { links }

        try await connectAndSettle(cached: [a])
        XCTAssertEqual(kernel.gateways[a], "iface:utun11", trail)
        let slow = SlowDNS(delay: 4)
        slow.set("listed.example.com", [a])
        useDNS(slow)

        links = [RouteManager.VPNLink(interface: "utun5", addresses: ["198.18.0.2"], label: "WireGuard", isTailscale: false)]
        let took = await switchTunnel(to: "utun5")
        XCTAssertLessThan(took, 2, "the switch waited for DNS: " + trail)
        XCTAssertEqual(logs(Self.switchFromCache), 1, trail)
        XCTAssertEqual(kernel.gateways[a], "iface:utun5", "the pinned route still points at the old tunnel")
        XCTAssertFalse(kernel.gateways.values.contains("iface:utun11"))
        await rm.waitForBackgroundRefreshForTests()
        XCTAssertEqual(kernel.gateways[a], "iface:utun5")
        XCTAssertFalse(kernel.gateways.values.contains("iface:utun11"))
    }
}
