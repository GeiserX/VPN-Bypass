// RouteModel.swift
// The multi-route data model: typed egresses + named routes + ordered rules.
//
// This is the P0 foundation (VPN-Bypass-3sc.7). It is ADDITIVE: `Config` gains
// `routes`/`rules`/`defaultRouteId`/`schemaVersion`, but while `schemaVersion`
// is 1 the existing bypass/vpnOnly engine keeps running, so there is no
// behaviour change yet. P1 flips to `schemaVersion = 2` and dispatches by rule.
// See docs/MULTI-ROUTE-DESIGN.md.
//
// Decoders use `decodeIfPresent` + defaults (mirroring DomainEntry/ServiceEntry)
// so partial or future JSON degrades gracefully and older builds round-trip.

import Foundation

/// A named egress that a destination can be routed through (the typed outbound).
enum Egress: String, Codable, Equatable {
    case vpnDefault     // leave on the OS default route (corporate VPN). No kernel route added.
    case direct         // physical NIC: host-route via the local gateway (or IP_BOUND_IF on en0).
    case tailscaleExit  // into the Tailscale utun (iface:utunX) — Mac-mini-as-exit-node.
    case proxyHTTP      // userspace 127.0.0.1:PORT listener → HTTP CONNECT upstream.
    case proxySOCKS5    // userspace 127.0.0.1:PORT listener → SOCKS5 (socks5h) upstream.
}

/// Residential-proxy session behaviour. Inert in P0; consumed in P1.
enum SessionMode: String, Codable, Equatable {
    case none       // a plain proxy (e.g. a dedicated-ISP port = one fixed exit IP).
    case rotating   // a new exit IP per connection.
    case sticky     // a session id in the credential pins the exit IP for a TTL.
    case portPinned // the port itself selects the exit (provider-specific).
}

/// The matcher kind for a routing rule.
enum MatchType: String, Codable, Equatable {
    case domain   // exact hostname (resolve → IP route under the kernel engine).
    case suffix   // *.example.com — only meaningful with a flow-intercept engine (P3).
    case ip       // a single IP.
    case cidr     // a CIDR block.
    case service  // a built-in ServiceEntry id (a bundle of domains + IP ranges).
    case process  // a process name — P3, NE-only.
}

/// A named route: a typed egress plus its provider configuration.
struct Route: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var egress: Egress
    var enabled: Bool

    // Proxy egress (nil for non-proxy routes).
    var proxyHost: String?
    var proxyPort: Int?
    var proxyUser: String?
    var proxyPass: String?
    // Two templates, not one: Oxylabs/Bright Data encode the session in the
    // USERNAME, IPRoyal in the PASSWORD. Tokens: {user} {pass} {id} {ttl}.
    var proxyUsernameTemplate: String?
    var proxyPasswordTemplate: String?
    var sessionMode: SessionMode
    var sessionTTLMinutes: Int?
    /// socks5h / CONNECT-by-name → the proxy resolves remotely (DNS-leak-safe).
    var remoteDNS: Bool

    // Tailscale egress: pin a specific exit node; nil = the detected one.
    var tailscaleExitNode: String?

    /// Daemon-managed: the assigned 127.0.0.1 listener port for proxy egresses.
    /// Never hand-edited.
    var localListenPort: Int?

    init(
        id: UUID = UUID(),
        name: String,
        egress: Egress,
        enabled: Bool = true,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        proxyUser: String? = nil,
        proxyPass: String? = nil,
        proxyUsernameTemplate: String? = nil,
        proxyPasswordTemplate: String? = nil,
        sessionMode: SessionMode = .none,
        sessionTTLMinutes: Int? = nil,
        remoteDNS: Bool = true,
        tailscaleExitNode: String? = nil,
        localListenPort: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.egress = egress
        self.enabled = enabled
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUser = proxyUser
        self.proxyPass = proxyPass
        self.proxyUsernameTemplate = proxyUsernameTemplate
        self.proxyPasswordTemplate = proxyPasswordTemplate
        self.sessionMode = sessionMode
        self.sessionTTLMinutes = sessionTTLMinutes
        self.remoteDNS = remoteDNS
        self.tailscaleExitNode = tailscaleExitNode
        self.localListenPort = localListenPort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        egress = try c.decodeIfPresent(Egress.self, forKey: .egress) ?? .direct
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost)
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort)
        proxyUser = try c.decodeIfPresent(String.self, forKey: .proxyUser)
        proxyPass = try c.decodeIfPresent(String.self, forKey: .proxyPass)
        proxyUsernameTemplate = try c.decodeIfPresent(String.self, forKey: .proxyUsernameTemplate)
        proxyPasswordTemplate = try c.decodeIfPresent(String.self, forKey: .proxyPasswordTemplate)
        sessionMode = try c.decodeIfPresent(SessionMode.self, forKey: .sessionMode) ?? .none
        sessionTTLMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionTTLMinutes)
        remoteDNS = try c.decodeIfPresent(Bool.self, forKey: .remoteDNS) ?? true
        tailscaleExitNode = try c.decodeIfPresent(String.self, forKey: .tailscaleExitNode)
        localListenPort = try c.decodeIfPresent(Int.self, forKey: .localListenPort)
    }
}

/// An ordered, first-match routing rule: a matcher → a route.
struct Rule: Codable, Identifiable, Equatable {
    var id: UUID
    var matchType: MatchType
    var pattern: String
    var routeId: UUID
    var enabled: Bool
    var order: Int  // lower runs earlier; first match wins.

    init(id: UUID = UUID(), matchType: MatchType, pattern: String, routeId: UUID, enabled: Bool = true, order: Int) {
        self.id = id
        self.matchType = matchType
        self.pattern = pattern
        self.routeId = routeId
        self.enabled = enabled
        self.order = order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        matchType = try c.decodeIfPresent(MatchType.self, forKey: .matchType) ?? .domain
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        // routeId has no default. Decoding stays total so one malformed rule
        // cannot fail the whole config decode (matching Config's resilient
        // decoder); the all-zero UUID matches no route, leaving the rule inert.
        routeId = try c.decodeIfPresent(UUID.self, forKey: .routeId)
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }
}
