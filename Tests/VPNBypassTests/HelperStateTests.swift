// HelperStateTests.swift
// Unit tests for HelperState enum and HelperConstants.

import XCTest
@testable import VPNBypassCore

// MARK: - HelperState.isReady Tests

final class HelperStateIsReadyTests: XCTestCase {

    func testReadyStateIsReady() {
        XCTAssertTrue(HelperState.ready.isReady)
    }

    func testMissingStateIsNotReady() {
        XCTAssertFalse(HelperState.missing.isReady)
    }

    func testCheckingStateIsNotReady() {
        XCTAssertFalse(HelperState.checking.isReady)
    }

    func testInstallingStateIsNotReady() {
        XCTAssertFalse(HelperState.installing.isReady)
    }

    func testOutdatedStateIsNotReady() {
        XCTAssertFalse(HelperState.outdated(installed: "1.0.0", expected: "2.0.0").isReady)
    }

    func testFailedStateIsNotReady() {
        XCTAssertFalse(HelperState.failed("something broke").isReady)
    }
}

// MARK: - HelperState.isFailed Tests

final class HelperStateIsFailedTests: XCTestCase {

    func testFailedWithMessageIsFailed() {
        XCTAssertTrue(HelperState.failed("timeout").isFailed)
    }

    func testFailedWithEmptyMessageIsFailed() {
        XCTAssertTrue(HelperState.failed("").isFailed)
    }

    func testReadyIsNotFailed() {
        XCTAssertFalse(HelperState.ready.isFailed)
    }

    func testMissingIsNotFailed() {
        XCTAssertFalse(HelperState.missing.isFailed)
    }

    func testCheckingIsNotFailed() {
        XCTAssertFalse(HelperState.checking.isFailed)
    }

    func testInstallingIsNotFailed() {
        XCTAssertFalse(HelperState.installing.isFailed)
    }

    func testOutdatedIsNotFailed() {
        XCTAssertFalse(HelperState.outdated(installed: "1.0.0", expected: "1.5.0").isFailed)
    }
}

// MARK: - HelperState.statusText Tests

final class HelperStateStatusTextTests: XCTestCase {

    func testMissingStatusTextContainsNotInstalled() {
        XCTAssertTrue(HelperState.missing.statusText.contains("Not Installed"))
    }

    func testCheckingStatusTextContainsChecking() {
        XCTAssertTrue(HelperState.checking.statusText.contains("Checking"))
    }

    func testInstallingStatusTextContainsInstalling() {
        XCTAssertTrue(HelperState.installing.statusText.contains("Installing"))
    }

    func testOutdatedStatusTextContainsBothVersions() {
        let text = HelperState.outdated(installed: "1.0.0", expected: "2.0.0").statusText
        XCTAssertTrue(text.contains("1.0.0"), "Should contain installed version")
        XCTAssertTrue(text.contains("2.0.0"), "Should contain expected version")
    }

    func testReadyStatusTextContainsInstalled() {
        XCTAssertTrue(HelperState.ready.statusText.contains("Installed"))
    }

    func testFailedStatusTextContainsErrorMessage() {
        let text = HelperState.failed("timeout").statusText
        XCTAssertTrue(text.contains("timeout"))
    }

    func testFailedStatusTextContainsErrorPrefix() {
        let text = HelperState.failed("").statusText
        XCTAssertTrue(text.contains("Error"))
    }
}

// MARK: - HelperState Equatable Tests

final class HelperStateEquatableTests: XCTestCase {

    func testReadyEqualsReady() {
        XCTAssertEqual(HelperState.ready, HelperState.ready)
    }

    func testMissingEqualsMissing() {
        XCTAssertEqual(HelperState.missing, HelperState.missing)
    }

    func testFailedWithSameMessageAreEqual() {
        XCTAssertEqual(HelperState.failed("a"), HelperState.failed("a"))
    }

    func testFailedWithDifferentMessagesAreNotEqual() {
        XCTAssertNotEqual(HelperState.failed("a"), HelperState.failed("b"))
    }

    func testReadyDoesNotEqualMissing() {
        XCTAssertNotEqual(HelperState.ready, HelperState.missing)
    }

    func testOutdatedWithSameVersionsAreEqual() {
        XCTAssertEqual(
            HelperState.outdated(installed: "1.0.0", expected: "2.0.0"),
            HelperState.outdated(installed: "1.0.0", expected: "2.0.0")
        )
    }

    func testOutdatedWithDifferentExpectedAreNotEqual() {
        XCTAssertNotEqual(
            HelperState.outdated(installed: "1.0.0", expected: "2.0.0"),
            HelperState.outdated(installed: "1.0.0", expected: "3.0.0")
        )
    }
}

// MARK: - HelperConstants Extended Tests

final class HelperConstantsExtendedTests: XCTestCase {

    func testHelperVersionHasExactlyTwoDots() {
        let dotCount = HelperConstants.helperVersion.filter { $0 == "." }.count
        XCTAssertEqual(dotCount, 2, "Semver must have exactly 2 dots (X.Y.Z)")
    }

    func testHelperVersionComponentsAreNonNegativeIntegers() {
        let parts = HelperConstants.helperVersion.components(separatedBy: ".")
        for (index, part) in parts.enumerated() {
            guard let value = Int(part) else {
                XCTFail("Version component \(index) ('\(part)') is not an integer")
                return
            }
            XCTAssertGreaterThanOrEqual(value, 0, "Version component \(index) must be non-negative")
        }
    }

    func testBundleIDIsNonEmpty() {
        XCTAssertFalse(HelperConstants.bundleID.isEmpty)
    }

    func testHostMarkerStartDoesNotEqualEnd() {
        XCTAssertNotEqual(HelperConstants.hostMarkerStart, HelperConstants.hostMarkerEnd)
    }

    func testMarkersContainIdentifyingText() {
        XCTAssertTrue(
            HelperConstants.hostMarkerStart.contains("VPN-BYPASS"),
            "Start marker should contain VPN-BYPASS"
        )
        XCTAssertTrue(
            HelperConstants.hostMarkerEnd.contains("VPN-BYPASS"),
            "End marker should contain VPN-BYPASS"
        )
    }
}
