import XCTest
@testable import SpikePolicy

final class FlowDeciderTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let publicIP = AddressRanges.parse("93.184.216.34")!

    func live(_ apps: [String] = ["com.geiserx.vpn-bypass.spike.fetch"], hosts: [String] = ["example.org"],
              lease: Int = 120, version: Int = SpikePolicy.currentVersion) -> PolicyState {
        var s = PolicyState()
        s.accept(SpikePolicy(version: version, generation: 1, apps: apps, hostnames: hosts, leaseSeconds: lease), at: t0)
        return s
    }

    func facts(_ id: String = "com.geiserx.vpn-bypass.spike.fetch", remote: FlowFacts.Remote? = nil, host: String? = nil,
               bound: Bool = false, path: String? = nil, team: String? = "624WUVM8B4") -> FlowFacts {
        FlowFacts(signingIdentifier: id, remote: remote ?? .ipv4(publicIP), remoteHostname: host, isBound: bound,
                  executablePath: { path }, teamIdentifier: { team })
    }

    func testNoPolicyDeclines() {
        XCTAssertEqual(FlowDecider.decide(facts(), state: PolicyState(), now: t0), .decline(.noPolicy))
    }

    func testExpiredLeaseDeclines() {
        let s = live(lease: 120)
        XCTAssertEqual(FlowDecider.decide(facts(), state: s, now: t0.addingTimeInterval(120)), .claim(.app))
        XCTAssertEqual(FlowDecider.decide(facts(), state: s, now: t0.addingTimeInterval(121)), .decline(.leaseExpired))
    }

    func testUnknownVersionDeclines() {
        XCTAssertEqual(FlowDecider.decide(facts(), state: live(version: 99), now: t0), .decline(.unknownVersion))
    }

    func testOwnAndSystemProcessesDecline() {
        let s = live(["com.geiserx", "com.apple"])
        XCTAssertEqual(FlowDecider.decide(facts("com.geiserx.vpn-bypass.spike.proxy"), state: s, now: t0), .decline(.ownProcess))
        XCTAssertEqual(FlowDecider.decide(facts("com.geiserx.vpnbypass.helper"), state: s, now: t0), .decline(.ownProcess))
        XCTAssertEqual(FlowDecider.decide(facts("com.apple.mDNSResponder"), state: s, now: t0), .decline(.systemProcess))
    }

    func testVPNClientDeclinedByTeamEvenWithBareIdentifier() {
        // GlobalProtect's daemon: Identifier=PanGPS, TeamIdentifier=PXPZ95SK77.
        let s = live(["PanGPS"])
        let f = facts("PanGPS", path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS", team: "PXPZ95SK77")
        XCTAssertEqual(FlowDecider.decide(f, state: s, now: t0), .decline(.protectedTeam))
        let ts = facts("io.tailscale.ipn.macsys", team: "W5364U7YZB")
        XCTAssertEqual(FlowDecider.decide(ts, state: live(["io.tailscale"]), now: t0), .decline(.protectedTeam))
    }

    func testTeamLookupRunsOnlyForMatchedFlows() {
        var looked = false
        let f = FlowFacts(signingIdentifier: "com.other.app", remote: .ipv4(publicIP), teamIdentifier: { looked = true; return nil })
        XCTAssertEqual(FlowDecider.decide(f, state: live(), now: t0), .decline(.noMatch))
        XCTAssertFalse(looked)
    }

    func testBoundDeclines() {
        XCTAssertEqual(FlowDecider.decide(facts(bound: true), state: live(), now: t0), .decline(.bound))
    }

    func testIPv6AndPrivateDestinationsDecline() {
        XCTAssertEqual(FlowDecider.decide(facts(remote: .ipv6), state: live(), now: t0), .decline(.ipv6))
        for a in ["10.1.2.3", "192.168.1.1", "172.20.0.1", "100.100.100.100", "169.254.1.1", "127.0.0.1", "224.0.0.251"] {
            let f = facts(remote: .ipv4(AddressRanges.parse(a)!))
            XCTAssertEqual(FlowDecider.decide(f, state: live(), now: t0), .decline(.excludedDestination), a)
        }
        // Edges just outside the private ranges are public.
        for a in ["172.32.0.1", "100.128.0.1", "11.0.0.1"] {
            XCTAssertFalse(AddressRanges.isExcluded(AddressRanges.parse(a)!), a)
        }
    }

    func testBundleIDMatchesOnDotBoundaryOnly() {
        let s = live(["com.x.App"], hosts: [])
        XCTAssertEqual(FlowDecider.decide(facts("com.x.App"), state: s, now: t0), .claim(.app))
        XCTAssertEqual(FlowDecider.decide(facts("com.x.App.helper"), state: s, now: t0), .claim(.app))
        XCTAssertEqual(FlowDecider.decide(facts("com.x.AppX"), state: s, now: t0), .decline(.noMatch))
        XCTAssertEqual(FlowDecider.decide(facts("com.x"), state: s, now: t0), .decline(.noMatch))
    }

    func testExecutableNameMatchesBasename() {
        let s = live(["curl"], hosts: [])
        XCTAssertEqual(FlowDecider.decide(facts("com.apple.curl", path: "/usr/bin/curl"), state: s, now: t0), .claim(.app))
        XCTAssertEqual(FlowDecider.decide(facts("x", path: "/opt/bin/curlx"), state: s, now: t0), .decline(.noMatch))
        XCTAssertEqual(FlowDecider.decide(facts("x", path: nil), state: s, now: t0), .decline(.noMatch))
    }

    func testHostnameMatchesConnectByNameOnly() {
        let s = live([], hosts: ["example.org"])
        XCTAssertEqual(FlowDecider.decide(facts("com.apple.nscurl", host: "example.org"), state: s, now: t0), .claim(.hostname))
        XCTAssertEqual(FlowDecider.decide(facts("com.apple.nscurl", host: "API.Example.org."), state: s, now: t0), .claim(.hostname))
        XCTAssertEqual(FlowDecider.decide(facts("com.apple.nscurl", remote: .name("www.example.org")), state: s, now: t0), .claim(.hostname))
        XCTAssertEqual(FlowDecider.decide(facts("com.apple.nscurl", host: "badexample.org"), state: s, now: t0), .decline(.noMatch))
        // A connect-by-IP flow (curl) carries no host name: not matched, it stays in the VPN.
        XCTAssertEqual(FlowDecider.decide(facts("com.apple.curl"), state: s, now: t0), .decline(.noMatch))
    }

    func testEmptyPolicyDeclinesEverything() {
        let s = live([], hosts: [])
        XCTAssertEqual(FlowDecider.decide(facts(host: "example.org"), state: s, now: t0), .decline(.noMatch))
    }

    func testUnknownRemoteDeclines() {
        XCTAssertEqual(FlowDecider.decide(facts(remote: .unknown), state: live(), now: t0), .decline(.excludedDestination))
    }
}

