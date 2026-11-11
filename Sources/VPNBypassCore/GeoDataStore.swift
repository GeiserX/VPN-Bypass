// GeoDataStore.swift
// The data behind Country (GeoIP) and Site (GeoSite) rules: a `geoip.dat` and a `geosite.dat` kept
// in Application Support, the ranges and domains read from them, and the opt-in download that
// replaces them.
//
// This is the only place the app fetches data over HTTP. Nothing is fetched until a rule needs a
// list (or the user presses Update); the source is shown on the Rules page and can be changed in
// the config (`geoipSourceURL`, `geositeSourceURL`) to a mirror, which matters where GitHub is
// blocked. A download only replaces the copy in use after it reads as a list of its kind, so a
// failed, truncated or wrong download leaves the last good copy in place. Every range a country
// lists still goes through the same install policy as a CIDR rule (RuleDestinationBuilder), so a
// list that claims 0.0.0.0/0 cannot take over the routing table, and a site list reaches the
// routing table only through the wildcard engine's own guards (WildcardSafetyGuard, the limiter).

import Foundation

/// Which file: country ranges, or domain lists.
enum GeoKind: String, CaseIterable {
    case ip
    case site

    var fileName: String { self == .ip ? "geoip.dat" : "geosite.dat" }

    /// Loyalsoldier's lists: the default of OpenWrt Passwall2. MetaCubeX, Chocolate4U's Iran list and
    /// runetfreedom's Russia list use the same formats.
    var defaultSource: String {
        "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/" + fileName
    }

    func isUsable(_ data: Data) -> Bool {
        self == .ip ? GeoIPDat.isUsable(data) : GeoSiteDat.isUsable(data)
    }
}

/// Reads one of the files, safe to call from any thread: the wildcard planner and the route compiler
/// both ask for it. Results are kept until the file changes.
final class GeoDataFile: @unchecked Sendable {

    static let geoip = GeoDataFile(kind: .ip, directory: GeoDataFile.defaultDirectory())
    static let geosite = GeoDataFile(kind: .site, directory: GeoDataFile.defaultDirectory())

    /// A country with more ranges than this is cut here: the largest real lists are a few thousand.
    static let maxRangesPerCountry = 30_000

    let kind: GeoKind
    let url: URL

    private let lock = NSLock()
    private var stamp: Date?
    private var rangesByCode: [String: [String]] = [:]
    private var expansionsByPattern: [String: GeoSiteExpansion] = [:]
    private var countryCounts: [String: Int]?
    private var listCounts: [String: Int]?

    init(kind: GeoKind, directory: URL) {
        self.kind = kind
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(kind.fileName)
    }

    static func defaultDirectory() -> URL {
        let underTests = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if underTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("VPNBypassTests-geo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VPNBypass", isDirectory: true)
    }

    /// When the file in use was downloaded, nil when there is none.
    var updated: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Forgets what was read, so the next question reads the file again.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        stamp = nil
    }

    private func refresh(_ current: Date) {
        guard stamp != current else { return }
        stamp = current
        rangesByCode = [:]
        expansionsByPattern = [:]
        countryCounts = nil
        listCounts = nil
    }

    private func data() -> Data? { try? Data(contentsOf: url, options: .mappedIfSafe) }

    /// The IPv4 ranges of each list in `codes` (lower case). One the file lacks, or no file, gives
    /// no entry: the rule then routes nothing, and its row says why.
    func ranges(for codes: Set<String>) -> [String: [String]] {
        guard kind == .ip, !codes.isEmpty, let current = updated else { return [:] }
        lock.lock(); defer { lock.unlock() }
        refresh(current)
        let missing = codes.subtracting(rangesByCode.keys)
        if !missing.isEmpty, let data = data() {
            for (code, ranges) in GeoIPDat.ranges(for: missing, in: data) {
                rangesByCode[code] = Array(ranges.prefix(Self.maxRangesPerCountry))
            }
        }
        return rangesByCode.filter { codes.contains($0.key) }
    }

    /// Every list in a geoip file with its number of IPv4 ranges.
    func countries() -> [String: Int] {
        guard kind == .ip, let current = updated else { return [:] }
        lock.lock(); defer { lock.unlock() }
        refresh(current)
        if countryCounts == nil, let data = data() { countryCounts = GeoIPDat.countries(in: data) }
        return countryCounts ?? [:]
    }

    /// The expansion of each pattern (`steam`, `category-games@cn`) in a geosite file, keyed by the
    /// pattern. Empty when there is no file, so a rule routes nothing until it is downloaded.
    func expansions(for patterns: Set<String>) -> [String: GeoSiteExpansion] {
        guard kind == .site, !patterns.isEmpty, let current = updated else { return [:] }
        lock.lock(); defer { lock.unlock() }
        refresh(current)
        let missing = patterns.subtracting(expansionsByPattern.keys)
        if !missing.isEmpty, let data = data() {
            for (pattern, expansion) in GeoSiteDat.expansions(for: missing, in: data) {
                expansionsByPattern[pattern] = expansion
            }
        }
        return expansionsByPattern.filter { patterns.contains($0.key) }
    }

    /// Every list in a geosite file with its number of suffix and name entries.
    func lists() -> [String: Int] {
        guard kind == .site, let current = updated else { return [:] }
        lock.lock(); defer { lock.unlock() }
        refresh(current)
        if listCounts == nil, let data = data() { listCounts = GeoSiteDat.lists(in: data) }
        return listCounts ?? [:]
    }
}

