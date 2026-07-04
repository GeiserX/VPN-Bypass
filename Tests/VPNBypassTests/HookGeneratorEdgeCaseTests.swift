// HookGeneratorEdgeCaseTests.swift
// Additional edge-case coverage for HookGenerator, layered on top of the already-
// thorough HookGeneratorTests.swift (single-pattern PAC matching, case-insensitivity,
// empty patterns, injection neutralization): a PAC with multiple distinct patterns
// (proving ANY of them can route, not just the first), and shellExports at the
// maximum UInt16 port value.

import XCTest
import JavaScriptCore
@testable import VPNBypassCore

final class HookGeneratorEdgeCaseTests: XCTestCase {

    private func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        var str = String(data: data, encoding: .utf8)!
        str.removeFirst(); str.removeLast()
        return str
    }

    private func evalPAC(_ pac: String, host: String) -> String {
        let ctx = JSContext()!
        ctx.evaluateScript("function dnsDomainIs(host, domain){ return host.length >= domain.length && host.substring(host.length - domain.length) === domain; }")
        ctx.evaluateScript(pac)
        let r = ctx.evaluateScript("FindProxyForURL('https://example/', \(jsString(host)))")
        return r?.toString() ?? "<nil>"
    }

    /// Several distinct domain patterns are all live at once: a host matching the
    /// SECOND pattern (not just the first) must still be proxied, and a host matching
    /// neither still goes DIRECT.
    func testPacWithMultiplePatternsMatchesAnyOfThem() {
        let pac = HookGenerator.pac(port: 18102, domainPatterns: ["a.com", "b.com"])
        XCTAssertEqual(evalPAC(pac, host: "a.com"), "PROXY 127.0.0.1:18102", "matches the first pattern")
        XCTAssertEqual(evalPAC(pac, host: "sub.b.com"), "PROXY 127.0.0.1:18102", "matches the second pattern as a sub-domain")
        XCTAssertEqual(evalPAC(pac, host: "other.com"), "DIRECT", "matches neither")
    }

    /// The maximum UInt16 port value must be embedded correctly, with no truncation or
    /// overflow surprises in the generated proxy URL.
    func testShellExportsWithMaxPortValue() {
        let s = HookGenerator.shellExports(port: 65535)
        XCTAssertTrue(s.contains("HTTPS_PROXY=\"http://127.0.0.1:65535\""))
        XCTAssertTrue(s.contains("HTTP_PROXY=\"http://127.0.0.1:65535\""))
    }
}
