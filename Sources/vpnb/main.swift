// main.swift
// vpnb — the command-line client for VPN Bypass's scripting/control surface
// (multi-route P1, see docs/MULTI-ROUTE-DESIGN.md, "Scripting / automation
// surface"). Deliberately thin: parse argv into a ControlRequest, send it as
// one newline-delimited JSON line over the app's UNIX control socket, print
// the one-line JSON response back, and exit. All validation and mutation
// logic lives server-side in CommandRouter — this file never duplicates it.

import Foundation
import VPNBypassCore
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Usage

func printUsage() {
    let usage = """
    vpnb — VPN Bypass control CLI

    Usage:
      vpnb <cmd> [key=value ...] [pass:-]

    Commands:
      status                                    Mode, routes, and schema/version info
      route.list                                List all routes
      route.set id=<uuid> [name=] [host=] [port=] [user=] [enabled=true|false] [pass:-]
                                                 Re-point a route's host/port/user/enabled/password
      route.enable id=<uuid>                    Enable a route
      route.disable id=<uuid>                   Disable a route
      route.add name=<name> [type=http|socks5|tailscale] [host=] [port=] [user=] [pass:-]
                                                 Add a new route
      route.rm id=<uuid>                        Remove a route
      rule.list                                 List all rules
      rule.add match=<domain|suffix|ip|cidr|service|process> pattern=<value> routeId=<uuid>
                                                 Add a routing rule
      rule.rm id=<uuid>                         Remove a rule
      mode mode=<bypass|vpnOnly|custom>          Set the routing mode (custom carries
                                                 your listed domains into rules)
      default routeId=<uuid>                    Set the default route
      help | --help | -h                        Show this help

    Secrets:
      Never pass a password as key=value — argv is world-visible via `ps` and
      shell history. Instead pass the bare token "pass:-" (or the flag
      --pass-stdin) and pipe/type the password on stdin:

        read -rs PASS && printf '%s' "$PASS" | vpnb route.set id=<uuid> port=24001 pass:-

      The stdin line is read once and sent as secrets.pass — it never appears
      in args, in a process listing, or in any log.

    Environment:
      VPNB_SOCKET   Override the control socket path (default:
                    ~/Library/Application Support/VPNBypass/control.sock).

    Exit codes:
      0  ok
      1  the app returned an error (see the printed "error: <code>: <message>")
      2  couldn't reach VPN Bypass's control socket (app not running, or no reply)
    """
    print(usage)
}

// MARK: - Argument parsing

struct ParsedArgs {
    var cmd: String
    var args: [String: String]
    var readPassFromStdin: Bool
}

func parseArguments(_ rawArgs: [String]) -> ParsedArgs {
    let cmd = rawArgs[0]
    var args: [String: String] = [:]
    var readPassFromStdin = false

    for token in rawArgs.dropFirst() {
        if token == "pass:-" || token == "--pass-stdin" {
            readPassFromStdin = true
            continue
        }
        guard let eqIndex = token.firstIndex(of: "=") else {
            FileHandle.standardError.write(Data("vpnb: ignoring malformed argument (expected key=value): \(token)\n".utf8))
            continue
        }
        let key = String(token[token.startIndex..<eqIndex])
        let value = String(token[token.index(after: eqIndex)...])
        args[key] = value
    }

    return ParsedArgs(cmd: cmd, args: args, readPassFromStdin: readPassFromStdin)
}

// MARK: - Socket I/O

/// Connects to the control socket. Returns nil on ANY failure (bad path,
/// ENOENT because the app isn't running, ECONNREFUSED because a stale socket
/// file has nothing listening, etc.) — the caller prints one clear message
/// regardless of the specific cause.
func connectToSocket(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < maxLen else {
        close(fd)
        return nil
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let buf = raw.bindMemory(to: UInt8.self)
        buf.initialize(repeating: 0)
        for (i, byte) in bytes.enumerated() {
            buf[i] = byte
        }
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) { rawAddr in
        rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, addrLen)
        }
    }
    guard rc == 0 else {
        close(fd)
        return nil
    }

    // Darwin has no MSG_NOSIGNAL; without SO_NOSIGPIPE, the server closing
    // mid-write would deliver SIGPIPE to this process and kill the CLI
    // instead of returning EPIPE from write().
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    return fd
}

