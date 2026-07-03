// RuleDestinationBuilderTests.swift
// Coverage for the pure rule→destination matcher (custom-mode engine). Given a
// pre-resolved DNS map it maps each enabled rule onto its concrete kernel
// destinations: domain→IPs from the map, ip/cidr passthrough, service expansion,
// suffix/process→nothing, de-dup within a rule, and enabled-in-ascending-order output.

import XCTest
@testable import VPNBypassCore

final class RuleDestinationBuilderTests: XCTestCase {

    private func rule(_ mt: MatchType, _ pattern: String, order: Int = 0, enabled: Bool = true) -> Rule {
        Rule(matchType: mt, pattern: pattern, routeId: UUID(), enabled: enabled, order: order)
    }

    // MARK: - domain

    func testDomainRuleMapsToResolvedHostIPs() {
        let out = RuleDestinationBuilder.build(
            rules: [rule(.domain, "x.com")],
            services: [],
            resolved: ["x.com": ["1.1.1.1", "2.2.2.2"]]
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].dests.map(\.value), ["1.1.1.1", "2.2.2.2"])
        XCTAssertTrue(out[0].dests.allSatisfy { !$0.isNetwork }, "resolved IPs are host routes")
    }

    func testUnresolvedDomainYieldsNoDestsButStillAppears() {
        let out = RuleDestinationBuilder.build(rules: [rule(.domain, "x.com")], services: [], resolved: [:])
        XCTAssertEqual(out.count, 1, "the rule still appears (its route silently drops to the default)")
        XCTAssertTrue(out[0].dests.isEmpty)
    }

    // MARK: - ip / cidr passthrough (no DNS)

    func testIPAndCIDRPassthrough() {
        let out = RuleDestinationBuilder.build(
            rules: [rule(.ip, "9.9.9.9", order: 0), rule(.cidr, "10.0.0.0/8", order: 1)],
            services: [], resolved: [:]
        )
        XCTAssertEqual(out[0].dests.map(\.value), ["9.9.9.9"])
        XCTAssertFalse(out[0].dests[0].isNetwork, "a single IP is a host route")
        XCTAssertEqual(out[1].dests.map(\.value), ["10.0.0.0/8"])
        XCTAssertTrue(out[1].dests[0].isNetwork, "a CIDR is a network route")
    }

    // MARK: - service expansion

    func testServiceExpandsDomainsAndStaticIPRanges() {
        let svc = RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: true,
                                            domains: ["t.me", "core.telegram.org"], ipRanges: ["91.108.4.0/22"])
        let out = RuleDestinationBuilder.build(
            rules: [rule(.service, "telegram")],
            services: [svc],
            resolved: ["t.me": ["1.1.1.1"], "core.telegram.org": ["2.2.2.2"]]
        )
        XCTAssertEqual(out.count, 1)
        let d = out[0].dests
        XCTAssertEqual(d.count, 3)
        XCTAssertTrue(d.contains { $0.value == "1.1.1.1" && !$0.isNetwork })
        XCTAssertTrue(d.contains { $0.value == "2.2.2.2" && !$0.isNetwork })
        XCTAssertTrue(d.contains { $0.value == "91.108.4.0/22" && $0.isNetwork })
    }

    func testUnknownServiceIdYieldsNoDests() {
        let out = RuleDestinationBuilder.build(rules: [rule(.service, "nope")], services: [], resolved: [:])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].dests.isEmpty)
    }

    // MARK: - suffix / process are not kernel-routable

    func testSuffixAndProcessYieldNoDestsEvenWhenHostIsInMap() {
        let out = RuleDestinationBuilder.build(
            rules: [rule(.suffix, "example.com", order: 0), rule(.process, "Mail", order: 1)],
            services: [],
            resolved: ["example.com": ["1.1.1.1"]]
        )
        XCTAssertTrue(out[0].dests.isEmpty, "suffix needs a flow-intercept engine, not a route")
        XCTAssertTrue(out[1].dests.isEmpty, "process needs NE, not a route")
    }

    // MARK: - de-dup

    func testPerRuleDeduplication() {
        // Two service domains share an IP, and a range is listed twice.
        let svc = RouteManager.ServiceEntry(id: "s", name: "S", enabled: true,
                                            domains: ["a.com", "b.com"], ipRanges: ["10.0.0.0/8", "10.0.0.0/8"])
        let out = RuleDestinationBuilder.build(
            rules: [rule(.service, "s")],
            services: [svc],
            resolved: ["a.com": ["1.1.1.1", "1.1.1.1"], "b.com": ["1.1.1.1"]]
        )
        let d = out[0].dests
        XCTAssertEqual(d.filter { $0.value == "1.1.1.1" }.count, 1, "a shared/repeat IP appears once")
        XCTAssertEqual(d.filter { $0.value == "10.0.0.0/8" }.count, 1, "a repeated range appears once")
    }

    // MARK: - ordering

    func testReturnsEnabledRulesInAscendingOrderDroppingDisabled() {
        let out = RuleDestinationBuilder.build(
            rules: [
                rule(.ip, "3", order: 30),
                rule(.ip, "1", order: 10),
                rule(.ip, "off", order: 5, enabled: false),
                rule(.ip, "2", order: 20),
            ],
            services: [], resolved: [:]
        )
        XCTAssertEqual(out.map { $0.rule.pattern }, ["1", "2", "3"], "ascending order, disabled dropped (first-match)")
    }

    // MARK: - hostsToResolve

    func testHostsToResolveCollectsDomainAndServiceHostsDedupedSkippingNonDNSAndDisabled() {
        let svc = RouteManager.ServiceEntry(id: "s", name: "S", enabled: true, domains: ["shared.com", "svc.com"], ipRanges: [])
        let hosts = RuleDestinationBuilder.hostsToResolve(
            rules: [
                rule(.domain, "shared.com", order: 0),          // also a service domain → deduped
                rule(.service, "s", order: 1),
                rule(.ip, "9.9.9.9", order: 2),                 // contributes no host
                rule(.cidr, "10.0.0.0/8", order: 3),            // contributes no host
                rule(.suffix, "x.com", order: 4),               // not kernel-routable
                rule(.process, "Mail", order: 5),               // not kernel-routable
                rule(.domain, "off.com", order: 6, enabled: false), // disabled → skipped
            ],
            services: [svc]
        )
        XCTAssertEqual(hosts, ["shared.com", "svc.com"])
    }

    func testHostsToResolveEmptyForNoDNSRules() {
        let hosts = RuleDestinationBuilder.hostsToResolve(
            rules: [rule(.ip, "1.2.3.4", order: 0), rule(.cidr, "10.0.0.0/8", order: 1)],
            services: []
        )
        XCTAssertTrue(hosts.isEmpty)
    }
}
