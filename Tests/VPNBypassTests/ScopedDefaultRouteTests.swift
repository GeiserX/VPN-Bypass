// ScopedDefaultRouteTests.swift
// Per-app routing's scoped default route on the physical interface (R12): when the app wants it,
// what the helper writes for a table, the argument checks at the privileged boundary, the
// routing-socket message, and the engine asking for it before it pushes a policy that claims.

import Darwin
import XCTest
@testable import VPNBypassCore
import VPNBypassPolicy

final class ScopedDefaultRouteTests: XCTestCase {
    private typealias KR = RouteKernel.KernelRoute
    private let router = "192.168.1.1"
    private var routerValue: UInt32 { RouteKernel.ipv4ToUInt32(router)! }
    private let en0: UInt16 = 6
    private let en1: UInt16 = 7
    private let utun: UInt16 = 27

    /// The mini's table with a wg-quick tunnel up (evidence, 2026-11-04): en0 primary with an
    /// unscoped default only, en1 with its scoped default, the tunnel's half routes.
    private func vpnTable() -> [KR] {
        [
            KR(destination: 0, prefix: 1, gatewayAddress: nil, gatewayInterfaceIndex: utun,
               flags: RTF_UP | RTF_STATIC, interfaceIndex: utun),
            KR(destination: 0x8000_0000, prefix: 1, gatewayAddress: nil, gatewayInterfaceIndex: utun,
               flags: RTF_UP | RTF_STATIC, interfaceIndex: utun),
            KR(destination: 0, prefix: 0, gatewayAddress: routerValue, gatewayInterfaceIndex: nil,
               flags: RTF_UP | RTF_GATEWAY | RTF_STATIC, interfaceIndex: en0),
            KR(destination: 0, prefix: 0, gatewayAddress: routerValue, gatewayInterfaceIndex: nil,
               flags: RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_IFSCOPE, interfaceIndex: en1),
        ]
    }

    private func ours(on index: UInt16, via gateway: String? = nil) -> KR {
        KR(destination: 0, prefix: 0, gatewayAddress: RouteKernel.ipv4ToUInt32(gateway ?? router), gatewayInterfaceIndex: nil,
           flags: RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_IFSCOPE | RTF_PROTO1, interfaceIndex: index)
    }

    private var request: ScopedDefaultRequest { ScopedDefaultRequest(interface: "en0", gateway: router) }

    // MARK: - When the app wants it

    func testWantedOnlyWhileTheEngineClaimsWithTheVPNUpAndTheNetworkKnown() {
        XCTAssertEqual(ScopedDefaultRoute.want(engineClaims: true, vpnConnected: true, interface: "en0", gateway: router), request)
        XCTAssertNil(ScopedDefaultRoute.want(engineClaims: false, vpnConnected: true, interface: "en0", gateway: router),
                     "engine off, or a policy that claims nothing (Pause, VPN Only, kill switch)")
        XCTAssertNil(ScopedDefaultRoute.want(engineClaims: true, vpnConnected: false, interface: "en0", gateway: router),
                     "the VPN went down")
        XCTAssertNil(ScopedDefaultRoute.want(engineClaims: true, vpnConnected: true, interface: nil, gateway: router))
        XCTAssertNil(ScopedDefaultRoute.want(engineClaims: true, vpnConnected: true, interface: "en0", gateway: nil))
        XCTAssertNil(ScopedDefaultRoute.want(engineClaims: true, vpnConnected: true, interface: "utun4", gateway: router),
                     "never scoped to a tunnel")
    }

    // MARK: - Arguments the helper takes

    func testOnlyPhysicalEnInterfaceNamesPass() {
        for ok in ["en0", "en1", "en12", "en123"] { XCTAssertTrue(ScopedDefaultRoute.isValidInterface(ok), ok) }
        for bad in ["", "en", "en1234", "utun3", "ipsec0", "ppp0", "bridge0", "lo0", "en0 ", "en0;rm", "en-1", "EN0", "en٣"] {
            XCTAssertFalse(ScopedDefaultRoute.isValidInterface(bad), bad)
        }
    }

    func testOnlyUnicastDottedIPv4GatewaysPass() {
        for ok in ["192.168.1.1", "10.0.0.1", "172.16.0.254", "100.64.0.1"] { XCTAssertTrue(ScopedDefaultRoute.isValidGateway(ok), ok) }
        for bad in ["", "fe80::1", "::1", "192.168.010.1", "192.168.1", "192.168.1.1.1", "256.1.1.1", "0.0.0.0",
                    "127.0.0.1", "169.254.1.1", "224.0.0.1", "255.255.255.255", "192.168.1.1/24", " 192.168.1.1", "router.local"] {
            XCTAssertFalse(ScopedDefaultRoute.isValidGateway(bad), bad)
        }
    }

