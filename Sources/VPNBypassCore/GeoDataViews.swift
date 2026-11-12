// GeoDataViews.swift
// What Country (GeoIP) and Site (GeoSite) rules show: the name and the line under a row, the status
// line under the Rules list, and the searchable pickers of the Add Rule sheet. The wording and the
// search live in `GeoDisplay` and `GeoChoices` as pure functions so the tests can read them without
// a window.

import SwiftUI

enum GeoDisplay {

    /// A country code as its row names it: "Iran (IR)" for a country, "PRIVATE" for a list that is
    /// not one.
    static func name(for code: String, locale: Locale = .current) -> String {
        let upper = code.uppercased()
        if upper.count == 2, let region = locale.localizedString(forRegionCode: upper) {
            return "\(region) (\(upper))"
        }
        return upper
    }

    /// The line under a Country rule's row: what it holds, or why it holds nothing yet. `leftOut` is how
    /// many of the list's ranges `GeoIPRangePolicy` does not route (special-use space).
    static func detail(count: Int?, hasData: Bool, leftOut: Int = 0, in bundle: Bundle = .main) -> String {
        guard hasData else { return String(localized: "Country list not downloaded yet.", bundle: bundle) }
        switch count ?? 0 {
        case let n where n > GeoDataFile.maxRangesPerCountry:
            let limit = GeoDataFile.maxRangesPerCountry
            return String(localized: "Too large to route: \(n) ranges, the limit is \(limit).", bundle: bundle)
        case 0 where leftOut == 0: return String(localized: "Not in the country list.", bundle: bundle)
        case 1 where leftOut > 0: return String(localized: "1 range, \(leftOut) left out", bundle: bundle)
        case let n where leftOut > 0: return String(localized: "\(n) ranges, \(leftOut) left out", bundle: bundle)
        case 1: return String(localized: "1 range", bundle: bundle)
        case let n: return String(localized: "\(n) ranges", bundle: bundle)
        }
    }

    /// The line under a rule the wildcard planner leaves out, in place of what its list holds.
    static func refusal(_ refusal: WildcardPlanner.Refusal, in bundle: Bundle = .main) -> String {
        switch refusal {
        case .overTotal(let count, let limit):
            return String(localized: "Left out: all rules together would pass the limit of \(limit) wildcards (this one adds \(count)).", bundle: bundle)
        case .tooManyExcluded(let count):
            let limit = WildcardSpec.maxExcluded
            return String(localized: "Wildcards left out: \(count). Earlier rules take more than \(limit) names under each.", bundle: bundle)
        }
    }

    /// The line under a Country rule left out by the total of all Country rules.
    static func countryRefusal(count: Int, limit: Int = GeoDataFile.maxRangesTotal, in bundle: Bundle = .main) -> String {
        String(localized: "Left out: all Country rules together would pass the limit of \(limit) ranges (this one adds \(count)).", bundle: bundle)
    }

    /// The refusal line of each rule that has one: the wildcard planner's (`refusals`, from its last
    /// pass) and the Country total's. Built once for the whole list, not once per row.
    static func refusalNotes(config: Config, wildcards refusals: [UUID: WildcardPlanner.Refusal],
                             in bundle: Bundle = .main) -> [UUID: String] {
        var notes = refusals.mapValues { refusal($0, in: bundle) }
        let codes = Set(config.rules.filter { $0.enabled && $0.matchType == .geoip }.map { $0.pattern.lowercased() })
        guard !codes.isEmpty else { return notes }
        let counts = GeoDataFile.geoip.ranges(for: codes).mapValues(\.count)
        let refused = GeoIPBudget.select(rules: config.rules, routes: config.routes, counts: counts).refused
        for rule in config.rules where rule.enabled && rule.matchType == .geoip {
            if let count = refused[rule.pattern.lowercased()] { notes[rule.id] = countryRefusal(count: count, in: bundle) }
        }
        return notes
    }

    /// A Country rule's line with the note that only its IPv4 ranges are routed or blocked: the lists
    /// hold IPv6 ranges too, and the kernel engine routes IPv4 only.
    static func withIPv4Note(_ detail: String, in bundle: Bundle = .main) -> String {
        "\(detail) · \(String(localized: "IPv4 only; IPv6 is not routed or blocked.", bundle: bundle))"
    }

