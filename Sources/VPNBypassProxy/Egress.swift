import Foundation
import Network
import VPNBypassPolicy

/// Tracks the Mac's physical interfaces (Wi-Fi and Ethernet, never a tunnel) with a path
/// monitor, and builds the scoped parameters a claimed flow is re-emitted with (design 3.5).
/// Ported from the spike's `Egress.swift`.
@available(macOS 15, *)
final class Egress {
    private let lock = NSLock()
    private var interfaces: [(name: String, iface: nw_interface_t)] = []
    private let monitor = nw_path_monitor_create()

    init(queue: DispatchQueue) {
        nw_path_monitor_prohibit_interface_type(monitor, nw_interface_type_other)
        nw_path_monitor_prohibit_interface_type(monitor, nw_interface_type_loopback)
        nw_path_monitor_set_queue(monitor, queue)
        nw_path_monitor_set_update_handler(monitor) { [weak self] path in
            var found: [(String, nw_interface_t)] = []
            nw_path_enumerate_interfaces(path) { iface in
                let type = nw_interface_get_type(iface)
                if type == nw_interface_type_wifi || type == nw_interface_type_wired {
                    found.append((String(cString: nw_interface_get_name(iface)), iface))
                }
                return true
            }
            guard let self else { return }
            self.lock.lock()
            self.interfaces = found
            self.lock.unlock()
        }
        nw_path_monitor_start(monitor)
    }

    deinit { nw_path_monitor_cancel(monitor) }

    /// The policy's interface if it is up, else none; with no interface named, the most
    /// preferred physical one (`EgressInterface.pick`).
    func pick(_ name: String?) -> (name: String, iface: nw_interface_t)? {
        lock.lock(); defer { lock.unlock() }
        guard let chosen = EgressInterface.pick(named: name, from: interfaces.map(\.name)) else { return nil }
        return interfaces.first { $0.name == chosen }
    }

    /// Plain TCP, IPv4 only, no-delay, 5 s connect timeout, required to leave on `iface`.
    ///
    /// Built from an empty stack, never the secure-TCP constructor with the "disable TLS"
    /// sentinel: Swift hands that sentinel over as a new block, Network does not recognise it,
    /// and every claimed flow ran a TLS handshake against the server and failed (spike). And no
    /// source-address bind: it moves no bytes behind a VPN's 0/1 routes (pia-foss/desktop#93).
    static func parameters(on iface: nw_interface_t) -> nw_parameters_t {
        let params = nw_parameters_create()
        let stack = nw_parameters_copy_default_protocol_stack(params)
        let tcp = nw_tcp_create_options()
        nw_tcp_options_set_no_delay(tcp, true)
        nw_tcp_options_set_connection_timeout(tcp, 5)
        nw_protocol_stack_set_transport_protocol(stack, tcp)
        if let ip = nw_protocol_stack_copy_internet_protocol(stack) {
            nw_ip_options_set_version(ip, nw_ip_version_4)
        }
        nw_parameters_require_interface(params, iface)
        return params
    }

    /// The kind of interface a bound flow names, for the bound counters (3.4 step 3).
    static func boundKind(_ iface: nw_interface_t?) -> BoundInterface {
        guard let iface else { return .unknown }
        let kind: BoundInterface.Kind
        switch nw_interface_get_type(iface) {
        case nw_interface_type_wifi: kind = .wifi
        case nw_interface_type_wired: kind = .wired
        case nw_interface_type_cellular: kind = .cellular
        case nw_interface_type_loopback: kind = .loopback
        default: kind = .other
        }
        return BoundInterface.classify(name: String(cString: nw_interface_get_name(iface)), kind: kind)
    }
}
