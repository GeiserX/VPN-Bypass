// LiveProxyEgressTests.swift
// LIVE, opt-in verification (skipped unless OXY_LIVE=1): proves ProxyForwarder
// tunnels through the real upstream relay and the upstream hop escapes the VPN
// when bound to the physical interface. Reads the upstream from the shell's
// HTTPS_PROXY/ALL_PROXY env so no secrets live in the repo. Never runs in CI.

import XCTest
@testable import VPNBypassCore

final class LiveProxyEgressTests: XCTestCase {

    func testForwarderExitIPDiffersFromDirect() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OXY_LIVE"] == "1", "live test — run with OXY_LIVE=1")

        let proxyURL = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? env["ALL_PROXY"] ?? env["all_proxy"]
        guard let proxyURL, let upstream = Self.parseUpstream(proxyURL, iface: env["OXY_IFACE"]) else {
            throw XCTSkip("no upstream proxy URL in env")
        }

        let forwarder = ProxyForwarder(listenPort: 0, upstream: upstream)
        try forwarder.start()
        defer { forwarder.stop() }
        guard let port = forwarder.boundPort else { return XCTFail("forwarder did not bind a port") }

        let viaForwarder = try await Self.fetchExitIP(throughLoopbackPort: port)
        let direct = try await Self.fetchExitIP(throughLoopbackPort: nil)

        print("LIVE-EGRESS via forwarder(en\(env["OXY_IFACE"] ?? "?")): \(viaForwarder)")
        print("LIVE-EGRESS direct (default route): \(direct)")

        XCTAssertFalse(viaForwarder.isEmpty)
        XCTAssertFalse(viaForwarder.hasPrefix("10."), "forwarder exit should NOT be the corporate VPN IP")
        XCTAssertFalse(viaForwarder.hasPrefix("192.168."), "forwarder exit should NOT be a LAN IP")
        XCTAssertNotEqual(viaForwarder, direct, "forwarder must egress somewhere other than the default route")
    }

    // MARK: - Helpers

    private static func fetchExitIP(throughLoopbackPort port: UInt16?) async throws -> String {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let port {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: Int(port),
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: Int(port),
            ]
        } else {
            // Force NO proxy (ignore the inherited env proxy) → the default route.
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesHTTPEnable as String: 0,
            ]
        }
        let session = URLSession(configuration: cfg)
        let (data, _) = try await session.data(from: URL(string: "https://ipinfo.io/ip")!)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Parse `http://user:pass@host:port` tolerantly (password may contain `=`).
    static func parseUpstream(_ urlString: String, iface: String?) -> ProxyForwarder.Upstream? {
        var s = urlString
        for p in ["http://", "https://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        guard let at = s.lastIndex(of: "@") else { return nil }
        let userinfo = String(s[s.startIndex..<at])
        let hostport = String(s[s.index(after: at)...])
        guard let cu = userinfo.firstIndex(of: ":") else { return nil }
        let user = String(userinfo[userinfo.startIndex..<cu])
        let pass = String(userinfo[userinfo.index(after: cu)...])
        guard let ch = hostport.lastIndex(of: ":"), let port = UInt16(hostport[hostport.index(after: ch)...]) else { return nil }
        let host = String(hostport[hostport.startIndex..<ch])
        return ProxyForwarder.Upstream(host: host, port: port, username: user, password: pass, boundInterface: iface)
    }

    /// End-to-end via the REAL app-startup path: set a proxy route + the
    /// experimental flag, call RouteManager.reconcileProxyListeners() (which also
    /// detects the physical interface), and confirm the listener it starts — on
    /// the route's STABLE port — egresses through Oxylabs.
    @MainActor
    func testAppReconcileServesOxylabsOnStablePort() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["OXY_LIVE"] == "1", "live test — run with OXY_LIVE=1")
        guard let proxyURL = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? env["ALL_PROXY"] ?? env["all_proxy"],
              let up = Self.parseUpstream(proxyURL, iface: nil) else { throw XCTSkip("no upstream") }

        let routeId = UUID()
        let route = Route(id: routeId, name: "oxy-live", egress: .proxyHTTP,
                          proxyHost: up.host, proxyPort: Int(up.port),
                          proxyUser: up.username, proxyPass: up.password, localListenPort: 18443)
        var cfg = RouteManager.shared.config
        cfg.multiRouteEnabled = true
        cfg.routes = [route]
        RouteManager.shared.config = cfg
        RouteManager.shared.localGateway = env["OXY_GW"] ?? "<lan-gateway>"

        await RouteManager.shared.reconcileProxyListeners()
        try await Task.sleep(nanoseconds: 1_500_000_000)  // let the off-main start settle
        defer { ProxyListenerManager.shared.stopAll() }

        let port = ProxyListenerManager.shared.port(for: routeId)
        print("APP-RECONCILE listener port: \(port.map(String.init) ?? "nil")")
        XCTAssertEqual(port, 18443, "stable per-route port honored")
        guard let port else { return }

        let exitIP = try await Self.fetchExitIP(throughLoopbackPort: port)
        print("APP-RECONCILE egress: \(exitIP)")
        XCTAssertFalse(exitIP.hasPrefix("10."), "should not be the corporate VPN IP")
        XCTAssertFalse(exitIP.hasPrefix("192.168."), "should not be a LAN IP")
    }
}
