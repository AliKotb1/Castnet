import SwiftUI
import AppKit
import CastnetCore

// MARK: - Models (stand-ins for @State, which needs Xcode's SwiftUI macro plugin)

final class Flag: ObservableObject { @Published var on = false }

enum SidebarFilter: Hashable {
    case all, category(FileCategory), unfinished, finished, queue(UUID), expired

    var title: String {
        switch self {
        case .all: return "All Downloads"
        case let .category(c): return c.rawValue
        case .unfinished: return "Unfinished"
        case .finished: return "Finished"
        case .queue: return "Queue"   // the sidebar shows the queue's own name
        case .expired: return "Expired Links"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case let .category(c): return c.symbol
        case .unfinished: return "arrow.down.circle"
        case .finished: return "checkmark.circle"
        case let .queue(id): return id == DownloadQueue.mainID ? "list.number" : "list.bullet"
        case .expired: return "link.badge.plus"
        }
    }

    @MainActor func matches(_ i: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case let .category(c): return i.category == c
        case .unfinished: return i.state != .completed
        case .finished: return i.state == .completed
        case let .queue(id): return i.queueId == id && i.state != .completed
        case .expired: return i.state == .expired
        }
    }
}

@MainActor
final class ListModel: ObservableObject {
    @Published var filter: SidebarFilter? = .all
    @Published var selection = Set<UUID>()
    @Published var sortOrder = [KeyPathComparator(\DownloadItem.sortLastTry, order: .reverse)]
    @Published var search = ""

    /// The queue the toolbar's Start/Stop Queue act on: the selected one, else the main queue.
    var currentQueue: UUID {
        if case let .queue(id)? = filter { return id }
        return DownloadQueue.mainID
    }
}

final class AddURLModel: ObservableObject {
    @Published var isPresented = false
}

final class AddURLForm: ObservableObject {
    @Published var urlText = ""
    @Published var kind = "auto"
    @Published var error: String?
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var addURL: AddURLModel
    @StateObject private var list = ListModel()

    private var rows: [DownloadItem] {
        let f = list.filter ?? .all
        let q = list.search.trimmingCharacters(in: .whitespaces).lowercased()
        return manager.items
            .filter { f.matches($0) && (q.isEmpty || $0.filename.lowercased().contains(q) || $0.descriptionText.lowercased().contains(q)) }
            .sorted(using: list.sortOrder)
    }

    private var selected: [DownloadItem] { manager.items.filter { list.selection.contains($0.id) } }

