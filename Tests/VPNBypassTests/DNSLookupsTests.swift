// DNSLookupsTests.swift
// The opt-in DNS Lookups page (#176): reading tcpdump's query lines, buffering them in the
// helper, counting them in the app, and the switch that keeps it all off by default.

import XCTest
@testable import VPNBypassCore

final class DNSQueryLineTests: XCTestCase {

    // Lines as `tcpdump -i any -p -l -n -t -s 512 "udp dst port 53"` printed them on macOS 26.6.1.
    func testReadsTheNameOfEachQueryType() {
        XCTAssertEqual(DNSQueryLine.name(from: "IP 192.168.10.11.61955 > 1.1.1.1.53: 29302+ [1au] A? apple.com. (38)"), "apple.com")
        XCTAssertEqual(DNSQueryLine.name(from: "IP 192.168.10.11.59104 > 1.1.1.1.53: 41380+ [1au] AAAA? github.com. (39)"), "github.com")
        XCTAssertEqual(DNSQueryLine.name(from: "IP 192.168.10.11.58592 > 1.1.1.1.53: 59911+ Type65? one.one.one.one. (33)"), "one.one.one.one")
        XCTAssertEqual(DNSQueryLine.name(from: "IP6 fe80::1.52000 > fe80::2.53: 41380+ HTTPS? WWW.Example.COM. (39)"), "www.example.com")
    }

    func testSkipsHousekeepingQueries() {
        XCTAssertNil(DNSQueryLine.name(from: "IP 192.168.10.11.58335 > 1.1.1.1.53: 7055+ [1au] PTR? 1.1.1.1.in-addr.arpa. (49)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 192.168.10.11.62342 > 1.1.1.1.53: 63811+ Type64? _dns.resolver.arpa. (36)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5353 > 224.0.0.251.53: 0 A? printer.local. (30)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ A? localhost. (27)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ A? weird/name.com. (27)"))
        XCTAssertNil(DNSQueryLine.name(from: "tcpdump: listening on any, link-type PKTAP"))
        XCTAssertNil(DNSQueryLine.name(from: ""))
    }

    /// The question type alone decides these: the names would pass every other check.
    func testSkipsQuestionTypesThatDoNotOpenAConnection() {
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ TXT? example.com. (29)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ PTR? example.com. (29)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ Type64? example.com. (29)"))
    }

    func testKeepsCompanyNames() {
        // VPN Only users list exactly these.
        XCTAssertEqual(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.8.0.1.53: 1+ A? jira.corp.internal. (36)"), "jira.corp.internal")
    }
}

final class DNSQueryBufferTests: XCTestCase {

    func testJoinsALineSplitAcrossReads() {
        var buffer = DNSQueryBuffer()
        buffer.append(Data("IP 10.0.0.2.1 > 1.1.1.1.53: 1+ A? exam".utf8))
        XCTAssertEqual(buffer.names, [])
        buffer.append(Data("ple.com. (29)\nIP 10.0.0.2.1 > 1.1.1.1.53: 2+ A? b.org. (29)\n".utf8))
        XCTAssertEqual(buffer.drain(), ["example.com", "b.org"])
        XCTAssertEqual(buffer.drain(), [])
    }

    func testKeepsTheNewestNamesWhenNobodyDrains() {
        var buffer = DNSQueryBuffer(limit: 3)
        for i in 1...5 {
            buffer.append(Data("IP 10.0.0.2.1 > 1.1.1.1.53: 1+ A? n\(i).com. (29)\n".utf8))
        }
        XCTAssertEqual(buffer.drain(), ["n3.com", "n4.com", "n5.com"])
    }

    func testDropsAStreamWithNoLineBreaks() {
        var buffer = DNSQueryBuffer()
        buffer.append(Data(repeating: UInt8(ascii: "x"), count: 5000))
        buffer.append(Data("IP 10.0.0.2.1 > 1.1.1.1.53: 1+ A? after.com. (29)\n".utf8))
        XCTAssertEqual(buffer.drain(), ["after.com"])
    }
}

final class DNSLookupTallyTests: XCTestCase {

    func testANameCountsOncePerDrain() {
        var tally = DNSLookupTally()
        let now = Date()
        // A browser's A, AAAA and HTTPS for one visit arrive in the same drain.
        tally.record(["github.com", "github.com", "github.com", "apple.com"], at: now)
        tally.record(["github.com"], at: now.addingTimeInterval(3))
        XCTAssertEqual(tally.entries["github.com"]?.count, 2)
        XCTAssertEqual(tally.entries["apple.com"]?.count, 1)
        XCTAssertEqual(tally.entries["github.com"]?.lastSeen, now.addingTimeInterval(3))
    }

