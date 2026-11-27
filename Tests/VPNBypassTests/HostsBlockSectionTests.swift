import XCTest
@testable import VPNBypassCore

/// The blocklist section of /etc/hosts (`HostsBlockSection`), the text work the helper runs as
/// root. Pure, so every case runs here on strings.
final class HostsBlockSectionTests: XCTestCase {

    private let start = HostsBlockSection.startMarker
    private let end = HostsBlockSection.endMarker

    private let userFile = """
        ##
        # Host Database
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost
        10.0.0.5 nas.home  # my NAS
        """ + "\n"

    private let pinned = """
        # VPN-BYPASS-MANAGED - START
        93.184.216.34 pinned.example.com
        # VPN-BYPASS-MANAGED - END
        """

    private func rewrite(_ content: String, _ names: [String]) -> String? {
        do { return try HostsBlockSection.rewritten(content, names: names) } catch {
            XCTFail("refused: \(error)")
            return nil
        }
    }

    private func sectionLines(_ content: String) -> [String] {
        var inside = false
        var out: [String] = []
        for line in content.components(separatedBy: "\n") {
            if line == start { inside = true; continue }
            if line == end { inside = false; continue }
            if inside { out.append(line) }
        }
        return out
    }

    // MARK: - Writing

    func testWritesOneZeroAddressLinePerName() throws {
        let out = try XCTUnwrap(rewrite(userFile, ["ads.example.com", "Tracker.Example.NET"]))
        XCTAssertEqual(sectionLines(out), ["0.0.0.0 ads.example.com", "0.0.0.0 tracker.example.net"])
        XCTAssertTrue(out.hasSuffix("\n\(start)\n0.0.0.0 ads.example.com\n0.0.0.0 tracker.example.net\n\(end)\n"))
        XCTAssertFalse(out.contains(":: "), "no IPv6 rows: a 0.0.0.0 row alone keeps AAAA lookups on the Mac")
    }

    func testDuplicateNamesAreWrittenOnce() throws {
        let out = try XCTUnwrap(rewrite(userFile, ["a.example.com", "A.example.com", "a.example.com"]))
        XCTAssertEqual(sectionLines(out), ["0.0.0.0 a.example.com"])
    }

    func testUserLinesAndPinnedSectionStayByteIdentical() throws {
        let file = userFile + "\n" + pinned + "\n"
        let out = try XCTUnwrap(rewrite(file, ["ads.example.com"]))
        XCTAssertTrue(out.hasPrefix(file.trimmingCharacters(in: .newlines)), "everything before the new section is unchanged")
        let removed = try XCTUnwrap(rewrite(out, []))
        XCTAssertEqual(removed, file, "removing the section gives the file back byte for byte")
    }

    func testSectionBetweenUserLinesAndPinsIsReplacedInPlace() throws {
        // The pin writer appends its section at the end, after ours.
        let first = try XCTUnwrap(rewrite(userFile, ["a.example.com"]))
        let file = first + "\n" + pinned + "\n"
        let out = try XCTUnwrap(rewrite(file, ["b.example.com"]))
        XCTAssertEqual(out, file.replacingOccurrences(of: "0.0.0.0 a.example.com", with: "0.0.0.0 b.example.com"))
        // Back and forth adds no blank lines.
        let again = try XCTUnwrap(rewrite(out, ["a.example.com"]))
        XCTAssertEqual(again, file)
        XCTAssertEqual(try XCTUnwrap(rewrite(again, [])), userFile + "\n" + pinned + "\n")
    }

    func testNameMappedOutsideTheSectionIsSkipped() throws {
        let file = userFile + "\n" + pinned + "\n"
        let out = try XCTUnwrap(rewrite(file, ["NAS.home", "pinned.example.com", "ads.example.com", "localhost.example"]))
        XCTAssertEqual(sectionLines(out), ["0.0.0.0 ads.example.com", "0.0.0.0 localhost.example"],
                       "a name the user or a pin maps stays as that line says")
    }

    func testOldSectionNamesDoNotCountAsMappedElsewhere() throws {
        let first = try XCTUnwrap(rewrite(userFile, ["a.example.com", "b.example.com"]))
        let out = try XCTUnwrap(rewrite(first, ["a.example.com", "c.example.com"]))
        XCTAssertEqual(sectionLines(out), ["0.0.0.0 a.example.com", "0.0.0.0 c.example.com"])
    }

