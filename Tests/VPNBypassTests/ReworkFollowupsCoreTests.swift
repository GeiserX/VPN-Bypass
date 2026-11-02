// ReworkFollowupsCoreTests.swift
// The leftovers the rework's reviews found in config and lifecycle code: the global SOCKS5
// proxy's edits reaching its Proxy route, a refresh interval from config.json that would fire
// without pause, and Restart Now saying when the restart could not start. The Pause, shared CDN
// line and network profile follow-ups sit beside their own tests.

import XCTest
@testable import VPNBypassCore

@MainActor
final class GlobalProxyRouteTests: XCTestCase {

    private var rm: RouteManager { RouteManager.shared }
    private var savedConfig: RouteManager.Config!

    override func setUp() async throws {
        savedConfig = rm.config
    }

    override func tearDown() async throws {
        rm.config = savedConfig
    }

    private func proxy(_ server: String, port: Int = 1080, enabled: Bool = true) -> ProxyConfig {
        var p = ProxyConfig()
        p.enabled = enabled
        p.server = server
        p.port = port
        return p
    }

    /// A config as decoded from disk with the proxy on: `derive` made its Proxy route.
    private func derivedConfig(with p: ProxyConfig) -> Config {
        var c = Config()
        c.proxyConfig = p
        let derived = Config.derive(domains: c.domains, services: c.services, mode: c.routingMode,
                                    inverseDomains: c.inverseDomains, proxy: p)
        c.routes = derived.routes
        c.rules = derived.rules
        c.defaultRouteId = derived.defaultRouteId
        return c
    }

    private func proxyRoutes(_ c: Config) -> [Route] { c.routes.filter { $0.egress == .proxySOCKS5 } }

    /// Before, `derive` ran only on an empty route list, so an edit in General never reached
    /// the route Custom mode and the listener use.
    func testAnEditReachesTheProxyRouteTheProxyBecame() throws {
        let start = derivedConfig(with: proxy("198.51.100.7"))
        var edit = start.proxyConfig
        edit.server = "198.51.100.8"
        edit.port = 1081
        edit.username = "lab"
        edit.password = "pw"
        let next = start.withGlobalProxy(edit)
        let route = try XCTUnwrap(proxyRoutes(next).first)
        XCTAssertEqual(proxyRoutes(next).count, 1)
        XCTAssertEqual(route.name, "Proxy")
        XCTAssertEqual(route.proxyHost, "198.51.100.8")
        XCTAssertEqual(route.proxyPort, 1081)
        XCTAssertEqual(route.proxyUser, "lab")
        XCTAssertEqual(route.proxyPass, "pw")
        XCTAssertEqual(next.proxyConfig.routeId, route.id, "the link is kept for the next edit")
        XCTAssertEqual(next.proxyConfig.server, "198.51.100.8")
    }

    /// An address cleared while it is retyped leaves the route alone, and the retyped one
    /// reaches the same route: one route, never a second.
    func testRetypingTheAddressKeepsOneRoute() throws {
        var c = derivedConfig(with: proxy("198.51.100.7"))
        var p = c.proxyConfig
        p.server = ""
        c = c.withGlobalProxy(p)
        XCTAssertEqual(proxyRoutes(c).first?.proxyHost, "198.51.100.7", "an unusable address is not written")
        p.server = "198.51.100.9"
        c = c.withGlobalProxy(p)
        XCTAssertEqual(proxyRoutes(c).map(\.proxyHost), ["198.51.100.9"])
    }

    /// Off in General, its route is off; on again, back on.
    func testTheSwitchTurnsTheRouteOffAndOn() {
        var c = derivedConfig(with: proxy("198.51.100.7"))
        var p = c.proxyConfig
        p.enabled = false
        c = c.withGlobalProxy(p)
        XCTAssertEqual(proxyRoutes(c).map(\.enabled), [false])
        p.enabled = true
        c = c.withGlobalProxy(p)
        XCTAssertEqual(proxyRoutes(c).map(\.enabled), [true])
    }

    /// A proxy turned on after the routes were made gets its route; a config with no routes yet
    /// gets none, since `derive` fills that list, system routes and all.
    func testTurningTheProxyOnGivesItARoute() {
        let start = derivedConfig(with: ProxyConfig())
        XCTAssertTrue(proxyRoutes(start).isEmpty)
        let next = start.withGlobalProxy(proxy("198.51.100.7"))
        XCTAssertEqual(proxyRoutes(next).map(\.proxyHost), ["198.51.100.7"])
        XCTAssertEqual(next.proxyConfig.routeId, proxyRoutes(next).first?.id)
        XCTAssertTrue(Config().withGlobalProxy(proxy("198.51.100.7")).routes.isEmpty)
    }

    /// A SOCKS5 route the user made on the Routes page is never the global proxy's.
    func testARouteTheUserMadeIsLeftAlone() {
        var c = derivedConfig(with: proxy("198.51.100.7"))
        let mine = Route(name: "Mine", egress: .proxySOCKS5, proxyHost: "203.0.113.5", proxyPort: 1080)
        c.routes.append(mine)
        var p = c.proxyConfig
        p.server = "198.51.100.8"
        p.enabled = false
        let next = c.withGlobalProxy(p)
        XCTAssertEqual(next.routes.first { $0.id == mine.id }, mine)
    }

