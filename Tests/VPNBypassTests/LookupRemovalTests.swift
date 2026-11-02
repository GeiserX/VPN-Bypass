// LookupRemovalTests.swift
// The Lookups page's remove action for a listed name: what it takes away for each way a name
// can be listed, what the button says, and what a row offers.

import XCTest
@testable import VPNBypassCore

/// `RouteManager.lookupRemoval(_:config:)`, pure: one case per way a name is listed.
final class LookupRemovalDecisionTests: XCTestCase {

    private let host = "api.example.com"

    private func bypassConfig() -> Config {
        var config = Config()
        config.routingMode = .bypass
        config.domains = []
        config.inverseDomains = []
        return config
    }

    private func removal(_ config: Config) -> LookupRemoval? {
        RouteManager.lookupRemoval(host, config: config)
    }

    func testNothingWhenTheNameIsNotListed() {
        XCTAssertNil(removal(bypassConfig()))
    }

    func testTheNameOnTheBypassListComesOff() {
        var config = bypassConfig()
        let entry = DomainEntry(domain: host)
        config.domains = [entry]
        XCTAssertEqual(removal(config), .listEntry(id: entry.id, list: .bypass, entry: host))
    }

    /// The name's own entry comes before a wildcard over it, so Remove takes the least.
    func testTheNameItselfBeforeAWildcardOverIt() {
        var config = bypassConfig()
        let wildcard = DomainEntry(domain: "*.example.com")
        let exact = DomainEntry(domain: host)
        config.domains = [wildcard, exact]
        XCTAssertEqual(removal(config), .listEntry(id: exact.id, list: .bypass, entry: host))
        config.domains = [wildcard]
        XCTAssertEqual(removal(config), .listEntry(id: wildcard.id, list: .bypass, entry: "*.example.com"))
    }

    /// A switched-off entry is `.listedOff` on the page: nothing to remove, the Domains page
    /// switches it. A switched-off wildcard does not hold the name.
    func testSwitchedOffEntriesOfferNothing() {
        var config = bypassConfig()
        config.domains = [DomainEntry(domain: host, enabled: false), DomainEntry(domain: "*.example.com", enabled: false)]
        XCTAssertNil(removal(config))
    }

    func testTheVPNOnlyListInVPNOnlyMode() {
        var config = bypassConfig()
        config.routingMode = .vpnOnly
        let exact = DomainEntry(domain: host)
        let wildcard = DomainEntry(domain: "*.example.com")
        config.inverseDomains = [wildcard, exact]
        // The Bypass list does not route in VPN Only mode.
        config.domains = [DomainEntry(domain: host)]
        XCTAssertEqual(removal(config), .listEntry(id: exact.id, list: .vpnOnly, entry: host))
        config.inverseDomains = [wildcard]
        XCTAssertEqual(removal(config), .listEntry(id: wildcard.id, list: .vpnOnly, entry: "*.example.com"))
        config.inverseDomains = []
        XCTAssertNil(removal(config))
    }

    func testADomainOfACustomServiceComesOutOfIt() {
        var config = bypassConfig()
        config.services.append(ServiceEntry(id: "custom_ex", name: "Example", enabled: true,
                                            domains: ["a.example.com", host], ipRanges: [], isCustom: true))
        XCTAssertEqual(removal(config), .serviceDomain(serviceId: "custom_ex", service: "Example", entry: host))
        config.services[config.services.count - 1].domains = ["*.example.com"]
        XCTAssertEqual(removal(config), .serviceDomain(serviceId: "custom_ex", service: "Example", entry: "*.example.com"))
        config.services[config.services.count - 1].enabled = false
        XCTAssertNil(removal(config), "a switched-off service does not list it")
    }

    func testADomainAddedToABuiltInServiceComesOutOfIt() {
        var config = bypassConfig()
        let slack = config.services.firstIndex { $0.id == "slack" }!
        config.services[slack].enabled = true
        config.services[slack].domains.append(host)
        config.builtInServiceExtras["slack"] = [host]
        XCTAssertEqual(removal(config), .serviceDomain(serviceId: "slack", service: "Slack", entry: host))
    }

