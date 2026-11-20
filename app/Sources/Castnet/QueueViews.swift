import SwiftUI
import AppKit
import CastnetCore

// MARK: - Scheduler (queue list on the left, Schedule / Files in the queue on the right)

final class SchedulerModel: ObservableObject {
    @Published var selected: UUID?
    @Published var tab: Int
    init(selected: UUID? = nil, tab: Int = 0) {
        self.selected = selected ?? DownloadQueue.mainID
        self.tab = tab
    }
}

struct SchedulerView: View {
    @EnvironmentObject var manager: DownloadManager
    @StateObject private var model: SchedulerModel

    init(queue: UUID? = nil, tab: Int = 0) {
        _model = StateObject(wrappedValue: SchedulerModel(selected: queue, tab: tab))
    }

    private var queueID: UUID { model.selected ?? DownloadQueue.mainID }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selected) {
                    Section("Queues") {
                        ForEach(manager.settings.queues) { q in
                            HStack {
                                Label(q.name, systemImage: q.isMain ? "list.number" : "list.bullet")
                                Spacer()
                                if manager.runningQueues.contains(q.id) {
                                    Circle().fill(Color.green).frame(width: 7, height: 7).help("Running")
                                }
                            }
                            .tag(Optional(q.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 2) {
                    Button { model.selected = manager.addQueue(named: "").id; model.tab = 0 } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .help("New queue")
                    Button {
                        let id = queueID
                        model.selected = DownloadQueue.mainID
                        manager.deleteQueue(id)
                    } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .disabled(queueID == DownloadQueue.mainID)
                    .help("Delete this queue. Its files move to the main queue.")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $model.tab) {
                    Text("Schedule").tag(0)
                    Text("Files in the queue").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                if model.tab == 0 {
                    ScheduleTab(queue: queueBinding(queueID))
                } else {
                    QueueFilesTab(queueID: queueID)
                }
                Divider()
                HStack {
                    let n = manager.items(inQueue: queueID).count
                    Text("\(n) file\(n == 1 ? "" : "s") in this queue").foregroundStyle(.secondary)
                    Spacer()
                    if manager.runningQueues.contains(queueID) {
                        Button("Stop Queue") { manager.stopQueue(queueID) }
                    } else {
                        Button("Start Now") { manager.startQueue(queueID) }
                            .disabled(manager.startableCount(queueID) == 0)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 720, height: 500)
    }

    private func queueBinding(_ id: UUID) -> Binding<DownloadQueue> {
        Binding(
            get: { manager.settings.queue(id) ?? .main },
            set: { manager.updateQueue($0) })
    }
}

struct ScheduleTab: View {
    @Binding var queue: DownloadQueue

    var body: some View {
        Form {
            TextField("Queue name", text: $queue.name)
            Section("Start and stop") {
                HStack {
                    Toggle("Start the queue at", isOn: $queue.schedule.startEnabled)
                    Spacer()
                    TimePicker(hour: $queue.schedule.startHour, minute: $queue.schedule.startMinute)
                        .disabled(!queue.schedule.startEnabled)
                }
                HStack {
                    Toggle("Stop the queue at", isOn: $queue.schedule.stopEnabled)
                    Spacer()
                    TimePicker(hour: $queue.schedule.stopHour, minute: $queue.schedule.stopMinute)
                        .disabled(!queue.schedule.stopEnabled)
                }
                DayPicker(days: $queue.schedule.days)
                    .disabled(!queue.schedule.startEnabled && !queue.schedule.stopEnabled)
            }
            Section("While it runs") {
                Stepper("Download \(queue.simultaneous) file\(queue.simultaneous == 1 ? "" : "s") at the same time",
                        value: $queue.simultaneous, in: 1...10)
                Picker("When the queue is done", selection: $queue.schedule.whenDone) {
                    ForEach(DoneAction.allCases) { Text($0.title).tag($0) }
                }
                if queue.schedule.whenDone == .sleep || queue.schedule.whenDone == .shutDown {
                    Text("Castnet shows a countdown first, so you can cancel. It only acts when the queue downloaded something and you didn’t pause any of its files.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Day checkboxes, as toggle chips. No day selected = every day.
struct DayPicker: View {
    @Binding var days: [Int]

    var body: some View {
        let cal = Calendar.current
        let symbols = cal.shortWeekdaySymbols
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Days")
                Spacer()
                ForEach(order, id: \.self) { d in
                    let on = days.isEmpty || days.contains(d)
                    Button { toggle(d) } label: {
                        Text(symbols[d - 1])
                            .font(.system(size: 11, weight: on ? .semibold : .regular))
                            .frame(width: 38, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(days.isEmpty ? "Every day" : "Only on the highlighted days")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggle(_ d: Int) {
        var set = Set(days.isEmpty ? Array(1...7) : days)
        if set.contains(d) { set.remove(d) } else { set.insert(d) }
        guard !set.isEmpty else { return }   // at least one day
        days = set.count == 7 ? [] : set.sorted()
    }
}

final class RowSelection: ObservableObject { @Published var id: UUID? }

struct QueueFilesTab: View {
    @EnvironmentObject var manager: DownloadManager
    let queueID: UUID
    @StateObject private var selection = RowSelection()

    var body: some View {
        let files = manager.items(inQueue: queueID)
        let selected = files.first { $0.id == selection.id }
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection.id) {
                ForEach(files) { i in
                    HStack {
                        NameCell(item: i)
                        Spacer()
                        SizeCell(item: i).foregroundStyle(.secondary)
                        StatusCell(item: i).frame(width: 130, alignment: .leading)
                    }
                    .tag(Optional(i.id))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if files.isEmpty {
                    Text("No files in this queue.\nRight-click a download → Add to Queue, or choose Download Later.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                }
            }
            HStack {
                Button { if let s = selected { manager.move(s, earlier: true) } } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(selected == nil || selected?.id == files.first?.id)
                Button { if let s = selected { manager.move(s, earlier: false) } } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(selected == nil || selected?.id == files.last?.id)
                Spacer()
                Button("Remove from Queue") { if let s = selected { manager.removeFromQueue(s) } }
                    .disabled(selected == nil)
            }
            Text("Files download in this order. Finished files leave the queue.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TimePicker: View {
    @Binding var hour: Int
    @Binding var minute: Int
    var body: some View {
        HStack(spacing: 2) {
            Picker("", selection: $hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
                .labelsHidden().frame(width: 64)
            Text(":")
            Picker("", selection: $minute) { ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
                .labelsHidden().frame(width: 64)
        }
    }
}

// MARK: - Batch download (Tasks → Add Batch Download / from Clipboard)

final class BatchModel: ObservableObject {
    @Published var mode = 0            // 0 = address with *, 1 = list of links
    @Published var pattern = ""
    @Published var from = "1"
    @Published var to = "10"
    @Published var width = 0
    @Published var text = ""
    @Published var queue = DownloadQueue.mainID
    @Published var message: String?

    init(text: String? = nil) {
        if let t = text { mode = 1; self.text = t }
    }
}

struct BatchView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var model: BatchModel
    let close: () -> Void

    private var links: [String] {
        model.mode == 0 ? BatchLinks.expand(model.pattern, from: model.from, to: model.to, width: model.width)
                        : BatchLinks.links(in: model.text)
    }

    var body: some View {
        let links = self.links
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Batch Download").font(.headline)
            Picker("", selection: $model.mode) {
                Text("Address with a wildcard").tag(0)
                Text("List of links").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            if model.mode == 0 {
                TextField("https://example.com/photos/image*.jpg", text: $model.pattern).textFieldStyle(.roundedBorder)
                Text("Put a * where the number or letter changes, then choose the range.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("From")
                    TextField("1", text: $model.from).frame(width: 64)
                    Text("to")
                    TextField("10", text: $model.to).frame(width: 64)
                    Spacer()
                    Stepper("Digits: \(model.width == 0 ? "as is" : "\(model.width)")", value: $model.width, in: 0...8)
                        .help("Zero-pad numbers, e.g. 3 digits makes 001, 002 …")
                }
                .textFieldStyle(.roundedBorder)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("First").foregroundStyle(.secondary)
                        Text(links.first ?? "–").lineLimit(1).truncationMode(.middle)
                    }
                    GridRow {
                        Text("Last").foregroundStyle(.secondary)
                        Text(links.count > 1 ? links.last! : "–").lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.callout)
            } else {
                TextEditor(text: $model.text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 170)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
                Text("Paste or type links. Every http(s) link in the text is added; links already in your list are skipped.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(links.count) link\(links.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                if let m = model.message { Text(m).foregroundStyle(.orange) }
                Spacer()
                if manager.settings.queues.count > 1 {
                    Picker("Queue", selection: $model.queue) {
                        ForEach(manager.settings.queues) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 220)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add to Queue") { add(links, start: false) }.disabled(links.isEmpty)
                Button("Download Now") { add(links, start: true) }.keyboardShortcut(.defaultAction).disabled(links.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func add(_ links: [String], start: Bool) {
        let r = manager.addBatch(links, startNow: start, queue: model.queue)
        if r.added == 0 {
            model.message = "These links are already in your list."
            return
        }
        close()
    }
}

// MARK: - Duplicate link

final class DuplicateModel: ObservableObject {
    @Published var choice = DuplicateAction.useExisting
    @Published var remember = false
}

struct DuplicateView: View {
    @EnvironmentObject var manager: DownloadManager
    @ObservedObject var existing: DownloadItem
    let request: DownloadRequest
    let confirm: Bool
    let close: () -> Void
    @StateObject private var model = DuplicateModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill").font(.system(size: 28)).foregroundStyle(.orange).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This link is already in your list").font(.headline)
                    Text("\(existing.filename) · \(status)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text(request.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Picker("", selection: $model.choice) {
                Text(existing.state == .completed ? "Show the file I already downloaded" : "Continue the existing download")
                    .tag(DuplicateAction.useExisting)
                Text("Download it again with a numbered file name").tag(DuplicateAction.addNumbered)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Toggle("Do this every time without asking", isOn: $model.remember).font(.caption)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var status: String {
        if existing.state == .completed { return "Complete" }
        if let f = existing.fraction { return String(format: "%.0f%% downloaded", f * 100) }
        return existing.detail
    }

    private func apply() {
        if model.remember { manager.settings.duplicateAction = model.choice }
        if model.choice == .addNumbered { manager.add(request, confirm: confirm) } else { manager.useExisting(existing) }
        close()
    }
}

// MARK: - "When done" countdown before sleeping or shutting down

final class CountdownModel: ObservableObject {
    @Published var remaining: Int
    private var timer: Timer?

    init(seconds: Int) { remaining = seconds }

    func start(_ fire: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.remaining -= 1
            if self.remaining <= 0 { t.invalidate(); fire() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct PowerCountdownView: View {
    let action: DoneAction
    let reason: String
    @ObservedObject var model: CountdownModel
    let now: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: action == .shutDown ? "power.circle.fill" : "moon.zzz.fill")
                    .font(.system(size: 32)).foregroundStyle(.orange).frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action == .shutDown ? "Your Mac will shut down in \(model.remaining) seconds"
                                             : "Your Mac will go to sleep in \(model.remaining) seconds")
                        .font(.headline).monospacedDigit()
                    Text(reason).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(action == .shutDown ? "Shut Down Now" : "Sleep Now", action: now)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
