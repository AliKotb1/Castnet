import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CastnetCore

// MARK: - Progress window ("Download status")

struct StatusView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var item: DownloadItem
    @StateObject private var details = Flag()
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabView {
                statusTab.tabItem { Text("Download status") }
                SpeedLimitTab(item: item).tabItem { Text("Speed Limiter") }
                CompletionTab(item: item).tabItem { Text("Options on completion") }
            }
            .frame(height: details.on ? 470 : 300)
            HStack {
                Button(details.on ? "<< Hide details" : "Show details >>") { details.on.toggle() }
                Spacer()
                if item.state.isActive {
                    Button("Pause") { manager.pause(item) }
                } else if item.state != .completed {
                    Button("Resume") { manager.resume(item) }
                }
                if item.state == .completed {
                    Button("Open") { AppActions.openItem(item) }
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { manager.cancel(item); close() }
                }
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("URL", item.request.url, selectable: true)
                row("Status", item.state == .completed ? "Complete" : item.state == .expired ? item.detail : item.detail)
                row("File size", item.total.map(formatBytes) ?? "Unknown")
                row("Downloaded", "\(formatBytes(item.received))\(item.fraction.map { String(format: " (%.2f %%)", $0 * 100) } ?? "")")
                row("Transfer rate", item.state == .running ? "\(formatBytes(Int64(item.speed)))/s" : "–")
                row("Time left", item.eta.map(formatDuration) ?? "–")
                row("Resume capability", item.resumable.map { $0 ? "Yes" : "No" } ?? (item.kind == .file ? "Unknown" : "Yes"))
            }
            ProgressView(value: item.fraction ?? 0).progressViewStyle(.linear)
            SegmentMap(item: item).frame(height: 16)
            if details.on {
                Text("Connections").font(.headline).padding(.top, 4)
                ConnectionsTable(item: item).frame(height: 150)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String, selectable: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            if selectable { Text(v).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            else { Text(v).lineLimit(2).monospacedDigit() }
        }
    }
}

/// Segment bar: each connection's slice of the file, downloaded part filled in.
struct SegmentMap: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        Canvas { ctx, size in
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
            ctx.fill(bg, with: .color(Color.secondary.opacity(0.18)))
            guard let total = item.total, total > 0, !item.segments.isEmpty else {
                let w = size.width * CGFloat(item.fraction ?? 0)
                ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: size.height)), with: .color(.accentColor))
                return
            }
            let scale = size.width / CGFloat(total)
            for s in item.segments {
                let x0 = CGFloat(s.start) * scale
                let x1 = CGFloat(min(s.pos, s.end + 1)) * scale
                if x1 > x0 {
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                             with: .color(s.active ? .blue : Color.accentColor.opacity(0.75)))
                }
                if s.active {
                    ctx.fill(Path(CGRect(x: max(0, x1 - 1.5), y: 0, width: 2, height: size.height)), with: .color(.green))
                }
                ctx.stroke(Path(CGRect(x: x0, y: 0, width: 0.5, height: size.height)), with: .color(Color.black.opacity(0.2)), lineWidth: 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .help("Each block is one connection's part of the file")
    }
}

struct ConnectionsTable: View {
    @ObservedObject var item: DownloadItem

    struct Row: Identifiable {
        let id: Int
        let downloaded: Int64
        let size: Int64
        let info: String
    }

    var body: some View {
        let rows = item.segments.enumerated().map { i, s in
            Row(id: i + 1, downloaded: max(0, min(s.pos, s.end + 1) - s.start), size: s.end - s.start + 1, info: s.status)
        }
        Table(rows) {
            TableColumn("N.") { Text("\($0.id)").monospacedDigit() }.width(30)
            TableColumn("Downloaded") { r in Text("\(formatBytes(r.downloaded)) / \(formatBytes(r.size))").monospacedDigit() }
            TableColumn("Info") { Text($0.info) }
        }
    }
}

final class LimitModel: ObservableObject {
    @Published var on = false
    @Published var kbps = 512
    var loaded = false
}

struct SpeedLimitTab: View {
    @ObservedObject var item: DownloadItem
    @StateObject private var model = LimitModel()

    var body: some View {
        Form {
            Toggle("Use speed limiter for this download", isOn: $model.on)
            Stepper("Maximum download speed: \(model.kbps) KB/s", value: $model.kbps, in: 16...100_000, step: 64)
                .disabled(!model.on)
            Text("There’s also a limit for all downloads together in the status bar and Settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onAppear {
            guard !model.loaded else { return }
            model.loaded = true
            model.on = item.speedLimitKBps != nil
            model.kbps = item.speedLimitKBps ?? 512
        }
        .onChange(of: model.on) { _ in item.speedLimitKBps = model.on ? model.kbps : nil }
        .onChange(of: model.kbps) { _ in if model.on { item.speedLimitKBps = model.kbps } }
    }
}

struct CompletionTab: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var item: DownloadItem
    var body: some View {
        Form {
            Picker("When this download finishes", selection: $item.whenDone) {
                ForEach(DoneAction.allCases) { Text($0.title).tag($0) }
            }
            .disabled(item.state == .completed)
            Toggle("Show the download complete dialog", isOn: $manager.settings.showCompleteDialog)
            Toggle("Show a notification when a download finishes", isOn: $manager.settings.notifyOnComplete)
            Toggle("Show this progress window for new downloads", isOn: $manager.settings.showProgressDialog)
        }
        .padding(16)
    }
}

