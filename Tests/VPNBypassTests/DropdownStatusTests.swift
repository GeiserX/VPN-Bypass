// DropdownStatusTests.swift
// Coverage for the status header at the top of the dropdown (DropdownStatus.make).
//
// The problem it locks down: after a reconnect the app waits on purpose before re-applying
// routes, and after repeated apply-kill strikes it withholds the apply for minutes. The old
// header stayed a green ON / "VPN Connected" / "62 routes" through all of it, so a user could
// not tell whether the app was done, waiting, or holding back.

import XCTest
@testable import VPNBypassCore

final class DropdownStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "WireGuard", helperReady: true, mode: .bypass,
            enabledServices: 4, enabledDomains: 2, enabledRules: 0, installedRoutes: 62,
            pending: nil,
            lastRouteChange: .init(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 62, failedCount: 0),
            lastDNSRefresh: now.addingTimeInterval(-12 * 60),
            nextDNSRefresh: now.addingTimeInterval(18 * 60),
            autoDNSRefresh: true)
        edit(&i)
        return i
    }

    private func status(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus {
        DropdownStatus.make(input(edit), now: now)
    }

    // MARK: Normal

    func testNormalBypassMatchesTheMockup() {
        let s = status()
        XCTAssertEqual(s.pill, "ON")
        XCTAssertEqual(s.tone, .ok)
        XCTAssertEqual(s.headline, "WireGuard connected")
        XCTAssertEqual(s.sentence, "4 services and 2 domains skip the VPN.")
        XCTAssertNil(s.note)
        XCTAssertEqual(s.facts, [
            .init(label: "Mode", value: "Bypass: everything else uses the VPN"),
            .init(label: "Routes", value: "62 applied 23 s ago, none failed"),
            .init(label: "DNS", value: "checked 12 min ago, next in 18 min"),
        ])
    }

    func testFailedRoutesShowInTheFacts() {
        let s = status { $0.lastRouteChange = .init(kind: .applied, at: self.now.addingTimeInterval(-5), routeCount: 60, failedCount: 2) }
        XCTAssertEqual(s.facts[1].value, "60 applied 5 s ago, 2 failed")
    }

    func testUnknownVPNNameReadsVPN() {
        XCTAssertEqual(status { $0.vpnName = nil }.headline, "VPN connected")
    }

    // MARK: WAITING

    /// Right after a reconnect the settle gate waits: the header says so and counts down.
    func testSettleWaitCountsDown() {
        let s = status {
            $0.pending = .init(reason: .settling, connectedAt: self.now.addingTimeInterval(-12),
                               appliesAt: self.now.addingTimeInterval(38))
        }
        XCTAssertEqual(s.pill, "WAITING")
        XCTAssertEqual(s.tone, .warn)
        XCTAssertEqual(s.headline, "WireGuard reconnected 12 s ago")
        XCTAssertEqual(s.sentence, "Waiting for the tunnel to hold before re-applying routes, in 38 s.")
        XCTAssertEqual(s.note, "The 62 routes from before the drop are still in place.")

        let later = DropdownStatus.make(input {
            $0.pending = .init(reason: .settling, connectedAt: self.now.addingTimeInterval(-12),
                               appliesAt: self.now.addingTimeInterval(38))
        }, now: now.addingTimeInterval(30))
        XCTAssertEqual(later.sentence, "Waiting for the tunnel to hold before re-applying routes, in 8 s.")
    }

    /// VPN Only tears everything down on a drop, so there is nothing "still in place" to claim.
    func testSettleWaitWithNothingInstalledDoesNotClaimRoutes() {
        let s = status {
            $0.installedRoutes = 0
            $0.pending = .init(reason: .settling, connectedAt: self.now, appliesAt: self.now.addingTimeInterval(10))
        }
        XCTAssertEqual(s.note, "No routes are installed until then.")
    }

    /// Past the deadline, before the task has cleared the state, it must not print "in 0 s".
    func testSettleDeadlinePassedSaysApplyingNow() {
        let s = status {
            $0.pending = .init(reason: .settling, connectedAt: self.now.addingTimeInterval(-20),
                               appliesAt: self.now.addingTimeInterval(-1))
        }
        XCTAssertEqual(s.sentence, "Re-applying routes now.")
    }

    // MARK: HELD BACK

    func testHeldBackSaysWhyAndForHowLong() {
        let s = status {
            $0.pending = .init(reason: .heldBack(strikes: 3), connectedAt: self.now,
                               appliesAt: self.now.addingTimeInterval(5 * 60 + 30))
        }
        XCTAssertEqual(s.pill, "HELD BACK")
        XCTAssertEqual(s.tone, .warn)
        XCTAssertEqual(s.headline, "WireGuard keeps dropping")
        XCTAssertEqual(s.sentence, "It dropped 3 times right after routes were applied, so the app is not applying again until the tunnel has held for 6 more minutes.")
        XCTAssertEqual(s.note, "Refresh Routes applies now anyway.")
    }

    func testHeldBackUnderAMinute() {
        let s = status {
            $0.pending = .init(reason: .heldBack(strikes: 4), connectedAt: self.now,
                               appliesAt: self.now.addingTimeInterval(20))
        }
        XCTAssertTrue(s.sentence.hasSuffix("held for less than a minute."))
    }

    // MARK: Other states win over or lose to a pending apply

    func testDisconnectedBeatsEverything() {
        let s = status {
            $0.isVPNConnected = false
            $0.pending = .init(reason: .settling, connectedAt: self.now, appliesAt: self.now.addingTimeInterval(10))
        }
        XCTAssertEqual(s.pill, "OFF")
        XCTAssertEqual(s.tone, .bad)
        XCTAssertEqual(s.headline, "No VPN connected")
        XCTAssertEqual(s.sentence, "62 routes stay in place for when it reconnects.")
        XCTAssertEqual(status { $0.isVPNConnected = false; $0.installedRoutes = 0 }.sentence,
                       "Nothing is routed until a VPN connects.")
    }

    func testHelperDownIsNotEnforcing() {
        let s = status { $0.helperReady = false }
        XCTAssertEqual(s.pill, "NOT ENFORCING")
        XCTAssertEqual(s.sentence, "Nothing is routed while the privileged helper is not running.")
    }

    func testNoRoutesIsAWarning() {
        let s = status { $0.installedRoutes = 0 }
        XCTAssertEqual(s.pill, "NO ROUTES")
        XCTAssertEqual(s.tone, .warn)
        XCTAssertEqual(s.sentence, "Nothing is routed right now.")
    }

    // MARK: Sentences and facts

    func testWhatIsRoutedPerModeWithSingulars() {
        func routed(_ edit: (inout DropdownStatus.Input) -> Void) -> String { DropdownStatus.whatIsRouted(input(edit)) }
        XCTAssertEqual(routed { $0.enabledServices = 1; $0.enabledDomains = 0 }, "1 service skips the VPN.")
        XCTAssertEqual(routed { $0.enabledServices = 3; $0.enabledDomains = 0 }, "3 services skip the VPN.")
        XCTAssertEqual(routed { $0.enabledServices = 0; $0.enabledDomains = 1 }, "1 domain skips the VPN.")
        XCTAssertEqual(routed { $0.enabledServices = 1; $0.enabledDomains = 1 }, "1 service and 1 domain skip the VPN.")
        XCTAssertEqual(routed { $0.enabledServices = 0; $0.enabledDomains = 0 }, "Nothing skips the VPN yet.")
        XCTAssertEqual(routed { $0.mode = .vpnOnly; $0.enabledDomains = 3 }, "3 entries use the VPN.")
        XCTAssertEqual(routed { $0.mode = .vpnOnly; $0.enabledDomains = 1 }, "1 entry uses the VPN.")
        XCTAssertEqual(routed { $0.mode = .custom; $0.enabledRules = 5 }, "5 rules decide where traffic goes.")
        XCTAssertEqual(routed { $0.mode = .custom; $0.enabledRules = 0 }, "No rules yet.")
    }

    func testModeDescriptions() {
        XCTAssertEqual(DropdownStatus.modeDescription(.vpnOnly), "VPN Only: everything else goes direct")
        XCTAssertEqual(DropdownStatus.modeDescription(.custom), "Custom: the first matching rule decides")
    }

    func testRoutesFactAfterRemovalAndBeforeAnyApply() {
        XCTAssertEqual(DropdownStatus.routesFact(input {
            $0.lastRouteChange = .init(kind: .removedAll, at: self.now.addingTimeInterval(-4), routeCount: 0, failedCount: 0)
        }, now: now), "all removed just now")
        XCTAssertEqual(DropdownStatus.routesFact(input { $0.lastRouteChange = nil }, now: now), "62 installed")
        XCTAssertEqual(DropdownStatus.routesFact(input { $0.lastRouteChange = nil; $0.installedRoutes = 0 }, now: now),
                       "none applied yet")
    }

    /// With the automatic refresh off there is no "next", and the fact must say so.
    func testDNSFactVariants() {
        XCTAssertEqual(DropdownStatus.dnsFact(input { $0.autoDNSRefresh = false }, now: now),
                       "checked 12 min ago, automatic check off")
        XCTAssertEqual(DropdownStatus.dnsFact(input { $0.lastDNSRefresh = nil }, now: now),
                       "not checked yet, next in 18 min")
        XCTAssertEqual(DropdownStatus.dnsFact(input { $0.nextDNSRefresh = self.now.addingTimeInterval(-5) }, now: now),
                       "checked 12 min ago, next one due now")
    }

    func testCountdownFormatting() {
        XCTAssertEqual(DropdownStatus.countdown(0.2), "1 s")
        XCTAssertEqual(DropdownStatus.countdown(38), "38 s")
        XCTAssertEqual(DropdownStatus.countdown(59.5), "1 min")
        XCTAssertEqual(DropdownStatus.countdown(61), "2 min")
        XCTAssertEqual(DropdownStatus.countdown(3600), "1 h")
        XCTAssertEqual(DropdownStatus.countdown(3600 + 20 * 60), "1 h 20 min")
    }
}
