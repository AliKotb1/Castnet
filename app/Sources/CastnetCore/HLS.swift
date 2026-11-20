import Foundation

// MARK: - Playlist model

public struct HLSVariant {
    public var url: URL
    public var bandwidth: Int
    public var width: Int?
    public var height: Int?
    public var codecs: String?
    public var audioGroup: String?
}

public struct HLSRendition {
    public var type: String
    public var groupId: String
    public var name: String?
    public var language: String?
    public var isDefault: Bool
    public var url: URL?
}

public struct HLSKeyInfo {
    public var method: String
    public var uri: URL?
    public var iv: Data?
    public var keyFormat: String?

    var isDRM: Bool {
        let m = method.uppercased()
        if m.hasPrefix("SAMPLE-AES") { return true }
        if let f = keyFormat?.lowercased(), f != "identity" { return true }
        return uri?.scheme?.lowercased() == "skd" // FairPlay

    }
}

public struct HLSMap: Equatable {
    public var url: URL
    public var range: ByteRange?
}

public struct HLSSegment {
    public var url: URL
    public var duration: Double
    public var range: ByteRange?
    public var key: HLSKeyInfo?
    public var map: HLSMap?
    public var sequence: Int
}

public struct HLSMediaPlaylist {
    public var targetDuration: Double = 6
    public var mediaSequence: Int = 0
    public var segments: [HLSSegment] = []
    public var endList = false
    public var isVOD = false
    public var hasDRM = false
    public var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
}

public enum HLSPlaylist {
    case master(variants: [HLSVariant], renditions: [HLSRendition], drm: Bool)
    case media(HLSMediaPlaylist)
}

// MARK: - Parser

