// ne-driver: the live-test stand-in for the app's side of per-app routing.
//
// The extension can only be activated, configured and fed a policy by the app that contains it
// (bundle id com.geiserx.vpn-bypass). Until FlowEngineManager does that inside the app, this
// command line does it, from a test bundle `make-test-app.sh` builds: the real extension from
// this tree, with this program as the app's executable. It is never shipped.
//
// It speaks the real wire format (VPNBypassPolicy is compiled in), so what it proves about the
// extension holds for the app. Run it as the console user, from the installed test bundle:
//
//   launchctl asuser $(id -u) "/Applications/VPN Bypass NE Test.app/Contents/MacOS/VPNBypass" status
//
// Exit codes: 0 ok, 1 failed, 2 usage, 3 needs the owner's approval.

import Foundation
import NetworkExtension
import SystemExtensions

let extensionID = "com.geiserx.vpn-bypass.proxy"
let usage = """
usage: VPNBypass <command> [options]
  activate                       activation request (exit 3: approval needed)
  deactivate                     deactivation request
  start                          save the configuration enabled, start the session, wait for connected
  push [--apps a,b] [--iface en0] [--lease s] [--hold] [--every s]
                                 push a policy (Direct for each app) and check the echo;
                                 --hold re-sends it every --every seconds (default 30) until killed
  pause [--hold]                 push a policy with no matchers
  bad-version                    push a policy with a version this extension does not read
  status                         session state, last disconnect error, the extension's reply
  probe [--count n] [--gap ms]   n status requests, prints reply times and misses
  stop-session                   stop the session (configuration stays enabled)
  turn-off                       disable the configuration
  remove                         remove the configuration, then deactivate the extension
"""

func out(_ s: String) { print("\(ISO8601DateFormatter().string(from: Date())) \(s)"); fflush(stdout) }
func finish(_ code: Int32) -> Never { fflush(stdout); exit(code) }

struct Options {
    let args: [String]
    func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    func flag(_ name: String) -> Bool { args.contains(name) }
}

final class Driver: NSObject, OSSystemExtensionRequestDelegate {
    var manager: NETransparentProxyManager?
    var onRequestEnd: (Int32) -> Void = { finish($0) }

    // MARK: System extension

    func submit(_ r: OSSystemExtensionRequest) {
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        out("replacing extension \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        out("needs approval in System Settings")
        onRequestEnd(3)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        out("request finished: \(result == .completed ? "completed" : "completes after reboot")")
        onRequestEnd(0)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        out("request failed: \(error.localizedDescription) (\((error as NSError).code))")
        onRequestEnd(1)
    }

    // MARK: Configuration

    func load(_ done: @escaping (NETransparentProxyManager?) -> Void) {
        NETransparentProxyManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error { out("load failed: \(error.localizedDescription)") }
                self.manager = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionID
                }
                done(self.manager)
            }
        }
    }

    func start(_ done: @escaping (Bool) -> Void) {
        load { existing in
            let m = existing ?? NETransparentProxyManager()
            if existing == nil {
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extensionID
                proto.serverAddress = "localhost"
                m.protocolConfiguration = proto
                m.localizedDescription = "VPN Bypass per-app routing (test)"
            }
            let go = {
                do {
                    try (m.connection as? NETunnelProviderSession)?.startTunnel(options: nil)
                    out("start requested")
                    done(true)
                } catch {
                    out("start failed: \(error.localizedDescription)")
                    done(false)
                }
            }
            // Saved only when a static field changes (3.3: re-saving has lost consent elsewhere).
            guard existing == nil || !m.isEnabled else { go(); return }
            m.isEnabled = true
            m.saveToPreferences { error in
                DispatchQueue.main.async {
                    if let error { out("save failed: \(error.localizedDescription)"); done(false); return }
                    out("configuration saved, enabled")
                    m.loadFromPreferences { _ in DispatchQueue.main.async { self.manager = m; go() } }
                }
            }
        }
    }

    var state: String {
        guard let m = manager else { return "no configuration" }
        let names: [NEVPNStatus: String] = [.invalid: "invalid", .disconnected: "disconnected", .connecting: "connecting",
                                            .connected: "connected", .reasserting: "reasserting",
                                            .disconnecting: "disconnecting"]
        return "\(names[m.connection.status] ?? "unknown"), configuration \(m.isEnabled ? "enabled" : "disabled")"
    }

    // MARK: Messages

    /// Sends `data`; `done(reply, seconds)`, reply nil when none came within `timeout`.
    func send(_ data: Data, timeout: Double = Double(FlowPolicy.echoTimeoutSeconds),
              _ done: @escaping (FlowPolicyReply?, Double) -> Void) {
        let fire = { (m: NETransparentProxyManager?) in
            guard let session = m?.connection as? NETunnelProviderSession, session.status == .connected else {
                done(nil, 0); return
            }
            let began = Date()
            var answered = false
            let answer = { (r: FlowPolicyReply?) in
                guard !answered else { return }
                answered = true
                done(r, Date().timeIntervalSince(began))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { answer(nil) }
            do {
                try session.sendProviderMessage(data) { reply in
                    let r = reply.flatMap { try? JSONDecoder().decode(FlowPolicyReply.self, from: $0) }
                    DispatchQueue.main.async { answer(r) }
                }
            } catch {
                out("send failed: \(error.localizedDescription)")
                DispatchQueue.main.async { answer(nil) }
            }
        }
        if let manager { fire(manager) } else { load(fire) }
    }

    func describe(_ r: FlowPolicyReply?) -> String {
        guard let r else { return "no reply from the extension" }
        let data = (try? JSONEncoder.sorted.encode(r)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

// MARK: - Commands

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"
let opts = Options(args: Array(args.dropFirst()))
let driver = Driver()
var signalSources: [DispatchSourceSignal] = []

func onSignal(_ handler: @escaping () -> Void) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler(handler: handler)
        src.resume()
        signalSources.append(src)
    }
}

/// A generation that rises across runs of this program, as the app's would.
func nextGeneration() -> Int { Int(Date().timeIntervalSince1970 * 10) }

func push(_ policy: FlowPolicy, hold: Bool, every: Double) {
    let data = try! FlowPolicyMessage.encode(policy)
    driver.send(data) { reply, seconds in
        let echoed = reply?.confirms(policy) ?? false
        out("push generation \(policy.generation) matchers \(policy.matchers.count): echo \(echoed ? "confirmed" : "MISSING") in \(Int(seconds * 1000)) ms")
        out(driver.describe(reply))
        guard hold else { finish(echoed ? 0 : 1) }
        out("holding: re-sending every \(Int(every)) s until killed")
        onSignal { out("stopped holding"); finish(0) }
        var misses = 0, sent = 0
        Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
            sent += 1
            driver.send(data) { r, s in
                if !(r?.confirms(policy) ?? false) { misses += 1 }
                out("heartbeat \(sent): \(r == nil ? "NO REPLY" : "reply") in \(Int(s * 1000)) ms, misses \(misses); \(driver.describe(r))")
            }
        }
    }
}

