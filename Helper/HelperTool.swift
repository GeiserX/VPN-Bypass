// HelperTool.swift
// Privileged helper tool implementation that runs as root.

import Foundation
import os.log

/// Structured logging for the privileged helper. Until now the helper logged nothing at all, so a
/// root daemon that owns the routing table left no record of which routes it wrote or which callers
/// it rejected. Read with:
///   log stream --predicate 'subsystem == "com.geiserx.vpnbypass.helper"' --info
/// Destinations/gateways are route data the caller already supplied; no credentials pass through here.
let helperLog = Logger(subsystem: "com.geiserx.vpnbypass.helper", category: "routes")

// MARK: - XPC Listener Delegate

class HelperToolDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Verify the connecting process is the real VPN Bypass app (by kernel audit token — race-free).
        guard verifyCaller(newConnection) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperTool()

        newConnection.invalidationHandler = {
            // Connection was invalidated
        }

        newConnection.interruptionHandler = {
            // Connection was interrupted
        }

        newConnection.resume()
        return true
    }

    /// Verify the calling process is the real VPN Bypass app.
    ///
    /// Prefer the connection's kernel-issued AUDIT TOKEN (`kSecGuestAttributeAudit`): it names the
    /// exact process on the other end and cannot be reused mid-connection. Validating by PID
    /// instead is subject to a PID-reuse race — a local process can grab the app's recycled PID in
    /// the window between exit and this check, so the helper's "who is PID X?" question is answered
    /// by the wrong process, satisfying even the pinned cdhash. The audit token closes that race.
    ///
    /// Anti-brick: if no usable audit token is present (it always is on a live XPC connection) we
    /// fall back to the previous PID check, so a missing/removed private API can never lock out the
    /// real app. See Helper/NSXPCConnection+AuditToken.h.
    private func verifyCaller(_ connection: NSXPCConnection) -> Bool {
        var token = connection.auditToken
        let tokenIsZero = withUnsafeBytes(of: token) { $0.allSatisfy { $0 == 0 } }
        if !tokenIsZero {
            let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
            return verifyCallerCode(attribute: kSecGuestAttributeAudit, value: tokenData as CFData)
        }
        return verifyCallerCode(attribute: kSecGuestAttributePid, value: connection.processIdentifier as CFNumber)
    }

    /// Build the caller's `SecCode` from a guest attribute (audit token or PID) and check it against
    /// our authorization requirement. Under ad-hoc signing the signing identifier alone is forgeable
    /// by any local binary (`codesign -s - -i com.geiserx.vpn-bypass /tmp/evil`), so identifier-only
    /// is NOT sufficient — HelperAuthPolicy binds the requirement to the root-only pinned cdhash,
    /// which a forged binary cannot reproduce.
    ///
    /// FAIL-CLOSED (1.8.0): when the pin is absent/malformed, `HelperAuthPolicy.requirementString`
    /// returns nil and we REJECT the caller rather than falling back to the forgeable identifier-only
    /// requirement. Anti-brick invariant: this cannot lock out the real app because the installer
    /// GUARANTEES a matching pin at install time and the readiness gate self-heals a missing/stale
    /// pin by reinstalling (see HelperManager). A correctly installed helper always has a matching
    /// pin, so only forged/unauthorized callers are rejected.
    private func verifyCallerCode(attribute: CFString, value: CFTypeRef) -> Bool {
        var code: SecCode?
        let attrs = [attribute: value] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let callerCode = code else {
            return false
        }

        // No valid pin ⇒ reject (fail-closed). Never fall back to identifier-only.
        guard let requirementString = HelperAuthPolicy.requirementString(
            pinnedCDHash: Self.readPinnedCDHash(),
            appSigningIdentifier: HelperConstants.appSigningIdentifier
        ) else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }

        return SecCodeCheckValidity(callerCode, [], req) == errSecSuccess
    }

    /// The pinned app cdhash (lowercase hex) if the root-only pin file holds a well-formed
    /// value, else nil. Validation is delegated to the shared, testable
    /// `HelperAuthPolicy.validatedCDHash` so the helper and the tests agree on exactly what
    /// counts as a valid pin (a whole 40- or 64-hex cdhash). Read fresh each call so a
    /// rewritten pin (app update) takes effect without restarting the helper. A nil result
    /// makes `verifyCallerCode` fail-closed (reject); because the installer and readiness
    /// gate guarantee a valid pin for the real app, nil means "no authorized caller present",
    /// not "brick the real app".
    private static func readPinnedCDHash() -> String? {
        guard let data = FileManager.default.contents(atPath: HelperConstants.cdhashPinPath),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return HelperAuthPolicy.validatedCDHash(fromRawPinFileContents: raw)
    }
}

