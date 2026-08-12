// RouteKernelTests.swift
// Byte-level coverage for routing-socket message construction and table parsing.
//
// These bytes go straight into the kernel via write(2) on a PF_ROUTE socket — a layout mistake
// doesn't error, it creates the WRONG route (or a route the kernel can't match for deletion).
// The two macOS-specific traps under test, both classic porting bugs:
//   - sockaddr alignment is FOUR bytes (FreeBSD/OpenBSD examples use 8 and silently misalign)
//   - the netmask sockaddr is TRIMMED (sa_len stops at the last non-zero byte)

import XCTest
import Darwin
@testable import VPNBypassCore

final class RouteKernelTests: XCTestCase {

    private let hdrSize = MemoryLayout<rt_msghdr>.size  // 92 on macOS

    private func header(of data: Data) -> rt_msghdr {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: rt_msghdr.self) }
    }

    // MARK: - Alignment

    func testRoundupIsFourByte() {
        XCTAssertEqual(RouteKernel.roundup(0), 4)
        XCTAssertEqual(RouteKernel.roundup(1), 4)
        XCTAssertEqual(RouteKernel.roundup(4), 4)
        XCTAssertEqual(RouteKernel.roundup(5), 8)
        XCTAssertEqual(RouteKernel.roundup(7), 8)
        XCTAssertEqual(RouteKernel.roundup(16), 16)
        XCTAssertEqual(RouteKernel.roundup(20), 20)
    }

    // MARK: - Trimmed netmask

    func testNetmaskIsTrimmedToLastNonzeroByte() {
        XCTAssertEqual(RouteKernel.trimmedMaskData(prefix: 24).count, 7)  // 255.255.255.0
        XCTAssertEqual(RouteKernel.trimmedMaskData(prefix: 16).count, 6)  // 255.255.0.0
        XCTAssertEqual(RouteKernel.trimmedMaskData(prefix: 8).count, 5)   // 255.0.0.0
        XCTAssertEqual(RouteKernel.trimmedMaskData(prefix: 1).count, 5)   // 128.0.0.0
        XCTAssertEqual(RouteKernel.trimmedMaskData(prefix: 10).count, 6)  // 255.192.0.0
        XCTAssertEqual(RouteKernel.trimmedMaskData(prefix: 32).count, 8)  // 255.255.255.255
        // sa_len byte must equal the data length
        for p in [1, 8, 10, 16, 24, 32] {
            let d = RouteKernel.trimmedMaskData(prefix: p)
            XCTAssertEqual(Int(d[0]), d.count, "sa_len must match trimmed length for /\(p)")
        }
    }

    // MARK: - Message construction

    func testHostAddMessageLayout() throws {
        let spec = RouteKernel.Spec(destination: "203.0.113.7",
                                    gateway: .address("192.168.1.1"), isNetwork: false)
        let msg = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 42, spec: spec))
        let hdr = header(of: msg)
        XCTAssertEqual(Int(hdr.rtm_msglen), msg.count)
        XCTAssertEqual(msg.count, hdrSize + 16 + 16, "header + dst sockaddr_in + gw sockaddr_in")
        XCTAssertEqual(Int(hdr.rtm_version), Int(RTM_VERSION))
        XCTAssertEqual(Int(hdr.rtm_type), Int(RTM_ADD))
        XCTAssertEqual(hdr.rtm_seq, 42)
        XCTAssertEqual(hdr.rtm_addrs, RTA_DST | RTA_GATEWAY)
        for flag in [RTF_UP, RTF_STATIC, RTF_HOST, RTF_GATEWAY, RTF_PROTO1] {
            XCTAssertNotEqual(hdr.rtm_flags & flag, 0, "missing flag 0x\(String(flag, radix: 16))")
        }
        XCTAssertEqual(hdr.rtm_flags & RTF_PROTO3, 0, "PROTO3 is the kernel's GC marker — never set")
    }

    func testNetworkAddCarriesTrimmedPaddedMask() throws {
        let spec = RouteKernel.Spec(destination: "10.20.0.0/16",
                                    gateway: .address("192.168.1.1"), isNetwork: true)
        let msg = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 1, spec: spec))
        let hdr = header(of: msg)
        // /16 mask trims to sa_len 6, padded to 8 on the wire.
        XCTAssertEqual(msg.count, hdrSize + 16 + 16 + 8)
        XCTAssertEqual(hdr.rtm_addrs, RTA_DST | RTA_GATEWAY | RTA_NETMASK)
        XCTAssertEqual(hdr.rtm_flags & RTF_HOST, 0, "a network route must not carry RTF_HOST")
        XCTAssertEqual(Int(msg[hdrSize + 32]), 6, "mask sa_len must be the trimmed 6, not 16")
    }

    func testDeleteOmitsGateway() throws {
        let spec = RouteKernel.Spec(destination: "203.0.113.7",
                                    gateway: .address("192.168.1.1"), isNetwork: false)
        let msg = try XCTUnwrap(RouteKernel.message(type: RTM_DELETE, seq: 9, spec: spec))
        let hdr = header(of: msg)
        XCTAssertEqual(hdr.rtm_addrs, RTA_DST, "delete identifies by destination — a stale gateway would make it miss")
        XCTAssertEqual(msg.count, hdrSize + 16)
    }

    func testInterfaceGatewayIsAFLinkWithoutRTFGateway() throws {
        let spec = RouteKernel.Spec(destination: "203.0.113.7",
                                    gateway: .interfaceIndex(7), isNetwork: false)
        let msg = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 3, spec: spec))
        let hdr = header(of: msg)
        XCTAssertEqual(hdr.rtm_flags & RTF_GATEWAY, 0,
                       "an interface route must NOT set RTF_GATEWAY")
        XCTAssertEqual(Int(msg[hdrSize + 16 + 1]), Int(AF_LINK), "gateway family must be AF_LINK")
        XCTAssertEqual(msg.count, hdrSize + 16 + 20)
    }

    func testUnparseableInputsReturnNil() {
        XCTAssertNil(RouteKernel.message(type: RTM_ADD, seq: 1, spec:
            .init(destination: "not-an-ip", gateway: .address("192.168.1.1"), isNetwork: false)))
        XCTAssertNil(RouteKernel.message(type: RTM_ADD, seq: 1, spec:
            .init(destination: "203.0.113.7", gateway: .address("bogus"), isNetwork: false)))
    }

    // MARK: - Roundtrip through the parser

    /// What we write must be exactly what we can read back — the reconcile diff depends on it.
    func testMessageParsesBackIdentically() throws {
        let host = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 1, spec:
            .init(destination: "203.0.113.7", gateway: .address("192.168.1.1"), isNetwork: false)))
        let net = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 2, spec:
            .init(destination: "10.20.0.0/16", gateway: .address("192.168.1.1"), isNetwork: true)))
        let iface = try XCTUnwrap(RouteKernel.message(type: RTM_ADD, seq: 3, spec:
            .init(destination: "198.51.100.9", gateway: .interfaceIndex(12), isNetwork: false)))

        let parsed = RouteKernel.parseTable(host + net + iface)
        XCTAssertEqual(parsed.count, 3)

        XCTAssertEqual(parsed[0].destinationString, "203.0.113.7")
        XCTAssertTrue(parsed[0].isHost)
        XCTAssertEqual(parsed[0].gatewayAddress.map(RouteKernel.dotted), "192.168.1.1")
        XCTAssertTrue(parsed[0].isOurs, "our PROTO1 tag must survive the roundtrip")

        XCTAssertEqual(parsed[1].destinationString, "10.20.0.0/16")
        XCTAssertFalse(parsed[1].isHost)

        XCTAssertEqual(parsed[2].gatewayInterfaceIndex, 12)
    }

    func testParserSkipsGarbageWithoutCrashing() {
        XCTAssertTrue(RouteKernel.parseTable(Data()).isEmpty)
        XCTAssertTrue(RouteKernel.parseTable(Data(repeating: 0, count: 50)).isEmpty)
        // A header claiming a length beyond the buffer must stop the walk, not crash it.
        var truncated = RouteKernel.message(type: RTM_ADD, seq: 1, spec:
            .init(destination: "203.0.113.7", gateway: .address("192.168.1.1"), isNetwork: false))!
        truncated.removeLast(10)
        XCTAssertTrue(RouteKernel.parseTable(truncated).isEmpty)
    }

    // MARK: - Live table (silent read)

    /// The silent sysctl read must work unprivileged — it is what replaces hundreds of
    /// event-emitting, process-forking `route -n get` calls.
    func testCurrentTableReadsLiveRoutesSilently() throws {
        let table = try XCTUnwrap(RouteKernel.currentTable(), "NET_RT_DUMP must be readable unprivileged")
        XCTAssertFalse(table.isEmpty, "a live machine always has IPv4 routes")
        XCTAssertTrue(table.contains { $0.gatewayAddress != nil || $0.gatewayInterfaceIndex != nil })
    }

    // MARK: - Helpers

    func testIPv4Conversions() {
        XCTAssertEqual(RouteKernel.ipv4ToUInt32("1.2.3.4"), 0x01020304)
        XCTAssertEqual(RouteKernel.dotted(0x01020304), "1.2.3.4")
        XCTAssertNil(RouteKernel.ipv4ToUInt32("1.2.3"))
        XCTAssertNil(RouteKernel.ipv4ToUInt32("1.2.3.256"))
        XCTAssertNil(RouteKernel.ipv4ToUInt32(""))
    }
}

