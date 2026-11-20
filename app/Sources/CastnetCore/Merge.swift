import Foundation

/// Resumes a checked continuation once only (completion vs. cancellation race).
final class OnceContinuation<T> {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Error>) { cont = c }
    func resume(with r: Result<T, Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(with: r)
    }
}

/// For sites that stream picture and sound as two files (Facebook, Instagram, Reddit,
/// Vimeo, LinkedIn…): downloads both in parallel, each with the multi-connection
/// downloader, then merges them losslessly with ffmpeg.
public final class MergeEngine: AsyncEngine {
    let request: DownloadRequest
    let config: EngineConfig
    let outputBase: String
    private let runner = ToolRunner()
    private let lock = NSLock()
    private var downloaders: [SegmentedDownloader] = []
    private var received: [Int64] = [0, 0]
    private var totals: [Int64?] = [nil, nil]

    public init(request: DownloadRequest, config: EngineConfig, workDir: URL, outputBase: String) {
        self.request = request
        self.config = config
        self.outputBase = outputBase
        super.init(workDir: workDir)
    }

    private func register(_ d: SegmentedDownloader) { lock.lock(); downloaders.append(d); lock.unlock() }
    private func allDownloaders() -> [SegmentedDownloader] { lock.lock(); defer { lock.unlock() }; return downloaders }

    private func update(_ i: Int, _ p: EngineProgress) {
        lock.lock()
        received[i] = p.received
        totals[i] = p.total
        let r = received.reduce(0, +)
        let t: Int64? = totals.allSatisfy { $0 != nil } ? totals.compactMap { $0 }.reduce(0, +) : nil
        lock.unlock()
        report(r, t, "Downloading video and audio")
    }

    public override func stopProcesses() {
        runner.terminate()
        for d in allDownloaders() { d.pause() }
        saveStates()
    }

    /// Byte ranges already on disk, for checking that renewed links serve the same files.
    public static func savedState(workDir: URL, name: String) -> HTTPResumeState? {
        (try? Data(contentsOf: workDir.appendingPathComponent("\(name).state.json"))).flatMap { try? JSONDecoder().decode(HTTPResumeState.self, from: $0) }
    }

    private func stateFile(_ name: String) -> URL { workDir.appendingPathComponent("\(name).state.json") }

    /// Saves each track's segment table so a pause, relaunch or link renewal continues where it stopped.
    private func saveStates() {
        for d in allDownloaders() {
            let name = d.partURL.lastPathComponent
            if let data = try? JSONEncoder().encode(d.resumeState) { try? data.write(to: stateFile(name)) }
        }
    }

    private func download(_ url: URL, name: String, index: Int) async throws -> URL {
        var resume = (try? Data(contentsOf: stateFile(name))).flatMap { try? JSONDecoder().decode(HTTPResumeState.self, from: $0) }
        if request.refreshed == true { resume?.etag = nil; resume?.lastModified = nil } // renewed link: new server, same file
        let d = SegmentedDownloader(url: url, ctx: RequestContext(request: request), config: config,
                                    partURL: workDir.appendingPathComponent(name), resume: resume)
        register(d)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let once = OnceContinuation(c)
                d.events.progress = { [weak self] p in self?.update(index, p) }
                d.events.completed = { [weak self] r in
                    if case .failure = r { self?.saveStates() }
                    once.resume(with: r.map { $0[0] })
                }
                d.start()
                if Task.isCancelled { once.resume(with: .failure(CancellationError())) }
                self.lock.lock(); self.cancelHooks.append { once.resume(with: .failure(CancellationError())) }; self.lock.unlock()
            }
        } onCancel: {
            self.lock.lock(); let hooks = self.cancelHooks; self.lock.unlock()
            hooks.forEach { $0() }
        }
    }
    private var cancelHooks: [() -> Void] = []

    static func sniffContainer(_ file: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: file) else { return "mp4" }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 12)) ?? Data()
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        return "mp4"
    }

    public override func run() async throws -> [URL] {
        guard let videoURL = URL(string: request.url), let audioURL = request.audioUrl.flatMap(URL.init(string:)) else {
            throw CastnetError.invalid("Missing video or audio URL")
        }
        report(0, nil, "Downloading video and audio")
        async let v = download(videoURL, name: "video.part", index: 0)
        async let a = download(audioURL, name: "audio.part", index: 1)
        let (videoPart, audioPart) = try await (v, a)
        try Task.checkCancellation()

        let vExt = Self.sniffContainer(videoPart)
        let aExt = Self.sniffContainer(audioPart)
        let video = workDir.appendingPathComponent("video.\(vExt)")
        let audio = workDir.appendingPathComponent("audio.\(aExt == "webm" ? "webm" : "m4a")")
        try? FileManager.default.removeItem(at: video)
        try? FileManager.default.removeItem(at: audio)
        try FileManager.default.moveItem(at: videoPart, to: video)
        try FileManager.default.moveItem(at: audioPart, to: audio)

        guard let ffmpeg = config.ffmpeg else { return [video, audio] } // no ffmpeg: keep both files
        let ext = vExt == "webm" && aExt == "webm" ? "webm" : (vExt == "mp4" && aExt == "mp4" ? "mp4" : "mkv")
        let out = workDir.appendingPathComponent("\(outputBase).\(ext)")
        report(received.reduce(0, +), nil, "Merging video and audio…")
        do {
            try await Muxer.merge(ffmpeg: ffmpeg, video: video, audio: audio, output: out, runner: runner)
        } catch {
            if isUserCancelled { throw CancellationError() }
            return [video, audio]
        }
        return [out]
    }
}
