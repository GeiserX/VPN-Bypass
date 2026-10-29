// WildcardTests.swift
// Always-on wildcard domains: the name rules, the DNS reader and writer the helper's forwarder
// uses, the safety guard and limiter, the XPC payloads, the plan, the ledger, the two system
// outputs the engine reads, and how the app keeps learned routes through an apply.

import XCTest
@testable import VPNBypassCore

// MARK: - Names

final class WildcardDomainTests: XCTestCase {

    func testSuffixNormalises() {
        XCTAssertEqual(WildcardDomain.suffix(of: "*.Example.COM."), "example.com")
        XCTAssertEqual(WildcardDomain.suffix(of: "*.us5.datadoghq.com"), "us5.datadoghq.com")
        XCTAssertNil(WildcardDomain.suffix(of: "example.com"), "not a wildcard")
        XCTAssertNil(WildcardDomain.suffix(of: "*.com"), "a whole top-level domain is refused")
        XCTAssertNil(WildcardDomain.suffix(of: "*..example.com"))
        XCTAssertNil(WildcardDomain.suffix(of: "*.exa mple.com"))
        XCTAssertNil(WildcardDomain.suffix(of: "*.-bad.example.com"))
        XCTAssertNil(WildcardDomain.normalizedSuffix("../etc/passwd"), "a suffix can never name a path")
    }

    func testMatchesTheApexAndEveryDepth() {
        let s = "example.com"
        XCTAssertTrue(WildcardDomain.matches("example.com", suffix: s), "the apex")
        XCTAssertTrue(WildcardDomain.matches("api.example.com", suffix: s))
        XCTAssertTrue(WildcardDomain.matches("a.b.c.d.example.com", suffix: s), "any depth")
        XCTAssertTrue(WildcardDomain.matches("API.Example.COM.", suffix: s), "case and the trailing dot")
        XCTAssertFalse(WildcardDomain.matches("notexample.com", suffix: s), "a label ends at a dot")
        XCTAssertFalse(WildcardDomain.matches("example.com.evil.net", suffix: s))
        XCTAssertFalse(WildcardDomain.matches("com", suffix: s))
    }

    func testMostSpecificWins() {
        let suffixes = ["example.com", "eu.example.com"]
        XCTAssertEqual(WildcardDomain.mostSpecific(for: "x.eu.example.com", among: suffixes), "eu.example.com")
        XCTAssertEqual(WildcardDomain.mostSpecific(for: "x.us.example.com", among: suffixes), "example.com")
        XCTAssertNil(WildcardDomain.mostSpecific(for: "example.org", among: suffixes))
    }
}

// MARK: - Cleaning what the user types

@MainActor
final class WildcardInputTests: XCTestCase {
    private let rm = RouteManager.shared

    func testCleanDomainKeepsTheWildcard() {
        XCTAssertEqual(rm.cleanDomain("*.Example.com"), "*.example.com")
        XCTAssertEqual(rm.cleanDomain("  *.us5.datadoghq.com  "), "*.us5.datadoghq.com")
        XCTAssertEqual(rm.cleanDomain("https://*.example.com/path?q=1"), "*.example.com")
        XCTAssertEqual(rm.cleanDomain("*.example.com:443"), "*.example.com")
    }

    func testCleanDomainRefusesAWildcardItCannotServe() {
        XCTAssertEqual(rm.cleanDomain("*.com"), "")
        XCTAssertEqual(rm.cleanDomain("*.*.example.com"), "")
        XCTAssertEqual(rm.cleanDomain("*."), "")
    }

    func testAStarInsideANameIsStillStripped() {
        XCTAssertEqual(rm.cleanDomain("ex*ample.com"), "example.com")
    }

    func testBothListsTakeAWildcard() {
        for list in [DomainList.bypass, .vpnOnly] {
            guard case .success(let checked) = rm.checkDomainInput("*.Example.com", list: list) else {
                return XCTFail("\(list) refused a wildcard")
            }
            XCTAssertEqual(checked, CheckedDomainInput(value: "*.example.com", isCIDR: false))
        }
        guard case .failure(.empty) = rm.checkDomainInput("*.com", list: .bypass) else {
            return XCTFail("*.com must be refused")
        }
    }

    func testAnEntryMadeFromAWildcardIsFlagged() {
        XCTAssertTrue(DomainEntry(domain: "*.example.com").isWildcard)
        XCTAssertFalse(DomainEntry(domain: "example.com").isWildcard)
    }

    func testAWildcardIsNeverResolvedByAService() {
        let service = ServiceEntry(id: "s", name: "S", enabled: true,
                                   domains: ["a.example.com", "*.example.net"], ipRanges: [])
        XCTAssertEqual(service.resolvableDomains, ["a.example.com"])
    }

    func testAddedMessageSaysHowAWildcardWorks() {
        let added = AddedDomain(entry: DomainEntry(domain: "*.example.com"), list: .bypass, typed: "*.example.com")
        XCTAssertTrue(added.message.contains("looked up"), added.message)
    }
}

// MARK: - Config

final class WildcardConfigTests: XCTestCase {

    func testWildcardEntrySurvivesARoundTrip() throws {
        var cfg = Config()
        cfg.domains = [DomainEntry(domain: "*.example.com")]
        cfg.inverseDomains = [DomainEntry(domain: "*.corp.example.net")]
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(decoded.domains.map(\.domain), ["*.example.com"])
        XCTAssertEqual(decoded.domains.map(\.isWildcard), [true])
        XCTAssertEqual(decoded.inverseDomains.map(\.isWildcard), [true])
    }

    /// An entry written by a build that saved "*.x" without setting the flag is still a wildcard.
    func testAWildcardWithoutItsFlagDecodesAsOne() throws {
        let json = #"{"id":"6F1C4D2E-0E8A-4E7B-9C0B-2B8F1A1D5E10","domain":"*.example.com","enabled":true,"isCIDR":false}"#
        let entry = try JSONDecoder().decode(DomainEntry.self, from: Data(json.utf8))
        XCTAssertTrue(entry.isWildcard)
    }

