// ServicesPage.swift
// The Services page on the shared components (section 3.3 of docs/design/APP-REWORK-PROPOSALS.md):
// one list of the user's own services, "Browse catalogue…" under it. The page's title is the
// window's (SettingsView's PageHeader), so the page has no heading of its own.

import SwiftUI

/// How the Services page splits the list: an On section with the services that were on when
/// the page opened, then the custom services that were not, each in the catalogue's order. A
/// catalogue service that is off is not on the page: it waits in the catalogue sheet
/// (`CatalogueSheet`), and switching one off on the page sends it back there. A saved built-in
/// service that is off and no longer in the catalogue has no sheet row to wait in, so it stays
/// on the page with the custom services, where it can be turned back on. Kept pure so the
/// split and its edge cases are unit-tested. The page shows the two parts as one list.
///
/// The split follows the switches as they were when the page opened (`pinned`), not as they
/// are now, so a switch flipped on the page leaves its row where it is. The row moves on the
/// next visit, never from under the pointer. A service added since the page opened, such as a
/// custom service just created or a service added from the catalogue, goes by its own switch,
/// and the page pins it as soon as it sees it, so flipping its switch does not move it either.
/// A catalogue service switched off on the page keeps its row, switch off, until the next visit.
struct ServiceSections {
    enum Kind: CaseIterable {
        case on, custom
    }

    var on: [ServiceEntry]
    var custom: [ServiceEntry]

    /// Each service's switch as it is now, by id: what the page pins when it opens.
    static func pin(_ services: [ServiceEntry]) -> [String: Bool] {
        Dictionary(services.map { ($0.id, $0.enabled) }, uniquingKeysWith: { first, _ in first })
    }

    /// The pin plus every service it has not seen yet, at its switch as it is now. The services
    /// already pinned keep their pin.
    static func pinNew(_ services: [ServiceEntry], into pinned: [String: Bool]) -> [String: Bool] {
        pinned.merging(pin(services)) { kept, _ in kept }
    }

    /// Whether a service that is off has a row on the page: a custom service, or a saved
    /// built-in the catalogue no longer ships. Any other service that is off waits in the sheet.
    static func keepsRowWhenOff(_ service: ServiceEntry) -> Bool {
        service.isCustom || !ServiceCatalogue.shippedIds.contains(service.id)
    }

    /// The pin with every service that is on now but pinned off and hidden pinned on: a
    /// catalogue service switched on outside the page (the sheet, the menu bar, vpnb). The page
    /// had no row for it, so pinning it moves nothing; rows the page shows keep their pin.
    static func pinSwitchedOn(_ services: [ServiceEntry], into pinned: [String: Bool]) -> [String: Bool] {
        var next = pinned
        for service in services where service.enabled && pinned[service.id] == false && !keepsRowWhenOff(service) {
            next[service.id] = true
        }
        return next
    }

