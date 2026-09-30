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

    /// The row draws `note.text` as is, so these pin what the user reads. The expected
    /// Text is built the same way a catalog lookup sees it: one sentence, name bold.
    private func bold(_ name: String) -> Text {
        Text(verbatim: name).foregroundColor(.white).fontWeight(.medium)
    }

    func testNoteTextWithAddress() {
        let note = ProxyReachNote(routeName: "office-proxy", address: "127.0.0.1:18168")
        XCTAssertEqual(note.text, Text("Only apps set to use \(bold("office-proxy")) (\(Text(verbatim: "127.0.0.1:18168"))) go this way. Other apps take the Mac's normal route to these hosts, even if a rule below also matches them."))
        XCTAssertNotEqual(note.text, ProxyReachNote(routeName: "office-proxy", address: "127.0.0.1:18169").text,
                          "positive control: a different address is a different Text")
    }

    /// An enabled route whose listener has not bound a port yet.
    func testNoteTextWhileListenerIsStarting() {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: "127.0.0.1", proxyPort: 1080)
        let note = ProxyReachNote.forRoute(route, listenerPort: nil)
        XCTAssertEqual(note, ProxyReachNote(routeName: "office-proxy", address: nil))
        XCTAssertEqual(note?.text, Text("Only apps set to use \(bold("office-proxy")) go this way. Other apps take the Mac's normal route to these hosts, even if a rule below also matches them."))
        XCTAssertNotEqual(note?.text, ProxyReachNote(routeName: "home-proxy", address: nil).text,
                          "positive control: a different route name is a different Text")
    }

    /// A switched-off route runs no listener and the compiler skips its rules, so the
    /// note must not claim any app goes that way.
    func testNoteForDisabledRouteSaysRuleDoesNothing() {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, enabled: false, proxyHost: "127.0.0.1", proxyPort: 1080)
        let note = ProxyReachNote.forRoute(route, listenerPort: nil)
        XCTAssertEqual(note, ProxyReachNote(routeName: "office-proxy", address: nil, routeOff: true))
        XCTAssertEqual(note?.text, Text("\(bold("office-proxy")) is off, so this rule does nothing."))
        XCTAssertNotEqual(note?.text, ProxyReachNote(routeName: "office-proxy", address: nil).text,
                          "positive control: the off sentence differs from the reach sentence")
    }

    // MARK: - Copy buttons

    /// The listener rejects a request without the local secret (407), so both things
    /// the Routes tab copies must carry it.
    func testCopyPayloadsCarryTheLocalSecret() {
        XCTAssertEqual(RouteRow.CopyKind.proxyURL.text(port: 18168, secret: "s3cr3t"),
                       "http://vpnb:s3cr3t@127.0.0.1:18168")
        let exports = RouteRow.CopyKind.exports.text(port: 18168, secret: "s3cr3t")
        XCTAssertTrue(exports.contains("export HTTPS_PROXY=\"http://vpnb:s3cr3t@127.0.0.1:18168\""), exports)
    }

    // MARK: - Catalogs

    /// The catalog key a `Text(LocalizedStringKey)` looks up, read by reflection.
    private func catalogKey(_ text: Text) -> String? {
        func find(_ value: Any) -> String? {
            for child in Mirror(reflecting: value).children {
                if child.label == "key", let key = child.value as? String { return key }
                if let key = find(child.value) { return key }
            }
            return nil
        }
        return find(text)
    }

    /// Every string these screens add is in en, es and fr, so a Spanish or French Mac
    /// does not fall back to English (the old single Copy button read "Copiar").
    func testNewStringsAreInEveryCatalog() throws {
        let notes = [
            ProxyReachNote(routeName: "r", address: "127.0.0.1:1"),
            ProxyReachNote(routeName: "r", address: nil),
            ProxyReachNote(routeName: "r", address: nil, routeOff: true),
        ]
        var keys = try notes.map { try XCTUnwrap(catalogKey($0.text), "no catalog key in \($0)") }
        keys += try [RouteRow.CopyKind.proxyURL, .exports].map { try XCTUnwrap(catalogKey(Text($0.title))) }
        keys.append("Copied")
        XCTAssertTrue(keys[0].contains("%@"), "positive control: the reflected key is the format, got \(keys[0])")

        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VPNBypassCore/Resources")
        for lang in ["en", "es", "fr"] {
            let url = resources.appendingPathComponent("\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang) does not parse")
            for key in keys {
                XCTAssertNotNil(table[key], "\(lang) is missing \"\(key)\"")
            }
        }
    }
}
