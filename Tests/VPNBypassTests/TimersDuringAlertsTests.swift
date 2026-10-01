// TimersDuringAlertsTests.swift
// The 30-second status refresh, the watchdog and the DNS refresh timer were scheduled with
// `Timer.scheduledTimer`, which uses the default run loop mode only. While a modal alert was
// open (the mode switch question runs `NSAlert.runModal`), the main run loop ran in the modal
// panel mode and none of them fired until the alert was answered. They now run in the common
// modes, which include the modal panel and event tracking modes.

import AppKit
import XCTest
@testable import VPNBypassCore

@MainActor
final class TimersDuringAlertsTests: XCTestCase {

    /// The modes AppKit runs the main run loop in while the app waits on the user: a modal
    /// alert, and an open menu. `.default` is there so the timers still fire the rest of the time.
    private let modes: [RunLoop.Mode] = [.default, .modalPanel, .eventTracking]

    override func setUp() {
        super.setUp()
        // NSApplication adds the modal panel and event tracking modes to the main run loop's
        // common modes when it is created.
        _ = NSApplication.shared
    }

    private func assertRunsInEveryMode(_ timer: Timer?, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let timer else { return XCTFail("\(name) was not scheduled", file: file, line: line) }
        for mode in modes {
            XCTAssertTrue(
                CFRunLoopContainsTimer(CFRunLoopGetMain(), timer, CFRunLoopMode(mode.rawValue as CFString)),
                "\(name) is not scheduled in \(mode.rawValue), so it stops while that mode runs",
                file: file, line: line)
        }
    }

    /// The real case: a timer that comes due while an alert is open fires before the alert is
    /// answered.
    func testATimerFiresWhileAModalAlertIsOpen() {
        final class Seen: @unchecked Sendable { var firedWhileOpen = false }
        let seen = Seen()
        let timer = Timer.scheduledInCommonModes(withTimeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                seen.firedWhileOpen = NSApp.modalWindow != nil
                if NSApp.modalWindow != nil { NSApp.abortModal() }
            }
        }
        // Never hang the suite: close the alert after 3 s if the timer never fired.
        let guardTimer = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        }
        RunLoop.main.add(guardTimer, forMode: .modalPanel)
        defer { timer.invalidate(); guardTimer.invalidate() }

        let alert = NSAlert()
        alert.messageText = "Switch to VPN Only?"
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        _ = alert.runModal()

        XCTAssertTrue(seen.firedWhileOpen, "the timer waited for the alert to be answered")
    }

    func testTheStatusRefreshRunsWhileAnAlertOrMenuIsOpen() {
        let delegate = AppDelegate()
        delegate.startPeriodicRefresh()
        defer { delegate.refreshTimer?.invalidate() }
        assertRunsInEveryMode(delegate.refreshTimer, "the 30-second status refresh")
    }

    func testTheWatchdogRunsWhileAnAlertOrMenuIsOpen() {
        let delegate = AppDelegate()
        delegate.startWatchdog()
        defer { delegate.watchdogTimer?.invalidate() }
        assertRunsInEveryMode(delegate.watchdogTimer, "the watchdog")
    }

    func testTheDNSRefreshRunsWhileAnAlertOrMenuIsOpen() {
        let rm = RouteManager.shared
        let saved = rm.config.autoDNSRefresh
        rm.config.autoDNSRefresh = true
        defer {
            rm.stopDNSRefreshTimer()
            rm.config.autoDNSRefresh = saved
        }
        rm.startDNSRefreshTimer()
        assertRunsInEveryMode(rm.dnsRefreshTimer, "the DNS refresh timer")
    }
}
