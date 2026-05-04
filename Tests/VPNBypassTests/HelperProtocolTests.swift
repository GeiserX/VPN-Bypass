import XCTest
@testable import VPNBypassCore

final class HelperProtocolConstantsTests: XCTestCase {

    func testHelperVersion() {
        XCTAssertFalse(HelperConstants.helperVersion.isEmpty)
    }

    func testHelperVersionIsSemver() {
        let parts = HelperConstants.helperVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        for part in parts {
            XCTAssertNotNil(Int(part), "\(part) is not a number")
        }
    }

    func testBundleID() {
        XCTAssertEqual(HelperConstants.bundleID, "com.geiserx.vpnbypass.helper")
    }

    func testHostMarkerStart() {
        XCTAssertTrue(HelperConstants.hostMarkerStart.hasPrefix("#"))
        XCTAssertTrue(HelperConstants.hostMarkerStart.contains("VPN-BYPASS"))
        XCTAssertTrue(HelperConstants.hostMarkerStart.contains("START"))
    }

    func testHostMarkerEnd() {
        XCTAssertTrue(HelperConstants.hostMarkerEnd.hasPrefix("#"))
        XCTAssertTrue(HelperConstants.hostMarkerEnd.contains("VPN-BYPASS"))
        XCTAssertTrue(HelperConstants.hostMarkerEnd.contains("END"))
    }

    func testHostMarkersAreDifferent() {
        XCTAssertNotEqual(HelperConstants.hostMarkerStart, HelperConstants.hostMarkerEnd)
    }

    func testMachServiceName() {
        XCTAssertEqual(kHelperToolMachServiceName, "com.geiserx.vpnbypass.helper")
    }

    func testMachServiceNameMatchesBundleID() {
        XCTAssertEqual(kHelperToolMachServiceName, HelperConstants.bundleID)
    }
}
