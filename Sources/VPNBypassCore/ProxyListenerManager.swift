// ProxyListenerManager.swift
// Owns one ProxyForwarder per enabled proxy route and tracks its loopback port
// (P1, VPN-Bypass-3sc.8). Driven by RouteManager's config; the forwarders run on
// their own queues. ProxyForwarder.start() blocks until the listener is ready, so
// new listeners are started OFF the main thread, then results are folded back in.

import Foundation

@MainActor
final class ProxyListenerManager: ObservableObject {
    static let shared = ProxyListenerManager()

    private var forwarders: [UUID: ProxyForwarder] = [:]
    /// routeId → bound listener port. @Published so the Routes UI updates the
    /// instant a listener comes up (the Copy-hook button keys off this).
    @Published private(set) var ports: [UUID: UInt16] = [:]
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
            $0.enabled && Self.usesLocalListener($0.egress) && !($0.proxyHost ?? "").isEmpty
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
                if let result = Self.startForwarder(route: route, upstream: upstream) {
                    started.append((route.id, result.forwarder, result.port))
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

    /// Start a single proxy forwarder and return it with its bound port.
    /// Returns nil if start() fails or no ephemeral port is assigned.
    /// Called from the startQueue background thread — must be nonisolated.
    nonisolated static func startForwarder(route: Route, upstream: ProxyForwarder.Upstream) -> (forwarder: ProxyForwarder, port: UInt16)? {
        // Try the route's STABLE preferred port first (so an app's HTTPS_PROXY
        // config survives restarts), then fall back to an OS-assigned port.
        for candidate in [preferredPort(for: route), 0] {
            let forwarder = ProxyForwarder(listenPort: candidate, upstream: upstream)
            if (try? forwarder.start()) != nil, let port = forwarder.boundPort {
                return (forwarder, port)
            }
            forwarder.stop()
        }
        return nil
    }

    /// The route's persisted port if set, else a stable port derived from its id.
    nonisolated static func preferredPort(for route: Route) -> UInt16 {
        if let p = route.localListenPort, let p16 = UInt16(exactly: p), p16 > 0 { return p16 }
        return derivePort(from: route.id)
    }

    /// A deterministic port in 18000–18999 from the route id (UUID bytes are
    /// stable across runs, unlike Swift's per-process-seeded Hasher).
    nonisolated static func derivePort(from id: UUID) -> UInt16 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let value = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return 18000 + (value % 1000)
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
        // A Tailscale-peer upstream is reachable ONLY through the Tailscale utun. Its
        // 100.x address routes there by the kernel's longest-prefix match, so binding
        // the socket to the physical NIC (the VPN-escape trick for internet proxies)
        // would send it out the wrong interface and break it. Such routes never bind.
        let effectiveInterface = usesTailnet(route) ? nil : boundInterface
        return ProxyForwarder.Upstream(host: host, port: port16, username: username, password: password, boundInterface: effectiveInterface)
    }

    // MARK: - Egress / tailnet classification (pure, testable)

    /// Egresses served by a local 127.0.0.1 listener (a chaining forwarder): the two
    /// proxy types and Tailscale-peer egress (which is proxy-over-tailnet under the hood).
    nonisolated static func usesLocalListener(_ egress: Egress) -> Bool {
        egress == .proxyHTTP || egress == .proxySOCKS5 || egress == .tailscaleExit
    }

    /// True when a route's upstream lives on the tailnet — either an explicit Tailscale
    /// egress or any upstream whose host is a literal CGNAT address (100.64.0.0/10).
    nonisolated static func usesTailnet(_ route: Route) -> Bool {
        if route.egress == .tailscaleExit { return true }
        if let host = route.proxyHost { return isTailnetHost(host) }
        return false
    }

    /// `host` is a literal Tailscale CGNAT address (100.64.0.0/10).
    nonisolated static func isTailnetHost(_ host: String) -> Bool {
        RuleResolver.ipv4(host, inCIDR: "100.64.0.0/10")
    }

    /// `host` falls in the CGNAT sub-range GlobalProtect also captures (100.112.0.0/12).
    /// While GP is up, longest-prefix match steals such a packet into the GP tunnel
    /// instead of the Tailscale utun, so callers must refuse the route. See the
    /// 2026-07-03 tailnet probe.
    nonisolated static func isTailnetHostShadowedByGlobalProtect(_ host: String) -> Bool {
        RuleResolver.ipv4(host, inCIDR: "100.112.0.0/12")
    }
}
