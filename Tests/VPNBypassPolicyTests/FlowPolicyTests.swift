import XCTest
@testable import VPNBypassPolicy

final class FlowPolicyTests: XCTestCase {
    func m(_ pattern: String, _ egress: FlowEgress = .direct(interface: "en0"), id: String? = nil) -> AppMatcher {
        AppMatcher(ruleID: id ?? pattern, kind: AppMatcher.kind(of: pattern), pattern: pattern, egress: egress)
    }

    func policy(_ matchers: [AppMatcher], teams: [String] = [], generation: Int = 1) -> FlowPolicy {
        FlowPolicy(generation: generation, matchers: matchers, declinedTeams: teams)
    }

    // MARK: - Wire format

    func testRoundTripsThroughTheMessage() throws {
        let p = FlowPolicy(generation: 42, matchers: [m("com.example.App"), m("Tool", .vpnDefault), m("a.b", .unsupported),
                                                      m("c.d", .direct(interface: nil))],
                           declinedTeams: ["TEAM000001"], leaseSeconds: 90)
        XCTAssertEqual(FlowPolicyMessage.decode(try FlowPolicyMessage.encode(p)), .policy(p))
    }

    func testUnknownVersionIsReportedNotMisread() throws {
        var newer = try JSONSerialization.jsonObject(with: FlowPolicyMessage.encode(policy([m("a.b")]))) as! [String: Any]
        newer["version"] = 2
        // A newer app may also change the shape; the version still reads.
        newer["matchers"] = [["somethingNew": true]]
        let data = try JSONSerialization.data(withJSONObject: newer)
        XCTAssertEqual(FlowPolicyMessage.decode(data), .unknownVersion(2))
    }

    func testMalformedMessages() {
        for text in ["", "{}", "[]", "not json", #"{"version":1}"#, #"{"version":"1"}"#] {
            XCTAssertEqual(FlowPolicyMessage.decode(Data(text.utf8)), .malformed, text)
        }
    }

