// NetworkProfilesTests.swift
// Profiles per network (idea 9): how a network is told apart (router address, its ARP MAC,
// the interface kind), what a profile keeps and how switching moves settings in and out of
// it, and, against a fake kernel, that a network change applies the new lists through the
// normal apply and waits in the settle gate when the VPN has just connected.

import XCTest
@testable import VPNBypassCore

// MARK: - Pure parts

final class NetworkProfilesModelTests: XCTestCase {

    private let home = NetworkIdentity(gateway: "192.168.1.1", routerMAC: "3c:84:6a:01:02:03", kind: .wifi)
    /// Same router address as home, another router: the case the MAC tells apart.
    private let office = NetworkIdentity(gateway: "192.168.1.1", routerMAC: "a4:91:b1:0a:0b:0c", kind: .wifi)

    private func service(_ id: String, enabled: Bool) -> ServiceEntry {
        ServiceEntry(id: id, name: id.capitalized, enabled: enabled, domains: ["\(id).example.com"], ipRanges: [])
    }

    private func baseConfig() -> RouteManager.Config {
        var c = RouteManager.Config()
        c.routingMode = .bypass
        c.domains = [DomainEntry(domain: "en.wikipedia.org")]
        c.services = [service("telegram", enabled: true), service("netflix", enabled: false)]
        return c
    }

    // MARK: ARP and identity

    func testARPGivesTheRouterMACWithLeadingZerosBack() {
        let out = "? (192.168.1.1) at 3c:84:6a:1:2:3 on en0 ifscope [ethernet]\n"
        let entry = NetworkIdentity.parseARP(out, gateway: "192.168.1.1")
        XCTAssertEqual(entry?.mac, "3c:84:6a:01:02:03")
        XCTAssertEqual(entry?.interface, "en0")
    }

    func testARPWithoutACompleteEntryIdentifiesNothing() {
        XCTAssertNil(NetworkIdentity.parseARP("? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]", gateway: "192.168.1.1"))
        XCTAssertNil(NetworkIdentity.parseARP("192.168.1.1 (192.168.1.1) -- no entry", gateway: "192.168.1.1"))
        XCTAssertNil(NetworkIdentity.parseARP("", gateway: "192.168.1.1"))
    }

    func testARPReadsOnlyTheGatewaysLine() {
        let out = """
        ? (192.168.1.10) at 11:22:33:44:55:66 on en0 ifscope [ethernet]
        ? (192.168.1.1) at A4:91:B1:A:B:C on en7 ifscope [ethernet]
        """
        XCTAssertEqual(NetworkIdentity.parseARP(out, gateway: "192.168.1.1")?.mac, "a4:91:b1:0a:0b:0c")
        XCTAssertEqual(NetworkIdentity.parseARP(out, gateway: "192.168.1.1")?.interface, "en7")
        XCTAssertNil(NetworkIdentity.parseARP(out, gateway: "192.168.1.100"), "a prefix of another address is not a match")
    }

    /// `arp -a -n -l`: the gateway's rows, each with its interface and the time it has left.
    func testTheARPTableGivesEachEntrysTimeLeft() {
        let out = """
        Neighbor                Linklayer Address Expire(O) Expire(I)          Netif Refs Prbs
        169.254.34.26           44:a3:bb:8f:b4:48 expired   expired        en0    2
        192.0.2.1               3c:84:6a:1:2:3    1m20s     1m1s           en0    1
        192.0.2.1               3c:84:6a:1:2:3    expired   2m9s           en1    1
        192.0.2.10              (incomplete)      expired   expired        en0    1
        """
        XCTAssertEqual(NetworkIdentity.parseARPTable(out, gateway: "192.0.2.1"), [
            .init(mac: "3c:84:6a:01:02:03", interface: "en0", expiresIn: 80),
            .init(mac: "3c:84:6a:01:02:03", interface: "en1", expiresIn: nil),
        ])
        XCTAssertEqual(NetworkIdentity.parseARPTable(out, gateway: "192.0.2.10"), [], "an incomplete entry is no router")
        XCTAssertEqual(NetworkIdentity.parseExpiry("45s"), 45)
        XCTAssertEqual(NetworkIdentity.parseExpiry("1h2m3s"), 3723)
        XCTAssertNil(NetworkIdentity.parseExpiry("expired"))
        XCTAssertNil(NetworkIdentity.parseExpiry("12"))
    }

