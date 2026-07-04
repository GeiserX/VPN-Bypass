// ExportSanitizationTests.swift
// Coverage for the export credential-strip (VPN-Bypass-3sc.5): a shared/exported
// config must never carry proxy usernames/passwords (they leak when users attach
// exports to bug reports). The in-app config keeps them; Import re-prompts.

import XCTest
@testable import VPNBypassCore

final class ExportSanitizationTests: XCTestCase {

    func testSanitizedForExportClearsAllCredentials() throws {
        var cfg = RouteManager.Config()
        cfg.proxyConfig.enabled = true
        cfg.proxyConfig.server = "disp.oxylabs.io"
        cfg.proxyConfig.port = 8001
        cfg.proxyConfig.username = "secret-user"
        cfg.proxyConfig.password = "secret-pass"
        cfg.routes = [Route(name: "p", egress: .proxySOCKS5, proxyHost: "h", proxyPort: 1,
                            proxyUser: "route-user", proxyPass: "route-pass")]

        let s = cfg.sanitizedForExport()

        // Credentials cleared.
        XCTAssertEqual(s.proxyConfig.username, "")
        XCTAssertEqual(s.proxyConfig.password, "")
        XCTAssertNil(s.routes.first?.proxyUser)
        XCTAssertNil(s.routes.first?.proxyPass)

        // Non-credential config preserved.
        XCTAssertEqual(s.proxyConfig.server, "disp.oxylabs.io")
        XCTAssertEqual(s.proxyConfig.port, 8001)
        XCTAssertTrue(s.proxyConfig.enabled)
        XCTAssertEqual(s.routes.first?.proxyHost, "h")

        // Original untouched — the running app keeps its live credentials.
        XCTAssertEqual(cfg.proxyConfig.username, "secret-user")

        // The ENCODED export JSON contains none of the secret values.
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        XCTAssertFalse(json.contains("secret-user"))
        XCTAssertFalse(json.contains("secret-pass"))
        XCTAssertFalse(json.contains("route-user"))
        XCTAssertFalse(json.contains("route-pass"))
    }
}
