// engine-driver: the app's own per-app routing code, run from a test bundle on a test Mac.
//
// The app turns per-app routing on with FlowEngineManager and LiveFlowEngineSystem
// (Sources/VPNBypassCore). On a shared test Mac the whole app cannot run beside another VPN
// Bypass: it would update the shared privileged helper and sweep the other app's routes. This
// program compiles those two files as they are, with the policy target and the state file, and
// drives them the way the Settings switch does: the same activation request, configuration,
// session, policy pushes, heartbeat and watchdog. Only the inputs differ: a Custom-mode policy
// for the apps named on the command line, instead of the config.
//
// Build it into a test bundle with `make-test-app.sh APP OUT [VERSION] --engine`, then run it as
// the console user:
//
//   launchctl asuser $(id -u) "/Applications/VPN Bypass NE Test.app/Contents/MacOS/VPNBypass" on --apps ne6-fetch
//
// With `--route-driver PATH --gateway ROUTER` it also keeps per-app routing's scoped default route
// (R12) the way the app does, through `FlowEngineManager.syncEgressRoute`, but by running the
// helper's code from `sudo -n PATH set|clear` (scoped-route-main.swift) instead of the installed
// helper, and with the VPN taken as up.
//
// It prints every state change. SIGUSR1 turns per-app routing off (the switch), SIGUSR2 pauses
// it (Pause), SIGINT and SIGTERM quit without turning it off (the app quitting: the lease runs
// out). Never shipped.

import Combine
import Foundation
import VPNBypassPolicy

func out(_ s: String) { print("\(ISO8601DateFormatter().string(from: Date())) \(s)"); fflush(stdout) }

let args = Array(CommandLine.arguments.dropFirst())
func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard args.first == "on" else {
    print("usage: VPNBypass on --apps a,b [--iface en1]")
    exit(2)
}

let apps = (value("--apps") ?? "").split(separator: ",").map(String.init)
let direct = UUID()
var enabled = false
var paused = false
var keep: [Any] = []

MainActor.assumeIsolated {
    let engine = FlowEngineManager(system: LiveFlowEngineSystem())
    engine.inputs = {
        FlowPolicyCompiler.Input(
            mode: .custom,
            processRules: apps.enumerated().map { i, a in .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!, pattern: a, routeID: direct, order: i) },
            routes: [.init(id: direct, kind: .direct)],
            paused: paused,
            physicalInterface: value("--iface"))
    }
    engine.isEnabled = { enabled }
    engine.saveEnabled = { enabled = $0 }
    engine.log = { level, message in out("log \(level): \(message)") }
    if let driver = value("--route-driver"), let gateway = value("--gateway") {
        engine.egressRouteFacts = { (true, gateway) }
        engine.applyEgressRoute = { request in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", driver] + (request.map { ["set", $0.interface, $0.gateway] } ?? ["clear"])
            let pipe = Pipe()
            p.standardOutput = pipe
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let answer = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out("route \(request.map { "set \($0.interface)" } ?? "clear"): \(answer)")
            return ScopedDefaultOutcome(rawValue: answer)
        }
    }
    keep.append(engine.$state.removeDuplicates().sink { out("state \($0.code)\($0.reasonCode.map { " (\($0))" } ?? "")") })
    keep.append(engine.$reply.sink { r in
        guard let r else { return }
        out("reply generation \(r.policyGeneration) extension \(r.extensionVersion ?? "?") claimed \(r.claimedByRule) bound \(r.boundByRule)")
    })
    out("support \(engine.system.support)")
    engine.begin()
    engine.setEnabled(true)

    for (sig, action) in [(SIGUSR1, "off"), (SIGUSR2, "pause"), (SIGINT, "quit"), (SIGTERM, "quit")] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            MainActor.assumeIsolated {
                switch action {
                case "off":
                    out("switch off")
                    engine.setEnabled(false)
                case "pause":
                    paused.toggle()
                    out(paused ? "pause" : "resume")
                    engine.inputsChanged()
                default:
                    out("quit (the lease runs out)")
                    exit(0)
                }
            }
        }
        src.resume()
        keep.append(src)
    }
}
dispatchMain()
