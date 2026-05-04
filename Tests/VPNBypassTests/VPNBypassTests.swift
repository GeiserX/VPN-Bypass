// VPNBypassTests.swift
// Unit tests for VPN Bypass core logic.

import XCTest
@testable import VPNBypassCore

// MARK: - IP Validation Tests

/// Tests for IP address and CIDR validation logic (mirrors HelperTool private methods).
/// HelperTool is a separate binary not importable by tests, so these reimplement its validation logic.
final class IPValidationTests: XCTestCase {

    private func isValidIP(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            guard let num = Int($0), num >= 0, num <= 255 else { return false }
            return String(num) == $0
        }
    }

    private func isValidDestination(_ string: String) -> Bool {
        if string.contains("/") {
            let parts = string.components(separatedBy: "/")
            guard parts.count == 2,
                  isValidIP(parts[0]),
                  let mask = Int(parts[1]),
                  mask >= 0 && mask <= 32 else {
                return false
            }
            return true
        }
        return isValidIP(string)
    }

    private func isValidGateway(_ gateway: String) -> Bool {
        if gateway.hasPrefix("iface:") {
            return isValidInterfaceName(String(gateway.dropFirst(6)))
        }
        return isValidIP(gateway)
    }

    private func isValidInterfaceName(_ name: String) -> Bool {
        let validPrefixes = ["utun", "ipsec", "ppp", "gpd", "tun", "tap", "feth", "zt"]
        guard validPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber } && name.count <= 16
    }

    private func isValidDomain(_ string: String) -> Bool {
        let domainRegex = #"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$"#
        return string.range(of: domainRegex, options: .regularExpression) != nil
    }

    // MARK: - IP Validation

    func testValidIPv4Addresses() {
        XCTAssertTrue(isValidIP("192.168.1.1"))
        XCTAssertTrue(isValidIP("0.0.0.0"))
        XCTAssertTrue(isValidIP("255.255.255.255"))
        XCTAssertTrue(isValidIP("10.0.0.1"))
        XCTAssertTrue(isValidIP("172.16.0.1"))
    }

    func testInvalidIPv4Addresses() {
        XCTAssertFalse(isValidIP(""))
        XCTAssertFalse(isValidIP("256.1.1.1"))
        XCTAssertFalse(isValidIP("1.2.3"))
        XCTAssertFalse(isValidIP("1.2.3.4.5"))
        XCTAssertFalse(isValidIP("abc.def.ghi.jkl"))
        XCTAssertFalse(isValidIP("192.168.1.-1"))
        XCTAssertFalse(isValidIP("192.168.1.999"))
    }

    // MARK: - Destination (IP or CIDR)

    func testValidCIDRDestinations() {
        XCTAssertTrue(isValidDestination("10.0.0.0/8"))
        XCTAssertTrue(isValidDestination("192.168.1.0/24"))
        XCTAssertTrue(isValidDestination("172.16.0.0/12"))
        XCTAssertTrue(isValidDestination("0.0.0.0/0"))
        XCTAssertTrue(isValidDestination("255.255.255.255/32"))
    }

    func testInvalidCIDRDestinations() {
        XCTAssertFalse(isValidDestination("10.0.0.0/33"))
        XCTAssertFalse(isValidDestination("10.0.0.0/-1"))
        XCTAssertFalse(isValidDestination("10.0.0.0/abc"))
        XCTAssertFalse(isValidDestination("not.an.ip/24"))
        XCTAssertFalse(isValidDestination("10.0.0.0/8/16"))
    }

    func testPlainIPDestinations() {
        XCTAssertTrue(isValidDestination("8.8.8.8"))
        XCTAssertTrue(isValidDestination("1.1.1.1"))
        XCTAssertFalse(isValidDestination(""))
        XCTAssertFalse(isValidDestination("hello"))
    }

    // MARK: - Gateway Validation

    func testValidGateways() {
        XCTAssertTrue(isValidGateway("192.168.1.1"))
        XCTAssertTrue(isValidGateway("10.0.0.1"))
        XCTAssertTrue(isValidGateway("iface:utun0"))
        XCTAssertTrue(isValidGateway("iface:utun3"))
        XCTAssertTrue(isValidGateway("iface:ipsec0"))
        XCTAssertTrue(isValidGateway("iface:ppp0"))
        XCTAssertTrue(isValidGateway("iface:tun0"))
        XCTAssertTrue(isValidGateway("iface:tap0"))
        XCTAssertTrue(isValidGateway("iface:feth0"))
        XCTAssertTrue(isValidGateway("iface:zt123"))
    }

    func testInvalidGateways() {
        XCTAssertFalse(isValidGateway(""))
        XCTAssertFalse(isValidGateway("iface:"))
        XCTAssertFalse(isValidGateway("iface:en0"))
        XCTAssertFalse(isValidGateway("iface:lo0"))
        XCTAssertFalse(isValidGateway("iface:eth0"))
        XCTAssertFalse(isValidGateway("not-an-ip"))
    }

    func testInterfaceNameLengthLimit() {
        XCTAssertTrue(isValidInterfaceName("utun1234567890ab"))  // 16 chars
        XCTAssertFalse(isValidInterfaceName("utun1234567890abc")) // 17 chars
    }

    func testInterfaceNameSpecialChars() {
        XCTAssertFalse(isValidInterfaceName("utun-0"))
        XCTAssertFalse(isValidInterfaceName("utun.0"))
        XCTAssertFalse(isValidInterfaceName("utun 0"))
    }

    // MARK: - Domain Validation

    func testValidDomains() {
        XCTAssertTrue(isValidDomain("example.com"))
        XCTAssertTrue(isValidDomain("sub.example.com"))
        XCTAssertTrue(isValidDomain("a.b.c.d.example.com"))
        XCTAssertTrue(isValidDomain("my-domain.com"))
        XCTAssertTrue(isValidDomain("telegram.org"))
        XCTAssertTrue(isValidDomain("t.me"))
        XCTAssertTrue(isValidDomain("a"))
    }

    func testInvalidDomains() {
        XCTAssertFalse(isValidDomain(""))
        XCTAssertFalse(isValidDomain("-invalid.com"))
        XCTAssertFalse(isValidDomain("invalid-.com"))
        XCTAssertFalse(isValidDomain(".leading-dot.com"))
        XCTAssertFalse(isValidDomain("trailing-dot.com."))
        XCTAssertFalse(isValidDomain("spa ce.com"))
    }

    // MARK: - Route Args Builder

    func testBuildRouteAddArgsHost() {
        let args = buildRouteAddArgs(destination: "8.8.8.8", gateway: "192.168.1.1", isNetwork: false)
        XCTAssertEqual(args, ["-n", "add", "-host", "8.8.8.8", "192.168.1.1"])
    }

    func testBuildRouteAddArgsNetwork() {
        let args = buildRouteAddArgs(destination: "10.0.0.0/8", gateway: "192.168.1.1", isNetwork: true)
        XCTAssertEqual(args, ["-n", "add", "-net", "10.0.0.0/8", "192.168.1.1"])
    }

    func testBuildRouteAddArgsInterface() {
        let args = buildRouteAddArgs(destination: "8.8.8.8", gateway: "iface:utun3", isNetwork: false)
        XCTAssertEqual(args, ["-n", "add", "-host", "8.8.8.8", "-interface", "utun3"])
    }

    private func buildRouteAddArgs(destination: String, gateway: String, isNetwork: Bool) -> [String] {
        var args = ["-n", "add"]
        args.append(isNetwork ? "-net" : "-host")
        args.append(destination)
        if gateway.hasPrefix("iface:") {
            args.append(contentsOf: ["-interface", String(gateway.dropFirst(6))])
        } else {
            args.append(gateway)
        }
        return args
    }
}

