import Foundation

/// A byte range of the output file handled by one connection. `end` is inclusive;
/// `Int64.max` means "until the server stops" (size unknown).
public struct Segment: Codable {
    public var start: Int64
    public var end: Int64
    public var pos: Int64

    var remaining: Int64 { end == .max ? .max : end - pos + 1 }
    var done: Bool { end != .max && pos > end }
}

public struct HTTPResumeState: Codable {
    public var total: Int64?
    public var acceptsRanges = false
    public var segments: [Segment] = []
    public var etag: String?
    public var lastModified: String?
    public var finalURL: String?
    public var filename: String?
    public var mime: String?

    public init() {}
    public var received: Int64 { segments.reduce(0) { $0 + max(0, $1.pos - $1.start) } }

    /// A downloaded byte range usable to check that a renewed link serves the same file.
    public var verificationRange: (start: Int64, end: Int64)? {
        guard let s = segments.max(by: { ($0.pos - $0.start) < ($1.pos - $1.start) }), s.pos - s.start > 0 else { return nil }
        return (s.start, s.start + min(s.pos - s.start, 65536) - 1)
    }
}

/// Multi-connection HTTP downloader with *dynamic segmentation*:
///
/// 1. One probe connection asks for `bytes=0-`. A `206` with `Content-Range` gives
///    the size and proves the server supports ranges.
/// 2. Whenever a connection slot is free (up to 32), the segment with the most bytes left
///    is split in half and a new connection starts on the second half. The first one keeps
///    going and is cut off when it reaches the new boundary. Nothing is downloaded twice.
/// 3. Each connection has its own URLSession, so they really are separate TCP connections
///    (one shared session would multiplex them over a single HTTP/2 connection).
/// 4. Connections write straight into a sparse, pre-sized `.part` file at their own offset.
///    Pausing keeps the segment table, so resuming fetches only missing bytes.
/// 5. Network drops never fail a download: it waits for connectivity and continues. When
///    the server keeps refusing the address (401/403/404/410) with no data flowing, the link
///    has expired: the download stops with `CastnetError.linkExpired`, keeping every byte,
///    so it can continue with a fresh link.
public final class SegmentedDownloader: NSObject, DownloadEngine, URLSessionDataDelegate, URLSessionTaskDelegate {
    public let events = EngineEvents()
    public let partURL: URL

    private let url: URL
    private let ctx: RequestContext
    private let config: EngineConfig
    private let queue: OperationQueue
    private var state: HTTPResumeState
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var sessions: [ObjectIdentifier: URLSession] = [:]
    private var retryPending: Set<Int> = []
    private var segStatus: [Int: String] = [:]
    private var file: FileHandle?
    private var stopped = false
    private var finished = false
    private var lastReport = Date.distantPast
    private var lastSnapshot = Date.distantPast
    private var linkErrors = 0          // consecutive link-level refusals without data
    private var otherFailures = 0       // consecutive server errors without data
    private var waitingForNetwork = false
    private var restarts = 0
    private var maxConns: Int
    private var generation = 0          // bumps on restart so stale callbacks are ignored

    private let snapLock = NSLock()
    private var snapshot: HTTPResumeState

    private struct Conn {
        let index: Int
        var retries: Int
        var probe: Bool
        var generation: Int
        var validated = false
        var httpError: Int?
    }

    public init(url: URL, ctx: RequestContext, config: EngineConfig, partURL: URL, resume: HTTPResumeState? = nil) {
        self.url = url
        self.ctx = ctx
        self.config = config
        self.partURL = partURL
        self.state = resume ?? HTTPResumeState()
        self.snapshot = self.state
        self.maxConns = max(1, min(32, config.connections))
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "castnet.http.\(partURL.lastPathComponent)"
        super.init()
    }

    /// Latest consistent copy of the segment table (safe from any thread).
    public var resumeState: HTTPResumeState {
        snapLock.lock(); defer { snapLock.unlock() }
        return snapshot
    }

    // MARK: control

