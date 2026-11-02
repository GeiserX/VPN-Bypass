// WildcardDelegationTests.swift
// Names under a wildcard that another resolver serves (Tailscale's MagicDNS for the tailnet, a
// VPN's split DNS) are asked of that resolver and passed on with no route learned; the rest of
// the wildcard is asked upstream and learned as before.

import XCTest
@testable import VPNBypassCore

final class WildcardDelegationTests: XCTestCase {

    /// Tailscale with `*.ts.net` and `*.example-tailnet.ts.net` on the Bypass list: the
    /// default resolver (the LAN's), our two files (order 1), Tailscale's supplemental
    /// resolver for the tailnet, and the scoped section, which never counts.
    private let tailscaleScutil = """
    DNS configuration

    resolver #1
      search domain[0] : example-tailnet.ts.net
      nameserver[0] : 192.168.10.1
      if_index : 11 (en0)
      flags    : Request A records
      order    : 200000

    resolver #2
      domain   : example-tailnet.ts.net
      nameserver[0] : 127.0.0.1
      port     : 53530
      flags    : Request A records, Request AAAA records
      order    : 1

    resolver #3
      domain   : ts.net
      nameserver[0] : 127.0.0.1
      port     : 53530
      flags    : Request A records, Request AAAA records
      order    : 1

    resolver #4
      domain   : example-tailnet.ts.net.
      nameserver[0] : 100.100.100.100
      nameserver[1] : fd7a:115c:a1e0::53
      if_index : 24 (utun10)
      flags    : Supplemental, Request A records, Request AAAA records
      order    : 101001

    DNS configuration (for scoped queries)

    resolver #1
      search domain[0] : example-tailnet.ts.net
      nameserver[0] : 192.168.10.1
      if_index : 11 (en0)
      flags    : Scoped, Request A records

    resolver #2
      domain   : scoped-only.ts.net
      nameserver[0] : 198.51.100.9
      if_index : 11 (en0)
      flags    : Scoped, Supplemental, Request A records
    """

    private let magicDNS = WildcardDelegation(domain: "example-tailnet.ts.net", servers: ["100.100.100.100"], interface: "utun10")

    // MARK: Which resolvers count

    func testTailscalesResolverServesTheTailnetUnderBothWildcards() {
        let r = ScutilDNS.parse(tailscaleScutil)
        XCTAssertEqual(ScutilDNS.owners(under: "ts.net", asking: ["192.168.10.1"], in: r), [magicDNS],
                       "the tailnet's resolver, IPv4 servers only; our own files, the default and the scoped section never")
        XCTAssertEqual(ScutilDNS.owners(under: "example-tailnet.ts.net", asking: ["192.168.10.1"], in: r), [magicDNS],
                       "the same domain as the wildcard counts: our file only wins on order")
        XCTAssertEqual(ScutilDNS.owners(under: "a.example-tailnet.ts.net", asking: ["192.168.10.1"], in: r), [magicDNS],
                       "a domain above the wildcard serves every name under it")
        XCTAssertEqual(ScutilDNS.owners(under: "example.com", asking: ["192.168.10.1"], in: r), [])
    }

    func testOurOwnForwarderIsNeverAnotherResolver() {
        let r = ScutilDNS.parse("""
        DNS configuration

        resolver #1
          domain   : a.example.com
          nameserver[0] : 127.0.0.1
          port     : 53530
          order    : 1

        resolver #2
          domain   : b.example.com
          nameserver[0] : 127.0.0.2
          nameserver[1] : 127.0.0.1
          port     : 53530
          order    : 5
        """)
        XCTAssertEqual(ScutilDNS.owners(under: "example.com", asking: ["192.168.10.1"], in: r), [])
        XCTAssertNil(WildcardDelegation(encoded: "a.example.com|127.0.0.1|53530|"), "the helper refuses to forward to itself")
        XCTAssertNil(WildcardDelegation(encoded: "a.example.com|127.9.9.9|53530|"))
        XCTAssertNil(WildcardDelegation(encoded: "a.example.com|0.0.0.0|53|"))
        XCTAssertNotNil(WildcardDelegation(encoded: "a.example.com|127.0.0.1|53|"), "a local resolver on another port is someone else's")
    }

    func testTheDefaultResolverNeverTakesNamesFromAWildcard() {
        // A VPN that publishes its servers as the default resolver: no domain, so it is not
        // the owner of any name in particular.
        let r = ScutilDNS.parse("""
        DNS configuration

        resolver #1
          nameserver[0] : 203.0.113.53
          if_index : 20 (utun4)
          order    : 1
        """)
        XCTAssertEqual(ScutilDNS.owners(under: "ts.net", asking: ["192.168.10.1"], in: r), [])
    }

