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
    static let helperVersion = "1.8.0"
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
