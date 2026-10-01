// LogFilterTests.swift
// The level filter and search on Settings > Logs (proposal 14 of #119): which entries each
// level lets through, how search matches, the count and empty lines, where a term is marked,
// what Copy puts on the clipboard, and the Spanish and French text.

import XCTest
@testable import VPNBypassCore

final class LogFilterTests: XCTestCase {

    private typealias Entry = RouteManager.LogEntry

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// The twelve lines of the proposal's image, newest first.
    private lazy var log: [Entry] = ([
        (.info, "Config saved"),
        (.success, "Added domain: en.wikipedia.org"),
        (.success, "Applied 62 unique routes"),
        (.success, "VPN connected via WireGuard — applying routes in 20s once the tunnel settles"),
        (.warning, "VPN dropped 4s after our last route write — suspected apply-kill (strike 1)"),
        (.warning, "VPN disconnected (was: utun4)"),
        (.info, "Skipping duplicate route application (applied 3s ago)"),
        (.success, "DNS refresh complete: 2 added, 1 removed"),
        (.error, "Cannot route example.org: no local gateway detected. Try Refresh Routes."),
        (.info, "Network changed: none → Home"),
        (.success, "Route verification: All 10 tested routes are reachable"),
        (.success, "Retry succeeded for en.wikipedia.org: 1 routes added"),
    ] as [(Entry.LogLevel, String)]).enumerated().map { i, line in
        Entry(timestamp: t0.addingTimeInterval(TimeInterval(-60 * i)), level: line.0, message: line.1)
    }

    // MARK: Levels

