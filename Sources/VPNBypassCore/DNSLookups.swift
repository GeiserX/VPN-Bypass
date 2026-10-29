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

@MainActor
final class DNSLookupsMonitor: ObservableObject {
    static let shared = DNSLookupsMonitor()

    static let drainInterval: TimeInterval = 3

    /// Settable from tests, which seed the doc screenshot with it.
    @Published var tally = DNSLookupTally()
    @Published private(set) var isCapturing = false
    /// Why the capture is not running although the page is on, such as a helper that is down.
    @Published private(set) var problem: String?
    /// When the counts started: the capture's first start, or the last Clear.
    @Published var since: Date?

    private var timer: Timer?
    private var tickInFlight = false
    /// Bumped by Clear and by turning off, so a drain already on its way is not counted
    /// into the fresh list.
    private var generation = 0

    private var enabled: Bool { RouteManager.shared.config.dnsLookupsEnabled }

    /// The page's switch. Saved, so a capture the user turned on resumes after a relaunch.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        RouteManager.shared.config.dnsLookupsEnabled = on
        RouteManager.shared.saveConfig()
        RouteManager.shared.log(.info, on ? "DNS Lookups turned on" : "DNS Lookups turned off; the list was cleared")
        followConfig()
    }

    /// Starts or stops to match the saved switch: at launch, and after a config import. At
    /// launch it runs whether or not the helper is ready yet; until it is, each tick shows why
    /// and tries again, so a helper repaired later starts the capture without a relaunch.
    func followConfig() {
        if enabled, timer == nil { start() }
        if !enabled, timer != nil { stop() }
    }

    func clear() {
        generation += 1
        tally = DNSLookupTally()
        since = Date()
    }

    private func start() {
        if since == nil { since = Date() }
        timer?.invalidate()
        timer = Timer.scheduledInCommonModes(withTimeInterval: Self.drainInterval, repeats: true) { _ in
            Task { @MainActor in await DNSLookupsMonitor.shared.tick() }
        }
        Task { await tick() }
    }

    private func stop() {
        generation += 1
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
        guard enabled, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        let drainGeneration = generation
        if isCapturing, let names = await HelperManager.shared.drainDNSQueries() {
            guard enabled, generation == drainGeneration else { return }
            if !names.isEmpty { tally.record(names, at: Date()) }
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
        guard enabled else { return }
        if failure != problem, let failure {
            RouteManager.shared.log(.warning, "DNS Lookups could not start: \(failure)")
        }
        problem = failure
        isCapturing = failure == nil
    }
}
