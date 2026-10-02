// ClassicControlTests.swift
// The Bypass / VPN Only control verbs (ClassicControl, reached through
// ControlSurface.handle): the two domain lists, the services, the installed kernel
// routes, the refresh actions and the log. Same save/restore discipline as
// ControlSurfaceTests. The helper is never ready under XCTest and the VPN is never
// connected, so none of these touch the kernel; the config is written to the
// temp-dir path RouteManager picks under XCTest (checked below, not assumed).

import XCTest
@testable import VPNBypassCore

@MainActor
final class ClassicControlTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedActiveRoutes: [RouteManager.ActiveRoute] = []
    private var savedLogs: [RouteManager.LogEntry] = []
    private var savedVPNConnected = false

    override func setUp() async throws {
        let rm = RouteManager.shared
        savedConfig = rm.config
        savedActiveRoutes = rm.activeRoutes
        savedLogs = rm.recentLogs
        savedVPNConnected = rm.isVPNConnected
        rm.isVPNConnected = false

        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        cfg.services = [
            RouteManager.ServiceEntry(id: "svc_a", name: "Service A", enabled: true,
                                      domains: ["a.example.com", "cdn.a.example.com"], ipRanges: ["203.0.113.0/24"]),
            RouteManager.ServiceEntry(id: "custom_b", name: "Service B", enabled: false,
                                      domains: ["b.example.com"], ipRanges: [], isCustom: true),
        ]
        rm.config = cfg
        rm.activeRoutes = []
    }

    override func tearDown() async throws {
        let rm = RouteManager.shared
        rm.config = savedConfig
        rm.activeRoutes = savedActiveRoutes
        rm.recentLogs = savedLogs
        rm.isVPNConnected = savedVPNConnected
        rm.cancelAllRetries()
        ClassicControl.busyWait = 30
        ClassicControl.routeOperationRunning = { RouteManager.shared.isApplyingRoutes }
    }

    private func send(_ cmd: String, _ args: [String: String]? = nil) async -> ControlResponse {
        await ControlSurface.handle(ControlRequest(cmd: cmd, args: args))
    }

    private var rm: RouteManager { RouteManager.shared }

    /// The config file the running test process saves to, decoded — proves a verb's change
    /// was saved, not only held in memory.
    private func savedConfigOnDisk() throws -> RouteManager.Config {
        let data = try Data(contentsOf: rm.configURL)
        return try JSONDecoder().decode(RouteManager.Config.self, from: data)
    }

    // MARK: - Config isolation

    func testConfigPathIsRedirectedAwayFromTheRealOne() async throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let real = appSupport.appendingPathComponent("VPNBypass/config.json").path
        XCTAssertNotEqual(rm.configURL.path, real)
        XCTAssertTrue(rm.configURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "under XCTest the config must live in the temp dir, got \(rm.configURL.path)")

        let before = (try? FileManager.default.attributesOfItem(atPath: real))?[.modificationDate] as? Date
        let resp = await send("domain.add", ["domain": "isolation.example.com"])
        XCTAssertTrue(resp.ok)
        let after = (try? FileManager.default.attributesOfItem(atPath: real))?[.modificationDate] as? Date
        XCTAssertEqual(before, after, "a mutating verb under XCTest must never write the real config.json")
    }

    // MARK: - domain.list

    func testDomainListReturnsBothListsBypassFirst() async {
        rm.config.domains = [DomainEntry(domain: "one.example.com"), DomainEntry(domain: "two.example.com", enabled: false)]
        rm.config.inverseDomains = [DomainEntry(domain: "10.0.0.0/8", isCIDR: true)]

        let resp = await send("domain.list")
        XCTAssertTrue(resp.ok)
        let domains = resp.result?.domains ?? []
        XCTAssertEqual(domains.map(\.domain), ["one.example.com", "two.example.com", "10.0.0.0/8"])
        XCTAssertEqual(domains.map(\.list), ["bypass", "bypass", "vpnOnly"])
        XCTAssertEqual(domains[1].enabled, false)
        XCTAssertEqual(domains[2].isCIDR, true)
        XCTAssertEqual(domains[0].id, rm.config.domains[0].id)
    }

    func testDomainListFiltersByList() async {
        rm.config.domains = [DomainEntry(domain: "one.example.com")]
        rm.config.inverseDomains = [DomainEntry(domain: "corp.example.com")]

        let vpnOnly = await send("domain.list", ["list": "vpnOnly"])
        XCTAssertEqual(vpnOnly.result?.domains?.map(\.domain), ["corp.example.com"])
        let bypass = await send("domain.list", ["list": "bypass"])
        XCTAssertEqual(bypass.result?.domains?.map(\.domain), ["one.example.com"])

        let bad = await send("domain.list", ["list": "both"])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error?.code, "invalid_args")
    }

    // MARK: - domain.add

    func testDomainAddCleansLikeTheGUIAndSavesBeforeAnswering() async throws {
        let resp = await send("domain.add", ["domain": "  user@Example.COM:443  "])
        XCTAssertTrue(resp.ok, "\(String(describing: resp.error))")
        let added = try XCTUnwrap(resp.result?.domains?.first)
        XCTAssertEqual(added.domain, "example.com")
        XCTAssertEqual(added.list, "bypass", "list defaults to bypass")
        XCTAssertTrue(added.enabled)
        XCTAssertEqual(rm.config.domains.map(\.domain), ["example.com"])
        XCTAssertEqual(rm.config.domains.first?.id, added.id)
        XCTAssertEqual(try savedConfigOnDisk().domains.map(\.domain), ["example.com"], "saved to disk before the answer")
    }

    func testDomainAddDuplicateIsAlreadyExists() async {
        _ = await send("domain.add", ["domain": "example.com"])
        let again = await send("domain.add", ["domain": "EXAMPLE.com"])
        XCTAssertFalse(again.ok)
        XCTAssertEqual(again.error?.code, "already_exists")
        XCTAssertEqual(rm.config.domains.count, 1)
    }

    /// Routes are tracked by a service's name and by a Bypass entry's domain, so the list may
    /// not take a domain a service has as its name.
    func testDomainAddRefusesTheNameOfAService() async {
        rm.config.services.append(RouteManager.ServiceEntry(id: "custom_s", name: "Shop.Example", enabled: true,
                                                            domains: ["s.example.com"], ipRanges: [], isCustom: true))
        let resp = await send("domain.add", ["domain": "shop.example"])
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "already_exists")
        XCTAssertEqual(resp.error?.message, "shop.example is the name of the service Shop.Example; routes are tracked by name, so the bypass list cannot take it")
        XCTAssertTrue(rm.config.domains.isEmpty)
    }

    func testDomainAddRejectsARangeOnBypassList() async {
        for value in ["10.0.0.0/8", "10.0.0/8", "10.0.0.0 /8", "2001:db8::/32"] {
            let resp = await send("domain.add", ["domain": value])
            XCTAssertFalse(resp.ok, value)
            XCTAssertEqual(resp.error?.code, "invalid_args", value)
        }
        XCTAssertTrue(rm.config.domains.isEmpty, "nothing saved")
    }

    /// The Domains tab takes a pasted link and saves its host; the socket does the same.
    func testDomainAddTakesALinkOnBypassListLikeTheGUI() async throws {
        let resp = await send("domain.add", ["domain": "https://example.com/path"])
        XCTAssertTrue(resp.ok, "\(String(describing: resp.error))")
        XCTAssertEqual(resp.result?.domains?.first?.domain, "example.com")
        XCTAssertEqual(rm.config.domains.map(\.domain), ["example.com"])
    }

    func testDomainAddRejectsEmptyAfterCleaningAndMissingDomain() async {
        let empty = await send("domain.add", ["domain": "!!!"])
        XCTAssertEqual(empty.error?.code, "invalid_args")
        let missing = await send("domain.add")
        XCTAssertEqual(missing.error?.code, "invalid_args")
        let badList = await send("domain.add", ["domain": "example.com", "list": "custom"])
        XCTAssertEqual(badList.error?.code, "invalid_args")
        XCTAssertTrue(rm.config.domains.isEmpty)
    }

    func testDomainAddVPNOnlyTakesDomainsAndCIDRs() async throws {
        let cidr = await send("domain.add", ["domain": "10.1.0.0/16", "list": "vpnOnly"])
        XCTAssertTrue(cidr.ok, "\(String(describing: cidr.error))")
        let entry = try XCTUnwrap(cidr.result?.domains?.first)
        XCTAssertEqual(entry.domain, "10.1.0.0/16")
        XCTAssertEqual(entry.list, "vpnOnly")
        XCTAssertTrue(entry.isCIDR)

        let name = await send("domain.add", ["domain": "Corp.Example.com", "list": "vpnOnly"])
        XCTAssertEqual(name.result?.domains?.first?.domain, "corp.example.com")
        XCTAssertEqual(name.result?.domains?.first?.isCIDR, false)

        XCTAssertEqual(rm.config.inverseDomains.map(\.domain), ["10.1.0.0/16", "corp.example.com"])
        XCTAssertTrue(rm.config.domains.isEmpty, "the bypass list is untouched")
    }

    func testDomainAddVPNOnlyRejectsMalformedAndCatchAllCIDRs() async {
        for value in ["10.0.0/8", "10.0.0.0/33", "10.0.0.0/x", "010.0.0.0/8"] {
            let resp = await send("domain.add", ["domain": value, "list": "vpnOnly"])
            XCTAssertEqual(resp.error?.code, "invalid_args", value)
        }
        for value in ["0.0.0.0/0", "128.0.0.0/1"] {
            let resp = await send("domain.add", ["domain": value, "list": "vpnOnly"])
            XCTAssertEqual(resp.error?.code, "invalid_args", value)
            XCTAssertTrue(resp.error?.message.contains("/0 and /1") ?? false, value)
        }
        XCTAssertTrue(rm.config.inverseDomains.isEmpty)
    }

    // MARK: - domain.rm and the lookup rule

    func testDomainRemoveByIdSearchesBothLists() async throws {
        let entry = DomainEntry(domain: "corp.example.com")
        rm.config.inverseDomains = [entry]

        let resp = await send("domain.rm", ["id": entry.id.uuidString])
        XCTAssertTrue(resp.ok, "\(String(describing: resp.error))")
        XCTAssertEqual(resp.result?.message, "domain removed")
        XCTAssertTrue(rm.config.inverseDomains.isEmpty, "removed before the answer")
        XCTAssertTrue(try savedConfigOnDisk().inverseDomains.isEmpty)
    }

    /// On the list the current mode routes, removeDomain removes the kernel routes first and
    /// the config entry after them, in a task. The answer must wait for that task, or a
    /// domain.list sent right after it still shows the entry.
    func testDomainRemoveOnTheLiveListAnswersAfterTheEntryIsGone() async throws {
        XCTAssertTrue(rm.bypassListIsLive, "precondition: Bypass mode routes the Bypass list")
        let entry = DomainEntry(domain: "example.com")
        rm.config.domains = [entry]

        let resp = await send("domain.rm", ["id": entry.id.uuidString])
        XCTAssertTrue(resp.ok, "\(String(describing: resp.error))")
        XCTAssertTrue(rm.config.domains.isEmpty, "removed before the answer")
        XCTAssertTrue(try savedConfigOnDisk().domains.isEmpty)
    }

    func testDomainRemoveByDomainCleansTheLookupValue() async {
        rm.config.domains = [DomainEntry(domain: "example.com")]
        let resp = await send("domain.rm", ["domain": " HTTPS://Example.com "])
        XCTAssertTrue(resp.ok, "\(String(describing: resp.error))")
        XCTAssertTrue(rm.config.domains.isEmpty)
    }

    func testDomainRemoveNotFound() async {
        rm.config.domains = [DomainEntry(domain: "example.com")]
        let byName = await send("domain.rm", ["domain": "other.example.com"])
        XCTAssertEqual(byName.error?.code, "not_found")
        let byId = await send("domain.rm", ["id": UUID().uuidString])
        XCTAssertEqual(byId.error?.code, "not_found")
        let malformed = await send("domain.rm", ["id": "not-a-uuid"])
        XCTAssertEqual(malformed.error?.code, "not_found")
        XCTAssertEqual(rm.config.domains.count, 1)
    }

    func testDomainOnBothListsNeedsList() async {
        let bypass = DomainEntry(domain: "example.com")
        let vpnOnly = DomainEntry(domain: "example.com")
        rm.config.domains = [bypass]
        rm.config.inverseDomains = [vpnOnly]

        let ambiguous = await send("domain.rm", ["domain": "example.com"])
        XCTAssertFalse(ambiguous.ok)
        XCTAssertEqual(ambiguous.error?.code, "invalid_args")
        XCTAssertTrue(ambiguous.error?.message.contains("list=") ?? false)
        XCTAssertEqual(rm.config.domains.count, 1)
        XCTAssertEqual(rm.config.inverseDomains.count, 1)

        let scoped = await send("domain.rm", ["domain": "example.com", "list": "vpnOnly"])
        XCTAssertTrue(scoped.ok)
        XCTAssertEqual(rm.config.domains, [bypass], "only the named list changed")
        XCTAssertTrue(rm.config.inverseDomains.isEmpty)
    }

    func testListScopesTheIdLookup() async {
        let entry = DomainEntry(domain: "corp.example.com")
        rm.config.inverseDomains = [entry]
        let wrongList = await send("domain.rm", ["id": entry.id.uuidString, "list": "bypass"])
        XCTAssertEqual(wrongList.error?.code, "not_found")
        XCTAssertEqual(rm.config.inverseDomains.count, 1)
    }

    func testLookupNeedsExactlyOneOfIdAndDomain() async {
        let entry = DomainEntry(domain: "example.com")
        rm.config.domains = [entry]
        let both = await send("domain.rm", ["id": entry.id.uuidString, "domain": "example.com"])
        XCTAssertEqual(both.error?.code, "invalid_args")
        let neither = await send("domain.rm")
        XCTAssertEqual(neither.error?.code, "invalid_args")
        XCTAssertEqual(rm.config.domains.count, 1)
    }

    /// The socket can edit the Bypass list while VPN Only is active, which the GUI never
    /// does. Removing a bypass entry there must not remove the kernel routes that share its
    /// name: those belong to the VPN Only entry.
    func testRemovingAnInactiveListEntryLeavesTheOtherListsRoutesAlone() async {
        rm.config.routingMode = .vpnOnly
        rm.config.domains = [DomainEntry(domain: "example.com")]
        rm.config.inverseDomains = [DomainEntry(domain: "example.com")]
        rm.activeRoutes = [RouteManager.ActiveRoute(destination: "198.51.100.7", gateway: "utun4",
                                                    source: "example.com", timestamp: Date())]
        rm.recentLogs = []

        let resp = await send("domain.rm", ["domain": "example.com", "list": "bypass"])
        XCTAssertTrue(resp.ok)
        XCTAssertTrue(rm.config.domains.isEmpty)
        XCTAssertEqual(rm.activeRoutes.count, 1)
        XCTAssertFalse(rm.recentLogs.contains { $0.message.contains("Removed routes for example.com") || $0.message.contains("Cannot remove route") },
                       "the VPN Only entry's route must not be touched: \(rm.recentLogs.map(\.message))")
    }

    /// The mirror: in Bypass mode, removing a VPN Only entry must leave the Bypass entry's
    /// route of the same name alone.
    func testRemovingAVPNOnlyEntryInBypassModeLeavesTheBypassRoutesAlone() async {
        rm.config.routingMode = .bypass
        rm.config.domains = [DomainEntry(domain: "example.com")]
        rm.config.inverseDomains = [DomainEntry(domain: "example.com")]
        rm.activeRoutes = [RouteManager.ActiveRoute(destination: "198.51.100.7", gateway: "192.168.1.1",
                                                    source: "example.com", timestamp: Date())]
        rm.recentLogs = []

        let resp = await send("domain.rm", ["domain": "example.com", "list": "vpnOnly"])
        XCTAssertTrue(resp.ok)
        XCTAssertTrue(rm.config.inverseDomains.isEmpty)
        XCTAssertEqual(rm.activeRoutes.count, 1)
        XCTAssertFalse(rm.recentLogs.contains { $0.message.contains("Removed routes for example.com") || $0.message.contains("Cannot remove route") },
                       "the Bypass entry's route must not be touched: \(rm.recentLogs.map(\.message))")
    }

    /// With a VPN connected, addDomain / toggleDomain / toggleService take the route gate
    /// synchronously when they go on to install routes. In VPN Only and in Custom (schema 2)
    /// the Bypass list and the services are not routed, so a scripted edit must leave the
    /// gate alone: no bypass route is installed.
    func testScriptedEditsInstallNoBypassRouteWhereTheListIsNotLive() async {
        ClassicControl.busyWait = 0.5   // a broken guard holds the gate; do not wait 30 s on it
        rm.isVPNConnected = true
        for (schema, mode) in [(1, RoutingMode.vpnOnly), (2, .custom)] {
            rm.config.schemaVersion = schema
            rm.config.routingMode = mode
            rm.config.domains = [DomainEntry(domain: "off.example.com", enabled: false)]
            rm.config.services[1].enabled = false
            XCTAssertFalse(rm.bypassListIsLive, "precondition for \(mode)")
            XCTAssertFalse(rm.isApplyingRoutes, "precondition for \(mode)")

            let add = await send("domain.add", ["domain": "new.example.com"])
            XCTAssertTrue(add.ok)
            XCTAssertFalse(rm.isApplyingRoutes, "domain.add in \(mode) must not start a bypass route apply")

            let enable = await send("domain.enable", ["domain": "off.example.com", "list": "bypass"])
            XCTAssertTrue(enable.ok)
            XCTAssertFalse(rm.isApplyingRoutes, "domain.enable in \(mode) must not start a bypass route apply")

            let service = await send("service.enable", ["id": "custom_b"])
            XCTAssertTrue(service.ok)
            XCTAssertFalse(rm.isApplyingRoutes, "service.enable in \(mode) must not start a bypass route apply")
        }
    }

    /// In Custom mode a DNS retry is keyed by a rule's host, which is often the same name as
    /// a Bypass entry. Removing that (unrouted) Bypass entry must keep the rule's retry.
    func testRemovingABypassEntryKeepsTheRetryWhenTheListIsNotLive() async {
        rm.config.schemaVersion = 2
        rm.config.routingMode = .custom
        rm.config.domains = [DomainEntry(domain: "example.com")]
        rm.scheduleRetry(for: "example.com")

        let resp = await send("domain.rm", ["domain": "example.com", "list": "bypass"])
        XCTAssertTrue(resp.ok)
        XCTAssertNotNil(rm.pendingRetryTasks["example.com"], "the Custom rule's retry must survive")

        // Mirror: where the Bypass list is live the retry is that entry's own, so it goes.
        rm.config.routingMode = .bypass
        rm.config.domains = [DomainEntry(domain: "example.com")]
        let live = await send("domain.rm", ["domain": "example.com"])
        XCTAssertTrue(live.ok)
        XCTAssertNil(rm.pendingRetryTasks["example.com"])
    }

    /// Argument errors do not depend on the lists, so they answer at once even while a route
    /// operation runs; only a valid request waits for it.
    func testBadArgumentsDoNotWaitForARunningRouteOperation() async {
        rm.config.domains = [DomainEntry(domain: "example.com")]
        ClassicControl.busyWait = 2
        ClassicControl.routeOperationRunning = { true }

        let bad: [(String, [String: String])] = [
            ("domain.rm", ["domain": "example.com", "list": "bogus"]),
            ("domain.rm", ["id": UUID().uuidString, "domain": "example.com"]),
            ("domain.enable", [:]),
            ("domain.disable", ["domain": "10.0.0.0/33"]),
            ("domain.add", ["domain": "10.0.0.0/8"]),
            ("domain.add", ["domain": "   "]),
            ("domain.add", ["domain": "10.0.0.0/1", "list": "vpnOnly"]),
        ]
        for (cmd, args) in bad {
            let start = Date()
            let resp = await send(cmd, args)
            XCTAssertEqual(resp.error?.code, "invalid_args", "\(cmd) \(args)")
            XCTAssertLessThan(Date().timeIntervalSince(start), 1, "\(cmd) \(args) waited for the route operation")
        }

        // Positive control: a valid request does wait.
        let start = Date()
        let good = await send("domain.disable", ["domain": "example.com"])
        XCTAssertTrue(good.ok)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 1.5)
    }

    /// cleanDomain cuts at the first "/", so "10.0.0.0/33" would look up the plain entry
    /// "10.0.0.0". A value with "/" that is neither a URL nor a valid CIDR is refused.
    func testDomainLookupRefusesAMalformedCIDR() async {
        let plain = DomainEntry(domain: "10.0.0.0")
        rm.config.domains = [plain]
        for value in ["10.0.0.0/33", "10.0.0.0/1", "10.0.0.0/0", "10.0.0.0/x"] {
            let rmResp = await send("domain.rm", ["domain": value])
            XCTAssertEqual(rmResp.error?.code, "invalid_args", value)
            let disable = await send("domain.disable", ["domain": value])
            XCTAssertEqual(disable.error?.code, "invalid_args", value)
        }
        XCTAssertEqual(rm.config.domains, [plain], "the entry nobody named is untouched")

        // A valid CIDR and a URL still resolve.
        rm.config.inverseDomains = [DomainEntry(domain: "10.0.0.0/8", isCIDR: true)]
        let cidr = await send("domain.rm", ["domain": "10.0.0.0/8"])
        XCTAssertTrue(cidr.ok, "\(String(describing: cidr.error))")
        let url = await send("domain.rm", ["domain": "https://10.0.0.0/path"])
        XCTAssertTrue(url.ok, "\(String(describing: url.error))")
        XCTAssertTrue(rm.config.domains.isEmpty)
    }

    /// domain.rm, domain.enable and domain.disable read a value by the rule domain.add
    /// saves it by, so every value add takes on the Bypass list names the entry it saved:
    /// "example.com/page" used to be refused there as a malformed CIDR.
    func testBypassLookupTakesEveryValueAddTakes() async {
        for value in ["example.com", "https://example.com/page", "example.com/page", "Example.com:8080/a?b=c"] {
            for list: String? in ["bypass", nil] {
                let label = "\(value) list=\(list ?? "none")"
                rm.config.domains = []
                rm.config.inverseDomains = []
                var args = ["domain": value]
                if let list { args["list"] = list }

                let add = await send("domain.add", args)
                XCTAssertTrue(add.ok, "\(label): \(String(describing: add.error))")
                XCTAssertEqual(rm.config.domains.map(\.domain), ["example.com"], label)

                let off = await send("domain.disable", args)
                XCTAssertTrue(off.ok, "\(label): \(String(describing: off.error))")
                XCTAssertEqual(rm.config.domains.first?.enabled, false, label)

                let on = await send("domain.enable", args)
                XCTAssertTrue(on.ok, "\(label): \(String(describing: on.error))")
                XCTAssertEqual(rm.config.domains.first?.enabled, true, label)

                let removed = await send("domain.rm", args)
                XCTAssertTrue(removed.ok, "\(label): \(String(describing: removed.error))")
                XCTAssertTrue(rm.config.domains.isEmpty, label)
            }
        }
    }

    /// The VPN Only list refuses any "/" that is not a CIDR, on add and on lookup alike, and
    /// the entry the cleaned value would hit is left alone.
    func testVPNOnlyLookupRefusesALinkWithASlashLikeAdd() async {
        let entry = DomainEntry(domain: "example.com")
        for value in ["https://example.com/page", "example.com/page"] {
            rm.config.inverseDomains = [entry]
            let args = ["domain": value, "list": "vpnOnly"]
            for cmd in ["domain.add", "domain.disable", "domain.enable", "domain.rm"] {
                let resp = await send(cmd, args)
                XCTAssertEqual(resp.error?.code, "invalid_args", "\(cmd) \(value)")
                XCTAssertEqual(resp.error?.message, "malformed CIDR (expected a.b.c.d/n with n from 2 to 32)", "\(cmd) \(value)")
            }
            XCTAssertEqual(rm.config.inverseDomains, [entry], value)
        }
        // A bare host still names it.
        let bare = await send("domain.disable", ["domain": "example.com", "list": "vpnOnly"])
        XCTAssertTrue(bare.ok, "\(String(describing: bare.error))")
        XCTAssertEqual(rm.config.inverseDomains.first?.enabled, false)
    }

    /// Without list=, a link is looked up on both lists by its host: a domain on both asks
    /// for list= instead of the Bypass entry being picked, and one only on VPN Only is found.
    func testLinkWithoutListSearchesBothListsByHost() async {
        for value in ["https://example.com", "example.com/page"] {
            let bypass = DomainEntry(domain: "example.com")
            let vpnOnly = DomainEntry(domain: "example.com")
            rm.config.domains = [bypass]
            rm.config.inverseDomains = [vpnOnly]
            for cmd in ["domain.disable", "domain.enable", "domain.rm"] {
                let resp = await send(cmd, ["domain": value])
                XCTAssertEqual(resp.error?.code, "invalid_args", "\(cmd) \(value)")
                XCTAssertEqual(resp.error?.message, "that domain is on both lists; add list=bypass or list=vpnOnly",
                               "\(cmd) \(value)")
            }
            XCTAssertEqual(rm.config.domains, [bypass], value)
            XCTAssertEqual(rm.config.inverseDomains, [vpnOnly], value)

            rm.config.domains = []
            let off = await send("domain.disable", ["domain": value])
            XCTAssertTrue(off.ok, "\(value): \(String(describing: off.error))")
            XCTAssertEqual(rm.config.inverseDomains.first?.enabled, false, value)
            let removed = await send("domain.rm", ["domain": value])
            XCTAssertTrue(removed.ok, "\(value): \(String(describing: removed.error))")
            XCTAssertTrue(rm.config.inverseDomains.isEmpty, value)
        }
    }

    /// A CIDR names a VPN Only entry, with or without list=. The Bypass list holds no ranges,
    /// so list=bypass refuses one instead of cutting it to the host "10.0.0.0".
    func testCIDRLookupOnEachList() async {
        let host = DomainEntry(domain: "10.0.0.0")
        rm.config.domains = [host]
        for cmd in ["domain.add", "domain.disable", "domain.enable", "domain.rm"] {
            let resp = await send(cmd, ["domain": "10.0.0.0/24", "list": "bypass"])
            XCTAssertEqual(resp.error?.code, "invalid_args", cmd)
        }
        let lookup = await send("domain.rm", ["domain": "10.0.0.0/24", "list": "bypass"])
        XCTAssertEqual(lookup.error?.message, "the bypass list holds domain names, not a CIDR")
        XCTAssertEqual(rm.config.domains, [host], "the host entry nobody named is untouched")

        for list: String? in ["vpnOnly", nil] {
            let label = "list=\(list ?? "none")"
            rm.config.inverseDomains = []
            var args = ["domain": "10.0.0.0/24"]
            if let list { args["list"] = list }
            if list == nil {
                rm.config.inverseDomains = [DomainEntry(domain: "10.0.0.0/24", isCIDR: true)]
            } else {
                let add = await send("domain.add", args)
                XCTAssertTrue(add.ok, "\(label): \(String(describing: add.error))")
            }
            let off = await send("domain.disable", args)
            XCTAssertTrue(off.ok, "\(label): \(String(describing: off.error))")
            XCTAssertEqual(rm.config.inverseDomains.first?.enabled, false, label)
            let on = await send("domain.enable", args)
            XCTAssertTrue(on.ok, "\(label): \(String(describing: on.error))")
            XCTAssertEqual(rm.config.inverseDomains.first?.enabled, true, label)
            let removed = await send("domain.rm", args)
            XCTAssertTrue(removed.ok, "\(label): \(String(describing: removed.error))")
            XCTAssertTrue(rm.config.inverseDomains.isEmpty, label)
        }
        XCTAssertEqual(rm.config.domains, [host])
    }

    /// A malformed range is refused by every verb on every list, and never cut down to the
    /// host entry "10.0.0.0".
    func testMalformedRangeIsRefusedByEveryVerbOnEveryList() async {
        let host = DomainEntry(domain: "10.0.0.0", enabled: false)
        let vpnHost = DomainEntry(domain: "10.0.0.0")
        rm.config.domains = [host]
        rm.config.inverseDomains = [vpnHost]
        for list: String? in ["bypass", "vpnOnly", nil] {
            var args = ["domain": "10.0.0.0/33"]
            if let list { args["list"] = list }
            for cmd in ["domain.add", "domain.disable", "domain.enable", "domain.rm"] {
                let resp = await send(cmd, args)
                XCTAssertEqual(resp.error?.code, "invalid_args", "\(cmd) list=\(list ?? "none")")
            }
        }
        let both = await send("domain.rm", ["domain": "10.0.0.0/33"])
        XCTAssertEqual(both.error?.message, "malformed CIDR (expected a.b.c.d/n with n from 2 to 32)",
                       "with both lists searched, the VPN Only reason names the range problem")
        XCTAssertEqual(rm.config.domains, [host])
        XCTAssertEqual(rm.config.inverseDomains, [vpnHost])
    }

    func testBypassListIsLiveOnlyWhereTheGUIShowsIt() {
        rm.config.schemaVersion = 2
        rm.config.routingMode = .bypass
        XCTAssertTrue(rm.bypassListIsLive)
        rm.config.routingMode = .vpnOnly
        XCTAssertFalse(rm.bypassListIsLive)
        rm.config.routingMode = .custom
        XCTAssertFalse(rm.bypassListIsLive)
        rm.config.schemaVersion = 1   // Custom on the legacy engine still routes the Bypass list
        XCTAssertTrue(rm.bypassListIsLive)
    }

    // MARK: - domain.enable / domain.disable

    func testDomainDisableAndEnable() async throws {
        let entry = DomainEntry(domain: "example.com")
        rm.config.domains = [entry]

        let off = await send("domain.disable", ["domain": "example.com"])
        XCTAssertTrue(off.ok)
        XCTAssertEqual(off.result?.domains?.first?.enabled, false)
        XCTAssertEqual(off.result?.domains?.first?.id, entry.id)
        XCTAssertEqual(rm.config.domains.first?.enabled, false)
        XCTAssertEqual(try savedConfigOnDisk().domains.first?.enabled, false)

        let offAgain = await send("domain.disable", ["id": entry.id.uuidString])
        XCTAssertTrue(offAgain.ok, "already disabled is ok")
        XCTAssertEqual(rm.config.domains.first?.enabled, false, "and does not toggle it back")

        let on = await send("domain.enable", ["id": entry.id.uuidString])
        XCTAssertEqual(on.result?.domains?.first?.enabled, true)
        XCTAssertEqual(rm.config.domains.first?.enabled, true)
    }

    func testVPNOnlyDomainEnableDisable() async {
        let entry = DomainEntry(domain: "10.0.0.0/8", isCIDR: true)
        rm.config.inverseDomains = [entry]
        let off = await send("domain.disable", ["domain": "10.0.0.0/8"])
        XCTAssertTrue(off.ok, "\(String(describing: off.error))")
        XCTAssertEqual(off.result?.domains?.first?.list, "vpnOnly")
        XCTAssertEqual(rm.config.inverseDomains.first?.enabled, false)

        let missing = await send("domain.enable", ["domain": "nope.example.com"])
        XCTAssertEqual(missing.error?.code, "not_found")
    }

    // MARK: - service.*

    func testServiceListSummaryAndDetail() async throws {
        let all = await send("service.list")
        XCTAssertTrue(all.ok)
        let services = try XCTUnwrap(all.result?.services)
        XCTAssertEqual(services.map(\.id), ["svc_a", "custom_b"])
        XCTAssertEqual(services[0].domainCount, 2)
        XCTAssertEqual(services[0].ipRangeCount, 1)
        XCTAssertNil(services[0].domains, "the list form carries counts only")
        XCTAssertEqual(services[1].isCustom, true)
        XCTAssertEqual(services[1].enabled, false)

        let one = await send("service.list", ["id": "svc_a"])
        let detail = try XCTUnwrap(one.result?.services)
        XCTAssertEqual(detail.count, 1)
        XCTAssertEqual(detail[0].domains, ["a.example.com", "cdn.a.example.com"])
        XCTAssertEqual(detail[0].ipRanges, ["203.0.113.0/24"])

        let unknown = await send("service.list", ["id": "nope"])
        XCTAssertEqual(unknown.error?.code, "not_found")
    }

    func testServiceEnableDisable() async throws {
        let on = await send("service.enable", ["id": "custom_b"])
        XCTAssertTrue(on.ok)
        XCTAssertEqual(on.result?.services?.first?.enabled, true)
        XCTAssertNil(on.result?.services?.first?.domains, "summary shape")
        XCTAssertEqual(rm.config.services.first { $0.id == "custom_b" }?.enabled, true)
        XCTAssertEqual(try savedConfigOnDisk().services.first { $0.id == "custom_b" }?.enabled, true)

        let onAgain = await send("service.enable", ["id": "custom_b"])
        XCTAssertTrue(onAgain.ok)
        XCTAssertEqual(rm.config.services.first { $0.id == "custom_b" }?.enabled, true, "no toggle back")

        let off = await send("service.disable", ["id": "svc_a"])
        XCTAssertEqual(off.result?.services?.first?.enabled, false)

        let unknown = await send("service.disable", ["id": "nope"])
        XCTAssertEqual(unknown.error?.code, "not_found")
        let missing = await send("service.enable")
        XCTAssertEqual(missing.error?.code, "invalid_args")
    }

    // MARK: - routes.*

    func testRoutesActiveListsAndFiltersBySource() async {
        rm.activeRoutes = [
            RouteManager.ActiveRoute(destination: "198.51.100.1", gateway: "192.168.1.1", source: "example.com", timestamp: Date()),
            RouteManager.ActiveRoute(destination: "198.51.100.2", gateway: "192.168.1.1", source: "Service A", timestamp: Date()),
            RouteManager.ActiveRoute(destination: "203.0.113.0/24", gateway: "192.168.1.1", source: "Service A", timestamp: Date()),
        ]
        let all = await send("routes.active")
        XCTAssertEqual(all.result?.activeRoutes?.count, 3)
        XCTAssertEqual(all.result?.activeRoutes?.first,
                       ControlActiveRoute(destination: "198.51.100.1", gateway: "192.168.1.1", source: "example.com"))

        let filtered = await send("routes.active", ["source": "service a"])
        XCTAssertEqual(filtered.result?.activeRoutes?.map(\.destination), ["198.51.100.2", "203.0.113.0/24"])

        let prefixOnly = await send("routes.active", ["source": "Service"])
        XCTAssertEqual(prefixOnly.result?.activeRoutes, [], "the filter is an exact match")
    }

    func testRoutesClearReportsWhatItCouldNotRemove() async {
        XCTAssertFalse(HelperManager.shared.isHelperInstalled, "precondition: no helper in tests")
        let empty = await send("routes.clear")
        XCTAssertTrue(empty.ok)
        XCTAssertEqual(empty.result?.message, "removed 0 routes")

        rm.activeRoutes = [
            RouteManager.ActiveRoute(destination: "198.51.100.1", gateway: "192.168.1.1", source: "a", timestamp: Date()),
            RouteManager.ActiveRoute(destination: "198.51.100.1", gateway: "192.168.1.1", source: "b", timestamp: Date()),
            RouteManager.ActiveRoute(destination: "198.51.100.2", gateway: "192.168.1.1", source: "b", timestamp: Date()),
        ]
        let kept = await send("routes.clear")
        XCTAssertTrue(kept.ok)
        XCTAssertEqual(kept.result?.message, "removed 0 routes; 2 could not be removed and are still installed",
                       "without a helper nothing is removed, and the answer must say so")
    }

    // MARK: - refresh / dns.refresh

    func testRefreshNeedsTheHelper() async {
        XCTAssertFalse(HelperManager.shared.isHelperInstalled, "precondition: no helper in tests")
        let resp = await send("refresh")
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "helper_not_ready")
        // The helper's Install button lives on the Status page, so the socket sends the user there.
        XCTAssertTrue(resp.error?.message.hasSuffix("repair it in Settings > Status") ?? false,
                      resp.error?.message ?? "no error")
    }

    /// The answer is a constant, so check the refresh really ran: with no VPN it logs that
    /// it skipped. Waiting for that line also drains the started task inside this test.
    func testDNSRefreshStarts() async {
        rm.recentLogs = []
        let resp = await send("dns.refresh")
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.result?.message, "DNS refresh started")

        let deadline = Date().addingTimeInterval(5)
        while !rm.recentLogs.contains(where: { $0.message == "DNS refresh skipped: VPN not connected" }),
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(rm.recentLogs.contains { $0.message == "DNS refresh skipped: VPN not connected" },
                      "dns.refresh must start the refresh: \(rm.recentLogs.map(\.message))")
    }

    // MARK: - logs

    private func seedLogs(_ count: Int) {
        let levels: [RouteManager.LogEntry.LogLevel] = [.info, .success, .warning, .error]
        // recentLogs is newest first; index 0 is the newest.
        rm.recentLogs = (0..<count).map { i in
            RouteManager.LogEntry(timestamp: Date(timeIntervalSince1970: 1_790_000_000 - Double(i)),
                                  level: levels[i % 4], message: "line \(i)")
        }
    }

    func testLogsDefaultLimitNewestFirstAndISOTime() async throws {
        seedLogs(120)
        let resp = await send("logs")
        XCTAssertTrue(resp.ok)
        let logs = try XCTUnwrap(resp.result?.logs)
        XCTAssertEqual(logs.count, 50, "default limit is 50")
        XCTAssertEqual(logs.first?.message, "line 0")
        XCTAssertEqual(logs.first?.level, "INFO")
        XCTAssertEqual(logs.first?.time, "2026-09-21T14:13:20Z", "ISO 8601 in UTC")
    }

    func testLogsLimitAndLevelFilter() async throws {
        seedLogs(20)
        let two = await send("logs", ["limit": "2"])
        XCTAssertEqual(two.result?.logs?.map(\.message), ["line 0", "line 1"])

        let warnings = await send("logs", ["level": "warning"])
        XCTAssertEqual(warnings.result?.logs?.map(\.message), ["line 2", "line 6", "line 10", "line 14", "line 18"])
        XCTAssertEqual(Set(warnings.result?.logs?.map(\.level) ?? []), ["WARNING"])

        let oneError = await send("logs", ["level": "ERROR", "limit": "1"])
        XCTAssertEqual(oneError.result?.logs?.map(\.message), ["line 3"])

        let max = await send("logs", ["limit": "200"])
        XCTAssertEqual(max.result?.logs?.count, 20)
    }

    func testLogsRejectsBadLimitAndLevel() async {
        for limit in ["0", "201", "-1", "ten", ""] {
            let resp = await send("logs", ["limit": limit])
            XCTAssertEqual(resp.error?.code, "invalid_args", "limit=\(limit)")
        }
        let level = await send("logs", ["level": "debug"])
        XCTAssertEqual(level.error?.code, "invalid_args")
    }

    // MARK: - read verbs, envelope, status

    func testReadVerbsDoNotMutate() async {
        rm.config.domains = [DomainEntry(domain: "example.com")]
        let domainsBefore = rm.config.domains
        let servicesBefore = rm.config.services.map { "\($0.id)=\($0.enabled)" }
        for cmd in ["domain.list", "service.list", "routes.active", "logs"] {
            XCTAssertFalse(CommandRouter.isMutating(cmd), cmd)
            let resp = await send(cmd)
            XCTAssertTrue(resp.ok, cmd)
        }
        XCTAssertEqual(rm.config.domains, domainsBefore)
        XCTAssertEqual(rm.config.services.map { "\($0.id)=\($0.enabled)" }, servicesBefore)
    }

    func testNewVerbsKeepTheEnvelopeVersionCheck() async {
        let resp = await ControlSurface.handle(ControlRequest(v: 2, cmd: "domain.add", args: ["domain": "example.com"]))
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, "unsupported_version")
        XCTAssertTrue(rm.config.domains.isEmpty)
    }

    func testStatusCarriesAppVersionWhenTheBundleHasOne() async {
        XCTAssertEqual(ControlSurface.appVersion(from: ["CFBundleShortVersionString": "4.9.0"]), "4.9.0")
        XCTAssertNil(ControlSurface.appVersion(from: ["CFBundleShortVersionString": " "]))
        XCTAssertNil(ControlSurface.appVersion(from: [:]))
        XCTAssertNil(ControlSurface.appVersion(from: nil))

        let resp = await send("status")
        XCTAssertEqual(resp.result?.runtime?.appVersion,
                       ControlSurface.appVersion(from: Bundle.main.infoDictionary),
                       "status reports the running bundle's version")
    }

    // MARK: - wire compatibility

    func testOlderPayloadsStillDecodeAndNilFieldsAreOmitted() throws {
        let oldRuntime = #"{"helperReady":true,"helperState":"Ready","vpnConnected":false,"enforcedRouteCount":0,"enforcing":false}"#
        let runtime = try JSONDecoder().decode(RuntimeStatus.self, from: Data(oldRuntime.utf8))
        XCTAssertNil(runtime.appVersion)
        let encoded = String(data: try JSONEncoder().encode(runtime), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("appVersion"), "omitted when unknown")

        let oldResult = #"{"message":"route removed"}"#
        let result = try JSONDecoder().decode(ControlResult.self, from: Data(oldResult.utf8))
        XCTAssertEqual(result.message, "route removed")
        XCTAssertNil(result.domains)
        XCTAssertNil(result.logs)
    }

    func testNewResultFieldsRoundTrip() throws {
        let entry = DomainEntry(domain: "example.com")
        let result = ControlResult(
            domains: [ControlDomain(entry, list: .vpnOnly)],
            services: [ControlService(ServiceEntry(id: "s", name: "S", enabled: true, domains: ["x"], ipRanges: []), detail: true)],
            activeRoutes: [ControlActiveRoute(destination: "1.2.3.4", gateway: "gw", source: "x")],
            logs: [ControlLogEntry(time: "2026-09-30T10:00:00Z", level: "INFO", message: "m")]
        )
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(ControlResult.self, from: data), result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let domain = try XCTUnwrap((json["domains"] as? [[String: Any]])?.first)
        XCTAssertEqual(domain["id"] as? String, entry.id.uuidString, "id goes on the wire as a UUID string")
        XCTAssertEqual(domain["list"] as? String, "vpnOnly")
        XCTAssertEqual(Set(domain.keys), ["id", "domain", "enabled", "list", "isCIDR", "isWildcard"])
    }
}
