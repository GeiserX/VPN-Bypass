// AddDomainOutcomeTests.swift
// What an add to the Bypass or VPN Only list says back: RouteManager.checkDomainInput,
// the result addDomain / addInverseDomain return, the line the Domains tab shows under
// its field, and the control socket giving the same answer as the GUI for the same input.
// The VPN is never connected here, so no add touches the kernel; the config is restored
// after each test, as in ClassicControlTests.

import XCTest
@testable import VPNBypassCore

@MainActor
final class AddDomainOutcomeTests: XCTestCase {

    private var savedConfig: RouteManager.Config!
    private var savedLogs: [RouteManager.LogEntry] = []
    private var savedVPNConnected = false

    private var rm: RouteManager { RouteManager.shared }

    override func setUp() async throws {
        savedConfig = rm.config
        savedLogs = rm.recentLogs
        savedVPNConnected = rm.isVPNConnected
        rm.isVPNConnected = false
        resetLists()
    }

    override func tearDown() async throws {
        rm.config = savedConfig
        rm.recentLogs = savedLogs
        rm.isVPNConnected = savedVPNConnected
        rm.cancelAllRetries()
    }

    private func resetLists() {
        var cfg = RouteManager.Config()
        cfg.routingMode = .bypass
        cfg.manageHostsFile = false
        cfg.domains = []
        cfg.inverseDomains = []
        rm.config = cfg
    }

    // MARK: - checkDomainInput

