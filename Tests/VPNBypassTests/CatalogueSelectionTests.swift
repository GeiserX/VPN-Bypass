// CatalogueSelectionTests.swift
// The catalogue sheet's rules, without a view: which rows can be picked, what a category's
// select-all does, what search matches (the region's name too), and the button's words. Plus
// the Lookups line for a name added to a catalogue service that is off.

import XCTest
@testable import VPNBypassCore

final class CatalogueSelectionTests: XCTestCase {

    private func entry(_ id: String, _ name: String, _ category: ServiceCatalogue.Category,
                       region: String? = nil, domains: [String]) -> ServiceCatalogue.Entry {
        ServiceCatalogue.Entry(category: category, region: region,
                               service: ServiceEntry(id: id, name: name, enabled: false, domains: domains, ipRanges: []))
    }

    private var catalogue: [ServiceCatalogue.Entry] {
        [entry("netflix", "Netflix", .video, domains: ["netflix.com"]),
         entry("twitch", "Twitch", .video, domains: ["twitch.tv"]),
         entry("youtube", "YouTube", .video, domains: ["youtube.com"]),
         entry("slack", "Slack", .work, domains: ["slack.com"]),
         entry("fr_lcl", "LCL", .developer, region: "FR", domains: ["*.lcl.fr"])]
    }

    /// Netflix on, Twitch held off by a custom service named "twitch", the rest off.
    private var services: [ServiceEntry] {
        var list = catalogue.map(\.service)
        list[0].enabled = true
        list.append(ServiceEntry(id: "custom_t", name: "twitch", enabled: true, domains: ["t.example"], ipRanges: [], isCustom: true))
        return list
    }

    private var rows: [CatalogueSelection.Row] { CatalogueSelection.rows(catalogue: catalogue, services: services) }

    private func ids(_ rows: [CatalogueSelection.Row]) -> [String] { rows.map(\.id) }

