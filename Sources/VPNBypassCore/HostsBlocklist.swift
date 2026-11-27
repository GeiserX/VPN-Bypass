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
//     Routes, and when the helper stops (its SIGTERM handler).

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
    /// that setting allows.
    nonisolated static func blockedHostsToSend(_ plan: HostsBlockPlanner.Plan, manageHostsFile: Bool) -> [String] {
        manageHostsFile ? plan.names : []
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
            return
        }
        let plan = blocklistPlan(for: config)
        if plan != hostsBlockPlan { hostsBlockPlan = plan }
        let names = Self.blockedHostsToSend(plan, manageHostsFile: config.manageHostsFile)
        guard names != sentBlockedHosts else { return }
        // Not known, and nothing to block: a section is left only if the file holds one (an
        // earlier run that was stopped before it could remove it). Most Macs never had one.
        if names.isEmpty, sentBlockedHosts == nil, !hostsFileHasBlocklistSection() {
            sentBlockedHosts = []
            return
        }
        await sendBlockedHosts(names)
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
            return
        }
        log(.info, "Blocklist: removing the /etc/hosts section (\(reason))")
        await sendBlockedHosts([])
    }

    /// Forgets what the helper holds and syncs again: after a helper restart (a stopping helper
    /// removes the section) and when a pin of a blocked name went (the pin writer had dropped its
    /// row).
    func resendBlockedHosts() {
        blockedHostsGeneration &+= 1
        sentBlockedHosts = nil
        requestBlockedHostsSync()
    }

    private func sendBlockedHosts(_ names: [String]) async {
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
        blockedHostsError = nil
        if result.error == HelperConstants.hostsUnchanged {
            log(.info, "Blocklist: /etc/hosts already holds \(names.count) blocked name(s); nothing written")
        } else if names.isEmpty {
            log(.info, "Blocklist: /etc/hosts section removed")
        } else {
            log(.success, "Blocklist: \(names.count) name(s) blocked in /etc/hosts")
        }
    }

    /// Whether /etc/hosts holds a blocklist start marker. Read as the user (the file is 0644).
    func hostsFileHasBlocklistSection() -> Bool {
        let text = hostsFileOverrideForTests.map { $0() } ?? (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8))
        // Unreadable: assume a section may be there, so the helper is asked.
        guard let text else { return true }
        return text.contains(HostsBlockSection.startMarker)
    }

    /// A pinned-name write went through with `pinned`: a name that was pinned and is no longer gets
    /// its blocklist row back, which the pin writer had dropped.
    func pinnedHostsChanged(to pinned: Set<String>) {
        let gone = pinnedHostNames.subtracting(pinned)
        pinnedHostNames = pinned
        guard !gone.isEmpty, let sent = sentBlockedHosts, !gone.isDisjoint(with: sent) else { return }
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
                             helperError: blockedHostsError)
    }
}

/// What a list rule does now, as its row and `vpnb rule.list` say it.
struct ListRuleState: Equatable {

    enum Kind: String, Equatable {
        /// Its names are in the section (or about to be).
        case blocked
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

    init(kind: Kind, names: Int = 0, error: String? = nil, updated: Date? = nil) {
        self.kind = kind
        self.names = names
        self.error = error
        self.updated = updated
    }

    init(rule: Rule, plan: HostsBlockPlanner.Plan, manageHostsFile: Bool, downloading: Bool,
         status: ListStatus?, helperError: String?, in bundle: Bundle = .main) {
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
        kind = .blocked
        // A write that failed outranks a refused refresh: the names are not blocked at all.
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
        case .pinningOff:
            return String(localized: "Blocks nothing while Pin listed names in /etc/hosts is off (General).", bundle: bundle)
        case .blocked:
            let count = names == 1 ? String(localized: "1 name blocked", bundle: bundle)
                                   : String(localized: "\(names) names blocked", bundle: bundle)
            var line = count
            if let updated {
                let when = RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: now)
                line = String(localized: "\(count), updated \(when)", bundle: bundle)
            }
            if let error { line += "\n" + String(localized: "Last try failed: \(error)", bundle: bundle) }
            return line
        }
    }
}
