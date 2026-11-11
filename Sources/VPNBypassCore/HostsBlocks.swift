// HostsBlocks.swift
// Custom mode's Block route for a list too large for wildcards: the names go in /etc/hosts as
// `0.0.0.0 name` (HostsBlockSection), through the helper's `updateBlockedHosts`. A GeoSite list of
// up to 10,000 wildcards is served by the DNS forwarder, which also covers the subdomains; a list
// past that (an ad list of 200,000 names) would need a resolver file per suffix, which stops being
// practical, so its names are blocked exactly here instead, and their subdomains are not.
//
// It is written only when "Pin listed names in /etc/hosts" is on, the one switch that lets the app
// write that file. The names have their own section, so the pinned names' frequent updates never
// carry the list, and the helper rewrites it only when the blocked set changes. First match holds:
// a name an earlier rule claims is not blocked. Like the address blocks, these follow the rules, not
// the VPN, and come out with the other routes on a mode switch, a pause, Remove All Routes or a quit.

import Foundation

/// What the hosts file holds for Custom mode's Block rules, and why it holds nothing when it does not.
struct HostsBlockState: Equatable {
    /// Names in the blocked section now.
    var count = 0
    /// Why the last write failed.
    var error: String?
    /// Names are wanted, but the setting that lets the app write /etc/hosts is off.
    var needsHostsFile = false
}

extension RouteManager {

