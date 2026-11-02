// ConnectFromCacheTests.swift
// The apply after a VPN connect puts the routes back from the addresses already resolved, then
// refreshes DNS in the background, as the startup and Resume applies do. On 6.0.0 it resolved
// every name first: 62 s for 204 names on a GlobalProtect connect, with the listed sites in the
// tunnel all that time. Driven through `checkVPNStatus` against a fake kernel and a slow fake
// DNS, with the settle wait shortened (its length is ReconnectSettleTests' business).

import XCTest
@testable import VPNBypassCore

/// What the fake DNS answers, readable from the resolver's nonisolated closure.
private final class SlowDNS: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [String]] = [:]
    private var lookups = 0
    let delay: TimeInterval

    init(delay: TimeInterval) { self.delay = delay }

    func set(_ domain: String, _ ips: [String]) {
        lock.lock(); answers[domain] = ips; lock.unlock()
    }

    var lookupCount: Int { lock.lock(); defer { lock.unlock() }; return lookups }

    func resolve(_ domain: String) async -> [String]? {
        lock.lock(); lookups += 1; lock.unlock()
        // Not Task.sleep: a real lookup is a dig process on a GCD queue and runs out its
        // timeout whatever the caller cancels, so a cancelled refresh must not wait for it.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { done.resume() }
        }
        lock.lock(); defer { lock.unlock() }
        return answers[domain]
    }
}

