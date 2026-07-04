// CommandRouter.swift
// The pure core of the forthcoming scripting/control surface (multi-route P1 —
// see docs/MULTI-ROUTE-DESIGN.md, "route-on <name> shell hook"). Maps a decoded
// ControlRequest -> a mutation on RouteManager.Config, returning a sanitized
// ControlResponse.
//
// PURE by construction: no @MainActor, no RouteManager, no sockets, no I/O, no
// Date()/Task. It operates on a Config value in and returns a Config value out
// plus a response. `apply` never throws — every failure becomes response.error.
// A socket server (built later) will decode wire JSON into a ControlRequest,
// call `apply` on the main actor, then persist the returned config and
// reconcile routes/listeners exactly like any other config mutation.
//
// Envelope decoding mirrors Route/Rule's decode-resilient `decodeIfPresent`
// style so a partial or newer-client payload degrades gracefully instead of
// throwing.

import Foundation

// MARK: - Wire envelope

/// A single control command from the (future) scripting surface.
///
/// `public`: this is the wire DTO the standalone `vpnb` CLI target encodes to
/// send over the control socket, so it must be visible outside this module.
/// `Sendable` because it crosses the `ControlSocketServer.Handler`'s
/// `@Sendable` closure boundary between the accept-loop thread and the
/// (possibly @MainActor) handler.
public struct ControlRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var cmd: String                 // e.g. "route.set"
    public var args: [String: String]?     // string args (id, name, host, port, user, pattern, routeId, mode, enabled, type, match)
    public var secrets: [String: String]?  // e.g. ["pass": "..."] — NEVER copied into any response or log

    public init(v: Int = 1, cmd: String, args: [String: String]? = nil, secrets: [String: String]? = nil) {
        self.v = v
        self.cmd = cmd
        self.args = args
        self.secrets = secrets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        // No default that would masquerade as a real verb: an absent/malformed
        // cmd decodes to "" and falls through to unknown_command in apply(),
        // rather than throwing and killing the whole decode.
        cmd = try c.decodeIfPresent(String.self, forKey: .cmd) ?? ""
        args = try c.decodeIfPresent([String: String].self, forKey: .args)
        secrets = try c.decodeIfPresent([String: String].self, forKey: .secrets)
    }
}

/// The result of applying a ControlRequest. Never carries a credential.
/// `public`/`Sendable` for the same reason as `ControlRequest` — `vpnb`
/// decodes this cross-module after reading a response line from the socket.
public struct ControlResponse: Codable, Equatable, Sendable {
    public var v: Int
    public var ok: Bool
    public var result: ControlResult?
    public var error: ControlError?

    public init(v: Int = 1, ok: Bool, result: ControlResult? = nil, error: ControlError? = nil) {
        self.v = v
        self.ok = ok
        self.result = result
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        result = try c.decodeIfPresent(ControlResult.self, forKey: .result)
        error = try c.decodeIfPresent(ControlError.self, forKey: .error)
    }
}

public struct ControlError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
}

/// The sanitized payload a verb returns. All fields optional — each verb
/// populates only what's relevant to it.
public struct ControlResult: Codable, Equatable, Sendable {
    public var routes: [SanitizedRoute]? = nil
    public var rules: [SanitizedRule]? = nil
    public var mode: String? = nil
    public var defaultRouteId: UUID? = nil
    public var schemaVersion: Int? = nil
    public var supportedVersion: Int? = nil
    public var listenerPort: UInt16? = nil
    public var message: String? = nil
}

/// Mirrors `Route` but never carries a credential value — the same discipline
/// `RouteManager.Config.sanitizedForExport()` applies to exports applies here,
/// since control responses can be logged, piped, or displayed. `hasProxyUser`/
/// `hasPassword` let a script tell "configured" from "not configured" without
/// ever seeing the secret itself.
public struct SanitizedRoute: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var egress: Egress
    public var enabled: Bool
    public var proxyHost: String?
    public var proxyPort: Int?
    public var hasProxyUser: Bool
    public var hasPassword: Bool
    public var tailscaleExitNode: String?
    public var localListenPort: Int?
    /// The route's LIVE loopback listener port, if a forwarder is currently
    /// running for it (nil for non-proxy routes or ones not yet started).
    public var listenerPort: UInt16?

    init(_ route: Route, listenerPort: UInt16?) {
        id = route.id
        name = route.name
        egress = route.egress
        enabled = route.enabled
        proxyHost = route.proxyHost
        proxyPort = route.proxyPort
        hasProxyUser = !(route.proxyUser ?? "").isEmpty
        hasPassword = !(route.proxyPass ?? "").isEmpty
        tailscaleExitNode = route.tailscaleExitNode
        localListenPort = route.localListenPort
        self.listenerPort = listenerPort
    }
}