// MARK: - Snapshot comparability (issue #69, requirement 4)

extension RouteKernelTests {

    /// A scoped route shares its destination STRING with the unscoped one — this machine
    /// carries `default … en8` scoped alongside the real default. In a destination-keyed
    /// snapshot the scoped entry would overwrite the one we actually need to compare against,
    /// and the comparison could then answer "already correct" about a route that does not
    /// serve ordinary traffic — silently skipping a write the bypass depends on.
    func testScopedRoutesAreNotComparable() {
        XCTAssertFalse(RouteKernel.isComparableEntry(RTF_UP | RTF_STATIC | RTF_IFSCOPE))
    }

    /// ARP entries are not routes: they carry an AF_LINK gateway and share destinations with
    /// real routes, so they can shadow one in the index.
    func testARPEntriesAreNotComparable() {
        XCTAssertFalse(RouteKernel.isComparableEntry(RTF_UP | RTF_LLINFO))
    }

    func testClonedRejectBlackholeAndDownEntriesAreNotComparable() {
        XCTAssertFalse(RouteKernel.isComparableEntry(RTF_UP | RTF_WASCLONED))
        XCTAssertFalse(RouteKernel.isComparableEntry(RTF_UP | RTF_REJECT))
        XCTAssertFalse(RouteKernel.isComparableEntry(RTF_UP | RTF_BLACKHOLE))
        XCTAssertFalse(RouteKernel.isComparableEntry(RTF_STATIC), "a down route carries nothing")
    }

    /// The routes we actually install must remain comparable, or every apply would rewrite
    /// everything and the zero-churn property would be lost.
    func testOurOwnRoutesRemainComparable() {
        XCTAssertTrue(RouteKernel.isComparableEntry(RTF_UP | RTF_STATIC | RTF_GATEWAY | RTF_HOST | RTF_PROTO1))
        XCTAssertTrue(RouteKernel.isComparableEntry(RTF_UP | RTF_STATIC | RTF_PROTO1))
    }

    /// The live table must still yield usable entries after filtering — a filter that
    /// excluded everything would silently turn every apply back into a blind write.
    func testLiveTableStillYieldsComparableEntries() throws {
        let table = try XCTUnwrap(RouteKernel.currentTable())
        let comparable = table.filter { RouteKernel.isComparableEntry($0.flags) }
        XCTAssertFalse(comparable.isEmpty, "a live machine must have comparable routes")
        XCTAssertTrue(comparable.allSatisfy { $0.flags & RTF_IFSCOPE == 0 })
    }
}