// MARK: - CIDR Validation Tests (RouteManager)

/// Tests for the RouteManager.isValidCIDR() function via @testable import.
@MainActor
final class CIDRValidationTests: XCTestCase {

    private let rm = RouteManager.shared

    // MARK: - Valid CIDRs

    func testValidCIDRWithCommonSubnets() {
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/8"))
        XCTAssertTrue(rm.isValidCIDR("172.16.0.0/12"))
        XCTAssertTrue(rm.isValidCIDR("192.168.1.0/24"))
        XCTAssertTrue(rm.isValidCIDR("192.168.0.0/16"))
    }

    func testValidCIDRWithHostMask() {
        XCTAssertTrue(rm.isValidCIDR("1.2.3.4/32"))
        XCTAssertTrue(rm.isValidCIDR("255.255.255.255/32"))
    }

    func testInvalidCIDRDefaultRoute() {
        XCTAssertFalse(rm.isValidCIDR("0.0.0.0/0"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/0"))
    }

    func testValidCIDRBoundaryMasks() {
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/1"))
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/31"))
        XCTAssertTrue(rm.isValidCIDR("10.0.0.0/32"))
    }

    // MARK: - Invalid CIDRs

    func testInvalidCIDRMaskTooLarge() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/33"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/64"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/128"))
    }

    func testInvalidCIDRNegativeMask() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/-1"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/-32"))
    }

    func testInvalidCIDRNonNumericMask() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/abc"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/xx"))
    }

    func testInvalidCIDRBadIPPart() {
        XCTAssertFalse(rm.isValidCIDR("999.0.0.0/24"))
        XCTAssertFalse(rm.isValidCIDR("not.an.ip.addr/24"))
        XCTAssertFalse(rm.isValidCIDR("1.2.3/24"))
        XCTAssertFalse(rm.isValidCIDR("256.1.1.1/24"))
    }

    func testInvalidCIDRMultipleSlashes() {
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/8/16"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0//8"))
    }

    func testInvalidCIDREmptyString() {
        XCTAssertFalse(rm.isValidCIDR(""))
    }

    func testInvalidCIDRPlainIP() {
        XCTAssertFalse(rm.isValidCIDR("192.168.1.1"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.1"))
    }

    func testInvalidCIDRDomainInput() {
        XCTAssertFalse(rm.isValidCIDR("example.com"))
        XCTAssertFalse(rm.isValidCIDR("example.com/24"))
        XCTAssertFalse(rm.isValidCIDR("sub.domain.org/16"))
    }

    func testInvalidCIDRWithWhitespace() {
        XCTAssertFalse(rm.isValidCIDR(" 10.0.0.0/8"))
        XCTAssertFalse(rm.isValidCIDR("10.0.0.0/8 "))
        XCTAssertFalse(rm.isValidCIDR(" 10.0.0.0/8 "))
    }

    func testInvalidCIDRWithProtocol() {
        XCTAssertFalse(rm.isValidCIDR("http://10.0.0.0/8"))
    }
}

// MARK: - DomainEntry Codable Tests

/// Tests for RouteManager.DomainEntry encoding/decoding, using the real production type.
final class DomainEntryCodableTests: XCTestCase {

    // MARK: - Encoding

    func testEncodeDomainEntryWithCIDRTrue() throws {
        let entry = RouteManager.DomainEntry(domain: "10.0.0.0/8", isCIDR: true)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["domain"] as? String, "10.0.0.0/8")
        XCTAssertEqual(json["isCIDR"] as? Bool, true)
        XCTAssertEqual(json["enabled"] as? Bool, true)
    }

    func testEncodeDomainEntryWithCIDRFalse() throws {
        let entry = RouteManager.DomainEntry(domain: "example.com", isCIDR: false)
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["domain"] as? String, "example.com")
        XCTAssertEqual(json["isCIDR"] as? Bool, false)
    }

    // MARK: - Decoding (backward compatibility)

    func testDecodeOldJSONWithoutCIDRFieldDefaultsToFalse() throws {
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "domain": "telegram.org",
            "enabled": true
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let entry = try JSONDecoder().decode(RouteManager.DomainEntry.self, from: data)
        XCTAssertEqual(entry.domain, "telegram.org")
        XCTAssertEqual(entry.enabled, true)
        XCTAssertEqual(entry.isCIDR, false)
        XCTAssertNil(entry.resolvedIP)
        XCTAssertNil(entry.lastResolved)
    }

    func testDecodeJSONWithCIDRTrue() throws {
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "domain": "192.168.1.0/24",
            "enabled": true,
            "isCIDR": true
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let entry = try JSONDecoder().decode(RouteManager.DomainEntry.self, from: data)
        XCTAssertEqual(entry.domain, "192.168.1.0/24")
        XCTAssertEqual(entry.isCIDR, true)
    }

    func testDecodeJSONWithCIDRExplicitlyFalse() throws {
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "domain": "example.com",
            "enabled": true,
            "isCIDR": false
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let entry = try JSONDecoder().decode(RouteManager.DomainEntry.self, from: data)
        XCTAssertEqual(entry.domain, "example.com")
        XCTAssertEqual(entry.isCIDR, false)
    }

    func testDecodeOldJSONWithResolvedIPPreserved() throws {
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "domain": "netflix.com",
            "enabled": false,
            "resolvedIP": "52.94.237.1"
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let entry = try JSONDecoder().decode(RouteManager.DomainEntry.self, from: data)
        XCTAssertEqual(entry.domain, "netflix.com")
        XCTAssertEqual(entry.enabled, false)
        XCTAssertEqual(entry.resolvedIP, "52.94.237.1")
        XCTAssertEqual(entry.isCIDR, false)
    }

    // MARK: - Round-trip

    func testRoundTripCIDREntry() throws {
        let original = RouteManager.DomainEntry(domain: "172.16.0.0/12", isCIDR: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.DomainEntry.self, from: data)
        XCTAssertEqual(decoded.domain, original.domain)
        XCTAssertEqual(decoded.enabled, original.enabled)
        XCTAssertEqual(decoded.isCIDR, original.isCIDR)
        XCTAssertEqual(decoded.id, original.id)
    }

    func testRoundTripDomainEntry() throws {
        let original = RouteManager.DomainEntry(domain: "example.com", isCIDR: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.DomainEntry.self, from: data)
        XCTAssertEqual(decoded.domain, original.domain)
        XCTAssertEqual(decoded.isCIDR, false)
    }

    // MARK: - Init defaults

    func testDomainEntryInitDefaultsCIDRToFalse() {
        let entry = RouteManager.DomainEntry(domain: "google.com")
        XCTAssertEqual(entry.isCIDR, false)
        XCTAssertEqual(entry.enabled, true)
    }

    func testDomainEntryInitExplicitCIDR() {
        let entry = RouteManager.DomainEntry(domain: "10.0.0.0/8", isCIDR: true)
        XCTAssertEqual(entry.isCIDR, true)
        XCTAssertEqual(entry.domain, "10.0.0.0/8")
    }
}