// MARK: - Helper Tool Implementation

class HelperTool: NSObject, HelperProtocol {

    /// Serialises every route/hosts mutation across ALL XPC connections. `HelperToolDelegate`
    /// creates a fresh `HelperTool` per connection, and the app drops and recreates its connection
    /// on an XPC deadline, so without this two handlers could mutate the routing table at the same
    /// time — the condition behind the concurrent `/sbin/route` processes seen in #65.
    /// Deliberately NOT used by `getVersion`: that is the app's liveness probe, and queueing it
    /// behind a long batch would time it out and trigger a spurious helper reinstall.
    private static let routeQueue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.routes")

    // MARK: - Route Management

    func addRoute(destination: String, gateway: String, isNetwork: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        // Validate inputs
        guard isValidDestination(destination), isValidGateway(gateway) else {
            reply(false, "Invalid destination or gateway format")
            return
        }

        Self.routeQueue.async {
            let result = self.installRoute(destination: destination, gateway: gateway, isNetwork: isNetwork, snapshot: self.kernelSnapshot())
            reply(result.success, result.error)
        }
    }

    func removeRoute(destination: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard isValidDestination(destination) else {
            reply(false, "Invalid destination format")
            return
        }

        Self.routeQueue.async {
            let result = self.deleteRoute(destination: destination)
            if result.success {
                helperLog.info("delete \(destination, privacy: .public): removed")
            } else {
                helperLog.info("delete \(destination, privacy: .public) failed: \(result.error ?? "unknown", privacy: .public)")
            }
            reply(result.success, result.error)
        }
    }
    
    // MARK: - Batch Route Management (for startup/stop performance)
    
    func addRoutesBatch(routes: [[String: Any]], withReply reply: @escaping (Int, Int, [String], String?) -> Void) {
        Self.routeQueue.async {
            var successCount = 0
            var failureCount = 0
            var failedDestinations: [String] = []
            var lastError: String?

            // ONE silent table read for the whole batch — replaces a forked, event-emitting
            // `route -n get` per destination.
            let snapshot = self.kernelSnapshot()

            for route in routes {
                guard let destination = route["destination"] as? String,
                      let gateway = route["gateway"] as? String else {
                    failureCount += 1
                    continue
                }

                let isNetwork = route["isNetwork"] as? Bool ?? false

                // Validate inputs
                guard self.isValidDestination(destination), self.isValidGateway(gateway) else {
                    failureCount += 1
                    failedDestinations.append(destination)
                    continue
                }

                let result = self.installRoute(destination: destination, gateway: gateway, isNetwork: isNetwork, snapshot: snapshot)
                if result.success {
                    successCount += 1
                } else {
                    failureCount += 1
                    failedDestinations.append(destination)
                    lastError = result.error
                }
            }

            helperLog.info("addRoutesBatch: \(routes.count, privacy: .public) requested, \(successCount, privacy: .public) ok, \(failureCount, privacy: .public) failed")
            reply(successCount, failureCount, failedDestinations, lastError)
        }
    }

    func removeRoutesBatch(destinations: [String], withReply reply: @escaping (Int, Int, [String], String?) -> Void) {
        Self.routeQueue.async {
            var successCount = 0
            var failureCount = 0
            var failedDestinations: [String] = []
            var lastError: String?

            for destination in destinations {
                guard self.isValidDestination(destination) else {
                    failureCount += 1
                    failedDestinations.append(destination)
                    continue
                }

                let result = self.deleteRoute(destination: destination)
                if result.success {
                    successCount += 1
                } else {
                    failureCount += 1
                    failedDestinations.append(destination)
                    lastError = result.error
                }
            }

            helperLog.info("removeRoutesBatch: \(destinations.count, privacy: .public) requested, \(successCount, privacy: .public) removed, \(failureCount, privacy: .public) failed")
            reply(successCount, failureCount, failedDestinations, lastError)
        }
    }

