// StatusPageTests.swift
// Settings > Status (proposal 13 of #119): the verdict at the top, each row's wording in
// every state, the plain tunnel sentences that replace the badges, the recent warnings,
// Status as the first page in every mode, and the Spanish and French text.

import XCTest
@testable import VPNBypassCore

final class StatusPageTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The state in the proposal's image: WireGuard on utun4, 4 services and 2 domains,
    /// 62 routes applied 23 s ago, DNS checked 12 min ago and due in 18 min.
    private func input(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> DropdownStatus.Input {
        var i = DropdownStatus.Input(
            isVPNConnected: true, vpnName: "WireGuard", helperReady: true, mode: .bypass,
            enabledServices: 4, enabledDomains: 2, enabledRules: 0, installedRoutes: 62,
            pending: nil,
            lastRouteChange: .init(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 62, failedCount: 0),
            lastDNSRefresh: now.addingTimeInterval(-12 * 60),
            nextDNSRefresh: now.addingTimeInterval(18 * 60),
            autoDNSRefresh: true)
        edit(&i)
        return i
    }

    private func summary(_ edit: (inout DropdownStatus.Input) -> Void = { _ in }) -> StatusPage.Summary {
        StatusPage.summary(input(edit), now: now)
    }

    // MARK: Summary

    func testWorkingMatchesTheMockup() {
        let s = summary()
        XCTAssertEqual(s.title, "Working")
        XCTAssertEqual(s.sentence, "4 services and 2 domains skip the VPN. 62 addresses routed 23 s ago, none failed.")
        XCTAssertEqual(s.tone, .ok)
        XCTAssertNil(s.note)
    }

    func testWorkingWithoutAnApplySaysWhatIsRoutedOnly() {
        let s = summary { $0.lastRouteChange = nil }
        XCTAssertEqual(s.title, "Working")
        XCTAssertEqual(s.sentence, "4 services and 2 domains skip the VPN.")
    }

    func testFailedRoutesShowInTheSentence() {
        let s = summary { $0.lastRouteChange = .init(kind: .applied, at: self.now.addingTimeInterval(-5), routeCount: 60, failedCount: 2) }
        XCTAssertEqual(s.sentence, "4 services and 2 domains skip the VPN. 60 addresses routed 5 s ago, 2 failed.")
    }

    /// The caption of image 13: with the helper down, the summary says why nothing is routed.
    func testHelperDownSaysWhyNothingIsRouted() {
        let s = summary { $0.helperReady = false }
        XCTAssertEqual(s.title, "Not working")
        XCTAssertEqual(s.sentence, "Nothing is routed while the privileged helper is not running.")
        XCTAssertEqual(s.tone, .warn)
    }

    func testNoVPNUsesTheDropdownHeadline() {
        let s = summary { $0.isVPNConnected = false; $0.installedRoutes = 0 }
        XCTAssertEqual(s.title, "No VPN connected")
        XCTAssertEqual(s.sentence, "Nothing is routed until a VPN connects.")
        XCTAssertEqual(s.tone, .bad)
    }

    func testWaitingAfterAReconnectUsesTheDropdownHeadline() {
        let pending = RouteManager.PendingReconnectApply(reason: .settling,
                                                         connectedAt: now.addingTimeInterval(-20),
                                                         appliesAt: now.addingTimeInterval(16))
        // The last apply (23 s ago) came before the reconnect, so the wait is current.
        let s = summary { $0.pending = pending }
        XCTAssertEqual(s.title, "WireGuard reconnected 20 s ago")
        XCTAssertEqual(s.sentence, "Waiting for the tunnel to hold before re-applying routes, in 16 s.")
        XCTAssertEqual(s.tone, .warn)
        XCTAssertTrue(StatusPage.isWaiting(input { $0.pending = pending }))
    }

    /// An apply after the reconnect supersedes the wait, exactly as in the dropdown.
    func testAnApplyAfterTheReconnectIsWorkingAgain() {
        let pending = RouteManager.PendingReconnectApply(reason: .heldBack(strikes: 3),
                                                         connectedAt: now.addingTimeInterval(-60),
                                                         appliesAt: now.addingTimeInterval(600))
        let s = summary { $0.pending = pending }
        XCTAssertEqual(s.title, "Working")
        XCTAssertEqual(s.note, "The scheduled re-apply still runs in 10 min.")
        XCTAssertFalse(StatusPage.isWaiting(input { $0.pending = pending }))
        XCTAssertEqual(DropdownStatus.make(input { $0.pending = pending }, now: now).pill, "ON",
                       "the page's verdict follows the dropdown's own decision")
    }

    func testNothingInstalledIsNotWorking() {
        XCTAssertEqual(summary { $0.installedRoutes = 0 }.title, "Nothing routed")
        XCTAssertEqual(summary { $0.mode = .vpnOnly; $0.installedRoutes = 0; $0.everythingElseDirect = true }.title, "Working",
                       "VPN Only's catch-alls are routed, though not counted")
        let fresh = summary { $0.installedRoutes = 0; $0.nothingConfigured = true; $0.enabledServices = 0; $0.enabledDomains = 0 }
        XCTAssertEqual(fresh.title, "Not set up")
        XCTAssertEqual(fresh.tone, .idle)
    }

    // MARK: Helper

    func testHelperLineInEveryState() {
        XCTAssertEqual(StatusPage.helperLine(.ready, version: "4.9.0"), .init(text: "Ready, version 4.9.0", tone: .ok))
        XCTAssertEqual(StatusPage.helperLine(.ready, version: nil), .init(text: "Ready", tone: .ok))
        XCTAssertEqual(StatusPage.helperLine(.missing, version: nil), .init(text: "Not Installed", tone: .bad))
        XCTAssertEqual(StatusPage.helperLine(.failed("boom"), version: nil), .init(text: "Error: boom", tone: .bad))
        XCTAssertEqual(StatusPage.helperLine(.outdated(installed: "4.8.0", expected: "4.9.0"), version: "4.8.0").tone, .warn)
        XCTAssertEqual(StatusPage.helperLine(.checking, version: nil).tone, .warn)
    }

    /// The row gains a button exactly when the user can fix something.
    func testHelperButtonOnlyWhenThereIsSomethingToDo() {
        XCTAssertNil(StatusPage.helperAction(.ready, isInstalling: false))
        XCTAssertNil(StatusPage.helperAction(.checking, isInstalling: false))
        XCTAssertEqual(StatusPage.helperAction(.missing, isInstalling: false), "Install")
        XCTAssertEqual(StatusPage.helperAction(.outdated(installed: "1", expected: "2"), isInstalling: false), "Update")
        XCTAssertEqual(StatusPage.helperAction(.failed("x"), isInstalling: false), "Retry")
        XCTAssertEqual(StatusPage.helperAction(.missing, isInstalling: true), "Installing...")
        XCTAssertNil(StatusPage.helperHint(.ready))
        XCTAssertEqual(StatusPage.helperHint(.missing), "Install to enable route management")
    }

    // MARK: Connection

    func testVPNLine() {
        XCTAssertEqual(StatusPage.vpnLine(isConnected: true, name: "WireGuard", interface: "utun4"),
                       .init(text: "WireGuard, connected on utun4", tone: .ok))
        XCTAssertEqual(StatusPage.vpnLine(isConnected: true, name: nil, interface: "utun4").text, "Connected on utun4")
        XCTAssertEqual(StatusPage.vpnLine(isConnected: true, name: "WireGuard", interface: nil).text, "WireGuard, connected")
        XCTAssertEqual(StatusPage.vpnLine(isConnected: true, name: nil, interface: nil).text, "Connected")
        XCTAssertEqual(StatusPage.vpnLine(isConnected: false, name: "WireGuard", interface: "utun4"),
                       .init(text: "Not connected", tone: .bad))
    }

    func testNormalConnectionLine() {
        XCTAssertEqual(StatusPage.normalConnectionLine(ssid: "Home", gateway: "192.168.1.1").text,
                       "Wi-Fi “Home”, gateway 192.168.1.1")
        XCTAssertEqual(StatusPage.normalConnectionLine(ssid: nil, gateway: "192.168.1.1"), .init(text: "Gateway 192.168.1.1"))
        XCTAssertEqual(StatusPage.normalConnectionLine(ssid: "Home", gateway: nil),
                       .init(text: "Wi-Fi “Home”, no gateway found", tone: .warn))
        XCTAssertEqual(StatusPage.normalConnectionLine(ssid: nil, gateway: nil), .init(text: "No gateway found", tone: .warn))
    }

    private let wireguard = RouteManager.VPNLink(interface: "utun4", addresses: ["10.0.0.2"], label: "WireGuard", isTailscale: false)
    private let tailscale = RouteManager.VPNLink(interface: "utun6", addresses: ["100.64.0.1"], label: "Tailscale", isTailscale: true)
    private let other = RouteManager.VPNLink(interface: "utun7", addresses: ["10.8.0.2"], label: "OpenVPN", isTailscale: false)

    private func snapshot(default iface: String?, selected: String? = "utun4") -> RouteManager.CoexistenceSnapshot {
        .init(links: [wireguard, tailscale, other], selectedInterface: selected, defaultRouteInterface: iface,
              taggedDestinations: (1...62).map { "198.51.100.\($0)" })
    }

    func testDefaultRouteLine() {
        XCTAssertEqual(StatusPage.defaultRouteLine(nil).text, "Reading…")
        XCTAssertEqual(StatusPage.defaultRouteLine(snapshot(default: nil)), .init(text: "Not found", tone: .warn))
        XCTAssertEqual(StatusPage.defaultRouteLine(snapshot(default: "utun4")).text, "utun4, the VPN")
        XCTAssertEqual(StatusPage.defaultRouteLine(snapshot(default: "utun6")).text, "utun6, Tailscale")
        XCTAssertEqual(StatusPage.defaultRouteLine(snapshot(default: "utun7")).text, "utun7, another tunnel")
        XCTAssertEqual(StatusPage.defaultRouteLine(snapshot(default: "en0")).text, "en0, outside the VPN")
    }

    // MARK: Addresses owned

    private func owned(_ destination: String, _ source: String) -> RoutedBySource.InstalledRoute {
        .init(destination: destination, source: source)
    }

    private var catchAlls: [RoutedBySource.InstalledRoute] {
        ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"].map { owned($0, ClassicRouteCompiler.catchAllSource) }
    }

    /// The row as the page builds it when the kernel holds exactly what the app recorded.
    private func ownedText(_ installed: [RoutedBySource.InstalledRoute], vpnOnly: Bool, bundle: Bundle = .main) -> String {
        StatusPage.ownedLine(tagged: installed.map(\.destination), installed: installed, vpnOnly: vpnOnly, bundle: bundle).text
    }

    /// The problem this row had: in VPN Only it read 6 while Routed above read 2, because it
    /// counted the 4 catch-alls as addresses.
    func testVPNOnlyNamesTheCatchAllsApartFromTheAddresses() {
        let installed = [owned("10.20.0.0/16", "10.20.0.0/16"), owned("140.82.112.4", "github.com")] + catchAlls
        XCTAssertEqual(ownedText(installed, vpnOnly: true), "2, plus 4 catch-alls")
        XCTAssertEqual(ownedText([owned("140.82.112.4", "github.com"), catchAlls[0]], vpnOnly: true), "1, plus 1 catch-all")
    }

    /// With nothing on the VPN Only list the catch-alls are all the app owns.
    func testVPNOnlyWithNoEntriesOwnsOnlyTheCatchAlls() {
        XCTAssertEqual(ownedText(catchAlls, vpnOnly: true), "0, plus 4 catch-alls")
        XCTAssertEqual(ownedText([], vpnOnly: true), "0")
    }

    /// Bypass has no catch-alls: the row is the bare number. The catch-all ranges left from a
    /// switch out of VPN Only are routes like any other, as the card and Routed count them.
    func testBypassIsTheBareNumber() {
        let installed = [owned("91.108.4.0/22", "Telegram"), owned("91.108.4.0/22", "telegram.org"),
                         owned("142.250.1.1", "YouTube")]
        XCTAssertEqual(ownedText(installed, vpnOnly: false), "2")
        XCTAssertEqual(ownedText(installed + catchAlls, vpnOnly: false), "6")
    }

    func testCustomIsTheBareNumber() {
        let installed = [owned("10.9.0.0/16", "10.9.0.0/16"), owned("1.2.3.4", "b.example")]
        XCTAssertEqual(ownedText(installed, vpnOnly: false), "2")
    }

    /// The first number is the Routed row's, read through the same function, in every mode.
    func testTheFirstNumberIsTheRoutedCount() {
        let installed = [owned("10.20.0.0/16", "10.20.0.0/16"), owned("140.82.112.4", "github.com"),
                         owned("140.82.112.4", "api.github.com")] + catchAlls
        for vpnOnly in [true, false] {
            let routed = RoutedBySource.addressCount(installed, vpnOnly: vpnOnly)
            XCTAssertTrue(ownedText(installed, vpnOnly: vpnOnly).hasPrefix("\(routed)"), "vpnOnly: \(vpnOnly)")
        }
    }

    /// The row still reads the kernel: a tagged route the app has no record of is an address,
    /// and a recorded route the kernel no longer holds is not counted. A user's own entry for
    /// a catch-all range is an address, as the card counts it.
    func testTheRowCountsWhatTheKernelHolds() {
        let installed = [owned("140.82.112.4", "github.com"), owned("140.82.112.5", "github.com"),
                         owned("0.0.0.0/2", "0.0.0.0/2")] + catchAlls.dropFirst()
        let tagged = ["140.82.112.4", "203.0.113.9", "0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"]
        XCTAssertEqual(StatusPage.ownedLine(tagged: tagged, installed: installed, vpnOnly: true).text, "3, plus 3 catch-alls")
    }

    func testTheCatchAllsAreNamedInSpanishAndFrench() throws {
        let es = try lproj("es"), fr = try lproj("fr")
        let installed = [owned("140.82.112.4", "github.com"), owned("140.82.112.5", "github.com")] + catchAlls
        XCTAssertEqual(ownedText(installed, vpnOnly: true, bundle: es), "2, más 4 rutas generales")
        XCTAssertEqual(ownedText(installed, vpnOnly: true, bundle: fr), "2, plus 4 routes générales")
        XCTAssertEqual(ownedText([catchAlls[0]], vpnOnly: true, bundle: es), "0, más 1 ruta general")
        XCTAssertEqual(ownedText([catchAlls[0]], vpnOnly: true, bundle: fr), "0, plus 1 route générale")
    }

    // MARK: Routes

    func testAppliedLine() {
        let applied = RouteManager.RouteChangeOutcome(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 62, failedCount: 0)
        XCTAssertEqual(StatusPage.appliedLine(installed: 62, lastChange: applied, now: now), .init(text: "62 addresses, 23 s ago, none failed"))
        let failed = RouteManager.RouteChangeOutcome(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 1, failedCount: 2)
        XCTAssertEqual(StatusPage.appliedLine(installed: 1, lastChange: failed, now: now),
                       .init(text: "1 address, 23 s ago, 2 failed", tone: .warn))
        XCTAssertEqual(StatusPage.appliedLine(installed: 5, lastChange: nil, now: now).text, "5 addresses")
        XCTAssertEqual(StatusPage.appliedLine(installed: 0, lastChange: nil, now: now).text, "None yet")
    }

    /// A removal is a claim about what is installed now, so it goes once routes come back.
    func testARemovalStopsShowingOnceRoutesAreBack() {
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now.addingTimeInterval(-120), routeCount: 0, failedCount: 0)
        XCTAssertEqual(StatusPage.appliedLine(installed: 0, lastChange: removed, now: now),
                       .init(text: "All removed 2 min ago", tone: .warn))
        XCTAssertEqual(StatusPage.appliedLine(installed: 3, lastChange: removed, now: now).text, "3 addresses")
        let stuck = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now.addingTimeInterval(-120), routeCount: 2, failedCount: 2)
        XCTAssertEqual(StatusPage.appliedLine(installed: 2, lastChange: stuck, now: now),
                       .init(text: "Removed 2 min ago, 2 could not be removed", tone: .bad))
    }

    func testFromLineFollowsTheMode() {
        XCTAssertEqual(StatusPage.fromLine(input()).text, "4 services, 2 domains")
        XCTAssertEqual(StatusPage.fromLine(input { $0.enabledServices = 1; $0.enabledDomains = 0 }).text, "1 service")
        XCTAssertEqual(StatusPage.fromLine(input { $0.enabledServices = 0; $0.enabledDomains = 1 }).text, "1 domain")
        XCTAssertEqual(StatusPage.fromLine(input { $0.enabledServices = 0; $0.enabledDomains = 0 }).text, "No services or domains")
        XCTAssertEqual(StatusPage.fromLine(input { $0.mode = .vpnOnly; $0.enabledDomains = 3 }).text, "3 entries")
        XCTAssertEqual(StatusPage.fromLine(input { $0.mode = .vpnOnly; $0.enabledDomains = 0 }).text, "No entries")
        XCTAssertEqual(StatusPage.fromLine(input { $0.mode = .custom; $0.enabledRules = 1 }).text, "1 rule")
        XCTAssertEqual(StatusPage.fromLine(input { $0.mode = .custom; $0.enabledRules = 0 }).text, "No rules")
    }

    private func result(_ ip: String, ok: Bool, ago: TimeInterval) -> RouteVerificationResult {
        RouteVerificationResult(destination: ip, isReachable: ok, latency: ok ? 12 : nil,
                                timestamp: now.addingTimeInterval(-ago), error: ok ? nil : "Ping timed out")
    }

    func testLastCheckSaysHowManyOfTheRoutesItChecked() {
        XCTAssertEqual(StatusPage.lastCheckLine([], installed: 62, now: now).text, "Not checked yet")
        let all = (0..<10).map { result("1.1.1.\($0)", ok: true, ago: 240 + Double($0)) }
        XCTAssertEqual(StatusPage.lastCheckLine(all, installed: 62, now: now),
                       .init(text: "10 of 62 checked, all reachable, 4 min ago"))
        let some = [result("1.1.1.1", ok: true, ago: 30), result("1.1.1.2", ok: false, ago: 31)]
        XCTAssertEqual(StatusPage.lastCheckLine(some, installed: 62, now: now),
                       .init(text: "2 of 62 checked, 1 not reachable, 30 s ago", tone: .warn))
        // Routes removed since the check: never "3 of 0".
        let three = (0..<3).map { result("1.1.1.\($0)", ok: true, ago: 10) }
        XCTAssertEqual(StatusPage.lastCheckLine(three, installed: 0, now: now).text, "3 of 3 checked, all reachable, 10 s ago")
        // A check clears the last results when it starts: while it runs, never "Not checked yet".
        XCTAssertEqual(StatusPage.lastCheckLine([], installed: 62, isChecking: true, now: now), .init(text: "Checking now…"))
        XCTAssertEqual(StatusPage.lastCheckLine(all, installed: 62, isChecking: true, now: now), .init(text: "Checking now…"))
    }

    // MARK: DNS

    func testResolverLine() {
        XCTAssertEqual(StatusPage.resolverLine("192.168.1.1"), .init(text: "192.168.1.1, outside the VPN"))
        XCTAssertEqual(StatusPage.resolverLine(nil), .init(text: "Not detected", tone: .warn))
    }

    func testRefreshedLine() {
        let last = now.addingTimeInterval(-12 * 60), next = now.addingTimeInterval(18 * 60)
        XCTAssertEqual(StatusPage.refreshedLine(last: last, next: next, automatic: true, now: now).text, "12 min ago, next in 18 min")
        XCTAssertEqual(StatusPage.refreshedLine(last: nil, next: next, automatic: true, now: now).text, "Not yet, next in 18 min")
        XCTAssertEqual(StatusPage.refreshedLine(last: last, next: now.addingTimeInterval(-1), automatic: true, now: now).text,
                       "12 min ago, next one due now")
        XCTAssertEqual(StatusPage.refreshedLine(last: nil, next: now, automatic: true, now: now).text, "Not yet, next one due now")
        XCTAssertEqual(StatusPage.refreshedLine(last: last, next: next, automatic: false, now: now).text,
                       "12 min ago, automatic refresh off")
        XCTAssertEqual(StatusPage.refreshedLine(last: nil, next: nil, automatic: false, now: now).text,
                       "Not yet, automatic refresh off")
        XCTAssertEqual(StatusPage.refreshedLine(last: last, next: nil, automatic: true, now: now).text, "12 min ago")
        XCTAssertEqual(StatusPage.refreshedLine(last: nil, next: nil, automatic: true, now: now).text, "Not yet")
    }

    // MARK: Tunnels

    func testTunnelSentencesReplaceTheBadges() {
        let s = snapshot(default: "utun4")
        XCTAssertEqual(StatusPage.tunnelLine(wireguard, snapshot: s), "The app acts on this one. It carries the default route.")
        XCTAssertEqual(StatusPage.tunnelLine(tailscale, snapshot: s), "Never touched.")
        XCTAssertEqual(StatusPage.tunnelLine(other, snapshot: s), "Not used by the app.")
        let exitNode = snapshot(default: "utun6")
        XCTAssertEqual(StatusPage.tunnelLine(wireguard, snapshot: exitNode), "The app acts on this one.")
        XCTAssertEqual(StatusPage.tunnelLine(tailscale, snapshot: exitNode), "Never touched. It carries the default route.")
        // Tailscale stays "never touched" even if it were somehow the selected interface.
        XCTAssertEqual(StatusPage.tunnelLine(tailscale, snapshot: snapshot(default: nil, selected: "utun6")), "Never touched.")
    }

    // MARK: Recent warnings

    func testRecentWarningsAreTheNewestWarningsAndErrors() {
        typealias Entry = RouteManager.LogEntry
        let log: [Entry] = [
            Entry(timestamp: now, level: .info, message: "a"),
            Entry(timestamp: now.addingTimeInterval(-1), level: .warning, message: "w1"),
            Entry(timestamp: now.addingTimeInterval(-2), level: .success, message: "b"),
            Entry(timestamp: now.addingTimeInterval(-3), level: .error, message: "e1"),
            Entry(timestamp: now.addingTimeInterval(-4), level: .warning, message: "w2"),
            Entry(timestamp: now.addingTimeInterval(-5), level: .warning, message: "w3"),
        ]
        XCTAssertEqual(StatusPage.recentWarnings(log).map(\.message), ["w1", "e1", "w2"])
        XCTAssertEqual(StatusPage.recentWarnings(log, limit: 10).map(\.message), ["w1", "e1", "w2", "w3"])
        XCTAssertTrue(StatusPage.recentWarnings(Array(log.prefix(1))).isEmpty)
    }

    // MARK: Pages

    func testStatusIsTheFirstPageInEveryMode() {
        XCTAssertEqual(SettingsView.tabs(for: .bypass), [.status, .domains, .services, .general, .logs, .info])
        XCTAssertEqual(SettingsView.tabs(for: .vpnOnly), [.status, .domains, .general, .logs, .info])
        XCTAssertEqual(SettingsView.tabs(for: .custom), [.status, .rules, .routes, .general, .logs, .info])
    }

    // MARK: Tunnel reads

    /// The tunnel snapshot feeds Default route and the tagged count, so it is re-read on every
    /// apply or removal and on every VPN change; a DNS refresh alone does not read it.
    @MainActor
    func testTunnelsAreReReadOnEveryRouteChangeAndVPNChange() {
        let rm = RouteManager.shared
        let saved = (rm.lastRouteChange, rm.lastDNSRefresh, rm.vpnInterface, rm.isVPNConnected)
        defer {
            rm.lastRouteChange = saved.0; rm.lastDNSRefresh = saved.1
            rm.vpnInterface = saved.2; rm.isVPNConnected = saved.3
        }
        rm.lastRouteChange = nil
        rm.vpnInterface = nil
        rm.isVPNConnected = false
        let start = StatusPage.TunnelReadKey.current(rm)

        rm.lastDNSRefresh = now
        XCTAssertEqual(StatusPage.TunnelReadKey.current(rm), start, "a DNS refresh is not a reason to read")

        rm.lastRouteChange = .init(kind: .applied, at: now, routeCount: 62, failedCount: 0)
        let applied = StatusPage.TunnelReadKey.current(rm)
        XCTAssertNotEqual(applied, start, "an apply re-reads the tagged count")

        rm.lastRouteChange = .init(kind: .removedAll, at: now.addingTimeInterval(5), routeCount: 0, failedCount: 0)
        let removed = StatusPage.TunnelReadKey.current(rm)
        XCTAssertNotEqual(removed, applied, "a removal re-reads the tagged count")

        rm.isVPNConnected = true
        let connected = StatusPage.TunnelReadKey.current(rm)
        XCTAssertNotEqual(connected, removed, "a VPN coming up re-reads the tunnels")

        rm.vpnInterface = "utun4"
        XCTAssertNotEqual(StatusPage.TunnelReadKey.current(rm), connected, "a new interface re-reads the tunnels")
    }

    // MARK: Pointers to this page

    /// The helper's row and its Install button moved from General to Status, so every message
    /// that sends the user to repair the helper must name Status.
    func testHelperRepairMessagesPointAtStatus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/VPNBypassCore")
        var found = 0
        for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            where line.contains("helper") && line.contains("repair it") {
                found += 1
                XCTAssertTrue(line.contains("Settings → Status") || line.contains("Settings > Status"),
                              "\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        // The startup notification, the Refresh Routes notification and the socket's refresh error.
        XCTAssertEqual(found, 3)
    }

    // MARK: Spanish and French

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    /// Every line the page can show, in one language.
    private func lines(in bundle: Bundle) -> [String] {
        let s = snapshot(default: "utun4")
        let applied = RouteManager.RouteChangeOutcome(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 62, failedCount: 0)
        let failed = RouteManager.RouteChangeOutcome(kind: .applied, at: now.addingTimeInterval(-23), routeCount: 62, failedCount: 2)
        let removed = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now.addingTimeInterval(-23), routeCount: 0, failedCount: 0)
        let stuck = RouteManager.RouteChangeOutcome(kind: .removedAll, at: now.addingTimeInterval(-23), routeCount: 2, failedCount: 2)
        let last = now.addingTimeInterval(-60), next = now.addingTimeInterval(60)
        var out = [
            StatusPage.summary(input(), now: now, bundle: bundle).title,
            StatusPage.summary(input { $0.helperReady = false }, now: now, bundle: bundle).title,
            StatusPage.summary(input { $0.installedRoutes = 0 }, now: now, bundle: bundle).title,
            StatusPage.summary(input { $0.installedRoutes = 0; $0.nothingConfigured = true }, now: now, bundle: bundle).title,
            StatusPage.helperLine(.ready, version: "4.9.0", bundle: bundle).text,
            StatusPage.helperLine(.ready, version: nil, bundle: bundle).text,
            StatusPage.vpnLine(isConnected: false, name: nil, interface: nil, bundle: bundle).text,
            StatusPage.vpnLine(isConnected: true, name: "WireGuard", interface: "utun4", bundle: bundle).text,
            StatusPage.vpnLine(isConnected: true, name: nil, interface: "utun4", bundle: bundle).text,
            StatusPage.vpnLine(isConnected: true, name: "WireGuard", interface: nil, bundle: bundle).text,
            StatusPage.normalConnectionLine(ssid: "Home", gateway: "1.2.3.4", bundle: bundle).text,
            StatusPage.normalConnectionLine(ssid: nil, gateway: "1.2.3.4", bundle: bundle).text,
            StatusPage.normalConnectionLine(ssid: "Home", gateway: nil, bundle: bundle).text,
            StatusPage.normalConnectionLine(ssid: nil, gateway: nil, bundle: bundle).text,
            StatusPage.defaultRouteLine(nil, bundle: bundle).text,
            StatusPage.defaultRouteLine(snapshot(default: nil), bundle: bundle).text,
            StatusPage.defaultRouteLine(s, bundle: bundle).text,
            StatusPage.defaultRouteLine(snapshot(default: "utun7"), bundle: bundle).text,
            StatusPage.defaultRouteLine(snapshot(default: "en0"), bundle: bundle).text,
            StatusPage.appliedLine(installed: 62, lastChange: applied, now: now, bundle: bundle).text,
            StatusPage.appliedLine(installed: 62, lastChange: failed, now: now, bundle: bundle).text,
            StatusPage.appliedLine(installed: 0, lastChange: removed, now: now, bundle: bundle).text,
            StatusPage.appliedLine(installed: 2, lastChange: stuck, now: now, bundle: bundle).text,
            StatusPage.appliedLine(installed: 0, lastChange: nil, now: now, bundle: bundle).text,
            StatusPage.fromLine(input { $0.enabledServices = 0; $0.enabledDomains = 0 }, bundle: bundle).text,
            StatusPage.fromLine(input { $0.mode = .vpnOnly; $0.enabledDomains = 0 }, bundle: bundle).text,
            StatusPage.fromLine(input { $0.mode = .custom; $0.enabledRules = 0 }, bundle: bundle).text,
            StatusPage.fromLine(input { $0.mode = .custom; $0.enabledRules = 1 }, bundle: bundle).text,
            StatusPage.fromLine(input { $0.mode = .custom; $0.enabledRules = 3 }, bundle: bundle).text,
            StatusPage.lastCheckLine([], installed: 62, now: now, bundle: bundle).text,
            StatusPage.lastCheckLine([result("1.1.1.1", ok: true, ago: 5)], installed: 62, now: now, bundle: bundle).text,
            StatusPage.lastCheckLine([result("1.1.1.1", ok: false, ago: 5)], installed: 62, now: now, bundle: bundle).text,
            StatusPage.lastCheckLine([], installed: 62, isChecking: true, now: now, bundle: bundle).text,
            StatusPage.resolverLine(nil, bundle: bundle).text,
            StatusPage.resolverLine("1.1.1.1", bundle: bundle).text,
            StatusPage.refreshedLine(last: nil, next: nil, automatic: true, now: now, bundle: bundle).text,
            StatusPage.refreshedLine(last: nil, next: nil, automatic: false, now: now, bundle: bundle).text,
            StatusPage.refreshedLine(last: last, next: nil, automatic: false, now: now, bundle: bundle).text,
            StatusPage.refreshedLine(last: nil, next: now, automatic: true, now: now, bundle: bundle).text,
            StatusPage.refreshedLine(last: nil, next: next, automatic: true, now: now, bundle: bundle).text,
            StatusPage.tunnelLine(wireguard, snapshot: s, bundle: bundle),
            StatusPage.tunnelLine(tailscale, snapshot: s, bundle: bundle),
            StatusPage.tunnelLine(other, snapshot: s, bundle: bundle),
            ownedText([catchAlls[0]], vpnOnly: true, bundle: bundle),
            ownedText(catchAlls, vpnOnly: true, bundle: bundle),
        ]
        for key in ["Status", "Helper", "Privileged helper", "Connection", "Normal connection", "Default route",
                    "Addresses", "Routed", "From", "Last check", "Verify", "Resolver", "Refreshed", "Refresh", "Act on",
                    "Automatic (recommended)", "No VPN tunnels are up.", "Addresses owned (kernel-tagged)",
                    "Reading network state…", "Recent warnings", "Show in Log"] {
            out.append(String(localized: String.LocalizationValue(key), bundle: bundle))
        }
        return out
    }

    func testEveryStringIsTranslated() throws {
        let en = try lproj("en"), es = try lproj("es"), fr = try lproj("fr")
        let english = lines(in: en)
        // Lines whose French or Spanish is the same word as the English one.
        let sameIn: [String: Set<String>] = ["fr": ["Tunnels"]]
        for (name, bundle) in [("es", es), ("fr", fr)] {
            let translated = lines(in: bundle)
            XCTAssertEqual(translated.count, english.count)
            for (e, t) in zip(english, translated) {
                if sameIn[name]?.contains(e) == true { continue }
                XCTAssertNotEqual(t, e, "\(name) has no entry for \"\(e)\"")
                XCTAssertFalse(t.contains("%"), "\(name): \(t)")
            }
        }
        XCTAssertEqual(StatusPage.vpnLine(isConnected: true, name: "WireGuard", interface: "utun4", bundle: es).text,
                       "WireGuard, conectada en utun4")
        XCTAssertEqual(StatusPage.normalConnectionLine(ssid: "Home", gateway: "192.168.1.1", bundle: fr).text,
                       "Wi-Fi « Home », passerelle 192.168.1.1")
        XCTAssertEqual(StatusPage.lastCheckLine([result("1.1.1.1", ok: false, ago: 5)], installed: 62, now: now, bundle: es).text
                        .hasPrefix("1 de 62 comprobadas, 1 sin respuesta"), true)
    }
}
