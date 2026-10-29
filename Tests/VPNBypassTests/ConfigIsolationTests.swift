// ConfigIsolationTests.swift
// Regression coverage for the test/production config-path split in
// RouteManager's private init: under XCTest, `configURL` must point at a
// throwaway temp directory, never the user's real
// ~/Library/Application Support/VPNBypass/config.json. Guards against
// reintroducing a shared path that would let `swift test` clobber a real,
// live config on a developer or CI machine that also runs the app.

import XCTest
@testable import VPNBypassCore

@MainActor
final class ConfigIsolationTests: XCTestCase {

    private func realConfigPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VPNBypass", isDirectory: true)
            .appendingPathComponent("config.json").path
    }

    /// saveConfig() is what every mutation path (control surface, RulesTab,
    /// RoutesTab, ...) ultimately calls. Proving it never touches the real
    /// file under XCTest is enough to prove the redirect in RouteManager's
    /// init works, without needing to touch any `private` state directly.
    func testSaveConfigUnderXCTestNeverTouchesTheRealConfigFile() {
        let realPath = realConfigPath()
        let mtimeBefore = (try? FileManager.default.attributesOfItem(atPath: realPath))?[.modificationDate] as? Date

        RouteManager.shared.saveConfig()

        let mtimeAfter = (try? FileManager.default.attributesOfItem(atPath: realPath))?[.modificationDate] as? Date
        XCTAssertEqual(mtimeBefore, mtimeAfter,
                        "saveConfig() under XCTest must never write the real config.json — the temp-dir redirect in RouteManager.init is broken")
    }

    /// The shared test base class snapshots and restores a config file around every test.
    /// It must do that to the test config, never to the real one: restoring the real file
    /// would undo whatever the running app saved during the test.
    func testTheTestBaseClassNeverTouchesTheRealConfigFile() {
        let base = RouteManagerTestCase()
        let temp = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(base.configURL.path.hasPrefix(temp), "got \(base.configURL.path)")
        XCTAssertTrue(base.testBackupURL.path.hasPrefix(temp), "got \(base.testBackupURL.path)")

        let realPath = realConfigPath()
        let inodeBefore = (try? FileManager.default.attributesOfItem(atPath: realPath))?[.systemFileNumber] as? Int
        base.setUp()
        base.tearDown()
        let inodeAfter = (try? FileManager.default.attributesOfItem(atPath: realPath))?[.systemFileNumber] as? Int
        XCTAssertEqual(inodeBefore, inodeAfter, "the real config.json was replaced by the test base class")
    }
}
