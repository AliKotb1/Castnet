import AppKit
import SwiftUI
import CastnetCore

/// `Castnet --snapshot out.png [--dark] [--empty]` renders the main window offscreen with
/// demo rows (for docs and visual checks) and exits. Nothing is saved or downloaded.
@MainActor
enum Snapshot {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: args[i + 1])
        let dark = args.contains("--dark")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let manager = DownloadManager(loadState: false)
        manager.persistenceEnabled = false
        if !args.contains("--empty") { addDemoItems(manager) }

        let setup = args.contains("--setup")
        let settingsShot = args.contains("--settings")
        let status = args.contains("--status")
        let info = args.contains("--info")
        let first = manager.items.first { $0.state == .running && $0.kind == .file } ?? manager.items.first
        let night = manager.settings.queues.first { !$0.isMain }?.id
        let extra: (AnyView, NSSize)?
        if args.contains("--scheduler") || args.contains("--queue-files") {
            extra = (AnyView(SchedulerView(queue: night, tab: args.contains("--queue-files") ? 1 : 0).environmentObject(manager)), NSSize(width: 720, height: 500))
        } else if args.contains("--batch") {
            let m = BatchModel()
            m.pattern = "https://photos.example.com/trip/IMG_*.jpg"; m.from = "1"; m.to = "120"; m.width = 4
            extra = (AnyView(BatchView(model: m, close: {}).environmentObject(manager)), NSSize(width: 560, height: 300))
        } else if args.contains("--duplicate"), let done = manager.items.first(where: { $0.state == .completed }) {
            extra = (AnyView(DuplicateView(existing: done, request: done.request, confirm: true, close: {}).environmentObject(manager)), NSSize(width: 460, height: 200))
        } else if args.contains("--countdown") {
            extra = (AnyView(PowerCountdownView(action: .shutDown, reason: "Queue “Night downloads” finished.", model: CountdownModel(seconds: 60), now: {}, cancel: {})), NSSize(width: 460, height: 110))
        } else if args.contains("--complete"), let done = manager.items.first(where: { $0.state == .completed }) {
            extra = (AnyView(CompleteView(item: done, close: {}).environmentObject(manager)), NSSize(width: 480, height: 200))
        } else {
            extra = nil
        }
        let view: AnyView = extra?.0 ?? (setup ? AnyView(SetupView {}.environmentObject(manager))
            : settingsShot ? AnyView(SettingsView().environmentObject(manager))
            : status ? AnyView(StatusView(item: first!, close: {}).environmentObject(manager))
            : info ? AnyView(DownloadInfoView(item: first!, close: {}).environmentObject(manager))
            : AnyView(ContentView(addURL: AddURLModel()).environmentObject(manager)))
        let size = extra?.1 ?? (setup ? NSSize(width: 640, height: 560) : settingsShot ? NSSize(width: 560, height: 700)
            : status ? NSSize(width: 560, height: 360) : info ? NSSize(width: 520, height: 330) : NSSize(width: 1060, height: 610))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = app.appearance
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        if setup || extra != nil {   // these windows size themselves to their content
            host.frame.size.height = max(size.height, host.fittingSize.height)
            window.setContentSize(host.frame.size)
        }
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        print("snapshot written to \(out.path)")
        exit(0)
    }

    private static func addDemoItems(_ m: DownloadManager) {
        func item(_ url: String, _ kind: DownloadKind, _ name: String, page: String) -> DownloadItem {
            m.add(DownloadRequest(url: url, kind: kind, filename: name, pageUrl: page), startNow: false)
        }
        let a = item("https://cdn.example.com/hls/master.m3u8", .hls, "Big Buck Bunny [1080p].mp4", page: "https://video.example.com/watch/42")
        a.state = .running; a.received = 412_000_000; a.total = 731_000_000; a.speed = 18_400_000; a.detail = "Segment 212/377 · 1080p"
        let b = item("https://releases.example.org/ubuntu-24.04-desktop-arm64.iso", .file, "ubuntu-24.04-desktop-arm64.iso", page: "https://example.org/download")
        b.state = .running; b.received = 1_930_000_000; b.total = 3_100_000_000; b.speed = 42_600_000; b.detail = "16 connections"
        b.resumable = true; b.lastTry = Date()
        let t: Int64 = 3_100_000_000
        b.segments = (0..<16).map { i -> SegmentView in
            let size = t / 16, start = Int64(i) * size, end = i == 15 ? t - 1 : start + size - 1
            let done = Int64(Double(end - start) * [0.95, 0.4, 0.7, 1.0, 0.55, 0.62, 0.3, 0.8, 0.66, 0.5, 1.0, 0.45, 0.71, 0.58, 0.35, 0.9][i])
            return SegmentView(start: start, end: end, pos: start + done, active: done < end - start, status: done < end - start ? "Receiving data…" : "Done")
        }
        let c = item("https://www.youtube.com/watch?v=dQw4w9WgXcQ", .ytdlp, "Conference keynote.mp4", page: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        c.state = .running; c.received = 96_000_000; c.total = 240_000_000; c.speed = 9_800_000; c.detail = "Downloading video"
        let d = item("https://live.example.tv/stream/index.m3u8", .hls, "Live news.mp4", page: "https://live.example.tv")
        d.state = .running; d.received = 58_000_000; d.total = nil; d.speed = 1_100_000; d.detail = "Recording live · 4:12 · 720p · Stop to save"
        let r = m.add(DownloadRequest(url: "https://video.fbcdn.example/v/720.mp4", kind: .file, filename: "Reel by a friend.mp4",
                                      pageUrl: "https://www.facebook.com/reel/1", audioUrl: "https://video.fbcdn.example/v/audio.mp4"), startNow: false)
        r.state = .expired; r.received = 14_000_000; r.total = 31_000_000; r.detail = "Link expired. Getting a fresh link from the page…"
        let e = item("https://media.example.com/podcast/episode-118.mp3", .file, "episode-118.mp3", page: "https://media.example.com/podcast")
        e.state = .completed; e.received = 71_300_000; e.total = 71_300_000; e.detail = "Completed"
        let f = item("https://cdn.example.com/dash/manifest.mpd", .dash, "Trailer.mp4", page: "https://studio.example.com/trailer")
        f.state = .failed; f.error = "This stream is DRM-protected (Widevine/FairPlay/PlayReady). Castnet does not download protected content."
        f.detail = f.error ?? ""
        for i in m.items { i.queueId = nil }
        // A second queue that runs on weeknights and shuts the Mac down when it's done.
        var q = m.addQueue(named: "Night downloads")
        q.schedule.startEnabled = true; q.schedule.startHour = 1; q.schedule.days = [2, 3, 4, 5, 6]
        q.schedule.stopEnabled = true; q.schedule.stopHour = 7
        q.schedule.whenDone = .shutDown; q.simultaneous = 2
        m.updateQueue(q)
        m.add(DownloadRequest(url: "https://cdn.example.org/lectures/lecture-12.mp4", kind: .file, filename: "Lecture 12.mp4"), startNow: false, queue: q.id).total = 812_000_000
        m.add(DownloadRequest(url: "https://downloads.example.com/wallpapers-2026.zip", kind: .file, filename: "wallpapers-2026.zip"), startNow: false, queue: q.id).total = 1_400_000_000
    }
}