func writeAll(fd: Int32, data: Data) -> Bool {
    var remaining = data
    while !remaining.isEmpty {
        let n = remaining.withUnsafeBytes { raw -> Int in
            write(fd, raw.baseAddress, remaining.count)
        }
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        if n == 0 { return false }
        remaining.removeFirst(n)
    }
    return true
}

/// Sends one request line and reads back exactly one response line.
func sendRequestAndReadResponse(fd: Int32, request: ControlRequest) -> ControlResponse? {
    guard var payload = try? JSONEncoder().encode(request) else { return nil }
    payload.append(0x0A)
    guard writeAll(fd: fd, data: payload) else { return nil }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            return try? JSONDecoder().decode(ControlResponse.self, from: lineData)
        }
        let n = chunk.withUnsafeMutableBytes { raw -> Int in
            read(fd, raw.baseAddress, raw.count)
        }
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if n == 0 {
            return nil  // EOF before a full response line arrived.
        }
        buffer.append(contentsOf: chunk[0..<n])
    }
}

// MARK: - Output

func printResult(_ response: ControlResponse) {
    if let error = response.error {
        print("error: \(error.code): \(error.message)")
        return
    }
    guard let result = response.result else {
        print("ok")
        return
    }

    if let routes = result.routes {
        if routes.isEmpty {
            print("no routes")
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
                print(line)
            }
        }
    }

    if let rules = result.rules {
        if rules.isEmpty {
            print("no rules")
        } else {
            for rule in rules.sorted(by: { $0.order < $1.order }) {
                let state = rule.enabled ? "enabled" : "disabled"
                print("\(rule.order)  \(rule.id)  \(rule.matchType.rawValue):\(rule.pattern) -> \(rule.routeId)  \(state)")
            }
        }
    }

    if let mode = result.mode { print("mode: \(mode)") }
    if let defaultRouteId = result.defaultRouteId { print("default route: \(defaultRouteId)") }
    if let schemaVersion = result.schemaVersion { print("schemaVersion: \(schemaVersion)") }
    if let supportedVersion = result.supportedVersion { print("supportedVersion: \(supportedVersion)") }
    if let listenerPort = result.listenerPort { print("listenerPort: \(listenerPort)") }
    if let message = result.message { print(message) }
}

// MARK: - Entry point

let rawArgs = Array(CommandLine.arguments.dropFirst())

if rawArgs.isEmpty {
    printUsage()
    exit(1)
}

if rawArgs[0] == "help" || rawArgs[0] == "--help" || rawArgs[0] == "-h" {
    printUsage()
    exit(0)
}

let parsed = parseArguments(rawArgs)

var secrets: [String: String] = [:]
if parsed.readPassFromStdin {
    guard let line = readLine(strippingNewline: true) else {
        FileHandle.standardError.write(Data("vpnb: pass:- (or --pass-stdin) given but no input on stdin\n".utf8))
        exit(2)
    }
    secrets["pass"] = line
}

let request = ControlRequest(
    cmd: parsed.cmd,
    args: parsed.args.isEmpty ? nil : parsed.args,
    secrets: secrets.isEmpty ? nil : secrets
)

// VPNB_SOCKET overrides the default socket path (for tests, or a non-standard
// install). Falls back to the app's standard user-only socket otherwise.
let socketPath = ProcessInfo.processInfo.environment["VPNB_SOCKET"] ?? ControlSocketServer.defaultSocketPath()
guard let fd = connectToSocket(path: socketPath) else {
    FileHandle.standardError.write(Data("VPN Bypass isn't running, or its control socket is unavailable. Start the app and try again.\n".utf8))
    exit(2)
}
defer { close(fd) }

guard let response = sendRequestAndReadResponse(fd: fd, request: request) else {
    FileHandle.standardError.write(Data("vpnb: no response from VPN Bypass (connection closed or malformed reply)\n".utf8))
    exit(2)
}

printResult(response)
exit(response.ok ? 0 : 1)
