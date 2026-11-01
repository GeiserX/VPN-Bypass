// LookupAddPanel.swift
// The DNS Lookups page's add panel: the popover a row's ⋯ (More ways to add) opens. It picks what to add
// (the looked-up name, or a wildcard over it) and where (the current mode's list, a new
// service, or any service). The choice logic is plain values here, so it is tested without
// a view; `LookupAddPanel` only draws it.

import SwiftUI

// MARK: - Wildcard levels

/// The wildcard levels a looked-up name offers: `*.us5.datadoghq.com` and `*.datadoghq.com`
/// for api.us5.datadoghq.com. Never `*.com`, and never a wildcard over a public suffix such
/// as `*.co.uk`, which would take in every site under it.
enum LookupAddLevels {
    /// Two-label public suffixes under which a site's own domain has three labels. A short
    /// built-in list, not the Public Suffix List: it only has to stop the widest wildcard
    /// from covering other people's sites in the countries that register this way.
    static let twoLabelPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "ac.uk", "gov.uk", "sch.uk", "nhs.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "ne.kr", "ac.kr", "go.kr",
        "co.in", "net.in", "org.in", "gov.in", "ac.in",
        "co.za", "org.za", "gov.za", "ac.za",
        "co.il", "org.il", "ac.il", "gov.il",
        "co.id", "or.id", "ac.id", "go.id",
        "co.th", "in.th", "ac.th", "go.th",
        "com.br", "net.br", "org.br", "gov.br",
        "com.mx", "org.mx", "gob.mx",
        "com.ar", "gob.ar", "com.co", "com.pe", "com.uy", "com.ve", "com.ec",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.hk", "org.hk", "edu.hk", "gov.hk",
        "com.tw", "org.tw", "edu.tw", "gov.tw",
        "com.sg", "org.sg", "edu.sg", "gov.sg",
        "com.my", "org.my", "gov.my",
        "com.tr", "org.tr", "gov.tr", "edu.tr",
        "com.ua", "org.ua", "gov.ua",
        "com.pl", "org.pl", "com.es", "org.es", "gob.es", "com.pt", "com.gr", "com.ru", "org.ru",
        "com.sa", "com.eg", "com.ng", "com.ph", "com.pk", "com.vn", "com.bd", "com.np",
    ]

    /// Hosting and CDN domains that give each customer a name of their own (from the private
    /// section of the Public Suffix List). `*.cloudfront.net` would take in every site on
    /// CloudFront, company ones too, so under these the site is the three-label name as well.
    static let hostingSuffixes: Set<String> = [
        "cloudfront.net", "amazonaws.com", "azurewebsites.net", "azureedge.net", "cloudapp.net",
        "github.io", "gitlab.io", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev",
        "workers.dev", "appspot.com", "web.app", "firebaseapp.com", "fastly.net", "blogspot.com",
        "onrender.com", "fly.dev",
    ]

    /// How many labels a site's own domain has under `labels`: three under a two-label public
    /// suffix or a hosting domain, two otherwise. A name that is itself such a suffix ("co.uk") has fewer, so it
    /// has no site domain and no wildcard.
    ///
    /// Under amazonaws.com everything but the first label is a shared AWS endpoint
    /// (`s3.amazonaws.com`, `execute-api.eu-west-1.amazonaws.com`), so the whole name is the
    /// customer's, and a name of three labels or fewer is an endpoint with no wildcard.
    static func floor(_ labels: [Substring]) -> Int {
        let last2 = labels.suffix(2).joined(separator: ".")
        if last2 == "amazonaws.com" { return max(labels.count, 4) }
        return twoLabelPublicSuffixes.contains(last2) || hostingSuffixes.contains(last2) ? 3 : 2
    }

    /// The site's own domain under `name` ("datadoghq.com", "bbc.co.uk"), lowercased, or nil
    /// for a name with fewer labels than that.
    static func registrableDomain(_ name: String) -> String? {
        let bare = WildcardDomain.isWildcard(name) ? String(name.dropFirst(WildcardDomain.prefix.count)) : name
        let labels = bare.lowercased().split(separator: ".")
        let floor = floor(labels)
        guard labels.count >= floor else { return nil }
        return labels.suffix(floor).joined(separator: ".")
    }

    /// The name itself first, then every wildcard over it from the narrowest to the site's own
    /// domain. A name that is the site's own domain gets its one wildcard, which holds the
    /// name too. A name with fewer labels (`localhost`, `co.uk`) gets no wildcard.
    static func levels(for name: String) -> [String] {
        let labels = name.lowercased().split(separator: ".")
        let floor = floor(labels)
        guard labels.count >= floor else { return [name] }
        let widest = labels.count == floor ? floor : labels.count - 1
        let wildcards = stride(from: widest, through: floor, by: -1).compactMap { count in
            WildcardDomain.normalizedSuffix(labels.suffix(count).joined(separator: ".")).map(WildcardDomain.entry(for:))
        }
        return [name] + wildcards
    }
}

