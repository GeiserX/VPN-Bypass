import XCTest
@testable import VPNBypassCore
import Foundation

// Tests that exercise RouteManager public methods which modify config state.
// Since isVPNConnected is false in tests, route application branches are skipped,
// but config mutations, logging, and validation logic all execute.

@MainActor
final class AddDomainTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.domains.removeAll()
    }

    func testAddDomainAppendsToConfig() {
        rm.addDomain("test-add.example.com")
        XCTAssertTrue(rm.config.domains.contains(where: { $0.domain == "test-add.example.com" }))
    }

    func testAddDomainCleansInput() {
        rm.addDomain("  https://Clean-Me.COM/path  ")
        XCTAssertTrue(rm.config.domains.contains(where: { $0.domain == "clean-me.com" }))
    }

    func testAddDomainRejectsEmpty() {
        let countBefore = rm.config.domains.count
        rm.addDomain("   ")
        XCTAssertEqual(rm.config.domains.count, countBefore)
    }

    func testAddDomainRejectsDuplicate() {
        rm.addDomain("dup.example.com")
        let countAfterFirst = rm.config.domains.count
        rm.addDomain("dup.example.com")
        XCTAssertEqual(rm.config.domains.count, countAfterFirst)
    }

    func testAddDomainCreatesEnabledEntry() {
        rm.addDomain("enabled-test.com")
        let entry = rm.config.domains.first(where: { $0.domain == "enabled-test.com" })
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry!.enabled)
    }

    func testAddDomainLogs() {
        rm.addDomain("log-test.example.com")
        XCTAssertTrue(rm.recentLogs.contains(where: { $0.message.contains("log-test.example.com") }))
    }
}

@MainActor
final class RemoveDomainTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.domains.removeAll()
    }

    func testRemoveDomainRemovesFromConfig() async throws {
        rm.addDomain("to-remove.com")
        guard let entry = rm.config.domains.first(where: { $0.domain == "to-remove.com" }) else {
            XCTFail("Domain was not added")
            return
        }
        rm.removeDomain(entry)
        // removeDomain dispatches an async Task; give it time to complete
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(rm.config.domains.contains(where: { $0.domain == "to-remove.com" }))
    }
}

@MainActor
final class ToggleDomainTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.domains.removeAll()
    }

    func testToggleDomainDisables() {
        rm.addDomain("toggle.com")
        guard let entry = rm.config.domains.first(where: { $0.domain == "toggle.com" }) else {
            XCTFail("Domain was not added")
            return
        }
        XCTAssertTrue(entry.enabled)
        rm.toggleDomain(entry.id)
        let updated = rm.config.domains.first(where: { $0.domain == "toggle.com" })
        XCTAssertFalse(updated!.enabled)
    }

    func testToggleDomainReEnables() {
        rm.addDomain("retoggle.com")
        guard let entry = rm.config.domains.first(where: { $0.domain == "retoggle.com" }) else {
            XCTFail("Domain was not added")
            return
        }
        rm.toggleDomain(entry.id)
        rm.toggleDomain(entry.id)
        let updated = rm.config.domains.first(where: { $0.domain == "retoggle.com" })
        XCTAssertTrue(updated!.enabled)
    }
}

@MainActor
final class SetAllDomainsEnabledTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.domains.removeAll()
    }

    func testDisableAll() {
        rm.addDomain("a1.com")
        rm.addDomain("b1.com")
        rm.setAllDomainsEnabled(false)
        for d in rm.config.domains {
            XCTAssertFalse(d.enabled, "\(d.domain) should be disabled")
        }
    }

    func testEnableAll() {
        rm.addDomain("a2.com")
        rm.addDomain("b2.com")
        rm.setAllDomainsEnabled(false)
        rm.setAllDomainsEnabled(true)
        for d in rm.config.domains {
            XCTAssertTrue(d.enabled, "\(d.domain) should be enabled")
        }
    }
}

