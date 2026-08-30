// HelperProtocol.swift
// XPC Protocol shared between main app and privileged helper.

import Darwin
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

    /// Every `utun` on the machine with the process that created it, as plist dictionaries.
    ///
    /// Read-only and privileged for one reason: the descriptor lists of root-owned VPN daemons
    /// are unreadable to the app, which runs as the user. Measured on two machines, an
    /// unprivileged sweep sees only Apple's own tunnels and never Tailscale, GlobalProtect or a
    /// mesh VPN — the exact ones we need to name.
    /// - Parameter reply: `(true, rows)` when the sweep ran — `rows` may legitimately be empty
    ///   on a machine with no tunnels. The flag exists so a caller can tell that apart from
    ///   "could not ask", which matters because utun numbers are recycled: keeping a stale map
    ///   would paint a departed tunnel's label onto whatever claims its number next.
    func listTunnelOwners(withReply reply: @escaping (Bool, [[String: String]]) -> Void)
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
    // 1.11.0: fixes a way the 1.10.0 read-before-write check could skip a route it should have
    // written. It ignored `flags:` entirely, so a kernel-CLONED route (the default route carries
    // PRCLONING, so macOS mints ephemeral host routes inheriting the parent's gateway) echoed back
    // our exact destination with a matching gateway and was accepted as "already correct" — we
    // skipped the write, recorded the route as applied, and the clone then expired. Silent. It now
    // rejects WASCLONED/REJECT/BLACKHOLE and requires the matched route to be the KIND being
    // installed. Network routes are no longer excluded from the check either (they were, so VPN
    // Only rewrote both catch-alls on every apply). Also bounds the wait on every `route`
    // subprocess — since 1.9.0 one wedged child would block the whole serial mutation queue for the
    // life of the daemon — and rejects /0 at the privileged boundary, which the app already did.
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
    // 2.1.0: kernel writes are PACED (RouteKernel.WritePacer). Every RTM write is broadcast to
    // every open routing socket and the kernel silently drops messages for a full receive
    // buffer, so an uninterrupted several-hundred-message batch could swallow the reply of a
    // concurrent `route -n get` — observed as GlobalProtect's gateway-route read timing out
    // seconds after our batch and tearing the tunnel down. A 200ms pause every 32 writes keeps
    // any listener's backlog under one buffer. Bumped so installed helpers pick this up.
    // 2.1.1: flushDNSCache bounds dscacheutil / killall -HUP mDNSResponder (3s each) instead
    // of waitUntilExit() with no deadline. A wedged child used to park the XPC thread for
    // the life of the daemon after the app had already dropped the 30s hosts-update
    // connection. Bumped so installed 2.1.0 helpers reinstall and pick this up.
    static let helperVersion = "2.2.0"
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


/// Parses `networksetup -listnetworkserviceorder` into the ordered list of enabled service names.
///
/// Lives here (compiled into both targets) so it is unit-testable.
///
/// Why this exists: gateway detection used to try a HARDCODED list of service names — "Wi-Fi",
/// "Ethernet", "USB 10/100/1000 LAN", "Thunderbolt Ethernet", "USB-C LAN". Any Mac whose active
/// link is named something else (docks in particular: "USB3.0 5K Graphic Docking", "Dell Universal
/// Dock D6000") matched nothing, so detection fell through to `route -n get default` — which, once
/// a VPN is connected, returns the VPN's OWN tunnel gateway. Every "bypass" route was then
/// installed pointing INTO the tunnel, and every VPN state change moved the gateway and triggered a
/// full re-apply. Enumerating the real services removes the guesswork.
public enum NetworkServiceOrder {
    /// Service names in the order macOS will use them. Disabled services (prefixed `*`) are skipped.
    ///
    /// Expected input lines look like:
    ///   `(1) Wi-Fi`
    ///   `(Hardware Port: Wi-Fi, Device: en0)`
    ///   `(*2) Thunderbolt Bridge`      <- disabled
    public static func parse(_ output: String) -> [String] {
        var services: [String] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Only the numbered heading lines name a service; the "(Hardware Port: …)" lines do not.
            guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { continue }
            let tag = String(line[line.index(after: line.startIndex)..<close])
            // Skip disabled services, which macOS marks with a leading asterisk.
            guard !tag.hasPrefix("*"), Int(tag) != nil else { continue }
            let name = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { services.append(name) }
        }
        return services
    }
}