    /// A domain the service ships with cannot come out of it, so the service goes off. A
    /// shipped domain listed in the extras too is still shipped.
    func testAShippedDomainTurnsTheBuiltInServiceOff() {
        var config = bypassConfig()
        let slack = config.services.firstIndex { $0.id == "slack" }!
        config.services[slack].enabled = true
        XCTAssertEqual(RouteManager.lookupRemoval("slack.com", config: config),
                       .turnOffService(serviceId: "slack", service: "Slack"))
        config.builtInServiceExtras["slack"] = ["slack.com"]
        XCTAssertEqual(RouteManager.lookupRemoval("slack.com", config: config),
                       .turnOffService(serviceId: "slack", service: "Slack"))
    }

    /// The Bypass list wins over a service, as on the page's status.
    func testTheListBeforeAService() {
        var config = bypassConfig()
        let entry = DomainEntry(domain: host)
        config.domains = [entry]
        config.services.append(ServiceEntry(id: "custom_ex", name: "Example", enabled: true,
                                            domains: [host], ipRanges: [], isCustom: true))
        XCTAssertEqual(removal(config), .listEntry(id: entry.id, list: .bypass, entry: host))
    }

    /// Custom mode deletes the rule in force: enabled, lowest order, on a route that is on.
    func testCustomModeDeletesTheRuleInForce() {
        var config = bypassConfig()
        config.schemaVersion = 2
        config.routingMode = .custom
        let direct = Route(name: "Direct", egress: .direct)
        let proxy = Route(name: "Office proxy", egress: .proxyHTTP, enabled: false)
        config.routes = [direct, proxy]
        let offRoute = Rule(matchType: .domain, pattern: host, routeId: proxy.id, order: 0)
        let disabled = Rule(matchType: .domain, pattern: host, routeId: direct.id, enabled: false, order: 1)
        let suffix = Rule(matchType: .suffix, pattern: "example.com", routeId: direct.id, order: 3)
        config.rules = [suffix, offRoute, disabled]
        XCTAssertEqual(removal(config), .rule(id: suffix.id, entry: "*.example.com", routeName: "Direct"))
        let exact = Rule(matchType: .domain, pattern: host, routeId: direct.id, order: 2)
        config.rules.append(exact)
        XCTAssertEqual(removal(config), .rule(id: exact.id, entry: host, routeName: "Direct"))
        config.rules = [offRoute, disabled]
        XCTAssertNil(removal(config))
    }