    func testAResolverTheWildcardAsksAnywayKeepsItsNamesRouted() {
        // VPN Only `*.corp.example.net`: the VPN's split DNS for it is the tunnel's own server,
        // the one the wildcard asks, so its names are learned into the tunnel as before.
        let r = ScutilDNS.parse("""
        DNS configuration

        resolver #1
          domain   : corp.example.net
          nameserver[0] : 10.20.0.53
          if_index : 20 (utun4)
          flags    : Supplemental, Request A records
          order    : 102000
        """)
        XCTAssertEqual(ScutilDNS.owners(under: "corp.example.net", asking: ["10.20.0.53"], in: r), [])
        XCTAssertEqual(ScutilDNS.owners(under: "corp.example.net", asking: ["192.168.10.1"], in: r),
                       [WildcardDelegation(domain: "corp.example.net", servers: ["10.20.0.53"], interface: "utun4")],
                       "around the VPN the wildcard asks the LAN, which does not know those names")
    }

    func testTheResolverMacOSWouldPickForADomainIsTheOneAsked() {
        let r = ScutilDNS.parse("""
        DNS configuration

        resolver #1
          domain   : a.example.com
          nameserver[0] : 198.51.100.2
          port     : 5353
          order    : 300

        resolver #2
          domain   : a.example.com
          nameserver[0] : 198.51.100.1
          port     : 5300
          order    : 200
        """)
        XCTAssertEqual(ScutilDNS.owners(under: "example.com", asking: [], in: r),
                       [WildcardDelegation(domain: "a.example.com", servers: ["198.51.100.1"], port: 5300)],
                       "lowest order, with its port")
    }

    // MARK: The plan carries them to the helper

    func testThePlanHandsTheHelperEachWildcardsOtherResolvers() throws {
        var c = Config()
        c.routingMode = .bypass
        c.domains = [DomainEntry(domain: "*.ts.net"), DomainEntry(domain: "*.example-tailnet.ts.net")]
        let env = WildcardPlanner.Environment(
            localGateway: "192.168.10.1", physicalInterface: "en0", physicalDNS: ["192.168.10.1"],
            vpnGateway: "10.20.0.1", vpnInterface: "utun4", vpnDNS: ["10.20.0.53"],
            resolvers: ScutilDNS.parse(tailscaleScutil))
        let specs = WildcardPlanner.plan(c, env: env).specs
        XCTAssertEqual(specs.map(\.suffix), ["ts.net", "example-tailnet.ts.net"])
        XCTAssertEqual(specs.map(\.delegated), [[magicDNS], [magicDNS]])
        for spec in specs {
            XCTAssertEqual(WildcardSpec(dictionary: spec.dictionary), spec, "crosses to the helper as it is")
        }
    }

    func testTheHelperRefusesADelegationOutsideTheWildcard() {
        var d = WildcardSpec(suffix: "ts.net", gateway: "192.168.10.1", upstream: ["192.168.10.1"], interface: "en0",
                             delegated: [magicDNS]).dictionary
        XCTAssertNotNil(WildcardSpec(dictionary: d))
        d["delegated"] = "example.com|198.51.100.1|53|"
        XCTAssertNil(WildcardSpec(dictionary: d), "a domain that shares no name with the wildcard")
        d["delegated"] = "example-tailnet.ts.net|not-an-ip|53|"
        XCTAssertNil(WildcardSpec(dictionary: d))
        d["delegated"] = "example-tailnet.ts.net|100.100.100.100|53|utun10;broken"
        XCTAssertNil(WildcardSpec(dictionary: d), "one bad entry refuses the spec, as for exclusions")
    }

    // MARK: One lookup

    private let tsSpec = WildcardSpec(
        suffix: "ts.net", gateway: "192.168.10.1", upstream: ["192.168.10.1"], interface: "en0",
        delegated: [WildcardDelegation(domain: "example-tailnet.ts.net", servers: ["100.100.100.100"]),
                    WildcardDelegation(domain: "eu.example-tailnet.ts.net", servers: ["198.51.100.53"], port: 5353)])

    private func labels(_ name: String) -> [[UInt8]] { name.split(separator: ".").map { Array($0.utf8) } }

    private func query(_ name: String, type: UInt16 = DNSWire.typeA) -> [UInt8] {
        DNSWire.encode(DNSWire.Message(id: 7, flags: 0x0100, questions: [.init(labels: labels(name), type: type, qclass: 1)],
                                       answers: [], authority: [], additional: []))!
    }

