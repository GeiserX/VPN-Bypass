// LookupsPageTests.swift
// The Lookups page on the shared components (step 5 of the 6.0 rework, section 3.3): what the
// page shows in each state, its rows as ListRows, and its words in Spanish and French.

import AppKit
import XCTest
@testable import VPNBypassCore

final class LookupsPageModelTests: XCTestCase {

    // MARK: - What the page shows

    func testOffShowsTheEmptyStateWhateverTheList() {
        XCTAssertEqual(LookupsTab.Content.resolve(isOn: false, matching: 0, query: ""), .off)
        XCTAssertEqual(LookupsTab.Content.resolve(isOn: false, matching: 12, query: "git"), .off)
    }

    func testOnShowsTheNamesOrSaysWhyThereAreNone() {
        XCTAssertEqual(LookupsTab.Content.resolve(isOn: true, matching: 3, query: ""), .names)
        XCTAssertEqual(LookupsTab.Content.resolve(isOn: true, matching: 0, query: ""), .waiting)
        XCTAssertEqual(LookupsTab.Content.resolve(isOn: true, matching: 0, query: "  "), .waiting, "blank search is no search")
        XCTAssertEqual(LookupsTab.Content.resolve(isOn: true, matching: 0, query: "zz"), .noMatch)
    }

    // MARK: - The rows

    /// The count sits in ListRow's number column, sized from the biggest count shown, so every
    /// number fits and all of them line up (the #183 rule, moved into ListRow).
    func testTheNumberColumnFitsTheBiggestCountShown() {
        func entry(_ name: String, _ count: Int) -> DNSLookupTally.Entry {
            DNSLookupTally.Entry(name: name, count: count, lastSeen: Date())
        }
        let shown = [entry("github.com", 1602), entry("slack.com", 755), entry("status.example.com", 3)]
        let width = LookupsTab.numberWidth(for: shown)
        XCTAssertEqual(width, ListRow.numberColumnWidth(for: [LookupRow.format(1602)]), "the biggest count sets the column")
        for count in [1602, 755, 3] {
            let drawn = (LookupRow.format(count) as NSString).size(withAttributes: [.font: ListRow.numberFont]).width
            XCTAssertLessThanOrEqual(drawn, width, "\(count) does not fit the column")
        }
        XCTAssertLessThan(LookupsTab.numberWidth(for: [entry("a.com", 48)]), width, "small counts get a tight column")
        XCTAssertEqual(LookupsTab.numberWidth(for: []), 0)
    }

    /// Where a name is listed is the row's detail line, not a column of words on the right.
    func testWhereTheNameIsListedIsTheDetailLine() {
        XCTAssertNil(LookupRow.detail(for: nil), "an unlisted name is one line")
        XCTAssertEqual(LookupRow.detail(for: .bypassList), "Bypassed")
        XCTAssertEqual(LookupRow.detail(for: .service("Meetings")), "Bypassed · Meetings")
        XCTAssertEqual(LookupRow.detail(for: .vpnOnlyList), "Via VPN")
        XCTAssertEqual(LookupRow.detail(for: .rule(routeName: "office-proxy")), "office-proxy")
        XCTAssertEqual(LookupRow.detail(for: .listedOff), "Off")
    }

    func testTheGlyphSaysWhetherTheModeRoutesTheName() {
        XCTAssertEqual(LookupRow.glyph(for: nil), "globe")
        XCTAssertEqual(LookupRow.glyph(for: .bypassList), "checkmark.circle")
        XCTAssertEqual(LookupRow.glyph(for: .service("Meetings")), "checkmark.circle")
        XCTAssertEqual(LookupRow.glyph(for: .listedOff), "pause.circle")
    }

    // MARK: - Words

    func testThePagesNewWordsAreTranslated() throws {
        let keys = ["Start Watching", "Stop Watching", "DNS lookups are not being watched",
                    "Stop reading DNS lookups, and clear the list", "What to Add", "Where",
                    "A wildcard covers every name under it. The helper routes each one as it is looked up, so the Lookups page need not be watching."]
        for language in ["es", "fr"] {
            let bundle = try lproj(language)
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "\u{0}", table: nil), "\u{0}", "\(language) has no \"\(key)\"")
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key, "\(language) leaves \"\(key)\" in English")
            }
        }
    }

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }
}
