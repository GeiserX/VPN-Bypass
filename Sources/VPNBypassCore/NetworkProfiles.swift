// NetworkProfiles.swift
// Profiles per network (idea 9 of docs/design/APP-REWORK-PROPOSALS.md). A profile is a saved
// mode plus lists: the domains, the VPN Only list, the rules and which services are on. A
// service is kept by its id, so a profile points into the service catalogue and never copies
// it. Networks are told apart by their router: its address, its MAC from the ARP table, and
// whether the Mac reaches it over Wi-Fi or Ethernet. That needs no Location permission and
// works on Ethernet, where a Wi-Fi name does not exist.
//
// The config's own fields are always the settings in use. Switching stores them into the slot
// of the profile that was in use (or "Other networks", the settings for any network no profile
// claims), then loads the new one's. RouteManager runs the switch from its status pass and
// applies through the normal mode-switch apply, which waits for the settle gate.

import Foundation
import SwiftUI
import SystemConfiguration

// MARK: - Network identity

/// One network, as its router identifies it.
struct NetworkIdentity: Codable, Hashable {
    /// How the Mac reaches the router.
    enum Kind: String, Codable {
        case wifi, ethernet, other

        /// From SystemConfiguration's interface type.
        init(interfaceType: String?) {
            if interfaceType == kSCNetworkInterfaceTypeIEEE80211 as String {
                self = .wifi
            } else if interfaceType == kSCNetworkInterfaceTypeEthernet as String {
                self = .ethernet
            } else {
                self = .other
            }
        }

        func title(in bundle: Bundle = .main) -> String {
            switch self {
            case .wifi: return String(localized: "Wi-Fi", bundle: bundle)
            case .ethernet: return String(localized: "Ethernet", bundle: bundle)
            case .other: return String(localized: "Other connection", bundle: bundle)
            }
        }
    }

    var gateway: String
    /// Lowercase, two digits per byte: "3c:84:6a:01:02:03".
    var routerMAC: String
    var kind: Kind

    /// "Wi-Fi, router 192.0.2.1".
    func title(in bundle: Bundle = .main) -> String {
        let kindTitle = kind.title(in: bundle)
        return String(localized: "\(kindTitle), router \(gateway)", bundle: bundle)
    }

    /// The router's MAC and the interface it was learned on, from `arp -n <gateway>`:
    /// `? (192.0.2.1) at 3c:84:6a:1:2:3 on en0 ifscope [ethernet]`. Nil when the entry is
    /// missing or incomplete, or the address is a broadcast or all-zero one.
    static func parseARP(_ output: String, gateway: String) -> (mac: String, interface: String)? {
        let pattern = #"\(([0-9.]+)\) at ([0-9A-Fa-f]{1,2}(?::[0-9A-Fa-f]{1,2}){5}) on ([A-Za-z0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges == 4,
                  let ipRange = Range(match.range(at: 1), in: text),
                  let macRange = Range(match.range(at: 2), in: text),
                  let ifRange = Range(match.range(at: 3), in: text),
                  text[ipRange] == gateway,
                  let mac = normalizedMAC(String(text[macRange])) else { continue }
            return (mac, String(text[ifRange]))
        }
        return nil
    }

    /// `arp` drops leading zeros ("3c:84:6a:1:2:3"); stored and compared with them back.
    static func normalizedMAC(_ raw: String) -> String? {
        let parts = raw.lowercased().split(separator: ":")
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && UInt8($0, radix: 16) != nil }) else {
            return nil
        }
        let mac = parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
        guard mac != "ff:ff:ff:ff:ff:ff", mac != "00:00:00:00:00:00" else { return nil }
        return mac
    }

    /// The kind of the interface named `bsdName` ("en0"). Asks configd, so call it off the
    /// main thread.
    static func kind(ofInterface bsdName: String) -> Kind {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return .other }
        for interface in all where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
            return Kind(interfaceType: SCNetworkInterfaceGetInterfaceType(interface) as String?)
        }
        return .other
    }
}

// MARK: - Profiles

/// What a profile keeps: the mode and its lists. Services are kept by id.
struct ProfileSettings: Codable, Equatable {
    var routingMode: RoutingMode
    var domains: [DomainEntry]
    var inverseDomains: [DomainEntry]
    /// The services that are on, by catalogue or custom-service id.
    var enabledServiceIds: [String]
    var rules: [Rule]
    var defaultRouteId: UUID?

    init(capturing config: Config) {
        routingMode = config.routingMode
        domains = config.domains
        inverseDomains = config.inverseDomains
        enabledServiceIds = config.services.filter(\.enabled).map(\.id)
        rules = config.rules
        defaultRouteId = config.defaultRouteId
    }

    /// `config` with these settings in use. The service definitions stay the config's own: an
    /// id this profile names that is no longer listed is skipped, a service it does not name
    /// is off.
    func applied(to config: Config) -> Config {
        var c = config
        c.routingMode = routingMode
        c.domains = domains
        c.inverseDomains = inverseDomains
        let on = Set(enabledServiceIds)
        for i in c.services.indices { c.services[i].enabled = on.contains(c.services[i].id) }
        c.rules = rules
        c.defaultRouteId = defaultRouteId
        // Custom mode reads its rules only from schema 2 on (`usesCustomEngine`).
        if routingMode == .custom, c.schemaVersion < 2 { c.schemaVersion = 2 }
        return c
    }

