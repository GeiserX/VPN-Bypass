// ServiceCatalogue.swift
// The built-in services, read from the JSON files in Resources/catalogue/, one file per
// category. The Services page lists the ones the user has on; the rest wait in the catalogue
// sheet. Every catalogue service is still in `config.services` with its switch, under the
// same id as when the list was written in code, so saved configs, `builtInServiceExtras`,
// `vpnb service.*` and the MCP server keep working.
//
// The files ship inside the signed app and are never downloaded. `decode` checks them with the
// app's own validators; ServiceCatalogueTests runs it over the source tree, so a bad file
// fails CI before it can ship.

import Foundation

enum ServiceCatalogue {
    /// The catalogue's groups, in the order the sheet shows them and the Services page lists
    /// their services. A file is named after its category: `video.json` holds `video`.
    enum Category: String, CaseIterable, Codable {
        case messaging, video, music, social, work, cloud, gaming, developer, ai

        func displayName(in bundle: Bundle = .main) -> String {
            switch self {
            case .messaging: return String(localized: "catalogue.category.messaging", defaultValue: "Messaging", bundle: bundle)
            case .video: return String(localized: "catalogue.category.video", defaultValue: "Video", bundle: bundle)
            case .music: return String(localized: "catalogue.category.music", defaultValue: "Music", bundle: bundle)
            case .social: return String(localized: "catalogue.category.social", defaultValue: "Social", bundle: bundle)
            case .work: return String(localized: "catalogue.category.work", defaultValue: "Work", bundle: bundle)
            case .cloud: return String(localized: "catalogue.category.cloud", defaultValue: "Cloud storage", bundle: bundle)
            case .gaming: return String(localized: "catalogue.category.gaming", defaultValue: "Gaming", bundle: bundle)
            case .developer: return String(localized: "catalogue.category.developer", defaultValue: "Developer", bundle: bundle)
            case .ai: return String(localized: "catalogue.category.ai", defaultValue: "AI", bundle: bundle)
            }
        }
    }

    /// One catalogue service. `service` is off and not custom; `region` is an ISO 3166 code
    /// for a service that belongs to one country, so the sheet can find "France" across
    /// categories.
    struct Entry {
        let category: Category
        let region: String?
        let service: ServiceEntry
    }

    /// What the app ships, read once: `Config.defaultServices` is read for every row.
    static let shipped: [Entry] = loaded.entries

    /// Why a shipped file or entry was left out, for the log. Empty unless a bad file got past CI.
    static var problems: [String] { loaded.problems }

    private static let loaded: (entries: [Entry], problems: [String]) = load()

    /// The shipped app reads `Contents/Resources/catalogue/`, which the Makefile copies in.
    /// `swift test` and `swift run` have no such folder, so a debug build reads SwiftPM's
    /// resource bundle instead. A release build never touches `Bundle.module`, which would
    /// stop the app when that bundle is missing.
    private static func load() -> (entries: [Entry], problems: [String]) {
        var urls: [URL] = []
        if let dir = Bundle.main.url(forResource: "catalogue", withExtension: nil) {
            urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
        }
        #if DEBUG
        if urls.isEmpty {
            urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        }
        #endif
        guard !urls.isEmpty else {
            return ([], ["no catalogue files found in the app bundle; the built-in services already saved are kept as they are"])
        }
        var problems: [String] = []
        var files: [(name: String, data: Data)] = []
        for url in urls {
            if let data = try? Data(contentsOf: url) {
                files.append((url.lastPathComponent, data))
            } else {
                problems.append("\(url.lastPathComponent): could not be read")
            }
        }
        let result = decode(files)
        return (result.entries, problems + result.problems)
    }

    // MARK: - Reading and checking the files

    private static let fileKeys: Set<String> = ["category", "services"]
    private static let serviceKeys: Set<String> = ["id", "name", "region", "domains", "ipRanges"]

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct UnknownKeys: Error { let keys: [String] }

    private struct File: Decodable {
        let category: String
        let services: [RawService]

        init(from decoder: Decoder) throws {
            let unknown = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
                .filter { !ServiceCatalogue.fileKeys.contains($0) }
            if !unknown.isEmpty { throw UnknownKeys(keys: unknown.sorted()) }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            category = try c.decode(String.self, forKey: .category)
            services = try c.decode([RawService].self, forKey: .services)
        }

        private enum CodingKeys: String, CodingKey { case category, services }
    }

    private struct RawService: Decodable {
        let id: String
        let name: String
        let region: String?
        let domains: [String]
        let ipRanges: [String]

        init(from decoder: Decoder) throws {
            let unknown = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
                .filter { !ServiceCatalogue.serviceKeys.contains($0) }
            if !unknown.isEmpty { throw UnknownKeys(keys: unknown.sorted()) }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            region = try c.decodeIfPresent(String.self, forKey: .region)
            domains = try c.decode([String].self, forKey: .domains)
            ipRanges = try c.decodeIfPresent([String].self, forKey: .ipRanges) ?? []
        }

        private enum CodingKeys: String, CodingKey { case id, name, region, domains, ipRanges }
    }

