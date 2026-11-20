import Foundation
import CommonCrypto

public let castnetVersion = "1.5.1"

public enum CastnetError: LocalizedError {
    case http(Int, String)
    case drm
    case unsupported(String)
    case invalid(String)
    case toolMissing(String)
    case process(String)
    case cancelled
    /// The download address stopped working (expired/revoked signed URL). Progress is kept.
    case linkExpired

    public var errorDescription: String? {
        switch self {
        case let .http(code, url): return "HTTP \(code) for \(URL(string: url)?.host ?? url)"
        case .drm: return "This stream is DRM-protected (Widevine/FairPlay/PlayReady). Castnet does not download protected content."
        case let .unsupported(s): return s
        case let .invalid(s): return s
        case let .toolMissing(t): return "Castnet's built-in \(t) is missing. Please reinstall Castnet."
        case let .process(s): return s
        case .cancelled: return "Cancelled"
        case .linkExpired: return "The download link expired"
        }
    }
}

// MARK: - Paths

public enum Paths {
    /// Test mode: CASTNET_HOME gives a completely separate support folder, socket and settings,
    /// so automated tests never touch the real download list.
    public static var testHome: URL? {
        ProcessInfo.processInfo.environment["CASTNET_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static var defaults: UserDefaults {
        if testHome != nil, let d = UserDefaults(suiteName: "app.castnet.mac.test") { return d }
        return .standard
    }

    public static var support: URL {
        let dir = testHome ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Castnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Unix socket the app listens on. Kept short: sun_path is limited to 104 bytes, so test
    /// homes (often long paths) use a hashed name in the per-user temporary folder.
    public static var socket: URL {
        if let home = testHome { return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("castnet-\(shortHash(home.path)).sock") }
        return support.appendingPathComponent("ipc.sock")
    }

    public static func shortHash(_ s: String) -> String {
        var h: UInt32 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt32(b) }
        return String(h, radix: 16)
    }

    public static var stateFile: URL { support.appendingPathComponent("downloads.json") }

    public static var caches: URL {
        let dir = testHome?.appendingPathComponent("Caches", isDirectory: true)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Castnet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var defaultDownloads: URL {
        testHome?.appendingPathComponent("Downloads", isDirectory: true)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}

// MARK: - External tools (ffmpeg, yt-dlp)

public enum Tools {
    public static var searchDirs: [String] {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/bin"]
    }

    /// Castnet.app/Contents/Helpers: the tools that ship inside the app (yt-dlp, ffmpeg, ffprobe, qjs).
    public static var bundledDir: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let helpers = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: helpers.path) ? helpers : nil
    }

    /// Writable copy of the site extractor that keeps itself up to date (see ExtractorUpdater).
    public static var updatableDir: URL { Paths.support.appendingPathComponent("bin", isDirectory: true) }

    /// Finds a tool: explicit path, then the self-updating extractor copy, then the copy inside
    /// Castnet.app. System locations (Homebrew…) are only a fallback for development builds.
    public static func find(_ name: String, override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty, fm.isExecutableFile(atPath: o) {
            return URL(fileURLWithPath: o)
        }
        if name == "yt-dlp" {
            let u = updatableDir.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }
        if let b = bundledDir?.appendingPathComponent(name), fm.isExecutableFile(atPath: b.path) { return b }
        var dirs = searchDirs
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
}

// MARK: - Files and formatting

public func sanitizeFilename(_ s: String, fallback: String = "download") -> String {
    var out = s.replacingOccurrences(of: "[\\u0000-\\u001F\\u007F/:\\\\]", with: " ", options: .regularExpression)
    out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while out.hasPrefix(".") { out.removeFirst() }
    if out.count > 180 {
        let ext = (out as NSString).pathExtension
        let base = (out as NSString).deletingPathExtension
        out = String(base.prefix(170)) + (ext.isEmpty ? "" : ".\(ext)")
    }
    return out.isEmpty ? fallback : out
}

/// Returns `dir/filename`, or `dir/name (2).ext` etc. if that already exists.
public func uniqueURL(in dir: URL, filename: String, reserved: Set<String> = []) -> URL {
    let fm = FileManager.default
    let ext = (filename as NSString).pathExtension
    let base = (filename as NSString).deletingPathExtension
    var candidate = dir.appendingPathComponent(filename)
    var n = 2
    while fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
        candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        n += 1
    }
    return candidate
}

public func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: n)
}

