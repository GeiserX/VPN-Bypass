// HostsBlocklist.swift
// Custom mode's Block route, the list half: the names of the hosts-format lists that list rules name
// (HostsList, ListStore) go to the helper's own /etc/hosts section (HostsBlockSection) as exact
// names, as HostsBlockPlanner decides.
//
// Every write to /etc/hosts stalls every lookup on the Mac while mDNSResponder reads the file
// again, for seconds once a large section is in it (2.4 to 3.1 s at 50,000 names, 5.2 to 7.0 s at
// 100,000 when it is added: docs/research/hosts-scale.md). So the section is written as rarely as
// possible:
//   - the set is sent only when it differs from the one the helper last confirmed, and the helper
//     writes nothing when the file already says it (the first send after a launch or a helper
//     restart costs an XPC call, not a write);
//   - it stays across Quit, Pause and a VPN drop: nothing here runs while the app shuts down, and
//     a pause or a drop does not change what the rules block;
//   - it goes when no list rule blocks any more (deleted, off, on another route, a route that is
//     off, another mode), when "Pin listed names in /etc/hosts" is turned off, on Remove All
//     Routes, when config.json fails to load, and when the helper stops (its SIGTERM handler, at
//     shutdown too, so the first launch after a restart writes the section once).

import Foundation

extension RouteManager {

    /// The list rules' URLs whose lists are kept downloaded: every enabled list rule's.
    var blocklistSources: [URL] {
        var seen = Set<URL>()
        return config.rules.filter { $0.enabled && $0.matchType == .list }
            .compactMap { ListStore.source(from: $0.pattern) }
            .filter { seen.insert($0).inserted }
    }

    /// What the list rules of `config` block, from the stored copies.
    func blocklistPlan(for config: Config) -> HostsBlockPlanner.Plan {
        let patterns = config.rules.filter { $0.enabled && $0.matchType == .list }.map(\.pattern)
        guard !patterns.isEmpty else { return HostsBlockPlanner.plan(config, lists: [:], geosite: [:]) }
        return HostsBlockPlanner.plan(config, lists: listStore.files.names(for: patterns))
    }

    /// The names to send for `plan`: none while pinning is off, since writing /etc/hosts is what
    /// that setting allows. Sorted, so the same set is the same section whatever order the lists
    /// are in: two overlapping list rules swapped, or a refresh that moved names around, block
    /// the same names and must not rewrite the file.
    nonisolated static func blockedHostsToSend(_ plan: HostsBlockPlanner.Plan, manageHostsFile: Bool) -> [String] {
        manageHostsFile ? plan.names.sorted() : []
    }

