// StatusTab.swift
// Settings > Status (proposal 13 of #119): one page that answers "is it working right now?".
// It gathers the live state that used to sit at the bottom of General (Privileged Helper,
// Network Status, Coexistence, the DNS schedule) and at the top of Logs (Route Health).
// The wording is the pure `StatusPage`, so every state's text is unit-tested.

import SwiftUI

// MARK: - Wording

/// What the Status page says, as pure functions of the app's state.
enum StatusPage {
    /// What re-reads the tunnels while the page is open: the VPN coming up, going down or
    /// moving to another interface, and every apply or removal of routes, so the tagged count
    /// and the default route never contradict the Applied row. Never a timer: the read spawns
    /// `ifconfig` and `tailscale status`.
    struct TunnelReadKey: Equatable {
        let vpnInterface: String?
        let isVPNConnected: Bool
        let lastRouteChangeAt: Date?

        @MainActor
        static func current(_ routeManager: RouteManager) -> TunnelReadKey {
            TunnelReadKey(vpnInterface: routeManager.vpnInterface,
                          isVPNConnected: routeManager.isVPNConnected,
                          lastRouteChangeAt: routeManager.lastRouteChange?.at)
        }
    }

    /// The block at the top: a one-word verdict, then the dropdown's own sentence.
    struct Summary: Equatable {
        let title: String
        let sentence: String
        let note: String?
        let tone: DropdownStatus.Tone
    }

    /// One value on the right of a row, and the colour of its dot. A nil tone draws no dot.
    struct Line: Equatable {
        let text: String
        var tone: DropdownStatus.Tone? = nil
    }

    // MARK: Summary

    /// The verdict reuses `DropdownStatus.make`, so the page and the dropdown never disagree:
    /// the title names the state, the sentence is the dropdown's sentence.
    static func summary(_ input: DropdownStatus.Input, now: Date, bundle: Bundle = .main) -> Summary {
        let status = DropdownStatus.make(input, now: now)
        let title: String
        var sentence = status.sentence
        var note = status.note
        var tone = status.tone
        if status.chip == .paused {
            title = String(localized: "Paused", bundle: bundle)
        } else if input.pause != nil && status.line3.action == .retryPause {
            title = String(localized: "Pause incomplete", bundle: bundle)
        } else if !input.isStarting && !input.isVPNConnected && !input.helperReady {
            // The real blocker first: connecting the VPN would route nothing while the helper
            // is down, so the helper is the verdict and the no-VPN sentence the note under it.
            title = String(localized: "Not working", bundle: bundle)
            sentence = String(localized: "The helper is not running, so no route can change.", bundle: bundle)
            note = status.sentence
            tone = .warn
        } else if input.isStarting || !input.isVPNConnected {
            title = status.headline
        } else if !input.helperReady {
            title = String(localized: "Not working", bundle: bundle)
        } else if input.killSwitch != nil {
            title = String(localized: "No effect", bundle: bundle)
        } else if isWaiting(input) {
            // WAITING or HELD BACK: the dropdown's headline already says what the tunnel did.
            title = status.headline
        } else if input.installedRoutes == 0 && input.nothingConfigured {
            title = String(localized: "Not set up", bundle: bundle)
        } else if input.installedRoutes == 0 && !input.everythingElseDirect {
            title = String(localized: "Nothing routed", bundle: bundle)
        } else {
            title = status.isPartial
                ? String(localized: "Partly working", bundle: bundle)
                : String(localized: "Working", bundle: bundle)
            if let change = DropdownCopy.shownRouteChange(input.lastRouteChange,
                                                          currentRouteCount: input.installedRoutes),
               change.kind == .applied {
                sentence += " " + DropdownCopy.routeChangeLine(change, now: now).text
            }
        }
        return Summary(title: title, sentence: sentence, note: note, tone: tone)
    }

    /// The same test `DropdownStatus.make` makes before it shows WAITING or HELD BACK: a
    /// pending re-apply that nothing has applied or removed routes since.
    static func isWaiting(_ input: DropdownStatus.Input) -> Bool {
        guard let pending = input.pending else { return false }
        if let change = input.lastRouteChange, change.at > pending.connectedAt { return false }
        return true
    }

    // MARK: Order

    /// The page's sections, top to bottom.
    enum Section: Equatable {
        case helper, problems, routeCheck, siteCheck, connection, addresses, dns, tunnels, warnings
    }

    /// A helper that is not ready is why nothing routes, so its section comes first, before the
    /// problems it causes; a ready helper sits with the other facts.
    static func sections(helperReady: Bool) -> [Section] {
        let rest: [Section] = [.connection, .addresses, .dns, .tunnels, .warnings]
        return helperReady
            ? [.problems, .routeCheck, .siteCheck, .helper] + rest
            : [.helper, .problems, .routeCheck, .siteCheck] + rest
    }

    // MARK: Where does this site go?

    /// The answer's leading glyph: ▲ when the check found something wrong or the name did not
    /// resolve, a tick when it left the way it should and answered, a plain glyph otherwise.
    static func siteGlyph(_ verdict: SiteRouteAnswer.Verdict) -> (glyph: String, needsAttention: Bool) {
        switch verdict {
        case .ok: return ("checkmark.circle", false)
        case .noVPN: return ("circle", false)
        case .notChecked: return ("arrow.triangle.branch", false)
        case .noAnswer, .wrongWay, .unknown, .checkBroken, .unresolved: return ("globe", true)
        }
    }

