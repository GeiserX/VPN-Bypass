// TunnelOwnership.swift
// Ask the OS which process owns a tunnel, instead of guessing from its address.
//
// A `utun` is created by opening a kernel control socket named `com.apple.net.utun_control`,
// and the process that opened it holds that descriptor for the tunnel's whole life. macOS will
// tell us who that is: `proc_pidfdinfo(..., PROC_PIDFDSOCKETINFO)` returns `SOCKINFO_KERN_CTL`
// carrying the control name and its unit. That is an exact answer with no vendor knowledge, no
// CLI, and no network call — where an address is only ever a guess, because CGNAT 100.64/10 is
// shared ground between Tailscale, NetBird, Netmaker, Twingate, Zscaler and Cloudflare WARP.
//
// It has to run as root. Every VPN daemon that matters runs as uid 0, and an unprivileged
// caller cannot read their descriptor lists — measured at 206/783 and 322/725 processes denied
// on two machines, with every VPN tunnel in the denied set. So the sweep lives in the helper.

import Foundation
import Darwin

/// One tunnel and the process that created it.
public struct TunnelOwner: Equatable {
    public let interface: String
    public let pid: Int32
    public let processName: String
    public let executablePath: String

    public init(interface: String, pid: Int32, processName: String, executablePath: String) {
        self.interface = interface
        self.pid = pid
        self.processName = processName
        self.executablePath = executablePath
    }

    /// XPC carries plists, not Swift structs.
    public var asDictionary: [String: String] {
        ["interface": interface, "pid": String(pid),
         "processName": processName, "executablePath": executablePath]
    }

    public init?(dictionary d: [String: String]) {
        guard let interface = d["interface"], let pidText = d["pid"], let pid = Int32(pidText),
              let processName = d["processName"] else { return nil }
        self.init(interface: interface, pid: pid, processName: processName,
                  executablePath: d["executablePath"] ?? "")
    }
}

public enum TunnelOwnership {

    // MARK: - Pure decisions

    /// Kernel control unit `N` is interface `utun(N-1)`.
    ///
    /// Unit numbering is 1-based because unit 0 means "kernel, pick one for me"; interface
    /// numbering is 0-based. Verified on real hardware rather than inferred: a process that
    /// creates a utun and reads its own name back via `getsockopt(UTUN_OPT_IFNAME)` reported
    /// `utun5` while this map saw its control unit as 6.
    public static func interfaceName(forControlUnit unit: UInt32) -> String? {
        guard unit >= 1 else { return nil }
        return "utun\(unit - 1)"
    }

    /// Processes that hold a tunnel's control socket without being the thing that made it.
    ///
    /// `nesessionmanager` is the NetworkExtension broker: it holds the same control unit as the
    /// extension it started, so a tunnel legitimately has more than one holder. Observed on two
    /// machines, where unit 3 was held by both Tailscale's network extension and this broker.
    /// Attributing a tunnel to the broker would label every NE-based VPN identically.
    public static let brokerProcessNames: Set<String> = ["nesessionmanager", "neagent"]

    /// Collapse raw `(unit, pid, name, path)` rows into one owner per interface.
    ///
    /// Brokers are dropped first. If that leaves nothing, the broker is kept rather than losing
    /// the tunnel entirely — knowing a tunnel exists is worth more than knowing nothing. Ties
    /// among real owners resolve to the lowest pid, so repeated calls agree with each other.
    public static func resolve(
        _ rows: [(unit: UInt32, pid: Int32, processName: String, executablePath: String)]
    ) -> [String: TunnelOwner] {
        var byInterface: [String: [(pid: Int32, name: String, path: String)]] = [:]
        for row in rows {
            guard let iface = interfaceName(forControlUnit: row.unit) else { continue }
            byInterface[iface, default: []].append((row.pid, row.processName, row.executablePath))
        }

        var out: [String: TunnelOwner] = [:]
        for (iface, holders) in byInterface {
            let real = holders.filter { !brokerProcessNames.contains($0.name) }
            let pick = (real.isEmpty ? holders : real).min { $0.pid < $1.pid }
            guard let pick else { continue }
            out[iface] = TunnelOwner(interface: iface, pid: pick.pid,
                                     processName: pick.name, executablePath: pick.path)
        }
        return out
    }

