// VPNKillSwitch.swift
// Notice when the VPN forces every connection into its tunnel, so routes cannot take effect.
//
// A VPN built on Apple's NetworkExtension can set `includeAllNetworks` (what Proton VPN's kill
// switch turns on) or `enforceRoutes`. Either one makes the system send connections into the
// tunnel above the routing table (every connection, or with `enforceRoutes` those the VPN's own
// routes cover), so the host routes this app installs stay in the table and do nothing. With `includeAllNetworks`, `excludeLocalNetworks` lets local-network addresses out.
//
// macOS keeps every NetworkExtension configuration in one world-readable file,
// `/Library/Preferences/com.apple.networkextension.plist`, an NSKeyedArchiver archive. Its top
// level maps each configuration's UUID to an `NEConfiguration`; a VPN configuration holds an
// `NEVPN` under "VPN", whose "Protocol" (`NETunnelProviderProtocol`, `NEVPNProtocolIKEv2`, ...)
// carries the flags. `scutil --nc list` names the configurations that are connected, by the
// same UUID. Reading both needs no privilege and no NetworkExtension entitlement.
//
// The archive is read with stand-in classes, so nothing from NetworkExtension is loaded and
// only the few keys used here are decoded. Anything missing or odd gives "unknown", never a
// crash: this is a warning, and no warning is the old behaviour.

import Foundation
import SystemConfiguration

/// The setting of a connected VPN that defeats the app's routes. Nil means none found.
public struct VPNKillSwitch: Equatable, Sendable {
    /// What to call the VPN: the product when its app is recognised, else the configuration's name.
    public let name: String?
    public let includeAllNetworks: Bool
    public let enforceRoutes: Bool
    public let excludeLocalNetworks: Bool

    public init(name: String?, includeAllNetworks: Bool, enforceRoutes: Bool, excludeLocalNetworks: Bool) {
        self.name = name
        self.includeAllNetworks = includeAllNetworks
        self.enforceRoutes = enforceRoutes
        self.excludeLocalNetworks = excludeLocalNetworks
    }

    /// The flags that are on, by Apple's property names, for `vpnb status`.
    public var flagNames: [String] {
        var names: [String] = []
        if includeAllNetworks { names.append("includeAllNetworks") }
        if enforceRoutes { names.append("enforceRoutes") }
        if includeAllNetworks && excludeLocalNetworks { names.append("excludeLocalNetworks") }
        return names
    }
}

/// One VPN configuration from the archive. A nil flag was not in the archive.
public struct NEVPNConfigurationInfo: Equatable, Sendable {
    /// The configuration's UUID, upper case, as `scutil --nc list` prints it.
    public let id: String
    public let name: String?
    /// The bundle id of the app that installed it.
    public let application: String?
    public let includeAllNetworks: Bool?
    public let enforceRoutes: Bool?
    public let excludeLocalNetworks: Bool?

    public init(id: String, name: String?, application: String?, includeAllNetworks: Bool?,
                enforceRoutes: Bool?, excludeLocalNetworks: Bool?) {
        self.id = id
        self.name = name
        self.application = application
        self.includeAllNetworks = includeAllNetworks
        self.enforceRoutes = enforceRoutes
        self.excludeLocalNetworks = excludeLocalNetworks
    }

    var defeatsRoutes: Bool { includeAllNetworks == true || enforceRoutes == true }
}

public enum VPNKillSwitchReader {
    public static let configurationsPath = "/Library/Preferences/com.apple.networkextension.plist"

    // MARK: - Pure

    /// Every VPN configuration in the archive. Empty for data that is not a readable archive.
    public static func vpnConfigurations(from data: Data) -> [NEVPNConfigurationInfo] {
        parseArchive(data)?.configurations ?? []
    }