    public func start() {
        queue.addOperation { [self] in
            stopped = false
            finished = false
            let fm = FileManager.default
            let canResume = !state.segments.isEmpty && state.acceptsRanges && fm.fileExists(atPath: partURL.path)
            if !canResume {
                fm.createFile(atPath: partURL.path, contents: nil)
                openFile()
                freshProbe()
            } else {
                openFile()
                report(force: true)
                rebalance()
                checkDone()
            }
        }
    }

    public func pause() {
        queue.addOperation { [self] in
            guard !stopped else { return }
            stopped = true
            dropAllSessions()
            closeFile()
            publishSnapshot()
        }
        queue.waitUntilAllOperationsAreFinished()
    }

    public func cancel() {
        pause()
        try? FileManager.default.removeItem(at: partURL)
    }

    // MARK: internals (all on `queue`)

    private func dropAllSessions() {
        for s in sessions.values { s.invalidateAndCancel() }
        sessions.removeAll()
        conns.removeAll()
        retryPending.removeAll()
        generation += 1
    }

    private func openFile() {
        closeFile()
        file = try? FileHandle(forWritingTo: partURL)
    }

    private func closeFile() {
        try? file?.synchronize()
        try? file?.close()
        file = nil
    }

    private func freshProbe() {
        state.segments = [Segment(start: 0, end: .max, pos: 0)]
        state.total = nil
        state.acceptsRanges = false
        try? file?.truncate(atOffset: 0)
        launch(0, probe: true)
    }

    private func restartFromScratch(_ why: String) {
        restarts += 1
        guard restarts <= 3 else { return fail(CastnetError.invalid("Download restarted too often: \(why)")) }
        dropAllSessions()
        freshProbe()
    }

