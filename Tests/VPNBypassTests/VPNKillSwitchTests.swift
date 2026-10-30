// VPNKillSwitchTests.swift
// A VPN with includeAllNetworks (Proton VPN's kill switch) or enforceRoutes sends every
// connection into its tunnel above the routing table, so the app's routes stay in the table and
// do nothing. These tests cover reading those flags from the NetworkExtension configuration
// archive, and the dropdown and Status page saying so instead of ON and Working.
//
// The fixtures are keyed archives built the way macOS writes
// /Library/Preferences/com.apple.networkextension.plist: the configuration UUIDs at the top
// level beside Version, Generation and Index, each an NEConfiguration with Name, Identifier,
// Application and Grade, a VPN configuration holding an NEVPN with Enabled and TunnelType, and
// its protocol holding the flags among its other keys. Names and ids are made up.

import XCTest
@testable import VPNBypassCore

// MARK: - Fixture classes (archived under the real class names)

@objc(VPNBypassTestsFixtureProtocol)
private final class FixtureProtocol: NSObject, NSCoding {
    var flags: [String: Any]
    init(flags: [String: Any]) { self.flags = flags }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode("vpn.example.test", forKey: "ServerAddress")
        coder.encode(4, forKey: "Type")
        coder.encode(true, forKey: "ExcludeAPNs")
        coder.encode(false, forKey: "DisconnectOnSleep")
        coder.encode(["tunnel": "made-up"] as NSDictionary, forKey: "VendorConfiguration")
        coder.encode(NSUUID(), forKey: "Identifier")
        for (key, value) in flags {
            if let b = value as? Bool { coder.encode(b, forKey: key) } else { coder.encode(value, forKey: key) }
        }
    }
}

@objc(VPNBypassTestsFixtureVPN)
private final class FixtureVPN: NSObject, NSCoding {
    let proto: FixtureProtocol?
    init(proto: FixtureProtocol?) { self.proto = proto }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(2, forKey: "TunnelType")
        coder.encode(false, forKey: "OnDemandEnabled")
        coder.encode(true, forKey: "Enabled")
        coder.encode(proto, forKey: "Protocol")
    }
}

/// A content filter: real archives hold those next to VPNs, and the reader must pass them by.
@objc(VPNBypassTestsFixtureFilter)
private final class FixtureFilter: NSObject, NSCoding {
    override init() {}
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) { coder.encode(true, forKey: "Enabled") }
}

@objc(VPNBypassTestsFixtureConfiguration)
private final class FixtureConfiguration: NSObject, NSCoding {
    let name: String
    let application: String?
    let vpn: FixtureVPN?
    let filter: FixtureFilter?
    init(name: String, application: String?, vpn: FixtureVPN?, filter: FixtureFilter? = nil) {
        self.name = name; self.application = application; self.vpn = vpn; self.filter = filter
    }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "Name")
        coder.encode(NSUUID(), forKey: "Identifier")
        coder.encode(application, forKey: "Application")
        coder.encode(application, forKey: "ApplicationName")
        coder.encode(1, forKey: "Grade")
        coder.encode(false, forKey: "IsDDMSystemScope")
        coder.encode(vpn, forKey: "VPN")
        coder.encode(filter, forKey: "ContentFilter")
    }
}

/// One entry of a fixture archive.
private struct FixtureEntry {
    let id: String
    let configuration: FixtureConfiguration
    var className = "NEConfiguration"
    var protocolClassName = "NETunnelProviderProtocol"
}

private func archive(_ entries: [FixtureEntry]) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.setClassName("NEVPN", for: FixtureVPN.self)
    archiver.setClassName("NEContentFilter", for: FixtureFilter.self)
    archiver.encode(1, forKey: "Version")
    archiver.encode(42, forKey: "Generation")
    archiver.encode(["UserMap": ["made-up": "index"]] as NSDictionary, forKey: "Index")
    for entry in entries {
        // setClassName is per class, so each entry with its own names is archived in turn.
        archiver.setClassName(entry.className, for: FixtureConfiguration.self)
        archiver.setClassName(entry.protocolClassName, for: FixtureProtocol.self)
        archiver.encode(entry.configuration, forKey: entry.id)
    }
    archiver.finishEncoding()
    return archiver.encodedData
}

private func vpnEntry(_ id: String, name: String = "Made-up VPN", app: String? = "test.madeup.vpn",
                      flags: [String: Any], protocolClass: String = "NETunnelProviderProtocol") -> FixtureEntry {
    FixtureEntry(id: id,
                 configuration: FixtureConfiguration(name: name, application: app,
                                                     vpn: FixtureVPN(proto: FixtureProtocol(flags: flags))),
                 protocolClassName: protocolClass)
}

private let idA = "11111111-2222-3333-4444-555555555555"
private let idB = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
private let idC = "99999999-8888-7777-6666-555555555555"