    func testRanksByCountThenNameAndFiltersBySearch() {
        var tally = DNSLookupTally()
        let now = Date()
        tally.record(["b.com", "a.com", "c.org"], at: now)
        tally.record(["c.org"], at: now)
        XCTAssertEqual(tally.ranked().map(\.name), ["c.org", "a.com", "b.com"])
        XCTAssertEqual(tally.ranked(matching: " .COM ").map(\.name), ["a.com", "b.com"])
    }

    func testForgetsTheLeastRecentNamesPastTheLimit() {
        var tally = DNSLookupTally()
        let start = Date()
        for i in 0...DNSLookupTally.limit {
            tally.record(["n\(i).com"], at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(tally.entries.count, DNSLookupTally.limit)
        XCTAssertNil(tally.entries["n0.com"])
        XCTAssertNotNil(tally.entries["n\(DNSLookupTally.limit).com"])
    }
}

final class DNSLookupsConfigTests: XCTestCase {

    func testIsOffByDefaultAndForAnOldConfig() throws {
        XCTAssertFalse(Config().dnsLookupsEnabled)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.dnsLookupsEnabled)
    }

    /// Config's decoder is hand-written: a field with no decode line is saved and then read
    /// back as its default, so the switch would turn itself off on every launch.
    func testTheSwitchSurvivesAnEncodeDecodeRoundTrip() throws {
        var config = Config()
        config.dnsLookupsEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(decoded.dnsLookupsEnabled)
    }

    /// The helper compiles the parser from the Makefile's file list, not from Package.swift.
    func testTheHelperBuildIncludesTheCapture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        for file in ["Sources/VPNBypassCore/DNSQueryLine.swift", "Helper/DNSCapture.swift"] {
            XCTAssertEqual(makefile.components(separatedBy: file).count - 1, 2, "\(file) must be in both helper builds")
        }
    }
}

/// What the Lookups page shows for a name already routed, and adding a name to a group.
@MainActor
final class LookupListingTests: RouteManagerTestCase {

    override func setUp() {
        super.setUp()
        rm.config.routingMode = .bypass
        rm.config.domains = []
        rm.config.inverseDomains = []
        rm.config.services.removeAll(where: { $0.isCustom })
    }

    func testNamesTheListOrServiceThatHasTheName() {
        XCTAssertNil(rm.lookupListing("api.example.com"))
        rm.config.domains = [DomainEntry(domain: "api.example.com")]
        XCTAssertEqual(rm.lookupListing("api.example.com"), .bypassList)

        rm.config.domains = []
        rm.addCustomService(name: "Example", domains: ["api.example.com"], ipRanges: [])
        XCTAssertEqual(rm.lookupListing("api.example.com"), .service("Example"))

        // A service that is off does not route the name, so the page offers to turn it on.
        let id = rm.config.services.first { $0.name == "Example" }!.id
        rm.config.services[rm.config.services.firstIndex { $0.id == id }!].enabled = false
        XCTAssertNil(rm.lookupListing("api.example.com"))

        rm.config.routingMode = .vpnOnly
        XCTAssertNil(rm.lookupListing("api.example.com"))
        rm.config.inverseDomains = [DomainEntry(domain: "api.example.com")]
        XCTAssertEqual(rm.lookupListing("api.example.com"), .vpnOnlyList)
        rm.config.inverseDomains = [DomainEntry(domain: "api.example.com", enabled: false)]
        XCTAssertEqual(rm.lookupListing("api.example.com"), .listedOff)

        rm.config.routingMode = .bypass
        rm.config.domains = [DomainEntry(domain: "api.example.com", enabled: false)]
        XCTAssertEqual(rm.lookupListing("api.example.com"), .listedOff)
    }

    /// Learn a Site's one Add puts each entry on the mode's list, and adds nothing when the
    /// mode changed since the click.
    func testAddLearnedAddsEachEntryOnlyInTheModeOfTheClick() async {
        let none = await rm.addLearned(["a.learn.test", "*.learn.test"], mode: .vpnOnly)
        XCTAssertNil(none)
        XCTAssertEqual(rm.config.domains.map(\.domain), [])
        XCTAssertEqual(rm.config.inverseDomains.map(\.domain), [])

        let feedback = await rm.addLearned(["a.learn.test", "*.learn.test"], mode: .bypass)
        XCTAssertNotNil(feedback)
        XCTAssertEqual(rm.config.domains.map(\.domain), ["a.learn.test", "*.learn.test"])
    }

