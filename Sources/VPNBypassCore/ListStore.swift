// ListStore.swift
// The hosts-format blocklists the list rules name, by URL: one copy of each in Application Support,
// the names read from it, and the download that replaces it.
//
// A list is published by a third party and changes without notice, so a new copy replaces the one in
// use only when it looks like the same list: HTTP 200, within the byte cap, a hosts file (HostsList),
// some names, and at least half as many names as the last good copy. Anything else is refused, the
// reason is kept in a small status file beside the list, and the last good copy stays in use. Lists
// are downloaded on the same schedule as the GeoIP and GeoSite lists, and a failure waits as long
// before the next try (GeoSyncSchedule, GeoSyncPlan).

import Foundation

/// What is known about one list, kept as JSON beside it: how many names the copy in use holds, when it
/// was downloaded, when a download was last tried, and why the last one was refused.
struct ListStatus: Codable, Equatable {
    /// Names in the copy in use; 0 when there is none.
    var names = 0
    /// When the copy in use was downloaded; nil when there is none.
    var updated: Date?
    /// When a download was last tried.
    var checked: Date?
    /// Why the last download was refused; nil when it was used.
    var error: String?
}

/// Reads the stored lists, safe to call from any thread: the planner asks from the apply pass. A list's
/// names are kept until its file changes.
final class ListFiles: @unchecked Sendable {

    static let shared = ListFiles(directory: GeoDataFile.defaultDirectory().appendingPathComponent("lists", isDirectory: true))

    let directory: URL
    private let lock = NSLock()
    private var cache: [URL: (stamp: Date, names: [String])] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// The file a list's copy is kept in: named after a digest of its URL, so no URL reaches a path.
    func fileURL(for source: URL) -> URL {
        directory.appendingPathComponent(String(GeoChecksum.sha256(Data(source.absoluteString.utf8)).prefix(24)) + ".hosts")
    }

    func statusURL(for source: URL) -> URL { fileURL(for: source).deletingPathExtension().appendingPathExtension("json") }

    func status(for source: URL) -> ListStatus? {
        guard let data = try? Data(contentsOf: statusURL(for: source)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ListStatus.self, from: data)
    }

    func writeStatus(_ status: ListStatus, for source: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        let url = statusURL(for: source)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// When the copy in use was saved, nil when there is none.
    func updated(for source: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL(for: source).path))?[.modificationDate] as? Date
    }

    /// The names of the copy in use, nil when there is none. Reads the file once per change.
    func names(for source: URL) -> [String]? {
        let file = fileURL(for: source)
        guard let stamp = updated(for: source) else { return nil }
        lock.lock()
        if let hit = cache[source], hit.stamp == stamp { lock.unlock(); return hit.names }
        lock.unlock()
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              case .success(let parsed) = HostsList.parse(data, skipping: ListStore.ownHosts(source)) else { return nil }
        lock.lock(); cache[source] = (stamp, parsed.names); lock.unlock()
        return parsed.names
    }

    /// The names of every list in `sources` that has a copy, keyed by the URL as written in the rule.
    func names(for sources: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for text in sources {
            guard let url = ListStore.source(from: text), let names = names(for: url) else { continue }
            out[text] = names
        }
        return out
    }
}

@MainActor
final class ListStore: ObservableObject {

    static let shared = ListStore(files: .shared)

    /// A download larger than this is refused, and stopped as soon as it passes it. The largest
    /// hosts lists in common use are under 10 MB.
    nonisolated static let maxDownloadBytes = 16 * 1024 * 1024

    /// A new copy with fewer names than this share of the last good one is refused: a list does not
    /// lose half of itself in one update, a broken build or a truncated mirror does.
    nonisolated static let minShareOfLastGood = 0.5

    let files: ListFiles
    /// Lists being downloaded now; a second request for one of them returns at once.
    @Published private(set) var updating: Set<URL> = []
    /// Counts up when a copy changes, so a view that shows it reads again.
    @Published private(set) var revision = 0

    /// Fetches `url` to a local file and returns it, stopping past `maxDownloadBytes`. Replaced in tests.
    var fetch: (URL) async throws -> URL

    /// `configuration` is the download's session; tests give one with a stub protocol.
    init(files: ListFiles, configuration: URLSessionConfiguration = .ephemeral) {
        self.files = files
        fetch = { try await GeoDownloader(limit: ListStore.maxDownloadBytes, configuration: configuration).fetch($0) }
    }

