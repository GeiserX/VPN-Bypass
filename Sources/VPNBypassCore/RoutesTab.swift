// RoutesTab.swift
// The Routes page in Custom mode, on the shared components (section 3.3 of
// docs/design/APP-REWORK-PROPOSALS.md): Direct and the detected VPN under "Always there", then
// the user's proxy, Tailscale-peer and pinned VPN routes. The window's title bar names the page.

import SwiftUI
import AppKit

// MARK: - Local listener address

/// The loopback address a proxy route listens on, as a user types it into an
/// app's proxy settings. Built as a plain String: a port interpolated into a
/// `Text` literal goes through locale number formatting and prints 18.168.
enum LocalListenerAddress {
    static func string(port: UInt16) -> String { "127.0.0.1:\(port)" }

    /// Verbatim, so no locale can group the port's digits.
    static func text(port: UInt16) -> Text { Text(verbatim: string(port: port)) }
}

// MARK: - Sheet state wrapper

private enum RouteSheetState: Identifiable {
    case add
    case edit(Route)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let r): return "edit-\(r.id.uuidString)"
        }
    }

    var route: Route? {
        if case .edit(let r) = self { return r }
        return nil
    }
}

// MARK: - RoutesTab

struct RoutesTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var settingsUndo: SettingsUndo
    @ObservedObject private var listenerManager = ProxyListenerManager.shared
    @State private var sheetState: RouteSheetState?
    /// What the last copy put on the clipboard, with the sign-in hint after a proxy URL.
    @State private var copiedLine = RoutesTab.copiedLineForScreenshots

    /// The doc screenshots draw this route's row as if the pointer were on it.
    static var hoveredForScreenshots: String?
    /// The doc screenshots open the page with this line under the list, as after a copy.
    static var copiedLineForScreenshots: String?

    private var listenerRoutes: [Route] {
        routeManager.config.routes.filter {
            ProxyListenerManager.usesLocalListener($0.egress)
                || ($0.egress == .vpnDefault && $0.vpnSelector?.kind == .interface)
        }
    }

    /// The title bar search (⌘F), which the window owns.
    @Environment(\.settingsSearch) private var searchText
    /// The routes the search leaves; every route with no search.
    private var shownRoutes: [Route] {
        listenerRoutes.filter { SettingsSidebar.matches($0.name, search: searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text("The ways out a rule can pick.")
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s)
                PageAddButton(name: String(localized: "Add Route")) { sheetState = .add }
            }

            systemRoutesSection

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                userRoutesSection

                if let copiedLine {
                    AddDomainFeedbackLine(feedback: AddDomainFeedback(success: copiedLine))
                }

                if let change = settingsUndo.last, change.page == .routes {
                    UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
                }
            }
        }
        .sheet(item: $sheetState) { state in
            RouteEditorSheet(editingRoute: state.route) { route in
                saveRoute(route)
                sheetState = nil
            } onCancel: {
                sheetState = nil
            }
        }
    }

    // MARK: - Always there (the auto-created Direct / VPN-default routes)

    /// The two system rows' names. Looked up here, so each is a String a row and a chip share.
    static func systemRouteNames(vpnType: VPNType?, in bundle: Bundle) -> (direct: String, vpn: String) {
        (String(localized: "Direct", bundle: bundle), vpnType?.knownName ?? String(localized: "VPN", bundle: bundle))
    }

    /// Which system rows the title bar search leaves, as the listener routes are filtered.
    static func shownSystemRoutes(direct: String, vpn: String, search: String) -> (direct: Bool, vpn: Bool) {
        (SettingsSidebar.matches(direct, search: search), SettingsSidebar.matches(vpn, search: search))
    }

    @ViewBuilder
    private var systemRoutesSection: some View {
        let names = Self.systemRouteNames(vpnType: routeManager.vpnType, in: .main)
        let shown = Self.shownSystemRoutes(direct: names.direct, vpn: names.vpn, search: searchText)
        if shown.direct || shown.vpn {
            GroupSection(String(localized: "Always there")) {
                if shown.direct {
                    systemRow(egress: .direct, name: names.direct,
                              detail: String(localized: "Your physical connection"))
                }
                if shown.direct && shown.vpn {
                    InsetDivider()
                }
                if shown.vpn {
                    systemRow(egress: .vpnDefault, name: names.vpn,
                              detail: String(localized: "Whatever tunnel is up, detected automatically"))
                }
            }
        }
    }

    /// A read-only row with the same chip the route gets on the Rules page, in the chip column
    /// of the rows below: past it come their small switch (44 pt) and the row's spacing.
    private func systemRow(egress: Egress, name: String, detail: String) -> some View {
        let glyph = RouteChip.systemImage(for: egress)
        return ListRow(glyph: glyph, name: name, detail: detail,
                       accessory: AnyView(RouteChip(systemImage: glyph, name: name).padding(.trailing, 44 + Theme.Space.s)))
    }

    // MARK: - Your routes

    @ViewBuilder
    private var userRoutesSection: some View {
        GroupSection(String(localized: "Your routes")) {
            if listenerRoutes.isEmpty {
                EmptyState(systemImage: "arrow.triangle.branch",
                           title: String(localized: "No proxy routes yet"),
                           message: String(localized: "Add one to route specific traffic through a proxy, a Tailscale peer, or a specific VPN."),
                           primary: .init(title: String(localized: "Add Route")) { sheetState = .add })
            } else {
                if shownRoutes.isEmpty {
                    SettingsSearchMiss(search: searchText)
                }
                ForEach(Array(shownRoutes.enumerated()), id: \.element.id) { idx, route in
                    if idx > 0 { InsetDivider() }
                    RouteRow(route: route, listenerPort: listenerManager.port(for: route.id),
                             onEdit: { sheetState = .edit(route) },
                             onDelete: { deleteRoute(route) },
                             onDuplicate: { duplicateRoute(route) },
                             onToggle: { enabled in toggleRoute(route.id, enabled: enabled) },
                             onCopied: { kind in copiedLine = kind.confirmation(routeName: route.name) },
                             showsActions: Self.hoveredForScreenshots == route.name)
                }
            }
        }
    }

    // MARK: - Mutations

    private func saveRoute(_ route: Route) {
        if let idx = routeManager.config.routes.firstIndex(where: { $0.id == route.id }) {
            routeManager.config.routes[idx] = route
        } else {
            routeManager.config.routes.append(route)
        }
        routeManager.saveConfig()
        // Custom mode: this route may compile to a KERNEL route (a `.vpnDefault`
        // route with an `.interface` selector) — re-apply so it doesn't go stale
        // until the next hourly refresh (mirrors ControlSurface.handle).
        let reapply = RouteManager.usesCustomEngine(schemaVersion: routeManager.config.schemaVersion, routingMode: routeManager.config.routingMode)
        Task { await routeManager.reconcileAfterConfigChange(reconcileListeners: true, reapplyRoutes: reapply) }
    }

    private func deleteRoute(_ route: Route) {
        // A copy line about a route that is gone would sit over the Undo line that replaces it.
        copiedLine = nil
        let index = routeManager.config.routes.firstIndex(where: { $0.id == route.id }) ?? routeManager.config.routes.count
        routeManager.removeRoute(route.id)
        settingsUndo.record(.route(route, index: index))
    }

    private func duplicateRoute(_ route: Route) {
        copiedLine = nil
        routeManager.duplicateRoute(route.id)
    }

    private func toggleRoute(_ id: UUID, enabled: Bool) {
        guard let idx = routeManager.config.routes.firstIndex(where: { $0.id == id }) else { return }
        routeManager.config.routes[idx].enabled = enabled
        routeManager.saveConfig()
        // Custom mode: this route may compile to a KERNEL route (a `.vpnDefault`
        // route with an `.interface` selector) — re-apply so it doesn't go stale
        // until the next hourly refresh (mirrors ControlSurface.handle).
        let reapply = RouteManager.usesCustomEngine(schemaVersion: routeManager.config.schemaVersion, routingMode: routeManager.config.routingMode)
        Task { await routeManager.reconcileAfterConfigChange(reconcileListeners: true, reapplyRoutes: reapply) }
    }
}