// MARK: - Where it goes

/// Where the add panel puts what it adds.
enum LookupAddTarget: Hashable {
    /// The current mode's list: the Bypass list, or the VPN Only list.
    case modeList
    /// Custom mode: a rule to the Direct route, a domain rule for a name, a suffix rule for a
    /// wildcard.
    case directRule
    /// A new custom service, named in a sheet.
    case newService
    /// A service by id, built-in or custom.
    case service(String)
}

/// The three ways the page can add a name, one per routing mode.
enum LookupMode {
    case bypass, vpnOnly, custom

    @MainActor init(_ routeManager: RouteManager) {
        let config = routeManager.config
        if config.routingMode == .vpnOnly {
            self = .vpnOnly
        } else if RouteManager.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            self = .custom
        } else {
            self = .bypass
        }
    }

    var addTitle: String {
        switch self {
        case .bypass: return String(localized: "Add to Bypass")
        case .vpnOnly: return String(localized: "Add to VPN Only")
        case .custom: return String(localized: "Send Direct")
        }
    }

    var addHelp: String {
        switch self {
        case .bypass: return String(localized: "Add to the Bypass list")
        case .vpnOnly: return String(localized: "Add to the VPN Only list")
        case .custom: return String(localized: "Add a rule that sends it Direct")
        }
    }
}

/// What the panel offers for one name in one mode. Bypass mode: the Bypass list, New
/// Service, and every service. VPN Only mode: the VPN Only list alone, as services route only
/// in Bypass mode. Custom mode: a Direct rule alone, the mode's own form of a bypass.
struct LookupAddChoices {
    let name: String
    let mode: LookupMode
    /// The name, then its wildcards (`LookupAddLevels.levels`).
    let levels: [String]
    /// The places above the service list.
    let targets: [LookupAddTarget]
    /// Bypass mode's services, in `RouteManager.lookupServices` order; empty in the others.
    let services: [ServiceEntry]

    init(name: String, mode: LookupMode, services: [ServiceEntry]) {
        self.name = name
        self.mode = mode
        levels = LookupAddLevels.levels(for: name)
        switch mode {
        case .bypass:
            targets = [.modeList, .newService]
            self.services = services
        case .vpnOnly:
            targets = [.modeList]
            self.services = []
        case .custom:
            targets = [.directRule]
            self.services = []
        }
    }

    /// The name itself, which is what the row's own button adds.
    var defaultLevel: String { name }
    var defaultTarget: LookupAddTarget { targets[0] }

    /// The services whose name contains `search`, in the same order; all of them when empty.
    func services(matching search: String) -> [ServiceEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return services }
        return services.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The target once the search reads `search`: a service the search hides is no longer
    /// picked, so Add can never send the name somewhere the panel does not show.
    func target(_ current: LookupAddTarget, whenSearching search: String) -> LookupAddTarget {
        guard case .service(let id) = current, !services(matching: search).contains(where: { $0.id == id }) else { return current }
        return defaultTarget
    }
}

// MARK: - The panel

struct LookupAddPanel: View {
    let choices: LookupAddChoices
    /// True while routes are being applied: Add waits, as the row's own buttons do.
    var isBusy = false
    /// What to add, then where; the panel closes itself after.
    let onAdd: (String, LookupAddTarget) -> Void
    let onCancel: () -> Void
    @State private var level: String
    @State private var target: LookupAddTarget
    @State private var search = ""