    /// A rule in force that sends the name to the VPN or a proxy is not a bypass: no button,
    /// the Rules page changes it. A Direct rule below it is not in force, so it does not count.
    func testCustomModeOffersNothingForARuleThatIsNotDirect() {
        var config = bypassConfig()
        config.schemaVersion = 2
        config.routingMode = .custom
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))
        config.routes = [direct, vpn]
        let toVPN = Rule(matchType: .suffix, pattern: "example.com", routeId: vpn.id, order: 0)
        let toDirect = Rule(matchType: .domain, pattern: host, routeId: direct.id, order: 1)
        config.rules = [toVPN, toDirect]
        XCTAssertNil(removal(config))
    }

    // MARK: - What still holds the name

    /// The config once a removal is done, for the "still listed" line: each case takes out
    /// exactly what it names.
    func testTheConfigWithoutARemoval() {
        var config = bypassConfig()
        let exact = DomainEntry(domain: host)
        let wildcard = DomainEntry(domain: "*.example.com")
        config.domains = [exact, wildcard]
        let first = try! XCTUnwrap(removal(config))
        let after = RouteManager.config(config, without: first)
        XCTAssertEqual(after.domains.map(\.domain), ["*.example.com"])
        XCTAssertEqual(RouteManager.lookupRemoval(host, config: after),
                       .listEntry(id: wildcard.id, list: .bypass, entry: "*.example.com"),
                       "the wildcard still holds the name")
        config.domains = []
        config.services.append(ServiceEntry(id: "custom_ex", name: "Example", enabled: true,
                                            domains: ["a.example.com", host], ipRanges: [], isCustom: true))
        let fromService = RouteManager.config(config, without: try! XCTUnwrap(removal(config)))
        XCTAssertEqual(fromService.services.last?.domains, ["a.example.com"])
        XCTAssertNil(RouteManager.lookupRemoval(host, config: fromService))
        let slack = config.services.firstIndex { $0.id == "slack" }!
        config.services[slack].enabled = true
        let off = RouteManager.config(config, without: .turnOffService(serviceId: "slack", service: "Slack"))
        XCTAssertFalse(off.services[slack].enabled)
    }

    // MARK: - What the button says

    func testTheButtonSaysWhatGoes() {
        let id = UUID()
        XCTAssertEqual(LookupRemoval.listEntry(id: id, list: .bypass, entry: host).title(for: host), "Remove")
        XCTAssertEqual(LookupRemoval.listEntry(id: id, list: .vpnOnly, entry: "*.example.com").title(for: host),
                       "Remove *.example.com")
        XCTAssertEqual(LookupRemoval.serviceDomain(serviceId: "x", service: "Example", entry: host).title(for: host),
                       "Remove from Example")
        XCTAssertEqual(LookupRemoval.serviceDomain(serviceId: "x", service: "Example", entry: "*.example.com").title(for: host),
                       "Remove *.example.com from Example")
        XCTAssertEqual(LookupRemoval.turnOffService(serviceId: "slack", service: "Slack").title(for: host), "Turn off Slack")
        XCTAssertEqual(LookupRemoval.rule(id: id, entry: host, routeName: "Direct").title(for: host), "Remove")
        XCTAssertEqual(LookupRemoval.rule(id: id, entry: "*.example.com", routeName: "Direct").title(for: host),
                       "Remove *.example.com")
    }

    // MARK: - What a row offers

    func testUnlistedRowsOfferTheAddAndTheAddPanel() {
        XCTAssertEqual(LookupRow.offers(listed: false, canRemove: false, isApplying: false), [.add, .moreWays])
    }

    func testListedRowsOfferRemoveOnlyWhenThePageHasOne() {
        XCTAssertEqual(LookupRow.offers(listed: true, canRemove: true, isApplying: false), [.remove])
        XCTAssertEqual(LookupRow.offers(listed: true, canRemove: false, isApplying: false), [],
                       "nothing to remove: the row offers nothing, its detail line still says where it is listed")
    }

    func testNoRowOffersAnythingWhileRoutesAreApplied() {
        XCTAssertEqual(LookupRow.offers(listed: false, canRemove: false, isApplying: true), [])
        XCTAssertEqual(LookupRow.offers(listed: true, canRemove: true, isApplying: true), [])
    }
}

/// `removeLookup` through the live RouteManager (no VPN, so the config paths alone).
@MainActor
final class LookupRemoveTests: RouteManagerTestCase {

    private let host = "api.example.com"

    override func setUp() {
        super.setUp()
        rm.config.routingMode = .bypass
        rm.config.schemaVersion = 1
        rm.config.domains = []
        rm.config.inverseDomains = []
        rm.config.services.removeAll(where: { $0.isCustom })
        rm.config.builtInServiceExtras = [:]
    }

    /// After the remove the name is unlisted, so the row offers Add again.
    private func assertUnlisted(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(rm.lookupListing(host), file: file, line: line)
        XCTAssertNil(rm.lookupRemoval(host), file: file, line: line)
    }

    /// The Bypass list entry goes after its routes, in a task, as on the Domains page.
    func testRemovesTheNameFromTheBypassList() async {
        rm.config.domains = [DomainEntry(domain: host), DomainEntry(domain: "other.example.com")]
        let removal = try! XCTUnwrap(rm.lookupRemoval(host))
        XCTAssertEqual(rm.removeLookup(removal, for: host)?.isError, false)
        for _ in 0..<100 where rm.config.domains.count > 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(rm.config.domains.map(\.domain), ["other.example.com"])
        assertUnlisted()
    }

