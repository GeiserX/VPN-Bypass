import Foundation
import Network
import NetworkExtension

/// Integer counters, reported to the app in the status reply.
final class Counters {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func add(_ key: String, _ n: Int = 1) {
        lock.lock(); values[key, default: 0] += n; lock.unlock()
    }

    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Carries one claimed TCP flow over an `nw_connection_t` scoped to the physical interface.
/// One read in flight per direction, so each direction buffers at most one chunk.
final class TCPRelay {
    private let flow: NEAppProxyTCPFlow
    private let connection: nw_connection_t
    private let queue: DispatchQueue
    private let interfaceName: String
    private let counters: Counters
    private var opened = false
    private var finished = false
    private var upDone = false
    private var downDone = false
    private var bytesUp = 0
    private var bytesDown = 0
    private var retainSelf: TCPRelay?

    init(flow: NEAppProxyTCPFlow, endpoint: nw_endpoint_t, parameters: nw_parameters_t, interfaceName: String,
         queue: DispatchQueue, counters: Counters) {
        self.flow = flow
        // setMetadata was called on `parameters` before this point: only a connection created from
        // them afterwards carries the original app's metadata.
        self.connection = nw_connection_create(endpoint, parameters)
        self.queue = queue
        self.interfaceName = interfaceName
        self.counters = counters
    }

    func start() {
        retainSelf = self
        counters.add("activeFlows")
        nw_connection_set_queue(connection, queue)
        nw_connection_set_state_changed_handler(connection) { [weak self] state, error in
            guard let self else { return }
            switch state {
            case nw_connection_state_ready:
                self.ready()
            case nw_connection_state_failed:
                self.fail(error)
            case nw_connection_state_cancelled:
                self.finish()
            default:
                break
            }
        }
        nw_connection_start(connection)
        // Waiting (no route, interface down) never turns into failed by itself.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.opened, !self.finished else { return }
            self.fail(nil)
        }
    }

    private func ready() {
        var onPolicyInterface = false
        if let path = nw_connection_copy_current_path(connection) {
            nw_path_enumerate_interfaces(path) { iface in
                if String(cString: nw_interface_get_name(iface)) == self.interfaceName { onPolicyInterface = true }
                return true
            }
        }
        counters.add(onPolicyInterface ? "egressOnPolicyInterface" : "egressOffPolicyInterface")
        SpikeLog.event(.egressReady, onPolicyInterface ? 1 : 0)
        flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if error != nil {
                    self.counters.add("flowOpenFailed")
                    self.closeAll()
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
            counters.add("egressFailed")
            SpikeLog.event(.egressFailed, error.map { Int(nw_error_get_error_code($0)) } ?? -1)
            // A claimed flow cannot be handed back: close it so the app sees a failed connect.
            let err = NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.hostUnreachable.rawValue)
            flow.closeReadWithError(err)
            flow.closeWriteWithError(err)
        }
        closeAll()
    }

    /// App to server.
    private func pumpUp() {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                guard error == nil, let data, !data.isEmpty else {
                    // EOF from the app: half-close towards the server.
                    nw_connection_send(self.connection, nil, _nw_content_context_final_send, true) { _ in }
                    self.upDone = true
                    self.finishIfDone()
                    return
                }
                self.bytesUp += data.count
                let content = data.withUnsafeBytes { DispatchData(bytes: $0) }
                nw_connection_send(self.connection, content as __DispatchData, _nw_content_context_default_message, false) { sendError in
                    self.queue.async {
                        if sendError != nil { self.closeAll(); return }
                        self.pumpUp()
                    }
                }
            }
        }
    }

    /// Server to app.
    private func pumpDown() {
        nw_connection_receive(connection, 1, 65536) { [weak self] content, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let content, (content as DispatchData).count > 0 {
                let data = Data(content as DispatchData)
                self.bytesDown += data.count
                self.flow.write(data) { writeError in
                    self.queue.async {
                        if writeError != nil { self.closeAll(); return }
                        if isComplete { self.endDown() } else { self.pumpDown() }
                    }
                }
                return
            }
            if error != nil { self.closeAll(); return }
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

    private func closeAll() {
        guard !finished else { return }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        nw_connection_cancel(connection)
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        counters.add("activeFlows", -1)
        counters.add("bytesUp", bytesUp)
        counters.add("bytesDown", bytesDown)
        SpikeLog.event(.flowClosed, bytesUp, bytesDown)
        retainSelf = nil
    }
}
