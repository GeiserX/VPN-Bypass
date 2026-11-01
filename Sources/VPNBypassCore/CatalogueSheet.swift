// CatalogueSheet.swift
// The Services page's "Browse catalogue…" sheet: search, a category filter, a checkbox per
// service and per category, and one button that turns every picked service on in one save and
// one batch of route writes. The rules (which rows can be picked, what select-all does, what
// search matches, the button's words) are plain values in `CatalogueSelection`, unit-tested
// without a view.

import SwiftUI

enum CatalogueSelection {
    /// One catalogue service with its live switch.
    struct Row: Identifiable {
        let entry: ServiceCatalogue.Entry
        /// The service as it is in the config: its switch, and Added names on a built-in one.
        let service: ServiceEntry
        /// The custom service that keeps this one off by having its name (`ServiceNameClash`).
        let heldBy: ServiceEntry?

        var id: String { service.id }
        var isOn: Bool { service.enabled }
        /// Off and free to turn on: the rows a checkbox can pick.
        var canPick: Bool { !isOn && heldBy == nil }
    }

    /// The catalogue joined by id with the config's services. A catalogue service missing from
    /// the config (not merged yet) shows off.
    static func rows(catalogue: [ServiceCatalogue.Entry], services: [ServiceEntry]) -> [Row] {
        let byId = Dictionary(services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return catalogue.map { entry in
            let service = byId[entry.service.id] ?? entry.service
            return Row(entry: entry, service: service,
                       heldBy: ServiceNameClash.customServiceHolding(nameOf: service, in: services))
        }
    }

    /// The region's name in the app's language, for the row and for search.
    static func regionName(_ code: String?, locale: Locale = .current) -> String? {
        guard let code else { return nil }
        return locale.localizedString(forRegionCode: code) ?? code
    }

    /// Whether a row shows for the search text: its name, a domain, its region's code or its
    /// region's name contains the text, ignoring case. "France" finds the French government
    /// and every French bank.
    static func matches(_ row: Row, search: String, locale: Locale = .current) -> Bool {
        let text = search.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || ServiceSections.matches(row.service, search: text) { return true }
        guard let region = row.entry.region else { return false }
        if region.caseInsensitiveCompare(text) == .orderedSame { return true }
        return [regionName(region, locale: locale), regionName(region, locale: Locale(identifier: "en"))]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }

    /// The rows to show, by category in catalogue order: only `category` when one is picked,
    /// only the services of `region` when one is picked, and only the rows search matches. A
    /// category with no row left is left out.
    static func groups(_ rows: [Row], category: ServiceCatalogue.Category?, region: String? = nil,
                       search: String, locale: Locale = .current) -> [(category: ServiceCatalogue.Category, rows: [Row])] {
        let inRegion = self.rows(rows, in: region)
        return ServiceCatalogue.Category.allCases.compactMap { cat in
            guard category == nil || category == cat else { return nil }
            let shown = inRegion.filter { $0.entry.category == cat && matches($0, search: search, locale: locale) }
            return shown.isEmpty ? nil : (cat, shown)
        }
    }

    /// The services of `region` (an ISO 3166 code), or every row when none is picked.
    static func rows(_ rows: [Row], in region: String?) -> [Row] {
        guard let region else { return rows }
        return rows.filter { $0.entry.region == region }
    }

    /// The categories that have at least one service in `region`: the filter's chips after "All".
    static func categories(_ rows: [Row], region: String? = nil) -> [ServiceCatalogue.Category] {
        let inRegion = self.rows(rows, in: region)
        return ServiceCatalogue.Category.allCases.filter { cat in inRegion.contains { $0.entry.category == cat } }
    }

    /// The countries that have a service of their own, by name in the app's language: the
    /// country menu's items after "All countries".
    static func regions(_ rows: [Row], locale: Locale = .current) -> [String] {
        Set(rows.compactMap(\.entry.region)).sorted {
            (regionName($0, locale: locale) ?? $0).localizedStandardCompare(regionName($1, locale: locale) ?? $1) == .orderedAscending
        }
    }

    /// The list's line when the country menu hides every match.
    static func regionMiss(_ region: String, search: String, locale: Locale = .current, in bundle: Bundle = .main) -> String {
        let country = regionName(region, locale: locale) ?? region
        return String(localized: "No service for \(country) matches \u{201C}\(search)\u{201D}. Choose All countries to see the matches elsewhere.", bundle: bundle)
    }

    enum GroupState: Equatable { case none, some, all, unavailable }

    /// A group's select-all box: checked when every row it can pick is picked, mixed when
    /// some are, off when none, and unavailable when no row can be picked.
    static func state(of rows: [Row], picked: Set<String>) -> GroupState {
        let pickable = rows.filter(\.canPick).map(\.id)
        guard !pickable.isEmpty else { return .unavailable }
        let count = pickable.filter(picked.contains).count
        return count == 0 ? .none : count == pickable.count ? .all : .some
    }

    /// The group's select-all box clicked: picks every row it can, or drops them all when they
    /// were all picked. Rows already on or held by a custom service are never picked.
    static func toggleAll(_ rows: [Row], picked: Set<String>) -> Set<String> {
        let pickable = Set(rows.filter(\.canPick).map(\.id))
        return pickable.isSubset(of: picked) ? picked.subtracting(pickable) : picked.union(pickable)
    }

    /// The primary button.
    static func buttonTitle(count: Int, in bundle: Bundle = .main) -> String {
        switch count {
        case 0: return String(localized: "Bypass services", bundle: bundle)
        case 1: return String(localized: "Bypass 1 service", bundle: bundle)
        default: return String(localized: "Bypass \(count) services", bundle: bundle)
        }
    }
}

struct CatalogueSheet: View {
    @EnvironmentObject var routeManager: RouteManager
    @Environment(\.dismiss) private var dismiss
    @State private var search: String
    @State private var category: ServiceCatalogue.Category?
    /// The country menu's pick, an ISO 3166 code; nil shows every country.
    @State private var region: String?
    @State private var picked: Set<String>
    @FocusState private var isSearchFocused: Bool
    let onBypass: (Set<String>) -> Void

