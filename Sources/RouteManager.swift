// RouteManager.swift
// Core routing logic - manages VPN detection, routes, and hosts entries.

import Foundation
import Network
import AppKit

@MainActor
final class RouteManager: ObservableObject {
    static let shared = RouteManager()
    
    // MARK: - Published State
    
    @Published var isVPNConnected = false
    @Published var vpnInterface: String?
    @Published var localGateway: String?
    @Published var activeRoutes: [ActiveRoute] = []
    @Published var lastUpdate: Date?
    @Published var config: Config = Config()
    @Published var recentLogs: [LogEntry] = []
    
    // MARK: - Types
    
    struct Config: Codable {
        var domains: [DomainEntry] = []
        var services: [ServiceEntry] = defaultServices
        var autoApplyOnVPN: Bool = true
        var manageHostsFile: Bool = true
        var checkInterval: TimeInterval = 300 // 5 minutes
        
        static var defaultServices: [ServiceEntry] {
            [
                ServiceEntry(id: "telegram", name: "Telegram", enabled: true, domains: [
                    "telegram.org", "t.me", "telegram.me",
                    "core.telegram.org", "api.telegram.org",
                    "web.telegram.org"
                ], ipRanges: [
                    "91.108.56.0/22", "91.108.4.0/22", "91.108.8.0/22",
                    "91.108.16.0/22", "91.108.12.0/22", "149.154.160.0/20",
                    "91.105.192.0/23", "185.76.151.0/24"
                ]),
                ServiceEntry(id: "youtube", name: "YouTube", enabled: false, domains: [
                    "youtube.com", "www.youtube.com", "m.youtube.com",
                    "youtu.be", "youtube-nocookie.com",
                    "googlevideo.com", "ytimg.com"
                ], ipRanges: []),
                ServiceEntry(id: "whatsapp", name: "WhatsApp", enabled: false, domains: [
                    "whatsapp.com", "web.whatsapp.com", "whatsapp.net"
                ], ipRanges: [
                    "3.33.221.0/24", "15.197.206.0/24",
                    "52.26.198.0/24", "169.45.71.0/24"
                ]),
                ServiceEntry(id: "spotify", name: "Spotify", enabled: false, domains: [
                    "spotify.com", "scdn.co", "spotifycdn.com"
                ], ipRanges: []),
                ServiceEntry(id: "tailscale", name: "Tailscale", enabled: true, domains: [
                    "login.tailscale.com", "controlplane.tailscale.com",
                    "tailscale.com", "pkgs.tailscale.com"
                ], ipRanges: []),
                ServiceEntry(id: "slack", name: "Slack", enabled: false, domains: [
                    "slack.com", "slack-edge.com", "slack-imgs.com"
                ], ipRanges: []),
                ServiceEntry(id: "discord", name: "Discord", enabled: false, domains: [
                    "discord.com", "discord.gg", "discordapp.com",
                    "discord.media", "discordcdn.com"
                ], ipRanges: []),
                ServiceEntry(id: "twitch", name: "Twitch", enabled: false, domains: [
                    "twitch.tv", "twitchcdn.net", "jtvnw.net"
                ], ipRanges: [])
            ]
        }
    }
    
    struct DomainEntry: Codable, Identifiable, Equatable {
        let id: UUID
        var domain: String
        var enabled: Bool
        var resolvedIP: String?
        var lastResolved: Date?
        
        init(domain: String, enabled: Bool = true) {
            self.id = UUID()
            self.domain = domain
            self.enabled = enabled
        }
    }
    
    struct ServiceEntry: Codable, Identifiable {
        let id: String
        var name: String
        var enabled: Bool
        var domains: [String]
        var ipRanges: [String]
    }
    
    struct ActiveRoute: Identifiable {
        let id = UUID()
        let destination: String
        let gateway: String
        let source: String // domain name or service name
        let timestamp: Date
    }
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
        