@MainActor
final class GeoDataStore: ObservableObject {

    static let geoip = GeoDataStore(file: .geoip)
    static let geosite = GeoDataStore(file: .geosite)

    /// A download larger than this is refused. The published lists are 4 to 18 MB, except one
    /// source's geosite at 87 MB.
    nonisolated static let maxDownloadBytes = 160 * 1024 * 1024
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

    let kind: GeoKind
    let file: GeoDataFile
    /// Fetches `url` to a local file and returns it. Replaced in tests.
    var fetch: (URL) async throws -> URL = GeoDataStore.download

    /// When a download last started, so an automatic one waits `retryAfter` after a failure.
    private(set) var lastAttempt: Date?

    init(file: GeoDataFile) {
        self.file = file
        kind = file.kind
    }

    convenience init(kind: GeoKind, directory: URL) {
        self.init(file: GeoDataFile(kind: kind, directory: directory))
    }

    var fileURL: URL { file.url }
    var updated: Date? { file.updated }
    var hasData: Bool { updated != nil }

    /// The copy is missing or at least `interval` old.
    func needsRefresh(every interval: TimeInterval = GeoSyncSchedule.default.interval!, now: Date = Date()) -> Bool {
        guard let updated else { return true }
        return now.timeIntervalSince(updated) >= interval
    }

    // MARK: - Update

    /// `string` as a source URL: https with a host, nil otherwise. A nil or empty string is the
    /// default source of `kind`.
    nonisolated static func source(from string: String?, kind: GeoKind) -> URL? {
        let text = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.isEmpty ? kind.defaultSource : text),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Downloads the list from `source` and, when it reads as a list of its kind, replaces the copy
    /// in use. Returns whether it did; the reason a download did not is in `phase`.
    @discardableResult
    func update(from source: URL) async -> Bool {
        guard phase != .updating else { return false }
        lastAttempt = Date()
        phase = .updating
        let downloaded: URL
        do {
            downloaded = try await fetch(source)
        } catch {
            phase = .failed(String(localized: "Could not download the list."))
            return false
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path))?[.size] as? Int ?? 0
        guard size > 0, size <= Self.maxDownloadBytes else {
            phase = .failed(String(localized: "The download is not a list of the right kind."))
            return false
        }
        // Read off the main actor: a list is tens of megabytes.
        let kind = self.kind
        let usable = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: downloaded, options: .mappedIfSafe) else { return false }
            return kind.isUsable(data)
        }.value
        guard usable else {
            phase = .failed(String(localized: "The download is not a list of the right kind."))
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(file.url, withItemAt: downloaded)
        } catch {
            do {
                try? FileManager.default.removeItem(at: file.url)
                try FileManager.default.moveItem(at: downloaded, to: file.url)
            } catch {
                phase = .failed(String(localized: "Could not save the list."))
                return false
            }
        }
        // 0600 like the config: the list is the owner's.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        file.invalidate()
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

// MARK: - Sync schedule

/// How often the lists are downloaded again by themselves. One setting for both lists, as in
/// OpenWrt Passwall2's auto-update mode. Off leaves every download to the Sync Now button.
enum GeoSyncSchedule: String, Codable, CaseIterable, Equatable {
    case off
    case daily
    case weekly
    case monthly

    static let `default`: GeoSyncSchedule = .weekly

    /// The age at which a list is downloaded again; nil when nothing is downloaded by itself.
    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        case .monthly: return 30 * 24 * 3600
        }
    }

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .daily: return String(localized: "Every day")
        case .weekly: return String(localized: "Every week")
        case .monthly: return String(localized: "Every month")
        }
    }
}

/// When a list is downloaded by itself: the schedule, the age of the copy, and an hour's wait after a
/// failed try. Pure, so the tests can ask it without a network.
enum GeoSyncPlan {
    static let retryAfter: TimeInterval = 3600

    static func shouldFetch(schedule: GeoSyncSchedule, updated: Date?, lastAttempt: Date?,
                            now: Date = Date()) -> Bool {
        guard let interval = schedule.interval else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryAfter { return false }
        guard let updated else { return true }
        return now.timeIntervalSince(updated) >= interval
    }
}

// MARK: - Sources

/// A place the lists are published, as OpenWrt Passwall2 offers them: the folder holds `geoip.dat`
/// and `geosite.dat`. A mirror is a different server for the same project's files, and whoever
/// serves a list decides what it routes, so the Rules page names the source it uses.
struct GeoSource: Identifiable, Equatable {
    let id: String
    /// A project's name, not translated.
    let title: String
    /// The folder's address, ending in `/`.
    let base: String

