import XCTest
@testable import VPNBypassPolicy

final class FlowDeciderTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let publicIP = ProtectedRanges.parse("93.184.216.34")!
    let ruleA = "11111111-1111-1111-1111-111111111111"
    let ruleB = "22222222-2222-2222-2222-222222222222"
    let en0 = FlowEgress.direct(interface: "en0")

    func matcher(_ pattern: String, _ rule: String, _ egress: FlowEgress? = nil) -> AppMatcher {
        AppMatcher(ruleID: rule, kind: AppMatcher.kind(of: pattern), pattern: pattern, egress: egress ?? en0)
    }

    func live(_ matchers: [AppMatcher]? = nil, teams: [String] = [], lease: Int = 120,
              version: Int = FlowPolicy.currentVersion) -> FlowPolicyState {
        var s = FlowPolicyState()
        let p = FlowPolicy(version: version, generation: 7, matchers: matchers ?? [matcher("com.example.App", ruleA)],
                           declinedTeams: teams, leaseSeconds: lease)
        s.receive(.policy(p), at: t0)
        return s
    }

    func facts(_ id: String = "com.example.App", remote: FlowFacts.Remote? = nil, host: String? = nil,
               bound: Bool = false, transport: FlowFacts.Transport = .tcp, path: String? = nil,
               team: String? = "ABCDE12345") -> FlowFacts {
        FlowFacts(signingIdentifier: id, remote: remote ?? .ipv4(publicIP), remoteHostname: host, isBound: bound,
                  transport: transport, executablePath: { path }, teamIdentifier: { team })
    }

    func decide(_ f: FlowFacts, _ s: FlowPolicyState, at offset: TimeInterval = 0) -> FlowDecision {
        FlowDecider.decide(f, state: s, now: t0.addingTimeInterval(offset))
    }

    // MARK: - 1. A live policy

    func testNoPolicyDeclines() {
        XCTAssertEqual(decide(facts(), FlowPolicyState()), .decline(.noPolicy))
    }

    func testLeaseRunsOutAfterItsLength() {
        let s = live(lease: 120)
        XCTAssertEqual(decide(facts(), s, at: 120), .claim(ruleID: ruleA, egress: en0))
        XCTAssertEqual(decide(facts(), s, at: 120.5), .decline(.leaseExpired))
        // A clock that went backwards is no proof of a fresh push.
        XCTAssertEqual(decide(facts(), s, at: -1), .decline(.leaseExpired))
    }

    func testLeaseIsCappedWhateverThePolicyAsks() {
        let s = live(lease: 86_400)
        let cap = TimeInterval(FlowPolicy.maxLeaseSeconds)
        XCTAssertEqual(decide(facts(), s, at: cap), .claim(ruleID: ruleA, egress: en0))
        XCTAssertEqual(decide(facts(), s, at: cap + 1), .decline(.leaseExpired))
    }

    func testUnknownVersionDeclinesEverything() {
        XCTAssertEqual(decide(facts(), live(version: 99)), .decline(.unknownVersion))
        var s = live()
        s.receive(.unknownVersion(2), at: t0)
        XCTAssertEqual(s.rejectedVersion, 2)
        XCTAssertEqual(decide(facts(), s), .decline(.unknownVersion))
        // A malformed push drops the policy too: never keep claiming on a policy the app replaced.
        s = live()
        s.receive(.malformed, at: t0)
        XCTAssertEqual(decide(facts(), s), .decline(.noPolicy))
    }

    func testReadablePushClearsAnEarlierVersionMismatch() {
        var s = FlowPolicyState()
        s.receive(.unknownVersion(2), at: t0)
        s.receive(.policy(FlowPolicy(generation: 8, matchers: [matcher("com.example.App", ruleA)])), at: t0)
        XCTAssertNil(s.rejectedVersion)
        XCTAssertEqual(decide(facts(), s), .claim(ruleID: ruleA, egress: en0))
    }

    // MARK: - 2. Own and system processes

    func testOwnAndSystemProcessesDeclineWhateverTheMatchers() {
        let s = live([matcher("com.geiserx", ruleA), matcher("com.apple", ruleB)])
        let table: [(String, FlowDecision.Reason)] = [
            ("com.geiserx.vpn-bypass", .ownProcess),
            ("com.geiserx.vpn-bypass.vpnb", .ownProcess),
            ("com.geiserx.vpnbypass.helper", .ownProcess),
            ("com.geiserx.vpn-bypass.proxy", .ownProcess),
            ("com.apple.mDNSResponder", .systemProcess),
            ("com.apple.mDNSResponderHelper", .systemProcess),
            ("com.apple.apsd", .systemProcess),
            ("com.apple.captiveagent", .systemProcess),
            ("com.apple.nesessionmanager", .systemProcess),
            ("com.apple.neagent", .systemProcess),
        ]
        for (id, reason) in table {
            XCTAssertEqual(decide(facts(id), s), .decline(reason), id)
        }
        // The prefix matcher still serves an app of the same vendor that is not on the list.
        XCTAssertEqual(decide(facts("com.apple.Safari"), s), .claim(ruleID: ruleB, egress: en0))
    }

    // MARK: - 3. Bound flows

    func testBoundFlowDeclinesAndNamesItsRule() {
        let s = live([matcher("com.example.App", ruleA)])
        XCTAssertEqual(decide(facts(bound: true), s), .decline(.bound, ruleID: ruleA))
        XCTAssertEqual(decide(facts("com.other.App", bound: true), s), .decline(.bound, ruleID: nil))
    }

    func testBoundFlowNeverReadsTheTeam() {
        var looked = false
        let f = FlowFacts(signingIdentifier: "com.example.App", remote: .ipv4(publicIP), isBound: true,
                          teamIdentifier: { looked = true; return nil })
        XCTAssertEqual(decide(f, live()), .decline(.bound, ruleID: ruleA))
        XCTAssertFalse(looked)
    }

    // MARK: - 4. Transport and destination

    func testDestinationsTable() {
        let s = live()
        let table: [(FlowFacts.Remote, FlowDecision)] = [
            (.ipv6, .decline(.ipv6)),
            (.unknown, .decline(.unknownDestination)),
            (.ipv4(ProtectedRanges.parse("0.1.2.3")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("10.0.0.1")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("100.64.0.1")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("100.100.100.100")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("100.127.255.255")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("127.0.0.1")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("169.254.1.1")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("172.16.0.1")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("172.31.255.255")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("192.168.1.1")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("224.0.0.251")!), .decline(.protectedDestination)),
            (.ipv4(ProtectedRanges.parse("255.255.255.255")!), .decline(.protectedDestination)),
            // Just outside each range: public, claimed.
            (.ipv4(ProtectedRanges.parse("100.128.0.1")!), .claim(ruleID: ruleA, egress: en0)),
            (.ipv4(ProtectedRanges.parse("100.63.255.255")!), .claim(ruleID: ruleA, egress: en0)),
            (.ipv4(ProtectedRanges.parse("172.32.0.1")!), .claim(ruleID: ruleA, egress: en0)),
            (.ipv4(ProtectedRanges.parse("11.0.0.1")!), .claim(ruleID: ruleA, egress: en0)),
            (.ipv4(ProtectedRanges.parse("223.255.255.255")!), .claim(ruleID: ruleA, egress: en0)),
            (.ipv4(publicIP), .claim(ruleID: ruleA, egress: en0)),
            // A connect-by-name flow: the extension dials the name on the physical interface (3.5).
            (.name("example.com"), .claim(ruleID: ruleA, egress: en0)),
            (.name("example.com."), .claim(ruleID: ruleA, egress: en0)),
            // A name that is an address literal is checked as that address.
            (.name("10.0.0.5"), .decline(.protectedDestination)),
            (.name("100.100.100.100"), .decline(.protectedDestination)),
            (.name("93.184.216.34"), .claim(ruleID: ruleA, egress: en0)),
            (.name("::1"), .decline(.ipv6)),
            (.name("2001:db8::1"), .decline(.ipv6)),
            // Names that never leave the Mac or the local link.
            (.name("localhost"), .decline(.protectedDestination)),
            (.name("LOCALHOST."), .decline(.protectedDestination)),
            (.name("printer.local"), .decline(.protectedDestination)),
            (.name("app.localhost"), .decline(.protectedDestination)),
            (.name("localhost.example.com"), .claim(ruleID: ruleA, egress: en0)),
        ]
        for (remote, verdict) in table {
            XCTAssertEqual(decide(facts(remote: remote), s), verdict, "\(remote)")
        }
    }

    func testUDPDeclines() {
        XCTAssertEqual(decide(facts(transport: .udp), live()), .decline(.notTCP))
    }

    // MARK: - 5. Matching

    func testBundleIDMatchesExactlyOrOnADotBoundary() {
        let s = live([matcher("com.example.App", ruleA)])
        let table: [(String, Bool)] = [
            ("com.example.App", true),
            ("com.example.App.helper", true),
            ("com.example.App.helper.GPU", true),
            ("com.example.AppX", false),
            ("com.example", false),
            ("com.example.app", false),
            ("xcom.example.App", false),
        ]
        for (id, claims) in table {
            XCTAssertEqual(decide(facts(id), s), claims ? .claim(ruleID: ruleA, egress: en0) : .decline(.noMatch), id)
        }
    }

    func testExecutableNameMatchesThePathsLastComponent() {
        let s = live([matcher("Example Helper", ruleA)])
        let table: [(String?, Bool)] = [
            ("/Applications/Example.app/Contents/MacOS/Example Helper", true),
            ("/usr/local/bin/Example Helper", true),
            ("/usr/local/bin/Example Helper2", false),
            ("/Applications/Example Helper/other", false),
            (nil, false),
        ]
        for (path, claims) in table {
            XCTAssertEqual(decide(facts("a.b.c", path: path), s),
                           claims ? .claim(ruleID: ruleA, egress: en0) : .decline(.noMatch), path ?? "nil")
        }
        // An unsigned binary's signing id is often its bare name; matching is by path all the same.
        XCTAssertEqual(decide(facts("Example Helper", path: "/tmp/other"), s), .decline(.noMatch))
    }

    func testExecutablePathReadOnceAndOnlyWhenNeeded() {
        var reads = 0
        let s = live([matcher("com.example.App", ruleA), matcher("one", ruleB), matcher("two", ruleB)])
        let byID = FlowFacts(signingIdentifier: "com.example.App", remote: .ipv4(publicIP),
                             executablePath: { reads += 1; return "/bin/two" })
        _ = decide(byID, s)
        XCTAssertEqual(reads, 0)
        let byName = FlowFacts(signingIdentifier: "x.y", remote: .ipv4(publicIP),
                               executablePath: { reads += 1; return "/bin/two" })
        XCTAssertEqual(decide(byName, s), .claim(ruleID: ruleB, egress: en0))
        XCTAssertEqual(reads, 1)
    }

    func testFirstMatchWinsAndItsRouteDecides() {
        let vpnFirst = live([matcher("com.example.App", ruleA, .vpnDefault), matcher("com.example.App.helper", ruleB)])
        XCTAssertEqual(decide(facts("com.example.App.helper"), vpnFirst), .decline(.vpnRoute, ruleID: ruleA))
        let directFirst = live([matcher("com.example.App.helper", ruleB), matcher("com.example.App", ruleA, .vpnDefault)])
        XCTAssertEqual(decide(facts("com.example.App.helper"), directFirst), .claim(ruleID: ruleB, egress: en0))
        XCTAssertEqual(decide(facts("com.example.App"), directFirst), .decline(.vpnRoute, ruleID: ruleA))
    }

    func testUnsupportedRouteDeclines() {
        XCTAssertEqual(decide(facts(), live([matcher("com.example.App", ruleA, .unsupported)])),
                       .decline(.unsupportedRoute, ruleID: ruleA))
    }

    func testDirectCarriesItsInterfaceOrNone() {
        let any = FlowEgress.direct(interface: nil)
        XCTAssertEqual(decide(facts(), live([matcher("com.example.App", ruleA, any)])), .claim(ruleID: ruleA, egress: any))
    }

    func testHostNameAloneNeverClaims() {
        let s = live([matcher("example.com", ruleA)])
        XCTAssertEqual(decide(facts("com.other.App", remote: .name("example.com"), host: "example.com"), s),
                       .decline(.noMatch))
        XCTAssertEqual(decide(facts("com.other.App", host: "api.example.com"), s), .decline(.noMatch))
    }

    func testEmptyPolicyClaimsNothing() {
        XCTAssertEqual(decide(facts(), live([])), .decline(.noMatch))
    }

    // MARK: - 6. VPN and security clients

    func testVPNClientsDeclinedByTeamEvenWithABareIdentifier() {
        // GlobalProtect's daemon: Identifier=PanGPS, TeamIdentifier=PXPZ95SK77.
        let pan = facts("PanGPS", path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS", team: "PXPZ95SK77")
        XCTAssertEqual(decide(pan, live([matcher("PanGPS", ruleA)])), .decline(.protectedTeam, ruleID: ruleA))
        for team in FlowDecider.protectedTeams {
            XCTAssertEqual(decide(facts(team: team), live()), .decline(.protectedTeam, ruleID: ruleA), team)
        }
    }

    func testTunnelOwnerTeamFromThePolicyDeclines() {
        let s = live(teams: ["TEAM000001"])
        XCTAssertEqual(decide(facts(team: "TEAM000001"), s), .decline(.protectedTeam, ruleID: ruleA))
        XCTAssertEqual(decide(facts(team: "TEAM000002"), s), .claim(ruleID: ruleA, egress: en0))
        XCTAssertEqual(decide(facts(team: nil), s), .claim(ruleID: ruleA, egress: en0))
    }

    func testTeamReadOnlyForAFlowThatWouldBeClaimed() {
        var looked = 0
        func f(_ id: String, remote: FlowFacts.Remote = .ipv4(ProtectedRanges.parse("93.184.216.34")!)) -> FlowFacts {
            FlowFacts(signingIdentifier: id, remote: remote, teamIdentifier: { looked += 1; return nil })
        }
        let s = live([matcher("com.vpn.App", ruleB, .vpnDefault), matcher("com.example.App", ruleA)])
        _ = decide(f("com.other.App"), s)
        _ = decide(f("com.vpn.App"), s)
        _ = decide(f("com.example.App", remote: .ipv6), s)
        XCTAssertEqual(looked, 0)
        XCTAssertEqual(decide(f("com.example.App"), s), .claim(ruleID: ruleA, egress: en0))
        XCTAssertEqual(looked, 1)
    }

    // MARK: - The order of the checks

    func testChecksRunInTheDesignedOrder() {
        // Each row breaks two checks at once; the earlier one in 3.4 must win.
        let s = live([matcher("com.example.App", ruleA)], teams: ["ABCDE12345"])
        let table: [(FlowFacts, FlowDecision, String)] = [
            (facts("com.geiserx.vpn-bypass", bound: true), .decline(.ownProcess), "own before bound"),
            (facts("com.apple.mDNSResponder", remote: .ipv6), .decline(.systemProcess), "system before destination"),
            (facts(remote: .ipv6, bound: true), .decline(.bound, ruleID: ruleA), "bound before destination"),
            (facts(remote: .ipv6, transport: .udp), .decline(.notTCP), "transport before destination"),
            (facts("com.other.App", remote: .ipv6), .decline(.ipv6), "destination before match"),
            (facts(remote: .ipv4(ProtectedRanges.parse("10.1.1.1")!)), .decline(.protectedDestination), "destination before team"),
            (facts(), .decline(.protectedTeam, ruleID: ruleA), "team last"),
        ]
        for (f, verdict, label) in table {
            XCTAssertEqual(decide(f, s), verdict, label)
        }
        XCTAssertEqual(decide(facts(), FlowPolicyState()), .decline(.noPolicy))
        XCTAssertEqual(decide(facts("com.geiserx.vpn-bypass"), live(lease: 1), at: 5), .decline(.leaseExpired),
                       "lease before own")
    }

    // MARK: - Ranges

    func testExcludedRuleCIDRsLeaveOutZeroSlashEight() {
        XCTAssertFalse(ProtectedRanges.ipv4RuleCIDRs.contains { $0.address == "0.0.0.0" })
        XCTAssertEqual(ProtectedRanges.ipv4RuleCIDRs.count, ProtectedRanges.ipv4.count - 1)
        XCTAssertTrue(ProtectedRanges.ipv4RuleCIDRs.contains { $0 == ("100.64.0.0", 10) })
        XCTAssertTrue(ProtectedRanges.contains(ProtectedRanges.parse("0.0.0.0")!))
    }

    func testParse() {
        XCTAssertEqual(ProtectedRanges.parse("1.2.3.4"), 0x0102_0304)
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "a.b.c.d", "+1.2.3.4", "0001.2.3.4"] {
            XCTAssertNil(ProtectedRanges.parse(bad), bad)
        }
        XCTAssertEqual(ProtectedRanges.dotted(0x0102_0304), "1.2.3.4")
    }
}
