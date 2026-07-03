// CommandRouterTests.swift
// Coverage for the pure scripting/control-surface router: every verb, every
// error code, and — the load-bearing property — that no secret (password or
// username) ever appears in an ENCODED ControlResponse, even though the
// returned Config does carry it for the (future) socket layer to persist.

import XCTest
@testable import VPNBypassCore

final class CommandRouterTests: XCTestCase {

    // MARK: - status / route.list (read-only)

    func testStatusIsReadOnlyAndReportsListenerPorts() {
        let r1 = Route(name: "A", egress: .direct)
        let r2 = Route(name: "B", egress: .proxySOCKS5, proxyHost: "h", proxyPort: 1)
        var config = RouteManager.Config()
        config.routes = [r1, r2]
        config.defaultRouteId = r1.id
        config.routingMode = .vpnOnly
        config.schemaVersion = 2

        let ports: [UUID: UInt16] = [r2.id: 18042]
        let (updated, response) = CommandRouter.apply(ControlRequest(cmd: "status"), to: config, listenerPorts: ports)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.mode, "vpnOnly")
        XCTAssertEqual(response.result?.defaultRouteId, r1.id)
        XCTAssertEqual(response.result?.schemaVersion, 2)
        XCTAssertEqual(response.result?.supportedVersion, 1)
        XCTAssertEqual(response.result?.routes?.count, 2)
        XCTAssertEqual(response.result?.routes?.first { $0.id == r2.id }?.listenerPort, 18042)
        XCTAssertNil(response.result?.routes?.first { $0.id == r1.id }?.listenerPort)

