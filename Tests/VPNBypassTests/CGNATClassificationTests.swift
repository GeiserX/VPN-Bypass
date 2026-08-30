// CGNATClassificationTests.swift
// Who owns a 100.64/10 address — issue #99.
//
// CGNAT is shared ground: Tailscale, NetBird, Netmaker, Twingate, Zscaler and Cloudflare WARP
// all hand out addresses in it, so the address alone proves nothing. The decision has three
// inputs, and conflating two of them is what broke NetBird detection: "Tailscale could not
// answer" and "there is no Tailscale here to ask" are not the same fact.

import XCTest
@testable import VPNBypassCore

final class CGNATClassificationTests: XCTestCase {

    /// The #99 case. No Tailscale anywhere on the machine, so a CGNAT tunnel belongs to
    /// something else by elimination — NetBird on utun100, Netmaker, Twingate, a self-hosted
    /// WireGuard mesh. This used to come back undetermined and the tunnel was dropped, which
    /// is why "VPN-Bypass does not detect my NetBird connection" was true.
    func testNoTailscaleOnTheMachineMeansTheAddressIsSomebodyElses() {
        XCTAssertEqual(
            RouteManager.classifyCGNAT(tailscaleRunning: false, statusAnswered: false, statusClaimsAddress: false),
            .notTailscale,
            "with no Tailscale process, no CGNAT address here can be Tailscale's"
        )
    }

    /// The #61 safety property, unchanged: Tailscale is up but its status query failed or timed
    /// out, so we genuinely do not know. Claiming another tool's tunnel is never the safe
    /// default — this must stay undetermined, which the caller treats as "not the VPN".
    func testTailscaleRunningButSilentStaysUndetermined() {
        XCTAssertEqual(
            RouteManager.classifyCGNAT(tailscaleRunning: true, statusAnswered: false, statusClaimsAddress: false),
            .undetermined,
            "a running Tailscale that cannot be queried must still fail closed"
        )
    }

    /// Tailscale answered and claims the address: it is Tailscale's, whatever else is running.
    func testTailscaleClaimingTheAddressWins() {
        XCTAssertEqual(
            RouteManager.classifyCGNAT(tailscaleRunning: true, statusAnswered: true, statusClaimsAddress: true),
            .tailscale
        )
    }

    /// Tailscale answered and disclaims the address — a different CGNAT VPN really is the
    /// tunnel. This is the pre-existing happy path and must not change.
    func testTailscaleDisclaimingTheAddressMeansAnotherVPN() {
        XCTAssertEqual(
            RouteManager.classifyCGNAT(tailscaleRunning: true, statusAnswered: true, statusClaimsAddress: false),
            .notTailscale
        )
    }

    /// An authoritative answer outranks process presence in both directions, so a stale or
    /// mis-scraped process list can never override what Tailscale itself said.
    func testAnAnswerAlwaysOutranksProcessPresence() {
        XCTAssertEqual(
            RouteManager.classifyCGNAT(tailscaleRunning: false, statusAnswered: true, statusClaimsAddress: true),
            .tailscale,
            "if Tailscale claims the address it is Tailscale's, however the process scan read"
        )
        XCTAssertEqual(
            RouteManager.classifyCGNAT(tailscaleRunning: false, statusAnswered: true, statusClaimsAddress: false),
            .notTailscale
        )
    }

    /// Every combination is decided; none falls through to a surprise default.
    func testTheDecisionTableIsTotal() {
        for running in [true, false] {
            for answered in [true, false] {
                for claims in [true, false] {
                    let got = RouteManager.classifyCGNAT(
                        tailscaleRunning: running, statusAnswered: answered, statusClaimsAddress: claims)
                    let want: RouteManager.CGNATIdentity =
                        answered ? (claims ? .tailscale : .notTailscale)
                                 : (running ? .undetermined : .notTailscale)
                    XCTAssertEqual(got, want, "running=\(running) answered=\(answered) claims=\(claims)")
                }
            }
        }
    }

    // MARK: - Reading the process list

    /// The listing has to have succeeded before its silence means anything.
    func testASuccessfulListingWithoutTailscaleMeansAbsent() {
        XCTAssertFalse(RouteManager.tailscaleAppearsRunning(
            psOutput: "/sbin/launchd\n/usr/sbin/netbird\n", psExitCode: 0))
    }

    func testASuccessfulListingNamingAnyTailscaleVariantMeansPresent() {
        for comm in [
            "/usr/local/bin/tailscaled",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/Library/SystemExtensions/X/io.tailscale.ipn.macsys.network-extension",
            "/Library/SystemExtensions/X/io.tailscale.ipn.macos.network-extension",
        ] {
            XCTAssertTrue(RouteManager.tailscaleAppearsRunning(psOutput: "/sbin/launchd\n\(comm)\n", psExitCode: 0),
                          "\(comm) must read as Tailscale present")
        }
    }

    /// A truncated or killed `ps` mentions Tailscale no more than an honest absence does.
    /// Reading that as "absent" would adopt an unverified CGNAT tunnel — possibly Tailscale's
    /// own — as the corporate VPN, which is the failure #61 exists to prevent.
    func testAFailedListingIsNotEvidenceOfAbsence() {
        XCTAssertTrue(RouteManager.tailscaleAppearsRunning(psOutput: "", psExitCode: 1),
                      "a nonzero exit means we could not look, not that Tailscale is gone")
        XCTAssertTrue(RouteManager.tailscaleAppearsRunning(psOutput: "/sbin/launchd\n", psExitCode: 137),
                      "a killed ps must not be read as a clean negative")
        XCTAssertTrue(RouteManager.tailscaleAppearsRunning(psOutput: nil, psExitCode: nil),
                      "no result at all must fail closed")
    }

    /// The two halves compose: a failed listing keeps the address undetermined rather than
    /// handing it to the corporate-VPN path.
    func testAFailedListingLeavesTheAddressUndetermined() {
        let running = RouteManager.tailscaleAppearsRunning(psOutput: nil, psExitCode: nil)
        XCTAssertEqual(
            RouteManager.classifyCGNAT(tailscaleRunning: running, statusAnswered: false, statusClaimsAddress: false),
            .undetermined
        )
    }
}
