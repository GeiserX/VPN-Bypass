import Foundation

// spike-fetch: the live test's matched client. Signed as com.geiserx.vpn-bypass.spike.fetch, it
// connects by name through URLSession, so its flows carry both an app id and a host name.
//
//   spike-fetch URL                      one request, prints status and the first 200 bytes
//   spike-fetch --every SECONDS URL      a fresh connection each second for SECONDS, one line each
//   spike-fetch --download URL           streams the body, prints bytes per second until it ends

let usage = "usage: spike-fetch [--every SECONDS | --download] URL"
var args = Array(CommandLine.arguments.dropFirst())
var every: Int?
var download = false
while let a = args.first, a.hasPrefix("--") {
    args.removeFirst()
    switch a {
    case "--every":
        guard let n = args.first.flatMap(Int.init), n > 0 else { FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(2) }
        args.removeFirst()
        every = n
    case "--download":
        download = true
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(2)
    }
}
guard args.count == 1, let url = URL(string: args[0]), url.scheme != nil else {
    FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(2)
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

/// A new session per request, so every request is a new TCP connection (a new flow).
func fetchOnce(_ url: URL, timeout: TimeInterval) -> String {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.httpMaximumConnectionsPerHost = 1
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var req = URLRequest(url: url)
    req.setValue("close", forHTTPHeaderField: "Connection")
    let sem = DispatchSemaphore(value: 0)
    var line = ""
    let started = Date()
    session.dataTask(with: req) { data, resp, error in
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let error {
            line = "error \((error as NSError).code) after \(ms) ms: \(error.localizedDescription)"
        } else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: (data ?? Data()).prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            line = "\(code) in \(ms) ms: \(body)"
        }
        sem.signal()
    }.resume()
    sem.wait()
    return line
}

final class Streamer: NSObject, URLSessionDataDelegate {
    var total = 0
    var window = 0
    let done = DispatchSemaphore(value: 0)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        total += data.count
        window += data.count
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            print("\(stamp())  stream ended with error \((error as NSError).code): \(error.localizedDescription), \(total) bytes")
        } else {
            print("\(stamp())  stream complete, \(total) bytes")
        }
        done.signal()
    }
}

if download {
    let s = Streamer()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: config, delegate: s, delegateQueue: nil)
    session.dataTask(with: url).resume()
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        print("\(stamp())  \(s.window) B/s, \(s.total) total")
        s.window = 0
    }
    timer.resume()
    s.done.wait()
    exit(0)
} else if let every {
    for _ in 0..<every {
        let t0 = Date()
        print("\(stamp())  \(fetchOnce(url, timeout: 5))")
        let left = 1 - Date().timeIntervalSince(t0)
        if left > 0 { Thread.sleep(forTimeInterval: left) }
    }
} else {
    print(fetchOnce(url, timeout: 15))
}