    /// The entry has refreshed when it holds another MAC or its time left went up; counting
    /// down, gone or expired, it has not.
    func testAnARPEntryRefreshesWhenItsTimeGoesUpOrItsMACChanges() {
        let snap = NetworkIdentity.ARPEntry(mac: "3c:84:6a:01:02:03", interface: "en0", expiresIn: 80)
        func entry(mac: String = "3c:84:6a:01:02:03", _ left: TimeInterval?) -> NetworkIdentity.ARPEntry {
            .init(mac: mac, interface: "en0", expiresIn: left)
        }
        XCTAssertFalse(NetworkProfiles.arpEntryRefreshed(snapshot: snap, now: entry(70), elapsed: 10), "counting down")
        XCTAssertFalse(NetworkProfiles.arpEntryRefreshed(snapshot: snap, now: entry(nil), elapsed: 90), "expired")
        XCTAssertFalse(NetworkProfiles.arpEntryRefreshed(snapshot: snap, now: nil, elapsed: 5), "gone")
        XCTAssertTrue(NetworkProfiles.arpEntryRefreshed(snapshot: snap, now: entry(1199), elapsed: 10))
        XCTAssertTrue(NetworkProfiles.arpEntryRefreshed(snapshot: snap, now: entry(mac: "a4:91:b1:0a:0b:0c", 30), elapsed: 10))
        XCTAssertTrue(NetworkProfiles.arpEntryRefreshed(
            snapshot: .init(mac: snap.mac, interface: "en0", expiresIn: nil), now: entry(60), elapsed: 5),
            "an expired entry answered again")
    }

    func testBroadcastAndEmptyMACsAreNoRouter() {
        XCTAssertNil(NetworkIdentity.normalizedMAC("ff:ff:ff:ff:ff:ff"))
        XCTAssertNil(NetworkIdentity.normalizedMAC("0:0:0:0:0:0"))
        XCTAssertNil(NetworkIdentity.normalizedMAC("3c:84:6a:01:02"))
        XCTAssertNil(NetworkIdentity.normalizedMAC("3c:84:6a:01:02:zz"))
        XCTAssertEqual(NetworkIdentity.normalizedMAC("3C:84:6A:01:02:03"), "3c:84:6a:01:02:03")
    }

    func testTheInterfaceKindComesFromSystemConfiguration() {
        XCTAssertEqual(NetworkIdentity.Kind(interfaceType: "IEEE80211"), .wifi)
        XCTAssertEqual(NetworkIdentity.Kind(interfaceType: "Ethernet"), .ethernet)
        XCTAssertEqual(NetworkIdentity.Kind(interfaceType: "Bridge"), .other)
        XCTAssertEqual(NetworkIdentity.Kind(interfaceType: nil), .other)
    }

    /// Two routers on the same address, or the same router over Wi-Fi and Ethernet, are
    /// different networks.
    func testANetworkIsItsRouterAddressMACAndKind() {
        var c = baseConfig()
        c = NetworkProfiles.creatingProfile(named: "Home", for: home, in: c)
        XCTAssertNil(NetworkProfiles.switchTarget(for: home, in: c), "already in use")
        XCTAssertEqual(NetworkProfiles.switchTarget(for: office, in: c), .otherNetworks, "another MAC on the same address")
        var wired = home
        wired.kind = .ethernet
        XCTAssertEqual(NetworkProfiles.switchTarget(for: wired, in: c), .otherNetworks, "same router over Ethernet")
        var moved = home
        moved.gateway = "192.168.1.254"
        XCTAssertEqual(NetworkProfiles.switchTarget(for: moved, in: c), .otherNetworks, "same MAC at another address")
    }

    func testAnUnidentifiedNetworkOrNoProfilesChangeNothing() {
        let c = NetworkProfiles.creatingProfile(named: "Home", for: home, in: baseConfig())
        XCTAssertNil(NetworkProfiles.switchTarget(for: nil, in: c))
        XCTAssertNil(NetworkProfiles.switchTarget(for: office, in: baseConfig()), "no profiles: nothing to switch")
    }

    // MARK: What a profile keeps

