import AppKit
import SpikePolicy

/// One window of buttons for the live test. Nothing starts on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let controller = Controller()
    private let appsField = NSTextField(string: "com.geiserx.vpn-bypass.spike.fetch")
    private let hostsField = NSTextField(string: "")
    private let interfaceField = NSTextField(string: "")
    private let scopePopup = NSPopUpButton()
    private let statusView = NSTextView()
    private let logView = NSTextView()
    private var refresh: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VPN Bypass NE spike"
        window.appearance = NSAppearance(named: .darkAqua)

        scopePopup.addItems(withTitles: ["port:80  (narrow: only TCP to port 80)", "all  (every outbound TCP flow)"])
        hostsField.placeholderString = "host names, comma separated (connect-by-name flows only)"
        interfaceField.placeholderString = "blank = most preferred Wi-Fi/Ethernet"

        let form = NSGridView(views: [
            [label("Apps (bundle id or executable name)"), appsField],
            [label("Host names"), hostsField],
            [label("Egress interface"), interfaceField],
            [label("Include scope (at start)"), scopePopup],
        ])
        form.column(at: 1).width = 460

        let row1 = NSStackView(views: [
            button("1. Activate extension", #selector(activate)),
            button("2. Start proxy", #selector(start)),
            button("3. Push policy", #selector(push)),
            button("Pause (empty policy)", #selector(pause)),
        ])
        let row2 = NSStackView(views: [
            button("Stop session", #selector(stopSession)),
            button("Turn off", #selector(turnOff)),
            button("Remove completely", #selector(remove)),
        ])

        for v in [statusView, logView] {
            v.isEditable = false
            v.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        let stack = NSStackView(views: [form, row1, row2, scroll(statusView, height: 230), scroll(logView, height: 150)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        controller.onLog = { [weak self] line in self?.log(line) }
        log("ready. Nothing is active until you click.")
        refresh = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshStatus() }
        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func activate() { controller.activate() }

    @objc private func start() {
        let scope: IncludeScope = scopePopup.indexOfSelectedItem == 0 ? .tcpPort(80) : .allTCP
        controller.start(scope: scope)
    }

    @objc private func push() {
        let apps = SpikePolicy.parseList(appsField.stringValue, lowercase: false)
        let hosts = SpikePolicy.parseList(hostsField.stringValue, lowercase: true)
        let iface = interfaceField.stringValue.trimmingCharacters(in: .whitespaces)
        controller.push(apps: apps, hostnames: hosts, interfaceName: iface.isEmpty ? nil : iface) { [weak self] s in
            self?.log(s == nil ? "push failed: proxy not connected" : "policy pushed: \(apps.count) app(s), \(hosts.count) host name(s), heartbeat every 30 s")
            self?.show(s)
        }
    }

    @objc private func pause() {
        controller.push(apps: [], hostnames: [], interfaceName: nil) { [weak self] s in
            self?.log(s == nil ? "pause failed: proxy not connected" : "paused: empty policy, include rule still installed")
            self?.show(s)
        }
    }

    @objc private func stopSession() { controller.stopSession() }
    @objc private func turnOff() { controller.turnOff() }
    @objc private func remove() { controller.remove() }

    private func refreshStatus() {
        controller.status { [weak self] s in self?.show(s) }
    }

    private func show(_ s: SpikeStatus?) {
        var lines = ["proxy: \(controller.connectionState)"]
        if let s {
            lines.append("extension pid \(s.extensionPID), started \(Date(timeIntervalSince1970: TimeInterval(s.startedAt)))")
            lines.append("scope \(s.scope), policy generation \(s.policyGeneration), lease \(s.policyLive ? "live" : "NOT live (declining all)")")
            lines.append("egress interface \(s.interfaceName)")
            for (k, v) in s.counters.sorted(by: { $0.key < $1.key }) { lines.append("  \(k) = \(v)") }
        } else {
            lines.append("(no reply from the extension)")
        }
        statusView.string = lines.joined(separator: "\n")
    }

    private func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logView.string = "\(f.string(from: Date()))  \(line)\n" + logView.string
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func scroll(_ v: NSTextView, height: CGFloat) -> NSScrollView {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.documentView = v
        v.autoresizingMask = [.width]
        v.minSize = NSSize(width: 0, height: height)
        v.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        v.isVerticallyResizable = true
        s.translatesAutoresizingMaskIntoConstraints = false
        s.heightAnchor.constraint(equalToConstant: height).isActive = true
        s.widthAnchor.constraint(equalToConstant: 736).isActive = true
        return s
    }
}
