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
}
