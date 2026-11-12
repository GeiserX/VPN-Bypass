// GeoDownloader.swift
// The download of a geoip.dat or geosite.dat: an https GET to a temporary file that stops when it
// has received more than the limit, instead of finishing a multi-gigabyte response and checking its
// size afterwards. The limit is checked up front from the response's length when it gives one, and
// as the bytes arrive when it does not.

import Foundation

enum GeoDownloadError: Error, Equatable {
    /// The response is, or became, larger than the limit.
    case tooLarge
    case badResponse(Int)
}

final class GeoDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let limit: Int64
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var downloaded: URL?
    private var failure: Error?
    private var session: URLSession?

    /// `configuration` is the session's; tests give one with a stub protocol.
    init(limit: Int, configuration: URLSessionConfiguration = .ephemeral) {
        self.limit = Int64(limit)
        // The request's 60 s is an idle timeout: a server that sends a few bytes at a time would keep a
        // download (and the Updating state that queues every later one) open for URLSession's default
        // of 7 days. The whole transfer gets 5 minutes; the largest list is under 20 MB.
        configuration.timeoutIntervalForResource = min(configuration.timeoutIntervalForResource, Self.resourceTimeout)
        self.configuration = configuration
    }

    /// The longest a whole download may take.
    static let resourceTimeout: TimeInterval = 300

    /// The session's whole-transfer limit, for the tests.
    var resourceTimeout: TimeInterval { configuration.timeoutIntervalForResource }

    /// Downloads `url` and returns the temporary file it was saved to, which the caller removes.
    func fetch(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var request = URLRequest(url: url, timeoutInterval: 60)
                request.setValue("VPN-Bypass", forHTTPHeaderField: "User-Agent")
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    /// Stops a response that is, or has grown, past the limit.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > limit) {
            setFailure(GeoDownloadError.tooLarge)
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            setFailure(GeoDownloadError.badResponse((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0))
            return
        }
        // The system removes `location` when this returns, so it is moved now.
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("geo-\(UUID().uuidString).dat")
        do {
            try FileManager.default.moveItem(at: location, to: saved)
            lock.lock(); downloaded = saved; lock.unlock()
        } catch {
            setFailure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let saved = downloaded
        let recorded = failure
        lock.unlock()
        session.finishTasksAndInvalidate()
        guard let continuation else { return }
        if let recorded {
            if let saved { try? FileManager.default.removeItem(at: saved) }
            continuation.resume(throwing: recorded)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let saved {
            continuation.resume(returning: saved)
        } else {
            continuation.resume(throwing: URLError(.cannotCreateFile))
        }
    }

    private func setFailure(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }
}
