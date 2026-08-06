// RouteCIDRTests.swift
// Coverage for the CIDR helpers the privileged helper uses to decide whether a NETWORK route is
// already installed correctly (#65).
//
// Why this matters more than it looks: `routeAlreadyCorrect` skips the kernel write when the route
// already matches. For network routes it compares `route -n get -net <cidr>`'s `destination:` and
// `mask:` against these two functions' output. If `netmaskString` is wrong, the comparison fails
// forever (harmless churn) — but if `parse` accepts a non-canonical prefix and yields a DIFFERENT
// value than the caller intended, the helper can conclude "already correct" about a route that is
// not the one requested, and silently skip installing it. In VPN Only mode the routes in question
// are the `0.0.0.0/1` + `128.0.0.0/1` catch-alls, so a wrong skip there is a traffic leak.

import XCTest
@testable import VPNBypassCore

final class RouteCIDRTests: XCTestCase {

    // MARK: - netmaskString

    /// The two VPN Only catch-alls are /1 routes; `route` prints their mask as 128.0.0.0.
    func testNetmaskForCatchAllHalfSpaces() {
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: 1), "128.0.0.0")
    }

    func testNetmaskForCommonPrefixes() {
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: 8), "255.0.0.0")
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: 16), "255.255.0.0")
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: 24), "255.255.255.0")
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: 32), "255.255.255.255")
    }

    /// `route(8)` prints a /0 as "default", not "0.0.0.0" — comparing against the wrong spelling
    /// would never match.
    func testNetmaskForZeroPrefixIsDefault() {
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: 0), "default")
    }

    func testNetmaskRejectsOutOfRangePrefix() {
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: 33), "default")
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: -1), "default")
    }

    // MARK: - parse

    func testParseSplitsNetworkAndPrefix() {
        let parsed = RouteCIDR.parse("10.0.0.0/8")
        XCTAssertEqual(parsed?.network, "10.0.0.0")
        XCTAssertEqual(parsed?.prefixLength, 8)
    }

    func testParseHandlesTheCatchAlls() {
        XCTAssertEqual(RouteCIDR.parse("0.0.0.0/1")?.prefixLength, 1)
        XCTAssertEqual(RouteCIDR.parse("128.0.0.0/1")?.network, "128.0.0.0")
    }

    /// A non-canonical prefix must be REJECTED rather than silently normalised. "/08" parsing as 8
    /// would make the helper compare against a mask the caller never asked for, and a match there
    /// means skipping a write that was needed.
    func testParseRejectsNonCanonicalPrefix() {
        XCTAssertNil(RouteCIDR.parse("10.0.0.0/08"))
        XCTAssertNil(RouteCIDR.parse("10.0.0.0/+8"))
        XCTAssertNil(RouteCIDR.parse("10.0.0.0/ 8"))
    }

    func testParseRejectsOutOfRangePrefix() {
        XCTAssertNil(RouteCIDR.parse("10.0.0.0/33"))
        XCTAssertNil(RouteCIDR.parse("10.0.0.0/-1"))
    }

    func testParseRejectsMalformedNetwork() {
        XCTAssertNil(RouteCIDR.parse("10.0.0/8"))          // three octets
        XCTAssertNil(RouteCIDR.parse("10.0.0.256/8"))      // octet out of range
        XCTAssertNil(RouteCIDR.parse("10.0.0.01/8"))       // non-canonical octet
        XCTAssertNil(RouteCIDR.parse("notanip/8"))
    }

    func testParseRejectsMissingOrExtraPrefix() {
        XCTAssertNil(RouteCIDR.parse("10.0.0.0"))          // a host, not a CIDR
        XCTAssertNil(RouteCIDR.parse("10.0.0.0/8/8"))
        XCTAssertNil(RouteCIDR.parse("10.0.0.0/"))
    }

    /// End-to-end shape of what the helper actually compares: for each catch-all, the pair
    /// (network, mask) must equal what `route -n get -net` reports for an installed route.
    func testCatchAllsProduceTheExactPairRouteWouldPrint() {
        guard let low = RouteCIDR.parse("0.0.0.0/1"), let high = RouteCIDR.parse("128.0.0.0/1") else {
            return XCTFail("catch-alls must parse")
        }
        XCTAssertEqual(low.network, "0.0.0.0")
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: low.prefixLength), "128.0.0.0")
        XCTAssertEqual(high.network, "128.0.0.0")
        XCTAssertEqual(RouteCIDR.netmaskString(prefixLength: high.prefixLength), "128.0.0.0")
    }
}
