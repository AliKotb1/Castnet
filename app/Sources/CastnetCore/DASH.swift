import Foundation

// MARK: - Minimal XML tree

final class XNode {
    let name: String
    let attrs: [String: String]
    var children: [XNode] = []
    var text = ""
    weak var parent: XNode?

    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

    func all(_ n: String) -> [XNode] { children.filter { $0.name == n } }
    func first(_ n: String) -> XNode? { children.first { $0.name == n } }
    subscript(_ a: String) -> String? { attrs[a] }
}

final class XTreeBuilder: NSObject, XMLParserDelegate {
    var root: XNode?
    private var stack: [XNode] = []

    static func parse(_ data: Data) -> XNode? {
        let b = XTreeBuilder()
        let p = XMLParser(data: data)
        p.delegate = b
        p.shouldProcessNamespaces = false
        return p.parse() ? b.root : nil
    }

    private func local(_ n: String) -> String { n.split(separator: ":").last.map(String.init) ?? n }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        var a: [String: String] = [:]
        for (k, v) in attributes { a[local(k)] = v }
        let node = XNode(name: local(name), attrs: a)
        node.parent = stack.last
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}

// MARK: - MPD model

public struct DASHRepresentation {
    public var id: String
    public var bandwidth: Int
    public var width: Int?
    public var height: Int?
    public var codecs: String?
    public var mimeType: String
    public var isVideo: Bool
    public var isAudio: Bool
    public var lang: String?
    public var protected: Bool
    /// Segment URLs in play order (init first), resolved and expanded.
    public var initSegment: (URL, ByteRange?)?
    public var segments: [(URL, ByteRange?)]
}

public struct DASHManifest {
    public var isLive: Bool
    public var duration: Double?
    /// One list of representations per period.
    public var periods: [[DASHRepresentation]]
}

public enum DASHParser {
    public static func isoDuration(_ s: String?) -> Double? {
        guard let s, s.hasPrefix("P") else { return nil }
        var total = 0.0
        var num = ""
        var inTime = false
        for ch in s.dropFirst() {
            switch ch {
            case "T": inTime = true
            case "0"..."9", ".": num.append(ch)
            case "Y": total += (Double(num) ?? 0) * 365 * 86400; num = ""
            case "D": total += (Double(num) ?? 0) * 86400; num = ""
            case "H": total += (Double(num) ?? 0) * 3600; num = ""
            case "M": total += (Double(num) ?? 0) * (inTime ? 60 : 30 * 86400); num = ""
            case "S": total += Double(num) ?? 0; num = ""
            default: break
            }
        }
        return total
    }

    static func range(_ s: String?) -> ByteRange? {
        guard let s else { return nil }
        let p = s.split(separator: "-")
        guard p.count == 2, let a = Int64(p[0]), let b = Int64(p[1]), b >= a else { return nil }
        return ByteRange(offset: a, length: b - a + 1)
    }

    /// Expands $RepresentationID$, $Bandwidth$, $Number%05d$, $Time$ and $$.
    static func expand(_ template: String, id: String, bandwidth: Int, number: Int? = nil, time: Int64? = nil) -> String {
        var out = ""
        var rest = Substring(template)
        while let start = rest.firstIndex(of: "$") {
            out += rest[..<start]
            let afterStart = rest.index(after: start)
            guard let end = rest[afterStart...].firstIndex(of: "$") else { out += rest[start...]; return out }
            let token = String(rest[afterStart..<end])
            rest = rest[rest.index(after: end)...]
            if token.isEmpty { out += "$"; continue }
            let parts = token.split(separator: "%", maxSplits: 1)
            let name = String(parts[0])
            let fmt = parts.count > 1 ? "%" + parts[1].replacingOccurrences(of: "d", with: "lld") : "%lld"
            func fmtNum(_ v: Int64) -> String { String(format: fmt, v) }
            switch name {
            case "RepresentationID": out += id
            case "Bandwidth": out += fmtNum(Int64(bandwidth))
            case "Number": out += fmtNum(Int64(number ?? 0))
            case "Time": out += fmtNum(time ?? 0)
            default: out += "$\(token)$"
            }
        }
        out += rest
        return out
    }

