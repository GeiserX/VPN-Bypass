// scoped-route: the helper's own scoped default route code (R12), run as root from a command
// line on a test Mac, for a live test beside another VPN Bypass whose helper must not be replaced.
//
// It is the helper's code as it is: `ScopedDefaultKeeper` and `HelperTool` from Helper/, with the
// plan, the validation and the routing-socket message from Sources/VPNBypassCore. Only this
// entry point differs: one request per run instead of one per XPC call. Build it with the helper's
// file list (Makefile `build-helper`), this file in place of Helper/main.swift (copied as
// main.swift, the one file swiftc runs top-level code from):
//
//   cp scripts/ne-live/scoped-route-main.swift /tmp/main.swift
//   swiftc -O -import-objc-header Helper/NSXPCConnection+AuditToken.h -o /tmp/scoped-route \
//     Sources/VPNBypassCore/{HelperProtocol,RouteKernel,TunnelOwnership,DNSQueryLine,WildcardDNS,ScopedDefaultRoute}.swift \
//     Helper/{DNSCapture,WildcardForwarder,ScopedDefaultKeeper,HelperTool}.swift /tmp/main.swift
//
//   sudo /tmp/scoped-route set en0 192.168.1.1   # prints the outcome, e.g. "added"
//   sudo /tmp/scoped-route clear                 # "removed" or "absent"
//
// The arguments go through the same checks as the XPC method. Never shipped.

import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let request: ScopedDefaultRequest?
switch (args.first, args.count) {
case ("set", 3):
    guard ScopedDefaultRoute.isValidInterface(args[1]), ScopedDefaultRoute.isValidGateway(args[2]) else {
        print("refused: invalid interface or gateway")
        exit(1)
    }
    request = ScopedDefaultRequest(interface: args[1], gateway: args[2])
case ("clear", 1):
    request = nil
default:
    print("usage: scoped-route set <en interface> <IPv4 router> | clear")
    exit(2)
}
let outcome = HelperTool.routeQueue.sync { ScopedDefaultKeeper.shared.set(request, reason: "scoped-route test driver") }
print(outcome.rawValue)
exit(outcome == .failed ? 1 : 0)
