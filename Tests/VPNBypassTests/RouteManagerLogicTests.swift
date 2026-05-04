// RouteManagerLogicTests.swift
// Unit tests for RouteManager business logic that is testable without system services.

import XCTest
@testable import VPNBypassCore

@MainActor
final class RouteManagerLogicTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }

    // MARK: - log() Tests

    func testLogAddsEntryToRecentLogs() {
        let countBefore = rm.recentLogs.count
        rm.log(.info, "test log entry")
        XCTAssertGreaterThan(rm.recentLogs.count, countBefore)
        XCTAssertEqual(rm.recentLogs[0].message, "test log entry")
    }

    func testLogPreservesLevel() {
        rm.log(.error, "error message")
        XCTAssertEqual(rm.recentLogs[0].level, .error)
    }

    func testLogPreservesMessage() {
        let msg = "unique message \(UUID().uuidString)"
        rm.log(.info, msg)
        XCTAssertEqual(rm.recentLogs[0].message, msg)
    }

    func testLogInfoLevel() {
        rm.log(.info, "info level test")
        XCTAssertEqual(rm.recentLogs[0].level, .info)
    }

    func testLogSuccessLevel() {
        rm.log(.success, "success level test")
        XCTAssertEqual(rm.recentLogs[0].level, .success)
    }

    func testLogWarningLevel() {
        rm.log(.warning, "warning level test")
        XCTAssertEqual(rm.recentLogs[0].level, .warning)
    }

    func testLogErrorLevel() {
        rm.log(.error, "error level test")
        XCTAssertEqual(rm.recentLogs[0].level, .error)
    }

    func testLogInsertsAtFront() {
        rm.log(.info, "first")
        rm.log(.info, "second")
        XCTAssertEqual(rm.recentLogs[0].message, "second")
    }

    func testLogMaxCapIs200() {
        // Clear existing logs by adding 200+ entries so we start from a known state
        for i in 0..<210 {
            rm.log(.info, "overflow entry \(i)")
        }
        XCTAssertLessThanOrEqual(rm.recentLogs.count, 200)
    }

    func testLogDropsOldestWhenOverCap() {
        // Fill to capacity plus extra
        for i in 0..<201 {
            rm.log(.info, "cap test \(i)")
        }
        XCTAssertEqual(rm.recentLogs.count, 200)
        // Most recent should be the last one logged
        XCTAssertEqual(rm.recentLogs[0].message, "cap test 200")
    }

    func testLogEntryHasTimestamp() {
        let before = Date()
        rm.log(.info, "timestamp check")
        let after = Date()
        let entry = rm.recentLogs[0]
        XCTAssertGreaterThanOrEqual(entry.timestamp, before)
        XCTAssertLessThanOrEqual(entry.timestamp, after)
    }

    func testLogEntryHasUniqueID() {
        rm.log(.info, "id check 1")
        rm.log(.info, "id check 2")
        XCTAssertNotEqual(rm.recentLogs[0].id, rm.recentLogs[1].id)
    }

    // MARK: - Config.defaultDomains Tests

    func testDefaultDomainsIsEmpty() {
        let domains = RouteManager.Config.defaultDomains
        XCTAssertTrue(domains.isEmpty)
    }

    // MARK: - Config.defaultServices Tests

    func testDefaultServicesCountIsAtLeast30() {
        let services = RouteManager.Config.defaultServices
        XCTAssertGreaterThanOrEqual(services.count, 30)
    }

    func testDefaultServicesHaveUniqueIDs() {
        let services = RouteManager.Config.defaultServices
        let ids = services.map(\.id)
        let uniqueIDs = Set(ids)
        XCTAssertEqual(ids.count, uniqueIDs.count, "Service IDs must be unique")
    }

    func testDefaultServicesAllHaveNonEmptyNames() {
        let services = RouteManager.Config.defaultServices
        for service in services {
            XCTAssertFalse(service.name.isEmpty, "Service \(service.id) has empty name")
        }
    }

    func testDefaultServicesAllStartDisabled() {
        let services = RouteManager.Config.defaultServices
        for service in services {
            XCTAssertFalse(service.enabled, "Service \(service.id) should start disabled")
        }
    }

    func testDefaultServicesAllHaveNonEmptyDomains() {
        let services = RouteManager.Config.defaultServices
        for service in services {
            XCTAssertFalse(service.domains.isEmpty, "Service \(service.id) has no domains")
        }
    }

    func testDefaultServicesNoDuplicateIDs() {
        let services = RouteManager.Config.defaultServices
        var seen = Set<String>()
        for service in services {
            XCTAssertFalse(seen.contains(service.id), "Duplicate service ID: \(service.id)")
            seen.insert(service.id)
        }
    }

    func testKnownServiceExists_Telegram() {
        let services = RouteManager.Config.defaultServices
        XCTAssertTrue(services.contains(where: { $0.id == "telegram" }))
    }

    func testKnownServiceExists_WhatsApp() {
        let services = RouteManager.Config.defaultServices
        XCTAssertTrue(services.contains(where: { $0.id == "whatsapp" }))
    }

    func testKnownServiceExists_YouTube() {
        let services = RouteManager.Config.defaultServices
        XCTAssertTrue(services.contains(where: { $0.id == "youtube" }))
    }

    func testKnownServiceExists_Netflix() {
        let services = RouteManager.Config.defaultServices
        XCTAssertTrue(services.contains(where: { $0.id == "netflix" }))
    }

    func testKnownServiceExists_Spotify() {
        let services = RouteManager.Config.defaultServices
        XCTAssertTrue(services.contains(where: { $0.id == "spotify" }))
    }

    func testKnownServiceExists_GitHub() {
        let services = RouteManager.Config.defaultServices
        XCTAssertTrue(services.contains(where: { $0.id == "github" }))
    }

    func testKnownServiceExists_Discord() {
        let services = RouteManager.Config.defaultServices
        XCTAssertTrue(services.contains(where: { $0.id == "discord" }))
    }

    // MARK: - DomainEntry Init Defaults Tests

    func testDomainEntryDefaultEnabledTrue() {
        let entry = RouteManager.DomainEntry(domain: "x")
        XCTAssertTrue(entry.enabled)
    }

    func testDomainEntryDefaultIsCIDRFalse() {
        let entry = RouteManager.DomainEntry(domain: "x")
        XCTAssertFalse(entry.isCIDR)
    }

    func testDomainEntryDefaultIsWildcardFalse() {
        let entry = RouteManager.DomainEntry(domain: "x")
        XCTAssertFalse(entry.isWildcard)
    }

    func testDomainEntryDefaultResolvedIPNil() {
        let entry = RouteManager.DomainEntry(domain: "x")
        XCTAssertNil(entry.resolvedIP)
    }

    func testDomainEntryDefaultLastResolvedNil() {
        let entry = RouteManager.DomainEntry(domain: "x")
        XCTAssertNil(entry.lastResolved)
    }

    func testDomainEntryExplicitCIDR() {
        let entry = RouteManager.DomainEntry(domain: "x", isCIDR: true)
        XCTAssertTrue(entry.isCIDR)
    }

    func testDomainEntryExplicitDisabled() {
        let entry = RouteManager.DomainEntry(domain: "x", enabled: false)
        XCTAssertFalse(entry.enabled)
    }

    func testDomainEntryUniqueUUIDs() {
        let a = RouteManager.DomainEntry(domain: "a")
        let b = RouteManager.DomainEntry(domain: "b")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testDomainEntryPreservesDomain() {
        let entry = RouteManager.DomainEntry(domain: "example.com")
        XCTAssertEqual(entry.domain, "example.com")
    }

    // MARK: - ServiceEntry Init Tests

    func testServiceEntryDefaultIsCustomFalse() {
        let entry = RouteManager.ServiceEntry(
            id: "test", name: "Test", enabled: false,
            domains: ["example.com"], ipRanges: []
        )
        XCTAssertFalse(entry.isCustom)
    }

    func testServiceEntryExplicitIsCustomTrue() {
        let entry = RouteManager.ServiceEntry(
            id: "custom", name: "Custom", enabled: true,
            domains: ["custom.com"], ipRanges: [], isCustom: true
        )
        XCTAssertTrue(entry.isCustom)
    }

    func testServiceEntryPreservesID() {
        let entry = RouteManager.ServiceEntry(
            id: "myid", name: "My Service", enabled: false,
            domains: ["my.com"], ipRanges: []
        )
        XCTAssertEqual(entry.id, "myid")
    }

    func testServiceEntryPreservesEnabledState() {
        let entry = RouteManager.ServiceEntry(
            id: "svc", name: "Svc", enabled: true,
            domains: ["svc.com"], ipRanges: []
        )
        XCTAssertTrue(entry.enabled)
    }

    // MARK: - ProxyConfig.isConfigured Tests

    func testProxyConfigDefaultIsNotConfigured() {
        let proxy = RouteManager.ProxyConfig()
        XCTAssertFalse(proxy.isConfigured)
    }

    func testProxyConfigWithValidServerAndPort() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "1.2.3.4"
        proxy.port = 1080
        XCTAssertTrue(proxy.isConfigured)
    }

    func testProxyConfigWithHostnameServerAndPort() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "host"
        proxy.port = 1080
        XCTAssertTrue(proxy.isConfigured)
    }

    func testProxyConfigWithPortZero() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "host"
        proxy.port = 0
        XCTAssertFalse(proxy.isConfigured)
    }

    func testProxyConfigWithPort65536() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "host"
        proxy.port = 65536
        XCTAssertFalse(proxy.isConfigured)
    }

    func testProxyConfigWithPort65535() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "host"
        proxy.port = 65535
        XCTAssertTrue(proxy.isConfigured)
    }

    func testProxyConfigWithPort1() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "host"
        proxy.port = 1
        XCTAssertTrue(proxy.isConfigured)
    }

    func testProxyConfigWithEmptyServer() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = ""
        proxy.port = 1080
        XCTAssertFalse(proxy.isConfigured)
    }

    func testProxyConfigNegativePort() {
        var proxy = RouteManager.ProxyConfig()
        proxy.server = "host"
        proxy.port = -1
        XCTAssertFalse(proxy.isConfigured)
    }

    // MARK: - VPNType.icon Tests

    func testVPNTypeIconGlobalProtect() {
        XCTAssertFalse(RouteManager.VPNType.globalProtect.icon.isEmpty)
    }

    func testVPNTypeIconCiscoAnyConnect() {
        XCTAssertFalse(RouteManager.VPNType.ciscoAnyConnect.icon.isEmpty)
    }

    func testVPNTypeIconOpenVPN() {
        XCTAssertFalse(RouteManager.VPNType.openVPN.icon.isEmpty)
    }

    func testVPNTypeIconWireGuard() {
        XCTAssertFalse(RouteManager.VPNType.wireGuard.icon.isEmpty)
    }

    func testVPNTypeIconTailscale() {
        XCTAssertFalse(RouteManager.VPNType.tailscale.icon.isEmpty)
    }

    func testVPNTypeIconFortinet() {
        XCTAssertFalse(RouteManager.VPNType.fortinet.icon.isEmpty)
    }

    func testVPNTypeIconZscaler() {
        XCTAssertFalse(RouteManager.VPNType.zscaler.icon.isEmpty)
    }

    func testVPNTypeIconCloudflareWARP() {
        XCTAssertFalse(RouteManager.VPNType.cloudflareWARP.icon.isEmpty)
    }

    func testVPNTypeIconPaloAlto() {
        XCTAssertFalse(RouteManager.VPNType.paloAlto.icon.isEmpty)
    }

    func testVPNTypeIconPulseSecure() {
        XCTAssertFalse(RouteManager.VPNType.pulseSecure.icon.isEmpty)
    }

    func testVPNTypeIconCheckPoint() {
        XCTAssertFalse(RouteManager.VPNType.checkPoint.icon.isEmpty)
    }

    func testVPNTypeIconUnknown() {
        XCTAssertFalse(RouteManager.VPNType.unknown.icon.isEmpty)
    }

    func testVPNTypeGlobalProtectAndPaloAltoShareIcon() {
        XCTAssertEqual(
            RouteManager.VPNType.globalProtect.icon,
            RouteManager.VPNType.paloAlto.icon
        )
    }

    // MARK: - RoutingMode Raw Value Tests

    func testRoutingModeBypassRawValue() {
        XCTAssertEqual(RouteManager.RoutingMode.bypass.rawValue, "bypass")
    }

    func testRoutingModeVPNOnlyRawValue() {
        XCTAssertEqual(RouteManager.RoutingMode.vpnOnly.rawValue, "vpnOnly")
    }

    // MARK: - uniqueRouteCount Tests

    func testUniqueRouteCountWithEmptyRoutes() {
        // activeRoutes starts empty or we verify the property works on current state
        let count = rm.uniqueRouteCount
        let uniqueDestinations = Set(rm.activeRoutes.map(\.destination)).count
        XCTAssertEqual(count, uniqueDestinations)
    }

    // MARK: - LogEntry.LogLevel Raw Value Tests

    func testLogLevelInfoRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.info.rawValue, "INFO")
    }

    func testLogLevelSuccessRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.success.rawValue, "SUCCESS")
    }

    func testLogLevelWarningRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.warning.rawValue, "WARNING")
    }

    func testLogLevelErrorRawValue() {
        XCTAssertEqual(RouteManager.LogEntry.LogLevel.error.rawValue, "ERROR")
    }

    // MARK: - Config Defaults Tests

    func testConfigDefaultAutoApplyOnVPN() {
        let config = RouteManager.Config()
        XCTAssertTrue(config.autoApplyOnVPN)
    }

    func testConfigDefaultManageHostsFile() {
        let config = RouteManager.Config()
        XCTAssertTrue(config.manageHostsFile)
    }

    func testConfigDefaultCheckInterval() {
        let config = RouteManager.Config()
        XCTAssertEqual(config.checkInterval, 300)
    }

    func testConfigDefaultVerifyRoutesDisabled() {
        let config = RouteManager.Config()
        XCTAssertFalse(config.verifyRoutesAfterApply)
    }

    func testConfigDefaultAutoDNSRefresh() {
        let config = RouteManager.Config()
        XCTAssertTrue(config.autoDNSRefresh)
    }

    func testConfigDefaultDNSRefreshInterval() {
        let config = RouteManager.Config()
        XCTAssertEqual(config.dnsRefreshInterval, 3600)
    }

    func testConfigDefaultFallbackDNS() {
        let config = RouteManager.Config()
        XCTAssertEqual(config.fallbackDNS, ["1.1.1.1", "8.8.8.8"])
    }

    func testConfigDefaultRoutingMode() {
        let config = RouteManager.Config()
        XCTAssertEqual(config.routingMode, .bypass)
    }

    func testConfigDefaultInverseDomainsEmpty() {
        let config = RouteManager.Config()
        XCTAssertTrue(config.inverseDomains.isEmpty)
    }

    func testConfigDefaultServicesMatchStaticDefault() {
        let config = RouteManager.Config()
        let defaults = RouteManager.Config.defaultServices
        XCTAssertEqual(config.services.count, defaults.count)
    }

    // MARK: - ProxyConfig Codable Tests

    func testProxyConfigRoundTrip() throws {
        var original = RouteManager.ProxyConfig()
        original.enabled = true
        original.server = "proxy.example.com"
        original.port = 8080
        original.username = "user"
        original.password = "pass"
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteManager.ProxyConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testProxyConfigEquatable() {
        let a = RouteManager.ProxyConfig()
        let b = RouteManager.ProxyConfig()
        XCTAssertEqual(a, b)
    }

    // MARK: - VPNType Raw Values Tests

    func testVPNTypeRawValues() {
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
}
