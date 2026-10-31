// RulesTab.swift
// Settings tab for managing routing rules in Custom Routes mode: an ordered,
// first-match list of destination -> route assignments (see RuleResolver).

import SwiftUI

// MARK: - Route display helpers (UI-only; the model/engine stay untouched)

extension Route {
    /// Friendly display name for route pickers/chips. `.direct`/`.vpnDefault`
    /// are the two auto-created system routes, so their name is derived rather
    /// than stored; proxy/Tailscale routes just use their own user-given name.
    func friendlyName(vpnName: String?, in bundle: Bundle = .main) -> String {
        switch egress {
        case .direct:      return String(localized: "Direct", bundle: bundle)
        case .vpnDefault:
            // A route pinned to a SPECIFIC tunnel is user-created — use its own name so
            // several VPNs are distinguishable. The primary-VPN route derives its label.
            if vpnSelector?.kind == .interface { return name.isEmpty ? String(localized: "VPN", bundle: bundle) : name }
            return vpnName ?? String(localized: "VPN", bundle: bundle)
        case .proxyHTTP, .proxySOCKS5, .tailscaleExit: return name
        }
    }

    /// Accent color by egress type, left only on the dropdown's Custom-mode rollup dots.
    /// The Rules and Routes pages show a grey glyph and a word instead (`RouteChip`).
    var accentColor: Color {
        switch egress {
        case .direct:       return Theme.textSecondary
        case .proxyHTTP:    return Theme.blue
        case .proxySOCKS5:  return Theme.purple
        case .tailscaleExit: return Theme.success
        case .vpnDefault:   return Theme.warning
        }
    }
}

extension RouteManager {
    /// Add a newly-created route and reconcile its listener. UI-only convenience
    /// so the "New Route…" flow (triggered from a rule/default-route chip) doesn't
    /// duplicate the append+persist+reconcile sequence RoutesTab.saveRoute already
    /// performs for edits made directly in the Routes tab.
    func addRoute(_ route: Route) {
        config.routes.append(route)
        saveConfig()
        Task { await reconcileAfterConfigChange(reconcileListeners: true, reapplyRoutes: false) }
    }

    /// Deletes a rule and re-applies, as the Rules page's trash button does.
    func removeRule(_ id: UUID) {
        config.rules.removeAll { $0.id == id }
        saveRulesAndReapply()
    }

    /// Puts back a rule a delete took out, at its old `order`, and re-applies. A rule that has
    /// since taken that order moves down one, with everything after it, so first match runs
    /// as it did before the delete. Returns false while a rule with that id is listed.
    @discardableResult
    func restoreRule(_ rule: Rule) -> Bool {
        guard !config.rules.contains(where: { $0.id == rule.id }) else { return false }
        config.rules = Self.rules(config.rules, restoring: rule)
        saveRulesAndReapply()
        log(.success, "Restored rule: \(rule.pattern)")
        return true
    }

    /// `rules` with `rule` back at its `order`, the rules from that order on moved down one
    /// when another rule holds it now.
    nonisolated static func rules(_ rules: [Rule], restoring rule: Rule) -> [Rule] {
        var result = rules
        if result.contains(where: { $0.order == rule.order }) {
            for i in result.indices where result[i].order >= rule.order {
                result[i].order += 1
            }
        }
        result.append(rule)
        return result
    }

