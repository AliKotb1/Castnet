import Foundation

/// Castnet was called "Grabber" up to version 1.4.0. On first launch this moves that version's
/// download list, settings, site-support updates and unfinished downloads over, so nothing is lost.
public enum LegacyMigration {
    static let oldName = "Grabber"
    static let oldDefaultsDomain = "local.grabber.Grabber"
    static let oldSettingsKey = "GrabberSettings"
    static let oldPartSuffix = ".grabber-part"
    /// Native-messaging registration file the old version wrote into each browser.
    public static let oldHostManifest = "local.grabber.host.json"

    /// Call before anything reads Paths.support or the settings.
    public static func run() {
        guard Paths.testHome == nil else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        merge(support.appendingPathComponent(oldName, isDirectory: true), into: support.appendingPathComponent("Castnet", isDirectory: true),
              regenerated: ["Browser Extension", "Firefox Add-on", "bin", "ipc.sock", "bridge.json"])
        merge(caches.appendingPathComponent(oldName, isDirectory: true), into: caches.appendingPathComponent("Castnet", isDirectory: true),
              regenerated: nil)
        let defaults = UserDefaults.standard
        if defaults.data(forKey: AppSettings.key) == nil,
           let old = UserDefaults(suiteName: oldDefaultsDomain)?.data(forKey: oldSettingsKey) {
            defaults.set(old, forKey: AppSettings.key)
        }
    }

    /// Moves the old folder's contents into the new one. Real data wins over an empty download
    /// list (something may have created the new folder first); things the app recreates by itself
    /// are dropped when the new folder already has them. `regenerated == nil`: everything left over
    /// is disposable (caches). The old folder is removed once it's empty.
    public static func merge(_ old: URL, into new: URL, regenerated: Set<String>?) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: old.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in names {
            let src = old.appendingPathComponent(name), dst = new.appendingPathComponent(name)
            if name == "ipc.sock" || name == "bridge.json" { try? fm.removeItem(at: src); continue }
            if name == "downloads.json", let d = try? Data(contentsOf: dst),
               let list = try? JSONSerialization.jsonObject(with: d) as? [Any], list.isEmpty {
                try? fm.removeItem(at: dst)
            }
            if !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            } else if regenerated == nil || regenerated!.contains(name) {
                try? fm.removeItem(at: src)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
            try? fm.removeItem(at: old)
        }
    }

    /// Unfinished downloads keep their data in "<name>.grabber-part"; rename it to the new suffix.
    @MainActor static func movePartFile(of item: DownloadItem) {
        let fm = FileManager.default
        let old = item.directory.appendingPathComponent(item.filename + oldPartSuffix)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: item.partURL.path) else { return }
        try? fm.moveItem(at: old, to: item.partURL)
    }
}