    /// Run a sync soon. Syncs never overlap: one asked for while another runs follows it.
    func requestBlockedHostsSync() {
        guard blockedHostsSyncTask == nil else {
            blockedHostsSyncAgain = true
            return
        }
        blockedHostsSyncTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.blockedHostsSyncAgain = false
                await self.syncBlockedHosts()
            } while self.blockedHostsSyncAgain && !self.isShuttingDown
            self.blockedHostsSyncTask = nil
        }
    }

    /// Waits for the sync running now, and any it queued. For the tests.
    func waitForBlockedHostsSync() async {
        while let task = blockedHostsSyncTask { await task.value }
    }

    /// Sends the names the list rules block to the helper when they differ from what it last
    /// confirmed. Nothing while the app shuts down: the section stays while the app is closed.
    func syncBlockedHosts() async {
        guard !isShuttingDown, !isConfigLoadFailed else { return }
        let hasListRules = config.rules.contains { $0.matchType == .list }
        // The common case, no list rule and nothing sent: no plan, no call.
        if !hasListRules, sentBlockedHosts == [] {
            if hostsBlockPlan != HostsBlockPlanner.Plan() { hostsBlockPlan = HostsBlockPlanner.Plan() }
            if confirmedBlockCounts != [:] { confirmedBlockCounts = [:] }
            return
        }
        let plan = blocklistPlan(for: config)
        if plan != hostsBlockPlan { hostsBlockPlan = plan }
        let names = Self.blockedHostsToSend(plan, manageHostsFile: config.manageHostsFile)
        // With pinning off no name goes to the file, so no list has a confirmed count.
        let confirmations = config.manageHostsFile ? Self.confirmations(of: plan, rules: config.rules) : [:]
        guard names != sentBlockedHosts else {
            // The helper holds this set already, but the plan may give its names to other rules:
            // a list whose names all sit in a list above it, two lists swapped. No call.
            if confirmedBlockCounts != confirmations { confirmedBlockCounts = confirmations }
            // A change whose send failed was undone (the list removed, its URL edited back): the
            // file holds what the rules say again, so that failure is no longer the last word.
            if blockedHostsError != nil { blockedHostsError = nil }
            return
        }
        // Not known, and nothing to block: a section is left only if the file holds one (an
        // earlier run that was stopped before it could remove it). Most Macs never had one.
        if names.isEmpty, sentBlockedHosts == nil, !hostsFileHasBlocklistSection() {
            sentBlockedHosts = []
            confirmedBlockCounts = confirmations
            return
        }
        // A name pinned now that the list blocks (a list rule added above the pinning rule, a
        // list that gained the name, a pin an earlier run left in the file): the pin goes first,
        // or the helper leaves out its row. Only that pin goes: at launch this runs before any
        // route is applied, and pins rebuilt from the routes then would drop every routed name's
        // pin for the route apply to write back, one more write. If the pin stays, nothing is
        // sent, the rows say why, and the next sync tries again.
        seedPinnedHostAddressesIfNeeded()
        let listed = Set(names)
        if !pinnedHostAddresses.isEmpty, !Set(pinnedHostAddresses.keys).isDisjoint(with: listed) {
            let kept = hostsFileText().map { Self.pins(in: $0, without: listed) }
                ?? pinnedHostAddresses.filter { !listed.contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            guard await modifyHostsFile(entries: kept) else {
                blockedHostsError = String(localized: "A pinned name that a list blocks could not be unpinned.")
                return
            }
        }
        await sendBlockedHosts(names, confirming: confirmations)
    }

    /// Each list rule's count in `plan`, with the URL the rule has in `rules`, the config that
    /// plan was made from. An edit keeps a rule's id: a count is the rule's only while its URL
    /// is the same (`listRuleState`).
    nonisolated static func confirmations(of plan: HostsBlockPlanner.Plan, rules: [Rule]) -> [UUID: ListConfirmation] {
        let patterns = Dictionary(rules.map { ($0.id, $0.pattern) }, uniquingKeysWith: { first, _ in first })
        var out: [UUID: ListConfirmation] = [:]
        for (id, names) in plan.accepted {
            guard let pattern = patterns[id] else { continue }
            out[id] = ListConfirmation(pattern: pattern, names: names)
        }
        return out
    }

    /// Whether Remove All Routes takes blocked names out of /etc/hosts: the helper confirmed some,
    /// or, while that is not known, the rules would send some. No while the file holds none, as
    /// with pinning off or after an earlier Remove All.
    var removeAllLiftsListBlocks: Bool {
        if let sent = sentBlockedHosts { return !sent.isEmpty }
        return !Self.blockedHostsToSend(hostsBlockPlan, manageHostsFile: config.manageHostsFile).isEmpty
    }

    /// Takes the section out now, whatever the rules say: Remove All Routes. The next apply puts it
    /// back while a list rule still blocks, as it puts the rule blocks back.
    func removeBlockedHosts(reason: String) async {
        guard !isShuttingDown else { return }
        // After the sync running now, so it cannot write the section back behind this.
        await waitForBlockedHostsSync()
        if sentBlockedHosts == [] { return }
        if sentBlockedHosts == nil, !hostsFileHasBlocklistSection() {
            sentBlockedHosts = []
            confirmedBlockCounts = [:]
            return
        }
        log(.info, "Blocklist: removing the /etc/hosts section (\(reason))")
        await sendBlockedHosts([], confirming: [:])
    }

    /// Forgets what the helper holds and syncs again: after a helper restart (a stopping helper
    /// removes the section) and when a pin of a blocked name went (the pin writer had dropped its
    /// row).
    func resendBlockedHosts() {
        blockedHostsGeneration &+= 1
        sentBlockedHosts = nil
        confirmedBlockCounts = nil
        requestBlockedHostsSync()
    }

    private func sendBlockedHosts(_ names: [String], confirming confirmations: [UUID: ListConfirmation]) async {
        // A send that was already out when the helper restarted reached the old helper: what it
        // confirms says nothing about the new one, which `resendBlockedHosts` asks again.
        let generation = blockedHostsGeneration
        let result: (success: Bool, error: String?)
        if let override = setBlockedHostsOverrideForTests {
            result = await override(names)
        } else {
            guard HelperManager.shared.isHelperInstalled else {
                blockedHostsError = String(localized: "The helper is not running.")
                return
            }
            result = await HelperManager.shared.setBlockedHosts(names: names)
        }
        guard generation == blockedHostsGeneration else { return }
        guard result.success else {
            blockedHostsError = result.error ?? String(localized: "The helper did not answer.")
            log(.error, "Blocklist: the helper did not write the /etc/hosts section: \(result.error ?? "no reason given")")
            return
        }
        sentBlockedHosts = names
        confirmedBlockCounts = confirmations
        blockedHostsError = nil
        if result.error == HelperConstants.hostsUnchanged {
            log(.info, "Blocklist: /etc/hosts already holds \(names.count) blocked name(s); nothing written")
        } else if names.isEmpty {
            log(.info, "Blocklist: /etc/hosts section removed")
        } else {
            log(.success, "Blocklist: \(names.count) name(s) blocked in /etc/hosts")
        }
    }

    /// /etc/hosts, read as the user (the file is 0644). Nil when it cannot be read.
    private func hostsFileText() -> String? {
        hostsFileOverrideForTests.map { $0() } ?? (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8))
    }

    /// Whether /etc/hosts holds a blocklist start marker.
    func hostsFileHasBlocklistSection() -> Bool {
        // Unreadable: assume a section may be there, so the helper is asked.
        guard let text = hostsFileText() else { return true }
        return text.contains(HostsBlockSection.startMarker)
    }

    /// The pins the pinned section of `content` holds, as the file spells and orders them, without
    /// the names in `names` (lowercase). The route apply writes the pins in the order the file
    /// already has them, so it then finds the file unchanged and writes nothing. Parsed as
    /// `HostsPinSection.pinnedAddresses` parses the section.
    nonisolated static func pins(in content: String, without names: Set<String>) -> [(domain: String, ip: String)] {
        var out: [(domain: String, ip: String)] = []
        var seen: Set<String> = []
        var inSection = false
        for line in content.components(separatedBy: "\n") {
            if line.contains(HelperConstants.hostMarkerStart) { inSection = true; continue }
            if line.contains(HelperConstants.hostMarkerEnd) { break }
            guard inSection else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, !fields[0].hasPrefix("#") else { continue }
            let name = fields[1].lowercased()
            guard !names.contains(name), seen.insert(name).inserted else { continue }
            out.append((String(fields[1]), String(fields[0])))
        }
        return out
    }

    /// Once per launch, before the first pin write: the pins already in /etc/hosts, so a pinned
    /// address that is still routed is kept and the write is skipped. Unreadable: start empty.
    func seedPinnedHostAddressesIfNeeded() {
        guard !pinnedHostAddressesSeeded else { return }
        pinnedHostAddressesSeeded = true
        guard pinnedHostAddresses.isEmpty, let text = hostsFileText() else { return }
        pinnedHostAddresses = HostsPinSection.pinnedAddresses(in: text)
    }

    /// A pinned-name write went through with `pinned`: a name that was pinned and is no longer gets
    /// its blocklist row back, which the pin writer had dropped. With nothing confirmed yet, a send
    /// in flight may hold the name and its confirmation would hide the missing row: resend too
    /// (the helper writes nothing when the file already holds the set).
    func pinnedHostsChanged(to pinned: [String: String]) {
        let gone = Set(pinnedHostAddresses.keys).subtracting(pinned.keys)
        pinnedHostAddresses = pinned
        guard !gone.isEmpty else { return }
        if let sent = sentBlockedHosts, gone.isDisjoint(with: sent) { return }
        resendBlockedHosts()
    }

    // MARK: - Downloads

    /// Downloads each list a rule needs when the schedule says it is due, on the GeoIP and GeoSite
    /// lists' schedule. A copy that replaced the one in use syncs the blocklist; one with the same
    /// names writes nothing.
    func refreshBlocklistsIfNeeded(now: Date = Date()) {
        guard GeoDataStore.autoUpdate else { return }
        for source in listStore.dueSources(blocklistSources, schedule: config.geoSyncSchedule, now: now) {
            Task { await updateBlocklist(from: source) }
        }
    }

    /// Downloads the list at `source` now. Returns whether the copy in use was replaced.
    @discardableResult
    func updateBlocklist(from source: URL) async -> Bool {
        let replaced = await listStore.update(from: source)
        if replaced {
            requestBlockedHostsSync()
        } else if listStore.status(for: source)?.error != nil {
            scheduleBlocklistRetry()
        }
        return replaced
    }

    /// After a failed download, tries again once the wait is over (GeoSyncPlan.retryAfter).
    private func scheduleBlocklistRetry() {
        guard GeoDataStore.autoUpdate, config.geoSyncSchedule.interval != nil else { return }
        blocklistRetryTask?.cancel()
        blocklistRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(GeoSyncPlan.retryAfter, 0) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.blocklistRetryTask = nil
            self.refreshBlocklistsIfNeeded()
        }
    }

    // MARK: - Row state

    /// A list rule's state, for its row (the plan of the last sync) and `vpnb rule.list` (a plan
    /// of the config the reply describes).
    func listRuleState(_ rule: Rule, plan: HostsBlockPlanner.Plan? = nil, config: Config? = nil) -> ListRuleState {
        let source = ListStore.source(from: rule.pattern)
        return ListRuleState(rule: rule, plan: plan ?? hostsBlockPlan, manageHostsFile: (config ?? self.config).manageHostsFile,
                             downloading: source.map { listStore.updating.contains($0) } ?? false,
                             status: source.flatMap { listStore.status(for: $0) },
                             helperError: blockedHostsError,
                             confirmed: confirmedBlockCounts?[rule.id].flatMap { $0.pattern == rule.pattern ? $0.names : nil },
                             helperReady: HelperManager.shared.isHelperInstalled)
    }
}