    /// Whether a service shows for the search text: its name or one of its domains contains
    /// the text, ignoring case. Empty text shows everything.
    static func matches(_ service: ServiceEntry, search: String) -> Bool {
        search.isEmpty
            || service.name.localizedCaseInsensitiveContains(search)
            || service.domains.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    init(services: [ServiceEntry], pinned: [String: Bool], search: String) {
        let shown = services.filter { Self.matches($0, search: search) }
        let isOn = { (service: ServiceEntry) in pinned[service.id] ?? service.enabled }
        on = shown.filter { isOn($0) }
        custom = shown.filter { !isOn($0) && Self.keepsRowWhenOff($0) }
    }

    /// What Turn All On switches on: the page's own rows that are off, less those a custom
    /// service holds off by its name. Never the catalogue: that would turn on every service
    /// the app ships.
    static func turnAllOn(services: [ServiceEntry], pinned: [String: Bool]) -> [ServiceEntry] {
        let page = ServiceSections(services: services, pinned: pinned, search: "")
        return (page.on + page.custom).filter {
            !$0.enabled && ServiceNameClash.customServiceHolding(nameOf: $0, in: services) == nil
        }
    }

    /// The page's one list: the services that were on when it opened, then the rest.
    var rows: [ServiceEntry] { on + custom }

    /// The sections that have rows, top to bottom.
    var nonEmpty: [(kind: Kind, services: [ServiceEntry])] {
        Kind.allCases.compactMap { kind in
            let rows = self[kind]
            return rows.isEmpty ? nil : (kind, rows)
        }
    }

    subscript(kind: Kind) -> [ServiceEntry] {
        switch kind {
        case .on: return on
        case .custom: return custom
        }
    }
}


/// The Services page as data: the purpose line, the rows and what each says. Kept apart from
/// the view so tests can read it.
enum ServicesPage {
    struct Row: Identifiable {
        let service: ServiceEntry
        let glyph: String
        /// "Custom · 2 domains · 1 IP range · Added: x.example", or the name clash to fix.
        let detail: String
        /// A custom service whose name is taken, or a built-in one a custom service holds off.
        let needsAttention: Bool
        /// The addresses routed for the service; none for a service that is off, or outside
        /// Bypass mode, where services route nothing.
        let number: String?
        /// The names the user added to a built-in service, which the row can remove.
        let added: [String]
        var id: String { service.id }

        /// A built-in service a custom one of the same name holds off: its switch is greyed,
        /// since turning it on would be refused, and the detail line says what to rename.
        var isHeldOff: Bool { !service.isCustom && needsAttention && !service.enabled }
    }

    static func purpose(in bundle: Bundle = .main) -> String {
        String(localized: "A service skips the VPN while its switch is on.", bundle: bundle)
    }

    static func listTitle(in bundle: Bundle = .main) -> String {
        String(localized: "Your services", bundle: bundle)
    }

    /// The line beside Browse catalogue…: how many services the catalogue offers.
    static func catalogueLine(count: Int, in bundle: Bundle = .main) -> String {
        String(localized: "\(count) services, pick several at once", bundle: bundle)
    }

    /// The button that opens the catalogue: with a search typed, the same search there, since
    /// most services live there; otherwise a plain browse.
    static func catalogueButton(search: String, in bundle: Bundle = .main) -> String {
        search.isEmpty ? String(localized: "Browse catalogue…", bundle: bundle)
            : String(localized: "Search the catalogue", bundle: bundle)
    }

    /// What a service holds, on one line: "Custom · 2 domains · 1 IP range · Added: x.example".
    static func detail(_ service: ServiceEntry, added: [String], in bundle: Bundle = .main) -> String {
        var parts: [String] = []
        if service.isCustom { parts.append(String(localized: "Custom", bundle: bundle)) }
        let d = service.domains.count
        parts.append(d == 1 ? String(localized: "1 domain", bundle: bundle) : String(localized: "\(d) domains", bundle: bundle))
        let r = service.ipRanges.count
        if r > 0 {
            parts.append(r == 1 ? String(localized: "1 IP range", bundle: bundle) : String(localized: "\(r) IP ranges", bundle: bundle))
        }
        if !added.isEmpty {
            parts.append(String(localized: "Added: \(added.joined(separator: ", "))", bundle: bundle))
        }
        return parts.joined(separator: " · ")
    }

    /// `routeSources` is the `source` of every installed route; a service's routes carry its
    /// name. `added` gives the names added to a built-in service, `clash` the line a name clash
    /// puts on the row.
    static func rows(_ services: [ServiceEntry], mode: RoutingMode, routeSources: [String],
                     added: (ServiceEntry) -> [String], clash: (ServiceEntry) -> String?,
                     in bundle: Bundle = .main) -> [Row] {
        var counts: [String: Int] = [:]
        for source in routeSources { counts[source, default: 0] += 1 }
        return services.map { service in
            let extra = service.isCustom ? [] : added(service)
            let problem = clash(service)
            let routes = service.enabled && mode == .bypass
            return Row(service: service,
                       glyph: service.isCustom ? "square.and.pencil" : ServiceChip.iconName(for: service.id),
                       detail: problem ?? detail(service, added: extra, in: bundle),
                       needsAttention: problem != nil,
                       number: routes ? String(counts[service.name] ?? 0) : nil,
                       added: extra)
        }
    }

