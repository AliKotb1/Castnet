import AppKit
import SwiftUI
import SafariServices
import UniformTypeIdentifiers
import CastnetCore

/// Everything install.sh used to do, done by the app on every launch: find the browsers that are
/// really installed, register the native-messaging bridge with them, and keep the extension
/// files where each browser can load them.
enum BrowserSetup {
    static let hostName = "app.castnet.host"
    static let chromeExtensionID = "jninbfcnkkcefbjldiiiogbajkeohemb"
    /// IDs the Chrome Web Store / Edge Add-ons gave the published extension (set at build time
    /// with CHROME_EXTENSION_IDS), so store installs can talk to the app too.
    static var storeExtensionIDs: [String] {
        ((Bundle.main.object(forInfoDictionaryKey: "CastnetChromeExtensionIDs") as? String) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count == 32 }
    }
    /// True when the bundled Firefox add-on was signed by Mozilla (build with SIGNED_XPI):
    /// every Firefox-family browser then installs it permanently with one click.
    static var firefoxAddonSigned: Bool { Bundle.main.object(forInfoDictionaryKey: "CastnetFirefoxAddonSigned") as? Bool ?? false }
    static let firefoxAddonID = "castnet@castnet.app"
    static let safariExtensionID = "app.castnet.mac.safari"

    enum Family { case chromium, firefox, safari }

    struct Browser: Identifiable, Hashable {
        let name: String
        let bundleIDs: [String]
        let family: Family
        /// Folder under ~/Library/Application Support that holds NativeMessagingHosts.
        let hostDir: String?
        let pageScheme: String
        /// Firefox forks that accept unsigned add-ons once xpinstall.signatures.required = false.
        var allowsUnsigned = false
        var id: String { name }
    }