    func withoutResolveFailures() -> ProfileSettings {
        var s = self
        for i in s.domains.indices { s.domains[i].resolveFailures = nil }
        for i in s.inverseDomains.indices { s.inverseDomains[i].resolveFailures = nil }
        return s
    }
}

struct NetworkProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// A network belongs to one profile at most.
    var networks: [NetworkIdentity]
    /// The profile's settings while it is not in use. While it is, the config's own fields
    /// are the live copy and this is what they were when it was last stored.
    var settings: ProfileSettings
}

/// The profile logic, pure so it is tested.
enum NetworkProfiles {
    enum Target: Equatable {
        case profile(UUID)
        case otherNetworks
    }

    /// The profile that claims `network`, or nil for Other networks.
    static func profileId(for network: NetworkIdentity, in profiles: [NetworkProfile]) -> UUID? {
        profiles.first { $0.networks.contains(network) }?.id
    }

    /// Where the config should switch to on `network`, or nil to stay. A network that could
    /// not be identified (no router yet, no ARP entry) changes nothing.
    static func switchTarget(for network: NetworkIdentity?, in config: Config) -> Target? {
        guard let network, !config.profiles.isEmpty || config.activeProfileId != nil else { return nil }
        let wanted = profileId(for: network, in: config.profiles)
        guard wanted != config.activeProfileId else { return nil }
        return wanted.map(Target.profile) ?? .otherNetworks
    }

    /// `config` with the settings in use stored into the slot of whatever is in use.
    static func storingLiveSettings(_ config: Config) -> Config {
        var c = config
        let live = ProfileSettings(capturing: config)
        if let id = c.activeProfileId, let index = c.profiles.firstIndex(where: { $0.id == id }) {
            c.profiles[index].settings = live
        } else {
            c.activeProfileId = nil
            c.otherNetworksSettings = live
        }
        return c
    }

    /// Stores the settings in use, then puts `target`'s in use. A profile that is gone
    /// changes nothing.
    static func switching(_ config: Config, to target: Target) -> Config {
        if case .profile(let id) = target, !config.profiles.contains(where: { $0.id == id }) { return config }
        var c = storingLiveSettings(config)
        let settings: ProfileSettings?
        switch target {
        case .profile(let id):
            settings = c.profiles.first { $0.id == id }?.settings
            c.activeProfileId = id
        case .otherNetworks:
            settings = c.otherNetworksSettings
            c.activeProfileId = nil
        }
        if let settings { c = settings.applied(to: c) }
        if c.activeProfileId == nil { c.otherNetworksSettings = nil }
        return c
    }

    /// A new profile with the settings in use, for `network`, put in use at once. Nothing
    /// routes differently: the settings are the same, only where edits are kept changes.
    static func creatingProfile(named name: String, for network: NetworkIdentity, in config: Config) -> Config {
        var c = storingLiveSettings(config)
        for i in c.profiles.indices { c.profiles[i].networks.removeAll { $0 == network } }
        let profile = NetworkProfile(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     networks: [network], settings: ProfileSettings(capturing: config))
        c.profiles.append(profile)
        c.activeProfileId = profile.id
        return c
    }

    /// Moves `network` to profile `id`. The caller then switches, as for a network change.
    static func addingNetwork(_ network: NetworkIdentity, to id: UUID, in config: Config) -> Config {
        guard config.profiles.contains(where: { $0.id == id }) else { return config }
        var c = config
        for i in c.profiles.indices {
            c.profiles[i].networks.removeAll { $0 == network }
            if c.profiles[i].id == id { c.profiles[i].networks.append(network) }
        }
        return c
    }

    /// Deletes profile `id`. When it is in use, Other networks is put in use first.
    static func removingProfile(_ id: UUID, in config: Config) -> Config {
        var c = config
        if c.activeProfileId == id { c = switching(c, to: .otherNetworks) }
        c.profiles.removeAll { $0.id == id }
        return c
    }

