// GeoIPStore.swift
// The country list behind Country (GeoIP) rules: one `geoip.dat` kept in Application Support,
// the ranges read from it, and the opt-in download that replaces it.
//
// This is the only place the app fetches data over HTTP. Nothing is fetched until the user adds
// a Country rule (or presses Update); the source is shown on the Rules page and can be changed
// in the config (`geoipSourceURL`) to a mirror, which matters where GitHub is blocked. A download
// only replaces the copy in use after it reads as a geoip list, so a failed, truncated or wrong
// download leaves the last good copy in place. Every range a country lists still goes through
// the same install policy as a CIDR rule (RuleDestinationBuilder), so a list that claims
// 0.0.0.0/0 cannot take over the routing table.

import Foundation

@MainActor
final class GeoIPStore: ObservableObject {

    /// Loyalsoldier's list: the default of OpenWrt Passwall2, and it holds the `ir`, `ru` and `cn`
    /// lists and `private`. Other sources (MetaCubeX, Chocolate4U's Iran list, runetfreedom's
    /// Russia list) use the same format.
    nonisolated static let defaultSource = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    /// The list is refreshed at launch when the copy is older than this and a Country rule uses it.
    nonisolated static let staleAfter: TimeInterval = 7 * 24 * 3600
    /// A download larger than this is refused (the published lists are about 10 to 20 MB).
    nonisolated static let maxDownloadBytes = 64 * 1024 * 1024
    /// A country with more ranges than this is cut here: the largest real lists are a few thousand.
    nonisolated static let maxRangesPerCountry = 30_000

    static let shared = GeoIPStore(directory: GeoIPStore.defaultDirectory())
    /// A failed download is not tried again on its own for this long.
    nonisolated static let retryAfter: TimeInterval = 3600
    /// False under tests, which must never reach the network.
    static var autoUpdate = NSClassFromString("XCTestCase") == nil

    enum Phase: Equatable {
        case idle
        case updating
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Counts up when the file changes, so a view that shows it reads again.
    @Published private(set) var revision = 0

    let fileURL: URL
    /// Fetches `url` to a local file and returns it. Replaced in tests.
    var fetch: (URL) async throws -> URL = GeoIPStore.download

    /// When a download last started, so an automatic one waits `retryAfter` after a failure.
    private(set) var lastAttempt: Date?
    private var cachedStamp: Date?
    private var cachedRanges: [String: [String]] = [:]
    private var cachedCountries: [String: Int]?

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("geoip.dat")
    }

    private static func defaultDirectory() -> URL {
        let underTests = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if underTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("VPNBypassTests-geoip-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VPNBypass", isDirectory: true)
    }

    // MARK: - The copy in use

    /// When the file in use was downloaded, nil when there is none.
    var updated: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    var hasData: Bool { updated != nil }

    /// The copy is missing or older than `staleAfter`.
    func needsRefresh(now: Date = Date()) -> Bool {
        guard let updated else { return true }
        return now.timeIntervalSince(updated) > Self.staleAfter
    }