extension RouteManager {
    /// Deletes a route from the Routes page and reconciles its listener. Rules that pointed
    /// at it keep its id, so putting the route back reconnects them.
    func removeRoute(_ id: UUID) {
        config.routes.removeAll { $0.id == id }
        saveRouteChange()
    }

    /// Puts back a route a delete took out, at its old place, and starts its listener again
    /// (the same id gives it the same stable port). Returns false while a route with that id
    /// is listed.
    @discardableResult
    func restoreRoute(_ route: Route, at index: Int) -> Bool {
        guard !config.routes.contains(where: { $0.id == route.id }) else { return false }
        config.routes.insert(route, at: min(max(index, 0), config.routes.count))
        saveRouteChange()
        log(.success, "Restored route: \(route.name)")
        return true
    }

    /// Adds a copy of the route `id` right after it, named "<name> copy", with its own id and
    /// so its own listener port. No rule points at the copy. Returns it, or nil when `id` is gone.
    @discardableResult
    func duplicateRoute(_ id: UUID) -> Route? {
        guard let index = config.routes.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = Self.duplicate(of: config.routes[index])
        config.routes.insert(copy, at: index + 1)
        saveRouteChange()
        log(.success, "Duplicated route: \(config.routes[index].name)")
        return copy
    }

    /// The route Duplicate adds: everything kept but the id, the name and the assigned port.
    nonisolated static func duplicate(of route: Route, in bundle: Bundle = .main) -> Route {
        var copy = route
        copy.id = UUID()
        copy.name = String(localized: "\(route.name) copy", bundle: bundle)
        copy.localListenPort = nil
        return copy
    }