    /// Edit and delete on a custom service. On a built-in service, the remove of each name the
    /// user added to it: one button for one name, a ⋯ menu for several.
    static func actions(for row: Row, in bundle: Bundle = .main, edit: @escaping () -> Void,
                        delete: @escaping () -> Void, removeAdded: @escaping (String) -> Void) -> [RowAction] {
        let name = row.service.name
        if row.service.isCustom {
            return [.edit(name, in: bundle, perform: edit), .delete(name, in: bundle, perform: delete)]
        }
        let removes = row.added.map { domain in
            RowAction(kind: .other, name: String(localized: "Remove \(domain) from \(name)", bundle: bundle),
                      systemImage: "minus.circle") { removeAdded(domain) }
        }
        guard removes.count > 1 else { return removes }
        return [RowAction(kind: .more, name: String(localized: "More actions for \(name)", bundle: bundle),
                          systemImage: "ellipsis", perform: {}, menu: removes)]
    }
}

struct ServicesTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var settingsUndo: SettingsUndo
    /// The title bar search (⌘F), which the window owns.
    @Environment(\.settingsSearch) private var searchText
    /// Set, Turn All On asks this before it runs.
    @State private var turnOnQuestion: ServiceBulkSwitch.Question?
    @State private var showingCustomServiceEditor = false
    @State private var editingService: RouteManager.ServiceEntry?
    /// Each service's switch when the page opened; nil until it appears.
    @State private var pinned: [String: Bool]?
    /// The catalogue sheet is open, with `catalogueSeed` in its search field.
    @State private var showingCatalogue = false
    @State private var catalogueSeed = ""
    /// The country the sheet opens on: the first run's country row sets it.
    @State private var catalogueRegion: String?

    /// The doc screenshots draw this service's row as if the pointer were on it.
    static var hoveredForScreenshots: String?

    /// The argument seeds the question Turn All On asks, for a rendered screenshot.
    init(turnOnQuestion: ServiceBulkSwitch.Question? = nil) {
        _turnOnQuestion = State(initialValue: turnOnQuestion)
    }

    private var isVPNOnly: Bool {
        routeManager.config.routingMode == .vpnOnly
    }

    private var sections: ServiceSections {
        let services = routeManager.config.services
        return ServiceSections(services: services,
                               pinned: pinned ?? ServiceSections.pin(services),
                               search: searchText)
    }

    private var enabledCount: Int {
        routeManager.config.services.filter { $0.enabled }.count
    }

    private var rows: [ServicesPage.Row] {
        ServicesPage.rows(sections.rows, mode: routeManager.config.routingMode,
                          routeSources: routeManager.activeRoutes.map(\.source),
                          added: { routeManager.domainsAddedToBuiltInService($0.id) },
                          clash: clashLine)
    }

    var body: some View {
        let rows = rows
        // One width for every number on the page, so the column lines up.
        let numberWidth = ListRow.numberColumnWidth(for: rows.compactMap(\.number))
        // A page with no service of the user's at all says so; a search that empties it says that.
        let hasServices = !ServiceSections(services: routeManager.config.services,
                                           pinned: pinned ?? ServiceSections.pin(routeManager.config.services),
                                           search: "").rows.isEmpty
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(ServicesPage.purpose())
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                GroupSection(ServicesPage.listTitle(), trailing: {
                    listTrailing(numberWidth: numberWidth, hasServices: hasServices)
                }) {
                    if !hasServices {
                        EmptyState(systemImage: "square.grid.2x2",
                                   title: String(localized: "No services yet"),
                                   message: String(localized: "Pick the ones you use from the catalogue, or make your own with the + button."),
                                   primary: .init(title: ServicesPage.catalogueButton(search: searchText)) {
                                       openCatalogue(seed: searchText)
                                   })
                    } else if rows.isEmpty {
                        SettingsSearchMiss(search: searchText)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { InsetDivider() }
                            ServiceRow(row: row, numberWidth: numberWidth,
                                       showsActions: Self.hoveredForScreenshots == row.service.name,
                                       onEdit: {
                                           editingService = row.service
                                           showingCustomServiceEditor = true
                                       },
                                       onDelete: { removeCustomService(row.service) })
                        }
                    }
                }