    /// Browsers running an older Castnet extension: Firefox-family browsers don't update an add-on
    /// installed from a file, and Chrome-family ones load the updated folder only when they restart.
    private var outdatedAddons: [BrowserSetup.Browser] {
        BrowserSetup.installed.filter { b in
            b.family != .safari && b.bundleIDs.contains { id in
                manager.extensionVersions[id].map { ExtractorUpdater.isNewer(castnetVersion, than: $0) } ?? false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MainToolbar(selected: selected, addURL: addURL, list: list)
            Divider()
            if let u = manager.availableUpdate {
                Banner(icon: "arrow.down.app", text: "Castnet \(u.version) is available.", button: "Download") {
                    if let url = URL(string: u.url) { NSWorkspace.shared.open(url) }
                }
            }
            ForEach(outdatedAddons, id: \.name) { b in
                if b.family == .firefox {
                    Banner(icon: "arrow.triangle.2.circlepath", text: "Castnet in \(b.name) is an older version. Update it to get the latest fixes.",
                           button: "Update in \(b.name)") {
                        BrowserSetup.openFile(BrowserSetup.firefoxAddon, in: b)
                    }
                } else {
                    Banner(icon: "arrow.triangle.2.circlepath",
                           text: "Castnet in \(b.name) is an older version. Restart \(b.name), or click ↻ on Castnet on its Extensions page.",
                           button: "Open Extensions") {
                        BrowserSetup.open("\(b.pageScheme)://extensions", in: b)
                    }
                }
            }
            if !manager.extensionEverConnected {
                Banner(icon: "puzzlepiece.extension", text: "Finish setup: add Castnet to your browser.", button: "Set Up…") {
                    AppActions.showSetup()
                }
            }
            HStack(spacing: 0) {
                Sidebar(list: list)
                    .frame(width: 190)
                Divider()
                DownloadTable(rows: rows, list: list)
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 860, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $addURL.isPresented) {
            AddURLSheet(isPresented: $addURL.isPresented).environmentObject(manager)
        }
    }
}

// MARK: - Toolbar (big-icon row)

struct MainToolbar: View {
    @EnvironmentObject var manager: DownloadManager
    let selected: [DownloadItem]
    @ObservedObject var addURL: AddURLModel
    @ObservedObject var list: ListModel

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Color.clear.frame(width: 70, height: 1) // traffic lights
            ToolButton(title: "Add URL", symbol: "plus.circle.fill", tint: .blue) { addURL.isPresented = true }
            ToolButton(title: "Resume", symbol: "play.circle.fill", tint: .green,
                       enabled: selected.contains { [.paused, .failed, .expired, .scheduled, .canceled].contains($0.state) }) {
                selected.forEach(manager.resume)
            }
            ToolButton(title: "Stop", symbol: "pause.circle.fill", tint: .orange, enabled: selected.contains { $0.state.isActive }) {
                selected.forEach(manager.pause)
            }
            ToolButton(title: "Stop All", symbol: "stop.circle.fill", tint: .red, enabled: manager.items.contains { $0.state.isActive }) {
                manager.pauseAll()
            }
            ToolDivider()
            ToolButton(title: "Delete", symbol: "trash.circle.fill", tint: .gray, enabled: !selected.isEmpty) {
                AppActions.confirmDelete(selected)
            }
            ToolButton(title: "Delete Completed", symbol: "checkmark.circle.fill", tint: .teal,
                       enabled: manager.items.contains { $0.state == .completed }) { manager.clearFinished() }
            ToolDivider()
            ToolButton(title: "Options", symbol: "gearshape.fill", tint: .gray) { AppActions.showSettings() }
            ToolButton(title: "Scheduler", symbol: "clock.fill", tint: .purple) { AppActions.showScheduler() }
            ToolButton(title: "Start Queue", symbol: "list.bullet.circle.fill", tint: .green,
                       enabled: manager.startableCount(list.currentQueue) > 0 && !manager.runningQueues.contains(list.currentQueue)) {
                manager.startQueue(list.currentQueue)
            }
            ToolButton(title: "Stop Queue", symbol: "stop.circle", tint: .red, enabled: manager.runningQueues.contains(list.currentQueue)) {
                manager.stopQueue(list.currentQueue)
            }
            Spacer(minLength: 10)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $list.search).textFieldStyle(.plain).frame(width: 130)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .padding(.trailing, 12)
        }
        .frame(height: 66)
    }
}

struct ToolDivider: View {
    var body: some View { Divider().frame(height: 40).padding(.horizontal, 4) }
}

struct ToolButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var enabled = true
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.4))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30, height: 28)
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(minWidth: 62)
            .padding(.vertical, 5)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover.on && enabled ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover.on = $0 }
    }
}

// MARK: - Sidebar (categories and queues)

