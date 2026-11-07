// FlowEngineState.swift
// What per-app routing (the opt-in Network Extension engine) is doing, in the words every
// surface uses: the General page's group, the Rules page's notes, `vpnb engine.status` and the
// `status` reply. Pure, so it is tested without the extension.
//
// Design: docs/design/NETWORK-EXTENSION-DESIGN.md, section 5 (the states) and 3.7 (failures).
// In every state but `active` the kernel engine runs as it always does, and process rules say
// why nothing serves them.

import Foundation

/// The engine's state. `public`: `vpnb` decodes it from `FlowEngineStatus`.
public enum FlowEngineState: Equatable, Sendable {
    public enum Unavailable: String, Codable, Sendable {
        /// macOS 14 or older: the flow APIs per-app routing uses arrived in macOS 15.
        case needsMacOS15
        /// A build without the extension or its entitlements (a dev or CI build).
        case notInThisBuild
    }

    public enum Blocked: String, Codable, Sendable {
        /// A profile installed by the Mac's administrator forbids it (system extension policy
        /// with AllowUserOverrides false, or a refused configuration).
        case forbiddenByPolicy
        /// The app does not run from /Applications (`unsupportedParentBundleLocation`).
        case notInApplications
        /// macOS finishes the activation after a restart.
        case needsRestart
    }

    public enum Paused: String, Codable, Sendable {
        /// The app's Pause.
        case pause
        /// The VPN sends every connection into its tunnel (`includeAllNetworks`/`enforceRoutes`).
        case killSwitch
        /// VPN Only mode: per-app routing never runs there.
        case vpnOnly
    }

    public enum Failed: String, Codable, Sendable {
        /// The extension stopped (a crash) or went silent; the app starts it once by itself.
        case stoppedRestarting
        /// It stopped twice within 10 minutes, so the app turned per-app routing off.
        case stoppedTwice
        /// The activation request failed for another reason (its code is logged).
        case activationFailed
        /// The session would not start.
        case startFailed
        /// The user said no to the proxy configuration, so per-app routing is off again.
        case configurationDeclined
    }

    case unavailable(Unavailable)
    case off
    /// The activation request is filed; the user has not allowed the extension yet.
    case awaitingExtensionApproval
    /// The extension is allowed; macOS is asking whether VPN Bypass may add the proxy configuration.
    case awaitingConfigApproval
    case blocked(Blocked)
    case starting
    case active
    case paused(Paused)
    /// The running extension does not read this app's policy: its replacement waits for approval.
    case updateWaiting
    case failed(Failed)

    /// The wire code (`vpnb engine.status`, `status`).
    public var code: String {
        switch self {
        case .unavailable: return "unavailable"
        case .off: return "off"
        case .awaitingExtensionApproval: return "awaitingExtensionApproval"
        case .awaitingConfigApproval: return "awaitingConfigApproval"
        case .blocked: return "blocked"
        case .starting: return "starting"
        case .active: return "active"
        case .paused: return "paused"
        case .updateWaiting: return "updateWaiting"
        case .failed: return "failed"
        }
    }

    /// The reason's wire code, nil for states that carry none.
    public var reasonCode: String? {
        switch self {
        case .unavailable(let r): return r.rawValue
        case .blocked(let r): return r.rawValue
        case .paused(let r): return r.rawValue
        case .failed(let r): return r.rawValue
        default: return nil
        }
    }

    /// The extension serves process rules with the Direct route.
    public var servesRules: Bool { self == .active }

    /// Why process rules do nothing in this state; nil when it serves them.
    var ruleReason: ProcessRule.InactiveReason? {
        switch self {
        case .active: return nil
        case .unavailable: return .perAppRoutingNotAvailable
        case .off: return .perAppRoutingOff
        case .awaitingExtensionApproval, .awaitingConfigApproval: return .perAppRoutingWaitingForApproval
        case .blocked: return .perAppRoutingBlocked
        case .starting: return .perAppRoutingStarting
        case .paused: return .perAppRoutingPaused
        case .updateWaiting: return .perAppRoutingUpdateWaiting
        case .failed: return .perAppRoutingFailed
        }
    }

