// GeoRound3GapTests.swift
// Edges of round 3's fixes that its own tests left open: a carved address at the start or end of the
// Block range, a Country rule on a route type this build does not know, a narrower wildcard under an
// excluded one, and the id of the Block route the Rules page makes.

import XCTest
@testable import VPNBypassCore

final class BlockRangeCarveEdgeTests: XCTestCase {

    /// An earlier rule's address at the first or last address of a later Block range keeps its route.
    func testAnAddressAtEitherEndOfTheRangeIsCutOut() {
        let vpn = Route(name: "VPN", egress: .vpnDefault)
        let block = Route(name: Route.blockName, egress: .block)
        for host in ["203.0.113.0", "203.0.113.255"] {
            let first = Rule(matchType: .ip, pattern: host, routeId: vpn.id, order: 0)
            let range = Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: block.id, order: 1)
            let blocks = RouteCompiler.compileAll(
                resolvedRules: [(first, [(host, false)]), (range, [("203.0.113.0/24", true)])],
                routes: [vpn, block], localGateway: "192.0.2.1", ifaceGatewayForRoute: { _ in nil }).blocks
            let covered = blocks.contains { RuleResolver.ipv4(host, inCIDR: $0.destination.contains("/") ? $0.destination : $0.destination + "/32") }
            XCTAssertFalse(covered, "\(host) is blocked although an earlier rule sends it to the VPN")
            XCTAssertEqual(blocks.count, 8, "the rest of the /24 is blocked in the fewest pieces")
        }
    }
}

final class GeoCountryTotalUnknownRouteTests: XCTestCase {

    /// A Country rule on a route type this build does not know routes nothing, so it counts nothing.
    func testACountryOnAnUnknownRouteTypeCountsNothing() {
        let direct = Route(name: "Direct", egress: .direct)
        let newer = Route(name: "Newer", egress: .unsupported)
        let rules = [Rule(matchType: .geoip, pattern: "aa", routeId: newer.id, order: 0),
                     Rule(matchType: .geoip, pattern: "bb", routeId: direct.id, order: 1)]
        let picked = GeoIPBudget.select(rules: rules, routes: [direct, newer], counts: ["aa": 60, "bb": 60], limit: 100)
        XCTAssertEqual(picked.accepted, ["bb"])
        XCTAssertTrue(picked.refused.isEmpty, "a rule on an unknown route took part of the total")
    }
}

final class NarrowerExcludedWildcardTests: XCTestCase {

    /// A claimed wildcard under a broader claimed one excludes nothing more, so it is not counted.
    func testAWildcardUnderAnExcludedWildcardCountsNothing() {
        let direct = Route(name: "Direct", egress: .direct)
        let block = Route(name: Route.blockName, egress: .block)
        let narrow = Rule(matchType: .suffix, pattern: "b.a.example.com", routeId: direct.id, order: 0)
        let broad = Rule(matchType: .suffix, pattern: "a.example.com", routeId: direct.id, order: 1)
        let names = (0..<63).map { Rule(matchType: .domain, pattern: "n\($0).example.com", routeId: direct.id, order: $0 + 2) }
        let later = Rule(matchType: .suffix, pattern: "example.com", routeId: block.id, order: 65)
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [direct, block]
        c.defaultRouteId = direct.id
        c.rules = [narrow, broad] + names + [later]
        let selection = WildcardPlanner.selection(c)
        let item = selection.items.first { $0.suffix == "example.com" }
        XCTAssertNotNil(item, "left out for 65 exclusions although 64 cover the same names")
        XCTAssertNil(selection.refused[later.id])
        XCTAssertFalse(item?.excluded.contains("*.b.a.example.com") ?? true)
        XCTAssertTrue(item?.excluded.contains("*.a.example.com") ?? false)
    }
}

@MainActor
final class RulesPageBlockRouteIdTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: RouteManager.Config!

    override func setUp() async throws { saved = rm.config }

    override func tearDown() async throws {
        await rm.cancelConfigFollowUps()
        rm.config = saved
        rm.droppedBlockRoutes = []
    }

    /// The route the Rules page makes carries the fixed id, so it is the one taken out when unused.
    func testTheRouteTheRulesPageMakesGoesWhenUnused() {
        let direct = Route(name: "Direct", egress: .direct)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.routes = [direct]
        cfg.defaultRouteId = direct.id
        rm.config = cfg
        let made = rm.ensureBlockRoute()
        XCTAssertEqual(made.id, Route.rulesPageBlockId)
        XCTAssertTrue(rm.removeUnusedBlockRoutes(), "the route the Rules page made outlived its last rule")
        XCTAssertFalse(rm.config.routes.contains { $0.egress == .block })
    }
    /// A route the user moved off Block keeps the fixed id. The next Block route must not share
    /// it, and the cleanup must not take the user's route with it.
    func testARouteTheUserMovedOffBlockKeepsItsIdAlone() {
        let direct = Route(name: "Direct", egress: .direct)
        let retyped = Route(id: Route.rulesPageBlockId, name: "Mine", egress: .direct)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.routes = [direct, retyped]
        cfg.defaultRouteId = direct.id
        rm.config = cfg
        let made = rm.ensureBlockRoute()
        XCTAssertEqual(made.egress, .block)
        XCTAssertNotEqual(made.id, Route.rulesPageBlockId, "two routes share one id")
        XCTAssertEqual(Set(rm.config.routes.map(\.id)).count, rm.config.routes.count, "two routes share one id")
        rm.removeUnusedBlockRoutes()
        XCTAssertTrue(rm.config.routes.contains { $0.name == "Mine" }, "the cleanup took the user's route")
    }

    /// Two routes with the fixed id, as a config saved before this was fixed can hold: the cleanup
    /// takes the Block one only.
    func testTheCleanupTakesOnlyTheBlockRouteOfTwoWithOneId() {
        let direct = Route(name: "Direct", egress: .direct)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.schemaVersion = 2
        cfg.routes = [direct,
                      Route(id: Route.rulesPageBlockId, name: "Mine", egress: .direct),
                      Route(id: Route.rulesPageBlockId, name: Route.blockName, egress: .block)]
        cfg.defaultRouteId = direct.id
        rm.config = cfg
        XCTAssertTrue(rm.removeUnusedBlockRoutes())
        XCTAssertEqual(rm.config.routes.map(\.name), ["Direct", "Mine"])
    }
}
