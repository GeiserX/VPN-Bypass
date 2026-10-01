// DocScreenshotsTests.swift
// Renders every screenshot in docs/images/screenshots/ from the real views, offscreen, with
// fixed fake state. Skipped unless VPNB_DOC_SCREENSHOTS names an output directory:
//
//   VPNB_DOC_SCREENSHOTS=/tmp/shots swift test --filter DocScreenshotsTests
//
// Run it on a Mac with a 2x display: the images are 2x and the renders take the screen's
// scale. Nothing here touches the routing table: the VPN check is off, routes are only
// written into `activeRoutes`, and the config is the test-run temp copy.

import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import VPNBypassCore

/// The dropdown's stand-in window: borderless, yet able to become key like the menu bar's.
final class DocScreenshotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    /// Kept where it is put, offscreen, instead of being pulled onto a display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class DocScreenshotsTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var outputDir: URL!
    private var windows: [NSWindow] = []
    /// A loopback listener started for the proxy route, stopped after the render.
    private var startedListener = false
    /// The app's appearance before the renders forced dark, put back in `tearDown`.
    private var savedAppearance: NSAppearance?
    private var saved: (config: RouteManager.Config, connected: Bool, iface: String?, type: VPNType?,
                        gateway: String?, routes: [RouteManager.ActiveRoute], update: Date?,
                        loading: Bool, change: RouteManager.RouteChangeOutcome?, dns: Date?, helper: HelperState)!

    nonisolated private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The dropdown's ground in the menu bar on a dark desktop, sampled from a real capture.
    private static let dropdownGround = Color(red: 15 / 255, green: 15 / 255, blue: 15 / 255)

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VPNB_DOC_SCREENSHOTS"], !dir.isEmpty else {
            throw XCTSkip("Set VPNB_DOC_SCREENSHOTS to an output directory to render the doc screenshots.")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        Self.serveBrandMark(true)
        XCTAssertNotNil(Bundle.main.image(forResource: "menubar-icon-active"), "the title bar's mark loads")
        Self.drawAsFrontmost(true)
        savedAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        saved = (rm.config, rm.isVPNConnected, rm.vpnInterface, rm.vpnType, rm.localGateway,
                 rm.activeRoutes, rm.lastUpdate, rm.isLoading, rm.lastRouteChange,
                 rm.lastDNSRefresh, HelperManager.shared.helperState)
        rm.refreshStatusOverrideForTests = {}
        SettingsPageRequest.shared.page = nil
    }

    override func tearDown() async throws {
        guard saved != nil else { return }
        Self.drawAsFrontmost(false)
        Self.serveBrandMark(false)
        XCTAssertNil(Bundle.main.image(forResource: "menubar-icon-active"),
                     "the test runner's own bundle answers again once the renders are done")
        NSApplication.shared.appearance = savedAppearance
        XCTAssertNil(NSApplication.shared.appearance, "the app follows the system appearance again")
        if startedListener { ProxyListenerManager.shared.stopAll() }
        startedListener = false
        windows.forEach { $0.orderOut(nil) }
        windows = []
        rm.refreshStatusOverrideForTests = nil
        rm.config = saved.config
        rm.isVPNConnected = saved.connected
        rm.vpnInterface = saved.iface
        rm.vpnType = saved.type
        rm.localGateway = saved.gateway
        rm.activeRoutes = saved.routes
        rm.lastUpdate = saved.update
        rm.isLoading = saved.loading
        rm.lastRouteChange = saved.change
        rm.lastDNSRefresh = saved.dns
        HelperManager.shared.helperState = saved.helper
        SettingsPageRequest.shared.page = nil
    }

    // MARK: - The screenshots

    func testDropdownInBypassMode() throws {
        seedBypass()
        let size = try renderDropdown(to: "menu-bar.png")
        XCTAssertEqual(size.width, 680)
    }

    func testDropdownOnFirstRun() throws {
        seedConnected(mode: .bypass)
        rm.activeRoutes = []
        rm.lastRouteChange = nil
        let size = try renderDropdown(to: "first-run.png")
        XCTAssertEqual(size.width, 680)
    }

    func testDropdownInVPNOnlyMode() throws {
        seedConnected(mode: .vpnOnly)
        rm.config.inverseDomains = [DomainEntry(domain: "intranet.example.com", enabled: true),
                                    DomainEntry(domain: "git.example.com", enabled: true)]
        var routes = ClassicRouteCompiler.bypassAllCatchAlls.map {
            route($0, via: "192.168.1.1", for: ClassicRouteCompiler.catchAllSource)
        }
        routes += addresses(["intranet.example.com": 2, "git.example.com": 1], gateway: "10.0.0.1")
        rm.activeRoutes = routes
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-19), routeCount: 3, failedCount: 0)
        let size = try renderDropdown(to: "vpn-only.png")
        XCTAssertEqual(size.width, 680)
    }

    func testSettingsOnServices() throws {
        seedBypass()
        let size = try renderSettings(page: .services, to: "services.png")
        XCTAssertEqual(size, NSSize(width: 1160, height: 1424))
    }

    func testSettingsOnDomains() throws {
        seedBypass()
        let size = try renderSettings(page: .domains, to: "domains.png")
        XCTAssertEqual(size, NSSize(width: 1160, height: 1424))
    }

    func testSettingsOnRules() throws {
        seedCustom()
        let size = try renderSettings(page: .rules, to: "rules.png")
        XCTAssertEqual(size, NSSize(width: 1160, height: 1424))
    }

    func testSettingsOnRoutes() throws {
        seedCustom()
        let size = try renderSettings(page: .routes, to: "routes.png")
        XCTAssertEqual(size, NSSize(width: 1160, height: 1424))
    }

    // MARK: - Fake state

    /// WireGuard on utun4, helper ready, nothing on any list yet.
    private func seedConnected(mode: RouteManager.RoutingMode) {
        var cfg = RouteManager.Config()
        cfg.routingMode = mode
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        rm.config = cfg
        rm.isVPNConnected = true
        rm.vpnInterface = "utun4"
        rm.vpnType = .wireGuard
        rm.localGateway = "192.168.1.1"
        rm.isLoading = false
        rm.lastUpdate = Date().addingTimeInterval(-23)
        rm.lastDNSRefresh = Date().addingTimeInterval(-12 * 60)
        HelperManager.shared.helperState = .ready
    }

    /// Four services and two domains, 62 addresses routed around the VPN.
    private func seedBypass() {
        seedConnected(mode: .bypass)
        let on: Set = ["telegram", "whatsapp", "youtube", "spotify"]
        for i in rm.config.services.indices where on.contains(rm.config.services[i].id) {
            rm.config.services[i].enabled = true
        }
        rm.config.domains = [DomainEntry(domain: "en.wikipedia.org", enabled: true),
                             DomainEntry(domain: "news.ycombinator.com", enabled: true)]
        rm.activeRoutes = addresses(["Telegram": 18, "WhatsApp": 12, "YouTube": 16, "Spotify": 8,
                                     "en.wikipedia.org": 4, "news.ycombinator.com": 4],
                                    gateway: "192.168.1.1")
        rm.lastRouteChange = .init(kind: .applied, at: Date().addingTimeInterval(-23), routeCount: 62, failedCount: 0)
    }

    /// A domain to a SOCKS5 proxy, a service direct, a subnet to the VPN, the rest direct.
    private func seedCustom() {
        seedConnected(mode: .custom)
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))
        let proxy = Route(name: "office-proxy", egress: .proxySOCKS5,
                          proxyHost: "198.51.100.7", proxyPort: 1080, localListenPort: 18168)
        rm.config.routes = [direct, vpn, proxy]
        rm.config.rules = [
            Rule(matchType: .domain, pattern: "en.wikipedia.org", routeId: proxy.id, order: 0),
            Rule(matchType: .service, pattern: "telegram", routeId: direct.id, order: 1),
            Rule(matchType: .cidr, pattern: "203.0.113.0/24", routeId: vpn.id, order: 2),
        ]
        rm.config.defaultRouteId = direct.id
        rm.config.schemaVersion = 2
        rm.config.multiRouteEnabled = true
        rm.activeRoutes = addresses(["Telegram": 18], gateway: "192.168.1.1")
            + [route("203.0.113.0/24", via: "10.0.0.1", for: "203.0.113.0/24")]

        // The Routes page shows a proxy route's local address once its listener is up. This
        // one listens on 127.0.0.1 only and reaches its upstream only if a client connects.
        var up = false
        ProxyListenerManager.shared.reconcile(routes: rm.config.routes, boundInterface: nil) { up = true }
        startedListener = true
        let deadline = Date().addingTimeInterval(5)
        while !up && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNotNil(ProxyListenerManager.shared.port(for: proxy.id), "office-proxy's listener is up")
    }

    private func route(_ destination: String, via gateway: String, for source: String) -> RouteManager.ActiveRoute {
        .init(destination: destination, gateway: gateway, source: source, timestamp: Date())
    }

    /// Addresses from the documentation ranges (RFC 5737), never a real host.
    private func addresses(_ counts: KeyValuePairs<String, Int>, gateway: String) -> [RouteManager.ActiveRoute] {
        let blocks = ["192.0.2", "198.51.100", "203.0.113"]
        var next = 0
        var out: [RouteManager.ActiveRoute] = []
        for (source, count) in counts {
            for _ in 0..<count {
                let ip = "\(blocks[next / 250]).\(next % 250 + 1)"
                out.append(route(ip, via: gateway, for: source))
                next += 1
            }
        }
        return out
    }

    // MARK: - Rendering

    private func renderDropdown(to name: String) throws -> NSSize {
        let hosting = NSHostingView(rootView: MenuContent()
            .environmentObject(rm)
            .environmentObject(NotificationManager.shared)
            .environmentObject(LaunchAtLoginManager.shared)
            .background(Self.dropdownGround))
        let window = DocScreenshotKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        show(window)
        window.setContentSize(hosting.fittingSize)
        settle(hosting)
        return try write(hosting, cornerRadius: 15, outline: NSColor(white: 0.2, alpha: 1), to: name)
    }

    private func renderSettings(page: SettingsView.SettingsTab, to name: String) throws -> NSSize {
        SettingsPageRequest.shared.page = page
        let window = SettingsWindowController.makeWindow()
        window.appearance = NSAppearance(named: .darkAqua)
        show(window)
        window.makeFirstResponder(nil)
        let frame = try XCTUnwrap(window.contentView?.superview, "the window's frame view")
        settle(frame)
        let size = try write(frame, cornerRadius: 17, outline: NSColor(white: 1, alpha: 0.2), to: name)
        try assertCloseButtonIsRed(name)
        return size
    }

    /// The close button is red only in the key window of the active app: grey here means the
    /// render came out inactive, switches and accents included.
    private func assertCloseButtonIsRed(_ name: String) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: outputDir.appendingPathComponent(name))))
        let close = try XCTUnwrap(rep.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(close.redComponent, 0.8, "\(name): close button \(close)")
        XCTAssertLessThan(close.greenComponent, 0.5, "\(name): close button \(close)")
    }

    /// Off every display, drawn as the key window of the active app (see `drawAsFrontmost`).
    private func show(_ window: NSWindow) {
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFront(nil)
        windows.append(window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.post(name: name, object: window)
        }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
        settle(window.contentView!)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Caches `view`, rounds its corners, draws a 1 pt outline inside the edge, and writes a PNG.
    private func write(_ view: NSView, cornerRadius: CGFloat, outline: NSColor, to name: String) throws -> NSSize {
        let bounds = view.bounds
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let scale = CGFloat(image.width) / bounds.width
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let radius = cornerRadius * scale
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: rect)
        let edge = rect.insetBy(dx: scale / 2, dy: scale / 2)
        ctx.addPath(CGPath(roundedRect: edge, cornerWidth: radius - scale / 2, cornerHeight: radius - scale / 2, transform: nil))
        ctx.setStrokeColor(outline.cgColor)
        ctx.setLineWidth(scale)
        ctx.strokePath()
        let out = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
        let png = try XCTUnwrap(out.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent(name))
        return NSSize(width: image.width, height: image.height)
    }

    // MARK: - Drawn as the frontmost window

    /// A process started over ssh cannot activate itself, so AppKit would draw every window
    /// inactive: grey traffic lights, grey switches. While on, every window reports itself key
    /// and main, and the app active. AppKit draws from its private appearance getters as well
    /// as the public ones, so both are answered; a selector a later macOS drops is skipped, and
    /// the close-button check in `renderSettings` catches a render that comes out inactive.
    /// Swapped per class, not per window: changing a window's class breaks the key-value
    /// observers AppKit keeps on it.
    private static var originals: [(Method, IMP)] = []

    private static func drawAsFrontmost(_ on: Bool) {
        guard on else {
            originals.forEach { method_setImplementation($0.0, $0.1) }
            originals = []
            return
        }
        guard originals.isEmpty else { return }
        let alwaysTrue = method_getImplementation(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.docScreenshotTrue))!)
        let getters: [(AnyClass, [String])] = [
            (NSWindow.self, ["isKeyWindow", "isMainWindow", "hasKeyAppearance", "hasMainAppearance",
                             "_isKeyWindow", "_hasKeyAppearance", "_hasMainAppearance", "_hasActiveControls",
                             "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus",
                             "_hasActiveAppearanceForStandardWindowButton:"]),
            (NSApplication.self, ["isActive", "_isActiveApp"]),
        ]
        for (cls, names) in getters {
            for name in names {
                guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { continue }
                originals.append((method, method_setImplementation(method, alwaysTrue)))
            }
        }
    }

    // MARK: - Brand mark

    /// The title bar and wordmark load the mark from `Bundle.main`, which under XCTest is the
    /// test runner. Serve it from `assets/`, where the app bundle copies it from, while on;
    /// off swaps the two methods back.
    private static var brandMarkInstalled = false

    private static func serveBrandMark(_ on: Bool) {
        guard on != brandMarkInstalled else { return }
        brandMarkInstalled = on
        let original = class_getInstanceMethod(Bundle.self, #selector(Bundle.image(forResource:)))!
        let replacement = class_getInstanceMethod(Bundle.self, #selector(Bundle.docScreenshotImage(forResource:)))!
        method_exchangeImplementations(original, replacement)
    }

    nonisolated fileprivate static func assetImage(_ name: String) -> NSImage? {
        let assets = repoRoot.appendingPathComponent("assets")
        guard let one = NSImageRep(contentsOf: assets.appendingPathComponent("\(name).png")) else { return nil }
        let image = NSImage(size: one.size)
        image.addRepresentation(one)
        if let two = NSImageRep(contentsOf: assets.appendingPathComponent("\(name)@2x.png")) {
            two.size = one.size
            image.addRepresentation(two)
        }
        return image
    }
}

extension NSWindow {
    @objc fileprivate func docScreenshotTrue() -> Bool { true }
}

extension Bundle {
    /// Swapped with `image(forResource:)` while the screenshots render; calling itself calls
    /// the original.
    @objc fileprivate func docScreenshotImage(forResource name: NSImage.Name) -> NSImage? {
        if self == Bundle.main, let image = DocScreenshotsTests.assetImage(name) { return image }
        return docScreenshotImage(forResource: name)
    }
}
