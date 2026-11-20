import SwiftUI
import AppKit
import CastnetCore

struct SettingsView: View {
    @EnvironmentObject var manager: DownloadManager

    var body: some View {
        Form {
            Section("Connection") {
                Stepper("Max. connections per download: \(manager.settings.connections)", value: $manager.settings.connections, in: 1...32)
                Text("Up to 32 parallel connections, each a separate connection to the server. Some servers limit connections; Castnet backs off automatically if they refuse.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Stepper("Downloads at the same time: \(manager.settings.maxConcurrent)", value: $manager.settings.maxConcurrent, in: 1...10)
                Stepper("Parallel segments for streams: \(manager.settings.segmentConcurrency)", value: $manager.settings.segmentConcurrency, in: 1...16)
                Toggle("Limit total download speed", isOn: $manager.settings.speedLimitEnabled)
                Stepper("Speed limit: \(manager.settings.speedLimitKBps) KB/s", value: $manager.settings.speedLimitKBps, in: 32...200_000, step: 128)
                    .disabled(!manager.settings.speedLimitEnabled)
            }
            Section("Save To") {
                HStack {
                    Text("Folder")
                    Spacer()
                    Text(manager.settings.downloadDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
                Toggle("Sort into category folders (Video, Music, Compressed, Documents, Programs)", isOn: $manager.settings.sortIntoCategoryFolders)
            }
            Section("Never lose a download") {
                Toggle("Renew expired links automatically", isOn: $manager.settings.autoRenewLinks)
                Text("When a link stops working halfway, Castnet asks your browser for a fresh one, checks it’s the same file, and continues from where it stopped. Network drops are waited out, never treated as failures.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Links") {
                Picker("When a link is already in the list", selection: $manager.settings.duplicateAction) {
                    ForEach(DuplicateAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Catch download links copied to the clipboard", isOn: $manager.settings.monitorClipboard)
                Text("Copy a link to a video, music, archive, program or PDF file anywhere, and Castnet offers to download it. macOS may ask whether Castnet can read the clipboard; choose Always Allow for Castnet under Privacy & Security in System Settings to stop the question.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Dialogs") {
                Toggle("Show “Download File Info” before starting", isOn: $manager.settings.showDownloadInfoDialog)
                Toggle("Show the progress window for each download", isOn: $manager.settings.showProgressDialog)
                Toggle("Show “Download complete”", isOn: $manager.settings.showCompleteDialog)
                Toggle("Notification when a download finishes", isOn: $manager.settings.notifyOnComplete)
                Toggle("Bring Castnet to the front when a download starts", isOn: $manager.settings.showWindowOnAdd)
            }
            Section("Built-in components") {
                ExtractorRow()
                ComponentRow(name: "Video merging", detail: "ffmpeg \(ComponentRow.ffmpegVersion)", ok: manager.settings.ffmpegURL != nil)
                ComponentRow(name: "JavaScript engine", detail: "QuickJS (for YouTube)", ok: Tools.find("qjs") != nil)
            }
            Section("Browsers") {
                BrowserStatusView()
                Button("Set Up Browser Extension…") { AppActions.showSetup() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 600)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: manager.settings.downloadDirectory)
        if panel.runModal() == .OK, let u = panel.url { manager.settings.downloadDirectory = u.path }
    }
}

struct BrowserStatusView: View {
    @EnvironmentObject var manager: DownloadManager

    var body: some View {
        let rows = BrowserSetup.installed
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty { Text("No supported browser found.").foregroundStyle(.secondary) }
            ForEach(rows) { b in
                HStack {
                    let ok = BrowserSetup.isReady(b)
                    Image(nsImage: BrowserSetup.icon(b)).resizable().frame(width: 18, height: 18)
                    Text(b.name)
                    Spacer()
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
                    Text(ok ? "Connected" : "Needs setup").foregroundStyle(.secondary).font(.caption)
                }
            }
            Text(manager.extensionEverConnected ? "The extension has connected to Castnet." : "Extension not added yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ComponentRow: View {
    let name: String
    let detail: String
    let ok: Bool

    static var ffmpegVersion: String {
        guard let f = Tools.bundledDir?.deletingLastPathComponent().appendingPathComponent("Resources/ffmpeg.version"),
              let v = try? String(contentsOf: f, encoding: .utf8) else { return "" }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(ok ? .green : .red)
            Text(name)
            Spacer()
            Text(ok ? detail : "Missing. Reinstall Castnet").foregroundStyle(.secondary).font(.caption)
        }
    }
}

final class ExtractorModel: ObservableObject {
    @Published var version = ExtractorUpdater.currentVersion ?? "built in"
    @Published var status = ""
    @Published var busy = false
    @Published var auto = ExtractorUpdater.isAutoUpdateOn {
        didSet { ExtractorUpdater.isAutoUpdateOn = auto }
    }

    @MainActor func checkNow() {
        busy = true
        status = "Checking…"
        Task {
            let result = await ExtractorUpdater.updateIfDue(force: true)
            await MainActor.run {
                self.status = result
                self.version = ExtractorUpdater.currentVersion ?? self.version
                self.busy = false
            }
        }
    }
}

/// Site support (yt-dlp inside Castnet) with its self-update controls.
struct ExtractorRow: View {
    @StateObject private var model = ExtractorModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Video sites")
                Spacer()
                Text("version \(model.version)").foregroundStyle(.secondary).font(.caption)
            }
            Toggle("Keep video site support up to date automatically", isOn: $model.auto).font(.caption)
            HStack {
                Button("Check Now") { model.checkNow() }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
