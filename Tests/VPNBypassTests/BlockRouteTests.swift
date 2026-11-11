// BlockRouteTests.swift
// The Block route (a blackhole, as in OpenWrt Passwall2): the spec the helper reads, the forwarder's
// answer, the planner, the compiler, the route editor's wording, and `vpnb route.add type=block`.
// Names are reserved example domains; nothing here touches the network or the routing table.

import XCTest
@testable import VPNBypassCore

final class BlockWildcardTests: XCTestCase {

    private func labels(_ name: String) -> [[UInt8]] { name.split(separator: ".").map { Array($0.utf8) } }

    private func query(_ name: String, type: UInt16 = DNSWire.typeA) -> [UInt8] {
        DNSWire.encode(DNSWire.Message(id: 7, flags: 0x0100, questions: [.init(labels: labels(name), type: type, qclass: 1)],
                                       answers: [], authority: [], additional: []))!
    }

    private let blackhole = WildcardSpec(suffix: "ads.example.com", gateway: "", upstream: [], interface: "", block: true)

    // MARK: - The spec

    func testABareBlackholeCrossesToTheHelperWithoutAGatewayOrUpstream() throws {
        XCTAssertEqual(blackhole.dictionary, ["suffix": "ads.example.com", "block": "1"])
        let back = try XCTUnwrap(WildcardSpec(dictionary: blackhole.dictionary))
        XCTAssertTrue(back.block)
        XCTAssertEqual(back, blackhole)
    }

    func testABlackholeThatCarriesAnUpstreamCarriesAllOfIt() throws {
        let spec = WildcardSpec(suffix: "ads.example.com", gateway: "192.168.10.1", upstream: ["192.168.10.1"], interface: "en0",
                                excluded: ["ok.ads.example.com"], block: true)
        XCTAssertEqual(try XCTUnwrap(WildcardSpec(dictionary: spec.dictionary)), spec)
        var partial = spec.dictionary
        partial["interface"] = nil
        XCTAssertNil(WildcardSpec(dictionary: partial), "a gateway with no interface is not a spec")
    }

    /// The reason a 2.9.0 helper serves the other wildcards and leaves a blackhole alone: without
    /// a gateway an ordinary spec does not parse, so it is dropped, never read as a route to learn.
    func testASpecWithoutAGatewayIsRefusedUnlessItIsABlackhole() {
        XCTAssertNil(WildcardSpec(dictionary: ["suffix": "ads.example.com"]))
        XCTAssertNil(WildcardSpec(dictionary: ["suffix": "ads.example.com", "upstream": "1.1.1.1"]))
        XCTAssertNotNil(WildcardSpec(dictionary: ["suffix": "ads.example.com", "block": "1"]))
        XCTAssertNil(WildcardSpec(dictionary: ["suffix": "com", "block": "1"]), "a top-level domain is never a suffix")
        XCTAssertNil(WildcardSpec(dictionary: ["suffix": "../etc", "block": "1"]))
    }

    func testAnOrdinarySpecIsNotABlackhole() throws {
        let plain = WildcardSpec(suffix: "example.com", gateway: "192.168.10.1", upstream: ["1.1.1.1"], interface: "en0")
        XCTAssertFalse(plain.block)
        XCTAssertNil(plain.dictionary["block"])
        XCTAssertFalse(try XCTUnwrap(WildcardSpec(dictionary: plain.dictionary)).block)
    }

    // MARK: - The answer

    private func answer(_ name: String, type: UInt16 = DNSWire.typeA, specs: [WildcardSpec]? = nil,
                        forwarded: inout Int, upstream: [UInt8]? = nil) -> DNSWire.Message? {
        var count = 0
        let out = WildcardLookup.reply(
            to: query(name, type: type), overTCP: false, specs: specs ?? [blackhole], guard: WildcardSafetyGuard(), ttlCap: 300,
            forward: { _, _ in count += 1; return upstream },
            admit: { ips, _ in ips },
            install: { ips, _ in WildcardLookup.Install(installed: ips) })
        forwarded += count
        return out.flatMap(DNSWire.parse)
    }

