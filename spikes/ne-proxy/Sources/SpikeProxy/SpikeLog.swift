import os

/// The extension's only way to log. It takes a fixed event and integers, never a string, so an app
/// id, an address or a host name cannot reach the log by accident.
enum SpikeEvent {
    case started          // a: include scope (0 all TCP, else the port)
    case stopped          // a: NEProviderStopReason raw value
    case policyAccepted   // a: generation, b: matcher count
    case policyRejected   // a: version received
    case leaseExpired     // a: generation
    case claimed          // a: 0 app, 1 hostname
    case egressReady      // a: 1 on the policy interface, 0 elsewhere
    case egressFailed     // a: nw_error code
    case flowClosed       // a: bytes up, b: bytes down
    case noInterface
    case settingsFailed
}

enum SpikeLog {
    private static let log = OSLog(subsystem: "com.geiserx.vpn-bypass.spike.proxy", category: "spike")

    static func event(_ e: SpikeEvent, _ a: Int = 0, _ b: Int = 0) {
        switch e {
        case .started: os_log("started scope=%{public}ld", log: log, type: .default, a)
        case .stopped: os_log("stopped reason=%{public}ld", log: log, type: .default, a)
        case .policyAccepted: os_log("policy accepted generation=%{public}ld matchers=%{public}ld", log: log, type: .default, a, b)
        case .policyRejected: os_log("policy rejected version=%{public}ld", log: log, type: .error, a)
        case .leaseExpired: os_log("lease expired generation=%{public}ld", log: log, type: .default, a)
        case .claimed: os_log("flow claimed by=%{public}ld", log: log, type: .info, a)
        case .egressReady: os_log("egress ready onPolicyInterface=%{public}ld", log: log, type: .info, a)
        case .egressFailed: os_log("egress failed error=%{public}ld", log: log, type: .error, a)
        case .flowClosed: os_log("flow closed up=%{public}ld down=%{public}ld", log: log, type: .info, a, b)
        case .noInterface: os_log("no physical interface, flow declined", log: log, type: .error)
        case .settingsFailed: os_log("setTunnelNetworkSettings failed", log: log, type: .fault)
        }
    }
}
