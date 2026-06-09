// DetectVPNStateOnlyTests.swift
// Regression coverage for the helper-absent "Setting Up..." hang fix (#PR43).
// detectVPNStateOnly() must ALWAYS clear isLoading so the spinner can't hang
// forever when the privileged helper is not ready.

import XCTest
@testable import VPNBypassCore

@MainActor
final class DetectVPNStateOnlyTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    /// The exact bug: isLoading stayed true forever when the helper was absent,
    /// leaving a permanent "Setting Up..." spinner. detectVPNStateOnly() must
    /// clear it regardless of what the live system reports for VPN/network state.
    func testDetectVPNStateOnlyClearsIsLoading() async {
        rm.isLoading = true
        await rm.detectVPNStateOnly()
        XCTAssertFalse(rm.isLoading, "detectVPNStateOnly must clear the loading spinner")
    }

    /// Display-only detection must NEVER apply routes (no helper available).
    /// activeRoutes must stay empty — it only ever populates via the helper path.
    func testDetectVPNStateOnlyDoesNotApplyRoutes() async {
        await rm.detectVPNStateOnly()
        XCTAssertTrue(rm.activeRoutes.isEmpty, "display-only detection must not apply routes")
    }
}
