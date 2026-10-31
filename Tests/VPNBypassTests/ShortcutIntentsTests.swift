// ShortcutIntentsTests.swift
// The Shortcuts actions (idea 10): each intent becomes the control-socket request `vpnb` sends
// for the same job, runs through ControlSurface.handle, and its change shows in the footer and
// the log as coming from Shortcuts, not from the command line. The helper is never ready under
// XCTest and the VPN is never connected, so nothing touches the kernel.

import XCTest
@testable import VPNBypassCore

final class ShortcutIntentMappingTests: XCTestCase {

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    // MARK: Intent to request

    func testEachModeIsTheModeVerb() {
        for (choice, raw) in [(ShortcutMode.bypass, "bypass"), (.vpnOnly, "vpnOnly"), (.custom, "custom")] {
            let intent = SetModeIntent(mode: choice)
            XCTAssertEqual(intent.action, .setMode(RoutingMode(rawValue: raw)!))
            XCTAssertEqual(intent.action.request, ControlRequest(cmd: "mode", args: ["mode": raw]))
        }
    }

    func testAddDomainIsDomainAddOnTheChosenList() {
        XCTAssertEqual(AddDomainIntent(domain: "example.org", list: .bypass).action.request,
                       ControlRequest(cmd: "domain.add", args: ["domain": "example.org", "list": "bypass"]))
        XCTAssertEqual(AddDomainIntent(domain: "example.org", list: .vpnOnly).action.request,
                       ControlRequest(cmd: "domain.add", args: ["domain": "example.org", "list": "vpnOnly"]))
    }

    func testTurningAServiceOnOrOffIsServiceEnableOrDisable() {
        let service = ShortcutService(id: "svc_a", name: "Service A")
        XCTAssertEqual(SetServiceIntent(service: service, on: true).action.request,
                       ControlRequest(cmd: "service.enable", args: ["id": "svc_a"]))
        XCTAssertEqual(SetServiceIntent(service: service, on: false).action.request,
                       ControlRequest(cmd: "service.disable", args: ["id": "svc_a"]))
    }

    func testGetStatusIsTheStatusVerbAndChangesNothing() {
        XCTAssertEqual(GetStatusIntent().action.request, ControlRequest(cmd: "status"))
        XCTAssertFalse(CommandRouter.isMutating(GetStatusIntent().action.request.cmd))
    }

    /// The request names must be ones the socket answers: a typo here would reach
    /// CommandRouter as unknown_command.
    @MainActor
    func testEveryRequestIsAVerbTheSocketKnows() {
        let actions: [ShortcutAction] = [.setMode(.bypass), .addDomain("x.org", list: .bypass),
                                         .setService(id: "s", on: true), .setService(id: "s", on: false), .getStatus]
        for action in actions {
            let cmd = action.request.cmd
            XCTAssertTrue(ClassicControl.verbs.contains(cmd) || cmd == "mode" || cmd == "status", cmd)
        }
    }

    // MARK: The service picker

    func testThePickerListsServicesByNameAndFindsByName() {
        let entries = [
            RouteManager.ServiceEntry(id: "zoom", name: "Zoom", enabled: true, domains: [], ipRanges: []),
            RouteManager.ServiceEntry(id: "telegram", name: "Telegram", enabled: false, domains: [], ipRanges: []),
            RouteManager.ServiceEntry(id: "custom_1", name: "Écoles", enabled: true, domains: [], ipRanges: [], isCustom: true),
        ]
        XCTAssertEqual(ShortcutServiceQuery.services(entries).map(\.id), ["custom_1", "telegram", "zoom"])
        XCTAssertEqual(ShortcutServiceQuery.matching("tele", in: entries).map(\.id), ["telegram"])
        XCTAssertEqual(ShortcutServiceQuery.matching("ecol", in: entries).map(\.id), ["custom_1"], "accents ignored")
        XCTAssertEqual(ShortcutServiceQuery.matching("  ", in: entries).count, 3)
    }