    /// The Add button beside an answer: shown only when nothing lists the site, titled for what
    /// it does in this mode (the Lookups page's words), with its tooltip as the spoken name.
    static func siteAdd(_ answer: SiteRouteAnswer, mode: LookupMode) -> (title: String, help: String)? {
        answer.canAdd ? (mode.addTitle, mode.addHelp) : nil
    }

    /// What the field says after a check of text that holds no host.
    static func siteNoHost(bundle: Bundle = .main) -> String {
        String(localized: "That is not a name, a link or an address.", bundle: bundle)
    }

    // MARK: Helper

    static func helperLine(_ state: HelperState, version: String?, bundle: Bundle = .main) -> Line {
        switch state {
        case .ready:
            guard let version else { return Line(text: String(localized: "Ready", bundle: bundle), tone: .ok) }
            return Line(text: String(localized: "Ready, version \(version)", bundle: bundle), tone: .ok)
        case .checking, .installing, .outdated:
            return Line(text: state.statusText, tone: .warn)
        case .missing, .failed:
            return Line(text: state.statusText, tone: .bad)
        }
    }

    /// The line under the helper row when it is not ready; nil when it is.
    static func helperHint(_ state: HelperState, bundle: Bundle = .main) -> String? {
        switch state {
        case .ready: return nil
        case .checking: return String(localized: "Verifying helper version...", bundle: bundle)
        case .installing: return String(localized: "Admin authorization required...", bundle: bundle)
        case .outdated: return String(localized: "Helper needs updating for this version", bundle: bundle)
        case .missing: return String(localized: "Install to enable route management", bundle: bundle)
        case .failed: return String(localized: "Helper could not be started", bundle: bundle)
        }
    }

    /// The helper row's button, or nil when there is nothing to do.
    static func helperAction(_ state: HelperState, isInstalling: Bool, bundle: Bundle = .main) -> String? {
        if isInstalling { return String(localized: "Installing...", bundle: bundle) }
        switch state {
        case .missing: return String(localized: "Install", bundle: bundle)
        case .outdated: return String(localized: "Update", bundle: bundle)
        case .failed: return String(localized: "Retry", bundle: bundle)
        case .ready, .checking, .installing: return nil
        }
    }

    // MARK: Connection

    static func vpnLine(isConnected: Bool, name: String?, interface: String?, bundle: Bundle = .main) -> Line {
        guard isConnected else { return Line(text: String(localized: "Not connected", bundle: bundle), tone: .bad) }
        switch (name, interface) {
        case let (name?, iface?): return Line(text: String(localized: "\(name), connected on \(iface)", bundle: bundle), tone: .ok)
        case let (nil, iface?): return Line(text: String(localized: "Connected on \(iface)", bundle: bundle), tone: .ok)
        case let (name?, nil): return Line(text: String(localized: "\(name), connected", bundle: bundle), tone: .ok)
        case (nil, nil): return Line(text: String(localized: "Connected", bundle: bundle), tone: .ok)
        }
    }

    /// The connection traffic takes when it skips the VPN. No Wi-Fi name: the app read it from
    /// `airport -I`, which current macOS no longer has, so it never showed.
    static func normalConnectionLine(gateway: String?, bundle: Bundle = .main) -> Line {
        guard let gateway else { return Line(text: String(localized: "No gateway found", bundle: bundle), tone: .warn) }
        return Line(text: String(localized: "Gateway \(gateway)", bundle: bundle))
    }

    /// Which interface carries the default route, and what it is to this app. Nil
    /// `snapshot` means the tunnels have not been read yet.
    static func defaultRouteLine(_ snapshot: RouteManager.CoexistenceSnapshot?, bundle: Bundle = .main) -> Line {
        guard let snapshot else { return Line(text: String(localized: "Reading…", bundle: bundle)) }
        guard let iface = snapshot.defaultRouteInterface else {
            return Line(text: String(localized: "Not found", bundle: bundle), tone: .warn)
        }
        if iface == snapshot.selectedInterface {
            return Line(text: String(localized: "\(iface), the VPN", bundle: bundle))
        }
        if let link = snapshot.links.first(where: { $0.interface == iface }) {
            return link.isTailscale
                ? Line(text: String(localized: "\(iface), Tailscale", bundle: bundle))
                : Line(text: String(localized: "\(iface), another tunnel", bundle: bundle))
        }
        return Line(text: String(localized: "\(iface), outside the VPN", bundle: bundle))
    }

    // MARK: Routes

    static func routes(_ n: Int, bundle: Bundle = .main) -> String {
        n == 1 ? String(localized: "1 address", bundle: bundle) : String(localized: "\(n) addresses", bundle: bundle)
    }

    /// The Applied row: what the last apply or removal did, or what is installed.
    static func appliedLine(installed: Int, lastChange: RouteManager.RouteChangeOutcome?, now: Date,
                            helperReady: Bool = true, bundle: Bundle = .main) -> Line {
        // Same rule as the dropdown: a removal stops being reported once routes are back, and
        // with the helper not ready a past apply is not reported over a "Not working" title.
        guard let change = DropdownCopy.shownRouteChange(lastChange, currentRouteCount: installed,
                                                         helperReady: helperReady) else {
            return installed > 0
                ? Line(text: routes(installed, bundle: bundle))
                : Line(text: String(localized: "None yet", bundle: bundle))
        }
        let when = DropdownCopy.age(since: change.at, now: now)
        switch change.kind {
        case .applied:
            let count = routes(change.routeCount, bundle: bundle)
            return change.failedCount == 0
                ? Line(text: String(localized: "\(count), \(when), none failed", bundle: bundle))
                : Line(text: String(localized: "\(count), \(when), \(change.failedCount) failed", bundle: bundle), tone: .warn)
        case .removedAll:
            return change.failedCount == 0
                ? Line(text: String(localized: "All removed \(when)", bundle: bundle), tone: .warn)
                : Line(text: String(localized: "Removed \(when), \(change.failedCount) could not be removed", bundle: bundle), tone: .bad)
        }
    }

