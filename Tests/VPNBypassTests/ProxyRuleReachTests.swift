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
            XCTAssertEqual(ProxyReachNote.forRoute(route), ProxyReachNote(routeName: "office-proxy"), "\(egress)")
        }
    }

    func testNoNoteForKernelRoutes() {
        XCTAssertNil(ProxyReachNote.forRoute(Route(name: "Direct", egress: .direct)))
        XCTAssertNil(ProxyReachNote.forRoute(Route(name: "VPN", egress: .vpnDefault)))
        var pinned = Route(name: "Work VPN", egress: .vpnDefault)
        pinned.vpnSelector = VPNSelector(kind: .interface, interfaceName: "utun4")
        XCTAssertNil(ProxyReachNote.forRoute(pinned),
                     "a VPN route pinned to one tunnel is still a kernel route for every app")
    }

    func testNoNoteForDanglingRoute() {
        XCTAssertNil(ProxyReachNote.forRoute(nil))
    }

    /// The rule row's detail line, the short form section 3.3 asks for.
    func testNoteLineForAnEnabledRoute() {
        let note = ProxyReachNote(routeName: "office-proxy")
        XCTAssertEqual(note.line(), "Only apps set to use office-proxy. Other apps take the Mac's normal route, even if a rule below matches.")
        XCTAssertNotEqual(note.line(), ProxyReachNote(routeName: "home-proxy").line(),
                          "positive control: a different route name is a different line")
    }

    /// A switched-off route runs no listener and the compiler skips its rules, so the
    /// line must not claim any app goes that way.
    func testNoteForDisabledRouteSaysRuleDoesNothing() {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, enabled: false, proxyHost: "127.0.0.1", proxyPort: 1080)
        let note = ProxyReachNote.forRoute(route)
        XCTAssertEqual(note, ProxyReachNote(routeName: "office-proxy", routeOff: true))
        XCTAssertEqual(note?.line(), "office-proxy is off, so this rule does nothing.")
    }

    /// Both lines are translated, with the route's name where each language puts it.
    func testNoteLinesAreTranslated() throws {
        let resources = Self.resources
        let es = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("es.lproj")))
        let fr = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("fr.lproj")))
        XCTAssertEqual(ProxyReachNote(routeName: "office-proxy").line(in: es),
                       "Solo las apps configuradas para usar office-proxy. Las demás apps toman la ruta normal del Mac, aunque coincida una regla de más abajo.")
        XCTAssertEqual(ProxyReachNote(routeName: "office-proxy", routeOff: true).line(in: fr),
                       "La route office-proxy est désactivée, cette règle n'a donc aucun effet.")
    }

    // MARK: - Copy actions

    /// The listener rejects a request without the local secret (407), so both things
    /// the Routes page copies must carry it.
    func testCopyPayloadsCarryTheLocalSecret() {
        XCTAssertEqual(RouteRow.CopyKind.proxyURL.text(port: 18168, secret: "s3cr3t"),
                       "http://vpnb:s3cr3t@127.0.0.1:18168")
        let exports = RouteRow.CopyKind.exports.text(port: 18168, secret: "s3cr3t")
        XCTAssertTrue(exports.contains("export HTTPS_PROXY=\"http://vpnb:s3cr3t@127.0.0.1:18168\""), exports)
    }

    /// The sign-in hint left the top of the page: it shows once, in the line after a proxy
    /// URL copy, naming the route.
    func testTheSignInHintShowsAfterAProxyURLCopy() {
        let line = RouteRow.CopyKind.proxyURL.confirmation(routeName: "office-proxy")
        XCTAssertTrue(line.contains("office-proxy"), line)
        XCTAssertTrue(line.contains("the user is vpnb"), line)
        XCTAssertFalse(RouteRow.CopyKind.exports.confirmation(routeName: "office-proxy").contains("the user is vpnb"),
                       "positive control: the shell exports need no browser sign-in")
    }

    // MARK: - Catalogs

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VPNBypassCore/Resources")

    /// Every string these screens add is in en, es and fr, so a Spanish or French Mac
    /// does not fall back to English (the old single Copy button read "Copiar").
    func testNewStringsAreInEveryCatalog() throws {
        let keys = [
            "Only apps set to use %@. Other apps take the Mac's normal route, even if a rule below matches.",
            "%@ is off, so this rule does nothing.",
            "Copy Proxy URL", "Copy Shell Exports",
            "Copied the proxy URL for %@. Paste it into an app's proxy setting. A browser asks you to sign in: the user is vpnb, the password is the part between vpnb: and @ in the URL.",
            "Copied the shell exports for %@. Paste them into a shell, and the apps you start from it use this route.",
        ]
        for lang in ["en", "es", "fr"] {
            let url = Self.resources.appendingPathComponent("\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(lang) does not parse")
            for key in keys {
                XCTAssertNotNil(table[key], "\(lang) is missing \"\(key)\"")
            }
        }
    }
}
