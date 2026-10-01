// RouteRowUpstreamLayoutTests.swift
// The Routes page's proxy card keeps its upstream address on one line (issue #153). The
// upstream used to share a line with "Listening on 127.0.0.1:<port>", so one longer than
// about 17 characters wrapped mid-address. Rows are drawn offscreen at the width the
// Settings window gives them, with a fixed listener port; nothing is routed or listened on.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class RouteRowUpstreamLayoutTests: XCTestCase {

    /// The width a route row gets: the 580 pt window, less the page's 24 pt padding and
    /// the Routes card's 16 pt padding on each side.
    private static let rowWidth: CGFloat = 580 - 2 * 24 - 2 * 16

    private func row(host: String, port: Int = 1080) -> RouteRow {
        let route = Route(name: "office-proxy", egress: .proxySOCKS5, proxyHost: host, proxyPort: port,
                          localListenPort: 18168)
        return RouteRow(route: route, listenerPort: 18168, onEdit: {}, onDelete: {}, onToggle: { _ in })
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

    func testALongUpstreamIsShownWhole() {
        for host in longHosts {
            XCTAssertLessThanOrEqual(idealWidth(host: host), Self.rowWidth,
                                     "\(host):1080 does not fit the row, so part of it is cut or wrapped")
        }
    }

    /// A host name too long for any line is cut, never wrapped.
    func testAnUpstreamLongerThanTheRowIsCutNotWrapped() {
        let host = "a-very-long-upstream-proxy-host-name.eu-west-1.internal.corp.example.com"
        XCTAssertGreaterThan(idealWidth(host: host), Self.rowWidth, "control: this host is wider than the row")
        XCTAssertEqual(height(host: host), height(host: shortHost), accuracy: 1)
    }
}