public func formatDuration(_ s: TimeInterval) -> String {
    guard s.isFinite, s >= 0 else { return "" }
    let t = Int(s.rounded())
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

public func filenameFromContentDisposition(_ value: String?) -> String? {
    guard let value else { return nil }
    if let r = value.range(of: "filename\\*\\s*=\\s*[^']*'[^']*'([^;]+)", options: [.regularExpression, .caseInsensitive]) {
        let part = String(value[r])
        if let q = part.range(of: "'[^']*'", options: .regularExpression) {
            let enc = String(part[q.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if let dec = enc.removingPercentEncoding, !dec.isEmpty { return dec }
        }
    }
    if let r = value.range(of: "filename\\s*=\\s*(\"[^\"]*\"|[^;]+)", options: [.regularExpression, .caseInsensitive]) {
        var part = String(value[r])
        part = String(part[part.index(after: part.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
        part = part.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return part.removingPercentEncoding ?? part
    }
    return nil
}

public let mimeExtensions: [String: String] = [
    "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov", "video/x-matroska": "mkv",
    "video/x-flv": "flv", "video/mp2t": "ts", "video/x-msvideo": "avi", "video/3gpp": "3gp",
    "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac", "audio/ogg": "ogg", "audio/webm": "weba",
    "audio/wav": "wav", "audio/flac": "flac", "application/zip": "zip", "application/pdf": "pdf",
    "application/x-apple-diskimage": "dmg", "application/gzip": "gz", "application/x-7z-compressed": "7z",
    "application/vnd.rar": "rar", "application/x-rar-compressed": "rar",
]

// MARK: - Bytes / crypto

public func hexToData(_ hex: String) -> Data? {
    var s = hex.lowercased()
    if s.hasPrefix("0x") { s.removeFirst(2) }
    if s.count % 2 == 1 { s = "0" + s }
    var data = Data(capacity: s.count / 2)
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
        data.append(b)
        idx = next
    }
    return data
}

/// HLS default IV: the media sequence number as a 128-bit big-endian integer.
public func ivFromSequence(_ seq: Int) -> Data {
    var d = Data(count: 16)
    var v = UInt64(seq)
    for i in stride(from: 15, through: 8, by: -1) {
        d[i] = UInt8(v & 0xFF)
        v >>= 8
    }
    return d
}

/// AES-128-CBC with PKCS#7 padding: the standard HLS segment encryption.
public func aes128CBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
    guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
        throw CastnetError.invalid("Bad AES-128 key or IV length")
    }
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let outCapacity = out.count
    let status = out.withUnsafeMutableBytes { outPtr in
        data.withUnsafeBytes { inPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeAES128, ivPtr.baseAddress,
                            inPtr.baseAddress, data.count, outPtr.baseAddress, outCapacity, &moved)
                }
            }
        }
    }
    if status == kCCDecodeError {
        // Some packagers omit PKCS#7 padding; retry without it.
        var raw = Data(count: data.count)
        var moved2 = 0
        let rawCap = raw.count
        let s2 = raw.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                                keyPtr.baseAddress, kCCKeySizeAES128, ivPtr.baseAddress,
                                inPtr.baseAddress, data.count, outPtr.baseAddress, rawCap, &moved2)
                    }
                }
            }
        }
        guard s2 == kCCSuccess else { throw CastnetError.invalid("AES-128 decrypt failed (\(s2))") }
        raw.count = moved2
        return raw
    }
    guard status == kCCSuccess else { throw CastnetError.invalid("AES-128 decrypt failed (\(status))") }
    out.count = moved
    return out
}

/// Appends `src` to an open file handle in 4 MB chunks.
func appendFile(_ src: URL, to handle: FileHandle) throws {
    let input = try FileHandle(forReadingFrom: src)
    defer { try? input.close() }
    while true {
        let chunk = try input.read(upToCount: 4 << 20) ?? Data()
        if chunk.isEmpty { break }
        try handle.write(contentsOf: chunk)
    }
}

/// Moves a file, falling back to copy+delete across volumes.
public func moveItem(_ src: URL, to dst: URL) throws {
    let fm = FileManager.default
    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try fm.moveItem(at: src, to: dst)
    } catch {
        try fm.copyItem(at: src, to: dst)
        try? fm.removeItem(at: src)
    }
}