    /// A human product name for an owning process, or nil when we have nothing better to say
    /// than the process name itself.
    ///
    /// Matching is on the OWNER, which is a much stronger signal than the loose scan of the
    /// whole process table it replaces: that one matched any command line containing
    /// "cloudflare", so `cloudflared` — a common tunnel daemon that is not WARP — was reported
    /// as Cloudflare WARP. Here the process being tested is the one holding the tunnel.
    public static func productLabel(processName: String, executablePath: String) -> String? {
        let haystack = (processName + " " + executablePath).lowercased()
        // Ordered: the first match wins, so put the specific before the generic.
        let table: [(needle: String, label: String)] = [
            ("io.tailscale", "Tailscale"),
            ("tailscaled", "Tailscale"),
            ("tailscale", "Tailscale"),
            ("netbird", "NetBird"),
            ("netmaker", "Netmaker"),
            ("netclient", "Netmaker"),
            ("twingate", "Twingate"),
            ("zerotier", "ZeroTier"),
            ("pangps", "GlobalProtect"),
            ("pangpa", "GlobalProtect"),
            ("globalprotect", "GlobalProtect"),
            ("anyconnect", "Cisco AnyConnect"),
            ("vpnagent", "Cisco AnyConnect"),
            ("secureclient", "Cisco AnyConnect"),
            ("forticlient", "Fortinet FortiClient"),
            ("zscaler", "Zscaler"),
            ("warp-svc", "Cloudflare WARP"),
            ("cloudflarewarp", "Cloudflare WARP"),
            ("openvpn", "OpenVPN"),
            ("wireguard", "WireGuard"),
            ("wg-go", "WireGuard"),
            ("mullvad", "Mullvad"),
            ("nordvpn", "NordVPN"),
            ("protonvpn", "Proton VPN"),
            ("expressvpn", "ExpressVPN"),
            ("pulsesecure", "Pulse Secure"),
            ("endpoint_security_vpn", "Check Point"),
        ]
        for entry in table where haystack.contains(entry.needle) { return entry.label }
        return nil
    }

    /// What to show for a tunnel: the product name when we recognise the owner, otherwise the
    /// owning process's own name, which is still far better than "VPN (utun7)".
    public static func displayLabel(for owner: TunnelOwner) -> String {
        if let product = productLabel(processName: owner.processName,
                                      executablePath: owner.executablePath) {
            return product
        }
        let base = (owner.processName as NSString).lastPathComponent
        return base.isEmpty ? "VPN (\(owner.interface))" : base
    }

    // MARK: - The privileged sweep

    /// Every `utun` on the machine with the process that created it.
    ///
    /// Returns only what the caller is allowed to see, so an unprivileged caller gets a short,
    /// misleading list rather than an error — which is exactly why this belongs in the helper.
    /// Costs 1.7–3.0 ms across ~750 processes on Apple silicon.
    public static func sweep() -> [TunnelOwner] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        // Processes come and go between sizing and reading; over-allocate so a burst of new
        // ones cannot truncate the list.
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = pids.withUnsafeMutableBufferPointer { buf in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress,
                          Int32(capacity * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        let count = min(Int(filled) / MemoryLayout<pid_t>.size, capacity)

        var rows: [(unit: UInt32, pid: Int32, processName: String, executablePath: String)] = []
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            let fdSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdSize > 0 else { continue }          // exited, or not ours to read
            let fdCapacity = Int(fdSize) + MemoryLayout<proc_fdinfo>.size * 32
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCapacity / MemoryLayout<proc_fdinfo>.size)
            let fdFilled = fds.withUnsafeMutableBufferPointer { buf in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(fdCapacity))
            }
            guard fdFilled > 0 else { continue }
            let fdCount = min(Int(fdFilled) / MemoryLayout<proc_fdinfo>.size, fds.count)

            for fdIndex in 0..<fdCount {
                guard fds[fdIndex].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                let read = proc_pidfdinfo(pid, fds[fdIndex].proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
                guard read == size, info.psi.soi_kind == SOCKINFO_KERN_CTL else { continue }
                var kctl = info.psi.soi_proto.pri_kern_ctl
                let name = withUnsafeBytes(of: &kctl.kcsi_name) { raw -> String in
                    let bytes = raw.bindMemory(to: CChar.self)
                    guard let base = bytes.baseAddress else { return "" }
                    return String(cString: base)
                }
                guard name == "com.apple.net.utun_control" else { continue }
                rows.append((unit: kctl.kcsi_unit, pid: pid,
                             processName: processName(of: pid), executablePath: executablePath(of: pid)))
            }
        }
        return resolve(rows).values.sorted { $0.interface < $1.interface }
    }

    private static func processName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        return written > 0 ? String(cString: buffer) : ""
    }

    private static func executablePath(of pid: pid_t) -> String {
        // PROC_PIDPATHINFO_MAXSIZE is a macro, so it does not survive into Swift; 4×PATH_MAX
        // is what the header defines it as.
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return written > 0 ? String(cString: buffer) : ""
    }
}
