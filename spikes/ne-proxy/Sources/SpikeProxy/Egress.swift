import Foundation
import Network

/// Tracks the Mac's physical interfaces (Wi-Fi and Ethernet, never a utun) through a path monitor,
/// and builds the scoped parameters a claimed flow is re-emitted with.
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

    /// The named interface if the policy names one and it is up, else the most preferred physical one.
    func pick(_ name: String?) -> (name: String, iface: nw_interface_t)? {
        lock.lock(); defer { lock.unlock() }
        if let name, !name.isEmpty { return interfaces.first { $0.name == name } }
        return interfaces.first
    }

    /// Plain TCP, IPv4 only, no-delay, 5 s connect timeout, required to leave on `iface`.
    ///
    /// Built from an empty stack, not `nw_parameters_create_secure_tcp(_nw_parameters_configure_protocol_disable, …)`:
    /// Swift hands that sentinel over as a fresh block, Network does not recognise it, and the
    /// connection ran a TLS handshake against port 80 ("bad protocol version"), so every claimed
    /// flow failed.
    static func parameters(on iface: nw_interface_t) -> nw_parameters_t {
        let params = nw_parameters_create()
        let stack = nw_parameters_copy_default_protocol_stack(params)
        let tcp = nw_tcp_create_options()
        nw_tcp_options_set_no_delay(tcp, true)
        nw_tcp_options_set_connection_timeout(tcp, 5)
        nw_protocol_stack_set_transport_protocol(stack, tcp)
        let ip = nw_protocol_stack_copy_internet_protocol(stack)
        if let ip { nw_ip_options_set_version(ip, nw_ip_version_4) }
        nw_parameters_require_interface(params, iface)
        return params
    }
}
