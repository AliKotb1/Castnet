import Foundation

/// One piece of a stream: an HLS/DASH segment or an init section.
struct SegmentJob {
    let index: Int
    let url: URL
    let range: ByteRange?
    let key: AESKey?
}

struct AESKey: Hashable {
    let url: URL
    let iv: Data
}

func waitUntilOnline() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in NetworkWatcher.shared.whenOnline { c.resume() } }
}

/// Downloads many small stream segments concurrently into `dir/NNNNNN.seg`.
/// Finished segments survive a pause, so resuming skips them.
final class SegmentFetcher {
    let ctx: RequestContext
    let session: URLSession
    let concurrency: Int
    private var keyCache: [URL: Data] = [:]
    private let keyLock = NSLock()

    init(ctx: RequestContext, concurrency: Int) {
        self.ctx = ctx
        self.concurrency = concurrency
        session = URLSession(configuration: RequestContext.sessionConfiguration(maxConnectionsPerHost: concurrency + 2))
    }

    deinit { session.invalidateAndCancel() }

    static func path(for job: SegmentJob, in dir: URL) -> URL {
        dir.appendingPathComponent(String(format: "%06d.seg", job.index))
    }

    private func cachedKey(_ url: URL) -> Data? {
        keyLock.lock(); defer { keyLock.unlock() }
        return keyCache[url]
    }

    private func storeKey(_ url: URL, _ data: Data) {
        keyLock.lock(); defer { keyLock.unlock() }
        keyCache[url] = data
    }

    private func key(_ url: URL) async throws -> Data {
        if let k = cachedKey(url) { return k }
        let (data, _) = try await ctx.fetch(url, session: session)
        guard data.count == 16 else { throw CastnetError.invalid("HLS key has \(data.count) bytes, expected 16") }
        storeKey(url, data)
        return data
    }

    private func fetchOne(_ job: SegmentJob, into dir: URL) async throws -> Int64 {
        let dest = Self.path(for: job, in: dir)
        if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? NSNumber {
            return size.int64Value
        }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let req = ctx.makeRequest(job.url, range: job.range?.header, extra: ["Accept-Encoding": "identity"])
                let (tmp, resp) = try await session.download(for: req)
                guard let http = resp as? HTTPURLResponse else { throw CastnetError.invalid("Bad response") }
                guard http.statusCode == 200 || http.statusCode == 206 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw CastnetError.http(http.statusCode, job.url.absoluteString)
                }
                let staging = dest.appendingPathExtension("tmp")
                try? FileManager.default.removeItem(at: staging)
                if let k = job.key {
                    var data = try Data(contentsOf: tmp)
                    try? FileManager.default.removeItem(at: tmp)
                    if job.range != nil, http.statusCode == 200, let r = job.range, data.count > r.length {
                        data = data.subdata(in: Int(r.offset)..<Int(r.offset + r.length))
                    }
                    let plain = try aes128CBCDecrypt(data, key: try await key(k.url), iv: k.iv)
                    try plain.write(to: staging)
                } else if let r = job.range, http.statusCode == 200 {
                    // Server ignored the byte range: cut it out ourselves.
                    let data = try Data(contentsOf: tmp)
                    try? FileManager.default.removeItem(at: tmp)
                    let end = min(data.count, Int(r.offset + r.length))
                    try data.subdata(in: Int(r.offset)..<end).write(to: staging)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: staging)
                }
                try FileManager.default.moveItem(at: staging, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                return size
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if error.isNetworkFailure {
                    // Never give up on a network drop: wait for it to come back.
                    await waitUntilOnline()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                attempt += 1
                if case CastnetError.http(let code, _) = error, isLinkError(code), attempt >= 2 { throw CastnetError.linkExpired }
                if attempt >= 8 { throw error }
                try await Task.sleep(nanoseconds: UInt64(min(16.0, pow(2.0, Double(attempt - 1))) * 1e9))
            }
        }
    }

    /// Downloads every job; `progress(doneCount, bytes)` is called after each segment.
    func fetchAll(_ jobs: [SegmentJob], into dir: URL, progress: @escaping (Int, Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var done = 0
        var bytes: Int64 = 0
        var next = 0
        try await withThrowingTaskGroup(of: Int64.self) { group in
            func addNext() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                next += 1
                group.addTask { try await self.fetchOne(job, into: dir) }
            }
            for _ in 0..<min(concurrency, jobs.count) { addNext() }
            while let size = try await group.next() {
                done += 1
                bytes += size
                progress(done, bytes)
                addNext()
            }
        }
    }

    /// Concatenates downloaded segments (in job order) into one file.
    static func concatenate(_ jobs: [SegmentJob], from dir: URL, to out: URL) throws {
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        for job in jobs {
            try appendFile(path(for: job, in: dir), to: handle)
        }
    }
}