    /// Services are kept by id: the definitions stay the config's own (the catalogue is never
    /// copied), an id that is gone is skipped, a service the profile does not name is off.
    func testAProfileKeepsServicesByIdOnly() throws {
        let settings = ProfileSettings(capturing: baseConfig())
        XCTAssertEqual(settings.enabledServiceIds, ["telegram"])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertFalse(json.contains("telegram.example.com"), "a service's domains were copied into the profile: \(json)")

        var other = settings
        other.enabledServiceIds = ["netflix", "custom_gone"]
        var config = baseConfig()
        config.services.append(service("custom_new", enabled: true))
        let applied = other.applied(to: config)
        XCTAssertEqual(applied.services.filter(\.enabled).map(\.id), ["netflix"])
        XCTAssertEqual(applied.services.map(\.id), config.services.map(\.id), "the service list itself is untouched")
        XCTAssertEqual(applied.services.map(\.domains), config.services.map(\.domains))
    }

    /// A built-in service a custom service of the same name holds stays off, even when the
    /// profile was saved with it on: both would route under one name.
    func testAProfileKeepsAHeldBuiltInServiceOff() {
        var c = baseConfig()
        var s = ProfileSettings(capturing: c)
        s.enabledServiceIds = ["telegram", "netflix", "custom_netflix"]
        c.services.append(ServiceEntry(id: "custom_netflix", name: "Netflix", enabled: false,
                                       domains: ["tv.example.com"], ipRanges: [], isCustom: true))
        XCTAssertEqual(s.applied(to: c).services.filter(\.enabled).map(\.id), ["telegram", "custom_netflix"])
    }

    func testACustomModeProfileTurnsTheRuleEngineOn() {
        var c = baseConfig()
        c.schemaVersion = 1
        var s = ProfileSettings(capturing: c)
        s.routingMode = .custom
        XCTAssertEqual(s.applied(to: c).schemaVersion, 2)
    }

    // MARK: Switching

    /// Saving a profile changes nothing in use; edits made on its network stay in it, and
    /// leaving the network brings back the settings from before.
    func testEditsStayInTheProfileInUse() throws {
        let base = baseConfig()
        var c = base
        c = NetworkProfiles.creatingProfile(named: "Office", for: office, in: c)
        XCTAssertEqual(ProfileSettings(capturing: c), ProfileSettings(capturing: base), "saving changed the settings in use")
        let officeId = c.activeProfileId

        // An edit at the office.
        c.routingMode = .vpnOnly
        c.inverseDomains = [DomainEntry(domain: "intranet.example.com")]
        c.services[0].enabled = false

        // Home has no profile: Other networks, as before the profile was saved.
        c = NetworkProfiles.switching(c, to: try XCTUnwrap(NetworkProfiles.switchTarget(for: home, in: c)))
        XCTAssertNil(c.activeProfileId)
        XCTAssertNil(c.otherNetworksSettings, "nothing is kept apart while Other networks is in use")
        XCTAssertEqual(ProfileSettings(capturing: c), ProfileSettings(capturing: base))

        // Back at the office, the edit is there.
        c = NetworkProfiles.switching(c, to: try XCTUnwrap(NetworkProfiles.switchTarget(for: office, in: c)))
        XCTAssertEqual(c.activeProfileId, officeId)
        XCTAssertEqual(c.routingMode, .vpnOnly)
        XCTAssertEqual(c.inverseDomains.map(\.domain), ["intranet.example.com"])
        XCTAssertEqual(c.services.filter(\.enabled).map(\.id), [])
        XCTAssertEqual(c.otherNetworksSettings, ProfileSettings(capturing: base))
    }

    func testANetworkBelongsToOneProfile() throws {
        var c = NetworkProfiles.creatingProfile(named: "Home", for: home, in: baseConfig())
        c = NetworkProfiles.creatingProfile(named: "Flat", for: home, in: c)
        XCTAssertEqual(c.profiles.map(\.networks.count), [0, 1])
        let homeId = try XCTUnwrap(c.profiles.first?.id)
        c = NetworkProfiles.addingNetwork(home, to: homeId, in: c)
        XCTAssertEqual(c.profiles.map(\.networks.count), [1, 0])
        XCTAssertEqual(NetworkProfiles.switchTarget(for: home, in: c), .profile(homeId))
    }

    func testDeletingTheProfileInUseBringsBackOtherNetworks() throws {
        var c = NetworkProfiles.creatingProfile(named: "Office", for: office, in: baseConfig())
        c.domains = []
        let id = try XCTUnwrap(c.activeProfileId)
        c = NetworkProfiles.removingProfile(id, in: c)
        XCTAssertTrue(c.profiles.isEmpty)
        XCTAssertNil(c.activeProfileId)
        XCTAssertNil(c.otherNetworksSettings)
        XCTAssertEqual(c.domains.map(\.domain), ["en.wikipedia.org"])
    }