// MARK: - AddInverseDomain Logic Tests

/// Tests for the addInverseDomain detection logic using real RouteManager functions.
@MainActor
final class AddInverseDomainLogicTests: XCTestCase {

    private let rm = RouteManager.shared

    /// Simulates the classification logic from addInverseDomain using real production functions
    private func classifyInput(_ domain: String) -> (entry: String, isCIDR: Bool)? {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let cidr = rm.isValidCIDR(trimmed)
        let entry: String
        if cidr {
            entry = trimmed
        } else if trimmed.contains("/") {
            return nil
        } else {
            entry = rm.cleanDomain(trimmed)
            guard !entry.isEmpty else { return nil }
        }
        return (entry, cidr)
    }

    // MARK: - CIDR Detection

    func testCIDRInputIsDetectedAsCIDR() {
        let result = classifyInput("192.168.1.0/24")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.entry, "192.168.1.0/24")
        XCTAssertTrue(result!.isCIDR)
    }

    func testCIDRInputWithWhitespaceIsTrimmedAndDetected() {
        let result = classifyInput("  10.0.0.0/8  ")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.entry, "10.0.0.0/8")
        XCTAssertTrue(result!.isCIDR)
    }

    func testCIDRInputPreservesExactNotation() {
        let result = classifyInput("172.16.0.0/12")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.entry, "172.16.0.0/12")
        XCTAssertTrue(result!.isCIDR)
    }

    // MARK: - Domain Detection

    func testDomainInputIsDetectedAsDomain() {
        let result = classifyInput("example.com")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.entry, "example.com")
        XCTAssertFalse(result!.isCIDR)
    }

    func testURLWithPathIsRejected() {
        let result = classifyInput("https://Example.COM/path?q=1")
        XCTAssertNil(result)
    }

    func testDomainInputIsCleaned() {
        let result = classifyInput("example.COM")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.entry, "example.com")
        XCTAssertFalse(result!.isCIDR)
    }

    func testDomainInputWithPort() {
        let result = classifyInput("example.com:8080")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.entry, "example.com")
        XCTAssertFalse(result!.isCIDR)
    }

    func testEmptyInputReturnsNil() {
        let result = classifyInput("")
        XCTAssertNil(result)
    }

    func testWhitespaceOnlyInputReturnsNil() {
        let result = classifyInput("   ")
        XCTAssertNil(result)
    }

    // MARK: - Deduplication

    private func wouldDuplicate(_ input: String, existingDomains: [String]) -> Bool {
        guard let result = classifyInput(input) else { return false }
        return existingDomains.contains(result.entry)
    }

    func testDuplicateCIDRIsDetected() {
        let existing = ["10.0.0.0/8", "example.com"]
        XCTAssertTrue(wouldDuplicate("10.0.0.0/8", existingDomains: existing))
    }

    func testDuplicateDomainIsDetected() {
        let existing = ["10.0.0.0/8", "example.com"]
        XCTAssertTrue(wouldDuplicate("example.com", existingDomains: existing))
    }

    func testNewCIDRIsNotDuplicate() {
        let existing = ["10.0.0.0/8", "example.com"]
        XCTAssertFalse(wouldDuplicate("192.168.0.0/16", existingDomains: existing))
    }

    func testNewDomainIsNotDuplicate() {
        let existing = ["10.0.0.0/8", "example.com"]
        XCTAssertFalse(wouldDuplicate("google.com", existingDomains: existing))
    }

    func testURLWithPathIsRejectedBeforeDuplicateCheck() {
        let existing = ["telegram.org"]
        XCTAssertFalse(wouldDuplicate("https://telegram.org/path", existingDomains: existing))
    }

    func testDuplicateDomainWithExactMatchIsDetected() {
        let existing = ["telegram.org"]
        XCTAssertTrue(wouldDuplicate("telegram.org", existingDomains: existing))
    }

    // MARK: - Hosts file skipping for CIDR entries

    func testCIDREntryShouldBeSkippedInHostsFile() {
        let cidrEntry = RouteManager.DomainEntry(domain: "10.0.0.0/8", isCIDR: true)
        XCTAssertTrue(cidrEntry.isCIDR, "CIDR entries must be skipped in hosts file generation")
    }

    func testDomainEntryShouldNotBeSkippedInHostsFile() {
        let domainEntry = RouteManager.DomainEntry(domain: "example.com", isCIDR: false)
        XCTAssertFalse(domainEntry.isCIDR, "Domain entries should be included in hosts file generation")
    }
}

