import Foundation
import CoreServices

/// What to do when a queue (or one download) finishes: the "when done" options.
public enum DoneAction: String, Codable, CaseIterable, Identifiable {
    case nothing, quit, sleep, shutDown
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .nothing: return "Do nothing"
        case .quit: return "Quit Castnet"
        case .sleep: return "Put the Mac to sleep"
        case .shutDown: return "Shut down the Mac"
        }
    }
}

/// Start/stop times of one queue (the Scheduler's Schedule tab).
public struct SchedulerSettings: Codable, Equatable {
    public var startEnabled = false
    public var startHour = 2
    public var startMinute = 0
    public var stopEnabled = false
    public var stopHour = 7
    public var stopMinute = 0
    /// Calendar weekdays (1 = Sunday … 7 = Saturday). Empty means every day.
    public var days: [Int] = []
    public var whenDone: DoneAction = .nothing
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SchedulerSettings()
        startEnabled = try c.decodeIfPresent(Bool.self, forKey: .startEnabled) ?? d.startEnabled
        startHour = try c.decodeIfPresent(Int.self, forKey: .startHour) ?? d.startHour
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute) ?? d.startMinute
        stopEnabled = try c.decodeIfPresent(Bool.self, forKey: .stopEnabled) ?? d.stopEnabled
        stopHour = try c.decodeIfPresent(Int.self, forKey: .stopHour) ?? d.stopHour
        stopMinute = try c.decodeIfPresent(Int.self, forKey: .stopMinute) ?? d.stopMinute
        days = try c.decodeIfPresent([Int].self, forKey: .days) ?? d.days
        whenDone = (try? c.decodeIfPresent(DoneAction.self, forKey: .whenDone)) ?? d.whenDone
    }

    public func runsOn(weekday: Int) -> Bool { days.isEmpty || days.contains(weekday) }
}

/// A download queue: the main queue plus any you create.
public struct DownloadQueue: Codable, Equatable, Identifiable {
    public static let mainID = UUID(uuidString: "6A1B0000-0000-4000-8000-000000000001")!
    public static var main: DownloadQueue { DownloadQueue(id: mainID, name: "Main Queue") }

    public var id: UUID
    public var name: String
    public var schedule = SchedulerSettings()
    /// "Download N files at the same time" for this queue.
    public var simultaneous = 3

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    public var isMain: Bool { id == Self.mainID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Queue"
        schedule = try c.decodeIfPresent(SchedulerSettings.self, forKey: .schedule) ?? SchedulerSettings()
        simultaneous = try c.decodeIfPresent(Int.self, forKey: .simultaneous) ?? 3
    }
}

/// What to do when a link that's already in the list is added again (the Duplicate Link dialog).
public enum DuplicateAction: String, Codable, CaseIterable, Identifiable {
    case ask, addNumbered, useExisting
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: return "Ask me"
        case .addNumbered: return "Add it again with a numbered file name"
        case .useExisting: return "Use the existing download (resume it, or show it if finished)"
        }
    }
}

/// "Add Batch Download" and "Add Batch Download from Clipboard".
public enum BatchLinks {
    /// Replaces the `*` in `pattern` with each value from `from` to `to`: numbers (zero-padded
    /// to `width` digits) or single letters. Returns nothing if the range isn't valid.
    public static func expand(_ pattern: String, from: String, to: String, width: Int = 0, limit: Int = 10_000) -> [String] {
        guard pattern.contains("*") else { return [] }
        let a = from.trimmingCharacters(in: .whitespaces), b = to.trimmingCharacters(in: .whitespaces)
        var values: [String] = []
        if let x = Int(a), let y = Int(b), x >= 0, y >= 0 {
            let step = x <= y ? 1 : -1
            for n in stride(from: x, through: y, by: step) {
                let s = String(n)
                values.append(s.count < width ? String(repeating: "0", count: width - s.count) + s : s)
                if values.count >= limit { break }
            }
        } else if a.count == 1, b.count == 1, let x = a.unicodeScalars.first, let y = b.unicodeScalars.first,
                  x.properties.isAlphabetic, y.properties.isAlphabetic,
                  CharacterSet.lowercaseLetters.contains(x) == CharacterSet.lowercaseLetters.contains(y) {
            let step = x.value <= y.value ? 1 : -1
            for v in stride(from: Int(x.value), through: Int(y.value), by: step) {
                if let u = Unicode.Scalar(UInt32(v)) { values.append(String(Character(u))) }
            }
        }
        return values.map { pattern.replacingOccurrences(of: "*", with: $0) }
    }

    /// Every http(s) link in a block of text, in order, without repeats.
    public static func links(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        detector?.enumerateMatches(in: text, options: [], range: range) { m, _, _ in
            guard let u = m?.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return }
            let s = u.absoluteString
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }
}

extension FileCategory {
    /// File types a copied link is caught for (clipboard monitoring).
    public static let monitoredExtensions: Set<String> = {
        var s = Set<String>()
        for c in [FileCategory.video, .music, .compressed, .programs] { s.formUnion(extensions[c] ?? []) }
        s.formUnion(["pdf", "m3u8", "mpd"])
        s.remove("app")   // a bundle, never a single downloadable file
        return s
    }()

    /// True for an http(s) link to a file type Castnet catches when it's copied.
    public static func isDownloadLink(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        return monitoredExtensions.contains(url.pathExtension.lowercased())
    }

    /// The copied text, if it's exactly one link to a file worth catching.
    public static func downloadLink(fromClipboard text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 4096, !s.contains(where: \.isWhitespace), let u = URL(string: s), isDownloadLink(u) else { return nil }
        return u
    }
}

/// Marks a finished download the way browsers do, so Gatekeeper checks downloaded apps and
/// disk images before they first open.
public enum Quarantine {
    public static func mark(_ file: URL, source: String?, page: String?) {
        var props: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Castnet",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let s = source.flatMap(URL.init(string:)) { props[kLSQuarantineDataURLKey as String] = s }
        if let p = page.flatMap(URL.init(string:)) { props[kLSQuarantineOriginURLKey as String] = p }
        var values = URLResourceValues()
        values.quarantineProperties = props
        var u = file
        try? u.setResourceValues(values)
    }
}
