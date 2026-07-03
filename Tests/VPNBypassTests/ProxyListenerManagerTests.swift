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
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("<tailnet-peer-ip>"))   // peer-mac
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("<tailnet-peer-ip>"))   // peer-relay
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("100.64.0.0"))      // low edge
        XCTAssertTrue(ProxyListenerManager.isTailnetHost("100.127.255.255")) // high edge
        // Outside.
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("100.63.255.255")) // just below
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("100.128.0.0"))    // just above
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("<proxy-exit-ip>"))    // an Oxylabs IP
        XCTAssertFalse(ProxyListenerManager.isTailnetHost("not-an-ip"))
    }

    func testGlobalProtectShadowClassification() {
        // GP captures 100.112.0.0/12 (100.112–100.127), which overlaps CGNAT.
        XCTAssertTrue(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("<tailnet-peer-ip>"))  // nuc — hijacked
        XCTAssertTrue(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.112.0.0"))
        XCTAssertTrue(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("100.127.255.255"))
        // Safe peers (below 100.112).
        XCTAssertFalse(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("<tailnet-peer-ip>")) // peer-mac
        XCTAssertFalse(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("<tailnet-peer-ip>"))  // peer-relay
        XCTAssertFalse(ProxyListenerManager.isTailnetHostShadowedByGlobalProtect("<tailnet-peer-ip>"))  // peer-server-b
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
                       proxyHost: "<tailnet-peer-ip>", proxyPort: 8888, tailscaleExitNode: "peer-mac")
        XCTAssertNil(ProxyListenerManager.makeUpstream(route: ts, boundInterface: "en8")?.boundInterface)

        // Belt-and-suspenders: even a plain proxy route pointed at a tailnet IP drops the binding.
        let proxyToTailnet = Route(name: "p", egress: .proxyHTTP, proxyHost: "<tailnet-peer-ip>", proxyPort: 3128)
        XCTAssertNil(ProxyListenerManager.makeUpstream(route: proxyToTailnet, boundInterface: "en8")?.boundInterface)

        // A normal internet proxy KEEPS the VPN-escape binding.
        let oxy = Route(name: "oxy", egress: .proxyHTTP, proxyHost: "dc.oxylabs.io", proxyPort: 8001)
        XCTAssertEqual(ProxyListenerManager.makeUpstream(route: oxy, boundInterface: "en8")?.boundInterface, "en8")
    }

    func testReconcileStartsListenerForTailscaleExitRoute() {
        // A Tailscale-peer route is served by a loopback listener like any proxy route
        // (the listener binds locally; the upstream isn't dialed until a client connects).
        let manager = ProxyListenerManager()
        let ts = Route(name: "mini", egress: .tailscaleExit,
                       proxyHost: "<tailnet-peer-ip>", proxyPort: 8888, tailscaleExitNode: "peer-mac")
        let started = expectation(description: "started")
        manager.reconcile(routes: [ts], boundInterface: "en8") { started.fulfill() }
        wait(for: [started], timeout: 5)
        XCTAssertNotNil(manager.port(for: ts.id), "a Tailscale-peer route gets a loopback listener")
        manager.stopAll()
    }
}