    /// The names Block rules put in /etc/hosts, in rule order: every name of a GeoSite list on the
    /// Block route that is too large for wildcards (and not past the hosts section's own limit), less
    /// the names an earlier rule claims. A claim is any earlier rule's name, suffix or list, whatever
    /// its route, so an allow rule above a block keeps its names.
    static func hostsBlockNames(config: Config, geosite lists: [String: GeoSiteExpansion]) -> [String] {
        guard usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) else { return [] }
        let routes = Dictionary(config.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let services = Dictionary(config.services.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var claimedSuffixes = Set<String>()
        var claimedNames = Set<String>()
        var seen = Set<String>()
        var names: [String] = []
        var bytes = 0
        for rule in config.rules.filter(\.enabled).sorted(by: { $0.order < $1.order }) {
            guard let route = routes[rule.routeId], route.enabled, route.egress != .unsupported else { continue }
            if route.egress == .block, rule.matchType == .geosite,
               let list = lists[rule.pattern.lowercased()], list.found, list.exceedsWildcards(onBlock: true),
               list.count <= HostsBlockSection.maxNames {
                // The helper takes the whole update or none of it, so a list that would put the
                // total over its count or byte budget is left out whole, not cut.
                var added: [String] = []
                var addedBytes = 0
                var local = Set<String>()
                for name in list.suffixes + list.names where HostsBlockSection.isValidName(name) {
                    if claimedNames.contains(name) || WildcardDomain.ancestors(of: name).contains(where: claimedSuffixes.contains) {
                        continue
                    }
                    guard !seen.contains(name), local.insert(name).inserted else { continue }
                    added.append(name)
                    addedBytes += name.utf8.count + HostsBlockSection.address.utf8.count + 2
                }
                if names.count + added.count <= HostsBlockSection.maxNames, bytes + addedBytes <= HostsBlockSection.maxBytes {
                    names += added
                    seen.formUnion(added)
                    bytes += addedBytes
                }
            }
            let (entries, exact) = WildcardPlanner.claims(of: rule, services: services, lists: lists)
            for entry in entries { if let suffix = WildcardDomain.suffix(of: entry) { claimedSuffixes.insert(suffix) } }
            for name in exact.compactMap(WildcardDomain.normalizedSuffix) { claimedNames.insert(name) }
        }
        return names
    }

    /// The helper's call, or the test seam's.
    func updateBlockedHostsVia(_ names: [String]) async -> (success: Bool, error: String?) {
        if let override = updateBlockedHostsOverrideForTests { return await override(names) }
        return await HelperManager.shared.updateBlockedHosts(names: names)
    }

    /// Makes the hosts file's blocked section the names the rules want now. Called by every Custom
    /// apply; a list that did not change is not sent again.
    func applyHostsBlocks() async {
        guard !isPaused, !isShuttingDown else { return }
        var names = Self.hostsBlockNames(config: config, geosite: geositeExpansions())
        let wanted = !names.isEmpty
        if wanted && !config.manageHostsFile {
            // Not the app's to write: say so, and take back what an earlier setting put there.
            names = []
            let state = HostsBlockState(count: 0, error: nil, needsHostsFile: true)
            if hostsBlock != state { hostsBlock = state }
            if hostsBlockSignature == nil && !hostsBlockMayExist { return }
        }
        if !wanted && hostsBlockSignature == nil && !hostsBlockMayExist {
            if hostsBlock != HostsBlockState() { hostsBlock = HostsBlockState() }
            return
        }
        guard HelperManager.shared.isHelperInstalled || updateBlockedHostsOverrideForTests != nil else { return }
        let signature = names.hashValue
        if signature == hostsBlockSignature, hostsBlock.error == nil { return }
        // From here on a section may exist, whatever the write reports: a timed-out write can finish
        // later, and a failed replacement leaves the previous section in place.
        if !names.isEmpty { hostsBlockMayExist = true }
        let result = await updateBlockedHostsVia(names)
        if result.success {
            hostsBlockMayExist = !names.isEmpty
            hostsBlockSignature = names.isEmpty ? nil : signature
            hostsBlock = HostsBlockState(count: names.count, error: nil, needsHostsFile: wanted && names.isEmpty)
            if wanted && !names.isEmpty { log(.success, "Block: \(names.count) name(s) blocked in /etc/hosts") }
        } else {
            hostsBlockSignature = nil
            hostsBlock = HostsBlockState(count: 0, error: result.error ?? "unknown", needsHostsFile: false)
            log(.warning, "Block: could not write the blocked names to /etc/hosts (\(result.error ?? "no reason given")); the next apply tries again")
        }
    }

    /// Takes the blocked section out of the hosts file. A failure keeps the signature, so a later
    /// teardown or the startup check tries again.
    func releaseHostsBlocks(reason: String) async {
        guard hostsBlockSignature != nil || hostsBlockMayExist else { return }
        guard HelperManager.shared.isHelperInstalled || updateBlockedHostsOverrideForTests != nil else {
            log(.error, "Cannot release the blocked names in /etc/hosts: the helper is not ready; they stay until it is")
            return
        }
        let result = await updateBlockedHostsVia([])
        if result.success {
            hostsBlockSignature = nil
            hostsBlockMayExist = false
            hostsBlock = HostsBlockState()
            log(.info, "Released the blocked names in /etc/hosts: \(reason)")
        } else {
            log(.warning, "Could not release the blocked names in /etc/hosts (\(reason)): \(result.error ?? "no reason given")")
        }
    }

    /// A blocked section left by a run that did not quit cleanly goes now when no rule wants it; when
    /// one does, the first apply puts the same names back and the helper writes nothing.
    func reconcileHostsBlocksAtStartup() async {
        guard HelperManager.shared.isHelperInstalled || updateBlockedHostsOverrideForTests != nil,
              let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8),
              HostsBlockSection.hasSection(hosts) else { return }
        let wanted = !Self.hostsBlockNames(config: config, geosite: geositeExpansions()).isEmpty
        guard !wanted || !config.manageHostsFile else {
            // Wanted and allowed: the next apply puts the names back, but a release before it must
            // still take this section out.
            hostsBlockMayExist = true
            return
        }
        let result = await updateBlockedHostsVia([])
        if result.success {
            log(.info, "Removed the blocked names a previous run left in /etc/hosts")
        } else {
            log(.warning, "Could not remove the blocked names a previous run left in /etc/hosts: \(result.error ?? "no reason given")")
        }
    }
}
