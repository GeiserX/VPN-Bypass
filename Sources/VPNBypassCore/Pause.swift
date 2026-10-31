// Pause.swift
// Pause (flow fix 2 and idea 4 of docs/design/APP-REWORK-PROPOSALS.md): take the app's routes
// out for a while, so traffic follows the VPN's own routes, then put them back.
//
// Removing routes is safe in one direction only, so whether Pause is offered depends on the
// mode (`PauseGate.blocker`). In Bypass the routes take listed traffic AROUND the VPN, and
// removing them sends it back through the VPN. In VPN Only they take listed traffic INTO the
// VPN, and removing them sends it out over the open connection: never offered. Custom is
// offered only when every enabled rule goes Direct, where it behaves as Bypass. A proxy route's
// loopback listener is not a route and keeps running, so while one runs the paused line would
// be false, and Pause is not offered.
//
// The state lives on RouteManager (`pause`), never on disk: quitting while paused removes the
// routes as every quit does, and the timer dies with the app. While paused nothing installs a
// route (the funnels refuse, see `RouteManager.addRoutesBatchTracked`), and Resume is one apply
// through the reconnect settle gate (`PauseGate.resumeAction`).

import Foundation

/// How long a pause lasts.
enum PauseLength: Equatable, Hashable {
    /// A timed pause; the app resumes on its own.
    case minutes(Int)
    /// Until the VPN drops and connects again.
    case untilReconnect
    /// Until Resume.
    case untilResume

    static let fifteenMinutes = PauseLength.minutes(15)
    static let oneHour = PauseLength.minutes(60)

    /// The Pause menu's items, in order.
    static let choices: [PauseLength] = [.fifteenMinutes, .oneHour, .untilReconnect, .untilResume]

    /// The longest timed pause `vpnb pause` takes: a day. Longer is "until I resume".
    static let maxMinutes = 24 * 60

    /// The menu item's title.
    func title(in bundle: Bundle = .main) -> String {
        switch self {
        case .minutes(15): return String(localized: "For 15 Minutes", bundle: bundle)
        case .minutes(60): return String(localized: "For 1 Hour", bundle: bundle)
        case .minutes(let m):
            return String(localized: "For \(DropdownStatus.countdown(TimeInterval(m * 60)))", bundle: bundle)
        case .untilReconnect: return String(localized: "Until the VPN Reconnects", bundle: bundle)
        case .untilResume: return String(localized: "Until I Resume", bundle: bundle)
        }
    }

    /// How `vpnb` and Shortcuts send it: "15m", "60m", "reconnect", "resume".
    var wireValue: String {
        switch self {
        case .minutes(let m): return "\(m)m"
        case .untilReconnect: return "reconnect"
        case .untilResume: return "resume"
        }
    }

    /// For the log: "for 15 min", "until the VPN reconnects", "until resumed".
    var logText: String {
        switch self {
        case .minutes(let m): return "for \(m) min"
        case .untilReconnect: return "until the VPN reconnects"
        case .untilResume: return "until resumed"
        }
    }

    /// Reads `vpnb pause`'s argument: "15m", "1h", "90m", "2h", "reconnect", "resume". Nothing
    /// at all means until resumed. A number with no unit is minutes. Nil for anything else, a
    /// zero length, or more than a day.
    static func parse(_ text: String?) -> PauseLength? {
        let t = (text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "", "resume", "untilresume", "until-resume", "indefinitely": return .untilResume
        case "reconnect", "untilreconnect", "until-reconnect": return .untilReconnect
        default: break
        }
        var digits = t
        var factor = 1
        if t.hasSuffix("min") {
            digits = String(t.dropLast(3))
        } else if t.hasSuffix("m") {
            digits = String(t.dropLast())
        } else if t.hasSuffix("h") {
            digits = String(t.dropLast())
            factor = 60
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let n = Int(digits), n > 0,
              n <= maxMinutes / factor else { return nil }
        return .minutes(n * factor)
    }
}

/// A pause in progress.
struct PauseState: Equatable {
    let length: PauseLength
    let since: Date
    /// The mode it was taken in. A switch to another mode ends it.
    let mode: RouteManager.RoutingMode

    /// When a timed pause ends on its own; nil for the other two.
    var until: Date? {
        guard case .minutes(let m) = length else { return nil }
        return since.addingTimeInterval(TimeInterval(m * 60))
    }

    /// For `vpnb status`: "until 2026-10-31T14:32:00Z", "until the VPN reconnects", "until resumed".
    var wireDescription: String {
        if let until {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return "until \(f.string(from: until))"
        }
        return length.logText
    }
}

enum PauseGate {

    /// Why Pause is not offered now.
    enum Blocker: Equatable {
        /// VPN Only: removing its routes sends listed sites outside the VPN.
        case vpnOnly
        /// A Custom rule that does not go Direct, by the name the dropdown shows for it.
        case rule(String, usesProxy: Bool)
        /// A proxy or Tailscale route whose loopback listener runs; Pause would not stop it.
        case listener(String)
    }

