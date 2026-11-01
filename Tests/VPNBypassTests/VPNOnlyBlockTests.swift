// VPNOnlyBlockTests.swift
// VPN Only can hold its listed addresses back with blocks (reject routes) while the VPN is
// down, instead of letting the listed sites load over the normal connection (idea 7). Three
// layers:
//   1. the kernel side: the block message, and the install step that replaces a block, which
//      a plain RTM_CHANGE cannot do (it keeps RTF_REJECT, measured on macOS 26.6);
//   2. the app's block lifecycle against a fake kernel: drop, reconnect, quit, mode switch,
//      the setting, Open them directly, an entry taken off the list;
//   3. the reconnect paths that bit before: #61 (a preempted apply), #67 (the startup sweep),
//      #106 (the settle gate), and the 1.5 s flap recheck, driven through checkVPNStatus.

import XCTest
import Darwin
@testable import VPNBypassCore

// MARK: - Kernel side

final class VPNOnlyBlockKernelTests: XCTestCase {

    private func header(_ data: Data) -> rt_msghdr {
        data.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
    }

    func testBlockSpecIsARejectRouteToLoopbackTaggedOurs() throws {
        let host = RouteKernel.blockSpec(destination: "203.0.113.7")
        XCTAssertFalse(host.isNetwork)
        XCTAssertTrue(host.reject)
        XCTAssertEqual(host.gateway, .address("127.0.0.1"))
        let msg = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 1, spec: host))
        let flags = header(msg).rtm_flags
        XCTAssertNotEqual(flags & RTF_REJECT, 0, "a block must reject")
        XCTAssertNotEqual(flags & RTF_PROTO1, 0, "a block must carry our tag, or the startup sweep cannot find it")
        XCTAssertNotEqual(flags & RTF_HOST, 0)
        XCTAssertNotEqual(flags & RTF_GATEWAY, 0, "route(8) writes UGHRS for -reject via 127.0.0.1")

        XCTAssertTrue(RouteKernel.blockSpec(destination: "10.20.0.0/16").isNetwork)
        XCTAssertFalse(RouteKernel.blockSpec(destination: "10.20.0.1/32").isNetwork)
    }

    func testOrdinaryRoutesStillCarryNoRejectFlag() throws {
        let spec = RouteKernel.Spec(destination: "203.0.113.7", gateway: .address("10.0.0.1"), isNetwork: false)
        let msg = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 1, spec: spec))
        XCTAssertEqual(header(msg).rtm_flags & RTF_REJECT, 0)
    }

    private func entry(_ dest: UInt32, gw: UInt32, flags: Int32) -> RouteKernel.KernelRoute {
        RouteKernel.KernelRoute(destination: dest, prefix: nil, gatewayAddress: gw,
                                gatewayInterfaceIndex: nil, flags: flags)
    }

    /// The restore. A block left by the drop is what the reconnect apply finds at a listed
    /// address. Before, the helper's index left reject routes out, so the install went ADD,
    /// got EEXIST and fell back to RTM_CHANGE, which keeps RTF_REJECT: the route came back
    /// pointing at the tunnel and still refused every packet.
    func testAnInstallOverOurBlockReplacesIt() {
        let block = entry(0xCB007107, gw: 0x7F000001, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC | RTF_REJECT | RTF_PROTO1)
        let index = RouteKernel.installIndex([block])
        XCTAssertEqual(index["203.0.113.7"], block, "our block must be visible to the install")
        let spec = RouteKernel.Spec(destination: "203.0.113.7", gateway: .address("10.0.0.1"), isNetwork: false)
        XCTAssertEqual(RouteKernel.installStep(current: index["203.0.113.7"], spec: spec), .replaceBlock)
        // Even a block whose gateway happens to equal the wanted one is not "already correct".
        let same = RouteKernel.Spec(destination: "203.0.113.7", gateway: .address("127.0.0.1"), isNetwork: false)
        XCTAssertEqual(RouteKernel.installStep(current: block, spec: same), .replaceBlock)
    }

    /// Someone else's reject route is not ours to replace: it stays out of the index, as before.
    func testAnotherProgramsRejectRouteIsLeftAlone() {
        let foreign = entry(0xCB007107, gw: 0x7F000001, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC | RTF_REJECT)
        XCTAssertNil(RouteKernel.installIndex([foreign])["203.0.113.7"])
    }

    /// A real route at the same destination wins over a block in the index, and the ordinary
    /// steps are unchanged.
    func testOrdinaryStepsAreUnchanged() {
        let live = entry(0xCB007107, gw: 0x0A000001, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC | RTF_PROTO1)
        let block = entry(0xCB007107, gw: 0x7F000001, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC | RTF_REJECT | RTF_PROTO1 | RTF_IFSCOPE)
        let index = RouteKernel.installIndex([live, block])
        XCTAssertEqual(index["203.0.113.7"], live)
        let toVPN = RouteKernel.Spec(destination: "203.0.113.7", gateway: .address("10.0.0.1"), isNetwork: false)
        let elsewhere = RouteKernel.Spec(destination: "203.0.113.7", gateway: .address("10.0.0.2"), isNetwork: false)
        XCTAssertEqual(RouteKernel.installStep(current: live, spec: toVPN), .alreadyCorrect)
        XCTAssertEqual(RouteKernel.installStep(current: live, spec: elsewhere), .change)
        XCTAssertEqual(RouteKernel.installStep(current: nil, spec: toVPN), .add)
    }

    /// A block replaces only our own route. A host route another program wrote (a VPN client
    /// pinning its server to the physical interface) is refused: blocking it would keep the
    /// VPN from coming back. Scoped and cloned entries do not collide with the block's add.
    func testABlockNeverReplacesAnotherProgramsRoute() {
        let ours = entry(0xCB007107, gw: 0x0A000001, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC | RTF_PROTO1)
        let pin = entry(0xCB007107, gw: 0xC0A80101, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC)
        let scoped = entry(0xCB007107, gw: 0xC0A80101, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC | RTF_IFSCOPE)
        XCTAssertTrue(RouteKernel.blockMayReplace(table: [], key: "203.0.113.7"))
        XCTAssertTrue(RouteKernel.blockMayReplace(table: [ours], key: "203.0.113.7"))
        XCTAssertFalse(RouteKernel.blockMayReplace(table: [pin], key: "203.0.113.7"))
        XCTAssertTrue(RouteKernel.blockMayReplace(table: [scoped, ours], key: "203.0.113.7"))
        XCTAssertTrue(RouteKernel.blockMayReplace(table: [pin], key: "203.0.113.8"))
    }

    /// #67: a block left by a killed run is swept at the next start like any route of ours.
    func testStartupSweepTakesLeftoverBlocks() {
        let block = entry(0xCB007107, gw: 0x7F000001, flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC | RTF_REJECT | RTF_PROTO1)
        XCTAssertEqual(RouteManager.orphanedDestinations(table: [block], desired: []), ["203.0.113.7"])
    }

    func testDisconnectNotificationNamesTheBlocks() {
        let body = NotificationManager.disconnectedBody(wasInterface: "utun4", routesKept: 0, routesFailed: 0, addressesBlocked: 3)
        XCTAssertTrue(body.contains("3 listed address(es) are blocked until the VPN returns"), body)
        XCTAssertFalse(body.contains("Nothing is routed now"))
        // A failed removal still outranks it.
        let failed = NotificationManager.disconnectedBody(wasInterface: "utun4", routesKept: 0, routesFailed: 1, addressesBlocked: 3)
        XCTAssertTrue(failed.contains("removing them failed"))
    }

    func testTheSettingIsOffByDefaultAndSurvivesARoundTrip() throws {
        XCTAssertFalse(RouteManager.Config().blockListedWhenVPNDown)
        let old = try JSONDecoder().decode(RouteManager.Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.blockListedWhenVPNDown, "a config written before the setting decodes with it off")
        var on = RouteManager.Config()
        on.blockListedWhenVPNDown = true
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(back.blockListedWhenVPNDown)
    }
}