    func testCustomModeTurnsAWildcardIntoASuffixRule() {
        let derived = Config.derive(domains: [DomainEntry(domain: "*.example.com"), DomainEntry(domain: "a.example.org")],
                                    services: [], mode: .bypass, inverseDomains: [], proxy: ProxyConfig())
        XCTAssertEqual(derived.rules.map(\.matchType), [.suffix, .domain])
        XCTAssertEqual(derived.rules.first?.pattern, "example.com")
        XCTAssertNotNil(RuleResolver.route(forDomain: "deep.api.example.com", rules: derived.rules,
                                           routes: derived.routes, defaultRouteId: nil))
    }
}

// MARK: - DNS messages

final class DNSWireTests: XCTestCase {

    private func labels(_ name: String) -> [[UInt8]] {
        name.split(separator: ".").map { Array($0.utf8) }
    }

    private func query(_ name: String, type: UInt16, id: UInt16 = 0x1234, opt: Bool = false) -> DNSWire.Message {
        let additional = opt ? [DNSWire.Record(labels: [], type: DNSWire.typeOPT, rclass: 1232, ttl: 0, data: [])] : []
        return DNSWire.Message(id: id, flags: 0x0100, questions: [.init(labels: labels(name), type: type, qclass: 1)],
                               answers: [], authority: [], additional: additional)
    }

    /// A real-shaped answer, compressed as servers send it: question at 12, a CNAME whose owner
    /// points at the question, an A record whose owner points into the CNAME's data.
    private func compressedAnswer() -> [UInt8] {
        var b: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 3, 0, 0, 0, 0]
        // question: app.example.com A IN, at offset 12
        b += [3] + Array("app".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        // CNAME: owner -> 12, ttl 3600, data "cdn" + pointer to "example.com" at 16
        b += [0xC0, 12, 0, 5, 0, 1, 0, 0, 0x0E, 0x10, 0, 6] + [3] + Array("cdn".utf8) + [0xC0, 16]
        let cnameData = b.count - 6
        // A: owner -> CNAME's data, ttl 86400, 34.149.66.165
        b += [0xC0, UInt8(cnameData), 0, 1, 0, 1, 0, 1, 0x51, 0x80, 0, 4, 34, 149, 66, 165]
        // AAAA for the same owner
        b += [0xC0, UInt8(cnameData), 0, 28, 0, 1, 0, 0, 0, 60, 0, 16] + [UInt8](repeating: 1, count: 16)
        return b
    }

    func testQueryRoundTrips() throws {
        let q = query("Foo.Example.com", type: DNSWire.typeA, opt: true)
        let bytes = try XCTUnwrap(DNSWire.encode(q))
        let parsed = try XCTUnwrap(DNSWire.parse(bytes))
        XCTAssertEqual(parsed, q)
        XCTAssertEqual(parsed.questions.first?.name, "foo.example.com")
        XCTAssertEqual(parsed.maxUDPSize, 1232)
        XCTAssertEqual(DNSWire.parse(DNSWire.encode(query("a.b", type: 1))!)?.maxUDPSize, 512)
    }

    func testCompressedAnswerIsExpanded() throws {
        let m = try XCTUnwrap(DNSWire.parse(compressedAnswer()))
        XCTAssertEqual(m.answers.map(\.name), ["app.example.com", "cdn.example.com", "cdn.example.com"])
        // The CNAME's data no longer points anywhere: "cdn.example.com" in full.
        XCTAssertEqual(m.answers[0].data, [3] + Array("cdn".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0])
        XCTAssertEqual(DNSWire.addresses(in: m), ["34.149.66.165"])
        // And what we write reads back the same.
        XCTAssertEqual(DNSWire.parse(try XCTUnwrap(DNSWire.encode(m))), m)
    }

    func testRewriteDropsAAAAAndCapsTTLButLeavesOPT() throws {
        var m = try XCTUnwrap(DNSWire.parse(compressedAnswer()))
        m.additional = [DNSWire.Record(labels: [], type: DNSWire.typeOPT, rclass: 1232, ttl: 0x8000, data: [])]
        let out = DNSWire.rewriteForWildcard(m, ttlCap: 300, keepAddress: { _ in true })
        XCTAssertEqual(out.answers.map(\.type), [DNSWire.typeCNAME, DNSWire.typeA])
        XCTAssertEqual(out.answers.map(\.ttl), [300, 300])
        XCTAssertEqual(out.additional.first?.ttl, 0x8000, "OPT's TTL holds EDNS flags")
        let short = DNSWire.rewriteForWildcard(m, ttlCap: 7200, keepAddress: { _ in true })
        XCTAssertEqual(short.answers.first?.ttl, 3600, "a TTL under the cap is left as it is")
    }

    private func httpsData(v4: [[UInt8]], v6: Bool) -> [UInt8] {
        var d: [UInt8] = [0, 1, 0]                       // priority 1, target "."
        d += [0, 1, 0, 3, 2] + Array("h2".utf8)          // alpn = h2
        if !v4.isEmpty { d += [0, 4, 0, UInt8(v4.count * 4)] + v4.flatMap { $0 } }
        if v6 { d += [0, 6, 0, 16] + [UInt8](repeating: 0x20, count: 16) }
        return d
    }

    func testHTTPSLosesIPv6HintAndKeepsOnlyRoutedIPv4Hints() throws {
        let record = DNSWire.Record(labels: labels("app.example.com"), type: DNSWire.typeHTTPS, rclass: 1, ttl: 600,
                                    data: httpsData(v4: [[34, 1, 1, 1], [34, 2, 2, 2]], v6: true))
        let m = DNSWire.Message(id: 1, flags: 0x8180, questions: [], answers: [record], authority: [], additional: [])
        XCTAssertEqual(DNSWire.addresses(in: m), ["34.1.1.1", "34.2.2.2"])

        let out = DNSWire.rewriteForWildcard(m, ttlCap: 300, keepAddress: { $0 == "34.1.1.1" })
        XCTAssertEqual(out.answers.first?.data, httpsData(v4: [[34, 1, 1, 1]], v6: false))

        let none = DNSWire.rewriteForWildcard(m, ttlCap: 300, keepAddress: { _ in false })
        XCTAssertEqual(none.answers.first?.data, httpsData(v4: [], v6: false), "the hint key goes when no address is left")
    }

