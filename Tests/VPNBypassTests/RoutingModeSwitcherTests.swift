// RoutingModeSwitcherTests.swift
// Coverage for the Settings window's Mode menu and the sheet it opens (RoutingModeSwitcher.swift).
//
// The problem it locks down: the routing mode used to sit above the page buttons in the same
// green pills, so a click meant to open the VPN Only page asked to switch the whole Mac. Now
// the mode is a menu in the title bar, a pick only opens a sheet, and the sheet says what each
// mode does with the user's own lists before anything changes.

import AppKit
import XCTest
@testable import VPNBypassCore

@MainActor
final class RoutingModeSwitcherTests: XCTestCase {

    private func lists(_ edit: (inout RoutingModeCopy.Lists) -> Void = { _ in }) -> RoutingModeCopy.Lists {
        var l = RoutingModeCopy.Lists(current: .bypass, bypassServices: 4, bypassDomains: 2,
                                      vpnOnlyEntries: 3, rules: 0, listsBecomeRules: true)
        edit(&l)
        return l
    }

    // MARK: Sheet wording

    func testSheetLinesMatchTheMockup() {
        XCTAssertEqual(RoutingModeCopy.sheetLine(.bypass, lists: lists()),
                       "Everything uses the VPN except what you list. 4 services and 2 domains.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.vpnOnly, lists: lists()),
                       "Only what you list uses the VPN; everything else goes direct. 3 entries.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.custom, lists: lists()),
                       "Send each destination through a route you pick: direct, a VPN, a proxy or a Tailscale peer. Your lists become rules.")
    }

    func testBypassCountsSingularsAndEmptyLists() {
        let prefix = "Everything uses the VPN except what you list. "
        XCTAssertEqual(RoutingModeCopy.sheetLine(.bypass, lists: lists { $0.bypassServices = 1; $0.bypassDomains = 1 }),
                       prefix + "1 service and 1 domain.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.bypass, lists: lists { $0.bypassDomains = 0 }),
                       prefix + "4 services.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.bypass, lists: lists { $0.bypassServices = 0; $0.bypassDomains = 1 }),
                       prefix + "1 domain.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.bypass, lists: lists { $0.bypassServices = 0; $0.bypassDomains = 0 }),
                       prefix + "Nothing listed yet.")
    }