public enum HLSParser {
    static func attributes(_ s: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            guard let eq = s[i...].firstIndex(of: "=") else { break }
            let key = s[i..<eq].trimmingCharacters(in: CharacterSet(charactersIn: ", ")).uppercased()
            var j = s.index(after: eq)
            var value = ""
            if j < s.endIndex, s[j] == "\"" {
                let start = s.index(after: j)
                let end = s[start...].firstIndex(of: "\"") ?? s.endIndex
                value = String(s[start..<end])
                j = end < s.endIndex ? s.index(after: end) : end
            } else {
                let end = s[j...].firstIndex(of: ",") ?? s.endIndex
                value = String(s[j..<end])
                j = end
            }
            out[key] = value
            if j < s.endIndex, s[j] == "," { j = s.index(after: j) }
            i = j
        }
        return out
    }

    /// "length[@offset]" → (length, offset?)
    static func parseRangeParts(_ s: String) -> (length: Int64, offset: Int64?)? {
        let parts = s.split(separator: "@")
        guard let first = parts.first, let len = Int64(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let off = parts.count > 1 ? Int64(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (len, off)
    }

    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first(where: { !$0.isEmpty })?.hasPrefix("#EXTM3U") == true else {
            throw CastnetError.invalid("Not an HLS playlist")
        }
        func resolve(_ s: String) -> URL? { URL(string: s, relativeTo: baseURL)?.absoluteURL }

        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var pendingInf: [String: String]?
        var media = HLSMediaPlaylist()
        var masterDRM = false

        var duration: Double?
        var pendingRange: (length: Int64, offset: Int64?)?
        var lastRangeEnd: [URL: Int64] = [:]
        var key: HLSKeyInfo?
        var map: HLSMap?
        var seq = 0

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingInf = attributes(line.dropFirst(18))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(line.dropFirst(13))
                renditions.append(HLSRendition(type: a["TYPE"] ?? "", groupId: a["GROUP-ID"] ?? "", name: a["NAME"],
                                               language: a["LANGUAGE"], isDefault: a["DEFAULT"] == "YES",
                                               url: a["URI"].flatMap(resolve)))
            } else if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let a = attributes(line.dropFirst(19))
                let k = HLSKeyInfo(method: a["METHOD"] ?? "NONE", uri: a["URI"].flatMap(resolve), iv: nil, keyFormat: a["KEYFORMAT"])
                if k.isDRM { masterDRM = true }
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                media.targetDuration = Double(line.dropFirst(22)) ?? 6
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                seq = Int(line.dropFirst(22)) ?? 0
                media.mediaSequence = seq
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                media.isVOD = line.dropFirst(21).uppercased() == "VOD"
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                media.endList = true
            } else if line.hasPrefix("#EXTINF:") {
                let v = line.dropFirst(8).split(separator: ",", maxSplits: 1).first ?? ""
                duration = Double(v.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseRangeParts(String(line.dropFirst(17)))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let a = attributes(line.dropFirst(11))
                let method = (a["METHOD"] ?? "NONE").uppercased()
                if method == "NONE" {
                    key = nil
                } else {
                    let k = HLSKeyInfo(method: method, uri: a["URI"].flatMap(resolve), iv: a["IV"].flatMap(hexToData), keyFormat: a["KEYFORMAT"])
                    if k.isDRM { media.hasDRM = true }
                    key = k
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(line.dropFirst(11))
                if let u = a["URI"].flatMap(resolve) {
                    let r = a["BYTERANGE"].flatMap(parseRangeParts).map { ByteRange(offset: $0.offset ?? 0, length: $0.length) }
                    map = HLSMap(url: u, range: r)
                }
            } else if line.hasPrefix("#") {
                continue
            } else if let inf = pendingInf {
                pendingInf = nil
                guard let u = resolve(line) else { continue }
                let res = inf["RESOLUTION"]?.lowercased().split(separator: "x").compactMap { Int($0) }
                variants.append(HLSVariant(url: u, bandwidth: Int(inf["AVERAGE-BANDWIDTH"] ?? inf["BANDWIDTH"] ?? "") ?? 0,
                                           width: res?.count == 2 ? res?[0] : nil, height: res?.count == 2 ? res?[1] : nil,
                                           codecs: inf["CODECS"], audioGroup: inf["AUDIO"]))
            } else if let d = duration {
                guard let u = resolve(line) else { continue }
                var r: ByteRange?
                if let pr = pendingRange {
                    // "#EXT-X-BYTERANGE:n" without "@offset" continues after the previous range of the same file.
                    let off = pr.offset ?? lastRangeEnd[u] ?? 0
                    r = ByteRange(offset: off, length: pr.length)
                    lastRangeEnd[u] = off + pr.length
                }
                media.segments.append(HLSSegment(url: u, duration: d, range: r, key: key, map: map, sequence: seq))
                seq += 1
                duration = nil
                pendingRange = nil
            }
        }
        if !variants.isEmpty || renditions.contains(where: { $0.url != nil }) && media.segments.isEmpty {
            return .master(variants: variants, renditions: renditions, drm: masterDRM)
        }
        return .media(media)
    }
}

// MARK: - Engine

/// Downloads an HLS stream: picks a variant (and its separate audio rendition),
/// fetches segments concurrently, decrypts AES-128, joins them, and remuxes to MP4
/// with ffmpeg when available. Live playlists are recorded until `finishLive()`.
public final class HLSEngine: AsyncEngine {
    let request: DownloadRequest
    let ctx: RequestContext
    let config: EngineConfig
    let outputBase: String
    private let runner = ToolRunner()
    private var liveStop = false
    private let liveLock = NSLock()

    public init(request: DownloadRequest, config: EngineConfig, workDir: URL, outputBase: String) {
        self.request = request
        self.ctx = RequestContext(request: request)
        self.config = config
        self.outputBase = outputBase
        super.init(workDir: workDir)
    }

    public override func stopProcesses() { runner.terminate() }

    public override func finishLive() {
        liveLock.lock(); liveStop = true; liveLock.unlock()
    }

    private var shouldStopLive: Bool { liveLock.lock(); defer { liveLock.unlock() }; return liveStop }

    struct Track { let name: String; let playlistURL: URL }