        // Read-only: config comes back unchanged.
        XCTAssertEqual(updated.routes, config.routes)
        XCTAssertEqual(updated.rules, config.rules)
        XCTAssertEqual(updated.defaultRouteId, config.defaultRouteId)
        XCTAssertEqual(updated.routingMode, config.routingMode)
    }

    func testRouteListIsReadOnlyAndReportsListenerPorts() {
        let r1 = Route(name: "Proxy", egress: .proxyHTTP, proxyHost: "h", proxyPort: 1)
        var config = RouteManager.Config()
        config.routes = [r1]

        let (updated, response) = CommandRouter.apply(ControlRequest(cmd: "route.list"), to: config, listenerPorts: [r1.id: 18100])

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.routes?.count, 1)
        XCTAssertEqual(response.result?.routes?.first?.listenerPort, 18100)
        XCTAssertEqual(updated.routes, config.routes, "route.list must not mutate config")
    }

    // MARK: - route.set

    func testRouteSetRepointsHostAndPortWithoutLeakingPassword() throws {
        let route = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "old.example.com", proxyPort: 8000,
                           proxyUser: "orig-user", proxyPass: "orig-secret-pass")
        var config = RouteManager.Config()
        config.routes = [route]

        let req = ControlRequest(cmd: "route.set", args: ["id": route.id.uuidString, "host": "new.example.com", "port": "9001"])
        let (updated, response) = CommandRouter.apply(req, to: config)

        XCTAssertTrue(response.ok)
        XCTAssertNil(response.error)
        XCTAssertEqual(updated.routes.first?.proxyHost, "new.example.com")
        XCTAssertEqual(updated.routes.first?.proxyPort, 9001)
        XCTAssertEqual(updated.routes.first?.proxyPass, "orig-secret-pass", "untouched password preserved in config")

        let sanitized = response.result?.routes?.first
        XCTAssertEqual(sanitized?.proxyHost, "new.example.com")
        XCTAssertEqual(sanitized?.proxyPort, 9001)
        XCTAssertTrue(sanitized?.hasPassword ?? false)
        XCTAssertTrue(sanitized?.hasProxyUser ?? false)
        XCTAssertEqual(response.result?.listenerPort, sanitized?.listenerPort)

        let json = String(data: try JSONEncoder().encode(response), encoding: .utf8)!
        XCTAssertFalse(json.contains("orig-secret-pass"))
        XCTAssertFalse(json.contains("orig-user"))
    }

    func testRouteSetUpdatesPasswordViaSecretsWithoutEchoingIt() throws {
        let route = Route(name: "Proxy", egress: .proxySOCKS5, proxyHost: "h", proxyPort: 1, proxyUser: "u", proxyPass: "old-pass")
        var config = RouteManager.Config()
        config.routes = [route]

        let req = ControlRequest(cmd: "route.set", args: ["id": route.id.uuidString], secrets: ["pass": "new-super-secret"])
        let (updated, response) = CommandRouter.apply(req, to: config)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(updated.routes.first?.proxyPass, "new-super-secret", "config DOES receive the new secret")
        XCTAssertTrue(response.result?.routes?.first?.hasPassword ?? false)

        let json = String(data: try JSONEncoder().encode(response), encoding: .utf8)!
        XCTAssertFalse(json.contains("new-super-secret"), "response JSON must never carry the secret")
    }

    func testRouteSetInvalidPortReturnsErrorAndDoesNotMutate() {
        let route = Route(name: "Proxy", egress: .proxySOCKS5)
        var config = RouteManager.Config()
        config.routes = [route]

        let req = ControlRequest(cmd: "route.set", args: ["id": route.id.uuidString, "port": "70000"])
        let (updated, response) = CommandRouter.apply(req, to: config)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_port")
        XCTAssertEqual(updated.routes, config.routes)
    }

    func testRouteSetUnknownIdReturnsNotFound() {
        let config = RouteManager.Config()
        let req = ControlRequest(cmd: "route.set", args: ["id": UUID().uuidString, "host": "x"])
        let (updated, response) = CommandRouter.apply(req, to: config)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "not_found")
        XCTAssertEqual(updated.routes, config.routes)
    }

    // MARK: - route.enable / route.disable

    func testRouteEnableAndDisableFlipEnabled() {
        let route = Route(name: "R", egress: .direct, enabled: false)
        var config = RouteManager.Config()
        config.routes = [route]

        let (afterEnable, enableResp) = CommandRouter.apply(ControlRequest(cmd: "route.enable", args: ["id": route.id.uuidString]), to: config)
        XCTAssertTrue(enableResp.ok)
        XCTAssertTrue(afterEnable.routes.first!.enabled)
        XCTAssertEqual(enableResp.result?.routes?.first?.enabled, true)

        let (afterDisable, disableResp) = CommandRouter.apply(ControlRequest(cmd: "route.disable", args: ["id": route.id.uuidString]), to: afterEnable)
        XCTAssertTrue(disableResp.ok)
        XCTAssertFalse(afterDisable.routes.first!.enabled)

        let (unchanged, notFoundResp) = CommandRouter.apply(ControlRequest(cmd: "route.enable", args: ["id": UUID().uuidString]), to: config)
        XCTAssertEqual(notFoundResp.error?.code, "not_found")
        XCTAssertEqual(unchanged.routes, config.routes)
    }

    // MARK: - route.add

    func testRouteAddCreatesRouteWithNewIdAndStoresPasswordWithoutEchoingIt() throws {
        let config = RouteManager.Config()
        XCTAssertTrue(config.routes.isEmpty)

        let req = ControlRequest(
            cmd: "route.add",
            args: ["name": "US Oxylabs", "type": "socks5", "host": "pr.oxylabs.io", "port": "7777", "user": "cust-user"],
            secrets: ["pass": "top-secret-pass"]
        )
        let (updated, response) = CommandRouter.apply(req, to: config)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(updated.routes.count, 1)
        let created = updated.routes[0]
        XCTAssertEqual(created.name, "US Oxylabs")
        XCTAssertEqual(created.egress, .proxySOCKS5)
        XCTAssertEqual(created.proxyHost, "pr.oxylabs.io")
        XCTAssertEqual(created.proxyPort, 7777)
        XCTAssertEqual(created.proxyPass, "top-secret-pass", "config DOES store the secret")

        let sanitized = response.result?.routes?.first
        XCTAssertEqual(sanitized?.id, created.id, "response carries the newly-generated id")
        XCTAssertTrue(sanitized?.hasPassword ?? false)
        XCTAssertTrue(sanitized?.hasProxyUser ?? false)

        let json = String(data: try JSONEncoder().encode(response), encoding: .utf8)!
        XCTAssertFalse(json.contains("top-secret-pass"), "response JSON must never carry the secret")
        XCTAssertFalse(json.contains("cust-user"), "response JSON must never carry the raw username either")
    }

    func testRouteAddMissingNameIsInvalidArgsAndUnrecognizedTypeDefaultsToHTTP() {
        let config = RouteManager.Config()

        let (unchanged, badResp) = CommandRouter.apply(ControlRequest(cmd: "route.add"), to: config)
        XCTAssertEqual(badResp.error?.code, "invalid_args")
        XCTAssertTrue(unchanged.routes.isEmpty)

        let (withRoute, okResp) = CommandRouter.apply(ControlRequest(cmd: "route.add", args: ["name": "Plain"]), to: config)
        XCTAssertTrue(okResp.ok)
        XCTAssertEqual(withRoute.routes.first?.egress, .proxyHTTP, "absent/unrecognized type defaults to HTTP proxy")
    }

    // MARK: - route.rm

    func testRouteRemoveCascadesToRulesAndClearsDefault() {
        let route = Route(name: "Doomed", egress: .direct)
        let survivor = Route(name: "Keeper", egress: .vpnDefault)
        var config = RouteManager.Config()
        config.routes = [route, survivor]
        config.rules = [
            Rule(matchType: .domain, pattern: "a.com", routeId: route.id, order: 0),
            Rule(matchType: .domain, pattern: "b.com", routeId: survivor.id, order: 1)
        ]
        config.defaultRouteId = route.id

        let (updated, response) = CommandRouter.apply(ControlRequest(cmd: "route.rm", args: ["id": route.id.uuidString]), to: config)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(updated.routes.map(\.id), [survivor.id])
        XCTAssertEqual(updated.rules.map(\.pattern), ["b.com"], "rule referencing the removed route is cascaded away")
        XCTAssertNil(updated.defaultRouteId, "default pointed at the removed route, so it is cleared")
    }

    func testRouteRemoveUnknownIdReturnsNotFound() {
        let config = RouteManager.Config()
        let (updated, response) = CommandRouter.apply(ControlRequest(cmd: "route.rm", args: ["id": UUID().uuidString]), to: config)
        XCTAssertEqual(response.error?.code, "not_found")
        XCTAssertEqual(updated.routes, config.routes)
    }

    // MARK: - rule.add / rule.rm

    func testRuleAddRejectsNonexistentRouteId() {
        let config = RouteManager.Config()
        let req = ControlRequest(cmd: "rule.add", args: ["match": "domain", "pattern": "x.com", "routeId": UUID().uuidString])
        let (updated, response) = CommandRouter.apply(req, to: config)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "not_found")
        XCTAssertTrue(updated.rules.isEmpty)
    }

    /// A typo'd CIDR (missing an octet, out-of-range bits, ...) would otherwise be
    /// accepted and then silently never match anything under RuleResolver.
    func testRuleAddRejectsMalformedCIDRPatternAndDoesNotMutate() {
        let route = Route(name: "R", egress: .direct)
        var config = RouteManager.Config()
        config.routes = [route]

        for badPattern in ["10.0.0/8", "10.0.0.0/33", "10.0.0.0/-1", "not-a-cidr", "10.0.0.0"] {
            let req = ControlRequest(cmd: "rule.add", args: ["match": "cidr", "pattern": badPattern, "routeId": route.id.uuidString])
            let (updated, response) = CommandRouter.apply(req, to: config)

            XCTAssertFalse(response.ok, "expected \(badPattern) to be rejected")
            XCTAssertEqual(response.error?.code, "invalid_args")
            XCTAssertTrue(updated.rules.isEmpty, "malformed pattern \(badPattern) must not create a rule")
        }
    }

    func testRuleAddRejectsMalformedIPPatternAndDoesNotMutate() {
        let route = Route(name: "R", egress: .direct)
        var config = RouteManager.Config()
        config.routes = [route]

        for badPattern in ["10.0.0.999", "10.0.0", "10.0.0.0.1", "not-an-ip"] {
            let req = ControlRequest(cmd: "rule.add", args: ["match": "ip", "pattern": badPattern, "routeId": route.id.uuidString])
            let (updated, response) = CommandRouter.apply(req, to: config)

            XCTAssertFalse(response.ok, "expected \(badPattern) to be rejected")
            XCTAssertEqual(response.error?.code, "invalid_args")
            XCTAssertTrue(updated.rules.isEmpty, "malformed pattern \(badPattern) must not create a rule")
        }
    }

    func testRuleAddAcceptsWellFormedIPAndCIDRPatterns() {
        let route = Route(name: "R", egress: .direct)
        var config = RouteManager.Config()
        config.routes = [route]

        let (afterIP, ipResp) = CommandRouter.apply(
            ControlRequest(cmd: "rule.add", args: ["match": "ip", "pattern": "10.0.0.5", "routeId": route.id.uuidString]),
            to: config
        )
        XCTAssertTrue(ipResp.ok)
        XCTAssertEqual(afterIP.rules.first?.pattern, "10.0.0.5")

        let (afterCIDR, cidrResp) = CommandRouter.apply(
            ControlRequest(cmd: "rule.add", args: ["match": "cidr", "pattern": "10.0.0.0/8", "routeId": route.id.uuidString]),
            to: afterIP
        )
        XCTAssertTrue(cidrResp.ok)
        XCTAssertEqual(afterCIDR.rules.last?.pattern, "10.0.0.0/8")
    }

    func testRuleAddAppendsWithIncrementingOrderAndRuleRemoveDeletes() {
        let route = Route(name: "R", egress: .direct)
        var config = RouteManager.Config()
        config.routes = [route]
        config.rules = [Rule(matchType: .domain, pattern: "existing.com", routeId: route.id, order: 5)]

        let (afterAdd, addResp) = CommandRouter.apply(
            ControlRequest(cmd: "rule.add", args: ["match": "suffix", "pattern": "new.com", "routeId": route.id.uuidString]),
            to: config
        )
        XCTAssertTrue(addResp.ok)
        let added = try! XCTUnwrap(afterAdd.rules.first { $0.pattern == "new.com" })
        XCTAssertEqual(added.order, 6, "appended after the max existing order")
        XCTAssertEqual(addResp.result?.rules?.first?.id, added.id)

        let (afterRemove, removeResp) = CommandRouter.apply(ControlRequest(cmd: "rule.rm", args: ["id": added.id.uuidString]), to: afterAdd)
        XCTAssertTrue(removeResp.ok)
        XCTAssertEqual(afterRemove.rules.map(\.pattern), ["existing.com"])

        let (unchanged, notFoundResp) = CommandRouter.apply(ControlRequest(cmd: "rule.rm", args: ["id": UUID().uuidString]), to: afterRemove)
        XCTAssertEqual(notFoundResp.error?.code, "not_found")
        XCTAssertEqual(unchanged.rules, afterRemove.rules)
    }

    // MARK: - mode / default

    func testModeSetsBypassAndVpnOnlyAndRejectsGarbage() {
        var config = RouteManager.Config()
        config.routingMode = .bypass

        let (toVpnOnly, resp1) = CommandRouter.apply(ControlRequest(cmd: "mode", args: ["mode": "vpnOnly"]), to: config)
        XCTAssertTrue(resp1.ok)
        XCTAssertEqual(toVpnOnly.routingMode, .vpnOnly)
        XCTAssertEqual(resp1.result?.mode, "vpnOnly")

        let (backToBypass, resp2) = CommandRouter.apply(ControlRequest(cmd: "mode", args: ["mode": "bypass"]), to: toVpnOnly)
        XCTAssertTrue(resp2.ok)
        XCTAssertEqual(backToBypass.routingMode, .bypass)

        let (unchanged, resp3) = CommandRouter.apply(ControlRequest(cmd: "mode", args: ["mode": "custom"]), to: backToBypass)
        XCTAssertEqual(resp3.error?.code, "invalid_args")
        XCTAssertEqual(unchanged.routingMode, .bypass, "rejected mode must not mutate config")
    }

    func testDefaultSetsDefaultRouteIdAndRejectsUnknownId() {
        let route = Route(name: "R", egress: .direct)
        var config = RouteManager.Config()
        config.routes = [route]

        let (updated, response) = CommandRouter.apply(ControlRequest(cmd: "default", args: ["routeId": route.id.uuidString]), to: config)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(updated.defaultRouteId, route.id)
        XCTAssertEqual(response.result?.defaultRouteId, route.id)

        let (unchanged, badResponse) = CommandRouter.apply(ControlRequest(cmd: "default", args: ["routeId": UUID().uuidString]), to: config)
        XCTAssertEqual(badResponse.error?.code, "not_found")
        XCTAssertNil(unchanged.defaultRouteId)
    }

    // MARK: - isMutating

    /// Pins the classification of every verb `apply()` currently switches on, so
    /// an edit that moves a verb into the wrong branch (or typos a case string)
    /// fails here instead of silently under/over-persisting+reconciling.
    func testIsMutatingClassifiesEveryKnownVerbCorrectly() {
        let readVerbs = ["status", "route.list", "rule.list"]
        let writeVerbs = [
            "route.set", "route.enable", "route.disable", "route.rm", "route.add",
            "rule.add", "rule.rm", "mode", "default"
        ]

        for verb in readVerbs {
            XCTAssertFalse(CommandRouter.isMutating(verb), "\(verb) must be classified as read-only")
        }
        for verb in writeVerbs {
            XCTAssertTrue(CommandRouter.isMutating(verb), "\(verb) must be classified as mutating")
        }
    }

    // MARK: - envelope errors

    func testUnknownCommandReturnsError() {
        let config = RouteManager.Config()
        let (updated, response) = CommandRouter.apply(ControlRequest(cmd: "route.teleport"), to: config)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_command")
        XCTAssertEqual(updated.routes, config.routes)
    }

    func testUnsupportedVersionReturnsError() {
        let config = RouteManager.Config()
        let (updated, response) = CommandRouter.apply(ControlRequest(v: 2, cmd: "status"), to: config)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unsupported_version")
        XCTAssertEqual(updated.routes, config.routes)
    }

    // MARK: - secrets never leak, across verbs

    func testSecretsNeverAppearInAnyEncodedResponse() throws {
        let existing = Route(name: "Existing", egress: .proxySOCKS5, proxyHost: "h", proxyPort: 1,
                              proxyUser: "existing-user-marker", proxyPass: "existing-pass-marker")
        var config = RouteManager.Config()
        config.routes = [existing]

        let secretMarkers = ["existing-user-marker", "existing-pass-marker", "added-pass-marker", "set-pass-marker"]

        let responses: [ControlResponse] = [
            CommandRouter.apply(ControlRequest(cmd: "status"), to: config).response,
            CommandRouter.apply(ControlRequest(cmd: "route.list"), to: config).response,
            CommandRouter.apply(
                ControlRequest(cmd: "route.set", args: ["id": existing.id.uuidString], secrets: ["pass": "set-pass-marker"]),
                to: config
            ).response,
            CommandRouter.apply(
                ControlRequest(cmd: "route.add", args: ["name": "New"], secrets: ["pass": "added-pass-marker"]),
                to: config
            ).response
        ]

        for response in responses {
            let json = String(data: try JSONEncoder().encode(response), encoding: .utf8)!
            for marker in secretMarkers {
                XCTAssertFalse(json.contains(marker), "response leaked secret marker \(marker): \(json)")
            }
        }
    }
}