    func testABlockedNameGetsNoAnswerWhateverIsAsked() {
        var forwarded = 0
        for type in [DNSWire.typeA, DNSWire.typeAAAA, DNSWire.typeHTTPS] {
            let reply = answer("tracker.ads.example.com", type: type, forwarded: &forwarded)
            XCTAssertEqual(reply.map { $0.flags & 0xF }, DNSWire.rcodeNXDomain, "type \(type)")
            XCTAssertEqual(reply?.answers.count, 0)
        }
        XCTAssertEqual(forwarded, 0, "no query for a blocked name leaves the Mac")
    }

    func testTheNameItselfIsBlockedAsWellAsWhatIsUnderIt() {
        var forwarded = 0
        XCTAssertEqual(answer("ads.example.com", forwarded: &forwarded).map { $0.flags & 0xF }, DNSWire.rcodeNXDomain)
    }

    func testANameAnEarlierRuleClaimsIsAnsweredByTheUpstreamNotBlocked() throws {
        let spec = WildcardSpec(suffix: "ads.example.com", gateway: "192.168.10.1", upstream: ["192.168.10.1"], interface: "en0",
                                excluded: ["ok.ads.example.com"], block: true)
        let upstream = DNSWire.encode(DNSWire.Message(
            id: 7, flags: 0x8180, questions: [.init(labels: labels("ok.ads.example.com"), type: DNSWire.typeA, qclass: 1)],
            answers: [.init(labels: labels("ok.ads.example.com"), type: DNSWire.typeA, rclass: 1, ttl: 60, data: [203, 0, 113, 9])],
            authority: [], additional: []))!
        var forwarded = 0
        let reply = try XCTUnwrap(answer("ok.ads.example.com", specs: [spec], forwarded: &forwarded, upstream: upstream))
        XCTAssertEqual(forwarded, 1)
        XCTAssertEqual(DNSWire.addresses(in: reply), ["203.0.113.9"], "first match: an allow rule above the block keeps its name")
        XCTAssertEqual(answer("other.ads.example.com", specs: [spec], forwarded: &forwarded, upstream: upstream).map { $0.flags & 0xF },
                       DNSWire.rcodeNXDomain)
    }

    func testAnExcludedNameOfABareBlackholeFailsInsteadOfBeingBlocked() {
        let spec = WildcardSpec(suffix: "ads.example.com", gateway: "", upstream: [], interface: "",
                                excluded: ["ok.ads.example.com"], block: true)
        var forwarded = 0
        let reply = answer("ok.ads.example.com", specs: [spec], forwarded: &forwarded, upstream: nil)
        XCTAssertEqual(reply.map { $0.flags & 0xF }, DNSWire.rcodeServFail, "the user said this name is not blocked")
    }

    func testABlackholeLeavesTheOtherWildcardsAlone() throws {
        let plain = WildcardSpec(suffix: "example.com", gateway: "192.168.10.1", upstream: ["1.1.1.1"], interface: "en0")
        let upstream = DNSWire.encode(DNSWire.Message(
            id: 7, flags: 0x8180, questions: [.init(labels: labels("www.example.com"), type: DNSWire.typeA, qclass: 1)],
            answers: [.init(labels: labels("www.example.com"), type: DNSWire.typeA, rclass: 1, ttl: 60, data: [203, 0, 113, 5])],
            authority: [], additional: []))!
        var forwarded = 0
        let reply = try XCTUnwrap(answer("www.example.com", specs: [plain, blackhole], forwarded: &forwarded, upstream: upstream))
        XCTAssertEqual(DNSWire.addresses(in: reply), ["203.0.113.5"])
        XCTAssertEqual(forwarded, 1)
        XCTAssertEqual(answer("a.ads.example.com", specs: [plain, blackhole], forwarded: &forwarded).map { $0.flags & 0xF },
                       DNSWire.rcodeNXDomain, "the most specific suffix decides: ads.example.com is under example.com")
    }