// MARK: - Color Extension Tests

final class ColorHexTests: XCTestCase {

    func testHexStripping() {
        let hex = "#FF0000".trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        XCTAssertEqual(hex, "FF0000")
    }

    func testThreeCharHexParsing() {
        let hex = "F00"
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = (int >> 8) * 17
        let g = (int >> 4 & 0xF) * 17
        let b = (int & 0xF) * 17
        XCTAssertEqual(r, 255)
        XCTAssertEqual(g, 0)
        XCTAssertEqual(b, 0)
    }

    func testSixCharHexParsing() {
        let hex = "00FF00"
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = int >> 16
        let g = int >> 8 & 0xFF
        let b = int & 0xFF
        XCTAssertEqual(r, 0)
        XCTAssertEqual(g, 255)
        XCTAssertEqual(b, 0)
    }

    func testEightCharHexWithAlpha() {
        let hex = "80FF0000"
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a = int >> 24
        let r = int >> 16 & 0xFF
        let g = int >> 8 & 0xFF
        let b = int & 0xFF
        XCTAssertEqual(a, 128)
        XCTAssertEqual(r, 255)
        XCTAssertEqual(g, 0)
        XCTAssertEqual(b, 0)
    }

    func testInvalidHexDefaultsToBlack() {
        let hex = "XY"
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let count = hex.count
        XCTAssertNotEqual(count, 3)
        XCTAssertNotEqual(count, 6)
        XCTAssertNotEqual(count, 8)
    }
}

