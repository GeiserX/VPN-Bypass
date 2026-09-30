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
        for value in ["10.0.0.0/24", "10.0.0/8", "192.168.1.0/33", " 10.0.0.0/24 "] {
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
                       "10.0.0.0/24 is an IP range. The Bypass list takes domains; add ranges on the VPN Only list or as a Custom rule.")
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

    // MARK: - GUI and socket agree

    /// The same input gets the same outcome from the Domains tab (addDomain /
    /// addInverseDomain) and from `vpnb domain.add`, and saves the same value.
    func testTheSocketAnswersLikeTheGUI() async {
        let inputs: [(String, DomainList)] = [
            ("example.com", .bypass),
            ("https://news.ycombinator.com/item?id=1", .bypass),
            ("10.0.0.0/24", .bypass),
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