    private func launch(_ i: Int, probe: Bool = false, retries: Int = 0) {
        guard !stopped, !finished else { return }
        let seg = state.segments[i]
        var range: String?
        if probe {
            range = "bytes=0-"
        } else if state.acceptsRanges {
            range = seg.end == .max ? "bytes=\(seg.pos)-" : "bytes=\(seg.pos)-\(seg.end)"
        }
        var extra = ["Accept-Encoding": "identity"]
        if !probe, state.acceptsRanges {
            if let etag = state.etag, !etag.hasPrefix("W/") { extra["If-Range"] = etag }
            else if let lm = state.lastModified { extra["If-Range"] = lm }
        }
        // One session per connection = one TCP connection per segment.
        let cfg = RequestContext.sessionConfiguration(maxConnectionsPerHost: 2)
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: ctx.makeRequest(url, range: range, extra: extra))
        let id = ObjectIdentifier(task)
        conns[id] = Conn(index: i, retries: retries, probe: probe, generation: generation)
        sessions[id] = session
        segStatus[i] = retries > 0 ? "Reconnecting (try \(retries + 1))…" : "Connecting…"
        task.resume()
    }

    private func finishSession(for task: URLSessionTask) {
        sessions.removeValue(forKey: ObjectIdentifier(task))?.finishTasksAndInvalidate()
    }

    /// Fill free connection slots: restart orphaned segments, then split the largest one.
    private func rebalance() {
        guard !stopped, !finished, !waitingForNetwork, state.acceptsRanges, state.total != nil else { return }
        var active = Set(conns.values.map(\.index))
        while conns.count < maxConns {
            if let i = state.segments.indices.first(where: { !state.segments[$0].done && !active.contains($0) && !retryPending.contains($0) }) {
                launch(i)
                active.insert(i)
                continue
            }
            let splittable = state.segments.indices.filter {
                active.contains($0) && state.segments[$0].remaining >= 2 * config.minSplitBytes
            }
            guard let i = splittable.max(by: { state.segments[$0].remaining < state.segments[$1].remaining }) else { break }
            let seg = state.segments[i]
            let mid = seg.pos + seg.remaining / 2
            state.segments[i].end = mid - 1
            state.segments.append(Segment(start: mid, end: seg.end, pos: mid))
            let ni = state.segments.count - 1
            launch(ni)
            active.insert(ni)
        }
    }

    private func checkDone() {
        guard !finished, !stopped, !state.segments.isEmpty, state.segments.allSatisfy(\.done) else { return }
        finished = true
        dropAllSessions()
        if let total = state.total { try? file?.truncate(atOffset: UInt64(total)) }
        closeFile()
        report(force: true)
        publishSnapshot()
        events.completed?(.success([partURL]))
    }

    private func fail(_ error: Error) {
        guard !stopped, !finished else { return }
        stopped = true
        dropAllSessions()
        closeFile()
        publishSnapshot()
        events.completed?(.failure(error))
    }

    private func scheduleRetry(_ conn: Conn, error: Error?) {
        let i = conn.index
        let network = error?.isNetworkFailure ?? false
        if let code = conn.httpError, isLinkError(code) {
            linkErrors += 1
            // Too many parallel connections is a common cause of 403/429: back off first.
            if maxConns > 1, conns.count > 0 { maxConns = max(1, min(maxConns - 1, conns.count)) }
            // Keeps refusing with nothing flowing: the signed address expired.
            if linkErrors >= 3 && conns.values.allSatisfy({ !$0.validated }) {
                return fail(CastnetError.linkExpired)
            }
        } else if !network {
            otherFailures += 1
            if let code = conn.httpError, [429, 503].contains(code), maxConns > 1 { maxConns = max(1, maxConns - 1) }
            if otherFailures > 40 {
                return fail(conn.httpError.map { CastnetError.http($0, url.absoluteString) } ?? CastnetError.invalid("The server keeps failing"))
            }
        }
        if !state.acceptsRanges && state.segments.first.map({ $0.pos > 0 }) == true {
            return restartFromScratch("server does not support resuming")
        }
        retryPending.insert(i)
        segStatus[i] = network ? "Waiting for network…" : "Retrying…"
        let gen = generation
        let retry: () -> Void = { [weak self] in
            guard let q = self?.queue else { return }
            q.addOperation {
                guard let self, !self.stopped, !self.finished, gen == self.generation else { return }
                self.retryPending.remove(i)
                self.waitingForNetwork = false
                if i < self.state.segments.count, !self.state.segments[i].done,
                   !self.conns.values.contains(where: { $0.index == i }) {
                    self.launch(i, retries: conn.retries + 1)
                }
                self.rebalance()
            }
        }
        if network && !NetworkWatcher.shared.isOnline {
            waitingForNetwork = true
            report(force: true)
            NetworkWatcher.shared.whenOnline { DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: retry) }
        } else {
            let linkErr = conn.httpError.map(isLinkError) ?? false
            let delay = linkErr ? 0.5 * pow(2.0, Double(min(conn.retries, 3)))
                : min(network ? 15.0 : 30.0, pow(2.0, Double(min(conn.retries, 5))))
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: retry)
        }
    }

    private func publishSnapshot() {
        snapLock.lock()
        snapshot = state
        snapLock.unlock()
    }

    private var segmentViews: [SegmentView] {
        let active = Set(conns.values.filter(\.validated).map(\.index))
        return state.segments.enumerated().map { i, s in
            let status = s.done ? "Done" : active.contains(i) ? "Receiving data…" : (segStatus[i] ?? "Waiting")
            return SegmentView(start: s.start, end: s.end == .max ? (state.total.map { $0 - 1 } ?? s.pos) : s.end,
                               pos: s.pos, active: active.contains(i), status: status)
        }
    }

    private func report(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastReport) < 0.25 { return }
        lastReport = now
        let active = conns.values.filter(\.validated).count
        let detail = waitingForNetwork ? "Waiting for network…"
            : state.acceptsRanges ? "\(active) connection\(active == 1 ? "" : "s")" : "single connection"
        events.progress?(EngineProgress(received: state.received, total: state.total, detail: detail,
                                        segments: segmentViews, resumable: state.acceptsRanges))
        if now.timeIntervalSince(lastSnapshot) > 2 {
            lastSnapshot = now
            publishSnapshot()
        }
    }

    private static func contentRange(_ http: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
        guard let v = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let parts = v.replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"), let start = Int64(parts[0][..<dash]) else { return nil }
        return (start, Int64(parts[1]))
    }

    private func isCurrent(_ task: URLSessionTask) -> Conn? {
        guard let c = conns[ObjectIdentifier(task)], c.generation == generation else { return nil }
        return c
    }

    // MARK: URLSession delegate

    public func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let newURL = request.url else { return completionHandler(request) }
        var extra: [String: String] = [:]
        for k in ["Accept-Encoding", "If-Range"] { if let v = task.originalRequest?.value(forHTTPHeaderField: k) { extra[k] = v } }
        var r = ctx.makeRequest(newURL, range: task.originalRequest?.value(forHTTPHeaderField: "Range"), extra: extra)
        r.httpMethod = request.httpMethod ?? "GET"
        completionHandler(r)
    }

    public func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = ObjectIdentifier(dataTask)
        guard var conn = isCurrent(dataTask), let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        let code = http.statusCode
        if conn.probe {
            guard code == 200 || code == 206 else {
                conn.httpError = code
                conns[id] = conn
                return completionHandler(.cancel)
            }
            state.finalURL = http.url?.absoluteString
            state.etag = http.value(forHTTPHeaderField: "ETag")
            state.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            state.filename = filenameFromContentDisposition(http.value(forHTTPHeaderField: "Content-Disposition"))
            state.mime = http.mimeType
            events.metadata?(state.filename, state.mime)
            if code == 206, let cr = Self.contentRange(http), cr.start == 0, let total = cr.total {
                state.total = total
                state.acceptsRanges = true
                state.segments[conn.index].end = total - 1
                try? file?.truncate(atOffset: UInt64(total)) // sparse pre-allocation
            } else {
                let len = http.expectedContentLength
                state.total = len > 0 ? len : nil
                let ar = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
                state.acceptsRanges = ar && state.total != nil && code == 200
                if let t = state.total { state.segments[conn.index].end = t - 1 }
            }
            conn.validated = true
            conns[id] = conn
            completionHandler(.allow)
            publishSnapshot()
            if state.total == 0 { state.segments[conn.index].end = -1; checkDone(); return }
            rebalance()
            return
        }

        let seg = state.segments[conn.index]
        if code == 206, let cr = Self.contentRange(http), cr.start == seg.pos {
            if let t = cr.total, let known = state.total, t != known {
                // Same address, different file: not resumable.
                completionHandler(.cancel)
                return restartFromScratch("the file on the server changed")
            }
            conn.validated = true
            conns[id] = conn
            return completionHandler(.allow)
        }
        if code == 200, seg.pos == 0, !state.acceptsRanges {
            conn.validated = true
            conns[id] = conn
            return completionHandler(.allow)
        }
        if code == 200 || code == 206 {
            completionHandler(.cancel)
            return restartFromScratch("server ignored byte ranges or the file changed")
        }
        if code == 416, seg.done { return completionHandler(.cancel) }
        conn.httpError = code
        conns[id] = conn
        completionHandler(.cancel)
    }

    public func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, let conn = isCurrent(dataTask), conn.validated else { return }
        var seg = state.segments[conn.index]
        var chunk = data
        if seg.end != .max {
            let room = seg.end - seg.pos + 1
            if room <= 0 { dataTask.cancel(); return }
            if Int64(chunk.count) > room { chunk = chunk.prefix(Int(room)) }
        }
        do {
            guard let file else { throw CastnetError.invalid("Output file is not open") }
            try file.seek(toOffset: UInt64(seg.pos))
            try file.write(contentsOf: chunk)
        } catch {
            return fail(CastnetError.invalid("Could not write to disk: \(error.localizedDescription)"))
        }
        seg.pos += Int64(chunk.count)
        state.segments[conn.index] = seg
        linkErrors = 0
        otherFailures = 0
        if seg.done { dataTask.cancel() }
        // Speed limiter: briefly pause this connection when over the limit.
        let wait = max(RateLimiter.global.consume(chunk.count), config.limiter?.consume(chunk.count) ?? 0)
        if wait > 0.02, !seg.done {
            dataTask.suspend()
            let gen = generation
            DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.queue.addOperation {
                    guard let self, !self.stopped, gen == self.generation, self.conns[ObjectIdentifier(dataTask)] != nil else { return }
                    dataTask.resume()
                }
            }
        }
        report()
    }

    public func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let conn = conns[ObjectIdentifier(task)] else { return }
        conns.removeValue(forKey: ObjectIdentifier(task))
        finishSession(for: task)
        guard conn.generation == generation, !stopped, !finished else { return }
        var seg = state.segments[conn.index]
        if seg.end == .max, error == nil, conn.httpError == nil, conn.validated {
            seg.end = seg.pos - 1
            state.segments[conn.index] = seg
            state.total = seg.pos
        }
        if seg.done {
            segStatus[conn.index] = "Done"
            rebalance()
            checkDone()
            report(force: true)
            return
        }
        if conn.probe, let code = conn.httpError, !isLinkError(code), ![429, 500, 502, 503, 504].contains(code) {
            return fail(CastnetError.http(code, url.absoluteString))
        }
        if !state.acceptsRanges, seg.end != .max, error == nil, conn.httpError == nil, seg.pos <= seg.end {
            return restartFromScratch("connection closed early")
        }
        scheduleRetry(conn, error: error)
        report(force: true)
    }
}