                if let change = settingsUndo.last, change.page == .services {
                    UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
                }

                // The way to the catalogue, under the list; with a search that found nothing
                // here, the same search there, since most services live there.
                if hasServices {
                    catalogueLine(searchMissed: rows.isEmpty)
                        .padding(.top, Theme.Space.xs)
                }
            }
            .onAppear {
                pinned = ServiceSections.pin(routeManager.config.services)
            }
            .onChange(of: routeManager.config.services.map(\.id)) { _ in
                if let current = pinned {
                    pinned = ServiceSections.pinNew(routeManager.config.services, into: current)
                }
            }
            // A catalogue service switched on elsewhere while the page is open shows at once.
            .onChange(of: routeManager.config.services.filter(\.enabled).map(\.id)) { _ in
                if let current = pinned {
                    pinned = ServiceSections.pinSwitchedOn(routeManager.config.services, into: current)
                }
            }
            // An undone Turn All On/Off moves many rows at once, like the switch itself.
            .onChange(of: settingsUndo.undoneCount) { _ in
                pinned = ServiceSections.pin(routeManager.config.services)
            }
        }
        .pageTitleActions([.add(String(localized: "Create Custom Service")) {
            editingService = nil
            showingCustomServiceEditor = true
        }])
        .sheet(isPresented: $showingCustomServiceEditor) {
            CustomServiceEditor(service: editingService)
                .environmentObject(routeManager)
        }
        .sheet(isPresented: $showingCatalogue) {
            CatalogueSheet(search: catalogueSeed, region: catalogueRegion) { picked in
                addFromCatalogue(picked)
            }
            .environmentObject(routeManager)
        }
        // The first-run dropdown's "All services…" row opens the page with the sheet up.
        .onReceive(SettingsPageRequest.shared.$openCatalogue) { open in
            guard open, !isVPNOnly else { return }
            SettingsPageRequest.shared.openCatalogue = false
            let region = SettingsPageRequest.shared.catalogueRegion
            SettingsPageRequest.shared.catalogueRegion = nil
            openCatalogue(region: region)
        }
        .alert(turnOnQuestion?.title ?? "", isPresented: Binding(
            get: { turnOnQuestion != nil },
            set: { if !$0 { turnOnQuestion = nil } }
        )) {
            Button(turnOnQuestion?.confirm ?? "") { switchAll(true) }
            Button(String(localized: "Cancel"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(turnOnQuestion?.message ?? "")
        }
    }

    /// The spinner while routes are applied, otherwise Turn All On / Off; then the label over
    /// the number column.
    private func listTrailing(numberWidth: CGFloat, hasServices: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if routeManager.isApplyingRoutes {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Applying..."))
            } else if hasServices {
                BulkSwitchMenu(
                    turnAllOnTitle: ServiceBulkSwitch.turnAllOnTitle(offCount: offServices.count),
                    canTurnOn: !offServices.isEmpty,
                    canTurnOff: enabledCount > 0,
                    onTurnAllOn: turnAllOn,
                    onTurnAllOff: { switchAll(false) }
                )
            }
            if numberWidth > 0 {
                Text("addresses")
                    // Ends over the number column, as on the Domains page: past it come the
                    // small switch (44 pt), the row's spacing and its inset, less the header's 2 pt.
                    .padding(.trailing, 44 + Theme.Space.s + ListRow.inset - 2)
            }
        }
    }

    private func catalogueLine(searchMissed: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Button(ServicesPage.catalogueButton(search: searchMissed ? searchText : "")) {
                openCatalogue(seed: searchMissed ? searchText : "")
            }
            .controlSize(.regular)
            Text(ServicesPage.catalogueLine(count: ServiceCatalogue.shipped.count))
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
        }
    }

    /// The line a name clash puts on the row: on a custom service, the editor's line asking for
    /// another name; on a built-in service kept off, which custom service to rename.
    private func clashLine(_ service: ServiceEntry) -> String? {
        if service.isCustom { return routeManager.customServiceNameClash(service.name, excluding: service.id)?.message }
        return routeManager.customServiceHolding(nameOf: service).map { ServiceNameClash.builtInOffMessage(custom: $0.name) }
    }

    /// The page's own rows Turn All On switches on; never the catalogue.
    private var offServices: [RouteManager.ServiceEntry] {
        let services = routeManager.config.services
        return ServiceSections.turnAllOn(services: services, pinned: pinned ?? ServiceSections.pin(services))
    }

    private func openCatalogue(seed: String = "", region: String? = nil) {
        catalogueSeed = seed
        catalogueRegion = region
        showingCatalogue = true
    }

    /// The sheet's primary button: every picked service on in one save and one batch of route
    /// writes, one undo line, and the new rows pinned on so they show at once.
    private func addFromCatalogue(_ ids: Set<String>) {
        showingCatalogue = false
        let changed = routeManager.setServicesEnabled(ids, true)
        // Pin the new rows on now; every row already on the page keeps its pin.
        let services = routeManager.config.services
        pinned = ServiceSections.pinSwitchedOn(services, into: pinned.map { ServiceSections.pinNew(services, into: $0) } ?? ServiceSections.pin(services))
        if !changed.isEmpty { settingsUndo.record(.servicesSwitched(ids: changed, on: true)) }
    }

    private func turnAllOn() {
        if let question = ServiceBulkSwitch.question(turningOn: offServices) {
            turnOnQuestion = question
        } else {
            switchAll(true)
        }
    }

    private func switchAll(_ on: Bool) {
        let changed = on ? routeManager.setServicesEnabled(Set(offServices.map(\.id)), true)
            : routeManager.setAllServicesEnabled(false)
        // The pointer is on the menu, not on a row: show the new split now.
        pinned = ServiceSections.pin(routeManager.config.services)
        if !changed.isEmpty { settingsUndo.record(.servicesSwitched(ids: changed, on: on)) }
    }

    private func removeCustomService(_ service: RouteManager.ServiceEntry) {
        let index = routeManager.config.services.firstIndex(where: { $0.id == service.id }) ?? routeManager.config.services.count
        routeManager.removeCustomService(service.id)
        settingsUndo.record(.customService(service, index: index))
    }
}

