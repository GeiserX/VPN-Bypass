import XCTest
@testable import VPNBypassCore

@MainActor
final class PrimaryVPNRouteTests: XCTestCase {

    private let routeManager = RouteManager.shared

    override func setUp() {
        super.setUp()
        routeManager.vpnType = nil
        routeManager.config = Config()
    }

    override func tearDown() {
        routeManager.vpnType = nil
        routeManager.config = Config()
        super.tearDown()
    }

    func testDetectedVPNAddsOnePersistedPrimaryRoute() {
        routeManager.vpnType = .tailscale

        XCTAssertEqual(routeManager.config.routes.count, 1)
        guard let route = routeManager.config.routes.first else {
            XCTFail("Expected a primary VPN route")
            return
        }
        XCTAssertEqual(route.egress, .vpnDefault)
        XCTAssertEqual(route.vpnSelector?.kind, .primary)
        XCTAssertEqual(route.name, "Primary VPN")
    }

    func testRepeatedDetectionDoesNotAddDuplicatePrimaryRoutes() {
        routeManager.vpnType = .tailscale
        let firstID = routeManager.config.routes.first?.id

        routeManager.vpnType = .tailscale

        XCTAssertEqual(routeManager.config.routes.count, 1)
        XCTAssertEqual(routeManager.config.routes.first?.id, firstID)
    }

    func testLegacyNilSelectorCountsAsExistingPrimaryRoute() {
        let existing = Route(name: "Corporate VPN", egress: .vpnDefault)
        routeManager.config.routes = [existing]

        routeManager.vpnType = .tailscale

        XCTAssertEqual(routeManager.config.routes, [existing])
    }
}
