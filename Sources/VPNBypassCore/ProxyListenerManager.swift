// ProxyListenerManager.swift
// Owns one ProxyForwarder per enabled proxy route and tracks its loopback port
// (P1, VPN-Bypass-3sc.8). Driven by RouteManager's config; the forwarders run on
// their own queues. ProxyForwarder.start() blocks until the listener is ready, so
// new listeners are started OFF the main thread, then results are folded back in.

import Foundation

@MainActor
final class ProxyListenerManager {
    static let shared = ProxyListenerManager()

    private var forwarders: [UUID: ProxyForwarder] = [:]
    private var ports: [UUID: UInt16] = [:]
    private let startQueue = DispatchQueue(label: "com.vpnbypass.listenermgr", qos: .userInitiated)

    init() {}

    /// The local listener port for a route, if its forwarder is running.
    func port(for routeId: UUID) -> UInt16? { ports[routeId] }

    /// Snapshot of every running routeId → port.
    var activePorts: [UUID: UInt16] { ports }

    /// Reconcile running listeners to the proxy routes in `routes`: start a
    /// forwarder for each newly-enabled proxy route, stop ones no longer present.
    /// `boundInterface` is the physical interface (e.g. "en0") that upstream
    /// sockets bind to so the proxy hop escapes a full-tunnel VPN (nil = OS default).
    /// `completion` runs on the main actor once starts settle.
    func reconcile(routes: [Route], boundInterface: String?, completion: (() -> Void)? = nil) {
        let proxyRoutes = routes.filter {
            $0.enabled && ($0.egress == .proxyHTTP || $0.egress == .proxySOCKS5) && !($0.proxyHost ?? "").isEmpty
        }
        let desired = Set(proxyRoutes.map { $0.id })

        // Stop forwarders that are no longer wanted.
        for (id, forwarder) in forwarders where !desired.contains(id) {
            forwarder.stop()
            forwarders[id] = nil
            ports[id] = nil
        }

        let toStart = proxyRoutes.filter { forwarders[$0.id] == nil }
        guard !toStart.isEmpty else { completion?(); return }

        // start() blocks until ready — do it off the main thread, then fold the
        // results back onto the main actor.
        startQueue.async {
            var started: [(id: UUID, forwarder: ProxyForwarder, port: UInt16)] = []
            for route in toStart {
                guard let upstream = Self.makeUpstream(route: route, boundInterface: boundInterface) else { continue }
                let forwarder = ProxyForwarder(listenPort: 0, upstream: upstream)
                if (try? forwarder.start()) != nil, let port = forwarder.boundPort {
                    started.append((route.id, forwarder, port))
                } else {
                    forwarder.stop()
                }
            }
            Task { @MainActor [weak self] in
                guard let self = self else {
                    started.forEach { $0.forwarder.stop() }
                    return
                }
                for entry in started {
                    self.forwarders[entry.id] = entry.forwarder
                    self.ports[entry.id] = entry.port
                }
                completion?()
            }
        }
    }

    /// Stop and forget every listener (e.g. on quit or VPN disconnect).
    func stopAll() {
        for (_, forwarder) in forwarders { forwarder.stop() }
        forwarders.removeAll()
        ports.removeAll()
    }

    /// Build the upstream descriptor for a proxy route, expanding any
    /// username/password session templates. nil if the route lacks a usable host/port.
    nonisolated static func makeUpstream(route: Route, boundInterface: String?) -> ProxyForwarder.Upstream? {
        guard let host = route.proxyHost, !host.isEmpty,
              let port = route.proxyPort, let port16 = UInt16(exactly: port) else { return nil }
        let user = route.proxyUser ?? ""
        let pass = route.proxyPass ?? ""
        let sessionId = route.sessionMode == .sticky ? CredentialTemplate.makeSessionId() : nil
        let username = CredentialTemplate.expand(
            template: route.proxyUsernameTemplate, rawValue: user,
            user: user, pass: pass, sessionId: sessionId, ttlMinutes: route.sessionTTLMinutes
        )
        let password = CredentialTemplate.expand(
            template: route.proxyPasswordTemplate, rawValue: pass,
            user: user, pass: pass, sessionId: sessionId, ttlMinutes: route.sessionTTLMinutes
        )
        return ProxyForwarder.Upstream(host: host, port: port16, username: username, password: password, boundInterface: boundInterface)
    }
}
