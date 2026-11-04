import Foundation
import Network
import NetworkExtension
import VPNBypassPolicy

/// Carries one claimed TCP flow over an `nw_connection_t` scoped to the physical interface
/// (design 3.5, ported from the spike's `TCPRelay.swift`). One read in flight per direction, so
/// each direction buffers at most one chunk (unbounded buffering gets a provider jetsam-killed).
/// No idle timeout: a long-lived connection stays up as long as both ends keep it.
@available(macOS 15, *)
final class TCPRelay {
    typealias Count = (FlowLedger.Counter, Int) -> Void
    /// Called once: true when the outbound connection got ready, false when it never did.
    typealias Egress = (Bool) -> Void

    /// A connection that never gets ready (waiting for a route, an interface gone) is given up
    /// after this long; the TCP connect timeout covers the plain refusals.
    static let giveUpSeconds: Double = 10
    /// The most one read takes from the server at once.
    static let chunk = 65536

    /// Where the flow goes: an address, or a host name that is looked up on the interface and
    /// checked first (design 3.5 step 4, `NameAnswer`).
    enum Target {
        case endpoint(nw_endpoint_t)
        case name(String, port: String)
    }

    private let flow: NEAppProxyTCPFlow
    private let target: Target
    private let parameters: nw_parameters_t
    private var connection: nw_connection_t?
    private var lookup: NameLookup?
    private let queue: DispatchQueue
    private let interfaceName: String
    private let count: Count
    private var onEgress: Egress?
    private var opened = false
    private var finished = false
    private var upDone = false
    private var downDone = false
    private var bytesUp = 0
    private var bytesDown = 0
    private var retainSelf: TCPRelay?

    /// `parameters` must already carry the flow's metadata (`flow.setMetadata`): only a
    /// connection created from them afterwards is attributed to the original app.
    init(flow: NEAppProxyTCPFlow, target: Target, parameters: nw_parameters_t, interfaceName: String,
         queue: DispatchQueue, count: @escaping Count, onEgress: @escaping Egress) {
        self.flow = flow
        self.target = target
        self.parameters = parameters
        self.queue = queue
        self.interfaceName = interfaceName
        self.count = count
        self.onEgress = onEgress
    }

    private func reportEgress(_ ok: Bool) {
        onEgress?(ok)
        onEgress = nil
    }

    func start() {
        retainSelf = self
        count(.active, 1)
        // Waiting (no route, interface down) never turns into failed by itself; a lookup that
        // hangs is covered too.
        queue.asyncAfter(deadline: .now() + Self.giveUpSeconds) { [weak self] in
            guard let self, !self.opened, !self.finished else { return }
            self.fail(nil)
        }
        queue.async {
            guard !self.finished else { return }
            switch self.target {
            case .endpoint(let endpoint): self.connect(endpoint)
            case .name(let name, let port): self.resolve(name, port: port)
            }
        }
    }

