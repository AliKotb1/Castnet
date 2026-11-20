import Foundation
import CastnetCore

// Headless downloader using the same engines as the app.
//   castnet-cli [--kind file|hls|dash|ytdlp] [--out DIR] [--name FILE] [--connections N]
//               [--quality HEIGHT] [--header "K: V"]... [--referer URL] URL
//   castnet-cli --send URL     # hand the URL to the running Castnet app instead
//   castnet-cli --ping         # ask the running app for its status

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: castnet-cli [--kind file|hls|dash|ytdlp] [--out DIR] [--name FILE] [--connections N]
                       [--segments N] [--quality HEIGHT] [--header "K: V"] [--referer URL] [--send] URL
           castnet-cli --ping

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var kind: DownloadKind?
var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var name: String?
var connections = 8
var segments = 6
var quality: Int?
var headers: [String: String] = [:]
var referer: String?
var sendToApp = false
var urlString: String?
var cookiePairs: [String] = []
var testPauseAfter: Double?
var audioURLString: String?
var listFormatsOnly = false
var requestFile: String?
var renewFrom: String?
var limitKBps: Double?

while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        if args.isEmpty { usage() }
        return args.removeFirst()
    }
    switch a {
    case "--kind": kind = DownloadKind(rawValue: value())
    case "--out": outDir = URL(fileURLWithPath: value(), isDirectory: true)
    case "--name": name = value()
    case "--connections": connections = Int(value()) ?? 8
    case "--segments": segments = Int(value()) ?? 6
    case "--quality": quality = Int(value())
    case "--header":
        let h = value()
        if let i = h.firstIndex(of: ":") { headers[String(h[..<i])] = h[h.index(after: i)...].trimmingCharacters(in: .whitespaces) }
    case "--referer": referer = value()
    case "--cookie": cookiePairs.append(value())
    case "--test-pause": testPauseAfter = Double(value())
    case "--audio": audioURLString = value()
    case "--formats": listFormatsOnly = true
    case "--request": requestFile = value()
    case "--renew-from": renewFrom = value()     // test: GET this URL for a fresh link when the link expires
    case "--limit": limitKBps = Double(value())  // speed limit in KB/s
    case "--send": sendToApp = true
    case "--ping":
        let reply = IPCClient.send(Data(#"{"type":"ping"}"#.utf8), to: Paths.socket.path)
        print(reply.map { String(decoding: $0, as: UTF8.self) } ?? "Castnet app is not running")
        exit(reply == nil ? 1 : 0)
    case "-h", "--help": usage()
    default: urlString = a
    }
}

// --request FILE: replay a full request exactly as the browser extension sent it.
let replayed: DownloadRequest? = requestFile.flatMap { try? JSONDecoder().decode(DownloadRequest.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
if requestFile != nil && replayed == nil { FileHandle.standardError.write(Data("bad --request file\n".utf8)); exit(2) }
if let r = replayed { urlString = r.url; name = name ?? r.filename }
guard let urlString, let url = URL(string: urlString) else { usage() }
let cookies = cookiePairs.compactMap { pair -> CookieInfo? in
    guard let eq = pair.firstIndex(of: "="), let host = url.host else { return nil }
    return CookieInfo(name: String(pair[..<eq]), value: String(pair[pair.index(after: eq)...]), domain: host, path: "/", hostOnly: true)
}
let request = replayed ?? DownloadRequest(url: urlString, kind: kind ?? DownloadKind.guess(for: url), filename: name, referer: referer,
                              headers: headers, cookies: cookies, quality: quality, audioUrl: audioURLString)

if listFormatsOnly {
    // Print the quality menu the browser would show for a page URL.
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let f = try await YTDLPEngine.listFormats(request: request, config: EngineConfig(ytdlp: Tools.find("yt-dlp")))
            print("\(f.title)  [listed \(f.useCookies ? "with" : "without") login cookies]")
            for o in f.options { print("  \(o.label)\t\(o.ext)\t\(o.sizeIsEstimate ? "~" : "")\(o.size.map(formatBytes) ?? "?")\t[\(o.format)]") }
        } catch { print("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
        sema.signal()
    }
    sema.wait()
    exit(0)
}

if sendToApp {
    let payload = try JSONSerialization.data(withJSONObject: [
        "type": "download",
        "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)),
    ])
    let reply = IPCClient.send(payload, to: Paths.socket.path)
    print(reply.map { String(decoding: $0, as: UTF8.self) } ?? "Castnet app is not running")
    exit(reply == nil ? 1 : 0)
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let config = EngineConfig(connections: connections, segmentConcurrency: segments,
                          ffmpeg: Tools.find("ffmpeg"), ytdlp: Tools.find("yt-dlp"))
let fileName = name ?? {
    let base = (url.lastPathComponent as NSString).deletingPathExtension
    let ext = request.kind == .file ? (url.pathExtension.isEmpty ? "bin" : url.pathExtension) : "mp4"
    return sanitizeFilename(base.isEmpty ? "download" : base) + ".\(ext)"
}()
let workDir = Paths.caches.appendingPathComponent("cli-\(UUID().uuidString)", isDirectory: true)

var engine: DownloadEngine
switch request.kind {
case .file where request.audioUrl != nil:
    engine = MergeEngine(request: request, config: config, workDir: workDir, outputBase: (fileName as NSString).deletingPathExtension)
case .file:
    engine = SegmentedDownloader(url: url, ctx: RequestContext(request: request), config: config,
                                 partURL: outDir.appendingPathComponent(fileName + ".castnet-part"))
case .hls:
    engine = HLSEngine(request: request, config: config, workDir: workDir, outputBase: (fileName as NSString).deletingPathExtension)
case .dash:
    engine = DASHEngine(request: request, config: config, workDir: workDir, outputBase: (fileName as NSString).deletingPathExtension)
case .ytdlp:
    engine = YTDLPEngine(request: request, config: config, workDir: workDir, outputBase: (fileName as NSString).deletingPathExtension)
}

if let l = limitKBps { RateLimiter.global.bytesPerSecond = l * 1024 }
let started = Date()
var lastLine = Date.distantPast
var renewals = 0
engine.events.progress = { p in
    guard Date().timeIntervalSince(lastLine) > 0.5 else { return }
    lastLine = Date()
    let pct = p.total.map { $0 > 0 ? String(format: "%5.1f%%", Double(p.received) / Double($0) * 100) : "" } ?? "     "
    let rate = Double(p.received) / max(0.001, Date().timeIntervalSince(started))
    FileHandle.standardError.write(Data("\(pct) \(formatBytes(p.received))\(p.total.map { " / \(formatBytes($0))" } ?? "") · \(formatBytes(Int64(rate)))/s · \(p.detail ?? "")\n".utf8))
}
engine.events.completed = { result in
    switch result {
    case let .success(files):
        for (i, f) in files.enumerated() {
            let finalName: String
            if request.kind == .file && request.audioUrl == nil { finalName = fileName }
            else if request.kind == .ytdlp { finalName = f.lastPathComponent }
            else {
                let base = (fileName as NSString).deletingPathExtension
                finalName = files.count > 1 ? "\(base) (\(i == 0 ? "video" : "audio")).\(f.pathExtension)" : "\(base).\(f.pathExtension)"
            }
            let dest = uniqueURL(in: outDir, filename: finalName)
            do { try moveItem(f, to: dest); print(dest.path) } catch { FileHandle.standardError.write(Data("move failed: \(error)\n".utf8)); exit(1) }
        }
        try? FileManager.default.removeItem(at: workDir)
        FileHandle.standardError.write(Data(String(format: "done in %.1fs\n", Date().timeIntervalSince(started)).utf8))
        exit(0)
    case let .failure(err):
        if case CastnetError.linkExpired = err, let src = renewFrom.flatMap(URL.init(string:)), let seg = engine as? SegmentedDownloader, renewals < 5 {
            // Same flow as the app: get a fresh link, check it's the same file, continue from the saved segments.
            renewals += 1
            var state = seg.resumeState
            FileHandle.standardError.write(Data("link expired at \(formatBytes(state.received)); renewing (\(renewals))…\n".utf8))
            Task.detached {
                guard let (d, _) = try? await URLSession.shared.data(from: src), let fresh = URL(string: String(decoding: d, as: UTF8.self)) else { exit(1) }
                let ok = await LinkVerifier.sameFile(newURL: fresh, ctx: RequestContext(request: request), resume: state, partURL: seg.partURL)
                FileHandle.standardError.write(Data("fresh link verified: \(ok)\n".utf8))
                guard ok else { exit(1) }
                state.etag = nil
                state.lastModified = nil
                DispatchQueue.main.async {
                    let next = SegmentedDownloader(url: fresh, ctx: RequestContext(request: request), config: config, partURL: seg.partURL, resume: state)
                    next.events.progress = engine.events.progress
                    next.events.completed = engine.events.completed
                    engine = next
                    next.start()
                }
            }
            return
        }
        FileHandle.standardError.write(Data("error: \((err as? LocalizedError)?.errorDescription ?? "\(err)")\n".utf8))
        exit(1)
    }
}
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    FileHandle.standardError.write(Data("\ninterrupted: stopping (live streams are saved)\n".utf8))
    engine.finishLive()
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(130) }
}
sigint.resume()
engine.start()
if let t = testPauseAfter, let seg = engine as? SegmentedDownloader {
    // Self-test: pause after t seconds, then resume from the saved segment table with a new engine.
    DispatchQueue.global().asyncAfter(deadline: .now() + t) {
        seg.pause()
        let state = seg.resumeState
        FileHandle.standardError.write(Data("paused at \(formatBytes(state.received)) with \(state.segments.count) segments; resuming…\n".utf8))
        let resumed = SegmentedDownloader(url: url, ctx: RequestContext(request: request), config: config,
                                          partURL: seg.partURL, resume: state)
        resumed.events.progress = engine.events.progress
        resumed.events.completed = engine.events.completed
        engine = resumed
        resumed.start()
    }
}
dispatchMain()
