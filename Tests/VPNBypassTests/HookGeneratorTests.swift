// HookGeneratorTests.swift
// Coverage for the route-on shell exports + the browser PAC (P1, VPN-Bypass-3sc.8).
// The PAC is evaluated with JavaScriptCore so we test its real routing behavior,
// not just its text.

import XCTest
import JavaScriptCore
@testable import VPNBypassCore

final class HookGeneratorTests: XCTestCase {

    func testShellExportsContainsListenerAndNoProxy() {
        let s = HookGenerator.shellExports(port: 18101)
        XCTAssertTrue(s.contains("HTTPS_PROXY=\"http://127.0.0.1:18101\""))
        XCTAssertTrue(s.contains("http_proxy=\"http://127.0.0.1:18101\""))
        XCTAssertTrue(s.contains("NO_PROXY=\"localhost,127.0.0.1,::1\""))
    }

    // MARK: - PAC behavior (evaluated with JavaScriptCore)

    /// Encode a Swift string as a JS string literal (via a JSON array, stripped).
    private func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        var str = String(data: data, encoding: .utf8)!  // ["..."]
        str.removeFirst(); str.removeLast()
        return str
    }

    private func evalPAC(_ pac: String, host: String) -> String {
        let ctx = JSContext()!
        // Standard PAC helper: true when host ends with domain.
        ctx.evaluateScript("function dnsDomainIs(host, domain){ return host.length >= domain.length && host.substring(host.length - domain.length) === domain; }")
        ctx.evaluateScript(pac)
        let r = ctx.evaluateScript("FindProxyForURL('https://example/', \(jsString(host)))")
        return r?.toString() ?? "<nil>"
    }

    func testPacRoutesMatchingHostsAndDirectsOthers() {
        let pac = HookGenerator.pac(port: 18101, domainPatterns: ["example.com"])
        XCTAssertEqual(evalPAC(pac, host: "example.com"), "PROXY 127.0.0.1:18101")
        XCTAssertEqual(evalPAC(pac, host: "api.example.com"), "PROXY 127.0.0.1:18101")
        XCTAssertEqual(evalPAC(pac, host: "deep.api.example.com"), "PROXY 127.0.0.1:18101")
        XCTAssertEqual(evalPAC(pac, host: "notexample.com"), "DIRECT")
        XCTAssertEqual(evalPAC(pac, host: "other.com"), "DIRECT")
    }

    func testPacIsCaseInsensitive() {
        let pac = HookGenerator.pac(port: 1, domainPatterns: ["Example.COM"])
        XCTAssertEqual(evalPAC(pac, host: "API.Example.com"), "PROXY 127.0.0.1:1")
    }

    func testEmptyPatternsAllDirect() {
        let pac = HookGenerator.pac(port: 1, domainPatterns: [])
        XCTAssertEqual(evalPAC(pac, host: "anything.com"), "DIRECT")
    }

    /// A malicious pattern must be neutralized by JSON-encoding — it can neither
    /// break the script nor grant a blanket match.
    func testPatternInjectionIsNeutralized() {
        let pac = HookGenerator.pac(port: 1, domainPatterns: ["\"]; return \"PROXY evil:1\"; //"])
        XCTAssertEqual(evalPAC(pac, host: "victim.com"), "DIRECT")
    }
}
