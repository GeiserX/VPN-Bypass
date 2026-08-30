// TunnelOwnershipTests.swift
// Naming a tunnel by its owner instead of its address — issue #101.
//
// The fixtures here are not invented. They are the rows a real sweep produced on a Mac mini
// (macOS 26.6.1, arm64) with Tailscale connected and a root-owned CGNAT tunnel held open by a
// process of known name and pid, whose own `getsockopt(UTUN_OPT_IFNAME)` gave the ground truth
// this file asserts against.

import XCTest
@testable import VPNBypassCore

final class TunnelOwnershipTests: XCTestCase {

    // MARK: - Control unit ↔ interface

    /// Ground truth from hardware: a process created `utun5` and reported its own name back
    /// through the socket, while the sweep saw its control unit as 6.
    func testControlUnitSixIsInterfaceUtunFive() {
        XCTAssertEqual(TunnelOwnership.interfaceName(forControlUnit: 6), "utun5")
    }

    /// The same off-by-one across the range, including the Apple-owned low units observed on
    /// both machines: rapportd on unit 1 held utun0.
    func testTheMappingIsConsistentlyOffByOne() {
        XCTAssertEqual(TunnelOwnership.interfaceName(forControlUnit: 1), "utun0")
        XCTAssertEqual(TunnelOwnership.interfaceName(forControlUnit: 3), "utun2")
        XCTAssertEqual(TunnelOwnership.interfaceName(forControlUnit: 100), "utun99")
    }

    /// Unit 0 means "kernel, choose for me" and is never a live tunnel's identity, so it must
    /// not silently become `utun-1`.
    func testUnitZeroIsNotATunnel() {
        XCTAssertNil(TunnelOwnership.interfaceName(forControlUnit: 0))
    }

    // MARK: - Resolving multiple holders

    /// The NetworkExtension broker holds the same control socket as the extension it started,
    /// so a tunnel really does have two holders. Observed on both machines: unit 3 held by
    /// Tailscale's extension AND by nesessionmanager. Attributing it to the broker would label
    /// every NE-based VPN identically, which is worse than not labelling at all.
    func testTheBrokerNeverWinsOverTheRealOwner() {
        let resolved = TunnelOwnership.resolve([
            (unit: 3, pid: 193, processName: "nesessionmanager", executablePath: "/usr/libexec/nesessionmanager"),
            (unit: 3, pid: 543, processName: "io.tailscale.ipn.macsys.network",
             executablePath: "/Library/SystemExtensions/X/io.tailscale.ipn.macsys.network-extension"),
        ])
        XCTAssertEqual(resolved["utun2"]?.processName, "io.tailscale.ipn.macsys.network")
        XCTAssertEqual(resolved["utun2"]?.pid, 543)
    }

    /// A broker on its own still identifies a tunnel. Knowing one exists beats dropping it.
    func testABrokerAloneStillReportsTheTunnel() {
        let resolved = TunnelOwnership.resolve([
            (unit: 4, pid: 193, processName: "nesessionmanager", executablePath: "/usr/libexec/nesessionmanager"),
        ])
        XCTAssertEqual(resolved["utun3"]?.processName, "nesessionmanager")
    }

    /// One process can hold several tunnels — identityservicesd held units 2, 4 and 5 on the
    /// mini — and each must resolve to its own interface rather than collapsing.
    func testOneProcessHoldingSeveralTunnelsKeepsThemSeparate() {
        let resolved = TunnelOwnership.resolve([
            (unit: 2, pid: 452, processName: "identityservicesd", executablePath: "/usr/libexec/identityservicesd"),
            (unit: 4, pid: 452, processName: "identityservicesd", executablePath: "/usr/libexec/identityservicesd"),
            (unit: 5, pid: 452, processName: "identityservicesd", executablePath: "/usr/libexec/identityservicesd"),
        ])
        XCTAssertEqual(Set(resolved.keys), ["utun1", "utun3", "utun4"])
    }

    /// Repeated sweeps must agree, or the label would flicker between polls.
    func testResolutionIsDeterministicWhenTwoRealOwnersTie() {
        let rows: [(unit: UInt32, pid: Int32, processName: String, executablePath: String)] = [
            (unit: 7, pid: 900, processName: "b", executablePath: "/b"),
            (unit: 7, pid: 400, processName: "a", executablePath: "/a"),
        ]
        XCTAssertEqual(TunnelOwnership.resolve(rows)["utun6"]?.pid, 400)
        XCTAssertEqual(TunnelOwnership.resolve(rows.reversed())["utun6"]?.pid, 400)
    }

    // MARK: - The real mini capture

    /// The exact rows a root sweep returned on the mini while a CGNAT tunnel was held open by
    /// pid 99197. Two tunnels that are indistinguishable by address — Tailscale's and the other
    /// one, both CGNAT — separate cleanly by owner. This is the whole point of #101.
    func testTheRealCaptureSeparatesTwoCGNATTunnelsByOwner() {
        let resolved = TunnelOwnership.resolve([
            (unit: 1, pid: 447, processName: "rapportd", executablePath: "/usr/libexec/rapportd"),
            (unit: 2, pid: 452, processName: "identityservicesd", executablePath: "/usr/libexec/identityservicesd"),
            (unit: 3, pid: 193, processName: "nesessionmanager", executablePath: "/usr/libexec/nesessionmanager"),
            (unit: 3, pid: 543, processName: "io.tailscale.ipn.macsys.network",
             executablePath: "/Library/SystemExtensions/X/io.tailscale.ipn.macsys.network-extension"),
            (unit: 6, pid: 99197, processName: "netbird-sim", executablePath: "/opt/homebrew/bin/netbird"),
        ])
        XCTAssertEqual(resolved["utun2"].map(TunnelOwnership.displayLabel), "Tailscale")
        XCTAssertEqual(resolved["utun5"].map(TunnelOwnership.displayLabel), "NetBird")
        XCTAssertEqual(resolved.count, 4)
    }

