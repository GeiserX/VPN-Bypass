// GeoDownloadLimitTests.swift
// A download at its edges: a preset whose checksum cannot be read, a source changed while one is
// checked, and a list used without a checksum.

import XCTest
@testable import VPNBypassCore

@MainActor
final class GeoDownloadLimitTests: XCTestCase {

    private var directory: URL!
    private var store: GeoDataStore!
    private let custom = URL(string: "https://example.org/geoip.dat")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("geo-limits-\(UUID().uuidString)")
        store = GeoDataStore(kind: .ip, directory: directory)
        store.fetch = { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Dat.sample.write(to: file)
            return file
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    /// Every preset publishes a checksum. When it cannot be read, the download fails and the list in
    /// use stays, instead of a list nobody checked taking its place.
    func testAPresetWhoseChecksumCannotBeReadIsNotUsed() async throws {
        let preset = try XCTUnwrap(URL(string: GeoKind.ip.defaultSource))
        store.fetchChecksum = { _ in nil }
        let unreadable = await store.update(from: preset)
        XCTAssertFalse(unreadable, "a preset with no readable checksum was used")
        XCTAssertFalse(store.hasData)

        store.fetchChecksum = { _ in "<html>Not Found</html>" }
        let errorPage = await store.update(from: preset)
        XCTAssertFalse(errorPage)
        XCTAssertFalse(store.hasData)

        let digest = GeoChecksum.sha256(Dat.sample)
        store.fetchChecksum = { _ in "\(digest)  geoip.dat\n" }
        let checked = await store.update(from: preset)
        XCTAssertTrue(checked)
        // A later download whose checksum fails to arrive leaves this one in place.
        let before = try Data(contentsOf: store.fileURL)
        store.fetch = { _ in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Dat.file([Dat.entry("IR", [Dat.cidr([198, 51, 100, 0], 24)])]).write(to: file)
            return file
        }
        store.fetchChecksum = { _ in nil }
        let failed = await store.update(from: preset)
        XCTAssertFalse(failed)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)

        // A custom address that publishes none is still used.
        let unpublished = await store.update(from: custom)
        XCTAssertTrue(unpublished)
    }

    /// A source chosen while another one is being checked: the first one does not replace the list in
    /// use, so a failed download of the chosen one cannot leave the first one's list behind.
    func testASourceChosenDuringTheCheckIsTheOnlyOneThatCanReplaceTheList() async {
        let other = URL(string: "https://example.com/geoip.dat")!
        let store = self.store!
        store.fetch = { url in
            if url == other { throw URLError(.notConnectedToInternet) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Dat.sample.write(to: file)
            return file
        }
        store.fetchChecksum = { url in
            if url.absoluteString.hasPrefix("https://example.org/") {
                // The user picks another source while this one's checksum is on its way.
                _ = await store.update(from: other)
            }
            return nil
        }
        _ = await store.update(from: custom)
        XCTAssertFalse(store.hasData, "the list of the source no longer chosen replaced the copy in use")
    }

    /// A custom address that publishes no checksum is used, and the status line under the list says it
    /// was not checked, until a checked list replaces it.
    func testAListThatWasNotCheckedSaysSo() async {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        store.fetchChecksum = { _ in nil }
        _ = await store.update(from: custom)
        XCTAssertTrue(store.isUnchecked)
        let line = GeoDisplay.status(.ip, updated: when, phase: .idle, unchecked: store.isUnchecked, now: when)
        XCTAssertTrue(line.hasSuffix(String(localized: "Not checked: its source publishes no checksum.")), line)
        XCTAssertFalse(GeoDisplay.status(.ip, updated: when, phase: .updating, unchecked: true, now: when).contains("Not checked"))

        let digest = GeoChecksum.sha256(Dat.sample)
        store.fetchChecksum = { _ in digest }
        _ = await store.update(from: custom)
        XCTAssertFalse(store.isUnchecked)
    }
}
