// DomainsPageTests.swift
// The Domains page on the shared components (section 3.3 of the rework): the list the mode
// uses comes first and is editable, the other mode's list follows read-only, a wildcard says
// it is learned as you browse and counts the routes it learned.
//
// The problem it locks down: the page showed only the mode's own list, so the VPN Only list
// could be seen only by switching the whole Mac's routing, and a wildcard row read like any
// other domain with no count.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

final class DomainsPageTests: XCTestCase {

    private func config(bypass: [DomainEntry], vpnOnly: [DomainEntry]) -> Config {
        var c = Config()
        c.domains = bypass
        c.inverseDomains = vpnOnly
        return c
    }

    private let wiki = DomainEntry(domain: "en.wikipedia.org")
    private let wild = DomainEntry(domain: "*.example.com")
    private let off = DomainEntry(domain: "off.example.net", enabled: false)
    private let intranet = DomainEntry(domain: "intranet.example.org")
    private let range = DomainEntry(domain: "10.20.0.0/16", isCIDR: true)
    private let parked = DomainEntry(domain: "parked.example.org", enabled: false)

    // MARK: Which list comes first

    func testBypassShowsItsListThenTheVPNOnlyListReadOnly() {
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [wiki], vpnOnly: [intranet]),
                                     routeSources: [], search: "")
        XCTAssertEqual(s.map(\.list), [.bypass, .vpnOnly])
        XCTAssertEqual(s.map(\.isReadOnly), [false, true])
        XCTAssertEqual(s.map(\.title), ["Bypass list", "VPN Only list · used in VPN Only mode"])
    }

    func testVPNOnlyShowsItsListThenTheBypassListReadOnly() {
        let s = DomainsPage.sections(mode: .vpnOnly, config: config(bypass: [wiki], vpnOnly: [intranet]),
                                     routeSources: [], search: "")
        XCTAssertEqual(s.map(\.list), [.vpnOnly, .bypass])
        XCTAssertEqual(s.map(\.isReadOnly), [false, true])
        XCTAssertEqual(s.map(\.title), ["VPN Only list", "Bypass list · used in Bypass mode"])
    }

    /// Custom edits neither list here (the page is read-only there); it shows Bypass's first.
    func testCustomShowsTheBypassListFirst() {
        let s = DomainsPage.sections(mode: .custom, config: config(bypass: [wiki], vpnOnly: [intranet]),
                                     routeSources: [], search: "")
        XCTAssertEqual(s.map(\.list), [.bypass, .vpnOnly])
    }

    /// Custom routes by rules; a rule's route can carry a listed name, but neither list routes
    /// anything there, so no row shows a number.
    func testCustomShowsNoNumbers() {
        let s = DomainsPage.sections(mode: .custom, config: config(bypass: [wiki], vpnOnly: [intranet]),
                                     routeSources: ["en.wikipedia.org"], search: "")
        XCTAssertEqual(s.flatMap { $0.rows.map(\.number) }, [nil, nil])
    }

    /// An empty list of the other mode has nothing to show; the mode's own list always shows,
    /// since its first row is the add field.
    func testAnEmptyOtherListIsLeftOutButTheOwnListStays() {
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [], vpnOnly: []),
                                     routeSources: [], search: "")
        XCTAssertEqual(s.map(\.list), [.bypass])
        XCTAssertEqual(s.first?.total, 0)
    }

    // MARK: Rows

    /// Each row of the list in use counts its own routes; a wildcard counts the routes learned
    /// under `*.suffix`. A row that is off routes nothing and shows no number.
    func testNumbersAreTheRoutesOfEachEntry() throws {
        let sources = ["en.wikipedia.org", "en.wikipedia.org", "*.example.com", "*.example.com",
                       "*.example.com", "Telegram"]
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [wiki, wild, off], vpnOnly: []),
                                     routeSources: sources, search: "")
        let rows = try XCTUnwrap(s.first?.rows)
        XCTAssertEqual(rows.map(\.number), ["2", "3", nil])
    }

    /// The other mode's list routes nothing in this mode, so its rows have no number, even when
    /// a route happens to carry the same name.
    func testReadOnlyRowsHaveNoNumber() throws {
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [wiki], vpnOnly: [intranet, range]),
                                     routeSources: ["intranet.example.org"], search: "")
        XCTAssertEqual(try XCTUnwrap(s.last).rows.map(\.number), [nil, nil])
    }

    func testDetailLines() throws {
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [wiki, wild], vpnOnly: [range, parked]),
                                     routeSources: [], search: "")
        XCTAssertEqual(s[0].rows.map(\.detail), [nil, "learned as you browse"])
        // A read-only row has no switch, so one that is off says so.
        XCTAssertEqual(s[1].rows.map(\.detail), ["IP range", "Off"])
    }

    /// The title bar search filters both lists; each section still knows how many it holds.
    func testSearchFiltersBothLists() {
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [wiki, wild], vpnOnly: [intranet, parked]),
                                     routeSources: [], search: "EXAMPLE")
        XCTAssertEqual(s[0].rows.map(\.entry.domain), ["*.example.com"])
        XCTAssertEqual(s[1].rows.map(\.entry.domain), ["intranet.example.org", "parked.example.org"])
        XCTAssertEqual(s.map(\.total), [2, 2])
    }

    /// A search that matches only the list in use leaves the other list out, so the page never
    /// says "nothing matches" under a list that shows the match.
    func testASearchThatMissesTheOtherListLeavesItOut() {
        let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [wiki, wild], vpnOnly: [intranet, parked]),
                                     routeSources: [], search: "wikipedia")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].rows.map(\.entry.domain), ["en.wikipedia.org"])
    }

    // MARK: Translations

    func testNewStringsAreTranslated() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            guard dir.pathComponents.count > 1 else { throw XCTSkip("repo root not found from \(#filePath)") }
            dir = dir.deletingLastPathComponent()
        }
        let expected = [
            ("es", "Lista Solo VPN · se usa en el modo Solo VPN", "Añade un dominio o un *.comodín…", "se aprende mientras navegas"),
            ("fr", "Liste VPN uniquement · utilisée en mode VPN uniquement", "Ajoutez un domaine ou un *.joker…", "appris pendant la navigation"),
        ]
        for (lang, other, prompt, learned) in expected {
            let bundle = try XCTUnwrap(Bundle(url: dir.appendingPathComponent("Sources/VPNBypassCore/Resources/\(lang).lproj")), lang)
            XCTAssertEqual(DomainListCopy.otherTitle(isInverse: true, bundle: bundle), other)
            XCTAssertEqual(DomainListCopy.addPrompt(isInverse: false, bundle: bundle), prompt)
            let s = DomainsPage.sections(mode: .bypass, config: config(bypass: [wild], vpnOnly: []),
                                         routeSources: [], search: "", bundle: bundle)
            XCTAssertEqual(s.first?.rows.first?.detail, learned)
        }
    }
}

