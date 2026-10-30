// ServiceCatalogueTests.swift
// The CI check on the service catalogue (Sources/VPNBypassCore/Resources/catalogue/): every
// file goes through `ServiceCatalogue.decode`, which uses the app's own validators, and must
// come back with no problem. The inline bad files below prove each rule can fail.

import XCTest
@testable import VPNBypassCore

final class ServiceCatalogueTests: XCTestCase {

    private static let catalogueDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VPNBypassCore/Resources/catalogue")

    /// Every JSON file in the source tree, by file name.
    private func sourceFiles() throws -> [(name: String, data: Data)] {
        let urls = try FileManager.default.contentsOfDirectory(at: Self.catalogueDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "no catalogue files at \(Self.catalogueDir.path)")
        return try urls.map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
    }

    // MARK: - The shipped files

    func testEveryCatalogueFilePassesEveryCheck() throws {
        let result = ServiceCatalogue.decode(try sourceFiles())
        XCTAssertEqual(result.problems, [], result.problems.joined(separator: "\n"))
        XCTAssertFalse(result.entries.isEmpty)
    }

    func testEveryCategoryHasItsFile() throws {
        let names = Set(try sourceFiles().map(\.name))
        for category in ServiceCatalogue.Category.allCases {
            XCTAssertTrue(names.contains("\(category.rawValue).json"), "\(category.rawValue).json is missing")
        }
    }

    /// The ids saved configs, `vpnb` and the MCP server refer to, in catalogue order. A
    /// renamed, dropped or reordered id fails here; a new service is added to this list.
    static let frozenIds = [
        "telegram", "whatsapp", "signal",
        "youtube", "netflix", "primevideo", "disneyplus", "hbomax", "twitch",
        "spotify", "applemusic", "soundcloud",
        "twitter", "instagram", "tiktok", "reddit", "facebook", "linkedin",
        "slack", "discord", "zoom", "teams", "googlemeet",
        "dropbox", "gdrive", "icloud",
        "steam", "epicgames", "playstation", "xbox",
        "github", "gitlab", "stackoverflow", "tailscale",
        "openai", "anthropic", "perplexity",
        "fr_gov",
        "fr_societegenerale", "fr_bnpparibas", "fr_creditagricole", "fr_banquepopulaire", "fr_caisseepargne",
        "fr_lcl", "fr_labanquepostale", "fr_boursobank", "fr_fortuneo", "fr_hellobank", "fr_monabanq",
        "fr_cic", "fr_creditmutuel",
    ]

    /// The French entries are wildcards only and each names its country, so search finds
    /// them by "France"; none hides another (`*.gouv.fr` already holds impots.gouv.fr).
    func testTheFrenchEntriesAreWildcardsOverTheirOwnSites() {
        let french = ServiceCatalogue.shipped.filter { $0.region == "FR" }
        XCTAssertEqual(french.count, 14)
        for entry in french {
            for domain in entry.service.domains {
                XCTAssertTrue(WildcardDomain.isWildcard(domain), domain)
                let suffix = WildcardDomain.suffix(of: domain)!
                let others = entry.service.domains.filter { $0 != domain }.compactMap(WildcardDomain.suffix(of:))
                XCTAssertFalse(others.contains { WildcardDomain.matches(suffix, suffix: $0) }, "\(domain) is covered by another entry")
            }
        }
    }

    func testTheBuiltInIdsAndTheirOrderAreFrozen() {
        XCTAssertEqual(Config.defaultServices.map(\.id), Self.frozenIds)
        XCTAssertTrue(Config.defaultServices.allSatisfy { !$0.enabled && !$0.isCustom })
    }

    /// The test run reads the catalogue from SwiftPM's resource bundle, the app from its
    /// Contents/Resources: both must hold every file of the source tree.
    func testTheLoadedCatalogueIsTheSourceTree() throws {
        let fromSource = ServiceCatalogue.decode(try sourceFiles()).entries
        XCTAssertEqual(ServiceCatalogue.shipped.map(\.service.id), fromSource.map(\.service.id))
        XCTAssertEqual(ServiceCatalogue.shipped.map(\.service.domains), fromSource.map(\.service.domains))
        XCTAssertEqual(ServiceCatalogue.problems, [])
    }

    func testCategoriesAreTranslated() throws {
        let root = Self.catalogueDir.deletingLastPathComponent()
        let es = try XCTUnwrap(Bundle(url: root.appendingPathComponent("es.lproj")))
        let fr = try XCTUnwrap(Bundle(url: root.appendingPathComponent("fr.lproj")))
        XCTAssertEqual(ServiceCatalogue.Category.messaging.displayName(in: es), "Mensajería")
        XCTAssertEqual(ServiceCatalogue.Category.cloud.displayName(in: fr), "Stockage en ligne")
        XCTAssertEqual(ServiceCatalogue.Category.banks.displayName(in: es), "Bancos")
        XCTAssertEqual(ServiceCatalogue.Category.government.displayName(in: fr), "Administration")
        XCTAssertEqual(ServiceCatalogue.Category.cloud.displayName(in: .main), "Cloud storage")
    }

    // MARK: - Each rule goes red

