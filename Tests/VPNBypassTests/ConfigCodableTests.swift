// ConfigCodableTests.swift
// Codable round-trip and backward-compatibility tests for RouteManager model types.

import XCTest
@testable import VPNBypassCore

// MARK: - Config Backward-Compatibility Tests

/// Tests the custom `init(from:)` decoder on `RouteManager.Config` which uses
/// `decodeIfPresent` with defaults for every field, ensuring old JSON configs
/// missing newer fields still decode correctly.
final class ConfigBackwardCompatTests: XCTestCase {

    // MARK: - Empty JSON → all defaults

    func testDecodeEmptyJSONProducesAllDefaults() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertTrue(config.autoApplyOnVPN)
        XCTAssertTrue(config.manageHostsFile)
        XCTAssertEqual(config.checkInterval, 300)
        XCTAssertFalse(config.verifyRoutesAfterApply)
        XCTAssertTrue(config.autoDNSRefresh)
        XCTAssertEqual(config.dnsRefreshInterval, 3600)
        XCTAssertEqual(config.fallbackDNS, ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(config.routingMode, .bypass)
        XCTAssertTrue(config.inverseDomains.isEmpty)
    }

    func testDecodeEmptyJSONProducesDefaultProxyConfig() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertFalse(config.proxyConfig.enabled)
        XCTAssertEqual(config.proxyConfig.server, "")
        XCTAssertEqual(config.proxyConfig.port, 1080)
        XCTAssertEqual(config.proxyConfig.username, "")
        XCTAssertEqual(config.proxyConfig.password, "")
        XCTAssertTrue(config.proxyConfig.useForServices.isEmpty)
    }

    func testDecodeEmptyJSONProducesDefaultDomains() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)
        // defaultDomains is [] per source
        XCTAssertTrue(config.domains.isEmpty)
    }

    func testDecodeEmptyJSONProducesDefaultServices() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)
        // defaultServices is a non-empty list of built-in services
        XCTAssertFalse(config.services.isEmpty)
        // Verify a known built-in service exists
        XCTAssertTrue(config.services.contains(where: { $0.id == "telegram" }))
    }

    // MARK: - Partial JSON → missing fields get defaults

    func testDecodePartialJSONWithOnlyAutoApply() throws {
        let json = Data(#"{"autoApplyOnVPN": false}"#.utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertFalse(config.autoApplyOnVPN)
        // All other fields should be defaults
        XCTAssertTrue(config.manageHostsFile)
        XCTAssertEqual(config.checkInterval, 300)
        XCTAssertFalse(config.verifyRoutesAfterApply)
        XCTAssertTrue(config.autoDNSRefresh)
        XCTAssertEqual(config.dnsRefreshInterval, 3600)
        XCTAssertEqual(config.fallbackDNS, ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(config.routingMode, .bypass)
        XCTAssertTrue(config.inverseDomains.isEmpty)
    }

    func testDecodePartialJSONWithCheckIntervalOnly() throws {
        let json = Data(#"{"checkInterval": 600}"#.utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertEqual(config.checkInterval, 600)
        XCTAssertTrue(config.autoApplyOnVPN)
        XCTAssertTrue(config.manageHostsFile)
    }

    func testDecodePartialJSONWithCustomFallbackDNS() throws {
        let json = Data(#"{"fallbackDNS": ["9.9.9.9"]}"#.utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertEqual(config.fallbackDNS, ["9.9.9.9"])
        XCTAssertTrue(config.autoApplyOnVPN)
    }

    // MARK: - Old config without newer fields

    func testDecodeOldConfigWithoutProxyConfig() throws {
        let json = Data(#"{"autoApplyOnVPN": true, "manageHostsFile": false}"#.utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertFalse(config.proxyConfig.enabled)
        XCTAssertEqual(config.proxyConfig.server, "")
        XCTAssertEqual(config.proxyConfig.port, 1080)
    }

    func testDecodeOldConfigWithoutRoutingMode() throws {
        let json = Data(#"{"autoApplyOnVPN": true}"#.utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertEqual(config.routingMode, .bypass)
    }

    func testDecodeOldConfigWithoutInverseDomains() throws {
        let json = Data(#"{"autoApplyOnVPN": true}"#.utf8)
        let config = try JSONDecoder().decode(RouteManager.Config.self, from: json)

        XCTAssertTrue(config.inverseDomains.isEmpty)
    }

    // MARK: - Full round-trip

    func testConfigFullRoundTrip() throws {
        var original = RouteManager.Config()
        original.autoApplyOnVPN = false
        original.manageHostsFile = false
        original.checkInterval = 120
        original.verifyRoutesAfterApply = true
        original.autoDNSRefresh = false
        original.dnsRefreshInterval = 1800
        original.fallbackDNS = ["9.9.9.9", "208.67.222.222"]
        original.routingMode = .vpnOnly
        original.inverseDomains = [RouteManager.DomainEntry(domain: "internal.corp")]

        var proxy = RouteManager.ProxyConfig()
        proxy.enabled = true
        proxy.server = "proxy.example.com"
        proxy.port = 8080
        proxy.username = "user"
        proxy.password = "pass"
        proxy.useForServices = ["telegram"]
        original.proxyConfig = proxy

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.Config.self, from: data)

        XCTAssertEqual(decoded.autoApplyOnVPN, false)
        XCTAssertEqual(decoded.manageHostsFile, false)
        XCTAssertEqual(decoded.checkInterval, 120)
        XCTAssertEqual(decoded.verifyRoutesAfterApply, true)
        XCTAssertEqual(decoded.autoDNSRefresh, false)
        XCTAssertEqual(decoded.dnsRefreshInterval, 1800)
        XCTAssertEqual(decoded.fallbackDNS, ["9.9.9.9", "208.67.222.222"])
        XCTAssertEqual(decoded.routingMode, .vpnOnly)
        XCTAssertEqual(decoded.inverseDomains.count, 1)
        XCTAssertEqual(decoded.inverseDomains.first?.domain, "internal.corp")
        XCTAssertEqual(decoded.proxyConfig.enabled, true)
        XCTAssertEqual(decoded.proxyConfig.server, "proxy.example.com")
        XCTAssertEqual(decoded.proxyConfig.port, 8080)
        XCTAssertEqual(decoded.proxyConfig.username, "user")
        XCTAssertEqual(decoded.proxyConfig.password, "pass")
        XCTAssertEqual(decoded.proxyConfig.useForServices, ["telegram"])
    }

    func testConfigDefaultInitRoundTrip() throws {
        let original = RouteManager.Config()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.Config.self, from: data)

        XCTAssertEqual(decoded.autoApplyOnVPN, original.autoApplyOnVPN)
        XCTAssertEqual(decoded.manageHostsFile, original.manageHostsFile)
        XCTAssertEqual(decoded.checkInterval, original.checkInterval)
        XCTAssertEqual(decoded.verifyRoutesAfterApply, original.verifyRoutesAfterApply)
        XCTAssertEqual(decoded.autoDNSRefresh, original.autoDNSRefresh)
        XCTAssertEqual(decoded.dnsRefreshInterval, original.dnsRefreshInterval)
        XCTAssertEqual(decoded.fallbackDNS, original.fallbackDNS)
        XCTAssertEqual(decoded.routingMode, original.routingMode)
        XCTAssertEqual(decoded.inverseDomains.count, original.inverseDomains.count)
    }
}

// MARK: - ServiceEntry Backward-Compatibility Tests

/// Tests the custom `init(from:)` decoder on `RouteManager.ServiceEntry` where
/// `isCustom` defaults to `false` when missing from old JSON.
final class ServiceEntryBackwardCompatTests: XCTestCase {

    func testDecodeWithoutIsCustomDefaultsToFalse() throws {
        let json = Data(#"""
        {
            "id": "telegram",
            "name": "Telegram",
            "enabled": true,
            "domains": ["telegram.org"],
            "ipRanges": ["91.108.56.0/22"]
        }
        """#.utf8)
        let entry = try JSONDecoder().decode(RouteManager.ServiceEntry.self, from: json)

        XCTAssertEqual(entry.id, "telegram")
        XCTAssertEqual(entry.name, "Telegram")
        XCTAssertTrue(entry.enabled)
        XCTAssertEqual(entry.domains, ["telegram.org"])
        XCTAssertEqual(entry.ipRanges, ["91.108.56.0/22"])
        XCTAssertFalse(entry.isCustom)
    }

    func testDecodeWithIsCustomTrue() throws {
        let json = Data(#"""
        {
            "id": "myservice",
            "name": "My Custom Service",
            "enabled": false,
            "domains": ["custom.example.com"],
            "ipRanges": [],
            "isCustom": true
        }
        """#.utf8)
        let entry = try JSONDecoder().decode(RouteManager.ServiceEntry.self, from: json)

        XCTAssertEqual(entry.id, "myservice")
        XCTAssertTrue(entry.isCustom)
        XCTAssertFalse(entry.enabled)
    }

    func testDecodeWithIsCustomExplicitlyFalse() throws {
        let json = Data(#"""
        {
            "id": "spotify",
            "name": "Spotify",
            "enabled": true,
            "domains": ["spotify.com"],
            "ipRanges": [],
            "isCustom": false
        }
        """#.utf8)
        let entry = try JSONDecoder().decode(RouteManager.ServiceEntry.self, from: json)

        XCTAssertFalse(entry.isCustom)
    }

    func testServiceEntryRoundTrip() throws {
        let original = RouteManager.ServiceEntry(
            id: "custom-svc",
            name: "Custom SVC",
            enabled: true,
            domains: ["a.com", "b.com"],
            ipRanges: ["10.0.0.0/8"],
            isCustom: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.ServiceEntry.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.enabled, original.enabled)
        XCTAssertEqual(decoded.domains, original.domains)
        XCTAssertEqual(decoded.ipRanges, original.ipRanges)
        XCTAssertEqual(decoded.isCustom, original.isCustom)
    }

    func testServiceEntryInitDefaultIsCustomFalse() {
        let entry = RouteManager.ServiceEntry(
            id: "test",
            name: "Test",
            enabled: true,
            domains: [],
            ipRanges: []
        )
        XCTAssertFalse(entry.isCustom)
    }

    func testServiceEntryInitWithIsCustomTrue() {
        let entry = RouteManager.ServiceEntry(
            id: "test",
            name: "Test",
            enabled: true,
            domains: [],
            ipRanges: [],
            isCustom: true
        )
        XCTAssertTrue(entry.isCustom)
    }
}

// MARK: - ProxyConfig Tests

/// Tests for `RouteManager.ProxyConfig` — `isConfigured`, defaults, Equatable, Codable.
final class ProxyConfigTests: XCTestCase {

    func testIsConfiguredTrueWhenServerAndPortValid() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "proxy.example.com"
        proxy.port = 1080
        XCTAssertTrue(proxy.isConfigured)
    }

    func testIsConfiguredTrueAtPortBoundary1() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "proxy.example.com"
        proxy.port = 1
        XCTAssertTrue(proxy.isConfigured)
    }

    func testIsConfiguredTrueAtPortBoundary65535() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "proxy.example.com"
        proxy.port = 65535
        XCTAssertTrue(proxy.isConfigured)
    }

    func testIsConfiguredFalseWhenServerEmpty() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = ""
        proxy.port = 1080
        XCTAssertFalse(proxy.isConfigured)
    }

    func testIsConfiguredFalseWhenPortZero() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "proxy.example.com"
        proxy.port = 0
        XCTAssertFalse(proxy.isConfigured)
    }

    func testIsConfiguredFalseWhenPortExceeds65535() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "proxy.example.com"
        proxy.port = 65536
        XCTAssertFalse(proxy.isConfigured)
    }

    func testIsConfiguredFalseWhenPortNegative() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "proxy.example.com"
        proxy.port = -1
        XCTAssertFalse(proxy.isConfigured)
    }

    func testDefaultInitValues() {
        let proxy = RouteManager.ProxyConfig()
        XCTAssertFalse(proxy.enabled)
        XCTAssertEqual(proxy.server, "")
        XCTAssertEqual(proxy.port, 1080)
        XCTAssertEqual(proxy.username, "")
        XCTAssertEqual(proxy.password, "")
        XCTAssertTrue(proxy.useForServices.isEmpty)
    }

    func testEquatableEqual() {
        let a = RouteManager.ProxyConfig()
        let b = RouteManager.ProxyConfig()
        XCTAssertEqual(a, b)
    }

    func testEquatableNotEqual() {
        var a = RouteManager.ProxyConfig()
        var b = RouteManager.ProxyConfig()
        a.server = "a.com"
        b.server = "b.com"
        XCTAssertNotEqual(a, b)
    }

    func testEquatablePortDifference() {
        var a = RouteManager.ProxyConfig()
        var b = RouteManager.ProxyConfig()
        a.port = 1080
        b.port = 8080
        XCTAssertNotEqual(a, b)
    }

    func testCodableRoundTrip() throws {
        var original = RouteManager.ProxyConfig()
        original.enabled = true
        original.server = "socks.example.com"
        original.port = 9050
        original.username = "admin"
        original.password = "secret"
        original.useForServices = ["netflix", "youtube"]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.ProxyConfig.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripDefault() throws {
        let original = RouteManager.ProxyConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.ProxyConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - RoutingMode Tests

/// Tests for `RouteManager.RoutingMode` — raw values and Codable.
final class RoutingModeTests: XCTestCase {

    func testBypassRawValue() {
        XCTAssertEqual(RouteManager.RoutingMode.bypass.rawValue, "bypass")
    }

    func testVpnOnlyRawValue() {
        XCTAssertEqual(RouteManager.RoutingMode.vpnOnly.rawValue, "vpnOnly")
    }

    func testCodableRoundTripBypass() throws {
        let original = RouteManager.RoutingMode.bypass
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.RoutingMode.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripVpnOnly() throws {
        let original = RouteManager.RoutingMode.vpnOnly
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.RoutingMode.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeFromRawStringBypass() throws {
        let json = Data(#""bypass""#.utf8)
        let decoded = try JSONDecoder().decode(RouteManager.RoutingMode.self, from: json)
        XCTAssertEqual(decoded, .bypass)
    }

    func testDecodeFromRawStringVpnOnly() throws {
        let json = Data(#""vpnOnly""#.utf8)
        let decoded = try JSONDecoder().decode(RouteManager.RoutingMode.self, from: json)
        XCTAssertEqual(decoded, .vpnOnly)
    }

    func testDecodeInvalidRawStringThrows() {
        let json = Data(#""invalid""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RouteManager.RoutingMode.self, from: json))
    }
}

// MARK: - VPNType Tests

/// Tests for `RouteManager.VPNType` — unique raw values, icon property, Codable.
final class VPNTypeTests: XCTestCase {

    private static let allCases: [RouteManager.VPNType] = [
        .globalProtect, .ciscoAnyConnect, .openVPN, .wireGuard,
        .tailscale, .fortinet, .zscaler, .cloudflareWARP,
        .paloAlto, .pulseSecure, .checkPoint, .unknown
    ]

    func testAllCasesHaveUniqueRawValues() {
        let rawValues = Self.allCases.map(\.rawValue)
        let uniqueRawValues = Set(rawValues)
        XCTAssertEqual(rawValues.count, uniqueRawValues.count, "All VPNType cases must have unique raw values")
    }

    func testAllCasesHaveNonEmptyIcon() {
        for vpnType in Self.allCases {
            XCTAssertFalse(vpnType.icon.isEmpty, "\(vpnType.rawValue) has an empty icon")
        }
    }

    func testIconsAreValidSFSymbolPatterns() {
        // SF Symbols use lowercase dot-separated names
        for vpnType in Self.allCases {
            let icon = vpnType.icon
            XCTAssertFalse(icon.contains(" "), "\(vpnType.rawValue) icon contains spaces: \(icon)")
            XCTAssertTrue(icon.contains(".") || icon.allSatisfy { $0.isLetter },
                          "\(vpnType.rawValue) icon doesn't match SF Symbol pattern: \(icon)")
        }
    }

    func testExpectedCaseCount() {
        // 12 cases: 11 named VPN types + unknown
        XCTAssertEqual(Self.allCases.count, 12)
    }

    func testCodableRoundTripAllCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for vpnType in Self.allCases {
            let data = try encoder.encode(vpnType)
            let decoded = try decoder.decode(RouteManager.VPNType.self, from: data)
            XCTAssertEqual(decoded, vpnType, "Round-trip failed for \(vpnType.rawValue)")
        }
    }

    func testDecodeFromRawString() throws {
        let json = Data(#""WireGuard""#.utf8)
        let decoded = try JSONDecoder().decode(RouteManager.VPNType.self, from: json)
        XCTAssertEqual(decoded, .wireGuard)
    }

    func testDecodeInvalidVPNTypeThrows() {
        let json = Data(#""NonExistentVPN""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RouteManager.VPNType.self, from: json))
    }

    func testSpecificRawValues() {
        XCTAssertEqual(RouteManager.VPNType.globalProtect.rawValue, "GlobalProtect")
        XCTAssertEqual(RouteManager.VPNType.ciscoAnyConnect.rawValue, "Cisco AnyConnect")
        XCTAssertEqual(RouteManager.VPNType.openVPN.rawValue, "OpenVPN")
        XCTAssertEqual(RouteManager.VPNType.wireGuard.rawValue, "WireGuard")
        XCTAssertEqual(RouteManager.VPNType.tailscale.rawValue, "Tailscale (Exit Node)")
        XCTAssertEqual(RouteManager.VPNType.fortinet.rawValue, "Fortinet FortiClient")
        XCTAssertEqual(RouteManager.VPNType.zscaler.rawValue, "Zscaler")
        XCTAssertEqual(RouteManager.VPNType.cloudflareWARP.rawValue, "Cloudflare WARP")
        XCTAssertEqual(RouteManager.VPNType.paloAlto.rawValue, "Palo Alto")
        XCTAssertEqual(RouteManager.VPNType.pulseSecure.rawValue, "Pulse Secure")
        XCTAssertEqual(RouteManager.VPNType.checkPoint.rawValue, "Check Point")
        XCTAssertEqual(RouteManager.VPNType.unknown.rawValue, "Unknown VPN")
    }

    func testSpecificIcons() {
        XCTAssertEqual(RouteManager.VPNType.globalProtect.icon, "shield.lefthalf.filled")
        XCTAssertEqual(RouteManager.VPNType.paloAlto.icon, "shield.lefthalf.filled")
        XCTAssertEqual(RouteManager.VPNType.wireGuard.icon, "key.fill")
        XCTAssertEqual(RouteManager.VPNType.tailscale.icon, "link.circle.fill")
        XCTAssertEqual(RouteManager.VPNType.zscaler.icon, "cloud.fill")
        XCTAssertEqual(RouteManager.VPNType.cloudflareWARP.icon, "cloud.bolt.fill")
        XCTAssertEqual(RouteManager.VPNType.unknown.icon, "shield.fill")
    }
}

// MARK: - ExportData Tests

/// Tests for `RouteManager.ExportData` Codable round-trip.
final class ExportDataTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let config = RouteManager.Config()
        let exportDate = Date(timeIntervalSince1970: 1_700_000_000) // deterministic
        let original = RouteManager.ExportData(
            version: "2.1.0",
            exportDate: exportDate,
            config: config
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RouteManager.ExportData.self, from: data)

        XCTAssertEqual(decoded.version, "2.1.0")
        XCTAssertEqual(decoded.exportDate.timeIntervalSince1970, exportDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(decoded.config.autoApplyOnVPN, config.autoApplyOnVPN)
        XCTAssertEqual(decoded.config.fallbackDNS, config.fallbackDNS)
    }

    func testExportDataPreservesConfigFields() throws {
        var config = RouteManager.Config()
        config.routingMode = .vpnOnly
        config.autoApplyOnVPN = false
        config.checkInterval = 60

        let original = RouteManager.ExportData(
            version: "1.0.0",
            exportDate: Date(),
            config: config
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(RouteManager.ExportData.self, from: data)

        XCTAssertEqual(decoded.config.routingMode, .vpnOnly)
        XCTAssertFalse(decoded.config.autoApplyOnVPN)
        XCTAssertEqual(decoded.config.checkInterval, 60)
    }
}

// MARK: - LogEntry.LogLevel Tests

/// Tests for `RouteManager.LogEntry.LogLevel` raw values (Codable context).
final class LogLevelCodableTests: XCTestCase {

    func testInfoRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.info.rawValue, "INFO")
    }

    func testSuccessRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.success.rawValue, "SUCCESS")
    }

    func testWarningRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.warning.rawValue, "WARNING")
    }

    func testErrorRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.error.rawValue, "ERROR")
    }

    func testAllLevelsHaveUniqueRawValues() {
        let levels: [RouteManager.LogEntry.LogLevel] = [.info, .success, .warning, .error]
        let rawValues = levels.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }

    func testInitFromRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "INFO"), .info)
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "SUCCESS"), .success)
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "WARNING"), .warning)
        XCTAssertEqual(RouteManager.LogEntry.LogLevel(rawValue: "ERROR"), .error)
        XCTAssertNil(RouteManager.LogEntry.LogLevel(rawValue: "UNKNOWN"))
    }
}