    /// A config read from disk links the Proxy route `derive` made, so a Routes-page edit of
    /// its address survives a General toggle: no second route, the edited address kept.
    func testTheDecodedProxyRouteStaysLinkedAfterARoutesPageEdit() throws {
        var legacy = Config()
        legacy.proxyConfig = proxy("198.51.100.7")
        legacy.routes = []
        var c = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(legacy))
        let route = try XCTUnwrap(proxyRoutes(c).first)
        XCTAssertEqual(c.proxyConfig.routeId, route.id)
        let i = try XCTUnwrap(c.routes.firstIndex { $0.id == route.id })
        c.routes[i].proxyHost = "198.51.100.20"   // edited on the Routes page
        var p = c.proxyConfig
        p.enabled = false
        c = c.withGlobalProxy(p)
        p.enabled = true
        c = c.withGlobalProxy(p)
        XCTAssertEqual(proxyRoutes(c).map(\.proxyHost), ["198.51.100.20"])
        XCTAssertEqual(proxyRoutes(c).map(\.enabled), [true])
    }

    /// The linked route retyped on the Routes page is the user's: General leaves it alone.
    func testALinkedRouteRetypedIsLeftAlone() throws {
        var c = derivedConfig(with: proxy("198.51.100.7"))
        c = c.withGlobalProxy(c.proxyConfig)   // links it
        let id = try XCTUnwrap(c.proxyConfig.routeId)
        let i = try XCTUnwrap(c.routes.firstIndex { $0.id == id })
        c.routes[i].egress = .direct
        let retyped = c.routes[i]
        var p = c.proxyConfig
        p.enabled = false
        c = c.withGlobalProxy(p)
        XCTAssertEqual(c.routes.first { $0.id == id }, retyped)
    }

    /// From before the link, two SOCKS5 routes on the proxy's address: neither is known to be
    /// the proxy's, so neither is changed.
    func testTwoRoutesOnTheProxyAddressAreBothLeftAlone() {
        var c = derivedConfig(with: proxy("198.51.100.7"))
        let twin = Route(name: "Twin", egress: .proxySOCKS5, proxyHost: "198.51.100.7", proxyPort: 1080)
        c.routes.insert(twin, at: 0)
        let before = c.routes
        var p = c.proxyConfig
        p.server = "198.51.100.8"
        c = c.withGlobalProxy(p)
        XCTAssertEqual(c.routes.filter { before.contains($0) }.count, before.count, "a route was rewritten")
    }

    /// General's fields go through the app, which saves the route with the proxy.
    func testTheAppKeepsTheRouteInStep() {
        rm.config = derivedConfig(with: proxy("198.51.100.7"))
        rm.updateGlobalProxy { $0.server = "198.51.100.8" }
        XCTAssertEqual(rm.config.proxyConfig.server, "198.51.100.8")
        XCTAssertEqual(proxyRoutes(rm.config).map(\.proxyHost), ["198.51.100.8"])
    }
}

final class RefreshIntervalNormalizationTests: XCTestCase {

    private func decoded(interval: Any) throws -> Config {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any])
        json["dnsRefreshInterval"] = interval
        return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Zero or less in config.json would make the refresh timer fire without pause.
    func testZeroOrLessBecomesTheDefault() throws {
        XCTAssertEqual(try decoded(interval: 0).dnsRefreshInterval, 3600)
        XCTAssertEqual(try decoded(interval: -60).dnsRefreshInterval, 3600)
        XCTAssertEqual(try decoded(interval: 900).dnsRefreshInterval, 900, "a real interval is kept")
        XCTAssertEqual(try decoded(interval: 10).dnsRefreshInterval, 10, "a short one too: only <= 0 is broken")
    }
}

@MainActor
final class RestartNowTests: XCTestCase {

    private struct NoWaiter: LocalizedError {
        var errorDescription: String? { "the waiter did not start" }
    }

    /// Before, a restart that could not start only wrote a log line: the app stayed open in
    /// the old language with nothing on screen.
    func testARestartThatCannotStartIsShown() throws {
        XCTAssertEqual(GeneralPage.restartNow({ throw NoWaiter() }),
                       "VPN Bypass could not restart itself (the waiter did not start). Quit it and open it again to use the new language.")
        XCTAssertNil(GeneralPage.restartNow({ }), "a restart under way shows nothing")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["es", "fr"] {
            let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
            let line = try XCTUnwrap(GeneralPage.restartNow({ throw NoWaiter() }, in: bundle))
            XCTAssertTrue(line.contains("the waiter did not start"), line)
            XCTAssertFalse(line.hasPrefix("VPN Bypass could not"), "\(language): \(line)")
            XCTAssertNotEqual(String(localized: "Restart Failed", bundle: bundle), "Restart Failed")
        }
    }
}