    /// The entries of `files` (file name, contents), categories in `Category` order and each
    /// file's services in its own order, and one line per thing wrong. A file that cannot be
    /// read is left out whole; an entry with anything wrong is left out on its own. CI fails
    /// on any line, so at runtime this only guards against a file that got past it.
    static func decode(_ files: [(name: String, data: Data)]) -> (entries: [Entry], problems: [String]) {
        var problems: [String] = []
        var byCategory: [Category: [RawService]] = [:]
        var fileOf: [Category: String] = [:]

        for file in files {
            let parsed: File
            do {
                parsed = try JSONDecoder().decode(File.self, from: file.data)
            } catch let error as UnknownKeys {
                problems.append("\(file.name): unknown field \(error.keys.joined(separator: ", "))")
                continue
            } catch {
                problems.append("\(file.name): not a catalogue file (\(describe(error)))")
                continue
            }
            guard let category = Category(rawValue: parsed.category) else {
                problems.append("\(file.name): unknown category \u{201C}\(parsed.category)\u{201D}")
                continue
            }
            guard file.name == "\(category.rawValue).json" else {
                problems.append("\(file.name): holds category \(category.rawValue), so it must be named \(category.rawValue).json")
                continue
            }
            guard fileOf[category] == nil else {
                problems.append("\(file.name): a second file for category \(category.rawValue)")
                continue
            }
            if parsed.services.isEmpty {
                problems.append("\(file.name): has no services")
            }
            fileOf[category] = file.name
            byCategory[category] = parsed.services
        }

        var entries: [Entry] = []
        var accepted: [ServiceEntry] = []
        var seenIds: Set<String> = []
        for category in Category.allCases {
            guard let raws = byCategory[category], let fileName = fileOf[category] else { continue }
            for raw in raws {
                let wrong = check(raw, seenIds: seenIds, accepted: accepted)
                seenIds.insert(raw.id)
                guard wrong.isEmpty else {
                    problems += wrong.map { "\(fileName): \(raw.id): \($0)" }
                    continue
                }
                let service = ServiceEntry(id: raw.id, name: raw.name, enabled: false,
                                           domains: raw.domains, ipRanges: raw.ipRanges)
                accepted.append(service)
                entries.append(Entry(category: category, region: raw.region, service: service))
            }
        }
        return (entries, problems)
    }

    /// What is wrong with one entry, checked with the rules the app applies to what a user types.
    private static func check(_ raw: RawService, seenIds: Set<String>, accepted: [ServiceEntry]) -> [String] {
        var wrong: [String] = []
        if raw.id.isEmpty || !raw.id.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) {
            wrong.append("the id may hold only a-z, 0-9 and _")
        }
        if raw.id.hasPrefix("custom_") {
            wrong.append("custom_ ids belong to custom services")
        }
        if seenIds.contains(raw.id) {
            wrong.append("the id is used twice")
        }
        if raw.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            wrong.append("the name is empty")
        } else if raw.name != raw.name.trimmingCharacters(in: .whitespacesAndNewlines) {
            wrong.append("the name has spaces around it")
        } else if case .service(let other)? = ServiceNameClash.find(raw.name, excluding: raw.id, services: accepted, domains: []) {
            wrong.append("the name clashes with \u{201C}\(other)\u{201D}")
        }
        if raw.domains.isEmpty && raw.ipRanges.isEmpty {
            wrong.append("has no domain and no range")
        }
        for domain in raw.domains where !isValidDomain(domain) {
            wrong.append("\(domain) is not a domain or a wildcard the app accepts")
        }
        for range in raw.ipRanges where !RouteManager.isValidCIDR(range) {
            wrong.append("\(range) is not an IPv4 range the app accepts")
        }
        for repeated in Set(raw.domains.filter { d in raw.domains.filter { $0 == d }.count > 1 }) {
            wrong.append("\(repeated) is listed twice")
        }
        for repeated in Set(raw.ipRanges.filter { r in raw.ipRanges.filter { $0 == r }.count > 1 }) {
            wrong.append("\(repeated) is listed twice")
        }
        if let region = raw.region,
           region.count != 2 || region != region.uppercased()
            || !Locale.Region.isoRegions.contains(where: { $0.identifier == region }) {
            wrong.append("\(region) is not an ISO 3166 country code")
        }
        return wrong
    }

    /// A plain name as `cleanDomain` would save it, or a wildcard whose suffix has a site of
    /// its own (`LookupAddLevels.registrableDomain`): never `*.com`, `*.co.uk` or
    /// `*.cloudfront.net`, which would take in other people's sites.
    static func isValidDomain(_ domain: String) -> Bool {
        if WildcardDomain.isWildcard(domain) {
            guard let suffix = WildcardDomain.suffix(of: domain), WildcardDomain.entry(for: suffix) == domain else { return false }
            return LookupAddLevels.registrableDomain(suffix) != nil
        }
        return !domain.isEmpty && RouteManager.cleanDomain(domain) == domain
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "missing field \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context): return "wrong type at \(path(context))"
        case DecodingError.valueNotFound(_, let context): return "missing value at \(path(context))"
        case DecodingError.dataCorrupted(let context): return context.codingPath.isEmpty ? "invalid JSON" : "bad value at \(path(context))"
        default: return "invalid JSON"
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}