    /// A switched-off wildcard neither hides an enabled entry or service nor blocks adding
    /// the name itself.
    func testASwitchedOffWildcardIsNotAListing() {
        rm.config.domains = [DomainEntry(domain: "*.example.com", enabled: false)]
        XCTAssertNil(rm.lookupListing("api.example.com"), "adding api.example.com is accepted")
        rm.config.domains.append(DomainEntry(domain: "api.example.com"))
        XCTAssertEqual(rm.lookupListing("api.example.com"), .bypassList)

        rm.config.domains = [DomainEntry(domain: "*.example.com", enabled: false)]
        rm.addCustomService(name: "Example", domains: ["api.example.com"], ipRanges: [])
        XCTAssertEqual(rm.lookupListing("api.example.com"), .service("Example"))

        rm.config.routingMode = .vpnOnly
        rm.config.inverseDomains = [DomainEntry(domain: "*.example.com", enabled: false)]
        XCTAssertNil(rm.lookupListing("api.example.com"))
        rm.config.inverseDomains.append(DomainEntry(domain: "api.example.com"))
        XCTAssertEqual(rm.lookupListing("api.example.com"), .vpnOnlyList)
    }

    /// Custom mode names the route of the rule the compiler would use: enabled, lowest
    /// order, with a route that is on.
    func testCustomModeNamesTheRouteOfTheRuleInForce() {
        rm.config.schemaVersion = 2
        rm.config.routingMode = .custom
        let direct = rm.config.routes.first { $0.egress == .direct }!
        var proxy = Route(name: "Office proxy", egress: .proxyHTTP, enabled: true)
        rm.config.routes.append(proxy)
        rm.config.rules = [
            Rule(matchType: .domain, pattern: "api.example.com", routeId: proxy.id, order: 2),
            Rule(matchType: .domain, pattern: "api.example.com", routeId: direct.id, enabled: false, order: 0),
        ]
        XCTAssertEqual(rm.lookupListing("api.example.com"), .rule(routeName: "Office proxy"))

        rm.config.rules.append(Rule(matchType: .domain, pattern: "api.example.com", routeId: direct.id, order: 1))
        XCTAssertEqual(rm.lookupListing("api.example.com"), .rule(routeName: "Direct"))

        proxy.enabled = false
        rm.config.routes[rm.config.routes.firstIndex { $0.id == proxy.id }!] = proxy
        rm.config.rules.removeLast()
        XCTAssertNil(rm.lookupListing("api.example.com"))
    }

