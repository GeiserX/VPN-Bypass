// ServiceNameClashTests.swift
// A custom service may not take the name of another service or of a Bypass list entry,
// because routes are tracked by that name: the two would share one source, the dropdown would
// group both under one row, and removing one could remove the other's routes. Covers the pure
// check, RouteManager's add, update and undo, config import, and that a config.json already holding
// such a name still loads. The VPN is never connected here, so nothing touches the kernel.

import XCTest
@testable import VPNBypassCore

@MainActor
final class ServiceNameClashTests: RouteManagerTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedLogs: [RouteManager.LogEntry] = []
    private var savedVPNConnected = false
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        savedConfig = rm.config
        savedLogs = rm.recentLogs
        savedVPNConnected = rm.isVPNConnected
        rm.isVPNConnected = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "example.com")]
        cfg.inverseDomains = []
        rm.config = cfg
    }

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        rm.config = savedConfig
        rm.recentLogs = savedLogs
        rm.isVPNConnected = savedVPNConnected
        rm.cancelAllRetries()
        super.tearDown()
    }

    private func custom(_ id: String, _ name: String) -> ServiceEntry {
        ServiceEntry(id: id, name: name, enabled: true, domains: ["\(id).test"], ipRanges: [], isCustom: true)
    }

    // MARK: - The check

    func testANameTakenByABuiltInServiceIsAClashWhateverItsCase() {
        for typed in ["Netflix", "netflix", "  NETFLIX ", "netFlix\n"] {
            XCTAssertEqual(rm.customServiceNameClash(typed), .service(name: "Netflix"), typed)
        }
    }

    func testANameThatIsOnTheBypassListIsAClash() {
        XCTAssertEqual(rm.customServiceNameClash("example.com"), .domain("example.com"))
        XCTAssertEqual(rm.customServiceNameClash("Example.COM "), .domain("example.com"))
    }

    func testAFreeNameAndAnEmptyOneAreNotClashes() {
        XCTAssertNil(rm.customServiceNameClash("Work Tools"))
        XCTAssertNil(rm.customServiceNameClash("example.org"))
        XCTAssertNil(rm.customServiceNameClash("   "))
    }

    func testAServiceKeepingItsOwnNameIsNotAClash() {
        rm.config.services.append(custom("custom_a", "Work Tools"))
        XCTAssertNil(rm.customServiceNameClash("work tools", excluding: "custom_a"))
        XCTAssertEqual(rm.customServiceNameClash("work tools"), .service(name: "Work Tools"))
    }

    // MARK: - Add and update

    func testAddRefusesATakenNameAndSavesNothing() {
        let before = rm.config.services.count
        XCTAssertEqual(rm.addCustomService(name: "Netflix", domains: ["mine.test"], ipRanges: []), .service(name: "Netflix"))
        XCTAssertEqual(rm.addCustomService(name: "example.com", domains: ["mine.test"], ipRanges: []), .domain("example.com"))
        XCTAssertEqual(rm.config.services.count, before)

        XCTAssertNil(rm.addCustomService(name: "Work Tools", domains: ["mine.test"], ipRanges: []))
        XCTAssertEqual(rm.config.services.count, before + 1)
        XCTAssertEqual(rm.addCustomService(name: "WORK TOOLS", domains: ["other.test"], ipRanges: []),
                       .service(name: "Work Tools"), "a second custom service may not take the first one's name")
        XCTAssertEqual(rm.config.services.count, before + 1)
    }

    func testUpdateRefusesARenameOntoATakenNameAndKeepsTheOldOne() throws {
        rm.config.services.append(custom("custom_a", "Work Tools"))
        rm.config.services.append(custom("custom_b", "Home Lab"))

        XCTAssertEqual(rm.updateCustomService(id: "custom_a", name: "home lab", domains: ["a.test"], ipRanges: []),
                       .service(name: "Home Lab"))
        XCTAssertEqual(rm.updateCustomService(id: "custom_a", name: "Spotify", domains: ["a.test"], ipRanges: []),
                       .service(name: "Spotify"))
        XCTAssertEqual(rm.updateCustomService(id: "custom_a", name: "example.com", domains: ["a.test"], ipRanges: []),
                       .domain("example.com"))
        XCTAssertEqual(try XCTUnwrap(rm.config.services.first { $0.id == "custom_a" }).name, "Work Tools")

        XCTAssertNil(rm.updateCustomService(id: "custom_a", name: "Work Tools", domains: ["b.test"], ipRanges: []),
                     "an edit that keeps the name saves")
        XCTAssertEqual(try XCTUnwrap(rm.config.services.first { $0.id == "custom_a" }).domains, ["b.test"])
    }

    func testUndoDoesNotBringBackADeletedServiceWhoseNameWasTakenSince() {
        let deleted = custom("custom_old", "Work Tools")
        XCTAssertNil(rm.addCustomService(name: "work tools", domains: ["new.test"], ipRanges: []),
                     "the name is free once the first one is deleted")
        let before = rm.config.services.map(\.id)
        XCTAssertFalse(rm.restoreCustomService(deleted, at: 0))
        XCTAssertEqual(rm.config.services.map(\.id), before)

        let free = custom("custom_free", "Home Lab")
        XCTAssertTrue(rm.restoreCustomService(free, at: 0), "a name nobody took comes back")
    }

    // MARK: - Import

    private func exportFile(services: [ServiceEntry], domains: [DomainEntry]) throws -> URL {
        var cfg = Config()
        cfg.services = services
        cfg.domains = domains
        let data = try JSONEncoder().encode(RouteManager.ExportData(version: "2.0", exportDate: Date(), config: cfg))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clash-\(UUID().uuidString).json")
        try data.write(to: url)
        tempFiles.append(url)
        return url
    }

    func testImportRefusesACustomServiceNamedLikeABuiltInOne() throws {
        // The file has no built-in services at all; the merge adds Netflix back, and the clash
        // is with that one.
        let url = try exportFile(services: [custom("custom_n", "netflix")], domains: [])
        let before = rm.config.services.map(\.id)

        XCTAssertFalse(rm.importConfig(from: url))
        XCTAssertEqual(rm.config.services.map(\.id), before, "nothing was imported")
        XCTAssertEqual(rm.config.domains.map(\.domain), ["example.com"])
        XCTAssertEqual(rm.lastImportRefusal,
                       "Nothing was imported. The custom service \u{201C}netflix\u{201D} has the same name as the service \u{201C}Netflix\u{201D}. Rename it in the file and import again.")
    }

    func testImportRefusesACustomServiceNamedLikeAnEntryOnItsBypassList() throws {
        let url = try exportFile(services: Config.defaultServices + [custom("custom_s", "Shop.example")],
                                 domains: [DomainEntry(domain: "shop.example")])
        XCTAssertFalse(rm.importConfig(from: url))
        XCTAssertFalse(rm.config.domains.contains { $0.domain == "shop.example" })
        XCTAssertEqual(rm.lastImportRefusal,
                       "Nothing was imported. The custom service \u{201C}Shop.example\u{201D} has the same name as shop.example on the Bypass list. Rename it in the file and import again.")
    }

    func testImportRefusesTwoCustomServicesWithOneName() throws {
        let url = try exportFile(services: Config.defaultServices + [custom("custom_a", "Work Tools"), custom("custom_b", "work tools")],
                                 domains: [])
        XCTAssertFalse(rm.importConfig(from: url))
        XCTAssertNotNil(rm.lastImportRefusal)
    }

    func testImportOfDistinctNamesWorksAndClearsTheLastRefusal() throws {
        let bad = try exportFile(services: [custom("custom_n", "Netflix")], domains: [])
        XCTAssertFalse(rm.importConfig(from: bad))
        XCTAssertNotNil(rm.lastImportRefusal)

        let good = try exportFile(services: Config.defaultServices + [custom("custom_a", "Work Tools")],
                                  domains: [DomainEntry(domain: "imported.example")])
        XCTAssertTrue(rm.importConfig(from: good))
        XCTAssertNil(rm.lastImportRefusal)
        XCTAssertTrue(rm.config.services.contains { $0.id == "custom_a" && $0.name == "Work Tools" })
        XCTAssertTrue(rm.config.domains.contains { $0.domain == "imported.example" })
    }

    // MARK: - Existing configs

    func testAConfigThatAlreadyHasAClashStillLoads() {
        rm.config.services.append(custom("custom_n", "Netflix"))
        rm.config.services.append(custom("custom_e", "example.com"))
        rm.saveConfig()
        rm.config = RouteManager.Config()
        rm.loadConfig()
        XCTAssertFalse(rm.isConfigLoadFailed)
        XCTAssertTrue(rm.config.services.contains { $0.id == "custom_n" && $0.name == "Netflix" })
        XCTAssertTrue(rm.config.services.contains { $0.id == "custom_e" && $0.name == "example.com" })
        XCTAssertTrue(rm.config.domains.contains { $0.domain == "example.com" })
    }

    // MARK: - The lines in Spanish and French

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testTheLinesAreTranslated() throws {
        let en = try lproj("en"), es = try lproj("es"), fr = try lproj("fr")
        let clashes: [ServiceNameClash] = [.service(name: "Netflix"), .domain("example.com")]
        func lines(_ bundle: Bundle) -> [String] {
            clashes.map { $0.message(in: bundle) } + clashes.map { $0.importMessage(service: "Mine", in: bundle) }
        }
        XCTAssertEqual(lines(en), [
            "A service named \u{201C}Netflix\u{201D} already exists. Choose another name, so their routes stay apart.",
            "example.com is on your Bypass list. Choose another name, so their routes stay apart.",
            "Nothing was imported. The custom service \u{201C}Mine\u{201D} has the same name as the service \u{201C}Netflix\u{201D}. Rename it in the file and import again.",
            "Nothing was imported. The custom service \u{201C}Mine\u{201D} has the same name as example.com on the Bypass list. Rename it in the file and import again.",
        ])
        XCTAssertEqual(ServiceNameClash.service(name: "Netflix").message(in: es),
                       "Ya existe un servicio llamado \u{201C}Netflix\u{201D}. Elige otro nombre para que sus rutas no se mezclen.")
        for (name, bundle) in [("es", es), ("fr", fr)] {
            for (line, original) in zip(lines(bundle), lines(en)) {
                XCTAssertNotEqual(line, original, "\(name) has no translation for: \(original)")
                XCTAssertFalse(line.contains("%"), "\(name) left a placeholder in: \(line)")
                XCTAssertTrue(line.contains("Mine") || !original.contains("Mine"), "\(name) lost the service name in: \(line)")
            }
        }
    }
}
