// HelperTool.swift
// Privileged helper tool implementation that runs as root.

import Foundation

// MARK: - XPC Listener Delegate

class HelperToolDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Verify the connecting process is our main app by checking its bundle identifier
        let pid = newConnection.processIdentifier
        guard verifyCallerIdentity(pid: pid) else {
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
    /// Baseline requirement: signed with our identifier. Under ad-hoc signing that string
    /// alone is forgeable by any local binary (`codesign -s - -i com.geiserx.vpn-bypass`),
    /// so when a cdhash pin file (written root-only in the same admin op that installs the
    /// helper) is present and valid, we ALSO require that exact cdhash — which a forged
    /// binary cannot reproduce. If the pin is absent or malformed we fall back to
    /// identifier-only: degraded but functional, and never a hard reject (removing/forging
    /// the root-owned pin already needs root). See docs + HelperConstants.cdhashPinPath.
    private func verifyCallerIdentity(pid: pid_t) -> Bool {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let callerCode = code else {
            return false
        }

        var requirementString = "identifier \"\(HelperConstants.appSigningIdentifier)\""
        if let pinnedHash = Self.readPinnedCDHash() {
            requirementString += " and cdhash H\"\(pinnedHash)\""
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else {
            return false
        }

        return SecCodeCheckValidity(callerCode, [], req) == errSecSuccess
    }

    /// The pinned app cdhash (lowercase hex) if the root-only pin file holds a well-formed
    /// value, else nil. ANTI-BRICK: any non-hex/empty content returns nil so the caller
    /// degrades to identifier-only rather than building a malformed `cdhash H"..."`
    /// requirement that would reject every caller (including the real app). Read fresh each
    /// call so a rewritten pin (app update) takes effect without restarting the helper.
    private static func readPinnedCDHash() -> String? {
        guard let data = FileManager.default.contents(atPath: HelperConstants.cdhashPinPath),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Require a WHOLE cdhash, not merely "some hex". kSecCodeInfoUnique is a 20-byte
        // code-directory hash (40 hex chars); a SHA-256 form is 32 bytes (64 hex). A
        // partial/truncated write (e.g. "ab") is still even-length valid hex but would
        // build a `cdhash H"ab"` requirement the real app can NEVER satisfy — locking out
        // the helper. Reject anything that isn't a full-length hex cdhash so we fall back
        // to identifier-only rather than pinning an unsatisfiable value.
        let isValidCDHash = (trimmed.count == 40 || trimmed.count == 64)
            && trimmed.allSatisfy { $0.isHexDigit }
        return isValidCDHash ? trimmed : nil
    }
}

// MARK: - Helper Tool Implementation

class HelperTool: NSObject, HelperProtocol {
    
    // MARK: - Route Management
    
    func addRoute(destination: String, gateway: String, isNetwork: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        // Validate inputs
        guard isValidDestination(destination), isValidGateway(gateway) else {
            reply(false, "Invalid destination or gateway format")
            return
        }

        // First try to delete existing route (ignore result)
        _ = executeRoute(args: ["-n", "delete", destination])

        // Add the new route
        let result = executeRoute(args: buildRouteAddArgs(destination: destination, gateway: gateway, isNetwork: isNetwork))
        reply(result.success, result.error)
    }
    
    func removeRoute(destination: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard isValidDestination(destination) else {
            reply(false, "Invalid destination format")
            return
        }
        
        let result = executeRoute(args: ["-n", "delete", destination])
        reply(result.success, result.error)
    }
    
    // MARK: - Batch Route Management (for startup/stop performance)
    
    func addRoutesBatch(routes: [[String: Any]], withReply reply: @escaping (Int, Int, [String], String?) -> Void) {
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
            guard isValidDestination(destination), isValidGateway(gateway) else {
                failureCount += 1
                failedDestinations.append(destination)
                continue
            }

            // First try to delete existing route (ignore result)
            _ = executeRoute(args: ["-n", "delete", destination])

            // Add the new route
            let result = executeRoute(args: buildRouteAddArgs(destination: destination, gateway: gateway, isNetwork: isNetwork))
            if result.success {
                successCount += 1
            } else {
                failureCount += 1
                failedDestinations.append(destination)
                lastError = result.error
            }
        }

        reply(successCount, failureCount, failedDestinations, lastError)
    }

    func removeRoutesBatch(destinations: [String], withReply reply: @escaping (Int, Int, [String], String?) -> Void) {
        var successCount = 0
        var failureCount = 0
        var failedDestinations: [String] = []
        var lastError: String?

        for destination in destinations {
            guard isValidDestination(destination) else {
                failureCount += 1
                failedDestinations.append(destination)
                continue
            }

            let result = executeRoute(args: ["-n", "delete", destination])
            if result.success {
                successCount += 1
            } else {
                failureCount += 1
                failedDestinations.append(destination)
                lastError = result.error
            }
        }

        reply(successCount, failureCount, failedDestinations, lastError)
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
        let hostsPath = "/etc/hosts"
        
        // Read current hosts file
        guard let currentContent = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            reply(false, "Could not read /etc/hosts")
            return
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
            reply(true, nil)
        } catch {
            reply(false, "Failed to write hosts file: \(error.localizedDescription)")
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

    private func buildRouteAddArgs(destination: String, gateway: String, isNetwork: Bool) -> [String] {
        var args = ["-n", "add"]
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
