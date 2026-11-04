// ScopedDefaultKeeper.swift
// The helper's half of per-app routing's scoped default route (R12). What to write is decided
// in `ScopedDefaultRoute.plan` (Sources/VPNBypassCore/ScopedDefaultRoute.swift, tested from the
// app target); this file holds what the helper added, writes it through the routing socket, and
// takes it away when nobody renews it.
//
// The route lives on a lease like the wildcard forwarder: every call from the app renews it (per-app
// routing pushes its policy every 30 s, and each push asks again), and with no call for
// `leaseSeconds` (the app quit, crashed or hung) the helper removes it by itself. It also goes at
// helper start and on SIGTERM, so a helper restart never leaves one behind; the app asks again.

import Foundation

final class ScopedDefaultKeeper {
    static let shared = ScopedDefaultKeeper()

    /// Five heartbeats of per-app routing.
    static let leaseSeconds: TimeInterval = 150

    /// Its own routing socket; the writes go through `HelperTool.routeQueue` and the shared pacer.
    private let routeWriter = HelperTool()
    /// What the app asked for and the helper holds for it. Touched on `routeQueue` only.
    private var held: ScopedDefaultRequest?
    private var lastRenew = DispatchTime.now()
    private var leaseTimer: DispatchSourceTimer?
    private var lastOutcome: ScopedDefaultOutcome?
    /// A removal failed: the lease timer tries it again on its next tick.
    private var removalPending = false

    /// Brings the table in line with `request` (nil: ours goes). Call on `HelperTool.routeQueue`.
    func set(_ request: ScopedDefaultRequest?, reason: String = "asked by the app") -> ScopedDefaultOutcome {
        // Only a request renews the lease: a removal that fails must be tried again by the lease
        // timer, not 150 s after its own attempt.
        if request != nil { lastRenew = DispatchTime.now() }
        let outcome = apply(request)
        if request != nil {
            held = request
            removalPending = false
            armLease()
        } else if outcome == .failed {
            removalPending = true
            armLease()
        } else {
            held = nil
            removalPending = false
            disarmLease()
        }
        // Interface names and the router only; never a host name.
        if outcome != lastOutcome || outcome == .refused || outcome == .failed {
            let target = request.map { "\($0.interface) via \($0.gateway)" } ?? "none"
            helperLog.info("scoped default: \(outcome.rawValue, privacy: .public) (wanted: \(target, privacy: .public); \(reason, privacy: .public))")
        }
        lastOutcome = outcome
        return outcome
    }

    /// At helper start and on SIGTERM: ours goes (unless the interface stopped being primary,
    /// `ScopedDefaultRoute.mayRemove`), whoever added it.
    func removeAll(reason: String) {
        HelperTool.routeQueue.sync { _ = set(nil, reason: reason) }
    }

    private func apply(_ request: ScopedDefaultRequest?) -> ScopedDefaultOutcome {
        guard let table = RouteKernel.currentTable() else { return .failed }
        let index: UInt16? = request.flatMap {
            let i = if_nametoindex($0.interface)
            return i == 0 || i > UInt32(UInt16.max) ? nil : UInt16(i)
        }
        let plan = ScopedDefaultRoute.plan(request, interfaceIndex: index, table: table)
        for scope in plan.delete {
            if let err = routeWriter.writeScopedDefault(type: RTM_DELETE, interfaceIndex: scope, gateway: "0.0.0.0"), err != ESRCH {
                helperLog.error("scoped default: delete on index \(scope, privacy: .public) failed (errno \(err, privacy: .public))")
                return .failed
            }
        }
        if plan.add, let request, let index {
            if let err = routeWriter.writeScopedDefault(type: RTM_ADD, interfaceIndex: index, gateway: request.gateway) {
                helperLog.error("scoped default: add on \(request.interface, privacy: .public) failed (errno \(err, privacy: .public))")
                return .failed
            }
        }
        return plan.outcome
    }

    // MARK: - Lease

    private func armLease() {
        guard leaseTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: HelperTool.routeQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.removalPending {
                _ = self.set(nil, reason: "retrying a removal that failed")
                return
            }
            guard self.held != nil else { return }
            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastRenew.uptimeNanoseconds) / 1_000_000_000
            if idle > Self.leaseSeconds { _ = self.set(nil, reason: "the app stopped asking") }
        }
        leaseTimer = timer
        timer.resume()
    }

    private func disarmLease() {
        leaseTimer?.cancel()
        leaseTimer = nil
    }
}
