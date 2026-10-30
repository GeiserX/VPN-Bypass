// VPNBCLITests.swift
// `vpnb --json` (#184): the flag is taken out of argv wherever it sits, every reply renders as
// one JSON object with sorted keys, no credential reaches it, and the text output without the
// flag is what it was. The last group runs the built `vpnb` binary against a stub control socket.

import XCTest
@testable import VPNBypassCore

final class VPNBCLITests: XCTestCase {

    // MARK: - argv

    func testJSONFlagIsStrippedWhereverItSits() {
        for argv in [["--json", "routes.active", "source=example.com"],
                     ["routes.active", "--json", "source=example.com"],
                     ["routes.active", "source=example.com", "--json"]] {
            let (rest, json) = VPNBCLI.stripJSONFlag(argv)
            XCTAssertTrue(json, "\(argv)")
            XCTAssertEqual(rest, ["routes.active", "source=example.com"], "\(argv)")
            let parsed = VPNBCLI.parse(rest)
            XCTAssertEqual(parsed.cmd, "routes.active")
            XCTAssertEqual(parsed.args, ["source": "example.com"], "--json must never reach the app as an arg")
            XCTAssertEqual(parsed.malformed, [])
        }
    }

    func testWithoutTheFlagArgvIsUntouched() {
        let argv = ["domain.add", "domain=example.com", "pass:-", "oops"]
        let (rest, json) = VPNBCLI.stripJSONFlag(argv)
        XCTAssertFalse(json)
        XCTAssertEqual(rest, argv)
        let parsed = VPNBCLI.parse(rest)
        XCTAssertEqual(parsed.cmd, "domain.add")
        XCTAssertEqual(parsed.args, ["domain": "example.com"])
        XCTAssertTrue(parsed.readPassFromStdin)
        XCTAssertEqual(parsed.malformed, ["oops"])
    }

    // MARK: - JSON rendering

    private let activeRoutesReply = ControlResponse(ok: true, result: ControlResult(activeRoutes: [
        ControlActiveRoute(destination: "93.184.216.34", gateway: "192.168.1.1", source: "example.com"),
        ControlActiveRoute(destination: "203.0.113.0/24", gateway: "192.168.1.1", source: "Example Service"),
    ]))

