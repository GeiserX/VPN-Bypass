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
    ///   - reply: Callback with success count, failure count, and optional error message
    func addRoutesBatch(
        routes: [[String: Any]],
        withReply reply: @escaping (Int, Int, String?) -> Void
    )
    
    /// Remove multiple routes in batch (faster for cleanup/VPN disconnect)
    /// - Parameters:
    ///   - destinations: Array of IP addresses or CIDR ranges to remove
    ///   - reply: Callback with success count, failure count, and optional error message
    func removeRoutesBatch(
        destinations: [String],
        withReply reply: @escaping (Int, Int, String?) -> Void
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

/// Protocol for the main app to receive callbacks from helper
@objc(HelperProgressProtocol) 
protocol HelperProgressProtocol {
    /// Called when an operation completes
    func operationComplete(success: Bool, message: String?)
}

// MARK: - Helper Constants

struct HelperConstants {
    static let helperVersion = "1.2.0"
    static let bundleID = "com.geiserx.vpnbypass.helper"
    static let hostMarkerStart = "# VPN-BYPASS-MANAGED - START"
    static let hostMarkerEnd = "# VPN-BYPASS-MANAGED - END"
}
