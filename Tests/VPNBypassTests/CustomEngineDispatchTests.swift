// CustomEngineDispatchTests.swift
// Coverage for the custom-engine dispatch predicate (RouteManager.usesCustomEngine),
// the single seam every apply path uses to decide legacy vs. rule engine. The key case
// is the FAIL-SAFE: a schemaVersion-1 config whose mode says .custom must NOT feed the
// rule engine — its routes/rules were never migrated — so it takes the legacy path.

import XCTest
@testable import VPNBypassCore

final class CustomEngineDispatchTests: XCTestCase {

    func testCustomEngineRunsOnlyAtSchemaV2AndCustomMode() {
        XCTAssertTrue(RouteManager.usesCustomEngine(schemaVersion: 2, routingMode: .custom))
    }

    func testSchemaV1CustomIsFailSafeToLegacy() {
        XCTAssertFalse(RouteManager.usesCustomEngine(schemaVersion: 1, routingMode: .custom),
                       "schemaVersion 1 + .custom must fall through to the legacy engine, not the rule builder")
    }

    func testClassicModesNeverUseCustomEngine() {
        XCTAssertFalse(RouteManager.usesCustomEngine(schemaVersion: 2, routingMode: .bypass))
        XCTAssertFalse(RouteManager.usesCustomEngine(schemaVersion: 2, routingMode: .vpnOnly))
        XCTAssertFalse(RouteManager.usesCustomEngine(schemaVersion: 1, routingMode: .bypass))
    }

    func testHigherSchemaVersionsStillUseCustomEngine() {
        XCTAssertTrue(RouteManager.usesCustomEngine(schemaVersion: 3, routingMode: .custom),
                      ">= 2 is the gate, so future schema versions still route to the engine")
    }
}
