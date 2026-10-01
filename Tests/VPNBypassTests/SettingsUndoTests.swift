// SettingsUndoTests.swift
// Undo on the Settings pages (proposal 8 of #119): the line's wording and page, the question
// before a large Turn All On, putting each kind of change back through RouteManager, and ⌘Z
// through the window's undo manager doing what the line's Undo does.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

// MARK: - Wording, page and the Turn All On question (pure)

final class UndoableChangeWordingTests: XCTestCase {

    private func service(_ name: String, domains: Int, ranges: Int = 0) -> ServiceEntry {
        ServiceEntry(id: "custom_\(name.lowercased())", name: name, enabled: true,
                     domains: (0..<domains).map { "d\($0).example.com" },
                     ipRanges: (0..<ranges).map { "10.0.\($0).0/24" }, isCustom: true)
    }

    private func off(_ names: [String]) -> [ServiceEntry] {
        names.map { ServiceEntry(id: $0.lowercased(), name: $0, enabled: false, domains: ["\($0).com"], ipRanges: []) }
    }

    func testADomainSaysWhichOne() {
        let change = UndoableChange.domain(DomainEntry(domain: "news.ycombinator.com"), index: 1, list: .bypass)
        XCTAssertEqual(change.message, "Removed news.ycombinator.com.")
        let range = UndoableChange.domain(DomainEntry(domain: "10.0.0.0/24", isCIDR: true), index: 0, list: .vpnOnly)
        XCTAssertEqual(range.message, "Removed the range 10.0.0.0/24.")
    }

    func testACustomServiceSaysWhatWentWithIt() {
        XCTAssertEqual(UndoableChange.customService(service("Work Tools", domains: 5), index: 0).message,
                       "Removed Work Tools and its 5 domains.")
        XCTAssertEqual(UndoableChange.customService(service("Wiki", domains: 1), index: 0).message,
                       "Removed Wiki and its 1 domain.")
        XCTAssertEqual(UndoableChange.customService(service("Lab", domains: 0, ranges: 2), index: 0).message,
                       "Removed Lab and its 2 IP ranges.")
        XCTAssertEqual(UndoableChange.customService(service("Office", domains: 3, ranges: 1), index: 0).message,
                       "Removed Office, its 3 domains and its 1 IP range.")
        XCTAssertEqual(UndoableChange.customService(service("Empty", domains: 0), index: 0).message,
                       "Removed Empty.")
    }

    func testRulesAndRoutesSayWhichOne() {
        let route = Route(name: "Office Proxy", egress: .proxyHTTP)
        let rule = Rule(matchType: .service, pattern: "netflix", routeId: route.id, order: 0)
        XCTAssertEqual(UndoableChange.rule(rule, label: "Netflix").message, "Removed the rule for Netflix.")
        XCTAssertEqual(UndoableChange.route(route, index: 0).message, "Removed the route Office Proxy.")
    }

    func testABulkSwitchCountsWhatItSwitched() {
        XCTAssertEqual(UndoableChange.servicesSwitched(ids: ["a", "b", "c", "d"], on: false).message,
                       "Turned off 4 services.")
        XCTAssertEqual(UndoableChange.servicesSwitched(ids: ["a"], on: true).message, "Turned on 1 service.")
        XCTAssertEqual(UndoableChange.domainsSwitched(ids: [UUID(), UUID()], on: true, list: .bypass).message,
                       "Turned on 2 domains.")
        XCTAssertEqual(UndoableChange.domainsSwitched(ids: [UUID()], on: false, list: .vpnOnly).message,
                       "Turned off 1 domain.")
    }

    func testEachChangeShowsOnThePageThatMadeIt() {
        let route = Route(name: "P", egress: .proxySOCKS5)
        XCTAssertEqual(UndoableChange.domain(DomainEntry(domain: "a.com"), index: 0, list: .vpnOnly).page, .domains)
        XCTAssertEqual(UndoableChange.domainsSwitched(ids: [], on: true, list: .bypass).page, .domains)
        XCTAssertEqual(UndoableChange.customService(service("W", domains: 1), index: 0).page, .services)
        XCTAssertEqual(UndoableChange.servicesSwitched(ids: [], on: true).page, .services)
        XCTAssertEqual(UndoableChange.rule(Rule(matchType: .domain, pattern: "a.com", routeId: route.id, order: 0), label: "a.com").page, .rules)
        XCTAssertEqual(UndoableChange.route(route, index: 0).page, .routes)
    }

