// ControlSurfaceTests.swift
// The integration seam: ControlSurface.handle turns a decoded ControlRequest into
// a live RouteManager mutation. Proves a scripted route.set re-points a running
// listener (keeping its stable local port), that read verbs don't mutate, and that
// a password sent via `secrets` never comes back in the response. The socket
// framing itself is covered separately by ControlSocketServerTests (stub handler).

import XCTest
@testable import VPNBypassCore

@MainActor
final class ControlSurfaceTests: XCTestCase {

    private var savedConfig: RouteManager.Config!

    override func setUp() async throws {
        savedConfig = RouteManager.shared.config
    }

    override func tearDown() async throws {
        ProxyListenerManager.shared.stopAll()
        RouteManager.shared.config = savedConfig
    }

    /// The listener starts off the main thread, so poll for its port to settle
    /// rather than asserting the instant reconcile returns.
    private func waitForPort(_ id: UUID, timeout: TimeInterval = 3) async -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = ProxyListenerManager.shared.port(for: id) { return p }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return ProxyListenerManager.shared.port(for: id)
    }

    func testRouteSetRepointsLiveListenerKeepingStablePort() async {
        let id = UUID()
        var cfg = RouteManager.shared.config
        cfg.multiRouteEnabled = true
        cfg.routes = [Route(id: id, name: "oxy", egress: .proxyHTTP,
                            proxyHost: "127.0.0.1", proxyPort: 8001, localListenPort: 18099)]
        RouteManager.shared.config = cfg

        await RouteManager.shared.reconcileProxyListeners()
        let started = await waitForPort(id)
        XCTAssertEqual(started, 18099, "listener up on its stable port")

        // Re-point the upstream port (the canonical "switch the exit IP" command).
        let resp = await ControlSurface.handle(ControlRequest(cmd: "route.set",
                                                              args: ["id": id.uuidString, "port": "8002"]))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.result?.routes?.first?.proxyPort, 8002)
        XCTAssertEqual(RouteManager.shared.config.routes.first?.proxyPort, 8002, "change persisted to config")
        let afterRepoint = await waitForPort(id)
        XCTAssertEqual(afterRepoint, 18099,
                       "listener re-pointed in place — stable local port survives (HTTPS_PROXY keeps working)")
    }

    func testRouteSetPasswordIsNeverEchoed() async {
        let id = UUID()
        var cfg = RouteManager.shared.config
        cfg.multiRouteEnabled = true
        cfg.routes = [Route(id: id, name: "oxy", egress: .proxyHTTP, proxyHost: "127.0.0.1", proxyPort: 8001)]
        RouteManager.shared.config = cfg

        let secret = "s3cr3t-should-never-appear"
        let resp = await ControlSurface.handle(ControlRequest(cmd: "route.set",
                                                              args: ["id": id.uuidString],
                                                              secrets: ["pass": secret]))
        XCTAssertTrue(resp.ok)
        // Stored on the route...
        XCTAssertEqual(RouteManager.shared.config.routes.first?.proxyPass, secret)
        // ...but the encoded response must not contain it anywhere.
        let json = String(data: try! JSONEncoder().encode(resp), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains(secret), "the password must never appear in a control response")
        XCTAssertEqual(resp.result?.routes?.first?.hasPassword, true, "only a boolean signal is exposed")
    }

    func testReadVerbDoesNotMutateOrStartListeners() async {
        var cfg = RouteManager.shared.config
        cfg.multiRouteEnabled = true
        cfg.routes = [Route(name: "r", egress: .proxyHTTP, proxyHost: "127.0.0.1", proxyPort: 8001)]
        RouteManager.shared.config = cfg

        let before = RouteManager.shared.config.routes
        let resp = await ControlSurface.handle(ControlRequest(cmd: "status"))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.result?.routes?.count, 1)
        XCTAssertEqual(RouteManager.shared.config.routes, before, "a read verb leaves config untouched")
        XCTAssertTrue(ProxyListenerManager.shared.activePorts.isEmpty, "status must not start listeners")
    }

    func testUnknownCommandErrorsWithoutMutating() async {
        var cfg = RouteManager.shared.config
        cfg.routes = [Route(name: "r", egress: .proxyHTTP, proxyHost: "h", proxyPort: 8001)]
        RouteManager.shared.config = cfg
        let before = RouteManager.shared.config.routes

        let resp = await ControlSurface.handle(ControlRequest(cmd: "route.nuke", args: ["id": "x"]))
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "unknown_command")
        XCTAssertEqual(RouteManager.shared.config.routes, before)
    }
}
