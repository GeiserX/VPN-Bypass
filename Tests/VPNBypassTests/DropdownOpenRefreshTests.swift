// DropdownOpenRefreshTests.swift
// The dropdown refreshes the VPN status on every open, not on the first one only.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

/// A MenuBarExtra(.window) keeps one window and one view tree for the app's life. Opening it
/// orders that window in and makes it key; closing orders it out. `.onAppear` runs on the first
/// open only and `.onDisappear` never, so a refresh hung on `.onAppear` ran once per launch.
/// The host here opens and closes a window the same way. The VPN is never connected, and
/// RouteManager.refreshStatus() is replaced by a counter, so nothing here checks or routes for real.
@MainActor
final class DropdownOpenRefreshTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedVPNConnected = false
    private var savedIsLoading = true
    private var windows: [NSWindow] = []
    /// Calls to RouteManager.refreshStatus(), the call the dropdown makes on each open.
    private var refreshes = 0

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() async throws {
        savedConfig = rm.config
        savedVPNConnected = rm.isVPNConnected
        savedIsLoading = rm.isLoading
        rm.isVPNConnected = false
        rm.isLoading = false
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        rm.config = cfg
        rm.refreshStatusOverrideForTests = { [weak self] in self?.refreshes += 1 }
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        rm.refreshStatusOverrideForTests = nil
        rm.config = savedConfig
        rm.isVPNConnected = savedVPNConnected
        rm.isLoading = savedIsLoading
    }

    /// The dropdown's window as the menu bar builds it: `MenuBarExtraWindow` is a borderless
    /// NSPanel with `.nonactivatingPanel` and `.fullSizeContentView` (style mask 0x8080, read
    /// from a running MenuBarExtra) that takes key focus without activating the app. A test
    /// process is not an active app, so a plain window here never becomes key.
    private final class DropdownPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func makeWindow<V: View>(_ view: V) -> NSWindow {
        let window = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 760),
                                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        windows.append(window)
        return window
    }

    private func settle() {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }

    private func open(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        settle()
    }

    private func dropdown(onAppear: @escaping () -> Void) -> some View {
        MenuContent()
            .environmentObject(rm)
            .environmentObject(NotificationManager.shared)
            .environmentObject(LaunchAtLoginManager.shared)
            .onAppear(perform: onAppear)
    }

    func testEveryOpenRefreshes() throws {
        var appears = 0
        let window = makeWindow(dropdown(onAppear: { appears += 1 }))

        open(window)
        XCTAssertTrue(window.isKeyWindow, "control: the host makes the window key, as the menu bar does")
        XCTAssertEqual(refreshes, 1, "the first open refreshes")
        close(window)
        open(window)

        XCTAssertEqual(appears, 1, "control: like the menu bar, the host runs .onAppear on the first open only")
        XCTAssertEqual(refreshes, 2, "the second open refreshes again")
    }

    /// Another window taking key focus is not an open of the dropdown.
    func testAnotherWindowBecomingKeyDoesNotRefresh() throws {
        let window = makeWindow(dropdown(onAppear: {}))
        open(window)
        XCTAssertEqual(refreshes, 1)

        let other = makeWindow(Text("Settings").frame(width: 200, height: 100))
        open(other)
        XCTAssertTrue(other.isKeyWindow, "control: the other window took key focus")
        XCTAssertEqual(refreshes, 1, "a different window became key")
    }
}