    /// The IPv4 ranges of each country in `codes` (lower case). A country the list does not hold,
    /// or no list at all, gives no entry: the rule then routes nothing, and its row says why.
    func ranges(for codes: Set<String>) -> [String: [String]] {
        guard !codes.isEmpty, let stamp = updated else { return [:] }
        refreshCache(stamp)
        let missing = codes.subtracting(cachedRanges.keys)
        if !missing.isEmpty, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            for (code, ranges) in GeoIPDat.ranges(for: missing, in: data) {
                cachedRanges[code] = Array(ranges.prefix(Self.maxRangesPerCountry))
            }
        }
        return cachedRanges.filter { codes.contains($0.key) }
    }

    /// Every country in the list, by code, with its number of IPv4 ranges.
    func countries() -> [(code: String, count: Int)] {
        guard let stamp = updated else { return [] }
        refreshCache(stamp)
        if cachedCountries == nil, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            cachedCountries = GeoIPDat.countries(in: data)
        }
        return (cachedCountries ?? [:]).map { (code: $0.key, count: $0.value) }.sorted { $0.code < $1.code }
    }

    private func refreshCache(_ stamp: Date) {
        guard cachedStamp != stamp else { return }
        cachedStamp = stamp
        cachedRanges = [:]
        cachedCountries = nil
    }

    // MARK: - Update

    /// `string` as a source URL: https with a host, nil otherwise. A nil or empty string is the
    /// default source.
    nonisolated static func source(from string: String?) -> URL? {
        let text = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.isEmpty ? defaultSource : text),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Downloads the list from `source` and, when it reads as a geoip list, replaces the copy in
    /// use. Returns whether it did; the reason a download did not is in `phase`.
    @discardableResult
    func update(from source: URL) async -> Bool {
        guard phase != .updating else { return false }
        lastAttempt = Date()
        phase = .updating
        let downloaded: URL
        do {
            downloaded = try await fetch(source)
        } catch {
            phase = .failed(String(localized: "Could not download the country list."))
            return false
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path))?[.size] as? Int ?? 0
        guard size > 0, size <= Self.maxDownloadBytes else {
            phase = .failed(String(localized: "The download is not a country list."))
            return false
        }
        // Read off the main actor: a list is tens of megabytes.
        let usable = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: downloaded, options: .mappedIfSafe) else { return false }
            return GeoIPDat.isUsable(data)
        }.value
        guard usable else {
            phase = .failed(String(localized: "The download is not a country list."))
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: downloaded)
        } catch {
            do {
                try? FileManager.default.removeItem(at: fileURL)
                try FileManager.default.moveItem(at: downloaded, to: fileURL)
            } catch {
                phase = .failed(String(localized: "Could not save the country list."))
                return false
            }
        }
        // 0600 like the config: the list is the owner's.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cachedStamp = nil
        phase = .idle
        revision += 1
        return true
    }

    /// The real download: an https GET with a time limit, to a temporary file.
    nonisolated private static func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("VPN-Bypass", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        return file
    }
}

// MARK: - Country rules

/// The pattern of a Country rule: the code of a list in the geoip file, lower case.
enum GeoIPRule {
    /// `input` as a stored pattern, nil when it cannot be a list name. The published lists use
    /// two-letter country codes and names such as `private`, `cloudflare` or `geolocation-cn`.
    static func normalized(_ input: String) -> String? {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (2...40).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "!") })
        else { return nil }
        return code
    }
}

extension RouteManager {
    /// The ranges the enabled Country rules name, by lower-case code. Empty before the list has
    /// been downloaded.
    func geoipRanges() -> [String: [String]] {
        let codes = Set(config.rules.filter { $0.enabled && $0.matchType == .geoip }.map { $0.pattern.lowercased() })
        return GeoIPStore.shared.ranges(for: codes)
    }

    /// Whether a rule that needs the list is on.
    var usesGeoIP: Bool { config.rules.contains { $0.enabled && $0.matchType == .geoip } }

    /// Fetches the list when a Country rule needs it and it is missing or stale. Called at launch,
    /// after a config save and by the 12-hour watchdog; a failure is retried an hour later.
    func refreshGeoIPIfNeeded(now: Date = Date()) {
        let store = GeoIPStore.shared
        guard GeoIPStore.autoUpdate, usesGeoIP, store.phase != .updating,
              !store.hasData || store.needsRefresh(now: now) else { return }
        if let last = store.lastAttempt, now.timeIntervalSince(last) < GeoIPStore.retryAfter { return }
        Task { await updateGeoIPData() }
    }

    /// Downloads the country list from the configured source and, in Custom mode, puts the
    /// routes in again so the new ranges take effect. Returns whether the list was replaced.
    @discardableResult
    func updateGeoIPData() async -> Bool {
        guard let source = GeoIPStore.source(from: config.geoipSourceURL) else {
            return false
        }
        let replaced = await GeoIPStore.shared.update(from: source)
        if replaced, usesGeoIP { startConfigFollowUp(reconcileListeners: false, reapplyRoutes: true) }
        return replaced
    }
}