    func url(for kind: GeoKind) -> String { base + kind.fileName }

    static let presets: [GeoSource] = [
        GeoSource(id: "loyalsoldier", title: "Loyalsoldier",
                  base: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/"),
        GeoSource(id: "loyalsoldier-cdn", title: "Loyalsoldier (jsDelivr)",
                  base: "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/"),
        GeoSource(id: "metacubex", title: "MetaCubeX",
                  base: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/"),
        GeoSource(id: "metacubex-cdn", title: "MetaCubeX (jsDelivr)",
                  base: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/"),
        GeoSource(id: "chocolate4u", title: "Chocolate4U (Iran)",
                  base: "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/"),
        GeoSource(id: "runetfreedom", title: "runetfreedom (Russia)",
                  base: "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/"),
    ]

    /// The preset whose list of `kind` is at `address`; nil and an empty address are the default.
    static func preset(for address: String?, kind: GeoKind) -> GeoSource? {
        let text = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { text.isEmpty ? $0.id == "loyalsoldier" : $0.url(for: kind) == text }
    }

    /// What the source menu calls the address in use: a preset's name, or the custom address's host.
    static func title(for address: String?, kind: GeoKind) -> String {
        if let preset = preset(for: address, kind: kind) { return preset.title }
        let text = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: text)?.host ?? text
    }
}

// MARK: - Rule patterns

/// The pattern of a Country rule: the code of a list in the geoip file, lower case.
enum GeoIPRule {
    /// `input` as a stored pattern, nil when it cannot be a list name. The published lists use
    /// two-letter country codes and names such as `private`, `cloudflare` or `telegram`.
    static func normalized(_ input: String) -> String? {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (2...40).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "!") })
        else { return nil }
        return code
    }
}

// MARK: - RouteManager

extension RouteManager {
    /// The ranges the enabled Country rules name, by lower-case code. Empty before the list has
    /// been downloaded.
    func geoipRanges() -> [String: [String]] {
        GeoDataFile.geoip.ranges(for: Set(config.rules.filter { $0.enabled && $0.matchType == .geoip }.map { $0.pattern.lowercased() }))
    }

    /// The domain lists the enabled Site rules name, by pattern (`steam`, `category-games@cn`).
    func geositeExpansions() -> [String: GeoSiteExpansion] {
        GeoDataFile.geosite.expansions(for: Set(config.rules.filter { $0.enabled && $0.matchType == .geosite }.map { $0.pattern.lowercased() }))
    }

    func usesGeoData(_ kind: GeoKind) -> Bool {
        config.rules.contains { $0.enabled && $0.matchType == (kind == .ip ? .geoip : .geosite) }
    }

    /// Whether a rule that needs one of the lists is on.
    var usesGeoIP: Bool { usesGeoData(.ip) }
    var usesGeoSite: Bool { usesGeoData(.site) }

    func geoStore(_ kind: GeoKind) -> GeoDataStore { kind == .ip ? .geoip : .geosite }

    func geoSourceURL(_ kind: GeoKind) -> URL? {
        GeoDataStore.source(from: kind == .ip ? config.geoipSourceURL : config.geositeSourceURL, kind: kind)
    }

    /// Uses `address` as the source of `kind` (nil for the default) and downloads from it now: a user
    /// who picks a source wants its list.
    func setGeoSource(_ kind: GeoKind, address: String?) {
        let value = GeoSource.preset(for: address, kind: kind)?.id == "loyalsoldier" ? nil : address
        if kind == .ip { config.geoipSourceURL = value } else { config.geositeSourceURL = value }
        saveConfig()
        Task { await updateGeoData(kind) }
    }

    /// Downloads a list from its configured source and, in Custom mode, puts the routes in again
    /// so the new data takes effect. Returns whether the list was replaced.
    @discardableResult
    func updateGeoData(_ kind: GeoKind) async -> Bool {
        guard let source = geoSourceURL(kind) else { return false }
        let replaced = await geoStore(kind).update(from: source)
        if replaced, usesGeoData(kind) {
            wildcards.requestSync()
            startConfigFollowUp(reconcileListeners: false, reapplyRoutes: true)
        }
        return replaced
    }

    /// Fetches each list a rule needs when the schedule says it is due: missing, or older than the
    /// schedule's interval. Off fetches nothing. Called at launch, after a config save and by the
    /// 12-hour watchdog; a failure is retried an hour later.
    func refreshGeoDataIfNeeded(now: Date = Date()) {
        guard GeoDataStore.autoUpdate else { return }
        for kind in GeoKind.allCases where usesGeoData(kind) {
            let store = geoStore(kind)
            guard store.phase != .updating,
                  GeoSyncPlan.shouldFetch(schedule: config.geoSync, updated: store.updated,
                                          lastAttempt: store.lastAttempt, now: now) else { continue }
            Task { await updateGeoData(kind) }
        }
    }
}