    /// Custom mode's dropdown quick-add: a rule on the Direct route, appended after the
    /// others as `RulesTab.saveRule` appends a new one. An IP range ("10.0.0.0/24") becomes
    /// a `.cidr` rule, checked by the VPN Only list's range check, which is the Rules
    /// editor's `isValidCIDR`; a name or a pasted link becomes a `.domain` rule for its host,
    /// cleaned as the Bypass list cleans it, and a wildcard ("*.example.com") a `.suffix` rule
    /// on its suffix, as `Config.derive` maps one. Saves but does not re-apply; the caller does.
    /// A rule with the same pattern refuses the add, naming its route: on Direct it is a
    /// repeat, and on another route it matches first, so a second rule would do nothing. A
    /// rule whose route is gone matches nothing, so it does not count. Returns the rule
    /// saved, why the input was refused (a Direct route that is off is refused too: the compiler
    /// skips rules on a route that is off), or nil when there is no Direct route (logged).
    func addDirectRule(_ input: String) -> Result<Rule, AddDomainError>? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let checked: CheckedDomainInput
        switch checkDomainInput(trimmed, list: Self.looksLikeIPRange(trimmed) ? .vpnOnly : .bypass) {
        case .failure(let error):
            log(.warning, error.message)
            return .failure(error)
        case .success(let value):
            checked = value
        }
        let suffix = WildcardDomain.suffix(of: checked.value)
        let matchType: MatchType = checked.isCIDR ? .cidr : (suffix == nil ? .domain : .suffix)
        let pattern = suffix ?? checked.value
        guard let directRouteId = config.routes.first(where: { $0.egress == .direct && $0.enabled })?.id else {
            if config.routes.contains(where: { $0.egress == .direct }) {
                let error = AddDomainError.directRouteOff(value: checked.value)
                log(.warning, error.message)
                return .failure(error)
            }
            log(.error, "Cannot add rule for \(checked.value): no Direct route found")
            return nil
        }
        // Only a rule that routes counts: one switched off, or on a route that is off, does not.
        let existing = config.rules
            .filter { $0.enabled && $0.matchType == matchType && $0.pattern == pattern }
            .compactMap { rule in config.routes.first(where: { $0.id == rule.routeId && $0.enabled }) }
            .first
        if let route = existing {
            let error = AddDomainError.ruleExists(value: checked.value, route: route, vpnName: vpnType?.knownName)
            log(.warning, error.message)
            return .failure(error)
        }
        let maxOrder = config.rules.map(\.order).max() ?? -1
        let rule = Rule(matchType: matchType, pattern: pattern, routeId: directRouteId, order: maxOrder + 1)
        config.rules.append(rule)
        saveConfig()
        log(.success, "Added rule: \(checked.value) → Direct")
        return .success(rule)
    }

    /// "Bypass this" in whatever mode is on, for the dropdown's quick-add and the DNS Lookups
    /// page: the Bypass list, the VPN Only list, or in Custom mode a rule to the Direct route.
    /// Custom mode routes from `config.rules`, not `config.domains` (see `usesCustomEngine`),
    /// so a Bypass-list add would silently do nothing there; the rule is the same mapping
    /// `Config.derive()` uses for a bypass-mode domain. A Custom mode add says where the rule
    /// went: it goes last, where an earlier rule may match first (A5). nil is Custom mode's
    /// add when it found no Direct route, which it logs.
    func addForCurrentMode(_ input: String) -> Result<AddedDomain, AddDomainError>? {
        if config.routingMode == .vpnOnly { return addInverseDomain(input) }
        guard Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) else {
            return addDomain(input)
        }
        switch addDirectRule(input) {
        case .success(let rule)?:
            Task { await reconcileAfterConfigChange(reconcileListeners: false, reapplyRoutes: true) }
            return .success(AddedDomain(rule: rule, typed: input,
                                        place: RulePlace(of: rule, in: config.rules, routes: config.routes,
                                                         services: config.services)))
        case .failure(let error)?:
            return .failure(error)
        case nil:
            return nil
        }
    }

    /// Where `name` already is, among the entries the current mode reads: the Bypass list or
    /// an enabled service, the VPN Only list, or a Custom mode domain or suffix rule. nil when
    /// nowhere. A wildcard ("*.example.com") holds every name under it. An enabled entry or
    /// service wins over a switched-off one. The name's own entry switched off is
    /// `.listedOff`: adding it again would be refused. A switched-off wildcard over it is not
    /// a listing, since adding the name itself is accepted.
    func lookupListing(_ name: String) -> LookupListing? {
        if config.routingMode == .vpnOnly {
            if config.inverseDomains.contains(where: { $0.enabled && Self.entry($0.domain, holds: name) }) { return .vpnOnlyList }
            return config.inverseDomains.contains { $0.domain == name } ? .listedOff : nil
        }
        if Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            // The rule the compiler would use: enabled, lowest order, with a route that is on.
            let routes = Dictionary(config.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let match = config.rules
                .filter { rule in
                    rule.enabled && (rule.matchType == .domain && rule.pattern == name
                                     || rule.matchType == .suffix && WildcardDomain.matches(name, suffix: rule.pattern))
                }
                .sorted { $0.order < $1.order }
                .lazy.compactMap { routes[$0.routeId] }
                .first { $0.enabled }
            guard let route = match else { return nil }
            return .rule(routeName: route.friendlyName(vpnName: vpnType?.knownName))
        }
        if config.domains.contains(where: { $0.enabled && Self.entry($0.domain, holds: name) }) { return .bypassList }
        if let service = config.services.first(where: { $0.enabled && $0.domains.contains { Self.entry($0, holds: name) } }) {
            return .service(service.name)
        }
        return config.domains.contains { $0.domain == name } ? .listedOff : nil
    }

    /// A list or service entry holds `name` when it is the name, or a wildcard over it.
    nonisolated static func entry(_ entry: String, holds name: String) -> Bool {
        if entry == name { return true }
        guard let suffix = WildcardDomain.suffix(of: entry) else { return false }
        return WildcardDomain.matches(name, suffix: suffix)
    }

    /// What the Lookups page's remove action takes away for a listed `name` (see `lookupRemoval`).
    func lookupRemoval(_ name: String) -> LookupRemoval? {
        Self.lookupRemoval(name, config: config, vpnName: vpnType?.knownName)
    }

    /// What un-routes a listed `name`, from the entry that lists it (`lookupListing` picks the
    /// same one): the name's own entry on the mode's list before a wildcard over it, and the
    /// first switched-on service that holds it. A domain the user put in a service (a custom
    /// service, or `builtInServiceExtras` of a built-in one) comes out of that service; a
    /// domain a built-in service ships with cannot, so the service is turned off. In Custom
    /// mode the rule in force is deleted when it sends the name to Direct. nil when the name is
    /// not listed, its own entry is switched off (`.listedOff`: turning it on or off is the
    /// Domains page's switch), or a Custom mode rule sends it elsewhere (the Rules page's).
    nonisolated static func lookupRemoval(_ name: String, config: Config, vpnName: String? = nil,
                                          shipped: [ServiceEntry] = Config.defaultServices) -> LookupRemoval? {
        func onList(_ entries: [DomainEntry], _ list: DomainList) -> LookupRemoval? {
            let held = entries.filter { $0.enabled && entry($0.domain, holds: name) }
            guard let pick = held.first(where: { $0.domain == name }) ?? held.first else { return nil }
            return .listEntry(id: pick.id, list: list, entry: pick.domain)
        }
        if config.routingMode == .vpnOnly { return onList(config.inverseDomains, .vpnOnly) }
        if usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode) {
            let routes = Dictionary(config.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let inForce = config.rules
                .filter { rule in
                    rule.enabled && (rule.matchType == .domain && rule.pattern == name
                                     || rule.matchType == .suffix && WildcardDomain.matches(name, suffix: rule.pattern))
                }
                .sorted { $0.order < $1.order }
                .first { routes[$0.routeId]?.enabled == true }
            // Only a rule to Direct is a bypass to undo; a rule to the VPN or a proxy is the
            // Rules page's to change, so the row offers nothing for it.
            guard let rule = inForce, let route = routes[rule.routeId], route.egress == .direct else { return nil }
            let shown = rule.matchType == .domain || WildcardDomain.isWildcard(rule.pattern)
                ? rule.pattern : WildcardDomain.entry(for: rule.pattern)
            return .rule(id: rule.id, entry: shown, routeName: route.friendlyName(vpnName: vpnName))
        }
        if let removal = onList(config.domains, .bypass) { return removal }
        guard let service = config.services.first(where: { $0.enabled && $0.domains.contains { entry($0, holds: name) } }),
              let held = service.domains.contains(name) ? name : service.domains.first(where: { entry($0, holds: name) })
        else { return nil }
        if service.isCustom {
            return .serviceDomain(serviceId: service.id, service: service.name, entry: held)
        }
        let ships = shipped.first { $0.id == service.id }?.domains.contains(held) ?? true
        if !ships, (config.builtInServiceExtras[service.id] ?? []).contains(held) {
            return .serviceDomain(serviceId: service.id, service: service.name, entry: held)
        }
        return .turnOffService(serviceId: service.id, service: service.name)
    }

    /// Does what `removal` says, through the same paths as the Domains, Services and Rules
    /// pages, so the routes go as they do there. The line to show, or nil when what it named
    /// is gone (or the service is already off).
    func removeLookup(_ removal: LookupRemoval, for name: String) -> AddDomainFeedback? {
        let after = Self.config(config, without: removal)
        guard let done = removeLookupEntry(removal) else { return nil }
        // Another entry still holds the name (an exact entry under a wildcard, the list and a
        // service, a second rule): say so, or the row would keep its status with no reason.
        guard !done.isError, Self.lookupRemoval(name, config: after, vpnName: vpnType?.knownName) != nil else { return done }
        return AddDomainFeedback(success: done.message + " "
            + String(localized: "\(name) is still listed by another entry; point at it again to remove that one."))
    }

    /// `config` once `removal` is done, so what still holds the name is known before the
    /// removal's own task (the Domains page's remove runs in one) has finished.
    nonisolated static func config(_ config: Config, without removal: LookupRemoval) -> Config {
        var after = config
        switch removal {
        case .listEntry(let id, let list, _):
            if list == .vpnOnly { after.inverseDomains.removeAll { $0.id == id } } else { after.domains.removeAll { $0.id == id } }
        case .rule(let id, _, _):
            after.rules.removeAll { $0.id == id }
        case .serviceDomain(let serviceId, _, let entry):
            if let i = after.services.firstIndex(where: { $0.id == serviceId }) { after.services[i].domains.removeAll { $0 == entry } }
        case .turnOffService(let serviceId, _):
            if let i = after.services.firstIndex(where: { $0.id == serviceId }) { after.services[i].enabled = false }
        }
        return after
    }

    private func removeLookupEntry(_ removal: LookupRemoval) -> AddDomainFeedback? {
        switch removal {
        case .listEntry(let id, let list, let entry):
            if list == .vpnOnly {
                guard let item = config.inverseDomains.first(where: { $0.id == id }) else { return nil }
                removeInverseDomain(item)
            } else {
                guard let item = config.domains.first(where: { $0.id == id }) else { return nil }
                removeDomain(item)
            }
            return AddDomainFeedback(success: String(localized: "Removed \(entry)."))
        case .rule(let id, let entry, _):
            guard config.rules.contains(where: { $0.id == id }) else { return nil }
            removeRule(id)
            return AddDomainFeedback(success: String(localized: "Removed the rule for \(entry)."))
        case .serviceDomain(let serviceId, _, let entry):
            guard let service = config.services.first(where: { $0.id == serviceId }) else { return nil }
            if service.isCustom {
                if let clash = updateCustomService(id: service.id, name: service.name,
                                                   domains: service.domains.filter { $0 != entry }, ipRanges: service.ipRanges) {
                    return AddDomainFeedback(refusal: clash.message, typed: entry)
                }
            } else if !removeDomainFromBuiltInService(entry, serviceId: service.id) {
                return nil
            }
            return AddDomainFeedback(success: String(localized: "Removed \(entry) from \(service.name)."))
        case .turnOffService(let serviceId, _):
            guard let service = config.services.first(where: { $0.id == serviceId }), service.enabled else { return nil }
            toggleService(serviceId)
            return AddDomainFeedback(success: String(localized: "Turned off \(service.name)."))
        }
    }

    /// The switched-off service, built-in or custom, whose domains hold exactly `name`: the
    /// Bypass mode row offers to turn it on. The first in the Services page order (custom
    /// services, then built-in ones) that can be turned on, falling back to one a custom
    /// service holds off by its name (`ServiceNameClash`), so the click shows why. nil outside
    /// Bypass mode and when the name is already listed (`lookupListing`). Only an exact match
    /// counts: a service routes the addresses of its own domains, never their subdomains.
    func lookupServiceToTurnOn(_ name: String) -> ServiceEntry? {
        guard config.routingMode != .vpnOnly,
              !Self.usesCustomEngine(schemaVersion: config.schemaVersion, routingMode: config.routingMode),
              lookupListing(name) == nil else { return nil }
        let off = config.services.filter { !$0.enabled && $0.domains.contains(name) }
        return off.first(where: \.isCustom)
            ?? off.first { customServiceHolding(nameOf: $0) == nil }
            ?? off.first
    }

    /// Turns on the service `serviceId` for the looked-up `name`, through `toggleService`.
    /// A built-in service a custom one holds off (see `ServiceNameClash`) stays off and the
    /// line says why. nil when the service is gone or already on.
    func turnOnLookupService(_ serviceId: String, for name: String) -> AddDomainFeedback? {
        guard let service = config.services.first(where: { $0.id == serviceId }), !service.enabled else { return nil }
        if let custom = customServiceHolding(nameOf: service) {
            return AddDomainFeedback(refusal: ServiceNameClash.builtInOffMessage(custom: custom.name), typed: name)
        }
        toggleService(service.id)
        return AddDomainFeedback(success: String(localized: "Turned on \(service.name)."))
    }

    /// The services a looked-up name can join in Bypass mode, built-in and custom, switched on
    /// or off. Those that already hold a name under the same registrable domain
    /// (`LookupAddLevels.registrableDomain`, so any *.datadoghq.com for
    /// http-intake.logs.datadoghq.com) come first, then the rest, each alphabetical. A service
    /// that already holds `name` is left out. A name added to a built-in service is kept in
    /// `builtInServiceExtras`, so the launch that resets its shipped domains keeps it.
    ///
    /// A built-in service the catalogue no longer ships is left out: a saved config can still
    /// hold one, but `addDomainToBuiltInService` refuses it, so picking it added nothing.
    func lookupServices(for name: String) -> [ServiceEntry] {
        let parent = LookupAddLevels.registrableDomain(name)
        let shipped = Set(Config.defaultServices.map(\.id))
        let services = config.services
            .filter { ($0.isCustom || shipped.contains($0.id)) && !$0.domains.contains(name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard let parent else { return services }
        let related = services.filter { $0.domains.contains { LookupAddLevels.registrableDomain($0) == parent } }
        return related + services.filter { service in !related.contains { $0.id == service.id } }
    }

    /// Adds `name` to the service `serviceId`, keeping its name, switch and addresses: a custom
    /// service through `updateCustomService`, a built-in one through `addDomainToBuiltInService`.
    /// The line to show, or nil when the service is gone.
    func addLookup(_ name: String, toService serviceId: String) -> AddDomainFeedback? {
        guard let service = config.services.first(where: { $0.id == serviceId }) else { return nil }
        if service.domains.contains(name) {
            return AddDomainFeedback(refusal: String(localized: "\(name) is already in \(service.name)."), typed: name)
        }
        if service.isCustom {
            if let clash = updateCustomService(id: service.id, name: service.name, domains: service.domains + [name], ipRanges: service.ipRanges) {
                return AddDomainFeedback(refusal: clash.message, typed: name)
            }
        } else if !addDomainToBuiltInService(name, serviceId: service.id) {
            return nil
        }
        // A catalogue service that is off is not on the Services page: it is added from the
        // catalogue, which puts it there.
        let message = service.enabled
            ? String(localized: "Added \(name) to \(service.name).")
            : service.isCustom
            ? String(localized: "Added \(name) to \(service.name). The service is off; turn it on from the Services page to bypass it.")
            : String(localized: "Added \(name) to \(service.name). The service is off; add it from Browse catalogue on the Services page to bypass it.")
        return AddDomainFeedback(success: message)
    }

    /// Makes a custom service named `serviceName` whose first domain is `name`.
    func addLookup(_ name: String, toNewService serviceName: String) -> AddDomainFeedback {
        let serviceName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clash = addCustomService(name: serviceName, domains: [name], ipRanges: []) {
            return AddDomainFeedback(refusal: clash.message, typed: name)
        }
        return AddDomainFeedback(success: String(localized: "Made the service \(serviceName) with \(name)."))
    }

    /// Adds what the Lookups add panel chose (`entry`, the looked-up name or a wildcard over
    /// it) where it chose. The line to show, or nil for a Custom mode rule that saved (it says
    /// nothing back, as the row's own button does) or a service that is gone. New Service
    /// opens a sheet instead, so it never reaches here.
    func addLookup(_ entry: String, to target: LookupAddTarget) -> AddDomainFeedback? {
        switch target {
        case .modeList, .directRule:
            return addForCurrentMode(entry).map { AddDomainFeedback($0, typed: entry) }
        case .service(let id):
            return addLookup(entry, toService: id)
        case .newService:
            return nil
        }
    }

    /// Adds what Learn a site chose (`SiteLearning.plan`), one entry at a time through the
    /// mode's own add, as the row's button does. Each add routes its entry while it holds the
    /// route lock, and an add made while the lock is held is saved without its routes, so each
    /// one waits for the one before (up to 30 s). Stops when the mode changes meanwhile: a
    /// choice made for one mode is never added in another. The line to show.
    func addLearned(_ entries: [String]) async -> AddDomainFeedback? {
        guard !entries.isEmpty else { return nil }
        let mode = LookupMode(self)
        var added = 0
        var firstRefusal: AddDomainFeedback?
        for entry in entries {
            var polls = 0
            while isApplyingRoutes && polls < LookupRow.applyWaitPolls {
                try? await Task.sleep(nanoseconds: 100_000_000)
                polls += 1
            }
            guard LookupMode(self) == mode else { break }
            switch addForCurrentMode(entry) {
            case .success?:
                added += 1
            case .failure(let error)?:
                if firstRefusal == nil { firstRefusal = AddDomainFeedback(.failure(error), typed: entry) }
            case nil:
                // Custom mode with no Direct route: every other entry would fail the same way.
                return AddDomainFeedback(refusal: String(localized: "There is no Direct route to send these names to."), typed: entry)
            }
        }
        if added == 0 { return firstRefusal }
        if added < entries.count {
            return AddDomainFeedback(success: String(localized: "Added \(added) of \(entries.count). The others were not added; Logs says why."))
        }
        return AddDomainFeedback(success: String(localized: "Added \(added) of \(entries.count)."))
    }

    /// Saves and re-applies after a rule change (RulesTab's `persistAndReapply`).
    func saveRulesAndReapply() {
        saveConfig()
        Task { await reconcileAfterConfigChange(reconcileListeners: false, reapplyRoutes: true) }
    }
}

/// Where a looked-up name already is, for the Lookups page's last column.
enum LookupListing: Equatable {
    case bypassList
    /// An enabled service lists it; the service's name.
    case service(String)
    case vpnOnlyList
    /// On the current mode's list, switched off.
    case listedOff
    /// A Custom mode domain rule, and the name of the route it sends the name to.
    case rule(routeName: String)
}

/// What the Lookups page's remove action does for a listed name. `entry` is what comes out:
/// the name itself, or a wildcard over it, which takes every name under it along.
enum LookupRemoval: Equatable {
    /// An entry on the Bypass or VPN Only list.
    case listEntry(id: UUID, list: DomainList, entry: String)
    /// A domain the user put in a service: a custom service's, or one added to a built-in one.
    case serviceDomain(serviceId: String, service: String, entry: String)
    /// A built-in service that ships with the name, which cannot come out of it.
    case turnOffService(serviceId: String, service: String)
    /// A Custom mode rule in force, and the route it sends the name to.
    case rule(id: UUID, entry: String, routeName: String)

    /// The button: what it does, naming the wildcard or the service when that is what goes.
    func title(for name: String, in bundle: Bundle = .main) -> String {
        switch self {
        case .listEntry(_, _, let entry), .rule(_, let entry, _):
            return entry == name ? String(localized: "Remove", bundle: bundle)
                                 : String(localized: "Remove \(entry)", bundle: bundle)
        case .serviceDomain(_, let service, let entry):
            return entry == name ? String(localized: "Remove from \(service)", bundle: bundle)
                                 : String(localized: "Remove \(entry) from \(service)", bundle: bundle)
        case .turnOffService(_, let service):
            return String(localized: "Turn off \(service)", bundle: bundle)
        }
    }

    /// The tooltip: where it comes out of, and what else goes with it.
    func help(for name: String, in bundle: Bundle = .main) -> String {
        switch self {
        case .listEntry(_, let list, let entry):
            switch (list, entry == name) {
            case (.bypass, true): return String(localized: "Take it off the Bypass list", bundle: bundle)
            case (.vpnOnly, true): return String(localized: "Take it off the VPN Only list", bundle: bundle)
            case (.bypass, false):
                return String(localized: "Take \(entry) off the Bypass list. Names under it stop bypassing the VPN unless another entry lists them.", bundle: bundle)
            case (.vpnOnly, false):
                return String(localized: "Take \(entry) off the VPN Only list. Names under it stop going through the VPN unless another entry lists them.", bundle: bundle)
            }
        case .serviceDomain(_, let service, let entry):
            return String(localized: "Take \(entry) out of the service \(service)", bundle: bundle)
        case .turnOffService(_, let service):
            return String(localized: "\(service) comes with this name and cannot lose it. Turning \(service) off stops bypassing all of its names.", bundle: bundle)
        case .rule(_, let entry, let routeName):
            return String(localized: "Delete the rule for \(entry) on the Rules page, which sends it to \(routeName)", bundle: bundle)
        }
    }
}

// MARK: - Proxy rule reach

/// What a rule does when its route is served by a local listener (HTTP CONNECT,
/// SOCKS5, Tailscale peer). Those routes emit no kernel route, so the rule only
/// reaches apps set to use the route's 127.0.0.1 address. The rule still claims its
/// hosts first-match (RouteCompiler), so a Direct or VPN rule below it for the same
/// hosts adds no kernel route either. Direct and VPN rules change the routing table
/// and reach every app, so they get no note.
struct ProxyReachNote: Equatable {
    let routeName: String
    /// The route is switched off: no listener runs and the compiler skips the rule.
    var routeOff = false

    /// nil for a Direct or VPN route, and for a rule whose route was deleted.
    static func forRoute(_ route: Route?) -> ProxyReachNote? {
        guard let route, ProxyListenerManager.usesLocalListener(route.egress) else { return nil }
        return ProxyReachNote(routeName: route.name, routeOff: !route.enabled)
    }

    /// The rule row's detail line. One catalog sentence per case, with the route name as an
    /// argument, so a translation can put the name where its grammar wants it. The address to
    /// point an app at is on the Routes page, which copies it.
    func line(in bundle: Bundle = .main) -> String {
        routeOff
            ? String(localized: "\(routeName) is off, so this rule does nothing.", bundle: bundle)
            : String(localized: "Only apps set to use \(routeName). Other apps take the Mac's normal route, even if a rule below matches.", bundle: bundle)
    }
}

// MARK: - Sheet state wrappers

private enum RuleSheetState: Identifiable {
    case add
    case edit(Rule)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let r): return "edit-\(r.id.uuidString)"
        }
    }

    var rule: Rule? {
        if case .edit(let r) = self { return r }
        return nil
    }
}