    func testTurningOnAHandfulDoesNotAsk() {
        XCTAssertNil(ServiceBulkSwitch.question(turningOn: off(["A", "B", "C", "D", "E"])))
        XCTAssertEqual(ServiceBulkSwitch.turnAllOnTitle(offCount: 5), "Turn All On")
        XCTAssertNil(ServiceBulkSwitch.question(turningOn: []))
    }

    func testTurningOnMoreThanAHandfulAsksAndNamesTwo() throws {
        let question = try XCTUnwrap(ServiceBulkSwitch.question(turningOn: off(["Netflix", "Steam", "C", "D", "E", "F"])))
        XCTAssertEqual(question.title, "Send 6 services around the VPN?")
        XCTAssertEqual(question.message, "Netflix, Steam and 4 more will use your normal connection instead of the VPN. You can turn them off again here.")
        XCTAssertEqual(question.confirm, "Turn On 6 Services")
        XCTAssertEqual(ServiceBulkSwitch.turnAllOnTitle(offCount: 6), "Turn All On…")
    }

    /// The default catalogue with four services on: Turn All On asks about the 33 that are
    /// off, not all 37.
    func testTheDefaultCatalogueAsksAboutTheServicesThatAreOff() throws {
        var services = RouteManager.Config().services.filter { !$0.isCustom }
        for i in services.indices where ["telegram", "whatsapp", "youtube", "slack"].contains(services[i].id) {
            services[i].enabled = true
        }
        let question = try XCTUnwrap(ServiceBulkSwitch.question(turningOn: services.filter { !$0.enabled }))
        XCTAssertEqual(question.title, "Send 33 services around the VPN?")
        XCTAssertTrue(question.message.contains("and 31 more"), question.message)
    }

    // MARK: Spanish and French

    /// A language folder from the source tree; a test run has no app bundle to take it from.
    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testEveryLineAndTheQuestionAreTranslated() throws {
        let en = try lproj("en"), es = try lproj("es"), fr = try lproj("fr")
        let route = Route(name: "Office Proxy", egress: .proxyHTTP)
        let changes: [UndoableChange] = [
            .domain(DomainEntry(domain: "a.com"), index: 0, list: .bypass),
            .domain(DomainEntry(domain: "10.0.0.0/24", isCIDR: true), index: 0, list: .vpnOnly),
            .customService(service("Work Tools", domains: 5), index: 0),
            .customService(service("Lab", domains: 0, ranges: 2), index: 0),
            .customService(service("Office", domains: 3, ranges: 1), index: 0),
            .rule(Rule(matchType: .domain, pattern: "a.com", routeId: route.id, order: 0), label: "a.com"),
            .route(route, index: 0),
            .domainsSwitched(ids: [UUID(), UUID()], on: true, list: .bypass),
            .servicesSwitched(ids: ["a", "b"], on: false),
        ]
        for (name, bundle) in [("es", es), ("fr", fr)] {
            for change in changes {
                let english = change.message(in: en), translated = change.message(in: bundle)
                XCTAssertNotEqual(translated, english, "\(name) has no entry for \"\(english)\"")
                XCTAssertFalse(translated.contains("%"), "\(name): \(translated)")
            }
            let services = off(["Netflix", "Steam", "C", "D", "E", "F"])
            let question = try XCTUnwrap(ServiceBulkSwitch.question(turningOn: services, in: bundle))
            let english = try XCTUnwrap(ServiceBulkSwitch.question(turningOn: services, in: en))
            XCTAssertNotEqual(question.title, english.title, name)
            XCTAssertNotEqual(question.message, english.message, name)
            XCTAssertNotEqual(question.confirm, english.confirm, name)
            XCTAssertTrue(question.message.hasPrefix("Netflix, Steam"), "\(name): \(question.message)")
            XCTAssertTrue(question.message.contains("4"), "\(name): \(question.message)")
            XCTAssertNotEqual(ServiceBulkSwitch.turnAllOnTitle(offCount: 9, in: bundle), "Turn All On…", name)
            XCTAssertNotEqual(String(localized: "Turn All Off", bundle: bundle), "Turn All Off", name)
            XCTAssertNotEqual(String(localized: "Undo", bundle: bundle), "Undo", name)
        }
        XCTAssertEqual(UndoableChange.customService(service("Work Tools", domains: 5), index: 0).message(in: es),
                       "Se quitó Work Tools junto con 5 dominios.")
        XCTAssertEqual(UndoableChange.servicesSwitched(ids: ["a"], on: true).message(in: fr),
                       "Vous avez activé 1 service.")
    }