    func testAnUnreadableHTTPSRecordIsDropped() {
        let record = DNSWire.Record(labels: labels("a.example.com"), type: DNSWire.typeHTTPS, rclass: 1, ttl: 60,
                                    data: [0, 1, 0, 0, 6, 0, 16, 1])   // ipv6hint says 16 bytes, has 1
        let m = DNSWire.Message(id: 1, flags: 0x8180, questions: [], answers: [record], authority: [], additional: [])
        XCTAssertTrue(DNSWire.rewriteForWildcard(m, ttlCap: 300, keepAddress: { _ in true }).answers.isEmpty)
    }

    func testMalformedMessagesAreRefused() {
        XCTAssertNil(DNSWire.parse([0, 1, 2]), "shorter than a header")
        // A pointer that points forward (a loop in disguise).
        var forward: [UInt8] = [0, 1, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        forward += [0xC0, 14, 0, 0, 1, 0, 1]
        XCTAssertNil(DNSWire.parse(forward))
        // A pointer to itself.
        var selfLoop: [UInt8] = [0, 1, 0x01, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        selfLoop += [0xC0, 12, 0, 1, 0, 1]
        XCTAssertNil(DNSWire.parse(selfLoop))
        // Counts the message cannot hold.
        XCTAssertNil(DNSWire.parse([0, 1, 0x81, 0x80, 0, 1, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 1, 0, 1]))
        // Record data that runs past the end.
        var long = compressedAnswer()
        long.removeLast(4)
        XCTAssertNil(DNSWire.parse(long))
    }

    func testLocalRepliesAndMatching() throws {
        let q = query("x.example.com", type: DNSWire.typeAAAA)
        let noData = try XCTUnwrap(DNSWire.parse(DNSWire.reply(to: q, rcode: DNSWire.rcodeNoError)))
        XCTAssertTrue(noData.isResponse)
        XCTAssertEqual(noData.rcode, 0)
        XCTAssertTrue(noData.answers.isEmpty)
        XCTAssertEqual(noData.id, q.id)
        XCTAssertEqual(noData.flags & 0x0100, 0x0100, "RD is copied")
        XCTAssertTrue(DNSWire.answers(noData, query: q))

        let refused = try XCTUnwrap(DNSWire.parse(DNSWire.reply(to: q, rcode: DNSWire.rcodeRefused)))
        XCTAssertEqual(refused.rcode, 5)

        var other = noData
        other.id = 0x9999
        XCTAssertFalse(DNSWire.answers(other, query: q), "another id is not our answer")
        XCTAssertFalse(DNSWire.answers(noData, query: query("y.example.com", type: DNSWire.typeAAAA)))

        let full = try XCTUnwrap(DNSWire.parse(compressedAnswer()))
        let cut = try XCTUnwrap(DNSWire.parse(DNSWire.truncated(full)))
        XCTAssertTrue(cut.isTruncated)
        XCTAssertTrue(cut.answers.isEmpty)
        XCTAssertEqual(cut.questions, full.questions)
    }
}

// MARK: - Safety guard and limiter

final class WildcardSafetyGuardTests: XCTestCase {

    func testRefusesEverythingThatIsNotPublic() {
        let g = WildcardSafetyGuard()
        for ip in ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.10.1", "100.64.0.1", "100.100.100.100",
                   "127.0.0.1", "169.254.1.1", "224.0.0.251", "239.255.255.250", "240.0.0.1", "255.255.255.255",
                   "0.0.0.0", "198.18.0.1", "203.0.113.7", "not-an-ip", "1.2.3",
                   "192.0.0.8", "192.0.2.1", "198.51.100.1", "198.19.255.1", "100.127.255.255"] {
            XCTAssertEqual(g.refusal(for: ip), .notPublic, ip)
        }
    }

    func testPublicAddressesPass() {
        let g = WildcardSafetyGuard()
        for ip in ["34.149.66.165", "1.1.1.1", "172.32.0.1", "100.128.0.1", "8.8.8.8", "172.15.255.255", "100.63.255.255"] {
            XCTAssertNil(g.refusal(for: ip), ip)
        }
    }

    func testRefusesTheExcludedHostsAndRanges() {
        let g = WildcardSafetyGuard(excludedHosts: ["1.1.1.1", "34.10.10.10"], excludedRanges: ["34.200.0.0/16"])
        XCTAssertEqual(g.refusal(for: "1.1.1.1"), .excludedHost)
        XCTAssertEqual(g.refusal(for: "34.10.10.10"), .excludedHost)
        XCTAssertEqual(g.refusal(for: "34.200.7.7"), .insideExcludedRange)
        XCTAssertNil(g.refusal(for: "34.201.7.7"))
    }

    /// A wildcard into a tunnel routes the company's private addresses, but never one on a
    /// network the Mac is attached to by another interface, nor loopback or link-local.
    func testATunnelWildcardMayLearnPrivateAddresses() {
        var g = WildcardSafetyGuard(excludedHosts: ["10.0.0.53"])
        g.connectedNetworks = [("en0", 0xC0A8_0A00, 0xFFFF_FF00), ("utun4", 0x0A08_0000, 0xFFFF_0000)]
        let tunnel = WildcardSpec(suffix: "corp.example.com", gateway: "iface:utun4", upstream: ["10.0.0.53"],
                                  interface: "utun4", intoTunnel: true)
        let around = WildcardSpec(suffix: "example.com", gateway: "192.168.10.1", upstream: ["1.1.1.1"], interface: "en0")
        XCTAssertNil(g.refusal(for: "10.20.30.40", spec: tunnel))
        XCTAssertNil(g.refusal(for: "172.16.5.5", spec: tunnel))
        XCTAssertNil(g.refusal(for: "10.8.1.1", spec: tunnel), "the tunnel's own network")
        XCTAssertEqual(g.refusal(for: "192.168.10.20", spec: tunnel), .connectedNetwork)
        XCTAssertEqual(g.refusal(for: "127.0.0.1", spec: tunnel), .notPublic)
        XCTAssertEqual(g.refusal(for: "169.254.1.1", spec: tunnel), .notPublic)
        XCTAssertEqual(g.refusal(for: "224.0.0.251", spec: tunnel), .notPublic)
        XCTAssertEqual(g.refusal(for: "10.0.0.53", spec: tunnel), .excludedHost)
        XCTAssertEqual(g.refusal(for: "10.20.30.40", spec: around), .notPublic)
        XCTAssertEqual(g.refusal(for: "10.20.30.40"), .notPublic, "no spec is the strict rule")
    }

    func testTheGuardCrossesXPCIntact() {
        let g = WildcardSafetyGuard(excludedHosts: ["1.1.1.1"], excludedRanges: ["34.200.0.0/16", "0.0.0.0/0"])
        XCTAssertEqual(WildcardSafetyGuard(dictionary: g.dictionary), g)
    }

    func testLimiterCapsNewAddressesPerMinuteButNotKnownOnes() {
        var limiter = WildcardLearnLimiter()
        let t0: UInt64 = 1_000_000_000_000
        for i in 0..<WildcardLearnLimiter.maxNewPerMinute {
            XCTAssertTrue(limiter.admit("34.0.\(i / 256).\(i % 256)", suffix: "example.com", nowNS: t0))
        }
        XCTAssertFalse(limiter.admit("35.0.0.1", suffix: "example.com", nowNS: t0), "over the minute's cap")
        XCTAssertTrue(limiter.admit("34.0.0.0", suffix: "example.com", nowNS: t0), "a known address always passes")
        XCTAssertTrue(limiter.admit("35.0.0.1", suffix: "other.com", nowNS: t0), "the cap is per wildcard")
        XCTAssertTrue(limiter.admit("35.0.0.1", suffix: "example.com", nowNS: t0 + 61_000_000_000), "a minute later")
    }

    func testLimiterCapsEachWildcardInTotal() {
        var limiter = WildcardLearnLimiter()
        var now: UInt64 = 1_000_000_000_000
        var admitted = 0
        for i in 0..<(WildcardLearnLimiter.maxPerWildcard + 10) {
            if i % WildcardLearnLimiter.maxNewPerMinute == 0 { now += 61_000_000_000 }
            if limiter.admit("34.\(i / 65536).\(i / 256 % 256).\(i % 256)", suffix: "example.com", nowNS: now) { admitted += 1 }
        }
        XCTAssertEqual(admitted, WildcardLearnLimiter.maxPerWildcard)
        XCTAssertFalse(limiter.admit("37.0.0.1", suffix: "example.com", nowNS: now + 61_000_000_000), "full")
        // A day later the addresses nobody looked up again are forgotten; one in use stays.
        let later = now + WildcardLearnLimiter.forgetAfterNS + 61_000_000_000
        XCTAssertTrue(limiter.admit("34.0.0.0", suffix: "example.com", nowNS: later - 1_000_000_000))
        XCTAssertTrue(limiter.admit("37.0.0.1", suffix: "example.com", nowNS: later), "room again after a day")
        limiter.keep(only: [])
        XCTAssertTrue(limiter.admit("36.0.0.1", suffix: "example.com", nowNS: now), "forgotten with its wildcard")
    }
}

// MARK: - Payloads and resolver files

final class WildcardPayloadTests: XCTestCase {

