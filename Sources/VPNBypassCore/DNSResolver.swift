// DNSResolver.swift
// DNS resolution + process-runner subsystem extracted from RouteManager.
// Pure, nonisolated static helpers: no actor isolation, no shared mutable state.

import Foundation

/// Dedicated queue for process execution to avoid GCD thread pool exhaustion
/// Module-internal so both DNSResolver's runners and RouteManager.runProcessAsync share it
let vpnBypassProcessQueue = DispatchQueue(label: "com.vpnbypass.process", qos: .userInitiated, attributes: .concurrent)

enum DNSResolver {
    /// Async process execution for parallel DNS - uses dedicated queue
    private nonisolated static func runProcessParallel(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = 5.0
    ) async -> (output: String, exitCode: Int32)? {
        await withCheckedContinuation { continuation in
            vpnBypassProcessQueue.async {
                let result = runProcessSyncSafe(executablePath, arguments: arguments, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Safe synchronous process execution - avoids semaphore deadlock by using runloop
    static nonisolated func runProcessSyncSafe(
        _ executablePath: String,
        arguments: [String] = [],
        timeout: TimeInterval = 5.0
    ) -> (output: String, exitCode: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
        } catch {
            return nil
        }
        
        // Use a simple polling approach with deadline instead of nested GCD + semaphore
        // This avoids thread pool exhaustion issues
        let deadline = Date().addingTimeInterval(timeout)
        
        // NOTE: this runs on `vpnBypassProcessQueue.async` (a raw GCD closure, not a Swift
        // Task), so `Task.isCancelled` is always false here — it cannot see the enclosing
        // resolver TaskGroup's cancelAll(). Promptly killing a losing resolver therefore needs
        // a cancellation flag threaded in via withTaskCancellationHandler (deferred; see
        // docs/CODE-REVIEW-3.0.1.md). A loser simply runs out its own 1–3 s timeout; harmless,
        // just wasted CPU.
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01) // 10ms poll interval
        }

        if process.isRunning {
            // Timeout - terminate the process
            process.terminate()
            // Give it a moment to clean up
            Thread.sleep(forTimeInterval: 0.05)
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }

    /// Nonisolated DNS resolution - races dig and DoH in parallel with trust hierarchy.
    /// Dig-based resolvers fire immediately (trusted); DoH fires after a 200ms grace period
    /// so it only wins when VPN blocks UDP DNS. Resolves in ~2s on VPN instead of 8+.
    nonisolated static func resolveIPsParallel(for domain: String, userDNS: String?, fallbackDNS: [String]) async -> [String]? {
        let dohGraceNs: UInt64 = 200_000_000 // 200ms head start for trusted dig resolvers
        let hardcodedDoH = ["https://cloudflare-dns.com/dns-query", "https://dns.google/dns-query"]
        
        for attempt in 1...2 {
            let result: [String]? = await withTaskGroup(of: [String]?.self) { group in
                // Tier 1: dig-based resolvers fire immediately (trusted, local/fast)
                if let userDNS = userDNS {
                    group.addTask { await resolveWithDNSParallel(domain, dns: userDNS) }
                }
                for dns in fallbackDNS {
                    group.addTask { await resolveWithDNSParallel(domain, dns: dns) }
                }
                
                // Tier 2: DoH fires after grace period — only wins when dig is blocked by VPN
                for doh in hardcodedDoH where !fallbackDNS.contains(doh) {
                    group.addTask {
                        do { try await Task.sleep(nanoseconds: dohGraceNs) } catch { return nil }
                        return await resolveWithDoHParallel(domain, dohURL: doh)
                    }
                }
                
                for await result in group {
                    if let ips = result, !ips.isEmpty {
                        group.cancelAll()
                        return ips
                    }
                }
                return nil
            }
            
            if let result = result {
                return result
            }
            
            if attempt < 2 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return nil }
            }
        }
        
        // System resolver as absolute last resort (uses VPN's DNS, may not bypass)
        return await resolveWithSystemResolver(domain, timeout: 3.0)
    }
    
