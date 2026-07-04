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
        let values: [String: String] = [
            "user": user,
            "pass": pass,
            "id": sessionId ?? "",
            "ttl": ttlMinutes.map(String.init) ?? "",
        ]
        // Single left-to-right pass. Chained `replacingOccurrences` would run each
        // replacement over the OUTPUT of the previous one, so a credential value that
        // itself contains a literal `{pass}`/`{id}`/`{ttl}` would get re-matched and
        // mangled (leaking one field into another's expansion). Here each recognized
        // `{token}` is replaced with its value and the cursor jumps PAST the inserted
        // value, so substituted text is never re-scanned. Unknown `{tokens}` are left
        // verbatim.
        var out = ""
        var i = t.startIndex
        while i < t.endIndex {
            if t[i] == "{", let close = t[i...].firstIndex(of: "}") {
                let token = String(t[t.index(after: i)..<close])
                if let value = values[token] {
                    out += value
                    i = t.index(after: close)
                    continue
                }
            }
            out.append(t[i])
            i = t.index(after: i)
        }
        return out
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