    private func answer(_ name: String, type: UInt16 = DNSWire.typeA, _ data: [[UInt8]]) -> [UInt8] {
        let records = data.map { DNSWire.Record(labels: labels(name), type: type, rclass: 1, ttl: 600, data: $0) }
        return DNSWire.encode(DNSWire.Message(id: 7, flags: 0x8180, questions: [.init(labels: labels(name), type: type, qclass: 1)],
                                              answers: records, authority: [], additional: []))!
    }

    private struct Calls {
        var forwarded = 0
        var delegatedTo: [WildcardDelegation] = []
        var learning: [String] = []
    }

    private func reply(_ bytes: [UInt8], upstream: [UInt8]?, owner: [UInt8]?) -> (DNSWire.Message?, Calls) {
        var calls = Calls()
        let out = WildcardLookup.reply(
            to: bytes, overTCP: false, specs: [tsSpec], guard: WildcardSafetyGuard(), ttlCap: 300,
            forward: { _, _ in calls.forwarded += 1; return upstream },
            delegate: { _, o in calls.delegatedTo.append(o); return owner },
            routed: { ips, _ in calls.learning += ips; return [] },
            admit: { ips, _ in calls.learning += ips; return ips },
            install: { ips, _ in calls.learning += ips; return WildcardLookup.Install(installed: ips) })
        return (out.flatMap(DNSWire.parse), calls)
    }

    func testATailnetNameIsAskedOfItsResolverAndNotLearned() {
        let tailnet = answer("box.example-tailnet.ts.net", [[100, 101, 102, 103]])
        let (m, calls) = reply(query("box.example-tailnet.ts.net"), upstream: nil, owner: tailnet)
        XCTAssertEqual(m?.rcode, DNSWire.rcodeNoError, "not the NXDOMAIN the LAN's DNS gives")
        XCTAssertEqual(m.map(DNSWire.addresses(in:)), ["100.101.102.103"])
        XCTAssertEqual(m?.answers.map(\.ttl), [600], "its answer, untouched")
        XCTAssertEqual(calls.delegatedTo.map(\.servers), [["100.100.100.100"]])
        XCTAssertEqual(calls.forwarded, 0, "the wildcard's upstream is not asked")
        XCTAssertEqual(calls.learning, [], "nothing learned")

        let v6 = answer("box.example-tailnet.ts.net", type: DNSWire.typeAAAA, [[0xfd, 0x7a] + [UInt8](repeating: 0, count: 13) + [1]])
        let (aaaa, aaaaCalls) = reply(query("box.example-tailnet.ts.net", type: DNSWire.typeAAAA), upstream: nil, owner: v6)
        XCTAssertEqual(aaaa?.answers.map(\.type), [DNSWire.typeAAAA], "its IPv6 answer too, not the empty one wildcards give")
        XCTAssertEqual(aaaaCalls.delegatedTo.count, 1)

        let (failed, _) = reply(query("box.example-tailnet.ts.net"), upstream: answer("box.example-tailnet.ts.net", [[34, 1, 1, 1]]), owner: nil)
        XCTAssertEqual(failed?.rcode, DNSWire.rcodeServFail, "no answer from the owner: the client asks again, never the upstream's")
    }

    func testAPublicNameUnderTheWildcardIsStillAskedUpstreamAndLearned() {
        let (m, calls) = reply(query("funnel.ts.net"), upstream: answer("funnel.ts.net", [[34, 1, 1, 1]]), owner: nil)
        XCTAssertEqual(m.map(DNSWire.addresses(in:)), ["34.1.1.1"])
        XCTAssertEqual(calls.forwarded, 1)
        XCTAssertEqual(calls.delegatedTo, [])
        XCTAssertTrue(calls.learning.contains("34.1.1.1"), "learned as before")
    }

    func testTheMostSpecificResolverWins() {
        let (_, calls) = reply(query("host.eu.example-tailnet.ts.net"), upstream: nil,
                               owner: answer("host.eu.example-tailnet.ts.net", [[34, 2, 2, 2]]))
        XCTAssertEqual(calls.delegatedTo.map(\.domain), ["eu.example-tailnet.ts.net"])
        XCTAssertEqual(calls.delegatedTo.map(\.port), [5353])
        XCTAssertEqual(tsSpec.delegation(for: "EXAMPLE-TAILNET.ts.net.")?.domain, "example-tailnet.ts.net", "the domain itself, any case")
        XCTAssertNil(tsSpec.delegation(for: "other-example-tailnet.ts.net"), "a label boundary, not a string suffix")
    }
}
