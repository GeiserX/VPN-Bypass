// GeoDataStore.swift
// The data behind Country (GeoIP) and Site (GeoSite) rules: a `geoip.dat` and a `geosite.dat` kept
// in Application Support, the ranges and domains read from them, and the opt-in download that
// replaces them.
//
// This is the only place the app fetches data over HTTP. Nothing is fetched until a rule needs a
// list (or the user presses Update); the source is shown on the Rules page and can be changed in
// the config (`geoipSourceURL`, `geositeSourceURL`) to a mirror, which matters where GitHub is
// blocked. A download only replaces the copy in use after it reads as a list of its kind, so a
// failed, truncated or wrong download, or one that does not match the checksum its source
// publishes, leaves the last good copy in place. Every range a country lists is held to a stricter
// policy than a CIDR rule (GeoIPRangePolicy: nothing shorter than /8, no private or reserved space),
// so a list cannot take over the routing table, and a site list reaches the routing table only
// through the wildcard engine's own guards (WildcardSafetyGuard, the limiter).

import CryptoKit
import Foundation

/// Which file: country ranges, or domain lists.
enum GeoKind: String, CaseIterable {
    case ip
    case site

    var fileName: String { self == .ip ? "geoip.dat" : "geosite.dat" }

    /// The first preset's list: Loyalsoldier's, the default of OpenWrt Passwall2 and the general
    /// build the others start from. The presets are the one place a source address is written.
    var defaultSource: String { GeoSource.presets[0].url(for: self) }

    func isUsable(_ data: Data) -> Bool {
        self == .ip ? GeoIPDat.isUsable(data) : GeoSiteDat.isUsable(data)
    }
}

/// Reads one of the files, safe to call from any thread: the wildcard planner and the route compiler
/// both ask for it. Results are kept until the file changes.
final class GeoDataFile: @unchecked Sendable {

    static let geoip = GeoDataFile(kind: .ip, directory: GeoDataFile.defaultDirectory())
    static let geosite = GeoDataFile(kind: .site, directory: GeoDataFile.defaultDirectory())

    /// A country with more ranges than this is not routed at all, and its row says so: each range is a
    /// kernel route, and a part of a country would send some of it one way and some another. The
    /// real lists run from a few dozen ranges to 36,000 (GB), with the US at 127,000.
    static let maxRangesPerCountry = 50_000

    let kind: GeoKind
    let url: URL