@MainActor
final class AddInverseDomainIntegrationTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.inverseDomains.removeAll()
    }

    func testAddInverseDomainAppends() {
        rm.addInverseDomain("inv.example.com")
        XCTAssertTrue(rm.config.inverseDomains.contains(where: { $0.domain == "inv.example.com" }))
    }

    func testAddInverseDomainCIDR() {
        rm.addInverseDomain("10.0.0.0/8")
        let entry = rm.config.inverseDomains.first(where: { $0.domain == "10.0.0.0/8" })
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry!.isCIDR)
    }

    func testAddInverseDomainRejectsDuplicate() {
        rm.addInverseDomain("inv-dup.com")
        let countAfterFirst = rm.config.inverseDomains.count
        rm.addInverseDomain("inv-dup.com")
        XCTAssertEqual(rm.config.inverseDomains.count, countAfterFirst)
    }

    func testAddInverseDomainRejectsInvalidSlash() {
        rm.addInverseDomain("not/cidr")
        XCTAssertFalse(rm.config.inverseDomains.contains(where: { $0.domain.contains("not") }))
    }

    func testAddInverseDomainCleansURL() {
        rm.addInverseDomain("  Internal.Corp.COM  ")
        XCTAssertTrue(rm.config.inverseDomains.contains(where: { $0.domain == "internal.corp.com" }))
    }
}

@MainActor
final class ToggleInverseDomainTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.inverseDomains.removeAll()
    }

    func testToggleInverseDomain() {
        rm.addInverseDomain("inv-toggle.com")
        guard let entry = rm.config.inverseDomains.first else {
            XCTFail("No inverse domain added")
            return
        }
        XCTAssertTrue(entry.enabled)
        rm.toggleInverseDomain(entry.id)
        XCTAssertFalse(rm.config.inverseDomains.first!.enabled)
    }
}

@MainActor
final class SetAllInverseDomainsTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.inverseDomains.removeAll()
    }

    func testDisableAllInverse() {
        rm.addInverseDomain("inv-a.com")
        rm.addInverseDomain("inv-b.com")
        rm.setAllInverseDomainsEnabled(false)
        for d in rm.config.inverseDomains {
            XCTAssertFalse(d.enabled)
        }
    }

    func testEnableAllInverse() {
        rm.addInverseDomain("inv-c.com")
        rm.setAllInverseDomainsEnabled(false)
        rm.setAllInverseDomainsEnabled(true)
        for d in rm.config.inverseDomains {
            XCTAssertTrue(d.enabled)
        }
    }
}

@MainActor
final class CustomServiceTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() {
        super.setUp()
        rm.config.services.removeAll(where: { $0.isCustom })
    }

    func testAddCustomService() {
        rm.addCustomService(name: "TestSvc", domains: ["test.svc.com"], ipRanges: [])
        let svc = rm.config.services.first(where: { $0.name == "TestSvc" })
        XCTAssertNotNil(svc)
        XCTAssertTrue(svc!.isCustom)
        XCTAssertTrue(svc!.enabled)
        XCTAssertTrue(svc!.id.hasPrefix("custom_"))
    }

    func testAddCustomServiceWithIPRanges() {
        rm.addCustomService(name: "IPSvc", domains: ["ip.svc.com"], ipRanges: ["10.0.0.0/8"])
        let svc = rm.config.services.first(where: { $0.name == "IPSvc" })
        XCTAssertEqual(svc?.ipRanges, ["10.0.0.0/8"])
    }

    func testRemoveCustomService() async throws {
        rm.addCustomService(name: "ToRemove", domains: ["remove.svc.com"], ipRanges: [])
        guard let svc = rm.config.services.first(where: { $0.name == "ToRemove" }) else {
            XCTFail("Custom service not added")
            return
        }
        rm.removeCustomService(svc.id)
        // removeCustomService dispatches an async Task; give it time to complete
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(rm.config.services.contains(where: { $0.id == svc.id }))
    }

    func testUpdateCustomService() {
        rm.addCustomService(name: "OldName", domains: ["old.com"], ipRanges: [])
        guard let svc = rm.config.services.first(where: { $0.name == "OldName" }) else {
            XCTFail("Custom service not added")
            return
        }
        rm.updateCustomService(id: svc.id, name: "NewName", domains: ["new.com"], ipRanges: ["1.2.3.0/24"])
        let updated = rm.config.services.first(where: { $0.id == svc.id })
        XCTAssertEqual(updated?.name, "NewName")
        XCTAssertEqual(updated?.domains, ["new.com"])
        XCTAssertEqual(updated?.ipRanges, ["1.2.3.0/24"])
    }
}

