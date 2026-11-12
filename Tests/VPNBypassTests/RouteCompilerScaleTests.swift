// RouteCompilerScaleTests.swift
// The compiler at the size of a country list: its speed, and the same first-match result as before.

import XCTest
@testable import VPNBypassCore

/// A country of tens of thousands of ranges compiles in about linear time, with the same first-match
/// result as checking each range against every earlier one.
final class RouteCompilerScaleTests: XCTestCase {

    private let direct = Route(name: "Direct", egress: .direct)
    private let proxy = Route(name: "Proxy", egress: .proxySOCKS5)

    func testACountrySizedRuleCompilesQuickly() {
        let ranges = (0..<40_000).map { (value: "\(20 + $0 / 65_536).\($0 / 256 % 256).\($0 % 256).0/24", isNetwork: true) }
        let rule = Rule(matchType: .geoip, pattern: "aa", routeId: direct.id, order: 0)
        let start = CFAbsoluteTimeGetCurrent()
        let compiled = RouteCompiler.compile(resolvedRules: [(rule: rule, dests: ranges)], routes: [direct],
                                             localGateway: "192.0.2.1", ifaceGatewayForRoute: { _ in nil })
        let seconds = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(compiled.count, 40_000)
        XCTAssertLessThan(seconds, 5, "compiling 40,000 ranges took \(seconds) s")
    }

    func testFirstMatchByContainmentIsUnchanged() {
        var generator = SystemRandomNumberGenerator()
        var rules: [(rule: Rule, dests: [(value: String, isNetwork: Bool)])] = []
        for order in 0..<6 {
            let dests = (0..<400).map { _ -> (value: String, isNetwork: Bool) in
                // Inside 11.0.0.0/18, so that ranges hold one another often.
                let prefix = Int.random(in: 18...32, using: &generator)
                let a = 0x0B00_0000 | UInt32.random(in: 0...0x3FFF, using: &generator) << 2
                let ip = "\(a >> 24 & 0xFF).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
                return prefix == 32 && Bool.random(using: &generator) ? (ip, false) : ("\(ip)/\(prefix)", true)
            } + [(value: "2001:db8::1", isNetwork: false)]
            rules.append((rule: Rule(matchType: .cidr, pattern: "r\(order)", routeId: order == 2 ? proxy.id : direct.id, order: order),
                          dests: dests))
        }
        let compiled = RouteCompiler.compile(resolvedRules: rules, routes: [direct, proxy], localGateway: "192.0.2.1",
                                             ifaceGatewayForRoute: { _ in nil })
        XCTAssertEqual(compiled.map { "\($0.source)|\($0.destination)" }, reference(rules))
    }

    /// Each destination against every earlier claim, as the compiler did before.
    private func reference(_ rules: [(rule: Rule, dests: [(value: String, isNetwork: Bool)])]) -> [String] {
        func parse(_ dest: String) -> (UInt32, Int)? {
            let parts = dest.split(separator: "/")
            let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
            guard octets.count == 4 else { return nil }
            let prefix = parts.count == 2 ? Int(parts[1])! : 32
            let addr = octets.reduce(0) { $0 << 8 | $1 }
            return (prefix == 0 ? 0 : addr & ~UInt32(0) << UInt32(32 - prefix), prefix)
        }
        var v4: [(UInt32, Int)] = []
        var raw: Set<String> = []
        var out: [String] = []
        for entry in rules {
            for dest in entry.dests {
                if let (network, prefix) = parse(dest.value) {
                    let held = v4.contains { outer in
                        outer.1 <= prefix && (outer.1 == 0 ? 0 : network & ~UInt32(0) << UInt32(32 - outer.1)) == outer.0
                    }
                    if held { continue }
                    v4.append((network, prefix))
                } else if !raw.insert(dest.value).inserted {
                    continue
                }
                if entry.rule.routeId == direct.id { out.append("\(entry.rule.pattern)|\(dest.value)") }
            }
        }
        return out
    }
}
