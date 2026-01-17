// main.swift
// Entry point for VPNBypassHelper privileged tool.

import Foundation

// The helper tool runs as a LaunchDaemon and listens for XPC connections
let delegate = HelperToolDelegate()
let listener = NSXPCListener(machServiceName: kHelperToolMachServiceName)
listener.delegate = delegate
listener.resume()

// Keep the helper running
RunLoop.main.run()