    func testRowsCarryTheLiveSwitchAndTheNameClash() {
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byId["netflix"]?.isOn, true)
        XCTAssertEqual(byId["netflix"]?.canPick, false, "already on")
        XCTAssertEqual(byId["twitch"]?.heldBy?.id, "custom_t")
        XCTAssertEqual(byId["twitch"]?.canPick, false, "held by a custom service")
        XCTAssertEqual(byId["youtube"]?.canPick, true)
    }

    func testSelectAllPicksOnlyTheRowsThatCanBePicked() {
        let video = rows.filter { $0.entry.category == .video }
        XCTAssertEqual(CatalogueSelection.state(of: video, picked: []), .none)
        let picked = CatalogueSelection.toggleAll(video, picked: [])
        XCTAssertEqual(picked, ["youtube"], "not Netflix, which is on, nor Twitch, which is held")
        XCTAssertEqual(CatalogueSelection.state(of: video, picked: picked), .all)
        XCTAssertEqual(CatalogueSelection.toggleAll(video, picked: picked.union(["slack"])), ["slack"],
                       "clicked again it drops its own rows and keeps the others")
        XCTAssertEqual(CatalogueSelection.state(of: video.filter { !$0.canPick }, picked: []), .unavailable)
    }

    func testSelectAllIsMixedWhenSomeArePicked() {
        var list = services
        list[2].enabled = false
        list.append(ServiceEntry(id: "x", name: "X", enabled: false, domains: ["x.com"], ipRanges: []))
        let video = CatalogueSelection.rows(catalogue: catalogue + [entry("x", "X", .video, domains: ["x.com"])], services: list)
            .filter { $0.entry.category == .video }
        XCTAssertEqual(CatalogueSelection.state(of: video, picked: ["youtube"]), .some)
        XCTAssertEqual(CatalogueSelection.toggleAll(video, picked: ["youtube"]), ["youtube", "x"])
    }

    func testSearchMatchesNameDomainAndRegion() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(ids(CatalogueSelection.groups(rows, category: nil, search: "tube", locale: english).flatMap(\.rows)), ["youtube"])
        XCTAssertEqual(ids(CatalogueSelection.groups(rows, category: nil, search: "slack.com", locale: english).flatMap(\.rows)), ["slack"])
        XCTAssertEqual(ids(CatalogueSelection.groups(rows, category: nil, search: "france", locale: english).flatMap(\.rows)), ["fr_lcl"])
        XCTAssertEqual(ids(CatalogueSelection.groups(rows, category: nil, search: "FR", locale: english).flatMap(\.rows)), ["fr_lcl"])
        // The region's name in the app's language, and in English whatever the language.
        let spanish = Locale(identifier: "es_ES")
        XCTAssertEqual(ids(CatalogueSelection.groups(rows, category: nil, search: "Francia", locale: spanish).flatMap(\.rows)), ["fr_lcl"])
        XCTAssertEqual(ids(CatalogueSelection.groups(rows, category: nil, search: "France", locale: spanish).flatMap(\.rows)), ["fr_lcl"])
        XCTAssertTrue(CatalogueSelection.groups(rows, category: nil, search: "zzz", locale: english).isEmpty)
    }

    func testTheCategoryFilterAndOrder() {
        XCTAssertEqual(CatalogueSelection.groups(rows, category: nil, search: "").map(\.category), [.video, .work, .developer])
        XCTAssertEqual(CatalogueSelection.groups(rows, category: .work, search: "").map(\.category), [.work])
        XCTAssertTrue(CatalogueSelection.groups(rows, category: .work, search: "tube").isEmpty)
        XCTAssertEqual(CatalogueSelection.categories(rows), [.video, .work, .developer])
    }

    func testTheShippedCatalogueGivesOneRowPerService() {
        let shipped = CatalogueSelection.rows(catalogue: ServiceCatalogue.shipped, services: Config().services)
        XCTAssertEqual(shipped.count, Config.defaultServices.count)
        XCTAssertTrue(shipped.allSatisfy(\.canPick), "a fresh install can pick every service")
    }

    func testTheButtonSaysHowMany() {
        XCTAssertEqual(CatalogueSelection.buttonTitle(count: 0), "Bypass services")
        XCTAssertEqual(CatalogueSelection.buttonTitle(count: 1), "Bypass 1 service")
        XCTAssertEqual(CatalogueSelection.buttonTitle(count: 3), "Bypass 3 services")
    }

    func testTheButtonIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let es = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/es.lproj")))
        let fr = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/fr.lproj")))
        XCTAssertEqual(CatalogueSelection.buttonTitle(count: 2, in: es), "Hacer bypass de 2 servicios")
        XCTAssertEqual(CatalogueSelection.buttonTitle(count: 1, in: fr), "Contourner 1 service")
    }
}

/// A name added from the Lookups page to a service that is off: a custom service is turned on
/// on the Services page, a catalogue service is added from the catalogue.
@MainActor
final class LookupAddToOffServiceTests: RouteManagerTestCase {

    private var savedConfig: RouteManager.Config!

    override func setUp() {
        super.setUp()
        savedConfig = rm.config
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.services.append(ServiceEntry(id: "custom_m", name: "Mine", enabled: false, domains: ["mine.example"], ipRanges: [], isCustom: true))
        rm.config = cfg
    }

    override func tearDown() {
        rm.config = savedConfig
        super.tearDown()
    }

    func testTheLineSaysWhereToTurnTheServiceOn() {
        XCTAssertEqual(rm.addLookup("cdn.netflix.example", toService: "netflix")?.message,
                       "Added cdn.netflix.example to Netflix. The service is off; add it from Browse catalogue on the Services page to bypass it.")
        XCTAssertEqual(rm.addLookup("b.mine.example", toService: "custom_m")?.message,
                       "Added b.mine.example to Mine. The service is off; turn it on from the Services page to bypass it.")
        rm.toggleService("netflix")
        XCTAssertEqual(rm.addLookup("img.netflix.example", toService: "netflix")?.message,
                       "Added img.netflix.example to Netflix.")
    }
}