    func testSpecRoundTripsAndIsChecked() {
        let spec = WildcardSpec(suffix: "us5.datadoghq.com", gateway: "192.168.10.1", upstream: ["192.168.10.1", "1.1.1.1"], interface: "en0")
        XCTAssertEqual(WildcardSpec(dictionary: spec.dictionary), spec)
        let iface = WildcardSpec(suffix: "corp.example.net", gateway: "iface:utun4", upstream: ["10.0.0.53"], interface: "utun4")
        XCTAssertEqual(WildcardSpec(dictionary: iface.dictionary), iface)
        let tunnel = WildcardSpec(suffix: "corp.example.net", gateway: "iface:utun4", upstream: ["10.0.0.53"],
                                  interface: "utun4", intoTunnel: true)
        XCTAssertEqual(WildcardSpec(dictionary: tunnel.dictionary), tunnel)
        XCTAssertNotEqual(WildcardSpec(dictionary: tunnel.dictionary), iface)

        var d = spec.dictionary
        d["suffix"] = "../../etc"
        XCTAssertNil(WildcardSpec(dictionary: d))
        d = spec.dictionary
        d["upstream"] = "127.0.0.1"
        XCTAssertNil(WildcardSpec(dictionary: d), "an upstream on loopback would loop back into the forwarder")
        d = spec.dictionary
        d["upstream"] = ""
        XCTAssertNil(WildcardSpec(dictionary: d))
        d = spec.dictionary
        d["gateway"] = "iface:utun4; rm -rf /"
        XCTAssertNil(WildcardSpec(dictionary: d))
        d = spec.dictionary
        d["interface"] = "en0/x"
        XCTAssertNil(WildcardSpec(dictionary: d))
    }

    func testLearnedRouteRoundTrips() {
        let r = LearnedWildcardRoute(ip: "34.149.66.165", suffix: "us5.datadoghq.com", gateway: "192.168.10.1")
        XCTAssertEqual(LearnedWildcardRoute(dictionary: r.dictionary), r)
        XCTAssertNil(LearnedWildcardRoute(dictionary: ["ip": "nope", "suffix": "a.b", "gateway": "1.1.1.1"]))
    }

