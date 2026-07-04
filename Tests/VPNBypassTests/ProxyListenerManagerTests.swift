// ProxyListenerManagerTests.swift
// Coverage for the route→forwarder reconcile + upstream construction (VPN-Bypass-3sc.8).

import XCTest
@testable import VPNBypassCore

@MainActor
final class ProxyListenerManagerTests: XCTestCase {

    func testReconcileStartsThenStopsForwarder() {
        let manager = ProxyListenerManager()
        let route = Route(name: "p", egress: .proxySOCKS5, proxyHost: "127.0.0.1", proxyPort: 9, proxyUser: "u", proxyPass: "p")

        let started = expectation(description: "started")
        manager.reconcile(routes: [route], boundInterface: nil) { started.fulfill() }
        wait(for: [started], timeout: 5)
        XCTAssertNotNil(manager.port(for: route.id), "a loopback listener port is assigned")

        let stopped = expectation(description: "stopped")
        manager.reconcile(routes: [], boundInterface: nil) { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
        XCTAssertNil(manager.port(for: route.id), "listener stops when the route is removed")

        manager.stopAll()
    }

    func testDisabledOrNonProxyRoutesGetNoListener() {
        let manager = ProxyListenerManager()
        let disabled = Route(name: "off", egress: .proxySOCKS5, enabled: false, proxyHost: "127.0.0.1", proxyPort: 9)
        let direct = Route(name: "d", egress: .direct)

        let done = expectation(description: "done")
        manager.reconcile(routes: [disabled, direct], boundInterface: nil) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNil(manager.port(for: disabled.id))
        XCTAssertNil(manager.port(for: direct.id))
        XCTAssertTrue(manager.activePorts.isEmpty)
    }

    func testMakeUpstreamExpandsStickySessionUsername() {
        let route = Route(
            name: "oxy", egress: .proxySOCKS5,
            proxyHost: "pr.oxylabs.io", proxyPort: 7777, proxyUser: "sp", proxyPass: "pw",
            proxyUsernameTemplate: "customer-{user}-sessid-{id}", sessionMode: .sticky
        )
        let up = ProxyListenerManager.makeUpstream(route: route, boundInterface: "en0")
        XCTAssertEqual(up?.host, "pr.oxylabs.io")
        XCTAssertEqual(up?.port, 7777)
        XCTAssertEqual(up?.boundInterface, "en0")
        XCTAssertTrue(up?.username.hasPrefix("customer-sp-sessid-") ?? false)
        XCTAssertNotEqual(up?.username, "customer-sp-sessid-", "a session id was generated")
    }

    func testMakeUpstreamReturnsNilForIncompleteRoute() {
        XCTAssertNil(ProxyListenerManager.makeUpstream(route: Route(name: "x", egress: .proxySOCKS5), boundInterface: nil))
        XCTAssertNil(ProxyListenerManager.makeUpstream(route: Route(name: "x", egress: .proxySOCKS5, proxyHost: "h"), boundInterface: nil), "missing port → nil")
    }

    // MARK: - Tailscale-peer egress (proxy-over-tailnet)

    func testTailnetHostClassification() {
        // Inside 100.64.0.0/10.
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("100.100.0.1"))     // a tailnet peer
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("100.100.0.2"))     // another tailnet peer
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("100.64.0.0"))      // low edge
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("100.127.255.255")) // high edge
        // Outside.
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("100.63.255.255")) // just below
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("100.128.0.0"))    // just above
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("203.0.113.10"))   // a public proxy IP (non-tailnet)
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("not-an-ip"))
    }

    func testGlobalProtectShadowClassification() {
        // GP captures 100.112.0.0/12 (100.112–100.127), which overlaps CGNAT.
        XCTAssertTrue(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.120.0.1"))  // a peer in 100.112/12 — hijacked by GP
        XCTAssertTrue(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.112.0.0"))
        XCTAssertTrue(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.127.255.255"))
        // Safe peers (below 100.112).
        XCTAssertFalse(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.100.0.1")) // a tailnet peer
        XCTAssertFalse(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.100.0.2"))  // another tailnet peer
        XCTAssertFalse(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.100.0.3"))  // another tailnet peer
    }

    func testUsesLocalListenerIncludesTailscaleExit() {
        XCTAssertTrue(ProxyListenerManager.usesLocalListener(.proxyHTTP))
        XCTAssertTrue(ProxyListenerManager.usesLocalListener(.proxySOCKS5))
        XCTAssertTrue(ProxyListenerManager.usesLocalListener(.tailscaleExit))
        XCTAssertFalse(ProxyListenerManager.usesLocalListener(.direct))
        XCTAssertFalse(ProxyListenerManager.usesLocalListener(.vpnDefault))
    }

    func testTailscaleRouteNeverBindsPhysicalInterface() {
        // A Tailscale-peer route must NOT bind the physical NIC — its 100.x upstream
        // routes via the Tailscale utun, so binding en8 would break it.
        let ts = Route(name: "mini", egress: .tailscaleExit,
                       proxyHost: "100.100.0.1", proxyPort: 8888, tailscaleExitNode: "peer-mac")
        XCTAssertNil(ProxyListenerManager.makeUpstream(route: ts, boundInterface: "en8")?.boundInterface)

        // Belt-and-suspenders: even a plain proxy route pointed at a tailnet IP drops the binding.
        let proxyToTailnet = Route(name: "p", egress: .proxyHTTP, proxyHost: "100.100.0.1", proxyPort: 3128)
        XCTAssertNil(ProxyListenerManager.makeUpstream(route: proxyToTailnet, boundInterface: "en8")?.boundInterface)

        // A normal internet proxy KEEPS the VPN-escape binding.
        let oxy = Route(name: "oxy", egress: .proxyHTTP, proxyHost: "dc.oxylabs.io", proxyPort: 8001)
        XCTAssertEqual(ProxyListenerManager.makeUpstream(route: oxy, boundInterface: "en8")?.boundInterface, "en8")
    }

    // MARK: - Upstream fingerprint (live re-point: editing a route restarts its forwarder)

    func testUpstreamFingerprintIsDeterministicWithinProcess() {
        // If it weren't stable, every reconcile would needlessly restart every forwarder.
        let r = Route(name: "p", egress: .proxyHTTP, proxyHost: "h", proxyPort: 8001, proxyUser: "u", proxyPass: "pw")
        XCTAssertEqual(
            ProxyListenerManager.upstreamFingerprint(r, boundInterface: "en0"),
            ProxyListenerManager.upstreamFingerprint(r, boundInterface: "en0")
        )
    }

    func testUpstreamFingerprintChangesWhenUpstreamChanges() {
        let base = Route(name: "p", egress: .proxyHTTP, proxyHost: "h", proxyPort: 8001, proxyUser: "u", proxyPass: "pw")
        let fp: (Route) -> Int = { ProxyListenerManager.upstreamFingerprint($0, boundInterface: "en0") }
        var port = base; port.proxyPort = 8002
        var host = base; host.proxyHost = "h2"
        var user = base; user.proxyUser = "u2"
        var pass = base; pass.proxyPass = "pw2"
        var tmpl = base; tmpl.proxyUsernameTemplate = "customer-{user}"
        var sess = base; sess.sessionMode = .sticky
        XCTAssertNotEqual(fp(base), fp(port), "a port change must restart the forwarder — THE re-point bug")
        XCTAssertNotEqual(fp(base), fp(host))
        XCTAssertNotEqual(fp(base), fp(user))
        XCTAssertNotEqual(fp(base), fp(pass))
        XCTAssertNotEqual(fp(base), fp(tmpl))
        XCTAssertNotEqual(fp(base), fp(sess))
    }

    func testUpstreamFingerprintIgnoresNonUpstreamFields() {
        let base = Route(name: "p", egress: .proxyHTTP, proxyHost: "h", proxyPort: 8001)
        let fp: (Route) -> Int = { ProxyListenerManager.upstreamFingerprint($0, boundInterface: "en0") }
        var renamed = base; renamed.name = "different name"
        var toggled = base; toggled.enabled = false
        var relisten = base; relisten.localListenPort = 18123
        XCTAssertEqual(fp(base), fp(renamed), "renaming a route must NOT restart its forwarder")
        XCTAssertEqual(fp(base), fp(toggled), "enabled is handled by the filter, not the upstream")
        XCTAssertEqual(fp(base), fp(relisten), "the local listen port is not part of the UPSTREAM")
    }

    func testTailnetFingerprintIgnoresBoundInterfaceButInternetProxyDoesNot() {
        // A tailnet route never binds the physical NIC → boundInterface must not affect it
        // (else a Wi-Fi/Ethernet switch would needlessly restart it).
        let ts = Route(name: "mini", egress: .tailscaleExit, proxyHost: "100.100.0.1", proxyPort: 8888)
        XCTAssertEqual(
            ProxyListenerManager.upstreamFingerprint(ts, boundInterface: "en0"),
            ProxyListenerManager.upstreamFingerprint(ts, boundInterface: "en8")
        )
        // An internet proxy's binding IS part of its upstream — a NIC change restarts it.
        let oxy = Route(name: "oxy", egress: .proxyHTTP, proxyHost: "dc.oxylabs.io", proxyPort: 8001)
        XCTAssertNotEqual(
            ProxyListenerManager.upstreamFingerprint(oxy, boundInterface: "en0"),
            ProxyListenerManager.upstreamFingerprint(oxy, boundInterface: "en8")
        )
    }

    func testReconcileKeepsServingAfterInPlaceUpstreamEdit() {
        // Editing a route in place (same id, new port) must keep it served (restart),
        // and an identical reconcile must be a no-op — both on a stable per-route port.
        let manager = ProxyListenerManager()
        let id = UUID()
        let r1 = Route(id: id, name: "p", egress: .proxyHTTP, proxyHost: "127.0.0.1", proxyPort: 9, localListenPort: 18077)

        let e1 = expectation(description: "start")
        manager.reconcile(routes: [r1], boundInterface: nil) { e1.fulfill() }
        wait(for: [e1], timeout: 5)
        XCTAssertEqual(manager.port(for: id), 18077)

        let r2 = Route(id: id, name: "p", egress: .proxyHTTP, proxyHost: "127.0.0.1", proxyPort: 10, localListenPort: 18077)
        let e2 = expectation(description: "restart")
        manager.reconcile(routes: [r2], boundInterface: nil) { e2.fulfill() }
        wait(for: [e2], timeout: 5)
        XCTAssertEqual(manager.port(for: id), 18077, "still served on its stable port after an in-place edit")

        manager.stopAll()
    }

    func testReconcileStartsListenerForTailscaleExitRoute() {
        // A Tailscale-peer route is served by a loopback listener like any proxy route
        // (the listener binds locally; the upstream isn't dialed until a client connects).
        let manager = ProxyListenerManager()
        let ts = Route(name: "mini", egress: .tailscaleExit,
                       proxyHost: "100.100.0.1", proxyPort: 8888, tailscaleExitNode: "peer-mac")
        let started = expectation(description: "started")
        manager.reconcile(routes: [ts], boundInterface: "en8") { started.fulfill() }
        wait(for: [started], timeout: 5)
        XCTAssertNotNil(manager.port(for: ts.id), "a Tailscale-peer route gets a loopback listener")
        manager.stopAll()
    }
}