/// Checks that a renewed link serves the same file as the partly downloaded one:
/// same total size, and identical bytes for a range we already have.
/// Before the browser's own copy of a download is dropped, checks that Castnet can fetch the same
/// file: the server must answer with it (not an error, and not a web page such as a login form), and
/// its size must match what the browser saw. Only the response headers are read.
public enum LinkProbe {
    public static func check(_ r: DownloadRequest, timeout: TimeInterval = 20) async -> (ok: Bool, reason: String?) {
        guard let url = URL(string: r.url) else { return (false, "Bad link") }
        let config = RequestContext.sessionConfiguration(maxConnectionsPerHost: 2)
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let req = RequestContext(request: r).makeRequest(url, range: "bytes=0-0", extra: ["Accept-Encoding": "identity"])
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            bytes.task.cancel()
            guard let http = resp as? HTTPURLResponse else { return (false, "The server didn’t answer") }
            guard (200..<300).contains(http.statusCode) else { return (false, "The server answered \(http.statusCode) to Castnet") }
            let total: Int64? = http.statusCode == 206
                ? http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
                : (http.expectedContentLength > 0 ? http.expectedContentLength : nil)
            if let want = r.size, want > 0, let got = total, got != want {
                return (false, "The link gives Castnet a different file (\(got) bytes; the browser has \(want))")
            }
            let got = (http.mimeType ?? "").lowercased(), want = (r.mime ?? "").lowercased()
            if got == "text/html", !want.isEmpty, want != "text/html" {
                return (false, "The link gives Castnet a web page instead of the file")
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

public enum LinkVerifier {
    public static func sameFile(newURL: URL, ctx: RequestContext, resume: HTTPResumeState, partURL: URL) async -> Bool {
        let session = URLSession(configuration: RequestContext.sessionConfiguration(maxConnectionsPerHost: 2))
        defer { session.finishTasksAndInvalidate() }
        let range = resume.verificationRange ?? (0, 0)
        let req = ctx.makeRequest(newURL, range: "bytes=\(range.start)-\(range.end)", extra: ["Accept-Encoding": "identity"])
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse,
              http.statusCode == 206 else { return false }
        let total = http.value(forHTTPHeaderField: "Content-Range").flatMap { $0.split(separator: "/").last.flatMap { Int64($0) } }
        if let expected = resume.total, total != expected { return false }
        guard resume.verificationRange != nil else { return true }
        guard let h = try? FileHandle(forReadingFrom: partURL) else { return false }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(range.start))
        let local = (try? h.read(upToCount: Int(range.end - range.start + 1))) ?? Data()
        return local == data
    }
}
