// ClassicControl.swift
// The control-socket verbs for the Bypass and VPN Only modes: the two domain lists,
// the services, the kernel routes the app has installed, the refresh actions and the
// log. CommandRouter (pure, config in, config out) covers the Custom-mode routes and
// rules; these verbs need live RouteManager state instead, so they live here and
// ControlSurface dispatches to them before falling through to CommandRouter.
//
// Every mutation calls the SAME RouteManager method the GUI button calls
// (addDomain, toggleService, removeAllRoutes, ...). Nothing here applies routes on its
// own: a full re-apply writes hundreds of kernel routes at once, which is exactly the
// burst that knocked GlobalProtect down before 4.8.5. Some GUI methods return silently
// on bad input, so those verbs validate first and answer with an error code; domain.add
// maps the result addDomain / addInverseDomain return.
//
// Never logs an argument value: only the verb, the same rule as ControlSurface.

import Foundation

// MARK: - Wire DTOs

/// One entry of the Bypass list or the VPN Only list.
public struct ControlDomain: Codable, Equatable, Sendable {
    public var id: UUID
    public var domain: String
    public var enabled: Bool
    /// "bypass" or "vpnOnly".
    public var list: String
    public var isCIDR: Bool
    public var isWildcard: Bool

    init(_ entry: DomainEntry, list: ClassicControl.DomainList) {
        id = entry.id
        domain = entry.domain
        enabled = entry.enabled
        self.list = list.rawValue
        isCIDR = entry.isCIDR
        isWildcard = entry.isWildcard
    }
}

/// A service (built-in or custom). `domains`/`ipRanges` are only filled for
/// `service.list id=<id>`; the list form carries the counts alone.
public struct ControlService: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var isCustom: Bool
    public var domainCount: Int
    public var ipRangeCount: Int
    public var domains: [String]? = nil
    public var ipRanges: [String]? = nil

    init(_ service: ServiceEntry, detail: Bool = false) {
        id = service.id
        name = service.name
        enabled = service.enabled
        isCustom = service.isCustom
        domainCount = service.domains.count
        ipRangeCount = service.ipRanges.count
        if detail {
            domains = service.domains
            ipRanges = service.ipRanges
        }
    }
}

/// A kernel route VPN Bypass has installed (RouteManager.activeRoutes).
public struct ControlActiveRoute: Codable, Equatable, Sendable {
    public var destination: String
    public var gateway: String
    /// The domain or service name the route was installed for.
    public var source: String
}

/// One line of the in-app log, newest first in `logs`.
public struct ControlLogEntry: Codable, Equatable, Sendable {
    /// ISO 8601, UTC.
    public var time: String
    /// "INFO", "SUCCESS", "WARNING" or "ERROR".
    public var level: String
    public var message: String
}

// MARK: - Verbs

@MainActor
enum ClassicControl {

    typealias DomainList = VPNBypassCore.DomainList

    /// Verbs this file answers. Anything else goes on to CommandRouter.
    static let verbs: Set<String> = [
        "domain.list", "domain.add", "domain.rm", "domain.enable", "domain.disable",
        "service.list", "service.enable", "service.disable",
        "routes.active", "routes.clear", "refresh", "dns.refresh", "logs",
    ]

    /// How long a domain/service mutation waits for a running route operation to finish.
    /// The GUI disables these controls while one runs, because the RouteManager method
    /// would then only save the config and leave the kernel for the next apply. Past the
    /// wait the method runs anyway, with that same config-only outcome.
    static var busyWait: TimeInterval = 30

    /// Whether a route operation holds the gate. A seam so a test can hold it; the app
    /// never changes it.
    static var routeOperationRunning: @MainActor () -> Bool = { RouteManager.shared.isApplyingRoutes }