    /// The arguments seed the sheet, for the empty page's "Search the catalogue", the first
    /// run's country row and a rendered screenshot.
    init(search: String = "", category: ServiceCatalogue.Category? = nil, region: String? = nil,
         picked: Set<String> = [], onBypass: @escaping (Set<String>) -> Void) {
        _search = State(initialValue: search)
        _category = State(initialValue: category)
        _region = State(initialValue: region)
        _picked = State(initialValue: picked)
        self.onBypass = onBypass
    }

    /// The list's height: the sheet fits its content, and a scrolling list has none of its own.
    static let listHeight: CGFloat = 400

    private var rows: [CatalogueSelection.Row] {
        CatalogueSelection.rows(catalogue: ServiceCatalogue.shipped, services: routeManager.config.services)
    }

    /// Only rows that can still be picked count, in case one was turned on meanwhile.
    private var pickedNow: Set<String> {
        picked.intersection(rows.filter(\.canPick).map(\.id))
    }

    var body: some View {
        let rows = self.rows
        let groups = CatalogueSelection.groups(rows, category: category, region: region, search: search)
        let count = pickedNow.count
        SheetScaffold(String(localized: "Service catalogue"), confirmTitle: CatalogueSelection.buttonTitle(count: count),
                      canConfirm: count > 0 && !routeManager.isApplyingRoutes,
                      onCancel: { dismiss() }, onConfirm: { onBypass(pickedNow) }) {
            // The search takes the full width; the country menu leads the chip row, so the
            // placeholder fits the sheet's 420 pt.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "Search by name, domain or country"), text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.bgInput)
            .cornerRadius(8)

            HStack(spacing: 8) {
                regionMenu(rows)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            chip(String(localized: "All"), selected: category == nil) { category = nil }
                            ForEach(CatalogueSelection.categories(rows, region: region), id: \.self) { cat in
                                chip(cat.displayName(), selected: category == cat) { category = cat }
                                    .id(cat)
                            }
                        }
                    }
                    // A sheet opened on a category shows its chip, which may sit past the edge.
                    .onAppear { if let category { proxy.scrollTo(category, anchor: .trailing) } }
                }
            }

