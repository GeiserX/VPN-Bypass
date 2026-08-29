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

    func testEnsurePrimaryVPNRouteAppendsAndReportsThatItDid() {
        routeManager.config = Config()
        XCTAssertTrue(routeManager.config.routes.isEmpty)

        // Simulate VPN connection detection
        routeManager.vpnType = .tailscale
        let added = routeManager.ensurePrimaryVPNRoute()

        XCTAssertTrue(added, "a config with no VPN route must get one, and say so")
        XCTAssertEqual(routeManager.config.routes.count, 1)
        XCTAssertEqual(routeManager.config.routes.first?.name, "Primary VPN")
    }

    func testSaveConfigSetsStrict0600PermissionsOnConfigAndBackup() throws {
        routeManager.vpnType = .tailscale
        try routeManager.saveConfigThrowing()

        let configAttrs = try FileManager.default.attributesOfItem(atPath: routeManager.configURL.path)
        let configPerms = (configAttrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(configPerms, 0o600, "config.json must have strict 0600 permissions")

        // Force the backup to exist rather than skipping the assertion when it does not:
        // wrapped in `if fileExists` this check never ran, so it could not fail. The source
        // is deliberately 0644 — a backup copied from a loose file inherits that mode, so
        // dropping the chmod in the backup path turns this red.
        try Data("{}".utf8).write(to: routeManager.configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: routeManager.configURL.path)
        try routeManager.saveConfigThrowing()
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path),
                      "a save with an existing config must produce the daily backup")
        let backupAttrs = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        XCTAssertEqual((backupAttrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600,
                       "config.json.bak carries the same credentials and must be 0600 too")
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
        let appVersion = try XCTUnwrap(
            (Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
            "Expected CFBundleShortVersionString in bundle infoDictionary"
        )
        let exportData = RouteManager.ExportData(version: appVersion, exportDate: Date(), config: validConfig)
        let exportDataData = try JSONEncoder().encode(exportData)

        let tempExportURL = routeManager.configURL.deletingLastPathComponent().appendingPathComponent("export_test.json")
        try exportDataData.write(to: tempExportURL, options: .atomic)
        defer { removeFileIgnoringMissing(tempExportURL) }

        // 3. Perform importConfig
        let success = routeManager.importConfig(from: tempExportURL)
        XCTAssertTrue(success, "importConfig must succeed for valid configuration")
        XCTAssertFalse(routeManager.isConfigLoadFailed, "isConfigLoadFailed must be cleared after successful recovery write")

        // 4. Verify disk content is valid and reloads successfully
        let reloadedData = try Data(contentsOf: routeManager.configURL)
        let reloadedConfig = try JSONDecoder().decode(Config.self, from: reloadedData)
        XCTAssertEqual(reloadedConfig.domains.first?.domain, "recovered.example.com")
    }

    func testImportConfigFailureDoesNotLeavePartiallyWrittenConfigOnDisk() throws {
        let invalidJSON = "{ invalid_json_syntax: true "
        try invalidJSON.write(to: routeManager.configURL, atomically: true, encoding: .utf8)

        // 1. loadConfig fails due to invalid JSON
        routeManager.loadConfig()
        XCTAssertTrue(routeManager.isConfigLoadFailed)

        // 2. Prepare an invalid export file path or unreadable file for import
        let nonExistentURL = routeManager.configURL.deletingLastPathComponent().appendingPathComponent("non_existent_export.json")

        // 3. Attempt importConfig from invalid URL
        let success = routeManager.importConfig(from: nonExistentURL)
        XCTAssertFalse(success, "importConfig must return false when source file is invalid/missing")

        // 4. Verify disk content remains completely untouched byte-for-byte
        let currentContent = try String(contentsOf: routeManager.configURL, encoding: .utf8)
        XCTAssertEqual(currentContent, invalidJSON, "config.json on disk must remain unchanged on import failure")
    }

    // MARK: - The production path

    /// The reported gap (#96), reproduced at the level the app actually reaches it. `Config`'s
    /// DECODER is the only place that derives the Direct + primary-VPN system routes, so a
    /// brand-new install — which has no config.json to decode — showed an empty route picker
    /// in Rules for its whole first session. Deleting the seed in `loadConfig()` turns this red.
    func testFirstLaunchWithNoConfigFileSeedsTheSystemRoutes() {
        cleanupConfigFiles()
        routeManager.config = Config()
        XCTAssertTrue(routeManager.config.routes.isEmpty, "precondition: a default Config has no routes")

        routeManager.loadConfig()

        XCTAssertTrue(routeManager.config.routes.contains { $0.egress == .direct },
                      "a fresh install must get the Direct system route")
        XCTAssertTrue(routeManager.config.routes.contains { $0.egress == .vpnDefault && $0.vpnSelector?.kind != .interface },
                      "a fresh install must get the primary-VPN system route Rules selects")
    }

    /// A config that decodes but carries no VPN route at all gets one back at load, which is
    /// the case `ensurePrimaryVPNRoute()` exists for. Deleting its call in `loadConfig()`
    /// turns this red.
    func testLoadingAConfigWithNoVPNRouteRestoresThePrimaryVPNRoute() throws {
        var stored = Config()
        stored.routes = [Route(name: "Direct", egress: .direct)]
        try JSONEncoder().encode(stored).write(to: routeManager.configURL, options: .atomic)

        routeManager.config = Config()
        routeManager.loadConfig()

        XCTAssertEqual(routeManager.config.routes.filter { $0.egress == .vpnDefault }.count, 1,
                       "exactly one primary-VPN route, not zero and not a duplicate")
    }

    /// The 30s status timer (VPNBypassApp.swift:289) drives `checkVPNStatus()`. Seeding from
    /// there re-created a route the user had deliberately deleted, and rewrote config.json,
    /// every half minute. Seeding is load-time only, so a second pass must be inert.
    func testSeedingIsIdempotentAndNeverDuplicatesTheRoute() {
        routeManager.config = Config()
        routeManager.loadConfig()
        let afterFirst = routeManager.config.routes.count

        routeManager.loadConfig()
        routeManager.ensurePrimaryVPNRoute()

        XCTAssertEqual(routeManager.config.routes.count, afterFirst,
                       "repeat passes must not append another route")
    }

    /// config.json holds proxy credentials and localProxySecret (GHSA-gm4h-95p9-9w7v). It must
    /// never exist at umask-default 0644, even briefly, inside a 0755 directory. Note that
    /// `replaceItemAt` keeps the DESTINATION's mode, so a 0644 file already on disk is the
    /// case that matters.
    func testSaveTightensAPreexistingWorldReadableConfig() throws {
        try Data("{}".utf8).write(to: routeManager.configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: routeManager.configURL.path)

        try routeManager.saveConfigThrowing()

        let attrs = try FileManager.default.attributesOfItem(atPath: routeManager.configURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600,
                       "a save must tighten an existing 0644 config to 0600")
    }
}
