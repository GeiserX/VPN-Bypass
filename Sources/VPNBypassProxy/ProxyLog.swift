import os

/// The extension's only way to log. It takes a fixed event and integers, never a string, so an
/// app id, an address or a host name cannot reach the log by accident (design 3.8).
enum ProxyEvent {
    case started          // a: 1 when the include rules were taken, 0 when macOS refused them
    case stopped          // a: NEProviderStopReason raw value
    case appMessage       // a: bytes received
}

enum ProxyLog {
    private static let log = OSLog(subsystem: "com.geiserx.vpn-bypass.proxy", category: "proxy")

    static func event(_ e: ProxyEvent, _ a: Int = 0) {
        switch e {
        case .started: os_log("started settingsTaken=%{public}ld", log: log, type: .default, a)
        case .stopped: os_log("stopped reason=%{public}ld", log: log, type: .default, a)
        case .appMessage: os_log("app message bytes=%{public}ld", log: log, type: .info, a)
        }
    }
}
