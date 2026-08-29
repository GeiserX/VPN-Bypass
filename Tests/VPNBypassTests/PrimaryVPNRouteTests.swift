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

    func testDetectedVPNAddsOnePersistedPrimaryRouteAndReloadsFromDisk() {
        routeManager.vpnType = .tailscale
        routeManager.ensurePrimaryVPNRoute()

        XCTAssertEqual(routeManager.config.routes.count, 1)
        guard let route = routeManager.config.routes.first else {
            XCTFail("Expected a primary VPN route in memory")
            return
        }
        XCTAssertEqual(route.egress, .vpnDefault)
        XCTAssertEqual(route.vpnSelector?.kind, .primary)
        XCTAssertEqual(route.name, "Primary VPN")

        let savedID = route.id

        // Reset in-memory configuration and reload from disk
        routeManager.config = Config()
        XCTAssertTrue(routeManager.config.routes.isEmpty)

        routeManager.loadConfig()

        XCTAssertEqual(routeManager.config.routes.count, 1)
        guard let reloadedRoute = routeManager.config.routes.first else {
            XCTFail("Expected primary VPN route to be reloaded from disk")
            return
        }
        XCTAssertEqual(reloadedRoute.id, savedID)
        XCTAssertEqual(reloadedRoute.egress, .vpnDefault)
        XCTAssertEqual(reloadedRoute.vpnSelector?.kind, .primary)
    }

    func testRepeatedDetectionDoesNotAddDuplicatePrimaryRoutes() {
        routeManager.vpnType = .tailscale
        routeManager.ensurePrimaryVPNRoute()
        let firstID = routeManager.config.routes.first?.id

        routeManager.vpnType = .tailscale
        routeManager.ensurePrimaryVPNRoute()

        XCTAssertEqual(routeManager.config.routes.count, 1)
        XCTAssertEqual(routeManager.config.routes.first?.id, firstID)
    }

    func testLegacyNilSelectorCountsAsExistingPrimaryRoute() {
        let existing = Route(name: "Corporate VPN", egress: .vpnDefault)
        routeManager.config.routes = [existing]

        routeManager.vpnType = .tailscale
        routeManager.ensurePrimaryVPNRoute()

        XCTAssertEqual(routeManager.config.routes, [existing])
    }

    func testDetectVPNStateOnlyIsReadOnlyAndDoesNotMutateConfig() async {
        routeManager.config = Config()
        XCTAssertTrue(routeManager.config.routes.isEmpty)

        await routeManager.detectVPNStateOnly()

        XCTAssertTrue(routeManager.config.routes.isEmpty, "detectVPNStateOnly must be read-only and never mutate config")
    }

    func testLoadConfigPreservesInvalidConfigFileAndBackupOnDisk() {
        let invalidJSON = "{ invalid_json_syntax: true "
        let backupJSON = "{ backup_json: true }"
        let backupURL = routeManager.configURL.deletingLastPathComponent().appendingPathComponent("config.json.bak")

        try? invalidJSON.write(to: routeManager.configURL, atomically: true, encoding: .utf8)
        try? backupJSON.write(to: backupURL, atomically: true, encoding: .utf8)

        routeManager.loadConfig()

        let currentConfigContent = (try? String(contentsOf: routeManager.configURL, encoding: .utf8)) ?? ""
        let currentBackupContent = (try? String(contentsOf: backupURL, encoding: .utf8)) ?? ""

        XCTAssertEqual(currentConfigContent, invalidJSON, "Corrupted config.json must be preserved on disk and not overwritten on load failure")
        XCTAssertEqual(currentBackupContent, backupJSON, "Existing config.json.bak must be preserved on disk and not overwritten on load failure")
    }
}