    private let lock = NSLock()
    private var stamp: Date?
    private var rangesByCode: [String: [String]] = [:]
    /// Codes the file does not hold, so asking again does not read the whole file again.
    private var missingCodes = Set<String>()
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
        missingCodes = []
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
        let missing = codes.subtracting(rangesByCode.keys).subtracting(missingCodes)
        if !missing.isEmpty, let data = data() {
            let found = GeoIPDat.ranges(for: missing, in: data)
            for (code, ranges) in found { rangesByCode[code] = ranges }
            missingCodes.formUnion(missing.subtracting(found.keys))
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
    var fetch: (URL) async throws -> URL = { try await GeoDownloader(limit: GeoDataStore.maxDownloadBytes).fetch($0) }
    /// The checksum file a source publishes next to a list (`geoip.dat.sha256sum`), nil when it has
    /// none or it cannot be read. Never reaches the network under tests unless a test sets it.
    var fetchChecksum: (URL) async -> String? = { await GeoDataStore.downloadChecksum($0) }

    private static func downloadChecksum(_ url: URL) async -> String? {
        guard autoUpdate, let file = try? await GeoDownloader(limit: 4096).fetch(url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        return try? String(contentsOf: file, encoding: .utf8)
    }

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
    /// Written next to the list when it was used without a checksum (a custom address that
    /// publishes none), removed when a checked one replaces it.
    private var uncheckedMarker: URL { file.url.appendingPathExtension("unchecked") }
    /// The list in use was not checked against a published checksum.
    var isUnchecked: Bool { hasData && FileManager.default.fileExists(atPath: uncheckedMarker.path) }
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

    /// A source chosen while another download is running: the latest choice wins and is fetched
    /// when that one ends, instead of being dropped and leaving the first one's list in place.
    private var pendingSource: URL?
    private var activeSource: URL?

    /// Downloads the list from `source` and, when it reads as a complete list of its kind, replaces the
    /// copy in use. Returns whether it did; the reason a download did not is in `phase`.
    @discardableResult
    func update(from source: URL) async -> Bool {
        if phase == .updating {
            // The latest choice wins: choosing the source that is running again leaves nothing queued
            // after it, and choosing another queues that one in place of any earlier choice.
            pendingSource = source == activeSource ? nil : source
            return false
        }
        lastAttempt = Date()
        phase = .updating
        activeSource = source
        pendingSource = nil
        let downloaded: URL
        do {
            downloaded = try await fetch(source)
        } catch GeoDownloadError.tooLarge {
            return await finish(failed: String(localized: "The download is larger than a list can be."), from: source)
        } catch {
            return await finish(failed: String(localized: "Could not download the list."), from: source)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        // Another source was chosen meanwhile: this list is not the one wanted, so it is dropped
        // unread and the chosen one is fetched.
        if let next = pendingSource, next != source {
            return await finish(failed: nil, from: source)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path))?[.size] as? Int ?? 0
        guard size > 0, size <= Self.maxDownloadBytes else {
            return await finish(failed: String(localized: "The download is not a list of the right kind."), from: source)
        }
        // The digest the source publishes next to the list: a truncated file or a mirror that serves
        // another file is refused before it is read. Every preset publishes one, so a preset whose
        // digest cannot be read fails and keeps the list in use; only a custom address that publishes
        // none is used unchecked, and the list's status line says so.
        let expected = GeoChecksum.digest(in: await fetchChecksum(GeoChecksum.url(for: source)) ?? "")
        if expected == nil, GeoSource.presets.contains(where: { $0.url(for: kind) == source.absoluteString }) {
            return await finish(failed: String(localized: "Could not download the checksum its source publishes."), from: source)
        }
        // Read off the main actor: a list is tens of megabytes. The whole file must read.
        let kind = self.kind
        let check = await Task.detached(priority: .utility) { () -> (usable: Bool, digest: String?) in
            guard let data = try? Data(contentsOf: downloaded, options: .mappedIfSafe) else { return (false, nil) }
            return (kind.isUsable(data), expected == nil ? nil : GeoChecksum.sha256(data))
        }.value
        if let expected, check.digest != expected {
            return await finish(failed: String(localized: "The download does not match the checksum its source publishes."), from: source)
        }
        guard check.usable else {
            return await finish(failed: String(localized: "The download is not a list of the right kind."), from: source)
        }
        // Another source was chosen while this one was checked: the copy in use is left alone, and the
        // chosen one is fetched. Installing this one would keep it if the chosen one then failed.
        if let next = pendingSource, next != source {
            return await finish(failed: nil, from: source)
        }
        // Staged next to the list, then swapped in: the copy in use is never removed first, so a
        // failed save (a full disk, a folder that cannot be written) leaves it as it was.
        let destination = file.url
        let staged = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial")
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: downloaded, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return await finish(failed: String(localized: "Could not save the list."), from: source)
        }
        // 0600 like the config: the list is the owner's.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        if expected == nil {
            FileManager.default.createFile(atPath: uncheckedMarker.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.removeItem(at: uncheckedMarker)
        }
        file.invalidate()
        phase = .idle
        revision += 1
        return await finish(failed: nil, from: source, replaced: true)
    }

    /// Ends a download: records why it failed (nil when it did not), and starts the source chosen
    /// while it ran, if one was.
    private func finish(failed reason: String?, from source: URL, replaced: Bool = false) async -> Bool {
        activeSource = nil
        phase = reason.map { .failed($0) } ?? .idle
        if let next = pendingSource, next != source {
            pendingSource = nil
            phase = .idle
            return await update(from: next)
        }
        pendingSource = nil
        return replaced
    }
}

// MARK: - Checksum

/// The `<file>.sha256sum` the presets publish next to each list: one line, the hex digest first.
enum GeoChecksum {
    static func url(for source: URL) -> URL {
        URL(string: source.absoluteString + ".sha256sum") ?? source.appendingPathExtension("sha256sum")
    }

