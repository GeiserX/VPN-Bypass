import XCTest
@testable import VPNBypassPolicy

/// The extension's side of the conversation (design 3.3, 3.4 step 3, 3.5, 3.7, 3.8): the lease
/// watchdog, status requests, the reply, the counters and the egress choice.
final class FlowLedgerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func policy(generation: Int = 3, lease: Int = 120) -> FlowPolicy {
        FlowPolicy(generation: generation,
                   matchers: [AppMatcher(ruleID: "r1", kind: .bundleID, pattern: "com.example.App",
                                         egress: .direct(interface: "en0"))],
                   leaseSeconds: lease)
    }

    func received(_ p: FlowPolicy, at offset: TimeInterval = 0) -> FlowPolicyState {
        var s = FlowPolicyState()
        s.receive(.policy(p), at: t0.addingTimeInterval(offset))
        return s
    }

    // MARK: - The lease watchdog

    func testTheWatchdogDropsAPolicyOnceItsLeaseRunsOut() {
        var s = received(policy(lease: 120))
        XCTAssertFalse(s.expireLease(at: t0.addingTimeInterval(119)), "still live")
        XCTAssertNotNil(s.policy)
        XCTAssertTrue(s.expireLease(at: t0.addingTimeInterval(121)))
        XCTAssertNil(s.policy, "a dead app leaves no policy behind")
        XCTAssertEqual(s.leaseExpiries, 1)
        XCTAssertFalse(s.expireLease(at: t0.addingTimeInterval(200)), "counted once per lapse")
        XCTAssertEqual(s.leaseExpiries, 1)
        let facts = FlowFacts(signingIdentifier: "com.example.App", remote: .ipv4(ProtectedRanges.parse("93.184.216.34")!))
        XCTAssertEqual(FlowDecider.decide(facts, state: s, now: t0.addingTimeInterval(200)), .decline(.noPolicy))
    }

    func testAFreshPushStartsANewLeaseAndTheCountStays() {
        var s = received(policy())
        _ = s.expireLease(at: t0.addingTimeInterval(500))
        s.receive(.policy(policy(generation: 4)), at: t0.addingTimeInterval(600))
        XCTAssertTrue(s.isLeaseLive(at: t0.addingTimeInterval(601)))
        XCTAssertEqual(s.leaseExpiries, 1)
        XCTAssertTrue(s.expireLease(at: t0.addingTimeInterval(600 + 121)))
        XCTAssertEqual(s.leaseExpiries, 2)
    }

    func testTheWatchdogHonoursTheLeaseCap() {
        var s = received(policy(lease: 86_400))
        XCTAssertFalse(s.expireLease(at: t0.addingTimeInterval(TimeInterval(FlowPolicy.maxLeaseSeconds))))
        XCTAssertTrue(s.expireLease(at: t0.addingTimeInterval(TimeInterval(FlowPolicy.maxLeaseSeconds) + 1)))
    }

    func testNoPolicyIsNoLapse() {
        var s = FlowPolicyState()
        XCTAssertFalse(s.expireLease(at: t0))
        s.receive(.unknownVersion(2), at: t0)
        XCTAssertFalse(s.expireLease(at: t0.addingTimeInterval(1000)))
        XCTAssertEqual(s.leaseExpiries, 0)
    }

    func testAStoppedSessionDeclinesEveryFlowUntilTheNextPush() {
        var s = received(policy())
        let facts = FlowFacts(signingIdentifier: "com.example.App", remote: .ipv4(ProtectedRanges.parse("93.184.216.34")!))
        XCTAssertEqual(FlowDecider.decide(facts, state: s, now: t0.addingTimeInterval(1)),
                       .claim(ruleID: "r1", egress: .direct(interface: "en0")))
        s.sessionStopped()
        XCTAssertNil(s.policy)
        XCTAssertFalse(s.isLeaseLive(at: t0.addingTimeInterval(2)), "the old lease does not carry into a new session")
        XCTAssertEqual(FlowDecider.decide(facts, state: s, now: t0.addingTimeInterval(2)), .decline(.noPolicy))
        XCTAssertEqual(s.leaseExpiries, 0, "a stop is not a lapse")
        s.receive(.policy(policy(generation: 4)), at: t0.addingTimeInterval(3))
        XCTAssertTrue(s.isLeaseLive(at: t0.addingTimeInterval(4)))
    }

    // MARK: - Status requests

    func testAStatusRequestIsReadAsOne() {
        XCTAssertEqual(FlowPolicyMessage.decode(FlowPolicyMessage.statusRequest), .status)
        XCTAssertEqual(FlowPolicyMessage.decode(Data(#"{"request":"other"}"#.utf8)), .malformed)
    }

    func testAStatusRequestNeitherRenewsNorDropsThePolicy() {
        var s = received(policy(lease: 120))
        s.receive(.status, at: t0.addingTimeInterval(100))
        XCTAssertNotNil(s.policy)
        XCTAssertFalse(s.isLeaseLive(at: t0.addingTimeInterval(121)), "the lease still runs from the push")
    }

    func testAPolicyIsStillAPolicyAndAnOldVersionStillReportsItself() throws {
        let p = policy()
        XCTAssertEqual(FlowPolicyMessage.decode(try FlowPolicyMessage.encode(p)), .policy(p))
        XCTAssertEqual(FlowPolicyMessage.decode(Data(#"{"version":9,"generation":1}"#.utf8)), .unknownVersion(9))
    }

    // MARK: - The reply

    func testTheReplyEchoesTheLiveGenerationAndTheLapses() {
        var s = received(policy(generation: 8))
        var ledger = FlowLedger()
        let live = ledger.reply(state: s, now: t0.addingTimeInterval(10), extensionVersion: "6.1.0")
        XCTAssertTrue(live.confirms(policy(generation: 8)))
        XCTAssertEqual(live.extensionVersion, "6.1.0")
        _ = s.expireLease(at: t0.addingTimeInterval(130))
        ledger.record(.decline(.noPolicy))
        let lapsed = ledger.reply(state: s, now: t0.addingTimeInterval(130), extensionVersion: "6.1.0")
        XCTAssertEqual(lapsed.policyGeneration, 0)
        XCTAssertFalse(lapsed.policyLive)
        XCTAssertEqual(lapsed.leaseExpiries, 1)
        XCTAssertFalse(lapsed.confirms(policy(generation: 8)))
    }

    func testTheReplyReportsARejectedVersion() {
        var s = received(policy())
        s.receive(.unknownVersion(2), at: t0)
        let r = FlowLedger().reply(state: s, now: t0, extensionVersion: nil)
        XCTAssertEqual(r.rejectedVersion, 2)
        XCTAssertFalse(r.policyLive)
    }

    func testAReplyFromAnOlderExtensionStillReads() throws {
        // What the step 4 extension sends: no generation fields beyond these, no counters.
        let old = Data(#"{"policyGeneration":0,"policyLive":false,"leaseExpiries":0,"declined":{"noPolicy":6},"claimedByRule":{},"boundByRule":{}}"#.utf8)
        let r = try JSONDecoder().decode(FlowPolicyReply.self, from: old)
        XCTAssertEqual(r.declined, ["noPolicy": 6])
        XCTAssertEqual(r.counters, [:])
        XCTAssertNil(r.extensionVersion)
        XCTAssertEqual(try JSONDecoder().decode(FlowPolicyReply.self, from: Data("{}".utf8)), FlowPolicyReply())
    }

    func testTheReplyRoundTripsWithTheNewFields() throws {
        let r = FlowPolicyReply(policyGeneration: 2, policyLive: true, boundByInterface: ["physical": 1],
                                counters: ["claimed": 4], extensionVersion: "6.1.0")
        XCTAssertEqual(try JSONDecoder().decode(FlowPolicyReply.self, from: JSONEncoder().encode(r)), r)
    }

    // MARK: - Counters

    func testCountersLandOnTheRuleAndTheReason() {
        var l = FlowLedger()
        l.record(.claim(ruleID: "r1", egress: .direct(interface: nil)))
        l.record(.claim(ruleID: "r1", egress: .direct(interface: nil)))
        l.record(.decline(.bound, ruleID: "r1"), bound: .physical)
        l.record(.decline(.bound, ruleID: nil), bound: .tunnel)
        l.record(.decline(.bound, ruleID: nil))
        l.record(.decline(.noMatch))
        l.record(.decline(.noInterface, ruleID: "r1"), bound: .physical)
        XCTAssertEqual(l.claimedByRule, ["r1": 2])
        XCTAssertEqual(l.count(.claimed), 2)
        XCTAssertEqual(l.boundByRule, ["r1": 1])
        XCTAssertEqual(l.boundByInterface, ["physical": 1, "tunnel": 1, "unknown": 1],
                       "only bound flows count by interface")
        XCTAssertEqual(l.declined, ["bound": 3, "noMatch": 1, "noInterface": 1])
        l.add(.active, 1); l.add(.active, -1); l.add(.bytesDown, 1000)
        XCTAssertEqual(l.count(.active), 0)
        XCTAssertEqual(l.count(.bytesDown), 1000)
    }

    func testTheReplyCarriesNoNames() throws {
        var l = FlowLedger()
        l.record(.claim(ruleID: "bypass-app-0", egress: .direct(interface: "en0")))
        l.record(.decline(.bound, ruleID: "bypass-app-0"), bound: .tunnel)
        let text = String(decoding: try JSONEncoder().encode(l.reply(state: received(policy()), now: t0,
                                                                     extensionVersion: "6.1.0")), as: UTF8.self)
        XCTAssertFalse(text.contains("com.example"), text)
        XCTAssertFalse(text.contains("en0"), text)
    }

    // MARK: - Interfaces

    func testBoundInterfaceKinds() {
        XCTAssertEqual(BoundInterface.classify(name: "en0", kind: .wifi), .physical)
        XCTAssertEqual(BoundInterface.classify(name: "en8", kind: .wired), .physical)
        XCTAssertEqual(BoundInterface.classify(name: "utun4", kind: .other), .tunnel)
        XCTAssertEqual(BoundInterface.classify(name: "ipsec0", kind: .other), .tunnel)
        XCTAssertEqual(BoundInterface.classify(name: "utun3", kind: .wired), .tunnel, "the name wins")
        XCTAssertEqual(BoundInterface.classify(name: "lo0", kind: .loopback), .other)
        XCTAssertEqual(BoundInterface.classify(name: "bridge0", kind: .other), .other)
        XCTAssertEqual(BoundInterface.classify(name: nil, kind: nil), .unknown)
        XCTAssertEqual(BoundInterface.classify(name: "", kind: .wifi), .unknown)
    }

    func testTheEgressIsThePolicysInterfaceOrNone() {
        XCTAssertEqual(EgressInterface.pick(named: "en1", from: ["en0", "en1"]), "en1")
        XCTAssertNil(EgressInterface.pick(named: "en7", from: ["en0", "en1"]),
                     "a gone interface declines, never another one")
        XCTAssertEqual(EgressInterface.pick(named: nil, from: ["en1", "en0"]), "en1", "most preferred")
        XCTAssertEqual(EgressInterface.pick(named: "", from: ["en1", "en0"]), "en1")
        XCTAssertNil(EgressInterface.pick(named: nil, from: []))
    }

    // MARK: - Egress health

    func testRepeatedEgressFailuresStopClaimsForACooldownThenOneRetry() {
        var h = EgressHealth()
        XCTAssertTrue(h.isUsable("en0", at: t0))
        h.record("en0", succeeded: false, at: t0)
        XCTAssertTrue(h.isUsable("en0", at: t0), "one failure is not a pattern")
        h.record("en0", succeeded: false, at: t0.addingTimeInterval(1))
        XCTAssertFalse(h.isUsable("en0", at: t0.addingTimeInterval(2)), "declined: the app goes through the VPN")
        XCTAssertTrue(h.isUsable("en1", at: t0.addingTimeInterval(2)), "per interface")
        let retry = t0.addingTimeInterval(1 + EgressHealth.cooldown)
        XCTAssertTrue(h.isUsable("en0", at: retry))
        h.claimed("en0", at: retry)
        XCTAssertFalse(h.isUsable("en0", at: retry.addingTimeInterval(1)), "only one claim tests it")
        h.record("en0", succeeded: true, at: retry.addingTimeInterval(1))
        XCTAssertTrue(h.isUsable("en0", at: retry.addingTimeInterval(1)), "a success clears it")
    }

    func testAClaimOnAHealthyInterfaceChangesNothing() {
        var h = EgressHealth()
        h.record("en0", succeeded: false, at: t0)
        h.claimed("en0", at: t0.addingTimeInterval(1))
        h.record("en0", succeeded: false, at: t0.addingTimeInterval(2))
        XCTAssertFalse(h.isUsable("en0", at: t0.addingTimeInterval(3)))
        XCTAssertTrue(h.isUsable("en0", at: t0.addingTimeInterval(2 + EgressHealth.cooldown)))
    }

    func testTheEchoTimeoutIsWellInsideTheLease() {
        XCTAssertGreaterThan(FlowPolicy.echoTimeoutSeconds, 0)
        XCTAssertLessThan(FlowPolicy.echoTimeoutSeconds * 4, FlowPolicy.defaultLeaseSeconds)
    }
}