        enum LogLevel: String {
            case info = "INFO"
            case success = "SUCCESS"
            case warning = "WARNING"
            case error = "ERROR"
        }
    }
    
    // MARK: - Private
    
    private let configURL: URL
    private var refreshTimer: Timer?
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("VPNBypass", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("config.json")
    }
    
    // MARK: - Public API
    
    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let loaded = try? JSONDecoder().decode(Config.self, from: data) else {
            log(.info, "Using default config")
            return
        }
        config = loaded
        log(.info, "Config loaded")
    }
    
    func saveConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configURL)
        log(.info, "Config saved")
    }
    
    func updateNetworkStatus(_ path: NWPath) {
        let wasVPNConnected = isVPNConnected
        
        // Check for VPN interfaces (utun, ipsec, etc.)
        let vpnInterfaces = path.availableInterfaces.filter { iface in
            let name = iface.name
            return name.hasPrefix("utun") || name.hasPrefix("ipsec") || 
                   name.hasPrefix("ppp") || name.hasPrefix("gpd") ||
                   name.hasPrefix("tun")
        }
        
        isVPNConnected = !vpnInterfaces.isEmpty
        vpnInterface = vpnInterfaces.first?.name
        
        // Detect local gateway
        Task {
            localGateway = await detectLocalGateway()
            
            // Auto-apply routes when VPN connects
            if isVPNConnected && !wasVPNConnected && config.autoApplyOnVPN {
                log(.info, "VPN connected, applying routes...")
                await applyAllRoutes()
            }
        }
    }
    
    func detectAndApplyRoutes() {
        Task {
            localGateway = await detectLocalGateway()
            if localGateway != nil {
                await applyAllRoutes()
            } else {
                log(.error, "Could not detect local gateway")
            }
        }
    }
    
    func applyAllRoutes() async {
        guard let gateway = localGateway else {
            log(.error, "No local gateway available")
            return
        }
        
        var newRoutes: [ActiveRoute] = []
        
        // Apply domain routes
        for domain in config.domains where domain.enabled {
            if let routes = await applyRoutesForDomain(domain.domain, gateway: gateway) {
                newRoutes.append(contentsOf: routes)
            }
        }
        
        // Apply service routes
        for service in config.services where service.enabled {
            for domain in service.domains {
                if let routes = await applyRoutesForDomain(domain, gateway: gateway, source: service.name) {
                    newRoutes.append(contentsOf: routes)
                }
            }
            // Apply IP ranges
            for range in service.ipRanges {
                if await applyRouteForRange(range, gateway: gateway) {
                    newRoutes.append(ActiveRoute(
                        destination: range,
                        gateway: gateway,
                        source: service.name,
                        timestamp: Date()
                    ))
                }
            }
        }
        
        activeRoutes = newRoutes
        lastUpdate = Date()
        
        // Manage hosts file if enabled
        if config.manageHostsFile {
            await updateHostsFile()
        }
        
        log(.success, "Applied \(newRoutes.count) routes")
    }
    
    func removeAllRoutes() async {
        for route in activeRoutes {
            await removeRoute(route.destination)
        }
        activeRoutes.removeAll()
        lastUpdate = Date()
        
        if config.manageHostsFile {
            await cleanHostsFile()
        }
        
        log(.info, "All routes removed")
    }
    
    func addDomain(_ domain: String) {
        let cleaned = cleanDomain(domain)
        guard !cleaned.isEmpty else { return }
        guard !config.domains.contains(where: { $0.domain == cleaned }) else {
            log(.warning, "Domain \(cleaned) already exists")
            return
        }
        
        config.domains.append(DomainEntry(domain: cleaned))
        saveConfig()
        log(.success, "Added domain: \(cleaned)")
        
        // Apply route immediately if VPN connected
        if isVPNConnected, let gateway = localGateway {
            Task {
                _ = await applyRoutesForDomain(cleaned, gateway: gateway)
            }
        }
    }
    
    func removeDomain(_ domain: DomainEntry) {
        config.domains.removeAll { $0.id == domain.id }
        saveConfig()
        
        // Remove active routes for this domain
        activeRoutes.removeAll { $0.source == domain.domain }
        
        log(.info, "Removed domain: \(domain.domain)")
    }
    
    func toggleService(_ serviceId: String) {
        guard let index = config.services.firstIndex(where: { $0.id == serviceId }) else { return }
        config.services[index].enabled.toggle()
        saveConfig()
        
        let service = config.services[index]
        log(.info, "\(service.name) \(service.enabled ? "enabled" : "disabled")")
        
        // Apply or remove routes
        if isVPNConnected {
            Task {
                await applyAllRoutes()
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func detectLocalGateway() async -> String? {
        // Try common network services
        let services = ["Wi-Fi", "Ethernet", "USB 10/100/1000 LAN", "Thunderbolt Ethernet"]
        
        for service in services {
            if let gateway = await getGatewayForService(service) {
                return gateway
            }
        }
        
        // Fallback: parse route table
        return await parseDefaultGateway()
    }
    
    private func getGatewayForService(_ service: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getinfo", service]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("Router:") {
                    let gateway = line.replacingOccurrences(of: "Router:", with: "").trimmingCharacters(in: .whitespaces)
                    if gateway != "none" && !gateway.isEmpty {
                        return gateway
                    }
                }
            }
        } catch {}
        
        return nil
    }
    
    private func parseDefaultGateway() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            for line in output.components(separatedBy: "\n") {
                if line.contains("gateway:") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count >= 2 {
                        return parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {}
        
        return nil
    }
    
    private func applyRoutesForDomain(_ domain: String, gateway: String, source: String? = nil) async -> [ActiveRoute]? {
        // Resolve domain IPs
        guard let ips = await resolveIPs(for: domain) else {
            log(.warning, "Could not resolve IPs for \(domain)")
            return nil
        }
        
        var routes: [ActiveRoute] = []
        
        for ip in ips {
            if await addRoute(ip, gateway: gateway) {
                routes.append(ActiveRoute(
                    destination: ip,
                    gateway: gateway,
                    source: source ?? domain,
                    timestamp: Date()
                ))
            }
        }
        
        return routes.isEmpty ? nil : routes
    }
    
    private func applyRouteForRange(_ range: String, gateway: String) async -> Bool {
        return await addRoute(range, gateway: gateway, isNetwork: true)
    }
    
    private func resolveIPs(for domain: String) async -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        process.arguments = ["+short", domain]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            let ips = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { isValidIP($0) }
            
            return ips.isEmpty ? nil : ips
        } catch {
            return nil
        }
    }
    
    private func addRoute(_ destination: String, gateway: String, isNetwork: Bool = false) async -> Bool {
        // First try to delete existing route
        _ = await removeRoute(destination)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        
        if isNetwork {
            process.arguments = ["-n", "add", "-net", destination, gateway]
        } else {
            process.arguments = ["-n", "add", "-host", destination, gateway]
        }
        
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private func removeRoute(_ destination: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "delete", destination]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            return true
        } catch {
            return false
        }
    }
    
    private func updateHostsFile() async {
        // Collect all domain -> IP mappings
        var entries: [(domain: String, ip: String)] = []
        
        for domain in config.domains where domain.enabled {
            if let ips = await resolveIPs(for: domain.domain), let firstIP = ips.first {
                entries.append((domain.domain, firstIP))
            }
        }
        
        for service in config.services where service.enabled {
            for domain in service.domains {
                if let ips = await resolveIPs(for: domain), let firstIP = ips.first {
                    entries.append((domain, firstIP))
                }
            }
        }
        
        // Update /etc/hosts (requires sudo)
        await modifyHostsFile(entries: entries)
    }
    
    private func cleanHostsFile() async {
        await modifyHostsFile(entries: [])
    }
    
    private func modifyHostsFile(entries: [(domain: String, ip: String)]) async {
        let marker = "# VPN-BYPASS-MANAGED"
        let hostsPath = "/etc/hosts"
        
        // Read current hosts file
        guard let currentContent = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            log(.error, "Could not read /etc/hosts")
            return
        }
        
        // Remove existing VPN-BYPASS section
        var lines = currentContent.components(separatedBy: "\n")
        var inSection = false
        lines = lines.filter { line in
            if line.contains("\(marker) - START") {
                inSection = true
                return false
            }
            if line.contains("\(marker) - END") {
                inSection = false
                return false
            }
            return !inSection
        }
        
        // Add new section if we have entries
        if !entries.isEmpty {
            lines.append("")
            lines.append("\(marker) - START")
            for entry in entries {
                lines.append("\(entry.ip) \(entry.domain)")
            }
            lines.append("\(marker) - END")
        }
        
        // Write back (this will fail without sudo - user needs to grant permission)
        let newContent = lines.joined(separator: "\n")
        
        // Use AppleScript to write with admin privileges
        let script = """
        do shell script "cat > /etc/hosts << 'VPNBYPASS_EOF'
        \(newContent)
        VPNBYPASS_EOF" with administrator privileges
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if error == nil {
                // Flush DNS cache
                let flush = Process()
                flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
                flush.arguments = ["-flushcache"]
                try? flush.run()
            }
        }
    }
    
    private func cleanDomain(_ input: String) -> String {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove protocol
        if let url = URL(string: domain), let host = url.host {
            domain = host
        } else {
            domain = domain
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
        }
        // Remove path
        if let slashIndex = domain.firstIndex(of: "/") {
            domain = String(domain[..<slashIndex])
        }
        return domain.lowercased()
    }
    
    private func isValidIP(_ string: String) -> Bool {
        let parts = string.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0) != nil && Int($0)! >= 0 && Int($0)! <= 255 }
    }
    
    private func log(_ level: LogEntry.LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        recentLogs.insert(entry, at: 0)
        if recentLogs.count > 100 {
            recentLogs.removeLast()
        }
        print("[\(level.rawValue)] \(message)")
    }
}