    static func resolveBase(_ node: XNode?, _ base: URL) -> URL {
        guard let b = node?.first("BaseURL")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty,
              let u = URL(string: b, relativeTo: base)?.absoluteURL else { return base }
        return u
    }

    /// Merges SegmentTemplate attributes/children from AdaptationSet then Representation level.
    static func merged(_ name: String, _ nodes: [XNode?]) -> (attrs: [String: String], timeline: XNode?, list: XNode?)? {
        var attrs: [String: String] = [:]
        var timeline: XNode?
        var node: XNode?
        for n in nodes.compactMap({ $0?.first(name) }) {
            node = n
            attrs.merge(n.attrs) { _, new in new }
            if let t = n.first("SegmentTimeline") { timeline = t }
        }
        guard node != nil else { return nil }
        return (attrs, timeline, node)
    }

    public static func parse(_ data: Data, baseURL: URL) throws -> DASHManifest {
        guard let mpd = XTreeBuilder.parse(data), mpd.name == "MPD" else { throw CastnetError.invalid("Not a DASH manifest") }
        let isLive = mpd["type"] == "dynamic"
        let total = isoDuration(mpd["mediaPresentationDuration"])
        let mpdBase = resolveBase(mpd, baseURL)
        let periodNodes = mpd.all("Period")
        var periods: [[DASHRepresentation]] = []

        for (pi, period) in periodNodes.enumerated() {
            let start = isoDuration(period["start"]) ?? 0
            var pdur = isoDuration(period["duration"])
            if pdur == nil {
                if pi + 1 < periodNodes.count, let nextStart = isoDuration(periodNodes[pi + 1]["start"]) { pdur = nextStart - start }
                else if let total { pdur = total - start }
            }
            let pBase = resolveBase(period, mpdBase)
            var reps: [DASHRepresentation] = []
            for set in period.all("AdaptationSet") {
                let sBase = resolveBase(set, pBase)
                let setProtected = set.first("ContentProtection") != nil
                for rep in set.all("Representation") {
                    let id = rep["id"] ?? "\(reps.count)"
                    let bw = Int(rep["bandwidth"] ?? "") ?? 0
                    let mime = rep["mimeType"] ?? set["mimeType"] ?? ""
                    let ctype = set["contentType"] ?? ""
                    let height = Int(rep["height"] ?? set["height"] ?? "")
                    let isVideo = mime.hasPrefix("video") || ctype == "video" || height != nil
                    let isAudio = !isVideo && (mime.hasPrefix("audio") || ctype == "audio")
                    let rBase = resolveBase(rep, sBase)
                    var initSeg: (URL, ByteRange?)?
                    var segs: [(URL, ByteRange?)] = []

                    if let tpl = merged("SegmentTemplate", [period, set, rep]) {
                        let a = tpl.attrs
                        let timescale = Double(a["timescale"] ?? "1") ?? 1
                        let startNumber = Int(a["startNumber"] ?? "1") ?? 1
                        if let ini = a["initialization"] {
                            let s = expand(ini, id: id, bandwidth: bw)
                            if let u = URL(string: s, relativeTo: rBase)?.absoluteURL { initSeg = (u, nil) }
                        }
                        if let media = a["media"] {
                            func add(number: Int, time: Int64) {
                                let s = expand(media, id: id, bandwidth: bw, number: number, time: time)
                                if let u = URL(string: s, relativeTo: rBase)?.absoluteURL { segs.append((u, nil)) }
                            }
                            if let tl = tpl.timeline {
                                var t: Int64 = 0
                                var n = startNumber
                                let endTime = pdur.map { Int64($0 * timescale) }
                                let sList = tl.all("S")
                                for (si, s) in sList.enumerated() {
                                    if let st = s["t"].flatMap({ Int64($0) }) { t = st }
                                    let d = Int64(s["d"] ?? "0") ?? 0
                                    guard d > 0 else { continue }
                                    var r = Int(s["r"] ?? "0") ?? 0
                                    if r < 0 {
                                        // Repeat until the next S@t or the end of the period.
                                        let limit = si + 1 < sList.count ? sList[si + 1]["t"].flatMap({ Int64($0) }) : endTime
                                        r = limit.map { Int(max(0, ($0 - t + d - 1) / d) - 1) } ?? 0
                                    }
                                    for _ in 0...max(0, r) {
                                        add(number: n, time: t)
                                        t += d
                                        n += 1
                                    }
                                }
                            } else if let d = Double(a["duration"] ?? ""), d > 0 {
                                let count = pdur.map { Int(ceil($0 * timescale / d)) } ?? 0
                                for k in 0..<count { add(number: startNumber + k, time: Int64(Double(k) * d)) }
                            }
                        }
                    } else if let list = merged("SegmentList", [period, set, rep])?.list {
                        if let ini = list.first("Initialization") {
                            let u = ini["sourceURL"].flatMap { URL(string: $0, relativeTo: rBase)?.absoluteURL } ?? rBase
                            initSeg = (u, range(ini["range"]))
                        }
                        for su in list.all("SegmentURL") {
                            let u = su["media"].flatMap { URL(string: $0, relativeTo: rBase)?.absoluteURL } ?? rBase
                            segs.append((u, range(su["mediaRange"])))
                        }
                    } else {
                        // SegmentBase or bare BaseURL: one self-contained file.
                        segs.append((rBase, nil))
                    }

                    reps.append(DASHRepresentation(
                        id: id, bandwidth: bw, width: Int(rep["width"] ?? set["width"] ?? ""), height: height,
                        codecs: rep["codecs"] ?? set["codecs"], mimeType: mime, isVideo: isVideo, isAudio: isAudio,
                        lang: set["lang"], protected: setProtected || rep.first("ContentProtection") != nil,
                        initSegment: initSeg, segments: segs))
                }
            }
            periods.append(reps)
        }
        return DASHManifest(isLive: isLive, duration: total, periods: periods)
    }
}