public struct SanitizedRule: Codable, Equatable, Sendable {
    public var id: UUID
    public var matchType: MatchType
    public var pattern: String
    public var routeId: UUID
    public var enabled: Bool
    public var order: Int

    init(_ rule: Rule) {
        id = rule.id
        matchType = rule.matchType
        pattern = rule.pattern
        routeId = rule.routeId
        enabled = rule.enabled
        order = rule.order
    }
}

// MARK: - Router

enum CommandRouter {

    /// Apply a command to a config. `listenerPorts` lets read verbs (status/route.list)
    /// and single-route mutations report the live loopback port per route id (the
    /// socket layer passes ProxyListenerManager.shared.activePorts; tests pass [:]).
    /// Returns the (possibly mutated) config + a response. Never throws; failures
    /// become response.error and the config is returned UNCHANGED.
    static func apply(
        _ request: ControlRequest,
        to config: RouteManager.Config,
        listenerPorts: [UUID: UInt16] = [:]
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard request.v == 1 else {
            return errorResponse(config, code: "unsupported_version",
                                  message: "unsupported envelope version \(request.v); only v=1 is supported")
        }

        switch request.cmd {
        case "status":
            return status(config, listenerPorts: listenerPorts)
        case "route.list":
            return routeList(config, listenerPorts: listenerPorts)
        case "route.set":
            return routeSet(request, config, listenerPorts: listenerPorts)
        case "route.enable":
            return routeSetEnabled(request, config, enabled: true, listenerPorts: listenerPorts)
        case "route.disable":
            return routeSetEnabled(request, config, enabled: false, listenerPorts: listenerPorts)
        case "route.rm":
            return routeRemove(request, config)
        case "route.add":
            return routeAdd(request, config, listenerPorts: listenerPorts)
        case "rule.list":
            return ruleList(config)
        case "rule.add":
            return ruleAdd(request, config)
        case "rule.rm":
            return ruleRemove(request, config)
        case "mode":
            return setMode(request, config)
        case "default":
            return setDefault(request, config)
        default:
            return errorResponse(config, code: "unknown_command", message: "unknown command: \(request.cmd)")
        }
    }

    /// Whether a verb can change the config (so the socket handler knows when to
    /// persist + reconcile). Read verbs return the config untouched; everything else
    /// may mutate it (an errored mutation still returns it unchanged, so callers gate
    /// on `response.ok` too).
    static func isMutating(_ cmd: String) -> Bool {
        switch cmd {
        case "status", "route.list", "rule.list": return false
        default: return true
        }
    }

    // MARK: - Read verbs (config always returned unchanged)

    private static func status(
        _ config: RouteManager.Config, listenerPorts: [UUID: UInt16]
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        let result = ControlResult(
            routes: config.routes.map { SanitizedRoute($0, listenerPort: listenerPorts[$0.id]) },
            mode: config.routingMode.rawValue,
            defaultRouteId: config.defaultRouteId,
            schemaVersion: config.schemaVersion,
            supportedVersion: 1
        )
        return successResponse(config, result: result)
    }

    private static func routeList(
        _ config: RouteManager.Config, listenerPorts: [UUID: UInt16]
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        let routes = config.routes.map { SanitizedRoute($0, listenerPort: listenerPorts[$0.id]) }
        return successResponse(config, result: ControlResult(routes: routes))
    }

    private static func ruleList(
        _ config: RouteManager.Config
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        let rules = config.rules.sorted { $0.order < $1.order }.map(SanitizedRule.init)
        return successResponse(config, result: ControlResult(rules: rules))
    }

    // MARK: - route.* mutations

