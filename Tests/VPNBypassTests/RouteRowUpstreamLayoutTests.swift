// RouteRowUpstreamLayoutTests.swift
// The Routes page keeps a proxy route's addresses on one line (issue #153). The upstream
// used to wrap mid-address beside "Listening on 127.0.0.1:<port>"; now the listener and the
// upstream share one mono detail line, which must neither wrap nor push the switch out. Rows
// are drawn offscreen at the width the Settings window gives them, with a fixed listener
// port; nothing is routed or listened on.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class RouteRowUpstreamLayoutTests: XCTestCase {

    /// The width a route row gets: the window's default content width, less the sidebar, its
    /// 1 pt edge and the page's margins.
    private static let rowWidth: CGFloat = SettingsWindowController.defaultContentSize.width
        - SettingsSidebarView.width - 1 - 2 * Theme.Space.page

    private func row(host: String, port: Int = 1080) -> RouteRow {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: host, proxyPort: port,
                          localListenPort: 18168)
        return RouteRow(route: route, listenerPort: 18168, onEdit: {}, onDelete: {}, onDuplicate: {},
                        onToggle: { _ in })
    }

    private func settled<V: View>(_ view: V) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            hosting.layoutSubtreeIfNeeded()
        }
        return hosting
    }

    /// Height of the row at the Settings width: one more text line when the upstream wraps.
    private func height(host: String) -> CGFloat {
        settled(row(host: host).frame(width: Self.rowWidth)).fittingSize.height
    }

    /// Width the row asks for with nothing cut or wrapped.
    private func idealWidth(host: String) -> CGFloat {
        settled(row(host: host).fixedSize()).fittingSize.width
    }

    private let shortHost = "10.0.0.1"
    private let longHosts = [
        "2001:db8:85a3::8a2e:370:7334",          // IPv6, shown as 2001:db8:85a3::8a2e:370:7334:1080
        "egress-proxy.eu-west-1.corp.example.com", // shown as ...example.com:1080, 44 characters
    ]

    func testALongUpstreamStaysOnOneLine() {
        let base = height(host: shortHost)
        for host in longHosts {
            XCTAssertEqual(height(host: host), base, accuracy: 1,
                           "\(host):1080 draws on more lines than a short upstream")
        }
    }

    /// The #153 example and a short host name fit beside the listener address whole. Longer
    /// ones are cut in the middle (the row's tooltip holds all of it), never wrapped.
    func testATypicalUpstreamIsShownWhole() {
        for host in ["198.51.100.20", "proxy.example.com"] {
            XCTAssertLessThanOrEqual(idealWidth(host: host), Self.rowWidth,
                                     "\(host):1080 does not fit the row, so part of it is cut")
        }
    }

    /// A host name too long for any line is cut, never wrapped.
    func testAnUpstreamLongerThanTheRowIsCutNotWrapped() {
        let host = "a-very-long-upstream-proxy-host-name.eu-west-1.internal.corp.example.com"
        XCTAssertGreaterThan(idealWidth(host: host), Self.rowWidth, "control: this host is wider than the row")
        XCTAssertEqual(height(host: host), height(host: shortHost), accuracy: 1)
    }
}
