// GeneralPage.swift
// The General page (section 3.5 of docs/design/APP-REWORK-PROPOSALS.md): five native groups
// with no icons (Startup, Routing, DNS servers, Notifications, Configuration), then the global
// SOCKS5 proxy behind an Advanced disclosure. Custom mode has its own proxy routes, so there the
// disclosure gives way to one sentence that points at the Routes page.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// What the General page shows and how its choices map onto the config. Pure, so it is tested.
enum GeneralPage {
    /// The page's groups, top to bottom.
    enum Group: CaseIterable {
        case startup, routing, dnsServers, notifications, configuration

        func title(in bundle: Bundle = .main) -> String {
            switch self {
            case .startup: return String(localized: "Startup", bundle: bundle)
            case .routing: return String(localized: "Routing", bundle: bundle)
            case .dnsServers: return String(localized: "DNS servers", bundle: bundle)
            case .notifications: return String(localized: "Notifications", bundle: bundle)
            case .configuration: return String(localized: "Configuration", bundle: bundle)
            }
        }
    }

    // MARK: Look up addresses again

    /// The intervals "Look up addresses again" offers, in seconds. Never is the extra choice.
    static let refreshIntervals: [TimeInterval] = [900, 1800, 3600, 7200, 21600]

    /// The popup's choices: every listed interval, the saved one when it is not listed (set in
    /// config.json or by an older version), then Never (nil).
    static func refreshChoices(current: TimeInterval) -> [TimeInterval?] {
        var intervals = refreshIntervals
        if current > 0, !intervals.contains(current) { intervals.append(current) }
        return intervals.sorted().map { Optional($0) } + [nil]
    }

    /// The popup's selection: nil (Never) when the periodic lookup is off.
    static func refreshSelection(autoRefresh: Bool, interval: TimeInterval) -> TimeInterval? {
        autoRefresh ? interval : nil
    }

    /// Writes a choice into the config. Never turns the lookup off and keeps the interval, so
    /// turning it back on (from `vpnb` or an older version) finds the one it had.
    static func apply(_ selection: TimeInterval?, to config: inout RouteManager.Config) {
        if let selection {
            config.autoDNSRefresh = true
            config.dnsRefreshInterval = selection
        } else {
            config.autoDNSRefresh = false
        }
    }

    static func refreshLabel(_ interval: TimeInterval?, in bundle: Bundle = .main) -> String {
        guard let interval else { return String(localized: "Never", bundle: bundle) }
        let minutes = Int((interval / 60).rounded())
        if minutes == 60 { return String(localized: "Every hour", bundle: bundle) }
        if minutes > 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return String(localized: "Every \(hours) hours", bundle: bundle)
        }
        return String(localized: "Every \(minutes) minutes", bundle: bundle)
    }

    // MARK: The global SOCKS5 proxy (3.5 A)

    /// The global proxy is shown in Bypass and VPN Only, behind Advanced. Custom mode sends
    /// traffic to a proxy with a route of its own, so the global one is hidden there.
    static func showsGlobalProxy(in mode: RouteManager.RoutingMode) -> Bool {
        mode != .custom
    }

    /// The one sentence Custom mode shows where the Advanced disclosure would be.
    static func customProxyNote(in bundle: Bundle = .main) -> String {
        String(localized: "In Custom mode, send traffic through a proxy with a route on the Routes page.", bundle: bundle)
    }

    /// Advanced opens by itself when the proxy is on, so nobody who uses it has to look for it.
    static func advancedStartsOpen(proxyEnabled: Bool) -> Bool {
        proxyEnabled
    }

    // MARK: Notifications

    /// The kinds of notification, as checkboxes under the master switch.
    enum NotificationKind: CaseIterable {
        case connect, disconnect, addresses, failures

        func title(in bundle: Bundle = .main) -> String {
            switch self {
            case .connect: return String(localized: "VPN connects", bundle: bundle)
            case .disconnect: return String(localized: "VPN drops", bundle: bundle)
            case .addresses: return String(localized: "Addresses change", bundle: bundle)
            case .failures: return String(localized: "Something fails", bundle: bundle)
            }
        }

        @MainActor var keyPath: ReferenceWritableKeyPath<NotificationManager, Bool> {
            switch self {
            case .connect: return \.notifyOnVPNConnect
            case .disconnect: return \.notifyOnVPNDisconnect
            case .addresses: return \.notifyOnRoutesApplied
            case .failures: return \.notifyOnRouteFailure
            }
        }
    }
}