private let killSwitchFlags: [String: Any] = [
    "IncludeAllNetworks": true, "EnforceRoutes": false, "ExcludeLocalNetworks": true]
private let offFlags: [String: Any] = [
    "IncludeAllNetworks": false, "EnforceRoutes": false, "ExcludeLocalNetworks": false]

final class VPNKillSwitchReaderTests: XCTestCase {

    // MARK: Archive

    func testReadsTheFlagsOfEveryVPNConfiguration() {
        let data = archive([
            vpnEntry(idA, name: "Proton VPN", app: "ch.protonvpn.mac", flags: killSwitchFlags),
            vpnEntry(idB, flags: offFlags),
            FixtureEntry(id: idC, configuration: FixtureConfiguration(name: "A filter", application: "test.filter",
                                                                      vpn: nil, filter: FixtureFilter())),
        ])
        let configs = VPNKillSwitchReader.vpnConfigurations(from: data)
        XCTAssertEqual(configs.map(\.id), [idA, idB], "the content filter is not a VPN")
        XCTAssertEqual(configs[0], NEVPNConfigurationInfo(id: idA, name: "Proton VPN", application: "ch.protonvpn.mac",
                                                          includeAllNetworks: true, enforceRoutes: false,
                                                          excludeLocalNetworks: true))
        XCTAssertEqual(configs[1].includeAllNetworks, false)
        XCTAssertEqual(configs[1].enforceRoutes, false)
    }

