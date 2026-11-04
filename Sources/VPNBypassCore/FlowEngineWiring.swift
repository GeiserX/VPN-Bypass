// FlowEngineWiring.swift
// Connects FlowEngineManager to the app: the saved switch, the log, and every RouteManager value
// the per-app policy is compiled from. Kept apart so FlowEngineManager compiles without the app.

import Combine
import Foundation
import Security
import VPNBypassPolicy

extension FlowEngineManager {
    /// At launch, after the config is loaded: follows the saved switch, and from then on every
    /// change that can change the policy.
    func start(observing rm: RouteManager) {
        guard !started else { return }
        inputs = { await rm.flowPolicyInput() }
        isEnabled = { rm.config.flowEngine.enabled }
        saveEnabled = { on in
            rm.config.flowEngine.enabled = on
            rm.saveConfig()
        }
        log = { level, message in
            switch level {
            case .info: rm.log(.info, message)
            case .warning: rm.log(.warning, message)
            case .error: rm.log(.error, message)
            }
        }
        let changes: [AnyPublisher<Void, Never>] = [
            rm.$config.map { _ in () }.eraseToAnyPublisher(),
            rm.$pauseState.map { _ in () }.eraseToAnyPublisher(),
            rm.$vpnKillSwitch.map { _ in () }.eraseToAnyPublisher(),
            rm.$localGateway.map { _ in () }.eraseToAnyPublisher(),
            rm.$vpnInterface.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.inputsChanged() }
            .store(in: &subscriptions)
        begin()
    }
}

// MARK: - The policy's inputs

/// Team ids of the processes that own the live tunnels, read from their code signatures.
@MainActor
enum TunnelOwnerTeams {
    private static var cache: [String: String] = [:]

    static func team(ofExecutable path: String) -> String? {
        if let hit = cache[path] { return hit.isEmpty ? nil : hit }
        var code: SecStaticCode?
        var team = ""
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let dict = info as? [String: Any] {
                team = dict[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
            }
        }
        cache[path] = team
        return team.isEmpty ? nil : team
    }
}

extension RouteManager {
    /// Everything the per-app policy is compiled from, read now.
    func flowPolicyInput() async -> FlowPolicyCompiler.Input {
        let iface = await detectPhysicalInterface()
        let teams = Set(tunnelOwnersByInterface.values.compactMap { TunnelOwnerTeams.team(ofExecutable: $0.executablePath) })
        return FlowPolicyCompiler.Input(config: config, paused: isPaused, killSwitchActive: vpnKillSwitch != nil,
                                        physicalInterface: iface, tunnelOwnerTeams: teams.sorted())
    }
}