    /// One line for the General page's group and the dropdown.
    func line(in bundle: Bundle = .main) -> String {
        switch self {
        case .unavailable(.needsMacOS15):
            return String(localized: "Needs macOS 15 or later.", bundle: bundle)
        case .unavailable(.notInThisBuild):
            return String(localized: "Not in this build of VPN Bypass.", bundle: bundle)
        case .off:
            return String(localized: "Off. Every app follows your routes, as before.", bundle: bundle)
        case .awaitingExtensionApproval:
            return String(localized: "Waiting for you to allow the extension in System Settings > General > Login Items & Extensions > Network Extensions.", bundle: bundle)
        case .awaitingConfigApproval:
            return String(localized: "Waiting for you to allow the proxy configuration macOS is asking about.", bundle: bundle)
        case .blocked(.forbiddenByPolicy):
            return String(localized: "Blocked: a profile installed by this Mac's administrator does not allow it.", bundle: bundle)
        case .blocked(.notInApplications):
            return String(localized: "Blocked: macOS runs it only when VPN Bypass is in the Applications folder.", bundle: bundle)
        case .blocked(.needsRestart):
            return String(localized: "macOS finishes turning it on after you restart the Mac.", bundle: bundle)
        case .starting:
            return String(localized: "Starting…", bundle: bundle)
        case .active:
            return String(localized: "On. Apps in your rules go around the VPN.", bundle: bundle)
        case .paused(.pause):
            return String(localized: "Paused with your routes. Listed apps use the VPN until you resume.", bundle: bundle)
        case .paused(.killSwitch):
            return String(localized: "Standing down: the VPN sends every connection into its tunnel, so listed apps use the VPN.", bundle: bundle)
        case .paused(.vpnOnly):
            return String(localized: "Not used in VPN Only mode.", bundle: bundle)
        case .updateWaiting:
            return String(localized: "An update of the extension is waiting for approval in System Settings. Until then listed apps use the VPN.", bundle: bundle)
        case .failed(.stoppedRestarting):
            return String(localized: "Per-app routing stopped; your listed apps use the VPN. Starting it again.", bundle: bundle)
        case .failed(.stoppedTwice):
            return String(localized: "Per-app routing stopped twice within 10 minutes, so it was turned off. Your listed apps use the VPN.", bundle: bundle)
        case .failed(.activationFailed):
            return String(localized: "macOS could not turn the extension on. Your listed apps use the VPN.", bundle: bundle)
        case .failed(.startFailed):
            return String(localized: "Per-app routing would not start. Your listed apps use the VPN.", bundle: bundle)
        case .failed(.configurationDeclined):
            return String(localized: "The proxy configuration was not allowed, so per-app routing is off. Nothing else changed.", bundle: bundle)
        }
    }

    /// States where System Settings holds the next step.
    var waitsInSystemSettings: Bool {
        self == .awaitingExtensionApproval || self == .updateWaiting
    }

    /// What an `OSSystemExtensionError` code means for the engine (SystemExtensions'
    /// `OSSystemExtensionErrorCode`): 2 missing entitlement and 4 extension not found are a build
    /// without the extension; 3 the app outside /Applications; 10 a system policy (MDM); 13 an
    /// authorization the user did not give. The rest fail with the code in the log.
    static func forActivationError(code: Int) -> FlowEngineState {
        switch code {
        case 2, 4: return .unavailable(.notInThisBuild)
        case 3: return .blocked(.notInApplications)
        case 10: return .blocked(.forbiddenByPolicy)
        default: return .failed(.activationFailed)
        }
    }
}

/// Where taking the extension off the Mac stands (turning per-app routing off, or Remove
/// Extension). Its wire code is the raw value.
public enum FlowEngineRemoval: String, Codable, Sendable {
    /// The configuration is being removed, or the deactivation waits for the administrator password.
    case removing
    case removed
    /// macOS removes the extension after a restart.
    case needsRestart
    /// The configuration or the extension could not be removed (the code is logged).
    case failed

    /// One line for the General page's group.
    func line(in bundle: Bundle = .main) -> String {
        switch self {
        case .removing:
            return String(localized: "Removing the extension from this Mac. macOS asks for an administrator password.", bundle: bundle)
        case .removed:
            return String(localized: "The extension is removed from this Mac.", bundle: bundle)
        case .needsRestart:
            return String(localized: "macOS removes the extension when you restart the Mac.", bundle: bundle)
        case .failed:
            return String(localized: "The extension could not be removed. Try again, or see Troubleshooting for the manual steps.", bundle: bundle)
        }
    }
}

/// Per rule, what the extension did with its app's connections since it started.
public struct FlowEngineRuleCounters: Codable, Equatable, Sendable {
    /// A rule's UUID, or an Apps list entry's. Never an app name.
    public var ruleId: String
    /// Connections carried around the VPN.
    public var claimed: Int
    /// Connections that arrived bound to a network interface, which per-app routing cannot serve.
    public var bound: Int
}