    /// The line under a Site rule's row: what the list holds, or why it routes nothing.
    /// On the Block route the exact names become wildcards too, so the limit is on both counts together
    /// (`GeoSiteExpansion.exceedsWildcards`), as the planner applies it.
    static func siteDetail(_ list: GeoSiteExpansion?, hasData: Bool, onBlock: Bool = false, in bundle: Bundle = .main) -> String {
        guard hasData else { return String(localized: "Site list not downloaded yet.", bundle: bundle) }
        guard let list, list.found else { return String(localized: "Not in the site list.", bundle: bundle) }
        if onBlock, !list.isTooLarge, list.exceedsWildcards(onBlock: true) {
            let count = list.count, limit = GeoSiteExpansion.maxSuffixes
            return String(localized: "Too large to route: \(count) domains, the limit is \(limit).", bundle: bundle)
        }
        if list.isTooLarge {
            // The number that is over, with its own limit: wildcards and exact names are limited apart.
            let namesOver = list.names.count > GeoSiteExpansion.maxNames
            let count = namesOver ? list.names.count : list.suffixes.count
            let limit = namesOver ? GeoSiteExpansion.maxNames : GeoSiteExpansion.maxSuffixes
            return String(localized: "Too large to route: \(count) domains, the limit is \(limit).", bundle: bundle)
        }
        let domains = list.count == 1 ? String(localized: "1 domain", bundle: bundle)
                                      : String(localized: "\(list.count) domains", bundle: bundle)
        guard list.unsupported > 0 else { return domains }
        return String(localized: "\(domains), \(list.unsupported) not supported", bundle: bundle)
    }

    /// A line about a list: when it was last synced (the time, and how long ago), or that it is being
    /// downloaded, or why the last download failed.
    /// `unchecked`: the list in use came from a source that publishes no checksum.
    static func status(_ kind: GeoKind, updated: Date?, phase: GeoDataStore.Phase, unchecked: Bool = false,
                       now: Date = Date(), in bundle: Bundle = .main) -> String {
        let line = baseStatus(kind, updated: updated, phase: phase, now: now, in: bundle)
        guard unchecked, updated != nil, phase != .updating else { return line }
        return "\(line) \(String(localized: "Not checked: its source publishes no checksum.", bundle: bundle))"
    }

    private static func baseStatus(_ kind: GeoKind, updated: Date?, phase: GeoDataStore.Phase,
                                   now: Date, in bundle: Bundle) -> String {
        switch phase {
        case .updating:
            return kind == .ip ? String(localized: "Downloading the country list…", bundle: bundle)
                               : String(localized: "Downloading the site list…", bundle: bundle)
        case .failed(let reason):
            guard let synced = lastSynced(kind, updated: updated, now: now, in: bundle) else { return reason }
            return "\(reason) \(synced)"
        case .idle:
            return lastSynced(kind, updated: updated, now: now, in: bundle)
                ?? (kind == .ip ? String(localized: "The country list is not downloaded yet.", bundle: bundle)
                                : String(localized: "The site list is not downloaded yet.", bundle: bundle))
        }
    }

    /// "Country list last synced Nov 11, 2026 at 5:32 PM (3 days ago).", nil before the first sync.
    static func lastSynced(_ kind: GeoKind, updated: Date?, now: Date = Date(), in bundle: Bundle = .main) -> String? {
        guard let updated else { return nil }
        let when = updated.formatted(date: .abbreviated, time: .shortened)
        let age = RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: now)
        return kind == .ip ? String(localized: "Country list last synced \(when) (\(age)).", bundle: bundle)
                           : String(localized: "Site list last synced \(when) (\(age)).", bundle: bundle)
    }
}

/// One entry of a picker: a country or a list, by its code or name in the file.
struct GeoChoice: Identifiable, Equatable {
    let code: String
    let title: String
    let count: Int
    var id: String { code }
}

enum GeoChoices {

    /// The countries and lists of a geoip file: two-letter countries by their name first, then the
    /// other lists (`private`, `cloudflare`) by code.
    static func countries(_ counts: [String: Int], locale: Locale = .current) -> [GeoChoice] {
        let all = counts.map { GeoChoice(code: $0.key, title: GeoDisplay.name(for: $0.key, locale: locale), count: $0.value) }
        let isCountry: (GeoChoice) -> Bool = { $0.code.count == 2 && $0.title != $0.code.uppercased() }
        return all.filter(isCountry).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            + all.filter { !isCountry($0) }.sorted { $0.code < $1.code }
    }

    /// The lists of a geosite file, by name.
    static func sites(_ counts: [String: Int]) -> [GeoChoice] {
        counts.map { GeoChoice(code: $0.key, title: $0.key, count: $0.value) }.sorted { $0.code < $1.code }
    }