// MARK: - RulesTab

/// The Rules page on the shared components (section 3.3 of docs/design/APP-REWORK-PROPOSALS.md):
/// one line on how the order works with the + beside it, then one list whose last row is
/// "Everything else". The window's title bar names the page, so the page has no heading.
struct RulesTab: View {
    @EnvironmentObject var routeManager: RouteManager
    @EnvironmentObject var settingsUndo: SettingsUndo
    @State private var sheetState: RuleSheetState?
    @State private var showingNewRouteSheet = false
    @State private var pendingNewRouteCompletion: ((Route) -> Void)?

    /// The doc screenshots draw this pattern's row as if the pointer were on it.
    static var hoveredForScreenshots: String?

    private var sortedRules: [Rule] {
        routeManager.config.rules.sorted { $0.order < $1.order }
    }
    /// The title bar search (⌘F), which the window owns.
    @Environment(\.settingsSearch) private var searchText
    /// False on the read-only page the shell shows in another mode.
    @Environment(\.isEnabled) private var isEnabled
    /// The rules the search leaves, in order; every rule with no search. Dragging still moves by
    /// id, so a filtered list reorders the full one.
    private var shownRules: [Rule] {
        let services = routeManager.config.services
        return sortedRules.filter { SettingsSidebar.matches(RuleRow.patternDisplay($0, services: services), search: searchText) }
    }

