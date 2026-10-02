// ServiceNameClashTests.swift
// A custom service may not take the name of another service or of a Bypass list entry,
// because routes are tracked by that name: the two would share one source, the dropdown would
// group both under one row, and removing one could remove the other's routes. Covers the pure
// check, RouteManager's add, update and undo, config import, and that a config.json already holding
// such a name still loads, the Bypass list refusing a service's name, and the put-back of a shared
// source's routes when a custom service leaves it. The put-back tests run against FakeKernel
// with a fake gateway, so nothing touches the real routing table or the network. An app update
// that brings a built-in service named like a custom one keeps the built-in one off.

import XCTest
@testable import VPNBypassCore

@MainActor
final class ServiceNameClashTests: RouteManagerTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedLogs: [RouteManager.LogEntry] = []
    private var savedVPNConnected = false
    private var savedGateway: String?
    private var savedVPNGateway: String?
    private var savedActiveRoutes: [RouteManager.ActiveRoute] = []
    private var savedPendingKernelAdds: Set<String> = []
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        savedConfig = rm.config
        savedLogs = rm.recentLogs
        savedVPNConnected = rm.isVPNConnected
        savedGateway = rm.localGateway
        savedVPNGateway = rm.vpnGateway
        savedActiveRoutes = rm.activeRoutes
        savedPendingKernelAdds = rm.pendingKernelAdds
        rm.isVPNConnected = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = [DomainEntry(domain: "example.com")]
        cfg.inverseDomains = []
        rm.config = cfg
    }

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        rm.config = savedConfig
        rm.recentLogs = savedLogs
        rm.isVPNConnected = savedVPNConnected
        rm.localGateway = savedGateway
        rm.vpnGateway = savedVPNGateway
        rm.activeRoutes = savedActiveRoutes
        // A batch add records its destinations here until a teardown; keep the fake ones out
        // of the next test's teardown.
        rm.pendingKernelAdds = savedPendingKernelAdds
        FakeKernel.detach(from: rm)
        rm.cancelAllRetries()
        super.tearDown()
    }

    private func custom(_ id: String, _ name: String) -> ServiceEntry {
        ServiceEntry(id: id, name: name, enabled: true, domains: ["\(id).test"], ipRanges: [], isCustom: true)
    }

    // MARK: - The check

    func testANameTakenByABuiltInServiceIsAClashWhateverItsCase() {
        for typed in ["Netflix", "netflix", "  NETFLIX ", "netFlix\n"] {
            XCTAssertEqual(rm.customServiceNameClash(typed), .service(name: "Netflix"), typed)
        }
    }

    func testANameThatIsOnTheBypassListIsAClash() {
        XCTAssertEqual(rm.customServiceNameClash("example.com"), .domain("example.com"))
        XCTAssertEqual(rm.customServiceNameClash("Example.COM "), .domain("example.com"))
    }

    func testAFreeNameAndAnEmptyOneAreNotClashes() {
        XCTAssertNil(rm.customServiceNameClash("Work Tools"))
        XCTAssertNil(rm.customServiceNameClash("example.org"))
        XCTAssertNil(rm.customServiceNameClash("   "))
    }

    func testAServiceKeepingItsOwnNameIsNotAClash() {
        rm.config.services.append(custom("custom_a", "Work Tools"))
        XCTAssertNil(rm.customServiceNameClash("work tools", excluding: "custom_a"))
        XCTAssertEqual(rm.customServiceNameClash("work tools"), .service(name: "Work Tools"))
    }

    // MARK: - Add and update

    func testAddRefusesATakenNameAndSavesNothing() {
        let before = rm.config.services.count
        XCTAssertEqual(rm.addCustomService(name: "Netflix", domains: ["mine.test"], ipRanges: []), .service(name: "Netflix"))
        XCTAssertEqual(rm.addCustomService(name: "example.com", domains: ["mine.test"], ipRanges: []), .domain("example.com"))
        XCTAssertEqual(rm.config.services.count, before)

        XCTAssertNil(rm.addCustomService(name: "Work Tools", domains: ["mine.test"], ipRanges: []))
        XCTAssertEqual(rm.config.services.count, before + 1)
        XCTAssertEqual(rm.addCustomService(name: "WORK TOOLS", domains: ["other.test"], ipRanges: []),
                       .service(name: "Work Tools"), "a second custom service may not take the first one's name")
        XCTAssertEqual(rm.config.services.count, before + 1)
    }

    func testUpdateRefusesARenameOntoATakenNameAndKeepsTheOldOne() throws {
        rm.config.services.append(custom("custom_a", "Work Tools"))
        rm.config.services.append(custom("custom_b", "Home Lab"))

        XCTAssertEqual(rm.updateCustomService(id: "custom_a", name: "home lab", domains: ["a.test"], ipRanges: []),
                       .service(name: "Home Lab"))
        XCTAssertEqual(rm.updateCustomService(id: "custom_a", name: "Spotify", domains: ["a.test"], ipRanges: []),
                       .service(name: "Spotify"))
        XCTAssertEqual(rm.updateCustomService(id: "custom_a", name: "example.com", domains: ["a.test"], ipRanges: []),
                       .domain("example.com"))
        XCTAssertEqual(try XCTUnwrap(rm.config.services.first { $0.id == "custom_a" }).name, "Work Tools")

        XCTAssertNil(rm.updateCustomService(id: "custom_a", name: "Work Tools", domains: ["b.test"], ipRanges: []),
                     "an edit that keeps the name saves")
        XCTAssertEqual(try XCTUnwrap(rm.config.services.first { $0.id == "custom_a" }).domains, ["b.test"])
    }

    func testUndoDoesNotBringBackADeletedServiceWhoseNameWasTakenSince() {
        let deleted = custom("custom_old", "Work Tools")
        XCTAssertNil(rm.addCustomService(name: "work tools", domains: ["new.test"], ipRanges: []),
                     "the name is free once the first one is deleted")
        let before = rm.config.services.map(\.id)
        XCTAssertFalse(rm.restoreCustomService(deleted, at: 0))
        XCTAssertEqual(rm.config.services.map(\.id), before)

        let free = custom("custom_free", "Home Lab")
        XCTAssertTrue(rm.restoreCustomService(free, at: 0), "a name nobody took comes back")
    }

    // MARK: - Import

    private func exportFile(services: [ServiceEntry], domains: [DomainEntry]) throws -> URL {
        var cfg = Config()
        cfg.services = services
        cfg.domains = domains
        let data = try JSONEncoder().encode(RouteManager.ExportData(version: "2.0", exportDate: Date(), config: cfg))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clash-\(UUID().uuidString).json")
        try data.write(to: url)
        tempFiles.append(url)
        return url
    }

    func testImportRefusesACustomServiceNamedLikeABuiltInOne() throws {
        // The file has no built-in services at all; the merge adds Netflix back, and the clash
        // is with that one.
        let url = try exportFile(services: [custom("custom_n", "netflix")], domains: [])
        let before = rm.config.services.map(\.id)

        XCTAssertFalse(rm.importConfig(from: url))
        XCTAssertEqual(rm.config.services.map(\.id), before, "nothing was imported")
        XCTAssertEqual(rm.config.domains.map(\.domain), ["example.com"])
        XCTAssertEqual(rm.lastImportRefusal,
                       "Nothing was imported. The custom service \u{201C}netflix\u{201D} has the same name as the service \u{201C}Netflix\u{201D}. Rename it in the file and import again.")
    }

    func testImportRefusesACustomServiceNamedLikeAnEntryOnItsBypassList() throws {
        let url = try exportFile(services: Config.defaultServices + [custom("custom_s", "Shop.example")],
                                 domains: [DomainEntry(domain: "shop.example")])
        XCTAssertFalse(rm.importConfig(from: url))
        XCTAssertFalse(rm.config.domains.contains { $0.domain == "shop.example" })
        XCTAssertEqual(rm.lastImportRefusal,
                       "Nothing was imported. The custom service \u{201C}Shop.example\u{201D} has the same name as shop.example on the Bypass list. Rename it in the file and import again.")
    }

    func testImportRefusesTwoCustomServicesWithOneName() throws {
        let url = try exportFile(services: Config.defaultServices + [custom("custom_a", "Work Tools"), custom("custom_b", "work tools")],
                                 domains: [])
        XCTAssertFalse(rm.importConfig(from: url))
        XCTAssertNotNil(rm.lastImportRefusal)
    }

    func testImportOfDistinctNamesWorksAndClearsTheLastRefusal() throws {
        let bad = try exportFile(services: [custom("custom_n", "Netflix")], domains: [])
        XCTAssertFalse(rm.importConfig(from: bad))
        XCTAssertNotNil(rm.lastImportRefusal)

        let good = try exportFile(services: Config.defaultServices + [custom("custom_a", "Work Tools")],
                                  domains: [DomainEntry(domain: "imported.example")])
        XCTAssertTrue(rm.importConfig(from: good))
        XCTAssertNil(rm.lastImportRefusal)
        XCTAssertTrue(rm.config.services.contains { $0.id == "custom_a" && $0.name == "Work Tools" })
        XCTAssertTrue(rm.config.domains.contains { $0.domain == "imported.example" })
    }

    // MARK: - Existing configs

    func testAConfigThatAlreadyHasAClashStillLoads() {
        rm.config.services.append(custom("custom_n", "Netflix"))
        rm.config.services.append(custom("custom_e", "example.com"))
        rm.saveConfig()
        rm.config = RouteManager.Config()
        rm.loadConfig()
        XCTAssertFalse(rm.isConfigLoadFailed)
        XCTAssertTrue(rm.config.services.contains { $0.id == "custom_n" && $0.name == "Netflix" })
        XCTAssertTrue(rm.config.services.contains { $0.id == "custom_e" && $0.name == "example.com" })
        XCTAssertTrue(rm.config.domains.contains { $0.domain == "example.com" })
    }

    // MARK: - The Bypass list, the other way round

    func testTheBypassListRefusesADomainAServiceHasAsItsName() {
        rm.config.services.append(custom("custom_s", "Shop.Example"))
        XCTAssertEqual(rm.addDomain("  SHOP.example "),
                       .failure(.nameTakenByService(value: "shop.example", service: "Shop.Example")))
        XCTAssertEqual(rm.config.domains.map(\.domain), ["example.com"], "nothing was added")
        XCTAssertNoThrow(try rm.addDomain("other.example").get(), "a name no service has still goes in")
    }

    func testUndoDoesNotBringBackADomainAServiceTookAsItsNameSince() {
        let deleted = DomainEntry(domain: "shop.example")
        rm.config.services.append(custom("custom_s", "shop.example"))
        XCTAssertFalse(rm.undo(.domain(deleted, index: 0, list: .bypass)))
        XCTAssertEqual(rm.config.domains.map(\.domain), ["example.com"])
        rm.config.services.removeAll { $0.id == "custom_s" }
        XCTAssertTrue(rm.undo(.domain(deleted, index: 0, list: .bypass)), "once the name is free it comes back")
    }

    // MARK: - Getting out of a clash an old config holds

    func testTheRoutesSharingASourceAreTheEnabledOwnersWithExactlyThatName() {
        let netflix = try! XCTUnwrap(rm.config.services.firstIndex { $0.id == "netflix" })
        rm.config.services[netflix].enabled = true
        rm.config.services.append(custom("custom_n", "Netflix"))
        rm.config.services.append(custom("custom_e", "example.com"))

        var sharers = rm.routeSourceSharers("Netflix", excludingService: "custom_n")
        XCTAssertEqual(sharers.services.map(\.id), ["netflix"])
        XCTAssertTrue(sharers.domains.isEmpty)
        sharers = rm.routeSourceSharers("example.com", excludingService: "custom_e")
        XCTAssertTrue(sharers.services.isEmpty)
        XCTAssertEqual(sharers.domains.map(\.domain), ["example.com"])
        XCTAssertTrue(rm.routeSourceSharers("netflix", excludingService: "custom_x").services.isEmpty,
                      "routes are tracked by the exact name, so another case shares nothing")

        rm.config.services[netflix].enabled = false
        rm.config.domains[0].enabled = false
        XCTAssertTrue(rm.routeSourceSharers("Netflix", excludingService: "custom_n").services.isEmpty, "an owner that is off has no routes")
        XCTAssertTrue(rm.routeSourceSharers("example.com", excludingService: "custom_e").domains.isEmpty)

        rm.config.services[netflix].enabled = true
        rm.config.routingMode = .vpnOnly
        XCTAssertTrue(rm.routeSourceSharers("Netflix", excludingService: "custom_n").services.isEmpty, "no Bypass routes in VPN Only")
    }

    private func waitForTheGate() async {
        var polls = 0
        while rm.isApplyingRoutes && polls < 100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            polls += 1
        }
        XCTAssertFalse(rm.isApplyingRoutes, "a route operation never finished")
    }

    private let notPutBack = "Routes of Netflix not put back: no local gateway detected. Try Refresh Routes."

    /// Deleting the custom "Netflix" takes out every route under the source "Netflix", the
    /// built-in one's too, so the delete puts those back. No gateway is known here, so the
    /// put-back stops at its first step and logs it; nothing reaches the routing table.
    func testDeletingACustomServiceThatSharedANamePutsTheOtherOwnersRoutesBack() async {
        let netflix = try! XCTUnwrap(rm.config.services.firstIndex { $0.id == "netflix" })
        rm.config.services[netflix].enabled = true
        rm.config.services.append(custom("custom_n", "Netflix"))
        rm.isVPNConnected = true
        rm.localGateway = nil
        rm.recentLogs = []

        rm.removeCustomService("custom_n")
        await waitForTheGate()
        XCTAssertFalse(rm.config.services.contains { $0.id == "custom_n" })
        XCTAssertTrue(rm.recentLogs.contains { $0.message == notPutBack }, rm.recentLogs.map(\.message).joined(separator: "\n"))
    }

    func testRenamingACustomServiceThatSharedANamePutsTheOtherOwnersRoutesBack() async {
        let netflix = try! XCTUnwrap(rm.config.services.firstIndex { $0.id == "netflix" })
        rm.config.services[netflix].enabled = true
        rm.config.services.append(custom("custom_n", "Netflix"))
        rm.isVPNConnected = true
        rm.localGateway = nil
        rm.recentLogs = []

        XCTAssertNil(rm.updateCustomService(id: "custom_n", name: "My Netflix", domains: ["custom_n.test"], ipRanges: []))
        await waitForTheGate()
        XCTAssertTrue(rm.recentLogs.contains { $0.message == notPutBack }, rm.recentLogs.map(\.message).joined(separator: "\n"))
    }

    func testDeletingACustomServiceWithAFreeNamePutsNothingBack() async {
        rm.config.services.append(custom("custom_w", "Work Tools"))
        rm.isVPNConnected = true
        rm.localGateway = nil
        rm.recentLogs = []

        rm.removeCustomService("custom_w")
        await waitForTheGate()
        XCTAssertFalse(rm.recentLogs.contains { $0.message.contains("not put back") || $0.message.hasPrefix("Putting back") })
    }

    // MARK: - The put-back, against a fake routing table

    private let gateway = "192.0.2.1"
    private let builtInRange = "198.51.100.0/24"
    private let customRange = "203.0.113.0/24"

    private func route(_ destination: String, _ source: String, via gw: String? = nil) -> RouteManager.ActiveRoute {
        RouteManager.ActiveRoute(destination: destination, gateway: gw ?? gateway, source: source, timestamp: Date())
    }

    /// Bypass with the VPN up: the built-in "Netflix" and a custom service of the same name are
    /// both on and both routed, each with one range, all under the one source "Netflix".
    private func bypassWithASharedName() -> FakeKernel {
        let kernel = FakeKernel(installed: [])
        kernel.attach(to: rm)
        _ = kernel.add([(builtInRange, gateway, true), (customRange, gateway, true)])
        rm.config.services = [
            ServiceEntry(id: "netflix", name: "Netflix", enabled: true, domains: [], ipRanges: [builtInRange]),
            ServiceEntry(id: "custom_n", name: "Netflix", enabled: true, domains: [], ipRanges: [customRange], isCustom: true),
        ]
        rm.activeRoutes = [route(builtInRange, "Netflix"), route(customRange, "Netflix")]
        rm.isVPNConnected = true
        rm.localGateway = gateway
        rm.recentLogs = []
        return kernel
    }

    private func routes(_ source: String) -> Set<String> {
        Set(rm.activeRoutes.filter { $0.source == source }.map(\.destination))
    }

    func testDeletingTheCustomServicePutsTheBuiltInOnesRoutesBackInBypass() async {
        let kernel = bypassWithASharedName()

        rm.removeCustomService("custom_n")
        await waitForTheGate()

        XCTAssertEqual(kernel.installed, [builtInRange], "the custom range goes, the built-in one is back")
        XCTAssertEqual(kernel.gateways[builtInRange], gateway)
        XCTAssertEqual(routes("Netflix"), [builtInRange])
        XCTAssertTrue(rm.recentLogs.contains { $0.message.hasPrefix("Putting back the routes of Netflix") })
    }

    /// The load turns a built-in service off while a custom one has its name, so the shared
    /// name a config can still hold is two custom services from before the check.
    func testDeletingACustomServicePutsBackTheRoutesOfAnotherCustomServiceOfItsName() async {
        let kernel = bypassWithASharedName()
        rm.config.services[0] = ServiceEntry(id: "custom_m", name: "Netflix", enabled: true, domains: [], ipRanges: [builtInRange], isCustom: true)

        rm.removeCustomService("custom_n")
        await waitForTheGate()

        XCTAssertEqual(rm.config.services.map(\.id), ["custom_m"])
        XCTAssertEqual(kernel.installed, [builtInRange], "the deleted one's range goes, the other's is back")
        XCTAssertEqual(routes("Netflix"), [builtInRange])
    }

    func testRenamingTheCustomServicePutsTheBuiltInOnesRoutesBackInBypass() async {
        let kernel = bypassWithASharedName()

        XCTAssertNil(rm.updateCustomService(id: "custom_n", name: "My Netflix", domains: [], ipRanges: [customRange]))
        await waitForTheGate()

        XCTAssertEqual(kernel.installed, [builtInRange, customRange])
        XCTAssertEqual(routes("Netflix"), [builtInRange], "the built-in service routes under its name again")
        XCTAssertEqual(routes("My Netflix"), [customRange], "the custom one routes under its new name")
    }

    func testDeletingTheCustomServicePutsABypassEntryOfItsNameBack() async {
        let kernel = FakeKernel(installed: ["198.51.100.7"])
        kernel.dns["shop.example"] = ["198.51.100.7"]
        kernel.attach(to: rm)
        rm.config.domains = [DomainEntry(domain: "shop.example")]
        rm.config.services = [ServiceEntry(id: "custom_s", name: "shop.example", enabled: true, domains: [], ipRanges: [customRange], isCustom: true)]
        _ = kernel.add(customRange, gateway: gateway)
        rm.activeRoutes = [route("198.51.100.7", "shop.example"), route(customRange, "shop.example")]
        rm.isVPNConnected = true
        rm.localGateway = gateway

        rm.removeCustomService("custom_s")
        await waitForTheGate()

        XCTAssertEqual(kernel.installed, ["198.51.100.7"])
        XCTAssertEqual(routes("shop.example"), ["198.51.100.7"])
    }

    /// VPN Only routes no service, so a custom service named like a VPN Only entry owns none of
    /// the routes under that name: renaming or deleting it leaves the entry's routes in, through
    /// the VPN, the whole time.
    private func vpnOnlyWithASharedName() -> FakeKernel {
        let vpn = "10.8.0.1"
        let kernel = FakeKernel(installed: [])
        kernel.attach(to: rm)
        _ = kernel.add("10.20.0.5", gateway: vpn)
        rm.config.routingMode = .vpnOnly
        rm.config.inverseDomains = [DomainEntry(domain: "corp.example")]
        rm.config.services = [ServiceEntry(id: "custom_c", name: "corp.example", enabled: true, domains: [], ipRanges: [customRange], isCustom: true)]
        rm.activeRoutes = [route("10.20.0.5", "corp.example", via: vpn)]
        rm.isVPNConnected = true
        rm.localGateway = gateway
        rm.vpnGateway = vpn
        return kernel
    }

    func testDeletingTheCustomServiceKeepsAVPNOnlyEntryOfItsNameRouted() async {
        let kernel = vpnOnlyWithASharedName()

        rm.removeCustomService("custom_c")
        await waitForTheGate()

        XCTAssertFalse(rm.config.services.contains { $0.id == "custom_c" })
        XCTAssertEqual(kernel.installed, ["10.20.0.5"])
        XCTAssertEqual(kernel.gateways["10.20.0.5"], "10.8.0.1")
        XCTAssertEqual(routes("corp.example"), ["10.20.0.5"])
    }

    func testRenamingTheCustomServiceKeepsAVPNOnlyEntryOfItsNameRouted() async {
        let kernel = vpnOnlyWithASharedName()

        XCTAssertNil(rm.updateCustomService(id: "custom_c", name: "Corp", domains: [], ipRanges: [customRange]))
        await waitForTheGate()

        XCTAssertEqual(kernel.installed, ["10.20.0.5"])
        XCTAssertEqual(routes("corp.example"), ["10.20.0.5"])
        XCTAssertTrue(routes("Corp").isEmpty, "a service routes nothing in VPN Only")
    }

    func testDeletingTheCustomServiceKeepsTheVPNOnlyCatchAllsRouted() async {
        let catchAll = ClassicRouteCompiler.catchAllSource
        let kernel = FakeKernel(installed: [])
        kernel.attach(to: rm)
        _ = kernel.add([("0.0.0.0/1", gateway, true), ("128.0.0.0/1", gateway, true)])
        rm.config.routingMode = .vpnOnly
        rm.config.services = [ServiceEntry(id: "custom_c", name: catchAll, enabled: true, domains: [], ipRanges: [customRange], isCustom: true)]
        XCTAssertNil(rm.customServiceNameClash(catchAll, excluding: "custom_c"), "nothing refuses this name")
        rm.activeRoutes = [route("0.0.0.0/1", catchAll), route("128.0.0.0/1", catchAll)]
        rm.isVPNConnected = true
        rm.localGateway = gateway

        rm.removeCustomService("custom_c")
        await waitForTheGate()

        XCTAssertFalse(rm.config.services.contains { $0.id == "custom_c" })
        XCTAssertEqual(kernel.installed, ["0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertEqual(routes(catchAll), ["0.0.0.0/1", "128.0.0.0/1"])
    }

    func testDeletingTheCustomServiceKeepsACustomModeRuleOfItsNameRouted() async {
        let kernel = FakeKernel(installed: [])
        kernel.attach(to: rm)
        _ = kernel.add("10.20.0.5", gateway: gateway)
        rm.config.schemaVersion = 2
        rm.config.routingMode = .custom
        rm.config.services = [ServiceEntry(id: "custom_c", name: "corp.example", enabled: true, domains: [], ipRanges: [customRange], isCustom: true)]
        rm.activeRoutes = [route("10.20.0.5", "corp.example")]
        rm.isVPNConnected = true
        rm.localGateway = gateway

        rm.removeCustomService("custom_c")
        await waitForTheGate()

        XCTAssertFalse(rm.config.services.contains { $0.id == "custom_c" })
        XCTAssertEqual(kernel.installed, ["10.20.0.5"], "the rule corp.example owns this route")
        XCTAssertEqual(routes("corp.example"), ["10.20.0.5"])
    }

    // MARK: - An app update brings a built-in service named like a custom one

    /// Writes config.json as an older version would have saved it, then loads it the way a
    /// launch does, so the built-in merge runs.
    private func load(_ services: [ServiceEntry]) {
        rm.config.services = services
        rm.saveConfig()
        rm.config = RouteManager.Config()
        rm.loadConfig()
        XCTAssertFalse(rm.isConfigLoadFailed)
    }

    private func service(_ id: String) throws -> ServiceEntry {
        try XCTUnwrap(rm.config.services.first { $0.id == id }, id)
    }

    func testANewBuiltInNamedLikeACustomServiceComesInOffAndStaysOff() async throws {
        load(Config.defaultServices.filter { $0.id != "netflix" } + [custom("custom_n", "netflix")])

        XCTAssertFalse(try service("netflix").enabled)
        XCTAssertEqual(try service("netflix").name, "Netflix")
        XCTAssertEqual(try service("custom_n").name, "netflix", "the custom service keeps its name")
        XCTAssertTrue(try service("custom_n").enabled, "and stays on")
        XCTAssertEqual(rm.customServiceHolding(nameOf: try service("netflix"))?.id, "custom_n")
        XCTAssertEqual(rm.customServiceNameClash("netflix", excluding: "custom_n"), .service(name: "Netflix"),
                       "the custom service's row and editor show the line asking for another name")

        rm.recentLogs = []
        rm.toggleService("netflix")
        XCTAssertFalse(try service("netflix").enabled, "its switch does not turn it on")
        XCTAssertTrue(rm.recentLogs.contains { $0.message == "Netflix not turned on: Your custom service \u{201C}netflix\u{201D} has this name. Rename it to turn this service on." },
                      rm.recentLogs.map(\.message).joined(separator: "\n"))

        let promised = rm.servicesTurnAllOnSwitchesOn.map(\.id)
        XCTAssertFalse(promised.contains("netflix"), "the Services page does not count or name it")
        let switched = rm.setAllServicesEnabled(true)
        XCTAssertEqual(Set(switched), Set(promised), "Turn All On switches what the page promised")
        XCTAssertFalse(switched.contains("netflix"))
        XCTAssertFalse(try service("netflix").enabled, "Turn All On leaves it off")
        XCTAssertTrue(try service("spotify").enabled)

        let response = await ControlSurface.handle(ControlRequest(cmd: "service.enable", args: ["id": "netflix"]))
        XCTAssertEqual(response.error?.code, "already_exists", "vpnb gets an error, not a success with the service still off")
        XCTAssertFalse(try service("netflix").enabled)

        XCTAssertNil(rm.updateCustomService(id: "custom_n", name: "My Netflix", domains: ["custom_n.test"], ipRanges: []))
        XCTAssertNil(rm.customServiceHolding(nameOf: try service("netflix")))
        rm.toggleService("netflix")
        XCTAssertTrue(try service("netflix").enabled, "once the custom service is renamed the built-in one turns on")
    }

    func testABuiltInRenamedOntoACustomServicesNameIsTurnedOffOnLoad() throws {
        // A built-in service the user had on, saved under a name this version changed to the
        // custom service's.
        var renamed = try XCTUnwrap(Config.defaultServices.first { $0.id == "netflix" })
        renamed.name = "Netflix (old)"
        renamed.enabled = true
        load(Config.defaultServices.filter { $0.id != "netflix" } + [renamed, custom("custom_n", "Netflix ")])

        XCTAssertEqual(try service("netflix").name, "Netflix")
        XCTAssertFalse(try service("netflix").enabled, "the two would route under one name")
        XCTAssertTrue(try service("custom_n").enabled)
        XCTAssertTrue(rm.config.services.filter { $0.enabled && $0.name.lowercased().hasPrefix("netflix") }.count == 1)

        // The merge saved it: the next launch reads the built-in one as off.
        rm.config = RouteManager.Config()
        rm.loadConfig()
        XCTAssertFalse(try service("netflix").enabled)
    }

    func testABuiltInWithAFreeNameKeepsItsSwitch() throws {
        var netflix = try XCTUnwrap(Config.defaultServices.first { $0.id == "netflix" })
        netflix.enabled = true
        load(Config.defaultServices.filter { $0.id != "netflix" } + [netflix, custom("custom_w", "Work Tools")])
        XCTAssertTrue(try service("netflix").enabled)
        XCTAssertNil(rm.customServiceHolding(nameOf: try service("netflix")))
    }

    // MARK: - The lines in Spanish and French

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testTheLinesAreTranslated() throws {
        let en = try lproj("en"), es = try lproj("es"), fr = try lproj("fr")
        let clashes: [ServiceNameClash] = [.service(name: "Netflix"), .domain("example.com")]
        func lines(_ bundle: Bundle) -> [String] {
            clashes.map { $0.message(in: bundle) } + clashes.map { $0.importMessage(service: "Mine", in: bundle) }
        }
        XCTAssertEqual(lines(en), [
            "A service named \u{201C}Netflix\u{201D} already exists. Choose another name, so their routes stay apart.",
            "example.com is on your Bypass list. Choose another name, so their routes stay apart.",
            "Nothing was imported. The custom service \u{201C}Mine\u{201D} has the same name as the service \u{201C}Netflix\u{201D}. Rename it in the file and import again.",
            "Nothing was imported. The custom service \u{201C}Mine\u{201D} has the same name as example.com on the Bypass list. Rename it in the file and import again.",
        ])
        let taken = AddDomainError.nameTakenByService(value: "shop.example", service: "Shop")
        XCTAssertEqual(taken.message(in: en), "\u{201C}Shop\u{201D} is the name of a service, and the two would share routes. Add a different domain.")
        for bundle in [es, fr] {
            XCTAssertNotEqual(taken.message(in: bundle), taken.message(in: en))
            XCTAssertTrue(taken.message(in: bundle).contains("Shop"))
            XCTAssertFalse(taken.message(in: bundle).contains("%"))
        }
        XCTAssertEqual(ServiceNameClash.builtInOffMessage(custom: "Mine", in: en),
                       "Your custom service \u{201C}Mine\u{201D} has this name. Rename it to turn this service on.")
        for (name, bundle) in [("es", es), ("fr", fr)] {
            let line = ServiceNameClash.builtInOffMessage(custom: "Mine", in: bundle)
            XCTAssertNotEqual(line, ServiceNameClash.builtInOffMessage(custom: "Mine", in: en), "\(name) has no translation")
            XCTAssertTrue(line.contains("Mine"), line)
            XCTAssertFalse(line.contains("%"), line)
        }
        XCTAssertEqual(ServiceNameClash.service(name: "Netflix").message(in: es),
                       "Ya existe un servicio llamado \u{201C}Netflix\u{201D}. Elige otro nombre para que sus rutas no se mezclen.")
        for (name, bundle) in [("es", es), ("fr", fr)] {
            for (line, original) in zip(lines(bundle), lines(en)) {
                XCTAssertNotEqual(line, original, "\(name) has no translation for: \(original)")
                XCTAssertFalse(line.contains("%"), "\(name) left a placeholder in: \(line)")
                XCTAssertTrue(line.contains("Mine") || !original.contains("Mine"), "\(name) lost the service name in: \(line)")
            }
        }
    }
}