    func testSwitchingToAProfileThatIsGoneChangesNothing() {
        let c = NetworkProfiles.creatingProfile(named: "Office", for: office, in: baseConfig())
        let after = NetworkProfiles.switching(c, to: .profile(UUID()))
        XCTAssertEqual(after.activeProfileId, c.activeProfileId)
        XCTAssertEqual(after.profiles, c.profiles)
    }

    func testNamesMustBeFreeAndNotBlank() {
        let c = NetworkProfiles.creatingProfile(named: "Office", for: office, in: baseConfig())
        XCTAssertFalse(NetworkProfiles.nameIsFree("  ", in: c.profiles))
        XCTAssertFalse(NetworkProfiles.nameIsFree("office ", in: c.profiles))
        XCTAssertFalse(NetworkProfiles.nameIsFree("Other networks", in: c.profiles))
        XCTAssertTrue(NetworkProfiles.nameIsFree("Home", in: c.profiles))
    }

    /// The switch applies at once only when nothing else will: with no VPN the connect
    /// applies, paused Resume does, and a connect or a waiting settle apply carries it.
    func testWhenASwitchApplies() {
        XCTAssertEqual(NetworkProfiles.applyAction(vpnConnected: true, justConnected: false, paused: false, settlePending: false), .now)
        XCTAssertEqual(NetworkProfiles.applyAction(vpnConnected: false, justConnected: false, paused: false, settlePending: false), .none)
        XCTAssertEqual(NetworkProfiles.applyAction(vpnConnected: true, justConnected: true, paused: false, settlePending: false), .none)
        XCTAssertEqual(NetworkProfiles.applyAction(vpnConnected: true, justConnected: false, paused: true, settlePending: false), .none)
        XCTAssertEqual(NetworkProfiles.applyAction(vpnConnected: true, justConnected: false, paused: false, settlePending: true), .none)
    }

    // MARK: Saved and exported