    // MARK: - What the helper writes

    func testAddsOnlyWhenTheInterfaceHasNoScopedDefault() {
        let plan = ScopedDefaultRoute.plan(request, interfaceIndex: en0, table: vpnTable())
        XCTAssertEqual(plan, .init(delete: [], add: true, outcome: .added))
    }

    func testKeepsOursWhenItIsAlreadyThere() {
        let plan = ScopedDefaultRoute.plan(request, interfaceIndex: en0, table: vpnTable() + [ours(on: en0)])
        XCTAssertEqual(plan, .init(delete: [], add: false, outcome: .kept))
    }

    func testAddsNothingWhenTheSystemKeepsOne() {
        // A VPN that becomes the primary service (GlobalProtect) leaves en1-style scoped defaults on
        // every physical interface: ask for en1 here.
        let plan = ScopedDefaultRoute.plan(ScopedDefaultRequest(interface: "en1", gateway: router), interfaceIndex: en1, table: vpnTable())
        XCTAssertEqual(plan, .init(delete: [], add: false, outcome: .systemRoute))
        XCTAssertTrue(plan.outcome.interfaceHasRoute)
    }

    func testRefusesWithoutTheInterfacesOwnDefaultThroughThatRouter() {
        let wrongRouter = ScopedDefaultRoute.plan(ScopedDefaultRequest(interface: "en0", gateway: "192.168.1.9"), interfaceIndex: en0, table: vpnTable())
        XCTAssertEqual(wrongRouter.outcome, .refused)
        XCTAssertFalse(wrongRouter.add)
        let noDefault = ScopedDefaultRoute.plan(request, interfaceIndex: en0, table: Array(vpnTable().dropLast(2)))
        XCTAssertEqual(noDefault.outcome, .refused)
        let gone = ScopedDefaultRoute.plan(request, interfaceIndex: nil, table: vpnTable())
        XCTAssertEqual(gone.outcome, .refused, "an interface that does not exist")
        XCTAssertFalse(gone.add)
    }

    func testANewRouterOrInterfaceReplacesOurs() {
        let newRouter = ScopedDefaultRoute.plan(request, interfaceIndex: en0, table: vpnTable() + [ours(on: en0, via: "192.168.1.254")])
        XCTAssertEqual(newRouter, .init(delete: [en0], add: true, outcome: .added), "the stale one goes, then the add")

        // Ours on en2 (the interface it was added for went off the list) goes when en0 is asked for.
        let en2: UInt16 = 9
        var table = vpnTable() + [ours(on: en2)]
        table.append(KR(destination: 0, prefix: 0, gatewayAddress: routerValue, gatewayInterfaceIndex: nil,
                        flags: RTF_UP | RTF_GATEWAY | RTF_STATIC, interfaceIndex: en2))
        XCTAssertEqual(ScopedDefaultRoute.plan(request, interfaceIndex: en0, table: table).delete, [en2])
    }

    func testRemovalTakesOursOnlyAndNeverTheUnscopedDefaultOrTheVPNsRoutes() {
        let plan = ScopedDefaultRoute.plan(nil, interfaceIndex: nil, table: vpnTable() + [ours(on: en0)])
        XCTAssertEqual(plan, .init(delete: [en0], add: false, outcome: .removed))
        XCTAssertEqual(ScopedDefaultRoute.plan(nil, interfaceIndex: nil, table: vpnTable()),
                       .init(delete: [], add: false, outcome: .absent))
        XCTAssertEqual(ScopedDefaultRoute.ours(in: vpnTable()), [], "the system's scoped default on en1 is not ours")
    }

    func testOursStaysWhenTheInterfaceStoppedBeingPrimary() {
        // The VPN became the primary service: the unscoped default moved to the tunnel, and macOS
        // keeps a scoped default for en0, which may now be ours. Removing it could cut that VPN.
        var table = vpnTable().filter { !($0.isDefault && !$0.isScoped) }
        table.append(KR(destination: 0, prefix: 0, gatewayAddress: nil, gatewayInterfaceIndex: utun,
                        flags: RTF_UP | RTF_STATIC, interfaceIndex: utun))
        table.append(ours(on: en0))
        XCTAssertEqual(ScopedDefaultRoute.plan(nil, interfaceIndex: nil, table: table),
                       .init(delete: [], add: false, outcome: .leftInPlace))
    }

    // MARK: - The message

