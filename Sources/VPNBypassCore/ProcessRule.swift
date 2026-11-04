// ProcessRule.swift
// What a `process` rule may name, and which engine serves each rule.
//
// A process rule matches an app, not a destination. The kernel engine (routes, /etc/hosts, the
// wildcard forwarder) decides by destination only, so it can never serve one: RuleResolver,
// RuleDestinationBuilder and WildcardRoutes skip process rules by design. Per-app routing, the
// opt-in Network Extension engine (docs/design/NETWORK-EXTENSION-DESIGN.md), serves those with
// the Direct route while it is active. In every other state every surface says why the rule does
// nothing (the Rules page, `vpnb rule.list`, `rule.add`, `why`) instead of staying silent.

import Foundation

/// Which engine serves a rule. `public`: carried in `SanitizedRule`, which `vpnb` decodes.
public enum RuleServedBy: String, Codable, Equatable, Sendable {
    /// The routing table, /etc/hosts and the wildcard forwarder: every destination rule.
    case kernel
    /// Per-app routing (the Network Extension engine): process rules, while it is active.
    case perAppEngine
    /// Nothing serves the rule; `SanitizedRule.inactiveReason` says why.
    case none
}

enum ProcessRule {
    /// Why nothing serves a rule, as the wire code `SanitizedRule.inactiveReason` carries. A
    /// string on the wire, so a later reason still decodes in an older `vpnb`.
    enum InactiveReason: String {
        /// This Mac or this build cannot run per-app routing (macOS 14 or older, a dev build).
        case perAppRoutingNotAvailable
        /// The Per-app routing switch is off.
        case perAppRoutingOff
        /// macOS is waiting for the user to allow the extension or its configuration.
        case perAppRoutingWaitingForApproval
        /// The Mac's administrator forbids it, or the app is not in /Applications.
        case perAppRoutingBlocked
        case perAppRoutingStarting
        /// Pause, a VPN kill switch, or VPN Only mode.
        case perAppRoutingPaused
        /// The extension's update waits for approval and it does not read this app's policy.
        case perAppRoutingUpdateWaiting
        /// It stopped or would not start.
        case perAppRoutingFailed
        /// The rule's route is not Direct: this version carries listed apps around the VPN only.
        case routeNotSupported
        /// The rule's route was deleted or is turned off, so the rule matches nothing.
        case routeUnavailable
    }

    /// The engine that serves `rule`, and why none does. A process rule with the Direct route is
    /// served while per-app routing is active; with another route, or a route deleted or turned
    /// off, it is not served in this version, whatever the engine does (FlowPolicyCompiler drops
    /// it). Every other kind is a destination the kernel engine routes. `engine` defaults to the
    /// state of a build without per-app routing, the answer the pure `CommandRouter` gives; the
    /// control surface fills in the live one. A rule turned off is not served and has no reason:
    /// its own switch says why.
    static func serving(_ rule: Rule, engine: FlowEngineState = .unavailable(.notInThisBuild),
                        routeIsDirect: Bool = true, routeUsable: Bool = true) -> (servedBy: RuleServedBy, reason: InactiveReason?) {
        guard rule.matchType == .process else { return (.kernel, nil) }
        if case .unavailable = engine { return (.none, .perAppRoutingNotAvailable) }
        guard routeUsable else { return (.none, .routeUnavailable) }
        guard routeIsDirect else { return (.none, .routeNotSupported) }
        if let reason = engine.ruleReason { return (.none, reason) }
        guard rule.enabled else { return (.none, nil) }
        return (.perAppEngine, nil)
    }

    /// `serving` for the rule's route (nil: deleted).
    static func serving(_ rule: Rule, engine: FlowEngineState, route: Route?) -> (servedBy: RuleServedBy, reason: InactiveReason?) {
        serving(rule, engine: engine, routeIsDirect: route?.egress == .direct, routeUsable: route?.enabled ?? false)
    }

    /// `serving` with the rule's route looked up in `routes`.
    static func serving(_ rule: Rule, engine: FlowEngineState, routes: [Route]) -> (servedBy: RuleServedBy, reason: InactiveReason?) {
        serving(rule, engine: engine, route: routes.first { $0.id == rule.routeId })
    }

    /// The Rules page's line under a process rule, by why nothing serves it (nil: it is served).
    static func rowNote(_ reason: InactiveReason?, claimed: Int = 0, bound: Int = 0, in bundle: Bundle = .main) -> String {
        guard let reason else {
            var line = String(localized: "Served by per-app routing: \(claimed) connections went around the VPN.", bundle: bundle)
            if bound > 0 {
                line += " " + String(localized: "\(bound) came bound to a network interface, which per-app routing cannot serve.", bundle: bundle)
            }
            return line
        }
        switch reason {
        case .perAppRoutingNotAvailable:
            return String(localized: "Needs per-app routing, which is not available yet, so this rule does nothing.", bundle: bundle)
        case .perAppRoutingOff:
            return String(localized: "Inactive: per-app routing is off (Settings > General).", bundle: bundle)
        case .perAppRoutingWaitingForApproval:
            return String(localized: "Inactive: per-app routing is waiting for your approval in System Settings.", bundle: bundle)
        case .perAppRoutingBlocked:
            return String(localized: "Inactive: per-app routing is blocked on this Mac (Settings > General says why).", bundle: bundle)
        case .perAppRoutingStarting:
            return String(localized: "Inactive while per-app routing starts.", bundle: bundle)
        case .perAppRoutingPaused:
            return String(localized: "Paused: this app uses the VPN until per-app routing resumes.", bundle: bundle)
        case .perAppRoutingUpdateWaiting:
            return String(localized: "Inactive: an update of per-app routing is waiting for approval in System Settings.", bundle: bundle)
        case .perAppRoutingFailed:
            return String(localized: "Inactive: per-app routing stopped, so this app uses the VPN (Settings > General says why).", bundle: bundle)
        case .routeNotSupported:
            return String(localized: "Inactive: per-app routing sends apps Direct only in this version; pick the Direct route.", bundle: bundle)
        case .routeUnavailable:
            return String(localized: "Inactive: this rule's route was deleted or is turned off.", bundle: bundle)
        }
    }