    /// The From row: what the user's lists hold for the current mode.
    static func fromLine(_ input: DropdownStatus.Input, bundle: Bundle = .main) -> Line {
        switch input.mode {
        case .bypass:
            let s = input.enabledServices, d = input.enabledDomains
            if s == 0 && d == 0 { return Line(text: String(localized: "No services or domains", bundle: bundle)) }
            let services = s == 1 ? String(localized: "1 service", bundle: bundle) : String(localized: "\(s) services", bundle: bundle)
            let domains = d == 1 ? String(localized: "1 domain", bundle: bundle) : String(localized: "\(d) domains", bundle: bundle)
            if d == 0 { return Line(text: services) }
            if s == 0 { return Line(text: domains) }
            return Line(text: String(localized: "\(services), \(domains)", bundle: bundle))
        case .vpnOnly:
            let d = input.enabledDomains
            if d == 0 { return Line(text: String(localized: "No entries", bundle: bundle)) }
            return Line(text: d == 1 ? String(localized: "1 entry", bundle: bundle) : String(localized: "\(d) entries", bundle: bundle))
        case .custom:
            let r = input.enabledRules
            if r == 0 { return Line(text: String(localized: "No rules", bundle: bundle)) }
            return Line(text: r == 1 ? String(localized: "1 rule", bundle: bundle) : String(localized: "\(r) rules", bundle: bundle))
        }
    }

    /// The Last check row as the page draws it: the line, the spinner and the Verify button.
    struct LastCheck: Equatable {
        let line: Line
        /// A check is pinging now. Drawn as a spinner beside a greyed-out Verify.
        let isChecking: Bool
        let canVerify: Bool
    }

    /// The Last check row from the manager's own state. `isCheckingRoutes` is set by every
    /// check, so the spinner also shows one started by an apply or from the dropdown.
    @MainActor
    static func lastCheck(_ routeManager: RouteManager, now: Date, bundle: Bundle = .main) -> LastCheck {
        let isChecking = routeManager.isCheckingRoutes
        return LastCheck(line: lastCheckLine(Array(routeManager.routeVerificationResults.values),
                                             installed: routeManager.routedAddressCount,
                                             isChecking: isChecking, now: now, bundle: bundle),
                         isChecking: isChecking,
                         canVerify: !isChecking && !routeManager.activeRoutes.isEmpty)
    }

    /// The Last check row, from Verify Routes' results. Verify pings a sample, so the line
    /// says how many of the installed routes it checked. A check clears the last results when
    /// it starts, so while one runs the line says so instead of "Not checked yet".
    static func lastCheckLine(_ results: [RouteVerificationResult], installed: Int, isChecking: Bool = false,
                              now: Date, bundle: Bundle = .main) -> Line {
        if isChecking { return Line(text: String(localized: "Checking now…", bundle: bundle)) }
        guard let at = results.map(\.timestamp).max() else {
            return Line(text: String(localized: "Not checked yet", bundle: bundle))
        }
        let checked = results.count
        let total = max(installed, checked)
        let failed = results.filter { !$0.isReachable }.count
        let when = DropdownCopy.age(since: at, now: now)
        return failed == 0
            ? Line(text: String(localized: "\(checked) of \(total) checked, all reachable, \(when)", bundle: bundle))
            : Line(text: String(localized: "\(checked) of \(total) checked, \(failed) not reachable, \(when)", bundle: bundle), tone: .warn)
    }

    // MARK: Problems

    /// One row of Problems: what failed, and why.
    struct Problem: Equatable, Identifiable {
        enum Kind: Equatable {
            case notRouted, notResolved, notRemoved, noAddresses, unlisted
        }
        let kind: Kind
        /// The address, the name, or the entry.
        let title: String
        /// What it was for and the reason.
        let detail: String

        var id: String { "\(kind)|\(title)|\(detail)" }
    }

