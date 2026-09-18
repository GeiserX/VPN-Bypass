import XCTest
@testable import VPNBypassCore

final class DestinationInstallPolicyTests: XCTestCase {

    func testRefusesFullTunnelPrefixes() {
        for dest in ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "10.0.0.0/1", "64.0.0.0/1"] {
            XCTAssertTrue(DestinationInstallPolicy.refusesInstall(dest), dest)
        }
    }

    func testAllowsSlashTwoQuartetAndNormalNets() {
        for dest in ClassicRouteCompiler.bypassAllCatchAlls + ["10.0.0.0/8", "192.168.1.0/24", "8.8.8.8"] {
            XCTAssertFalse(DestinationInstallPolicy.refusesInstall(dest), dest)
        }
    }

    func testTrimsWhitespace() {
        XCTAssertTrue(DestinationInstallPolicy.refusesInstall("  0.0.0.0/1  "))
        XCTAssertFalse(DestinationInstallPolicy.refusesInstall("  10.0.0.0/8  "))
    }
}