    /// Every service, built-in and custom, on or off, alphabetical when none is related.
    func testOffersEveryServiceAlphabetically() {
        rm.addCustomService(name: "Zeta", domains: ["z.example"], ipRanges: [])
        rm.addCustomService(name: "alpha", domains: ["a.example"], ipRanges: [])
        let offered = rm.lookupServices(for: "api.other.com").map(\.name)
        XCTAssertEqual(offered.count, rm.config.services.count)
        XCTAssertEqual(offered, offered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(offered.contains("Slack"), "built-in services are offered too")
        XCTAssertTrue(offered.contains("alpha") && offered.contains("Zeta"))
    }

    /// A service that already holds a name under the same site domain comes first; the one
    /// that holds the name itself is left out.
    func testSuggestsServicesWithTheSameParentDomainFirst() {
        rm.addCustomService(name: "Alpha", domains: ["a.example"], ipRanges: [])
        rm.addCustomService(name: "Zeta Datadog", domains: ["app.DatadogHQ.com"], ipRanges: [])
        rm.addCustomService(name: "Monitoring", domains: ["status.example", "browser-intake-datadoghq.com"], ipRanges: [])
        rm.addCustomService(name: "Logs", domains: ["http-intake.logs.us5.datadoghq.com"], ipRanges: [])
        XCTAssertEqual(rm.lookupServices(for: "http-intake.logs.us5.datadoghq.com").first?.name, "Zeta Datadog")
        XCTAssertFalse(rm.lookupServices(for: "http-intake.logs.us5.datadoghq.com").contains { $0.name == "Logs" })
        XCTAssertEqual(rm.lookupServices(for: "api.datadoghq.com").prefix(2).map(\.name), ["Logs", "Zeta Datadog"])
        XCTAssertEqual(rm.lookupServices(for: "localhost").map(\.name).filter { ["Alpha", "Logs", "Monitoring", "Zeta Datadog"].contains($0) },
                       ["Alpha", "Logs", "Monitoring", "Zeta Datadog"])
        // A wildcard counts as a name under its site domain.
        rm.addCustomService(name: "Wild", domains: ["*.datadoghq.com"], ipRanges: [])
        XCTAssertEqual(rm.lookupServices(for: "api.datadoghq.com").prefix(3).map(\.name), ["Logs", "Wild", "Zeta Datadog"])
    }

    func testAddsToAServiceKeepingItsNameSwitchAndAddresses() {
        rm.addCustomService(name: "Example", domains: ["a.example.com"], ipRanges: ["10.0.0.0/8"])
        let id = rm.config.services.first { $0.name == "Example" }!.id

        let added = rm.addLookup("b.example.com", toService: id)
        XCTAssertEqual(added?.isError, false)
        let service = rm.config.services.first { $0.id == id }!
        XCTAssertEqual(service.domains, ["a.example.com", "b.example.com"])
        XCTAssertEqual(service.ipRanges, ["10.0.0.0/8"])
        XCTAssertTrue(service.enabled)
        XCTAssertEqual(rm.lookupListing("b.example.com"), .service("Example"))

        XCTAssertEqual(rm.addLookup("b.example.com", toService: id)?.isError, true)
        XCTAssertEqual(rm.config.services.first { $0.id == id }!.domains.count, 2)
    }

    func testMakesANewServiceAndRefusesATakenName() {
        let made = rm.addLookup("c.example.com", toNewService: "  Example  ")
        XCTAssertFalse(made.isError)
        XCTAssertEqual(rm.lookupListing("c.example.com"), .service("Example"))

        let clash = rm.addLookup("d.example.com", toNewService: "example")
        XCTAssertTrue(clash.isError)
        XCTAssertNil(rm.lookupListing("d.example.com"))
    }

    // MARK: - Turning on the service that lists the name

    private func setEnabled(_ id: String, _ on: Bool) {
        rm.config.services[rm.config.services.firstIndex { $0.id == id }!].enabled = on
    }

    /// Only an exact domain of a switched-off service counts, the custom one first (the
    /// Services page lists custom services before built-in ones), and only in Bypass mode.
    func testFindsTheSwitchedOffServiceThatListsTheName() {
        setEnabled("slack", false)
        XCTAssertEqual(rm.lookupServiceToTurnOn("slack.com")?.id, "slack")
        XCTAssertNil(rm.lookupServiceToTurnOn("api.slack.com"), "a parent-domain match would not route the name")

        rm.addCustomService(name: "Chat", domains: ["slack.com"], ipRanges: [])
        XCTAssertEqual(rm.lookupListing("slack.com"), .service("Chat"))
        XCTAssertNil(rm.lookupServiceToTurnOn("slack.com"), "an enabled service already routes it")

        let chat = rm.config.services.first { $0.name == "Chat" }!.id
        setEnabled(chat, false)
        XCTAssertEqual(rm.lookupServiceToTurnOn("slack.com")?.id, chat)

        rm.config.routingMode = .vpnOnly
        XCTAssertNil(rm.lookupServiceToTurnOn("slack.com"))
    }

    func testTurningOnTheServiceRoutesTheName() {
        setEnabled("slack", false)
        let line = rm.turnOnLookupService("slack", for: "slack.com")
        XCTAssertEqual(line?.isError, false)
        XCTAssertTrue(rm.config.services.first { $0.id == "slack" }!.enabled)
        XCTAssertEqual(rm.lookupListing("slack.com"), .service("Slack"))
        XCTAssertNil(rm.lookupServiceToTurnOn("slack.com"))
        XCTAssertNil(rm.turnOnLookupService("slack", for: "slack.com"), "already on: nothing to do")
    }

    /// A built-in service a custom one holds off by its name stays off, and the line says why.
    func testRefusesABuiltInServiceACustomOneHoldsOff() {
        setEnabled("slack", false)
        rm.config.services.append(ServiceEntry(id: "custom_slack", name: "slack", enabled: false,
                                               domains: ["chat.example"], ipRanges: [], isCustom: true))
        XCTAssertEqual(rm.lookupServiceToTurnOn("slack.com")?.id, "slack")

        let line = rm.turnOnLookupService("slack", for: "slack.com")
        XCTAssertEqual(line?.isError, true)
        XCTAssertEqual(line?.message, ServiceNameClash.builtInOffMessage(custom: "slack"))
        XCTAssertFalse(rm.config.services.first { $0.id == "slack" }!.enabled)
    }

    /// When the first switched-off service with the name is held off, a later one that can be
    /// turned on is offered instead.
    func testSkipsAServiceACustomOneHoldsOffWhenAnotherCanBeTurnedOn() {
        setEnabled("slack", false)
        setEnabled("discord", false)
        rm.config.services[rm.config.services.firstIndex { $0.id == "discord" }!].domains.append("slack.com")
        rm.config.services.append(ServiceEntry(id: "custom_slack", name: "slack", enabled: false,
                                               domains: ["chat.example"], ipRanges: [], isCustom: true))
        XCTAssertEqual(rm.lookupServiceToTurnOn("slack.com")?.id, "discord")
    }
}
