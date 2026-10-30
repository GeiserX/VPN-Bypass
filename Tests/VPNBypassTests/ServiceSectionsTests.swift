// ServiceSectionsTests.swift
// How the Services page splits its list (proposal 11 of #119): the services that were on when
// the page opened come first, then the custom services that are off, each in the catalogue's
// order. A catalogue service that is off is not on the page: it waits in the catalogue sheet. A
// switch flipped on the page does not move its row, search filters every section, Turn All On
// covers the page only, and the headers are translated.

import XCTest
@testable import VPNBypassCore

final class ServiceSectionsTests: XCTestCase {

    private func service(_ id: String, on: Bool = false, custom: Bool = false,
                         domains: [String] = []) -> ServiceEntry {
        ServiceEntry(id: id, name: id.capitalized, enabled: on,
                     domains: domains.isEmpty ? ["\(id).com"] : domains, ipRanges: [], isCustom: custom)
    }

    private func ids(_ services: [ServiceEntry]) -> [String] { services.map(\.id) }

    private var catalogue: [ServiceEntry] {
        [service("telegram", on: true), service("whatsapp", on: true), service("signal"),
         service("youtube", on: true), service("netflix"), service("slack", on: true),
         service("discord")]
    }

    func testTheServicesThatAreOnComeFirstAndTheRestKeepTheirOrder() {
        let sections = ServiceSections(services: catalogue, pinned: ServiceSections.pin(catalogue), search: "")
        XCTAssertEqual(ids(sections.on), ["telegram", "whatsapp", "youtube", "slack"])
        XCTAssertEqual(sections.custom.count, 0)
        XCTAssertEqual(sections.nonEmpty.map(\.kind), [.on], "the services that are off stay in the catalogue")
    }

    func testTheDefaultCatalogueWithFourOnShowsOnlyThoseFour() {
        var services = RouteManager.Config().services.filter { !$0.isCustom }
        for i in services.indices where ["telegram", "whatsapp", "youtube", "slack"].contains(services[i].id) {
            services[i].enabled = true
        }
        let sections = ServiceSections(services: services, pinned: ServiceSections.pin(services), search: "")
        XCTAssertEqual(services.count, Config.defaultServices.count)
        XCTAssertEqual(ids(sections.on), ["telegram", "whatsapp", "youtube", "slack"])
        XCTAssertEqual(sections.nonEmpty.map(\.kind), [.on], "nothing else shown")
    }

    func testAFreshInstallShowsAnEmptyPage() {
        let services = RouteManager.Config().services
        XCTAssertTrue(ServiceSections(services: services, pinned: ServiceSections.pin(services), search: "").nonEmpty.isEmpty)
    }

    func testCustomServicesThatAreOnJoinTheOnSectionInCatalogueOrder() {
        let services = [service("mine", on: true, custom: true), service("draft", custom: true),
                        service("telegram", on: true), service("signal")]
        let sections = ServiceSections(services: services, pinned: ServiceSections.pin(services), search: "")
        XCTAssertEqual(ids(sections.on), ["mine", "telegram"])
        XCTAssertEqual(ids(sections.custom), ["draft"])
        XCTAssertEqual(sections.nonEmpty.map(\.kind), [.on, .custom], "signal is off: in the catalogue")
    }

    /// The page pins the split when it opens. Turning a catalogue service off there keeps its
    /// row in On with its switch off; the next visit sends it back to the catalogue.
    func testAServiceSwitchedOffKeepsItsRowUntilTheNextVisit() {
        let opened = catalogue
        let pinned = ServiceSections.pin(opened)
        var now = opened
        now[0].enabled = false   // telegram off

        let sameVisit = ServiceSections(services: now, pinned: pinned, search: "")
        XCTAssertEqual(ids(sameVisit.on), ["telegram", "whatsapp", "youtube", "slack"])
        XCTAssertEqual(sameVisit.on.first?.enabled, false, "the row shows the live switch")

        let nextVisit = ServiceSections(services: now, pinned: ServiceSections.pin(now), search: "")
        XCTAssertEqual(ids(nextVisit.on), ["whatsapp", "youtube", "slack"], "telegram is back in the catalogue")
        XCTAssertTrue(nextVisit.custom.isEmpty)
    }

    /// A catalogue service turned on from the sheet, Lookups or vpnb shows once the page pins
    /// again, as the sheet does after its button.
    func testAServiceTurnedOnFromTheCatalogueShowsOnceThePageRepins() {
        var now = catalogue
        now[2].enabled = true    // signal on from the sheet
        XCTAssertFalse(ids(ServiceSections(services: now, pinned: ServiceSections.pin(catalogue), search: "").on).contains("signal"),
                       "control: the old pin still has it off")
        XCTAssertEqual(ids(ServiceSections(services: now, pinned: ServiceSections.pin(now), search: "").on),
                       ["telegram", "whatsapp", "signal", "youtube", "slack"])
    }