    /// The page's one line: how the order works, and how to change it once there are two rules.
    static func purpose(ruleCount: Int, in bundle: Bundle = .main) -> String {
        ruleCount >= 2
            ? String(localized: "The first rule that matches wins. Drag to reorder.", bundle: bundle)
            : String(localized: "The first rule that matches wins.", bundle: bundle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(Self.purpose(ruleCount: sortedRules.count))
                    .font(Theme.Font.detail)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s)
                PageAddButton(name: String(localized: "Add Rule")) { sheetState = .add }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                GroupSection {
                    if sortedRules.isEmpty {
                        EmptyState(systemImage: "list.bullet",
                                   title: String(localized: "No rules yet"),
                                   message: String(localized: "Add a rule to send a domain, service, or IP range through a specific route."),
                                   primary: .init(title: String(localized: "Add Rule")) { sheetState = .add })
                    } else {
                        ruleRows
                    }
                    InsetDivider()
                    everythingElseRow
                }

                if let change = settingsUndo.last, change.page == .rules {
                    UndoLine(message: change.message, isDisabled: routeManager.isApplyingRoutes) { settingsUndo.undoLast() }
                }
            }
        }
        .sheet(item: $sheetState) { state in
            RuleEditorSheet(editingRule: state.rule, services: routeManager.config.services) { rule in
                saveRule(rule)
                sheetState = nil
            } onCancel: {
                sheetState = nil
            }
        }
        .sheet(isPresented: $showingNewRouteSheet) {
            RouteEditorSheet(editingRoute: nil) { newRoute in
                routeManager.addRoute(newRoute)
                pendingNewRouteCompletion?(newRoute)
                pendingNewRouteCompletion = nil
                showingNewRouteSheet = false
            } onCancel: {
                pendingNewRouteCompletion = nil
                showingNewRouteSheet = false
            }
        }
    }

    // MARK: - Rule list

    @ViewBuilder
    private var ruleRows: some View {
        if shownRules.isEmpty {
            SettingsSearchMiss(search: searchText)
        }
        let services = routeManager.config.services
        ForEach(Array(shownRules.enumerated()), id: \.element.id) { idx, rule in
            if idx > 0 { InsetDivider() }
            RuleRow(
                rule: rule,
                onEdit: { sheetState = .edit(rule) },
                onDelete: { deleteRule(rule) },
                onToggle: { enabled in toggleRule(rule.id, enabled: enabled) },
                onReassign: { newRouteId in reassignRule(rule.id, to: newRouteId) },
                onNewRoute: {
                    pendingNewRouteCompletion = { newRoute in reassignRule(rule.id, to: newRoute.id) }
                    showingNewRouteSheet = true
                },
                showsActions: Self.hoveredForScreenshots == RuleRow.patternDisplay(rule, services: services)
            )
            .draggable(rule.id.uuidString)
            .dropDestination(for: String.self) { items, _ in
                // A read-only page (another mode) takes no drop: `.disabled` does not stop one.
                guard isEnabled else { return false }
                guard let draggedIdString = items.first, let draggedId = UUID(uuidString: draggedIdString) else { return false }
                moveRule(draggedId: draggedId, to: rule.id)
                return true
            }
        }
    }

    /// The pinned last row: where traffic no rule matches goes. No switch, no actions.
    private var everythingElseRow: some View {
        HStack(spacing: Theme.Space.s) {
            Color.clear
                .frame(width: ListRow.glyphColumn, height: 1)
                .accessibilityHidden(true)
            Text("Everything else")
                .font(Theme.Font.body)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            RulesRouteChipMenu(
                selectedRouteId: routeManager.config.defaultRouteId,
                rowName: String(localized: "Everything else"),
                onSelect: { newId in setDefaultRoute(newId) },
                onNewRoute: {
                    pendingNewRouteCompletion = { newRoute in setDefaultRoute(newRoute.id) }
                    showingNewRouteSheet = true
                }
            )
            // In the chip column of the rows above: past it come their small switch (44 pt,
            // as measured for the Domains page) and the row's spacing.
            .padding(.trailing, 44 + Theme.Space.s)
        }
        .padding(.horizontal, ListRow.inset)
        .frame(minHeight: ListRow.singleLineHeight)
        .help(String(localized: "Destinations that don't match any rule above use this route."))
    }

    // MARK: - Mutations

    private func saveRule(_ rule: Rule) {
        if let idx = routeManager.config.rules.firstIndex(where: { $0.id == rule.id }) {
            routeManager.config.rules[idx] = rule
        } else {
            let maxOrder = routeManager.config.rules.map(\.order).max() ?? -1
            var newRule = rule
            newRule.order = maxOrder + 1
            routeManager.config.rules.append(newRule)
        }
        persistAndReapply()
    }

    private func deleteRule(_ rule: Rule) {
        routeManager.removeRule(rule.id)
        settingsUndo.record(.rule(rule, label: RuleRow.patternDisplay(rule, services: routeManager.config.services)))
    }

    private func toggleRule(_ id: UUID, enabled: Bool) {
        guard let idx = routeManager.config.rules.firstIndex(where: { $0.id == id }) else { return }
        routeManager.config.rules[idx].enabled = enabled
        persistAndReapply()
    }

    private func reassignRule(_ id: UUID, to routeId: UUID) {
        guard let idx = routeManager.config.rules.firstIndex(where: { $0.id == id }) else { return }
        routeManager.config.rules[idx].routeId = routeId
        persistAndReapply()
    }

    private func setDefaultRoute(_ routeId: UUID) {
        routeManager.config.defaultRouteId = routeId
        persistAndReapply()
    }

    /// Reorders `sortedRules` (dragged rule moves to the target's position) and
    /// renumbers every rule's `order` to its new index, so future appends
    /// (`(max order)+1`) stay consistent.
    private func moveRule(draggedId: UUID, to targetId: UUID) {
        guard draggedId != targetId else { return }
        var ordered = sortedRules
        guard let fromIndex = ordered.firstIndex(where: { $0.id == draggedId }),
              let toIndex = ordered.firstIndex(where: { $0.id == targetId }) else { return }
        let moved = ordered.remove(at: fromIndex)
        ordered.insert(moved, at: toIndex)
        for (newOrder, rule) in ordered.enumerated() {
            if let idx = routeManager.config.rules.firstIndex(where: { $0.id == rule.id }) {
                routeManager.config.rules[idx].order = newOrder
            }
        }
        persistAndReapply()
    }

    private func persistAndReapply() {
        routeManager.saveRulesAndReapply()
    }
}

