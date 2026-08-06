// HelperProtocol.swift
// XPC Protocol shared between main app and privileged helper.

import Foundation

/// The bundle ID for the privileged helper tool
let kHelperToolMachServiceName = "com.geiserx.vpnbypass.helper"

/// Protocol for the helper tool - defines what privileged operations it can perform
@objc(HelperProtocol)
protocol HelperProtocol {
    
    /// Add a route to bypass VPN
    /// - Parameters:
    ///   - destination: IP address or CIDR range
    ///   - gateway: Gateway to route through
    ///   - isNetwork: Whether destination is a network (CIDR) or host
    ///   - reply: Callback with success status and optional error message
    func addRoute(
        destination: String,
        gateway: String,
        isNetwork: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    
    /// Remove a route
    /// - Parameters:
    ///   - destination: IP address or CIDR range to remove
    ///   - reply: Callback with success status and optional error message
    func removeRoute(
        destination: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    
    /// Add multiple routes in batch (faster for startup/VPN connect)
    /// - Parameters:
    ///   - routes: Array of dictionaries with "destination", "gateway", and "isNetwork" keys
    ///   - reply: Callback with success count, failure count, failed destinations, and optional error message
    func addRoutesBatch(
        routes: [[String: Any]],
        withReply reply: @escaping (Int, Int, [String], String?) -> Void
    )

    /// Remove multiple routes in batch (faster for cleanup/VPN disconnect)
    /// - Parameters:
    ///   - destinations: Array of IP addresses or CIDR ranges to remove
    ///   - reply: Callback with success count, failure count, failed destinations, and optional error message
    func removeRoutesBatch(
        destinations: [String],
        withReply reply: @escaping (Int, Int, [String], String?) -> Void
    )
    
    /// Update the hosts file with VPN bypass entries
    /// - Parameters:
    ///   - entries: Array of dictionaries with "domain" and "ip" keys
    ///   - reply: Callback with success status and optional error message
    func updateHostsFile(
        entries: [[String: String]],
        withReply reply: @escaping (Bool, String?) -> Void
    )
    
    /// Flush DNS cache after hosts file changes
    /// - Parameter reply: Callback with success status
    func flushDNSCache(withReply reply: @escaping (Bool) -> Void)
    
    /// Get the installed helper version
    /// - Parameter reply: Callback with version string
    func getVersion(withReply reply: @escaping (String) -> Void)
}

// MARK: - Helper Constants

struct HelperConstants {
    // 1.6.0: helper pins the installing app's cdhash (Helper/HelperTool.swift) so a
    // locally forged binary that merely claims our identifier under ad-hoc signing can
    // no longer drive the root helper. Bumped from 1.5.0 so installed helpers update.
    // 1.7.0: helper verifies XPC callers by the kernel AUDIT TOKEN instead of the reusable,
    // race-prone PID (closes a PID-reuse window where a forged process could momentarily
    // impersonate the app). This code shipped in app 3.1.0 but helperVersion was NOT bumped,
    // so installed 1.6.0 helpers never reinstalled and never received it; bumping to 1.7.0
    // makes existing installs detect the mismatch, reinstall, and actually get the hardening.
    // 1.8.0: helper is FAIL-CLOSED on the cdhash pin — it REJECTS every caller when the
    // pin is absent/malformed instead of falling back to the (forgeable under ad-hoc
    // signing) identifier-only requirement. To keep that from bricking the real app, the
    // installer now GUARANTEES the pin (modern path verifies it and falls back to the
    // atomic legacy install; legacy fails rather than install pin-less), and readiness
    // self-heals a missing/stale pin by reinstalling. Bumped from 1.7.0 so existing
    // (possibly pin-less, identifier-only) helpers detect the mismatch and reinstall to
    // the fail-closed + guaranteed-pin build.
    // 1.10.0: the helper now READS before it writes (#65). Callers re-apply the same route set
    // constantly (DNS refresh, failed-domain retries, status passes); 1.9.0 still issued a
    // `route change` for every one of those, and every write is a kernel route-change event that
    // other VPN clients react to by re-validating their tunnel. installRoute now asks
    // `route -n get` first and returns success WITHOUT writing when the route is already correct,
    // so steady state costs zero mutations. Every mutation path also logs now — 1.9.0 logged only
    // batches and failures, which hid per-route churn completely.
    // 1.9.0: the helper no longer issues a blind `route delete` before every `route add` (#65).
    // That cost two kernel mutations per route even when the route was already correct, and it
    // briefly REMOVED the route — every mutation raises a kernel route-change event, and
    // GlobalProtect re-validates its gateway route on each one, tearing down its tunnel when the
    // lookup transiently fails. It now changes-in-place, adds only when nothing was there, and
    // replaces only as a last resort. Route/hosts mutations are also serialised across XPC
    // connections (concurrent handlers were producing simultaneous /sbin/route processes), and the
    // helper finally emits os_log records. Bumped from 1.8.0 so installed helpers pick this up.
    static let helperVersion = "1.10.0"
    static let bundleID = "com.geiserx.vpnbypass.helper"
    static let hostMarkerStart = "# VPN-BYPASS-MANAGED - START"
    static let hostMarkerEnd = "# VPN-BYPASS-MANAGED - END"

    /// The main app's code-signing identifier (ad-hoc). Under ad-hoc signing this string
    /// alone is forgeable (`codesign -s - -i com.geiserx.vpn-bypass`), so as of 1.8.0 the
    /// helper requires this identifier AND the pinned cdhash below — never the identifier
    /// alone. See HelperAuthPolicy.
    static let appSigningIdentifier = "com.geiserx.vpn-bypass"

    /// Root-only file (root:wheel 644) holding the installing app's cdhash as lowercase
    /// hex. Written in the SAME admin operation that installs/updates the helper, read
    /// per-connection by the helper's caller check. As of 1.8.0 this pin is MANDATORY:
    /// absent/!valid-hex ⇒ the helper rejects the caller (fail-closed), and the installer
    /// guarantees the pin so a correctly-installed helper always has it. A missing/stale
    /// pin is recovered by reinstall (readiness gate), never accepted as identifier-only.
    static let cdhashPinPath = "/Library/PrivilegedHelperTools/com.geiserx.vpnbypass.helper.cdhash"
}

// MARK: - Helper Authorization Policy (pure, testable seam)

/// Pure authorization-policy decisions for the privileged helper. Lives in this file on
/// purpose: `HelperProtocol.swift` is the ONE source file compiled BOTH into the standalone
/// helper binary (`make build-helper` uses an explicit file list) AND into the VPNBypassCore
/// module, so the helper can enforce these decisions and the test target can exercise them
/// without duplicating logic or touching the helper build's file list.
enum HelperAuthPolicy {

    /// The code-signing requirement the helper must enforce on an XPC caller, or `nil` when
    /// the caller MUST be rejected outright.
    ///
    /// FAIL-CLOSED: under ad-hoc signing the `identifier` predicate alone is forgeable by any
    /// local binary, so identifier-only is NOT a safe authorization. When the root-only cdhash
    /// pin is absent/malformed (`pinnedCDHash == nil`) this returns `nil` → the helper rejects
    /// the caller rather than accepting a forgeable identity. When the pin is present it binds
    /// to it — `identifier "<id>" and cdhash H"<pin>"` — which a forged binary cannot
    /// reproduce. The installer guarantees the pin (see HelperManager), so a correctly
    /// installed helper always has one and the real app is never rejected.
    static func requirementString(pinnedCDHash: String?, appSigningIdentifier: String) -> String? {
        guard let pin = pinnedCDHash else { return nil }
        return "identifier \"\(appSigningIdentifier)\" and cdhash H\"\(pin)\""
    }

    /// Validate raw pin-file contents into a canonical lowercase-hex cdhash, or `nil` if the
    /// content isn't a whole cdhash. `kSecCodeInfoUnique` is a 20-byte code-directory hash
    /// (40 hex chars); the SHA-256 form is 32 bytes (64 hex). A partial/truncated write
    /// (e.g. "ab") is even-length valid hex but is not a real cdhash, so treat it as "no
    /// valid pin" — under the fail-closed model the helper then rejects (and the readiness
    /// gate reinstalls to restore a good pin) rather than pinning an unsatisfiable value.
    static func validatedCDHash(fromRawPinFileContents raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isValidCDHash = (trimmed.count == 40 || trimmed.count == 64)
            && trimmed.allSatisfy { $0.isHexDigit }
        return isValidCDHash ? trimmed : nil
    }
}

/// CIDR helpers shared by the app and the privileged helper.
///
/// These live here, rather than in `HelperTool.swift`, specifically so they are testable: the helper
/// target is a root LaunchDaemon that is never linked into the test bundle, whereas this file is
/// compiled into both. The helper's `routeAlreadyCorrect` depends on getting these exactly right —
/// a wrong netmask makes it skip a route write that was genuinely needed, which is silent.
public enum RouteCIDR {
    /// Split `"10.0.0.0/8"` into `("10.0.0.0", 8)`. Returns nil for anything that is not a
    /// well-formed IPv4 CIDR with a canonical, in-range prefix.
    public static func parse(_ cidr: String) -> (network: String, prefixLength: Int)? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let network = String(parts[0])
        let prefixText = String(parts[1])
        // Reject non-canonical forms ("08", "+8") so they can never round-trip to a different value
        // than the one the caller believes it asked for.
        guard let prefix = Int(prefixText), String(prefix) == prefixText, (0...32).contains(prefix) else { return nil }
        let octets = network.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        for octet in octets {
            guard let value = Int(octet), String(value) == octet, (0...255).contains(value) else { return nil }
        }
        return (network, prefix)
    }

    /// Expand a prefix length into the dotted netmask `route(8)` prints, e.g. 1 -> "128.0.0.0",
    /// 8 -> "255.0.0.0", 24 -> "255.255.255.0". A /0 is reported by `route` as "default", not
    /// "0.0.0.0", so it is returned as such to match what we would be comparing against.
    public static func netmaskString(prefixLength: Int) -> String {
        guard (1...32).contains(prefixLength) else { return "default" }
        let mask = UInt32.max << (32 - UInt32(prefixLength))
        return "\((mask >> 24) & 0xFF).\((mask >> 16) & 0xFF).\((mask >> 8) & 0xFF).\(mask & 0xFF)"
    }
}
