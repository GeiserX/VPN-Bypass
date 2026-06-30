// CredentialTemplate.swift
// Expands per-route proxy credential templates (P1, VPN-Bypass-3sc.8).
//
// Residential providers encode the session differently: Oxylabs/Bright Data put
// it in the USERNAME (customer-{user}-sessid-{id}-sesstime-{ttl}), IPRoyal in the
// PASSWORD ({pass}_session-{id}). So a route carries BOTH a usernameTemplate and
// a passwordTemplate; each is expanded independently. A dedicated-ISP proxy (one
// fixed IP per port) has no templates — the raw user/pass are used verbatim.
//
// Tokens: {user} {pass} {id} {ttl}. Pure + side-effect-free.

import Foundation

enum CredentialTemplate {

    /// Expand a credential template. A nil/empty template returns `rawValue`
    /// unchanged (the no-session, dedicated-ISP case).
    static func expand(
        template: String?,
        rawValue: String,
        user: String,
        pass: String,
        sessionId: String?,
        ttlMinutes: Int?
    ) -> String {
        guard let t = template, !t.isEmpty else { return rawValue }
        return t
            .replacingOccurrences(of: "{user}", with: user)
            .replacingOccurrences(of: "{pass}", with: pass)
            .replacingOccurrences(of: "{id}", with: sessionId ?? "")
            .replacingOccurrences(of: "{ttl}", with: ttlMinutes.map(String.init) ?? "")
    }

    /// A short, URL-safe random session id for sticky residential sessions.
    /// Deterministic generation is the caller's job (pass a seed) — this is the
    /// convenience used by the UI/manager when starting a new sticky session.
    static func makeSessionId(length: Int = 8, from characters: String = "abcdefghijklmnopqrstuvwxyz0123456789") -> String {
        let chars = Array(characters)
        guard !chars.isEmpty else { return "" }
        var out = ""
        for _ in 0..<max(0, length) {
            out.append(chars[Int.random(in: 0..<chars.count)])
        }
        return out
    }
}