    func testSuccessRendersSortedCompactJSON() throws {
        let json = VPNBCLI.renderJSON(activeRoutesReply)
        XCTAssertEqual(json, #"{"ok":true,"result":{"activeRoutes":[{"destination":"93.184.216.34","gateway":"192.168.1.1","source":"example.com"},{"destination":"203.0.113.0/24","gateway":"192.168.1.1","source":"Example Service"}]},"v":1}"#)
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: Data(json.utf8)), activeRoutesReply)
    }

    func testStatusRuntimeKeysAreSorted() {
        let reply = ControlResponse(ok: true, result: ControlResult(mode: "bypass", runtime: RuntimeStatus(
            helperReady: true, helperState: "Ready", vpnConnected: true, vpnInterface: "utun4",
            vpnType: "WireGuard", enforcedRouteCount: 2, enforcing: true, appVersion: "5.2.0")))
        XCTAssertEqual(VPNBCLI.renderJSON(reply), #"{"ok":true,"result":{"mode":"bypass","runtime":{"appVersion":"5.2.0","enforcedRouteCount":2,"enforcing":true,"helperReady":true,"helperState":"Ready","vpnConnected":true,"vpnInterface":"utun4","vpnType":"WireGuard"}},"v":1}"#)
    }

    func testErrorRendersAsJSON() throws {
        let reply = ControlResponse(ok: false, error: ControlError(code: "not_found", message: "no domain example.com"))
        let json = VPNBCLI.renderJSON(reply)
        XCTAssertEqual(json, #"{"error":{"code":"not_found","message":"no domain example.com"},"ok":false,"v":1}"#)
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: Data(json.utf8)), reply)
        XCTAssertEqual(VPNBCLI.renderJSON(VPNBCLI.clientError(code: "app_unreachable", message: "down")),
                       #"{"error":{"code":"app_unreachable","message":"down"},"ok":false,"v":1}"#)
    }

    func testNoCredentialReachesTheJSON() {
        let route = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "proxy.example.com", proxyPort: 1080,
                          proxyUser: "scripted-user", proxyPass: "hunter2-secret")
        var config = RouteManager.Config()
        config.routes = [route]
        for cmd in ["status", "route.list"] {
            let (_, response) = CommandRouter.apply(ControlRequest(cmd: cmd), to: config)
            let json = VPNBCLI.renderJSON(response)
            XCTAssertFalse(json.contains("hunter2-secret"), cmd)
            XCTAssertFalse(json.contains("scripted-user"), cmd)
            XCTAssertTrue(json.contains(#""hasPassword":true"#), cmd)
            XCTAssertTrue(json.contains(#""hasProxyUser":true"#), cmd)
        }
    }

    // MARK: - text rendering (unchanged by #184)

    /// Pins the lines this change moved into `VPNBCLI.textLines` that a status, routes.active or
    /// error reply prints; the rules, domains, services and logs branches are not covered here.
    func testTextOutputIsUnchanged() {
        let routeId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let route = Route(id: routeId, name: "Proxy", egress: .proxySOCKS5, proxyHost: "proxy.example.com", proxyPort: 1080,
                          proxyUser: "u", proxyPass: "p")
        var result = ControlResult(routes: [SanitizedRoute(route, listenerPort: 18042)], mode: "custom",
                                   schemaVersion: 2, supportedVersion: 1)
        result.activeRoutes = activeRoutesReply.result?.activeRoutes
        result.runtime = RuntimeStatus(helperReady: true, helperState: "Ready", vpnConnected: true, vpnInterface: "utun4",
                                       enforcedRouteCount: 2, enforcing: true, appVersion: "5.2.0")
        XCTAssertEqual(VPNBCLI.textLines(ControlResponse(ok: true, result: result)), [
            "11111111-1111-1111-1111-111111111111  Proxy  [proxySOCKS5]  enabled  proxy.example.com:1080  user:yes  pass:yes  listening:127.0.0.1:18042",
            "93.184.216.34 -> 192.168.1.1  (example.com)",
            "203.0.113.0/24 -> 192.168.1.1  (Example Service)",
            "helper: Ready  vpn: utun4  routes: 2  enforcing: true  app: 5.2.0",
            "mode: custom",
            "schemaVersion: 2",
            "supportedVersion: 1",
        ])
        XCTAssertEqual(VPNBCLI.textLines(ControlResponse(ok: false, error: ControlError(code: "not_found", message: "gone"))),
                       ["error: not_found: gone"])
        XCTAssertEqual(VPNBCLI.textLines(ControlResponse(ok: true)), ["ok"])
        XCTAssertEqual(VPNBCLI.textLines(ControlResponse(ok: true, result: ControlResult(activeRoutes: []))), ["no active routes"])
    }

    // MARK: - the real binary against a stub socket

    /// The `vpnb` the package built, next to the test bundle. `swift build` and `swift test` both
    /// build it; the test skips only when it is missing (for example under a filtered Xcode run).
    private func vpnbBinary() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("vpnb")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("vpnb is not built next to the test bundle (\(url.path))")
        }
        return url
    }

    private func run(_ binary: URL, _ args: [String], socket: String,
                     stdin: FileHandle? = nil) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = ["VPNB_SOCKET": socket]
        if let stdin { process.standardInput = stdin }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testBinaryPrintsJSONForSuccessAndErrorWithTheSameExitCodes() throws {
        let binary = try vpnbBinary()
        let path = NSTemporaryDirectory() + "vpnb-cli-\(UUID().uuidString.prefix(8)).sock"
        let reply = activeRoutesReply
        let seen = Locked<[ControlRequest]>([])
        let server = ControlSocketServer(socketPath: path) { request in
            seen.mutate { $0.append(request) }
            if request.cmd == "routes.active" { return reply }
            return ControlResponse(ok: false, error: ControlError(code: "unknown_command", message: "unknown command: \(request.cmd)"))
        }
        try server.start()
        defer { server.stop() }

        let ok = try run(binary, ["routes.active", "--json"], socket: path)
        XCTAssertEqual(ok.status, 0)
        XCTAssertEqual(ok.out, VPNBCLI.renderJSON(reply) + "\n")

        let text = try run(binary, ["routes.active"], socket: path)
        XCTAssertEqual(text.status, 0)
        XCTAssertEqual(text.out, VPNBCLI.textLines(reply).joined(separator: "\n") + "\n")

        let bad = try run(binary, ["--json", "nope", "x=1"], socket: path)
        XCTAssertEqual(bad.status, 1)
        XCTAssertEqual(bad.out, #"{"error":{"code":"unknown_command","message":"unknown command: nope"},"ok":false,"v":1}"# + "\n")

        XCTAssertEqual(seen.value.map(\.cmd), ["routes.active", "routes.active", "nope"])
        XCTAssertEqual(seen.value.last?.args, ["x": "1"], "--json is never sent to the app")
        XCTAssertNil(seen.value.first?.args)
    }

    func testBinaryUnreachableExits2WithJSONOnStdoutAndTextOnStderr() throws {
        let binary = try vpnbBinary()
        let missing = NSTemporaryDirectory() + "vpnb-none-\(UUID().uuidString.prefix(8)).sock"

        let json = try run(binary, ["status", "--json"], socket: missing)
        XCTAssertEqual(json.status, 2)
        XCTAssertTrue(json.err.contains("isn't running"))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(json.out.utf8))
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "app_unreachable")

        let text = try run(binary, ["status"], socket: missing)
        XCTAssertEqual(text.status, 2)
        XCTAssertEqual(text.out, "", "without --json stdout stays empty, as before")
        XCTAssertTrue(text.err.contains("isn't running"))
    }

    func testBinaryNoStdinExits2WithJSONCode() throws {
        let binary = try vpnbBinary()
        let missing = NSTemporaryDirectory() + "vpnb-none-\(UUID().uuidString.prefix(8)).sock"
        // stdin is read before the socket is opened, so no server is needed.
        let json = try run(binary, ["route.set", "id=x", "pass:-", "--json"], socket: missing,
                           stdin: FileHandle.nullDevice)
        XCTAssertEqual(json.status, 2)
        XCTAssertTrue(json.err.contains("no input on stdin"), json.err)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(json.out.utf8))
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "no_stdin")
    }

    func testBinaryNoResponseExits2WithJSONCode() throws {
        let binary = try vpnbBinary()
        let path = NSTemporaryDirectory() + "vpnb-mute-\(UUID().uuidString.prefix(8)).sock"
        let listener = try MuteListener(path: path)
        defer { listener.stop() }

        let json = try run(binary, ["status", "--json"], socket: path)
        XCTAssertEqual(json.status, 2)
        XCTAssertTrue(json.err.contains("no response"), json.err)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: Data(json.out.utf8))
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error?.code, "no_response")
    }
}

/// An AF_UNIX listener that accepts each connection and closes it at once, never replying.
private final class MuteListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.prefix(raw.count - 1).enumerated() { raw[i] = b }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        let listenFD = self.fd
        Thread.detachNewThread {
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 { return }
                close(client)
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }
}

/// A value shared with the socket server's threads.
private final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
