// GeoReviewTests.swift
// The maintainer's review of the GeoIP, GeoSite and Block work: what a downloaded list may route, the
// checksum and time limit of a download, the cost of large lists and many wildcards, the root call
// that was taken out, and what a config that never uses the new types writes. Every address and name
// is a documentation or example one.

import XCTest
@testable import VPNBypassCore

final class GeoReviewTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)

    private func custom(_ rules: [Rule], routes: [Route]? = nil) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = routes ?? [direct, block]
        c.defaultRouteId = direct.id
        c.rules = rules
        return c
    }

    // MARK: - The hosts-file blocklist is gone

    /// The root helper takes no call that writes a list of names into /etc/hosts.
    func testTheHelperHasNoCallThatWritesBlockedNamesIntoTheHostsFile() throws {
        let proto = try XCTUnwrap(NSProtocolFromString("HelperProtocol"))
        let selector = NSSelectorFromString("updateBlockedHostsWithNames:withReply:")
        let method = protocol_getMethodDescription(proto, selector, true, true)
        XCTAssertNil(method.name, "updateBlockedHosts is still part of the helper's protocol")
        // The control: a call the helper does have is found the same way.
        let known = protocol_getMethodDescription(proto, NSSelectorFromString("flushDNSCacheWithReply:"), true, true)
        XCTAssertNotNil(known.name)
    }

    // MARK: - What a downloaded country list may route

    func testADownloadedListCannotRouteHugeOrSpecialUseRanges() {
        let hostile = ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2", "6.0.0.0/7", "10.0.0.0/8",
                       "127.0.0.0/8", "172.16.5.0/24", "100.64.0.0/10", "224.0.0.0/4", "203.0.113.0/24", "198.51.100.0/24"]
        let rules = [Rule(matchType: .geoip, pattern: "xx", routeId: direct.id, order: 0)]
        let built = RuleDestinationBuilder.build(rules: rules, services: [], resolved: [:], geoip: ["xx": hostile])
        XCTAssertEqual(built.first?.dests.map(\.value), ["203.0.113.0/24", "198.51.100.0/24"])

        // The same list on Block blocks only those two, not the Mac's own networks.
        let blockRules = [Rule(matchType: .geoip, pattern: "xx", routeId: block.id, order: 0)]
        let resolved = RuleDestinationBuilder.build(rules: blockRules, services: [], resolved: [:], geoip: ["xx": hostile],
                                                    routes: [direct, block])
        let compiled = RouteCompiler.compileAll(resolvedRules: resolved, routes: [direct, block],
                                                localGateway: "192.0.2.1", ifaceGatewayForRoute: { _ in nil })
        XCTAssertEqual(compiled.blocks.map(\.destination), ["203.0.113.0/24", "198.51.100.0/24"])
        XCTAssertTrue(compiled.routes.isEmpty)
    }

    // MARK: - Planning many wildcards

    /// `scutil --dns` lists every resolver file of ours: the plan must not walk all of them for each
    /// wildcard. With 4,000 wildcards and their 4,000 files this took 21 seconds in a debug build, now about 3.
    func testManyWildcardsPlanInLinearTimeWithTheirResolverFilesListed() {
        let count = 4_000
        let suffixes = (0..<count).map { "d\($0).example.com" }
        let rules = suffixes.enumerated().map { Rule(matchType: .suffix, pattern: "*.\($0.element)", routeId: direct.id, order: $0.offset) }
        var resolvers = suffixes.map {
            ScutilDNS.Resolver(domain: $0, nameservers: ["127.0.0.1"], port: Int(WildcardResolverFile.port),
                               order: WildcardResolverFile.searchOrder)
        }
        resolvers += (0..<20).map { ScutilDNS.Resolver(domain: "corp\($0).example", nameservers: ["10.1.0.\($0 + 10)"], order: 100 + $0) }
        resolvers.append(ScutilDNS.Resolver(domain: "inner.d7.example.com", nameservers: ["10.2.0.99"], order: 1))
        let env = WildcardPlanner.Environment(localGateway: "192.168.1.1", physicalInterface: "en0", physicalDNS: ["192.168.1.53"],
                                              vpnGateway: nil, vpnInterface: nil, vpnDNS: [], resolvers: resolvers)
        let started = CFAbsoluteTimeGetCurrent()
        let planned = WildcardPlanner.plan(custom(rules), env: env)
        let warnings = WildcardEngine.shadowWarnings(specs: planned.specs, served: Set(suffixes), resolvers: resolvers, warned: [:])
        let seconds = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(planned.specs.count, count)
        XCTAssertEqual(planned.specs.first { $0.suffix == "d7.example.com" }?.delegated.map(\.domain), ["inner.d7.example.com"])
        XCTAssertEqual(warnings.log.map(\.suffix), ["d7.example.com"])
        XCTAssertLessThan(seconds, 12, "planning \(count) wildcards with their resolver files listed took \(seconds) s")
    }

    /// The shadow check gives the same answer as before for each case it knows.
    func testTheShadowIndexAnswersAsTheScanDid() {
        let resolvers = [
            ScutilDNS.Resolver(domain: "a.example.com", nameservers: ["192.0.2.1"], order: 200),
            ScutilDNS.Resolver(domain: "b.example.com", nameservers: ["192.0.2.2"], order: 1),
            ScutilDNS.Resolver(domain: "b.example.com", nameservers: ["127.0.0.1"], port: Int(WildcardResolverFile.port), order: 0),
            ScutilDNS.Resolver(domain: "c.example.com", nameservers: ["192.0.2.3"], scoped: true),
            ScutilDNS.Resolver(domain: "example.com", nameservers: ["192.0.2.4"]),
        ]
        XCTAssertEqual(ScutilDNS.shadowing("example.com", in: resolvers), ["a.example.com"])
        XCTAssertEqual(ScutilDNS.shadowing("example.com", in: resolvers, served: ["a.example.com"]), [],
                       "our own file for the same domain comes first")
    }

    /// Two large lists cannot together ask for more resolver files than one may.
    func testAllListsTogetherStayUnderOneTotal() {
        let first = GeoSiteExpansion(suffixes: (0..<6_000).map { "a\($0).example.net" })
        let second = GeoSiteExpansion(suffixes: (0..<6_000).map { "b\($0).example.org" })
        let small = GeoSiteExpansion(suffixes: ["c.example.com"])
        let config = custom([Rule(matchType: .geosite, pattern: "first", routeId: direct.id, order: 0),
                             Rule(matchType: .geosite, pattern: "second", routeId: direct.id, order: 1),
                             Rule(matchType: .geosite, pattern: "small", routeId: direct.id, order: 2)])
        let configured = WildcardPlanner.configured(config, geosite: ["first": first, "second": second, "small": small])
        XCTAssertEqual(configured.count, 6_001, "the second list is left out whole; the small one still fits")
    }

    // MARK: - Collapsing a large list

    func testALargeListCollapsesQuicklyAndTheSameAsBefore() {
        // 150,000 suffixes in 3,000 families, each with a parent, as an ad list is shaped.
        var entries: [[UInt8]] = []
        for family in 0..<3_000 {
            entries.append(Dat.domain(2, "f\(family).example.net"))
            for child in 0..<49 { entries.append(Dat.domain(2, "c\(child).f\(family).example.net")) }
        }
        entries.append(Dat.domain(3, "x.f1.example.net"))
        entries.append(Dat.domain(3, "lone.example.org"))
        let data = Dat.file([Dat.site("ADS", entries)])
        let started = CFAbsoluteTimeGetCurrent()
        let list = GeoSiteDat.expansions(for: ["ads"], in: data)["ads"]
        let seconds = CFAbsoluteTimeGetCurrent() - started
        XCTAssertEqual(list?.suffixes.count, 3_000)
        XCTAssertEqual(list?.suffixes.first, "f0.example.net")
        XCTAssertEqual(list?.names, ["lone.example.org"])
        XCTAssertLessThan(seconds, 6, "collapsing 150,000 entries took \(seconds) s")
    }

    // MARK: - The command line matches the Rules page

    func testTheCommandLineRefusesABlockDefaultAndTheUnsupportedPlaceholder() {
        let config = custom([])
        let setDefault = CommandRouter.apply(ControlRequest(cmd: "default", args: ["routeId": block.id.uuidString]), to: config)
        XCTAssertFalse(setDefault.response.ok)
        XCTAssertEqual(setDefault.config.defaultRouteId, direct.id)
        let toDirect = CommandRouter.apply(ControlRequest(cmd: "default", args: ["routeId": direct.id.uuidString]), to: config)
        XCTAssertTrue(toDirect.response.ok, "the control: another route is still taken")

        let unsupported = CommandRouter.apply(ControlRequest(cmd: "rule.add", args: [
            "match": "unsupported", "pattern": "x", "routeId": direct.id.uuidString]), to: config)
        XCTAssertFalse(unsupported.response.ok)
        XCTAssertTrue(unsupported.config.rules.isEmpty)
    }

    // MARK: - What a config that never uses the lists writes

    func testAConfigThatNeverTouchesTheSyncScheduleDoesNotWriteIt() throws {
        let decoded = try JSONDecoder().decode(RouteManager.Config.self, from: Data("{}".utf8))
        let written = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(written.contains("geoSync"), "an untouched config gains no key")
        var set = decoded
        set.geoSync = .daily
        let back = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(back.geoSync, .daily, "a schedule the user set is kept")
    }

    func testAWholeNumberPastInt64RoundTripsUnchanged() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("18446744073709551615".utf8))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), "18446744073709551615")
    }
}
