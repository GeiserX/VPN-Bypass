// DNSCapture.swift
// The opt-in DNS Lookups capture (#176): one root tcpdump that reads outgoing DNS queries.
//
// Read-only by construction. The arguments are fixed here and nothing the caller sends reaches
// them; `-p` keeps every interface out of promiscuous mode, `-n` stops tcpdump resolving
// addresses (which would add DNS traffic of its own), and the filter takes queries only.
// Names stay in memory until the app drains them and are never logged.
//
// The capture runs on a lease. The app drains every few seconds; when nothing has drained for
// `leaseSeconds` (the app quit, crashed or hung), the capture stops on its own. If the helper
// itself exits, tcpdump's next line goes into a pipe nobody reads, and SIGPIPE ends it.

import Foundation

final class DNSCapture {
    static let shared = DNSCapture()

    static let tcpdumpPath = "/usr/sbin/tcpdump"
    static let arguments = ["-i", "any", "-p", "-l", "-n", "-t", "-s", "512", "udp dst port 53"]
    static let leaseSeconds: TimeInterval = 60

    private let queue = DispatchQueue(label: "com.geiserx.vpnbypass.helper.dnscapture")
    private var process: Process?
    private var buffer = DNSQueryBuffer()
    private var lastDrain = DispatchTime.now()
    private var leaseTimer: DispatchSourceTimer?

    /// Starts the capture, or renews the lease of one already running.
    func start() -> (Bool, String?) {
        queue.sync {
            lastDrain = .now()
            if let process, process.isRunning { return (true, nil) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.tcpdumpPath)
            process.arguments = Self.arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.queue.async { self?.buffer.append(data) }
            }
            process.terminationHandler = { [weak self] ended in
                self?.queue.async {
                    guard let self, self.process === ended else { return }
                    helperLog.info("DNS capture ended (tcpdump exit \(ended.terminationStatus, privacy: .public))")
                    self.process = nil
                    self.cancelLease()
                }
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                helperLog.error("DNS capture failed to start: \(error.localizedDescription, privacy: .public)")
                return (false, "tcpdump could not start: \(error.localizedDescription)")
            }
            self.process = process
            buffer = DNSQueryBuffer()
            armLease()
            helperLog.info("DNS capture started (tcpdump pid \(process.processIdentifier, privacy: .public))")
            return (true, nil)
        }
    }

    func stop() {
        queue.sync { stopLocked(reason: "stopped by the app") }
    }

    /// The names since the last drain, and whether the capture is still running. A drain
    /// renews the lease.
    func drain() -> (Bool, [String]) {
        queue.sync {
            lastDrain = .now()
            let running = process?.isRunning ?? false
            return (running, buffer.drain())
        }
    }

    private func stopLocked(reason: String) {
        cancelLease()
        buffer = DNSQueryBuffer()
        guard let process else { return }
        self.process = nil
        if process.isRunning { process.terminate() }
        helperLog.info("DNS capture \(reason, privacy: .public)")
    }

    private func armLease() {
        cancelLease()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastDrain.uptimeNanoseconds) / 1_000_000_000
            if idle > Self.leaseSeconds { self.stopLocked(reason: "stopped: the app stopped asking") }
        }
        leaseTimer = timer
        timer.resume()
    }

    private func cancelLease() {
        leaseTimer?.cancel()
        leaseTimer = nil
    }
}