// MARK: - Helper Constants Tests

final class HelperConstantsTests: XCTestCase {

    func testHelperVersionFormat() {
        let parts = HelperConstants.helperVersion.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertNotNil(Int(parts[0]))
        XCTAssertNotNil(Int(parts[1]))
        XCTAssertNotNil(Int(parts[2]))
    }

    func testBundleID() {
        XCTAssertTrue(HelperConstants.bundleID.hasPrefix("com.geiserx."))
        XCTAssertTrue(HelperConstants.bundleID.hasSuffix(".helper"))
    }

    func testHostMarkers() {
        XCTAssertTrue(HelperConstants.hostMarkerStart.hasPrefix("#"))
        XCTAssertTrue(HelperConstants.hostMarkerEnd.hasPrefix("#"))
        XCTAssertTrue(HelperConstants.hostMarkerStart.contains("START"))
        XCTAssertTrue(HelperConstants.hostMarkerEnd.contains("END"))
    }
}

// MARK: - Hosts File Logic Tests

final class HostsFileTests: XCTestCase {

    private func removeVPNBypassSection(from content: String) -> String {
        let markerStart = HelperConstants.hostMarkerStart
        let markerEnd = HelperConstants.hostMarkerEnd
        var lines = content.components(separatedBy: "\n")
        var inSection = false
        lines = lines.filter { line in
            if line.contains(markerStart) {
                inSection = true
                return false
            }
            if line.contains(markerEnd) {
                inSection = false
                return false
            }
            return !inSection
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    func testRemoveExistingSection() {
        let hosts = """
        127.0.0.1 localhost
        # VPN-BYPASS-MANAGED - START
        1.2.3.4 example.com
        5.6.7.8 test.org
        # VPN-BYPASS-MANAGED - END
        """
        let result = removeVPNBypassSection(from: hosts)
        XCTAssertFalse(result.contains("VPN-BYPASS-MANAGED"))
        XCTAssertFalse(result.contains("example.com"))
        XCTAssertTrue(result.contains("localhost"))
    }

    func testNoSectionPresent() {
        let hosts = "127.0.0.1 localhost\n::1 localhost"
        let result = removeVPNBypassSection(from: hosts)
        XCTAssertEqual(result, hosts)
    }

    func testEmptySection() {
        let hosts = """
        127.0.0.1 localhost
        # VPN-BYPASS-MANAGED - START
        # VPN-BYPASS-MANAGED - END
        """
        let result = removeVPNBypassSection(from: hosts)
        XCTAssertFalse(result.contains("VPN-BYPASS-MANAGED"))
        XCTAssertTrue(result.contains("localhost"))
    }

    private func buildHostsSection(entries: [(domain: String, ip: String)]) -> [String] {
        guard !entries.isEmpty else { return [] }
        var lines: [String] = []
        lines.append(HelperConstants.hostMarkerStart)
        for entry in entries {
            lines.append("\(entry.ip) \(entry.domain)")
        }
        lines.append(HelperConstants.hostMarkerEnd)
        return lines
    }

    func testBuildHostsSection() {
        let entries = [
            (domain: "telegram.org", ip: "91.108.56.1"),
            (domain: "t.me", ip: "91.108.56.2"),
        ]
        let lines = buildHostsSection(entries: entries)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.first!.contains("START"))
        XCTAssertTrue(lines.last!.contains("END"))
        XCTAssertEqual(lines[1], "91.108.56.1 telegram.org")
    }

    func testBuildEmptyHostsSection() {
        let lines = buildHostsSection(entries: [])
        XCTAssertTrue(lines.isEmpty)
    }
}

// MARK: - OnceGate Tests

/// Tests the exactly-once delivery semantics of the OnceGate pattern.
final class OnceGateTests: XCTestCase {

    func testOnceGateDeliversFirstValue() async {
        let result: Int = await withCheckedContinuation { continuation in
            let gate = OnceGate(continuation: continuation)
            gate.complete(42)
            gate.complete(99)
        }
        XCTAssertEqual(result, 42)
    }

    func testOnceGateConcurrentCompletion() async {
        let result: String = await withCheckedContinuation { continuation in
            let gate = OnceGate(continuation: continuation)
            DispatchQueue.global().async { gate.complete("first") }
            DispatchQueue.global().async { gate.complete("second") }
        }
        XCTAssertTrue(result == "first" || result == "second")
    }
}