    func testResolverFileIsMarkedAndPointsAtTheForwarder() {
        let text = WildcardResolverFile.contents
        XCTAssertTrue(WildcardResolverFile.isOurs(text))
        XCTAssertTrue(text.contains("\nnameserver 127.0.0.1\n"))
        XCTAssertTrue(text.contains("\nport 53530\n"))
        XCTAssertFalse(WildcardResolverFile.isOurs("nameserver 10.0.0.1\n"), "someone else's file")
        XCTAssertFalse(WildcardResolverFile.isOurs("nameserver 1.1.1.1\n# VPN-BYPASS-MANAGED wildcard resolver"),
                       "the marker counts only as the first line")
    }

    /// Our files come and go with the wanted list; someone else's file, a symlink and a stray
    /// file without the marker are never touched.
    func testResolverFileSyncTouchesOnlyOurFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wildcard-resolver-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let ours = WildcardResolverFile.contents
        try "nameserver 10.0.0.1\n".write(toFile: dir + "/corp.example.com", atomically: true, encoding: .utf8)
        try ours.write(toFile: dir + "/gone.example.com", atomically: true, encoding: .utf8)
        try (WildcardResolverFile.marker + " old\n").write(toFile: dir + "/stale.example.com", atomically: true, encoding: .utf8)
        let target = dir + "-target"
        try ours.write(toFile: target, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: target) }
        try fm.createSymbolicLink(atPath: dir + "/link.example.com", withDestinationPath: target)

        let result = WildcardResolverFile.sync(
            wanted: ["new.example.com", "stale.example.com", "corp.example.com", "link.example.com"], in: dir)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.foreign, ["corp.example.com", "link.example.com"])
        XCTAssertEqual(try String(contentsOfFile: dir + "/new.example.com", encoding: .utf8), ours)
        XCTAssertEqual(try String(contentsOfFile: dir + "/stale.example.com", encoding: .utf8), ours, "an old version of ours is rewritten")
        XCTAssertEqual(try String(contentsOfFile: dir + "/corp.example.com", encoding: .utf8), "nameserver 10.0.0.1\n")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: dir + "/link.example.com"), "the symlink stays")
        XCTAssertFalse(fm.fileExists(atPath: dir + "/gone.example.com"), "ours, no longer wanted")

        let none = WildcardResolverFile.sync(wanted: [], in: dir)
        XCTAssertTrue(none.changed)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: dir)), ["corp.example.com", "link.example.com"],
                       "every file of ours goes, and nothing else")
        XCTAssertTrue(fm.fileExists(atPath: target), "a symlink to a file of ours is not followed")
        XCTAssertFalse(WildcardResolverFile.sync(wanted: [], in: dir).changed)
    }

    /// The helper compiles these from the Makefile's file list, not from Package.swift.
    func testTheHelperBuildIncludesTheForwarder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        for file in ["Sources/VPNBypassCore/WildcardDNS.swift", "Helper/WildcardForwarder.swift"] {
            XCTAssertEqual(makefile.components(separatedBy: file).count - 1, 2, "\(file) must be in both helper builds")
        }
    }
}

// MARK: - Plan

final class WildcardPlannerTests: XCTestCase {

    private let env = WildcardPlanner.Environment(
        localGateway: "192.168.10.1", physicalInterface: "en0", physicalDNS: ["192.168.10.1"],
        vpnGateway: "10.20.0.1", vpnInterface: "utun4", vpnDNS: ["10.20.0.53"])

    private func bypassConfig() -> Config {
        var c = Config()
        c.routingMode = .bypass
        c.domains = [DomainEntry(domain: "*.us5.datadoghq.com"), DomainEntry(domain: "plain.example.com"),
                     DomainEntry(domain: "*.off.example.com", enabled: false)]
        c.services = [ServiceEntry(id: "s", name: "S", enabled: true, domains: ["*.svc.example.com", "*.us5.datadoghq.com"], ipRanges: []),
                      ServiceEntry(id: "t", name: "T", enabled: false, domains: ["*.disabled.example.com"], ipRanges: [])]
        c.inverseDomains = [DomainEntry(domain: "*.corp.example.net")]
        return c
    }

    func testBypassServesItsListAndItsServicesAroundTheVPN() {
        let c = bypassConfig()
        XCTAssertEqual(WildcardPlanner.configuredSuffixes(c), ["us5.datadoghq.com", "svc.example.com"])
        let plan = WildcardPlanner.plan(c, env: env)
        XCTAssertEqual(plan.specs, [
            WildcardSpec(suffix: "us5.datadoghq.com", gateway: "192.168.10.1", upstream: ["192.168.10.1"], interface: "en0"),
            WildcardSpec(suffix: "svc.example.com", gateway: "192.168.10.1", upstream: ["192.168.10.1"], interface: "en0"),
        ])
    }

    func testVPNOnlyServesItsListThroughTheTunnel() {
        var c = bypassConfig()
        c.routingMode = .vpnOnly
        XCTAssertEqual(WildcardPlanner.plan(c, env: env).specs, [
            WildcardSpec(suffix: "corp.example.net", gateway: "10.20.0.1", upstream: ["10.20.0.53"], interface: "utun4", intoTunnel: true),
        ])
    }

    func testAWildcardWithNoDNSServerOrRouteIsSkippedAndSaysWhy() {
        var noDNS = env
        noDNS.physicalDNS = ["127.0.0.1", "https://dns.example/dns-query"]
        let plan = WildcardPlanner.plan(bypassConfig(), env: noDNS)
        XCTAssertTrue(plan.specs.isEmpty)
        XCTAssertEqual(Set(plan.skipped.keys), ["us5.datadoghq.com", "svc.example.com"])

        var c = bypassConfig()
        c.routingMode = .vpnOnly
        var noVPN = env
        noVPN.vpnGateway = nil
        XCTAssertEqual(WildcardPlanner.plan(c, env: noVPN).skipped["corp.example.net"], "its route is not up")
    }