    /// Resolve using system's getaddrinfo - uses OS-level DNS which may work when dig fails
    /// Note: When VPN is active, this typically uses VPN's DNS servers
    private nonisolated static func resolveWithSystemResolver(_ domain: String, timeout: TimeInterval) async -> [String]? {
        // Race between getaddrinfo and timeout
        return await withTaskGroup(of: [String]?.self) { group in
            // Actual resolution task
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var hints = addrinfo()
                        hints.ai_family = AF_INET  // IPv4 only for routing
                        hints.ai_socktype = SOCK_STREAM
                        
                        var result: UnsafeMutablePointer<addrinfo>?
                        let status = getaddrinfo(domain, nil, &hints, &result)
                        
                        guard status == 0, let addrInfo = result else {
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        defer { freeaddrinfo(addrInfo) }
                        
                        var ips: [String] = []
                        var current: UnsafeMutablePointer<addrinfo>? = addrInfo
                        
                        while let info = current {
                            if info.pointee.ai_family == AF_INET,
                               let sockaddr = info.pointee.ai_addr {
                                sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                                    var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                                    var inAddr = addr.pointee.sin_addr
                                    if inet_ntop(AF_INET, &inAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                                        let ip = String(cString: ipBuffer)
                                        if !ips.contains(ip) {
                                            ips.append(ip)
                                        }
                                    }
                                }
                            }
                            current = info.pointee.ai_next
                        }
                        
                        continuation.resume(returning: ips.isEmpty ? nil : ips)
                    }
                }
            }
            
            // Timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            
            // Return first result (either success or timeout)
            if let result = await group.next(), let ips = result {
                group.cancelAll()
                return ips
            }
            
            group.cancelAll()
            return nil
        }
    }
    
    private nonisolated static func resolveWithDNSParallel(_ domain: String, dns: String) async -> [String]? {
        // Reject domains that could be interpreted as flags
        guard !domain.isEmpty, !domain.hasPrefix("-") else { return nil }

        // Validate DNS server string — reject whitespace, semicolons, and shell metacharacters
        let dnsStripped = dns.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dnsStripped.isEmpty,
              dnsStripped.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";|&`$"))) == nil
        else { return nil }

        // Check protocol type
        if dnsStripped.hasPrefix("https://") {
            return await resolveWithDoHParallel(domain, dohURL: dnsStripped)
        } else if dnsStripped.hasPrefix("tls://") {
            let server = String(dnsStripped.dropFirst(6))
            return await resolveWithDoTParallel(domain, server: server)
        } else if dnsStripped.contains(":853") {
            let server = dnsStripped.replacingOccurrences(of: ":853", with: "")
            return await resolveWithDoTParallel(domain, server: server)
        }

        let isLocalDNS = dnsStripped.hasPrefix("192.168.") || dnsStripped.hasPrefix("10.") || dnsStripped.hasPrefix("172.16.") || dnsStripped.hasPrefix("172.17.") || dnsStripped.hasPrefix("172.18.") || dnsStripped.hasPrefix("172.19.") || dnsStripped.hasPrefix("172.2") || dnsStripped.hasPrefix("172.30.") || dnsStripped.hasPrefix("172.31.")
        let timeout: TimeInterval = isLocalDNS ? 1.0 : 1.5
        let args = ["@\(dnsStripped)", "+short", "+time=1", "+tries=1", domain]
        guard let result = await runProcessParallel("/usr/bin/dig", arguments: args, timeout: timeout) else {
            return nil
        }
        
        let ips = result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && isValidIPStatic($0) }
        
        return ips.isEmpty ? nil : ips
    }
    
    private nonisolated static func resolveWithDoTParallel(_ domain: String, server: String) async -> [String]? {
        // DNS-over-TLS using kdig (from knot-dns package)
        // Install with: brew install knot
        
        // Check if kdig is available
        let kdigPaths = ["/opt/homebrew/bin/kdig", "/usr/local/bin/kdig"]
        var kdigPath: String?
        for path in kdigPaths {
            if FileManager.default.fileExists(atPath: path) {
                kdigPath = path
                break
            }
        }
        
        guard let kdig = kdigPath else {
            // kdig not installed, fall back to other DNS methods
            return nil
        }
        
        let args = ["+tls", "+short", "@\(server)", domain]
        guard let result = await runProcessParallel(kdig, arguments: args, timeout: 3.0),
              result.exitCode == 0 else {
            return nil
        }
        
        let ips = result.output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && isValidIPStatic($0) }
        
        return ips.isEmpty ? nil : ips
    }
    
    private nonisolated static func resolveWithDoHParallel(_ domain: String, dohURL: String) async -> [String]? {
        // DNS-over-HTTPS using JSON API (works with Cloudflare, Google, etc.)
        let url = "\(dohURL)?name=\(domain)&type=A"
        let args = ["-s", "-H", "accept: application/dns-json", url]
        
        guard let result = await runProcessParallel("/usr/bin/curl", arguments: args, timeout: 3.0),
              result.exitCode == 0 else {
            return nil
        }
        
        // Parse JSON response for A records
        // Format: {"Answer":[{"data":"1.2.3.4"},...]}
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else {
            return nil
        }
        
        let ips = answers.compactMap { answer -> String? in
            guard let type = answer["type"] as? Int, type == 1,  // Type 1 = A record
                  let ip = answer["data"] as? String,
                  isValidIPStatic(ip) else {
                return nil
            }
            return ip
        }
        
        return ips.isEmpty ? nil : ips
    }
    
    /// Static version of isValidIP for use in nonisolated methods
    private nonisolated static func isValidIPStatic(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy {
            guard let num = Int($0), num >= 0, num <= 255 else { return false }
            return String(num) == $0
        }
    }
}
