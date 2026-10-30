import Foundation
import SpikePolicy

/// Command-line mode: the same `Controller` calls the buttons make, so an agent can drive the spike
/// over ssh. Only the owner's two approvals (the system extension, the proxy configuration) still
/// need a click. Run it as the console user, from the installed bundle:
///
///   launchctl asuser $(id -u sergio) sudo -u sergio \
///     "/Applications/VPN Bypass NE Spike.app/Contents/MacOS/VPNBypassNESpike" status
enum CLI {
    static let usage = """
    usage: VPNBypassNESpike <command> [options]
      status                         proxy state, last disconnect error, the extension's reply
      activate                       1. Activate extension (exit 3: the owner must approve it)
      start [--scope port:80|all]    2. Start proxy (default port:80), waits up to 20 s for connected
      push [--apps a,b] [--hosts h1,h2] [--iface en0] [--hold]
                                     3. Push policy; --hold keeps the 30 s heartbeat until killed,
                                     without it the lease ends 2 minutes after the push
      pause [--hold]                 Pause (empty policy)
      stop-session                   Stop session (configuration stays enabled)
      turn-off                       Turn off (configuration disabled)
      remove                         Remove completely (configuration, then the extension)
    exit: 0 ok, 1 failed, 2 usage, 3 needs the owner's approval
    """

    /// Runs `args` (without the program name) and never returns.
    static func run(_ args: [String]) -> Never {
        let controller = Controller()
        controller.onLog = { print($0) }
        let cmd = args.first ?? "help"
        let opts = Options(Array(args.dropFirst()))

        func finish(_ code: Int32) -> Never {
            fflush(stdout)
            exit(code)
        }
        func printStatus(then code: Int32) {
            controller.lastDisconnectError { err in
                controller.status { s in
                    controller.describe(s).forEach { print($0) }
                    if let err { print("last disconnect error: \(err)") }
                    finish(s == nil && code == 0 ? 1 : code)
                }
            }
        }
        func push(apps: [String], hosts: [String], iface: String?, hold: Bool) {
            controller.push(apps: apps, hostnames: hosts, interfaceName: iface) { s in
                guard s != nil else { print("push failed: proxy not connected"); finish(1) }
                print("policy pushed: \(apps.count) app(s), \(hosts.count) host name(s)")
                controller.describe(s).forEach { print($0) }
                fflush(stdout)
                if hold {
                    print("holding: heartbeat every \(Int(Controller.heartbeatSeconds)) s until killed")
                    fflush(stdout)
                    for sig in [SIGINT, SIGTERM] {
                        signal(sig, SIG_IGN)
                        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                        src.setEventHandler { controller.stopHeartbeat(); finish(0) }
                        src.resume()
                        signalSources.append(src)
                    }
                } else {
                    controller.stopHeartbeat()
                    finish(0)
                }
            }
        }

        switch cmd {
        case "status":
            printStatus(then: 0)
        case "activate":
            controller.onRequestEnd = { end in
                switch end {
                case .completed: finish(0)
                case .willCompleteAfterReboot: finish(0)
                case .needsApproval: finish(3)
                case .failed: finish(1)
                }
            }
            controller.activate()
        case "start":
            guard let scope = IncludeScope(opts.value("--scope") ?? "port:80") else {
                print("bad --scope; use port:<n> or all"); finish(2)
            }
            controller.start(scope: scope) { ok in
                guard ok else { finish(1) }
                let began = Date()
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                    let waited = Date().timeIntervalSince(began)
                    if controller.isConnected || (waited > 3 && controller.isSettled) || waited > 20 {
                        t.invalidate()
                        printStatus(then: controller.isConnected ? 0 : 1)
                    }
                }
            }
        case "push":
            let apps = SpikePolicy.parseList(opts.value("--apps") ?? "", lowercase: false)
            let hosts = SpikePolicy.parseList(opts.value("--hosts") ?? "", lowercase: true)
            push(apps: apps, hosts: hosts, iface: opts.value("--iface"), hold: opts.flag("--hold"))
        case "pause":
            push(apps: [], hosts: [], iface: nil, hold: opts.flag("--hold"))
        case "stop-session":
            controller.stopSession { finish(0) }
        case "turn-off":
            controller.turnOff { finish(0) }
        case "remove":
            controller.onRequestEnd = { end in finish(end == .needsApproval ? 3 : end == .failed ? 1 : 0) }
            controller.remove()
        default:
            print(usage)
            finish(cmd == "help" ? 0 : 2)
        }
        RunLoop.main.run()
        finish(0)
    }

    private static var signalSources: [DispatchSourceSignal] = []

    struct Options {
        let args: [String]
        init(_ args: [String]) { self.args = args }
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func flag(_ name: String) -> Bool { args.contains(name) }
    }
}
