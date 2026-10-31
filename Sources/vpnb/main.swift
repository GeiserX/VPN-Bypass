// main.swift
// vpnb — the command-line client for VPN Bypass's scripting/control surface
// (multi-route P1, see docs/MULTI-ROUTE-DESIGN.md, "Scripting / automation
// surface"). Deliberately thin: parse argv into a ControlRequest, send it as
// one newline-delimited JSON line over the app's UNIX control socket, decode
// the one-line JSON reply, print it as text (or, with --json, as one JSON
// object with sorted keys), and exit. Parsing and rendering live in
// VPNBypassCore's VPNBCLI so the tests reach them; all validation and mutation
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
      vpnb <cmd> [key=value ...] [pass:-] [--json]

    Commands:
      status                                    Mode, routes, live enforcement (helper/VPN/route facts)
      route.list                                List all routes
      route.set id=<uuid> [name=] [host=] [port=] [user=] [enabled=true|false] [pass:-]
                                                 Re-point a route's host/port/user/enabled/password
      route.enable id=<uuid>                    Enable a route
      route.disable id=<uuid>                   Disable a route
      route.add name=<name> [type=http|socks5|tailscale|vpn] [host=] [port=] [user=] [pass:-]
                                                [interface=utunX] [product=<label>]  (type=vpn: pin a tunnel)
                                                 Add a new route
      route.rm id=<uuid>                        Remove a route
      rule.list                                 List all rules
      rule.add match=<domain|suffix|ip|cidr|service|process> pattern=<value> routeId=<uuid>
                                                 Add a routing rule
      rule.rm id=<uuid>                         Remove a rule
      mode mode=<bypass|vpnOnly|custom>          Set the routing mode (custom carries
                                                 your listed domains into rules)
      default routeId=<uuid>                    Set the default route

    Bypass and VPN Only modes:
      domain.list [list=bypass|vpnOnly]         List the domain lists (both when list= is omitted)
      domain.add domain=<value> [list=bypass|vpnOnly]
                                                 Add a domain (vpnOnly also takes a CIDR); list defaults to bypass
      domain.rm (id=<uuid> | domain=<value>) [list=]
                                                 Remove a domain
      domain.enable (id=<uuid> | domain=<value>) [list=]
                                                 Enable a domain
      domain.disable (id=<uuid> | domain=<value>) [list=]
                                                 Disable a domain
                                                 (a domain on both lists needs list=)
      service.list [id=<service id>]            List the services (with id=: its domains and IP ranges)
      service.enable id=<service id>            Enable a service
      service.disable id=<service id>           Disable a service
      routes.active [source=<domain or service>]
                                                 Kernel routes VPN Bypass has installed now
      routes.clear                              Remove every installed route (the menu's Remove All
                                                 Routes…, without the question); they come back on
                                                 the next refresh
      refresh                                   Re-detect the VPN and re-apply every route (Refresh Routes)
      dns.refresh                               Re-resolve every domain and apply only what changed
      logs [limit=1..200] [level=info|success|warning|error]
                                                 Recent log lines, newest first (default 50)

    Any mode:
      why <host>                                Where a site goes: the entry or rule that routes it,
                                                 then a path check (the interface its connection to
                                                 port 443 leaves through, and whether it answers),
                                                 with a control address that must leave the other way
      pause [15m|1h|<n>m|<n>h|reconnect]        Take the app's routes out until the time is up,
                                                 the VPN reconnects, or resume (no length: until
                                                 resume); refused in VPN Only, and in Custom
                                                 unless every enabled rule goes Direct
      resume                                    Put the routes back (one apply, after the
                                                 tunnel settles)

      help | --help | -h                        Show this help

    JSON output:
      --json, anywhere on the line, prints the reply as one line of JSON with
      sorted keys instead of text: {"ok":true,"result":{...},"v":1}, or
      {"error":{"code":"...","message":"..."},"ok":false,"v":1}. A field that
      does not apply is left out, never null. The exit codes are the same. When
      the app cannot be reached (exit 2) the message still goes to stderr, and
      stdout carries an error object too (code app_unreachable, no_response or
      no_stdin), so a script always reads one JSON object.

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

var jsonOutput = false

func printResponse(_ response: ControlResponse) {
    if jsonOutput {
        print(VPNBCLI.renderJSON(response))
    } else {
        for line in VPNBCLI.textLines(response) { print(line) }
    }
}

/// A failure before or instead of an answer from the app: the text on stderr as always, plus
/// the same as a JSON error object on stdout under --json. Exits 2.
func failUnreachable(code: String, message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if jsonOutput { print(VPNBCLI.renderJSON(VPNBCLI.clientError(code: code, message: message))) }
    exit(2)
}

// MARK: - Entry point

let (rawArgs, wantsJSON) = VPNBCLI.stripJSONFlag(Array(CommandLine.arguments.dropFirst()))
jsonOutput = wantsJSON

if rawArgs.isEmpty {
    printUsage()
    exit(1)
}

if rawArgs[0] == "help" || rawArgs[0] == "--help" || rawArgs[0] == "-h" {
    printUsage()
    exit(0)
}

let parsed = VPNBCLI.parse(rawArgs)
for token in parsed.malformed {
    FileHandle.standardError.write(Data("vpnb: ignoring malformed argument (expected key=value): \(token)\n".utf8))
}

var secrets: [String: String] = [:]
if parsed.readPassFromStdin {
    guard let line = readLine(strippingNewline: true) else {
        failUnreachable(code: "no_stdin", message: "vpnb: pass:- (or --pass-stdin) given but no input on stdin")
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
    failUnreachable(code: "app_unreachable",
                    message: "VPN Bypass isn't running, or its control socket is unavailable. Start the app and try again.")
}
defer { close(fd) }

guard let response = sendRequestAndReadResponse(fd: fd, request: request) else {
    failUnreachable(code: "no_response", message: "vpnb: no response from VPN Bypass (connection closed or malformed reply)")
}

printResponse(response)
exit(response.ok ? 0 : 1)