    /// Answers a request for one of `verbs`, or returns nil so the caller falls through
    /// to CommandRouter. The caller has already checked the envelope version.
    static func handle(_ request: ControlRequest) async -> ControlResponse? {
        guard verbs.contains(request.cmd) else { return nil }
        let args = request.args ?? [:]
        let response: ControlResponse
        switch request.cmd {
        case "domain.list": response = domainList(args)
        case "domain.add": response = await domainAdd(args)
        case "domain.rm": response = await domainRemove(args)
        case "domain.enable": response = await domainSetEnabled(args, enabled: true)
        case "domain.disable": response = await domainSetEnabled(args, enabled: false)
        case "service.list": response = serviceList(args)
        case "service.enable": response = await serviceSetEnabled(args, enabled: true)
        case "service.disable": response = await serviceSetEnabled(args, enabled: false)
        case "routes.active": response = activeRoutes(args)
        case "routes.clear": response = await clearRoutes()
        case "refresh": response = refresh()
        case "dns.refresh": response = dnsRefresh()
        case "logs": response = logs(args)
        default: return nil
        }
        if response.ok, CommandRouter.isMutating(request.cmd) {
            RouteManager.shared.log(.info, "Control: '\(request.cmd)' applied via the command line")
        }
        return response
    }

    // MARK: - domain.*

    private static func domainList(_ args: [String: String]) -> ControlResponse {
        let rm = RouteManager.shared
        let lists: [DomainList]
        switch parseList(args) {
        case .failure(let e): return e.response
        case .success(let list): lists = list.map { [$0] } ?? [.bypass, .vpnOnly]
        }
        let domains = lists.flatMap { list in entries(list, rm).map { ControlDomain($0, list: list) } }
        return ok(ControlResult(domains: domains))
    }