    func testBypassListRefusesAnIPRangeInsteadOfSavingItsFirstAddress() {
        // IPv6 and a space before the "/" used to get through: cleanDomain cut them to
        // "2001", "fd00" and "10.0.0.0".
        for value in ["10.0.0.0/24", "10.0.0/8", "192.168.1.0/33", " 10.0.0.0/24 ",
                      "10.0.0.0 /24", "2001:db8::/32", "fd00::/8", "::ffff:10.0.0.0/104"] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(rm.checkDomainInput(value, list: .bypass), .failure(.rangeOnBypassList(input: trimmed)), value)
        }
    }

    func testBypassListStillTakesAPastedLink() {
        let cases: [(String, String)] = [
            ("https://news.ycombinator.com/item?id=1", "news.ycombinator.com"),
            ("example.com/page", "example.com"),
            ("https://10.0.0.1/admin", "10.0.0.1"),
            ("user@Example.COM:443", "example.com"),
            ("example.com:8080/page", "example.com"),
            ("cafe.be:80/menu", "cafe.be"),
        ]
        for (typed, saved) in cases {
            XCTAssertEqual(rm.checkDomainInput(typed, list: .bypass),
                           .success(CheckedDomainInput(value: saved, isCIDR: false)), typed)
        }
    }

    func testNothingUsableLeftIsEmpty() {
        XCTAssertEqual(rm.checkDomainInput("!!!", list: .bypass), .failure(.empty(input: "!!!")))
        XCTAssertEqual(rm.checkDomainInput("   ", list: .bypass), .failure(.empty(input: "")))
        XCTAssertEqual(rm.checkDomainInput("!!!", list: .vpnOnly), .failure(.empty(input: "!!!")))
    }

    func testVPNOnlyListTakesAValidRangeAndNamesWhatIsWrongWithABadOne() {
        XCTAssertEqual(rm.checkDomainInput("10.1.0.0/16", list: .vpnOnly),
                       .success(CheckedDomainInput(value: "10.1.0.0/16", isCIDR: true)))
        XCTAssertEqual(rm.checkDomainInput("Corp.Example.com", list: .vpnOnly),
                       .success(CheckedDomainInput(value: "corp.example.com", isCIDR: false)))
        for value in ["10.0.0.0/33", "10.0.0/8", "not/cidr", "010.0.0.0/8"] {
            XCTAssertEqual(rm.checkDomainInput(value, list: .vpnOnly), .failure(.malformedRange(input: value)), value)
        }
        for value in ["0.0.0.0/0", "128.0.0.0/1"] {
            XCTAssertEqual(rm.checkDomainInput(value, list: .vpnOnly), .failure(.catchAllRange(input: value)), value)
        }
    }

    // MARK: - addDomain / addInverseDomain

    func testAddDomainSavesTheCleanedNameAndSaysWhereItCameFrom() throws {
        let added = try rm.addDomain("  https://News.YCombinator.com/item?id=1  ").get()
        XCTAssertEqual(added.entry.domain, "news.ycombinator.com")
        XCTAssertEqual(added.list, .bypass)
        XCTAssertEqual(added.rewrittenFrom, "https://News.YCombinator.com/item?id=1")
        XCTAssertEqual(rm.config.domains.map(\.domain), ["news.ycombinator.com"])
        XCTAssertEqual(rm.config.domains.first?.id, added.entry.id, "the result is the entry that was saved")
    }

    func testAddDomainWithACaseChangeOnlyIsNotARewrite() throws {
        let added = try rm.addDomain("Example.COM").get()
        XCTAssertNil(added.rewrittenFrom)
    }

    func testAddDomainDuplicateFailsAndSavesNothing() {
        rm.addDomain("en.wikipedia.org")
        XCTAssertEqual(rm.addDomain("EN.wikipedia.org"),
                       .failure(.alreadyListed(value: "en.wikipedia.org", list: .bypass)))
        XCTAssertEqual(rm.config.domains.count, 1)
    }

    /// The bug behind proposal 5: "10.0.0.0/24" used to be saved as the host 10.0.0.0.
    func testAddDomainRefusesARangeAndSavesNothing() {
        XCTAssertEqual(rm.addDomain("10.0.0.0/24"), .failure(.rangeOnBypassList(input: "10.0.0.0/24")))
        XCTAssertTrue(rm.config.domains.isEmpty, "saved \(rm.config.domains.map(\.domain))")
    }

    func testAddInverseDomainReturnsTheRangeOrWhyNot() throws {
        let range = try rm.addInverseDomain("10.0.0.0/8").get()
        XCTAssertTrue(range.entry.isCIDR)
        XCTAssertEqual(range.list, .vpnOnly)
        XCTAssertEqual(rm.addInverseDomain("10.0.0.0/8"), .failure(.alreadyListed(value: "10.0.0.0/8", list: .vpnOnly)))
        XCTAssertEqual(rm.addInverseDomain("0.0.0.0/0"), .failure(.catchAllRange(input: "0.0.0.0/0")))
        XCTAssertEqual(rm.config.inverseDomains.map(\.domain), ["10.0.0.0/8"])
        XCTAssertTrue(rm.config.domains.isEmpty, "the Bypass list is untouched")
    }

    // MARK: - The line under the field

    func testMessagesNameWhatWasSavedOrWhyNot() {
        let entry = DomainEntry(domain: "news.ycombinator.com")
        XCTAssertEqual(AddedDomain(entry: entry, list: .bypass, typed: "https://news.ycombinator.com/item?id=1").message,
                       "Added news.ycombinator.com, from the link you pasted.")
        XCTAssertEqual(AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass, typed: "user@example.com:443").message,
                       "Added example.com, cleaned up from \u{201C}user@example.com:443\u{201D}.")
        XCTAssertEqual(AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass, typed: "example.com").message,
                       "Added example.com to your Bypass list.")
        XCTAssertEqual(AddedDomain(entry: DomainEntry(domain: "10.0.0.0/24", isCIDR: true), list: .vpnOnly, typed: "10.0.0.0/24").message,
                       "Added the range 10.0.0.0/24 to your VPN Only list.")

        XCTAssertEqual(AddDomainError.alreadyListed(value: "en.wikipedia.org", list: .bypass).message,
                       "en.wikipedia.org is already on your Bypass list.")
        XCTAssertEqual(AddDomainError.rangeOnBypassList(input: "10.0.0.0/24").message,
                       "10.0.0.0/24 is an IP range. The Bypass list takes domains; to send a range around the VPN, add it as a rule on the Direct route in Custom mode.")
        XCTAssertFalse(AddDomainError.rangeOnBypassList(input: "10.0.0.0/24").message.contains("VPN Only"),
                       "the VPN Only list sends a range through the VPN, the opposite of bypassing it")
        XCTAssertEqual(AddDomainError.empty(input: "!!!").message, "\u{201C}!!!\u{201D} is not a domain name.")
        XCTAssertEqual(AddDomainError.empty(input: "").message, "Type a domain first.")
        XCTAssertTrue(AddDomainError.malformedRange(input: "10.0.0.0/33").message.hasPrefix("10.0.0.0/33 is not an IP range"))
        XCTAssertTrue(AddDomainError.catchAllRange(input: "0.0.0.0/0").message.contains("/2 to /32"))
    }

    func testAFailedAddKeepsTheTextAndASavedOneEmptiesTheField() {
        let failed = AddDomainFeedback(.failure(.alreadyListed(value: "en.wikipedia.org", list: .bypass)),
                                       typed: "en.wikipedia.org")
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.fieldText, "en.wikipedia.org", "the text stays so it can be fixed")
        XCTAssertEqual(failed.message, "en.wikipedia.org is already on your Bypass list.")

        let saved = AddDomainFeedback(.success(AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass,
                                                            typed: "example.com")),
                                      typed: "example.com")
        XCTAssertFalse(saved.isError)
        XCTAssertEqual(saved.fieldText, "")
        XCTAssertEqual(saved.message, "Added example.com to your Bypass list.")
    }

    // MARK: - The line in Spanish and French

    /// A language folder from the source tree; a test run has no app bundle to take it from.
    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testTheLineUnderTheFieldIsTranslated() throws {
        let en = try lproj("en"), es = try lproj("es"), fr = try lproj("fr")

        XCTAssertEqual(AddDomainError.alreadyListed(value: "en.wikipedia.org", list: .vpnOnly).message(in: es),
                       "en.wikipedia.org ya está en tu lista Solo VPN.")
        XCTAssertEqual(AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass, typed: "user@example.com:443").message(in: fr),
                       "example.com ajouté, nettoyé à partir de « user@example.com:443 ».")
        XCTAssertEqual(AddDomainError.rangeOnBypassList(input: "10.0.0.0/24").message(in: en),
                       AddDomainError.rangeOnBypassList(input: "10.0.0.0/24").message)

        let errors: [AddDomainError] = [
            .empty(input: ""), .empty(input: "!!!"), .rangeOnBypassList(input: "10.0.0.0/24"),
            .malformedRange(input: "10.0.0.0/33"), .catchAllRange(input: "0.0.0.0/0"),
            .alreadyListed(value: "example.com", list: .bypass),
            .ruleExists(value: "example.com", route: Route(name: "Direct", egress: .direct), vpnName: nil),
            .ruleExists(value: "example.com", route: Route(name: "Work Proxy", egress: .proxyHTTP), vpnName: nil),
        ]
        let added: [AddedDomain] = [
            AddedDomain(entry: DomainEntry(domain: "10.0.0.0/24", isCIDR: true), list: .vpnOnly, typed: "10.0.0.0/24"),
            AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass, typed: "example.com"),
            AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass, typed: "https://example.com/a"),
            AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass, typed: "user@example.com"),
        ]
        let english = errors.map { $0.message(in: en) } + added.map { $0.message(in: en) }
        for (name, bundle) in [("es", es), ("fr", fr)] {
            let translated = errors.map { $0.message(in: bundle) } + added.map { $0.message(in: bundle) }
            for (line, original) in zip(translated, english) {
                XCTAssertNotEqual(line, original, "\(name) has no translation for: \(original)")
                XCTAssertFalse(line.contains("%"), "\(name) left a placeholder in: \(line)")
            }
        }
    }

    // MARK: - The menu bar quick-add

    func testQuickAddStaysOpenOnARefusalAndClosesOnASave() {
        let refused = MenuContent.quickAdd(after: .failure(.rangeOnBypassList(input: "10.0.0.0/24")), typed: "10.0.0.0/24")
        XCTAssertTrue(refused.isOpen, "closing would look like it worked")
        XCTAssertEqual(refused.text, "10.0.0.0/24")
        XCTAssertEqual(refused.error?.message, AddDomainError.rangeOnBypassList(input: "10.0.0.0/24").message)

        let saved = MenuContent.quickAdd(after: .success(AddedDomain(entry: DomainEntry(domain: "example.com"), list: .bypass,
                                                                    typed: "example.com")), typed: "example.com")
        XCTAssertEqual(saved, .closed)
        XCTAssertEqual(MenuContent.quickAdd(after: nil, typed: "example.com"), .closed, "Custom mode's rule add")
    }

    // MARK: - Custom mode's quick-add

    /// A Custom-mode config with the Direct route and no rules.
    @discardableResult
    private func customWithDirect() -> Route {
        let direct = Route(name: "Direct", egress: .direct)
        var cfg = RouteManager.Config()
        cfg.routingMode = .custom
        cfg.manageHostsFile = false
        cfg.routes = [direct]
        cfg.rules = []
        rm.config = cfg
        return direct
    }

    /// The bug: "10.0.0.0/24" was saved as a `.domain` rule for the host 10.0.0.0.
    func testCustomQuickAddSavesARangeAsARangeRule() throws {
        let direct = customWithDirect()
        let rule = try XCTUnwrap(rm.addDirectRule(" 10.0.0.0/24 ")).get()
        XCTAssertEqual(rule.matchType, .cidr)
        XCTAssertEqual(rule.pattern, "10.0.0.0/24")
        XCTAssertEqual(rule.routeId, direct.id)
        XCTAssertEqual(rm.config.rules, [rule])
        XCTAssertTrue(rm.isValidCIDR(rule.pattern), "the Rules editor saves the same pattern unchanged")
        let socket = CommandRouter.apply(ControlRequest(cmd: "rule.add", args: ["match": "cidr", "pattern": rule.pattern,
                                                                                "routeId": direct.id.uuidString]),
                                         to: rm.config)
        XCTAssertTrue(socket.response.ok, "vpnb rule.add takes the same pattern")
        XCTAssertEqual(socket.config.rules.last?.matchType, .cidr)
    }

    func testCustomQuickAddSavesANameOrALinkAsADomainRule() throws {
        let cases: [(String, String)] = [
            ("Example.COM", "example.com"),
            ("https://news.ycombinator.com/item?id=1", "news.ycombinator.com"),
            ("example.com/page", "example.com"),
            ("https://10.0.0.1/admin", "10.0.0.1"),
        ]
        for (typed, saved) in cases {
            let direct = customWithDirect()
            let rule = try XCTUnwrap(rm.addDirectRule(typed), typed).get()
            XCTAssertEqual(rule.matchType, .domain, typed)
            XCTAssertEqual(rule.pattern, saved, typed)
            XCTAssertEqual(rule.routeId, direct.id, typed)
            XCTAssertEqual(rm.config.rules, [rule], typed)
        }
    }

    func testCustomQuickAddRefusesABadRangeAndSavesNothing() {
        let cases: [(String, AddDomainError)] = [
            ("10.0.0.0/33", .malformedRange(input: "10.0.0.0/33")),
            ("10.0.0/8", .malformedRange(input: "10.0.0/8")),
            ("010.0.0.0/8", .malformedRange(input: "010.0.0.0/8")),
            ("10.0.0.0 /24", .malformedRange(input: "10.0.0.0 /24")),
            ("2001:db8::/32", .malformedRange(input: "2001:db8::/32")),
            ("0.0.0.0/0", .catchAllRange(input: "0.0.0.0/0")),
            ("128.0.0.0/1", .catchAllRange(input: "128.0.0.0/1")),
            ("!!!", .empty(input: "!!!")),
        ]
        for (typed, error) in cases {
            customWithDirect()
            XCTAssertEqual(rm.addDirectRule(typed), .failure(error), typed)
            XCTAssertEqual(rm.config.rules, [], "\(typed) saved \(rm.config.rules.map(\.pattern))")
            XCTAssertEqual(rm.config.domains, [], typed)
            XCTAssertEqual(rm.config.inverseDomains, [], typed)
            if typed.contains("/") {
                XCTAssertFalse(rm.isValidCIDR(typed), "the Rules editor refuses \(typed) too")
            }
        }
    }

    func testCustomQuickAddRefusalStaysOpenWithTheLine() {
        customWithDirect()
        let refusal = rm.addDirectRule("10.0.0.0/33")
        guard case .failure(let error)? = refusal else { return XCTFail("not refused: \(String(describing: refusal))") }
        let state = MenuContent.quickAdd(after: .failure(error), typed: "10.0.0.0/33")
        XCTAssertTrue(state.isOpen)
        XCTAssertEqual(state.text, "10.0.0.0/33")
        XCTAssertEqual(state.error?.message, AddDomainError.malformedRange(input: "10.0.0.0/33").message)
    }

    /// A repeat used to close the field as if it had saved.
    func testCustomQuickAddRefusesARepeatAndSaysSo() {
        let direct = customWithDirect()
        _ = rm.addDirectRule("10.0.0.0/24")
        let error = AddDomainError.ruleExists(value: "10.0.0.0/24", route: direct, vpnName: rm.vpnType?.knownName)
        XCTAssertEqual(rm.addDirectRule("10.0.0.0/24"), .failure(error))
        XCTAssertEqual(rm.config.rules.map(\.pattern), ["10.0.0.0/24"])
        XCTAssertEqual(error.message, "10.0.0.0/24 already has a rule on the Direct route.")
        let state = MenuContent.quickAdd(after: .failure(error), typed: "10.0.0.0/24")
        XCTAssertTrue(state.isOpen, "closing would look like it saved")
        XCTAssertEqual(state.text, "10.0.0.0/24")
    }

    /// A rule on another route matches first, so a Direct rule after it would do nothing.
    func testCustomQuickAddRefusesAPatternAnotherRouteHas() {
        let direct = customWithDirect()
        let proxy = Route(name: "Work Proxy", egress: .proxyHTTP)
        let vpn = Route(name: "", egress: .vpnDefault)
        rm.config.routes = [direct, proxy, vpn]
        let theirs = [Rule(matchType: .cidr, pattern: "10.0.0.0/24", routeId: vpn.id, order: 0),
                      Rule(matchType: .domain, pattern: "example.com", routeId: proxy.id, order: 1)]
        rm.config.rules = theirs
        let vpnName = rm.vpnType?.knownName

        XCTAssertEqual(rm.addDirectRule("10.0.0.0/24"),
                       .failure(.ruleExists(value: "10.0.0.0/24", route: vpn, vpnName: vpnName)))
        let link = rm.addDirectRule("https://example.com/page")
        XCTAssertEqual(link, .failure(.ruleExists(value: "example.com", route: proxy, vpnName: vpnName)))
        XCTAssertEqual(rm.config.rules, theirs, "no second rule")

        guard case .failure(let error)? = link else { return XCTFail("not refused") }
        XCTAssertEqual(error.message, "example.com already has a rule on the Work Proxy route, and the first matching rule wins. To send it direct, change that rule's route on the Rules page.")
        XCTAssertTrue(MenuContent.quickAdd(after: .failure(error), typed: "https://example.com/page").isOpen)
    }

    /// A rule whose route was deleted matches nothing, so it does not block the add.
    func testCustomQuickAddIgnoresARuleWhoseRouteIsGone() throws {
        customWithDirect()
        let orphan = Rule(matchType: .cidr, pattern: "10.0.0.0/24", routeId: UUID(), order: 0)
        rm.config.rules = [orphan]
        let rule = try XCTUnwrap(rm.addDirectRule("10.0.0.0/24")).get()
        XCTAssertEqual(rm.config.rules, [orphan, rule])
    }

    // MARK: - GUI and socket agree

    /// The same input gets the same outcome from the Domains tab (addDomain /
    /// addInverseDomain) and from `vpnb domain.add`, and saves the same value.
    func testTheSocketAnswersLikeTheGUI() async {
        let inputs: [(String, DomainList)] = [
            ("example.com", .bypass),
            ("https://news.ycombinator.com/item?id=1", .bypass),
            ("10.0.0.0/24", .bypass),
            ("10.0.0.0 /24", .bypass),
            ("2001:db8::/32", .bypass),
            ("example.com:8080/page", .bypass),
            ("!!!", .bypass),
            ("10.1.0.0/16", .vpnOnly),
            ("10.0.0.0/33", .vpnOnly),
            ("0.0.0.0/1", .vpnOnly),
            ("corp.example.com", .vpnOnly),
        ]
        for (value, list) in inputs {
            resetLists()
            let gui = list == .bypass ? rm.addDomain(value) : rm.addInverseDomain(value)
            let guiSaved = (list == .bypass ? rm.config.domains : rm.config.inverseDomains).map(\.domain)

            resetLists()
            let socket = await ControlSurface.handle(ControlRequest(cmd: "domain.add",
                                                                   args: ["domain": value, "list": list.rawValue]))
            let socketSaved = (list == .bypass ? rm.config.domains : rm.config.inverseDomains).map(\.domain)

            let guiOK: Bool
            if case .success = gui { guiOK = true } else { guiOK = false }
            XCTAssertEqual(socket.ok, guiOK, "\(value) on \(list)")
            XCTAssertEqual(socketSaved, guiSaved, "\(value) on \(list)")
        }
    }
}
