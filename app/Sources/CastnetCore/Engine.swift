import Foundation

/// One connection's slice of the file, for the segment map in the progress window.
public struct SegmentView: Equatable {
    public var start: Int64
    public var end: Int64
    public var pos: Int64
    public var active: Bool
    public var status: String
    public init(start: Int64, end: Int64, pos: Int64, active: Bool, status: String) {
        self.start = start; self.end = end; self.pos = pos; self.active = active; self.status = status
    }
}

/// Progress snapshot reported by engines (called on an arbitrary queue).
public struct EngineProgress {
    public var received: Int64
    public var total: Int64?
    public var detail: String?
    public var segments: [SegmentView]?
    public var resumable: Bool?
    public init(received: Int64, total: Int64?, detail: String? = nil, segments: [SegmentView]? = nil, resumable: Bool? = nil) {
        self.received = received; self.total = total; self.detail = detail; self.segments = segments; self.resumable = resumable
    }
}

public final class EngineEvents {
    public var progress: ((EngineProgress) -> Void)?
    /// Server-provided file name / MIME type once known (HTTP downloads).
    public var metadata: ((_ filename: String?, _ mime: String?) -> Void)?
    /// Finished: the produced files (usually one) in a temporary location, or an error.
    public var completed: ((Result<[URL], Error>) -> Void)?
    public init() {}
}

public protocol DownloadEngine: AnyObject {
    var events: EngineEvents { get }
    func start()
    /// Stop, keeping partial data so `start()` on a new engine can resume.
    func pause()
    /// Stop and delete partial data.
    func cancel()
    /// Live streams: stop recording and finalize what was captured.
    func finishLive()
}

public extension DownloadEngine {
    func finishLive() { pause() }
}

/// Runs an async job as an engine with pause/cancel support (HLS, DASH, yt-dlp).
open class AsyncEngine: DownloadEngine {
    public let events = EngineEvents()
    private var task: Task<Void, Never>?
    public let workDir: URL
    private let lock = NSLock()
    private var cancelledByUser = false

    public init(workDir: URL) {
        self.workDir = workDir
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    /// Subclasses implement the download; return the produced files.
    open func run() async throws -> [URL] { [] }

    public func start() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await self.run()
                try Task.checkCancellation()
                self.events.completed?(.success(files))
            } catch {
                if self.isUserCancelled { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                self.events.completed?(.failure(error))
            }
        }
    }

    var isUserCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledByUser }

    public func pause() {
        lock.lock(); cancelledByUser = true; lock.unlock()
        task?.cancel()
        stopProcesses()
    }

    public func cancel() {
        pause()
        try? FileManager.default.removeItem(at: workDir)
    }

    open func finishLive() { pause() }

    /// Hook for engines running external processes.
    open func stopProcesses() {}

    public func report(_ received: Int64, _ total: Int64?, _ detail: String? = nil) {
        events.progress?(EngineProgress(received: received, total: total, detail: detail))
    }
}
