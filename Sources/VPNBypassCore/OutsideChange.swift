// OutsideChange.swift
// Changes made through the control socket, which `vpnb` and the MCP server use, shown in the
// app (proposal 15 of #119). The socket runs the same RouteManager methods as the app's own
// buttons, so without this the lists just changed and nothing said where from. Two pieces:
//   - ControlOrigin marks the code running for one socket request, so every log line it
//     writes, and every line written by work it started, is tagged.
//   - OutsideChange is the last settings change a socket request made, which the dropdown
//     footer names. Its wording is pure so it is unit-tested.

import Foundation

/// Whether the running code serves a request that came through the control socket.
enum ControlOrigin {
    /// True inside `ControlSurface.handle`. A task-local, so it follows the request through its
    /// awaits and into the tasks it starts (an apply that `refresh` kicks off), and never leaks
    /// into a button's code that runs on the main actor while the request is suspended.
    @TaskLocal static var isControlSocket = false
}

/// Where a log line came from.
enum LogSource: Equatable {
    /// The app itself: a button, a timer, a network change.
    case app
    /// A request on the control socket, or work one started.
    case controlSocket

    /// The tag the Logs page shows at the end of a socket line.
    var tag: String? { tag(in: .main) }

    func tag(in bundle: Bundle) -> String? {
        switch self {
        case .app: return nil
        case .controlSocket: return String(localized: "via the command line", bundle: bundle)
        }
    }

    /// The tag's tooltip, which names what "the command line" is.
    static var tagHelp: String { tagHelp(in: .main) }

    static func tagHelp(in bundle: Bundle) -> String {
        String(localized: "Came through the control socket, which vpnb and the MCP server use", bundle: bundle)
    }

    /// What the log file and Copy add after a socket line. English, like the rest of the file.
    var fileSuffix: String {
        switch self {
        case .app: return ""
        case .controlSocket: return " (via the command line)"
        }
    }
}

/// The last change to the settings made through the control socket.
struct OutsideChange: Equatable {
    enum Kind: Equatable {
        case addedDomain(String)
        case removedDomain(String)
        case turnedOn(String)
        case turnedOff(String)
        case switchedMode(RouteManager.RoutingMode)
        /// `routes.clear`. `routesLeft` is what the removal could not take out, counted as the
        /// screen counts (`routedAddressCount`); `everythingElseDirect` is VPN Only's catch-alls,
        /// which that count leaves out, still installed.
        case removedAllRoutes(routesLeft: Int, everythingElseDirect: Bool = false)
        /// `route.add`, `route.set`, `route.enable`, `route.disable`, `route.rm`, `default`.
        case changedRoutes
        /// `rule.add`, `rule.rm`.
        case changedRules
    }

    let kind: Kind
    let at: Date

    /// The change a successful mutating request made, or nil when it changed nothing: a verb
    /// that changes no setting, a setting already as asked (`mode` to the mode in use, enabling
    /// what is on), or `routes.clear` with no routes installed.
    static func make(cmd: String, result: ControlResult?,
                     before: RouteManager.Config, after: RouteManager.Config,
                     routesBefore: Int, routesLeft: Int, everythingElseDirect: Bool = false,
                     at: Date) -> OutsideChange? {
        guard let kind = kind(cmd: cmd, result: result, before: before, after: after,
                              routesLeft: routesLeft, everythingElseDirect: everythingElseDirect) else {
            return nil
        }
        if case .removedAllRoutes = kind {
            return routesBefore > 0 ? OutsideChange(kind: kind, at: at) : nil
        }
        return sameSettings(before, after) ? nil : OutsideChange(kind: kind, at: at)
    }

