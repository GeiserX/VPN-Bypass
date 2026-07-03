// ControlSurface.swift
// Wires the transport (ControlSocketServer) to the app's state: it turns one
// decoded ControlRequest into a CommandRouter mutation on RouteManager, persists
// it, and reconciles so the change takes effect live (a scripted `route.set`
// re-points its listener via ProxyForwarder.updateUpstream — same path the GUI
// edit takes). This is the ONE place the otherwise-generic socket touches app
// state, so all the app's invariants (MainActor isolation, save, reconcile) live
// here rather than in the transport.

import Foundation

/// The bridge between the control socket and RouteManager. Namespaced enum; no state.
public enum ControlSurface {

    /// A ready-to-start socket server bound to the default user-only socket path,
    /// dispatching every request through `handle`. The caller (the app delegate)
    /// owns start()/stop() over the app lifecycle.
    public static func makeServer() -> ControlSocketServer {
        ControlSocketServer(socketPath: ControlSocketServer.defaultSocketPath()) { request in
            await handle(request)
        }
    }

    /// Apply one request on the main actor (so it serializes with the GUI's own
    /// RouteManager mutations), persist + reconcile if it changed something, and
    /// return the sanitized response. Never logs args or secrets — only the verb.
    @MainActor
    public static func handle(_ request: ControlRequest) async -> ControlResponse {
        let ports = ProxyListenerManager.shared.activePorts
        let (newConfig, response) = CommandRouter.apply(request, to: RouteManager.shared.config, listenerPorts: ports)

        // Read verbs (and any errored verb) leave the config untouched — don't
        // write config.json or churn listeners for a `status`/`route.list`.
        guard response.ok, CommandRouter.isMutating(request.cmd) else { return response }

        RouteManager.shared.config = newConfig
        RouteManager.shared.saveConfig()
        RouteManager.shared.log(.info, "Control: '\(request.cmd)' applied via the command line")

        // Proxy/Tailscale routes: re-point/start/stop the affected listener live.
        await RouteManager.shared.reconcileProxyListeners()

        // A routing-mode change also needs the legacy kernel routes re-applied for
        // the new mode (the config already carries the new mode at this point).
        if request.cmd == "mode" {
            await RouteManager.shared.detectAndApplyRoutesAsync(sendNotification: false)
        }

        return response
    }
}
