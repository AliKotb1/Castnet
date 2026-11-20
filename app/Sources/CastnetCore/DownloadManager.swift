import Foundation
import Combine

public enum DownloadState: String, Codable {
    /// waiting for a free slot (starts automatically)
    case queued
    case running, paused, completed, failed, canceled
    /// in the download queue, waiting for "Start Queue" or the scheduler ("Download Later")
    case scheduled
    /// the address stopped working; progress is kept until a fresh link is found
    case expired

    public var isActive: Bool { self == .running || self == .queued }
    public var isFinished: Bool { self == .completed }
}

/// File categories: decide the sidebar group and (optionally) the folder.
public enum FileCategory: String, CaseIterable, Codable, Identifiable {
    case video = "Video", music = "Music", compressed = "Compressed", documents = "Documents", programs = "Programs", other = "Other"
    public var id: String { rawValue }

    static let extensions: [FileCategory: Set<String>] = [
        .video: ["mp4", "mkv", "webm", "mov", "avi", "flv", "wmv", "m4v", "mpg", "mpeg", "3gp", "ts", "ogv"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "weba", "aiff"],
        .compressed: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "cab"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "rtf", "odt", "pages", "numbers", "key"],
        .programs: ["dmg", "pkg", "exe", "msi", "apk", "ipa", "deb", "rpm", "jar", "iso", "img", "app"],
    ]

    public static func of(filename: String, kind: DownloadKind) -> FileCategory {
        if kind == .hls || kind == .dash || kind == .ytdlp {
            let ext = (filename as NSString).pathExtension.lowercased()
            return ["m4a", "mp3", "opus", "weba"].contains(ext) ? .music : .video
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        return extensions.first { $0.value.contains(ext) }?.key ?? .other
    }

    public var symbol: String {
        switch self {
        case .video: return "film"
        case .music: return "music.note"
        case .compressed: return "shippingbox"
        case .documents: return "doc.text"
        case .programs: return "app.badge"
        case .other: return "doc"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public var downloadDirectory: String = Paths.defaultDownloads.path
    public var connections: Int = 8
    public var maxConcurrent: Int = 3
    public var segmentConcurrency: Int = 6
    public var ffmpegPath: String = ""
    public var ytdlpPath: String = ""
    public var showWindowOnAdd: Bool = true
    public var notifyOnComplete: Bool = true
    // Dialogs, folders, speed limit, link renewal
    public var showDownloadInfoDialog: Bool = true
    public var showProgressDialog: Bool = true
    public var showCompleteDialog: Bool = true
    public var sortIntoCategoryFolders: Bool = false
    public var speedLimitEnabled: Bool = false
    public var speedLimitKBps: Int = 1024
    public var autoRenewLinks: Bool = true
    /// Download queues; the first is always the main queue.
    public var queues: [DownloadQueue] = [.main]
    public var duplicateAction: DuplicateAction = .ask
    /// Clipboard monitoring: copying a link to a file shows "Download File Info".
    public var monitorClipboard: Bool = false

    public init() {}

    private enum LegacyKeys: String, CodingKey { case scheduler }

    // Tolerant decoding: settings saved by older versions keep their values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        downloadDirectory = try c.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? d.downloadDirectory
        connections = try c.decodeIfPresent(Int.self, forKey: .connections) ?? d.connections
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? d.maxConcurrent
        segmentConcurrency = try c.decodeIfPresent(Int.self, forKey: .segmentConcurrency) ?? d.segmentConcurrency
        ffmpegPath = try c.decodeIfPresent(String.self, forKey: .ffmpegPath) ?? d.ffmpegPath
        ytdlpPath = try c.decodeIfPresent(String.self, forKey: .ytdlpPath) ?? d.ytdlpPath
        showWindowOnAdd = try c.decodeIfPresent(Bool.self, forKey: .showWindowOnAdd) ?? d.showWindowOnAdd
        notifyOnComplete = try c.decodeIfPresent(Bool.self, forKey: .notifyOnComplete) ?? d.notifyOnComplete
        showDownloadInfoDialog = try c.decodeIfPresent(Bool.self, forKey: .showDownloadInfoDialog) ?? d.showDownloadInfoDialog
        showProgressDialog = try c.decodeIfPresent(Bool.self, forKey: .showProgressDialog) ?? d.showProgressDialog
        showCompleteDialog = try c.decodeIfPresent(Bool.self, forKey: .showCompleteDialog) ?? d.showCompleteDialog
        sortIntoCategoryFolders = try c.decodeIfPresent(Bool.self, forKey: .sortIntoCategoryFolders) ?? d.sortIntoCategoryFolders
        speedLimitEnabled = try c.decodeIfPresent(Bool.self, forKey: .speedLimitEnabled) ?? d.speedLimitEnabled
        speedLimitKBps = try c.decodeIfPresent(Int.self, forKey: .speedLimitKBps) ?? d.speedLimitKBps
        autoRenewLinks = try c.decodeIfPresent(Bool.self, forKey: .autoRenewLinks) ?? d.autoRenewLinks
        duplicateAction = (try? c.decodeIfPresent(DuplicateAction.self, forKey: .duplicateAction)) ?? d.duplicateAction
        monitorClipboard = try c.decodeIfPresent(Bool.self, forKey: .monitorClipboard) ?? d.monitorClipboard
        queues = (try? c.decodeIfPresent([DownloadQueue].self, forKey: .queues)) ?? []
        if !queues.contains(where: \.isMain) {
            // 1.3.0 had one queue, with its schedule stored as "scheduler".
            var main = DownloadQueue.main
            if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
               let old = try? legacy.decodeIfPresent(SchedulerSettings.self, forKey: .scheduler) { main.schedule = old }
            queues.insert(main, at: 0)
        }
    }

    public func queue(_ id: UUID?) -> DownloadQueue? { id.flatMap { q in queues.first { $0.id == q } } }

    static let key = "CastnetSettings"

    public static func load() -> AppSettings {
        guard let d = Paths.defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else {
            return AppSettings()
        }
        return s
    }

    public func save() {
        if let d = try? JSONEncoder().encode(self) { Paths.defaults.set(d, forKey: Self.key) }
    }

    public var ffmpegURL: URL? { Tools.find("ffmpeg", override: ffmpegPath) }
    public var ytdlpURL: URL? { Tools.find("yt-dlp", override: ytdlpPath) }

    public var engineConfig: EngineConfig {
        EngineConfig(connections: connections, segmentConcurrency: segmentConcurrency, ffmpeg: ffmpegURL, ytdlp: ytdlpURL)
    }

    public func folder(for category: FileCategory) -> URL {
        let base = URL(fileURLWithPath: downloadDirectory, isDirectory: true)
        return sortIntoCategoryFolders ? base.appendingPathComponent(category.rawValue, isDirectory: true) : base
    }
}

@MainActor
public final class DownloadItem: ObservableObject, Identifiable {
    public let id: UUID
    @Published public var request: DownloadRequest
    public let createdAt: Date
    @Published public var filename: String
    @Published public var directory: URL
    @Published public var state: DownloadState
    @Published public var received: Int64 = 0
    @Published public var total: Int64?
    @Published public var speed: Double = 0
    @Published public var detail: String = ""
    @Published public var error: String?
    @Published public var finishedAt: Date?
    @Published public var lastTry: Date?
    @Published public var outputPaths: [String] = []
    /// Live connection map for the progress window.
    @Published public var segments: [SegmentView] = []
    @Published public var resumable: Bool?
    /// Waiting in the "Download File Info" dialog.
    @Published public var awaitingConfirmation = false
    @Published public var speedLimitKBps: Int? {
        didSet { limiter.bytesPerSecond = Double(speedLimitKBps ?? 0) * 1024 }
    }
    @Published public var renewAttempts = 0
    /// The queue this download belongs to ("Add to Queue"), if any.
    @Published public var queueId: UUID?
    /// This download's own "Options on completion".
    @Published public var whenDone: DoneAction = .nothing

    var httpResume: HTTPResumeState?
    var engine: DownloadEngine?
    var lastSample: (Date, Int64)?
    let limiter = RateLimiter()
    /// Server-suggested name applied when the download completes.
    var pendingRename: String?
    var lastSegmentUpdate = Date.distantPast

    public var kind: DownloadKind { request.kind }
    public var category: FileCategory { FileCategory.of(filename: filename, kind: kind) }
    public var destination: URL { directory.appendingPathComponent(filename) }
    public var partURL: URL { directory.appendingPathComponent(filename + ".castnet-part") }
    public var workDir: URL { Paths.caches.appendingPathComponent(id.uuidString, isDirectory: true) }
    public var isMerge: Bool { kind == .file && request.audioUrl != nil }
    /// "Description" column: the page title or site.
    public var descriptionText: String {
        if let t = request.title, !t.isEmpty { return t }
        return URL(string: request.pageUrl ?? request.url)?.host ?? ""
    }

    public var fraction: Double? {
        guard let t = total, t > 0 else { return state == .completed ? 1 : nil }
        return min(1, Double(received) / Double(t))
    }

    public var eta: TimeInterval? {
        guard state == .running, let t = total, speed > 1 else { return nil }
        return Double(max(0, t - received)) / speed
    }

    public var isLive: Bool { detail.hasPrefix("Recording live") }

    // Sort keys for the table.
    public var sortSize: Int64 { total ?? received }
    public var sortStatus: Double { state == .completed ? 2 : (fraction ?? 0) }
    public var sortLastTry: Date { lastTry ?? createdAt }

    init(id: UUID = UUID(), request: DownloadRequest, filename: String, directory: URL, state: DownloadState = .queued, createdAt: Date = Date()) {
        self.id = id
        self.request = request
        self.filename = filename
        self.directory = directory
        self.state = state
        self.createdAt = createdAt
    }

    struct Record: Codable {
        var id: UUID
        var request: DownloadRequest
        var filename: String
        var directory: String
        var state: DownloadState
        var received: Int64
        var total: Int64?
        var error: String?
        var createdAt: Date
        var finishedAt: Date?
        var outputPaths: [String]
        var httpResume: HTTPResumeState?
        var pendingRename: String?
        var lastTry: Date?
        var speedLimitKBps: Int?
        var resumable: Bool?
        var queueId: UUID?
        var whenDone: DoneAction?
    }

    var record: Record {
        Record(id: id, request: request, filename: filename, directory: directory.path, state: state, received: received,
               total: total, error: error, createdAt: createdAt, finishedAt: finishedAt, outputPaths: outputPaths,
               httpResume: (engine as? SegmentedDownloader)?.resumeState ?? httpResume, pendingRename: pendingRename,
               lastTry: lastTry, speedLimitKBps: speedLimitKBps, resumable: resumable,
               queueId: queueId, whenDone: whenDone == .nothing ? nil : whenDone)
    }

    convenience init(record r: Record) {
        let st: DownloadState = (r.state == .running || r.state == .queued) ? .paused : r.state
        self.init(id: r.id, request: r.request, filename: r.filename, directory: URL(fileURLWithPath: r.directory), state: st, createdAt: r.createdAt)
        received = r.received
        total = r.total
        error = r.error
        finishedAt = r.finishedAt
        outputPaths = r.outputPaths
        httpResume = r.httpResume
        pendingRename = r.pendingRename
        lastTry = r.lastTry
        speedLimitKBps = r.speedLimitKBps
        resumable = r.resumable
        queueId = r.queueId ?? (st == .scheduled ? DownloadQueue.mainID : nil)
        whenDone = r.whenDone ?? .nothing
        if let h = r.httpResume, h.acceptsRanges, let t = h.total {
            segments = h.segments.map { SegmentView(start: $0.start, end: $0.end == .max ? t - 1 : $0.end, pos: $0.pos, active: false, status: $0.done ? "Done" : "Paused") }
        }
        switch st {
        case .paused: detail = "Paused"
        case .completed: detail = "Completed"
        case .failed: detail = r.error ?? "Failed"
        case .canceled: detail = "Canceled"
        case .scheduled: detail = "In queue"
        case .expired: detail = "Link expired"
        default: break
        }
    }
}

/// Owns the download list: queueing, engines, progress/speed, link renewal, scheduler, persistence.
@MainActor
public final class DownloadManager: ObservableObject {
    public static let shared = DownloadManager()

    @Published public private(set) var items: [DownloadItem] = []
    @Published public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if persistenceEnabled { settings.save() }
            applySpeedLimit()
            pump()
        }
    }
    /// Queues started with "Start Queue" (or by the scheduler) that still have work.
    @Published public private(set) var runningQueues = Set<UUID>()
    public var queueRunning: Bool { !runningQueues.isEmpty }
    /// Per running queue: how many downloads it handed out / finished in this run.
    private var queueHandedOut: [UUID: Int] = [:]
    private var queueCompleted: [UUID: Int] = [:]

    // Hooks for the app's windows and dialogs.
    public var onAdded: ((DownloadItem) -> Void)?
    public var onConfirmNeeded: ((DownloadItem) -> Void)?
    public var onStarted: ((DownloadItem) -> Void)?
    public var onFinished: ((DownloadItem) -> Void)?
    public var onExpired: ((DownloadItem) -> Void)?
    public var onRenewed: ((DownloadItem) -> Void)?
    /// A queue or a download with a "when done" action finished (quit / sleep / shut down).
    public var onPowerAction: ((DoneAction, String) -> Void)?
    /// A link that's already in the list was added again and the rule is "ask".
    public var onDuplicate: ((_ existing: DownloadItem, _ request: DownloadRequest, _ confirm: Bool) -> Void)?
    /// "Use the existing download": show it (complete dialog or progress window).
    public var onShowExisting: ((DownloadItem) -> Void)?

    private var ticker: Timer?
    private var saveScheduled = false
    private var lastSchedulerMinute = ""

    public init(loadState: Bool = true) {
        settings = AppSettings.load()
        if loadState { load() }
        applySpeedLimit()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public var activeCount: Int { items.filter { $0.state == .running }.count }
    public var totalSpeed: Double { items.filter { $0.state == .running }.reduce(0) { $0 + $1.speed } }

    private func applySpeedLimit() {
        RateLimiter.global.bytesPerSecond = settings.speedLimitEnabled ? Double(settings.speedLimitKBps) * 1024 : 0
    }

    // MARK: adding

    /// Adds a download. `confirm` shows the "Download File Info" dialog first (if enabled).
    @discardableResult
    public func add(_ request: DownloadRequest, startNow: Bool = true, confirm: Bool = false, queue: UUID? = nil) -> DownloadItem {
        let name = Self.initialFilename(for: request)
        let dir = settings.folder(for: FileCategory.of(filename: name, kind: request.kind))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reserved = Set(items.filter { $0.state != .completed }.map { $0.destination.path })
        let dest = uniqueURL(in: dir, filename: name, reserved: reserved)
        let item = DownloadItem(request: request, filename: dest.lastPathComponent, directory: dir)
        items.insert(item, at: 0)
        if confirm && settings.showDownloadInfoDialog && onConfirmNeeded != nil {
            item.state = .scheduled
            item.awaitingConfirmation = true
            item.detail = "Waiting for confirmation"
            onConfirmNeeded?(item)
        } else if startNow {
            item.detail = "Queued"
            pump()
        } else {
            enqueue(item, into: queue ?? DownloadQueue.mainID)
        }
        scheduleSave()
        onAdded?(item)
        return item
    }

    // MARK: duplicates (the Duplicate Link dialog)

    /// A download already in the list for the same link.
    public func existingItem(for r: DownloadRequest) -> DownloadItem? {
        items.first { i in
            !i.awaitingConfirmation && i.request.url == r.url && i.request.audioUrl == r.audioUrl && i.request.format == r.format &&
                (i.state != .completed || i.outputPaths.contains { FileManager.default.fileExists(atPath: $0) })
        }
    }

    /// "Use the existing download": resume it if unfinished, show it either way.
    public func useExisting(_ item: DownloadItem) {
        switch item.state {
        case .canceled: retry(item)
        case .paused, .failed, .scheduled: resume(item)
        default: break
        }
        onShowExisting?(item)
    }

    /// Entry point for new links (browser, Add URL, clipboard): applies the duplicate rule.
    @discardableResult
    public func submit(_ r: DownloadRequest, confirm: Bool = true) -> (item: DownloadItem, existing: Bool) {
        if let dup = existingItem(for: r) {
            switch settings.duplicateAction {
            case .useExisting:
                useExisting(dup)
                return (dup, true)
            case .ask where onDuplicate != nil:
                onDuplicate?(dup, r, confirm)
                return (dup, true)
            default: break
            }
        }
        return (add(r, confirm: confirm), false)
    }

    /// A download the browser finished itself because Castnet couldn't take it over (a one-time link,
    /// a file the page made, a form download, or one that finished before the browser reported it):
    /// it's listed in Castnet as finished and moved into Castnet's folder if it was saved elsewhere.
    @discardableResult
    public func adopt(path: String, url: String, pageUrl: String?) -> DownloadItem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        if let known = items.first(where: { $0.outputPaths.contains(path) }) { return known }
        var file = URL(fileURLWithPath: path).standardizedFileURL
        let category = FileCategory.of(filename: file.lastPathComponent, kind: .file)
        let dir = settings.folder(for: category).standardizedFileURL
        if dir.path != file.deletingLastPathComponent().path {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = uniqueURL(in: dir, filename: file.lastPathComponent)
            if (try? fm.moveItem(at: file, to: dest)) != nil { file = dest }
        }
        var r = DownloadRequest(url: url.isEmpty ? file.absoluteString : url, kind: .file, filename: file.lastPathComponent, pageUrl: pageUrl)
        r.referer = pageUrl
        let item = DownloadItem(request: r, filename: file.lastPathComponent, directory: file.deletingLastPathComponent(), state: .completed)
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        item.received = size
        item.total = size
        item.outputPaths = [file.path]
        item.finishedAt = Date()
        item.lastTry = Date()
        item.detail = "Completed"
        items.insert(item, at: 0)
        scheduleSave()
        onFinished?(item)
        return item
    }

    /// Batch download: adds many links at once, skipping ones already in the list.
    @discardableResult
    public func addBatch(_ urls: [String], startNow: Bool, queue: UUID? = nil) -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        for s in urls {
            guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { skipped += 1; continue }
            let r = DownloadRequest(url: s, kind: DownloadKind.guess(for: u))
            if existingItem(for: r) != nil { skipped += 1; continue }
            add(r, startNow: startNow, queue: queue)
            added += 1
        }
        return (added, skipped)
    }

    /// Tasks → Export Links: one address per line.
    public func exportLinks(_ list: [DownloadItem]? = nil) -> String {
        (list ?? items.reversed()).map(\.request.url).joined(separator: "\n") + "\n"
    }

    /// Result of the "Download File Info" dialog.
    public func confirm(_ item: DownloadItem, filename: String, directory: URL, startNow: Bool, queue: UUID? = nil) {
        item.awaitingConfirmation = false
        let name = sanitizeFilename(filename)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if name != item.filename || directory != item.directory {
            let reserved = Set(items.filter { $0 !== item && $0.state != .completed }.map { $0.destination.path })
            let dest = uniqueURL(in: directory, filename: name, reserved: reserved)
            item.filename = dest.lastPathComponent
            item.directory = directory
            var r = item.request
            r.filename = dest.lastPathComponent
            item.request = r
        }
        if startNow {
            item.state = .queued
            item.detail = "Queued"
            pump()
        } else {
            enqueue(item, into: queue ?? DownloadQueue.mainID)
        }
        scheduleSave()
    }

    static func initialFilename(for r: DownloadRequest) -> String {
        if r.kind == .ytdlp {
            if let f = r.filename, !f.isEmpty { return sanitizeFilename(f) }
            return sanitizeFilename(r.title ?? "video", fallback: "video") + ".\(r.container ?? "mp4")"
        }
        if let f = r.filename, !f.isEmpty { return sanitizeFilename(f) }
        let url = URL(string: r.url)
        var base = url.map { ($0.lastPathComponent as NSString).deletingPathExtension } ?? "download"
        base = base.removingPercentEncoding ?? base
        if let t = r.title, !t.isEmpty, r.kind != .file { base = t }
        var ext = url?.pathExtension.lowercased() ?? ""
        switch r.kind {
        case .hls, .dash: ext = "mp4"
        default: if ext.isEmpty { ext = "bin" }
        }
        return sanitizeFilename(base.isEmpty ? "download" : base) + ".\(ext)"
    }

    // MARK: control

    public func pump() {
        var running = items.filter { $0.state == .running }.count
        var perQueue: [UUID: Int] = [:]
        for i in items where i.state == .running {
            if let q = i.queueId, runningQueues.contains(q) { perQueue[q, default: 0] += 1 }
        }
        for item in items.reversed() where item.state == .queued && running < settings.maxConcurrent {
            // Downloads handed out by a running queue respect its "files at the same time".
            if let q = item.queueId, runningQueues.contains(q) {
                let limit = max(1, settings.queue(q)?.simultaneous ?? settings.maxConcurrent)
                if perQueue[q, default: 0] >= limit { continue }
                perQueue[q, default: 0] += 1
            }
            start(item)
            running += 1
        }
    }

    private func start(_ item: DownloadItem) {
        item.state = .running
        item.error = nil
        item.detail = "Starting…"
        item.lastSample = nil
        item.lastTry = Date()
        var config = settings.engineConfig
        config.limiter = item.limiter
        let engine: DownloadEngine
        let base = (item.filename as NSString).deletingPathExtension
        switch item.kind {
        case .file where item.request.audioUrl != nil:
            engine = MergeEngine(request: item.request, config: config, workDir: item.workDir, outputBase: base)
        case .file:
            guard let url = URL(string: item.request.url) else { return fail(item, CastnetError.invalid("Bad URL")) }
            engine = SegmentedDownloader(url: url, ctx: RequestContext(request: item.request), config: config,
                                         partURL: item.partURL, resume: item.httpResume)
        case .hls:
            engine = HLSEngine(request: item.request, config: config, workDir: item.workDir, outputBase: base)
        case .dash:
            engine = DASHEngine(request: item.request, config: config, workDir: item.workDir, outputBase: base)
        case .ytdlp:
            engine = YTDLPEngine(request: item.request, config: config, workDir: item.workDir, outputBase: base)
        }
        item.engine = engine
        engine.events.progress = { [weak item] p in
            Task { @MainActor in
                guard let item, item.state == .running else { return }
                item.received = p.received
                item.total = p.total
                if let d = p.detail { item.detail = d }
                if let r = p.resumable { item.resumable = r }
                if let segs = p.segments, Date().timeIntervalSince(item.lastSegmentUpdate) > 0.4 {
                    item.lastSegmentUpdate = Date()
                    item.segments = segs
                }
            }
        }
        engine.events.metadata = { [weak self, weak item] name, mime in
            Task { @MainActor in
                guard let self, let item else { return }
                self.adoptServerName(item, name: name, mime: mime)
            }
        }
        engine.events.completed = { [weak self, weak item] result in
            Task { @MainActor in
                guard let self, let item else { return }
                switch result {
                case let .success(files): self.complete(item, files: files)
                case let .failure(err): self.fail(item, err)
                }
            }
        }
        engine.start()
        onStarted?(item)
        scheduleSave()
    }

    /// For plain downloads, prefer the server's Content-Disposition name when the browser didn't supply one.
    private func adoptServerName(_ item: DownloadItem, name: String?, mime: String?) {
        guard item.kind == .file, item.request.audioUrl == nil else { return }
        var newName: String?
        if let n = name, !n.isEmpty, item.request.filename == nil {
            newName = sanitizeFilename(n)
        } else if item.request.filename == nil, (item.filename as NSString).pathExtension == "bin",
                  let m = mime, let ext = mimeExtensions[m.lowercased()] {
            newName = (item.filename as NSString).deletingPathExtension + ".\(ext)"
        }
        guard let n = newName, n != item.filename else { return }
        let reserved = Set(items.filter { $0 !== item && $0.state != .completed }.map { $0.destination.path })
        let dest = uniqueURL(in: item.directory, filename: n, reserved: reserved)
        item.pendingRename = dest.lastPathComponent
    }

    private func complete(_ item: DownloadItem, files: [URL]) {
        item.engine = nil
        item.httpResume = nil
        var produced: [String] = []
        do {
            if item.kind == .file, item.request.audioUrl == nil, let part = files.first {
                let finalName = item.pendingRename ?? item.filename
                let dest = uniqueURL(in: item.directory, filename: finalName)
                try moveItem(part, to: dest)
                item.filename = dest.lastPathComponent
                produced = [dest.path]
            } else {
                let base = (item.filename as NSString).deletingPathExtension
                for (i, f) in files.enumerated() {
                    var name: String
                    if item.kind == .ytdlp {
                        name = f.lastPathComponent
                    } else {
                        let isAudio = f.lastPathComponent.hasPrefix("audio")
                        let suffix = files.count > 1 ? (isAudio ? " (audio)" : " (video)") : ""
                        name = "\(base)\(suffix).\(f.pathExtension)"
                    }
                    let dest = uniqueURL(in: item.directory, filename: name)
                    try moveItem(f, to: dest)
                    produced.append(dest.path)
                    if i == 0 { item.filename = dest.lastPathComponent }
                }
                try? FileManager.default.removeItem(at: item.workDir)
            }
        } catch {
            return fail(item, error)
        }
        item.outputPaths = produced
        let page = item.request.pageUrl ?? item.request.referer
        for path in produced { Quarantine.mark(URL(fileURLWithPath: path), source: item.request.url, page: page) }
        if let size = produced.first.flatMap({ try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber }) {
            item.received = size.int64Value
            item.total = size.int64Value
        }
        item.state = .completed
        item.speed = 0
        item.finishedAt = Date()
        item.segments = item.segments.map { var s = $0; s.pos = s.end + 1; s.active = false; s.status = "Done"; return s }
        item.detail = produced.count > 1 ? "Saved \(produced.count) files" : "Completed"
        if let q = item.queueId {
            if runningQueues.contains(q) { queueCompleted[q, default: 0] += 1 }
            item.queueId = nil   // finished files leave the queue
        }
        onFinished?(item)
        scheduleSave()
        pump()
        checkQueueDone()
        if item.whenDone != .nothing {
            let action = item.whenDone
            item.whenDone = .nothing
            onPowerAction?(action, "“\(item.filename)” finished downloading.")
        }
    }

    private func fail(_ item: DownloadItem, _ error: Error) {
        if let seg = item.engine as? SegmentedDownloader { item.httpResume = seg.resumeState }
        item.engine = nil
        item.speed = 0
        item.segments = item.segments.map { var s = $0; s.active = false; return s }
        if case CastnetError.linkExpired = error {
            item.state = .expired
            item.error = nil
            item.detail = settings.autoRenewLinks
                ? "Link expired. Getting a fresh link from the page…"
                : "Link expired. Right-click → Refresh Link to continue."
            onExpired?(item)
        } else {
            item.state = .failed
            item.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            item.detail = item.error ?? "Failed"
        }
        scheduleSave()
        pump()
        checkQueueDone()
    }

    public func pause(_ item: DownloadItem) {
        guard item.state.isActive else { return }
        if item.isLive, let e = item.engine {
            item.detail = "Saving recording…"
            e.finishLive()
            return
        }
        if let e = item.engine {
            e.pause()
            if let seg = e as? SegmentedDownloader { item.httpResume = seg.resumeState }
        }
        item.engine = nil
        item.state = .paused
        item.speed = 0
        item.detail = "Paused"
        item.segments = item.segments.map { var s = $0; s.active = false; return s }
        scheduleSave()
        pump()
    }

    public func resume(_ item: DownloadItem) {
        guard [.paused, .failed, .canceled, .scheduled, .expired].contains(item.state), !item.awaitingConfirmation else { return }
        item.state = .queued
        item.detail = "Queued"
        item.error = nil
        pump()
        scheduleSave()
    }

    public func cancel(_ item: DownloadItem) {
        item.engine?.cancel()
        item.engine = nil
        try? FileManager.default.removeItem(at: item.partURL)
        try? FileManager.default.removeItem(at: item.workDir)
        item.httpResume = nil
        item.state = .canceled
        item.speed = 0
        item.received = 0
        item.segments = []
        item.detail = "Canceled"
        scheduleSave()
        pump()
        checkQueueDone()
    }

    public func remove(_ item: DownloadItem, deleteFiles: Bool = false) {
        if item.state.isActive { cancel(item) }
        if item.state != .completed {
            try? FileManager.default.removeItem(at: item.partURL)
            try? FileManager.default.removeItem(at: item.workDir)
        }
        if deleteFiles { for p in item.outputPaths { try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) } }
        items.removeAll { $0 === item }
        scheduleSave()
        checkQueueDone()
    }

    /// "Redownload": start over from zero.
    public func redownload(_ item: DownloadItem) {
        if item.state.isActive { pause(item) }
        try? FileManager.default.removeItem(at: item.partURL)
        try? FileManager.default.removeItem(at: item.workDir)
        item.httpResume = nil
        item.received = 0
        item.segments = []
        item.outputPaths = []
        item.state = .queued
        item.detail = "Queued"
        pump()
        scheduleSave()
    }

    public func retry(_ item: DownloadItem) {
        if item.state == .canceled { item.httpResume = nil; item.received = 0 }
        resume(item)
    }

    public func pauseAll() { items.filter(\.state.isActive).forEach(pause) }
    public func resumeAll() { items.filter { [.paused, .failed, .expired].contains($0.state) }.forEach(resume) }
    public func clearFinished() { items.removeAll { $0.state == .completed || $0.state == .canceled }; scheduleSave() }

    // MARK: queues & scheduler (Start Queue / Stop Queue / Scheduler)

    /// Downloads waiting in any queue.
    public var queuedCount: Int { items.filter { $0.state == .scheduled && !$0.awaitingConfirmation }.count }

    /// Unfinished downloads in a queue, in queue order (first to download first).
    public func items(inQueue id: UUID) -> [DownloadItem] {
        items.reversed().filter { $0.queueId == id && $0.state != .completed && !$0.awaitingConfirmation }
    }

    /// Downloads "Start Queue" would hand out.
    public func startableCount(_ id: UUID) -> Int {
        items.filter { $0.queueId == id && [.scheduled, .paused, .failed].contains($0.state) && !$0.awaitingConfirmation }.count
    }

    private func enqueue(_ item: DownloadItem, into q: UUID) {
        let q = settings.queue(q) != nil ? q : DownloadQueue.mainID
        item.queueId = q
        if runningQueues.contains(q) {
            item.state = .queued
            item.detail = "Queued"
            queueHandedOut[q, default: 0] += 1
            pump()
        } else {
            item.state = .scheduled
            item.detail = "In queue"
        }
    }

    public func addToQueue(_ item: DownloadItem, queue: UUID = DownloadQueue.mainID) {
        guard !item.state.isFinished else { return }
        if item.state.isActive { pause(item) }
        enqueue(item, into: queue)
        scheduleSave()
    }

    public func removeFromQueue(_ item: DownloadItem) {
        guard item.queueId != nil else { return }
        item.queueId = nil
        if item.state == .scheduled { item.state = .paused; item.detail = item.received > 0 ? "Paused" : "Not started" }
        scheduleSave()
        checkQueueDone()
    }

    /// Moves a download one place earlier or later within its queue.
    public func move(_ item: DownloadItem, earlier: Bool) {
        guard let q = item.queueId, let idx = items.firstIndex(where: { $0 === item }) else { return }
        // `items` is newest first, so queue order runs from the end of the array to the start.
        let candidates = earlier ? Array((idx + 1)..<items.count) : Array((0..<idx).reversed())
        guard let j = candidates.first(where: { items[$0].queueId == q && items[$0].state != .completed }) else { return }
        items.swapAt(idx, j)
        scheduleSave()
    }

    public func startQueue(_ id: UUID = DownloadQueue.mainID) {
        let members = items.reversed().filter { $0.queueId == id && [.scheduled, .paused, .failed].contains($0.state) && !$0.awaitingConfirmation }
        guard !members.isEmpty else { return }
        if !runningQueues.contains(id) { queueHandedOut[id] = 0; queueCompleted[id] = 0 }
        runningQueues.insert(id)
        for item in members {
            item.state = .queued
            item.error = nil
            item.detail = "Queued"
        }
        queueHandedOut[id, default: 0] += members.count
        pump()
        scheduleSave()
    }

    public func stopQueue(_ id: UUID = DownloadQueue.mainID) {
        runningQueues.remove(id)
        queueHandedOut[id] = nil
        queueCompleted[id] = nil
        // Waiting ones first, so pausing the running ones can't start them.
        for item in items where item.queueId == id && item.state == .queued {
            item.state = .scheduled
            item.detail = "In queue"
        }
        for item in items where item.queueId == id && item.state == .running {
            pause(item)
            item.state = .scheduled
            item.detail = "In queue"
        }
        scheduleSave()
    }

    public func stopAllQueues() { for id in runningQueues { stopQueue(id) } }

    /// A running queue with nothing left to do is finished; its "when done" action runs only if
    /// it actually downloaded something and you didn't pause any of its files.
    private func checkQueueDone() {
        for id in Array(runningQueues) {
            let busy = items.contains { $0.queueId == id && ($0.state.isActive || ($0.state == .scheduled && !$0.awaitingConfirmation)) }
            guard !busy else { continue }
            runningQueues.remove(id)
            let completed = queueCompleted.removeValue(forKey: id) ?? 0
            queueHandedOut[id] = nil
            let interrupted = items.contains { $0.queueId == id && $0.state == .paused }
            if completed > 0, !interrupted, let q = settings.queue(id), q.schedule.whenDone != .nothing {
                onPowerAction?(q.schedule.whenDone, "Queue “\(q.name)” finished.")
            }
        }
    }

    /// Starts and stops queues at their scheduled times (called every second; acts once a minute).
    public func runScheduler(at now: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute, .weekday], from: now)
        let key = "\(c.weekday ?? 0) \(c.hour ?? 0):\(c.minute ?? 0)"
        guard key != lastSchedulerMinute else { return }
        lastSchedulerMinute = key
        for q in settings.queues where q.schedule.runsOn(weekday: c.weekday ?? 0) {
            let s = q.schedule
            if s.startEnabled, c.hour == s.startHour, c.minute == s.startMinute { startQueue(q.id) }
            if s.stopEnabled, c.hour == s.stopHour, c.minute == s.stopMinute { stopQueue(q.id) }
        }
    }

    @discardableResult
    public func addQueue(named name: String) -> DownloadQueue {
        var q = DownloadQueue(name: name.isEmpty ? "Queue \(settings.queues.count + 1)" : name)
        q.simultaneous = settings.queues.first?.simultaneous ?? 3
        settings.queues.append(q)
        return q
    }

    public func updateQueue(_ q: DownloadQueue) {
        guard let i = settings.queues.firstIndex(where: { $0.id == q.id }) else { return }
        var q = q
        if q.name.trimmingCharacters(in: .whitespaces).isEmpty { q.name = settings.queues[i].name }
        settings.queues[i] = q
    }

    /// Deletes a queue; its downloads move to the main queue.
    public func deleteQueue(_ id: UUID) {
        guard id != DownloadQueue.mainID else { return }
        stopQueue(id)
        for i in items where i.queueId == id { i.queueId = DownloadQueue.mainID }
        settings.queues.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: link renewal (Castnet's "never lose a download")

    /// Expired downloads the browser extension should find fresh links for.
    public var renewalList: [[String: Any]] {
        guard settings.autoRenewLinks else { return [] }
        return items.filter { $0.state == .expired && $0.kind != .ytdlp }.map { item in
            var d: [String: Any] = ["id": item.id.uuidString, "kind": item.kind.rawValue, "filename": item.filename,
                                    "attempts": item.renewAttempts]
            if let p = item.request.pageUrl { d["pageUrl"] = p }
            if let t = item.total ?? item.httpResume?.total { d["size"] = t }
            if item.isMerge, let v = MergeEngine.savedState(workDir: item.workDir, name: "video.part")?.total { d["size"] = v }
            if item.isMerge, let a = MergeEngine.savedState(workDir: item.workDir, name: "audio.part")?.total { d["audioSize"] = a }
            if let u = URL(string: item.request.url) { d["host"] = u.host ?? ""; d["path"] = u.path }
            d["url"] = item.request.url              // the dead address: never offer it back
            if let a = item.request.audioUrl { d["audioUrl"] = a }
            return d
        }
    }

    /// Finds an expired download that a new request from the browser is a fresh link for.
    func expiredMatch(for req: DownloadRequest) -> DownloadItem? {
        items.first { item in
            guard item.state == .expired, item.kind == req.kind, item.kind != .ytdlp else { return false }
            switch item.kind {
            case .hls, .dash:
                guard let a = URL(string: item.request.url), let b = URL(string: req.url) else { return false }
                return a.host == b.host && a.path == b.path
            default:
                let known = item.isMerge ? MergeEngine.savedState(workDir: item.workDir, name: "video.part")?.total : (item.total ?? item.httpResume?.total)
                guard let size = req.size, let k = known else { return false }
                return size == k && (item.request.audioUrl == nil) == (req.audioUrl == nil)
            }
        }
    }

    /// Checks a fresh link serves the same file, then continues the download where it stopped.
    public func renew(_ item: DownloadItem, with fresh: DownloadRequest) async -> (Bool, String?) {
        guard item.kind != .ytdlp else { return (false, "Site downloads renew themselves") }
        if item.state.isActive { pause(item) }
        var r = fresh
        r.kind = item.kind
        r.filename = item.request.filename ?? item.filename
        r.title = r.title ?? item.request.title
        r.pageUrl = r.pageUrl ?? item.request.pageUrl
        r.variantUrl = r.variantUrl ?? item.request.variantUrl
        r.quality = r.quality ?? item.request.quality
        r.refreshed = true
        let ctx = RequestContext(request: r)
        switch item.kind {
        case .file where item.isMerge:
            guard let v = URL(string: r.url), let a = r.audioUrl.flatMap(URL.init(string:)) else { return (false, "Missing video or audio link") }
            for (url, name) in [(v, "video.part"), (a, "audio.part")] {
                if let st = MergeEngine.savedState(workDir: item.workDir, name: name),
                   !(await LinkVerifier.sameFile(newURL: url, ctx: ctx, resume: st, partURL: item.workDir.appendingPathComponent(name))) {
                    return (false, "The new link is a different file")
                }
            }
        case .file:
            guard let u = URL(string: r.url) else { return (false, "Bad URL") }
            if let st = item.httpResume, st.acceptsRanges,
               !(await LinkVerifier.sameFile(newURL: u, ctx: ctx, resume: st, partURL: item.partURL)) {
                return (false, "The new link is a different file")
            }
        default:
            break
        }
        item.request = r
        if var h = item.httpResume { h.etag = nil; h.lastModified = nil; item.httpResume = h }
        item.renewAttempts = 0
        item.state = .queued
        item.detail = "Fresh link found, continuing…"
        onRenewed?(item)
        pump()
        scheduleSave()
        return (true, nil)
    }

    /// "Refresh Link": wait for a fresh link (the browser extension sends it
    /// when the video plays again) and continue where the download stopped.
    public func requestRenewal(_ item: DownloadItem) {
        guard item.state != .completed else { return }
        if item.kind == .ytdlp { resume(item); return }   // site downloads fetch fresh links themselves
        if item.state.isActive { pause(item) }
        item.state = .expired
        item.renewAttempts = 0
        item.detail = "Play the video again in the page that opened. Castnet continues with the fresh link."
        scheduleSave()
    }

    /// Manual "Change Address…": paste a new link for the same file.
    public func changeAddress(_ item: DownloadItem, to url: String) async -> (Bool, String?) {
        var r = item.request
        r.url = url
        return await renew(item, with: r)
    }

    /// Pause everything so it can resume after relaunch.
    public func prepareForQuit() {
        for item in items where item.state.isActive {
            if let e = item.engine {
                e.pause()
                if let seg = e as? SegmentedDownloader { item.httpResume = seg.resumeState }
            }
            item.engine = nil
            item.state = .paused
            item.detail = "Paused"
        }
        saveNow()
    }

    // MARK: speed / persistence

    private func tick() {
        let now = Date()
        for item in items where item.state == .running {
            if let (t, r) = item.lastSample {
                let dt = now.timeIntervalSince(t)
                if dt > 0 {
                    let inst = Double(max(0, item.received - r)) / dt
                    item.speed = item.speed == 0 ? inst : item.speed * 0.7 + inst * 0.3
                }
            }
            item.lastSample = (now, item.received)
        }
        runScheduler(at: now)
        if items.contains(where: { $0.state == .running }) { scheduleSave(delay: 5) }
    }

    func scheduleSave(delay: TimeInterval = 0.5) {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                self?.saveScheduled = false
                self?.saveNow()
            }
        }
    }

    /// Off for previews/snapshots/self-tests so demo rows and settings never overwrite the real ones.
    public var persistenceEnabled = true

    public func saveNow() {
        guard persistenceEnabled else { return }
        let records = items.map(\.record)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Paths.stateFile, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let records = try? JSONDecoder().decode([DownloadItem.Record].self, from: data) else { return }
        items = records.map(DownloadItem.init(record:))
        for item in items where item.state != .completed { LegacyMigration.movePartFile(of: item) }
    }

    // MARK: IPC entry point

    /// Handles a JSON message from castnet-host / the Safari bridge / the CLI.
    public func handle(message: [String: Any], raw: Data) async -> [String: Any] {
        if let client = message["client"] as? String, !client.isEmpty {
            noteBrowser(client)
            if let v = message["ext"] as? String, extensionVersions[client] != v { extensionVersions[client] = v }
        }
        switch message["type"] as? String {
        case "formats":
            guard let req = Self.decodeRequest(message["request"]) else { return ["ok": false, "error": "Malformed request"] }
            let config = settings.engineConfig
            do {
                let formats = try await YTDLPEngine.listFormats(request: req, config: config)
                let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(formats))
                return ["ok": true, "formats": obj]
            } catch {
                return ["ok": false, "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]
            }
        case "downloadBatch":
            let list = (message["requests"] as? [Any] ?? []).compactMap(Self.decodeRequest)
                .filter { URL(string: $0.url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false }
            guard !list.isEmpty else { return ["ok": false, "error": "No downloadable links"] }
            for r in list { add(r) }
            return ["ok": true, "count": list.count]
        case "ping":
            lastExtensionContact = Date()
            return ["ok": true, "running": true, "version": castnetVersion, "browsers": connectedBrowsers.sorted(), "extensions": extensionVersions,
                    "ffmpeg": settings.ffmpegURL != nil, "ytdlp": settings.ytdlpURL != nil,
                    "renewals": renewalList.count]
        case "show":
            onShowRequested?()
            return ["ok": true]
        case "download":
            guard let req = Self.decodeRequest(message["request"]) else {
                return ["ok": false, "error": "Malformed download request"]
            }
            guard let u = URL(string: req.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
                return ["ok": false, "error": "Only http(s) URLs can be downloaded"]
            }
            if req.kind == .ytdlp, settings.ytdlpURL == nil {
                return ["ok": false, "error": "Video site support is missing. Please reinstall Castnet."]
            }
            // The same file as an expired download: continue it instead of starting over.
            if let old = expiredMatch(for: req) {
                let (ok, _) = await renew(old, with: req)
                if ok { return ["ok": true, "renewed": true, "id": old.id.uuidString, "filename": old.filename] }
            }
            // A download the browser already started: take it only if Castnet can fetch the same file,
            // otherwise the browser keeps it (one-time links, downloads that need the browser itself).
            if message["verify"] as? Bool == true, req.kind == .file, req.audioUrl == nil {
                let (ok, reason) = await LinkProbe.check(req)
                if !ok { return ["ok": false, "keepInBrowser": true, "error": reason ?? "Castnet can’t fetch this link"] }
            }
            let (item, existing) = submit(req, confirm: message["confirm"] as? Bool ?? true)
            return ["ok": true, "id": item.id.uuidString, "filename": item.filename, "existing": existing]
        case "adopt":
            guard let path = message["path"] as? String,
                  let item = adopt(path: path, url: message["url"] as? String ?? "", pageUrl: message["pageUrl"] as? String) else {
                return ["ok": false, "error": "No finished file at that location"]
            }
            return ["ok": true, "id": item.id.uuidString, "filename": item.filename, "path": item.outputPaths.first ?? ""]
        case "renewals":
            lastExtensionContact = Date()
            return ["ok": true, "items": renewalList]
        case "renew":
            guard let id = (message["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let item = items.first(where: { $0.id == id }),
                  let req = Self.decodeRequest(message["request"]) else { return ["ok": false, "error": "Unknown download"] }
            let (ok, err) = await renew(item, with: req)
            return ok ? ["ok": true, "filename": item.filename] : ["ok": false, "error": err ?? "Not the same file"]
        case "renewFailed":
            if let id = (message["id"] as? String).flatMap(UUID.init(uuidString:)), let item = items.first(where: { $0.id == id }) {
                item.renewAttempts += 1
                if item.state == .expired {
                    item.detail = "Couldn’t renew the link automatically. Play the video again in your browser, or right-click → Refresh Link."
                }
            }
            return ["ok": true]
        case "list":
            return ["ok": true, "items": items.map { ["id": $0.id.uuidString, "filename": $0.filename, "state": $0.state.rawValue,
                                                        "received": $0.received, "total": $0.total ?? -1, "detail": $0.detail,
                                                        "outputs": $0.outputPaths] }]
        case "remove":
            if let id = (message["id"] as? String).flatMap(UUID.init(uuidString:)), let item = items.first(where: { $0.id == id }) {
                remove(item)
            }
            return ["ok": true]
        default:
            return ["ok": false, "error": "Unknown message type"]
        }
    }

    public var onShowRequested: (() -> Void)?

    /// Last time the browser extension reached the app (used by the setup window).
    @Published public var lastExtensionContact: Date? {
        didSet { if lastExtensionContact != nil { Paths.defaults.set(true, forKey: "ExtensionConnected") } }
    }
    public var extensionEverConnected: Bool { Paths.defaults.bool(forKey: "ExtensionConnected") }

    /// The extension version each browser runs (bundle identifier → version), as last reported.
    @Published public private(set) var extensionVersions: [String: String] = [:]

    /// Bundle identifiers of the browsers whose Castnet extension has reached the app (kept across launches).
    @Published public private(set) var connectedBrowsers: Set<String> = Set(Paths.defaults.stringArray(forKey: "ConnectedBrowsers") ?? [])

    private func noteBrowser(_ bundleID: String) {
        guard !connectedBrowsers.contains(bundleID) else { return }
        connectedBrowsers.insert(bundleID)
        Paths.defaults.set(connectedBrowsers.sorted(), forKey: "ConnectedBrowsers")
    }

    /// Set when a newer Castnet is published (see UpdateChecker).
    @Published public var availableUpdate: AppUpdate?

    static func decodeRequest(_ obj: Any?) -> DownloadRequest? {
        guard let obj, let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(DownloadRequest.self, from: data)
    }
}