    func testFlagsMissingFromTheArchiveAreUnknown() {
        let configs = VPNKillSwitchReader.vpnConfigurations(from: archive([vpnEntry(idA, flags: [:])]))
        XCTAssertEqual(configs.count, 1)
        XCTAssertNil(configs[0].includeAllNetworks)
        XCTAssertNil(configs[0].enforceRoutes)
        XCTAssertNil(configs[0].excludeLocalNetworks)
        XCTAssertNil(VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idA]))
    }

    func testAnIKEv2ConfigurationIsReadToo() {
        let data = archive([vpnEntry(idA, flags: ["IncludeAllNetworks": true], protocolClass: "NEVPNProtocolIKEv2")])
        XCTAssertEqual(VPNKillSwitchReader.vpnConfigurations(from: data).first?.includeAllNetworks, true)
    }

    func testUnreadableDataGivesNothing() {
        XCTAssertEqual(VPNKillSwitchReader.vpnConfigurations(from: Data()), [])
        XCTAssertEqual(VPNKillSwitchReader.vpnConfigurations(from: Data("not a plist".utf8)), [])
        let plainPlist = try! PropertyListSerialization.data(fromPropertyList: ["$top": ["x": 1]], format: .binary, options: 0)
        XCTAssertEqual(VPNKillSwitchReader.vpnConfigurations(from: plainPlist), [])
        // An archive cut short.
        let whole = archive([vpnEntry(idA, flags: killSwitchFlags)])
        XCTAssertEqual(VPNKillSwitchReader.vpnConfigurations(from: whole.prefix(whole.count / 2)), [])
    }

    /// A configuration this reader cannot decode is skipped, and the next one is still read.
    func testAnOddConfigurationDoesNotHideTheNextOne() {
        let data = archive([
            FixtureEntry(id: idA, configuration: FixtureConfiguration(name: "Odd", application: nil,
                                                                      vpn: FixtureVPN(proto: FixtureProtocol(flags: killSwitchFlags))),
                         className: "NESomethingNew"),
            vpnEntry(idB, flags: ["IncludeAllNetworks": "yes"]),
            vpnEntry(idC, flags: killSwitchFlags),
        ])
        let configs = VPNKillSwitchReader.vpnConfigurations(from: data)
        XCTAssertFalse(configs.contains { $0.id == idA })
        XCTAssertNotEqual(configs.first { $0.id == idB }?.includeAllNetworks, true, "a string is not a true flag")
        XCTAssertEqual(configs.first { $0.id == idC }?.includeAllNetworks, true)
    }

    // MARK: Which VPN

    func testOnlyAConnectedVPNCounts() {
        let configs = VPNKillSwitchReader.vpnConfigurations(from: archive([
            vpnEntry(idA, flags: killSwitchFlags), vpnEntry(idB, flags: offFlags)]))
        XCTAssertNil(VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idB]),
                     "the kill switch belongs to a VPN that is not connected")
        XCTAssertNil(VPNKillSwitchReader.killSwitch(configurations: configs, connected: []))
        XCTAssertEqual(VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idA, idB])?.includeAllNetworks, true)
    }

    func testFlagsOffIsNoKillSwitch() {
        let configs = VPNKillSwitchReader.vpnConfigurations(from: archive([vpnEntry(idA, flags: offFlags)]))
        XCTAssertNil(VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idA]))
    }

    func testEnforceRoutesAloneCounts() {
        let configs = VPNKillSwitchReader.vpnConfigurations(from: archive([
            vpnEntry(idA, flags: ["IncludeAllNetworks": false, "EnforceRoutes": true, "ExcludeLocalNetworks": true])]))
        let ks = VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idA])
        XCTAssertEqual(ks?.enforceRoutes, true)
        XCTAssertEqual(ks?.flagNames, ["enforceRoutes"], "excludeLocalNetworks only matters with includeAllNetworks")
    }

    func testNamesTheProductFromItsAppThenTheConfiguration() {
        let configs = VPNKillSwitchReader.vpnConfigurations(from: archive([
            vpnEntry(idA, name: "My tunnel", app: "ch.protonvpn.mac", flags: killSwitchFlags),
            vpnEntry(idB, name: "Office", app: "test.unknown.app", flags: killSwitchFlags)]))
        XCTAssertEqual(VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idA])?.name, "Proton VPN")
        XCTAssertEqual(VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idB])?.name, "Office")
        XCTAssertEqual(VPNKillSwitchReader.killSwitch(configurations: configs, connected: [idA])?.flagNames,
                       ["includeAllNetworks", "excludeLocalNetworks"])
    }

    func testTheTrackedTunnelWinsWhenSeveralHaveOne() {
        let configs = VPNKillSwitchReader.vpnConfigurations(from: archive([
            vpnEntry(idA, name: "First", app: nil, flags: killSwitchFlags),
            vpnEntry(idB, name: "Second", app: nil, flags: ["EnforceRoutes": true])]))
        let both: Set = [idA, idB]
        XCTAssertEqual(VPNKillSwitchReader.killSwitch(configurations: configs, connected: both)?.name, "First")
        XCTAssertEqual(VPNKillSwitchReader.killSwitch(configurations: configs, connected: both,
                                                      interfaces: [idA: "utun3", idB: "utun7"],
                                                      trackedInterface: "utun7")?.name, "Second")
    }

    // MARK: scutil --nc list

    func testConnectedIDsFromSCUtil() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      \(idA.lowercased()) VPN (test.madeup.vpn) "Made-up VPN"     [VPN:test.madeup.vpn]
        * (Disconnected)   \(idB) VPN (test.other) "Other"                          [VPN:test.other]
          (Connecting)     \(idC) IPSec "Office"                                   [IPSec]
        """
        XCTAssertEqual(VPNKillSwitchReader.connectedIDs(fromNCList: output), [idA])
        XCTAssertEqual(VPNKillSwitchReader.connectedIDs(fromNCList: ""), [])
        XCTAssertEqual(VPNKillSwitchReader.connectedIDs(fromNCList: "* (Connected) not-a-uuid VPN"), [])
    }

    // MARK: The file

    /// The positive control for the live path: a file in the real layout with the kill switch
    /// on, read the way the app reads /Library/Preferences/com.apple.networkextension.plist.
    func testReadsAKillSwitchFromAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ne-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try archive([vpnEntry(idA, name: "Proton VPN", app: "ch.protonvpn.mac", flags: killSwitchFlags),
                     vpnEntry(idB, flags: offFlags)]).write(to: url)
        let ks = VPNKillSwitchReader.read(connected: [idA], trackedInterface: "utun9", path: url.path)
        XCTAssertEqual(ks, VPNKillSwitch(name: "Proton VPN", includeAllNetworks: true, enforceRoutes: false,
                                         excludeLocalNetworks: true))
        XCTAssertNil(VPNKillSwitchReader.read(connected: [idB], trackedInterface: nil, path: url.path))
        XCTAssertNil(VPNKillSwitchReader.read(connected: [idA], trackedInterface: nil, path: url.path + ".missing"))
    }

    /// Set VPNB_NE_PLIST to a copy of a real archive to see what the reader makes of it.
    /// Prints flags only, never names or ids.
    func testReadsARealArchiveWhenGivenOne() throws {
        guard let path = ProcessInfo.processInfo.environment["VPNB_NE_PLIST"] else {
            throw XCTSkip("VPNB_NE_PLIST not set")
        }
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let configs = VPNKillSwitchReader.vpnConfigurations(from: data)
        XCTAssertFalse(configs.isEmpty, "a real archive with a VPN configuration reads at least one")
        for (n, c) in configs.enumerated() {
            print("real-archive vpn \(n): includeAllNetworks=\(String(describing: c.includeAllNetworks)) enforceRoutes=\(String(describing: c.enforceRoutes)) excludeLocalNetworks=\(String(describing: c.excludeLocalNetworks))")
        }
    }
}

// MARK: - What the app says

final class KillSwitchStatusTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let proton = VPNKillSwitch(name: "Proton VPN", includeAllNetworks: true, enforceRoutes: false,
                                       excludeLocalNetworks: false)

    private func input(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "Proton VPN", helperReady: true, mode: .bypass,
            enabledServices: 4, enabledDomains: 2, enabledRules: 0, installedRoutes: 62,
            pending: nil,
            lastRouteChange: .init(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 62, failedCount: 0),
            lastDNSRefresh: now.addingTimeInterval(-12 * 60),
            nextDNSRefresh: now.addingTimeInterval(18 * 60),
            autoDNSRefresh: true)
        edit(&i)
        return i
    }

    func testTheKillSwitchReplacesOn() {
        XCTAssertEqual(DropdownStatus.make(input(), now: now).pill, "ON", "control: the same state without it is ON")
        let s = DropdownStatus.make(input { $0.killSwitch = self.proton }, now: now)
        XCTAssertEqual(s.pill, "NO EFFECT")
        XCTAssertEqual(s.tone, .warn)
        XCTAssertEqual(s.headline, "Proton VPN connected")
        XCTAssertEqual(s.sentence, "Proton VPN's kill switch sends all traffic through the VPN. Sites set to skip it still go through it.")
        XCTAssertEqual(s.note, "Turn off its kill switch, or use its own split tunnelling.")
        XCTAssertEqual(s.facts, [], "no route count that reads as success")
    }

    func testTheKillSwitchReplacesWorking() {
        XCTAssertEqual(StatusPage.summary(input(), now: now).title, "Working")
        let s = StatusPage.summary(input { $0.killSwitch = self.proton }, now: now)
        XCTAssertEqual(s.title, "No effect")
        XCTAssertEqual(s.sentence, "Proton VPN's kill switch sends all traffic through the VPN. Sites set to skip it still go through it.")
        XCTAssertEqual(s.tone, .warn)
    }

    func testItAlsoReplacesWaiting() {
        let pending = RouteManager.PendingReconnectApply(reason: .settling, connectedAt: now.addingTimeInterval(-5),
                                                         appliesAt: now.addingTimeInterval(10))
        let s = DropdownStatus.make(input { $0.pending = pending; $0.killSwitch = self.proton }, now: now)
        XCTAssertEqual(s.pill, "NO EFFECT")
    }

    func testAllowLANSaysLocalAddressesStillSkipIt() {
        let lan = VPNKillSwitch(name: "Proton VPN", includeAllNetworks: true, enforceRoutes: false, excludeLocalNetworks: true)
        XCTAssertEqual(DropdownStatus.make(input { $0.killSwitch = lan }, now: now).note,
                       "Turn off its kill switch, or use its own split tunnelling. Local-network addresses still skip it.")
    }

    func testEnforceRoutesHasItsOwnWording() {
        let enforce = VPNKillSwitch(name: nil, includeAllNetworks: false, enforceRoutes: true, excludeLocalNetworks: false)
        let s = DropdownStatus.make(input { $0.vpnName = "WireGuard"; $0.killSwitch = enforce }, now: now)
        XCTAssertEqual(s.sentence, "WireGuard makes its own routes win over this app's. Sites set to skip it still go through it.")
        XCTAssertEqual(s.note, "Turn off that setting in the VPN app, or use its own split tunnelling.")
    }

    func testNoVPNAndHelperDownStillComeFirst() {
        XCTAssertEqual(DropdownStatus.make(input { $0.isVPNConnected = false; $0.killSwitch = self.proton }, now: now).pill, "OFF")
        XCTAssertEqual(DropdownStatus.make(input { $0.helperReady = false; $0.killSwitch = self.proton }, now: now).pill, "NOT ENFORCING")
    }

    func testSpanishAndFrench() throws {
        for (lang, title) in [("es", "Sin efecto"), ("fr", "Sans effet")] {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(lang).lproj")))
            XCTAssertEqual(StatusPage.summary(input { $0.killSwitch = self.proton }, now: now, bundle: bundle).title, title)
        }
    }

    // MARK: vpnb status

    func testStatusCarriesTheFlagsAndOmitsThemWhenOff() throws {
        let on = RuntimeStatus(helperReady: true, helperState: "Ready", vpnConnected: true, enforcedRouteCount: 62,
                               enforcing: false, killSwitch: ["includeAllNetworks"])
        let json = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
        XCTAssertTrue(json.contains("\"killSwitch\":[\"includeAllNetworks\"]"), json)
        let off = RuntimeStatus(helperReady: true, helperState: "Ready", vpnConnected: true, enforcedRouteCount: 62, enforcing: true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(off), as: UTF8.self).contains("killSwitch"))
        XCTAssertEqual(try JSONDecoder().decode(RuntimeStatus.self, from: JSONEncoder().encode(on)), on)
    }
}
