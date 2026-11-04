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

/// Team ids of the processes that own the live tunnels, read from their code signatures. Only a
/// team that was found is kept, under the file's path and modification date: a failed read is
/// tried again on the next push, and a binary replaced or signed again at the same path is read
/// again, so the VPN client's team is never left out of the policy for the rest of the session.
@MainActor
enum TunnelOwnerTeams {
    private static var cache: [String: String] = [:]
    /// Reads the team from the signature (a seam for tests).
    static var read: (String) -> String? = signingTeam

    static func team(ofExecutable path: String) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .map { "\($0.timeIntervalSince1970)" } ?? "?"
        let key = path + "\n" + modified
        if let hit = cache[key] { return hit }
        guard let team = read(path), !team.isEmpty else { return nil }
        cache[key] = team
        return team
    }

    static func resetCache() { cache = [:] }

    nonisolated static func signingTeam(ofExecutable path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
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