    func testVPNOnlyCounts() {
        let prefix = "Only what you list uses the VPN; everything else goes direct. "
        XCTAssertEqual(RoutingModeCopy.sheetLine(.vpnOnly, lists: lists { $0.vpnOnlyEntries = 1 }), prefix + "1 entry.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.vpnOnly, lists: lists { $0.vpnOnlyEntries = 0 }), prefix + "Nothing listed yet.")
    }

    func testCustomSaysRulesOnlyWhenNoMigrationWillHappen() {
        let prefix = "Send each destination through a route you pick: direct, a VPN, a proxy or a Tailscale peer. "
        XCTAssertEqual(RoutingModeCopy.sheetLine(.custom, lists: lists { $0.listsBecomeRules = false; $0.rules = 5 }), prefix + "5 rules.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.custom, lists: lists { $0.listsBecomeRules = false; $0.rules = 1 }), prefix + "1 rule.")
        XCTAssertEqual(RoutingModeCopy.sheetLine(.custom, lists: lists { $0.listsBecomeRules = false; $0.rules = 0 }), prefix + "No rules yet.")
    }

    // MARK: Reading the config

    func testListsCountOnlyEnabledEntriesPerMode() {
        var c = RouteManager.Config()
        c.routingMode = .vpnOnly
        c.services = [ServiceEntry(id: "a", name: "A", enabled: true, domains: [], ipRanges: []),
                      ServiceEntry(id: "b", name: "B", enabled: false, domains: [], ipRanges: [])]
        c.domains = [DomainEntry(domain: "x.com"), DomainEntry(domain: "y.com", enabled: false)]
        c.inverseDomains = [DomainEntry(domain: "corp.example"), DomainEntry(domain: "off.example", enabled: false),
                            DomainEntry(domain: "wiki.example")]
        c.rules = []
        let l = RoutingModeCopy.lists(from: c)
        XCTAssertEqual(l.current, .vpnOnly)
        XCTAssertEqual(l.bypassServices, 1)
        XCTAssertEqual(l.bypassDomains, 1)
        XCTAssertEqual(l.vpnOnlyEntries, 2)
        XCTAssertEqual(l.rules, 0)
        XCTAssertTrue(l.listsBecomeRules)
    }

    /// "Your lists become rules" must say exactly when `setRoutingMode(.custom)` derives rules:
    /// `Config.preparedForCustomMode` builds them only with no rules yet and something to route.
    func testListsBecomeRulesAgreesWithPreparedForCustomMode() {
        func config(domains: [DomainEntry]) -> RouteManager.Config {
            var c = RouteManager.Config()
            c.routingMode = .bypass
            c.services = c.services.map { var s = $0; s.enabled = false; return s }
            c.domains = domains
            c.inverseDomains = []
            c.rules = []
            return c
        }
        let withList = config(domains: [DomainEntry(domain: "x.com")])
        let empty = config(domains: [])
        // Rules already built by an earlier visit to Custom, then back in Bypass.
        var withRules = withList.preparedForCustomMode()
        withRules.routingMode = .bypass
        XCTAssertFalse(withRules.rules.isEmpty, "the fixture needs rules")

        for c in [withList, empty, withRules] {
            let rulesWereBuilt = c.rules.isEmpty && !c.preparedForCustomMode().rules.isEmpty
            XCTAssertEqual(RoutingModeCopy.lists(from: c).listsBecomeRules, rulesWereBuilt,
                           "rules=\(c.rules.count) domains=\(c.domains.count)")
        }
        XCTAssertTrue(RoutingModeCopy.lists(from: withList).listsBecomeRules)

        // Already in Custom, switching to Custom does nothing, so nothing is about to become rules.
        var inCustom = withList
        inCustom.routingMode = .custom
        XCTAssertFalse(RoutingModeCopy.lists(from: inCustom).listsBecomeRules)
    }

    // MARK: Menu and sheet decisions

    func testPickingTheCurrentModeOpensNoSheet() {
        XCTAssertNil(RoutingModeCopy.sheetSelection(forPick: .bypass, current: .bypass))
        XCTAssertEqual(RoutingModeCopy.sheetSelection(forPick: .vpnOnly, current: .bypass), .vpnOnly)
        XCTAssertEqual(RoutingModeCopy.sheetSelection(forPick: .custom, current: .vpnOnly), .custom)
    }

    func testSwitchOnlyActsOnADifferentMode() {
        XCTAssertFalse(RoutingModeCopy.canSwitch(to: .vpnOnly, from: .vpnOnly))
        XCTAssertTrue(RoutingModeCopy.canSwitch(to: .bypass, from: .vpnOnly))
    }

    func testMenuChecksTheCurrentModeAndListsAllThree() {
        let menu = RoutingModeMenu(current: .vpnOnly) { _ in }
        XCTAssertEqual(menu.menu.items.map(\.title), ["Bypass", "VPN Only", "Custom Routes"])
        XCTAssertEqual(menu.menu.items.map(\.state), [.off, .on, .off])
        XCTAssertTrue(menu.menu.items.allSatisfy { $0.image != nil && $0.isEnabled })
        if #available(macOS 14.4, *) {
            XCTAssertEqual(menu.menu.items.map(\.subtitle), [
                "Everything uses the VPN except what you list",
                "Only what you list uses the VPN",
                "Pick a route for each destination",
            ])
        }
    }

    func testMenuPickReportsTheModeAndChangesNothingElse() {
        var picked: [RoutingMode] = []
        let menu = RoutingModeMenu(current: .bypass) { picked.append($0) }
        // Each item fires `pick(_:)` on the menu object, which reads the mode off the item.
        for item in menu.menu.items {
            XCTAssertEqual(item.action, #selector(RoutingModeMenu.pick(_:)))
            XCTAssertTrue(item.target === menu)
        }
        menu.pick(menu.menu.items[2])
        menu.pick(menu.menu.items[0])
        XCTAssertEqual(picked, [.custom, .bypass])
        // The menu does not move its own check: the title bar keeps the mode in use until Switch.
        XCTAssertEqual(menu.menu.items.map(\.state), [.on, .off, .off])
    }

    // MARK: Translations

    func testEveryModeSwitcherStringIsTranslated() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            guard dir.pathComponents.count > 1 else { throw XCTSkip("repo root not found from \(#filePath)") }
            dir = dir.deletingLastPathComponent()
        }
        let core = dir.appendingPathComponent("Sources/VPNBypassCore")
        let source = try String(contentsOf: core.appendingPathComponent("RoutingModeSwitcher.swift"), encoding: .utf8)

        // String(localized: "…") literals, turned into lookup keys (a String interpolation is %@,
        // an Int %lld), plus the SwiftUI Text and Button literals.
        let stringLocals: Set<String> = ["services", "domains", "name(mode)"]
        let localized = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        let swiftUI = try NSRegularExpression(pattern: #"(?:Text|Button)\("((?:[^"\\]|\\.)*)""#)
        let interpolation = try NSRegularExpression(pattern: #"\\\((.*?)\)(?=[^)]|$)"#)
        var keys: [String] = []
        for regex in [localized, swiftUI] {
            for m in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                var key = String(source[Range(m.range(at: 1), in: source)!])
                for i in interpolation.matches(in: key, range: NSRange(key.startIndex..., in: key)).reversed() {
                    let expr = String(key[Range(i.range(at: 1), in: key)!])
                    key.replaceSubrange(Range(i.range, in: key)!, with: stringLocals.contains(expr) ? "%@" : "%lld")
                }
                keys.append(key)
            }
        }
        XCTAssertGreaterThan(keys.count, 20, "the scan found too few strings")
        XCTAssertTrue(keys.contains("%@ and %@."))
        XCTAssertTrue(keys.contains("%lld rules."))
        XCTAssertTrue(keys.contains("Routing mode: %@"))

        for lang in ["en", "es", "fr"] {
            let url = core.appendingPathComponent("Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys {
                XCTAssertNotNil(table[key], "\(lang).lproj has no entry for \"\(key)\"")
            }
        }
    }
}
