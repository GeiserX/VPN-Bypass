// RoutesTab.swift
// Settings tab for managing proxy routes (HTTP CONNECT / SOCKS5).

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

    private var listenerRoutes: [Route] {
        routeManager.config.routes.filter {
            ProxyListenerManager.usesLocalListener($0.egress)
                || ($0.egress == .vpnDefault && $0.vpnSelector?.kind == .interface)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.blueGradient)
                    Text("Routes")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                if !listenerRoutes.isEmpty {
                    Text("\(listenerRoutes.filter { $0.enabled }.count)/\(listenerRoutes.count) active")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }

                Button {
                    sheetState = .add
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.blueLight)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Add Route")
                .accessibilityLabel("Add Route")
            }

            // Helper hint
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 1)
                Text("Point an app at a route: paste the copied shell exports into a shell, or the copied proxy URL into an app's proxy setting. A browser set to 127.0.0.1 and the port asks you to sign in: the user is vpnb, the password is the part between vpnb: and @ in the proxy URL.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            systemRoutesCard

            if listenerRoutes.isEmpty {
                emptyState
            } else {
                routeList
            }

            if let change = settingsUndo.last, change.page == .routes {
                UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
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

    // MARK: - System routes (the auto-created Direct / VPN-default routes)

    /// The two system rows' names. SystemRouteRow takes a String, which Text shows as it is,
    /// so both are looked up here.
    static func systemRouteNames(vpnType: VPNType?, in bundle: Bundle) -> (direct: String, vpn: String) {
        (String(localized: "Direct", bundle: bundle), vpnType?.knownName ?? String(localized: "VPN", bundle: bundle))
    }

    private var systemRoutesCard: some View {
        SettingsCard(title: "System Routes", icon: "shield.lefthalf.filled", iconColor: Theme.textSecondary) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    SystemRouteRow(
                        icon: "arrow.up.right",
                        name: Self.systemRouteNames(vpnType: routeManager.vpnType, in: .main).direct,
                        subtitle: "Your physical connection",
                        color: Theme.textSecondary
                    )
                    Divider().background(Theme.divider).padding(.vertical, 4)
                    SystemRouteRow(
                        icon: routeManager.vpnType?.icon ?? "lock.shield",
                        name: Self.systemRouteNames(vpnType: routeManager.vpnType, in: .main).vpn,
                        subtitle: "Whatever tunnel is currently up",
                        color: Theme.warning
                    )
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    Text("Detected automatically.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44))
                .foregroundColor(Theme.textDisabled)
            Text("No proxy routes yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text("Add one to route specific traffic through a proxy, a Tailscale peer, or a specific VPN.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button {
                sheetState = .add
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                    Text("Add Route")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Theme.blueGradient)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: - Route list

    private var routeList: some View {
        SettingsCard(title: "Routes", icon: "arrow.triangle.branch", iconColor: Theme.blue) {
            VStack(spacing: 0) {
                ForEach(Array(listenerRoutes.enumerated()), id: \.element.id) { idx, route in
                    RouteRow(route: route, listenerPort: listenerManager.port(for: route.id)) {
                        sheetState = .edit(route)
                    } onDelete: {
                        deleteRoute(route)
                    } onToggle: { enabled in
                        toggleRoute(route.id, enabled: enabled)
                    }
                    if idx < listenerRoutes.count - 1 {
                        Divider()
                            .background(Theme.divider)
                            .padding(.vertical, 4)
                    }
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
        let index = routeManager.config.routes.firstIndex(where: { $0.id == route.id }) ?? routeManager.config.routes.count
        routeManager.removeRoute(route.id)
        settingsUndo.record(.route(route, index: index))
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

    private func saveRouteChange() {
        saveConfig()
        // Custom mode: this route may compile to a KERNEL route (a `.vpnDefault`
        // route with an `.interface` selector) — re-apply so it doesn't go stale
        // until the next hourly refresh (mirrors ControlSurface.handle).
        let reapply = RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode)
        Task { await reconcileAfterConfigChange(reconcileListeners: true, reapplyRoutes: reapply) }
    }
}

// MARK: - SystemRouteRow

/// Read-only row for the auto-created Direct / VPN-default routes shown in
/// "System Routes" — no edit/delete, these aren't user-configurable.
struct SystemRouteRow: View {
    let icon: String
    let name: String
    let subtitle: LocalizedStringKey
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - RouteRow

struct RouteRow: View {
    let route: Route
    let listenerPort: UInt16?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void

    /// The two things a user copies from a listener route. Both carry the local
    /// secret: the listener answers a bare `127.0.0.1:<port>` with 407.
    enum CopyKind {
        case proxyURL, exports

        var title: LocalizedStringKey {
            switch self {
            case .proxyURL: return "Copy Proxy URL"
            case .exports:  return "Copy Shell Exports"
            }
        }

        func text(port: UInt16, secret: String) -> String {
            switch self {
            case .proxyURL: return HookGenerator.proxyURL(port: port, secret: secret)
            case .exports:  return HookGenerator.shellExports(port: port, secret: secret)
            }
        }
    }
    /// Which Copy button last copied, so only that one flips to "Copied".
    @State private var copied: CopyKind?

    private var typeLabel: String { Self.typeLabel(route.egress, in: .main) }

    /// The badge beside the route's name. Text(String) shows a String as it is, so each
    /// label is looked up here; the protocol and product names read the same in every language.
    static func typeLabel(_ egress: Egress, in bundle: Bundle) -> String {
        switch egress {
        case .proxyHTTP: return String(localized: "HTTP CONNECT", bundle: bundle)
        case .proxySOCKS5: return String(localized: "SOCKS5", bundle: bundle)
        case .tailscaleExit: return String(localized: "Tailscale", bundle: bundle)
        case .vpnDefault: return String(localized: "VPN", bundle: bundle)
        case .direct: return String(localized: "Direct", bundle: bundle)
        }
    }

    private var typeAccent: Color {
        switch route.egress {
        case .proxyHTTP: return Theme.blue
        case .proxySOCKS5: return Theme.purple
        case .tailscaleExit: return Theme.success
        case .vpnDefault: return Theme.warning
        case .direct: return Theme.textSecondary
        }
    }

    private var upstreamDisplay: String {
        switch route.egress {
        case .tailscaleExit:
            let peerName = route.tailscaleExitNode ?? route.proxyHost ?? "—"
            if let port = route.proxyPort {
                return "\(peerName) · :\(port)"
            }
            return peerName
        case .vpnDefault:
            return Self.vpnTarget(route, in: .main)
        case .proxyHTTP, .proxySOCKS5, .direct:
            let host = route.proxyHost ?? "—"
            if let port = route.proxyPort {
                return "\(host):\(port)"
            }
            return host
        }
    }

    /// Status text for `.vpnDefault` / `.direct` routes, which have no loopback listener.
    private var nonListenerStatusLabel: String { Self.nonListenerStatusLabel(route, in: .main) }

    static func nonListenerStatusLabel(_ route: Route, in bundle: Bundle) -> String {
        guard route.egress == .vpnDefault else { return String(localized: "direct", bundle: bundle) }
        return vpnTarget(route, in: bundle)
    }

    /// Where a VPN route goes: a specific-VPN route shows its pinned tunnel; the primary VPN has none.
    static func vpnTarget(_ route: Route, in bundle: Bundle) -> String {
        let iface = route.vpnSelector?.interfaceName ?? route.vpnSelector?.productHint
        return iface.map { "→ \($0)" } ?? String(localized: "primary VPN", bundle: bundle)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Enabled toggle
            Toggle(route.name, isOn: Binding(
                get: { route.enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .tint(Theme.success)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 38)

            // Info column
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(route.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(typeLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(typeAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(typeAccent.opacity(0.15))
                        .cornerRadius(4)
                }

                if ProxyListenerManager.usesLocalListener(route.egress) {
                    listenerDetails
                } else {
                    nonListenerDetails
                }
            }

            Spacer()

            // Edit
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.bgHover)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Edit route")
            .accessibilityLabel(ControlNames.edit(route.name))

            // Delete
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.error)
                    .frame(width: 28, height: 28)
                    .background(Theme.error.opacity(0.1))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Delete route")
            .accessibilityLabel(ControlNames.delete(route.name))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// Proxy and Tailscale-peer routes: where the route goes, the local address an
    /// app points at, and one button per thing a user copies.
    /// The upstream and the listener sit on two lines: side by side, an upstream
    /// longer than about 17 characters wrapped mid-address. An upstream too long
    /// even for its own line is cut in the middle, and its tooltip shows all of it.
    @ViewBuilder
    private var listenerDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Upstream")
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize()
                Text(verbatim: upstreamDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: upstreamDisplay))
            }
            HStack(spacing: 4) {
                if let port = listenerPort {
                    Text("Listening on")
                        .foregroundColor(Theme.textTertiary)
                    LocalListenerAddress.text(port: port)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(route.enabled ? Theme.success : Theme.textSecondary)
                        .textSelection(.enabled)
                } else {
                    Text(route.enabled ? "Listener starting…" : "Listener off")
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
        .font(.system(size: 11))

        if let port = listenerPort {
            HStack(spacing: 6) {
                copyButton(.proxyURL, port: port)
                copyButton(.exports, port: port)
            }
            .padding(.top, 4)
        }
    }

    /// `.vpnDefault` / `.direct` routes have no loopback listener: show what they target.
    private var nonListenerDetails: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                Text(verbatim: upstreamDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 4) {
                Image(systemName: route.egress == .vpnDefault ? "lock.shield" : "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(route.enabled ? Theme.success : Theme.textTertiary)
                Text(verbatim: nonListenerStatusLabel)
                    .font(.system(size: 11))
                    .foregroundColor(route.enabled ? Theme.success : Theme.textTertiary)
            }
        }
    }

    private func copyButton(_ kind: CopyKind, port: UInt16) -> some View {
        let done = copied == kind
        return Button {
            // RouteRow has no routeManager in scope; the singleton is what
            // ProxyListenerManager.shared above already uses from this file.
            let text = kind.text(port: port, secret: RouteManager.shared.ensureLocalProxySecret())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = kind }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { if copied == kind { copied = nil } }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: done ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                Text(done ? "Copied" : kind.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(done ? Theme.success : Theme.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((done ? Theme.success : Theme.blue).opacity(0.15))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
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
    @State private var peers: [RouteManager.TailscalePeer] = []

    // VPN egress: which tunnel to target ("" = primary/automatic).
    @State private var selectedVPNInterface: String
    @State private var vpnProductHint: String
    @State private var vpnLinks: [RouteManager.VPNLink] = []
    /// Live tunnels PLUS ones seen before, so a VPN that is currently disconnected can still
    /// be chosen — live enumeration alone only ever reports tunnels that are UP.
    @State private var selectableLinks: [(link: RouteManager.RememberedLink, isLive: Bool)] = []

    init(
        editingRoute: Route?,
        onSave: @escaping (Route) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.editingRoute = editingRoute
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
                        Picker("", selection: $egress) {
                            Text("HTTP CONNECT").tag(Egress.proxyHTTP)
                            Text("SOCKS5").tag(Egress.proxySOCKS5)
                            Text("Tailscale Peer").tag(Egress.tailscaleExit)
                            Text("VPN").tag(Egress.vpnDefault)
                        }
                        .pickerStyle(.segmented)
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
                                Picker("", selection: Binding(
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
                                            Text(peer.exitNodeCapable ? "\(peer.name) · exit node" : peer.name)
                                        }
                                        .tag(peer.ip)
                                    }
                                }
                                .pickerStyle(.menu)
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
                Picker("", selection: Binding(
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