    private func saveRouteChange() {
        saveConfig()
        // Custom mode: this route may compile to a KERNEL route (a `.vpnDefault`
        // route with an `.interface` selector) — re-apply so it doesn't go stale
        // until the next hourly refresh (mirrors ControlSurface.handle).
        let reapply = RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode)
        Task { await reconcileAfterConfigChange(reconcileListeners: true, reapplyRoutes: reapply) }
    }
}

// MARK: - RouteRow

/// One of the user's routes as a `ListRow`: its glyph and name, where the app listens and where
/// the route goes on one mono line, Copy Proxy URL, edit and ⋯ under the pointer, the type chip,
/// and the switch last.
struct RouteRow: View {
    let route: Route
    let listenerPort: UInt16?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onToggle: (Bool) -> Void
    /// Told what was copied, so the page can say so under the list.
    var onCopied: (CopyKind) -> Void = { _ in }
    /// Draws the actions as if the pointer were over the row, for the doc screenshots.
    var showsActions = false

    /// The two things a user copies from a listener route. Both carry the local
    /// secret: the listener answers a bare `127.0.0.1:<port>` with 407.
    enum CopyKind {
        case proxyURL, exports

        func title(in bundle: Bundle = .main) -> String {
            switch self {
            case .proxyURL: return String(localized: "Copy Proxy URL", bundle: bundle)
            case .exports:  return String(localized: "Copy Shell Exports", bundle: bundle)
            }
        }

        func text(port: UInt16, secret: String) -> String {
            switch self {
            case .proxyURL: return HookGenerator.proxyURL(port: port, secret: secret)
            case .exports:  return HookGenerator.shellExports(port: port, secret: secret)
            }
        }

        /// The line under the list after a copy. The sign-in hint shows here, once, instead
        /// of as a paragraph at the top of the page.
        func confirmation(routeName: String, in bundle: Bundle = .main) -> String {
            switch self {
            case .proxyURL:
                return String(localized: "Copied the proxy URL for \(routeName). Paste it into an app's proxy setting. A browser asks you to sign in: the user is vpnb, the password is the part between vpnb: and @ in the URL.", bundle: bundle)
            case .exports:
                return String(localized: "Copied the shell exports for \(routeName). Paste them into a shell, and the apps you start from it use this route.", bundle: bundle)
            }
        }
    }