    func testAnotherResolversNamesAreNotBlocked() {
        let tailnet = WildcardDelegation(domain: "tail.ads.example.com", servers: ["100.100.100.100"])
        let spec = WildcardSpec(suffix: "ads.example.com", gateway: "", upstream: [], interface: "", delegated: [tailnet], block: true)
        var delegatedTo = 0
        let out = WildcardLookup.reply(
            to: query("box.tail.ads.example.com"), overTCP: false, specs: [spec], guard: WildcardSafetyGuard(), ttlCap: 300,
            forward: { _, _ in nil }, delegate: { _, _ in delegatedTo += 1; return nil },
            admit: { ips, _ in ips }, install: { ips, _ in WildcardLookup.Install(installed: ips) })
        XCTAssertEqual(delegatedTo, 1, "a name another resolver serves goes to it, as for any wildcard")
        XCTAssertEqual(out.flatMap(DNSWire.parse).map { $0.flags & 0xF }, DNSWire.rcodeServFail)
    }
}

final class BlockRoutePlanTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)
    private let block = Route(name: Route.blockName, egress: .block)
    private let proxy = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "p", proxyPort: 1080)

    private let env = WildcardPlanner.Environment(
        localGateway: "192.168.10.1", physicalInterface: "en0", physicalDNS: ["192.168.10.1"],
        vpnGateway: "10.20.0.1", vpnInterface: "utun4", vpnDNS: ["10.20.0.53"])

    private func custom(_ rules: [Rule]) -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        c.routes = [direct, block, proxy]
        c.rules = rules
        return c
    }

    private func rule(_ type: MatchType, _ pattern: String, _ route: Route, order: Int) -> Rule {
        Rule(matchType: type, pattern: pattern, routeId: route.id, order: order)
    }

    func testARuleOnTheBlockRouteBecomesABlackholeSpec() {
        let plan = WildcardPlanner.plan(custom([rule(.suffix, "ads.example.com", block, order: 0)]), env: env)
        XCTAssertEqual(plan.specs.count, 1)
        XCTAssertEqual(plan.specs.first?.suffix, "ads.example.com")
        XCTAssertEqual(plan.specs.first?.block, true)
        XCTAssertEqual(plan.specs.first?.upstream, ["192.168.10.1"], "the physical resolver is there for the names an earlier rule claims")
    }

    func testAnExactNameAndAServiceNameAreBlockedWithWhatIsUnderThem() {
        var c = custom([rule(.domain, "track.example.net", block, order: 0), rule(.service, "svc", block, order: 1)])
        c.services = [ServiceEntry(id: "svc", name: "Svc", enabled: true, domains: ["*.beacon.example.org", "pixel.example.org"], ipRanges: [])]
        let specs = WildcardPlanner.plan(c, env: env).specs
        XCTAssertEqual(Set(specs.map(\.suffix)), ["track.example.net", "beacon.example.org", "pixel.example.org"])
        XCTAssertTrue(specs.allSatisfy(\.block))
    }

    func testAGeositeListOnTheBlockRouteBlocksItsSuffixesAndNames() {
        let data = Dat.file([Dat.site("ADS", [Dat.domain(2, "ads.example.com"), Dat.domain(3, "pixel.example.net"),
                                              Dat.domain(1, "^t[0-9]\\.example\\.org$")])])
        let lists = GeoSiteDat.expansions(for: ["ads"], in: data)
        let specs = WildcardPlanner.configured(custom([rule(.geosite, "ads", block, order: 0)]), geosite: lists)
        XCTAssertEqual(specs.map(\.suffix), ["ads.example.com", "pixel.example.net"], "the regex is left out")
        XCTAssertTrue(specs.allSatisfy { $0.via == .block })
    }

    func testFirstMatchHoldsAnAllowRuleAboveABlockKeepsItsName() {
        let allow = rule(.domain, "ok.ads.example.com", direct, order: 0)
        let plan = WildcardPlanner.plan(custom([allow, rule(.suffix, "ads.example.com", block, order: 1)]), env: env)
        let spec = plan.specs.first { $0.suffix == "ads.example.com" }
        XCTAssertEqual(spec?.excluded, ["ok.ads.example.com"])
        XCTAssertEqual(spec?.block, true)
    }

    func testABlockAboveARuleWins() {
        let specs = WildcardPlanner.configured(custom([rule(.suffix, "ads.example.com", block, order: 0),
                                                       rule(.suffix, "ads.example.com", direct, order: 1)]))
        XCTAssertEqual(specs.map(\.suffix), ["ads.example.com"])
        XCTAssertEqual(specs.first?.via, .block, "the later Direct rule for the same suffix is shadowed")
    }

    func testWithNoPhysicalNetworkTheBlackholeIsStillSent() {
        var offline = env
        offline.localGateway = nil
        offline.physicalInterface = nil
        offline.physicalDNS = []
        let plan = WildcardPlanner.plan(custom([rule(.suffix, "ads.example.com", block, order: 0)]), env: offline)
        XCTAssertEqual(plan.specs.first?.dictionary, ["suffix": "ads.example.com", "block": "1"], "blocking needs no network")
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testAnOlderHelperGetsNoBlackholeAndTheReasonIsRecorded() {
        var old = env
        old.blockSupported = false
        let c = custom([rule(.suffix, "ads.example.com", block, order: 0), rule(.suffix, "video.example.com", direct, order: 1)])
        let plan = WildcardPlanner.plan(c, env: old)
        XCTAssertEqual(plan.specs.map(\.suffix), ["video.example.com"], "the other wildcards are served")
        XCTAssertEqual(plan.skipped["ads.example.com"], "the helper needs an update to block names")
    }

    func testADisabledBlockRouteBlocksNothing() {
        var c = custom([rule(.suffix, "ads.example.com", block, order: 0)])
        c.routes[1].enabled = false
        XCTAssertTrue(WildcardPlanner.plan(c, env: env).specs.isEmpty)
    }

    func testAProxyRouteStillMakesNoWildcard() {
        XCTAssertTrue(WildcardPlanner.plan(custom([rule(.suffix, "ads.example.com", proxy, order: 0)]), env: env).specs.isEmpty)
    }

    // MARK: - Addresses

    /// No kernel route blocks an address yet; a rule that names one does not pretend to, and
    /// does not stop a later rule from deciding the address.
    func testBlockingAnAddressIsNotYetDoneAndClaimsNothing() {
        let resolved: [(rule: Rule, dests: [(value: String, isNetwork: Bool)])] = [
            (rule: rule(.cidr, "203.0.113.0/24", block, order: 0), dests: [("203.0.113.0/24", true)]),
            (rule: rule(.cidr, "203.0.113.0/24", direct, order: 1), dests: [("203.0.113.0/24", true)]),
        ]
        let out = RouteCompiler.compile(resolvedRules: resolved, routes: [direct, block], localGateway: "192.168.10.1",
                                        ifaceGatewayForRoute: { _ in nil })
        XCTAssertEqual(out.map(\.destination), ["203.0.113.0/24"])
        XCTAssertEqual(out.first?.gateway, "192.168.10.1")
        XCTAssertTrue(RouteCompiler.compile(resolvedRules: [resolved[0]], routes: [block], localGateway: "192.168.10.1",
                                            ifaceGatewayForRoute: { _ in nil }).isEmpty)
    }

    // MARK: - Route and rule

    func testTheBlockRouteHasANameAChipAndAGlyph() {
        XCTAssertEqual(RouteChip.systemImage(for: .block), "nosign")
        XCTAssertEqual(block.friendlyName(vpnName: nil), "Block")
        XCTAssertEqual(Route(name: "Ads", egress: .block).friendlyName(vpnName: nil), "Ads", "a name the user chose stays")
        XCTAssertEqual(RouteRow.typeLabel(.block, in: .main), "Block")
    }

    func testVpnbMakesABlockRouteWithNoHost() throws {
        let (updated, response) = CommandRouter.apply(ControlRequest(cmd: "route.add", args: ["name": "Block", "type": "block"]),
                                                      to: RouteManager.Config())
        XCTAssertTrue(response.ok)
        let made = try XCTUnwrap(updated.routes.last)
        XCTAssertEqual(made.egress, .block)
        XCTAssertNil(made.proxyHost)
        let (_, refused) = CommandRouter.apply(ControlRequest(cmd: "route.add", args: ["name": "x", "type": "blackhole"]),
                                               to: RouteManager.Config())
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.message, "type must be one of: http, socks5, tailscale, vpn, block")
    }

    func testPerAppRoutingTreatsABlockRouteAsAnotherRoute() {
        XCTAssertEqual(flowRouteKind(block), .proxy)
        XCTAssertEqual(flowRouteKind(Route(name: "?", egress: .unsupported)), .proxy)
    }
}