final class PolicyTests: XCTestCase {
    func testParseList() {
        XCTAssertEqual(SpikePolicy.parseList(" Example.org., example.org\napi.x.com  ", lowercase: true), ["example.org", "api.x.com"])
        XCTAssertEqual(SpikePolicy.parseList("com.X.App, curl", lowercase: false), ["com.X.App", "curl"])
        XCTAssertEqual(SpikePolicy.parseList(" , ", lowercase: true), [])
    }

    func testAppListKeepsSpacesInExecutableNames() {
        XCTAssertEqual(SpikePolicy.parseAppList("Google Chrome Helper, com.X.App\ncurl ,"),
                       ["Google Chrome Helper", "com.X.App", "curl"])
        let path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper"
        XCTAssertTrue(Matching.appMatches(SpikePolicy.parseAppList("Google Chrome Helper"),
                                          signingIdentifier: "com.google.Chrome.helper", executablePath: { path }))
    }

    func testStatusConfirmsOnlyTheLivePushedPolicy() {
        let p = SpikePolicy(generation: 3, apps: ["curl"], hostnames: [])
        var s = SpikeStatus()
        s.policyGeneration = 3
        s.policyLive = true
        XCTAssertTrue(s.confirms(p))
        // The extension rejected the policy (unknown version): it cleared its state.
        var rejected = SpikeStatus()
        rejected.policyGeneration = 0
        rejected.policyLive = false
        XCTAssertFalse(rejected.confirms(p))
        s.policyGeneration = 2
        XCTAssertFalse(s.confirms(p))
    }

    func testScope() {
        XCTAssertEqual(IncludeScope("all"), .allTCP)
        XCTAssertEqual(IncludeScope("port:80"), .tcpPort(80))
        XCTAssertNil(IncludeScope("port:0"))
        XCTAssertNil(IncludeScope("port:99999"))
        XCTAssertNil(IncludeScope(nil))
        XCTAssertEqual(IncludeScope.tcpPort(80).token, "port:80")
    }

    /// A start by the OS (boot, wake, restart after a crash or kill -9) has no options: it must come
    /// up on the narrow scope, never on `all`. So must a start whose scope cannot be read.
    func testStartWithoutScopeIsNarrow() {
        XCTAssertEqual(IncludeScope.atStart(nil), .tcpPort(80))
        XCTAssertEqual(IncludeScope.atStart(""), .tcpPort(80))
        XCTAssertEqual(IncludeScope.atStart("everything"), .tcpPort(80))
        XCTAssertEqual(IncludeScope.atStart("port:0"), .tcpPort(80))
        XCTAssertEqual(IncludeScope.atStart("all"), .allTCP)
        XCTAssertEqual(IncludeScope.atStart("port:443"), .tcpPort(443))
    }

    func testRequestRoundTrip() throws {
        let r = SpikeRequest(policy: SpikePolicy(generation: 3, apps: ["a.b"], hostnames: ["c.d"], interfaceName: "en0"))
        XCTAssertEqual(try JSONDecoder().decode(SpikeRequest.self, from: JSONEncoder().encode(r)), r)
    }

    /// The status reply carries no strings beyond the scope token and the interface name.
    func testStatusCarriesNoNames() throws {
        var s = SpikeStatus()
        s.scope = "all"
        s.interfaceName = "en0"
        s.counters = ["claimed.app": 2]
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        let props = Mirror(reflecting: s).children.map { "\(type(of: $0.value))" }
        XCTAssertEqual(props.filter { $0 == "String" }.count, 2, json)
    }

    func testExcludedCIDRText() {
        let cidrs = AddressRanges.excludedIPv4CIDRs.map { "\($0.address)/\($0.prefix)" }
        XCTAssertTrue(cidrs.contains("100.64.0.0/10"))
        XCTAssertTrue(cidrs.contains("172.16.0.0/12"))
    }

    /// An excluded rule is built with port 0 (any); on 0.0.0.0 that is all wildcards and macOS
    /// refuses the whole settings object, so the proxy never starts. 0/8 stays declined in code.
    func testExcludedRulesHaveNoWildcardAddress() {
        let rules = AddressRanges.excludedRuleCIDRs.map { "\($0.address)/\($0.prefix)" }
        XCTAssertFalse(rules.contains { $0.hasPrefix("0.0.0.0/") }, "\(rules)")
        XCTAssertEqual(rules.count, AddressRanges.excludedIPv4.count - 1)
        XCTAssertTrue(rules.contains("100.64.0.0/10"))
        XCTAssertTrue(AddressRanges.isExcluded(AddressRanges.parse("0.1.2.3")!))
    }
}