    func testTheRestoredRuleGoesBackToItsOrder() {
        let routeId = UUID()
        let a = Rule(matchType: .domain, pattern: "a.com", routeId: routeId, order: 0)
        let b = Rule(matchType: .domain, pattern: "b.com", routeId: routeId, order: 1)
        let c = Rule(matchType: .domain, pattern: "c.com", routeId: routeId, order: 2)
        // b was deleted; nothing has taken order 1.
        let back = RouteManager.rules([a, c], restoring: b).sorted { $0.order < $1.order }
        XCTAssertEqual(back.map(\.pattern), ["a.com", "b.com", "c.com"])
        // A drag renumbered a and c to 0 and 1 since: b goes before the one at 1 now.
        var c1 = c; c1.order = 1
        let shifted = RouteManager.rules([a, c1], restoring: b).sorted { $0.order < $1.order }
        XCTAssertEqual(shifted.map(\.pattern), ["a.com", "b.com", "c.com"])
        XCTAssertEqual(Set(shifted.map(\.order)).count, 3, "no two rules may share an order")
    }
}

// MARK: - Putting changes back through RouteManager

@MainActor
final class SettingsUndoRestoreTests: RouteManagerTestCase {

    private var savedConnected = false

    override func setUp() {
        super.setUp()
        savedConnected = rm.isVPNConnected
        rm.isVPNConnected = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "a.example.com"), DomainEntry(domain: "b.example.com", enabled: false),
                       DomainEntry(domain: "c.example.com")]
        cfg.inverseDomains = [DomainEntry(domain: "10.1.0.0/16", isCIDR: true), DomainEntry(domain: "corp.example.com")]
        rm.config = cfg
    }

    override func setUp() async throws {
        await waitForTheGate()
    }

    override func tearDown() {
        rm.cancelAllRetries()
        rm.isVPNConnected = savedConnected
        super.tearDown()
    }

    private func waitForTheGate() async {
        var polls = 0
        while rm.isApplyingRoutes && polls < 100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            polls += 1
        }
        XCTAssertFalse(rm.isApplyingRoutes, "a route operation never finished")
    }

    func testADeletedDomainComesBackWithItsIdSwitchAndPlace() async {
        let b = rm.config.domains[1]
        await rm.removeDomain(b)?.value
        XCTAssertEqual(rm.config.domains.map(\.domain), ["a.example.com", "c.example.com"])

        XCTAssertTrue(rm.undo(.domain(b, index: 1, list: .bypass)))
        XCTAssertEqual(rm.config.domains.map(\.domain), ["a.example.com", "b.example.com", "c.example.com"])
        XCTAssertEqual(rm.config.domains[1].id, b.id)
        XCTAssertFalse(rm.config.domains[1].enabled, "it was off when deleted and comes back off")
    }

    func testADomainAddedBackByHandIsNotDuplicated() async {
        let a = rm.config.domains[0]
        await rm.removeDomain(a)?.value
        rm.addDomain("a.example.com")
        XCTAssertFalse(rm.undo(.domain(a, index: 0, list: .bypass)))
        XCTAssertEqual(rm.config.domains.filter { $0.domain == "a.example.com" }.count, 1)
    }

    func testAVPNOnlyRangeComesBackToItsList() async {
        let range = rm.config.inverseDomains[0]
        await rm.removeInverseDomain(range)?.value
        XCTAssertTrue(rm.undo(.domain(range, index: 0, list: .vpnOnly)))
        XCTAssertEqual(rm.config.inverseDomains.first?.id, range.id)
        XCTAssertTrue(rm.config.inverseDomains.first?.isCIDR ?? false)
        XCTAssertFalse(rm.config.domains.contains { $0.domain == range.domain }, "not on the Bypass list")
    }

    func testACustomServiceComesBackWithItsDomainsAndPlace() async {
        rm.addCustomService(name: "Work Tools", domains: ["jira.example.com", "wiki.example.com"], ipRanges: ["10.9.0.0/16"])
        let index = rm.config.services.count - 1
        let service = rm.config.services[index]
        rm.removeCustomService(service.id)
        await waitForTheGate()   // the cleanup takes it out of the config when it ends
        XCTAssertFalse(rm.config.services.contains { $0.id == service.id })

        XCTAssertTrue(rm.undo(.customService(service, index: index)))
        let back = rm.config.services[index]
        XCTAssertEqual(back.id, service.id)
        XCTAssertEqual(back.domains, ["jira.example.com", "wiki.example.com"])
        XCTAssertEqual(back.ipRanges, ["10.9.0.0/16"])
        XCTAssertFalse(rm.undo(.customService(service, index: index)), "a second undo has nothing to put back")
    }

    func testARouteComesBackInItsPlace() {
        let one = Route(name: "One", egress: .direct), two = Route(name: "Two", egress: .direct)
        rm.config.routes = [one, two]
        rm.removeRoute(one.id)
        XCTAssertEqual(rm.config.routes.map(\.id), [two.id])
        XCTAssertTrue(rm.undo(.route(one, index: 0)))
        XCTAssertEqual(rm.config.routes.map(\.id), [one.id, two.id])
    }

    /// Undoing Turn All Off turns back on only what it turned off; one that was already off
    /// stays off.
    func testUndoingTurnAllOffSwitchesBackOnlyWhatItSwitched() {
        let changed = rm.setAllDomainsEnabled(false)
        XCTAssertEqual(Set(changed), Set([rm.config.domains[0].id, rm.config.domains[2].id]))
        XCTAssertTrue(rm.undo(.domainsSwitched(ids: changed, on: false, list: .bypass)))
        XCTAssertEqual(rm.config.domains.map(\.enabled), [true, false, true])
    }

    func testUndoingTurnAllOnForServicesSwitchesBackOnlyWhatItSwitched() {
        for i in rm.config.services.indices { rm.config.services[i].enabled = ["telegram", "slack"].contains(rm.config.services[i].id) }
        let changed = rm.setAllServicesEnabled(true)
        XCTAssertEqual(changed.count, rm.config.services.count - 2)
        XCTAssertFalse(changed.contains("telegram"))
        XCTAssertTrue(rm.undo(.servicesSwitched(ids: changed, on: true)))
        XCTAssertEqual(Set(rm.config.services.filter(\.enabled).map(\.id)), ["telegram", "slack"])
    }

    func testUndoingVPNOnlyTurnAllOffSwitchesBackOnlyWhatItSwitched() {
        rm.config.inverseDomains[1].enabled = false
        let changed = rm.setAllInverseDomainsEnabled(false)
        XCTAssertEqual(changed, [rm.config.inverseDomains[0].id])
        XCTAssertTrue(rm.undo(.domainsSwitched(ids: changed, on: false, list: .vpnOnly)))
        XCTAssertEqual(rm.config.inverseDomains.map(\.enabled), [true, false])
    }

    /// Routes follow the entry back in: with a VPN up, a restored VPN Only entry takes the
    /// route gate at once and runs the same install as `addInverseDomain`. No VPN gateway is
    /// known here, so the install stops at its first step and logs it; nothing reaches the
    /// routing table.
    func testARestoredVPNOnlyEntryInstallsItsRoutesLikeAnAdd() async {
        rm.config.routingMode = .vpnOnly
        rm.vpnGateway = nil
        let corp = rm.config.inverseDomains[1]
        await rm.removeInverseDomain(corp)?.value
        rm.isVPNConnected = true
        rm.recentLogs = []

        XCTAssertTrue(rm.undo(.domain(corp, index: 1, list: .vpnOnly)))
        XCTAssertTrue(rm.isApplyingRoutes, "the restore must start the route install, as an add does")
        await waitForTheGate()
        XCTAssertTrue(rm.recentLogs.contains { $0.message == "Cannot route corp.example.com: no VPN gateway detected" },
                      rm.recentLogs.map(\.message).joined(separator: "\n"))
    }

    /// A Bypass entry that was off comes back off, so it installs nothing.
    func testARestoredBypassEntryThatWasOffInstallsNothing() async {
        let b = rm.config.domains[1]
        await rm.removeDomain(b)?.value
        rm.isVPNConnected = true
        XCTAssertTrue(rm.undo(.domain(b, index: 1, list: .bypass)))
        XCTAssertFalse(rm.isApplyingRoutes)
    }
}