struct Sidebar: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var list: ListModel

    var body: some View {
        List(selection: $list.filter) {
            Section("Categories") {
                row(.all)
                ForEach(FileCategory.allCases) { c in row(.category(c)).padding(.leading, 12) }
                row(.unfinished)
                row(.finished)
                if manager.items.contains(where: { $0.state == .expired }) { row(.expired) }
            }
            Section("Queues") {
                ForEach(manager.settings.queues) { q in
                    row(.queue(q.id), title: q.name, running: manager.runningQueues.contains(q.id))
                        .contextMenu { queueMenu(q) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ f: SidebarFilter, title: String? = nil, running: Bool = false) -> some View {
        let n = manager.items.filter { f.matches($0) }.count
        return HStack {
            Label(title ?? f.title, systemImage: f.symbol)
            Spacer()
            if running { Circle().fill(Color.green).frame(width: 6, height: 6).help("Running") }
            if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary) }
        }
        .tag(Optional(f))
    }

    @ViewBuilder
    private func queueMenu(_ q: DownloadQueue) -> some View {
        if manager.runningQueues.contains(q.id) {
            Button("Stop Queue") { manager.stopQueue(q.id) }
        } else {
            Button("Start Queue") { manager.startQueue(q.id) }.disabled(manager.startableCount(q.id) == 0)
        }
        Button("Scheduler…") { AppActions.showScheduler() }
        Divider()
        Button("New Queue") { list.filter = .queue(manager.addQueue(named: "").id) }
        if !q.isMain {
            Button("Delete Queue") {
                if list.filter == .queue(q.id) { list.filter = .queue(DownloadQueue.mainID) }
                manager.deleteQueue(q.id)
            }
        }
    }
}

// MARK: - Download list

struct DownloadTable: View {
    @EnvironmentObject var manager: DownloadManager
    let rows: [DownloadItem]
    @ObservedObject var list: ListModel

    var body: some View {
        Table(rows, selection: $list.selection, sortOrder: $list.sortOrder) {
            TableColumn("File Name", value: \.filename) { NameCell(item: $0) }.width(min: 200, ideal: 300)
            TableColumn("Size", value: \.sortSize) { SizeCell(item: $0) }.width(min: 60, ideal: 80)
            TableColumn("Status", value: \.sortStatus) { StatusCell(item: $0) }.width(min: 110, ideal: 150)
            TableColumn("Time left") { EtaCell(item: $0) }.width(min: 55, ideal: 70)
            TableColumn("Transfer rate") { RateCell(item: $0) }.width(min: 70, ideal: 90)
            TableColumn("Last Try Date", value: \.sortLastTry) { DateCell(item: $0) }.width(min: 100, ideal: 130)
            TableColumn("Description") { DescCell(item: $0) }.width(min: 100, ideal: 200)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemMenu(items: manager.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            for item in manager.items where ids.contains(item.id) { AppActions.openItem(item) }
        }
        .overlay {
            if rows.isEmpty { EmptyStateView() }
        }
    }
}

struct ItemMenu: View {
    @EnvironmentObject var manager: DownloadManager
    let items: [DownloadItem]

    var body: some View {
        let one = items.count == 1 ? items.first : nil
        if let i = one, i.state == .completed {
            Button("Open") { AppActions.openItem(i) }
            Button("Open Folder") { AppActions.reveal(i) }
            Divider()
        }
        if items.contains(where: { [.paused, .failed, .expired, .scheduled, .canceled].contains($0.state) }) {
            Button("Resume") { items.forEach(manager.resume) }
        }
        if items.contains(where: { $0.state.isActive }) { Button("Stop") { items.forEach(manager.pause) } }
        if let i = one, i.state != .completed {
            Button("Progress Window…") { AppActions.showStatus(i) }
        }
        if let i = one, i.kind != .ytdlp, i.state != .completed {
            Divider()
            Button("Refresh Link…") { AppActions.refreshLink(i) }
            Button("Change Address…") { AppActions.changeAddress(i) }
        }
        let queues = manager.settings.queues
        if items.contains(where: { !$0.state.isFinished }) {
            if queues.count > 1 {
                Menu("Add to Queue") {
                    ForEach(queues) { q in Button(q.name) { items.forEach { manager.addToQueue($0, queue: q.id) } } }
                }
            } else if items.contains(where: { $0.queueId == nil }) {
                Button("Add to Queue") { items.forEach { manager.addToQueue($0) } }
            }
        }
        if let i = one, i.queueId != nil, i.state != .completed {
            Button("Move Up in Queue") { manager.move(i, earlier: true) }
            Button("Move Down in Queue") { manager.move(i, earlier: false) }
            Button("Remove from Queue") { manager.removeFromQueue(i) }
        }
        Button("Redownload") { items.forEach(manager.redownload) }
        Divider()
        if let i = one {
            Button("Copy Address") { copy(i.request.url) }
            if let p = i.request.pageUrl, !p.isEmpty {
                Button("Open Page in Browser") { if let u = URL(string: p) { NSWorkspace.shared.open(u) } }
            }
            Divider()
        }
        Button("Remove from List") { items.forEach { manager.remove($0) } }
        if items.contains(where: { $0.state == .completed }) {
            Button("Move Files to Trash") { items.forEach { manager.remove($0, deleteFiles: true) } }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        AppActions.ownClipboardChange = NSPasteboard.general.changeCount   // not a link for the clipboard monitor
    }
}

// Cells observe their item so the table updates live.

struct NameCell: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.category.symbol)
                .foregroundStyle(item.state == .completed ? Color.green : item.state == .expired ? .orange : item.state == .failed ? .red : .accentColor)
                .frame(width: 16)
            Text(item.filename).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct SizeCell: View {
    @ObservedObject var item: DownloadItem
    var body: some View { Text(item.total.map(formatBytes) ?? (item.received > 0 ? formatBytes(item.received) : "")).monospacedDigit() }
}

struct StatusCell: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        switch item.state {
        case .running:
            HStack(spacing: 6) {
                ProgressView(value: item.fraction ?? 0).progressViewStyle(.linear).frame(width: 60)
                Text(item.fraction.map { String(format: "%.1f%%", $0 * 100) } ?? "…").monospacedDigit().font(.callout)
            }
        case .completed: Text("Complete").foregroundStyle(.green)
        case .paused: Text(item.fraction.map { String(format: "%.1f%% · Paused", $0 * 100) } ?? "Paused").foregroundStyle(.secondary)
        case .queued: Text("Queued").foregroundStyle(.secondary)
        case .scheduled: Text(item.awaitingConfirmation ? "Waiting…" : "In queue").foregroundStyle(.secondary)
        case .expired: Text("Link expired").foregroundStyle(.orange)
        case .failed: Text("Error").foregroundStyle(.red).help(item.error ?? "")
        case .canceled: Text("Canceled").foregroundStyle(.secondary)
        }
    }
}