    func testThePickerSuggestsWhatTheServicesPageLists() {
        let shipped = ServiceCatalogue.shippedIds.sorted()
        XCTAssertGreaterThanOrEqual(shipped.count, 2)
        let entries = [
            RouteManager.ServiceEntry(id: shipped[0], name: "B on", enabled: true, domains: [], ipRanges: []),
            RouteManager.ServiceEntry(id: shipped[1], name: "C off", enabled: false, domains: [], ipRanges: []),
            RouteManager.ServiceEntry(id: "custom_1", name: "A custom off", enabled: false, domains: [], ipRanges: [], isCustom: true),
        ]
        XCTAssertEqual(ShortcutServiceQuery.suggested(entries).map(\.name), ["A custom off", "B on"],
                       "a catalogue service that is off waits in the sheet, so it is not suggested")
        XCTAssertEqual(ShortcutServiceQuery.matching("c off", in: entries).map(\.id), [shipped[1]],
                       "typing its name still finds it")
    }

    // MARK: What it says back

    private func runtime(helper: Bool = true, vpn: Bool = true, routes: Int = 12,
                         killSwitch: [String]? = nil) -> RuntimeStatus {
        RuntimeStatus(helperReady: helper, helperState: helper ? "Ready" : "Not installed", vpnConnected: vpn,
                      enforcedRouteCount: routes, enforcing: helper && vpn && routes > 0 && killSwitch == nil,
                      killSwitch: killSwitch)
    }

