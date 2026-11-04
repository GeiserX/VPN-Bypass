import Foundation
import Network
import NetworkExtension
import VPNBypassPolicy

/// Per-app routing's transparent proxy. This build serves nothing: it declines every flow, so
/// each one carries on as if no proxy were there, and it takes no policy. It exists to prove the
/// packaging (signing, profiles, activation) before any routing code ships (design, section 10
/// step 4).
///
/// `@objc(FlowProxy)` fixes the Objective-C name, so `NEProviderClasses` in Proxy/Info.plist is
/// the bare `FlowProxy` whatever the module is called. CI checks the name is in the binary.
@available(macOS 15, *)
@objc(FlowProxy)
final class FlowProxy: NETransparentProxyProvider {
    private let lock = NSLock()
    private var declined: [String: Int] = [:]

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Fixed include rules (design 3.4): all outbound TCP, minus the protected ranges. They never
        // change at runtime; every decision is made per flow.
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                                                       localNetworkEndpoint: nil, localPrefix: 0,
                                                       protocol: .TCP, direction: .outbound)]
        let ranges = ProtectedRanges.ipv4RuleCIDRs + ProtectedRanges.ipv6CIDRs
        settings.excludedNetworkRules = ranges.map {
            NENetworkRule(destinationNetworkEndpoint: .hostPort(host: .init($0.address), port: .any),
                          prefix: $0.prefix, protocol: .TCP)
        }
        setTunnelNetworkSettings(settings) { error in
            ProxyLog.event(.started, error == nil ? 1 : 0)
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ProxyLog.event(.stopped, reason.rawValue)
        completionHandler()
    }

    /// Never blocks and never claims: returning false hands the flow back to normal routing.
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let reason: FlowDecision.Reason = flow is NEAppProxyTCPFlow ? .noPolicy : .notTCP
        lock.lock()
        declined[reason.rawValue, default: 0] += 1
        lock.unlock()
        return false
    }

    /// Any message (a policy push or a status request) gets the counters back. A policy is not
    /// taken: this build has no routing, so it reports none held.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        ProxyLog.event(.appMessage, messageData.count)
        lock.lock()
        let reply = FlowPolicyReply(declined: declined)
        lock.unlock()
        completionHandler?(try? JSONEncoder().encode(reply))
    }
}