/// The real page in a window: the other mode's list is on it, below the mode's own.
@MainActor
final class DomainsPageViewTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedVPNConnected = false
    private var rm: RouteManager { RouteManager.shared }

    override func setUp() async throws {
        savedConfig = rm.config
        savedVPNConnected = rm.isVPNConnected
        rm.isVPNConnected = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "x.com")]
        cfg.inverseDomains = []
        rm.config = cfg
    }

    override func tearDown() async throws {
        rm.config = savedConfig
        rm.isVPNConnected = savedVPNConnected
    }

    private func height() -> CGFloat {
        let view = NSHostingView(rootView: DomainsTab().environmentObject(rm).environmentObject(SettingsUndo())
            .frame(width: 600))
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
        return view.fittingSize.height
    }

    /// Three VPN Only entries add a section of three rows under the Bypass list: well over
    /// 60 points. Before, the page drew only the Bypass list, whatever the VPN Only list held.
    func testTheOtherModesListIsOnThePage() {
        let without = height()
        rm.config.inverseDomains = [DomainEntry(domain: "a.example.org"), DomainEntry(domain: "b.example.org"),
                                    DomainEntry(domain: "c.example.org")]
        let with = height()
        XCTAssertGreaterThan(with - without, 60, "the VPN Only list is shown, read-only, under the Bypass list")
    }

    /// The VPN Only list in use: the Bypass list shows under it, and adding to the Bypass
    /// list from outside (vpnb, the dropdown) grows the page.
    func testTheBypassListShowsInVPNOnlyMode() {
        rm.config.routingMode = .vpnOnly
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.org")]
        let one = height()
        rm.config.domains += [DomainEntry(domain: "y.com"), DomainEntry(domain: "z.com")]
        XCTAssertGreaterThan(height() - one, 40)
    }
}