    /// The chip's word. The protocol and product names read the same in every language.
    static func typeLabel(_ egress: Egress, in bundle: Bundle) -> String {
        switch egress {
        case .proxyHTTP: return String(localized: "HTTP CONNECT", bundle: bundle)
        case .proxySOCKS5: return String(localized: "SOCKS5", bundle: bundle)
        case .tailscaleExit: return String(localized: "Tailscale", bundle: bundle)
        case .vpnDefault: return String(localized: "VPN", bundle: bundle)
        case .direct: return String(localized: "Direct", bundle: bundle)
        }
    }

    /// Where the route goes: the upstream proxy, the Tailscale peer, or the pinned tunnel.
    static func upstream(_ route: Route, in bundle: Bundle) -> String {
        switch route.egress {
        case .tailscaleExit:
            let peerName = route.tailscaleExitNode ?? route.proxyHost ?? "—"
            return route.proxyPort.map { "\(peerName) · :\($0)" } ?? peerName
        case .vpnDefault:
            return vpnTarget(route, in: bundle)
        case .proxyHTTP, .proxySOCKS5, .direct:
            let host = route.proxyHost ?? "—"
            return route.proxyPort.map { "\(host):\($0)" } ?? host
        }
    }

    /// Where a VPN route goes: a specific-VPN route shows its pinned tunnel; the primary VPN has none.
    static func vpnTarget(_ route: Route, in bundle: Bundle) -> String {
        let iface = route.vpnSelector?.interfaceName ?? route.vpnSelector?.productHint
        return iface.map { "→ \($0)" } ?? String(localized: "primary VPN", bundle: bundle)
    }

    /// The row's one mono line: the local address an app points at, then where it goes
    /// ("127.0.0.1:18168 → 198.51.100.7:1080"). A pinned VPN route has no listener, only a target.
    static func detail(_ route: Route, listenerPort: UInt16?, in bundle: Bundle = .main) -> String {
        let target = upstream(route, in: bundle)
        guard ProxyListenerManager.usesLocalListener(route.egress) else { return target }
        let listener = listenerPort.map(LocalListenerAddress.string)
            ?? (route.enabled ? String(localized: "Listener starting…", bundle: bundle)
                              : String(localized: "Listener off", bundle: bundle))
        return "\(listener) → \(target)"
    }

    /// Copy Proxy URL, edit, and ⋯ holding Copy Shell Exports, Duplicate and Delete. The copies
    /// need the listener's port, so a route whose listener is not up offers neither.
    static func actions(for route: Route, canCopy: Bool, in bundle: Bundle = .main,
                        copy: @escaping (CopyKind) -> Void, edit: @escaping () -> Void,
                        duplicate: @escaping () -> Void, delete: @escaping () -> Void) -> [RowAction] {
        var more: [RowAction] = []
        if canCopy {
            more.append(RowAction(kind: .other, name: CopyKind.exports.title(in: bundle), systemImage: "terminal") { copy(.exports) })
        }
        more.append(RowAction(kind: .other, name: String(localized: "Duplicate \(route.name)", bundle: bundle),
                              systemImage: "plus.square.on.square", perform: duplicate))
        more.append(.delete(route.name, in: bundle, perform: delete))
        var actions: [RowAction] = []
        if canCopy {
            actions.append(RowAction(kind: .other, name: CopyKind.proxyURL.title(in: bundle), systemImage: "doc.on.doc") { copy(.proxyURL) })
        }
        actions.append(.edit(route.name, in: bundle, perform: edit))
        actions.append(RowAction(kind: .more, name: String(localized: "More actions for \(route.name)", bundle: bundle),
                                 systemImage: "ellipsis", perform: {}, menu: more))
        return actions
    }