/// One service on the shared row: its glyph, name and what it holds, the actions under the
/// pointer, the addresses it routes, and its switch.
struct ServiceRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let row: ServicesPage.Row
    var numberWidth: CGFloat = 0
    var showsActions = false
    var onEdit: () -> Void = {}
    /// The delete of a custom service. ServicesTab removes it and leaves the undo line.
    var onDelete: () -> Void = {}

    private var actions: [RowAction] {
        ServicesPage.actions(for: row, edit: onEdit, delete: onDelete) { domain in
            guard !routeManager.isApplyingRoutes else { return }
            _ = routeManager.removeDomainFromBuiltInService(domain, serviceId: row.service.id)
        }
    }

    var body: some View {
        let service = row.service
        ListRow(
            glyph: row.glyph,
            name: service.name,
            detail: row.detail,
            needsAttention: row.needsAttention,
            number: row.number,
            numberWidth: numberWidth,
            numberLabel: ListRow.addressesLabel(row.number),
            actions: actions,
            // A built-in service a custom one holds off does not turn on: toggleService refuses,
            // and the detail line says which custom service to rename.
            isOn: Binding(
                get: { service.enabled },
                set: { _ in
                    if !routeManager.isApplyingRoutes { routeManager.toggleService(service.id) }
                }
            ),
            isSwitchDisabled: row.isHeldOff,
            showsActions: showsActions,
            detailLineLimit: row.needsAttention || !row.added.isEmpty ? nil : 1
        )
        .disabled(routeManager.isApplyingRoutes)
    }
}