    func testUnchangedInputReturnsNil() throws {
        let out = try XCTUnwrap(rewrite(userFile, ["a.example.com", "b.example.com"]))
        XCTAssertNil(rewrite(out, ["a.example.com", "b.example.com"]), "same set: no write, no flush")
        XCTAssertNil(rewrite(out, ["A.EXAMPLE.COM", "b.example.com", "a.example.com"]))
        XCTAssertNil(rewrite(userFile, []), "no section and nothing to block: no write")
        XCTAssertNil(rewrite(userFile, ["nas.home"]), "every name mapped elsewhere: no section, no write")
    }

    func testEmptySetRemovesBothMarkers() throws {
        let out = try XCTUnwrap(rewrite(userFile, ["a.example.com"]))
        let removed = try XCTUnwrap(rewrite(out, []))
        XCTAssertFalse(removed.contains(start))
        XCTAssertFalse(removed.contains(end))
        XCTAssertFalse(removed.contains("a.example.com"))
        XCTAssertEqual(removed, userFile)
    }

    func testSetWhoseNamesAreAllMappedElsewhereRemovesTheSection() throws {
        let out = try XCTUnwrap(rewrite(userFile, ["a.example.com"]))
        let file = out.replacingOccurrences(of: "10.0.0.5 nas.home", with: "10.0.0.5 nas.home a.example.com")
        let removed = try XCTUnwrap(rewrite(file, ["a.example.com"]))
        XCTAssertFalse(removed.contains(start))
    }

    // MARK: - Refusals

    func testOverTheCeilingRefusesTheWholeSet() {
        XCTAssertEqual(HostsBlockSection.maxNames, 200_000)
        let names = (0...HostsBlockSection.maxNames).map { "n\($0).example.com" }
        XCTAssertThrowsError(try HostsBlockSection.rewritten(userFile, names: names)) { error in
            XCTAssertEqual(error as? HostsBlockSection.Refusal, .tooManyNames(200_001))
        }
        XCTAssertNoThrow(try HostsBlockSection.rewritten(userFile, names: Array(names.dropLast())))
    }

    func testOneBadNameRefusesTheWholeSet() {
        let bad = [
            "evil.com\n1.2.3.4 bank.com", "two words.com", "tab\t.com", "nul\u{0}.com", "\r\n.com",
            "1.2.3.4", "10.0.0.1", "::1", "fe80::1", "2001:db8::1",
            "münchen.de", "пример.рф", "exa_mple.com",
            "localhost", "com", "", ".", "a..com", ".a.com", "a.com.", "-a.com", "a-.com",
            "# comment.com", "a.com#x",
            String(repeating: "a", count: 64) + ".com",
            String(repeating: "abcdefgh.", count: 28) + "com",
        ]
        for name in bad {
            XCTAssertFalse(HostsBlockSection.isValidName(name), "accepted \(name.debugDescription)")
            XCTAssertThrowsError(try HostsBlockSection.rewritten(userFile, names: ["ok.example.com", name]),
                                 "a set holding \(name.debugDescription) was written")
        }
    }

    func testValidNames() {
        for name in ["a.co", "ads.example.com", "x-y.z9.net", "0ad.com", "3com.com.example",
                     String(repeating: "a", count: 63) + ".com", "UPPER.Example.COM"] {
            XCTAssertTrue(HostsBlockSection.isValidName(name), "refused \(name)")
        }
    }

    func testRefusalMessageCannotCarryALineBreak() {
        let message = HostsBlockSection.Refusal.invalidName("a.com\n0.0.0.0 bank.com\u{7}").message
        XCTAssertFalse(message.contains("\n"))
        XCTAssertFalse(message.contains("\u{7}"))
    }

    // MARK: - The pin writer

    func testPinWriterIgnoresBlocklistNames() throws {
        let file = try XCTUnwrap(rewrite(userFile, ["ads.example.com", "pin-me.example.com"]))
        let lines = file.components(separatedBy: "\n")
        let elsewhere = HostsBlockSection.namesManagedElsewhere(lines)
        XCTAssertFalse(elsewhere.contains("ads.example.com"))
        XCTAssertFalse(elsewhere.contains("pin-me.example.com"))
        XCTAssertTrue(elsewhere.contains("nas.home"), "the user's own names still count")
        XCTAssertTrue(elsewhere.contains("localhost"))
        XCTAssertFalse(elsewhere.contains("my"), "an end-of-line comment is not read")
    }

    // MARK: - Helper wiring

    func testHelperVersionCarriesTheNewMethod() {
        XCTAssertEqual(HelperManager.MethodSince.blockedHosts, "2.11.0")
        XCTAssertFalse(HelperManager.helper("2.10.0", supports: HelperManager.MethodSince.blockedHosts))
        XCTAssertTrue(HelperManager.helper(HelperConstants.helperVersion, supports: HelperManager.MethodSince.blockedHosts))
    }
}