// MARK: - Download File Info (shown when a download is added)

final class InfoModel: ObservableObject {
    @Published var filename = ""
    @Published var directory = URL(fileURLWithPath: NSHomeDirectory())
    @Published var category = FileCategory.other
    var loaded = false
}

struct DownloadInfoView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var item: DownloadItem
    @StateObject private var model = InfoModel()
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: model.category.symbol).font(.system(size: 30)).foregroundStyle(Color.accentColor).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download File Info").font(.headline)
                    Text(item.descriptionText).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("URL").foregroundStyle(.secondary)
                    Text(item.request.url).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                GridRow {
                    Text("Category").foregroundStyle(.secondary)
                    Picker("", selection: $model.category) {
                        ForEach(FileCategory.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: model.category) { c in
                        if manager.settings.sortIntoCategoryFolders { model.directory = manager.settings.folder(for: c) }
                    }
                }
                GridRow {
                    Text("Save As").foregroundStyle(.secondary)
                    HStack {
                        TextField("File name", text: $model.filename).textFieldStyle(.roundedBorder)
                        Button("…") { choose() }.help("Choose where to save")
                    }
                }
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    Text(model.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                }
                if let size = item.request.size ?? item.total {
                    GridRow { Text("Size").foregroundStyle(.secondary); Text(formatBytes(size)) }
                }
            }
            Toggle("Don’t show this dialog again (start downloads right away)", isOn: Binding(
                get: { !manager.settings.showDownloadInfoDialog },
                set: { manager.settings.showDownloadInfoDialog = !$0 }))
                .font(.caption)
            HStack {
                Button("Cancel") { manager.remove(item); close() }.keyboardShortcut(.cancelAction)
                Spacer()
                if manager.settings.queues.count > 1 {
                    Menu("Download Later") {
                        ForEach(manager.settings.queues) { q in Button("Add to \(q.name)") { finish(start: false, queue: q.id) } }
                    }
                    .fixedSize()
                } else {
                    Button("Download Later") { finish(start: false) }
                }
                Button("Start Download") { finish(start: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            guard !model.loaded else { return }
            model.loaded = true
            model.filename = item.filename
            model.directory = item.directory
            model.category = item.category
        }
    }

    private func choose() {
        let p = NSSavePanel()
        p.nameFieldStringValue = model.filename
        p.directoryURL = model.directory
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url {
            model.filename = u.lastPathComponent
            model.directory = u.deletingLastPathComponent()
        }
    }

    private func finish(start: Bool, queue: UUID? = nil) {
        manager.confirm(item, filename: model.filename, directory: model.directory, startNow: start, queue: queue)
        close()
    }
}

// MARK: - Download complete

struct CompleteView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var item: DownloadItem
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download complete").font(.headline)
                    Text(item.filename).lineLimit(1).truncationMode(.middle)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow { Text("Downloaded").foregroundStyle(.secondary); Text(formatBytes(item.total ?? item.received)) }
                GridRow { Text("Address").foregroundStyle(.secondary); Text(item.request.url).lineLimit(1).truncationMode(.middle) }
                GridRow {
                    Text("Saved to").foregroundStyle(.secondary)
                    Text((item.outputPaths.first ?? item.destination.path).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Toggle("Don’t show this dialog again", isOn: Binding(
                get: { !manager.settings.showCompleteDialog }, set: { manager.settings.showCompleteDialog = !$0 }))
                .font(.caption)
            HStack {
                Spacer()
                Button("Open With…", action: openWith)
                Button("Open Folder") { AppActions.reveal(item); close() }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Open") { AppActions.openItem(item); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    /// "Open With…": pick any app for the downloaded file.
    private func openWith() {
        guard let path = item.outputPaths.first else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an app to open “\(item.filename)”"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        close()
    }
}

// MARK: - Change Address (manual link renewal)

final class AddressModel: ObservableObject {
    @Published var url = ""
    @Published var busy = false
    @Published var message: String?
    @Published var ok = false
}

struct ChangeAddressView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var item: DownloadItem
    @StateObject private var model = AddressModel()
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Address").font(.headline)
            Text("Paste a new link for **\(item.filename)**. Castnet checks it’s the same file (size and the bytes already downloaded) and continues from \(item.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "where it stopped"), so nothing is downloaded again.")
                .foregroundStyle(.secondary)
            TextField("https://…", text: $model.url).textFieldStyle(.roundedBorder).frame(width: 460)
            if let m = model.message { Text(m).font(.caption).foregroundStyle(model.ok ? .green : .red) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Check & Continue") { apply() }.keyboardShortcut(.defaultAction).disabled(model.busy || model.url.isEmpty)
            }
        }
        .padding(18)
        .onAppear {
            if let s = Clipboard.stringIfAllowed(), s.hasPrefix("http") { model.url = s }
        }
    }

    private func apply() {
        model.busy = true
        model.message = "Checking the new link…"
        Task {
            let (ok, err) = await manager.changeAddress(item, to: model.url.trimmingCharacters(in: .whitespacesAndNewlines))
            await MainActor.run {
                model.busy = false
                model.ok = ok
                model.message = ok ? "Same file. Continuing the download." : (err ?? "That link doesn’t work.")
                if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { close() } }
            }
        }
    }
}