    /// The canonical re-point verb: a script re-points a route's host/port/user/name/
    /// enabled/password (e.g. switching a residential proxy's port to change the exit IP).
    private static func routeSet(
        _ request: ControlRequest, _ config: RouteManager.Config, listenerPorts: [UUID: UInt16]
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard let id = uuid(request.args, "id"), let idx = config.routes.firstIndex(where: { $0.id == id }) else {
            return errorResponse(config, code: "not_found", message: "no route with that id")
        }

        // Validate everything before mutating anything.
        var validatedPort: Int?
        if let portStr = request.args?["port"] {
            guard let p = parsePort(portStr) else {
                return errorResponse(config, code: "invalid_port", message: "port must be an integer 1...65535")
            }
            validatedPort = p
        }
        var validatedEnabled: Bool?
        if let enabledStr = request.args?["enabled"] {
            guard let e = parseBool(enabledStr) else {
                return errorResponse(config, code: "invalid_args", message: "enabled must be \"true\" or \"false\"")
            }
            validatedEnabled = e
        }

        var updated = config
        var route = updated.routes[idx]
        if let name = request.args?["name"] { route.name = name }
        if let host = request.args?["host"] { route.proxyHost = host }
        if let port = validatedPort { route.proxyPort = port }
        if let user = request.args?["user"] { route.proxyUser = user }
        if let enabled = validatedEnabled { route.enabled = enabled }
        if let pass = request.secrets?["pass"] { route.proxyPass = pass }
        updated.routes[idx] = route

        let sanitized = SanitizedRoute(route, listenerPort: listenerPorts[route.id])
        return successResponse(updated, result: ControlResult(routes: [sanitized], listenerPort: sanitized.listenerPort))
    }

    private static func routeSetEnabled(
        _ request: ControlRequest, _ config: RouteManager.Config, enabled: Bool, listenerPorts: [UUID: UInt16]
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard let id = uuid(request.args, "id"), let idx = config.routes.firstIndex(where: { $0.id == id }) else {
            return errorResponse(config, code: "not_found", message: "no route with that id")
        }
        var updated = config
        updated.routes[idx].enabled = enabled
        let sanitized = SanitizedRoute(updated.routes[idx], listenerPort: listenerPorts[id])
        return successResponse(updated, result: ControlResult(routes: [sanitized], listenerPort: sanitized.listenerPort))
    }

    /// Removes the route AND cascades to any rule referencing it (a rule pointing
    /// at a nonexistent route can never match under RuleResolver, so leaving it
    /// behind is just dead config) and clears defaultRouteId if it pointed here.
    private static func routeRemove(
        _ request: ControlRequest, _ config: RouteManager.Config
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard let id = uuid(request.args, "id"), config.routes.contains(where: { $0.id == id }) else {
            return errorResponse(config, code: "not_found", message: "no route with that id")
        }
        var updated = config
        updated.routes.removeAll { $0.id == id }
        updated.rules.removeAll { $0.routeId == id }
        if updated.defaultRouteId == id { updated.defaultRouteId = nil }
        return successResponse(updated, result: ControlResult(message: "route removed"))
    }

    private static func routeAdd(
        _ request: ControlRequest, _ config: RouteManager.Config, listenerPorts: [UUID: UInt16]
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard let name = request.args?["name"], !name.isEmpty else {
            return errorResponse(config, code: "invalid_args", message: "name is required")
        }
        var validatedPort: Int?
        if let portStr = request.args?["port"] {
            guard let p = parsePort(portStr) else {
                return errorResponse(config, code: "invalid_port", message: "port must be an integer 1...65535")
            }
            validatedPort = p
        }

        let route = Route(
            name: name,
            egress: parseEgressType(request.args?["type"]),
            proxyHost: request.args?["host"],
            proxyPort: validatedPort,
            proxyUser: request.args?["user"],
            proxyPass: request.secrets?["pass"]
        )
        var updated = config
        updated.routes.append(route)
        let sanitized = SanitizedRoute(route, listenerPort: listenerPorts[route.id])
        return successResponse(updated, result: ControlResult(routes: [sanitized], listenerPort: sanitized.listenerPort))
    }

    // MARK: - rule.* mutations