    /// The choices `query` leaves, best first: the code it names, then those that start with it, then
    /// those that hold it anywhere, ignoring case and accents. At most `limit` are returned, with the
    /// number left out.
    static func filter(_ choices: [GeoChoice], query: String, limit: Int = 300) -> (shown: [GeoChoice], hidden: Int) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return (Array(choices.prefix(limit)), max(0, choices.count - limit)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func rank(_ choice: GeoChoice) -> Int? {
            if choice.code.caseInsensitiveCompare(q) == .orderedSame { return 0 }
            if choice.code.range(of: q, options: options.union(.anchored)) != nil
                || choice.title.range(of: q, options: options.union(.anchored)) != nil { return 1 }
            if choice.code.range(of: q, options: options) != nil || choice.title.range(of: q, options: options) != nil { return 2 }
            return nil
        }
        let ranked = choices.enumerated().compactMap { index, choice in rank(choice).map { (rank: $0, index: index, choice: choice) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.choice)
        return (Array(ranked.prefix(limit)), max(0, ranked.count - limit))
    }
}

/// Where a list is downloaded from: the presets Passwall2 offers, or an address of the user's own.
struct GeoSourceMenu: View {
    let kind: GeoKind
    @EnvironmentObject var routeManager: RouteManager
    @State private var showingCustom = false

    private var address: String? { kind == .ip ? routeManager.config.geoipSourceURL : routeManager.config.geositeSourceURL }
    private var current: GeoSource? { GeoSource.preset(for: address, kind: kind) }

    var body: some View {
        Menu {
            ForEach(GeoSource.presets) { source in
                Button {
                    routeManager.setGeoSource(kind, address: source.url(for: kind))
                } label: {
                    if source == current {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: source.title)
                    }
                }
            }
            Divider()
            Button {
                showingCustom = true
            } label: {
                if current == nil { Label(String(localized: "Custom URL…"), systemImage: "checkmark") }
                else { Text("Custom URL…") }
            }
        } label: {
            Text("Source: \(GeoSource.title(for: address, kind: kind))")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(String(localized: "Where the list is downloaded from"))
        .sheet(isPresented: $showingCustom) {
            GeoSourceSheet(kind: kind, initial: current == nil ? (address ?? "") : "",
                           onSave: { text in
                               showingCustom = false
                               routeManager.setGeoSource(kind, address: text)
                           }, onCancel: { showingCustom = false })
        }
    }
}

/// The sheet for an address of the user's own: an https address of a geoip.dat or geosite.dat.
struct GeoSourceSheet: View {
    let kind: GeoKind
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @State private var error: String?

    init(kind: GeoKind, initial: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.kind = kind
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initial)
    }

    /// An address shown as an example of the field, a `String` so it is not looked up as a translation.
    private var example: String { "https://example.org/" + kind.fileName }