    /// Every failure the dropdown's count includes, in the order the apply met them: the
    /// addresses the helper did not route (or remove), with their entry and the reason it gave,
    /// and the names that did not resolve, with their entry and the DNS error. Then the
    /// entries left with no address, and a last row for failures counted but not itemised.
    /// Empty when nothing failed. Shown on the same rule as the dropdown (`shownRouteChange`),
    /// so the page never lists failures the dropdown no longer counts. An address that is
    /// routed by now (a DNS retry or a later add put it in) is left out.
    static func problems(lastChange: RouteManager.RouteChangeOutcome?, installed: Int, helperReady: Bool,
                         withoutAddresses: [RoutedBySource.Row], routes: [RoutedBySource.InstalledRoute] = [],
                         bundle: Bundle = .main) -> [Problem] {
        var out: [Problem] = []
        let lastChange = lastChange?.outstanding(routedNow: Set(routes.map(\.destination)))
        if let change = DropdownCopy.shownRouteChange(lastChange, currentRouteCount: installed, helperReady: helperReady),
           change.failedCount > 0 {
            for failure in change.failures {
                let kind: Problem.Kind
                let what: String
                switch failure.kind {
                case .notRouted:
                    kind = .notRouted
                    what = String(localized: "Not routed", bundle: bundle)
                case .notResolved:
                    kind = .notResolved
                    what = String(localized: "Did not resolve", bundle: bundle)
                case .notRemoved:
                    kind = .notRemoved
                    what = String(localized: "Not removed", bundle: bundle)
                }
                // A domain listed on its own is its own entry: say it once.
                let detail = failure.entry.isEmpty || failure.entry == failure.target
                    ? String(localized: "\(what): \(failure.reason)", bundle: bundle)
                    : String(localized: "\(what), for \(failure.entry): \(failure.reason)", bundle: bundle)
                out.append(Problem(kind: kind, title: failure.target, detail: detail))
            }
            let unlisted = change.failedCount - change.failures.count
            if unlisted > 0 {
                out.append(Problem(kind: .unlisted,
                                   title: unlisted == 1
                                       ? String(localized: "1 more failure", bundle: bundle)
                                       : String(localized: "\(unlisted) more failures", bundle: bundle),
                                   detail: String(localized: "Settings > Logs has the details.", bundle: bundle)))
            }
        }
        // After Remove All Routes an empty entry is what the user asked for; what it could not
        // remove is listed above.
        let removed = DropdownCopy.removalStands(lastChange, currentRouteCount: installed, helperReady: helperReady)
        for row in withoutAddresses where row.isProblem && !removed {
            out.append(Problem(kind: .noAddresses, title: row.name,
                               detail: String(localized: "No address is routed for it.", bundle: bundle)))
        }
        return out
    }

    /// What Problems' Retry does: after a Remove All Routes that left routes behind it removes
    /// them again, since applying would put back every route the user just took away.
    enum RetryAction: Equatable { case apply, remove }

    static func retryAction(lastChange: RouteManager.RouteChangeOutcome?, installed: Int,
                            helperReady: Bool) -> RetryAction {
        let change = DropdownCopy.shownRouteChange(lastChange, currentRouteCount: installed, helperReady: helperReady)
        return change?.kind == .removedAll && (change?.failedCount ?? 0) > 0 ? .remove : .apply
    }

    // MARK: DNS

    static func resolverLine(_ detected: String?, bundle: Bundle = .main) -> Line {
        guard let detected else { return Line(text: String(localized: "Not detected", bundle: bundle), tone: .warn) }
        return Line(text: String(localized: "\(detected), outside the VPN", bundle: bundle))
    }

    static func refreshedLine(last: Date?, next: Date?, automatic: Bool, now: Date, bundle: Bundle = .main) -> Line {
        let when = last.map { DropdownCopy.age(since: $0, now: now) }
        guard automatic else {
            return Line(text: when.map { String(localized: "\($0), automatic refresh off", bundle: bundle) }
                ?? String(localized: "Not yet, automatic refresh off", bundle: bundle))
        }
        guard let next else {
            return Line(text: when ?? String(localized: "Not yet", bundle: bundle))
        }
        let left = next.timeIntervalSince(now)
        if left <= 0 {
            return Line(text: when.map { String(localized: "\($0), next one due now", bundle: bundle) }
                ?? String(localized: "Not yet, next one due now", bundle: bundle))
        }
        let countdown = DropdownStatus.countdown(left)
        return Line(text: when.map { String(localized: "\($0), next in \(countdown)", bundle: bundle) }
            ?? String(localized: "Not yet, next in \(countdown)", bundle: bundle))
    }

    // MARK: Tunnels

    /// One plain sentence per tunnel, in place of the old acting on, default route and
    /// Tailscale badges.
    static func tunnelLine(_ link: RouteManager.VPNLink, snapshot: RouteManager.CoexistenceSnapshot,
                           bundle: Bundle = .main) -> String {
        let role: String
        if link.isTailscale {
            role = String(localized: "Never touched.", bundle: bundle)
        } else if link.interface == snapshot.selectedInterface {
            role = String(localized: "The app acts on this one.", bundle: bundle)
        } else {
            role = String(localized: "Not used by the app.", bundle: bundle)
        }
        guard link.interface == snapshot.defaultRouteInterface else { return role }
        return role + " " + String(localized: "It carries the default route.", bundle: bundle)
    }

    /// The Addresses owned row: the kernel's tagged routes, counted by the rule every other
    /// count uses (`RoutedBySource`). In VPN Only the catch-alls are named apart, so while the
    /// kernel holds what the app recorded, the first number is the Routed row's. A tagged
    /// destination the app has no record of counts as an address.
    static func ownedLine(tagged: [String], installed: [RoutedBySource.InstalledRoute], vpnOnly: Bool,
                          bundle: Bundle = .main) -> Line {
        let inKernel = Set(tagged)
        let recorded = installed.filter { inKernel.contains($0.destination) }
        let unrecorded = inKernel.subtracting(recorded.map(\.destination))
            .map { RoutedBySource.InstalledRoute(destination: $0, source: "") }
        let routes = recorded + unrecorded
        let addresses = RoutedBySource.addressCount(routes, vpnOnly: vpnOnly)
        switch RoutedBySource.catchAllCount(routes, vpnOnly: vpnOnly) {
        case 0: return Line(text: "\(addresses)")
        case 1: return Line(text: String(localized: "\(addresses), plus 1 catch-all", bundle: bundle))
        case let n: return Line(text: String(localized: "\(addresses), plus \(n) catch-alls", bundle: bundle))
        }
    }