    func testCustomModeFollowsTheFirstMatchingRuleAndSkipsProxies() {
        var c = Config()
        c.routingMode = .custom
        c.schemaVersion = 2
        let direct = Route(name: "Direct", egress: .direct)
        let proxy = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "p", proxyPort: 1080)
        let primary = Route(name: "VPN", egress: .vpnDefault)
        let pinned = Route(name: "Lab", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .interface, interfaceName: "utun7"))
        c.routes = [direct, proxy, primary, pinned]
        c.rules = [
            Rule(matchType: .suffix, pattern: "proxied.example.com", routeId: proxy.id, order: 0),
            Rule(matchType: .suffix, pattern: "*.direct.example.com", routeId: direct.id, order: 1),
            Rule(matchType: .suffix, pattern: "direct.example.com", routeId: pinned.id, order: 2),  // shadowed by order 1
            Rule(matchType: .suffix, pattern: "lab.example.com", routeId: pinned.id, order: 3),
            Rule(matchType: .suffix, pattern: "vpn.example.com", routeId: primary.id, order: 4),
        ]
        var e = env
        e.pinnedGateway = { $0.id == pinned.id ? "iface:utun7" : nil }
        e.dnsForInterface = { $0 == "utun7" ? ["10.7.0.53"] : [] }
        XCTAssertEqual(WildcardPlanner.configuredSuffixes(c), ["direct.example.com", "lab.example.com"])
        XCTAssertEqual(WildcardPlanner.plan(c, env: e).specs, [
            WildcardSpec(suffix: "direct.example.com", gateway: "192.168.10.1", upstream: ["192.168.10.1"], interface: "en0"),
            WildcardSpec(suffix: "lab.example.com", gateway: "iface:utun7", upstream: ["10.7.0.53"], interface: "utun7", intoTunnel: true),
        ])
    }

    func testTheGuardExcludesOurGatewaysDNSServersAndVPNOnlyRanges() {
        var c = bypassConfig()
        c.inverseDomains.append(DomainEntry(domain: "34.200.0.0/16", isCIDR: true))
        let plan = WildcardPlanner.plan(c, env: env)
        let g = WildcardPlanner.safetyGuard(c, env: env, specs: plan.specs)
        XCTAssertEqual(g.refusal(for: "34.200.1.1"), .insideExcludedRange)
        var publicDNS = env
        publicDNS.physicalDNS = ["9.9.9.9"]
        let g2 = WildcardPlanner.safetyGuard(c, env: publicDNS, specs: WildcardPlanner.plan(c, env: publicDNS).specs)
        XCTAssertEqual(g2.refusal(for: "9.9.9.9"), .excludedHost, "a zone must not move our own DNS server")
    }
}

// MARK: - Ledger

final class WildcardLedgerTests: XCTestCase {

    func testExpiresAfterADayUnseenUnlessConnected() {
        var ledger = WildcardLedger()
        let now = Date()
        ledger.record("34.1.1.1", suffix: "example.com", at: now.addingTimeInterval(-25 * 3600))
        ledger.record("34.2.2.2", suffix: "example.com", at: now.addingTimeInterval(-25 * 3600))
        ledger.record("34.3.3.3", suffix: "example.com", at: now.addingTimeInterval(-23 * 3600))
        let expired = ledger.expired(at: now, openPeers: ["34.2.2.2"])
        XCTAssertEqual(expired.map(\.ip), ["34.1.1.1"], "a day unseen expires; an open connection or a recent lookup keeps it")

        ledger.record("34.1.1.1", suffix: "example.com", at: now)
        XCTAssertTrue(ledger.expired(at: now, openPeers: []).map(\.ip) == ["34.2.2.2"], "a new lookup restarts the clock")
    }

    func testForgetsWildcardsThatAreGone() {
        var ledger = WildcardLedger()
        ledger.record("34.1.1.1", suffix: "a.com", at: Date())
        ledger.record("34.2.2.2", suffix: "b.com", at: Date())
        XCTAssertEqual(ledger.addresses(for: ["a.com"]), ["34.1.1.1"])
        XCTAssertTrue(ledger.keep(only: ["b.com"]))
        XCTAssertFalse(ledger.keep(only: ["b.com"]))
        ledger.remove("34.2.2.2", suffix: "b.com")
        XCTAssertTrue(ledger.seen.isEmpty)
    }

    func testSurvivesARestartOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wildcard-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wildcard-routes.json")
        var ledger = WildcardLedger()
        ledger.record("34.1.1.1", suffix: "example.com", at: Date(timeIntervalSince1970: 1_800_000_000))
        try ledger.save(to: url)
        XCTAssertEqual(WildcardLedger.load(from: url), ledger)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(WildcardLedger.load(from: dir.appendingPathComponent("missing.json")), WildcardLedger())
    }
}

// MARK: - System outputs

final class WildcardSystemOutputTests: XCTestCase {

    private let scutil = """
    DNS configuration

    resolver #1
      search domain[0] : lan
      nameserver[0] : 192.168.10.1
      if_index : 11 (en0)
      flags    : Request A records
      reach    : 0x00020002 (Reachable,Directly Reachable Address)

    resolver #2
      domain   : eu.example.com
      nameserver[0] : 10.9.0.53
      flags    : Request A records

    resolver #3
      domain   : example.com
      nameserver[0] : 127.0.0.1
      port     : 53530
      flags    : Request A records, Request AAAA records
      order    : 1

    resolver #4
      domain   : corp.example.net
      nameserver[0] : 10.20.0.53
      nameserver[1] : 10.20.0.54
      if_index : 24 (utun4)

    DNS configuration (for scoped queries)

    resolver #1
      search domain[0] : lan
      nameserver[0] : 192.168.10.1
      if_index : 11 (en0)

    resolver #2
      nameserver[0] : 10.20.0.53
      if_index : 24 (utun4)
    """