struct EtaCell: View {
    @ObservedObject var item: DownloadItem
    var body: some View { Text(item.eta.map(formatDuration) ?? "").monospacedDigit() }
}

struct RateCell: View {
    @ObservedObject var item: DownloadItem
    var body: some View { Text(item.state == .running && item.speed > 0 ? "\(formatBytes(Int64(item.speed)))/s" : "").monospacedDigit() }
}

struct DateCell: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        Text((item.lastTry ?? item.createdAt).formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
    }
}

struct DescCell: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        Text(item.state == .expired || item.state == .failed ? item.detail : item.descriptionText)
            .foregroundStyle(item.state == .expired ? Color.orange : .secondary)
            .lineLimit(1)
            .help(item.detail)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.circle").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text("No downloads here").font(.headline)
            Text("Play a video in your browser and click **Download this video**,\nor press ⌘N to paste a link.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var manager: DownloadManager
    var body: some View {
        let running = manager.items.filter { $0.state == .running }.count
        HStack(spacing: 14) {
            if running > 0 {
                Label("\(running) downloading · \(formatBytes(Int64(manager.totalSpeed)))/s", systemImage: "arrow.down")
            } else {
                Text("Idle")
            }
            if manager.queuedCount > 0 { Text("\(manager.queuedCount) in queue") }
            if manager.queueRunning {
                Text(manager.runningQueues.count == 1 ? "Queue running" : "\(manager.runningQueues.count) queues running").foregroundStyle(.green)
            }
            Spacer()
            Toggle(isOn: $manager.settings.speedLimitEnabled) {
                Text(manager.settings.speedLimitEnabled ? "Speed limiter: \(manager.settings.speedLimitKBps) KB/s" : "Speed limiter")
            }
            .toggleStyle(.checkbox)
            Text("Castnet \(UpdateChecker.appVersion)")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
    }
}

struct Banner: View {
    let icon: String
    let text: String
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(text)
            Spacer()
            Button(button, action: action)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Add URL

struct AddURLSheet: View {
    @EnvironmentObject var manager: DownloadManager
    @Binding var isPresented: Bool
    @StateObject private var form = AddURLForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter New Address to Download").font(.headline)
            TextField("https://…", text: $form.urlText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 460)
                .onSubmit(add)
            Picker("Type", selection: $form.kind) {
                Text("Automatic").tag("auto")
                Text("File").tag("file")
                Text("HLS stream (.m3u8)").tag("hls")
                Text("DASH stream (.mpd)").tag("dash")
                Text("Video page (YouTube, Vimeo, X…)").tag("ytdlp")
            }
            .pickerStyle(.menu)
            .frame(width: 320)
            if let error = form.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("OK", action: add).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            if let s = Clipboard.stringIfAllowed(), s.hasPrefix("http") { form.urlText = s }
        }
    }

    private func add() {
        let s = form.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
            form.error = "Enter an http(s) address."
            return
        }
        let k: DownloadKind
        if form.kind == "auto" {
            let g = DownloadKind.guess(for: u)
            let host = u.host ?? ""
            let pageLike = g == .file && u.pathExtension.isEmpty &&
                ["youtube.com", "youtu.be", "vimeo.com", "x.com", "twitter.com", "tiktok.com", "instagram.com", "facebook.com", "dailymotion.com", "twitch.tv"]
                    .contains { host == $0 || host.hasSuffix("." + $0) }
            k = pageLike ? .ytdlp : g
        } else {
            k = DownloadKind(rawValue: form.kind) ?? .file
        }
        manager.submit(DownloadRequest(url: s, kind: k, pageUrl: k == .ytdlp ? s : nil), confirm: true)
        isPresented = false
    }
}
