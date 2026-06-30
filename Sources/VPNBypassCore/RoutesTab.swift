// RoutesTab.swift
// Settings tab for managing proxy routes (HTTP CONNECT / SOCKS5).

import SwiftUI
import AppKit

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
    @ObservedObject private var listenerManager = ProxyListenerManager.shared
    @State private var sheetState: RouteSheetState?

    private var proxyRoutes: [Route] {
        routeManager.config.routes.filter {
            $0.egress == .proxyHTTP || $0.egress == .proxySOCKS5
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

                if !proxyRoutes.isEmpty {
                    Text("\(proxyRoutes.filter { $0.enabled }.count)/\(proxyRoutes.count) active")
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
                .help("Add Proxy Route")
            }

            // Helper hint
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.top, 1)
                Text("Point an app at a route: paste the copied proxy exports into your shell, or enter 127.0.0.1:<port> in your browser's manual proxy settings.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if proxyRoutes.isEmpty {
                emptyState
            } else {
                routeList
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44))
                .foregroundColor(Theme.textDisabled)
            Text("No proxy routes yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text("Add one to route specific traffic through a proxy (e.g. Oxylabs).")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
            Button {
                sheetState = .add
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                    Text("Add Proxy Route")
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
        SettingsCard(title: "Proxy Routes", icon: "arrow.triangle.branch", iconColor: Theme.blue) {
            VStack(spacing: 0) {
                ForEach(Array(proxyRoutes.enumerated()), id: \.element.id) { idx, route in
                    RouteRow(route: route, listenerPort: listenerManager.port(for: route.id)) {
                        sheetState = .edit(route)
                    } onDelete: {
                        deleteRoute(route)
                    } onToggle: { enabled in
                        toggleRoute(route.id, enabled: enabled)
                    }
                    if idx < proxyRoutes.count - 1 {
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
        Task { await routeManager.reconcileProxyListeners() }
    }

    private func deleteRoute(_ route: Route) {
        routeManager.config.routes.removeAll { $0.id == route.id }
        routeManager.saveConfig()
        Task { await routeManager.reconcileProxyListeners() }
    }

    private func toggleRoute(_ id: UUID, enabled: Bool) {
        guard let idx = routeManager.config.routes.firstIndex(where: { $0.id == id }) else { return }
        routeManager.config.routes[idx].enabled = enabled
        routeManager.saveConfig()
        Task { await routeManager.reconcileProxyListeners() }
    }
}

// MARK: - RouteRow

struct RouteRow: View {
    let route: Route
    let listenerPort: UInt16?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void

    @State private var didCopy = false

    private var typeLabel: String {
        route.egress == .proxyHTTP ? "HTTP CONNECT" : "SOCKS5"
    }

    private var typeAccent: Color {
        route.egress == .proxyHTTP ? Theme.blue : Theme.purple
    }

    private var upstreamDisplay: String {
        let host = route.proxyHost ?? "—"
        if let port = route.proxyPort {
            return "\(host):\(port)"
        }
        return host
    }

    var body: some View {
        HStack(spacing: 10) {
            // Enabled toggle
            Toggle("", isOn: Binding(
                get: { route.enabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .tint(Theme.success)
            .scaleEffect(0.75)
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

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                        Text(upstreamDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10))
                            .foregroundColor(route.enabled ? Theme.success : Theme.textTertiary)
                        if let port = listenerPort {
                            Text("127.0.0.1:\(port)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(route.enabled ? Theme.success : Theme.textSecondary)
                        } else {
                            Text(route.enabled ? "starting…" : "inactive")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
            }

            Spacer()

            // Copy shell exports — only available once listener is up
            if let port = listenerPort {
                Button {
                    let text = HookGenerator.shellExports(port: port)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation { didCopy = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { didCopy = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(didCopy ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(didCopy ? Theme.success : Theme.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background((didCopy ? Theme.success : Theme.blue).opacity(0.15))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

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
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
    }

    private var isEditing: Bool { editingRoute != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text(isEditing ? "Edit Proxy Route" : "Add Proxy Route")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider().background(Theme.divider)

            // Form fields
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formField(label: "Name", required: true) {
                        TextField("e.g. Oxylabs Residential", text: $name)
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
                        }
                        .pickerStyle(.segmented)
                    }

                    formField(label: "Upstream Host", required: true) {
                        TextField("pr.oxylabs.io", text: $proxyHost)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Theme.bgInput)
                            .cornerRadius(8)
                    }

                    formField(label: "Upstream Port", required: true) {
                        TextField("8080", text: $proxyPortText)
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
    }

    @ViewBuilder
    private func formField<F: View>(
        label: String,
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
        let trimmedHost = proxyHost.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Name is required."
            return
        }
        guard !trimmedHost.isEmpty else {
            validationError = "Upstream host is required."
            return
        }
        guard let port = Int(proxyPortText.trimmingCharacters(in: .whitespaces)),
              (1 ... 65535).contains(port) else {
            validationError = "Port must be a number between 1 and 65535."
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
            proxyPass: proxyPass.isEmpty ? nil : proxyPass
        )
        onSave(route)
    }
}
