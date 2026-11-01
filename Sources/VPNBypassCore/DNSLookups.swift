// DNSLookups.swift
// The opt-in DNS Lookups page (#176): which names this Mac looks up, most frequent first, so a
// user who does not know what to bypass can pick from what the Mac actually uses.
//
// The helper runs the capture (Helper/DNSCapture.swift) and hands over bare names; this side
// counts them. The counts live in memory only: they are cleared when the page is turned off or
// the app quits, and no name is written to the log or to disk.

import Foundation

/// How often each name was looked up.
struct DNSLookupTally: Equatable {
    struct Entry: Identifiable, Equatable {
        let name: String
        var count: Int
        var lastSeen: Date
        var id: String { name }
    }

    /// Plenty for a day of browsing; past it the names not seen for longest go first.
    static let limit = 5000

    private(set) var entries: [String: Entry] = [:]

    /// One drain's names. A name counts once per drain, so the A, AAAA and HTTPS queries a
    /// browser sends together for one visit are one lookup, not three.
    mutating func record(_ names: [String], at date: Date) {
        for name in Set(names) {
            entries[name, default: Entry(name: name, count: 0, lastSeen: date)].count += 1
            entries[name]?.lastSeen = date
        }
        if entries.count > Self.limit {
            let oldest = entries.values.sorted { $0.lastSeen < $1.lastSeen }.prefix(entries.count - Self.limit)
            for entry in oldest { entries[entry.name] = nil }
        }
    }

    /// Most looked-up first; `query` keeps the names that contain it.
    func ranked(matching query: String = "") -> [Entry] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.values
            .filter { term.isEmpty || $0.name.contains(term) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

/// The lookups the resolver made by appending a DNS search domain to a name, as it does when
/// the name gets no answer: with search domains `corp.example` and `lab.example`, a failed `host.example.com`
/// is asked again as `host.example.com.corp.example` and `host.example.com.lab.example`, and
/// each retry is one more row on the page. They are folded under the name they came from.
/// A single-label name is left alone: `intranet` asked as `intranet.corp.example` is the name
/// the user means, not a retry.
enum SearchDomainRetries {
    /// The search domains of the system resolver, in order, each once, from `scutil --dns`
    /// ("search domain[0] : corp.example").
    static func searchDomains(fromScutilDNS output: String) -> [String] {
        var out: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("search domain["), let colon = trimmed.firstIndex(of: ":") else { continue }
            let domain = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if !domain.isEmpty && !out.contains(domain) { out.append(domain) }
        }
        return out
    }

    /// The search domains after one read of `scutil --dns`: none when the read failed, so a
    /// resolver state that cannot be read never hides a name.
    static func searchDomains(afterRead output: String?) -> [String] {
        output.map { searchDomains(fromScutilDNS: $0) } ?? []
    }

    /// The names that are another of `names`, a name with a dot in it, with one of
    /// `searchDomains` appended.
    static func retries(among names: some Collection<String>, searchDomains: [String]) -> Set<String> {
        guard !searchDomains.isEmpty else { return [] }
        let all = Set(names)
        var out: Set<String> = []
        for name in all {
            for domain in searchDomains where name.hasSuffix("." + domain) {
                let base = String(name.dropLast(domain.count + 1))
                if base.contains("."), all.contains(base) {
                    out.insert(name)
                    break
                }
            }
        }
        return out
    }
}

@MainActor
final class DNSLookupsMonitor: ObservableObject {
    static let shared = DNSLookupsMonitor()

    static let drainInterval: TimeInterval = 3

    /// Settable from tests, which seed the doc screenshot with it.
    @Published var tally = DNSLookupTally()
    /// The system resolver's search domains (`SearchDomainRetries`), read when watching starts
    /// and again each minute while it runs, since a VPN brings its own. Settable from tests.
    @Published var searchDomains: [String] = []
    /// False keeps `searchDomains` as a test set it.
    var readsSearchDomains = true
    private var searchDomainsReadAt: Date?
    @Published private(set) var isCapturing = false
    /// Why the capture is not running although the page is on, such as a helper that is down.
    @Published private(set) var problem: String?
    /// When the counts started: the capture's first start, or the last Clear.
    @Published var since: Date?
    /// Learn a site: the open window, or the last one's names until the user dismisses them.
    /// Settable from tests, which seed the doc screenshot with it.
    @Published var learning: SiteLearning?

    private var timer: Timer?
    private var tickInFlight = false
    /// Bumped by Clear and by turning off, so a drain already on its way is not counted
    /// into the fresh list.
    private var generation = 0
    /// Closes the learning window when its time is up.
    private var learnTask: Task<Void, Never>?

    private var enabled: Bool { RouteManager.shared.config.dnsLookupsEnabled }
    /// The capture runs while the page watches, or while a learning window is open.
    private var wanted: Bool { enabled || learning?.isOpen == true }

    /// The page's switch. Saved, so a capture the user turned on resumes after a relaunch.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        RouteManager.shared.config.dnsLookupsEnabled = on
        RouteManager.shared.saveConfig()
        RouteManager.shared.log(.info, on ? "DNS Lookups turned on" : "DNS Lookups turned off; the list was cleared")
        // An open learning window keeps the capture running, so the count is cleared here.
        if !on { clearCount() }
        followConfig()
    }

