// ShortcutActions.swift
// What the Shortcuts actions (ShortcutIntents.swift) do, kept apart from the App Intents types
// so it is unit-tested. Each action is one control-socket request, run through
// `ControlSurface.handle`, the entry point `vpnb` and the MCP server use. So a Shortcut gets the
// same checks, the same save and re-apply, the same log lines and the same footer line as
// `vpnb`, marked as coming from Shortcuts instead of the command line.

import Foundation

/// One thing a Shortcut can ask the app to do.
enum ShortcutAction: Equatable {
    case setMode(RoutingMode)
    case addDomain(String, list: DomainList)
    case setService(id: String, on: Bool)
    case getStatus
    case pause(PauseLength)
    case resume

    /// The control-socket request that does it.
    var request: ControlRequest {
        switch self {
        case .setMode(let mode):
            return ControlRequest(cmd: "mode", args: ["mode": mode.rawValue])
        case .addDomain(let domain, let list):
            return ControlRequest(cmd: "domain.add", args: ["domain": domain, "list": list.rawValue])
        case .setService(let id, let on):
            return ControlRequest(cmd: on ? "service.enable" : "service.disable", args: ["id": id])
        case .getStatus:
            return ControlRequest(cmd: "status")
        case .pause(let length):
            return ControlRequest(cmd: "pause", args: ["for": length.wireValue])
        case .resume:
            return ControlRequest(cmd: "resume")
        }
    }
}

/// A refused action. Shortcuts shows the message, which is the one `vpnb` prints.
struct ShortcutActionError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    let code: String
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

enum ShortcutActions {

    /// Runs one action through the control surface, marked as coming from Shortcuts. Throws
    /// what the socket would answer with `ok: false`.
    @MainActor
    static func run(_ action: ShortcutAction) async throws -> ControlResponse {
        // Shortcuts can launch the app to run an action. Until the saved config is loaded the
        // app holds the default one, and a change saved now would replace the user's file.
        guard RouteManager.shared.hasLoadedConfig else {
            throw ShortcutActionError(code: "starting", message: notReady())
        }
        // An unreadable config.json blocks every save, so a change would only live in memory,
        // on the default config, until the app quits. Get Status still answers.
        if RouteManager.shared.isConfigLoadFailed, CommandRouter.isMutating(action.request.cmd) {
            throw ShortcutActionError(code: "config_unreadable", message: configUnreadable())
        }
        let response = await ControlOrigin.$channel.withValue(.shortcuts) {
            await ControlSurface.handle(action.request)
        }
        guard response.ok else {
            throw ShortcutActionError(code: response.error?.code ?? "unknown",
                                      message: response.error?.message ?? "The action failed.")
        }
        return response
    }

    // MARK: - What the action says back

    static func configUnreadable(in bundle: Bundle = .main) -> String {
        String(localized: "VPN Bypass could not read its configuration file, so it saves no changes. Repair it or import a saved configuration in Settings.", bundle: bundle)
    }

    static func notReady(in bundle: Bundle = .main) -> String {
        String(localized: "VPN Bypass is still starting. Run the shortcut again in a moment.", bundle: bundle)
    }

    /// The domain Add Domain names: the entry as the app saved it, cleaned (a pasted link
    /// becomes its host), or what was typed when the answer has none.
    static func savedDomain(_ response: ControlResponse, typed: String) -> String {
        response.result?.domains?.first?.domain ?? typed
    }

    static func modeDone(_ mode: RoutingMode, in bundle: Bundle = .main) -> String {
        let name = DropdownModePicker.label(mode, in: bundle)
        return String(localized: "The mode is now \(name).", bundle: bundle)
    }

    static func domainAdded(_ domain: String, list: DomainList, in bundle: Bundle = .main) -> String {
        switch list {
        case .bypass: return String(localized: "Added \(domain) to the Bypass list.", bundle: bundle)
        case .vpnOnly: return String(localized: "Added \(domain) to the VPN Only list.", bundle: bundle)
        }
    }

    static func serviceDone(_ name: String, on: Bool, in bundle: Bundle = .main) -> String {
        on ? String(localized: "\(name) is on.", bundle: bundle)
           : String(localized: "\(name) is off.", bundle: bundle)
    }

    static func pauseDone(_ length: PauseLength, in bundle: Bundle = .main) -> String {
        switch length {
        case .minutes(let m):
            return String(localized: "Paused for \(DropdownStatus.countdown(TimeInterval(m * 60))): traffic follows the VPN's own routes.", bundle: bundle)
        case .untilReconnect:
            return String(localized: "Paused until the VPN reconnects: traffic follows the VPN's own routes.", bundle: bundle)
        case .untilResume:
            return String(localized: "Paused until you resume: traffic follows the VPN's own routes.", bundle: bundle)
        }
    }

    static func resumeDone(in bundle: Bundle = .main) -> String {
        String(localized: "Resumed: the routes are coming back.", bundle: bundle)
    }

    /// Pause Routing when some routes could not be removed: never the clean paused line.
    static func pausePartial(left: Int, in bundle: Bundle = .main) -> String {
        left == 1
            ? String(localized: "Paused, but 1 address is still routed: removing it failed. Retry from the dropdown.", bundle: bundle)
            : String(localized: "Paused, but \(left) addresses are still routed: removing them failed. Retry from the dropdown.", bundle: bundle)
    }

    static func notPaused(in bundle: Bundle = .main) -> String {
        String(localized: "Routing was not paused.", bundle: bundle)
    }

    /// Get Status's answer: the mode, then whether anything is routed and, when not, the one
    /// reason, in the order the dropdown checks them (MenuBarLabel.iconAccessibilityLabel): the
    /// kill switch before "nothing routed", since it is why routes would have no effect.
    static func statusLine(mode: RoutingMode, runtime: RuntimeStatus?, in bundle: Bundle = .main) -> String {
        let name = DropdownModePicker.label(mode, in: bundle)
        guard let runtime else {
            return String(localized: "\(name) mode.", bundle: bundle)
        }
        if !runtime.helperReady {
            return String(localized: "\(name) mode. The helper is not ready, so nothing is routed.", bundle: bundle)
        }
        // Only once every route is out and a VPN is up, as the dropdown says Paused only then.
        if runtime.paused != nil && runtime.vpnConnected && runtime.enforcedRouteCount == 0 {
            return String(localized: "\(name) mode. Paused: traffic follows the VPN's own routes.", bundle: bundle)
        }
        if !runtime.vpnConnected {
            return String(localized: "\(name) mode. The VPN is not connected.", bundle: bundle)
        }
        // The same three cases as the dropdown (MenuBarLabel.killSwitchAccessibilityLabel).
        if let flags = runtime.killSwitch {
            guard flags.contains("includeAllNetworks") else {
                return String(localized: "\(name) mode. The VPN's own routes win over this app's, so routes set here have no effect.", bundle: bundle)
            }
            return flags.contains("excludeLocalNetworks")
                ? String(localized: "\(name) mode. The VPN's kill switch sends all traffic through it except local-network addresses.", bundle: bundle)
                : String(localized: "\(name) mode. The VPN's kill switch sends all traffic through it, so nothing skips it.", bundle: bundle)
        }
        if runtime.enforcedRouteCount == 0 {
            return String(localized: "\(name) mode. Nothing is routed yet.", bundle: bundle)
        }
        return String(localized: "\(name) mode. Routed addresses: \(runtime.enforcedRouteCount)", bundle: bundle)
    }
}