// MARK: - View

struct GeneralTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var notificationManager: NotificationManager
    @EnvironmentObject var launchAtLoginManager: LaunchAtLoginManager
    @State private var showingImportPicker = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""
    @State private var selectedLanguage: String = UserDefaults.standard.string(forKey: "UserLanguageOverride") ?? "system"
    @State private var showingRestartAlert = false
    @State private var advancedOpen: Bool?
    /// The doc screenshots show a documentation address here, never the build Mac's own.
    static var detectedDNSForScreenshots: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.page) {
            startup
            routing
            dnsServers
            notifications
            configuration
            advanced
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if !routeManager.importConfig(from: url) {
                        importErrorMessage = routeManager.lastImportRefusal
                            ?? String(localized: "Failed to import configuration file.")
                        showingImportError = true
                    }
                }
            case .failure(let error):
                importErrorMessage = error.localizedDescription
                showingImportError = true
            }
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
        .alert(String(localized: "Restart Required"), isPresented: $showingRestartAlert) {
            Button(String(localized: "Restart Now")) {
                // Not `open -n` followed by a quit: the new copy would start while this one
                // still holds the single-instance lock, exit at once, and leave the app closed.
                do {
                    try AppUpdateRelauncher.restart(bundlePath: Bundle.main.bundlePath)
                } catch {
                    RouteManager.shared.log(.warning, "Restart could not be scheduled: \(error.localizedDescription)")
                }
            }
            Button(String(localized: "Later"), role: .cancel) { }
        } message: {
            Text("The app needs to restart to apply the language change.")
        }
    }

    // MARK: Groups

    private var startup: some View {
        GroupSection(GeneralPage.Group.startup.title()) {
            GeneralRow(String(localized: "Open at login")) {
                switchControl(String(localized: "Open at login"), isOn: Binding(
                    get: { launchAtLoginManager.isEnabled },
                    set: { _ in launchAtLoginManager.toggle() }
                ))
            }
            InsetDivider.plain
            GeneralRow(String(localized: "Language"), detail: String(localized: "App language (restart required)")) {
                Picker(String(localized: "Language"), selection: $selectedLanguage) {
                    Text("System").tag("system")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: selectedLanguage) { newValue in
                    if newValue == "system" {
                        UserDefaults.standard.removeObject(forKey: "UserLanguageOverride")
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set(newValue, forKey: "UserLanguageOverride")
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                    showingRestartAlert = true
                }
            }
        }
    }

    private var routing: some View {
        GroupSection(GeneralPage.Group.routing.title()) {
            GeneralRow(String(localized: "Apply when a VPN connects")) {
                switchControl(String(localized: "Apply when a VPN connects"), isOn: Binding(
                    get: { routeManager.config.autoApplyOnVPN },
                    set: { routeManager.config.autoApplyOnVPN = $0; routeManager.saveConfig() }
                ))
            }
            InsetDivider.plain
            GeneralRow(String(localized: "Pin listed names in /etc/hosts"),
                       detail: String(localized: "Needs the helper. Covers apps that use the system resolver.")) {
                switchControl(String(localized: "Pin listed names in /etc/hosts"), isOn: Binding(
                    get: { routeManager.config.manageHostsFile },
                    set: { routeManager.config.manageHostsFile = $0; routeManager.saveConfig() }
                ))
            }
            InsetDivider.plain
            GeneralRow(String(localized: "Look up addresses again")) {
                Picker(String(localized: "Look up addresses again"), selection: Binding(
                    get: {
                        GeneralPage.refreshSelection(autoRefresh: routeManager.config.autoDNSRefresh,
                                                     interval: routeManager.config.dnsRefreshInterval)
                    },
                    set: { choice in
                        GeneralPage.apply(choice, to: &routeManager.config)
                        routeManager.saveConfig()
                        routeManager.startDNSRefreshTimer()
                    }
                )) {
                    ForEach(GeneralPage.refreshChoices(current: routeManager.config.dnsRefreshInterval), id: \.self) { choice in
                        Text(GeneralPage.refreshLabel(choice)).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            InsetDivider.plain
            GeneralRow(String(localized: "Check the path after applying"),
                       detail: String(localized: "Checks which way up to 10 routed addresses leave, and that they answer on port 443.")) {
                switchControl(String(localized: "Check the path after applying"), isOn: Binding(
                    get: { routeManager.config.verifyRoutesAfterApply },
                    set: { routeManager.config.verifyRoutesAfterApply = $0; routeManager.saveConfig() }
                ))
            }
            InsetDivider.plain
            GeneralRow(String(localized: "Block listed sites when the VPN drops"),
                       detail: String(localized: "VPN Only: hold the listed addresses back until the VPN returns")) {
                switchControl(String(localized: "Block listed sites when the VPN drops"), isOn: Binding(
                    get: { routeManager.config.blockListedWhenVPNDown },
                    set: { routeManager.setBlockListedWhenVPNDown($0) }
                ))
            }
        }
    }

    private var dnsServers: some View {
        GroupSection(GeneralPage.Group.dnsServers.title()) {
            GeneralRow(String(localized: "Detected")) {
                Text(verbatim: Self.detectedDNSForScreenshots ?? routeManager.detectedDNSServerDisplay ?? "–")
                    .font(Theme.Font.mono)
                    .foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            Text("Asked at the same time as the detected server. Cloudflare and Google DoH join after 200 ms, and the first answer with addresses wins. When all of them fail, the system resolver answers, which may use the VPN's DNS.")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ListRow.inset)
                .padding(.bottom, Theme.Space.s)
            ForEach(Array(routeManager.config.fallbackDNS.enumerated()), id: \.offset) { index, server in
                InsetDivider.plain
                GeneralRow(nil) {
                    TextField(String(localized: "1.1.1.1, https://… or tls://…"), text: Binding(
                        get: { routeManager.config.fallbackDNS.indices.contains(index) ? routeManager.config.fallbackDNS[index] : "" },
                        set: {
                            guard routeManager.config.fallbackDNS.indices.contains(index) else { return }
                            routeManager.config.fallbackDNS[index] = $0
                            routeManager.saveConfig()
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.mono)
                    .accessibilityLabel(String(localized: "DNS server \(index + 1)"))
                    Button {
                        routeManager.config.fallbackDNS.remove(at: index)
                        routeManager.saveConfig()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(ControlNames.delete(server))
                    .accessibilityLabel(ControlNames.delete(server))
                }
            }
            InsetDivider.plain
            GeneralRow(nil) {
                Button(String(localized: "Add Server")) {
                    routeManager.config.fallbackDNS.append("")
                    routeManager.saveConfig()
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accentText)
                Spacer()
            }
        }
    }

    private var notifications: some View {
        GroupSection(GeneralPage.Group.notifications.title()) {
            GeneralRow(String(localized: "Send notifications")) {
                switchControl(String(localized: "Send notifications"), isOn: Binding(
                    get: { notificationManager.notificationsEnabled },
                    set: { notificationManager.notificationsEnabled = $0; notificationManager.savePreferences() }
                ))
            }
            InsetDivider.plain
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Tell me when")
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                          alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(GeneralPage.NotificationKind.allCases, id: \.self) { kind in
                        Toggle(kind.title(), isOn: Binding(
                            get: { notificationManager[keyPath: kind.keyPath] },
                            set: { notificationManager[keyPath: kind.keyPath] = $0; notificationManager.savePreferences() }
                        ))
                        .toggleStyle(.checkbox)
                        .font(Theme.Font.body)
                        .help(kind == .addresses ? String(localized: "Addresses: services, domains, DNS refresh") : "")
                    }
                }
            }
            .padding(.horizontal, ListRow.inset)
            .padding(.vertical, Theme.Space.s)
            .disabled(!notificationManager.notificationsEnabled)
            .opacity(notificationManager.notificationsEnabled ? 1 : 0.55)
            InsetDivider.plain
            GeneralRow(String(localized: "Play a sound")) {
                switchControl(String(localized: "Play a sound"), isOn: Binding(
                    get: { !notificationManager.silentNotifications },
                    set: { notificationManager.silentNotifications = !$0; notificationManager.savePreferences() }
                ))
            }
            .disabled(!notificationManager.notificationsEnabled)
            .opacity(notificationManager.notificationsEnabled ? 1 : 0.55)
        }
    }

    private var configuration: some View {
        GroupSection(GeneralPage.Group.configuration.title()) {
            GeneralRow(String(localized: "Domains, services, rules and routes")) {
                Button(String(localized: "Export…")) { exportConfig() }
                    .controlSize(.small)
                Button(String(localized: "Import…")) { showingImportPicker = true }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var advanced: some View {
        if GeneralPage.showsGlobalProxy(in: routeManager.config.routingMode) {
            DisclosureGroup(isExpanded: Binding(
                get: { advancedOpen ?? GeneralPage.advancedStartsOpen(proxyEnabled: routeManager.config.proxyConfig.enabled) },
                set: { advancedOpen = $0 }
            )) {
                proxyGroup
                    .padding(.top, Theme.Space.s)
            } label: {
                Text("Advanced: SOCKS5 for VPNs that block UDP")
                    .font(Theme.Font.strong)
                    .foregroundColor(Theme.textSecondary)
            }
        } else {
            Text(GeneralPage.customProxyNote())
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var proxyGroup: some View {
        GroupSection {
            GeneralRow(String(localized: "Enable SOCKS5 Proxy"),
                       detail: String(localized: "For corporate VPNs (Cisco, Zscaler) that block UDP. Requires external SOCKS5 proxy server with UDP support."),
                       detailLines: nil) {
                switchControl(String(localized: "Enable SOCKS5 Proxy"), isOn: Binding(
                    get: { routeManager.config.proxyConfig.enabled },
                    set: { routeManager.config.proxyConfig.enabled = $0; routeManager.saveConfig() }
                ))
            }
            if routeManager.config.proxyConfig.enabled {
                InsetDivider.plain
                GeneralRow(String(localized: "Proxy Server")) {
                    TextField(String(localized: "Server address"), text: Binding(
                        get: { routeManager.config.proxyConfig.server },
                        set: { routeManager.config.proxyConfig.server = $0; routeManager.saveConfig() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .accessibilityLabel(String(localized: "Server address"))
                    TextField(String(localized: "Port"), value: Binding(
                        get: { routeManager.config.proxyConfig.port },
                        set: { routeManager.config.proxyConfig.port = $0; routeManager.saveConfig() }
                    ), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .frame(width: 70)
                    .accessibilityLabel(String(localized: "Port"))
                }
                InsetDivider.plain
                GeneralRow(String(localized: "Authentication (optional)")) {
                    TextField(String(localized: "Username"), text: Binding(
                        get: { routeManager.config.proxyConfig.username },
                        set: { routeManager.config.proxyConfig.username = $0; routeManager.saveConfig() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 130)
                    .accessibilityLabel(String(localized: "Username"))
                    SecureField(String(localized: "Password"), text: Binding(
                        get: { routeManager.config.proxyConfig.password },
                        set: { routeManager.config.proxyConfig.password = $0; routeManager.saveConfig() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 130)
                    .accessibilityLabel(String(localized: "Password"))
                }
                InsetDivider.plain
                GeneralRow(nil) {
                    Button(routeManager.isTestingProxy ? String(localized: "Testing...") : String(localized: "Test Connection")) {
                        Task { await routeManager.testProxyConnection() }
                    }
                    .controlSize(.small)
                    .disabled(!routeManager.config.proxyConfig.isConfigured || routeManager.isTestingProxy)
                    if let result = routeManager.proxyTestResult {
                        Text(result.message)
                            .font(Theme.Font.detail)
                            .foregroundColor(result.success ? Theme.textSecondary : Theme.failure)
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: Parts

    private func switchControl(_ name: String, isOn: Binding<Bool>) -> some View {
        Toggle(name, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(Theme.accent)
    }

    private func exportConfig() {
        guard let exportURL = routeManager.exportConfig() else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = exportURL.lastPathComponent
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            try? FileManager.default.copyItem(at: exportURL, to: destinationURL)
        }
        try? FileManager.default.removeItem(at: exportURL)
    }
}

/// One row of a General group: the setting's name and an optional detail line, then its
/// control at the trailing end. No icon: the name says what the row is.
struct GeneralRow<Control: View>: View {
    let title: String?
    var detail: String?
    var detailLines: Int? = 2
    let control: Control

    init(_ title: String?, detail: String? = nil, detailLines: Int? = 2, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.detailLines = detailLines
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if title != nil || detail != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(title)
                            .font(Theme.Font.body)
                            .foregroundColor(Theme.text)
                    }
                    if let detail {
                        Text(detail)
                            .font(Theme.Font.detail)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(detailLines)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            control
        }
        .padding(.horizontal, ListRow.inset)
        .padding(.vertical, detail == nil ? 0 : Theme.Space.xs + 2)
        .frame(minHeight: detail == nil ? ListRow.singleLineHeight : ListRow.twoLineHeight)
    }
}

extension InsetDivider {
    /// The hairline between two rows that have no glyph column, such as General's.
    static var plain: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.horizontal, ListRow.inset)
            .accessibilityHidden(true)
    }
}