    /// The archive's VPN configurations, and the ids (upper case) of the entries that failed to
    /// decode. Nil for data that is not a readable archive.
    static func parseArchive(_ data: Data) -> (configurations: [NEVPNConfigurationInfo], undecoded: Set<String>)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let top = plist["$top"] as? [String: Any] else { return nil }
        // The other top-level keys (Version, Generation, Index) are not configurations.
        let ids = top.keys.filter { UUID(uuidString: $0) != nil }.sorted()
        var result: [NEVPNConfigurationInfo] = []
        var undecoded = Set<String>()
        var unarchiver = makeUnarchiver(data)
        guard unarchiver != nil else { return nil }
        for id in ids {
            guard let current = unarchiver else {
                undecoded.insert(id.uppercased())
                continue
            }
            let config = current.decodeObject(of: NEConfigurationStub.self, forKey: id)
            if current.error != nil {
                // An error sticks to the unarchiver; start a fresh one for the next configuration.
                undecoded.insert(id.uppercased())
                unarchiver = makeUnarchiver(data)
                continue
            }
            guard let config, let vpn = config.vpn else { continue }
            let proto = vpn.proto
            result.append(NEVPNConfigurationInfo(
                id: id.uppercased(), name: config.name, application: config.application,
                includeAllNetworks: proto?.includeAllNetworks, enforceRoutes: proto?.enforceRoutes,
                excludeLocalNetworks: proto?.excludeLocalNetworks))
        }
        return (result, undecoded)
    }

    /// The UUIDs `scutil --nc list` marks "(Connected)", upper case.
    public static func connectedIDs(fromNCList output: String) -> Set<String> {
        var ids = Set<String>()
        for line in output.split(separator: "\n") {
            guard let open = line.range(of: "("), let close = line.range(of: ")", range: open.upperBound..<line.endIndex),
                  line[open.upperBound..<close.lowerBound] == "Connected" else { continue }
            let rest = line[close.upperBound...].split(separator: " ", omittingEmptySubsequences: true)
            if let first = rest.first, UUID(uuidString: String(first)) != nil {
                ids.insert(first.uppercased())
            }
        }
        return ids
    }

    /// The kill switch of a connected VPN, or nil. `includeAllNetworks` takes every connection
    /// whichever tunnel the app acts on, so any connected VPN with it counts. `enforceRoutes`
    /// only takes what the VPN's own routes cover, so it counts only on `trackedInterface` (the
    /// tunnel the app acts on): a split VPN beside it leaves the app's routes working. When
    /// several count, the one on `trackedInterface` wins, then the first by id.
    public static func killSwitch(configurations: [NEVPNConfigurationInfo], connected: Set<String>,
                                  interfaces: [String: String] = [:],
                                  trackedInterface: String? = nil) -> VPNKillSwitch? {
        let onTracked = { (c: NEVPNConfigurationInfo) in
            trackedInterface != nil && interfaces[c.id] == trackedInterface
        }
        let candidates = configurations.filter {
            connected.contains($0.id) && ($0.includeAllNetworks == true || ($0.enforceRoutes == true && onTracked($0)))
        }
        guard !candidates.isEmpty else { return nil }
        let chosen = candidates.first(where: onTracked)
            ?? candidates.min { $0.id < $1.id }!
        let product = chosen.application.flatMap {
            TunnelOwnership.productLabel(processName: "", executablePath: $0)
        }
        let name = product ?? chosen.name.flatMap { $0.isEmpty ? nil : $0 }
        return VPNKillSwitch(name: name,
                             includeAllNetworks: chosen.includeAllNetworks == true,
                             enforceRoutes: chosen.enforceRoutes == true,
                             excludeLocalNetworks: chosen.excludeLocalNetworks == true)
    }

    // MARK: - Live

    /// The kill switch of a connected VPN, from the archive at `path` and the `connected` ids
    /// (`scutil --nc list`). `.some(nil)` is a successful read with no kill switch; nil means
    /// the file could not be read or parsed, or a connected entry failed to decode, so the
    /// caller keeps what it knew. Blocking but cheap: one
    /// file read, and a status call only for a connected configuration that has a flag on.
    /// Never call it on the main thread.
    static func read(connected: Set<String>, trackedInterface: String?,
                     path: String = configurationsPath) -> VPNKillSwitch?? {
        guard !connected.isEmpty else { return .some(nil) }
        guard let data = FileManager.default.contents(atPath: path),
              let archive = parseArchive(data),
              archive.undecoded.isDisjoint(with: connected) else { return nil }
        let configurations = archive.configurations
        var interfaces: [String: String] = [:]
        for config in configurations where connected.contains(config.id) && config.defeatsRoutes {
            interfaces[config.id] = interfaceName(ofConfiguration: config.id)
        }
        return killSwitch(configurations: configurations, connected: connected,
                          interfaces: interfaces, trackedInterface: trackedInterface)
    }

    /// The tunnel a connected configuration runs on, as `scutil --nc status <id>` shows it.
    private static func interfaceName(ofConfiguration id: String) -> String? {
        guard let connection = SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil),
              let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any],
              let ipv4 = status["IPv4"] as? [String: Any] else { return nil }
        return ipv4["InterfaceName"] as? String
    }

    // MARK: - Archive stand-ins

    /// The archive's class names and the stand-in that decodes each. The protocol classes
    /// all keep the flags under the same keys.
    static let standIns: [(name: String, cls: AnyClass)] = [
        ("NEConfiguration", NEConfigurationStub.self),
        ("NEVPN", NEVPNStub.self),
        ("NEVPNProtocol", NEVPNProtocolStub.self),
        ("NETunnelProviderProtocol", NEVPNProtocolStub.self),
        ("NEVPNProtocolIKEv2", NEVPNProtocolStub.self),
        ("NEVPNProtocolIPSec", NEVPNProtocolStub.self),
        ("NEVPNProtocolL2TP", NEVPNProtocolStub.self),
        ("NEVPNProtocolPPTP", NEVPNProtocolStub.self),
    ]

    private static func makeUnarchiver(_ data: Data) -> NSKeyedUnarchiver? {
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        u.decodingFailurePolicy = .setErrorAndReturn
        u.requiresSecureCoding = true
        for entry in standIns { u.setClass(entry.cls, forClassName: entry.name) }
        return u
    }
}

