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
}