// MARK: - RuleRow

/// One rule as a `ListRow`: a glyph for what it matches, the pattern, the proxy note as its
/// detail line, edit and delete under the pointer, the route chip, and the switch last.
struct RuleRow: View {
    @EnvironmentObject var routeManager: RouteManager
    let rule: Rule
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let onReassign: (UUID) -> Void
    let onNewRoute: () -> Void
    /// Draws the actions as if the pointer were over the row, for the doc screenshots.
    var showsActions = false

    /// The leading glyph says what the rule matches, in place of the old uppercase badge.
    static func glyph(for type: MatchType) -> String {
        switch type {
        case .domain, .suffix: return "globe"
        case .service: return "square.grid.2x2"
        case .ip, .cidr: return "network"
        case .process: return "app"
        }
    }

    private var patternDisplay: String {
        Self.patternDisplay(rule, services: routeManager.config.services)
    }

    /// The rule's pattern as its row shows it: a service rule shows the service's name, and a
    /// suffix rule its wildcard (`*.example.com`), as the Domains page writes one.
    static func patternDisplay(_ rule: Rule, services: [ServiceEntry]) -> String {
        switch rule.matchType {
        case .service:
            return services.first(where: { $0.id == rule.pattern })?.name ?? rule.pattern
        case .suffix:
            return WildcardDomain.isWildcard(rule.pattern) ? rule.pattern : WildcardDomain.entry(for: rule.pattern)
        case .domain, .ip, .cidr, .process:
            return rule.pattern
        }
    }