/// A list rule's names in the set the helper confirmed: how many it added, from which URL.
struct ListConfirmation: Equatable {
    var pattern: String
    var names: Int
}

/// What a list rule does now, as its row and `vpnb rule.list` say it.
struct ListRuleState: Equatable {

    enum Kind: String, Equatable {
        /// The helper confirmed its names in the section.
        case blocked
        /// The helper confirmed none of its names, and the helper is not ready or the last send
        /// failed: nothing of this list is blocked.
        case notBlocked
        /// The helper is ready and has not confirmed its names yet: the send is on its way.
        case pending
        /// The first copy is downloading.
        case downloading
        /// No copy yet: never downloaded, or every download was refused.
        case noCopy
        /// Over the cap, alone or with the lists above it.
        case refused
        /// "Pin listed names in /etc/hosts" is off.
        case pinningOff
        case notBlockRoute
        case routeOff
        case notCustomMode
        case off
    }

    var kind: Kind
    /// Names this list adds to the section (names a list above holds are not counted again).
    var names = 0
    /// Why it blocks nothing, or why the last download or write failed.
    var error: String?
    /// When the copy in use was downloaded.
    var updated: Date?
    /// It adds no names because the rules above it hold every one (`HostsBlockPlanner.Plan.coveredAbove`).
    var coveredAbove = false

