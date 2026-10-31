// AboutPage.swift
// The About page (section 3.5 of docs/design/APP-REWORK-PROPOSALS.md), which replaces Info: the
// wordmark, one line with the version, licence and author, three buttons (Website, GitHub,
// Report a problem…) and one "Support the project" row whose popup holds the four ways to give.
//
// "Report a problem…" copies a diagnostics bundle and opens a new issue on GitHub. The bundle
// carries versions, the VPN type, the mode, counts and recent warnings, and no names: every
// domain, address, service, rule, route, URL, e-mail and user folder is replaced before it
// leaves the app.

import AppKit
import SwiftUI

// MARK: - Model

enum AboutPage {
    static let websiteURL = URL(string: "https://geiserx.github.io/VPN-Bypass/")!
    static let repositoryURL = URL(string: "https://github.com/GeiserX/VPN-Bypass")!

    /// The four ways to give, in the order the Support popup lists them.
    struct SupportOption: Equatable {
        let name: String
        let url: URL
    }

    static let supportOptions: [SupportOption] = [
        SupportOption(name: "GitHub Sponsors", url: URL(string: "https://github.com/sponsors/GeiserX")!),
        SupportOption(name: "Buy Me a Coffee", url: URL(string: "https://buymeacoffee.com/geiser")!),
        SupportOption(name: "Patreon", url: URL(string: "https://patreon.com/geiser")!),
        SupportOption(name: "Thanks.dev", url: URL(string: "https://thanks.dev/u/gh/geiserx")!),
    ]