    /// The lower-case hex digest at the start of `text`, nil when it does not start with one (an error
    /// page, a source that publishes none).
    static func digest(in text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first,
              first.count == 64, first.allSatisfy(\.isHexDigit) else { return nil }
        return first.lowercased()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    /// How long after a failed try the next one waits. A variable so a test can shorten it.
    nonisolated(unsafe) static var retryAfter: TimeInterval = 3600

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

    /// The first is the default: what a config with no source set uses.
    /// Each one publishes a `.sha256sum` next to each file, which a download is checked against.
    /// jsDelivr's mirrors are left out: they cache a file and its checksum apart, so the two can
    /// disagree for days (Custom URL still takes such a mirror).
    static let presets: [GeoSource] = [
        GeoSource(id: "loyalsoldier", title: "Loyalsoldier",
                  base: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/"),
        GeoSource(id: "chocolate4u", title: "Chocolate4U (Iran)",
                  base: "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/"),
        GeoSource(id: "metacubex", title: "MetaCubeX",
                  base: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/"),
        GeoSource(id: "runetfreedom", title: "runetfreedom (Russia)",
                  base: "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/"),
    ]

    /// The default preset's id.
    static var defaultID: String { presets[0].id }

    /// The preset whose list of `kind` is at `address`; nil and an empty address are the default.
    static func preset(for address: String?, kind: GeoKind) -> GeoSource? {
        let text = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { text.isEmpty ? $0.id == defaultID : $0.url(for: kind) == text }
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

/// What a downloaded country list may route or block. The list comes from a server, so a broken or
/// hostile one must not take over the routing table with a few short prefixes (four /2 ranges cover
/// all of IPv4), nor send the Mac's own networks (the LAN, a VPN's internal DNS, loopback) somewhere.
enum GeoIPRangePolicy {
    /// No real country list goes below /8 (the shortest in the published lists is one /7, in the US).
    static let shortestPrefix = 8

    /// Address space that is not any country's: private, loopback, link-local, carrier-grade NAT,
    /// benchmarking, multicast and reserved. Only the `private` list may name it.
    static let specialUse = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
                             "172.16.0.0/12", "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/3"]

    static func allows(_ range: String, code: String) -> Bool {
        guard let (network, prefix) = RouteCIDR.parse(range), let start = WildcardIPv4.parse(network),
              prefix >= shortestPrefix, !DestinationInstallPolicy.refusesInstall(range) else { return false }
        if code.lowercased() == "private" { return true }
        return !specialUse.contains { overlaps(start, prefix, $0) }
    }

    /// Two IPv4 ranges overlap when one holds the other's start.
    private static func overlaps(_ start: UInt32, _ prefix: Int, _ other: String) -> Bool {
        guard let (network, otherPrefix) = RouteCIDR.parse(other), let otherStart = WildcardIPv4.parse(network) else { return false }
        let shorter = min(prefix, otherPrefix)
        let mask: UInt32 = shorter == 0 ? 0 : ~UInt32(0) << UInt32(32 - shorter)
        return start & mask == otherStart & mask
    }
}

// MARK: - RouteManager

extension RouteManager {
    /// The ranges the enabled Country rules name, by lower-case code. Empty before the list has
    /// been downloaded.
    func geoipRanges() -> [String: [String]] {
        // A country over the limit routes nothing, and its row says why; never a part of it.
        GeoDataFile.geoip.ranges(for: Set(config.rules.filter { $0.enabled && $0.matchType == .geoip }.map { $0.pattern.lowercased() }))
            .filter { $0.value.count <= GeoDataFile.maxRangesPerCountry }
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
        let value = GeoSource.preset(for: address, kind: kind)?.id == GeoSource.defaultID ? nil : address
        if kind == .ip { config.geoipSourceURL = value } else { config.geositeSourceURL = value }
        saveConfig()
        Task { await updateGeoData(kind) }
    }

    /// Downloads a list from its configured source and, in Custom mode, puts the routes in again
    /// so the new data takes effect. Returns whether the list was replaced.
    @discardableResult
    func updateGeoData(_ kind: GeoKind) async -> Bool {
        guard let source = geoSourceURL(kind) else { return false }
        let store = geoStore(kind)
        let replaced = await store.update(from: source)
        if replaced {
            geoRetryTasks[kind]?.cancel()
            geoRetryTasks[kind] = nil
            if usesGeoData(kind) {
                wildcards.requestSync()
                startConfigFollowUp(reconcileListeners: false, reapplyRoutes: true)
            }
        } else if case .failed = store.phase {
            scheduleGeoRetry(kind)
        }
        return replaced
    }

    /// After a failed download, tries again once the wait is over, if a rule still needs the list
    /// and the schedule still allows it: without this a failure with nothing else to trigger a
    /// refresh would leave the rule routing nothing until the next launch or the 12-hour watchdog.
    func scheduleGeoRetry(_ kind: GeoKind) {
        guard GeoDataStore.autoUpdate, usesGeoData(kind), config.geoSyncSchedule.interval != nil else { return }
        geoRetryTasks[kind]?.cancel()
        geoRetryTasks[kind] = Task { [weak self] in
            let wait = UInt64(max(GeoSyncPlan.retryAfter, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self else { return }
            self.geoRetryTasks[kind] = nil
            self.refreshGeoDataIfNeeded()
        }
    }

    /// Fetches each list a rule needs when the schedule says it is due: missing, or older than the
    /// schedule's interval. Off fetches nothing. Called at launch, after a config save and by the
    /// 12-hour watchdog; a failure is retried an hour later.
    func refreshGeoDataIfNeeded(now: Date = Date()) {
        guard GeoDataStore.autoUpdate else { return }
        for kind in GeoKind.allCases where usesGeoData(kind) {
            let store = geoStore(kind)
            guard store.phase != .updating,
                  GeoSyncPlan.shouldFetch(schedule: config.geoSyncSchedule, updated: store.updated,
                                          lastAttempt: store.lastAttempt, now: now) else { continue }
            Task { await updateGeoData(kind) }
        }
    }
}