    public override func run() async throws -> [URL] {
        guard let masterURL = URL(string: request.url) else { throw CastnetError.invalid("Bad URL") }
        let fetcher = SegmentFetcher(ctx: ctx, concurrency: config.segmentConcurrency)
        report(0, nil, "Reading playlist…")

        let (data, resp): (Data, HTTPURLResponse)
        do { (data, resp) = try await ctx.fetch(masterURL, session: fetcher.session) }
        catch CastnetError.http(let code, _) where isLinkError(code) { throw CastnetError.linkExpired }
        let base = resp.url ?? masterURL
        var tracks: [Track] = []
        var detail = ""

        switch try HLSParser.parse(String(decoding: data, as: UTF8.self), baseURL: base) {
        case let .master(variants, renditions, drm):
            if drm { throw CastnetError.drm }
            let chosen = Self.pickVariant(variants, wantedURL: request.variantUrl, height: request.quality)
            if let v = chosen {
                tracks.append(Track(name: "video", playlistURL: v.url))
                detail = v.height.map { "\($0)p" } ?? ""
                if let group = v.audioGroup {
                    let audios = renditions.filter { $0.type == "AUDIO" && $0.groupId == group && $0.url != nil }
                    if let a = audios.first(where: \.isDefault) ?? audios.first, let u = a.url, u != v.url {
                        tracks.append(Track(name: "audio", playlistURL: u))
                    }
                }
            } else if let a = renditions.first(where: { $0.type == "AUDIO" && $0.url != nil }), let u = a.url {
                tracks.append(Track(name: "audio", playlistURL: u))
            } else {
                throw CastnetError.invalid("Master playlist has no playable variants")
            }
        case .media:
            tracks.append(Track(name: "video", playlistURL: base))
        }

        // Load media playlists.
        var playlists: [(Track, HLSMediaPlaylist)] = []
        for t in tracks {
            let pl: HLSMediaPlaylist
            if t.playlistURL == base, case let .media(p) = try HLSParser.parse(String(decoding: data, as: UTF8.self), baseURL: base) {
                pl = p
            } else {
                let (d, r) = try await ctx.fetch(t.playlistURL, session: fetcher.session)
                guard case let .media(p) = try HLSParser.parse(String(decoding: d, as: UTF8.self), baseURL: r.url ?? t.playlistURL) else {
                    throw CastnetError.invalid("Expected a media playlist at \(t.playlistURL.lastPathComponent)")
                }
                pl = p
            }
            if pl.hasDRM { throw CastnetError.drm }
            playlists.append((t, pl))
        }

        let isLive = !(playlists.first?.1.endList ?? true) && !(playlists.first?.1.isVOD ?? false)
        var outputs: [URL] = []
        if isLive {
            outputs = try await recordLive(playlists: playlists, fetcher: fetcher, label: detail)
        } else {
            let allJobs = playlists.map { Self.jobs(for: $0.1) }
            let totalJobs = allJobs.reduce(0) { $0 + $1.count }
            var doneBefore = 0
            var bytesBefore: Int64 = 0
            for (i, (track, _)) in playlists.enumerated() {
                var jobs = allJobs[i]
                let dir = workDir.appendingPathComponent(track.name, isDirectory: true)
                var refreshes = 0
                while true {
                    do {
                        try await fetcher.fetchAll(jobs, into: dir) { done, bytes in
                            let d = doneBefore + done
                            let b = bytesBefore + bytes
                            let est = d > 0 ? Int64(Double(b) / Double(d) * Double(totalJobs)) : nil
                            self.report(b, est, "\(track.name == "audio" ? "Audio" : "Segment") \(d)/\(totalJobs)\(detail.isEmpty ? "" : " · \(detail)")")
                        }
                        break
                    } catch CastnetError.linkExpired where refreshes < 3 {
                        // Segment links expired: re-read the playlist for fresh ones and continue.
                        refreshes += 1
                        report(bytesBefore, nil, "Links expired, refreshing the playlist…")
                        jobs = Self.jobs(for: try await reloadPlaylist(track, fetcher: fetcher, base: base))
                    }
                }
                doneBefore += jobs.count
                bytesBefore = Self.dirSize(dir)
                let out = workDir.appendingPathComponent("\(track.name).\(Self.containerExt(jobs, dir: dir))")
                try SegmentFetcher.concatenate(jobs, from: dir, to: out)
                outputs.append(out)
            }
        }
        return try await finalize(outputs)
    }

