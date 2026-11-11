// RuleBlockLifecycleTests.swift
// Custom mode's Block route, the address half, against a fake kernel: the blocks a rule asks for go
// in, follow the rule when it changes, and come out with the routes. The helper's real reject routes
// are the ones VPN Only already uses; here the kernel is `BlockingKernel`.

import XCTest
@testable import VPNBypassCore

@MainActor
final class RuleBlockLifecycleTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, connected: Bool, gateway: String?, helper: HelperState, loading: Bool)!
    private var kernel: BlockingKernel!
    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)

    override func setUp() async throws {
        await rm.cancelConfigFollowUps()
        await rm.waitForBackgroundRefreshForTests()
        // Another test can leave a pause on or the route-operation gate held, and then every apply
        // here returns at once having done nothing. Both are cleared, and the reason is named if one
        // had to be.
        if rm.isPaused {
            rm.endPause(reason: "a lifecycle test", apply: false)
            XCTAssertFalse(rm.isPaused, "an earlier test left routing paused")
        }
        var waited = 0
        while rm.isApplyingRoutes && waited < 100 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
        if rm.isApplyingRoutes {
            rm.releaseRouteOperation()
            XCTAssertFalse(rm.isApplyingRoutes, "an earlier test left the route-operation gate held")
        }
        saved = (rm.config, rm.isVPNConnected, rm.localGateway, HelperManager.shared.helperState, rm.isLoading)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.manageHostsFile = false
        cfg.services = []
        cfg.domains = []
        cfg.routes = [direct, block]
        cfg.defaultRouteId = direct.id
        cfg.fallbackDNS = ["1.1.1.1"]
        cfg.rules = [Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: block.id, order: 0),
                     Rule(matchType: .ip, pattern: "198.51.100.9", routeId: block.id, order: 1),
                     Rule(matchType: .ip, pattern: "198.51.100.77", routeId: direct.id, order: 2)]
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
    }

    override func tearDown() async throws {
        // An apply leaves background work (a DNS refresh, a config follow-up): let it finish before
        // the next test changes the state it reads, as the other lifecycle tests do.
        await rm.cancelConfigFollowUps()
        await rm.waitForBackgroundRefreshForTests()
        BlockingKernel.detach(from: rm)
        rm.activeRoutes = []
        rm.ruleBlocks = []
        rm.blockedRoutes = []
        rm.pendingKernelAdds = []
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.localGateway = saved.gateway
        rm.isLoading = saved.loading
        HelperManager.shared.helperState = saved.helper
        rm.resetShutdownStateForTests()
    }

    private func block(_ d: String, _ source: String) -> RouteCompiler.DesiredBlock { .init(destination: d, source: source) }

    // MARK: - The apply

    func testAnApplyBlocksWhatTheBlockRulesNameAndRoutesTheRest() async {
        await rm.applyAllRoutes()
        XCTAssertEqual(kernel.blocks, ["203.0.113.0/24", "198.51.100.9"])
        XCTAssertEqual(kernel.base.installed, ["198.51.100.77"], "the Direct rule's address is routed, not blocked")
        XCTAssertEqual(rm.ruleBlocks.map(\.destination).sorted(), ["198.51.100.9", "203.0.113.0/24"])
        XCTAssertEqual(rm.ruleBlockCount(forPattern: "203.0.113.0/24"), 1)
        XCTAssertTrue(rm.blockedRoutes.isEmpty, "VPN Only's blocks are a different record")
        XCTAssertEqual(rm.routedAddressCount, 1, "a block is not a route")
    }

    func testAReapplyThatChangesNothingBlocksNothingAgain() async {
        await rm.applyAllRoutes()
        let calls = kernel.blockCalls.count
        await rm.applyAllRoutes()
        XCTAssertEqual(kernel.blockCalls.count, calls, "the same blocks are not written twice")
        XCTAssertEqual(kernel.blocks.count, 2)
    }

    func testARuleEditedOrSwitchedOffLosesItsBlock() async {
        await rm.applyAllRoutes()
        rm.config.rules[1].enabled = false
        await rm.applyAllRoutes()
        XCTAssertEqual(kernel.blocks, ["203.0.113.0/24"], "switching the rule off takes its block out, even with no route changing")
        rm.config.rules.remove(at: 0)
        await rm.applyAllRoutes()
        XCTAssertTrue(kernel.blocks.isEmpty)
        XCTAssertTrue(rm.ruleBlocks.isEmpty)
    }

    func testARuleMovedFromBlockToDirectKeepsItsNewRoute() async {
        await rm.applyAllRoutes()
        rm.config.rules[1].routeId = direct.id    // 198.51.100.9: block -> Direct
        await rm.applyAllRoutes()
        XCTAssertTrue(kernel.base.installed.contains("198.51.100.9"), "the route that replaced the block is still there")
        XCTAssertFalse(kernel.blocks.contains("198.51.100.9"))
        XCTAssertEqual(rm.ruleBlocks.map(\.destination), ["203.0.113.0/24"])
        XCTAssertEqual(rm.activeRoutes.filter { $0.destination == "198.51.100.9" }.count, 1)
    }

    func testARuleMovedFromDirectToBlockIsBlockedNotRemovedByTheCleanup() async {
        await rm.applyAllRoutes()
        XCTAssertTrue(kernel.base.installed.contains("198.51.100.77"))
        rm.config.rules[2].routeId = block.id     // 198.51.100.77: Direct -> block
        await rm.applyAllRoutes()
        XCTAssertTrue(kernel.blocks.contains("198.51.100.77"), "the stale-route cleanup did not take the new block")
        XCTAssertFalse(kernel.base.installed.contains("198.51.100.77"))
    }

    func testABlockTheHelperRefusesIsTriedAgainOnTheNextApply() async {
        kernel.failBlocks = ["198.51.100.9"]
        await rm.applyAllRoutes()
        XCTAssertEqual(kernel.blocks, ["203.0.113.0/24"])
        XCTAssertEqual(rm.ruleBlocks.map(\.destination), ["203.0.113.0/24"], "a block that did not land is not recorded")
        kernel.failBlocks = []
        await rm.applyAllRoutes()
        XCTAssertEqual(kernel.blocks, ["203.0.113.0/24", "198.51.100.9"])
    }

    // MARK: - Teardown

    func testRemoveAllRoutesTakesTheBlocksOutToo() async {
        await rm.applyAllRoutes()
        await rm.removeAllRoutes()
        XCTAssertTrue(kernel.blocks.isEmpty, "a mode switch, a pause, Remove All Routes or a quit leaves no block behind")
        XCTAssertTrue(kernel.base.installed.isEmpty)
        XCTAssertTrue(rm.ruleBlocks.isEmpty)
    }

    func testAVPNDropKeepsTheBlocks() async {
        await rm.applyAllRoutes()
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        XCTAssertEqual(kernel.blocks, ["203.0.113.0/24", "198.51.100.9"], "a block is a block whether the VPN is up or not")
        XCTAssertEqual(rm.ruleBlocks.count, 2)
    }

    func testTheVPNReturningDoesNotReleaseThem() async {
        await rm.applyAllRoutes()
        rm.isVPNConnected = true
        await rm.releaseBlocksIfNoApplyComing(applyPending: false)
        await rm.releaseBlocksIfUnwanted()
        XCTAssertEqual(kernel.blocks.count, 2, "VPN Only's release rules do not apply to rule blocks")
    }

    func testAFailedReleaseKeepsTheRecordSoItCanBeRemovedLater() async {
        await rm.applyAllRoutes()
        let working = rm.removeRoutesBatchOverrideForTests
        rm.removeRoutesBatchOverrideForTests = { dests in (0, dests.count, dests, "refused") }
        await rm.removeAllRoutes()
        XCTAssertEqual(rm.ruleBlocks.count, 2, "the record of what is still installed is kept")
        rm.removeRoutesBatchOverrideForTests = working
        await rm.removeAllRoutes()
        XCTAssertTrue(kernel.blocks.isEmpty)
        XCTAssertTrue(rm.ruleBlocks.isEmpty)
    }

    // MARK: - Care

    func testNothingIsBlockedWhilePausedOrWithoutTheHelper() async {
        HelperManager.shared.helperState = .missing
        rm.addBlockRoutesBatchOverrideForTests = nil
        await rm.applyRuleBlocks([block("203.0.113.0/24", "x")])
        XCTAssertTrue(rm.ruleBlocks.isEmpty)
    }

    func testABlockThatWouldCutOffTheMacIsLeftOut() async {
        rm.localGateway = "192.168.1.1"
        rm.vpnGateway = "10.0.0.1"
        await rm.applyRuleBlocks([block("192.168.1.0/24", "lan"), block("192.168.1.1", "gw"), block("10.0.0.1", "vpn"),
                                  block("1.1.1.0/24", "dns"), block("203.0.113.0/24", "ok")])
        XCTAssertEqual(kernel.blocks, ["203.0.113.0/24"], "the gateway, the VPN's and a DNS server's ranges are refused")
        XCTAssertEqual(rm.ruleBlocks.map(\.destination), ["203.0.113.0/24"])
        rm.vpnGateway = nil
    }

    func testABatchThatTimesOutStaysOwnedSoItCanBeReleased() async {
        rm.addBlockRoutesBatchOverrideForTests = { _ in (0, 0, [], "timed out") }
        defer { rm.addBlockRoutesBatchOverrideForTests = nil }
        await rm.applyRuleBlocks([block("203.0.113.0/24", "r")])
        XCTAssertEqual(rm.ruleBlocks.map(\.destination), ["203.0.113.0/24"], "the helper may still install it, so it is ours")
    }

    func testABatchThatFinishesAfterATeardownIsReleased() async {
        let manager = rm
        rm.addBlockRoutesBatchOverrideForTests = { destinations in
            await manager.releaseRuleBlocks(reason: "teardown while the batch is out")
            return (destinations.count, 0, [], nil)
        }
        defer { rm.addBlockRoutesBatchOverrideForTests = nil }
        await rm.applyRuleBlocks([block("203.0.113.0/24", "r")])
        XCTAssertTrue(rm.ruleBlocks.isEmpty, "nothing is left listed after the teardown")
    }

    func testTheDNSServersInUseAreProtectedToo() {
        XCTAssertTrue(RouteManager.address(in: ["9.9.9.9"], isCoveredBy: "9.9.9.0/24"))
    }

    func testTheRowCountsTheAddressesItBlocks() async {
        await rm.applyAllRoutes()
        let rule = rm.config.rules[0]
        XCTAssertEqual(rm.ruleBlockCount(forPattern: rule.pattern), 1)
        XCTAssertEqual(rm.ruleBlockCount(forPattern: "nothing"), 0)
    }
}