    private var actions: [RowAction] {
        Self.actions(for: route, canCopy: listenerPort != nil, copy: copy, edit: onEdit,
                     duplicate: onDuplicate, delete: onDelete)
    }

    var body: some View {
        let glyph = RouteChip.systemImage(for: route.egress)
        ListRow(
            glyph: glyph,
            name: route.name,
            detail: Self.detail(route, listenerPort: listenerPort),
            actions: actions,
            isOn: Binding(get: { route.enabled }, set: onToggle),
            showsActions: showsActions,
            accessory: AnyView(RouteChip(systemImage: glyph, name: Self.typeLabel(route.egress, in: .main))),
            monoDetail: true
        )
        .help(Text(verbatim: Self.detail(route, listenerPort: listenerPort)))
        // The buttons show only under the pointer, and a hidden button is hidden from
        // VoiceOver too, so the row itself carries every action, the ⋯ menu's included.
        .accessibilityActions {
            ForEach(RowAction.flattened(actions)) { action in
                Button(action.name, action: action.perform)
            }
        }
    }

    private func copy(_ kind: CopyKind) {
        guard let port = listenerPort else { return }
        // RouteRow has no routeManager in scope; the singleton is what
        // ProxyListenerManager.shared above already uses from this file.
        let text = kind.text(port: port, secret: RouteManager.shared.ensureLocalProxySecret())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopied(kind)
    }
}

// MARK: - Route editor sheet

struct RouteEditorSheet: View {
    let editingRoute: Route?
    let onSave: (Route) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var egress: Egress
    @State private var proxyHost: String
    @State private var proxyPortText: String
    @State private var proxyUser: String
    @State private var proxyPass: String
    @State private var validationError: String?

    // Tailscale-peer egress: picking a peer from the list sets both of these.
    @State private var selectedPeerIP: String
    @State private var tailscaleNodeName: String
    @State private var peers: [RouteManager.TailscalePeer]

    // VPN egress: which tunnel to target ("" = primary/automatic).
    @State private var selectedVPNInterface: String
    @State private var vpnProductHint: String
    @State private var vpnLinks: [RouteManager.VPNLink] = []
    /// Live tunnels PLUS ones seen before, so a VPN that is currently disconnected can still
    /// be chosen — live enumeration alone only ever reports tunnels that are UP.
    @State private var selectableLinks: [(link: RouteManager.RememberedLink, isLive: Bool)] = []
    /// False when the tunnels were handed in: the sheet shows them and `peers` as given, so a
    /// test or a render can show any tunnel state without reading the real ones.
    private let readsTunnels: Bool

