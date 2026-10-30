// VPNBCLI.swift
// The parts of the `vpnb` command-line client that decide what it sends and what it prints:
// argv parsing, the text rendering, and the `--json` rendering. They live here, not in the
// `vpnb` executable target, so the test target can reach them. The executable keeps only the
// socket I/O and the exit codes.

import Foundation

public enum VPNBCLI {

    /// Prints every reply as one JSON object instead of text. Accepted anywhere in argv and
    /// never sent to the app.
    public static let jsonFlag = "--json"

    public struct ParsedArgs: Equatable {
        public var cmd: String
        public var args: [String: String]
        public var readPassFromStdin: Bool
        /// Tokens that were neither a flag nor key=value; the caller warns about each on stderr.
        public var malformed: [String]
    }

    /// Splits `--json` out of argv. The rest keeps its order, so the first token left is the verb.
    public static func stripJSONFlag(_ argv: [String]) -> (argv: [String], json: Bool) {
        let rest = argv.filter { $0 != jsonFlag }
        return (rest, rest.count != argv.count)
    }

    /// Parses argv (without `--json`) into a verb, its key=value args and the stdin flag.
    /// `argv` must not be empty: the first token is the verb.
    public static func parse(_ argv: [String]) -> ParsedArgs {
        var parsed = ParsedArgs(cmd: argv[0], args: [:], readPassFromStdin: false, malformed: [])
        for token in argv.dropFirst() {
            if token == "pass:-" || token == "--pass-stdin" {
                parsed.readPassFromStdin = true
                continue
            }
            guard let eqIndex = token.firstIndex(of: "=") else {
                parsed.malformed.append(token)
                continue
            }
            let key = String(token[token.startIndex..<eqIndex])
            parsed.args[key] = String(token[token.index(after: eqIndex)...])
        }
        return parsed
    }

    /// An error `vpnb` raises itself, before or instead of an answer from the app (exit code 2),
    /// in the same shape as the app's own errors so a `--json` reader parses one shape.
    public static func clientError(code: String, message: String) -> ControlResponse {
        ControlResponse(ok: false, error: ControlError(code: code, message: message))
    }

    /// The reply as one line of JSON with sorted keys. Absent fields are omitted, never null.
    /// It encodes the decoded `ControlResponse`, so only fields that type declares can appear,
    /// and none of them holds a credential (`SanitizedRoute` carries `hasPassword`, not the value).
    public static func renderJSON(_ response: ControlResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(response), let line = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":"encode_failed","message":"vpnb could not encode the reply as JSON"},"ok":false,"v":1}"#
        }
        return line
    }

    /// The reply as the text lines `vpnb` prints without `--json`.
    public static func textLines(_ response: ControlResponse) -> [String] {
        var out: [String] = []
        if let error = response.error {
            return ["error: \(error.code): \(error.message)"]
        }
        guard let result = response.result else {
            return ["ok"]
        }

        if let routes = result.routes {
            if routes.isEmpty {
                out.append("no routes")
            } else {
                for r in routes {
                    var line = "\(r.id)  \(r.name)  [\(r.egress.rawValue)]  \(r.enabled ? "enabled" : "disabled")"
                    if let host = r.proxyHost, let port = r.proxyPort {
                        line += "  \(host):\(port)"
                    }
                    if r.hasProxyUser { line += "  user:yes" }
                    if r.hasPassword { line += "  pass:yes" }
                    if let exitNode = r.tailscaleExitNode { line += "  tailscale:\(exitNode)" }
                    if let listenerPort = r.listenerPort { line += "  listening:127.0.0.1:\(listenerPort)" }
                    out.append(line)
                }
            }
        }

        if let rules = result.rules {
            if rules.isEmpty {
                out.append("no rules")
            } else {
                for rule in rules.sorted(by: { $0.order < $1.order }) {
                    let state = rule.enabled ? "enabled" : "disabled"
                    out.append("\(rule.order)  \(rule.id)  \(rule.matchType.rawValue):\(rule.pattern) -> \(rule.routeId)  \(state)")
                }
            }
        }

        if let domains = result.domains {
            if domains.isEmpty {
                out.append("no domains")
            } else {
                for d in domains {
                    var line = "\(d.id)  \(d.domain)  [\(d.list)]  \(d.enabled ? "enabled" : "disabled")"
                    if d.isCIDR { line += "  cidr" }
                    if d.isWildcard { line += "  wildcard" }
                    out.append(line)
                }
            }
        }

        if let services = result.services {
            if services.isEmpty {
                out.append("no services")
            } else {
                for s in services {
                    var line = "\(s.id)  \(s.name)  \(s.enabled ? "enabled" : "disabled")  domains:\(s.domainCount)  ipRanges:\(s.ipRangeCount)"
                    if s.isCustom { line += "  custom" }
                    out.append(line)
                    for d in s.domains ?? [] { out.append("  domain  \(d)") }
                    for r in s.ipRanges ?? [] { out.append("  ipRange  \(r)") }
                }
            }
        }

        if let activeRoutes = result.activeRoutes {
            if activeRoutes.isEmpty {
                out.append("no active routes")
            } else {
                for r in activeRoutes {
                    out.append("\(r.destination) -> \(r.gateway)  (\(r.source))")
                }
            }
        }

        if let logs = result.logs {
            if logs.isEmpty {
                out.append("no log lines")
            } else {
                for l in logs {
                    out.append("\(l.time)  \(l.level)  \(l.message)")
                }
            }
        }

        if let runtime = result.runtime {
            var line = "helper: \(runtime.helperState)  vpn: \(runtime.vpnConnected ? (runtime.vpnInterface ?? "connected") : "disconnected")"
            line += "  routes: \(runtime.enforcedRouteCount)  enforcing: \(runtime.enforcing)"
            if let version = runtime.appVersion { line += "  app: \(version)" }
            if let killSwitch = runtime.killSwitch { line += "  kill switch: \(killSwitch.joined(separator: ","))" }
            out.append(line)
        }

        if let mode = result.mode { out.append("mode: \(mode)") }
        if let defaultRouteId = result.defaultRouteId { out.append("default route: \(defaultRouteId)") }
        if let schemaVersion = result.schemaVersion { out.append("schemaVersion: \(schemaVersion)") }
        if let supportedVersion = result.supportedVersion { out.append("supportedVersion: \(supportedVersion)") }
        if let listenerPort = result.listenerPort { out.append("listenerPort: \(listenerPort)") }
        if let message = result.message { out.append(message) }
        return out
    }
}