    // MARK: - Routing-socket engine
    //
    // Every route mutation goes through ONE owned PF_ROUTE socket instead of forking
    // /sbin/route per operation. The fork/exec design was the traced root cause of the VPN
    // instability this helper used to trigger: each exec opens its own routing socket and
    // blocks with no timeout, and stacked execs starved other processes' route operations —
    // including the corporate VPN client's own periodic gateway-route READ, whose timeout it
    // misreads as "my gateway route was removed" and tears the tunnel down. A single socket
    // with one in-flight request makes that starvation structurally impossible: no processes,
    // errno straight from write(2), and reads replaced by a silent NET_RT_DUMP snapshot.

    private var routeSocketFD: Int32 = -1
    private var routeSeq: Int32 = 0
    /// Paces write bursts so other processes' routing sockets never overflow mid request/reply
    /// (a lost reply is what the corporate VPN client misreads as "gateway route removed" — see
    /// RouteKernel.WritePacer). Only ever touched on `routeQueue`, like the socket itself.
    private var writePacer = RouteKernel.WritePacer()

    /// Writes one routing message; returns nil on success or the errno on failure.
    private func routeSocketPerform(type: Int32, spec: RouteKernel.Spec) -> Int32? {
        if routeSocketFD < 0 {
            routeSocketFD = socket(PF_ROUTE, SOCK_RAW, 0)
            guard routeSocketFD >= 0 else { return errno }
            // Outcomes come from write(2)'s errno — nothing is ever read from this socket, and
            // an unread receive buffer on a long-lived routing socket would otherwise fill with
            // every other process's routing chatter.
            shutdown(routeSocketFD, SHUT_RD)
        }
        routeSeq &+= 1
        guard let msg = RouteKernel.message(type: type, seq: routeSeq, spec: spec) else {
            return EINVAL
        }
        let written = msg.withUnsafeBytes { raw in
            write(routeSocketFD, raw.baseAddress, raw.count)
        }
        // Failed writes are broadcast to listeners exactly like successful ones, so every
        // attempt counts toward the pacing budget.
        if writePacer.recordWrite(nowNS: DispatchTime.now().uptimeNanoseconds) {
            usleep(writePacer.pauseMicroseconds)
        }
        if written == msg.count { return nil }
        let err = errno
        if err == EBADF || err == EPIPE {
            // Socket itself is broken — reopen on the next call.
            close(routeSocketFD)
            routeSocketFD = -1
        }
        return err
    }

    private func errnoString(_ err: Int32) -> String {
        String(cString: strerror(err)) + " (errno \(err))"
    }

    /// Resolves the wire-format spec for a request. `iface:<name>` gateways become interface
    /// indices here — if the interface vanished, that is a normal failure, not a crash.
    private func specFor(destination: String, gateway: String, isNetwork: Bool) -> RouteKernel.Spec? {
        if gateway.hasPrefix("iface:") {
            let name = String(gateway.dropFirst(6))
            let index = if_nametoindex(name)
            guard index != 0 else { return nil }
            return RouteKernel.Spec(destination: destination,
                                    gateway: .interfaceIndex(UInt16(index)),
                                    isNetwork: isNetwork)
        }
        return RouteKernel.Spec(destination: destination,
                                gateway: .address(gateway),
                                isNetwork: isNetwork)
    }

    /// Snapshot of the live table, indexed by destination string, restricted to entries that
    /// could be "the route we would install": real static-kind entries, not kernel clones and
    /// not reject/blackhole placeholders. One silent sysctl replaces a `route -n get` fork —
    /// which also BROADCASTS a routing message to every listener — per destination.
    private func kernelSnapshot() -> [String: RouteKernel.KernelRoute] {
        guard let table = RouteKernel.currentTable() else { return [:] }
        var index: [String: RouteKernel.KernelRoute] = [:]
        for route in table {
            guard RouteKernel.isComparableEntry(route.flags) else { continue }
            index[route.destinationString] = route
        }
        return index
    }

    /// Whether the kernel entry already IS the route we want — same kind, same egress.
    /// Skipping the write on a match is what makes steady state cost zero kernel events.
    private func kernelRouteMatches(_ kernel: RouteKernel.KernelRoute, spec: RouteKernel.Spec) -> Bool {
        guard kernel.isHost == !spec.isNetwork else { return false }
        switch spec.gateway {
        case .address(let ip):
            return kernel.gatewayAddress != nil
                && RouteKernel.dotted(kernel.gatewayAddress!) == ip
        case .interfaceIndex(let index):
            return kernel.gatewayInterfaceIndex == index
        }
    }

