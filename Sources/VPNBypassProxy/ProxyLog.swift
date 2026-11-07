import os

/// The extension's only way to log. It takes a fixed event and integers, never a string, so an
/// app id, an address or a host name cannot reach the log by accident (design 3.8).
enum ProxyEvent {
    case started          // a: 1 when the include rules were taken, 0 when macOS refused them
    case stopped          // a: NEProviderStopReason raw value
    case appMessage       // a: bytes received
    case policyAccepted   // a: generation, b: matcher count
    case policyRejected   // a: version received (0 when the message was malformed)
    case leaseExpired     // a: expiries so far
    case noInterface      // a flow was claimable but no egress interface was up
    case egressFailed     // a: nw_error code, -1 for the give-up timer
    case flowClosed       // a: bytes up, b: bytes down
}

enum ProxyLog {
    private static let log = OSLog(subsystem: "com.geiserx.vpn-bypass.proxy", category: "proxy")

    static func event(_ e: ProxyEvent, _ a: Int = 0, _ b: Int = 0) {
        switch e {
        case .started: os_log("started settingsTaken=%{public}ld", log: log, type: .default, a)
        case .stopped: os_log("stopped reason=%{public}ld", log: log, type: .default, a)
        case .appMessage: os_log("app message bytes=%{public}ld", log: log, type: .info, a)
        case .policyAccepted:
            os_log("policy accepted generation=%{public}ld matchers=%{public}ld", log: log, type: .default, a, b)
        case .policyRejected: os_log("policy rejected version=%{public}ld", log: log, type: .error, a)
        case .leaseExpired: os_log("lease expired count=%{public}ld, declining every flow", log: log, type: .default, a)
        case .noInterface: os_log("no egress interface up, flow declined", log: log, type: .error)
        case .egressFailed: os_log("egress failed error=%{public}ld", log: log, type: .error, a)
        case .flowClosed: os_log("flow closed up=%{public}ld down=%{public}ld", log: log, type: .info, a, b)
        }
    }
}
