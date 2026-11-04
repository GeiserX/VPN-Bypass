// ProcessRule.swift
// What a `process` rule may name, and which engine serves each rule.
//
// A process rule matches an app, not a destination. The kernel engine (routes, /etc/hosts, the
// wildcard forwarder) decides by destination only, so it can never serve one: RuleResolver,
// RuleDestinationBuilder and WildcardRoutes skip process rules by design. Per-app routing, the
// opt-in Network Extension engine (docs/design/NETWORK-EXTENSION-DESIGN.md), will serve them.
// Until it exists every surface says so (the Rules page, `vpnb rule.list`, `rule.add`, `why`)
// instead of keeping a rule that silently does nothing.

import Foundation

/// Which engine serves a rule. `public`: carried in `SanitizedRule`, which `vpnb` decodes.
public enum RuleServedBy: String, Codable, Equatable, Sendable {
    /// The routing table, /etc/hosts and the wildcard forwarder: every destination rule.
    case kernel
    /// Per-app routing (the Network Extension engine): process rules, once it runs.
    case perAppEngine
    /// Nothing serves the rule; `SanitizedRule.inactiveReason` says why.
    case none
}

enum ProcessRule {
    /// Why nothing serves a rule, as the wire code `SanitizedRule.inactiveReason` carries. A
    /// string on the wire, so a later reason (per-app routing off, waiting for approval) still
    /// decodes in an older `vpnb`.
    enum InactiveReason: String {
        /// This version has no per-app routing engine.
        case perAppRoutingNotAvailable
    }

    /// The engine that serves `rule`, and why none does. Process rules are served by nothing
    /// until per-app routing exists; every other kind is a destination the kernel engine routes.
    static func serving(_ rule: Rule) -> (servedBy: RuleServedBy, reason: InactiveReason?) {
        rule.matchType == .process ? (.none, .perAppRoutingNotAvailable) : (.kernel, nil)
    }

    /// The Rules page's line under a process rule.
    static func rowNote(in bundle: Bundle = .main) -> String {
        String(localized: "Needs per-app routing, which is not available yet, so this rule does nothing.", bundle: bundle)
    }

    /// What `rule.add match=process` replies after saving the rule.
    static let savedMessage = "process rule saved, but it will not route anything until per-app routing exists; this version does not have it yet"

    /// `vpnb rule.list`'s note for a rule nothing serves, by its wire reason.
    static func inactiveNote(reason: String?) -> String {
        switch reason.flatMap(InactiveReason.init(rawValue:)) {
        case .perAppRoutingNotAvailable: return "inactive: needs per-app routing, which is not available yet"
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
