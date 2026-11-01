// VPNBCLI.swift
// The parts of the `vpnb` command-line client that decide what it sends and what it prints:
// argv parsing, the text rendering, the `--json` rendering and opening the socket. They live
// here, not in the `vpnb` executable target, so the test target can reach them. The executable
// keeps the request and reply I/O and the exit codes.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
            // `vpnb why <host>`: the one verb whose argument may come bare.
            // A pasted link counts as bare even when its query holds "=".
            let isLink = token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://")
            if parsed.cmd == "why", isLink || !token.contains("="), parsed.args["host"] == nil, !token.hasPrefix("-") {
                parsed.args["host"] = token
                continue
            }
            // `vpnb pause 15m`: the length may come bare too.
            if parsed.cmd == "pause", !token.contains("="), parsed.args["for"] == nil, !token.hasPrefix("-") {
                parsed.args["for"] = token
                continue
            }
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

    /// `why`: the app's sentence, then one line per checked address and one for the control.
    static func whyLines(_ why: SiteRouteAnswer) -> [String] {
        var out = [why.summary]
        func line(_ check: SiteRouteCheck, label: String) -> String {
            var text = "  \(label)\(check.address)  via \(check.interface ?? "?")"
            if let source = check.sourceAddress { text += " from \(source)" }
            if check.answer != .notTried { text += "  443: \(check.answer.rawValue)" }
            if let ms = check.latencyMs { text += " in \(Int(ms.rounded())) ms" }
            if let verdict = check.verdict { text += "  \(verdict.rawValue)" }
            return text
        }
        for check in why.checks { out.append(line(check, label: "")) }
        if let control = why.control { out.append(line(control, label: "control ")) }
        var facts = "  match: \(why.match.rawValue)"
        if let entry = why.entry { facts += "  entry: \(entry)" }
        if let expected = why.expected { facts += "  expected: \(expected)" }
        facts += "  verdict: \(why.verdict.rawValue)"
        out.append(facts)
        return out
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
            if let paused = runtime.paused { line += "  paused: \(paused)" }
            out.append(line)
        }

        if let why = result.why { out += whyLines(why) }

        if let mode = result.mode { out.append("mode: \(mode)") }
        if let defaultRouteId = result.defaultRouteId { out.append("default route: \(defaultRouteId)") }
        if let schemaVersion = result.schemaVersion { out.append("schemaVersion: \(schemaVersion)") }
        if let supportedVersion = result.supportedVersion { out.append("supportedVersion: \(supportedVersion)") }
        if let listenerPort = result.listenerPort { out.append("listenerPort: \(listenerPort)") }
        if let message = result.message { out.append(message) }
        return out
    }

    // MARK: - The socket

    /// A UNIX stream socket that returns EPIPE instead of raising SIGPIPE when the app closes
    /// its end. SO_NOSIGPIPE is set here, before the connect: the kernel refuses it (EINVAL) on
    /// a socket whose peer has already closed, so set after the connect it was lost whenever
    /// the app closed first, and the write that followed killed vpnb with SIGPIPE (exit 13
    /// instead of 2 with "no response", seen once on CI).
    public static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Connects to the control socket. Returns nil on ANY failure (bad path, ENOENT because
    /// the app isn't running, ECONNREFUSED because a stale socket file has nothing listening,
    /// etc.); the caller prints one clear message whatever the cause.
    public static func connect(path: String) -> Int32? {
        guard let fd = makeSocket() else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            buf.initialize(repeating: 0)
            for (i, byte) in bytes.enumerated() { buf[i] = byte }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { rawAddr in
            rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