    convenience init(directory: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.init(files: ListFiles(directory: directory), configuration: configuration)
    }

    func status(for source: URL) -> ListStatus? { files.status(for: source) }

    /// `text` as a list URL: https with a host, nil otherwise.
    nonisolated static func source(from text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The names a list never blocks for its own sake: the host it is downloaded from.
    nonisolated static func ownHosts(_ source: URL) -> Set<String> {
        source.host.map { [$0.lowercased()] } ?? []
    }

    // MARK: - Update

    /// Downloads the list at `source` and, when the new copy passes every check, replaces the copy in
    /// use. Returns whether it did; the reason it did not is in the list's status.
    @discardableResult
    func update(from source: URL) async -> Bool {
        guard !updating.contains(source) else { return false }
        updating.insert(source)
        defer { updating.remove(source) }
        var status = files.status(for: source) ?? ListStatus()
        status.checked = Date()

        func refuse(_ reason: String) -> Bool {
            status.error = reason
            files.writeStatus(status, for: source)
            return false
        }

        let downloaded: URL
        do {
            downloaded = try await fetch(source)
        } catch GeoDownloadError.tooLarge {
            return refuse(String(localized: "The download is larger than a list can be."))
        } catch GeoDownloadError.badResponse(let code) {
            return refuse(String(localized: "The server answered HTTP \(code), not the list."))
        } catch {
            return refuse(String(localized: "Could not download the list."))
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path))?[.size] as? Int ?? 0
        guard size <= Self.maxDownloadBytes else {
            return refuse(String(localized: "The download is larger than a list can be."))
        }
        // Read off the main actor: a list is megabytes and hundreds of thousands of lines.
        // The last good count is read from the copy in use itself, so a lost status file cannot let a
        // shrunken list through.
        let skipping = Self.ownHosts(source)
        let stored = files
        let (parsed, lastGood) = await Task.detached(priority: .utility) { () -> (Result<HostsList.Parsed, HostsList.Refusal>?, Int) in
            let lastGood = stored.names(for: source)?.count ?? 0
            guard let data = try? Data(contentsOf: downloaded, options: .mappedIfSafe) else { return (nil, lastGood) }
            return (HostsList.parse(data, skipping: skipping), lastGood)
        }.value
        let names: Int
        switch parsed {
        case .none:
            return refuse(String(localized: "Could not download the list."))
        case .failure(let refusal):
            return refuse(refusal.message)
        case .success(let list):
            names = list.names.count
        }
        guard names > 0 else {
            return refuse(String(localized: "The list holds no names to block."))
        }
        guard Double(names) >= Double(lastGood) * Self.minShareOfLastGood else {
            return refuse(String(localized: "The new copy has \(names) names, under half of the \(lastGood) in use, so the copy in use is kept."))
        }

        // Staged next to the list, then swapped in: the copy in use is never removed first, so a
        // failed save leaves it as it was.
        let destination = files.fileURL(for: source)
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
            return refuse(String(localized: "Could not save the list."))
        }
        // 0600 like the config: the list is the owner's.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        status.names = names
        status.updated = files.updated(for: source) ?? Date()
        status.error = nil
        files.writeStatus(status, for: source)
        revision += 1
        return true
    }

    /// Downloads each list in `sources` that the schedule says is due: no copy yet, or one older than
    /// the schedule's interval, and no failed try within the last `GeoSyncPlan.retryAfter`. Off
    /// downloads nothing. Never runs under tests.
    func refreshIfNeeded(_ sources: [URL], schedule: GeoSyncSchedule, now: Date = Date()) {
        guard GeoDataStore.autoUpdate else { return }
        for source in dueSources(sources, schedule: schedule, now: now) {
            Task { await update(from: source) }
        }
    }

    /// The lists in `sources` the schedule says are due now (see `refreshIfNeeded`).
    func dueSources(_ sources: [URL], schedule: GeoSyncSchedule, now: Date = Date()) -> [URL] {
        sources.filter { source in
            !updating.contains(source)
                && GeoSyncPlan.shouldFetch(schedule: schedule, updated: files.updated(for: source),
                                           lastAttempt: files.status(for: source)?.checked, now: now)
        }
    }
}