    /// In VPN Only mode the entry goes after its routes, in a task, as on the Domains page.
    func testRemovesAWildcardFromTheVPNOnlyList() async {
        rm.config.routingMode = .vpnOnly
        rm.config.inverseDomains = [DomainEntry(domain: "*.example.com")]
        let removal = try! XCTUnwrap(rm.lookupRemoval(host))
        XCTAssertEqual(removal.title(for: host), "Remove *.example.com")
        XCTAssertEqual(rm.removeLookup(removal, for: host)?.isError, false)
        for _ in 0..<100 where !rm.config.inverseDomains.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(rm.config.inverseDomains.isEmpty)
        assertUnlisted()
    }

    /// The name's own entry under a wildcard: Remove takes the entry, and the line says the
    /// wildcard still lists the name, since the row keeps reading Bypassed.
    func testSaysWhenAnotherEntryStillListsTheName() async {
        rm.config.domains = [DomainEntry(domain: host), DomainEntry(domain: "*.example.com")]
        let removal = try! XCTUnwrap(rm.lookupRemoval(host))
        let line = try! XCTUnwrap(rm.removeLookup(removal, for: host))
        XCTAssertFalse(line.isError)
        XCTAssertTrue(line.message.contains("still listed by another entry"), line.message)
        for _ in 0..<100 where rm.config.domains.count > 1 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(rm.lookupRemoval(host), .listEntry(id: rm.config.domains[0].id, list: .bypass, entry: "*.example.com"))
        // The last entry goes with no such note.
        let last = try! XCTUnwrap(rm.removeLookup(rm.lookupRemoval(host)!, for: host))
        XCTAssertFalse(last.message.contains("still listed"), last.message)
    }

    func testRemovesTheDomainFromACustomServiceKeepingTheRest() {
        rm.addCustomService(name: "Example", domains: ["a.example.com", host], ipRanges: ["10.0.0.0/8"])
        let removal = try! XCTUnwrap(rm.lookupRemoval(host))
        XCTAssertEqual(rm.removeLookup(removal, for: host)?.isError, false)
        let service = rm.config.services.first { $0.name == "Example" }!
        XCTAssertEqual(service.domains, ["a.example.com"])
        XCTAssertEqual(service.ipRanges, ["10.0.0.0/8"])
        XCTAssertTrue(service.enabled)
        assertUnlisted()
    }

    func testRemovesADomainAddedToABuiltInService() {
        let slack = rm.config.services.firstIndex { $0.id == "slack" }!
        rm.config.services[slack].enabled = true
        XCTAssertTrue(rm.addDomainToBuiltInService(host, serviceId: "slack"))
        let removal = try! XCTUnwrap(rm.lookupRemoval(host))
        XCTAssertEqual(rm.removeLookup(removal, for: host)?.isError, false)
        XCTAssertFalse(rm.config.services[slack].domains.contains(host))
        XCTAssertNil(rm.config.builtInServiceExtras["slack"])
        XCTAssertTrue(rm.config.services[slack].enabled, "the service stays on")
        assertUnlisted()
    }

    func testTurnsOffABuiltInServiceThatShipsTheName() {
        let slack = rm.config.services.firstIndex { $0.id == "slack" }!
        rm.config.services[slack].enabled = true
        let removal = try! XCTUnwrap(rm.lookupRemoval("slack.com"))
        XCTAssertEqual(rm.removeLookup(removal, for: "slack.com")?.isError, false)
        XCTAssertFalse(rm.config.services[slack].enabled)
        XCTAssertNil(rm.lookupListing("slack.com"))
        XCTAssertEqual(rm.lookupServiceToTurnOn("slack.com")?.id, "slack", "the row offers to turn it back on")
        XCTAssertNil(rm.removeLookup(removal, for: "slack.com"), "already off: nothing to do")
    }

    func testDeletesTheCustomModeRule() {
        rm.config.schemaVersion = 2
        rm.config.routingMode = .custom
        if !rm.config.routes.contains(where: { $0.egress == .direct }) {
            rm.config.routes.append(Route(name: "Direct", egress: .direct))
        }
        rm.config.rules = []
        guard case .success? = rm.addDirectRule(host) else { return XCTFail("rule not added") }
        let removal = try! XCTUnwrap(rm.lookupRemoval(host))
        XCTAssertEqual(rm.removeLookup(removal, for: host)?.isError, false)
        XCTAssertTrue(rm.config.rules.isEmpty)
        assertUnlisted()
    }
}
