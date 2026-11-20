import Foundation

public enum DownloadKind: String, Codable, CaseIterable {
    case file, hls, dash, ytdlp

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DownloadKind(rawValue: raw.lowercased()) ?? .file
    }

    /// Guess from a URL when the caller didn't say.
    public static func guess(for url: URL) -> DownloadKind {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u": return .hls
        case "mpd": return .dash
        default: return .file
        }
    }
}

/// A browser cookie, as delivered by chrome.cookies.getAll().
public struct CookieInfo: Codable, Hashable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String?
    public var secure: Bool?
    public var httpOnly: Bool?
    public var hostOnly: Bool?
    public var expirationDate: Double?

    public init(name: String, value: String, domain: String, path: String? = "/", secure: Bool? = false,
                httpOnly: Bool? = false, hostOnly: Bool? = false, expirationDate: Double? = nil) {
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.secure = secure; self.httpOnly = httpOnly; self.hostOnly = hostOnly; self.expirationDate = expirationDate
    }

    func matches(_ url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let exp = expirationDate, exp > 0, Date(timeIntervalSince1970: exp) < now { return false }
        if secure == true, url.scheme?.lowercased() != "https" { return false }
        var d = domain.lowercased()
        let leadingDot = d.hasPrefix(".")
        if leadingDot { d.removeFirst() }
        if hostOnly == true || (!leadingDot && hostOnly == nil) {
            if host != d { return false }
        } else if !(host == d || host.hasSuffix("." + d)) {
            return false
        }
        let p = path ?? "/"
        let urlPath = url.path.isEmpty ? "/" : url.path
        return p == "/" || urlPath == p || urlPath.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }
}

/// What the browser extension sends for each download.
public struct DownloadRequest: Codable {
    public var url: String
    public var kind: DownloadKind
    public var filename: String?
    public var title: String?
    public var pageUrl: String?
    public var referer: String?
    public var userAgent: String?
    public var headers: [String: String]?
    public var cookies: [CookieInfo]?
    /// HLS: the exact variant playlist the user picked.
    public var variantUrl: String?
    /// Preferred video height (HLS/DASH), e.g. 1080.
    public var quality: Int?
    public var size: Int64?
    /// Separate audio-only file to merge with `url` (sites that stream audio and video apart).
    public var audioUrl: String?
    /// Site downloads: exact format selection (e.g. "137+140") picked in the browser menu.
    public var format: String?
    /// Site downloads: container to merge into ("mp4", "mkv").
    public var container: String?
    /// Site downloads: whether to send the browser's login cookies (nil = decide per site).
    public var useCookies: Bool?
    /// Set when the address was renewed after expiring (resume without If-Range checks).
    public var refreshed: Bool?
    /// The type the browser saw for a download it handed over (used to check the link).
    public var mime: String?

    public init(url: String, kind: DownloadKind, filename: String? = nil, title: String? = nil, pageUrl: String? = nil,
                referer: String? = nil, userAgent: String? = nil, headers: [String: String]? = nil,
                cookies: [CookieInfo]? = nil, variantUrl: String? = nil, quality: Int? = nil, size: Int64? = nil,
                audioUrl: String? = nil, format: String? = nil, container: String? = nil) {
        self.url = url; self.kind = kind; self.filename = filename; self.title = title; self.pageUrl = pageUrl
        self.referer = referer; self.userAgent = userAgent; self.headers = headers; self.cookies = cookies
        self.variantUrl = variantUrl; self.quality = quality; self.size = size
        self.audioUrl = audioUrl; self.format = format; self.container = container
    }
}

/// Tunables shared by all engines.
public struct EngineConfig {
    public var connections: Int = 8
    public var segmentConcurrency: Int = 6
    public var ffmpeg: URL?
    public var ytdlp: URL?
    public var minSplitBytes: Int64 = 1 << 20

    /// Optional per-download speed limit (the global one always applies too).
    public var limiter: RateLimiter?

    public init(connections: Int = 8, segmentConcurrency: Int = 6, ffmpeg: URL? = nil, ytdlp: URL? = nil) {
        self.connections = max(1, min(32, connections))
        self.segmentConcurrency = max(1, min(32, segmentConcurrency))
        self.ffmpeg = ffmpeg
        self.ytdlp = ytdlp
    }
}

public struct ByteRange: Codable, Hashable {
    public var offset: Int64
    public var length: Int64
    public var header: String { "bytes=\(offset)-\(offset + length - 1)" }
}