/// Destinations this app must NEVER install, change, or delete, because they belong to other
/// networking software sharing the machine — or to the kernel itself.
///
/// Enforced at the privileged boundary (the root daemon), deliberately: the helper must be the
/// strictest layer, never the most permissive. Whatever the app asks for, these are refused.
///
/// The motivating case is Tailscale. It runs alongside this app in mesh mode, owns `100.64.0.0/10`
/// and answers DNS on `100.100.100.100`. Nothing previously stopped a route for either from being
/// written: a user CIDR of exactly `100.64.0.0/10` in VPN Only would reach `route change -net`,
/// match on destination, and silently repoint Tailscale's own route into the corporate tunnel —
/// and teardown would then delete it outright. Mesh networking would break with no indication that
/// this app was responsible.
///
/// Note this is the UNCONDITIONAL list only. Individual host routes that merely fall inside CGNAT
/// are a policy question for the app layer, which knows whether Tailscale is actually running;
/// blocking them here would break legitimate Zscaler/WARP setups that share the same range.
public enum ProtectedDestinations {
    /// Tailscale's CGNAT range. A destination equal to it, or covering it, is refused.
    public static let tailscaleCGNAT = (network: "100.64.0.0", prefix: 10)
    /// Tailscale MagicDNS.
    public static let magicDNS = "100.100.100.100"

    public static func isProtected(_ destination: String) -> Bool {
        let d = destination.trimmingCharacters(in: .whitespaces)

        // MagicDNS, in host or /32 form.
        if d == magicDNS || d == "\(magicDNS)/32" { return true }

        if let (network, prefix) = RouteCIDR.parse(d) {
            // The tailnet range itself, or any prefix that COVERS it — a shorter prefix on the same
            // network wins longest-prefix match against Tailscale's own route just as surely.
            if network == tailscaleCGNAT.network && prefix <= tailscaleCGNAT.prefix { return true }
            // Kernel-reserved space nothing here should ever route.
            if network == "127.0.0.0" { return true }
            if network == "169.254.0.0" { return true }
            if network == "224.0.0.0" { return true }
        }

        // Host forms of the same reserved space.
        if d.hasPrefix("127.") || d.hasPrefix("169.254.") { return true }
        if d == "255.255.255.255" { return true }

        return false
    }
}

// MARK: - VPN interface selection

/// One tunnel considered as "the VPN", with everything the choice depends on already resolved.
public struct VPNCandidate: Equatable, Sendable {
    public let interface: String
    public let isUp: Bool
    public let isTunnel: Bool
    /// The address looks like a corporate VPN address (see `isCorporateVPNIP`).
    public let isCorporateAddress: Bool
    /// This is Tailscale's own utun.
    public let isTailscale: Bool

    public init(interface: String, isUp: Bool, isTunnel: Bool,
                isCorporateAddress: Bool, isTailscale: Bool) {
        self.interface = interface
        self.isUp = isUp
        self.isTunnel = isTunnel
        self.isCorporateAddress = isCorporateAddress
        self.isTailscale = isTailscale
    }
}

/// Chooses which tunnel is "the VPN" when several are up at once.
///
/// This has to be deliberate because more than one tunnel is the normal case, not the exception:
/// a corporate client and Tailscale routinely run together, and a Mac can easily show nine utun
/// interfaces. Selection used to be "first match in `ifconfig` order", which is neither
/// deterministic nor related to which tunnel carries traffic — and since Tailscale's utun usually
/// sorts BEFORE a corporate client's, Tailscale won that race whenever an exit node made it look
/// like a VPN. The consequence in VPN Only mode is a leak: the catch-alls are installed to escape
/// the tunnel the app selected, sending the OTHER tunnel's corporate traffic direct.
public enum VPNInterfaceSelector {