    func testEncodingIsStable() throws {
        let p = policy([m("com.example.App")], teams: ["T"])
        XCTAssertEqual(try FlowPolicyMessage.encode(p), try FlowPolicyMessage.encode(p))
        let text = String(decoding: try FlowPolicyMessage.encode(p), as: UTF8.self)
        XCTAssertTrue(text.contains(#""version":1"#), text)
        XCTAssertTrue(text.contains(#""generation":1"#), text)
    }

    // MARK: - The echo

    func testReplyConfirmsOnlyTheLiveGenerationItHolds() {
        let p = policy([m("a.b")], generation: 5)
        XCTAssertTrue(FlowPolicyReply(policyGeneration: 5, policyLive: true).confirms(p))
        XCTAssertFalse(FlowPolicyReply(policyGeneration: 4, policyLive: true).confirms(p))
        XCTAssertFalse(FlowPolicyReply(policyGeneration: 5, policyLive: false).confirms(p))
        XCTAssertFalse(FlowPolicyReply(policyGeneration: 5, policyLive: true, rejectedVersion: 2).confirms(p))
        XCTAssertFalse(FlowPolicyReply().confirms(p))
    }

    func testReplyRoundTripsAndCarriesNoNames() throws {
        let r = FlowPolicyReply(policyGeneration: 9, policyLive: true, leaseExpiries: 2,
                                declined: [FlowDecision.Reason.bound.rawValue: 3],
                                claimedByRule: ["bypass-app-0": 4], boundByRule: ["bypass-app-0": 3])
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(FlowPolicyReply.self, from: data), r)
    }

    // MARK: - Which pushes must wait for the echo

    func testShrinksClaimsTable() {
        let a = m("com.example.A"), b = m("com.example.B"), vpnA = m("com.example.A", .vpnDefault)
        let base = policy([a, b])
        let table: [(FlowPolicy?, FlowPolicy, Bool, String)] = [
            (nil, base, true, "first push after launch: the extension may hold an older lease"),
            (base, base, false, "same policy again (heartbeat)"),
            (base, policy([a, b, m("com.example.C")]), false, "a Direct rule added at the end"),
            (policy([a]), policy([m("com.example.C"), a]), false, "a Direct rule added in front only adds claims"),
            (base, policy([a]), true, "a Direct rule removed"),
            (base, policy([]), true, "Pause, VPN Only, kill switch"),
            (base, policy([vpnA, b]), true, "a rule's route changed from Direct to VPN"),
            (base, policy([m("com.example.X", .vpnDefault), a, b]), true, "a VPN rule added in front of Direct ones"),
            (base, policy([a, b, m("com.example.X", .vpnDefault)]), false, "a VPN rule added at the end"),
            (base, policy([b, a]), false, "Direct rules on one interface reordered"),
            (policy([vpnA, a]), policy([a, vpnA]), false, "a Direct rule moved in front of a VPN one"),
            (policy([a, m("com.example.A.helper", .vpnDefault, id: "h")]),
             policy([m("com.example.A.helper", .vpnDefault, id: "h"), a]), true, "a VPN rule moved in front of a Direct one"),
            (base, policy([m("com.example.A", .direct(interface: "en1"), id: "x"), a, b]), true,
             "a Direct rule on another interface added in front"),
            (base, policy([m("com.example.A", .direct(interface: "en1")), b]), true, "the interface changed"),
            (base, policy([a, b], teams: ["T1"]), true, "a declined team added"),
            (policy([a, b], teams: ["T1"]), base, false, "a declined team removed"),
            (policy([]), base, false, "Resume"),
        ]
        for (previous, next, shrinks, label) in table {
            XCTAssertEqual(next.shrinksClaims(from: previous), shrinks, label)
        }
    }

    func testClaimsNothing() {
        XCTAssertTrue(policy([]).claimsNothing)
        XCTAssertTrue(policy([m("a.b", .vpnDefault), m("c.d", .unsupported)]).claimsNothing)
        XCTAssertFalse(policy([m("a.b", .vpnDefault), m("c.d")]).claimsNothing)
    }

    func testMatcherKindFollowsTheDot() {
        XCTAssertEqual(AppMatcher.kind(of: "com.example.App"), .bundleID)
        XCTAssertEqual(AppMatcher.kind(of: "Example Helper"), .executableName)
    }
    // MARK: - Egress routes (R12)

    func testAPolicyWithoutEgressRoutesStillDecodes() throws {
        let old = Data(#"{"declinedTeams":[],"generation":7,"leaseSeconds":120,"matchers":[],"version":1}"#.utf8)
        guard case .policy(let p) = FlowPolicyMessage.decode(old) else { return XCTFail("an older app's push must still read") }
        XCTAssertEqual(p.generation, 7)
        XCTAssertEqual(p.egressRoutes, [:])
    }

    func testEgressRoutesRoundTripAndOnlyNewOrRestampedOnesCount() throws {
        let p = FlowPolicy(generation: 2, matchers: [], egressRoutes: ["en0": 2])
        guard case .policy(let back) = FlowPolicyMessage.decode(try FlowPolicyMessage.encode(p)) else { return XCTFail() }
        XCTAssertEqual(back, p)
        XCTAssertEqual(p.newEgressRoutes(since: FlowPolicy(generation: 1, matchers: [])), ["en0"])
        XCTAssertEqual(p.newEgressRoutes(since: nil), ["en0"])
        XCTAssertEqual(p.newEgressRoutes(since: FlowPolicy(generation: 1, matchers: [], egressRoutes: ["en0": 2])), [],
                       "the same route, renewed by a heartbeat")
        XCTAssertEqual(p.newEgressRoutes(since: FlowPolicy(generation: 1, matchers: [], egressRoutes: ["en0": 1])), ["en0"],
                       "put in again after it went missing (a helper restart)")
        XCTAssertEqual(FlowPolicy(generation: 3, matchers: []).newEgressRoutes(since: p), [])
    }
}