    /// A service the page has not seen, such as a custom service just created, goes by its own
    /// switch instead of falling into the off sections.
    func testAServiceAddedSinceThePageOpenedGoesByItsOwnSwitch() {
        let pinned = ServiceSections.pin(catalogue)
        let now = catalogue + [service("new", on: true, custom: true), service("later", custom: true)]
        let sections = ServiceSections(services: now, pinned: pinned, search: "")
        XCTAssertEqual(ids(sections.on), ["telegram", "whatsapp", "youtube", "slack", "new"])
        XCTAssertEqual(ids(sections.custom), ["later"])
    }

    /// Once the page has seen a service added during the visit, it is pinned like the others:
    /// switching it off keeps it in On. The services pinned when the page opened keep their pin.
    func testAServiceAddedDuringTheVisitKeepsItsRowWhenFlipped() {
        var now = catalogue
        now[0].enabled = false   // telegram off on the page
        now.append(service("new", on: true, custom: true))
        let pinned = ServiceSections.pinNew(now, into: ServiceSections.pin(catalogue))
        XCTAssertEqual(pinned["telegram"], true)
        XCTAssertEqual(pinned["new"], true)

        now[now.count - 1].enabled = false   // the new service off on the page
        let sections = ServiceSections(services: now, pinned: pinned, search: "")
        XCTAssertEqual(ids(sections.on), ["telegram", "whatsapp", "youtube", "slack", "new"])
        XCTAssertEqual(sections.custom.count, 0)
    }

    func testARemovedServiceLeavesItsSection() {
        let pinned = ServiceSections.pin(catalogue)
        let now = catalogue.filter { $0.id != "youtube" }
        XCTAssertEqual(ids(ServiceSections(services: now, pinned: pinned, search: "").on),
                       ["telegram", "whatsapp", "slack"])
    }

    func testSearchFiltersEverySectionByNameOrDomain() {
        let services = [service("telegram", on: true, domains: ["t.me", "telegram.org"]),
                        service("signal", domains: ["signal.org"]),
                        service("slack", on: true, domains: ["slack.com"])]
        let pinned = ServiceSections.pin(services)

        let byDomain = ServiceSections(services: services, pinned: pinned, search: ".ORG")
        XCTAssertEqual(ids(byDomain.on), ["telegram"], "signal is off, so it is not on the page")

        let byName = ServiceSections(services: services, pinned: pinned, search: "sla")
        XCTAssertEqual(ids(byName.on), ["slack"])
        XCTAssertEqual(byName.nonEmpty.map(\.kind), [.on])

        let nothing = ServiceSections(services: services, pinned: pinned, search: "zzz")
        XCTAssertTrue(nothing.nonEmpty.isEmpty)
    }

    func testWithNothingOnOnlyCustomServicesShow() {
        let services = [service("telegram"), service("signal"), service("draft", custom: true)]
        let sections = ServiceSections(services: services, pinned: ServiceSections.pin(services), search: "")
        XCTAssertEqual(sections.nonEmpty.map(\.kind), [.custom])
        XCTAssertEqual(ids(sections.custom), ["draft"])
    }

    // MARK: - Turn All On covers the page only

    func testTurnAllOnNeverTurnsOnTheCatalogue() {
        var now = catalogue + [service("draft", custom: true)]
        now[0].enabled = false   // telegram switched off on the page this visit
        let pinned = ServiceSections.pin(catalogue + [service("draft", custom: true)])
        XCTAssertEqual(ids(ServiceSections.turnAllOn(services: now, pinned: pinned)), ["telegram", "draft"],
                       "the page's own rows that are off; signal, netflix and discord stay in the catalogue")
        XCTAssertEqual(ids(ServiceSections.turnAllOn(services: catalogue, pinned: ServiceSections.pin(catalogue))), [])
    }

    func testPinCopesWithADuplicateID() {
        let services = [service("dup", on: true), service("dup")]
        XCTAssertEqual(ServiceSections.pin(services), ["dup": true])
    }

    // MARK: - Headers in Spanish and French

    /// A language folder from the source tree; a test run has no app bundle to take it from.
    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testTheHeadersAreTranslated() throws {
        let en = try lproj("en"), es = try lproj("es"), fr = try lproj("fr")
        XCTAssertEqual(ServiceSections.Kind.allCases.map { ServiceSections.title($0, in: en) },
                       ["ON", "CUSTOM SERVICES"])
        XCTAssertEqual(ServiceSections.Kind.allCases.map { ServiceSections.title($0, in: es) },
                       ["ACTIVADOS", "SERVICIOS PERSONALIZADOS"])
        XCTAssertEqual(ServiceSections.Kind.allCases.map { ServiceSections.title($0, in: fr) },
                       ["ACTIVÉS", "SERVICES PERSONNALISÉS"])
        // The dropdown's pill keeps its own word.
        XCTAssertEqual(String(localized: "ON", bundle: es), "ON")
    }
}
