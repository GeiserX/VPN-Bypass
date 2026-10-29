// main.swift
// Entry point for VPNBypassHelper privileged tool.

import Foundation

// A wildcard resolver file left by a previous run points at a forwarder that is not running
// yet, which breaks every lookup under its suffix. Remove them before anything else; the app
// sets its wildcards again on its next pass.
WildcardForwarder.removeLeftoverResolverFiles()

// The helper tool runs as a LaunchDaemon and listens for XPC connections
let delegate = HelperToolDelegate()
let listener = NSXPCListener(machServiceName: kHelperToolMachServiceName)
listener.delegate = delegate
listener.resume()

// Keep the helper running
RunLoop.main.run()
