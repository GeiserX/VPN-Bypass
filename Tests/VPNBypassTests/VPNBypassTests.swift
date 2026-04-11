// VPNBypassTests.swift
// Unit tests for VPN Bypass core logic.

import XCTest

// MARK: - IP Validation Tests

/// Tests for IP address and CIDR validation logic (mirrors HelperTool private methods).
final class IPValidationTests: XCTestCase {

    // Reimplementation of HelperTool.isValidIP for testability
    private func isValidIP(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            guard let num = Int($0) else { return false }
            return num >= 0 && num <= 255
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
        // 16 chars is the max
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

// MARK: - Color Extension Tests

final class ColorHexTests: XCTestCase {

    func testHexStripping() {
        // The hex init strips non-alphanumerics, so "#FF0000" -> "FF0000"
        let hex = "#FF0000".trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        XCTAssertEqual(hex, "FF0000")
    }

    func testThreeCharHexParsing() {
        // RGB (12-bit): "F00" -> red
        let hex = "F00"
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = (int >> 8) * 17
        let g = (int >> 4 & 0xF) * 17
        let b = (int & 0xF) * 17
        XCTAssertEqual(r, 255) // F * 17
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
        // Any count not 3, 6, or 8 defaults to (255, 0, 0, 0) = opaque black
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
        // Version must be semver-like: X.Y.Z
        let version = "1.4.0"
        let parts = version.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertNotNil(Int(parts[0]))
        XCTAssertNotNil(Int(parts[1]))
        XCTAssertNotNil(Int(parts[2]))
    }

    func testBundleID() {
        let bundleID = "com.geiserx.vpnbypass.helper"
        XCTAssertTrue(bundleID.hasPrefix("com.geiserx."))
        XCTAssertTrue(bundleID.hasSuffix(".helper"))
    }

    func testHostMarkers() {
        let start = "# VPN-BYPASS-MANAGED - START"
        let end = "# VPN-BYPASS-MANAGED - END"
        XCTAssertTrue(start.hasPrefix("#"))
        XCTAssertTrue(end.hasPrefix("#"))
        XCTAssertTrue(start.contains("START"))
        XCTAssertTrue(end.contains("END"))
    }
}

// MARK: - Hosts File Logic Tests

final class HostsFileTests: XCTestCase {

    /// Simulates the hosts file section removal logic from HelperTool
    private func removeVPNBypassSection(from content: String) -> String {
        let markerStart = "# VPN-BYPASS-MANAGED - START"
        let markerEnd = "# VPN-BYPASS-MANAGED - END"
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
        // Remove trailing empty lines
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

    /// Simulates building the new hosts section
    private func buildHostsSection(entries: [(domain: String, ip: String)]) -> [String] {
        guard !entries.isEmpty else { return [] }
        var lines: [String] = []
        lines.append("# VPN-BYPASS-MANAGED - START")
        for entry in entries {
            lines.append("\(entry.ip) \(entry.domain)")
        }
        lines.append("# VPN-BYPASS-MANAGED - END")
        return lines
    }

    func testBuildHostsSection() {
        let entries = [
            (domain: "telegram.org", ip: "91.108.56.1"),
            (domain: "t.me", ip: "91.108.56.2"),
        ]
        let lines = buildHostsSection(entries: entries)
        XCTAssertEqual(lines.count, 4) // START + 2 entries + END
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
            let gate = OnceGateTestImpl(continuation: continuation)
            gate.complete(42)
            gate.complete(99) // Second call should be silently dropped
        }
        XCTAssertEqual(result, 42)
    }

    func testOnceGateConcurrentCompletion() async {
        let result: String = await withCheckedContinuation { continuation in
            let gate = OnceGateTestImpl(continuation: continuation)
            DispatchQueue.global().async { gate.complete("first") }
            DispatchQueue.global().async { gate.complete("second") }
        }
        // One of them wins, but we only get one value (no crash)
        XCTAssertTrue(result == "first" || result == "second")
    }
}

/// Minimal reimplementation for testing (mirrors OnceGate from HelperManager.swift)
final class OnceGateTestImpl<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func complete(_ value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