    /// What `rule.add match=process` replies after saving the rule.
    static let savedMessage = "process rule saved; it routes the app's connections only while per-app routing is on and its route is Direct"

    /// `vpnb rule.list`'s note for a rule nothing serves, by its wire reason.
    static func inactiveNote(reason: String?) -> String {
        switch reason.flatMap(InactiveReason.init(rawValue:)) {
        case .perAppRoutingNotAvailable: return "inactive: needs per-app routing, which is not available yet"
        case .perAppRoutingOff: return "inactive: per-app routing is off"
        case .perAppRoutingWaitingForApproval: return "inactive: per-app routing is waiting for approval"
        case .perAppRoutingBlocked: return "inactive: per-app routing is blocked"
        case .perAppRoutingStarting: return "inactive: per-app routing is starting"
        case .perAppRoutingPaused: return "paused: per-app routing stands down"
        case .perAppRoutingUpdateWaiting: return "inactive: per-app routing update waiting for approval"
        case .perAppRoutingFailed: return "inactive: per-app routing stopped"
        case .routeNotSupported: return "inactive: per-app routing serves the Direct route only"
        case .routeUnavailable: return "inactive: its route was deleted or is turned off"
        case nil: return "inactive" + (reason.map { ": \($0)" } ?? "")
        }
    }

    // MARK: - The pattern

    /// The two shapes a process pattern takes (design doc 3.4): with a dot, a bundle id, matched
    /// exactly or on a dot boundary (`com.example.App` covers `com.example.App.helper`); without
    /// one, an executable's file name, compared with the last part of the process's path.
    enum Kind: Equatable {
        case bundleID
        case executableName
    }

    /// Why a pattern cannot be a process rule.
    enum Invalid: Equatable {
        case empty
        case path
        case wildcard
        case appFolder
        case badBundleID
        case badCharacter
        case tooLong
    }

    /// A file name's limit on macOS, in bytes.
    static let maxLength = 255

    static func kind(of pattern: String) -> Kind {
        pattern.contains(".") ? .bundleID : .executableName
    }

    /// Nil when `pattern` is a bundle id or an executable name as the design defines them.
    static func invalid(_ pattern: String) -> Invalid? {
        guard !pattern.isEmpty else { return .empty }
        guard pattern.utf8.count <= maxLength else { return .tooLong }
        if pattern.contains("/") { return .path }
        if pattern.contains(where: { "*?[]".contains($0) }) { return .wildcard }
        // Spaces inside an executable's name are real ("Example Helper"); around it they are a typo.
        guard pattern.trimmingCharacters(in: .whitespacesAndNewlines) == pattern,
              !pattern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .badCharacter
        }
        guard kind(of: pattern) == .bundleID else { return nil }
        // "Example.app" is the app's folder, not its id; a bundle id may end in "app" too
        // (com.example.App), so only a name with that one dot is taken for the folder.
        if pattern.lowercased().hasSuffix(".app"), pattern.filter({ $0 == "." }).count == 1 { return .appFolder }
        // A bundle id: dot-separated parts of letters, digits, hyphens and underscores.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let parts = pattern.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return .badBundleID
        }
        return nil
    }

    /// The English message `vpnb rule.add` returns for an invalid pattern.
    static func message(_ invalid: Invalid) -> String {
        let shape = "use an app's bundle id (com.example.App) or its executable name (Example)"
        switch invalid {
        case .empty: return "pattern is required"
        case .path: return "a process pattern is not a path; \(shape)"
        case .wildcard: return "a process pattern takes no wildcard; \(shape)"
        case .appFolder: return "name the app's bundle id, not its .app folder; \(shape)"
        case .badBundleID: return "a bundle id is dot-separated letters, digits, hyphens and underscores; \(shape)"
        case .badCharacter: return "a process pattern has no control characters and no spaces around it; \(shape)"
        case .tooLong: return "a process pattern is at most \(maxLength) bytes"
        }
    }

    /// The rule sheet's message for an invalid pattern, one sentence whatever the reason.
    static func localizedMessage(in bundle: Bundle = .main) -> String {
        String(localized: "Enter an app's bundle ID (com.example.App) or its executable name (Example), with no path or wildcard.", bundle: bundle)
    }
}