// MARK: - App lifecycle against a fake kernel

/// The fake kernel with blocks: a block replaces the destination's route, an install over a
/// block replaces it, and a removal by destination takes either.
final class BlockingKernel {
    let base: FakeKernel
    var blocks: Set<String> = []
    var blockCalls: [[String]] = []
    var failBlocks: Set<String> = []

    init(installed: Set<String>) { base = FakeKernel(installed: installed) }

    var everything: Set<String> { base.installed.union(blocks) }

    @MainActor
    func attach(to rm: RouteManager) {
        base.attach(to: rm)
        rm.removeRoutesBatchOverrideForTests = { [unowned self] dests in
            for d in dests { self.blocks.remove(d) }
            return self.base.remove(dests.filter { self.base.installed.contains($0) })
        }
        rm.addRoutesBatchOverrideForTests = { [unowned self] routes in
            for r in routes { self.blocks.remove(r.destination) }
            return self.base.add(routes)
        }
        rm.addBlockRoutesBatchOverrideForTests = { [unowned self] dests in
            self.blockCalls.append(dests)
            let ok = dests.filter { !self.failBlocks.contains($0) }
            for d in ok {
                self.base.installed.remove(d)
                self.blocks.insert(d)
            }
            let failed = dests.filter { self.failBlocks.contains($0) }
            return (ok.count, failed.count, failed, failed.isEmpty ? nil : "refused")
        }
    }