    private static func ruleAdd(
        _ request: ControlRequest, _ config: RouteManager.Config
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard let matchStr = request.args?["match"], let matchType = MatchType(rawValue: matchStr) else {
            return errorResponse(config, code: "invalid_args", message: "match must be a valid match type")
        }
        guard let pattern = request.args?["pattern"], !pattern.isEmpty else {
            return errorResponse(config, code: "invalid_args", message: "pattern is required")
        }
        // RuleResolver treats `.ip`/`.cidr` patterns as opaque strings at match
        // time — a typo like "10.0.0/8" (missing an octet) is otherwise accepted
        // here and then silently never matches anything.
        if matchType == .ip, !isValidIPv4(pattern) {
            return errorResponse(config, code: "invalid_args", message: "malformed IP/CIDR pattern")
        }
        if matchType == .cidr, !isValidCIDR(pattern) {
            return errorResponse(config, code: "invalid_args", message: "malformed IP/CIDR pattern")
        }
        guard let routeId = uuid(request.args, "routeId"), config.routes.contains(where: { $0.id == routeId }) else {
            return errorResponse(config, code: "not_found", message: "no route with that id")
        }
        let nextOrder = (config.rules.map(\.order).max() ?? -1) + 1
        let rule = Rule(matchType: matchType, pattern: pattern, routeId: routeId, order: nextOrder)
        var updated = config
        updated.rules.append(rule)
        return successResponse(updated, result: ControlResult(rules: [SanitizedRule(rule)]))
    }

    private static func ruleRemove(
        _ request: ControlRequest, _ config: RouteManager.Config
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard let id = uuid(request.args, "id"), config.rules.contains(where: { $0.id == id }) else {
            return errorResponse(config, code: "not_found", message: "no rule with that id")
        }
        var updated = config
        updated.rules.removeAll { $0.id == id }
        return successResponse(updated, result: ControlResult(message: "rule removed"))
    }

    // MARK: - mode / default

    private static func setMode(
        _ request: ControlRequest, _ config: RouteManager.Config
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        // All three modes are scriptable. Entering Custom runs the SAME pure migration
        // the GUI uses (Config.preparedForCustomMode) so a bypass/vpnOnly user's listed
        // domains are carried into rules first — otherwise a scripted switch to custom
        // would enter with zero rules and drop them. ControlSurface re-applies routes
        // after a `mode` command, so the new custom routes take effect immediately.
        guard let modeStr = request.args?["mode"], let mode = RouteManager.RoutingMode(rawValue: modeStr) else {
            return errorResponse(config, code: "invalid_args", message: "mode must be \"bypass\", \"vpnOnly\", or \"custom\"")
        }
        var updated = config
        if mode == .custom {
            updated = updated.preparedForCustomMode()   // reads the pre-switch mode for rule semantics
        }
        updated.routingMode = mode
        return successResponse(updated, result: ControlResult(mode: mode.rawValue))
    }

    private static func setDefault(
        _ request: ControlRequest, _ config: RouteManager.Config
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        guard let routeId = uuid(request.args, "routeId"), config.routes.contains(where: { $0.id == routeId }) else {
            return errorResponse(config, code: "not_found", message: "no route with that id")
        }
        var updated = config
        updated.defaultRouteId = routeId
        return successResponse(updated, result: ControlResult(defaultRouteId: routeId))
    }

    // MARK: - Helpers

    private static func successResponse(
        _ config: RouteManager.Config, result: ControlResult
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        (config, ControlResponse(ok: true, result: result))
    }

    private static func errorResponse(
        _ config: RouteManager.Config, code: String, message: String
    ) -> (config: RouteManager.Config, response: ControlResponse) {
        (config, ControlResponse(ok: false, error: ControlError(code: code, message: message)))
    }

    private static func uuid(_ args: [String: String]?, _ key: String) -> UUID? {
        guard let s = args?[key] else { return nil }
        return UUID(uuidString: s)
    }

    private static func parsePort(_ s: String) -> Int? {
        guard let n = Int(s), (1...65535).contains(n) else { return nil }
        return n
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Same dotted-quad shape RuleResolver.ipv4(_:inCIDR:) parses at match time
    /// (4 numeric octets 0...255). Kept as its own small parser rather than
    /// shared — RuleResolver's is `private` to that file — but deliberately
    /// no stricter (e.g. still tolerates a leading zero like "01") so a
    /// pattern accepted here is guaranteed to also be one RuleResolver can match.
    private static func isValidIPv4(_ s: String) -> Bool {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { UInt32($0).map { $0 <= 255 } ?? false }
    }

    private static func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits) else { return false }
        return isValidIPv4(String(parts[0]))
    }

    private static func parseEgressType(_ s: String?) -> Egress {
        switch s {
        case "socks5": return .proxySOCKS5
        case "tailscale": return .tailscaleExit
        default: return .proxyHTTP  // "http" and anything unrecognized
        }
    }
}