    /// The route this rule is assigned to, resolved live so a rename/edit in the
    /// Routes tab is reflected immediately. nil if routeId is dangling (its route
    /// was deleted out from under the rule).
    private var assignedRoute: Route? {
        routeManager.config.routes.first { $0.id == rule.routeId }
    }

    private var actions: [RowAction] {
        [.edit(patternDisplay, perform: onEdit), .delete(patternDisplay, perform: onDelete)]
    }

    var body: some View {
        ListRow(
            glyph: Self.glyph(for: rule.matchType),
            name: patternDisplay,
            detail: ProxyReachNote.forRoute(assignedRoute)?.line(),
            actions: actions,
            isOn: Binding(get: { rule.enabled }, set: onToggle),
            showsActions: showsActions,
            accessory: AnyView(
                RulesRouteChipMenu(selectedRouteId: rule.routeId, rowName: patternDisplay,
                                   onSelect: onReassign, onNewRoute: onNewRoute)
            ),
            detailLineLimit: nil
        )
        // The buttons show only under the pointer, and a hidden button is hidden from
        // VoiceOver too, so the row itself carries them.
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.name, action: action.perform)
            }
        }
    }
}

// MARK: - Route chip + grouped picker (System / Your Routes / New Route…)

/// The route a rule (or Everything else) goes to, as the shared `RouteChipMenu`: a grey glyph
/// and the route's name with one chevron, opening System, Your Routes and New Route….
struct RulesRouteChipMenu: View {
    @EnvironmentObject var routeManager: RouteManager
    let selectedRouteId: UUID?
    /// The row the chip belongs to, so VoiceOver tells one rule's route from another's.
    var rowName: String?
    let onSelect: (UUID) -> Void
    let onNewRoute: () -> Void