    /// Nil when Pause may run in this config. Checked in this order: the mode, then the first
    /// enabled Custom rule that does not go Direct, then a running proxy listener.
    static func blocker(_ config: RouteManager.Config) -> Blocker? {
        if config.routingMode == .vpnOnly { return .vpnOnly }
        let custom = RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode)
        if custom {
            for rule in config.rules.filter(\.enabled).sorted(by: { $0.order < $1.order }) {
                // A rule pointing at no route matches nothing (RuleResolver), so it routes nothing.
                // Nor one on a route turned off: RouteCompiler skips it.
                guard let route = config.routes.first(where: { $0.id == rule.routeId }),
                      route.enabled, route.egress != .direct else { continue }
                return .rule(ruleName(rule, services: config.services),
                             usesProxy: ProxyListenerManager.usesLocalListener(route.egress))
            }
        }
        // The same test as reconcileProxyListeners and ProxyListenerManager.reconcile: these
        // routes have a listener running for the apps set to use it, rule or no rule.
        if config.multiRouteEnabled || config.routingMode == .custom,
           let route = config.routes.first(where: {
               $0.enabled && ProxyListenerManager.usesLocalListener($0.egress) && !($0.proxyHost ?? "").isEmpty
           }) {
            return .listener(route.name)
        }
        return nil
    }

    /// A rule as the dropdown names it: a service rule by the service's name, any other by its pattern.
    static func ruleName(_ rule: Rule, services: [ServiceEntry]) -> String {
        if rule.matchType == .service, let service = services.first(where: { $0.id == rule.pattern }) {
            return service.name
        }
        return rule.pattern
    }

    /// The one line under the greyed Pause button, and what `vpnb pause` answers.
    static func message(_ blocker: Blocker, in bundle: Bundle = .main) -> String {
        switch blocker {
        case .vpnOnly:
            return String(localized: "Pausing VPN Only would send listed sites outside the VPN. Switch mode instead.", bundle: bundle)
        case .rule(let name, usesProxy: false):
            return String(localized: "The rule \(name) does not go Direct: pausing could send its traffic outside the VPN. Turn the rule off or switch mode instead.", bundle: bundle)
        case .rule(let name, usesProxy: true):
            return String(localized: "The rule \(name) uses a proxy, which keeps running while paused. Turn the rule off first.", bundle: bundle)
        case .listener(let name):
            return String(localized: "The route \(name) keeps its local listener running, so Pause would not stop it. Turn the route off first.", bundle: bundle)
        }
    }

    /// What Resume does. Resuming is one apply, the same write burst as Refresh, so it waits
    /// as the post-reconnect apply waits: never a burst into a tunnel that just came up or is
    /// marked by apply-kill strikes (`ReconnectSettle`).
    enum ResumeAction: Equatable {
        /// No VPN, or the helper is not ready: the next connect applies, as it always does.
        case nothing
        /// A settle-gated apply is already scheduled; it runs as planned.
        case waitForSettle
        /// Apply after this many seconds; 0 is now.
        case apply(after: TimeInterval, heldBackStrikes: Int?)
    }

    static func resumeAction(vpnConnected: Bool, canApply: Bool, settlePending: Bool,
                             killStrikes: Int, lastStrikeAt: Date?, lastConnectAt: Date?,
                             now: Date) -> ResumeAction {
        guard vpnConnected, canApply else { return .nothing }
        if settlePending { return .waitForSettle }
        let strikes = ReconnectSettle.effectiveStrikes(killStrikes, lastStrikeAt: lastStrikeAt, now: now)
        if let withheld = ReconnectSettle.withheldDelay(killStrikes: strikes, lastStrikeAt: lastStrikeAt, now: now) {
            return .apply(after: withheld, heldBackStrikes: strikes)
        }
        if strikes > 0 {
            return .apply(after: ReconnectSettle.delay(deferrals: 0, hasInstalledRoutes: false, killStrikes: strikes),
                          heldBackStrikes: nil)
        }
        // Paused, nothing is installed, so a tunnel that just came up gets the cold wait.
        if let connectAt = lastConnectAt {
            let since = now.timeIntervalSince(connectAt)
            if since >= 0 && since < ReconnectSettle.coldDelay {
                return .apply(after: ReconnectSettle.coldDelay - since, heldBackStrikes: nil)
            }
        }
        return .apply(after: 0, heldBackStrikes: nil)
    }
}

/// ⌘P in the dropdown. A menu answers its items' keys only while open, so the key sits on a
/// hidden button and does one thing: Resume while paused, else the menu's ⌘P item, an hour.
enum PauseShortcut {
    enum Action: Equatable {
        case resume
        case pause(PauseLength)
        /// Pause is greyed: the key does nothing, as a greyed item's key does nothing.
        case nothing
    }

    static func action(isPaused: Bool, blocker: PauseGate.Blocker?) -> Action {
        if isPaused { return .resume }
        return blocker == nil ? .pause(.oneHour) : .nothing
    }
}

/// Why `RouteManager.pause` did not pause.
enum PauseRefusal: Error, Equatable {
    case blocked(PauseGate.Blocker)
    case shuttingDown
    /// config.json could not be read: the app enforces nothing it would know how to restore.
    case configUnreadable
}