    /// A name is free when it is not blank and no profile, nor Other networks, has it.
    static func nameIsFree(_ name: String, in profiles: [NetworkProfile], bundle: Bundle = .main) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        let taken = profiles.map { $0.name.lowercased() } + [otherNetworksName(in: bundle).lowercased()]
        return !taken.contains(trimmed)
    }

    /// Whether a switch applies now. Never while the VPN is down (the connect applies), while
    /// paused (Resume applies what is in use then), or when the VPN has just connected or a
    /// post-reconnect apply is waiting: the settle gate's apply then carries the new lists.
    enum ApplyAction: Equatable { case none, now }

    static func applyAction(vpnConnected: Bool, justConnected: Bool, paused: Bool, settlePending: Bool) -> ApplyAction {
        guard vpnConnected, !justConnected, !paused, !settlePending else { return .none }
        return .now
    }

    // MARK: Words

    static func otherNetworksName(in bundle: Bundle = .main) -> String {
        String(localized: "Other networks", bundle: bundle)
    }

    static func networkCount(_ count: Int, in bundle: Bundle = .main) -> String {
        switch count {
        case 0: return String(localized: "No network yet", bundle: bundle)
        case 1: return String(localized: "1 network", bundle: bundle)
        default: return String(localized: "\(count) networks", bundle: bundle)
        }
    }

    /// A profile row's detail: "Bypass · 2 networks". The mode is the one in use when the
    /// profile is, since its stored copy may be older.
    static func detail(mode: RoutingMode, networks: Int, in bundle: Bundle = .main) -> String {
        RoutingModeCopy.name(mode) + " · " + networkCount(networks, in: bundle)
    }

    /// Other networks' detail: "Bypass · Any network without a profile".
    static func otherNetworksDetail(mode: RoutingMode, in bundle: Bundle = .main) -> String {
        RoutingModeCopy.name(mode) + " · " + String(localized: "Any network without a profile", bundle: bundle)
    }

    static func useOnThisNetworkName(_ profile: String, in bundle: Bundle = .main) -> String {
        String(localized: "Use \(profile) on this network", bundle: bundle)
    }
}

// MARK: - View

/// The Network profiles group on the General page: this network, Other networks and each
/// profile, and the button that saves a profile for this network.
struct NetworkProfilesGroup: View {
    @EnvironmentObject var routeManager: RouteManager
    @State private var showingNewProfile = false

    var body: some View {
        let config = routeManager.config
        let network = routeManager.currentNetwork
        GroupSection(GeneralPage.Group.networkProfiles.title()) {
            Text("A profile keeps a mode and its lists. When the Mac joins one of its networks, the profile is put in use. Networks are told apart by their router.")
                .font(Theme.Font.detail)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ListRow.inset)
                .padding(.vertical, Theme.Space.s)
            InsetDivider.plain
            GeneralRow(String(localized: "This network")) {
                Text(network?.title() ?? String(localized: "Not identified yet"))
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            if !config.profiles.isEmpty {
                InsetDivider.plain
                row(name: NetworkProfiles.otherNetworksName(),
                    detail: NetworkProfiles.otherNetworksDetail(mode: config.otherNetworksSettings?.routingMode ?? config.routingMode),
                    inUse: config.activeProfileId == nil) { EmptyView() }
                ForEach(config.profiles) { profile in
                    InsetDivider.plain
                    let inUse = config.activeProfileId == profile.id
                    row(name: profile.name,
                        detail: NetworkProfiles.detail(mode: inUse ? config.routingMode : profile.settings.routingMode,
                                                       networks: profile.networks.count),
                        inUse: inUse) {
                        if let network, !profile.networks.contains(network) {
                            Button(String(localized: "Use on This Network")) {
                                routeManager.useProfileOnThisNetwork(profile.id)
                            }
                            .controlSize(.small)
                            .accessibilityLabel(NetworkProfiles.useOnThisNetworkName(profile.name))
                        }
                        Button {
                            routeManager.deleteProfile(profile.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 22, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(ControlNames.delete(profile.name))
                        .accessibilityLabel(ControlNames.delete(profile.name))
                    }
                }
            }
            InsetDivider.plain
            GeneralRow(nil) {
                Button(String(localized: "Save as Profile for This Network…")) { showingNewProfile = true }
                    .buttonStyle(.plain)
                    .foregroundColor(network == nil ? Theme.textSecondary : Theme.accentText)
                    .disabled(network == nil)
                Spacer()
            }
        }
        .sheet(isPresented: $showingNewProfile) {
            NewProfileSheet(profiles: config.profiles,
                            onCancel: { showingNewProfile = false },
                            onSave: { name in
                                routeManager.createProfile(named: name)
                                showingNewProfile = false
                            })
        }
    }

    private func row<Actions: View>(name: String, detail: String, inUse: Bool,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        GeneralRow(name, detail: detail) {
            if inUse {
                Text("In use")
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
            }
            actions()
        }
        .accessibilityElement(children: .contain)
    }
}

/// Names a new profile for this network.
struct NewProfileSheet: View {
    let profiles: [NetworkProfile]
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var name: String

    init(profiles: [NetworkProfile], name: String = "", onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.profiles = profiles
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: name)
    }

    var body: some View {
        let free = NetworkProfiles.nameIsFree(name, in: profiles)
        let blank = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        SheetScaffold(String(localized: "New profile"), confirmTitle: String(localized: "Save"), canConfirm: free,
                      onCancel: onCancel, onConfirm: { if free { onSave(name) } }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Saves the mode and lists in use now for this network. Changes made while the profile is in use stay in it.")
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SheetField(String(localized: "Name"), required: true) {
                    TextField(String(localized: "Home, Office…"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(String(localized: "Name"))
                }
                if !blank && !free {
                    SheetError(message: String(localized: "A profile with this name exists."))
                }
            }
        }
    }
}
