// LookupAddPanelTests.swift
// The DNS Lookups add panel: the wildcard levels it offers, the public-suffix floor, where it
// can add in each mode, and the domains a user adds to a built-in service, which must outlive
// restarts and app updates.

import XCTest
@testable import VPNBypassCore

final class LookupAddLevelsTests: XCTestCase {

    func testOffersTheNameThenEveryWildcardDownToTheSiteDomain() {
        XCTAssertEqual(LookupAddLevels.levels(for: "api.us5.datadoghq.com"),
                       ["api.us5.datadoghq.com", "*.us5.datadoghq.com", "*.datadoghq.com"])
        XCTAssertEqual(LookupAddLevels.levels(for: "http-intake.logs.us5.datadoghq.com"),
                       ["http-intake.logs.us5.datadoghq.com", "*.logs.us5.datadoghq.com",
                        "*.us5.datadoghq.com", "*.datadoghq.com"])
    }

    /// The site's own domain gets its one wildcard, which holds the name too.
    func testTheSiteDomainGetsItsOwnWildcard() {
        XCTAssertEqual(LookupAddLevels.levels(for: "datadoghq.com"), ["datadoghq.com", "*.datadoghq.com"])
        XCTAssertEqual(LookupAddLevels.levels(for: "bbc.co.uk"), ["bbc.co.uk", "*.bbc.co.uk"])
    }

    /// Never a wildcard over a top-level domain or a two-label public suffix.
    func testNeverOffersAPublicSuffix() {
        XCTAssertEqual(LookupAddLevels.levels(for: "www.bbc.co.uk"), ["www.bbc.co.uk", "*.bbc.co.uk"])
        XCTAssertEqual(LookupAddLevels.levels(for: "a.b.example.com.au"),
                       ["a.b.example.com.au", "*.b.example.com.au", "*.example.com.au"])
        XCTAssertEqual(LookupAddLevels.levels(for: "co.uk"), ["co.uk"])
        XCTAssertEqual(LookupAddLevels.levels(for: "localhost"), ["localhost"])
        for name in ["api.us5.datadoghq.com", "www.bbc.co.uk", "x.y.shop.com.br", "datadoghq.com"] {
            for level in LookupAddLevels.levels(for: name).dropFirst() {
                let suffix = String(level.dropFirst(2))
                XCTAssertGreaterThanOrEqual(suffix.split(separator: ".").count, 2, level)
                XCTAssertFalse(LookupAddLevels.twoLabelPublicSuffixes.contains(suffix), level)
                XCTAssertFalse(suffix.split(separator: ".").count == 1, level)
            }
        }
    }

    /// Every wildcard offered is one the lists accept as typed.
    @MainActor
    func testEveryWildcardOfferedSurvivesCleanDomain() {
        for level in LookupAddLevels.levels(for: "http-intake.logs.us5.datadoghq.com").dropFirst() {
            XCTAssertEqual(RouteManager.shared.cleanDomain(level), level)
        }
    }

