// DisconnectNotificationTests.swift
// Kept-by-design and failed-removal are different facts and must read differently.
//
// Bypass mode deliberately KEEPS local-gateway routes on VPN disconnect — a reconnect finds
// them already correct and costs zero kernel churn (the #65 fix). The notification template
// predated that behaviour and rendered ANY remaining count as "could not be removed", so the
// churn fix's first live run reported itself as a malfunction ("374 routes could not be
// removed" — all 374 were correct, deliberate, and pointing at the local gateway).

import XCTest
@testable import VPNBypassCore

final class DisconnectNotificationTests: XCTestCase {

    func testKeptRoutesReadAsKeptNotFailed() {
        let body = NotificationManager.disconnectedBody(wasInterface: "utun9", routesKept: 374, routesFailed: 0)
        XCTAssertTrue(body.contains("Keeping 374"), body)
        XCTAssertFalse(body.contains("could not be removed"), "kept-by-design must never read as a failure")
    }

    func testGenuineFailuresStillReadAsFailures() {
        let body = NotificationManager.disconnectedBody(wasInterface: "utun9", routesKept: 0, routesFailed: 3)
        XCTAssertTrue(body.contains("3 route(s) could not be removed"), body)
    }

    /// Failures outrank kept in the headline — a real problem must not be softened by the
    /// routine fact that some routes were kept.
    func testFailuresOutrankKept() {
        let body = NotificationManager.disconnectedBody(wasInterface: nil, routesKept: 100, routesFailed: 2)
        XCTAssertTrue(body.contains("could not be removed"))
        XCTAssertFalse(body.contains("Keeping"))
    }

    func testCleanTeardownSaysCleared() {
        let body = NotificationManager.disconnectedBody(wasInterface: "utun9", routesKept: 0, routesFailed: 0)
        XCTAssertTrue(body.contains("Routes cleared"), body)
    }
}