    init(
        editingRoute: Route?,
        selectableLinks: [(link: RouteManager.RememberedLink, isLive: Bool)]? = nil,
        peers: [RouteManager.TailscalePeer] = [],
        onSave: @escaping (Route) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.editingRoute = editingRoute
        _selectableLinks = State(initialValue: selectableLinks ?? [])
        _peers = State(initialValue: peers)
        readsTunnels = selectableLinks == nil
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: editingRoute?.name ?? "")
        _egress = State(initialValue: editingRoute?.egress ?? .proxyHTTP)
        _proxyHost = State(initialValue: editingRoute?.proxyHost ?? "")
        _proxyPortText = State(initialValue: editingRoute?.proxyPort.map(String.init) ?? "")
        _proxyUser = State(initialValue: editingRoute?.proxyUser ?? "")
        _proxyPass = State(initialValue: editingRoute?.proxyPass ?? "")
        _selectedPeerIP = State(initialValue: editingRoute?.proxyHost ?? "")
        _tailscaleNodeName = State(initialValue: editingRoute?.tailscaleExitNode ?? "")
        _selectedVPNInterface = State(initialValue: editingRoute?.vpnSelector?.interfaceName ?? "")
        _vpnProductHint = State(initialValue: editingRoute?.vpnSelector?.productHint ?? "")
    }

    private var isEditing: Bool { editingRoute != nil }

    /// A neutral, type-appropriate name hint (never a specific provider).
    private var namePlaceholder: LocalizedStringKey {
        switch egress {
        case .proxyHTTP, .proxySOCKS5: return "e.g. Residential Proxy"
        case .tailscaleExit:           return "e.g. Home exit"
        case .vpnDefault:              return "e.g. Work VPN"
        case .direct:                  return "e.g. Direct"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text(isEditing ? "Edit Route" : "Add Route")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Cancel"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Theme.divider)

            // Form fields
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formField(label: "Name", required: true) {
                        TextField(namePlaceholder, text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Theme.bgInput)
                            .cornerRadius(8)
                    }

                    formField(label: "Type", required: true) {
                        Picker(String(localized: "Type"), selection: $egress) {
                            Text("HTTP CONNECT").tag(Egress.proxyHTTP)
                            Text("SOCKS5").tag(Egress.proxySOCKS5)
                            Text("Tailscale Peer").tag(Egress.tailscaleExit)
                            Text("VPN").tag(Egress.vpnDefault)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if egress == .vpnDefault {
                        vpnPickerField
                    } else {
                    if egress == .tailscaleExit {
                        formField(label: "Tailscale Peer", required: true) {
                            if peers.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    TextField("100.x.x.x", text: $selectedPeerIP)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(Theme.bgInput)
                                        .cornerRadius(8)
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 10))
                                            .foregroundColor(Theme.textTertiary)
                                        Text("No Tailscale peers detected — enter the peer's 100.x IP manually.")
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            } else {
                                Picker(String(localized: "Tailscale Peer"), selection: Binding(
                                    get: { selectedPeerIP },
                                    set: { newIP in
                                        selectedPeerIP = newIP
                                        if let match = peers.first(where: { $0.ip == newIP }) {
                                            tailscaleNodeName = match.name
                                        }
                                    }
                                )) {
                                    ForEach(peers) { peer in
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(peer.online ? Theme.success : Theme.textTertiary)
                                                .frame(width: 6, height: 6)
                                            // An exit-capable peer is usually a small minority
                                            // of a tailnet, and it is the only kind that can
                                            // carry general internet traffic without extra
                                            // setup — so say which ones they are.
                                            Text(peer.exitNodeCapable ? String(localized: "\(peer.name) · exit node") : peer.name)
                                        }
                                        .tag(peer.ip)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                        }
                    } else {
                        formField(label: "Upstream Host", required: true) {
                            TextField("proxy.example.com", text: $proxyHost)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.bgInput)
                                .cornerRadius(8)
                        }
                    }

                    formField(label: egress == .tailscaleExit ? "Proxy port on peer" : "Upstream Port", required: true) {
                        TextField(egress == .tailscaleExit ? "8888" : "8080", text: $proxyPortText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Theme.bgInput)
                            .cornerRadius(8)
                    }

                    formField(label: "Username", required: false) {
                        TextField("Optional", text: $proxyUser)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Theme.bgInput)
                            .cornerRadius(8)
                    }

                    formField(label: "Password", required: false) {
                        SecureField("Optional", text: $proxyPass)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Theme.bgInput)
                            .cornerRadius(8)
                    }

                    if egress == .tailscaleExit {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.top, 1)
                            Text("Runs a small forward proxy (e.g. tinyproxy) on a Tailscale peer; traffic on this route exits through that peer's internet connection. Set up the proxy on the peer first, listening on its Tailscale IP.")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    }  // end else: proxy/Tailscale fields (hidden for VPN routes)

                    if let error = validationError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.error)
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.error)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Theme.error.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding(20)
            }

            Divider().background(Theme.divider)

            // Action buttons
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.bgInput)
                    .cornerRadius(8)

                Spacer()

                Button(isEditing ? "Save Changes" : "Add Route") {
                    attemptSave()
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.blueGradient)
                .cornerRadius(8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 400)
        .background(Theme.bgSecondary)
        .task {
            guard readsTunnels else { return }
            peers = await RouteManager.shared.listTailscalePeers()
            vpnLinks = await RouteManager.shared.listVPNLinks()
            selectableLinks = await RouteManager.shared.selectableVPNLinks()
        }
    }

    /// VPN egress: "Primary VPN (automatic)" plus one entry per detected non-Tailscale
    /// tunnel. Selecting a specific one pins the route to that interface.
    @ViewBuilder
    private var vpnPickerField: some View {
        let selectable = selectableLinks
        formField(label: "VPN", required: false) {
            if selectable.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    Text("Uses whichever VPN is active. Connect a second VPN to pin this route to a specific one.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Picker(String(localized: "VPN"), selection: Binding(
                    get: { selectedVPNInterface },
                    set: { iface in
                        selectedVPNInterface = iface
                        vpnProductHint = selectableLinks.first(where: { $0.link.interface == iface })?.link.label ?? ""
                    }
                )) {
                    Text("Primary VPN (automatic)").tag("")
                    ForEach(selectable, id: \.link.interface) { entry in
                        Text(entry.isLive
                             ? "\(VPNType.displayLabel(entry.link.label)) · \(entry.link.interface)"
                             : "\(VPNType.displayLabel(entry.link.label)) · \(entry.link.interface) — not connected")
                            .tag(entry.link.interface)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func formField<F: View>(
        label: LocalizedStringKey,
        required: Bool,
        @ViewBuilder field: () -> F
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                if required {
                    Text("*")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.error)
                }
            }
            field()
        }
    }

    private func attemptSave() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = String(localized: "Name is required.")
            return
        }

        // VPN egress: no host/port — just a tunnel selector ("" = the primary VPN).
        if egress == .vpnDefault {
            let selector = selectedVPNInterface.isEmpty
                ? VPNSelector(kind: .primary)
                : VPNSelector(kind: .interface, interfaceName: selectedVPNInterface,
                              productHint: vpnProductHint.isEmpty ? nil : vpnProductHint)
            onSave(Route(
                id: editingRoute?.id ?? UUID(),
                name: trimmedName,
                egress: .vpnDefault,
                enabled: editingRoute?.enabled ?? true,
                vpnSelector: selector
            ))
            return
        }

        let isTailscalePeer = egress == .tailscaleExit
        let trimmedHost = (isTailscalePeer ? selectedPeerIP : proxyHost).trimmingCharacters(in: .whitespaces)

        guard !trimmedHost.isEmpty else {
            validationError = isTailscalePeer
                ? String(localized: "Select a Tailscale peer (or enter its 100.x IP).")
                : String(localized: "Upstream host is required.")
            return
        }
        guard let port = Int(proxyPortText.trimmingCharacters(in: .whitespaces)),
              (1 ... 65535).contains(port) else {
            validationError = String(localized: "Port must be a number between 1 and 65535.")
            return
        }

        let route = Route(
            id: editingRoute?.id ?? UUID(),
            name: trimmedName,
            egress: egress,
            enabled: editingRoute?.enabled ?? true,
            proxyHost: trimmedHost,
            proxyPort: port,
            proxyUser: proxyUser.isEmpty ? nil : proxyUser,
            proxyPass: proxyPass.isEmpty ? nil : proxyPass,
            // Not editable in this sheet — carry them through from the route being
            // edited so a GUI save (even a plain rename) doesn't wipe scripting/
            // session config the sheet has no inputs for.
            proxyUsernameTemplate: editingRoute?.proxyUsernameTemplate,
            proxyPasswordTemplate: editingRoute?.proxyPasswordTemplate,
            sessionMode: editingRoute?.sessionMode ?? .none,
            sessionTTLMinutes: editingRoute?.sessionTTLMinutes,
            remoteDNS: editingRoute?.remoteDNS ?? true,
            tailscaleExitNode: isTailscalePeer && !tailscaleNodeName.isEmpty ? tailscaleNodeName : nil,
            localListenPort: editingRoute?.localListenPort
        )
        onSave(route)
    }
}
