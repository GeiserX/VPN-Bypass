// ServicesPageTests.swift
// The Services page on the shared rows (rework step 7), as data: what each row says, when it
// counts addresses, when it needs attention, the actions it offers, and the page's lines in
// Spanish and French.

import XCTest
@testable import VPNBypassCore

final class ServicesPageTests: XCTestCase {

    private func service(_ id: String, name: String? = nil, on: Bool = true, custom: Bool = false,
                         domains: Int = 1, ranges: Int = 0) -> ServiceEntry {
        ServiceEntry(id: id, name: name ?? id.capitalized, enabled: on,
                     domains: (0..<domains).map { "\(id)\($0).example" },
                     ipRanges: (0..<ranges).map { "203.0.113.\($0)/32" }, isCustom: custom)
    }

    private func rows(_ services: [ServiceEntry], mode: RoutingMode = .bypass, sources: [String] = [],
                      added: [String: [String]] = [:], clash: [String: String] = [:]) -> [ServicesPage.Row] {
        ServicesPage.rows(services, mode: mode, routeSources: sources,
                          added: { added[$0.id] ?? [] }, clash: { clash[$0.id] })
    }

    func testTheDetailLineSaysWhatTheServiceHolds() {
        XCTAssertEqual(ServicesPage.detail(service("a", domains: 1), added: []), "1 domain")
        XCTAssertEqual(ServicesPage.detail(service("a", domains: 6, ranges: 8), added: []), "6 domains · 8 IP ranges")
        XCTAssertEqual(ServicesPage.detail(service("a", domains: 2, ranges: 1), added: []), "2 domains · 1 IP range")
        XCTAssertEqual(ServicesPage.detail(service("w", custom: true, domains: 2), added: []), "Custom · 2 domains")
        XCTAssertEqual(ServicesPage.detail(service("t", domains: 7), added: ["a.example", "b.example"]),
                       "7 domains · Added: a.example, b.example")
    }

    func testOnlyAServiceThatIsOnInBypassModeCountsAddresses() {
        let services = [service("telegram", name: "Telegram"), service("work", name: "Work", on: false, custom: true),
                        service("spotify", name: "Spotify")]
        let sources = Array(repeating: "Telegram", count: 18) + ["en.wikipedia.org"]
        XCTAssertEqual(rows(services, sources: sources).map(\.number), ["18", nil, "0"])
        // Services route only in Bypass: the page is read-only elsewhere and counts nothing.
        XCTAssertEqual(rows(services, mode: .vpnOnly, sources: sources).map(\.number), [nil, nil, nil])
        XCTAssertEqual(rows(services, mode: .custom, sources: sources).map(\.number), [nil, nil, nil])
    }

    func testANameClashIsTheDetailLineAndNeedsAttention() {
        let r = rows([service("netflix"), service("youtube")], clash: ["netflix": "Rename Netflix"])
        XCTAssertEqual(r[0].detail, "Rename Netflix")
        XCTAssertTrue(r[0].needsAttention)
        XCTAssertFalse(r[1].needsAttention)
    }

    func testOnlyABuiltInServiceListsAddedNames() {
        let r = rows([service("telegram"), service("work", custom: true)],
                     added: ["telegram": ["t.example"], "work": ["w.example"]])
        XCTAssertEqual(r[0].added, ["t.example"])
        XCTAssertEqual(r[1].added, [], "a custom service's names are its own, edited in its sheet")
        XCTAssertNotEqual(r[0].glyph, r[1].glyph, "a custom service has its own glyph")
    }

    func testACustomServiceOffersEditAndDelete() {
        let row = rows([service("work", name: "Work Tools", custom: true)])[0]
        let actions = ServicesPage.actions(for: row, edit: {}, delete: {}, removeAdded: { _ in })
        XCTAssertEqual(actions.map(\.kind), [.edit, .delete])
        XCTAssertEqual(actions.map(\.name), ["Edit Work Tools", "Delete Work Tools"])
    }

    func testABuiltInServiceOffersTheRemoveOfEachAddedName() {
        var removed: [String] = []
        let plain = rows([service("youtube", name: "YouTube")])[0]
        XCTAssertTrue(ServicesPage.actions(for: plain, edit: {}, delete: {}, removeAdded: { _ in }).isEmpty,
                      "a built-in service with nothing added has nothing to edit or delete")

        let one = rows([service("telegram", name: "Telegram")], added: ["telegram": ["t.example"]])[0]
        let single = ServicesPage.actions(for: one, edit: {}, delete: {}, removeAdded: { removed.append($0) })
        XCTAssertEqual(single.map(\.name), ["Remove t.example from Telegram"])
        single[0].perform()
        XCTAssertEqual(removed, ["t.example"])

        let two = rows([service("telegram", name: "Telegram")], added: ["telegram": ["a.example", "b.example"]])[0]
        let menu = ServicesPage.actions(for: two, edit: {}, delete: {}, removeAdded: { removed.append($0) })
        XCTAssertEqual(menu.map(\.kind), [.more])
        XCTAssertEqual(RowAction.flattened(menu).map(\.name),
                       ["Remove a.example from Telegram", "Remove b.example from Telegram"])
        let items = RowAction.flattened(menu)
        items[1].perform()
        items[0].perform()
        XCTAssertEqual(removed, ["t.example", "b.example", "a.example"], "each menu item removes its own name")
    }

    /// A fresh install with a search typed keeps the search on its way to the catalogue.
    func testTheCatalogueButtonCarriesTheSearch() {
        XCTAssertEqual(ServicesPage.catalogueButton(search: ""), "Browse catalogue…")
        XCTAssertEqual(ServicesPage.catalogueButton(search: "netflix"), "Search the catalogue")
    }

    // MARK: - Spanish and French

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testThePageLinesAreTranslated() throws {
        let es = try lproj("es"), fr = try lproj("fr")
        XCTAssertEqual(ServicesPage.purpose(in: es), "Un servicio evita la VPN mientras su interruptor está activado.")
        XCTAssertEqual(ServicesPage.purpose(in: fr), "Un service contourne le VPN tant que son interrupteur est activé.")
        XCTAssertEqual(ServicesPage.listTitle(in: es), "Tus servicios")
        XCTAssertEqual(ServicesPage.listTitle(in: fr), "Vos services")
        XCTAssertEqual(ServicesPage.catalogueLine(count: 37, in: es), "37 servicios, elige varios a la vez")
        XCTAssertEqual(ServicesPage.catalogueLine(count: 37, in: fr), "37 services, choisissez-en plusieurs à la fois")
        XCTAssertEqual(ServicesPage.detail(service("w", custom: true, domains: 2, ranges: 1), added: [], in: es),
                       "Personalizado · 2 dominios · 1 rango de IP")
    }
}