/// Per-app routing in the `status` reply and `vpnb engine.*`. Counts and codes only: no app
/// names, no addresses, no host names (design 3.8).
public struct FlowEngineStatus: Codable, Equatable, Sendable {
    /// The switch in Settings > General (saved in config.json).
    public var enabled: Bool
    /// `FlowEngineState.code`.
    public var state: String
    /// `FlowEngineState.reasonCode`, omitted when the state carries none.
    public var reason: String? = nil
    /// The generation of the last policy the extension confirmed.
    public var policyGeneration: Int? = nil
    /// The extension's version, from its last reply.
    public var extensionVersion: String? = nil
    /// The extension runs another version than the app: its replacement waits.
    public var updateWaiting: Bool? = nil
    /// Per rule: connections claimed and connections declined because they arrived bound.
    public var rules: [FlowEngineRuleCounters]? = nil
    /// Flows declined, by reason code.
    public var declined: [String: Int]? = nil
    /// Times the lease ran out without a fresh push.
    public var leaseExpiries: Int? = nil
    /// `FlowEngineRemoval` code of the last removal, omitted when none ran since launch.
    public var removal: String? = nil
    /// `FlowEngineStartRetry` code: when a failed start is tried again; omitted otherwise.
    public var retry: String? = nil

    public init(enabled: Bool, state: FlowEngineState, reply: FlowEngineReplySummary? = nil, appVersion: String? = nil,
                removal: FlowEngineRemoval? = nil, retry: FlowEngineStartRetry? = nil) {
        self.enabled = enabled
        self.removal = removal?.rawValue
        self.retry = retry?.rawValue
        self.state = state.code
        self.reason = state.reasonCode
        // Also with no reply: a replacement waiting for approval has none.
        if state == .updateWaiting { updateWaiting = true }
        guard let reply else { return }
        policyGeneration = reply.policyGeneration
        extensionVersion = reply.extensionVersion
        if let ext = reply.extensionVersion, let appVersion, ext != appVersion { updateWaiting = true }
        let ids = Set(reply.claimedByRule.keys).union(reply.boundByRule.keys)
        rules = ids.isEmpty ? nil : ids.sorted().map {
            FlowEngineRuleCounters(ruleId: $0, claimed: reply.claimedByRule[$0] ?? 0, bound: reply.boundByRule[$0] ?? 0)
        }
        declined = reply.declined.isEmpty ? nil : reply.declined
        leaseExpiries = reply.leaseExpiries == 0 ? nil : reply.leaseExpiries
    }

    /// The `vpnb engine.status` text.
    public var textLines: [String] {
        var line = "per-app routing: \(state)"
        if let reason { line += " (\(reason))" }
        line += enabled ? "  switch: on" : "  switch: off"
        if let policyGeneration { line += "  generation: \(policyGeneration)" }
        if let extensionVersion { line += "  extension: \(extensionVersion)" }
        if updateWaiting == true { line += "  update waiting" }
        if let removal { line += "  extension removal: \(removal)" }
        switch retry.flatMap(FlowEngineStartRetry.init(rawValue:)) {
        case .waitingForNetwork: line += "  retry: when the network is up"
        case .onNextChange: line += "  retry: on the next change of the network or the settings"
        case nil: break
        }
        var out = [line]
        for r in rules ?? [] {
            out.append("  rule \(r.ruleId): \(r.claimed) around the VPN, \(r.bound) bound to an interface (not served)")
        }
        return out
    }
}

/// When a failed start is tried again (`engine.status`'s `retry`).
public enum FlowEngineStartRetry: String, Codable, Sendable {
    /// The network is down or not reported yet: the start runs again once it is up.
    case waitingForNetwork
    /// The network is up: the start runs again on the next change, at most every 30 s.
    case onNextChange
}

/// The parts of the extension's reply the app keeps (`FlowPolicyReply`, copied so this file
/// stays free of the policy target in its public API).
public struct FlowEngineReplySummary: Equatable, Sendable {
    public var policyGeneration: Int
    public var extensionVersion: String?
    public var claimedByRule: [String: Int]
    public var boundByRule: [String: Int]
    public var declined: [String: Int]
    public var leaseExpiries: Int

    public init(policyGeneration: Int = 0, extensionVersion: String? = nil, claimedByRule: [String: Int] = [:],
                boundByRule: [String: Int] = [:], declined: [String: Int] = [:], leaseExpiries: Int = 0) {
        self.policyGeneration = policyGeneration
        self.extensionVersion = extensionVersion
        self.claimedByRule = claimedByRule
        self.boundByRule = boundByRule
        self.declined = declined
        self.leaseExpiries = leaseExpiries
    }
}
