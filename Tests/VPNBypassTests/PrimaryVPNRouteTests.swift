import XCTest
@testable import VPNBypassCore

@MainActor
final class PrimaryVPNRouteTests: XCTestCase {

    private let routeManager = RouteManager.shared

    private var backupURL: URL {
        routeManager.configURL.deletingLastPathComponent().appendingPathComponent("config.json.bak")
    }

    override func setUp() {
        super.setUp()
        routeManager.isConfigLoadFailed = false
        routeManager.vpnType = nil
        routeManager.config = Config()
        cleanupConfigFiles()
    }

    override func tearDown() {
        cleanupConfigFiles()
        routeManager.isConfigLoadFailed = false
        routeManager.vpnType = nil
        routeManager.config = Config()
        super.tearDown()
    }

    private func removeFileIgnoringMissing(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
                return
            }
            XCTFail("Failed to clean up test file at \(url.path): \(error.localizedDescription)")
        }
    }

    private func cleanupConfigFiles() {
        removeFileIgnoringMissing(routeManager.configURL)
        removeFileIgnoringMissing(backupURL)
    }

    func testDetectedVPNAddsOnePersistedPrimaryRouteAndReloadsFromDisk() throws {
        routeManager.vpnType = .tailscale
        routeManager.ensurePrimaryVPNRoute()

        XCTAssertEqual(routeManager.config.routes.count, 1)
        let route = try XCTUnwrap(routeManager.config.routes.first, "Expected a primary VPN route in memory")
        XCTAssertEqual(route.egress, .vpnDefault)
        XCTAssertEqual(route.vpnSelector?.kind, .primary)
        XCTAssertEqual(route.name, "Primary VPN")

        let savedID = route.id

        // Reset in-memory configuration and reload from disk
        routeManager.config = Config()
        XCTAssertTrue(routeManager.config.routes.isEmpty)

        routeManager.loadConfig()

        XCTAssertEqual(routeManager.config.routes.count, 1)
        let reloadedRoute = try XCTUnwrap(routeManager.config.routes.first, "Expected primary VPN route to be reloaded from disk")
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

    func testLoadConfigPreservesInvalidConfigFileAndBackupOnDisk() throws {
        let invalidJSON = "{ invalid_json_syntax: true "
        let backupJSON = "{ backup_json: true }"

        try invalidJSON.write(to: routeManager.configURL, atomically: true, encoding: .utf8)
        try backupJSON.write(to: backupURL, atomically: true, encoding: .utf8)

        routeManager.loadConfig()

        let currentConfigContent = try String(contentsOf: routeManager.configURL, encoding: .utf8)
        let currentBackupContent = try String(contentsOf: backupURL, encoding: .utf8)

        XCTAssertEqual(currentConfigContent, invalidJSON, "Corrupted config.json must be preserved on disk and not overwritten on load failure")
        XCTAssertEqual(currentBackupContent, backupJSON, "Existing config.json.bak must be preserved on disk and not overwritten on load failure")
    }

    func testInvalidConfigBlocksAutomaticWritesAndPreservesFiles() async throws {
        let invalidJSON = "{ invalid_json_syntax: true "
        let backupJSON = "{ backup_json: true }"

        try invalidJSON.write(to: routeManager.configURL, atomically: true, encoding: .utf8)
        try backupJSON.write(to: backupURL, atomically: true, encoding: .utf8)

        // 1. loadConfig fails due to invalid JSON
        routeManager.loadConfig()
        XCTAssertTrue(routeManager.isConfigLoadFailed, "isConfigLoadFailed state must be active after load failure")

        // 2. Automatic VPN detection and apply path runs with VPN connected
        routeManager.isVPNConnected = true
        routeManager.vpnType = .tailscale

        await routeManager.detectAndApplyRoutesAsync()

        // 3. Verify no configuration write occurred and files remain byte-for-byte unchanged
        let currentConfigContent = try String(contentsOf: routeManager.configURL, encoding: .utf8)
        let currentBackupContent = try String(contentsOf: backupURL, encoding: .utf8)

        XCTAssertEqual(currentConfigContent, invalidJSON, "invalid config.json must remain byte-for-byte unchanged after automatic apply pass")
        XCTAssertEqual(currentBackupContent, backupJSON, "existing config.json.bak must remain byte-for-byte unchanged after automatic apply pass")
    }

    func testStatusDrivenVPNConnectPersistsPrimaryVPNRoute() {
        routeManager.config = Config()
        XCTAssertTrue(routeManager.config.routes.isEmpty)

        // Simulate VPN connection detection
        routeManager.vpnType = .tailscale
        let added = routeManager.ensurePrimaryVPNRoute()

        XCTAssertTrue(added, "Primary VPN route must be added on VPN connect")
        XCTAssertEqual(routeManager.config.routes.count, 1)
        XCTAssertEqual(routeManager.config.routes.first?.name, "Primary VPN")
    }

    func testSaveConfigSetsStrict0600PermissionsOnConfigAndBackup() throws {
        routeManager.vpnType = .tailscale
        try routeManager.saveConfigThrowing()

        let configAttrs = try FileManager.default.attributesOfItem(atPath: routeManager.configURL.path)
        let configPerms = (configAttrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(configPerms, 0o600, "config.json must have strict 0600 permissions")

        if FileManager.default.fileExists(atPath: backupURL.path) {
            let backupAttrs = try FileManager.default.attributesOfItem(atPath: backupURL.path)
            let backupPerms = (backupAttrs[.posixPermissions] as? NSNumber)?.uint16Value
            XCTAssertEqual(backupPerms, 0o600, "config.json.bak must have strict 0600 permissions")
        }
    }

    func testImportConfigRecoversFromConfigLoadFailureAndPersistsToDisk() throws {
        let invalidJSON = "{ invalid_json_syntax: true "
        try invalidJSON.write(to: routeManager.configURL, atomically: true, encoding: .utf8)

        // 1. loadConfig fails
        routeManager.loadConfig()
        XCTAssertTrue(routeManager.isConfigLoadFailed, "isConfigLoadFailed state must be active after load failure")

        // 2. Prepare valid export file to import
        var validConfig = Config()
        validConfig.domains = [DomainEntry(domain: "recovered.example.com")]
        let exportData = RouteManager.ExportData(version: "4.7.2", exportDate: Date(), config: validConfig)
        let exportDataData = try JSONEncoder().encode(exportData)

        let tempExportURL = routeManager.configURL.deletingLastPathComponent().appendingPathComponent("export_test.json")
        try exportDataData.write(to: tempExportURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempExportURL) }

        // 3. Perform importConfig
        let success = routeManager.importConfig(from: tempExportURL)
        XCTAssertTrue(success, "importConfig must succeed for valid configuration")
        XCTAssertFalse(routeManager.isConfigLoadFailed, "isConfigLoadFailed must be cleared after successful recovery write")

        // 4. Verify disk content is valid and reloads successfully
        let reloadedData = try Data(contentsOf: routeManager.configURL)
        let reloadedConfig = try JSONDecoder().decode(Config.self, from: reloadedData)
        XCTAssertEqual(reloadedConfig.domains.first?.domain, "recovered.example.com")
    }
}