switch cmd {
case "activate":
    driver.submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main))
case "deactivate":
    driver.submit(.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main))
case "start":
    driver.start { ok in
        guard ok else { finish(1) }
        let began = Date()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            let st = driver.manager?.connection.status
            let waited = Date().timeIntervalSince(began)
            if st == .connected || (waited > 3 && st == .disconnected) || waited > 20 {
                t.invalidate()
                out("session \(driver.state) after \(Int(waited * 1000)) ms")
                finish(st == .connected ? 0 : 1)
            }
        }
    }
case "push", "pause":
    let apps = cmd == "pause" ? [] : (opts.value("--apps") ?? "").split(separator: ",").map(String.init)
    let iface = opts.value("--iface")
    let matchers = apps.enumerated().map { i, a in
        AppMatcher(ruleID: FlowPolicyCompiler.bypassAppRuleID(i), kind: AppMatcher.kind(of: a), pattern: a,
                   egress: .direct(interface: iface))
    }
    let lease = Int(opts.value("--lease") ?? "") ?? FlowPolicy.defaultLeaseSeconds
    push(FlowPolicy(generation: nextGeneration(), matchers: matchers, leaseSeconds: lease),
         hold: opts.flag("--hold"), every: Double(opts.value("--every") ?? "") ?? 30)
case "bad-version":
    let data = Data(#"{"version":\#(FlowPolicy.currentVersion + 1),"generation":\#(nextGeneration())}"#.utf8)
    driver.send(data) { r, s in
        out("bad-version push: reply in \(Int(s * 1000)) ms: \(driver.describe(r))")
        finish(r?.rejectedVersion == FlowPolicy.currentVersion + 1 && r?.policyLive == false ? 0 : 1)
    }
case "status":
    driver.load { m in
        out("session \(driver.state)")
        guard let m else { finish(0) }
        m.connection.fetchLastDisconnectError { error in
            DispatchQueue.main.async {
                if let error { out("last disconnect error: \(error.localizedDescription)") }
                driver.send(FlowPolicyMessage.statusRequest) { r, s in
                    out("reply in \(Int(s * 1000)) ms: \(driver.describe(r))")
                    finish(r == nil ? 1 : 0)
                }
            }
        }
    }
case "probe":
    let count = Int(opts.value("--count") ?? "") ?? 100
    let gap = Double(opts.value("--gap") ?? "") ?? 50
    var times: [Double] = []
    var misses = 0
    func one(_ i: Int) {
        guard i < count else {
            let sorted = times.sorted()
            func pct(_ p: Double) -> Int { sorted.isEmpty ? -1 : Int(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000) }
            out("probe: \(count) requests, \(misses) without a reply, ms p50 \(pct(0.5)) p99 \(pct(0.99)) max \(pct(1.0))")
            finish(misses == 0 ? 0 : 1)
        }
        driver.send(FlowPolicyMessage.statusRequest) { r, s in
            if r == nil { misses += 1 } else { times.append(s) }
            DispatchQueue.main.asyncAfter(deadline: .now() + gap / 1000) { one(i + 1) }
        }
    }
    driver.load { _ in one(0) }
case "stop-session":
    driver.load { m in
        m?.connection.stopVPNTunnel()
        out(m == nil ? "no configuration" : "session stop requested")
        finish(0)
    }
case "turn-off":
    driver.load { m in
        guard let m else { out("no configuration"); finish(0) }
        m.isEnabled = false
        m.saveToPreferences { error in
            out(error.map { "disable failed: \($0.localizedDescription)" } ?? "configuration disabled")
            finish(error == nil ? 0 : 1)
        }
    }
case "remove":
    driver.load { m in
        let deactivate = { driver.submit(.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main)) }
        guard let m else { out("no configuration"); deactivate(); return }
        m.removeFromPreferences { error in
            DispatchQueue.main.async {
                if let error { out("remove failed: \(error.localizedDescription)"); finish(1) }
                out("configuration removed")
                deactivate()
            }
        }
    }
default:
    print(usage)
    finish(cmd == "help" ? 0 : 2)
}
RunLoop.main.run()
