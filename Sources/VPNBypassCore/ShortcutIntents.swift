// ShortcutIntents.swift
// The Shortcuts actions (idea 10 of docs/design/APP-REWORK-PROPOSALS.md): Set Mode, Add Domain,
// Turn Service On or Off and Get Status. Each one only turns its parameters into a
// ShortcutAction and runs it (ShortcutActions.swift), so what it does is what `vpnb` does.
//
// Shortcuts finds these through Contents/Resources/Metadata.appintents, which the Makefile's
// bundle step writes from the compiler's constant values (`appintentsmetadataprocessor`).
// The titles and parameter names are literals on purpose: the processor reads them from the
// source, and Shortcuts looks them up in the app's Localizable.strings.

import AppIntents
import Foundation

// MARK: - Parameter types

/// The routing mode, as Shortcuts offers it.
enum ShortcutMode: String, AppEnum {
    case bypass
    case vpnOnly
    case custom

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Routing mode"
    static var caseDisplayRepresentations: [ShortcutMode: DisplayRepresentation] = [
        .bypass: "Bypass",
        .vpnOnly: "VPN Only",
        .custom: "Custom",
    ]

    var mode: RoutingMode {
        switch self {
        case .bypass: return .bypass
        case .vpnOnly: return .vpnOnly
        case .custom: return .custom
        }
    }
}

/// Which domain list Add Domain writes to.
enum ShortcutDomainList: String, AppEnum {
    case bypass
    case vpnOnly

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Domain list"
    static var caseDisplayRepresentations: [ShortcutDomainList: DisplayRepresentation] = [
        .bypass: "Bypass list",
        .vpnOnly: "VPN Only list",
    ]

    var list: DomainList {
        switch self {
        case .bypass: return .bypass
        case .vpnOnly: return .vpnOnly
        }
    }
}

/// A service on the Services page, built-in or custom, by its id.
struct ShortcutService: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Service"
    static var defaultQuery = ShortcutServiceQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(_ service: ServiceEntry) {
        self.init(id: service.id, name: service.name)
    }
}

/// Suggests the services the Services page lists, by name; a typed name finds any service,
/// a catalogue one that is off too, as `vpnb service enable` takes any id.
struct ShortcutServiceQuery: EntityStringQuery {
    init() {}

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ShortcutService] {
        Self.services(RouteManager.shared.config.services).filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ShortcutService] {
        Self.matching(string, in: RouteManager.shared.config.services)
    }

    @MainActor
    func suggestedEntities() async throws -> [ShortcutService] {
        Self.suggested(RouteManager.shared.config.services)
    }

    /// The services the Services page has a row for: those on, and custom or retired ones that
    /// are off. A catalogue service that is off waits in the catalogue sheet, so it is not
    /// suggested; there are hundreds.
    static func suggested(_ entries: [ServiceEntry]) -> [ShortcutService] {
        services(entries.filter { $0.enabled || ServiceSections.keepsRowWhenOff($0) })
    }

    /// Every service, sorted by name as the Services page sorts them.
    static func services(_ entries: [ServiceEntry]) -> [ShortcutService] {
        entries.map(ShortcutService.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The services whose name holds `string`, ignoring case and accents.
    static func matching(_ string: String, in entries: [ServiceEntry]) -> [ShortcutService] {
        let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return services(entries) }
        return services(entries).filter {
            $0.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

// MARK: - Actions

struct SetModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Routing Mode"
    static var description = IntentDescription("Switches VPN Bypass to Bypass, VPN Only or Custom, as vpnb mode does.")

    @Parameter(title: "Mode")
    var mode: ShortcutMode

    init() {}

    init(mode: ShortcutMode) {
        self.mode = mode
    }

    var action: ShortcutAction { .setMode(mode.mode) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await ShortcutActions.run(action)
        return .result(dialog: "\(ShortcutActions.modeDone(mode.mode))")
    }
}

struct AddDomainIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Domain"
    static var description = IntentDescription("Adds a domain to the Bypass list or the VPN Only list, as vpnb domain add does.")

    @Parameter(title: "Domain")
    var domain: String

    @Parameter(title: "List", default: .bypass)
    var list: ShortcutDomainList

    init() {}

    init(domain: String, list: ShortcutDomainList) {
        self.domain = domain
        self.list = list
    }

    var action: ShortcutAction { .addDomain(domain, list: list.list) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await ShortcutActions.run(action)
        // The answer names the entry as the app saved it, cleaned (a pasted link becomes its host).
        let saved = ShortcutActions.savedDomain(response, typed: domain)
        return .result(dialog: "\(ShortcutActions.domainAdded(saved, list: list.list))")
    }
}

struct SetServiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Service On or Off"
    static var description = IntentDescription("Turns a service on the Services page on or off, as vpnb service enable and disable do.")

    @Parameter(title: "Service")
    var service: ShortcutService

    @Parameter(title: "Turn On", default: true, displayName: Bool.IntentDisplayName(true: "on", false: "off"))
    var on: Bool

    init() {}

    init(service: ShortcutService, on: Bool) {
        self.service = service
        self.on = on
    }

    var action: ShortcutAction { .setService(id: service.id, on: on) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await ShortcutActions.run(action)
        let name = response.result?.services?.first?.name ?? service.name
        return .result(dialog: "\(ShortcutActions.serviceDone(name, on: on))")
    }
}

struct GetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Status"
    static var description = IntentDescription("Tells the routing mode and whether anything is routed now, as vpnb status does.")

    init() {}

    var action: ShortcutAction { .getStatus }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let response = try await ShortcutActions.run(action)
        let mode = response.result?.mode.flatMap(RoutingMode.init(rawValue:)) ?? RouteManager.shared.config.routingMode
        let line = ShortcutActions.statusLine(mode: mode, runtime: response.result?.runtime)
        return .result(value: line, dialog: "\(line)")
    }
}