    // MARK: - Labels

    /// Every Tailscale distribution on macOS reports a different process, and all three must
    /// read as Tailscale — these strings are copied from real `ps` output.
    func testAllThreeTailscaleDistributionsAreRecognised() {
        for (name, path) in [
            ("tailscaled", "/opt/homebrew/bin/tailscaled"),
            ("io.tailscale.ipn.macsys.network", "/Library/SystemExtensions/X/io.tailscale.ipn.macsys.network-extension"),
            ("io.tailscale.ipn.macos.network", "/Library/SystemExtensions/X/io.tailscale.ipn.macos.network-extension"),
        ] {
            XCTAssertEqual(TunnelOwnership.productLabel(processName: name, executablePath: path),
                           "Tailscale", "\(name) must read as Tailscale")
        }
    }

    /// The real NetBird daemon on the mini reported exactly this.
    func testTheRealNetBirdDaemonIsRecognised() {
        XCTAssertEqual(
            TunnelOwnership.productLabel(processName: "netbird", executablePath: "/opt/homebrew/bin/netbird"),
            "NetBird"
        )
    }

    /// `cloudflared` is a very common tunnel daemon and is NOT Cloudflare WARP. The process
    /// scan this replaces matched any line containing "cloudflare", so it would have labelled
    /// it WARP. Matching the tunnel's actual owner is what makes the stricter needle safe.
    func testCloudflaredIsNotMistakenForWARP() {
        XCTAssertNil(TunnelOwnership.productLabel(processName: "cloudflared",
                                                  executablePath: "/opt/homebrew/bin/cloudflared"))
        XCTAssertEqual(TunnelOwnership.productLabel(processName: "warp-svc",
                                                   executablePath: "/Applications/Cloudflare WARP.app/warp-svc"),
                       "Cloudflare WARP")
    }

    /// An unrecognised owner still beats "VPN (utun7)" — show what the OS called it.
    func testAnUnknownOwnerFallsBackToItsProcessName() {
        let owner = TunnelOwner(interface: "utun7", pid: 5, processName: "acme-tunneld",
                                executablePath: "/usr/local/bin/acme-tunneld")
        XCTAssertEqual(TunnelOwnership.displayLabel(for: owner), "acme-tunneld")
    }

    /// And a nameless owner degrades to the interface rather than to an empty string.
    func testANamelessOwnerDegradesToTheInterface() {
        let owner = TunnelOwner(interface: "utun9", pid: 5, processName: "", executablePath: "")
        XCTAssertEqual(TunnelOwnership.displayLabel(for: owner), "VPN (utun9)")
    }

    // MARK: - XPC round trip

    /// XPC carries plists, so the struct has to survive the dictionary hop intact.
    func testOwnersSurviveTheDictionaryRoundTrip() throws {
        let original = TunnelOwner(interface: "utun5", pid: 99197, processName: "netbird",
                                   executablePath: "/opt/homebrew/bin/netbird")
        let restored = try XCTUnwrap(TunnelOwner(dictionary: original.asDictionary))
        XCTAssertEqual(restored, original)
    }

    /// A malformed payload must be rejected rather than producing a half-built owner.
    func testAMalformedPayloadIsRejected() {
        XCTAssertNil(TunnelOwner(dictionary: ["interface": "utun5"]))
        XCTAssertNil(TunnelOwner(dictionary: ["interface": "utun5", "pid": "not-a-number",
                                              "processName": "x"]))
    }

    // MARK: - Could-not-ask vs genuinely-none

    /// utun numbers are recycled. If Tailscale releases utun2 and a mesh VPN later takes it,
    /// a map that was never cleared would label the new tunnel "Tailscale". So a sweep that
    /// ran and found nothing MUST clear, even though it looks like an empty answer.
    func testAnEmptySweepClearsTheMapBecauseUtunNumbersAreRecycled() {
        let stale = ["utun2": TunnelOwner(interface: "utun2", pid: 543,
                                          processName: "io.tailscale.ipn.macsys.network",
                                          executablePath: "/Library/SystemExtensions/X")]
        XCTAssertTrue(RouteManager.mergedTunnelOwners(previous: stale, fetched: []).isEmpty,
                      "a sweep that ran and found nothing is an answer, not a failure")
    }

    /// Whereas not being able to ask — no helper, an older helper without the method, a
    /// timeout — must leave the map alone, or labels would flicker between polls.
    func testAFailedSweepKeepsThePreviousMap() {
        let known = ["utun2": TunnelOwner(interface: "utun2", pid: 543, processName: "tailscaled",
                                          executablePath: "/opt/homebrew/bin/tailscaled")]
        XCTAssertEqual(RouteManager.mergedTunnelOwners(previous: known, fetched: nil), known)
    }

    /// And a successful sweep replaces wholesale rather than merging, so a tunnel that went
    /// away leaves no trace behind for a recycled number to inherit.
    func testASuccessfulSweepReplacesRatherThanMerges() {
        let stale = ["utun2": TunnelOwner(interface: "utun2", pid: 1, processName: "old",
                                          executablePath: "/old")]
        let fresh = [TunnelOwner(interface: "utun5", pid: 2, processName: "netbird",
                                 executablePath: "/opt/homebrew/bin/netbird")]
        let merged = RouteManager.mergedTunnelOwners(previous: stale, fetched: fresh)
        XCTAssertNil(merged["utun2"], "the departed tunnel must not linger")
        XCTAssertEqual(merged["utun5"].map(TunnelOwnership.displayLabel), "NetBird")
    }
}