    func testTheStatusLineSaysTheModeAndTheOneReason() throws {
        let en = try lproj("en")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .bypass, runtime: runtime(), in: en),
                       "Bypass mode. Routed addresses: 12")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .vpnOnly, runtime: runtime(helper: false, vpn: false), in: en),
                       "VPN Only mode. The helper is not ready, so nothing is routed.")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .bypass, runtime: runtime(vpn: false), in: en),
                       "Bypass mode. The VPN is not connected.")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .custom, runtime: runtime(routes: 0), in: en),
                       "Custom mode. Nothing is routed yet.")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .bypass, runtime: runtime(killSwitch: ["includeAllNetworks"]), in: en),
                       "Bypass mode. The VPN's kill switch sends all traffic through it, so nothing skips it.")
        XCTAssertEqual(ShortcutActions.statusLine(mode: .bypass, runtime: nil, in: en), "Bypass mode.")
    }

    func testEveryStringIsTranslated() throws {
        let en = try lproj("en")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let later = t0.addingTimeInterval(150)
        func texts(_ b: Bundle) -> [String] {
            var all = [
                ShortcutActions.modeDone(.vpnOnly, in: b),
                ShortcutActions.domainAdded("x.org", list: .bypass, in: b),
                ShortcutActions.domainAdded("x.org", list: .vpnOnly, in: b),
                ShortcutActions.serviceDone("Zoom", on: true, in: b),
                ShortcutActions.serviceDone("Zoom", on: false, in: b),
                LogSource.shortcuts.tag(in: b) ?? "",
                LogSource.shortcuts.helpText(in: b),
                OutsideChange(kind: .addedDomain("x.org"), at: t0, via: .shortcuts).logsHelp(in: b),
                LogFilter(onlySource: .shortcuts).sourceToken(in: b).title,
                LogFilter(onlySource: .shortcuts).emptyLine(shown: 0, in: b) ?? "",
                LogFilter(level: .errors, onlySource: .shortcuts).emptyLine(shown: 0, in: b) ?? "",
            ]
            for r in [runtime(), runtime(helper: false), runtime(vpn: false), runtime(routes: 0),
                      runtime(killSwitch: ["enforceRoutes"])] as [RuntimeStatus?] + [nil] {
                all.append(ShortcutActions.statusLine(mode: .bypass, runtime: r, in: b))
            }
            for kind in [OutsideChange.Kind.addedDomain("x.org"), .turnedOn("Zoom"), .turnedOff("Zoom"), .switchedMode(.vpnOnly)] {
                all.append(OutsideChange(kind: kind, at: t0, via: .shortcuts).line(now: later, in: b).text)
            }
            return all
        }
        let english = texts(en)
        for name in ["es", "fr"] {
            let translated = texts(try lproj(name))
            for (e, t) in zip(english, translated) {
                XCTAssertFalse(e.isEmpty)
                XCTAssertNotEqual(t, e, "\(name) has no entry for \"\(e)\"")
                XCTAssertFalse(t.contains("%"), "\(name): \(t)")
            }
        }
        // The intent titles Shortcuts shows are looked up by key in the app's own tables.
        for key in ["Set Routing Mode", "Add Domain", "Turn Service On or Off", "Get Status", "Routing mode",
                    "Domain list", "List", "Turn On", "on", "off"] {
            for name in ["es", "fr"] {
                let bundle = try lproj(name)
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING", "\(name): \(key)")
            }
        }
    }

    func testAShortcutsChangeSaysShortcutsAndACommandLineChangeStillSaysTheCommandLine() throws {
        let en = try lproj("en")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let later = t0.addingTimeInterval(150)
        XCTAssertEqual(OutsideChange(kind: .switchedMode(.vpnOnly), at: t0, via: .shortcuts).line(now: later, in: en).text,
                       "Last change: switched to VPN Only via Shortcuts, 2 min ago")
        XCTAssertEqual(OutsideChange(kind: .turnedOff("Zoom"), at: t0, via: .shortcuts).line(now: later, in: en).subject, "Zoom")
        XCTAssertEqual(OutsideChange(kind: .switchedMode(.vpnOnly), at: t0).line(now: later, in: en).text,
                       "Last change: switched to VPN Only via the command line, 2 min ago")
        XCTAssertEqual(OutsideChange(kind: .addedDomain("x.org"), at: t0).logsHelp(in: en), OutsideChange.help(in: en))
    }

    func testTheShortcutsFilterKeepsOnlyShortcutsLines() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let log = [RouteManager.LogEntry(timestamp: t0, level: .info, message: "a", source: .shortcuts),
                   RouteManager.LogEntry(timestamp: t0, level: .info, message: "b", source: .controlSocket),
                   RouteManager.LogEntry(timestamp: t0, level: .info, message: "c")]
        XCTAssertEqual(LogFilter(onlySource: .shortcuts).apply(log).map(\.message), ["a"])
        XCTAssertEqual(LogFilter(onlySource: .controlSocket).apply(log).map(\.message), ["b"])
        XCTAssertEqual(LogFilter.clipboardText([log[0]], timeZone: TimeZone(identifier: "UTC")!),
                       "[2026-09-21 14:13:20] [INFO] a (via Shortcuts)")
    }
}