    func testScopedDefaultMessageCarriesIfscopeAndTheIndex() throws {
        let spec = RouteKernel.scopedDefaultSpec(interfaceIndex: en0, gateway: router)
        let add = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 1, spec: spec))
        let hdr = add.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: rt_msghdr.self) }
        XCTAssertNotEqual(hdr.rtm_flags & RTF_IFSCOPE, 0)
        XCTAssertNotEqual(hdr.rtm_flags & RTF_PROTO1, 0, "tagged ours")
        XCTAssertNotEqual(hdr.rtm_flags & RTF_GATEWAY, 0)
        XCTAssertEqual(hdr.rtm_flags & RTF_HOST, 0)
        XCTAssertEqual(hdr.rtm_index, u_short(en0))
        XCTAssertEqual(hdr.rtm_addrs, RTA_DST | RTA_GATEWAY | RTA_NETMASK)

        let parsed = try XCTUnwrap(RouteKernel.parseTable(add).first)
        XCTAssertTrue(parsed.isDefault)
        XCTAssertTrue(parsed.isScoped)
        XCTAssertTrue(parsed.isOurs)
        XCTAssertEqual(parsed.interfaceIndex, en0)
        XCTAssertEqual(parsed.gatewayAddress, routerValue)
        XCTAssertEqual(ScopedDefaultRoute.ours(in: [parsed]), [parsed])

        let delete = try XCTUnwrap(RouteKernel.message(type: RTM_DELETE, seq: 2, spec: spec))
        let dh = delete.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: rt_msghdr.self) }
        XCTAssertNotEqual(dh.rtm_flags & RTF_IFSCOPE, 0, "the delete takes the scoped route, not the unscoped default")
        XCTAssertEqual(dh.rtm_index, u_short(en0))
    }

    func testOrdinaryRoutesStayUnscoped() throws {
        let msg = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 1, spec:
            .init(destination: "203.0.113.7", gateway: .address(router), isNetwork: false)))
        let hdr = msg.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: rt_msghdr.self) }
        XCTAssertEqual(hdr.rtm_flags & RTF_IFSCOPE, 0)
        XCTAssertEqual(hdr.rtm_index, 0)
    }

    /// The live table: every default route reads as one, and the reading of rtm_index matches
    /// the interface `route -n get default` names for the unscoped one.
    func testLiveDefaultRoutesCarryTheirInterface() throws {
        let table = try XCTUnwrap(RouteKernel.currentTable())
        guard let lookup = RouteKernel.lookup("default"), let name = lookup.interfaceName else {
            throw XCTSkip("no default route on this Mac")
        }
        let index = UInt16(if_nametoindex(name))
        XCTAssertTrue(table.contains { $0.isDefault && !$0.isScoped && $0.interfaceIndex == index },
                      "the unscoped default on \(name) (index \(index))")
    }

    // MARK: - The helper call

    func testOnlyAHelperOf290OrNewerIsAsked() {
        XCTAssertEqual(HelperManager.MethodSince.scopedDefault, "2.9.0")
        XCTAssertFalse(HelperManager.helper("2.8.0", supports: HelperManager.MethodSince.scopedDefault))
        XCTAssertTrue(HelperManager.helper("2.9.0", supports: HelperManager.MethodSince.scopedDefault))
        XCTAssertTrue(HelperManager.helper(HelperConstants.helperVersion, supports: HelperManager.MethodSince.scopedDefault))
    }
}

// MARK: - The engine asks for it

@MainActor
final class ScopedDefaultEngineTests: XCTestCase {
    private var system: FakeFlowEngineSystem!
    private var engine: FlowEngineManager!
    private var enabled = false
    private var vpnUp = true
    private var input = FlowPolicyCompiler.Input(mode: .custom)
    /// Every call to the helper, in order, with the number of policies sent before it.
    private var calls: [(request: ScopedDefaultRequest?, sentBefore: Int)] = []
    private var answer: ScopedDefaultOutcome? = .added
    private var removalAnswer: ScopedDefaultOutcome? = .removed
    private let directID = UUID()

    override func setUp() async throws {
        system = FakeFlowEngineSystem()
        enabled = false
        vpnUp = true
        calls = []
        answer = .added
        removalAnswer = .removed
        input = FlowPolicyCompiler.Input(
            mode: .custom,
            processRules: [.init(id: UUID(), pattern: "com.example.App", routeID: directID, order: 0)],
            routes: [.init(id: directID, kind: .direct)],
            physicalInterface: "en0")
        let e = FlowEngineManager(system: system)
        e.inputs = { [unowned self] in self.input }
        e.isEnabled = { [unowned self] in self.enabled }
        e.saveEnabled = { [unowned self] in self.enabled = $0 }
        e.wasActivated = { false }
        e.saveActivated = { _ in }
        e.sleep = { _ in await Task.yield() }
        e.heartbeatWait = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        e.egressRouteFacts = { [unowned self] in (self.vpnUp, "192.168.1.1") }
        e.applyEgressRoute = { [unowned self] request in
            self.calls.append((request, self.system.sent.count))
            return request == nil ? self.removalAnswer : self.answer
        }
        engine = e
    }