// MARK: - Engine

/// Downloads the best (or requested) video representation plus the best audio
/// representation of a DASH manifest, then merges them with ffmpeg.
public final class DASHEngine: AsyncEngine {
    let request: DownloadRequest
    let ctx: RequestContext
    let config: EngineConfig
    let outputBase: String
    private let runner = ToolRunner()

    public init(request: DownloadRequest, config: EngineConfig, workDir: URL, outputBase: String) {
        self.request = request
        self.ctx = RequestContext(request: request)
        self.config = config
        self.outputBase = outputBase
        super.init(workDir: workDir)
    }

    public override func stopProcesses() { runner.terminate() }

    static func pick(_ reps: [DASHRepresentation], height: Int?) -> (video: DASHRepresentation?, audio: DASHRepresentation?) {
        let videos = reps.filter(\.isVideo)
        var video: DASHRepresentation?
        if let h = height {
            video = videos.filter { ($0.height ?? 0) <= h }.max { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
        }
        video = video ?? videos.max { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
        let audios = reps.filter(\.isAudio)
        let audio = audios.max { $0.bandwidth < $1.bandwidth }
        return (video, audio)
    }

    public override func run() async throws -> [URL] {
        guard let url = URL(string: request.url) else { throw CastnetError.invalid("Bad URL") }
        let fetcher = SegmentFetcher(ctx: ctx, concurrency: config.segmentConcurrency)
        report(0, nil, "Reading manifest…")
        let (videoJobs, audioJobs, label) = try await planJobs(url: url, fetcher: fetcher)
        guard !videoJobs.isEmpty || !audioJobs.isEmpty else { throw CastnetError.invalid("No downloadable representations in manifest") }
        return try await download(videoJobs: videoJobs, audioJobs: audioJobs, label: label, url: url, fetcher: fetcher)
    }

    private func planJobs(url: URL, fetcher: SegmentFetcher) async throws -> ([SegmentJob], [SegmentJob], String) {
        let (data, resp): (Data, HTTPURLResponse)
        do { (data, resp) = try await ctx.fetch(url, session: fetcher.session) }
        catch CastnetError.http(let code, _) where isLinkError(code) { throw CastnetError.linkExpired }
        let manifest = try DASHParser.parse(data, baseURL: resp.url ?? url)
        if manifest.isLive { throw CastnetError.unsupported("Live DASH streams aren't supported. Try “Grab with yt-dlp”.") }

        var videoJobs: [SegmentJob] = []
        var audioJobs: [SegmentJob] = []
        var label = ""
        for reps in manifest.periods {
            let (v, a) = Self.pick(reps, height: request.quality)
            if v?.protected == true || a?.protected == true { throw CastnetError.drm }
            if let v {
                if label.isEmpty, let h = v.height { label = "\(h)p" }
                for (u, r) in ([v.initSegment].compactMap { $0 } + v.segments) {
                    videoJobs.append(SegmentJob(index: videoJobs.count, url: u, range: r, key: nil))
                }
            }
            if let a {
                for (u, r) in ([a.initSegment].compactMap { $0 } + a.segments) {
                    audioJobs.append(SegmentJob(index: audioJobs.count, url: u, range: r, key: nil))
                }
            }
        }
        return (videoJobs, audioJobs, label)
    }

    private func download(videoJobs: [SegmentJob], audioJobs: [SegmentJob], label: String, url: URL, fetcher: SegmentFetcher) async throws -> [URL] {
        let total = videoJobs.count + audioJobs.count
        var outputs: [URL] = []
        var doneBefore = 0
        var bytesBefore: Int64 = 0
        for (name, firstJobs) in [("video", videoJobs), ("audio", audioJobs)] where !firstJobs.isEmpty {
            let dir = workDir.appendingPathComponent(name, isDirectory: true)
            var jobs = firstJobs
            var refreshes = 0
            while true {
                do {
                    try await fetcher.fetchAll(jobs, into: dir) { done, bytes in
                        let d = doneBefore + done, b = bytesBefore + bytes
                        let est = d > 0 ? Int64(Double(b) / Double(d) * Double(total)) : nil
                        self.report(b, est, "\(name.capitalized) segment \(d)/\(total)\(label.isEmpty ? "" : " · \(label)")")
                    }
                    break
                } catch CastnetError.linkExpired where refreshes < 3 {
                    refreshes += 1
                    report(bytesBefore, nil, "Links expired, refreshing the manifest…")
                    let (v, a, _) = try await planJobs(url: url, fetcher: fetcher)
                    jobs = name == "video" ? v : a
                }
            }
            doneBefore += jobs.count
            bytesBefore += HLSEngine.dirSize(dir)
            let ext = Self.sniffExt(SegmentFetcher.path(for: jobs[0], in: dir), audio: name == "audio")
            let out = workDir.appendingPathComponent("\(name).\(ext)")
            try SegmentFetcher.concatenate(jobs, from: dir, to: out)
            outputs.append(out)
        }

        guard let ffmpeg = config.ffmpeg else { return outputs }
        let webm = outputs.contains { $0.pathExtension == "webm" }
        let ext = outputs.count == 1 && outputs[0].lastPathComponent.hasPrefix("audio") ? (webm ? "webm" : "m4a") : (webm ? "mkv" : "mp4")
        let final = workDir.appendingPathComponent("\(outputBase).\(ext)")
        report(bytesBefore, bytesBefore, outputs.count > 1 ? "Merging audio and video (ffmpeg)…" : "Finalizing (ffmpeg)…")
        do {
            if outputs.count == 2 {
                try await Muxer.merge(ffmpeg: ffmpeg, video: outputs[0], audio: outputs[1], output: final, runner: runner)
            } else {
                try await Muxer.remux(ffmpeg: ffmpeg, input: outputs[0], output: final, runner: runner)
            }
            return [final]
        } catch {
            if isUserCancelled { throw CancellationError() }
            return outputs
        }
    }

    static func sniffExt(_ file: URL, audio: Bool) -> String {
        guard let h = try? FileHandle(forReadingFrom: file) else { return audio ? "m4a" : "mp4" }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4)) ?? Data()
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        return audio ? "m4a" : "mp4"
    }
}
