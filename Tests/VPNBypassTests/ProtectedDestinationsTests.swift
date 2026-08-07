// ProtectedDestinationsTests.swift
// Coverage for the destinations VPN Bypass must never touch because they belong to other
// networking software sharing the machine.
//
// The motivating case: Tailscale runs alongside this app in mesh mode, owns 100.64.0.0/10 and
// answers DNS on 100.100.100.100. Nothing previously stopped a route for either being written — a
// VPN Only entry of exactly 100.64.0.0/10 would reach `route change -net`, match on destination,
// and silently repoint Tailscale's own route into the corporate tunnel; teardown would then delete
// it outright. Mesh networking would break with nothing indicating this app was responsible.
//
// Enforced at the privileged boundary (the root daemon), so it holds regardless of what the app
// asks for — the same reasoning that makes the helper reject /0.

import XCTest
@testable import VPNBypassCore

final class ProtectedDestinationsTests: XCTestCase {

    // MARK: - Tailscale

    func testTailnetRangeItselfIsProtected() {
        XCTAssertTrue(ProtectedDestinations.isProtected("100.64.0.0/10"))
    }

    /// A SHORTER prefix on the same network covers the tailnet and wins longest-prefix match
    /// against Tailscale's own route just as surely, so it must be refused too.
    func testPrefixesCoveringTheTailnetAreProtected() {
        XCTAssertTrue(ProtectedDestinations.isProtected("100.64.0.0/8"))
        XCTAssertTrue(ProtectedDestinations.isProtected("100.64.0.0/1"))
    }

    func testMagicDNSIsProtectedInBothForms() {
        XCTAssertTrue(ProtectedDestinations.isProtected("100.100.100.100"))
        XCTAssertTrue(ProtectedDestinations.isProtected("100.100.100.100/32"))
    }

    /// Deliberately NOT protected: an ordinary host inside CGNAT. That range is shared with Zscaler
    /// and Cloudflare WARP, and the helper cannot know whether Tailscale is running — refusing all
    /// of it here would break legitimate bypasses for those clients. Whether to route an individual
    /// CGNAT host is a policy decision for the app layer, which does know.
    func testOrdinaryCGNATHostIsNotBlanketProtected() {
        XCTAssertFalse(ProtectedDestinations.isProtected("100.127.106.1"))
        XCTAssertFalse(ProtectedDestinations.isProtected("100.64.1.5"))
    }

    // MARK: - Kernel-reserved space

    func testLoopbackLinkLocalMulticastAndBroadcastAreProtected() {
        XCTAssertTrue(ProtectedDestinations.isProtected("127.0.0.1"))
        XCTAssertTrue(ProtectedDestinations.isProtected("127.0.0.0/8"))
        XCTAssertTrue(ProtectedDestinations.isProtected("169.254.1.1"))
        XCTAssertTrue(ProtectedDestinations.isProtected("169.254.0.0/16"))
        XCTAssertTrue(ProtectedDestinations.isProtected("224.0.0.0/4"))
        XCTAssertTrue(ProtectedDestinations.isProtected("255.255.255.255"))
    }

    // MARK: - Ordinary traffic must still be routable

    /// The policy must not become a blanket refusal — normal bypass destinations still work.
    func testOrdinaryDestinationsAreAllowed() {
        for d in ["1.1.1.1", "8.8.8.8", "140.82.121.3", "10.0.0.0/8",
                  "192.168.1.0/24", "172.16.0.0/12", "13.107.42.14"] {
            XCTAssertFalse(ProtectedDestinations.isProtected(d), "\(d) must remain routable")
        }
    }

    /// Whitespace must not be a bypass for the policy.
    func testWhitespaceDoesNotEvadeThePolicy() {
        XCTAssertTrue(ProtectedDestinations.isProtected("  100.64.0.0/10  "))
        XCTAssertTrue(ProtectedDestinations.isProtected(" 100.100.100.100 "))
    }
}