    init(kind: Kind, names: Int = 0, error: String? = nil, updated: Date? = nil) {
        self.kind = kind
        self.names = names
        self.error = error
        self.updated = updated
    }

    /// `confirmed`: how many names of this rule are in the plan the helper last confirmed, nil when
    /// it confirmed none. Only that says "blocked", with that count: a plan of the last sync or of
    /// a config may hold names the helper never wrote.
    init(rule: Rule, plan: HostsBlockPlanner.Plan, manageHostsFile: Bool, downloading: Bool,
         status: ListStatus?, helperError: String?, confirmed: Int?, helperReady: Bool,
         in bundle: Bundle = .main) {
        updated = status?.updated
        guard rule.enabled else { kind = .off; return }
        if let inactive = plan.inactive[rule.id] {
            switch inactive {
            case .notBlockRoute: kind = .notBlockRoute
            case .routeOff: kind = .routeOff
            case .notCustomMode: kind = .notCustomMode
            case .noCopy:
                kind = downloading ? .downloading : .noCopy
                error = status?.error
            }
            return
        }
        if let refusal = plan.refused[rule.id] {
            kind = .refused
            switch refusal {
            case .tooLarge(let count, let limit):
                names = count
                error = String(localized: "It holds \(count) names, over the limit of \(limit).", bundle: bundle)
            case .overTotal(let count, let limit):
                names = count
                error = String(localized: "Its \(count) names would take all lists past the limit of \(limit).", bundle: bundle)
            }
            return
        }
        names = plan.accepted[rule.id] ?? 0
        guard manageHostsFile else { kind = .pinningOff; return }
        guard let confirmed else {
            names = 0
            if let helperError {
                kind = .notBlocked
                error = helperError
            } else if !helperReady {
                kind = .notBlocked
                error = String(localized: "The helper is not running.", bundle: bundle)
            } else {
                kind = .pending
            }
            return
        }
        names = confirmed
        kind = .blocked
        coveredAbove = plan.coveredAbove.contains(rule.id)
        // A write that failed outranks a refused refresh: the names in the file are the old set.
        error = helperError ?? status?.error
    }