    func testParsesBothSections() {
        let r = ScutilDNS.parse(scutil)
        XCTAssertEqual(r.count, 6)
        XCTAssertEqual(r[2].domain, "example.com")
        XCTAssertTrue(r[2].isWildcardForwarder)
        XCTAssertEqual(r[3].nameservers, ["10.20.0.53", "10.20.0.54"])
        XCTAssertEqual(r[3].interface, "utun4")
        XCTAssertTrue(r[5].scoped)
        XCTAssertFalse(r[0].scoped)
    }

    func testFindsATunnelsServers() {
        let r = ScutilDNS.parse(scutil)
        XCTAssertEqual(ScutilDNS.nameservers(forInterface: "utun4", in: r), ["10.20.0.53", "10.20.0.54"])
        XCTAssertEqual(ScutilDNS.nameservers(forInterface: "en0", in: r), ["192.168.10.1"])
    }

    func testFindsAMoreSpecificResolverThatHidesPartOfAWildcard() {
        let r = ScutilDNS.parse(scutil)
        XCTAssertEqual(ScutilDNS.shadowing("example.com", in: r), ["eu.example.com"])
        XCTAssertEqual(ScutilDNS.shadowing("eu.example.com", in: r), [], "an equal or broader one is not more specific")
        XCTAssertEqual(ScutilDNS.shadowing("example.net", in: r), ["corp.example.net"])
    }

    func testReadsEstablishedTCPPeers() {
        let netstat = """
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
        tcp4       0      0  192.168.10.11.52314    34.149.66.165.443      ESTABLISHED
        tcp4       0      0  192.168.10.11.52315    34.149.66.166.443      TIME_WAIT
        tcp6       0      0  fe80::1%lo0.1024       fe80::1%lo0.1025       ESTABLISHED
        tcp46      0      0  *.22                   *.*                    LISTEN
        """
        XCTAssertEqual(OpenTCPPeers.parse(netstat), ["34.149.66.165"])
    }
}

// MARK: - Learned routes through an apply

@MainActor
final class LearnedWildcardRouteTests: XCTestCase {

    private var savedConfig = Config()

    override func setUp() {
        super.setUp()
        let rm = RouteManager.shared
        savedConfig = rm.config
        rm.config.manageHostsFile = false
        // The wildcard stays configured, so an engine pass the commit starts keeps its routes.
        rm.config.routingMode = .bypass
        rm.config.domains = [DomainEntry(domain: "*.example.com")]
        rm.activeRoutes = []
    }

    override func tearDown() {
        let rm = RouteManager.shared
        rm.removeRoutesBatchOverrideForTests = nil
        rm.activeRoutes = []
        rm.config = savedConfig
        super.tearDown()
    }

    /// An apply knows only the listed entries. It must neither delete a learned route as stale
    /// nor drop it from the model, including one whose address a listed entry used to share.
    func testAnApplyKeepsLearnedRoutes() async {
        let rm = RouteManager.shared
        var removed: [String] = []
        rm.removeRoutesBatchOverrideForTests = { dests in
            removed += dests
            return (dests.count, 0, [], nil)
        }
        rm.activeRoutes = [
            .init(destination: "34.1.1.1", gateway: "192.168.10.1", source: "old.example.org", timestamp: Date()),
            .init(destination: "34.9.9.9", gateway: "192.168.10.1", source: "gone.example.org", timestamp: Date()),
            .init(destination: "34.1.1.1", gateway: "192.168.10.1", source: "*.example.com", timestamp: Date()),
            .init(destination: "34.2.2.2", gateway: "192.168.10.1", source: "*.example.com", timestamp: Date()),
        ]
        let routes: [(destination: String, gateway: String, isNetwork: Bool, source: String)] = [
            (destination: "34.5.5.5", gateway: "192.168.10.1", isNetwork: false, source: "new.example.org"),
        ]
        let committed = await rm.commitAppliedRoutes(
            routesToAdd: routes,
            allSourceEntries: routes.map { (destination: $0.destination, gateway: $0.gateway, source: $0.source) },
            batchFailedDests: [], epoch: rm.routeEpochForTests, logLabel: "")
        XCTAssertTrue(committed)
        XCTAssertEqual(removed, ["34.9.9.9"], "only the listed entry nobody wants any more leaves the kernel")
        XCTAssertEqual(Set(rm.activeRoutes.map { "\($0.source)|\($0.destination)" }),
                       ["new.example.org|34.5.5.5", "*.example.com|34.1.1.1", "*.example.com|34.2.2.2"])
    }

    func testLearnedRoutesAreTellable() {
        XCTAssertTrue(RouteManager.isLearnedWildcardRoute(.init(destination: "34.1.1.1", gateway: "g", source: "*.example.com", timestamp: Date())))
        XCTAssertFalse(RouteManager.isLearnedWildcardRoute(.init(destination: "34.1.1.1", gateway: "g", source: "example.com", timestamp: Date())))
    }

    /// The engine records what the helper drained as ActiveRoutes under the wildcard.
    func testDrainedRoutesJoinActiveRoutesUnderTheirWildcard() async {
        let rm = RouteManager.shared
        let engine = rm.wildcards
        // An apply has committed in the test above or not; the engine must be live to record.
        engine.routesApplied()
        engine.record([LearnedWildcardRoute(ip: "34.7.7.7", suffix: "example.com", gateway: "192.168.10.1"),
                       LearnedWildcardRoute(ip: "34.7.7.7", suffix: "example.com", gateway: "192.168.10.1")])
        XCTAssertEqual(rm.activeRoutes.filter { $0.destination == "34.7.7.7" }.map(\.source), ["*.example.com"])
        XCTAssertNotNil(engine.ledger.seen["example.com"]?["34.7.7.7"])
        engine.record([LearnedWildcardRoute(ip: "34.7.7.7", suffix: "example.com", gateway: "iface:utun4")])
        XCTAssertEqual(rm.activeRoutes.filter { $0.destination == "34.7.7.7" }.map(\.gateway), ["iface:utun4"], "a new gateway replaces the old")
    }
}

// MARK: - One lookup

/// The forwarder's decision for one query (`WildcardLookup.reply`), with the upstream, the
/// limiter and the kernel replaced by closures that record what they were asked.
final class WildcardLookupTests: XCTestCase {