    /// The chip for `route`: its glyph and name, or "Choose Route" when the rule has none.
    static func chip(for route: Route?, vpnName: String?, in bundle: Bundle = .main) -> RouteChip {
        guard let route else {
            return RouteChip(systemImage: "questionmark", name: String(localized: "Choose Route", bundle: bundle))
        }
        return RouteChip(systemImage: RouteChip.systemImage(for: route.egress),
                         name: route.friendlyName(vpnName: vpnName, in: bundle))
    }

    /// What VoiceOver says for the chip of a row: "Route for en.wikipedia.org: office-proxy".
    static func spokenName(row: String, route: String, in bundle: Bundle = .main) -> String {
        String(localized: "Route for \(row): \(route)", bundle: bundle)
    }

    /// Direct first, then the PRIMARY VPN — the two auto-created system routes. A
    /// VPN route pinned to a specific tunnel is user-created, so it lives in Your Routes.
    private var systemRoutes: [Route] {
        routeManager.config.routes
            .filter { $0.egress == .direct || ($0.egress == .vpnDefault && $0.vpnSelector?.kind != .interface) }
            .sorted { ($0.egress == .direct ? 0 : 1) < ($1.egress == .direct ? 0 : 1) }
    }

    private var userRoutes: [Route] {
        routeManager.config.routes.filter {
            ProxyListenerManager.usesLocalListener($0.egress)
                || ($0.egress == .vpnDefault && $0.vpnSelector?.kind == .interface)
        }
    }