    /// The row's line under the list's URL.
    func line(now: Date = Date(), in bundle: Bundle = .main) -> String {
        switch kind {
        case .off:
            return String(localized: "Off.", bundle: bundle)
        case .notBlockRoute:
            return String(localized: "A list blocks names only on the Block route.", bundle: bundle)
        case .routeOff:
            return String(localized: "Its route is off, so this list blocks nothing.", bundle: bundle)
        case .notCustomMode:
            return String(localized: "Lists block names only in Custom mode.", bundle: bundle)
        case .downloading:
            return String(localized: "Downloading…", bundle: bundle)
        case .noCopy:
            guard let error else { return String(localized: "Not downloaded yet.", bundle: bundle) }
            return String(localized: "Not downloaded: \(error)", bundle: bundle)
        case .refused:
            return String(localized: "Not blocked. \(error ?? "")", bundle: bundle)
        case .notBlocked:
            return String(localized: "Not blocked: \(error ?? "")", bundle: bundle)
        case .pending:
            return String(localized: "Not blocked yet.", bundle: bundle)
        case .pinningOff:
            return String(localized: "Blocks nothing while Pin listed names in /etc/hosts is off (General).", bundle: bundle)
        case .blocked:
            var line: String
            if names == 0 {
                // The cause only when it is the cause: a list can add none for other reasons, such
                // as names that are the app's own download hosts, which no list blocks.
                line = coveredAbove
                    ? String(localized: "Adds no names: the rules above it already cover every one.", bundle: bundle)
                    : String(localized: "Adds no names of its own.", bundle: bundle)
            } else {
                let count = names == 1 ? String(localized: "1 name blocked", bundle: bundle)
                                       : String(localized: "\(names) names blocked", bundle: bundle)
                line = count
                if let updated {
                    let when = RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: now)
                    line = String(localized: "\(count), updated \(when)", bundle: bundle)
                }
            }
            if let error { line += "\n" + String(localized: "Last try failed: \(error)", bundle: bundle) }
            return line
        }
    }
}
