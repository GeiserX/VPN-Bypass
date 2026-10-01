// SettingsUndo.swift
// Undo for the Settings pages: a delete or a Turn All On/Off leaves one line that can take
// it back, and Edit > Undo (⌘Z) does the same. Putting a change back goes through the same
// RouteManager methods as making it, so routes follow the entry back in.

import SwiftUI

/// What the last delete or bulk switch on a Settings page changed, with what it takes to put
/// it back. Kept pure so its wording and which page shows it are unit-tested.
enum UndoableChange {
    /// A Bypass or VPN Only entry, and where it sat in its list.
    case domain(DomainEntry, index: Int, list: DomainList)
    /// A custom service, domains and all, and where it sat in the services list.
    case customService(ServiceEntry, index: Int)
    /// A Custom Routes rule. Its `order` puts it back in place. `label` is the pattern as
    /// the row showed it (a service rule shows the service's name).
    case rule(Rule, label: String)
    /// A route from the Routes page, and where it sat in the routes list.
    case route(Route, index: Int)
    /// The domains a Turn All On or Turn All Off switched, and which way.
    case domainsSwitched(ids: [UUID], on: Bool, list: DomainList)
    /// The services a Turn All On or Turn All Off switched, and which way.
    case servicesSwitched(ids: [String], on: Bool)

    /// The page whose line shows this change.
    var page: SettingsView.SettingsTab {
        switch self {
        case .domain, .domainsSwitched: return .domains
        case .customService, .servicesSwitched: return .services
        case .rule: return .rules
        case .route: return .routes
        }
    }

    /// The line's text, in the app's language.
    var message: String { message(in: .main) }

    func message(in bundle: Bundle) -> String {
        switch self {
        case .domain(let entry, _, _):
            if entry.isCIDR {
                return String(localized: "Removed the range \(entry.domain).", bundle: bundle)
            }
            return String(localized: "Removed \(entry.domain).", bundle: bundle)
        case .customService(let service, _):
            let domains = Self.count(service.domains.count, one: String(localized: "1 domain", bundle: bundle),
                                     many: String(localized: "\(service.domains.count) domains", bundle: bundle))
            let ranges = Self.count(service.ipRanges.count, one: String(localized: "1 IP range", bundle: bundle),
                                    many: String(localized: "\(service.ipRanges.count) IP ranges", bundle: bundle))
            switch (domains, ranges) {
            case let (domains?, ranges?):
                return String(localized: "Removed \(service.name), its \(domains) and its \(ranges).", bundle: bundle)
            case (let what?, nil), (nil, let what?):
                return String(localized: "Removed \(service.name) and its \(what).", bundle: bundle)
            case (nil, nil):
                return String(localized: "Removed \(service.name).", bundle: bundle)
            }
        case .rule(_, let label):
            return String(localized: "Removed the rule for \(label).", bundle: bundle)
        case .route(let route, _):
            return String(localized: "Removed the route \(route.friendlyName(vpnName: nil)).", bundle: bundle)
        case .domainsSwitched(let ids, let on, _):
            let what = ids.count == 1 ? String(localized: "1 domain", bundle: bundle)
                : String(localized: "\(ids.count) domains", bundle: bundle)
            return on ? String(localized: "Turned on \(what).", bundle: bundle)
                : String(localized: "Turned off \(what).", bundle: bundle)
        case .servicesSwitched(let ids, let on):
            let what = ids.count == 1 ? String(localized: "1 service", bundle: bundle)
                : String(localized: "\(ids.count) services", bundle: bundle)
            return on ? String(localized: "Turned on \(what).", bundle: bundle)
                : String(localized: "Turned off \(what).", bundle: bundle)
        }
    }

    private static func count(_ n: Int, one: String, many: String) -> String? {
        n == 0 ? nil : (n == 1 ? one : many)
    }
}

extension RouteManager {
    /// Puts a change back through the methods that manage each list, so routes come back with
    /// the entry (or go again with a switch). Returns false when there was nothing to put
    /// back: the entry is listed again, or no switch was left to flip.
    @discardableResult
    func undo(_ change: UndoableChange) -> Bool {
        switch change {
        case .domain(let entry, let index, .bypass):
            return restoreDomain(entry, at: index)
        case .domain(let entry, let index, .vpnOnly):
            return restoreInverseDomain(entry, at: index)
        case .customService(let service, let index):
            return restoreCustomService(service, at: index)
        case .rule(let rule, _):
            return restoreRule(rule)
        case .route(let route, let index):
            return restoreRoute(route, at: index)
        case .domainsSwitched(let ids, let on, .bypass):
            return !setDomainsEnabled(Set(ids), !on).isEmpty
        case .domainsSwitched(let ids, let on, .vpnOnly):
            return !setInverseDomainsEnabled(Set(ids), !on).isEmpty
        case .servicesSwitched(let ids, let on):
            return !setServicesEnabled(Set(ids), !on).isEmpty
        }
    }
}