    private var selectedRoute: Route? {
        guard let selectedRouteId else { return nil }
        return routeManager.config.routes.first(where: { $0.id == selectedRouteId })
    }

    var body: some View {
        let chip = Self.chip(for: selectedRoute, vpnName: routeManager.vpnType?.knownName)
        RouteChipMenu(chip, spokenName: rowName.map { Self.spokenName(row: $0, route: chip.name) }) {
            Section("System") {
                ForEach(systemRoutes) { route in
                    routeButton(route)
                }
            }
            if !userRoutes.isEmpty {
                Section("Your Routes") {
                    ForEach(userRoutes) { route in
                        routeButton(route)
                    }
                }
            }
            Divider()
            Button {
                onNewRoute()
            } label: {
                Label("New Route…", systemImage: "plus")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func routeButton(_ route: Route) -> some View {
        Button {
            onSelect(route.id)
        } label: {
            if selectedRouteId == route.id {
                Label(route.friendlyName(vpnName: routeManager.vpnType?.knownName), systemImage: "checkmark")
            } else {
                Text(route.friendlyName(vpnName: routeManager.vpnType?.knownName))
            }
        }
    }
}

// MARK: - Rule editor sheet

struct RuleEditorSheet: View {
    @EnvironmentObject var routeManager: RouteManager
    let editingRule: Rule?
    let services: [RouteManager.ServiceEntry]
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    @State private var matchType: MatchType
    @State private var pattern: String
    @State private var selectedServiceId: String
    @State private var routeId: UUID?
    @State private var validationError: String?
    @State private var showingNewRouteSheet = false

    init(
        editingRule: Rule?,
        services: [RouteManager.ServiceEntry],
        onSave: @escaping (Rule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.editingRule = editingRule
        self.services = services
        self.onSave = onSave
        self.onCancel = onCancel
        _matchType = State(initialValue: editingRule?.matchType ?? .domain)
        _pattern = State(initialValue: editingRule?.matchType == .service ? "" : (editingRule?.pattern ?? ""))
        _selectedServiceId = State(initialValue: editingRule?.matchType == .service ? (editingRule?.pattern ?? "") : (services.first?.id ?? ""))
        _routeId = State(initialValue: editingRule?.routeId)
    }

    private var isEditing: Bool { editingRule != nil }

    private var patternPlaceholder: String {
        switch matchType {
        case .domain:  return "example.com"
        case .suffix:  return "*.example.com"
        case .ip:      return "10.0.0.5"
        case .cidr:    return "10.0.0.0/8"
        case .service, .process: return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet header
            HStack {
                Text(isEditing ? "Edit Rule" : "Add Rule")
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

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formField(label: "Match", required: true) {
                        Picker(String(localized: "Match"), selection: $matchType) {
                            Text("Domain").tag(MatchType.domain)
                            Text("Service").tag(MatchType.service)
                            Text("IP").tag(MatchType.ip)
                            Text("CIDR").tag(MatchType.cidr)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if matchType == .service {
                        formField(label: "Service", required: true) {
                            if services.isEmpty {
                                Text("No services configured. Add one in the Services tab first.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                            } else {
                                Picker(String(localized: "Service"), selection: $selectedServiceId) {
                                    ForEach(services) { service in
                                        Text(service.name).tag(service.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                        }
                    } else {
                        formField(label: "Pattern", required: true) {
                            TextField(patternPlaceholder, text: $pattern)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.bgInput)
                                .cornerRadius(8)
                        }
                    }

                    formField(label: "Route", required: true) {
                        RulesRouteChipMenu(
                            selectedRouteId: routeId,
                            onSelect: { routeId = $0 },
                            onNewRoute: { showingNewRouteSheet = true }
                        )
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

                Button(isEditing ? "Save Changes" : "Add Rule") {
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
        .sheet(isPresented: $showingNewRouteSheet) {
            RouteEditorSheet(editingRoute: nil) { newRoute in
                routeManager.addRoute(newRoute)
                routeId = newRoute.id
                showingNewRouteSheet = false
            } onCancel: {
                showingNewRouteSheet = false
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
        let effectivePattern = matchType == .service ? selectedServiceId : pattern.trimmingCharacters(in: .whitespaces)
        guard !effectivePattern.isEmpty else {
            validationError = matchType == .service ? String(localized: "Select a service.") : String(localized: "Pattern is required.")
            return
        }
        // Same validators RouteManager already uses for inverse-domain/CIDR entry
        // (see addInverseDomain) — reused here rather than duplicated, so a malformed
        // IP/CIDR can't be saved as an inert rule.
        guard matchType != .ip || routeManager.isValidIP(effectivePattern) else {
            validationError = String(localized: "Enter a valid IPv4 address (e.g. 10.0.0.5).")
            return
        }
        guard matchType != .cidr || routeManager.isValidCIDR(effectivePattern) else {
            validationError = String(localized: "Enter a valid IPv4 CIDR range (e.g. 10.0.0.0/8).")
            return
        }
        guard let routeId else {
            validationError = String(localized: "Select a route.")
            return
        }
        let rule = Rule(
            id: editingRule?.id ?? UUID(),
            matchType: matchType,
            pattern: effectivePattern,
            routeId: routeId,
            enabled: editingRule?.enabled ?? true,
            order: editingRule?.order ?? 0 // new rules: RulesTab.saveRule overwrites this to (max order)+1
        )
        onSave(rule)
    }
}