    func testProfilesSurviveASaveAndOldConfigsHaveNone() throws {
        let c = NetworkProfiles.creatingProfile(named: "Office", for: office, in: baseConfig())
        let decoded = try JSONDecoder().decode(RouteManager.Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded.profiles, c.profiles)
        XCTAssertEqual(decoded.activeProfileId, c.activeProfileId)
        XCTAssertEqual(decoded.otherNetworksSettings, c.otherNetworksSettings)

        let old = try JSONDecoder().decode(RouteManager.Config.self, from: Data(#"{"routingMode":"bypass"}"#.utf8))
        XCTAssertTrue(old.profiles.isEmpty)
        XCTAssertNil(old.activeProfileId)
        XCTAssertNil(old.otherNetworksSettings)
    }

    /// The router's address and MAC are this Mac's note, like failed lookups: not exported.
    func testAnExportKeepsProfilesButNotTheirNetworks() {
        var c = NetworkProfiles.creatingProfile(named: "Office", for: office, in: baseConfig())
        c.profiles[0].settings.domains[0].resolveFailures = .init(count: 3, since: Date())
        let exported = c.sanitizedForExport()
        XCTAssertEqual(exported.profiles.map(\.name), ["Office"])
        XCTAssertEqual(exported.profiles[0].networks, [])
        XCTAssertNil(exported.profiles[0].settings.domains[0].resolveFailures)
    }

    // MARK: Words

    func testTheWordsAreTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["es", "fr"] {
            let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
            XCTAssertNotEqual(NetworkProfiles.otherNetworksName(in: bundle), NetworkProfiles.otherNetworksName(), language)
            XCTAssertNotEqual(NetworkProfiles.networkCount(2, in: bundle), NetworkProfiles.networkCount(2), language)
            XCTAssertNotEqual(NetworkProfiles.useOnThisNetworkName("X", in: bundle), NetworkProfiles.useOnThisNetworkName("X"), language)
            XCTAssertNotEqual(NetworkProfiles.deleteQuestion("X", in: bundle), NetworkProfiles.deleteQuestion("X"), language)
            XCTAssertNotEqual(GeneralPage.Group.networkProfiles.title(in: bundle), GeneralPage.Group.networkProfiles.title(), language)
        }
        XCTAssertEqual(home.title(), "Wi-Fi, router 192.168.1.1")
        let fr = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/fr.lproj")))
        XCTAssertEqual(home.title(in: fr), "Wi-Fi, routeur 192.168.1.1")
        XCTAssertEqual(NetworkProfiles.detail(mode: .bypass, networks: 2), "Bypass · 2 networks")
    }
}

// MARK: - Against a fake kernel

@MainActor
final class NetworkProfileSwitchTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, gateway: String?,
                        loading: Bool, helper: HelperState, update: Date?, network: NetworkIdentity?)!
    private var kernel: FakeKernel!

    private let home = NetworkIdentity(gateway: "192.168.1.1", routerMAC: "3c:84:6a:01:02:03", kind: .wifi)
    private let office = NetworkIdentity(gateway: "192.168.1.1", routerMAC: "a4:91:b1:0a:0b:0c", kind: .wifi)
    /// The network the override answers.
    private var onNetwork: NetworkIdentity?
    /// What `arp -a -n -l` prints.
    private var arpTable: String?

    override func setUp() async throws {
        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.localGateway, rm.isLoading,
                 HelperManager.shared.helperState, rm.lastUpdate, rm.currentNetwork)
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.autoApplyOnVPN = true
        // Two services of address ranges only, so an apply needs no DNS: Lab at home, Office
        // at the office.
        cfg.services = [
            ServiceEntry(id: "custom_lab", name: "Lab", enabled: true, domains: [], ipRanges: ["203.0.113.0/24"], isCustom: true),
            ServiceEntry(id: "custom_office", name: "Office", enabled: false, domains: [], ipRanges: ["198.51.100.0/24"], isCustom: true),
        ]
        rm.config = cfg
        rm.resetShutdownStateForTests()
        rm.pendingKernelAdds = []
        rm.isVPNConnected = true
        rm.vpnInterface = "utun4"
        rm.localGateway = "192.168.1.1"
        rm.isLoading = false
        kernel = FakeKernel(installed: ["203.0.113.0/24"])
        kernel.attach(to: rm)
        rm.activeRoutes = [.init(destination: "203.0.113.0/24", gateway: "192.168.1.1", source: "Lab", timestamp: Date())]
        onNetwork = home
        rm.detectNetworkIdentityOverrideForTests = { [unowned self] in self.onNetwork }
        HelperManager.shared.helperState = .ready

        // An Office profile, saved on the office network: Office on, Lab off.
        rm.currentNetwork = office
        XCTAssertTrue(rm.createProfile(named: "Office"))
        rm.config.services[0].enabled = false
        rm.config.services[1].enabled = true
        // Leave it for home without an apply, so the test starts on home's settings.
        rm.isVPNConnected = false
        await rm.updateNetworkProfile()
        rm.isVPNConnected = true
        XCTAssertNil(rm.config.activeProfileId, "setup: home is Other networks")
        XCTAssertEqual(rm.config.services.filter(\.enabled).map(\.id), ["custom_lab"])
    }

    override func tearDown() async throws {
        if rm.pendingReconnectApply != nil { _ = await rm.pause(for: .untilResume) }
        rm.endPause(reason: "test over", apply: false)
        await waitForApply()
        FakeKernel.detach(from: rm)
        rm.detectVPNInterfaceOverrideForTests = nil
        rm.cancelARPRecheckForTests()
        rm.detectNetworkIdentityOverrideForTests = nil
        rm.readARPTableOverrideForTests = nil
        rm.currentNetworkInterface = nil
        NetworkProfiles.arpRecheckPoll = 5
        rm.activeRoutes = []
        rm.pendingKernelAdds = []
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.localGateway = saved.gateway
        rm.isLoading = saved.loading
        rm.lastUpdate = saved.update
        rm.currentNetwork = saved.network
        HelperManager.shared.helperState = saved.helper
        rm.resetShutdownStateForTests()
    }

    private func waitForApply() async {
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if !rm.isApplyingRoutes { return }
        }
    }

    /// Arriving at the office with the VPN up: the Office profile is put in use and its
    /// ranges replace home's through the normal apply.
    func testMovingToTheOfficeAppliesItsLists() async {
        onNetwork = office
        await rm.updateNetworkProfile()
        XCTAssertEqual(rm.currentNetwork, office)
        XCTAssertEqual(rm.config.profiles.first?.id, rm.config.activeProfileId)
        XCTAssertEqual(rm.config.services.filter(\.enabled).map(\.id), ["custom_office"])
        await Task.yield()
        await waitForApply()
        XCTAssertEqual(kernel.installed, ["198.51.100.0/24"], "the office's range in, home's out")

        // And back home.
        onNetwork = home
        await rm.updateNetworkProfile()
        await Task.yield()
        await waitForApply()
        XCTAssertNil(rm.config.activeProfileId)
        XCTAssertEqual(kernel.installed, ["203.0.113.0/24"])
    }

    /// Home and the office share a router address. Right after the move the ARP table can
    /// still hold home's router, so the network reads as home: it is read again once that
    /// entry refreshes, and the office's profile is put in use then, not on a later pass.
    func testAStaleARPEntryIsReadAgainOnceItRefreshes() async throws {
        NetworkProfiles.arpRecheckPoll = 0.05
        rm.readARPTableOverrideForTests = { [unowned self] in self.arpTable }
        rm.currentNetwork = home
        arpTable = "192.168.1.1             3c:84:6a:1:2:3    1m20s     1m1s           en0    1\n"
        rm.noteNetworkChange()
        await rm.updateNetworkProfile()   // still home's entry
        XCTAssertNil(rm.config.activeProfileId)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(rm.config.activeProfileId, "an entry that has not refreshed is not read again")

        // The office router answers: the entry now holds its MAC.
        onNetwork = office
        arpTable = "192.168.1.1             a4:91:b1:a:b:c    19m59s    19m59s         en0    1\n"
        let deadline = Date().addingTimeInterval(3)
        while rm.config.activeProfileId == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(rm.config.activeProfileId, rm.config.profiles.first?.id, "the office profile is in use")
    }

    /// Wi-Fi and Ethernet to one router: two rows with the same address and MAC. The network
    /// was read on Ethernet (en7), so only en7's row is watched. The Wi-Fi row listed first
    /// refreshing on its own must not count, and the re-read waits for en7's.
    func testTheARPRecheckWatchesTheInterfaceTheNetworkWasReadOn() async throws {
        NetworkProfiles.arpRecheckPoll = 0.05
        rm.readARPTableOverrideForTests = { [unowned self] in self.arpTable }
        rm.currentNetwork = home
        rm.currentNetworkInterface = "en7"
        arpTable = """
        192.168.1.1             3c:84:6a:1:2:3    1m20s     1m1s           en0    1
        192.168.1.1             3c:84:6a:1:2:3    1m20s     1m1s           en7    1
        """
        rm.noteNetworkChange()
        await rm.updateNetworkProfile()
        XCTAssertNil(rm.config.activeProfileId)

        // The office network answers the next read, but only the Wi-Fi row has refreshed.
        onNetwork = office
        arpTable = """
        192.168.1.1             3c:84:6a:1:2:3    19m59s    19m59s         en0    1
        192.168.1.1             3c:84:6a:1:2:3    1m20s     1m1s           en7    1
        """
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(rm.config.activeProfileId, "the Wi-Fi row refreshing is not the Ethernet entry refreshing")

        // Control: en7's row now holds the office router.
        arpTable = """
        192.168.1.1             3c:84:6a:1:2:3    19m59s    19m59s         en0    1
        192.168.1.1             a4:91:b1:a:b:c    19m59s    19m59s         en7    1
        """
        let deadline = Date().addingTimeInterval(3)
        while rm.config.activeProfileId == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(rm.config.activeProfileId, rm.config.profiles.first?.id, "en7's refresh reads the network again")
    }

    /// Use on This Network at home moves home to the Office profile and puts it in use.
    func testUseOnThisNetworkMovesThisNetworkToTheProfile() async throws {
        let officeId = try XCTUnwrap(rm.config.profiles.first?.id)
        rm.currentNetwork = home
        rm.useProfileOnThisNetwork(officeId)
        XCTAssertEqual(rm.config.activeProfileId, officeId)
        XCTAssertEqual(rm.config.profiles.first?.networks, [office, home])
        XCTAssertEqual(rm.config.services.filter(\.enabled).map(\.id), ["custom_office"])
        await Task.yield()
        await waitForApply()
        XCTAssertEqual(kernel.installed, ["198.51.100.0/24"])
    }

    /// At launch on the office network the Office profile is in use before the startup apply,
    /// and nothing is written by the switch itself.
    func testAtLaunchTheProfileIsChosenBeforeTheStartupApply() async {
        let before = kernel.installed
        onNetwork = office
        await rm.selectNetworkProfileBeforeStartupApply()
        XCTAssertEqual(rm.config.activeProfileId, rm.config.profiles.first?.id)
        XCTAssertEqual(rm.config.services.filter(\.enabled).map(\.id), ["custom_office"])
        await Task.yield()
        await waitForApply()
        XCTAssertEqual(kernel.installed, before, "the startup apply writes, not the switch")
    }

    /// The same network on the next pass switches nothing and writes nothing.
    func testStayingOnANetworkWritesNothing() async {
        let before = kernel.installed
        await rm.updateNetworkProfile()
        await Task.yield()
        await waitForApply()
        XCTAssertEqual(kernel.installed, before)
    }

    /// Joining the office network brings the VPN up on it: the switch happens on that pass,
    /// and the lists wait in the settle gate like any post-reconnect apply.
    func testAtAConnectTheSwitchWaitsInTheSettleGate() async {
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.lastUpdate = nil
        onNetwork = office
        rm.detectVPNInterfaceOverrideForTests = { (true, "utun4", .wireGuard) }
        await rm.checkVPNStatus()
        XCTAssertTrue(rm.isVPNConnected)
        XCTAssertNotNil(rm.config.activeProfileId, "the office profile is in use")
        XCTAssertNotNil(rm.pendingReconnectApply, "the apply waits in the settle gate")
        XCTAssertFalse(kernel.installed.contains("198.51.100.0/24"), "nothing is written before the tunnel settles")
    }

    /// The settled apply after that connect is an auto apply, whose orphan grace keeps routes
    /// that only rotated out of DNS for 30 minutes. Home's ranges did not rotate out, the
    /// profile took them off: they go at once, or home's sites skip the VPN at the office.
    func testTheSettledApplyAfterASwitchKeepsNothingFromTheOldProfile() async {
        rm.isVPNConnected = false
        rm.vpnInterface = nil
        rm.lastUpdate = nil
        onNetwork = office
        rm.detectVPNInterfaceOverrideForTests = { (true, "utun4", .wireGuard) }
        await rm.checkVPNStatus()
        XCTAssertNotNil(rm.pendingReconnectApply)
        // What the settle task runs once the tunnel has settled.
        await rm.applyAllRoutes(orphanGrace: true)
        XCTAssertEqual(kernel.installed, ["198.51.100.0/24"], "home's range is out, not kept by the grace")
        XCTAssertEqual(rm.activeRoutes.map(\.destination), ["198.51.100.0/24"])
    }

    /// Paused in the same mode, the switch changes the lists and Resume applies them.
    func testWhilePausedTheSwitchWritesNothing() async {
        await rm.pause(for: .untilResume)
        let before = kernel.installed
        onNetwork = office
        await rm.updateNetworkProfile()
        await Task.yield()
        await waitForApply()
        XCTAssertTrue(rm.isPaused)
        XCTAssertEqual(kernel.installed, before)
        XCTAssertEqual(rm.config.services.filter(\.enabled).map(\.id), ["custom_office"])
    }
}

// MARK: - Live, opt-in

/// Reads this Mac's own network through the real paths (networksetup, arp, configd). Skipped
/// unless VPNB_LIVE_NETWORK=1; never runs in CI. Prints nothing about the network.
@MainActor
final class NetworkIdentityLiveTests: XCTestCase {
    func testThisMacsNetworkIsIdentified() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VPNB_LIVE_NETWORK"] == "1", "live test — run with VPNB_LIVE_NETWORK=1")
        let rm = RouteManager.shared
        let saved = rm.localGateway
        defer { rm.localGateway = saved }
        await rm.checkVPNStatus()
        let gateway = try XCTUnwrap(rm.localGateway, "no router on this Mac")
        let read = await rm.detectNetworkIdentity()
        let network = try XCTUnwrap(read, "the router's ARP entry was not read")
        XCTAssertEqual(network.gateway, gateway)
        XCTAssertNotNil(NetworkIdentity.normalizedMAC(network.routerMAC))
        XCTAssertNotEqual(network.kind, .other, "a Mac on a LAN reaches its router over Wi-Fi or Ethernet")
        let again = await rm.detectNetworkIdentity()
        XCTAssertEqual(again, network, "two reads of one network must agree")
    }
}