            ScrollView {
                if groups.isEmpty, let region,
                   !CatalogueSelection.groups(rows, category: category, search: search).isEmpty {
                    // The matches are in other countries, hidden by the country menu.
                    Text(CatalogueSelection.regionMiss(region, search: search))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if groups.isEmpty, let category,
                   !CatalogueSelection.groups(rows, category: nil, region: region, search: search).isEmpty {
                    // The matches are in other categories, hidden by the chip.
                    Text(String(localized: "No service in \(category.displayName()) matches \u{201C}\(search)\u{201D}. Choose All to see the matches in other categories."))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if groups.isEmpty {
                    Text(String(localized: "No service in the catalogue matches \u{201C}\(search)\u{201D}. Make a custom service with the + button."))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.category) { group in
                            groupHeader(group.category, rows: group.rows)
                            ForEach(group.rows) { row in
                                serviceRow(row)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(height: Self.listHeight)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.group).fill(Theme.bgElevated))
        }
        .onAppear { isSearchFocused = true }
    }

    /// The country menu: every country with a service of its own, and All countries.
    private func regionMenu(_ rows: [CatalogueSelection.Row]) -> some View {
        Picker(String(localized: "Country"), selection: Binding(
            get: { region },
            set: { new in
                region = new
                // A chip the new country has no service in would leave the list empty.
                if let category, !CatalogueSelection.categories(rows, region: new).contains(category) {
                    self.category = nil
                }
            }
        )) {
            Text(String(localized: "All countries")).tag(String?.none)
            Divider()
            ForEach(CatalogueSelection.regions(rows), id: \.self) { code in
                Text(verbatim: CatalogueSelection.regionName(code) ?? code).tag(String?.some(code))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(String(localized: "Country"))
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(selected ? .white : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Theme.accent : Theme.bgInput))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func groupHeader(_ cat: ServiceCatalogue.Category, rows: [CatalogueSelection.Row]) -> some View {
        let state = CatalogueSelection.state(of: rows, picked: picked)
        // Every row already on: the box shows them checked, as the rows do, but cannot be clicked.
        let allOn = state == .unavailable && rows.allSatisfy(\.isOn)
        let symbol: String
        let value: String
        switch state {
        case .all:
            symbol = "checkmark.square.fill"
            value = String(localized: "All selected")
        case .some:
            symbol = "minus.square.fill"
            value = String(localized: "Some selected")
        case .none:
            symbol = "square"
            value = String(localized: "None selected")
        case .unavailable:
            symbol = allOn ? "checkmark.square.fill" : "square"
            value = allOn ? String(localized: "Already on") : String(localized: "None selected")
        }
        let label = state == .all
            ? String(localized: "Deselect all \(cat.displayName())")
            : String(localized: "Select all \(cat.displayName())")
        return HStack(spacing: 8) {
            Button {
                picked = CatalogueSelection.toggleAll(rows, picked: picked)
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundColor(state == .all || state == .some ? Theme.accentText : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(state == .unavailable)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            Text(cat.displayName().uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)
            Text(verbatim: String(rows.count))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func serviceRow(_ row: CatalogueSelection.Row) -> some View {
        let isChecked = row.isOn || picked.contains(row.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { isChecked },
                    set: { on in if on { picked.insert(row.id) } else { picked.remove(row.id) } }
                )) {
                    Text(row.service.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(row.canPick ? .white : Theme.textSecondary)
                }
                .toggleStyle(.checkbox)
                .disabled(!row.canPick)

                if let region = CatalogueSelection.regionName(row.entry.region) {
                    Text(region)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                if row.isOn {
                    Text("Already on")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.live)
                } else {
                    Text(FirstRunSetup.domainCount(row.service.domains.count))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            if let holder = row.heldBy, !row.isOn {
                Text(ServiceNameClash.builtInOffMessage(custom: holder.name))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .help(row.heldBy.map { ServiceNameClash.builtInOffMessage(custom: $0.name) } ?? "")
    }
}