    private func until(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    private let wanted = ScopedDefaultRequest(interface: "en0", gateway: "192.168.1.1")

    func testTheRouteGoesInBeforeTheFirstPolicyThatClaims() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        XCTAssertEqual(calls.first?.request, wanted)
        XCTAssertEqual(calls.first?.sentBefore, 0, "asked before the first push")
        XCTAssertEqual(system.sent.first.map { Array($0.egressRoutes.keys) }, ["en0"], "the extension hears the route is there")
    }

    func testTurningOffRemovesIt() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        engine.setEnabled(false)
        await until("removed") { calls.last.map { $0.request == nil } == true }
    }

    func testAModeThatClaimsNothingRemovesIt() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        input.mode = .vpnOnly
        engine.inputsChanged()
        await until("paused") { engine.state == .paused(.vpnOnly) }
        XCTAssertNil(calls.last?.request)
        XCTAssertEqual(system.sent.last?.egressRoutes, [:], "no route named while nothing is claimed")
    }

    func testTheVPNGoingDownRemovesIt() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        let before = calls.count
        vpnUp = false
        engine.inputsChanged()
        await until("removed") { calls.count > before && calls.last.map { $0.request == nil } == true }
    }

    func testANewRouterIsAskedForAtTheNextPush() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        engine.egressRouteFacts = { (true, "192.168.2.1") }
        engine.inputsChanged()
        await until("asked again") { calls.last?.request == ScopedDefaultRequest(interface: "en0", gateway: "192.168.2.1") }
    }

    func testAnEngineThatIsOffSendsOneRemovalNotOnePerChange() async {
        engine.inputsChanged()
        await until("one removal") { calls.count == 1 }
        engine.inputsChanged()
        engine.inputsChanged()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls.count, 1, "the helper already said nothing of ours is there")
        XCTAssertNil(calls[0].request)
        await engine.helperRestarted()
        XCTAssertEqual(calls.count, 2, "a new helper is asked again")
    }

    func testARestartedHelperGetsTheRouteBackWithTheNextPush() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        let first = system.sent.last?.egressRoutes
        answer = .kept
        engine.requestPush(force: true)
        await until("a heartbeat") { system.sent.count >= 2 }
        XCTAssertEqual(system.sent.last?.egressRoutes, first, "a route that stayed keeps its stamp")
        let before = calls.count
        answer = .added
        await engine.helperRestarted()
        await until("asked again") { calls.count > before && calls.last?.request == wanted && system.sent.count >= 3 }
        await until("pushed with a new stamp") { system.sent.last?.egressRoutes != first }
        XCTAssertEqual(system.sent.last.map { Array($0.egressRoutes.keys) }, ["en0"])
        XCTAssertEqual(system.sent.last?.newEgressRoutes(since: system.sent[1]), ["en0"],
                       "the extension forgets the failures counted while the route was gone")
    }

    func testARouteTheHelperCouldNotAddIsNotNamed() async {
        answer = .refused
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        XCTAssertEqual(system.sent.last?.egressRoutes, [:])
        answer = nil
        engine.requestPush(force: true)
        await until("pushed") { system.sent.count >= 2 }
        XCTAssertEqual(system.sent.last?.egressRoutes, [:], "an older helper (nil) adds nothing")
    }

    func testACrashedSessionRemovesItUntilTheRestartAsksAgain() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        let before = calls.count
        system.connectOnStart = false
        system.crash()
        await until("removed while nothing claims") { calls.dropFirst(before).contains { $0.request == nil } }
    }

    func testAFailedRemovalIsSentAgain() async {
        removalAnswer = .failed
        engine.inputsChanged()
        await until("one removal") { calls.count == 1 }
        engine.inputsChanged()
        await until("sent again, not taken as done") { calls.count == 2 }
        removalAnswer = .removed
        engine.inputsChanged()
        await until("third") { calls.count == 3 }
        engine.inputsChanged()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls.count, 3, "a removal the helper confirmed is not sent again")
    }

    func testAnUnansweredCallGivesTheNextRouteANewStamp() async {
        engine.setEnabled(true)
        await until("active") { engine.state == .active }
        let first = system.sent.last?.egressRoutes
        answer = nil   // the helper added it, but the reply was lost
        engine.requestPush(force: true)
        await until("pushed") { system.sent.count >= 2 }
        answer = .kept
        engine.requestPush(force: true)
        await until("pushed again") { system.sent.count >= 3 }
        XCTAssertEqual(system.sent.last.map { Array($0.egressRoutes.keys) }, ["en0"])
        XCTAssertNotEqual(system.sent.last?.egressRoutes, first, "a new stamp, so the extension forgets old failures")
    }
}