    private static func domainAdd(_ args: [String: String]) async -> ControlResponse {
        let rm = RouteManager.shared
        let list: DomainList
        switch parseList(args) {
        case .failure(let e): return e.response
        case .success(let l): list = l ?? .bypass
        }
        guard let raw = args["domain"] else {
            return fail("invalid_args", "domain is required")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // The same check addDomain / addInverseDomain run, done before the wait so a bad
        // value is answered at once.
        if case .failure(let error) = rm.checkDomainInput(trimmed, list: list) {
            return fail(error)
        }

        // Only what depends on the lists waits for a running route operation.
        await waitForRouteIdle()
        let outcome: Result<AddedDomain, AddDomainError>
        switch list {
        case .bypass: outcome = rm.addDomain(trimmed)
        case .vpnOnly: outcome = rm.addInverseDomain(trimmed)
        }
        switch outcome {
        case .failure(let error): return fail(error)
        case .success(let added): return ok(ControlResult(domains: [ControlDomain(added.entry, list: list)]))
        }
    }

    /// The socket's code and message for a refused add. The GUI shows `error.message`
    /// instead; the decision behind both is the same.
    private static func fail(_ error: AddDomainError) -> ControlResponse {
        switch error {
        case .empty:
            return fail("invalid_args", "domain is empty after cleaning")
        case .rangeOnBypassList:
            return fail("invalid_args", "the bypass list takes a domain name, not a CIDR (to send a range around the VPN, use rule.add match=cidr with the Direct route, in custom mode)")
        case .malformedRange:
            return fail("invalid_args", "malformed CIDR (expected a.b.c.d/n with n from 2 to 32)")
        case .catchAllRange:
            return fail("invalid_args", "CIDR /0 and /1 cannot be installed as routes")
        case .alreadyListed(let value, let list):
            return fail("already_exists", "\(value) is already on the \(list.rawValue) list")
        }
    }

    private static func domainRemove(_ args: [String: String]) async -> ControlResponse {
        let rm = RouteManager.shared
        let target: DomainTarget
        switch parseTarget(args, rm) {
        case .failure(let e): return e.response
        case .success(let t): target = t
        }
        await waitForRouteIdle()
        let entry: DomainEntry, list: DomainList
        switch findDomain(target, rm) {
        case .failure(let e): return e.response
        case .success(let found): (entry, list) = found
        }
        let cleanup: Task<Void, Never>?
        switch list {
        case .bypass: cleanup = rm.removeDomain(entry)
        case .vpnOnly: cleanup = rm.removeInverseDomain(entry)
        }
        // When the method removes routes first, the config change lands after them; wait,
        // so a domain.list sent right after this answer no longer shows the entry.
        await cleanup?.value
        return ok(ControlResult(message: "domain removed"))
    }

    private static func domainSetEnabled(_ args: [String: String], enabled: Bool) async -> ControlResponse {
        let rm = RouteManager.shared
        let target: DomainTarget
        switch parseTarget(args, rm) {
        case .failure(let e): return e.response
        case .success(let t): target = t
        }
        await waitForRouteIdle()
        let entry: DomainEntry, list: DomainList
        switch findDomain(target, rm) {
        case .failure(let e): return e.response
        case .success(let found): (entry, list) = found
        }
        if entry.enabled != enabled {
            switch list {
            case .bypass: rm.toggleDomain(entry.id)
            case .vpnOnly: rm.toggleInverseDomain(entry.id)
            }
        }
        let after = entries(list, rm).first(where: { $0.id == entry.id }) ?? entry
        return ok(ControlResult(domains: [ControlDomain(after, list: list)]))
    }

    // MARK: - service.*

    private static func serviceList(_ args: [String: String]) -> ControlResponse {
        let services = RouteManager.shared.config.services
        if let id = args["id"] {
            guard let service = services.first(where: { $0.id == id }) else {
                return fail("not_found", "no service with that id")
            }
            return ok(ControlResult(services: [ControlService(service, detail: true)]))
        }
        return ok(ControlResult(services: services.map { ControlService($0) }))
    }

    private static func serviceSetEnabled(_ args: [String: String], enabled: Bool) async -> ControlResponse {
        let rm = RouteManager.shared
        guard let id = args["id"], !id.isEmpty else {
            return fail("invalid_args", "id is required")
        }
        await waitForRouteIdle()
        guard let service = rm.config.services.first(where: { $0.id == id }) else {
            return fail("not_found", "no service with that id")
        }
        if service.enabled != enabled {
            rm.toggleService(id)
        }
        let after = rm.config.services.first(where: { $0.id == id }) ?? service
        return ok(ControlResult(services: [ControlService(after)]))
    }

    // MARK: - routes / refresh

    private static func activeRoutes(_ args: [String: String]) -> ControlResponse {
        var routes = RouteManager.shared.activeRoutes
        if let source = args["source"] {
            routes = routes.filter { $0.source.caseInsensitiveCompare(source) == .orderedSame }
        }
        let result = routes.map { ControlActiveRoute(destination: $0.destination, gateway: $0.gateway, source: $0.source) }
        return ok(ControlResult(activeRoutes: result))
    }

    /// The menu's Remove All Routes…, without the question. removeAllRoutes also sweeps destinations pushed to the kernel
    /// but not yet recorded, so count those too; what it could not remove it keeps recorded.
    private static func clearRoutes() async -> ControlResponse {
        let rm = RouteManager.shared
        let before = Set(rm.activeRoutes.map(\.destination)).union(rm.pendingKernelAdds).count
        await rm.removeAllRoutes()
        let left = rm.uniqueRouteCount
        let removed = max(0, before - left)
        var message = "removed \(removed) route\(removed == 1 ? "" : "s")"
        if left > 0 {
            message += "; \(left) could not be removed and \(left == 1 ? "is" : "are") still installed"
        }
        return ok(ControlResult(message: message))
    }

    /// The menu's Refresh Routes button, without the user notification.
    private static func refresh() -> ControlResponse {
        let rm = RouteManager.shared
        let helper = HelperManager.shared
        guard helper.isHelperInstalled else {
            return fail("helper_not_ready",
                        "the privileged helper is not ready (\(helper.helperState.statusText)); repair it in Settings > Status")
        }
        Task { await rm.detectAndApplyRoutesAsync(sendNotification: false) }
        return ok(ControlResult(message: "refresh started"))
    }

    /// Settings > Refresh DNS now.
    private static func dnsRefresh() -> ControlResponse {
        RouteManager.shared.forceDNSRefresh()
        return ok(ControlResult(message: "DNS refresh started"))
    }

    // MARK: - logs

    private static func logs(_ args: [String: String]) -> ControlResponse {
        var limit = 50
        if let s = args["limit"] {
            guard let n = Int(s), (1...200).contains(n) else {
                return fail("invalid_args", "limit must be an integer from 1 to 200")
            }
            limit = n
        }
        var level: RouteManager.LogEntry.LogLevel?
        if let s = args["level"] {
            guard let l = RouteManager.LogEntry.LogLevel(rawValue: s.uppercased()) else {
                return fail("invalid_args", "level must be info, success, warning or error")
            }
            level = l
        }
        let formatter = ISO8601DateFormatter()   // UTC, "2026-09-30T10:00:00Z"
        let lines = RouteManager.shared.recentLogs   // already newest first
            .filter { level == nil || $0.level == level }
            .prefix(limit)
            .map { ControlLogEntry(time: formatter.string(from: $0.timestamp), level: $0.level.rawValue, message: $0.message) }
        return ok(ControlResult(logs: Array(lines)))
    }

    // MARK: - Helpers

    private struct VerbError: Error {
        let code: String
        let message: String
        var response: ControlResponse { ControlResponse(ok: false, error: ControlError(code: code, message: message)) }
    }

    private static func ok(_ result: ControlResult) -> ControlResponse {
        ControlResponse(ok: true, result: result)
    }

    private static func fail(_ code: String, _ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: ControlError(code: code, message: message))
    }