/// The actions run for real, through the same entry point as `vpnb`.
@MainActor
final class ShortcutIntentRunTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedActiveRoutes: [RouteManager.ActiveRoute] = []
    private var savedLogs: [RouteManager.LogEntry] = []
    private var savedVPNConnected = false
    private var savedChange: OutsideChange?

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() async throws {
        savedConfig = rm.config
        savedActiveRoutes = rm.activeRoutes
        savedLogs = rm.recentLogs
        savedVPNConnected = rm.isVPNConnected
        savedChange = rm.lastOutsideChange
        rm.isVPNConnected = false

        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        cfg.services = [RouteManager.ServiceEntry(id: "svc_a", name: "Service A", enabled: true,
                                                  domains: ["a.example.com"], ipRanges: [])]
        rm.config = cfg
        rm.activeRoutes = []
        rm.recentLogs = []
        rm.lastOutsideChange = nil
    }

    override func tearDown() async throws {
        rm.config = savedConfig
        rm.activeRoutes = savedActiveRoutes
        rm.recentLogs = savedLogs
        rm.isVPNConnected = savedVPNConnected
        rm.lastOutsideChange = savedChange
        rm.cancelAllRetries()
    }

    func testAddDomainSavesItAndTheFooterSaysShortcuts() async throws {
        let response = try await ShortcutActions.run(.addDomain("https://En.Wikipedia.org/wiki/Main", list: .bypass))
        XCTAssertEqual(response.result?.domains?.first?.domain, "en.wikipedia.org")
        XCTAssertEqual(rm.config.domains.map(\.domain), ["en.wikipedia.org"])
        XCTAssertEqual(rm.lastOutsideChange?.kind, .addedDomain("en.wikipedia.org"))
        XCTAssertEqual(rm.lastOutsideChange?.via, .shortcuts)
        for message in ["Added domain: en.wikipedia.org", "Config saved", "Control: 'domain.add' applied"] {
            XCTAssertEqual(rm.recentLogs.first { $0.message == message }?.source, .shortcuts,
                           "\(message) in \(rm.recentLogs.map(\.message))")
        }
        // The mark ends with the action.
        rm.log(.info, "A line from the app")
        XCTAssertEqual(rm.recentLogs.first?.source, .app)
    }

    func testSetModeSwitchesAndTheFooterSaysShortcuts() async throws {
        _ = try await ShortcutActions.run(.setMode(.vpnOnly))
        XCTAssertEqual(rm.config.routingMode, .vpnOnly)
        XCTAssertEqual(rm.lastOutsideChange, OutsideChange(kind: .switchedMode(.vpnOnly), at: rm.lastOutsideChange!.at, via: .shortcuts))
        XCTAssertTrue(rm.recentLogs.contains { $0.message == "Control: 'mode' applied" && $0.source == .shortcuts })
    }

    func testTurningAServiceOffAndOn() async throws {
        _ = try await ShortcutActions.run(.setService(id: "svc_a", on: false))
        XCTAssertEqual(rm.config.services.first?.enabled, false)
        XCTAssertEqual(rm.lastOutsideChange?.kind, .turnedOff("Service A"))
        XCTAssertEqual(rm.lastOutsideChange?.via, .shortcuts)
        _ = try await ShortcutActions.run(.setService(id: "svc_a", on: true))
        XCTAssertEqual(rm.config.services.first?.enabled, true)
        XCTAssertEqual(rm.lastOutsideChange?.kind, .turnedOn("Service A"))
    }

    func testGetStatusAnswersWithTheLiveStateAndChangesNothing() async throws {
        let response = try await ShortcutActions.run(.getStatus)
        XCTAssertEqual(response.result?.mode, "bypass")
        let runtime = try XCTUnwrap(response.result?.runtime)
        XCTAssertFalse(runtime.vpnConnected)
        XCTAssertNil(rm.lastOutsideChange)
    }

    func testARefusedActionThrowsTheSocketsAnswer() async {
        do {
            _ = try await ShortcutActions.run(.setService(id: "no_such_service", on: true))
            XCTFail("an unknown service must be refused")
        } catch let error as ShortcutActionError {
            XCTAssertEqual(error, ShortcutActionError(code: "not_found", message: "no service with that id"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        do {
            _ = try await ShortcutActions.run(.addDomain("10.0.0.0/8", list: .bypass))
            XCTFail("a range on the Bypass list must be refused")
        } catch let error as ShortcutActionError {
            XCTAssertEqual(error.code, "invalid_args")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertNil(rm.lastOutsideChange)
        XCTAssertTrue(rm.config.domains.isEmpty)
    }

    /// A `vpnb` request after a Shortcut is the command line again: the channel is a
    /// task-local of the one action, not app state.
    func testACommandLineRequestAfterAShortcutSaysTheCommandLine() async throws {
        _ = try await ShortcutActions.run(.addDomain("example.org", list: .bypass))
        _ = await ControlSurface.handle(ControlRequest(cmd: "domain.add", args: ["domain": "example.net"]))
        XCTAssertEqual(rm.lastOutsideChange?.kind, .addedDomain("example.net"))
        XCTAssertEqual(rm.lastOutsideChange?.via, .controlSocket)
        XCTAssertEqual(rm.recentLogs.first { $0.message == "Added domain: example.net" }?.source, .controlSocket)
    }
}
