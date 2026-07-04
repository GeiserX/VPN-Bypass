// RuleDestinationBuilderEdgeCaseTests.swift
// Additional edge-case coverage for RuleDestinationBuilder, layered on top of
// RuleDestinationBuilderTests.swift: a service with static IP ranges but no domains,
// a service whose domains have no entry in the resolved map, two independent rules
// referencing the SAME service (proving dedup is per-rule, not cross-rule), the
// resolved-map lookup being case-sensitive against a `.domain` rule's pattern, and
// hostsToResolve silently skipping a `.service` rule whose id isn't a known service.

import XCTest
@testable import VPNBypassCore

final class RuleDestinationBuilderEdgeCaseTests: XCTestCase {

    private func rule(_ mt: MatchType, _ pattern: String, order: Int = 0, enabled: Bool = true) -> Rule {
        Rule(matchType: mt, pattern: pattern, routeId: UUID(), enabled: enabled, order: order)
    }

    /// A service with static ipRanges but NO domains still emits its ranges alone.
    func testServiceWithOnlyIPRangesNoDomains() {
        let svc = RouteManager.ServiceEntry(id: "s", name: "S", enabled: true, domains: [], ipRanges: ["1.2.3.0/24"])
        let out = RuleDestinationBuilder.build(rules: [rule(.service, "s")], services: [svc], resolved: [:])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].dests.map(\.value), ["1.2.3.0/24"])
        XCTAssertTrue(out[0].dests[0].isNetwork)
    }

    /// A service whose domain has no entry in the resolved map contributes nothing for
    /// that domain (it is simply absent, not an empty-string placeholder).
    func testServiceWithDomainsButNoResolvedIPs() {
        let svc = RouteManager.ServiceEntry(id: "s", name: "S", enabled: true, domains: ["x.com"], ipRanges: [])
        let out = RuleDestinationBuilder.build(rules: [rule(.service, "s")], services: [svc], resolved: [:])
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].dests.isEmpty)
    }

    /// De-duplication happens WITHIN a rule's own dests, not ACROSS rules: two separate
    /// rules referencing the same service each independently get the full dests list.
    func testTwoRulesForSameServiceEachGetFullDestsIndependently() {
        let svc = RouteManager.ServiceEntry(id: "s", name: "S", enabled: true, domains: ["a.com"], ipRanges: [])
        let out = RuleDestinationBuilder.build(
            rules: [rule(.service, "s", order: 0), rule(.service, "s", order: 1)],
            services: [svc],
            resolved: ["a.com": ["1.1.1.1"]]
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].dests.map(\.value), ["1.1.1.1"])
        XCTAssertEqual(out[1].dests.map(\.value), ["1.1.1.1"], "the second rule gets its own full dests, not an empty/deduped remainder")
    }

    /// The resolved-map lookup for a `.domain` rule is an exact (case-SENSITIVE) key
    /// match — a rule pattern that differs only in case from the resolved map's key
    /// misses entirely.
    func testDomainRuleLookupIsCaseSensitiveAgainstResolvedMap() {
        let out = RuleDestinationBuilder.build(
            rules: [rule(.domain, "X.com")],
            services: [],
            resolved: ["x.com": ["1.1.1.1"]]
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].dests.isEmpty, "differing case vs. the resolved map's key must not match")
    }

    /// hostsToResolve silently contributes NO hosts for a `.service` rule whose pattern
    /// isn't a known service id (the lookup just misses; it never crashes/throws).
    func testHostsToResolveSkipsUnknownServiceId() {
        let hosts = RuleDestinationBuilder.hostsToResolve(rules: [rule(.service, "nope")], services: [])
        XCTAssertTrue(hosts.isEmpty)
    }
}
