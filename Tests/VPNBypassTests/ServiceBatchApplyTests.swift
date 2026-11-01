// ServiceBatchApplyTests.swift
// Switching on several services at once (the catalogue sheet, Turn All On, Undo) writes the
// routing table in ONE batch, not one per service, while each service keeps its own routes.
// Runs against FakeKernel with a fake gateway; nothing touches the real routing table.

import XCTest
@testable import VPNBypassCore

@MainActor
final class ServiceBatchApplyTests: RouteManagerTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedConnected = false
    private var savedGateway: String?
    private var savedRoutes: [RouteManager.ActiveRoute] = []
    private var savedPendingKernelAdds: Set<String> = []
    private var kernel: FakeKernel!
    /// The batches the apply sent to the kernel, in order.
    private var batches: [[String]] = []
    private let gateway = "192.0.2.1"

    override func setUp() {
        super.setUp()
        savedConfig = rm.config
        savedConnected = rm.isVPNConnected
        savedGateway = rm.localGateway
        savedRoutes = rm.activeRoutes
        savedPendingKernelAdds = rm.pendingKernelAdds
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.services = [
            ServiceEntry(id: "a", name: "Alpha", enabled: false, domains: [], ipRanges: ["198.51.100.0/24"]),
            ServiceEntry(id: "b", name: "Beta", enabled: false, domains: [], ipRanges: ["203.0.113.0/24", "198.51.100.0/24"]),
            ServiceEntry(id: "c", name: "Gamma", enabled: false, domains: ["*.gamma.example"], ipRanges: ["192.0.2.128/25"]),
        ]
        rm.config = cfg
        rm.activeRoutes = []
        kernel = FakeKernel(installed: [])
        kernel.attach(to: rm)
        batches = []
        rm.addRoutesBatchOverrideForTests = { [unowned self] routes in
            self.batches.append(routes.map(\.destination))
            return self.kernel.add(routes)
        }
        rm.isVPNConnected = true
        rm.localGateway = gateway
        rm.gatewayDetectedAt = Date()
    }

    override func tearDown() {
        rm.config = savedConfig
        rm.isVPNConnected = savedConnected
        rm.localGateway = savedGateway
        rm.gatewayDetectedAt = nil
        rm.activeRoutes = savedRoutes
        rm.pendingKernelAdds = savedPendingKernelAdds
        FakeKernel.detach(from: rm)
        rm.cancelAllRetries()
        super.tearDown()
    }

    private func waitForTheGate() async {
        var polls = 0
        while rm.isApplyingRoutes && polls < 100 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            polls += 1
        }
        XCTAssertFalse(rm.isApplyingRoutes, "a route operation never finished")
    }

    private func owned(by source: String) -> Set<String> {
        Set(rm.activeRoutes.filter { $0.source == source }.map(\.destination))
    }

    func testSwitchingOnThreeServicesWritesTheRoutingTableOnce() async {
        let changed = rm.setServicesEnabled(["a", "b", "c"], true)
        await waitForTheGate()

        XCTAssertEqual(Set(changed), ["a", "b", "c"])
        XCTAssertEqual(batches.count, 1, "one batch for the three services, got \(batches)")
        XCTAssertEqual(batches.first?.sorted(), ["192.0.2.128/25", "198.51.100.0/24", "203.0.113.0/24"],
                       "a range two services share goes in once")
        XCTAssertEqual(owned(by: "Alpha"), ["198.51.100.0/24"])
        XCTAssertEqual(owned(by: "Beta"), ["203.0.113.0/24", "198.51.100.0/24"], "each service owns its own routes")
        XCTAssertEqual(owned(by: "Gamma"), ["192.0.2.128/25"])
        XCTAssertEqual(kernel.gateways["203.0.113.0/24"], gateway)
    }

    func testSwitchingOnOneServiceStillWritesOnce() async {
        rm.toggleService("b")
        await waitForTheGate()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(owned(by: "Beta"), ["203.0.113.0/24", "198.51.100.0/24"])
    }

    func testARouteAlreadyInTheTableIsNotWrittenAgainButIsOwned() async {
        rm.toggleService("a")
        await waitForTheGate()
        batches = []
        rm.setServicesEnabled(["b"], true)
        await waitForTheGate()
        XCTAssertEqual(batches, [["203.0.113.0/24"]], "198.51.100.0/24 is already routed for Alpha")
        XCTAssertEqual(owned(by: "Beta"), ["203.0.113.0/24", "198.51.100.0/24"])
    }
}