    /// Starts or stops to match the saved switch: at launch, and after a config import. At
    /// launch it runs whether or not the helper is ready yet; until it is, each tick shows why
    /// and tries again, so a helper repaired later starts the capture without a relaunch.
    func followConfig() {
        if enabled, since == nil { since = Date() }
        if wanted, timer == nil { start() }
        if !wanted, timer != nil { stop() }
    }

    /// Also empties the helper's buffer, so a name looked up just before Clear does not come
    /// back with the next drain.
    func clear() {
        generation += 1
        tally = DNSLookupTally()
        since = Date()
        // An open learning window still gets the names this drain takes out.
        if isCapturing { Task { learnFrom(await HelperManager.shared.drainDNSQueries()) } }
    }

    /// Opens a learning window of `SiteLearning.duration`. When the page is not watching, the
    /// capture starts for the window alone and stops after it. Names the helper holds from
    /// before the click are drained first, into the count only.
    func startLearning() async {
        guard learning?.isOpen != true else { return }
        if isCapturing { await drainNow() }
        // A second click that waited on the same drain finds the window already open.
        guard learning?.isOpen != true else { return }
        learning = SiteLearning(started: Date())
        followConfig()
        learnTask?.cancel()
        learnTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SiteLearning.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopLearning()
        }
    }

    /// Closes the window, at its end or when the user stops it early. The names asked until
    /// now are drained into it first. The names stay on the page until `dismissLearning`.
    func stopLearning() async {
        guard learning?.isOpen == true else { return }
        learnTask?.cancel()
        learnTask = nil
        if isCapturing { await drainNow() }
        learning?.close()
        followConfig()
    }

    /// Forgets the last window's names.
    func dismissLearning() {
        learnTask?.cancel()
        learnTask = nil
        learning = nil
        followConfig()
    }

    /// One drain now, after the one already on its way. The wait outlasts the helper call's
    /// own 10 s deadline, so a slow drain is never cut off before its names are recorded.
    private func drainNow() async {
        var waits = 0
        while tickInFlight && waits < 600 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waits += 1
        }
        await tick()
    }

    /// One drain's names into the open learning window. A drain that lands just after the
    /// window's end holds names asked before it. An empty drain is recorded once, so the window
    /// knows the capture ran.
    private func learnFrom(_ names: [String]?) {
        guard let names, let window = learning, window.isOpen, !names.isEmpty || !window.heard else { return }
        learning?.record(names, at: min(Date(), window.ends))
    }

    private func clearCount() {
        generation += 1
        tally = DNSLookupTally()
        since = nil
    }

    private func start() {
        timer?.invalidate()
        timer = Timer.scheduledInCommonModes(withTimeInterval: Self.drainInterval, repeats: true) { _ in
            Task { @MainActor in await DNSLookupsMonitor.shared.tick() }
        }
        Task { await tick() }
    }

    /// Reads the search domains at the first tick and once a minute after.
    private func readSearchDomainsIfDue() async {
        guard readsSearchDomains, searchDomainsReadAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        searchDomainsReadAt = Date()
        let result = await RouteManager.shared.runProcessAsync("/usr/sbin/scutil", arguments: ["--dns"], timeout: 3.0)
        let domains = SearchDomainRetries.searchDomains(afterRead: result?.exitCode == 0 ? result?.output : nil)
        if domains != searchDomains { searchDomains = domains }
    }

    private func stop() {
        generation += 1
        searchDomainsReadAt = nil
        timer?.invalidate()
        timer = nil
        isCapturing = false
        problem = nil
        tally = DNSLookupTally()
        since = nil
        Task { await HelperManager.shared.stopDNSCapture() }
    }

    /// Drains the helper; when the capture is not running (first tick, a helper restart, a lease
    /// that ran out), starts it again. Starting is idempotent in the helper.
    private func tick() async {
        guard wanted, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }
        // Read beside the capture, never before it: `scutil` can take seconds, and the names
        // looked up while it runs would be missed.
        Task { await readSearchDomainsIfDue() }

        let drainGeneration = generation
        if isCapturing, let names = await HelperManager.shared.drainDNSQueries() {
            guard wanted else { return }
            // Clear and Stop Watching start the count again; the learning window keeps the
            // names, since the helper no longer has them.
            if enabled, generation == drainGeneration, !names.isEmpty { tally.record(names, at: Date()) }
            learnFrom(names)
            return
        }
        // At launch this runs before the helper check finishes: say so on the page, without a
        // warning in the log each launch, and try again next tick.
        guard HelperManager.shared.isHelperInstalled else {
            problem = String(localized: "The privileged helper is not running.")
            isCapturing = false
            return
        }
        let failure = await HelperManager.shared.startDNSCapture()
        guard wanted else { return }
        if failure != problem, let failure {
            RouteManager.shared.log(.warning, "DNS Lookups could not start: \(failure)")
        }
        problem = failure
        isCapturing = failure == nil
    }
}