    private func file(_ category: String, _ services: String, name: String? = nil) -> (name: String, data: Data) {
        (name ?? "\(category).json", Data(#"{"category": "\#(category)", "services": [\#(services)]}"#.utf8))
    }

    private func problems(_ files: [(name: String, data: Data)]) -> [String] {
        ServiceCatalogue.decode(files).problems
    }

    private func assertRefused(_ services: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = problems([self.file("ai", services)])
        XCTAssertTrue(found.contains { $0.contains(expected) }, "expected \u{201C}\(expected)\u{201D}, got \(found)", file: file, line: line)
        XCTAssertTrue(ServiceCatalogue.decode([self.file("ai", services)]).entries.allSatisfy { $0.service.id == "ok" },
                      "the bad entry is left out", file: file, line: line)
    }

    func testAGoodFileHasNoProblem() {
        let result = ServiceCatalogue.decode([file("ai", #"{"id": "ok", "name": "Ok Bank", "region": "FR", "domains": ["*.ok-bank.fr", "ok-bank.com"], "ipRanges": ["10.1.0.0/16"]}"#)])
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.entries.first?.region, "FR")
        XCTAssertEqual(result.entries.first?.category, .ai)
    }

    func testBadJSONIsRefused() {
        XCTAssertTrue(problems([("banks.json", Data("{ not json".utf8))]).first?.contains("not a catalogue file") == true)
    }

    func testAMissingOrUnknownFieldIsRefused() {
        XCTAssertTrue(problems([file("ai", #"{"id": "a", "name": "A"}"#)]).first?.contains("missing field domains") == true)
        XCTAssertTrue(problems([file("ai", #"{"id": "a", "name": "A", "domains": ["a.fr"], "iprange": []}"#)])
            .first?.contains("unknown field iprange") == true)
    }

    func testAnUnknownCategoryIsRefused() {
        XCTAssertTrue(problems([file("shops", #"{"id": "a", "name": "A", "domains": ["a.fr"]}"#)])
            .first?.contains("unknown category") == true)
    }

    func testAFileNamedAfterAnotherCategoryIsRefused() {
        XCTAssertTrue(problems([file("ai", #"{"id": "a", "name": "A", "domains": ["a.fr"]}"#, name: "money.json")])
            .first?.contains("must be named ai.json") == true)
    }

    func testARepeatedIdIsRefusedAcrossFiles() {
        let found = problems([file("video", #"{"id": "netflix", "name": "Netflix", "domains": ["netflix.com"]}"#),
                              file("ai", #"{"id": "netflix", "name": "Other", "domains": ["other.fr"]}"#)])
        XCTAssertEqual(found, ["ai.json: netflix: the id is used twice"])
    }

    func testANameThatDiffersOnlyByCaseOrSpacesIsRefused() {
        let found = problems([file("video", #"{"id": "netflix", "name": "Netflix", "domains": ["netflix.com"]}"#),
                              file("ai", #"{"id": "n2", "name": "netflix", "domains": ["other.fr"]}"#)])
        XCTAssertEqual(found, ["ai.json: n2: the name clashes with \u{201C}Netflix\u{201D}"])
        assertRefused(#"{"id": "n3", "name": "netflix ", "domains": ["other.fr"]}"#, "spaces around it")
    }

    func testABadIdIsRefused() {
        assertRefused(#"{"id": "Bad-Id", "name": "A", "domains": ["a.fr"]}"#, "may hold only")
        assertRefused(#"{"id": "custom_a", "name": "A", "domains": ["a.fr"]}"#, "custom_ ids")
    }

    func testAWildcardOverATopLevelOrPublicSuffixIsRefused() {
        for wide in ["*.com", "*.co.uk", "*.cloudfront.net", "*.bnpparibas", "*.Lcl.fr", "*.lcl.fr."] {
            assertRefused(#"{"id": "a", "name": "A", "domains": ["\#(wide)"]}"#, "\(wide) is not")
        }
    }

    func testAPlainNameTheAppWouldCleanIsRefused() {
        for bad in ["https://a.fr", "A.fr", "a.fr/path", "a fr", ""] {
            assertRefused(#"{"id": "a", "name": "A", "domains": ["\#(bad)"]}"#, "\(bad) is not")
        }
    }

    func testABadRangeIsRefused() {
        for bad in ["10.0.0.0/1", "10.0.0.0", "300.0.0.0/8", "2001:db8::/32"] {
            assertRefused(#"{"id": "a", "name": "A", "domains": ["a.fr"], "ipRanges": ["\#(bad)"]}"#, "\(bad) is not")
        }
    }

    func testAnEmptyServiceIsRefused() {
        assertRefused(#"{"id": "a", "name": "A", "domains": []}"#, "no domain and no range")
    }

    func testARepeatedDomainIsRefused() {
        assertRefused(#"{"id": "a", "name": "A", "domains": ["a.fr", "a.fr"]}"#, "a.fr is listed twice")
    }

    func testAnUnknownRegionIsRefused() {
        assertRefused(#"{"id": "a", "name": "A", "region": "XX", "domains": ["a.fr"]}"#, "XX is not")
        assertRefused(#"{"id": "a", "name": "A", "region": "fr", "domains": ["a.fr"]}"#, "fr is not")
    }

    func testAFileWithNoServicesIsReported() {
        XCTAssertEqual(problems([file("ai", "")]), ["ai.json: has no services"])
    }

    func testTheGoodEntriesOfAFileWithABadOneStillLoad() {
        let result = ServiceCatalogue.decode([file("ai", #"{"id": "ok", "name": "Ok", "domains": ["ok.fr"]}, {"id": "bad", "name": "Bad", "domains": ["*.com"]}"#)])
        XCTAssertEqual(result.entries.map(\.service.id), ["ok"])
        XCTAssertEqual(result.problems.count, 1)
    }

    func testEntriesFollowTheCategoryOrderWhateverTheFileOrder() {
        let result = ServiceCatalogue.decode([file("ai", #"{"id": "b", "name": "B", "domains": ["b.fr"]}"#),
                                              file("messaging", #"{"id": "m", "name": "M", "domains": ["m.fr"]}"#)])
        XCTAssertEqual(result.entries.map(\.service.id), ["m", "b"])
    }
}