/// The Settings window's one undoable change. A new delete or bulk switch replaces it; a
/// page or mode switch and closing the window drop it. Undo on the line and ⌘Z both run
/// `undoLast`.
@MainActor
final class SettingsUndo: ObservableObject {
    @Published private(set) var last: UndoableChange?
    /// Counts the changes put back, so a page can re-sort after one (the Services page).
    @Published private(set) var undoneCount = 0
    /// The window's undo manager. ⌘Z goes to Edit > Undo, which asks the window's.
    weak var undoManager: UndoManager? {
        didSet {
            guard oldValue !== undoManager else { return }
            oldValue?.removeAllActions(withTarget: self)
            if last != nil { register() }
        }
    }
    private let routeManager: RouteManager
    /// How many 100 ms polls an undo waits for a running route operation (10 s). Tests
    /// shorten it.
    var gateWaitPolls = 100
    /// Moves on with every recorded or dropped change, so an undo that outlasted its wait
    /// puts its line back only if nothing replaced or dropped it meanwhile.
    private var generation = 0

    /// `last` seeds the line, for a rendered screenshot.
    init(routeManager: RouteManager? = nil, last: UndoableChange? = nil) {
        self.routeManager = routeManager ?? .shared
        self.last = last
    }

    func record(_ change: UndoableChange) {
        generation += 1
        undoManager?.removeAllActions(withTarget: self)
        last = change
        register()
    }

    func clear() {
        generation += 1
        undoManager?.removeAllActions(withTarget: self)
        last = nil
    }

    /// The line's Undo button.
    func undoLast() {
        undoManager?.removeAllActions(withTarget: self)
        perform()
    }

    private func register() {
        undoManager?.registerUndo(withTarget: self) { $0.perform() }
    }

    /// A delete takes its entry out of the config only once its route cleanup ends, and the
    /// route methods skip their work while another operation holds the gate. So while one
    /// runs this waits for it (at most 10 s, as long as a delete's cleanup can take), then
    /// puts the change back. If it is still running then, the change stays on its line and
    /// in Edit > Undo (unless a newer change or a page or mode switch dropped it meanwhile):
    /// putting it back now would change the config with no route work.
    private func perform() {
        guard let change = last else { return }
        last = nil
        let started = generation
        guard routeManager.isApplyingRoutes else {
            finish(change)
            return
        }
        Task { @MainActor in
            var polls = 0
            while routeManager.isApplyingRoutes && polls < gateWaitPolls {
                try? await Task.sleep(nanoseconds: 100_000_000)
                polls += 1
            }
            guard !routeManager.isApplyingRoutes else {
                if generation == started {
                    last = change
                    register()
                }
                return
            }
            finish(change)
        }
    }

    private func finish(_ change: UndoableChange) {
        routeManager.undo(change)
        undoneCount += 1
    }
}

/// The line a delete or bulk switch leaves in its list: what changed, and Undo.
struct UndoLine: View {
    let message: String
    /// True while a route operation runs, as the rows' switches and trash are.
    var isDisabled = false
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onUndo) {
                Text("Undo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.14))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        )
        .accessibilityElement(children: .combine)
    }
}

/// Turn All On for services asks first when it would send more than a handful around the
/// VPN at once. Turn All Off never asks: it only puts traffic back through the VPN, and the
/// undo line covers it.
enum ServiceBulkSwitch {
    /// Turning on more than this many services at once asks first.
    static let askAbove = 5

    struct Question: Equatable {
        let title: String
        let message: String
        let confirm: String
    }

    /// The question for turning on `services` (the ones that are off), or nil when the
    /// switch goes ahead without one.
    static func question(turningOn services: [ServiceEntry], in bundle: Bundle = .main) -> Question? {
        guard services.count > askAbove else { return nil }
        let count = services.count
        return Question(
            title: String(localized: "Send \(count) services around the VPN?", bundle: bundle),
            message: String(localized: "\(services[0].name), \(services[1].name) and \(count - 2) more will use your normal connection instead of the VPN. You can turn them off again here.", bundle: bundle),
            confirm: String(localized: "Turn On \(count) Services", bundle: bundle)
        )
    }

    /// The menu item's title: an ellipsis when it will ask first.
    static func turnAllOnTitle(offCount: Int, in bundle: Bundle = .main) -> String {
        offCount > askAbove ? String(localized: "Turn All On…", bundle: bundle)
            : String(localized: "Turn All On", bundle: bundle)
    }
}
