// ProxyRuleReachTests.swift
// Coverage for the Custom-mode screens that explain proxy routes: the note under a
// rule that points at a local-listener route, and the listener address, which must
// never go through locale number formatting (it printed 127.0.0.1:18.168).

import XCTest
import SwiftUI
@testable import VPNBypassCore

final class ProxyRuleReachTests: XCTestCase {

    // MARK: - Listener address

    func testListenerAddressStringHasNoGrouping() {
        XCTAssertEqual(LocalListenerAddress.string(port: 18168), "127.0.0.1:18168")
        XCTAssertEqual(LocalListenerAddress.string(port: 65535), "127.0.0.1:65535")
        XCTAssertEqual(LocalListenerAddress.string(port: 80), "127.0.0.1:80")
    }

    /// The row draws the port with this Text. A `Text("127.0.0.1:\(port)")` literal is a
    /// LocalizedStringKey, which formats the integer for the locale; only a verbatim Text
    /// equals `Text(verbatim:)` of the same characters.
    func testListenerAddressTextIsVerbatim() {
        XCTAssertEqual(LocalListenerAddress.text(port: 18168), Text(verbatim: "127.0.0.1:18168"))
        XCTAssertNotEqual(LocalListenerAddress.text(port: 18168), Text("127.0.0.1:\(UInt16(18168))"),
                          "positive control: the localized form is a different Text")
    }

    // MARK: - Reach note

    func testNoteForEveryListenerEgress() {
        for egress in [Egress.proxyHTTP, .proxySOCKS5, .tailscaleExit] {
            let route = Route(name: "office-proxy", egress: egress, proxyHost: "127.0.0.1", proxyPort: 1080)
            XCTAssertEqual(ProxyReachNote.forRoute(route, listenerPort: 18168),
                           ProxyReachNote(routeName: "office-proxy", address: "127.0.0.1:18168"),
                           "\(egress)")
        }
    }

    func testNoNoteForKernelRoutes() {
        XCTAssertNil(ProxyReachNote.forRoute(Route(name: "Direct", egress: .direct), listenerPort: nil))
        XCTAssertNil(ProxyReachNote.forRoute(Route(name: "VPN", egress: .vpnDefault), listenerPort: nil))
        var pinned = Route(name: "Work VPN", egress: .vpnDefault)
        pinned.vpnSelector = VPNSelector(kind: .interface, interfaceName: "utun4")
        XCTAssertNil(ProxyReachNote.forRoute(pinned, listenerPort: nil),
                     "a VPN route pinned to one tunnel is still a kernel route for every app")
    }

    func testNoNoteForDanglingRoute() {
        XCTAssertNil(ProxyReachNote.forRoute(nil, listenerPort: 18168))
    }

    func testPlainTextWithAddress() {
        let note = ProxyReachNote(routeName: "office-proxy", address: "127.0.0.1:18168")
        XCTAssertEqual(note.plainText,
                       "Only apps set to use office-proxy (127.0.0.1:18168) go this way. Other apps are not affected by this rule.")
    }

    func testPlainTextWhileListenerIsDown() {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, enabled: false, proxyHost: "127.0.0.1", proxyPort: 1080)
        let note = ProxyReachNote.forRoute(route, listenerPort: nil)
        XCTAssertEqual(note?.address, nil)
        XCTAssertEqual(note?.plainText,
                       "Only apps set to use office-proxy go this way. Other apps are not affected by this rule.")
    }
}