// MARK: - The line's Undo and ⌘Z

@MainActor
final class SettingsUndoManagerTests: RouteManagerTestCase {

    private var savedConnected = false

    override func setUp() {
        super.setUp()
        savedConnected = rm.isVPNConnected
        rm.isVPNConnected = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "a.example.com"), DomainEntry(domain: "b.example.com")]
        rm.config = cfg
    }

    override func tearDown() {
        rm.isVPNConnected = savedConnected
        super.tearDown()
    }

    /// A delete as DomainsTab makes it: the entry goes, then the change is recorded. The
    /// cleanup takes the entry out of the config when it ends.
    private func deleteB(_ undo: SettingsUndo) {
        let b = rm.config.domains[1]
        rm.removeDomain(b)
        undo.record(.domain(b, index: 1, list: .bypass))
        settle()
    }

    /// Lets the delete's cleanup finish and NSUndoManager close the group a registration
    /// opened, which it does at the end of the run loop pass.
    private func settle() {
        var passes = 0
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            passes += 1
        } while rm.isApplyingRoutes && passes < 100
    }

    func testCommandZPutsBackTheDeleteAndClearsTheLine() {
        let manager = UndoManager()
        let undo = SettingsUndo(routeManager: rm)
        undo.undoManager = manager
        deleteB(undo)
        XCTAssertNotNil(undo.last)
        XCTAssertTrue(manager.canUndo)

        manager.undo()
        XCTAssertEqual(rm.config.domains.map(\.domain), ["a.example.com", "b.example.com"])
        XCTAssertNil(undo.last, "the line goes once the change is back")
        XCTAssertEqual(undo.undoneCount, 1)
    }

    func testTheLinesUndoAlsoTakesTheChangeOffTheUndoMenu() {
        let manager = UndoManager()
        let undo = SettingsUndo(routeManager: rm)
        undo.undoManager = manager
        deleteB(undo)

        undo.undoLast()
        XCTAssertEqual(rm.config.domains.count, 2)
        XCTAssertFalse(manager.canUndo, "⌘Z must not put it back a second time")
    }

    func testANewChangeReplacesTheLastOne() {
        let manager = UndoManager()
        let undo = SettingsUndo(routeManager: rm)
        undo.undoManager = manager
        deleteB(undo)
        let a = rm.config.domains[0]
        rm.removeDomain(a)
        undo.record(.domain(a, index: 0, list: .bypass))
        settle()

        manager.undo()
        XCTAssertEqual(rm.config.domains.map(\.domain), ["a.example.com"], "only the last delete comes back")
        XCTAssertFalse(manager.canUndo)
    }

    func testClearingDropsTheLineAndTheUndoMenuItem() {
        let manager = UndoManager()
        let undo = SettingsUndo(routeManager: rm)
        undo.undoManager = manager
        deleteB(undo)
        undo.clear()
        XCTAssertNil(undo.last)
        XCTAssertFalse(manager.canUndo)
    }

    /// The Settings window hands its own undo manager to SettingsUndo, so Edit > Undo, which
    /// asks the key window's, reaches it.
    func testTheSettingsWindowSuppliesItsUndoManager() throws {
        let undo = SettingsUndo(routeManager: rm)
        let window = SettingsWindowController.makeWindow(settingsUndo: undo)
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let windowManager = try XCTUnwrap(window.undoManager)
        XCTAssertTrue(undo.undoManager === windowManager, "SettingsView must hand the window's undo manager over")

        deleteB(undo)
        XCTAssertTrue(windowManager.canUndo)
        windowManager.undo()
        XCTAssertEqual(rm.config.domains.count, 2)
    }
}