    /// The snapshot key a spec's destination corresponds to.
    private func snapshotKey(destination: String, isNetwork: Bool) -> String {
        guard isNetwork, let (network, prefix) = RouteCIDR.parse(destination) else {
            return destination.hasSuffix("/32") ? String(destination.dropLast(3)) : destination
        }
        return "\(network)/\(prefix)"
    }


    /// Install one route via the routing socket, never opening a window where the destination
    /// has no route:
    ///   1. no-op — the snapshot says the kernel already has exactly this route (ZERO events;
    ///      this is what makes a restart against an already-correct kernel completely silent).
    ///   2. RTM_CHANGE — a different route exists for the destination: rewrite in place.
    ///   3. RTM_ADD — nothing exists for it.
    ///   4. cross-retry for the race in between: ADD refused with EEXIST → CHANGE.
    private func installRoute(destination: String, gateway: String, isNetwork: Bool,
                              snapshot: [String: RouteKernel.KernelRoute]) -> (success: Bool, error: String?) {
        guard let spec = specFor(destination: destination, gateway: gateway, isNetwork: isNetwork) else {
            return (false, "cannot resolve gateway \(gateway)")
        }
        let key = snapshotKey(destination: destination, isNetwork: isNetwork)
        if let current = snapshot[key] {
            if kernelRouteMatches(current, spec: spec) {
                helperLog.debug("install \(destination, privacy: .public): already correct, no mutation")
                return (true, nil)
            }
            // Route exists with a different egress — rewrite in place (one event, no gap).
            if routeSocketPerform(type: RTM_CHANGE, spec: spec) == nil {
                helperLog.info("install \(destination, privacy: .public): changed in place")
                return (true, nil)
            }
        }
        var err = routeSocketPerform(type: RTM_ADD, spec: spec)
        if err == nil {
            helperLog.info("install \(destination, privacy: .public): added")
            return (true, nil)
        }
        if err == EEXIST {
            // A route landed between the snapshot and the add — converge with a change.
            err = routeSocketPerform(type: RTM_CHANGE, spec: spec)
            if err == nil {
                helperLog.info("install \(destination, privacy: .public): raced, changed in place")
                return (true, nil)
            }
        }
        let message = errnoString(err ?? EINVAL)
        helperLog.error("install \(destination, privacy: .public) failed: \(message, privacy: .public)")
        return (false, message)
    }

    /// Remove one route. "Not in table" (ESRCH) is SUCCESS — the goal state is "absent", and
    /// treating an already-gone route as a failure made teardown retain phantom records.
    private func deleteRoute(destination: String) -> (success: Bool, error: String?) {
        let isNetwork = destination.contains("/") && !destination.hasSuffix("/32")
        let spec = RouteKernel.Spec(destination: destination, gateway: .address("0.0.0.0"),
                                    isNetwork: isNetwork)
        let err = routeSocketPerform(type: RTM_DELETE, spec: spec)
        if err == nil {
            helperLog.info("delete \(destination, privacy: .public): removed")
            return (true, nil)
        }
        if err == ESRCH {
            helperLog.info("delete \(destination, privacy: .public): already absent")
            return (true, nil)
        }
        let message = errnoString(err!)
        helperLog.error("delete \(destination, privacy: .public) failed: \(message, privacy: .public)")
        return (false, message)
    }

    // MARK: - Hosts File Management
    
    func updateHostsFile(entries: [[String: String]], withReply reply: @escaping (Bool, String?) -> Void) {
        // Serialised alongside route mutations on the same queue. This is a read-modify-write of
        // /etc/hosts, so without it two concurrent XPC connections could read the same content and
        // the later write would silently discard the earlier update.
        Self.routeQueue.async {
            let result = self.performHostsUpdate(entries: entries)
            reply(result.success, result.error)
        }
    }

    /// The /etc/hosts read-modify-write itself. Always call it on `routeQueue`.
    private func performHostsUpdate(entries: [[String: String]]) -> (success: Bool, error: String?) {
        let hostsPath = "/etc/hosts"

        // Read current hosts file
        guard let currentContent = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            return (false, "Could not read /etc/hosts")
        }
        
        // Remove existing VPN-BYPASS section
        var lines = currentContent.components(separatedBy: "\n")
        var inSection = false
        lines = lines.filter { line in
            if line.contains(HelperConstants.hostMarkerStart) {
                inSection = true
                return false
            }
            if line.contains(HelperConstants.hostMarkerEnd) {
                inSection = false
                return false
            }
            return !inSection
        }
        
