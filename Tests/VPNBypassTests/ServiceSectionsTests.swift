// ServiceSectionsTests.swift
// How the Services page splits its list (proposal 11 of #119): the services that were on when
// the page opened come first, the rest keep the catalogue's order, a switch flipped on the
// page does not move its row, search filters every section, and the headers are translated.

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
        XCTAssertEqual(ids(sections.builtIn), ["signal", "netflix", "discord"])
        XCTAssertEqual(sections.custom.count, 0)
        XCTAssertEqual(sections.nonEmpty.map(\.kind), [.on, .builtIn])
    }

    func testTheDefaultCatalogueWithFourOnSplitsFourAndThirtyThree() {
        var services = RouteManager.Config().services.filter { !$0.isCustom }
        for i in services.indices where ["telegram", "whatsapp", "youtube", "slack"].contains(services[i].id) {
            services[i].enabled = true
        }
        let sections = ServiceSections(services: services, pinned: ServiceSections.pin(services), search: "")
        XCTAssertEqual(services.count, 37)
        XCTAssertEqual(ids(sections.on), ["telegram", "whatsapp", "youtube", "slack"])
        XCTAssertEqual(sections.builtIn.count, 33)
        XCTAssertEqual(sections.builtIn.first?.id, "signal")
    }

    func testCustomServicesThatAreOnJoinTheOnSectionInCatalogueOrder() {
        let services = [service("mine", on: true, custom: true), service("draft", custom: true),
                        service("telegram", on: true), service("signal")]
        let sections = ServiceSections(services: services, pinned: ServiceSections.pin(services), search: "")
        XCTAssertEqual(ids(sections.on), ["mine", "telegram"])
        XCTAssertEqual(ids(sections.custom), ["draft"])
        XCTAssertEqual(ids(sections.builtIn), ["signal"])
        XCTAssertEqual(sections.nonEmpty.map(\.kind), [.on, .custom, .builtIn])
    }

    /// The page pins the split when it opens. Turning a service off there keeps it in On with
    /// its switch off, and turning one on keeps it below, until the next visit pins again.
    func testAFlippedSwitchKeepsItsRowUntilTheNextVisit() {
        let opened = catalogue
        let pinned = ServiceSections.pin(opened)
        var now = opened
        now[0].enabled = false   // telegram off
        now[2].enabled = true    // signal on

        let sameVisit = ServiceSections(services: now, pinned: pinned, search: "")
        XCTAssertEqual(ids(sameVisit.on), ["telegram", "whatsapp", "youtube", "slack"])
        XCTAssertEqual(sameVisit.on.first?.enabled, false, "the row shows the live switch")
        XCTAssertEqual(ids(sameVisit.builtIn), ["signal", "netflix", "discord"])

        let nextVisit = ServiceSections(services: now, pinned: ServiceSections.pin(now), search: "")
        XCTAssertEqual(ids(nextVisit.on), ["whatsapp", "signal", "youtube", "slack"])
        XCTAssertEqual(ids(nextVisit.builtIn), ["telegram", "netflix", "discord"])
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
        XCTAssertEqual(ids(byDomain.on), ["telegram"])
        XCTAssertEqual(ids(byDomain.builtIn), ["signal"])

        let byName = ServiceSections(services: services, pinned: pinned, search: "sla")
        XCTAssertEqual(ids(byName.on), ["slack"])
        XCTAssertEqual(byName.nonEmpty.map(\.kind), [.on])

        let nothing = ServiceSections(services: services, pinned: pinned, search: "zzz")
        XCTAssertTrue(nothing.nonEmpty.isEmpty)
    }

    func testWithNothingOnThereIsNoOnSection() {
        let services = [service("telegram"), service("signal")]
        let sections = ServiceSections(services: services, pinned: ServiceSections.pin(services), search: "")
        XCTAssertEqual(sections.nonEmpty.map(\.kind), [.builtIn])
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
                       ["ON", "CUSTOM SERVICES", "BUILT-IN SERVICES"])
        XCTAssertEqual(ServiceSections.Kind.allCases.map { ServiceSections.title($0, in: es) },
                       ["ACTIVADOS", "SERVICIOS PERSONALIZADOS", "SERVICIOS INTEGRADOS"])
        XCTAssertEqual(ServiceSections.Kind.allCases.map { ServiceSections.title($0, in: fr) },
                       ["ACTIVÉS", "SERVICES PERSONNALISÉS", "SERVICES INTÉGRÉS"])
        // The dropdown's pill keeps its own word.
        XCTAssertEqual(String(localized: "ON", bundle: es), "ON")
    }
}