/// Reads the optional Bool under `key`: nil when it is absent. The archive stores a Bool
/// inline, where `decodeObject` cannot see it, so this asks for a Bool.
private func optionalBool(_ coder: NSCoder, _ key: String) -> Bool? {
    guard coder.containsValue(forKey: key) else { return nil }
    return coder.decodeBool(forKey: key)
}

@objc(VPNBypassNEConfigurationStub)
final class NEConfigurationStub: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let name: String?
    let application: String?
    let vpn: NEVPNStub?

    init(name: String?, application: String?, vpn: NEVPNStub?) {
        self.name = name
        self.application = application
        self.vpn = vpn
    }

    init?(coder: NSCoder) {
        name = coder.decodeObject(of: NSString.self, forKey: "Name") as String?
        application = coder.decodeObject(of: NSString.self, forKey: "Application") as String?
        vpn = coder.decodeObject(of: NEVPNStub.self, forKey: "VPN")
    }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "Name")
        coder.encode(application, forKey: "Application")
        coder.encode(vpn, forKey: "VPN")
    }
}

@objc(VPNBypassNEVPNStub)
final class NEVPNStub: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let proto: NEVPNProtocolStub?

    init(proto: NEVPNProtocolStub?) {
        self.proto = proto
    }

    init?(coder: NSCoder) {
        proto = coder.decodeObject(of: NEVPNProtocolStub.self, forKey: "Protocol")
    }

    func encode(with coder: NSCoder) {
        coder.encode(proto, forKey: "Protocol")
    }
}

@objc(VPNBypassNEVPNProtocolStub)
final class NEVPNProtocolStub: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let includeAllNetworks: Bool?
    let enforceRoutes: Bool?
    let excludeLocalNetworks: Bool?

    init(includeAllNetworks: Bool?, enforceRoutes: Bool?, excludeLocalNetworks: Bool?) {
        self.includeAllNetworks = includeAllNetworks
        self.enforceRoutes = enforceRoutes
        self.excludeLocalNetworks = excludeLocalNetworks
    }

    init?(coder: NSCoder) {
        includeAllNetworks = optionalBool(coder, "IncludeAllNetworks")
        enforceRoutes = optionalBool(coder, "EnforceRoutes")
        excludeLocalNetworks = optionalBool(coder, "ExcludeLocalNetworks")
    }

    func encode(with coder: NSCoder) {
        if let includeAllNetworks { coder.encode(includeAllNetworks, forKey: "IncludeAllNetworks") }
        if let enforceRoutes { coder.encode(enforceRoutes, forKey: "EnforceRoutes") }
        if let excludeLocalNetworks { coder.encode(excludeLocalNetworks, forKey: "ExcludeLocalNetworks") }
    }
}
