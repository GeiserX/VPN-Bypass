// SiteRouteTests.swift
// "Where does this site go?" (`vpnb why <host>`): which entry routes a host, in the order an
// installed route, a listed wildcard, the Custom rules by first match, a listed entry with no
// route, then nothing; and the verdict the path check gives it, control included.

import XCTest
@testable import VPNBypassCore

final class SiteRouteTests: XCTestCase {

    private let local = "192.168.1.1"

    private func snapshot(mode: RoutingMode = .bypass, list: [DomainEntry] = [], services: [ServiceEntry] = [],
                          rules: [Rule] = [], routes: [Route] = [], defaultRouteId: UUID? = nil,
                          active: [(String, String, String)] = [], vpn: String? = "utun4") -> SiteRoute.Snapshot {
        SiteRoute.Snapshot(mode: mode, custom: mode == .custom, list: list, services: services,
                           rules: rules, routes: routes, defaultRouteId: defaultRouteId,
                           activeRoutes: active.map { ($0.0, $0.1, $0.2) },
                           localGateway: local, vpnInterface: vpn)
    }

    // MARK: Bypass and VPN Only

    func testAnInstalledRouteNamesItsSource() {
        let s = snapshot(list: [DomainEntry(domain: "example.com")],
                         active: [("203.0.113.5", local, "example.com")])
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .route)
        XCTAssertEqual(found.entry, "example.com")
        XCTAssertEqual(found.routedDestination, "203.0.113.5")
        XCTAssertEqual(found.expected, .physical)
    }

    /// A name not on the list whose address another entry routes goes that way too.
    func testASharedAddressNamesTheEntryThatRoutesIt() {
        let s = snapshot(active: [("203.0.113.5", local, "other.example")])
        let found = SiteRoute.match(host: "cdn.example.net", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .route)
        XCTAssertEqual(found.entry, "other.example")
    }

    func testAServiceRangeIsAMatchUnderTheServiceName() {
        let service = ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: [], ipRanges: ["149.154.160.0/20"])
        let s = snapshot(services: [service], active: [("149.154.160.0/20", local, "Telegram")])
        let found = SiteRoute.match(host: "149.154.167.50", addresses: ["149.154.167.50"], in: s)
        XCTAssertEqual(found.match, .route)
        XCTAssertEqual(found.entry, "Telegram")
        XCTAssertEqual(found.routedDestination, "149.154.160.0/20")
    }

    func testAWildcardCoversANameWithNoRouteYet() {
        let s = snapshot(list: [DomainEntry(domain: "*.example.com"), DomainEntry(domain: "*.eu.example.com")])
        let found = SiteRoute.match(host: "a.eu.example.com", addresses: ["203.0.113.9"], in: s)
        XCTAssertEqual(found.match, .wildcard)
        XCTAssertEqual(found.entry, "*.eu.example.com", "the most specific wildcard, as macOS picks it")
        XCTAssertEqual(found.expected, .physical)
    }

    func testAListedNameWithoutARouteSaysSo() {
        let s = snapshot(list: [DomainEntry(domain: "example.com")])
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .listed)
        XCTAssertEqual(found.expected, .physical, "it should go around the VPN, and the check will show it does not")
    }

    func testADisabledEntryDoesNotMatch() {
        let s = snapshot(list: [DomainEntry(domain: "example.com", enabled: false)])
        XCTAssertEqual(SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s).match, .none)
    }

    func testAnUnlistedNameFollowsTheVPNInBypass() {
        let found = SiteRoute.match(host: "example.org", addresses: ["203.0.113.7"], in: snapshot())
        XCTAssertEqual(found.match, .none)
        XCTAssertEqual(found.expected, .tunnel("utun4"))
    }

    /// VPN Only's catch-alls are what an unlisted address takes, never a match.
    func testVPNOnlyCatchAllsAreNotAMatch() {
        let s = snapshot(mode: .vpnOnly, active: [("192.0.0.0/2", local, ClassicRouteCompiler.catchAllSource)])
        let found = SiteRoute.match(host: "example.org", addresses: ["203.0.113.7"], in: s)
        XCTAssertEqual(found.match, .none)
        XCTAssertEqual(found.expected, .physical)
    }

    func testVPNOnlyListedRangeExpectsTheTunnel() {
        let s = snapshot(mode: .vpnOnly, list: [DomainEntry(domain: "10.0.0.0/8", isCIDR: true)])
        let found = SiteRoute.match(host: "10.1.2.3", addresses: ["10.1.2.3"], in: s)
        XCTAssertEqual(found.match, .listed)
        XCTAssertEqual(found.expected, .tunnel("utun4"))
    }

    func testNoAddressesIsUnresolved() {
        XCTAssertEqual(SiteRoute.match(host: "nx.invalid", addresses: [], in: snapshot()).match, .unresolved)
    }

    /// With no VPN there is one way out: nothing listed or unlisted is expected in a tunnel.
    func testWithoutAVPNEverythingIsExpectedAroundIt() {
        let s = snapshot(mode: .vpnOnly, list: [DomainEntry(domain: "intranet.example.com")], vpn: nil)
        XCTAssertEqual(SiteRoute.match(host: "intranet.example.com", addresses: ["10.1.2.3"], in: s).expected, .physical)
        XCTAssertEqual(SiteRoute.match(host: "example.org", addresses: ["203.0.113.7"], in: snapshot(vpn: nil)).expected, .physical)
    }

    // MARK: Custom: first match

    private let direct = Route(name: "Direct", egress: .direct)
    private let corp = Route(name: "Corp VPN", egress: .vpnDefault)
    private let proxy = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "127.0.0.1", proxyPort: 1080)

    /// An address rule placed before a name rule wins, as the engine evaluates them.
    func testCustomFirstMatchCrossesNameAndAddressRules() {
        let rules = [Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: corp.id, order: 0),
                     Rule(matchType: .domain, pattern: "example.com", routeId: direct.id, order: 1)]
        let s = snapshot(mode: .custom, rules: rules, routes: [direct, corp], defaultRouteId: corp.id)
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .rule)
        XCTAssertEqual(found.rulePosition, 1)
        XCTAssertEqual(found.ruleMatchType, "cidr")
        XCTAssertEqual(found.routeName, "Corp VPN")
        XCTAssertEqual(found.expected, .tunnel("utun4"))
    }

    func testCustomSkipsDisabledRulesAndCountsPositionsAmongEnabled() {
        let rules = [Rule(matchType: .domain, pattern: "example.com", routeId: corp.id, enabled: false, order: 0),
                     Rule(matchType: .ip, pattern: "198.51.100.1", routeId: corp.id, order: 1),
                     Rule(matchType: .suffix, pattern: "example.com", routeId: direct.id, order: 2)]
        let s = snapshot(mode: .custom, rules: rules, routes: [direct, corp], defaultRouteId: corp.id)
        let found = SiteRoute.match(host: "www.example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .rule)
        XCTAssertEqual(found.rulePosition, 2)
        XCTAssertEqual(found.expected, .physical)
    }

    func testCustomServiceRuleMatchesTheServicesNames() {
        let service = ServiceEntry(id: "github", name: "GitHub", enabled: true, domains: ["*.github.com"], ipRanges: [])
        let rules = [Rule(matchType: .service, pattern: "github", routeId: direct.id, order: 0)]
        let s = snapshot(mode: .custom, services: [service], rules: rules, routes: [direct, corp], defaultRouteId: corp.id)
        XCTAssertEqual(SiteRoute.match(host: "api.github.com", addresses: ["203.0.113.5"], in: s).match, .rule)
    }

    /// A rule whose route is turned off is inert, as RouteCompiler skips it: the name falls
    /// through to the next rule.
    func testCustomRuleOnADisabledRouteFallsThrough() {
        let off = Route(name: "Off", egress: .direct, enabled: false)
        let rules = [Rule(matchType: .domain, pattern: "example.com", routeId: off.id, order: 0),
                     Rule(matchType: .suffix, pattern: "example.com", routeId: corp.id, order: 1)]
        let s = snapshot(mode: .custom, rules: rules, routes: [off, direct, corp], defaultRouteId: direct.id)
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .rule)
        XCTAssertEqual(found.rulePosition, 2)
        XCTAssertEqual(found.routeName, "Corp VPN")
    }

    /// A wildcard typed into a name rule covers the names under it, as WildcardRoutes reads it.
    func testCustomWildcardNameRuleCoversNamesUnderIt() {
        let rules = [Rule(matchType: .domain, pattern: "*.example.com", routeId: direct.id, order: 0)]
        let s = snapshot(mode: .custom, rules: rules, routes: [direct, corp], defaultRouteId: corp.id)
        XCTAssertEqual(SiteRoute.match(host: "api.example.com", addresses: ["203.0.113.5"], in: s).match, .rule)
    }

    /// Custom service rules read the service whether or not the Bypass list has it on, as
    /// RuleDestinationBuilder does, so the snapshot keeps every service there.
    @MainActor
    func testCustomSnapshotKeepsServicesTheBypassListHasOff() {
        let manager = RouteManager.shared
        let saved = manager.config
        defer { manager.config = saved }
        var config = saved
        config.schemaVersion = 2
        config.routingMode = .custom
        config.services = [ServiceEntry(id: "github", name: "GitHub", enabled: false, domains: ["github.com"], ipRanges: [])]
        manager.config = config
        XCTAssertEqual(manager.siteRouteSnapshot.services.map(\.id), ["github"])
        config.routingMode = .bypass
        manager.config = config
        XCTAssertTrue(manager.siteRouteSnapshot.services.isEmpty)
    }

    /// The engine installs routes for rules only, so a name no rule claims follows the system's
    /// own routing, the VPN, even with Everything else set to Direct: the check expects the
    /// tunnel, and the sentence says why the setting does not apply.
    func testCustomWithNoMatchFollowsTheSystemWhateverEverythingElseSays() {
        let s = snapshot(mode: .custom, routes: [direct, corp], defaultRouteId: direct.id)
        let found = SiteRoute.match(host: "example.org", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .defaultRoute)
        XCTAssertEqual(found.routeName, "Direct")
        XCTAssertEqual(found.expected, .tunnel("utun4"))
        XCTAssertTrue(found.defaultRouteNotApplied)
        let tunnel = PathCheck.Probe(address: "203.0.113.5", routeInterface: "utun4", answer: .connected)
        let answer = SiteRoute.answer(host: "example.org", mode: .custom, addresses: ["203.0.113.5"], found: found,
                                      probes: [tunnel], control: nil, vpnConnected: true)
        XCTAssertEqual(answer.verdict, .ok, "the traffic takes the VPN, which is right")
        XCTAssertTrue(answer.summary.contains("Everything else is set to Direct, but the app adds routes for rules only"), answer.summary)
        XCTAssertTrue(answer.canAdd, "Send Direct still sends it direct")
        // Everything else set to the VPN is what the system does anyway.
        let vpn = SiteRoute.match(host: "example.org", addresses: ["203.0.113.5"],
                                  in: snapshot(mode: .custom, routes: [direct, corp], defaultRouteId: corp.id))
        XCTAssertEqual(vpn.expected, .tunnel("utun4"))
        XCTAssertFalse(vpn.defaultRouteNotApplied)
        XCTAssertEqual(SiteRoute.whySentence(host: "example.org", mode: .custom, found: vpn),
                       "example.org matches no rule, so it takes the default route, Corp VPN.")
    }

    /// Everything else set to a pinned tunnel no rule uses: its pin is read too, so Site Check
    /// sees that the system sends the name to the primary VPN instead and says the setting is not
    /// applied.
    func testEverythingElseOnAPinnedTunnelIsComparedWithItsPin() {
        let pinned = Route(name: "WG", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun9"))
        var config = RouteManager.Config()
        config.schemaVersion = 2
        config.routingMode = .custom
        config.routes = [direct, pinned]
        XCTAssertTrue(RouteManager.pinnedRoutesToRead(config).isEmpty, "no rule and not Everything else")
        config.defaultRouteId = pinned.id
        XCTAssertEqual(RouteManager.pinnedRoutesToRead(config).map(\.id), [pinned.id])
        config.routingMode = .bypass
        XCTAssertTrue(RouteManager.pinnedRoutesToRead(config).isEmpty, "only Custom reads pins")

        var s = snapshot(mode: .custom, routes: [direct, pinned], defaultRouteId: pinned.id)
        s.pinnedInterfaces = [pinned.id: "utun7"]
        let found = SiteRoute.match(host: "example.org", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.expected, .tunnel("utun4"))
        XCTAssertTrue(found.defaultRouteNotApplied)
    }

    /// The kernel decides before the rules: an installed route is reported first.
    func testCustomInstalledRouteComesBeforeTheRules() {
        let rules = [Rule(matchType: .domain, pattern: "example.com", routeId: corp.id, order: 0)]
        let s = snapshot(mode: .custom, rules: rules, routes: [direct, corp],
                         active: [("203.0.113.5", local, "203.0.113.5/32")])
        XCTAssertEqual(SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s).match, .route)
    }

    func testAProxyRouteIsNotDecidedByTheRoutingTable() {
        let rules = [Rule(matchType: .domain, pattern: "example.com", routeId: proxy.id, order: 0)]
        let s = snapshot(mode: .custom, rules: rules, routes: [direct, proxy])
        let found = SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s)
        XCTAssertEqual(found.match, .rule)
        XCTAssertNil(found.expected)
    }

    /// A pinned route expects the tunnel its pin resolves to now, not the saved name, which goes
    /// stale when macOS renumbers the utun; a pin that is not up takes the system's default.
    func testAPinnedVPNRouteExpectsTheTunnelItResolvesTo() {
        let pinned = Route(name: "WG", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun9"))
        XCTAssertEqual(SiteRoute.way(for: pinned, vpnInterface: "utun4", pinned: [pinned.id: "utun7"]), .tunnel("utun7"))
        XCTAssertEqual(SiteRoute.way(for: pinned, vpnInterface: "utun4", pinned: [:]), .tunnel("utun4"))
        let rules = [Rule(matchType: .domain, pattern: "example.com", routeId: pinned.id, order: 0)]
        var s = snapshot(mode: .custom, rules: rules, routes: [pinned, direct])
        s.pinnedInterfaces = [pinned.id: "utun7"]
        XCTAssertEqual(SiteRoute.match(host: "example.com", addresses: ["203.0.113.5"], in: s).expected, .tunnel("utun7"))
    }

    /// In Custom the engine installs routes only for rules, so the control, which no rule
    /// claims, follows the VPN whatever the default route is set to.
    func testCustomControlFollowsTheVPNWhateverTheDefaultRoute() {
        var config = RouteManager.Config()
        config.schemaVersion = 2
        config.routingMode = .custom
        config.routes = [direct, corp]
        config.defaultRouteId = direct.id
        XCTAssertEqual(SiteRoute.unroutedWay(config: config, vpnInterface: "utun4"), .tunnel("utun4"))
        config.defaultRouteId = nil
        XCTAssertEqual(SiteRoute.unroutedWay(config: config, vpnInterface: "utun4"), .tunnel("utun4"))
        XCTAssertNil(SiteRoute.unroutedWay(config: config, vpnInterface: nil))
    }

    /// Loopback never enters a tunnel, so an unlisted loopback address expects no tunnel.
    func testUnlistedLoopbackExpectsNoTunnel() {
        XCTAssertEqual(SiteRoute.match(host: "localhost", addresses: ["127.0.0.1"], in: snapshot()).expected, .physical)
        XCTAssertEqual(SiteRoute.match(host: "localhost", addresses: ["127.0.0.1"],
                                       in: snapshot(mode: .custom, routes: [direct, corp])).expected, .physical)
        XCTAssertEqual(SiteRoute.match(host: "example.org", addresses: ["203.0.113.7"], in: snapshot()).expected, .tunnel("utun4"))
    }

    /// The address whose route decided the answer is always among those checked.
    func testTheMatchedAddressIsAlwaysChecked() {
        let addresses = ["203.0.113.1", "203.0.113.2", "203.0.113.3", "203.0.113.4", "203.0.113.5"]
        let s = snapshot(list: [DomainEntry(domain: "example.com")], active: [("203.0.113.5", local, "example.com")])
        let found = SiteRoute.match(host: "example.com", addresses: addresses, in: s)
        XCTAssertEqual(found.address, "203.0.113.5")
        XCTAssertEqual(SiteRoute.addressesToCheck(addresses, matched: found.address),
                       ["203.0.113.1", "203.0.113.2", "203.0.113.3", "203.0.113.5"])
        XCTAssertEqual(SiteRoute.addressesToCheck(addresses, matched: "203.0.113.2"), Array(addresses.prefix(4)))
        XCTAssertEqual(SiteRoute.addressesToCheck(addresses, matched: nil), Array(addresses.prefix(4)))
    }

    // MARK: The answer

    private func probe(_ address: String, via interface: String, _ answer: PathCheck.Answer = .connected) -> PathCheck.Probe {
        PathCheck.Probe(address: address, routeInterface: interface, answer: answer, latencyMs: answer.answered ? 12 : nil)
    }

    func testAnswerOK() {
        let found = SiteRoute.Found(match: .route, entry: "example.com", routedDestination: "203.0.113.5", expected: .physical)
        let a = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                 probes: [probe("203.0.113.5", via: "en0")],
                                 control: (probe("192.0.2.1", via: "utun4", .notTried), .passed), vpnConnected: true)
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertEqual(a.expected, "physical")
        XCTAssertEqual(a.checks.first?.verdict, .ok)
        XCTAssertEqual(a.control?.address, "192.0.2.1")
        XCTAssertFalse(a.canAdd)
        XCTAssertTrue(a.summary.contains("example.com") && a.summary.contains("en0"), a.summary)
    }

    /// One address the wrong way makes the whole site read wrong, and the sentence names it.
    func testAnswerWrongWayNamesTheTunnel() {
        let found = SiteRoute.Found(match: .listed, entry: "example.com", expected: .physical)
        let a = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5", "203.0.113.6"],
                                 found: found,
                                 probes: [probe("203.0.113.5", via: "en0"), probe("203.0.113.6", via: "utun4")],
                                 control: (probe("192.0.2.1", via: "utun4", .notTried), .passed), vpnConnected: true)
        XCTAssertEqual(a.verdict, .wrongWay)
        XCTAssertTrue(a.summary.contains("utun4"), a.summary)
    }

    func testAnswerCheckBrokenWinsOverAPass() {
        let found = SiteRoute.Found(match: .route, entry: "example.com", routedDestination: "203.0.113.5", expected: .physical)
        let a = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                 probes: [probe("203.0.113.5", via: "en0")],
                                 control: (probe("192.0.2.1", via: "en0", .notTried), .broken(interface: "en0")),
                                 vpnConnected: true)
        XCTAssertEqual(a.verdict, .checkBroken)
        XCTAssertNil(a.checks.first?.verdict, "a broken control leaves no address judged")
    }

    // MARK: Split-tunnel VPN

    /// The control as the app decides it, for a VPN on utun11 in Bypass or Custom.
    private func control(via interface: String) -> (probe: PathCheck.Probe, outcome: PathCheck.Control) {
        let p = probe("192.0.2.1", via: interface, .notTried)
        return (p, PathCheck.control(p, unrouted: .tunnel("utun11")))
    }

    /// A route pinned to a tunnel, under a VPN that carries only some networks: the probe left
    /// through the tunnel and the control around it, so the check told the two ways apart. It
    /// is judged by its own tunnel, and an unanswered 443 stays its own fact, never "broken".
    func testSplitTunnelPinnedRouteIsJudgedByItsTunnel() {
        let found = SiteRoute.Found(match: .route, entry: "rule:198.51.100.20/32", routedDestination: "198.51.100.20/32",
                                    expected: .tunnel("utun11"))
        let silent = SiteRoute.answer(host: "198.51.100.20", mode: .custom, addresses: ["198.51.100.20"], found: found,
                                      probes: [probe("198.51.100.20", via: "utun11", .noAnswer)],
                                      control: control(via: "en8"), vpnConnected: true)
        XCTAssertEqual(silent.verdict, .noAnswer)
        XCTAssertEqual(silent.checks.first?.verdict, .noAnswer)
        XCTAssertEqual(silent.splitTunnel, true)
        XCTAssertEqual(silent.summary, "198.51.100.20 uses 198.51.100.20/32, which has a route added for rule:198.51.100.20/32."
                       + " The check saw it leave through utun11, but nothing answered on port 443.")
        let answered = SiteRoute.answer(host: "198.51.100.20", mode: .custom, addresses: ["198.51.100.20"], found: found,
                                        probes: [probe("198.51.100.20", via: "utun11")],
                                        control: control(via: "en8"), vpnConnected: true)
        XCTAssertEqual(answered.verdict, .ok)
        // A pinned route that leaked around the tunnel is still the wrong way.
        let leaked = SiteRoute.answer(host: "198.51.100.20", mode: .custom, addresses: ["198.51.100.20"], found: found,
                                      probes: [probe("198.51.100.20", via: "en8")],
                                      control: control(via: "en8"), vpnConnected: true)
        XCTAssertEqual(leaked.verdict, .wrongWay)
    }

    /// A Bypass entry under a split tunnel leaves the right way, but its route is not what makes
    /// it so: the answer says that instead of calling the check broken.
    func testSplitTunnelDirectEntrySaysTheRouteChangesNothing() {
        let found = SiteRoute.Found(match: .route, entry: "example.com", routedDestination: "203.0.113.5", expected: .physical)
        let a = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                 probes: [probe("203.0.113.5", via: "en8")],
                                 control: control(via: "en8"), vpnConnected: true)
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertEqual(a.checks.first?.verdict, .ok)
        XCTAssertEqual(a.splitTunnel, true)
        XCTAssertEqual(a.summary, "example.com is on your list, and its address 203.0.113.5 has a route."
                       + " The check saw it leave through en8, and it answered on port 443."
                       + " This VPN carries only some networks, so an address it does not carry leaves through en8"
                       + " even without the entry.")
    }

    /// Custom, no rule matches and the default route is the VPN, under a split tunnel: the name
    /// leaves through the physical interface, and the answer says so instead of naming the VPN.
    func testSplitTunnelCustomDefaultRouteSaysItLeavesThePhysicalInterface() {
        let found = SiteRoute.Found(match: .defaultRoute, routeName: "Corporate VPN", expected: .tunnel("utun11"))
        let a = SiteRoute.answer(host: "example.org", mode: .custom, addresses: ["203.0.113.7"], found: found,
                                 probes: [probe("203.0.113.7", via: "en8")],
                                 control: control(via: "en8"), vpnConnected: true)
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertEqual(a.expected, "physical")
        XCTAssertEqual(a.summary, "example.org matches no rule, so it takes the default route, Corporate VPN,"
                       + " which leaves it to the system's own routing."
                       + " The check saw it leave through en8, and it answered on port 443."
                       + " This VPN carries only some networks, not the default route, so traffic without a route leaves through en8.")
        // A name in one of the VPN's own networks still goes into it: that is the system's routing too.
        let inside = SiteRoute.answer(host: "intranet.example", mode: .custom, addresses: ["10.0.0.5"], found: found,
                                      probes: [probe("10.0.0.5", via: "utun11")],
                                      control: control(via: "en8"), vpnConnected: true)
        XCTAssertEqual(inside.verdict, .ok)
        XCTAssertFalse(inside.summary.contains("only some networks"), inside.summary)
        // Bypass, not on the list: it is not said to follow the VPN.
        let none = SiteRoute.Found(match: .none, expected: .tunnel("utun11"))
        let bypass = SiteRoute.answer(host: "example.org", mode: .bypass, addresses: ["203.0.113.7"], found: none,
                                      probes: [probe("203.0.113.7", via: "en8")],
                                      control: control(via: "en8"), vpnConnected: true)
        XCTAssertEqual(bypass.verdict, .ok)
        XCTAssertTrue(bypass.summary.hasPrefix("example.org is not on your list, so it follows the system's own routing."),
                      bypass.summary)
    }

    /// A full-tunnel VPN keeps today's answers: the control goes through it, nothing mentions a
    /// split tunnel, and an unlisted name still follows the VPN.
    func testFullTunnelAnswersAreUnchanged() {
        let found = SiteRoute.Found(match: .defaultRoute, routeName: "Corporate VPN", expected: .tunnel("utun11"))
        let a = SiteRoute.answer(host: "example.org", mode: .custom, addresses: ["203.0.113.7"], found: found,
                                 probes: [probe("203.0.113.7", via: "utun11")],
                                 control: control(via: "utun11"), vpnConnected: true)
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertNil(a.splitTunnel)
        XCTAssertEqual(a.expected, "tunnel:utun11")
        XCTAssertEqual(a.summary, "example.org matches no rule, so it takes the default route, Corporate VPN."
                       + " The check saw it leave through utun11, and it answered on port 443.")
        let leaked = SiteRoute.answer(host: "example.org", mode: .custom, addresses: ["203.0.113.7"], found: found,
                                      probes: [probe("203.0.113.7", via: "en8")],
                                      control: control(via: "utun11"), vpnConnected: true)
        XCTAssertEqual(leaked.verdict, .wrongWay)
    }

    /// Genuinely broken: the control left through another tunnel, so the ways cannot be told apart.
    func testControlThroughAnotherTunnelIsStillBroken() {
        let found = SiteRoute.Found(match: .route, entry: "example.com", routedDestination: "203.0.113.5", expected: .physical)
        let a = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                 probes: [probe("203.0.113.5", via: "en8")],
                                 control: control(via: "utun7"), vpnConnected: true)
        XCTAssertEqual(a.verdict, .checkBroken)
        XCTAssertNil(a.splitTunnel)
        XCTAssertNil(a.checks.first?.verdict)
    }

    func testAnswerNotListedOffersAdd() {
        let found = SiteRoute.Found(match: .none, expected: .tunnel("utun4"))
        let a = SiteRoute.answer(host: "example.org", mode: .bypass, addresses: ["203.0.113.7"], found: found,
                                 probes: [probe("203.0.113.7", via: "utun4")], control: nil, vpnConnected: true)
        XCTAssertEqual(a.verdict, .ok)
        XCTAssertTrue(a.canAdd)
    }

    func testAnswerWithoutVPNAndUnresolved() {
        let none = SiteRoute.Found(match: .none, expected: .tunnel("VPN"))
        XCTAssertEqual(SiteRoute.answer(host: "example.org", mode: .bypass, addresses: ["203.0.113.7"], found: none,
                                        probes: [probe("203.0.113.7", via: "en0")], control: nil,
                                        vpnConnected: false).verdict, .noVPN)
        let unresolved = SiteRoute.Found(match: .unresolved, expected: nil)
        let a = SiteRoute.answer(host: "nx.invalid", mode: .bypass, addresses: [], found: unresolved,
                                 probes: [], control: nil, vpnConnected: true)
        XCTAssertEqual(a.verdict, .unresolved)
        XCTAssertTrue(a.checks.isEmpty)
    }

    func testAnswerThroughAProxyIsNotChecked() {
        let found = SiteRoute.Found(match: .rule, entry: "example.com", rulePosition: 1, ruleMatchType: "domain",
                                    routeName: "Proxy", expected: nil)
        let a = SiteRoute.answer(host: "example.com", mode: .custom, addresses: ["203.0.113.5"], found: found,
                                 probes: [probe("203.0.113.5", via: "utun4")], control: nil, vpnConnected: true)
        XCTAssertEqual(a.verdict, .notChecked)
        XCTAssertNil(a.checks.first?.verdict)
    }

    // MARK: vpnb why

    func testWhyTakesABareHost() {
        let parsed = VPNBCLI.parse(["why", "example.com"])
        XCTAssertEqual(parsed.cmd, "why")
        XCTAssertEqual(parsed.args, ["host": "example.com"])
        XCTAssertEqual(parsed.malformed, [])
        XCTAssertEqual(VPNBCLI.parse(["why", "host=example.com"]).args, ["host": "example.com"])
        XCTAssertEqual(VPNBCLI.parse(["status", "example.com"]).malformed, ["example.com"], "only why takes a bare token")
        // A pasted link stays whole even when its query holds "=".
        let link = VPNBCLI.parse(["why", "https://example.com/search?q=a&b=c"])
        XCTAssertEqual(link.args, ["host": "https://example.com/search?q=a&b=c"])
        XCTAssertEqual(link.malformed, [])
    }

    func testWhyIsAReadVerb() {
        XCTAssertFalse(CommandRouter.isMutating("why"))
    }

    func testWhyRendersAsTextAndJSON() throws {
        let found = SiteRoute.Found(match: .route, entry: "example.com", routedDestination: "203.0.113.5", expected: .physical)
        let answer = SiteRoute.answer(host: "example.com", mode: .bypass, addresses: ["203.0.113.5"], found: found,
                                      probes: [probe("203.0.113.5", via: "en0")],
                                      control: (probe("192.0.2.1", via: "utun4", .notTried), .passed), vpnConnected: true)
        let response = ControlResponse(ok: true, result: ControlResult(why: answer))
        let lines = VPNBCLI.textLines(response)
        XCTAssertEqual(lines.first, answer.summary)
        XCTAssertTrue(lines.contains("  203.0.113.5  via en0  443: connected in 12 ms  ok"), "\(lines)")
        XCTAssertTrue(lines.contains("  control 192.0.2.1  via utun4"), "\(lines)")
        XCTAssertTrue(lines.contains("  match: route  entry: example.com  expected: physical  verdict: ok"), "\(lines)")

        let json = VPNBCLI.renderJSON(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.result?.why, answer)
        XCTAssertTrue(json.contains(#""verdict":"ok""#), json)
    }
}