    /// Looks the name up on the egress interface and dials the first answer, unless any answer
    /// is protected: then the flow is closed, since a claimed flow cannot be handed back, and the
    /// app sees a failed connect. A name that points into a private network is never reached
    /// past the VPN: one the app resolves itself arrives by address, which the excluded ranges keep.
    private func resolve(_ name: String, port: String) {
        lookup = NameLookup.start(name, interfaceIndex: if_nametoindex(interfaceName), queue: queue) { [weak self] answers in
            guard let self, !self.finished else { return }
            self.lookup = nil
            switch NameAnswer.check(answers, tunnelNetworks: NameAnswer.tunnelNetworks(NameLookup.interfaceAddresses())) {
            case .dial(let address):
                self.connect(nw_endpoint_create_host(ProtectedRanges.dotted(address), port))
            case .protected:
                // Not a failure of the interface: its health is left alone.
                self.onEgress = nil
                self.count(.nameProtected, 1)
                self.closeAll(NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.hostUnreachable.rawValue))
            case .noAnswer:
                self.fail(nil)
            }
        }
    }

    private func connect(_ endpoint: nw_endpoint_t) {
        let connection = nw_connection_create(endpoint, parameters)
        self.connection = connection
        nw_connection_set_queue(connection, queue)
        nw_connection_set_state_changed_handler(connection) { [weak self] state, error in
            guard let self else { return }
            switch state {
            case nw_connection_state_ready: self.ready()
            case nw_connection_state_failed: self.fail(error)
            // Waiting before it ever got ready means no route out the interface: fail now rather
            // than hold the app's connect until the give-up timer.
            case nw_connection_state_waiting where !self.opened: self.fail(error)
            case nw_connection_state_cancelled: self.finish()
            default: break
            }
        }
        nw_connection_start(connection)
    }

    private func ready() {
        reportEgress(true)
        guard let connection else { return }
        var onInterface = false
        if let path = nw_connection_copy_current_path(connection) {
            nw_path_enumerate_interfaces(path) { iface in
                if String(cString: nw_interface_get_name(iface)) == self.interfaceName { onInterface = true }
                return true
            }
        }
        if !onInterface { count(.egressOffInterface, 1) }
        flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                if error != nil {
                    self.count(.flowOpenFailed, 1)
                    self.closeAll(Self.aborted)
                    return
                }
                self.opened = true
                self.pumpUp()
                self.pumpDown()
            }
        }
    }

    private func fail(_ error: nw_error_t?) {
        guard !finished else { return }
        if !opened {
            reportEgress(false)
            count(.egressFailed, 1)
            ProxyLog.event(.egressFailed, error.map { Int(nw_error_get_error_code($0)) } ?? -1)
            // A claimed flow cannot be handed back: close it so the app sees a failed connect.
            closeAll(NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.hostUnreachable.rawValue))
            return
        }
        count(.aborted, 1)
        closeAll(Self.aborted)
    }

    /// App to server.
    private func pumpUp() {
        guard let connection else { return }
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                if error != nil { self.count(.appReset, 1); self.closeAll(Self.aborted); return }
                guard let data, !data.isEmpty else {
                    // EOF from the app: half-close towards the server, and finish only once that
                    // final send is done, so the connection is not cancelled under it.
                    nw_connection_send(connection, nil, _nw_content_context_final_send, true) { _ in
                        self.queue.async {
                            self.upDone = true
                            self.finishIfDone()
                        }
                    }
                    return
                }
                let content = data.withUnsafeBytes { DispatchData(bytes: $0) }
                nw_connection_send(connection, content as __DispatchData, _nw_content_context_default_message,
                                   false) { sendError in
                    self.queue.async {
                        if sendError != nil { self.count(.aborted, 1); self.closeAll(Self.aborted); return }
                        self.bytesUp += data.count
                        self.pumpUp()
                    }
                }
            }
        }
    }

    /// Server to app.
    private func pumpDown() {
        guard let connection else { return }
        nw_connection_receive(connection, 1, UInt32(Self.chunk)) { [weak self] content, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let content, (content as DispatchData).count > 0 {
                let data = Data(content as DispatchData)
                self.flow.write(data) { writeError in
                    self.queue.async {
                        if writeError != nil { self.count(.appReset, 1); self.closeAll(Self.aborted); return }
                        self.bytesDown += data.count
                        // A last chunk can come with an error: the app must see the abort, not a clean end.
                        if error != nil { self.count(.aborted, 1); self.closeAll(Self.aborted); return }
                        if isComplete { self.endDown() } else { self.pumpDown() }
                    }
                }
                return
            }
            if error != nil { self.count(.aborted, 1); self.closeAll(Self.aborted); return }
            if isComplete { self.endDown(); return }
            self.pumpDown()
        }
    }

    private func endDown() {
        flow.closeWriteWithError(nil)
        downDone = true
        finishIfDone()
    }

    private func finishIfDone() {
        if upDone && downDone { closeAll() }
    }

    /// A transport failure after the flow opened: the app must see an error, not a clean end that
    /// would pass a truncated response off as complete.
    private static let aborted = NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.aborted.rawValue)

    /// Closes both directions of the flow, with `error` when the relay broke (nil only for a clean end).
    private func closeAll(_ error: Error? = nil) {
        guard !finished else { return }
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        lookup?.cancel()
        lookup = nil
        if let connection { nw_connection_cancel(connection) }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        count(.active, -1)
        count(.bytesUp, bytesUp)
        count(.bytesDown, bytesDown)
        ProxyLog.event(.flowClosed, bytesUp, bytesDown)
        retainSelf = nil
    }
}
