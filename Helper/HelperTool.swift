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
            let result = self.installRoute(destination: destination, gateway: gateway, isNetwork: isNetwork)
            reply(result.success, result.error)
        }
    }

    func removeRoute(destination: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard isValidDestination(destination) else {
            reply(false, "Invalid destination format")
            return
        }

        Self.routeQueue.async {
            let result = self.executeRoute(args: ["-n", "delete", destination])
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

                let result = self.installRoute(destination: destination, gateway: gateway, isNetwork: isNetwork)
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

                let result = self.executeRoute(args: ["-n", "delete", destination])
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

    /// Install one route WITHOUT the old blind `route delete` that preceded every add.
    ///
    /// #65: the previous `delete` + `add` pair cost two kernel mutations per route even when the
    /// route was already correct, and — worse — it briefly REMOVED the route. Each mutation raises a
    /// kernel route-change event, and GlobalProtect re-validates its own gateway route on every one;
    /// its teardowns were preceded by `Failed to find route for <gateway>`, exactly what a transient
    /// removal produces. The blind delete could also remove a route this app never owned.
    ///
    /// The ladder below never opens a window where the destination has no route:
    ///   1. `change` — rewrites an existing route in place (one mutation, no gap). Succeeds in the
    ///      re-apply case, which is the common one.
    ///   2. `add` — only when nothing was there to change (one mutation).
    ///   3. `delete` + `add` — last resort, only if `add` reports the route already exists (a race
    ///      with another writer between steps 1 and 2). This is the sole path that can still open a
    ///      gap, and it is now rare rather than universal.
    private func installRoute(destination: String, gateway: String, isNetwork: Bool) -> (success: Bool, error: String?) {
        // #65, the core of it: if the kernel ALREADY has exactly this route, write nothing.
        // Callers re-apply the same route set constantly (DNS refresh, failed-domain retries,
        // status passes), and each redundant write raises a kernel route-change event that other
        // VPN clients react to by re-validating their tunnel — which is the entire bug. Skipping
        // the write is what makes steady state cost ZERO mutations.
        if routeAlreadyCorrect(destination: destination, gateway: gateway, isNetwork: isNetwork) {
            helperLog.debug("install \(destination, privacy: .public): already correct, no mutation")
            return (true, nil)
        }

        let changed = executeRoute(args: buildRouteArgs(verb: "change", destination: destination, gateway: gateway, isNetwork: isNetwork))
        if changed.success {
            helperLog.info("install \(destination, privacy: .public): changed in place")
            return (true, nil)
        }

        let added = executeRoute(args: buildRouteArgs(verb: "add", destination: destination, gateway: gateway, isNetwork: isNetwork))
        if added.success {
            helperLog.info("install \(destination, privacy: .public): added")
            return (true, nil)
        }

        // `add` refused because a route for this destination exists after all — fall back to the
        // old replace, which is the only remaining way to converge.
        if (added.error ?? "").localizedCaseInsensitiveContains("exists") {
            helperLog.info("install \(destination, privacy: .public): change+add both refused, replacing")
            let removed = executeRoute(args: ["-n", "delete", destination])
            guard removed.success else {
                // Report why the removal failed rather than letting the follow-up add fail with a
                // secondary "exists" that hides the real cause.
                helperLog.error("install \(destination, privacy: .public): delete before replace failed: \(removed.error ?? "unknown", privacy: .public)")
                return (false, removed.error)
            }
            let replaced = executeRoute(args: buildRouteArgs(verb: "add", destination: destination, gateway: gateway, isNetwork: isNetwork))
            return (replaced.success, replaced.error)
        }

        helperLog.error("install \(destination, privacy: .public) failed: \(added.error ?? "unknown", privacy: .public)")
        return (false, added.error)
    }

    /// True when the kernel already holds exactly this route, so installing it again would be a
    /// pure no-op write. `route -n get` is a READ: it reports the route that *would* be used and
    /// raises no route-change event, so asking is free in the sense that matters here.
    ///
    /// The `destination:` comparison is load-bearing, not defensive padding. For a host with NO
    /// specific route, `route get` reports the DEFAULT route — and in Bypass mode the default
    /// route's gateway IS the local gateway we are about to install through. Comparing gateways
    /// alone would therefore report "already correct" for a route that does not exist, and we
    /// would silently never install it: the bypass would break with no error anywhere. Requiring
    /// `destination` to equal the host we asked about is what distinguishes "this exact route is
    /// present" from "something else would carry this traffic".
    ///
    /// Network routes are deliberately excluded: `route get` normalises a network destination in
    /// ways that are not reliably comparable to the CIDR string we were handed, and a wrong match
    /// there would skip a write that was genuinely needed. They are few; host routes are where
    /// the churn is.
    private func routeAlreadyCorrect(destination: String, gateway: String, isNetwork: Bool) -> Bool {
        guard !isNetwork else { return false }
        guard let output = routeOutput(args: ["-n", "get", destination]) else { return false }

        var dest: String?
        var gw: String?
        var iface: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("destination:") {
                dest = String(line.dropFirst("destination:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("gateway:") {
                gw = String(line.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("interface:") {
                iface = String(line.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        // No route specific to this destination -> it must be installed.
        guard dest == destination else { return false }

        if gateway.hasPrefix("iface:") {
            return iface == String(gateway.dropFirst(6))
        }
        return gw == gateway
    }

    /// Run `route` and capture stdout. Used only for read-only queries (`route -n get`).
    private func routeOutput(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = args

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func executeRoute(args: [String]) -> (success: Bool, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = args
        
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                return (true, nil)
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                return (false, errorString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            return (false, error.localizedDescription)
        }
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
    private func buildRouteArgs(verb: String, destination: String, gateway: String, isNetwork: Bool) -> [String] {
        var args = ["-n", verb]
        args.append(isNetwork ? "-net" : "-host")
        args.append(destination)
        if gateway.hasPrefix("iface:") {
            args.append(contentsOf: ["-interface", String(gateway.dropFirst(6))])
        } else {
            args.append(gateway)
        }
        return args
    }

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
        // Can be IP or CIDR notation
        if string.contains("/") {
            let parts = string.components(separatedBy: "/")
            guard parts.count == 2,
                  isValidIP(parts[0]),
                  let mask = Int(parts[1]),
                  mask >= 0 && mask <= 32 else {
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