    public static func select(candidates: [VPNCandidate],
                              defaultRouteInterface: String?,
                              current: String?,
                              pinnedInterface: String? = nil) -> String? {
        // Tailscale is excluded outright. In mesh mode it is not a VPN at all, and as an exit node
        // it has its own egress route type — it must never become the tunnel whose traffic the app
        // reroutes, because doing so silently changes what a corporate VPN policy applies to.
        let eligible = candidates.filter {
            $0.isUp && $0.isTunnel && $0.isCorporateAddress && !$0.isTailscale
        }
        guard !eligible.isEmpty else { return nil }

        // 0. A user pin CONSTRAINS the choice — it never invents one. If the pinned tunnel is
        //    eligible right now, it wins outright; if it is absent or ineligible, selection
        //    falls through to the automatic rules below (the caller logs the disagreement).
        //    Failing open here is deliberate: a stale pin must degrade to today's automatic
        //    behaviour, not silently disable the app.
        if let pinnedInterface,
           let pinned = eligible.first(where: { $0.interface == pinnedInterface }) {
            return pinned.interface
        }

        // 1. Ground truth. The tunnel carrying the default route is the one actually moving
        //    traffic; no heuristic beats observing it. A change here is a real change worth acting
        //    on, so this deliberately outranks hysteresis.
        if let defaultRouteInterface,
           eligible.contains(where: { $0.interface == defaultRouteInterface }) {
            return defaultRouteInterface
        }

        // 2. Hysteresis. With the default route on neither tunnel (split tunnel — the common case
        //    for GlobalProtect), several candidates stay equally valid indefinitely. Keeping the
        //    existing choice is what stops the selection oscillating, and an oscillating selection
        //    is not cosmetic: every flip is read as an interface change and re-issues the entire
        //    route set, which is the feedback loop that destabilises the tunnel.
        if let current, eligible.contains(where: { $0.interface == current }) {
            return current
        }

        // 3. Deterministic tie-break, so two machines in the same state make the same choice and a
        //    restart does not silently pick differently.
        return eligible.map(\.interface).min(by: interfaceOrdersBefore)
    }

    /// Orders interfaces by NUMERIC suffix, not lexically — "utun10" must sort after "utun9",
    /// which plain string comparison gets backwards.
    static func interfaceOrdersBefore(_ a: String, _ b: String) -> Bool {
        let sa = numericSuffix(a), sb = numericSuffix(b)
        if let sa, let sb, sa != sb { return sa < sb }
        let pa = a.prefix(while: { !$0.isNumber }), pb = b.prefix(while: { !$0.isNumber })
        if pa != pb { return pa < pb }
        return a < b
    }

    static func numericSuffix(_ s: String) -> Int? {
        let digits = s.drop(while: { !$0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The interface the default route exits through, from `route -n get default` output.
    /// Pure so it can be tested without a routing table.
    public static func parseDefaultRouteInterface(_ routeOutput: String) -> String? {
        for line in routeOutput.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                let v = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}

// MARK: - Process deadline (pure, testable seam)

/// Bounded wait around `Foundation.Process`. Lives in this file so the helper
/// binary (`make build-helper` compiles this source) and the test target share
/// one implementation (same reason as `HelperAuthPolicy` / `RouteCIDR`).
///
/// The app already bounds every subprocess via `DNSResolver.runProcessSyncSafe`.
/// The privileged helper's DNS flush still used unbounded `waitUntilExit()`.
enum ProcessDeadline {
    /// Long enough for `dscacheutil -flushcache` / `killall -HUP mDNSResponder`
    /// on a healthy box; short enough that two sequential flushes stay well
    /// under the app's 30s hosts-update XPC deadline.
    static let defaultSeconds: TimeInterval = 3

    /// How `run` finished. Distinguishes a timely exit (with status) from a
    /// start failure or a kill, so the helper can log nonzero exits.
    enum Outcome: Equatable {
        case failedToStart
        case timedOut
        case exited(Int32)
    }

    /// Launch `process` and wait up to `seconds`. Deadlines use `DispatchTime`
    /// (monotonic) so a wall-clock step backward cannot stretch the wait.
    @discardableResult
    static func run(_ process: Process, seconds: TimeInterval = defaultSeconds) -> Outcome {
        do {
            try process.run()
        } catch {
            return .failedToStart
        }
        // Same 10ms poll as `DNSResolver.runProcessSyncSafe`: a nested GCD
        // semaphore on the helper's XPC thread has deadlocked this process
        // runner before; a deadline loop does not.
        waitUntilNotRunning(process, seconds: seconds)
        if process.isRunning {
            process.terminate()
            waitUntilNotRunning(process, seconds: 1)
            if process.isRunning {
                // SIGTERM is ignorable. A wedged dscacheutil that ignored it
                // would recreate the original hang on waitUntilExit.
                kill(process.processIdentifier, SIGKILL)
                waitUntilNotRunning(process, seconds: 0.5)
            }
            return .timedOut
        }
        return .exited(process.terminationStatus)
    }

    @discardableResult
    static func run(path: String, arguments: [String] = [], seconds: TimeInterval = defaultSeconds) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return run(process, seconds: seconds)
    }

    /// Poll `isRunning` until the child exits or `seconds` of monotonic
    /// time elapse. Never uses `Date()`, which can move backward.
    private static func waitUntilNotRunning(_ process: Process, seconds: TimeInterval) {
        let ns = max(0, seconds) * 1_000_000_000
        let deadline = DispatchTime.now() + .nanoseconds(Int(ns.rounded()))
        while process.isRunning && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