    /// One service row; the list shows up to `maxRows` of them before it scrolls.
    static let rowHeight: CGFloat = 24
    static let maxRows = 8
    static let width: CGFloat = 340

    /// The service box's height: as tall as `count` rows, up to `maxRows`.
    static func listHeight(count: Int) -> CGFloat {
        CGFloat(min(count, maxRows)) * rowHeight
    }

    init(choices: LookupAddChoices, level: String? = nil, target: LookupAddTarget? = nil, isBusy: Bool = false,
         onAdd: @escaping (String, LookupAddTarget) -> Void, onCancel: @escaping () -> Void) {
        self.choices = choices
        self.isBusy = isBusy
        self.onAdd = onAdd
        self.onCancel = onCancel
        _level = State(initialValue: level ?? choices.defaultLevel)
        _target = State(initialValue: target ?? choices.defaultTarget)
    }

    private var isWildcard: Bool { WildcardDomain.isWildcard(level) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            section(String(localized: "What to Add")) {
                ForEach(choices.levels, id: \.self) { value in
                    choiceRow(selected: level == value, action: { level = value }) {
                        Text(verbatim: value)
                            .font(Theme.Font.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if choices.levels.count > 1 {
                    Text("A wildcard covers every name under it. The helper routes each one as it is looked up, so the Lookups page need not be watching.")
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 22)
                }
            }

            section(String(localized: "Where")) {
                ForEach(choices.targets, id: \.self) { place in
                    choiceRow(selected: target == place, action: { target = place }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(place)).font(Theme.Font.body)
                            if place == .directRule {
                                Text(isWildcard ? String(localized: "Matches every name under \(String(level.dropFirst(WildcardDomain.prefix.count)))")
                                                : String(localized: "Matches this name only"))
                                    .font(Theme.Font.detail)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                    }
                }
                if !choices.services.isEmpty {
                    serviceList
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(target == .newService ? String(localized: "Add…") : String(localized: "Add")) {
                    onAdd(level, target)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(isBusy)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: Self.width)
        // A service picked here and deleted meanwhile is no longer picked.
        .onChange(of: choices.services.map(\.id)) { _ in target = choices.target(target, whenSearching: search) }
    }

    private var serviceList: some View {
        let shown = choices.services(matching: search)
        return VStack(alignment: .leading, spacing: 6) {
            LogSearchField(text: $search, placeholder: String(localized: "Search services"))
                .onChange(of: search) { newValue in target = choices.target(target, whenSearching: newValue) }
            Group {
                if shown.isEmpty {
                    Text("No service matches \"\(search)\"")
                        .font(Theme.Font.detail)
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                } else {
                    // The box is as tall as the rows, up to `maxRows`. A list that fits is drawn
                    // as it is, so it can never show a scroll bar; a longer one scrolls in the box.
                    ViewThatFits(in: .vertical) {
                        serviceRows(shown)
                        ScrollView { serviceRows(shown) }
                    }
                    .frame(height: Self.listHeight(count: shown.count))
                }
            }
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.bgInput))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.border, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .padding(.leading, 22)
    }

    private func serviceRows(_ services: [ServiceEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(services) { service in
                choiceRow(selected: target == .service(service.id), action: { target = .service(service.id) }) {
                    HStack(spacing: 6) {
                        Text(service.name)
                            .font(Theme.Font.body)
                            .foregroundColor(service.enabled ? Theme.text : Theme.textSecondary)
                            .lineLimit(1)
                        if !service.enabled {
                            Text("off")
                                .font(Theme.Font.detail)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(height: Self.rowHeight)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Font.section)
                .foregroundColor(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func choiceRow<Label: View>(selected: Bool, action: @escaping () -> Void,
                                        @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(selected ? Theme.accent : Theme.textSecondary)
                    .accessibilityHidden(true)
                label()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func title(_ place: LookupAddTarget) -> String {
        switch place {
        case .modeList:
            return choices.mode == .vpnOnly ? String(localized: "VPN Only list") : String(localized: "Bypass list")
        case .directRule:
            return String(localized: "Direct rule")
        case .newService:
            return String(localized: "New Service…")
        case .service(let id):
            return choices.services.first { $0.id == id }?.name ?? id
        }
    }
}
