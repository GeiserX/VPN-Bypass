// ServiceNameClash.swift
// Why a custom service name is refused. The app tracks every route by a source string: a
// service's name, or the domain itself for a Bypass list entry. A custom service named like
// another service or a listed domain shares that source with it, so the dropdown groups both
// sets of routes under one row and removing one can remove the other's routes. The Settings
// editor, config import and Undo refuse such a name, and the Bypass list refuses a domain a
// service has as its name; a config.json that already holds one still loads as before.
//
// An app update can still bring a built-in service whose name a user's custom service already
// has. The custom one keeps its name and its routes; the built-in one stays off until the
// custom one is renamed (see `customServiceHolding`), and the custom one's row shows the line
// asking for a new name.

import Foundation

enum ServiceNameClash: Error, Equatable {
    /// Another service, built-in or custom, already has this name.
    case service(name: String)
    /// The name is an entry on the Bypass list.
    case domain(String)

    /// The service or Bypass list entry that already uses `name`, ignoring case and the
    /// spaces around it, or nil when the name is free. `excluding` is the id of the service
    /// being edited, so keeping its own name is not a clash.
    static func find(_ name: String, excluding id: String?,
                     services: [ServiceEntry], domains: [DomainEntry]) -> ServiceNameClash? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        if let other = services.first(where: { $0.id != id && normalized($0.name) == key }) {
            return .service(name: other.name)
        }
        if let entry = domains.first(where: { normalized($0.domain) == key }) {
            return .domain(entry.domain)
        }
        return nil
    }

    /// The first custom service in an imported config whose name clashes, checked against the
    /// services the config will hold once the built-in ones are merged in: every built-in
    /// under its current name, plus the file's own services the merge keeps.
    static func firstInImport(_ config: Config) -> (service: String, clash: ServiceNameClash)? {
        let builtIns = Config.defaultServices
        let builtInIds = Set(builtIns.map(\.id))
        let merged = builtIns + config.services.filter { !builtInIds.contains($0.id) }
        for service in merged where service.isCustom {
            if let clash = find(service.name, excluding: service.id, services: merged, domains: config.domains) {
                return (service.name, clash)
            }
        }
        return nil
    }

    /// The service whose name is `name`, ignoring case and the spaces around it, or nil. The
    /// Bypass list asks before it takes a domain, because the entry's routes would be tracked
    /// under the same source as that service's.
    static func service(named name: String, in services: [ServiceEntry]) -> ServiceEntry? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        return services.first { normalized($0.name) == key }
    }

    /// The custom service that has the name of the built-in service `builtIn`, ignoring case
    /// and the spaces around it, or nil. While there is one the built-in service stays off, so
    /// the two never route under one name; nil for a custom service.
    static func customServiceHolding(nameOf builtIn: ServiceEntry, in services: [ServiceEntry]) -> ServiceEntry? {
        guard !builtIn.isCustom else { return nil }
        let key = normalized(builtIn.name)
        guard !key.isEmpty else { return nil }
        return services.first { $0.isCustom && $0.id != builtIn.id && normalized($0.name) == key }
    }

    /// Why a built-in service stays off: the custom service `custom` has its name.
    static func builtInOffMessage(custom: String) -> String { builtInOffMessage(custom: custom, in: .main) }

    static func builtInOffMessage(custom: String, in bundle: Bundle) -> String {
        String(localized: "Your custom service \u{201C}\(custom)\u{201D} has this name. Rename it to turn this service on.", bundle: bundle)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One line for under the Service Name field, in the app's language.
    var message: String { message(in: .main) }

    func message(in bundle: Bundle) -> String {
        switch self {
        case .service(let name):
            return String(localized: "A service named \u{201C}\(name)\u{201D} already exists. Choose another name, so their routes stay apart.", bundle: bundle)
        case .domain(let domain):
            return String(localized: "\(domain) is on your Bypass list. Choose another name, so their routes stay apart.", bundle: bundle)
        }
    }

    /// Why an import saved nothing, naming the custom service `service` in the file.
    func importMessage(service: String) -> String { importMessage(service: service, in: .main) }

    func importMessage(service: String, in bundle: Bundle) -> String {
        switch self {
        case .service(let name):
            return String(localized: "Nothing was imported. The custom service \u{201C}\(service)\u{201D} has the same name as the service \u{201C}\(name)\u{201D}. Rename it in the file and import again.", bundle: bundle)
        case .domain(let domain):
            return String(localized: "Nothing was imported. The custom service \u{201C}\(service)\u{201D} has the same name as \(domain) on the Bypass list. Rename it in the file and import again.", bundle: bundle)
        }
    }
}