    /// "Version 6.0.0 · GPL-3.0 · by GeiserX". The version is the bundle's, never typed in.
    static func versionLine(_ version: String, in bundle: Bundle = .main) -> String {
        String(localized: "Version \(version) · GPL-3.0 · by GeiserX", bundle: bundle)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

/// The text "Report a problem…" copies, and the issue it opens. Pure, so the redaction is tested.
enum Diagnostics {
    struct Input {
        var appVersion: String
        var helperVersion: String?
        var helperState: String
        var macOS: String
        var architecture: String
        var vpnConnected: Bool
        var vpnType: String?
        var mode: RouteManager.RoutingMode
        var servicesOn: Int
        var domainsOn: Int
        var domainsTotal: Int
        var vpnOnlyEntries: Int
        var rules: Int
        var routes: Int
        var routedAddresses: Int
        var lastFailed: Int?
        var autoApply: Bool
        var hostsFile: Bool
        var pathCheck: Bool
        var refreshEvery: TimeInterval?
        var globalProxy: Bool
        var lookups: Bool
        /// The newest warnings and errors, oldest first.
        var recent: [RouteManager.LogEntry]
        /// Every name the user typed or picked: domains, services, rule patterns, route names,
        /// the proxy server. Each is taken out of the log lines, whatever its shape.
        var names: [String]
    }

    /// How many warnings and errors the bundle carries.
    static let recentLimit = 10

    static func bundle(_ i: Input) -> String {
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        var lines = [
            "VPN Bypass diagnostics (no names: domains, addresses, services and routes are replaced)",
            "App: \(i.appVersion)",
            // A failed state carries the install error, which may name a folder or a host.
            "Helper: \(i.helperVersion ?? "unknown"), \(redact(i.helperState, names: i.names))",
            "macOS: \(i.macOS), \(i.architecture)",
            "VPN: \(i.vpnConnected ? "connected" : "not connected")\(i.vpnType.map { ", \($0)" } ?? "")",
            "Mode: \(i.mode.rawValue)",
            "Lists: \(i.servicesOn) services on, \(i.domainsOn) of \(i.domainsTotal) domains on, \(i.vpnOnlyEntries) VPN Only entries, \(i.rules) rules, \(i.routes) routes",
            "Routed: \(i.routedAddresses) addresses\(i.lastFailed.map { ", \($0) failed at the last apply" } ?? "")",
            "Settings: apply on connect \(onOff(i.autoApply)), /etc/hosts \(onOff(i.hostsFile)), path check \(onOff(i.pathCheck)), look up again \(i.refreshEvery.map { "every \(Int($0)) s" } ?? "never"), SOCKS5 proxy \(onOff(i.globalProxy)), lookups \(onOff(i.lookups))",
            "Recent warnings and errors:",
        ]
        let recent = i.recent.suffix(recentLimit)
        if recent.isEmpty {
            lines.append("(none)")
        } else {
            let time = DateFormatter()
            time.locale = Locale(identifier: "en_US_POSIX")
            time.timeZone = TimeZone(identifier: "UTC")
            time.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
            for entry in recent {
                lines.append("- \(time.string(from: entry.timestamp)) [\(entry.level.rawValue)] \(redact(entry.message, names: i.names))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"[A-Za-z][A-Za-z0-9+.-]*://\S+"#, "<url>"),
        (#"/Users/[^/\s]+"#, "/Users/<user>"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?::\d+)?\b"#, "<address>"),
        (#"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:/\d{1,3})?(?![\w:])"#, "<address>"),
        (#"(?:\*\.)?\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}\b"#, "<name>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// The line with every name taken out: the user's own names first (a service called
    /// "Work Tools" has no dot to find), then anything shaped like an e-mail, a URL, a user
    /// folder, an IPv4 or IPv6 address or range, or a host name.
    static func redact(_ line: String, names: [String]) -> String {
        var out = line
        // Longest first, so "mail.example.com" goes before "example.com" leaves "mail." behind.
        for name in names.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ $0.count >= 2 })
            .sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: name, with: "<name>", options: [.caseInsensitive])
        }
        for (regex, replacement) in patterns {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: replacement)
        }
        return out
    }

    /// The new-issue page on the bug form, with the version filled in and the bundle in the Logs
    /// field when the link stays short enough for a browser; the clipboard holds it either way.
    static func issueURL(version: String, bundle: String, maxLength: Int = 7000) -> URL {
        func url(includingLogs: Bool) -> URL {
            var components = URLComponents(url: AboutPage.repositoryURL.appendingPathComponent("issues/new"),
                                           resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "template", value: "bug_report.yml"),
                         URLQueryItem(name: "version", value: version)]
            if includingLogs { items.append(URLQueryItem(name: "logs", value: bundle)) }
            components.queryItems = items
            // URLComponents leaves "+" alone, and the form would read it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url!
        }
        let full = url(includingLogs: true)
        return full.absoluteString.count <= maxLength ? full : url(includingLogs: false)
    }

    /// The live state, read on the main actor when the button is pressed.
    @MainActor
    static func current(_ rm: RouteManager) -> Input {
        let config = rm.config
        var names = config.domains.map(\.domain) + config.inverseDomains.map(\.domain)
        names += config.services.flatMap { [$0.name] + $0.domains + $0.ipRanges }
        // The built-in Direct and VPN routes' names are words every log line may use; they name nothing.
        names += config.rules.map(\.pattern)
            + config.routes.filter { $0.egress != .direct && $0.name.lowercased() != "vpn" }.map(\.name)
        names += config.routes.compactMap(\.proxyHost)
        names += [config.proxyConfig.server, config.proxyConfig.username].filter { !$0.isEmpty }
        let recent = rm.recentLogs
            .filter { $0.level == .warning || $0.level == .error }
            .sorted { $0.timestamp < $1.timestamp }
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        return Input(
            appVersion: AboutPage.appVersion,
            helperVersion: HelperManager.shared.helperVersion,
            helperState: String(describing: HelperManager.shared.helperState),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: arch,
            vpnConnected: rm.isVPNConnected,
            vpnType: rm.vpnType?.rawValue,
            mode: config.routingMode,
            servicesOn: config.services.filter(\.enabled).count,
            domainsOn: config.domains.filter(\.enabled).count,
            domainsTotal: config.domains.count,
            vpnOnlyEntries: config.inverseDomains.count,
            rules: config.rules.count,
            routes: config.routes.count,
            routedAddresses: rm.activeRoutes.count,
            lastFailed: rm.lastRouteChange?.failedCount,
            autoApply: config.autoApplyOnVPN,
            hostsFile: config.manageHostsFile,
            pathCheck: config.verifyRoutesAfterApply,
            refreshEvery: config.autoDNSRefresh ? config.dnsRefreshInterval : nil,
            globalProxy: config.proxyConfig.enabled,
            lookups: config.dnsLookupsEnabled,
            recent: recent,
            names: names
        )
    }
}

// MARK: - View

struct AboutTab: View {
    @State private var reportCopied = false

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.s) {
                BrandedAppName(fontSize: 28)
                Text(AboutPage.versionLine(AboutPage.appVersion))
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(.top, Theme.Space.l)

            HStack(spacing: Theme.Space.s) {
                Button(String(localized: "Website")) { NSWorkspace.shared.open(AboutPage.websiteURL) }
                Button(String(localized: "GitHub")) { NSWorkspace.shared.open(AboutPage.repositoryURL) }
                Button(String(localized: "Report a problem…")) { reportProblem() }
                    .help(String(localized: "Copies a diagnostics bundle with no names in it and opens a new issue"))
            }

            if reportCopied {
                Text("Diagnostics copied, with no names in them. If the issue's Logs field is empty, paste them there.")
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupSection {
                GeneralRow(String(localized: "Support the project"), detail: String(localized: "Four ways to give, in one menu")) {
                    Menu {
                        ForEach(AboutPage.supportOptions, id: \.name) { option in
                            Button(option.name) { NSWorkspace.shared.open(option.url) }
                        }
                    } label: {
                        Text("Choose…")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .accessibilityLabel(String(localized: "Support the project"))
                }
            }
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }

    private func reportProblem() {
        let text = Diagnostics.bundle(Diagnostics.current(RouteManager.shared))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        reportCopied = true
        NSWorkspace.shared.open(Diagnostics.issueURL(version: AboutPage.appVersion, bundle: text))
    }
}