@MainActor
final class ConnectFromCacheTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, gateway: String?,
                        loading: Bool, helper: HelperState, update: Date?, refresh: Date?)!
    private var kernel: FakeKernel!
    /// Every destination a batch add asked for, in order.
    private var addCalls: [String] = []
    private var startedAt = Date()

    private let settle: TimeInterval = 0.2

    override func setUp() async throws {
        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.localGateway, rm.isLoading,
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
        addCalls = []
        rm.addRoutesBatchOverrideForTests = { [unowned self] routes in
            self.addCalls += routes.map(\.destination)
            return self.kernel.add(routes)
        }
        startedAt = Date()
    }

    override func tearDown() async throws {
        await rm.waitForBackgroundRefreshForTests()
        DNSResolver.resolveOverrideForTests = nil
        rm.settleDelayOverrideForTests = nil
        rm.detectVPNInterfaceOverrideForTests = nil
        rm.setDNSDiskCacheForTests([:])
        FakeKernel.detach(from: rm)
        rm.activeRoutes = []
        rm.pendingKernelAdds = []
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.localGateway = saved.gateway
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

    /// The VPN comes up on this status pass.
    private func connect() async {
        rm.lastUpdate = nil   // or the connect is skipped as a duplicate of the last apply
        // A status pass can re-probe the helper, which this machine does not run.
        HelperManager.shared.helperState = .ready
        rm.detectVPNInterfaceOverrideForTests = { (true, "utun5", .globalProtect) }
        await rm.checkVPNStatus()
        XCTAssertTrue(rm.isVPNConnected)
    }

    private func disconnect() async {
        rm.detectVPNInterfaceOverrideForTests = { (false, nil, nil) }
        await rm.checkVPNStatus()   // waits out the 1.5 s flap recheck
        XCTAssertFalse(rm.isVPNConnected)
    }

    private func logs(_ message: String) -> Int {
        rm.recentLogs.filter { $0.timestamp >= startedAt && $0.message == message }.count
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private static let fromCache = "Routes put back from the DNS cache; refreshing DNS in the background"

    /// The live report: routes in ~75 s after every connect. With the names resolved before,
    /// they are in right after the settle wait, while every lookup still takes 4 s.
    func testRoutesAreInWithinTwoSecondsOfTheSettle() async throws {
        let dns = SlowDNS(delay: 4)
        dns.set("listed.example.com", ["198.51.100.20"])
        useDNS(dns)
        rm.setDNSDiskCacheForTests(["listed.example.com": ["198.51.100.20"]])

        await connect()
        let settledAt = Date().addingTimeInterval(settle)
        try await waitUntil(settle + 3) { kernel.installed.contains("198.51.100.20") }
        XCTAssertTrue(kernel.installed.contains("198.51.100.20"), "the route is not in")
        XCTAssertLessThan(Date().timeIntervalSince(settledAt), 2, "the route waited for DNS")
        XCTAssertEqual(logs(Self.fromCache), 1)
        XCTAssertEqual(logs("Resolving 1 domains..."), 0, "the connect ran the full apply")
    }

    /// The refresh after the cache apply adds an address DNS now gives and removes one it no
    /// longer gives.
    func testTheBackgroundRefreshAddsANewAddressAndRemovesAGoneOne() async throws {
        let dns = SlowDNS(delay: 0.5)
        dns.set("listed.example.com", ["198.51.100.20", "198.51.100.22"])
        useDNS(dns)
        rm.setDNSDiskCacheForTests(["listed.example.com": ["198.51.100.20", "198.51.100.21"]])

        await connect()
        try await waitUntil(settle + 3) { logs(Self.fromCache) == 1 }
        XCTAssertEqual(kernel.installed, ["198.51.100.20", "198.51.100.21"], "the cache apply put back what was cached")
        await rm.waitForBackgroundRefreshForTests()
        XCTAssertEqual(kernel.installed, ["198.51.100.20", "198.51.100.22"])
        XCTAssertEqual(Set(rm.activeRoutes.map(\.destination)), ["198.51.100.20", "198.51.100.22"])
        XCTAssertEqual(addCalls.filter { $0 == "198.51.100.20" }.count, 1, "an unchanged address was written twice")
    }

    /// Nothing resolved before (a first run): the connect resolves every name, as before.
    func testAnEmptyCacheStillRunsTheFullApply() async throws {
        let dns = SlowDNS(delay: 0.1)
        dns.set("listed.example.com", ["198.51.100.30"])
        useDNS(dns)
        rm.setDNSDiskCacheForTests([:])

        await connect()
        try await waitUntil(settle + 5) { kernel.installed.contains("198.51.100.30") }
        XCTAssertEqual(kernel.installed, ["198.51.100.30"])
        XCTAssertEqual(logs("Resolving 1 domains..."), 1)
        XCTAssertEqual(logs(Self.fromCache), 0)
    }

    /// A cached add that fails is not retried by the refresh, which adds only changed
    /// answers, so the connect goes on to the full apply, which puts it back.
    func testAFailedCacheAddFallsBackToTheFullApply() async throws {
        let dns = SlowDNS(delay: 0.1)
        dns.set("listed.example.com", ["198.51.100.20"])
        useDNS(dns)
        rm.setDNSDiskCacheForTests(["listed.example.com": ["198.51.100.20"]])
        var failOnce = true
        rm.addRoutesBatchOverrideForTests = { [unowned self] routes in
            self.addCalls += routes.map(\.destination)
            if failOnce {
                failOnce = false
                return (0, routes.count, routes.map(\.destination), "test")
            }
            return self.kernel.add(routes)
        }

        await connect()
        try await waitUntil(settle + 5) { kernel.installed.contains("198.51.100.20") }
        XCTAssertFalse(failOnce, "the cache add was tried")
        XCTAssertEqual(kernel.installed, ["198.51.100.20"], "the full apply put the failed address back")
        XCTAssertEqual(logs("Resolving 1 domains..."), 1)
        XCTAssertEqual(logs(Self.fromCache), 0)
    }

    /// The tunnel drops and comes back while the first connect's refresh still resolves. The
    /// second connect stops that refresh and runs its own: nothing is written twice, and the
    /// new address is added once, by the refresh that finishes.
    func testASecondConnectDuringTheRefreshDoesNotDoubleApply() async throws {
        // Slower than the drop and the reconnect below, so the first refresh is still resolving.
        let dns = SlowDNS(delay: 8)
        dns.set("listed.example.com", ["198.51.100.20", "198.51.100.23"])
        useDNS(dns)
        rm.setDNSDiskCacheForTests(["listed.example.com": ["198.51.100.20"]])
        // The second connect must apply: routes older than the refresh interval do.
        rm.config.dnsRefreshInterval = 0.001

        await connect()
        let settledAt = Date().addingTimeInterval(settle)
        try await waitUntil(settle + 3) { kernel.installed.contains("198.51.100.20") }
        XCTAssertLessThan(Date().timeIntervalSince(settledAt), 2, "the first connect waited for DNS")
        XCTAssertEqual(logs(Self.fromCache), 1)

        await disconnect()   // Bypass keeps its routes across the drop
        XCTAssertEqual(kernel.installed, ["198.51.100.20"])
        XCTAssertEqual(logs("Background refresh: 1 routes added, 0 removed"), 0, "the first refresh ended before the reconnect")
        await connect()
        let resettledAt = Date().addingTimeInterval(settle)
        try await waitUntil(settle + 9) { logs(Self.fromCache) == 2 }
        // The first refresh's lookups still have seconds to run; the apply must not wait them out.
        XCTAssertLessThan(Date().timeIntervalSince(resettledAt), 2, "the second connect waited for the cancelled refresh")
        XCTAssertEqual(logs(Self.fromCache), 2, "the second connect did not apply: " + rm.recentLogs.filter { $0.timestamp >= startedAt }.map(\.message).joined(separator: " | "))
        XCTAssertEqual(logs("Settle-gated apply skipped — preconditions changed during the wait"), 0)
        XCTAssertEqual(logs("Background DNS refresh cancelled: a newer apply replaces it"), 1)
        await rm.waitForBackgroundRefreshForTests()

        XCTAssertEqual(kernel.installed, ["198.51.100.20", "198.51.100.23"])
        XCTAssertEqual(addCalls.filter { $0 == "198.51.100.20" }.count, 1, "the cached address was written twice")
        XCTAssertEqual(addCalls.filter { $0 == "198.51.100.23" }.count, 1, "the new address was added twice")
        XCTAssertEqual(rm.activeRoutes.filter { $0.destination == "198.51.100.23" }.count, 1)
    }

    /// The wait the refresh uses on its lookups: a value when the work ends, nil at once on a
    /// cancel, even a cancel that lands before the wait starts.
    func testValueUnlessCancelledReturnsAtOnceOnCancel() async {
        let quick = Task<Int, Never> { 7 }
        let value = await RouteManager.valueUnlessCancelled(quick)
        XCTAssertEqual(value, 7)

        let slow = Task<Int, Never> {
            await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { done.resume(returning: 1) }
            }
        }
        let started = Date()
        let waiter = Task { await RouteManager.valueUnlessCancelled(slow) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertNil(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the cancelled wait ran the work out")

        let early = Task { () -> Int? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await RouteManager.valueUnlessCancelled(slow)
        }
        let earlyValue = await early.value
        XCTAssertNil(earlyValue)
    }
}