    var body: some View {
        SheetScaffold(String(localized: "Custom Source"), confirmTitle: String(localized: "Use This Source"),
                      onCancel: onCancel, onConfirm: save) {
            SheetField(String(localized: "Address"), required: true) {
                TextField(example, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .onSubmit(save)
            }
            Text(kind == .ip ? "An https address of a geoip.dat file. Whoever serves it decides which ranges the rules route."
                             : "An https address of a geosite.dat file. Whoever serves it decides which domains the rules route.")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { SheetError(message: error) }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, GeoDataStore.source(from: trimmed, kind: kind) != nil else {
            error = String(localized: "Enter an https address.")
            return
        }
        onSave(trimmed)
    }
}

/// How often the lists are downloaded again by themselves.
struct GeoSyncMenu: View {
    @EnvironmentObject var routeManager: RouteManager

    var body: some View {
        Menu {
            ForEach(GeoSyncSchedule.allCases, id: \.self) { schedule in
                Button {
                    routeManager.config.geoSync = schedule
                    routeManager.saveConfig()
                } label: {
                    if schedule == routeManager.config.geoSyncSchedule {
                        Label(schedule.title, systemImage: "checkmark")
                    } else {
                        Text(schedule.title)
                    }
                }
            }
        } label: {
            Text("Sync: \(routeManager.config.geoSyncSchedule.title)")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(String(localized: "How often the lists are downloaded again"))
    }
}

/// Everything about a downloaded list in one place: when it was last synced, where it comes from,
/// how often it is synced again, and a button to sync it now. On the Rules page under the list, and
/// in the Add Rule sheet under the picker.
struct GeoDataControls: View {
    let kind: GeoKind
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var store: GeoDataStore

    init(kind: GeoKind) {
        self.kind = kind
        _store = ObservedObject(wrappedValue: kind == .ip ? .geoip : .geosite)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(GeoDisplay.status(kind, updated: store.updated, phase: store.phase, unchecked: store.isUnchecked))
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                GeoSourceMenu(kind: kind)
                GeoSyncMenu()
                Spacer(minLength: 8)
                Button {
                    Task { await routeManager.updateGeoData(kind) }
                } label: {
                    Text("Sync Now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Theme.bgDisabled)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .disabled(store.phase == .updating)
                .opacity(store.phase == .updating ? 0.5 : 1)
                .accessibilityLabel(kind == .ip ? String(localized: "Sync the country list now")
                                                : String(localized: "Sync the site list now"))
            }
        }
    }
}

/// The country or site list field of the Add Rule sheet: a button that opens a searchable list.
struct GeoListField: View {
    let kind: GeoKind
    @Binding var pattern: String
    @EnvironmentObject var routeManager: RouteManager
    @ObservedObject private var store: GeoDataStore
    @State private var open = false

    init(kind: GeoKind, pattern: Binding<String>) {
        self.kind = kind
        _pattern = pattern
        _store = ObservedObject(wrappedValue: kind == .ip ? .geoip : .geosite)
    }

    private var choices: [GeoChoice] {
        _ = store.revision
        return kind == .ip ? GeoChoices.countries(store.file.countries()) : GeoChoices.sites(store.file.lists())
    }

    /// What the button says: the choice's title, the stored pattern when the file lacks it, or the prompt.
    private var buttonTitle: String {
        let code = pattern.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else {
            return kind == .ip ? String(localized: "Choose a country…") : String(localized: "Choose a site list…")
        }
        if kind == .ip { return GeoDisplay.name(for: code) }
        return code
    }

    var body: some View {
        SheetField(kind == .ip ? String(localized: "Country") : String(localized: "Site list"), required: true) {
            VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                Button { open = true } label: {
                    HStack {
                        Text(buttonTitle)
                            .foregroundColor(pattern.isEmpty ? Theme.textSecondary : Theme.text)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(kind == .ip ? String(localized: "Choose a country") : String(localized: "Choose a site list"))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    GeoPickerPopover(kind: kind, choices: choices, selected: GeoSiteDat.parse(pattern: pattern).name,
                                     store: store, onPick: { code in
                        pattern = kind == .site ? GeoSiteRule.pattern(afterPicking: code, current: pattern) : code
                        open = false
                    }, onDownload: { Task { await routeManager.updateGeoData(kind) } })
                }
                GeoDataControls(kind: kind)
            }
        }
    }
}

/// The popover: a search field over a list of countries or site lists.
struct GeoPickerPopover: View {
    let kind: GeoKind
    let choices: [GeoChoice]
    let selected: String
    @ObservedObject var store: GeoDataStore
    let onPick: (String) -> Void
    let onDownload: () -> Void
    @State private var query: String
    @FocusState private var searching: Bool

    init(kind: GeoKind, choices: [GeoChoice], selected: String, store: GeoDataStore,
         initialQuery: String = "", onPick: @escaping (String) -> Void, onDownload: @escaping () -> Void) {
        self.kind = kind
        self.choices = choices
        self.selected = selected
        self.store = store
        self.onPick = onPick
        self.onDownload = onDownload
        _query = State(initialValue: initialQuery)
    }

    private var result: (shown: [GeoChoice], hidden: Int) { GeoChoices.filter(choices, query: query) }

    private func countText(_ n: Int) -> String {
        kind == .ip ? (n == 1 ? String(localized: "1 range") : String(localized: "\(n) ranges"))
                    : (n == 1 ? String(localized: "1 domain") : String(localized: "\(n) domains"))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(kind == .ip ? String(localized: "Search countries") : String(localized: "Search site lists"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit { if let first = result.shown.first { onPick(first.code) } }
                .padding(8)
            Divider()
            if choices.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Text(kind == .ip ? "Download the country list to choose from it." : "Download the site list to choose from it.")
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "Download"), action: onDownload)
                        .disabled(store.phase == .updating)
                    if store.phase == .updating { ProgressView().controlSize(.small) }
                    if case .failed(let reason) = store.phase {
                        Text(reason).font(Theme.Font.detail).foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if result.shown.isEmpty {
                Text("No matches.")
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(result.shown) { choice in
                            Button { onPick(choice.code) } label: {
                                HStack(spacing: Theme.Space.s) {
                                    Text(choice.title)
                                        .font(Theme.Font.body)
                                        .foregroundColor(Theme.text)
                                    Spacer(minLength: 8)
                                    Text(countText(choice.count))
                                        .font(Theme.Font.detail)
                                        .foregroundColor(Theme.textSecondary)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .opacity(choice.code == selected ? 1 : 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if result.hidden > 0 {
                            Text("\(result.hidden) more. Keep typing to narrow the list.")
                                .font(Theme.Font.detail)
                                .foregroundColor(Theme.textSecondary)
                                .padding(10)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: 380)
        .onAppear { searching = true }
    }
}