    /// Fetches a track's media playlist again (fresh segment tokens). If the variant address
    /// itself expired, goes back to the master playlist and picks the same quality.
    private func reloadPlaylist(_ track: Track, fetcher: SegmentFetcher, base: URL) async throws -> HLSMediaPlaylist {
        func media(_ url: URL) async throws -> HLSMediaPlaylist {
            do {
                let (d, r) = try await ctx.fetch(url, session: fetcher.session)
                guard case let .media(p) = try HLSParser.parse(String(decoding: d, as: UTF8.self), baseURL: r.url ?? url) else {
                    throw CastnetError.invalid("Expected a media playlist")
                }
                return p
            } catch CastnetError.http(let code, _) where isLinkError(code) {
                throw CastnetError.linkExpired
            }
        }
        if let p = try? await media(track.playlistURL) { return p }
        guard let masterURL = URL(string: request.url) else { throw CastnetError.linkExpired }
        let (d, r): (Data, HTTPURLResponse)
        do { (d, r) = try await ctx.fetch(masterURL, session: fetcher.session) }
        catch CastnetError.http(let code, _) where isLinkError(code) { throw CastnetError.linkExpired }
        guard case let .master(variants, renditions, _) = try HLSParser.parse(String(decoding: d, as: UTF8.self), baseURL: r.url ?? masterURL) else {
            return try await media(r.url ?? masterURL)
        }
        if track.name == "audio", let a = renditions.first(where: { $0.type == "AUDIO" && $0.url != nil })?.url { return try await media(a) }
        guard let v = Self.pickVariant(variants, wantedURL: nil, height: request.quality) else { throw CastnetError.linkExpired }
        return try await media(v.url)
    }

    /// Picks the variant matching the requested URL / height, else the highest bandwidth.
    static func pickVariant(_ variants: [HLSVariant], wantedURL: String?, height: Int?) -> HLSVariant? {
        if let w = wantedURL, let v = variants.first(where: { $0.url.absoluteString == w }) { return v }
        if let h = height {
            let fit = variants.filter { ($0.height ?? 0) <= h }.max { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
            if let fit { return fit }
        }
        return variants.max { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
    }

    /// Turns a media playlist into download jobs, inserting each EXT-X-MAP init section once.
    static func jobs(for pl: HLSMediaPlaylist, startIndex: Int = 0, after: Int? = nil, lastMap: inout HLSMap?) -> [SegmentJob] {
        var jobs: [SegmentJob] = []
        var idx = startIndex
        for seg in pl.segments {
            if let after, seg.sequence <= after { continue }
            if let m = seg.map, m != lastMap {
                jobs.append(SegmentJob(index: idx, url: m.url, range: m.range, key: nil))
                idx += 1
                lastMap = m
            }
            var aes: AESKey?
            if let k = seg.key, k.method == "AES-128", let u = k.uri {
                aes = AESKey(url: u, iv: k.iv ?? ivFromSequence(seg.sequence))
            }
            jobs.append(SegmentJob(index: idx, url: seg.url, range: seg.range, key: aes))
            idx += 1
        }
        return jobs
    }

    static func jobs(for pl: HLSMediaPlaylist) -> [SegmentJob] {
        var m: HLSMap?
        return jobs(for: pl, lastMap: &m)
    }

    static func containerExt(_ jobs: [SegmentJob], dir: URL) -> String {
        // fMP4 (CMAF) streams start with an init section; their join is a playable fragmented MP4.
        guard let first = jobs.first, let h = try? FileHandle(forReadingFrom: SegmentFetcher.path(for: first, in: dir)) else { return "ts" }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 12)) ?? Data()
        if head.count >= 8, String(decoding: head[4..<8], as: UTF8.self) == "ftyp" || String(decoding: head[4..<8], as: UTF8.self) == "styp" { return "mp4" }
        if head.first == 0x47 { return "ts" }
        if head.starts(with: [0x49, 0x44, 0x33]) { return "aac" } // packed audio with ID3
        return "ts"
    }

