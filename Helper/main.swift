// main.swift
// Entry point for VPNBypassHelper privileged tool.

import Foundation

// A wildcard resolver file left by a previous run points at a forwarder that is not running
// yet, which breaks every lookup under its suffix. Remove them before anything else; the app
// sets its wildcards again on its next pass.
WildcardForwarder.removeLeftoverResolverFiles()

// launchd stops the helper with SIGTERM (`launchctl bootout` on an upgrade or an uninstall, and
// at shutdown). A helper that is not started again would leave its resolver files pointing at
// a closed port, so they go first. A crash is covered by KeepAlive in the launchd plist: the
// helper comes straight back and the line above removes them.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
terminationSource.setEventHandler {
    WildcardForwarder.shared.shutdown()
    exit(0)
}
terminationSource.resume()

// The helper tool runs as a LaunchDaemon and listens for XPC connections
let delegate = HelperToolDelegate()
let listener = NSXPCListener(machServiceName: kHelperToolMachServiceName)
listener.delegate = delegate
listener.resume()

// Keep the helper running
RunLoop.main.run()