        // Remove trailing empty lines
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        
        // Collect domains already managed by other tools (outside our block)
        let externalDomains: Set<String> = Set(lines.flatMap { line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return [] }
            var fields = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2 else { return [] }
            fields.removeFirst() // drop IP
            if let commentIdx = fields.firstIndex(where: { $0.hasPrefix("#") }) {
                fields = Array(fields[..<commentIdx])
            }
            return fields.map { String($0).lowercased() }
        })

        // Add new section if we have entries (skip domains managed by other tools)
        if !entries.isEmpty {
            var managedEntries: [String] = []
            for entry in entries {
                if let domain = entry["domain"], let ip = entry["ip"] {
                    if isValidIP(ip) && isValidDomain(domain) {
                        if externalDomains.contains(domain.lowercased()) {
                            continue
                        }
                        managedEntries.append("\(ip) \(domain)")
                    }
                }
            }
            if !managedEntries.isEmpty {
                lines.append("")
                lines.append(HelperConstants.hostMarkerStart)
                lines.append(contentsOf: managedEntries)
                lines.append(HelperConstants.hostMarkerEnd)
            }
        }
        
        // Write back
        let newContent = lines.joined(separator: "\n") + "\n"
        
        do {
            try newContent.write(toFile: hostsPath, atomically: true, encoding: .utf8)
            return (true, nil)
        } catch {
            return (false, "Failed to write hosts file: \(error.localizedDescription)")
        }
    }
    
    func flushDNSCache(withReply reply: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-flushcache"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Also run killall -HUP mDNSResponder for good measure
            let mdnsProcess = Process()
            mdnsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            mdnsProcess.arguments = ["-HUP", "mDNSResponder"]
            mdnsProcess.standardOutput = FileHandle.nullDevice
            mdnsProcess.standardError = FileHandle.nullDevice
            try? mdnsProcess.run()
            mdnsProcess.waitUntilExit()
            
            reply(true)
        } catch {
            reply(false)
        }
    }
    
    // MARK: - Version
    
    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }
    
    // MARK: - Validation
    
    private func isValidGateway(_ gateway: String) -> Bool {
        if gateway.hasPrefix("iface:") {
            return isValidInterfaceName(String(gateway.dropFirst(6)))
        }
        return isValidIP(gateway)
    }

    private func isValidInterfaceName(_ name: String) -> Bool {
        let validPrefixes = ["utun", "ipsec", "ppp", "gpd", "tun", "tap", "feth", "zt"]
        guard validPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber } && name.count <= 16
    }

    /// Build `route(8)` arguments for `verb` ("add" or "change"). Both take an identical argument
    /// shape, so `installRoute` can try an in-place change before falling back to an add.
    private func isValidIP(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            guard let num = Int($0), num >= 0, num <= 255 else { return false }
            // Reject leading zeros (e.g., "010") — route interprets them as octal
            return String(num) == $0
        }
    }
    
    private func isValidDestination(_ string: String) -> Bool {
        // Refuse destinations owned by other networking software on this machine — Tailscale's
        // tailnet range and MagicDNS — plus kernel-reserved space. Enforced HERE, at the privileged
        // boundary, so the root daemon is the strictest layer rather than the most permissive; the
        // same reasoning that makes it reject /0.
        //
        // Without this, a VPN Only entry of exactly 100.64.0.0/10 reached `route change -net`,
        // matched on destination, and silently repointed Tailscale's own route into the corporate
        // tunnel — and teardown would then delete it outright. Mesh networking would break with
        // nothing indicating this app was responsible.
        if ProtectedDestinations.isProtected(string) {
            helperLog.error("refusing protected destination \(string, privacy: .public) — it belongs to another network service")
            return false
        }

        // Can be IP or CIDR notation
        if string.contains("/") {
            let parts = string.components(separatedBy: "/")
            guard parts.count == 2,
                  isValidIP(parts[0]),
                  let mask = Int(parts[1]),
                  mask >= 1 && mask <= 32 else {
            // /0 is the entire default route. The app-side validator already rejects it; the root
            // daemon must never be the MORE permissive layer, or a caller that slipped past the app
            // could hand the kernel a route that captures everything.
                return false
            }
            return true
        }
        return isValidIP(string)
    }
    
    private func isValidDomain(_ string: String) -> Bool {
        // Basic domain validation
        let domainRegex = #"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$"#
        return string.range(of: domainRegex, options: .regularExpression) != nil
    }
}