    /// Config is not Equatable; its sorted JSON is, and it holds every setting.
    static func sameSettings(_ a: RouteManager.Config, _ b: RouteManager.Config) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let x = try? encoder.encode(a), let y = try? encoder.encode(b) else { return false }
        return x == y
    }

    /// What a successful request changed, or nil when it changes no setting: the read
    /// verbs, and `refresh` and `dns.refresh`, which re-apply the settings there are.
    ///
    /// `before` and `after` are the config as the request found and left it. Argument values
    /// never reach the log, but a domain or service name is not a secret and the footer is not
    /// the log.
    static func kind(cmd: String, result: ControlResult?,
                     before: RouteManager.Config, after: RouteManager.Config, routesLeft: Int,
                     everythingElseDirect: Bool = false) -> Kind? {
        switch cmd {
        case "domain.add":
            return result?.domains?.first.map { .addedDomain($0.domain) }
        case "domain.enable":
            return result?.domains?.first.map { .turnedOn($0.domain) }
        case "domain.disable":
            return result?.domains?.first.map { .turnedOff($0.domain) }
        case "domain.rm":
            // The answer names no entry, so the removed one is the entry `before` has and
            // `after` no longer does.
            let left = Set((after.domains + after.inverseDomains).map(\.id))
            return (before.domains + before.inverseDomains).first { !left.contains($0.id) }.map { .removedDomain($0.domain) }
        case "service.enable":
            return result?.services?.first.map { .turnedOn($0.name) }
        case "service.disable":
            return result?.services?.first.map { .turnedOff($0.name) }
        case "mode":
            return .switchedMode(after.routingMode)
        case "routes.clear":
            return .removedAllRoutes(routesLeft: routesLeft, everythingElseDirect: everythingElseDirect)
        case "route.add", "route.set", "route.enable", "route.disable", "route.rm", "default":
            return .changedRoutes
        case "rule.add", "rule.rm":
            return .changedRules
        default:
            return nil
        }
    }

    /// Whether the footer still shows this change. A removal is a claim about what is
    /// installed, so it stops showing once the route count moves, the same rule as the result
    /// line under Refresh Routes (`DropdownCopy.shownRouteChange`).
    func isShown(currentRouteCount: Int, everythingElseDirect: Bool = false) -> Bool {
        if case .removedAllRoutes(let left, let direct) = kind {
            return left == currentRouteCount && direct == everythingElseDirect
        }
        return true
    }

    /// The footer line, and the name in it, which the footer sets brighter.
    func line(now: Date) -> (text: String, subject: String?) { line(now: now, in: .main) }

    func line(now: Date, in bundle: Bundle) -> (text: String, subject: String?) {
        let when = DropdownCopy.age(since: at, now: now, in: bundle)
        switch kind {
        case .addedDomain(let name):
            return (String(localized: "Last change: added \(name) via the command line, \(when)", bundle: bundle), name)
        case .removedDomain(let name):
            return (String(localized: "Last change: removed \(name) via the command line, \(when)", bundle: bundle), name)
        case .turnedOn(let name):
            return (String(localized: "Last change: turned on \(name) via the command line, \(when)", bundle: bundle), name)
        case .turnedOff(let name):
            return (String(localized: "Last change: turned off \(name) via the command line, \(when)", bundle: bundle), name)
        case .switchedMode(let mode):
            let name = DropdownModePicker.label(mode, in: bundle)
            return (String(localized: "Last change: switched to \(name) via the command line, \(when)", bundle: bundle), name)
        case .removedAllRoutes(0, false):
            return (String(localized: "Last change: removed all routed addresses via the command line, \(when)", bundle: bundle), nil)
        case .removedAllRoutes(0, true):
            // VPN Only's catch-alls could not be removed: something is still routed.
            return (String(localized: "Last change: removed routed addresses via the command line, \(when); everything else still goes direct", bundle: bundle), nil)
        case .removedAllRoutes(let left, _):
            // Some could not be removed; "all" would be false. The count is a label, so no plural.
            return (String(localized: "Last change: removed routed addresses via the command line, \(when); still routed: \(left)", bundle: bundle), nil)
        case .changedRoutes:
            return (String(localized: "Last change: changed the routes via the command line, \(when)", bundle: bundle), nil)
        case .changedRules:
            return (String(localized: "Last change: changed the rules via the command line, \(when)", bundle: bundle), nil)
        }
    }

    /// The footer line's tooltip: a click opens the log at what came through the socket.
    static var help: String { help(in: .main) }

    static func help(in bundle: Bundle) -> String {
        String(localized: "Show what came through the command line in Logs", bundle: bundle)
    }
}

extension RouteManager.LogEntry {
    /// The text the socket's `logs` verb returns. The verb's own line read "Control: '<verb>'
    /// applied via the command line" before the tag existed, and the reply keeps that text, so
    /// a script reading `logs` sees what it saw before.
    var socketReplyMessage: String {
        guard source == .controlSocket, message.hasPrefix("Control: '"), message.hasSuffix("' applied") else {
            return message
        }
        return message + " via the command line"
    }
}