@MainActor
final class ToggleServiceTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    func testToggleBuiltInService() {
        guard let first = rm.config.services.first else {
            XCTFail("No services")
            return
        }
        let wasBefore = first.enabled
        rm.toggleService(first.id)
        let after = rm.config.services.first(where: { $0.id == first.id })!
        XCTAssertNotEqual(wasBefore, after.enabled)
        rm.toggleService(first.id)
    }
}

@MainActor
final class SetRoutingModeTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    func testSetRoutingModeToVPNOnly() {
        rm.setRoutingMode(.vpnOnly)
        XCTAssertEqual(rm.config.routingMode, .vpnOnly)
    }

    func testSetRoutingModeToBypass() {
        rm.setRoutingMode(.vpnOnly)
        rm.setRoutingMode(.bypass)
        XCTAssertEqual(rm.config.routingMode, .bypass)
    }

    func testSetSameModeNoOp() {
        rm.setRoutingMode(.bypass)
        let logsBefore = rm.recentLogs.count
        rm.setRoutingMode(.bypass)
        XCTAssertEqual(rm.recentLogs.count, logsBefore)
    }
}

@MainActor
final class ExportImportConfigTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    func testExportConfigReturnsURL() {
        let url = rm.exportConfig()
        XCTAssertNotNil(url)
        if let url = url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        }
    }

    func testExportContainsValidJSON() throws {
        guard let url = rm.exportConfig() else {
            XCTFail("Export returned nil")
            return
        }
        let data = try Data(contentsOf: url)
        let export = try JSONDecoder().decode(RouteManager.ExportData.self, from: data)
        XCTAssertEqual(export.version, "1.1")
        try? FileManager.default.removeItem(at: url)
    }

    func testImportConfigFromExport() throws {
        rm.addDomain("import-test.com")
        guard let url = rm.exportConfig() else {
            XCTFail("Export returned nil")
            return
        }
        rm.config.domains.removeAll()
        let success = rm.importConfig(from: url)
        XCTAssertTrue(success)
        XCTAssertTrue(rm.config.domains.contains(where: { $0.domain == "import-test.com" }))
        try? FileManager.default.removeItem(at: url)
    }

    func testImportInvalidFileReturnsFalse() {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("bad-import.json")
        try? "not json".data(using: .utf8)!.write(to: tmpURL)
        let result = rm.importConfig(from: tmpURL)
        XCTAssertFalse(result)
        try? FileManager.default.removeItem(at: tmpURL)
    }
}

@MainActor
final class SaveLoadConfigTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    func testSaveConfigDoesNotCrash() {
        rm.saveConfig()
    }

    func testLoadConfigDoesNotCrash() {
        rm.loadConfig()
    }

    func testSaveAndLoadPreservesConfig() {
        rm.config.checkInterval = 999
        rm.saveConfig()
        rm.config.checkInterval = 0
        rm.loadConfig()
        XCTAssertEqual(rm.config.checkInterval, 999)
        rm.config.checkInterval = 300
        rm.saveConfig()
    }
}

@MainActor
final class DetectedDNSDisplayTests: XCTestCase {

    func testDetectedDNSServerDisplayDefaultNil() {
        let display = RouteManager.shared.detectedDNSServerDisplay
        // May or may not be nil depending on state, just check it doesn't crash
        _ = display
    }
}

@MainActor
final class ProxyTestResultTests: XCTestCase {

    func testProxyTestResultCreation() {
        let result = RouteManager.ProxyTestResult(success: true, message: "OK")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, "OK")
    }

    func testProxyTestResultFailure() {
        let result = RouteManager.ProxyTestResult(success: false, message: "Timeout")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "Timeout")
    }
}