    func testRegistrableDomain() {
        XCTAssertEqual(LookupAddLevels.registrableDomain("API.us5.DatadogHQ.com"), "datadoghq.com")
        XCTAssertEqual(LookupAddLevels.registrableDomain("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(LookupAddLevels.registrableDomain("*.us5.datadoghq.com"), "datadoghq.com")
        XCTAssertNil(LookupAddLevels.registrableDomain("localhost"))
        XCTAssertNil(LookupAddLevels.registrableDomain("co.uk"))
    }
}

final class LookupAddChoicesTests: XCTestCase {

    private let services = [
        ServiceEntry(id: "custom_dd", name: "Datadog", enabled: true, domains: ["app.datadoghq.com"], ipRanges: [], isCustom: true),
        ServiceEntry(id: "slack", name: "Slack", enabled: false, domains: ["slack.com"], ipRanges: []),
    ]

    func testBypassModeOffersTheListNewServiceAndEveryService() {
        let choices = LookupAddChoices(name: "api.datadoghq.com", mode: .bypass, services: services)
        XCTAssertEqual(choices.targets, [.modeList, .newService])
        XCTAssertEqual(choices.services.map(\.id), ["custom_dd", "slack"])
        XCTAssertEqual(choices.defaultLevel, "api.datadoghq.com", "the exact name is chosen first")
        XCTAssertEqual(choices.defaultTarget, .modeList)
        XCTAssertEqual(choices.levels, ["api.datadoghq.com", "*.datadoghq.com"])
    }

    func testVPNOnlyModeOffersOnlyItsList() {
        let choices = LookupAddChoices(name: "jira.corp.example.com", mode: .vpnOnly, services: services)
        XCTAssertEqual(choices.targets, [.modeList])
        XCTAssertTrue(choices.services.isEmpty, "services route only in Bypass mode")
        XCTAssertEqual(choices.levels.last, "*.example.com")
    }

    func testCustomModeOffersADirectRule() {
        let choices = LookupAddChoices(name: "api.datadoghq.com", mode: .custom, services: services)
        XCTAssertEqual(choices.targets, [.directRule])
        XCTAssertEqual(choices.defaultTarget, .directRule)
        XCTAssertTrue(choices.services.isEmpty)
    }

    func testSearchFiltersServicesByNameKeepingTheirOrder() {
        let choices = LookupAddChoices(name: "api.datadoghq.com", mode: .bypass, services: services)
        XCTAssertEqual(choices.services(matching: "  sla ").map(\.id), ["slack"])
        XCTAssertEqual(choices.services(matching: "").map(\.id), ["custom_dd", "slack"])
        XCTAssertTrue(choices.services(matching: "zzz").isEmpty)
    }

    /// A service the search hides is no longer the target, so Add cannot send the name to a
    /// place the panel does not show. Any other target stays.
    func testASearchThatHidesThePickedServiceDropsIt() {
        let choices = LookupAddChoices(name: "api.datadoghq.com", mode: .bypass, services: services)
        XCTAssertEqual(choices.target(.service("slack"), whenSearching: "zzz"), .modeList)
        XCTAssertEqual(choices.target(.service("slack"), whenSearching: "sla"), .service("slack"))
        XCTAssertEqual(choices.target(.newService, whenSearching: "zzz"), .newService)
        XCTAssertEqual(choices.target(.modeList, whenSearching: "zzz"), .modeList)
    }

    /// The box is as tall as a short list, and eight rows tall for a long one, which scrolls.
    func testTheServiceBoxHoldsEightRows() {
        XCTAssertEqual(LookupAddPanel.maxRows, 8)
        XCTAssertEqual(LookupAddPanel.listHeight(count: 3), 3 * LookupAddPanel.rowHeight)
        XCTAssertEqual(LookupAddPanel.listHeight(count: 20), 8 * LookupAddPanel.rowHeight)
    }

    /// A hosting or CDN domain is not one site: its widest wildcard is the customer's name.
    func testNeverOffersAHostingDomainAsTheSite() {
        XCTAssertEqual(LookupAddLevels.levels(for: "d1abc.cloudfront.net"), ["d1abc.cloudfront.net", "*.d1abc.cloudfront.net"])
        XCTAssertEqual(LookupAddLevels.levels(for: "docs.foo.github.io"), ["docs.foo.github.io", "*.foo.github.io"])
        XCTAssertEqual(LookupAddLevels.levels(for: "github.io"), ["github.io"])
    }

    /// Under amazonaws.com all but the first label is a shared AWS endpoint: never
    /// `*.s3.amazonaws.com`, which would take in every bucket.
    func testNeverOffersASharedAWSEndpoint() {
        XCTAssertEqual(LookupAddLevels.levels(for: "my-bucket.s3.amazonaws.com"),
                       ["my-bucket.s3.amazonaws.com", "*.my-bucket.s3.amazonaws.com"])
        XCTAssertEqual(LookupAddLevels.levels(for: "my-bucket.s3.eu-west-1.amazonaws.com"),
                       ["my-bucket.s3.eu-west-1.amazonaws.com", "*.my-bucket.s3.eu-west-1.amazonaws.com"])
        XCTAssertEqual(LookupAddLevels.levels(for: "s3.amazonaws.com"), ["s3.amazonaws.com"])
        XCTAssertEqual(LookupAddLevels.levels(for: "s3-external-1.amazonaws.com"), ["s3-external-1.amazonaws.com"])
        XCTAssertEqual(LookupAddLevels.registrableDomain("my-bucket.s3.amazonaws.com"), "my-bucket.s3.amazonaws.com")
    }

    func testTheSuggestedServiceNameIsTheSiteName() {
        XCTAssertEqual(NewServiceSheet.suggestedName(for: "http-intake.logs.us5.datadoghq.com"), "Datadoghq")
        XCTAssertEqual(NewServiceSheet.suggestedName(for: "*.bbc.co.uk"), "Bbc")
        XCTAssertEqual(NewServiceSheet.suggestedName(for: "api.bbc.co.uk"), "Bbc")
        XCTAssertEqual(NewServiceSheet.suggestedName(for: "localhost"), "localhost")
    }
}

/// Adding what the panel chose, in each mode.
@MainActor
final class LookupAddTargetTests: RouteManagerTestCase {

    override func setUp() {
        super.setUp()
        rm.config.routingMode = .bypass
        rm.config.schemaVersion = 1
        rm.config.domains = []
        rm.config.inverseDomains = []
        rm.config.builtInServiceExtras = [:]
        rm.config.services.removeAll(where: { $0.isCustom })
    }

    func testAWildcardOnTheBypassListHoldsEveryNameUnderIt() {
        XCTAssertEqual(rm.addLookup("*.datadoghq.com", to: .modeList)?.isError, false)
        XCTAssertEqual(rm.config.domains.map(\.domain), ["*.datadoghq.com"])
        XCTAssertTrue(rm.config.domains[0].isWildcard)
        XCTAssertEqual(rm.lookupListing("api.us5.datadoghq.com"), .bypassList)
        XCTAssertEqual(rm.lookupListing("datadoghq.com"), .bypassList)
        XCTAssertNil(rm.lookupListing("datadoghq.com.evil.example"))
    }

    func testVPNOnlyModeAddsToItsList() {
        rm.config.routingMode = .vpnOnly
        XCTAssertEqual(rm.addLookup("*.corp.example.com", to: .modeList)?.isError, false)
        XCTAssertEqual(rm.config.inverseDomains.map(\.domain), ["*.corp.example.com"])
        XCTAssertEqual(rm.lookupListing("jira.corp.example.com"), .vpnOnlyList)
    }

    /// Custom mode: the exact name becomes a domain rule, a wildcard a suffix rule on Direct.
    func testCustomModeAddsADomainOrASuffixRule() {
        rm.config.schemaVersion = 2
        rm.config.routingMode = .custom
        rm.config.rules = []
        let direct = rm.config.routes.first { $0.egress == .direct }!

        XCTAssertNil(rm.addLookup("api.datadoghq.com", to: .directRule))
        XCTAssertNil(rm.addLookup("*.us5.datadoghq.com", to: .directRule))
        XCTAssertEqual(rm.config.rules.map(\.matchType), [.domain, .suffix])
        XCTAssertEqual(rm.config.rules.map(\.pattern), ["api.datadoghq.com", "us5.datadoghq.com"])
        XCTAssertTrue(rm.config.rules.allSatisfy { $0.routeId == direct.id })
        XCTAssertEqual(rm.lookupListing("intake.us5.datadoghq.com"), .rule(routeName: "Direct"))

        // The same suffix again is refused, naming its route.
        XCTAssertEqual(rm.addLookup("*.us5.datadoghq.com", to: .directRule)?.isError, true)
        XCTAssertEqual(rm.config.rules.count, 2)
    }

    /// A rule that routes nothing (switched off, or on a route that is off) does not refuse a
    /// new Direct rule for the same name, which the Lookups page shows as not listed.
    func testASwitchedOffRuleDoesNotBlockADirectRule() {
        rm.config.schemaVersion = 2
        rm.config.routingMode = .custom
        let direct = rm.config.routes.first { $0.egress == .direct }!
        var offRoute = Route(name: "Off", egress: .direct)
        offRoute.enabled = false
        rm.config.routes.append(offRoute)
        defer { rm.config.routes.removeAll { $0.id == offRoute.id } }
        var offRule = Rule(matchType: .domain, pattern: "api.datadoghq.com", routeId: direct.id, order: 0)
        offRule.enabled = false
        rm.config.rules = [offRule, Rule(matchType: .suffix, pattern: "us5.datadoghq.com", routeId: offRoute.id, order: 1)]

        XCTAssertNil(rm.addLookup("api.datadoghq.com", to: .directRule))
        XCTAssertNil(rm.addLookup("*.us5.datadoghq.com", to: .directRule))
        XCTAssertEqual(rm.config.rules.count, 4)
        XCTAssertEqual(rm.lookupListing("intake.us5.datadoghq.com"), .rule(routeName: "Direct"))
    }

    func testAddsAWildcardToACustomService() {
        rm.addCustomService(name: "Datadog", domains: ["app.datadoghq.com"], ipRanges: [])
        let id = rm.config.services.first { $0.name == "Datadog" }!.id
        XCTAssertEqual(rm.addLookup("*.datadoghq.com", to: .service(id))?.isError, false)
        XCTAssertEqual(rm.config.services.first { $0.id == id }!.domains, ["app.datadoghq.com", "*.datadoghq.com"])
        XCTAssertEqual(rm.lookupListing("api.datadoghq.com"), .service("Datadog"))
        XCTAssertTrue(rm.config.builtInServiceExtras.isEmpty, "a custom service keeps its own domains")
    }
}

/// Domains added to a built-in service: merged in wherever service domains are read, kept
/// apart so the shipped list cannot wipe them, and removable while the shipped ones are not.
@MainActor
final class BuiltInServiceExtrasTests: RouteManagerTestCase {

    private let shippedSlack = Config.defaultServices.first { $0.id == "slack" }!.domains

    override func setUp() {
        super.setUp()
        rm.config.routingMode = .bypass
        rm.config.schemaVersion = 1
        rm.config.domains = []
        rm.config.builtInServiceExtras = [:]
        rm.config.services.removeAll(where: { $0.isCustom })
        // The shared manager keeps its config between tests: start from the shipped list.
        rm.config.services[rm.config.services.firstIndex { $0.id == "slack" }!].domains = shippedSlack
        setSlack(enabled: true)
    }

    private func setSlack(enabled: Bool) {
        rm.config.services[rm.config.services.firstIndex { $0.id == "slack" }!].enabled = enabled
    }

    private var slack: ServiceEntry { rm.config.services.first { $0.id == "slack" }! }

    func testTheFieldSurvivesAnEncodeDecodeRoundTrip() throws {
        var config = Config()
        config.builtInServiceExtras = ["slack": ["files.example.org", "*.slack-edge.example"]]
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.builtInServiceExtras, config.builtInServiceExtras)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(old.builtInServiceExtras, [:])
    }

    func testAddingToABuiltInServiceRoutesTheNameAndRecordsIt() {
        let line = rm.addLookup("files.example.org", toService: "slack")
        XCTAssertEqual(line?.isError, false)
        XCTAssertEqual(slack.domains, shippedSlack + ["files.example.org"])
        XCTAssertEqual(rm.config.builtInServiceExtras, ["slack": ["files.example.org"]])
        XCTAssertEqual(rm.lookupListing("files.example.org"), .service("Slack"))
        XCTAssertEqual(rm.domainsAddedToBuiltInService("slack"), ["files.example.org"])

        XCTAssertEqual(rm.addLookup("files.example.org", toService: "slack")?.isError, true, "already there")
        XCTAssertEqual(rm.addLookup(shippedSlack[0], toService: "slack")?.isError, true, "a shipped domain is already there")
        XCTAssertEqual(rm.config.builtInServiceExtras["slack"], ["files.example.org"])
    }

    /// The launch resets a built-in service to the shipped list; the extras come back after it.
    func testAddedDomainsSurviveARestart() {
        rm.addDomainToBuiltInService("files.example.org", serviceId: "slack")
        rm.addDomainToBuiltInService("*.slack-edge.example", serviceId: "slack")
        rm.loadConfig()
        XCTAssertEqual(slack.domains, shippedSlack + ["files.example.org", "*.slack-edge.example"])
        XCTAssertTrue(slack.enabled)
        XCTAssertEqual(rm.lookupListing("a.slack-edge.example"), .service("Slack"))
    }

    /// An app update ships a different list: it replaces the old shipped domains, the user's
    /// stay, and one the update now ships is not listed twice.
    func testAddedDomainsSurviveAnAppUpdate() throws {
        rm.addDomainToBuiltInService("files.example.org", serviceId: "slack")
        rm.addDomainToBuiltInService(shippedSlack[0], serviceId: "slack") // refused: shipped
        XCTAssertEqual(rm.config.builtInServiceExtras["slack"], ["files.example.org"])

        // As an older version saved it: other shipped domains, and an extra the new list ships.
        var onDisk = try JSONDecoder().decode(Config.self, from: Data(contentsOf: rm.configURL))
        let index = onDisk.services.firstIndex { $0.id == "slack" }!
        onDisk.services[index].domains = ["old.slack.example", "files.example.org"]
        onDisk.builtInServiceExtras["slack"] = ["files.example.org", shippedSlack[1]]
        try JSONEncoder().encode(onDisk).write(to: rm.configURL)

        rm.loadConfig()
        XCTAssertEqual(slack.domains, shippedSlack + ["files.example.org"])
        XCTAssertFalse(slack.domains.contains("old.slack.example"), "the shipped list is authoritative for its own entries")
        XCTAssertEqual(rm.domainsAddedToBuiltInService("slack"), ["files.example.org"])
    }

    func testRemovesOnlyWhatTheUserAdded() {
        rm.addDomainToBuiltInService("files.example.org", serviceId: "slack")
        XCTAssertFalse(rm.removeDomainFromBuiltInService(shippedSlack[0], serviceId: "slack"))
        XCTAssertEqual(slack.domains, shippedSlack + ["files.example.org"])

        XCTAssertTrue(rm.removeDomainFromBuiltInService("files.example.org", serviceId: "slack"))
        XCTAssertEqual(slack.domains, shippedSlack)
        XCTAssertNil(rm.config.builtInServiceExtras["slack"])
        rm.loadConfig()
        XCTAssertEqual(slack.domains, shippedSlack, "a removed domain stays removed after a restart")
    }

    /// The extras are in the service's domains, so every reader of them sees them: the
    /// resolver skips a wildcard, and the wildcard planner serves it in Bypass and Custom mode.
    func testExtrasReachEveryReaderOfServiceDomains() {
        rm.addDomainToBuiltInService("*.slack-edge.example", serviceId: "slack")
        XCTAssertTrue(slack.domains.contains("*.slack-edge.example"))
        XCTAssertFalse(slack.resolvableDomains.contains("*.slack-edge.example"))
        XCTAssertTrue(WildcardPlanner.configuredSuffixes(rm.config).contains("slack-edge.example"))

        var custom = rm.config
        custom.schemaVersion = 2
        custom.routingMode = .custom
        let direct = custom.routes.first { $0.egress == .direct }!
        custom.rules = [Rule(matchType: .service, pattern: "slack", routeId: direct.id, order: 0)]
        XCTAssertEqual(WildcardPlanner.configuredSuffixes(custom), ["slack-edge.example"])
    }

    func testRefusesCustomServicesAndUnknownIds() {
        rm.addCustomService(name: "Mine", domains: ["a.example"], ipRanges: [])
        let id = rm.config.services.first { $0.name == "Mine" }!.id
        XCTAssertFalse(rm.addDomainToBuiltInService("b.example", serviceId: id))
        XCTAssertFalse(rm.addDomainToBuiltInService("b.example", serviceId: "no-such-service"))
        XCTAssertTrue(rm.config.builtInServiceExtras.isEmpty)
    }
}
