// ConfigChangeStampTests.swift
// `configChangedAt` is what turns a warm Bypass reconnect (which writes nothing) back into a
// full re-apply. It must move only for a save made while the VPN is down: an edit made while
// the VPN is up is applied by its own path, and stamping it as well made every scripted or GUI
// edit cost one full burst of route writes on the next reconnect.

import XCTest
@testable import VPNBypassCore

@MainActor
final class ConfigChangeStampTests: XCTestCase {

    private var savedConnected = false

    override func setUp() async throws {
        savedConnected = RouteManager.shared.isVPNConnected
    }

    override func tearDown() async throws {
        RouteManager.shared.isVPNConnected = savedConnected
    }

    func testSaveWhileConnectedDoesNotForceAFullApplyOnTheNextReconnect() throws {
        let rm = RouteManager.shared
        rm.isVPNConnected = false
        try rm.saveConfigThrowing()
        let stampedWhileDown = try XCTUnwrap(rm.configChangedAt, "a save with the VPN down must stamp the change")

        rm.isVPNConnected = true
        try rm.saveConfigThrowing()
        XCTAssertEqual(rm.configChangedAt, stampedWhileDown,
                       "a save with the VPN up is applied live and must not move the stamp")

        rm.isVPNConnected = false
        try rm.saveConfigThrowing()
        XCTAssertGreaterThan(try XCTUnwrap(rm.configChangedAt), stampedWhileDown,
                             "the next save with the VPN down moves it again")
    }
}
