// DNSCapture.swift
// The opt-in DNS Lookups capture (#176): one root tcpdump that reads outgoing DNS queries.
//
// Read-only by construction. The arguments are fixed here and nothing the caller sends reaches
// them; `-p` keeps every interface out of promiscuous mode, `-n` stops tcpdump resolving
// addresses (which would add DNS traffic of its own), the filter takes queries only, and
// `-Q out` keeps them to the ones this Mac sends: a LAN device asking a resolver on this Mac
// is not this Mac's lookup. A query to a local resolver on loopback still counts.
// Names stay in memory until the app drains them and are never logged.
//
// The capture runs on a lease. The app drains every few seconds; when nothing has drained for
// `leaseSeconds` (the app quit, crashed or hung), the capture stops on its own. If the helper
// itself exits, tcpdump's next line goes into a pipe nobody reads, and SIGPIPE ends it.

import Foundation

final class DNSCapture {
    static let shared = DNSCapture()

    static let tcpdumpPath = "/usr/sbin/tcpdump"
    static let arguments = ["-i", "any", "-Q", "out", "-p", "-l", "-n", "-t", "-s", "512", "udp dst port 53"]
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
            // Read only when tcpdump exits at once; while it runs, drained and discarded.
            let errors = Pipe()
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                // A stopped capture's last output must not land in the next one's buffer.
                self?.queue.async {
                    guard let self, let process, self.process === process else { return }
                    self.buffer.append(data)
                }
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
            // tcpdump that cannot capture (no BPF device, a refused interface) exits at once
            // with its reason on stderr. Report that instead of a capture that never yields.
            let deadline = DispatchTime.now() + .milliseconds(500)
            while process.isRunning && DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            guard process.isRunning else {
                output.fileHandleForReading.readabilityHandler = nil
                let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n").last.map { String($0.prefix(200)) } ?? "status \(process.terminationStatus)"
                helperLog.error("DNS capture: tcpdump exited at once: \(said, privacy: .public)")
                return (false, "tcpdump exited at once: \(said)")
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
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