    static func dirSize(_ dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func recordLive(playlists: [(Track, HLSMediaPlaylist)], fetcher: SegmentFetcher, label: String) async throws -> [URL] {
        var outputs: [URL] = []
        var state: [(track: Track, lastSeq: Int?, nextIndex: Int, map: HLSMap?, jobs: [SegmentJob])] =
            playlists.map { ($0.0, nil, 0, nil, []) }
        var current = playlists.map(\.1)
        let started = Date()
        while true {
            for i in state.indices {
                var lastMap = state[i].map
                let newJobs = Self.jobs(for: current[i], startIndex: state[i].nextIndex, after: state[i].lastSeq, lastMap: &lastMap)
                state[i].map = lastMap
                if let lastSeg = current[i].segments.last { state[i].lastSeq = max(state[i].lastSeq ?? -1, lastSeg.sequence) }
                state[i].nextIndex += newJobs.count
                state[i].jobs += newJobs
                let dir = workDir.appendingPathComponent(state[i].track.name, isDirectory: true)
                try await fetcher.fetchAll(newJobs, into: dir) { _, _ in }
            }
            let bytes = state.reduce(Int64(0)) { $0 + Self.dirSize(workDir.appendingPathComponent($1.track.name)) }
            report(bytes, nil, "Recording live · \(formatDuration(Date().timeIntervalSince(started)))\(label.isEmpty ? "" : " · \(label)") · Stop to save")
            if shouldStopLive || current.allSatisfy(\.endList) { break }
            try await Task.sleep(nanoseconds: UInt64(max(1.0, (current.first?.targetDuration ?? 6) / 2) * 1e9))
            if shouldStopLive { break }
            for i in state.indices {
                if let (d, r) = try? await ctx.fetch(state[i].track.playlistURL, session: fetcher.session),
                   case let .media(p) = try HLSParser.parse(String(decoding: d, as: UTF8.self), baseURL: r.url ?? state[i].track.playlistURL) {
                    current[i] = p
                }
            }
        }
        for s in state where !s.jobs.isEmpty {
            let dir = workDir.appendingPathComponent(s.track.name, isDirectory: true)
            let out = workDir.appendingPathComponent("\(s.track.name).\(Self.containerExt(s.jobs, dir: dir))")
            try SegmentFetcher.concatenate(s.jobs, from: dir, to: out)
            outputs.append(out)
        }
        return outputs
    }

    private func finalize(_ outputs: [URL]) async throws -> [URL] {
        guard !outputs.isEmpty else { throw CastnetError.invalid("Nothing was downloaded") }
        let audioOnly = outputs.count == 1 && outputs[0].lastPathComponent.hasPrefix("audio")
        let wantExt = audioOnly ? "m4a" : "mp4"
        guard let ffmpeg = config.ffmpeg else {
            // No ffmpeg: hand back the raw joined stream(s). .ts plays in IINA/VLC.
            return outputs
        }
        report(Self.dirSize(workDir), nil, outputs.count > 1 ? "Merging audio and video (ffmpeg)…" : "Converting to \(wantExt.uppercased()) (ffmpeg)…")
        let final = workDir.appendingPathComponent("\(outputBase).\(wantExt)")
        do {
            if outputs.count > 1 {
                try await Muxer.merge(ffmpeg: ffmpeg, video: outputs[0], audio: outputs[1], output: final, runner: runner)
            } else {
                try await Muxer.remux(ffmpeg: ffmpeg, input: outputs[0], output: final, runner: runner)
            }
        } catch {
            if isUserCancelled { throw CancellationError() }
            return outputs // keep the raw stream rather than failing
        }
        return [final]
    }
}