    static let known: [Browser] = [
        Browser(name: "Safari", bundleIDs: ["com.apple.Safari"], family: .safari, hostDir: nil, pageScheme: ""),
        Browser(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], family: .chromium, hostDir: "Google/Chrome", pageScheme: "chrome"),
        Browser(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], family: .chromium, hostDir: "Microsoft Edge", pageScheme: "edge"),
        Browser(name: "Brave", bundleIDs: ["com.brave.Browser"], family: .chromium, hostDir: "BraveSoftware/Brave-Browser", pageScheme: "brave"),
        Browser(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], family: .chromium, hostDir: "Arc/User Data", pageScheme: "chrome"),
        Browser(name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], family: .chromium, hostDir: "Vivaldi", pageScheme: "vivaldi"),
        Browser(name: "Opera", bundleIDs: ["com.operasoftware.Opera"], family: .chromium, hostDir: "com.operasoftware.Opera", pageScheme: "opera"),
        Browser(name: "Chrome Beta", bundleIDs: ["com.google.Chrome.beta"], family: .chromium, hostDir: "Google/Chrome Beta", pageScheme: "chrome"),
        Browser(name: "Chrome Canary", bundleIDs: ["com.google.Chrome.canary"], family: .chromium, hostDir: "Google/Chrome Canary", pageScheme: "chrome"),
        Browser(name: "Chromium", bundleIDs: ["org.chromium.Chromium"], family: .chromium, hostDir: "Chromium", pageScheme: "chrome"),
        Browser(name: "Firefox", bundleIDs: ["org.mozilla.firefox"], family: .firefox, hostDir: "Mozilla", pageScheme: "about"),
        Browser(name: "Firefox Developer Edition", bundleIDs: ["org.mozilla.firefoxdeveloperedition"], family: .firefox, hostDir: "Mozilla", pageScheme: "about", allowsUnsigned: true),
        Browser(name: "Firefox Nightly", bundleIDs: ["org.mozilla.nightly"], family: .firefox, hostDir: "Mozilla", pageScheme: "about", allowsUnsigned: true),
        Browser(name: "Zen", bundleIDs: ["app.zen-browser.zen"], family: .firefox, hostDir: "zen", pageScheme: "about", allowsUnsigned: true),
        Browser(name: "LibreWolf", bundleIDs: ["io.gitlab.librewolf-community.librewolf", "org.librewolf"], family: .firefox, hostDir: "LibreWolf", pageScheme: "about", allowsUnsigned: true),
        Browser(name: "Floorp", bundleIDs: ["one.ablaze.floorp"], family: .firefox, hostDir: "Floorp", pageScheme: "about", allowsUnsigned: true),
        Browser(name: "Waterfox", bundleIDs: ["net.waterfox.waterfox"], family: .firefox, hostDir: "Waterfox", pageScheme: "about", allowsUnsigned: true),
    ]

    static var supportBase: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    /// The browser's .app, only if it really exists on disk (leftover settings folders don't count).
    static func appURL(_ b: Browser) -> URL? {
        for id in b.bundleIDs {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), FileManager.default.fileExists(atPath: u.path) {
                return u
            }
        }
        return nil
    }

    static var installed: [Browser] { known.filter { appURL($0) != nil } }

    static func icon(_ b: Browser) -> NSImage {
        appURL(b).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
    }

    static var hostExecutable: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("castnet-host")
    }

    /// Native-messaging manifest locations for a browser (Firefox forks also read Mozilla's folder).
    static func manifestURLs(_ b: Browser) -> [URL] {
        guard let dir = b.hostDir else { return [] }
        var dirs = [dir]
        if b.family == .firefox && dir != "Mozilla" { dirs.append("Mozilla") }
        return dirs.map { supportBase.appendingPathComponent($0).appendingPathComponent("NativeMessagingHosts/\(hostName).json") }
    }

    static func manifestData(for family: Family) -> Data? {
        guard let host = hostExecutable, FileManager.default.isExecutableFile(atPath: host.path) else { return nil }
        var m: [String: Any] = ["name": hostName, "description": "Castnet download manager", "path": host.path, "type": "stdio"]
        if family == .firefox { m["allowed_extensions"] = [firefoxAddonID] }
        else { m["allowed_origins"] = ([chromeExtensionID] + storeExtensionIDs).map { "chrome-extension://\($0)/" } }
        return try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys])
    }

    /// Registers the bridge with every installed browser (refreshes it if Castnet moved).
    @discardableResult
    static func registerNativeHost() -> [String] {
        // Remove Castnet's own registration from browsers that aren't installed (anymore).
        let installedDirs = Set(installed.flatMap(manifestURLs))
        for b in known where b.family != .safari && appURL(b) == nil {
            for url in manifestURLs(b) where !installedDirs.contains(url) { try? FileManager.default.removeItem(at: url) }
        }
        // The old name's registration (Grabber, up to 1.4.0) points at an app that no longer exists.
        for b in known where b.family != .safari {
            for url in manifestURLs(b) {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(LegacyMigration.oldHostManifest))
            }
        }
        var done: [String] = []
        for b in installed where b.family != .safari {
            guard let data = manifestData(for: b.family) else { continue }
            for url in manifestURLs(b) {
                if (try? Data(contentsOf: url)) == data { continue }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch { continue }
            }
            done.append(b.name)
        }
        return done
    }

    static func isRegistered(_ b: Browser) -> Bool {
        guard let url = manifestURLs(b).first, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: Safari

    static var safariEnabled: Bool?

    static func refreshSafariState(_ done: (() -> Void)? = nil) {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: safariExtensionID) { state, _ in
            DispatchQueue.main.async {
                safariEnabled = state?.isEnabled
                done?()
            }
        }
    }

    static func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: safariExtensionID) { _ in }
    }

    static var hasSafariExtension: Bool {
        Bundle.main.builtInPlugInsURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("CastnetSafari.appex").path) } ?? false
    }

    static func isReady(_ b: Browser) -> Bool {
        switch b.family {
        case .safari: return safariEnabled == true
        default: return isRegistered(b)
        }
    }

    // MARK: Extension files

    /// Stable folder the user loads into Chromium browsers (survives app updates and moves).
    static var extensionFolder: URL { Paths.support.appendingPathComponent("Browser Extension", isDirectory: true) }
    static var firefoxAddon: URL { Paths.support.appendingPathComponent("Firefox Add-on/Castnet.xpi") }
    static var bundledExtension: URL? { Bundle.main.resourceURL?.appendingPathComponent("Extension", isDirectory: true) }
    static var bundledFirefoxAddon: URL? { Bundle.main.resourceURL?.appendingPathComponent("Firefox/Castnet.xpi") }

    static func manifestVersion(_ dir: URL) -> String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["version"] as? String
    }

    /// Copies the extensions shipped inside Castnet.app to stable folders when they changed.
    static func installExtensionFiles() {
        let fm = FileManager.default
        if let src = bundledExtension, fm.fileExists(atPath: src.path), manifestVersion(src) != manifestVersion(extensionFolder) {
            let tmp = extensionFolder.deletingLastPathComponent().appendingPathComponent(".extension-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: src, to: tmp)
                if fm.fileExists(atPath: extensionFolder.path) { _ = try fm.replaceItemAt(extensionFolder, withItemAt: tmp) }
                else { try fm.moveItem(at: tmp, to: extensionFolder) }
            } catch { try? fm.removeItem(at: tmp) }
        }
        if let xpi = bundledFirefoxAddon, fm.fileExists(atPath: xpi.path),
           (try? Data(contentsOf: xpi)) != (try? Data(contentsOf: firefoxAddon)) {
            try? fm.createDirectory(at: firefoxAddon.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: firefoxAddon)
            try? fm.copyItem(at: xpi, to: firefoxAddon)
        }
    }

    /// Opens an address (extensions page, about:config…) in a specific browser and puts it on
    /// the clipboard too, in case the browser won't open internal pages from outside.
    static func open(_ address: String, in b: Browser) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        guard let app = appURL(b), let url = URL(string: address) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, _ in }
    }

    static func openFile(_ file: URL, in b: Browser) {
        guard let app = appURL(b) else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

// MARK: - Setup window

final class SetupModel: ObservableObject {
    @Published var browser: BrowserSetup.Browser?
    @Published var opened = false
    @Published var tick = 0

    init() {
        let list = BrowserSetup.installed
        let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        browser = list.first { BrowserSetup.appURL($0) == defaultBrowser } ?? list.first { $0.family == .chromium } ?? list.first
    }
}

struct SetupView: View {
    @EnvironmentObject var manager: DownloadManager
    @StateObject private var model = SetupModel()
    let onDone: () -> Void

    private var connected: Bool { manager.lastExtensionContact != nil || manager.extensionEverConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Castnet to your browser").font(.title2.weight(.semibold))
                    Text("One-time setup. It adds a “Download this video” button to videos on every site.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            let list = BrowserSetup.installed
            if list.count > 1 {
                HStack(spacing: 8) {
                    ForEach(list) { b in
                        Button { model.browser = b; model.opened = false } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: BrowserSetup.icon(b)).resizable().frame(width: 34, height: 34)
                                Text(b.name).font(.caption).lineLimit(1)
                            }
                            .frame(width: 92, height: 66)
                            .background(RoundedRectangle(cornerRadius: 9).fill(model.browser == b ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(model.browser == b ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let b = model.browser {
                switch b.family {
                case .chromium: chromiumSteps(b)
                case .firefox: firefoxSteps(b)
                case .safari: safariSteps(b)
                }
            } else {
                Text("No supported browser found. Install Safari, Chrome, Firefox, Edge, Brave, Arc, Zen, Vivaldi or Opera, then open this window again from the Castnet menu.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if connected {
                    Label("Castnet is connected to your browser. You’re all set!", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser extension…").foregroundStyle(.secondary)
                }
                Spacer()
                Button(connected ? "Done" : "Later", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear { BrowserSetup.refreshSafariState { model.tick += 1 } }
    }

    @ViewBuilder private func chromiumSteps(_ b: BrowserSetup.Browser) -> some View {
        step(1, "Open the Extensions page") {
            HStack {
                Button("Open \(b.name) Extensions") { BrowserSetup.open("\(b.pageScheme)://extensions", in: b); model.opened = true }
                    .controlSize(.large)
                if model.opened {
                    Text("Didn’t open? Paste \(b.pageScheme)://extensions in the address bar (it’s on your clipboard).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        step(2, "Turn on “Developer mode”") {
            Text("It’s the switch in the top-right corner of the Extensions page.").foregroundStyle(.secondary)
        }
        step(3, "Drag this folder onto the Extensions page") {
            HStack(spacing: 14) {
                FolderTile(url: BrowserSetup.extensionFolder, title: "Castnet Extension")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or click **Load unpacked** on that page and choose this folder.").foregroundStyle(.secondary)
                    Button("Show Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BrowserSetup.extensionFolder]) }
                }
            }
        }
    }

    @ViewBuilder private func firefoxSteps(_ b: BrowserSetup.Browser) -> some View {
        if BrowserSetup.firefoxAddonSigned {
            step(1, "Install the Castnet add-on") {
                HStack(spacing: 14) {
                    Button("Add Castnet to \(b.name)") { BrowserSetup.openFile(BrowserSetup.firefoxAddon, in: b) }.controlSize(.large)
                    Text("\(b.name) asks once whether to add it. Or drag Castnet.xpi into a \(b.name) window.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FolderTile(url: BrowserSetup.firefoxAddon, title: "Castnet.xpi", symbol: true)
                }
            }
            step(2, "Let Castnet see videos on every site") {
                Text("Click the Castnet button in the toolbar and choose **Allow on all websites** (the browser asks this for every new add-on).")
                    .foregroundStyle(.secondary)
            }
        } else if b.allowsUnsigned {
            step(1, "Allow add-ons from outside Mozilla’s store") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Open \(b.name) Advanced Settings") { BrowserSetup.open("about:config", in: b); model.opened = true }
                    Text("In **about:config**, search for **xpinstall.signatures.required** and set it to **false**. (It’s on your clipboard if the page didn’t open.)")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            step(2, "Install the Castnet add-on") {
                HStack(spacing: 14) {
                    Button("Add Castnet to \(b.name)") { BrowserSetup.openFile(BrowserSetup.firefoxAddon, in: b) }.controlSize(.large)
                    Text("Or drag Castnet.xpi into a \(b.name) window.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FolderTile(url: BrowserSetup.firefoxAddon, title: "Castnet.xpi", symbol: true)
                }
            }
            step(3, "Let Castnet see videos on every site") {
                Text("Click the Castnet button in the toolbar and choose **Allow on all websites** (the browser asks this for every new add-on).")
                    .foregroundStyle(.secondary)
            }
        } else {
            step(1, "Load Castnet in Firefox") {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Open Firefox Debugging Page") { BrowserSetup.open("about:debugging#/runtime/this-firefox", in: b) }.controlSize(.large)
                    Text("Click **Load Temporary Add-on…** and choose **Castnet.xpi** below. Regular Firefox only keeps unsigned add-ons until it restarts; a Mozilla-signed version installs permanently with one click.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Show Castnet.xpi in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BrowserSetup.firefoxAddon]) }
                }
            }
        }
    }

    @ViewBuilder private func safariSteps(_ b: BrowserSetup.Browser) -> some View {
        if !BrowserSetup.hasSafariExtension {
            Text("This copy of Castnet was built without its Safari extension.").foregroundStyle(.secondary)
        } else {
            step(1, "Allow Castnet’s extension") {
                Text("Safari only runs extensions from identified developers. Until Castnet is signed by Apple: in Safari, open **Settings → Advanced**, turn on **Show features for web developers**, then in the **Developer** tab turn on **Allow unsigned extensions**. Safari turns this off again when it quits.")
                    .foregroundStyle(.secondary)
            }
            step(2, "Turn on Castnet in Safari") {
                HStack {
                    Button("Open Safari Extensions Settings") { BrowserSetup.openSafariExtensionSettings() }.controlSize(.large)
                    let on = BrowserSetup.safariEnabled == true
                    Label(on ? "Enabled" : "Not enabled yet", systemImage: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? .green : .secondary).font(.caption)
                }
            }
            step(3, "Allow it on every website") {
                Text("In the same settings pane, select Castnet, click **Edit Websites…** and set **Other Websites** to **Allow**.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            .fixedSize(horizontal: false, vertical: true)   // wrap long instructions instead of cutting them off
        }
    }
}

/// A folder/file tile that can be dragged straight into the browser.
struct FolderTile: View {
    let url: URL
    var title = "Castnet Extension"
    var symbol = false
    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: symbol ? NSWorkspace.shared.icon(for: UTType(filenameExtension: "xpi") ?? .zip) : NSWorkspace.shared.icon(for: .folder))
                .resizable().frame(width: 48, height: 48)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("Drag me into the browser")
    }
}
