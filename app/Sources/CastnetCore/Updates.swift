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

/// App updates: `CastnetUpdateURL` in Info.plist points at a JSON file published with every release,
/// {"version": "1.5.6", "url": "https://…/Castnet-1.5.6.dmg", "sha256": "…", "notes": "…"}.
/// When a newer version is published, Castnet offers it in a window, downloads it itself, checks it,
/// and replaces the app. Downloads, settings and files live outside the app and stay as they are.
public struct AppUpdate: Codable, Equatable {
    public var version: String
    public var url: String
    public var notes: String?
    public var sha256: String?

    public init(version: String, url: String, notes: String? = nil, sha256: String? = nil) {
        self.version = version; self.url = url; self.notes = notes; self.sha256 = sha256
    }
}

public enum UpdateChecker {
    public static var feedURL: URL? {
        // Tests point a test copy of the app at a local feed.
        if Paths.testHome != nil, let t = ProcessInfo.processInfo.environment["CASTNET_UPDATE_FEED"], let u = URL(string: t) { return u }
        return (Bundle.main.object(forInfoDictionaryKey: "CastnetUpdateURL") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
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

/// Downloads and installs an app update in place.
public final class AppInstaller: NSObject, URLSessionDownloadDelegate {
    public enum Failure: LocalizedError {
        case message(String)
        public var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
    }

    private var progress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    public override init() {}

    /// Downloads the update's disk image and checks its SHA-256 against the published one.
    public func download(_ u: AppUpdate, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = URL(string: u.url), url.scheme == "https" || Paths.testHome != nil else { throw Failure.message("The update’s address isn’t secure") }
        let dir = Paths.caches.appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        destination = dir.appendingPathComponent("Castnet-\(u.version).dmg")
        self.progress = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let file: URL = try await withCheckedThrowingContinuation { c in
            continuation = c
            session.downloadTask(with: url).resume()
        }
        if let want = u.sha256?.lowercased(), !want.isEmpty {
            let got = try Self.sha256(of: file)
            guard got == want else {
                try? FileManager.default.removeItem(at: file)
                throw Failure.message("The downloaded update doesn’t match the published checksum")
            }
        }
        return file
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
            continuation?.resume(throwing: Failure.message("The update server answered \(code)")); continuation = nil; return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }

    static func sha256(of file: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", file.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(text.split(separator: " ").first ?? "").lowercased()
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Replaces `app` (the running Castnet) with the one in the disk image, after checking it's
    /// Castnet, the expected version, and correctly signed. Nothing outside the app is touched.
    public static func install(dmg: URL, expectedVersion: String, replacing app: URL) throws {
        let fm = FileManager.default
        let mount = Paths.caches.appendingPathComponent("Updates/mount-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) == 0 else {
            throw Failure.message("The update’s disk image couldn’t be opened")
        }
        defer {
            run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }
        guard let newApp = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure.message("The update doesn’t contain Castnet")
        }
        let myID = Bundle.main.bundleIdentifier ?? "app.castnet.mac"
        guard info["CFBundleIdentifier"] as? String == myID else { throw Failure.message("The update is a different app") }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else { throw Failure.message("The update has an unexpected version") }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
            throw Failure.message("The update’s signature isn’t valid")
        }
        // Copy next to the current app (same disk), then swap the two in one step.
        let staged = app.deletingLastPathComponent().appendingPathComponent(".Castnet-update-\(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) == 0 else {
            try? fm.removeItem(at: staged)
            throw Failure.message("Castnet can’t write to \(app.deletingLastPathComponent().path)")
        }
        do {
            _ = try fm.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw Failure.message("Castnet couldn’t replace itself: \(error.localizedDescription)")
        }
    }

    /// Starts the (new) app once this process has quit.
    public static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = Paths.testHome != nil
            ? "\"\(app.path)/Contents/MacOS/Castnet\" >/dev/null 2>&1 &"     // test copy: keep its test settings
            : "/usr/bin/open \"\(app.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; \(start)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