    // MARK: Recent warnings

    /// The newest warnings and errors, newest first, as the log keeps them.
    static func recentWarnings(_ logs: [RouteManager.LogEntry], limit: Int = 3) -> [RouteManager.LogEntry] {
        Array(logs.filter { LogLevelFilter.warnings.admits($0.level) }.prefix(limit))
    }
}

extension DropdownStatus.Input {
    /// Everything the status sentence reads, from the live app state. The dropdown's header
    /// and the Status page both build their input here, so they read the same facts.
    @MainActor
    static func current(_ routeManager: RouteManager, helperReady: Bool) -> DropdownStatus.Input {
        let config = routeManager.config
        let mode: DropdownCopy.Mode = RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode)
            ? .custom
            : (config.routingMode == .vpnOnly ? .vpnOnly : .bypass)
        let routed = Set(routeManager.activeRoutes.map(\.destination))
        return DropdownStatus.Input(
            isVPNConnected: routeManager.isVPNConnected,
            vpnName: routeManager.vpnType.flatMap { $0 == .unknown ? nil : $0.rawValue },
            helperReady: helperReady,
            mode: mode,
            enabledServices: config.services.filter { $0.enabled }.count,
            enabledDomains: mode == .vpnOnly
                ? config.inverseDomains.filter { $0.enabled }.count
                : config.domains.filter { $0.enabled }.count,
            enabledRules: config.rules.filter { $0.enabled }.count,
            installedRoutes: routeManager.routedAddressCount,
            pending: routeManager.pendingReconnectApply,
            // Without the failed addresses routed since, as Problems lists them.
            lastRouteChange: routeManager.lastRouteChange?.outstanding(routedNow: routed),
            lastDNSRefresh: routeManager.lastDNSRefresh,
            nextDNSRefresh: routeManager.nextDNSRefresh,
            autoDNSRefresh: config.autoDNSRefresh,
            nothingConfigured: FirstRunSetup.isFresh(mode: config.routingMode,
                                                     domains: config.domains,
                                                     services: config.services,
                                                     installedRoutes: routeManager.routedAddressCount),
            everythingElseDirect: routeManager.everythingElseDirect,
            killSwitch: routeManager.vpnKillSwitch,
            isStarting: routeManager.isLoading && routeManager.lastUpdate == nil,
            // After Remove All Routes an empty entry is what the user asked for.
            entriesWithoutAddresses: DropdownCopy.removalStands(routeManager.lastRouteChange,
                                                                currentRouteCount: routeManager.routedAddressCount,
                                                                helperReady: helperReady) ? 0 : RoutedBySource.make(
                mode: mode, config: config, routes: routeManager.installedRoutes,
                busy: RoutedBySource.mayStillAddRoutes(running: routeManager.isLoading || routeManager.isApplyingRoutes,
                                                       pending: routeManager.pendingReconnectApply))?.problemCount ?? 0,
            lastCheckCount: routeManager.lastRouteCheck?.results.count ?? 0,
            // Only addresses still routed: one removed since the check is no longer a fault.
            lastCheckWrongWay: routeManager.lastRouteCheck?.leftWrongWay
                .filter { routed.contains($0.destination) }.count ?? 0,
            lastCheckBroken: routeManager.lastRouteCheck?.controlBroken ?? false,
            pause: routeManager.pauseState
        )
    }
}

// MARK: - Page