    @MainActor
    static func detach(from rm: RouteManager) {
        FakeKernel.detach(from: rm)
        rm.addBlockRoutesBatchOverrideForTests = nil
        rm.detectVPNInterfaceOverrideForTests = nil
    }
}

@MainActor
final class VPNOnlyBlockLifecycleTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var savedConfig: RouteManager.Config!
    private var savedConnected = false
    private var kernel: BlockingKernel!

    private let catchAlls = ClassicRouteCompiler.bypassAllCatchAlls.sorted()
    private let listed = ["203.0.113.1", "203.0.113.2", "198.51.100.9"]

    override func setUp() async throws {
        savedConfig = rm.config
        savedConnected = rm.isVPNConnected
        var cfg = rm.config
        cfg.routingMode = .vpnOnly
        cfg.blockListedWhenVPNDown = true
        cfg.manageHostsFile = false
        cfg.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                              DomainEntry(domain: "git.example.com", enabled: true)]
        rm.config = cfg
        rm.resetShutdownStateForTests()
        rm.pendingKernelAdds = []
        rm.blockedRoutes = []
        kernel = BlockingKernel(installed: Set(catchAlls + listed))
        kernel.attach(to: rm)
        rm.activeRoutes = catchAlls.map { route($0, "192.168.1.1", "VPN Only catch-all") }
            + [route("203.0.113.1", "10.0.0.1", "intranet.example.com"),
               route("203.0.113.2", "10.0.0.1", "intranet.example.com"),
               route("198.51.100.9", "10.0.0.1", "git.example.com")]
    }

    override func tearDown() async throws {
        BlockingKernel.detach(from: rm)
        rm.activeRoutes = []
        rm.blockedRoutes = []
        rm.pendingKernelAdds = []
        rm.config = savedConfig
        rm.isVPNConnected = savedConnected
        rm.resetShutdownStateForTests()
    }

    private func route(_ d: String, _ gw: String, _ source: String) -> RouteManager.ActiveRoute {
        .init(destination: d, gateway: gw, source: source, timestamp: Date())
    }

    // The drop

    func testADropBlocksTheListedAddressesAndRemovesTheCatchAlls() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        XCTAssertEqual(kernel.blockCalls, [listed.sorted()], "the listed addresses, and only them, are blocked")
        XCTAssertEqual(kernel.blocks, Set(listed))
        XCTAssertTrue(kernel.base.installed.isEmpty, "the catch-alls go")
        XCTAssertTrue(rm.activeRoutes.isEmpty, "a block is not a route: nothing reads as routed")
        XCTAssertEqual(rm.blockedDestinations, Set(listed))
        XCTAssertEqual(rm.blockedSiteCount, 2, "two entries hold the three addresses")
    }

    func testWithTheSettingOffADropRemovesEverythingAsBefore() async {
        rm.config.blockListedWhenVPNDown = false
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        XCTAssertTrue(kernel.blockCalls.isEmpty)
        XCTAssertTrue(kernel.everything.isEmpty)
        XCTAssertTrue(rm.blockedRoutes.isEmpty)
    }

    func testOutsideVPNOnlyNothingIsBlocked() async {
        rm.config.routingMode = .custom
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        XCTAssertTrue(kernel.blockCalls.isEmpty)
    }

    /// A block the helper refused leaves its address with no route at all, as without the
    /// setting: never a route still pointing at the dead tunnel.
    func testAnAddressThatCannotBeBlockedIsRemoved() async {
        kernel.failBlocks = ["198.51.100.9"]
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        XCTAssertEqual(kernel.blocks, ["203.0.113.1", "203.0.113.2"])
        XCTAssertFalse(kernel.everything.contains("198.51.100.9"))
        XCTAssertFalse(rm.blockedDestinations.contains("198.51.100.9"))
        XCTAssertTrue(rm.activeRoutes.isEmpty)
    }

    /// #61: an address an in-flight apply pushed but has not committed is blocked too, never
    /// deleted by the teardown, and the apply's abort does not delete the block either.
    func testAnInFlightApplysAddressIsBlockedAndSurvivesItsAbort() async {
        let epoch = rm.routeEpochForTests
        kernel.base.installed.insert("192.0.2.44")
        rm.pendingKernelAdds = ["192.0.2.44", catchAlls[0]]
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        XCTAssertTrue(kernel.blocks.contains("192.0.2.44"))

        let attempted: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = [
            (destination: "192.0.2.44", gateway: "10.0.0.1", isNetwork: false, source: "intranet.example.com"),
            (destination: catchAlls[0], gateway: "192.168.1.1", isNetwork: true, source: "VPN Only catch-all"),
        ]
        let committed = await rm.commitAppliedRoutes(
            routesToAdd: attempted,
            allSourceEntries: attempted.map { ($0.destination, $0.gateway, $0.source) },
            batchFailedDests: [], epoch: epoch, logLabel: "")
        XCTAssertFalse(committed, "the drop's teardown preempted the apply")
        XCTAssertTrue(kernel.blocks.contains("192.0.2.44"), "#61 unstrand must not delete a block")
        XCTAssertFalse(kernel.base.installed.contains(catchAlls[0]), "the catch-all it pushed is still unstranded")
    }

    // The return

    func testTheReconnectApplyReplacesTheBlocksAndRemovesTheRest() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        rm.isVPNConnected = true
        // The apply's batch add goes over two blocks (the helper replaces them); one address
        // is no longer in DNS.
        let back: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = [
            (destination: "203.0.113.1", gateway: "10.0.0.1", isNetwork: false, source: "intranet.example.com"),
            (destination: "198.51.100.9", gateway: "10.0.0.1", isNetwork: false, source: "git.example.com"),
        ]
        _ = await rm.addRoutesBatchTracked(routes: back.map { ($0.destination, $0.gateway, $0.isNetwork) })
        let committed = await rm.commitAppliedRoutes(
            routesToAdd: back, allSourceEntries: back.map { ($0.destination, $0.gateway, $0.source) },
            batchFailedDests: [], epoch: rm.routeEpochForTests, logLabel: "")
        XCTAssertTrue(committed)
        XCTAssertTrue(rm.blockedRoutes.isEmpty)
        XCTAssertTrue(kernel.blocks.isEmpty, "203.0.113.2 is no longer listed, its block goes")
        XCTAssertEqual(kernel.base.installed, ["203.0.113.1", "198.51.100.9"])
    }

    /// #106: while a settle-gated apply is pending (the settle wait, or held back by strikes)
    /// the blocks stay: no write burst into the fragile window, and no gap for the sites.
    func testBlocksWaitForAPendingApply() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        rm.isVPNConnected = true
        rm.isLoading = false
        await rm.releaseBlocksIfNoApplyComing(applyPending: true)
        XCTAssertEqual(kernel.blocks, Set(listed))
        XCTAssertEqual(rm.blockedDestinations, Set(listed))
    }

    /// With no apply coming (auto-apply off, or it was skipped or refused), blocks go once the
    /// VPN is up: holding them would only keep the sites unreachable.
    func testBlocksGoWhenNoApplyIsComing() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        await rm.releaseBlocksIfNoApplyComing(applyPending: false)
        XCTAssertEqual(kernel.blocks, Set(listed), "not while the VPN is still down")
        rm.isVPNConnected = true
        rm.isLoading = false
        await rm.releaseBlocksIfNoApplyComing(applyPending: false)
        XCTAssertTrue(kernel.blocks.isEmpty)
        XCTAssertTrue(rm.blockedRoutes.isEmpty)
    }

    // The ways out

    func testQuitRemovesTheBlocks() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        await rm.cleanupOnQuit()
        XCTAssertTrue(kernel.everything.isEmpty)
        XCTAssertTrue(rm.blockedRoutes.isEmpty)
    }

    /// A time-capped quit spends its first write on the catch-alls, not on the blocks.
    func testTeardownRemovesTheCatchAllsBeforeTheBlocks() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        kernel.base.installed.formUnion(catchAlls)
        rm.activeRoutes = catchAlls.map { route($0, "192.168.1.1", "VPN Only catch-all") }
        var order: [[String]] = []
        let inner = rm.removeRoutesBatchOverrideForTests
        rm.removeRoutesBatchOverrideForTests = { dests in
            order.append(dests.sorted())
            return await inner!(dests)
        }
        await rm.removeAllRoutes()
        XCTAssertEqual(order.first, catchAlls, "the catch-alls go first")
        XCTAssertEqual(order.last, listed.sorted(), "the blocks go after them")
        XCTAssertTrue(kernel.everything.isEmpty)
    }

    func testOpenThemDirectlyRemovesTheBlocks() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        await rm.releaseBlocks(reason: "Open them directly")
        XCTAssertTrue(kernel.blocks.isEmpty)
        XCTAssertTrue(rm.blockedRoutes.isEmpty)
    }

    func testLeavingVPNOnlyOrTurningTheSettingOffRemovesTheBlocks() async {
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        await rm.releaseBlocksIfUnwanted()
        XCTAssertEqual(kernel.blocks, Set(listed), "nothing changed, the blocks stay")
        rm.config.blockListedWhenVPNDown = false
        await rm.releaseBlocksIfUnwanted()
        XCTAssertTrue(kernel.blocks.isEmpty)

        rm.config.blockListedWhenVPNDown = true
        rm.activeRoutes = listed.map { route($0, "10.0.0.1", "git.example.com") }
        kernel.base.installed = Set(listed)
        await rm.tearDownAfterDrop()
        rm.config.routingMode = .bypass
        await rm.releaseBlocksIfUnwanted()
        XCTAssertTrue(kernel.blocks.isEmpty)
    }

    /// An entry taken off the list while the VPN is down loses its blocks, except an address
    /// another blocked entry shares.
    func testAnEntryTakenOffTheListLosesItsBlocks() async {
        rm.activeRoutes.append(route("198.51.100.9", "10.0.0.1", "intranet.example.com"))
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        let entry = rm.config.inverseDomains[0]
        await rm.removeInverseDomain(entry)?.value
        XCTAssertEqual(kernel.blocks, ["198.51.100.9"], "git.example.com still holds the shared address")
        XCTAssertEqual(rm.blockedSiteCount, 1)
    }

    /// An entry disabled (or imported away) while the VPN is down loses its blocks; a shared
    /// address keeps the block another listed entry holds.
    func testADisabledEntryLosesItsBlocks() async {
        rm.activeRoutes.append(route("198.51.100.9", "10.0.0.1", "intranet.example.com"))
        rm.isVPNConnected = false
        await rm.tearDownAfterDrop()
        rm.config.inverseDomains[0].enabled = false
        await rm.releaseBlocksIfUnwanted()
        XCTAssertEqual(kernel.blocks, ["198.51.100.9"], "git.example.com still holds the shared address")
        XCTAssertEqual(rm.blockedRoutes.map(\.source), ["git.example.com"])
        rm.config.inverseDomains = []
        await rm.releaseBlocksIfUnwanted()
        XCTAssertTrue(kernel.blocks.isEmpty)
        XCTAssertTrue(rm.blockedRoutes.isEmpty)
    }

    /// The setting turned off while the block batch was out: its blocks do not outlive it.
    func testTheSettingTurnedOffDuringTheBatchLeavesNoBlocks() async {
        rm.isVPNConnected = false
        let inner = rm.addBlockRoutesBatchOverrideForTests!
        rm.addBlockRoutesBatchOverrideForTests = { [unowned self] dests in
            let r = await inner(dests)
            self.rm.config.blockListedWhenVPNDown = false
            await self.rm.releaseBlocksIfUnwanted()
            return r
        }
        await rm.tearDownAfterDrop()
        XCTAssertTrue(kernel.blocks.isEmpty)
        XCTAssertTrue(rm.blockedRoutes.isEmpty)
    }

    // The flap recheck, through checkVPNStatus

    /// An interface that is back within the 1.5 s recheck is no drop: nothing is blocked and
    /// nothing removed.
    func testAFlapBlocksNothing() async {
        rm.isVPNConnected = true
        rm.vpnInterface = "utun4"
        rm.vpnGateway = nil
        var calls = 0
        rm.detectVPNInterfaceOverrideForTests = {
            calls += 1
            return calls == 1 ? (false, nil, nil) : (true, "utun4", .wireGuard)
        }
        let before = Set(rm.activeRoutes.map(\.destination))
        await rm.checkVPNStatus()
        XCTAssertEqual(calls, 2, "the recheck ran")
        XCTAssertTrue(rm.isVPNConnected)
        XCTAssertTrue(kernel.blockCalls.isEmpty)
        XCTAssertEqual(Set(rm.activeRoutes.map(\.destination)), before)
    }

    /// The same pass with the interface still gone after the recheck is a drop: the listed
    /// addresses are blocked.
    func testACommittedDropBlocks() async {
        rm.isVPNConnected = true
        rm.vpnInterface = "utun4"
        rm.vpnGateway = nil
        rm.detectVPNInterfaceOverrideForTests = { (false, nil, nil) }
        await rm.checkVPNStatus()
        XCTAssertFalse(rm.isVPNConnected)
        XCTAssertEqual(kernel.blockCalls, [listed.sorted()])
        XCTAssertEqual(kernel.blocks, Set(listed))
        XCTAssertTrue(kernel.base.installed.isEmpty)
    }
}
