import Foundation
import Darwin

/// Keeps the site extractor (yt-dlp) current without the user doing anything.
///
/// Castnet.app ships a copy in Contents/Helpers. On launch it is copied to
/// ~/Library/Application Support/Castnet/bin, and that copy updates itself from the official
/// yt-dlp releases (`yt-dlp -U`, which verifies the release checksums) at most once a day.
/// The signed app bundle is never modified. If an updated copy ever fails to run, Castnet
/// falls back to the bundled one. A newer Castnet release that bundles a newer yt-dlp
/// replaces an older updated copy.
public enum ExtractorUpdater {
    static let lastCheckKey = "ExtractorLastUpdateCheck"
    public static let autoUpdateKey = "ExtractorAutoUpdate"

    public static var isAutoUpdateOn: Bool {
        get { UserDefaults.standard.object(forKey: autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    static var bundled: URL? { Tools.bundledDir?.appendingPathComponent("yt-dlp") }
    static var bundledVersionFile: URL? { Tools.bundledDir?.deletingLastPathComponent().appendingPathComponent("Resources/yt-dlp.version") }
    static var copy: URL { Tools.updatableDir.appendingPathComponent("yt-dlp") }
    static var copyVersionFile: URL { Tools.updatableDir.appendingPathComponent("yt-dlp.version") }

    /// "2026.10.26" or "2026.10.26.1" → comparable integers.
    static func parts(_ v: String) -> [Int] { v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func read(_ url: URL?) -> String? {
        guard let url, let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Version of the extractor Castnet will actually run.
    public static var currentVersion: String? {
        FileManager.default.isExecutableFile(atPath: copy.path) ? (read(copyVersionFile) ?? read(bundledVersionFile)) : read(bundledVersionFile)
    }

    /// Fast, synchronous: make sure the updatable copy exists and isn't older than the bundled one.
    public static func prepare() {
        guard let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) else { return }
        let fm = FileManager.default
        let bundledVersion = read(bundledVersionFile) ?? "0"
        let copyVersion = read(copyVersionFile)
        let needsCopy = !fm.isExecutableFile(atPath: copy.path) || copyVersion == nil || isNewer(bundledVersion, than: copyVersion!)
        guard needsCopy else { return }
        do {
            try fm.createDirectory(at: Tools.updatableDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: copy)
            try fm.copyItem(at: bundled, to: copy)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            removexattr(copy.path, "com.apple.quarantine", 0) // our own copy, not a download
            try bundledVersion.write(to: copyVersionFile, atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: copy) // Tools.find falls back to the bundled one
        }
    }

    static func runVersion(_ exe: URL) async -> String? {
        guard let (status, out, _) = try? await YTDLPEngine.runCapture(exe, ["--version", "--ignore-config"], timeout: 60),
              status == 0 else { return nil }
        let v = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Updates the extractor if a day has passed since the last check (or `force`).
    /// Returns a short human-readable status.
    @discardableResult
    public static func updateIfDue(force: Bool = false) async -> String {
        guard force || isAutoUpdateOn else { return "Automatic updates are off" }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 24 * 3600 else { return "Up to date" }
        prepare()
        guard FileManager.default.isExecutableFile(atPath: copy.path) else { return "Not available" }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        let before = read(copyVersionFile)
        let backup = Tools.updatableDir.appendingPathComponent("yt-dlp.previous")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: copy, to: backup)
        _ = try? await YTDLPEngine.runCapture(copy, ["-U", "--ignore-config", "--no-colors"], timeout: 300)
        if let v = await runVersion(copy) {
            try? v.write(to: copyVersionFile, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: backup)
            return before.map { isNewer(v, than: $0) ? "Updated to \(v)" : "Up to date (\(v))" } ?? "Version \(v)"
        }
        // The update left a broken file: restore the previous copy.
        try? FileManager.default.removeItem(at: copy)
        if (try? FileManager.default.moveItem(at: backup, to: copy)) == nil { prepare() }
        return "Update failed; kept version \(before ?? "bundled")"
    }
}

/// Optional app updates: set `CastnetUpdateURL` in Info.plist to a JSON file such as
/// {"version": "1.3.0", "url": "https://example.com/Castnet-1.3.0.dmg", "notes": "…"}.
/// When a newer version is published, the window shows an "Update available" banner.
public struct AppUpdate: Codable, Equatable {
    public var version: String
    public var url: String
    public var notes: String?
}

public enum UpdateChecker {
    public static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "CastnetUpdateURL") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? castnetVersion
    }

    public static func check() async -> AppUpdate? {
        guard let feed = feedURL else { return nil }
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("Castnet/\(appVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let u = try? JSONDecoder().decode(AppUpdate.self, from: data),
              ExtractorUpdater.isNewer(u.version, than: appVersion) else { return nil }
        return u
    }
}