    func testAllLetsEveryLevelThrough() {
        let f = LogFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.apply(log).map(\.id), log.map(\.id))
    }

    func testWarningsIncludesErrors() {
        let shown = LogFilter(level: .warnings).apply(log)
        XCTAssertEqual(shown.map(\.level), [.warning, .warning, .error])
        XCTAssertEqual(shown.first?.message, "VPN dropped 4s after our last route write — suspected apply-kill (strike 1)")
    }

    func testErrorsIsErrorsOnly() {
        let shown = LogFilter(level: .errors).apply(log)
        XCTAssertEqual(shown.map(\.message), ["Cannot route example.org: no local gateway detected. Try Refresh Routes."])
    }

    func testEachLevelAdmitsExactlyItsLevels() {
        let levels: [Entry.LogLevel] = [.info, .success, .warning, .error]
        XCTAssertEqual(levels.filter(LogLevelFilter.all.admits), levels)
        XCTAssertEqual(levels.filter(LogLevelFilter.warnings.admits), [.warning, .error])
        XCTAssertEqual(levels.filter(LogLevelFilter.errors.admits), [.error])
    }

    // MARK: Search

    func testSearchMatchesTheMessageIgnoringCase() {
        let shown = LogFilter(query: "WIKIPEDIA").apply(log)
        XCTAssertEqual(shown.map(\.message), ["Added domain: en.wikipedia.org",
                                              "Retry succeeded for en.wikipedia.org: 1 routes added"])
    }

    func testSearchIgnoresAccentsAndSurroundingSpaces() {
        let entries = [Entry(timestamp: t0, level: .info, message: "Réseau changé")]
        XCTAssertEqual(LogFilter(query: "  reseau ").apply(entries).count, 1)
        XCTAssertEqual(LogFilter(query: "   ").term, "")
        XCTAssertFalse(LogFilter(query: "   ").isActive, "spaces alone are no search")
    }

    func testSearchAndLevelCombine() {
        XCTAssertEqual(LogFilter(level: .warnings, query: "utun4").apply(log).map(\.message),
                       ["VPN disconnected (was: utun4)"])
        XCTAssertTrue(LogFilter(level: .errors, query: "wikipedia").apply(log).isEmpty)
    }

    func testRangesMarkEveryMatchWithoutOverlap() {
        let message = "aaa wiki Wiki"
        let ranges = LogFilter.ranges(of: "wiki", in: message)
        XCTAssertEqual(ranges.map { String(message[$0]) }, ["wiki", "Wiki"])
        XCTAssertEqual(LogFilter.ranges(of: "aa", in: "aaa").count, 1)
        XCTAssertTrue(LogFilter.ranges(of: "", in: message).isEmpty)
        XCTAssertTrue(LogFilter.ranges(of: "zzz", in: message).isEmpty)
    }

    // MARK: Count and empty lines

    func testCountLineSaysHowManyMatch() {
        XCTAssertEqual(LogFilter().countLine(shown: 214, total: 214), "214 entries")
        XCTAssertEqual(LogFilter().countLine(shown: 1, total: 1), "1 entry")
        XCTAssertEqual(LogFilter(level: .warnings).countLine(shown: 3, total: 214), "3 of 214 entries")
        XCTAssertEqual(LogFilter(query: "wikipedia").countLine(shown: 2, total: 214), "2 of 214 entries")
    }

    func testEmptyLineSaysWhatFoundNothing() {
        XCTAssertNil(LogFilter().emptyLine(shown: 0), "no filter: the page shows No activity yet")
        XCTAssertNil(LogFilter(level: .errors).emptyLine(shown: 1))
        XCTAssertEqual(LogFilter(level: .warnings).emptyLine(shown: 0), "No warnings or errors.")
        XCTAssertEqual(LogFilter(level: .errors).emptyLine(shown: 0), "No errors.")
        XCTAssertEqual(LogFilter(level: .errors, query: " zoom ").emptyLine(shown: 0), "No entries match “zoom”.")
    }

    // MARK: Copy

    func testCopyPutsTheShownEntriesOnTheClipboard() {
        let shown = LogFilter(level: .errors).apply(log)
        XCTAssertEqual(LogFilter.clipboardText(shown, timeZone: TimeZone(identifier: "UTC")!),
                       "[2026-09-21 14:05:20] [ERROR] Cannot route example.org: no local gateway detected. Try Refresh Routes.")
        XCTAssertEqual(LogFilter.clipboardText(log).components(separatedBy: "\n").count, 12)
    }

    // MARK: Spanish and French

    private func lproj(_ language: String) throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(Bundle(url: root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj")))
    }

    func testEveryStringIsTranslated() throws {
        let en = try lproj("en"), es = try lproj("es"), fr = try lproj("fr")
        for (name, bundle) in [("es", es), ("fr", fr)] {
            var pairs: [(String, String)] = LogLevelFilter.allCases.flatMap {
                [($0.title(in: en), $0.title(in: bundle)), ($0.help(in: en), $0.help(in: bundle))]
            }
            let filters = [LogFilter(), LogFilter(level: .warnings), LogFilter(level: .errors), LogFilter(query: "zoom")]
            for f in filters {
                pairs.append((f.countLine(shown: 3, total: 214, in: en), f.countLine(shown: 3, total: 214, in: bundle)))
                if let english = f.emptyLine(shown: 0, in: en) {
                    pairs.append((english, f.emptyLine(shown: 0, in: bundle) ?? ""))
                }
            }
            pairs.append((LogFilter().countLine(shown: 1, total: 1, in: en), LogFilter().countLine(shown: 1, total: 1, in: bundle)))
            for key in ["Search", "Copy the entries shown", "Remove every entry, including any the filter hides"] {
                pairs.append((String(localized: String.LocalizationValue(key), bundle: en),
                              String(localized: String.LocalizationValue(key), bundle: bundle)))
            }
            for (english, translated) in pairs {
                XCTAssertNotEqual(translated, english, "\(name) has no entry for \"\(english)\"")
                XCTAssertFalse(translated.contains("%"), "\(name): \(translated)")
            }
        }
        XCTAssertEqual(LogFilter(level: .warnings).countLine(shown: 3, total: 214, in: es), "3 de 214 entradas")
        XCTAssertEqual(LogFilter(query: "zoom").emptyLine(shown: 0, in: fr), "Aucune entrée ne contient « zoom ».")
    }
}