    private static func entries(_ list: DomainList, _ rm: RouteManager) -> [DomainEntry] {
        switch list {
        case .bypass: return rm.config.domains
        case .vpnOnly: return rm.config.inverseDomains
        }
    }

    /// `list` absent is `.success(nil)`; an unknown value is invalid_args.
    private static func parseList(_ args: [String: String]) -> Result<DomainList?, VerbError> {
        guard let s = args["list"] else { return .success(nil) }
        guard let list = DomainList(rawValue: s) else {
            return .failure(VerbError(code: "invalid_args", message: "list must be \"bypass\" or \"vpnOnly\""))
        }
        return .success(list)
    }

    /// The target of domain.rm / domain.enable / domain.disable, checked without looking at
    /// the lists: `lists` to search and exactly one key.
    private struct DomainTarget {
        let lists: [DomainList]
        /// nil when the id is malformed: it cannot name an entry, so it ends as not_found.
        let id: UUID?
        let domain: String?
    }

    /// With `list`, only that list is searched. Without it, both are (see `findDomain`).
    private static func parseTarget(_ args: [String: String], _ rm: RouteManager) -> Result<DomainTarget, VerbError> {
        let lists: [DomainList]
        switch parseList(args) {
        case .failure(let e): return .failure(e)
        case .success(let list): lists = list.map { [$0] } ?? [.bypass, .vpnOnly]
        }
        let id = args["id"], raw = args["domain"]
        if id != nil && raw != nil {
            return .failure(VerbError(code: "invalid_args", message: "give id or domain, not both"))
        }
        if let id {
            // A malformed id cannot name an entry: not_found, as for the route verbs.
            return .success(DomainTarget(lists: lists, id: UUID(uuidString: id), domain: nil))
        }
        guard let raw else {
            return .failure(VerbError(code: "invalid_args", message: "id or domain is required"))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stored values are cleaned (lowercase, no scheme or port); a CIDR is stored as typed.
        // A "/" outside a URL is a CIDR attempt: cleanDomain would cut "10.0.0.0/33" down to
        // "10.0.0.0" and hit a different entry than the one named, so refuse it, as domain.add does.
        let key: String
        if rm.isValidCIDR(trimmed) {
            key = trimmed
        } else if trimmed.contains("/") && !trimmed.contains("://") {
            return .failure(VerbError(code: "invalid_args",
                                      message: "malformed CIDR (expected a.b.c.d/n with n from 2 to 32)"))
        } else {
            key = rm.cleanDomain(trimmed)
        }
        guard !key.isEmpty else {
            return .failure(VerbError(code: "invalid_args", message: "domain is empty after cleaning"))
        }
        return .success(DomainTarget(lists: lists, id: nil, domain: key))
    }

    /// An id is searched in every list of the target (ids are unique). A domain is too, but a
    /// domain on both lists needs `list` to say which.
    private static func findDomain(_ target: DomainTarget, _ rm: RouteManager) -> Result<(DomainEntry, DomainList), VerbError> {
        var matches: [(DomainEntry, DomainList)] = []
        for list in target.lists {
            let found: DomainEntry?
            if let key = target.domain {
                found = entries(list, rm).first(where: { $0.domain == key })
            } else if let uuid = target.id {
                found = entries(list, rm).first(where: { $0.id == uuid })
            } else {
                found = nil
            }
            if let found { matches.append((found, list)) }
        }
        switch matches.count {
        case 0:
            return .failure(VerbError(code: "not_found", message: "no domain entry matches"))
        case 1:
            return .success(matches[0])
        default:
            return .failure(VerbError(code: "invalid_args",
                                      message: "that domain is on both lists; add list=bypass or list=vpnOnly"))
        }
    }

    private static func waitForRouteIdle() async {
        let deadline = Date().addingTimeInterval(busyWait)
        while routeOperationRunning() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
