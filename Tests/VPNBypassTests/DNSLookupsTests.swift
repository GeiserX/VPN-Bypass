// DNSLookupsTests.swift
// The opt-in DNS Lookups page (#176): reading tcpdump's query lines, buffering them in the
// helper, counting them in the app, and the switch that keeps it all off by default.

import XCTest
@testable import VPNBypassCore

final class DNSQueryLineTests: XCTestCase {

    // Lines as `tcpdump -i any -p -l -n -t -s 512 "udp dst port 53"` printed them on macOS 26.6.1.
    func testReadsTheNameOfEachQueryType() {
        XCTAssertEqual(DNSQueryLine.name(from: "IP 192.168.10.11.61955 > 1.1.1.1.53: 29302+ [1au] A? apple.com. (38)"), "apple.com")
        XCTAssertEqual(DNSQueryLine.name(from: "IP 192.168.10.11.59104 > 1.1.1.1.53: 41380+ [1au] AAAA? github.com. (39)"), "github.com")
        XCTAssertEqual(DNSQueryLine.name(from: "IP 192.168.10.11.58592 > 1.1.1.1.53: 59911+ Type65? one.one.one.one. (33)"), "one.one.one.one")
        XCTAssertEqual(DNSQueryLine.name(from: "IP6 fe80::1.52000 > fe80::2.53: 41380+ HTTPS? WWW.Example.COM. (39)"), "www.example.com")
    }

    func testSkipsHousekeepingQueries() {
        XCTAssertNil(DNSQueryLine.name(from: "IP 192.168.10.11.58335 > 1.1.1.1.53: 7055+ [1au] PTR? 1.1.1.1.in-addr.arpa. (49)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 192.168.10.11.62342 > 1.1.1.1.53: 63811+ Type64? _dns.resolver.arpa. (36)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5353 > 224.0.0.251.53: 0 A? printer.local. (30)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ A? localhost. (27)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ A? weird/name.com. (27)"))
        XCTAssertNil(DNSQueryLine.name(from: "tcpdump: listening on any, link-type PKTAP"))
        XCTAssertNil(DNSQueryLine.name(from: ""))
    }

    /// The question type alone decides these: the names would pass every other check.
    func testSkipsQuestionTypesThatDoNotOpenAConnection() {
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ TXT? example.com. (29)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ PTR? example.com. (29)"))
        XCTAssertNil(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.0.0.1.53: 1+ Type64? example.com. (29)"))
    }

    func testKeepsCompanyNames() {
        // VPN Only users list exactly these.
        XCTAssertEqual(DNSQueryLine.name(from: "IP 10.0.0.2.5000 > 10.8.0.1.53: 1+ A? jira.corp.internal. (36)"), "jira.corp.internal")
    }
}

final class DNSQueryBufferTests: XCTestCase {

    func testJoinsALineSplitAcrossReads() {
        var buffer = DNSQueryBuffer()
        buffer.append(Data("IP 10.0.0.2.1 > 1.1.1.1.53: 1+ A? exam".utf8))
        XCTAssertEqual(buffer.names, [])
        buffer.append(Data("ple.com. (29)\nIP 10.0.0.2.1 > 1.1.1.1.53: 2+ A? b.org. (29)\n".utf8))
        XCTAssertEqual(buffer.drain(), ["example.com", "b.org"])
        XCTAssertEqual(buffer.drain(), [])
    }

    func testKeepsTheNewestNamesWhenNobodyDrains() {
        var buffer = DNSQueryBuffer(limit: 3)
        for i in 1...5 {
            buffer.append(Data("IP 10.0.0.2.1 > 1.1.1.1.53: 1+ A? n\(i).com. (29)\n".utf8))
        }
        XCTAssertEqual(buffer.drain(), ["n3.com", "n4.com", "n5.com"])
    }

    func testDropsAStreamWithNoLineBreaks() {
        var buffer = DNSQueryBuffer()
        buffer.append(Data(repeating: UInt8(ascii: "x"), count: 5000))
        buffer.append(Data("IP 10.0.0.2.1 > 1.1.1.1.53: 1+ A? after.com. (29)\n".utf8))
        XCTAssertEqual(buffer.drain(), ["after.com"])
    }
}

final class DNSLookupTallyTests: XCTestCase {

    func testANameCountsOncePerDrain() {
        var tally = DNSLookupTally()
        let now = Date()
        // A browser's A, AAAA and HTTPS for one visit arrive in the same drain.
        tally.record(["github.com", "github.com", "github.com", "apple.com"], at: now)
        tally.record(["github.com"], at: now.addingTimeInterval(3))
        XCTAssertEqual(tally.entries["github.com"]?.count, 2)
        XCTAssertEqual(tally.entries["apple.com"]?.count, 1)
        XCTAssertEqual(tally.entries["github.com"]?.lastSeen, now.addingTimeInterval(3))
    }

    func testRanksByCountThenNameAndFiltersBySearch() {
        var tally = DNSLookupTally()
        let now = Date()
        tally.record(["b.com", "a.com", "c.org"], at: now)
        tally.record(["c.org"], at: now)
        XCTAssertEqual(tally.ranked().map(\.name), ["c.org", "a.com", "b.com"])
        XCTAssertEqual(tally.ranked(matching: " .COM ").map(\.name), ["a.com", "b.com"])
    }

    func testForgetsTheLeastRecentNamesPastTheLimit() {
        var tally = DNSLookupTally()
        let start = Date()
        for i in 0...DNSLookupTally.limit {
            tally.record(["n\(i).com"], at: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(tally.entries.count, DNSLookupTally.limit)
        XCTAssertNil(tally.entries["n0.com"])
        XCTAssertNotNil(tally.entries["n\(DNSLookupTally.limit).com"])
    }
}

final class DNSLookupsConfigTests: XCTestCase {

    func testIsOffByDefaultAndForAnOldConfig() throws {
        XCTAssertFalse(Config().dnsLookupsEnabled)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.dnsLookupsEnabled)
    }

    /// Config's decoder is hand-written: a field with no decode line is saved and then read
    /// back as its default, so the switch would turn itself off on every launch.
    func testTheSwitchSurvivesAnEncodeDecodeRoundTrip() throws {
        var config = Config()
        config.dnsLookupsEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(decoded.dnsLookupsEnabled)
    }

    /// The helper compiles the parser from the Makefile's file list, not from Package.swift.
    func testTheHelperBuildIncludesTheCapture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        for file in ["Sources/VPNBypassCore/DNSQueryLine.swift", "Helper/DNSCapture.swift"] {
            XCTAssertEqual(makefile.components(separatedBy: file).count - 1, 2, "\(file) must be in both helper builds")
        }
    }
}