struct StatusTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var helperManager = HelperManager.shared
    /// Opens the Logs page with Warnings selected.
    private let onShowWarnings: () -> Void
    /// Opens the Logs page on every line, for the route check's results.
    private let onShowLogs: () -> Void
    /// False when a snapshot was handed in: the page shows it as given, so a test or a render
    /// can show any tunnel state, until Refresh reads the real one.
    private let readsTunnelsOnChange: Bool

    @State private var snapshot: RouteManager.CoexistenceSnapshot?
    @State private var isReadingTunnels = false
    /// "Where does this site go?": the field, the check and its answer.
    @StateObject private var siteRoute: SiteRouteModel
    /// What the last Add from the answer saved, or why it saved nothing.
    @State private var siteAddFeedback: AddDomainFeedback?
    /// The doc screenshots open the page with this in the field and its answer under it.
    static var siteCheckForScreenshots: (query: String, answer: SiteRouteAnswer)?

    init(onShowWarnings: @escaping () -> Void = {}, onShowLogs: @escaping () -> Void = {},
         snapshot: RouteManager.CoexistenceSnapshot? = nil) {
        self.onShowWarnings = onShowWarnings
        self.onShowLogs = onShowLogs
        _snapshot = State(initialValue: snapshot)
        readsTunnelsOnChange = snapshot == nil
        let seed = Self.siteCheckForScreenshots
        _siteRoute = StateObject(wrappedValue: SiteRouteModel(query: seed?.query ?? "", answer: seed?.answer))
    }

    var body: some View {
        // Ticks once a second so the ages and the DNS countdown stay true while the page is open.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .task { if readsTunnelsOnChange { await readTunnels() } }
        .onAppear(perform: MenuBarIconHiddenNote.refreshOnAppear)
        .onChange(of: StatusPage.TunnelReadKey.current(routeManager)) { _ in
            if readsTunnelsOnChange { Task { await readTunnels() } }
        }
    }

    private func content(now: Date) -> some View {
        let input = DropdownStatus.Input.current(routeManager, helperReady: helperManager.helperState.isReady)
        return VStack(alignment: .leading, spacing: Theme.Space.l + 2) {
            MenuBarIconHiddenNote()
            summaryView(StatusPage.summary(input, now: now))
            ForEach(StatusPage.sections(helperReady: helperManager.helperState.isReady), id: \.self) { section in
                switch section {
                case .helper: helperSection
                case .problems: problemsSection(input)
                case .routeCheck: routeCheckSection
                case .siteCheck: siteCheckSection
                case .connection: connectionSection
                case .addresses: routesSection(input, now: now)
                case .dns: dnsSection(now: now)
                case .tunnels: tunnelsSection
                case .warnings: warningsSection
                }
            }
        }
    }

    // MARK: Summary

    private func summaryView(_ summary: StatusPage.Summary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(summary.tone.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: summaryIcon(summary.tone))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(summary.tone.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(Theme.Font.title)
                    .foregroundColor(Theme.text)
                Text(summary.sentence)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = summary.note {
                    Text(note)
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryIcon(_ tone: DropdownStatus.Tone) -> String {
        switch tone {
        case .ok: return "checkmark"
        case .warn: return "exclamationmark"
        case .bad: return "xmark"
        case .idle: return "minus"
        }
    }

    // MARK: Sections

    /// Where the dropdown's "Show" lands: every failure behind its count, with Retry.
    @ViewBuilder
    private func problemsSection(_ input: DropdownStatus.Input) -> some View {
        // With no VPN an entry without addresses is expected, as in the dropdown's list.
        let missing = !input.isVPNConnected ? [] : RoutedBySource.make(
            mode: input.mode, config: routeManager.config, routes: routeManager.installedRoutes,
            busy: RoutedBySource.mayStillAddRoutes(running: routeManager.isLoading || routeManager.isApplyingRoutes,
                                                   pending: routeManager.pendingReconnectApply))?.problemRows ?? []
        let problems = StatusPage.problems(lastChange: routeManager.lastRouteChange,
                                           installed: routeManager.routedAddressCount,
                                           helperReady: input.helperReady, withoutAddresses: missing,
                                           routes: routeManager.installedRoutes)
        if !problems.isEmpty {
            GroupSection(String(localized: "Problems"), trailing: {
                let retry = StatusPage.retryAction(lastChange: routeManager.lastRouteChange,
                                                   installed: routeManager.routedAddressCount,
                                                   helperReady: input.helperReady)
                Button(String(localized: "Retry")) {
                    switch retry {
                    case .apply: routeManager.refreshRoutes()
                    case .remove: Task { await routeManager.removeAllRoutes() }
                    }
                }
                    .controlSize(.small)
                    .disabled(routeManager.isLoading || routeManager.isApplyingRoutes || !input.helperReady
                              || (retry == .apply && !routeManager.isVPNConnected))
                    .help(retry == .apply ? String(localized: "Apply the routes again")
                                          : String(localized: "Remove the routes again"))
                    .accessibilityLabel(retry == .apply ? String(localized: "Retry: apply the routes again")
                                                        : String(localized: "Retry: remove the routes again"))
            }) {
                ForEach(Array(problems.enumerated()), id: \.element.id) { index, problem in
                    if index > 0 { InsetDivider() }
                    ListRow(glyph: "exclamationmark.triangle.fill", name: problem.title,
                            detail: problem.detail, needsAttention: true)
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// The last Verify Routes, moved here from the dropdown; Dismiss takes it away.
    @ViewBuilder
    private var routeCheckSection: some View {
        if let run = routeManager.lastRouteCheck {
            RouteCheckCard(run: run,
                           logsHoldResults: run.logsHoldResults(oldestLogAt: routeManager.recentLogs.last?.timestamp),
                           onShowLogs: onShowLogs,
                           onDismiss: { routeManager.clearRouteCheck() })
        }
    }

    /// "Where does this site go?": a name, a link or an address in, one answer out, with Add
    /// when nothing lists the site. The same model as `vpnb why`.
    private var siteCheckSection: some View {
        GroupSection(String(localized: "Where does this site go?")) {
            HStack(spacing: Theme.Space.s) {
                TextField(String(localized: "A name, a link or an address"), text: $siteRoute.query)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.body)
                    .onSubmit(checkSite)
                    .accessibilityLabel(String(localized: "Site to check"))
                if siteRoute.isChecking {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel(String(localized: "Checking now…"))
                }
                Button(String(localized: "Check"), action: checkSite)
                    .disabled(siteRoute.isChecking || siteRoute.query.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(String(localized: "Say which entry routes this site, and check the way it leaves"))
                    .accessibilityLabel(String(localized: "Check the site"))
            }
            .padding(.horizontal, ListRow.inset)
            .padding(.vertical, Theme.Space.s)
            if let answer = siteRoute.answer {
                InsetDivider()
                let look = StatusPage.siteGlyph(answer.verdict)
                ListRow(glyph: look.glyph, name: answer.host, detail: answer.summary,
                        needsAttention: look.needsAttention,
                        accessory: StatusPage.siteAdd(answer, mode: LookupMode(routeManager)).map { add in
                            AnyView(Button(add.title) { addSite(answer.host) }
                                .controlSize(.small)
                                .disabled(routeManager.isApplyingRoutes)
                                .help(add.help)
                                .accessibilityLabel(add.help))
                        },
                        detailLineLimit: nil)
            } else if siteRoute.checkedQuery != nil, !siteRoute.isChecking {
                StatusNote(text: StatusPage.siteNoHost())
            }
            if let feedback = siteAddFeedback {
                AddDomainFeedbackLine(feedback: feedback)
                    .padding(.horizontal, ListRow.inset)
                    .padding(.bottom, Theme.Space.s)
            }
        }
    }

    private var helperSection: some View {
        let state = helperManager.helperState
        let line = StatusPage.helperLine(state, version: helperManager.helperVersion)
        // A helper that is not ready is why nothing is routed: its section comes first.
        return GroupSection(String(localized: "Helper")) {
            StatusLineRow(label: String(localized: "Privileged helper"), line: line) {
                if let action = StatusPage.helperAction(state, isInstalling: helperManager.isInstalling) {
                    Button(action) { installHelper() }
                        .disabled(helperManager.isInstalling)
                }
            }
            .help(String(localized: "The helper runs as root and handles route/hosts changes without prompting."))
            if let hint = StatusPage.helperHint(state) {
                StatusNote(text: hint)
            }
            if let error = helperManager.installationError {
                StatusNote(text: error, color: Theme.attention)
            }
        }
    }

    private var connectionSection: some View {
        GroupSection(String(localized: "Connection")) {
            StatusLineRow(label: String(localized: "VPN"),
                          line: StatusPage.vpnLine(isConnected: routeManager.isVPNConnected,
                                                   name: routeManager.vpnType.flatMap { $0 == .unknown ? nil : $0.rawValue },
                                                   interface: routeManager.vpnInterface))
            StatusDivider()
            StatusLineRow(label: String(localized: "Normal connection"),
                          line: StatusPage.normalConnectionLine(gateway: routeManager.localGateway))
            StatusDivider()
            StatusLineRow(label: String(localized: "Default route"), line: StatusPage.defaultRouteLine(snapshot))
        }
    }

    private func routesSection(_ input: DropdownStatus.Input, now: Date) -> some View {
        GroupSection(String(localized: "Addresses")) {
            StatusLineRow(label: String(localized: "Routed"),
                          line: StatusPage.appliedLine(installed: routeManager.routedAddressCount,
                                                       lastChange: input.lastRouteChange, now: now,
                                                       helperReady: input.helperReady))
            StatusDivider()
            StatusLineRow(label: String(localized: "From"), line: StatusPage.fromLine(input))
            StatusDivider()
            let check = StatusPage.lastCheck(routeManager, now: now)
            StatusLineRow(label: String(localized: "Last check"), line: check.line) {
                HStack(spacing: 6) {
                    if check.isChecking {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                    Button(String(localized: "Verify")) { verify() }
                        .disabled(!check.canVerify)
                }
            }
        }
    }

    private func dnsSection(now: Date) -> some View {
        GroupSection(String(localized: "DNS")) {
            StatusLineRow(label: String(localized: "Resolver"),
                          line: StatusPage.resolverLine(routeManager.detectedDNSServerDisplay))
            StatusDivider()
            StatusLineRow(label: String(localized: "Refreshed"),
                          line: StatusPage.refreshedLine(last: routeManager.lastDNSRefresh,
                                                         next: routeManager.nextDNSRefresh,
                                                         automatic: routeManager.config.autoDNSRefresh,
                                                         now: now)) {
                Button(String(localized: "Refresh Now")) { routeManager.forceDNSRefresh() }
                    .disabled(routeManager.isApplyingRoutes || routeManager.isPaused)
            }
        }
    }

    private var tunnelsSection: some View {
        GroupSection(String(localized: "Tunnels"), trailing: {
            Button(String(localized: "Refresh")) { Task { await readTunnels() } }
                .controlSize(.small)
                .disabled(isReadingTunnels)
                .help(String(localized: "Read the tunnels again"))
        }) {
            if let snapshot {
                if snapshot.links.isEmpty {
                    StatusPlainRow(text: String(localized: "No VPN tunnels are up."))
                } else {
                    ForEach(snapshot.links) { link in
                        HStack(spacing: 10) {
                            Text(link.interface)
                                .font(Theme.Font.mono)
                                .foregroundColor(Theme.text)
                            Text(VPNType.displayLabel(link.label))
                                .font(Theme.Font.body)
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: Theme.Space.m)
                            Text(StatusPage.tunnelLine(link, snapshot: snapshot))
                                .font(Theme.Font.body)
                                .foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, ListRow.inset)
                        .frame(minHeight: ListRow.singleLineHeight)
                        StatusDivider()
                    }
                }
                actOnRow(snapshot)
                if let pinned = routeManager.config.pinnedVPNInterface,
                   let selected = snapshot.selectedInterface, pinned != selected {
                    StatusNote(text: String(localized: "Pinned tunnel \(pinned) is not eligible right now — acting on \(selected) automatically."),
                               color: Theme.attention)
                }
                StatusDivider()
                StatusLineRow(label: String(localized: "Addresses owned (kernel-tagged)"),
                              line: StatusPage.ownedLine(tagged: snapshot.taggedDestinations,
                                                         installed: routeManager.installedRoutes,
                                                         vpnOnly: routeManager.config.routingMode == .vpnOnly))
            } else {
                StatusPlainRow(text: String(localized: "Reading network state…"))
            }
        }
    }

    /// The pin: act only on one tunnel. A stale pin degrades to automatic with a logged
    /// warning, never to a silent no-op.
    private func actOnRow(_ snapshot: RouteManager.CoexistenceSnapshot) -> some View {
        HStack {
            Text(String(localized: "Act on"))
                .font(Theme.Font.body)
                .foregroundColor(Theme.text)
            Spacer()
            Picker(String(localized: "Act on"), selection: Binding(
                get: { routeManager.config.pinnedVPNInterface ?? "" },
                set: { iface in
                    routeManager.config.pinnedVPNInterface = iface.isEmpty ? nil : iface
                    routeManager.config.pinnedVPNProductHint = iface.isEmpty ? nil
                        : snapshot.links.first(where: { $0.interface == iface })?.label
                    routeManager.saveConfig()
                    Task {
                        await routeManager.reconcileAfterConfigChange(reconcileListeners: false, reapplyRoutes: true)
                        await readTunnels()
                    }
                }
            )) {
                Text(String(localized: "Automatic (recommended)")).tag("")
                ForEach(snapshot.links.filter { !$0.isTailscale }) { link in
                    Text("\(VPNType.displayLabel(link.label)) · \(link.interface)").tag(link.interface)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, ListRow.inset)
        .frame(minHeight: ListRow.singleLineHeight)
    }

    private var warningsSection: some View {
        let warnings = StatusPage.recentWarnings(routeManager.recentLogs)
        return GroupSection(String(localized: "Recent warnings"), trailing: {
            Button(String(localized: "Show in Log")) { onShowWarnings() }
                .buttonStyle(.link)
        }) {
            if warnings.isEmpty {
                StatusPlainRow(text: String(localized: "No warnings or errors."))
            } else {
                ForEach(Array(warnings.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { StatusDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: entry.level == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(entry.level == .error ? Theme.failure : Theme.attention)
                        Text(entry.timestamp, format: .dateTime.hour().minute())
                            .font(Theme.Font.mono)
                            .monospacedDigit()
                            .foregroundColor(Theme.textSecondary)
                        Text(entry.message)
                            .font(Theme.Font.body)
                            .foregroundColor(Theme.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, ListRow.inset)
                    .padding(.vertical, Theme.Space.s)
                }
            }
        }
    }

    // MARK: Actions

    private func checkSite() {
        guard !siteRoute.isChecking, !siteRoute.query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        siteAddFeedback = nil
        Task { await siteRoute.check(routeManager) }
    }

    /// Adds the site as the current mode adds a name, then checks it again so the answer says
    /// what the entry changed.
    private func addSite(_ host: String) {
        guard let result = routeManager.addForCurrentMode(host) else { return }
        siteAddFeedback = AddDomainFeedback(result, typed: host)
        if case .success = result {
            siteRoute.query = host
            Task { await siteRoute.check(routeManager) }
        }
    }

    /// On appear, on a `TunnelReadKey` change and on Refresh only: the read spawns `ifconfig`
    /// and `tailscale status`, which must never sit on a timer.
    private func readTunnels() async {
        isReadingTunnels = true
        snapshot = await routeManager.coexistenceSnapshot()
        isReadingTunnels = false
    }

    /// The spinner and the greyed-out button follow `isCheckingRoutes`, the flag every check
    /// sets, so this page never starts a second check over one an apply or the dropdown began.
    private func verify() {
        guard !routeManager.isCheckingRoutes else { return }
        Task { await routeManager.verifyRoutes() }
    }

    private func installHelper() {
        Task {
            let ready = await helperManager.ensureHelperReady()
            if ready && routeManager.isVPNConnected && routeManager.activeRoutes.isEmpty {
                // Helper just became ready and VPN is connected but no routes: the initial
                // startup was skipped because the helper wasn't ready. Apply routes and start
                // the DNS refresh lifecycle.
                await routeManager.detectAndApplyRoutesAsync()
                routeManager.startDNSRefreshTimer()
            }
        }
    }
}

// MARK: - Building blocks

/// A label on the left, a value on the right with an optional dot, and an optional button.
struct StatusLineRow<Accessory: View>: View {
    let label: String
    let line: StatusPage.Line
    let accessory: Accessory

    init(label: String, line: StatusPage.Line, @ViewBuilder accessory: () -> Accessory) {
        self.label = label
        self.line = line
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(label)
                .font(Theme.Font.body)
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: Theme.Space.m)
            HStack(spacing: 6) {
                if let tone = line.tone {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 7, height: 7)
                }
                Text(line.text)
                    .font(Theme.Font.body)
                    // A fault reads in its colour; a healthy value stays grey beside its green dot.
                    .foregroundColor(line.tone.flatMap { $0 == .warn || $0 == .bad ? $0.color : nil } ?? Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            accessory
                .controlSize(.small)
        }
        .padding(.horizontal, ListRow.inset)
        .padding(.vertical, Theme.Space.xs)
        .frame(minHeight: ListRow.singleLineHeight)
        .accessibilityElement(children: .combine)
    }
}

extension StatusLineRow where Accessory == EmptyView {
    init(label: String, line: StatusPage.Line) {
        self.init(label: label, line: line, accessory: { EmptyView() })
    }
}

/// A row that is one sentence, such as "No VPN tunnels are up."
struct StatusPlainRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: ListRow.singleLineHeight, alignment: .leading)
            .padding(.horizontal, ListRow.inset)
    }
}

/// A small line under a row: why the helper is not ready, a stale pin.
struct StatusNote: View {
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(Theme.Font.detail)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ListRow.inset)
            .padding(.bottom, Theme.Space.s)
    }
}

/// The hairline between two label rows, which have no glyph column: from the row inset.
struct StatusDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.horizontal, ListRow.inset)
            .accessibilityHidden(true)
    }
}