    private let spec = WildcardSpec(suffix: "example.com", gateway: "192.168.10.1", upstream: ["1.1.1.1"], interface: "en0")
    private let tunnelSpec = WildcardSpec(suffix: "corp.example.net", gateway: "iface:utun4", upstream: ["10.0.0.53"],
                                          interface: "utun4", intoTunnel: true)

    private func labels(_ name: String) -> [[UInt8]] {
        name.split(separator: ".").map { Array($0.utf8) }
    }

    private func query(_ name: String, type: UInt16 = DNSWire.typeA) -> [UInt8] {
        DNSWire.encode(DNSWire.Message(id: 7, flags: 0x0100, questions: [.init(labels: labels(name), type: type, qclass: 1)],
                                       answers: [], authority: [], additional: []))!
    }

    private func upstreamAnswer(_ name: String, _ ips: [[UInt8]]) -> [UInt8] {
        let records = ips.map { DNSWire.Record(labels: labels(name), type: DNSWire.typeA, rclass: 1, ttl: 600, data: $0) }
        return DNSWire.encode(DNSWire.Message(id: 7, flags: 0x8180, questions: [.init(labels: labels(name), type: DNSWire.typeA, qclass: 1)],
                                              answers: records, authority: [], additional: []))!
    }

    private struct Calls {
        var forwarded = 0
        var admitted: [String] = []
        var installed: [String] = []
    }

    private func reply(_ bytes: [UInt8], specs: [WildcardSpec]? = nil, guard g: WildcardSafetyGuard = WildcardSafetyGuard(),
                       upstream: [UInt8]?, admit: @escaping ([String]) -> [String] = { $0 },
                       install: @escaping ([String]) -> [String] = { $0 }) -> (DNSWire.Message?, Calls) {
        var calls = Calls()
        let out = WildcardLookup.reply(
            to: bytes, overTCP: false, specs: specs ?? [spec, tunnelSpec], guard: g, ttlCap: 300,
            forward: { _, _ in calls.forwarded += 1; return upstream },
            admit: { ips, _ in calls.admitted += ips; return admit(ips) },
            install: { ips, _ in calls.installed += ips; return install(ips) })
        return (out.flatMap(DNSWire.parse), calls)
    }

    private func addresses(_ m: DNSWire.Message?) -> [String] {
        m.map(DNSWire.addresses(in:)) ?? []
    }

    func testTheDDRProbeIsAnsweredEmptyWithoutAskingUpstream() throws {
        let (m, calls) = reply(query(DNSWire.ddrName, type: DNSWire.typeSVCB), upstream: nil)
        XCTAssertEqual(m?.rcode, DNSWire.rcodeNoError)
        XCTAssertEqual(m?.answers.isEmpty, true)
        XCTAssertEqual(calls.forwarded, 0)
    }

    func testANameOutsideEveryWildcardIsRefused() {
        let (m, calls) = reply(query("example.org"), upstream: nil)
        XCTAssertEqual(m?.rcode, DNSWire.rcodeRefused)
        XCTAssertEqual(calls.forwarded, 0)
    }

    func testAAAAIsAnsweredEmptyUnderAWildcardOnly() {
        let (m, calls) = reply(query("api.example.com", type: DNSWire.typeAAAA), upstream: nil)
        XCTAssertEqual(m?.rcode, DNSWire.rcodeNoError)
        XCTAssertEqual(m?.answers.isEmpty, true)
        XCTAssertEqual(calls.forwarded, 0)
        XCTAssertEqual(reply(query("example.org", type: DNSWire.typeAAAA), upstream: nil).0?.rcode, DNSWire.rcodeRefused,
                       "the suffix is checked before the type")
    }

    func testNoUpstreamAnswerIsServFail() {
        XCTAssertEqual(reply(query("api.example.com"), upstream: nil).0?.rcode, DNSWire.rcodeServFail)
    }

    func testOnlyAddressesThatPassTheGuardReachTheLimiterAndTheKernel() {
        let (m, calls) = reply(query("api.example.com"), upstream: upstreamAnswer("api.example.com", [[34, 1, 1, 1], [10, 0, 0, 5]]))
        XCTAssertEqual(calls.admitted, ["34.1.1.1"])
        XCTAssertEqual(calls.installed, ["34.1.1.1"])
        // The private address is left to the routing table, as without the wildcard.
        XCTAssertEqual(addresses(m), ["34.1.1.1", "10.0.0.5"])
        XCTAssertEqual(m?.answers.map(\.ttl), [300, 300])
    }

    func testAnAddressThatMissedItsRouteIsTakenOut() {
        let up = upstreamAnswer("api.example.com", [[34, 1, 1, 1], [34, 2, 2, 2], [34, 3, 3, 3]])
        let (m, _) = reply(query("api.example.com"), upstream: up,
                           admit: { $0.filter { $0 != "34.2.2.2" } }, install: { $0.filter { $0 != "34.3.3.3" } })
        XCTAssertEqual(addresses(m), ["34.1.1.1"], "refused by the limiter, or not installed in time: never handed out")

        let (none, _) = reply(query("api.example.com"), upstream: up, install: { _ in [] })
        XCTAssertEqual(none?.rcode, DNSWire.rcodeServFail, "no address left: the client asks again")
    }

    func testATunnelWildcardRoutesPrivateAddresses() {
        let (m, calls) = reply(query("git.corp.example.net"), upstream: upstreamAnswer("git.corp.example.net", [[10, 20, 30, 40]]))
        XCTAssertEqual(calls.installed, ["10.20.30.40"])
        XCTAssertEqual(addresses(m), ["10.20.30.40"])
    }

    func testAResponseIsNotAQuery() {
        let (m, calls) = reply(upstreamAnswer("api.example.com", [[34, 1, 1, 1]]), upstream: nil)
        XCTAssertNil(m)
        XCTAssertEqual(calls.forwarded, 0)
    }
}
