// FakeKernel.swift
// Minimal in-memory stand-in for the kernel routing table. `removeRoutesBatchOverrideForTests`
// routes RouteManager's batch removals here instead of the privileged helper, so a test can seed
// the "installed" set, then observe exactly what an aborting apply removes. `attach(to:)` also
// routes the batch add, the one-route add and remove, and the DNS lookup here, so a single
// entry's edit runs end to end with no helper and no network.

import Foundation
@testable import VPNBypassCore

final class FakeKernel {
    var installed: Set<String>
    /// The gateway each installed destination was added through.
    var gateways: [String: String] = [:]
    let failRemovals: Bool
    /// What `resolveIPsOverrideForTests` answers per domain; a domain missing here fails to resolve.
    var dns: [String: [String]] = [:]

    init(installed: Set<String>, failRemovals: Bool = false) {
        self.installed = installed
        self.failRemovals = failRemovals
    }

    func remove(_ destinations: [String]) -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        if failRemovals {
            // Simulate a kernel-delete failure: nothing is removed; every dest is reported failed.
            return (successCount: 0, failureCount: destinations.count, failedDestinations: destinations, error: nil)
        }
        var success = 0
        for d in destinations where installed.remove(d) != nil {
            gateways[d] = nil
            success += 1
        }
        return (successCount: success, failureCount: 0, failedDestinations: [], error: nil)
    }

    func add(_ destination: String, gateway: String) -> Bool {
        installed.insert(destination)
        gateways[destination] = gateway
        return true
    }

    func add(_ routes: [(destination: String, gateway: String, isNetwork: Bool)]) -> (successCount: Int, failureCount: Int, failedDestinations: [String], error: String?) {
        for route in routes { _ = add(route.destination, gateway: route.gateway) }
        return (successCount: routes.count, failureCount: 0, failedDestinations: [], error: nil)
    }

    /// Routes every kernel call and DNS lookup of `rm` here.
    @MainActor
    func attach(to rm: RouteManager) {
        rm.removeRoutesBatchOverrideForTests = { [unowned self] in self.remove($0) }
        rm.addRoutesBatchOverrideForTests = { [unowned self] in self.add($0) }
        rm.addRouteOverrideForTests = { [unowned self] destination, gateway, _ in self.add(destination, gateway: gateway) }
        rm.removeRouteOverrideForTests = { [unowned self] in self.remove([$0]).failureCount == 0 }
        rm.resolveIPsOverrideForTests = { [unowned self] in self.dns[$0] }
    }

    @MainActor
    static func detach(from rm: RouteManager) {
        rm.removeRoutesBatchOverrideForTests = nil
        rm.addRoutesBatchOverrideForTests = nil
        rm.addRouteOverrideForTests = nil
        rm.removeRouteOverrideForTests = nil
        rm.resolveIPsOverrideForTests = nil
    }
}
