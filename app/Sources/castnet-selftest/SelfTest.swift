import Foundation
import CastnetCore

/// In-process tests of the download manager: queues, scheduler, duplicate
/// links, batch download, "when done" actions and quarantine. Needs CASTNET_HOME (a throwaway
/// folder) and the test server:   CASTNET_HOME=/tmp/x castnet-selftest http://127.0.0.1:8765
/// Not shipped in Castnet.app.
@main
struct SelfTest {
    @MainActor static var fails = 0

    @MainActor static func check(_ ok: Bool, _ label: String) {
        print((ok ? "  ✓ " : "  ✗ ") + label)
        if !ok { fails += 1 }
    }

    @MainActor static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    static func quarantined(_ path: String) -> Bool { getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0 }

    @MainActor static func main() async {
        let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:8765"
        guard let home = Paths.testHome else {
            print("Set CASTNET_HOME to a throwaway folder first.")
            exit(2)
        }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        print("== batch links and clipboard detection")
        check(BatchLinks.expand("http://x/img*.jpg", from: "1", to: "3") == ["http://x/img1.jpg", "http://x/img2.jpg", "http://x/img3.jpg"],
              "numbers 1…3")
        check(BatchLinks.expand("http://x/p*.png", from: "8", to: "10", width: 3) == ["http://x/p008.png", "http://x/p009.png", "http://x/p010.png"],
              "zero-padded to 3 digits")
        check(BatchLinks.expand("http://x/*.zip", from: "a", to: "c") == ["http://x/a.zip", "http://x/b.zip", "http://x/c.zip"], "letters a…c")
        check(BatchLinks.expand("http://x/*.zip", from: "3", to: "1") == ["http://x/3.zip", "http://x/2.zip", "http://x/1.zip"], "counts down")
        check(BatchLinks.expand("http://x/file.zip", from: "1", to: "3").isEmpty && BatchLinks.expand("http://x/*", from: "a", to: "C").isEmpty,
              "no * or mixed-case letters: nothing")
        let found = BatchLinks.links(in: "see https://a.com/x.zip and http://b.org/y.mp4,\nagain https://a.com/x.zip; ftp://c.net/z.iso")
        check(found == ["https://a.com/x.zip", "http://b.org/y.mp4"], "links in text: http(s) only, no repeats (\(found.count))")
        check(FileCategory.downloadLink(fromClipboard: "  https://x.com/Setup.dmg\n") != nil, "copied .dmg link is caught")
        check(FileCategory.downloadLink(fromClipboard: "https://x.com/clip.MP4?token=1") != nil, "copied .mp4 link with a query is caught")
        check(FileCategory.downloadLink(fromClipboard: "https://x.com/article") == nil, "copied page link is ignored")
        check(FileCategory.downloadLink(fromClipboard: "look https://x.com/a.zip") == nil, "text that only contains a link is ignored")
        check(FileCategory.downloadLink(fromClipboard: "file:///Users/me/a.zip") == nil, "local file paths are ignored")

        print("== settings from 1.3.0 keep their schedule")
        let legacy = #"{"connections":16,"scheduler":{"startEnabled":true,"startHour":3,"startMinute":15,"stopEnabled":false,"stopHour":7,"stopMinute":0}}"#
        if let s = try? JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8)) {
            check(s.connections == 16 && s.queues.count == 1 && s.queues[0].isMain && s.queues[0].schedule.startEnabled
                  && s.queues[0].schedule.startHour == 3 && s.queues[0].schedule.startMinute == 15 && s.queues[0].schedule.days.isEmpty,
                  "old schedule becomes the main queue's schedule")
        } else { check(false, "old settings decode") }
        let other = #"{"queues":[{"id":"11111111-2222-4333-8444-555555555555","name":"Night"}],"duplicateAction":"somethingNew"}"#
        if let s = try? JSONDecoder().decode(AppSettings.self, from: Data(other.utf8)) {
            check(s.queues.count == 2 && s.queues[0].isMain && s.queues[1].name == "Night" && s.duplicateAction == .ask,
                  "main queue is always there; unknown values fall back to defaults")
        } else { check(false, "settings with queues decode") }

        let m = DownloadManager(loadState: false)
        m.persistenceEnabled = false
        var s = AppSettings()
        s.downloadDirectory = downloads.path
        s.connections = 2
        s.maxConcurrent = 6
        s.showDownloadInfoDialog = false
        m.settings = s
        var power: [(DoneAction, String)] = []
        m.onPowerAction = { power.append(($0, $1)) }
        var started: [String] = []
        m.onStarted = { started.append($0.filename) }

        print("== queue: order, files at the same time, when done")
        var q = m.addQueue(named: "Test queue")
        q.simultaneous = 1
        q.schedule.whenDone = .shutDown
        m.updateQueue(q)
        let qItems = (1...3).map { i in
            m.add(DownloadRequest(url: "\(base)/slow/av.webm?q=\(i)", kind: .file, filename: "q\(i).webm"), startNow: false, queue: q.id)
        }
        check(qItems.allSatisfy { $0.state == .scheduled && $0.queueId == q.id }, "Download Later puts files in the chosen queue")
        check(m.items(inQueue: q.id).map(\.filename) == ["q1.webm", "q2.webm", "q3.webm"], "queue lists files in the order added")
        var maxParallel = 0
        m.startQueue(q.id)
        check(m.runningQueues.contains(q.id), "queue is running")
        let qDone = await waitUntil(60) {
            maxParallel = max(maxParallel, qItems.filter { $0.state == .running }.count)
            return qItems.allSatisfy { $0.state == .completed }
        }
        check(qDone, "all 3 files downloaded")
        check(maxParallel == 1, "never more than 1 at a time (\(maxParallel))")
        check(started.filter { $0.hasPrefix("q") } == ["q1.webm", "q2.webm", "q3.webm"], "downloaded in queue order")
        check(!m.runningQueues.contains(q.id), "queue stops itself when it's empty")
        check(power.count == 1 && power.first?.0 == .shutDown && power.first?.1.contains("Test queue") == true,
              "the queue's when-done action fires once (\(power.map(\.0.rawValue)))")
        check(qItems.allSatisfy { $0.queueId == nil }, "finished files leave the queue")
        let out = qItems.compactMap(\.outputPaths.first)
        check(out.count == 3 && out.allSatisfy(quarantined), "downloaded files carry the quarantine flag, like browser downloads")
        power.removeAll()

        print("== moving files in a queue")
        let main = DownloadQueue.mainID
        let abc = ["a", "b", "c"].map { m.add(DownloadRequest(url: "\(base)/aonly.mp4?m=\($0)", kind: .file, filename: "\($0).mp4"), startNow: false) }
        check(m.items(inQueue: main).map(\.filename) == ["a.mp4", "b.mp4", "c.mp4"], "files start in the main queue")
        m.move(abc[2], earlier: true)
        check(m.items(inQueue: main).map(\.filename) == ["a.mp4", "c.mp4", "b.mp4"], "Move Up")
        m.move(abc[0], earlier: false)
        check(m.items(inQueue: main).map(\.filename) == ["c.mp4", "a.mp4", "b.mp4"], "Move Down")
        m.removeFromQueue(abc[2])
        check(m.items(inQueue: main).map(\.filename) == ["a.mp4", "b.mp4"] && abc[2].queueId == nil && abc[2].state == .paused, "Remove from Queue")
        abc.forEach { m.remove($0) }

        print("== stopping a queue")
        var r = m.addQueue(named: "Stopped queue")
        r.simultaneous = 2
        r.schedule.whenDone = .sleep
        m.updateQueue(r)
        let rItems = (1...3).map { m.add(DownloadRequest(url: "\(base)/slow/progressive.mp4?r=\($0)", kind: .file, filename: "r\($0).mp4"), startNow: false, queue: r.id) }
        m.startQueue(r.id)
        let twoRunning = await waitUntil(5) { rItems.filter { $0.state == .running }.count == 2 }
        check(twoRunning && rItems.filter { $0.state == .queued }.count == 1, "2 run, the 3rd waits")
        try? await Task.sleep(nanoseconds: 800_000_000)
        m.stopQueue(r.id)
        check(rItems.allSatisfy { $0.state == .scheduled } && !m.runningQueues.contains(r.id), "Stop Queue puts every file back in the queue")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check(rItems.allSatisfy { $0.state == .scheduled }, "nothing restarts by itself after stopping")
        check(power.isEmpty, "stopping never triggers the when-done action")
        check(rItems.contains { $0.received > 0 }, "progress is kept for the next start")

        print("== scheduler: days and times")
        let cal = Calendar.current
        let t0 = cal.date(bySettingHour: 10, minute: 30, second: 0, of: Date())!
        let today = cal.component(.weekday, from: t0)
        var sq = m.settings.queue(r.id)!
        sq.schedule.startEnabled = true
        sq.schedule.startHour = 10; sq.schedule.startMinute = 30
        sq.schedule.days = [today % 7 + 1]
        m.updateQueue(sq)
        m.runScheduler(at: t0)
        check(!m.runningQueues.contains(r.id), "not started on a day that isn't selected")
        sq.schedule.startMinute = 31
        sq.schedule.days = [today]
        sq.schedule.stopEnabled = true
        sq.schedule.stopHour = 10; sq.schedule.stopMinute = 32
        m.updateQueue(sq)
        m.runScheduler(at: t0.addingTimeInterval(60))
        check(m.runningQueues.contains(r.id), "started at its time on a selected day")
        m.runScheduler(at: t0.addingTimeInterval(120))
        check(!m.runningQueues.contains(r.id) && rItems.allSatisfy { $0.state == .scheduled }, "stopped at its stop time")
        var empty = m.addQueue(named: "Empty")
        empty.schedule.startEnabled = true; empty.schedule.startHour = 10; empty.schedule.startMinute = 33
        empty.schedule.whenDone = .quit
        m.updateQueue(empty)
        m.runScheduler(at: t0.addingTimeInterval(180))
        check(!m.runningQueues.contains(empty.id) && power.isEmpty, "an empty queue starting on schedule does nothing (no quit)")
        rItems.forEach { m.remove($0) }
        m.deleteQueue(r.id)
        m.deleteQueue(empty.id)

        print("== a paused file cancels the queue's when-done action")
        var p = m.addQueue(named: "Paused queue")
        p.simultaneous = 1
        p.schedule.whenDone = .quit
        m.updateQueue(p)
        let pItems = (1...2).map { m.add(DownloadRequest(url: "\(base)/slow/progressive.mp4?p=\($0)", kind: .file, filename: "p\($0).mp4"), startNow: false, queue: p.id) }
        pItems[1].request.url = "\(base)/slow/vonly.webm?p=2"
        m.startQueue(p.id)
        _ = await waitUntil(5) { pItems[0].state == .running }
        m.pause(pItems[0])
        let pDone = await waitUntil(30) { pItems[1].state == .completed && !m.runningQueues.contains(p.id) }
        check(pDone, "the other file finished and the queue ended")
        check(power.isEmpty, "no quit, because you paused one of its files")
        pItems.forEach { m.remove($0) }

        print("== one download's own when-done action")
        let solo = m.add(DownloadRequest(url: "\(base)/vonly.webm?solo=1", kind: .file, filename: "solo.webm"), startNow: false)
        solo.whenDone = .sleep
        m.resume(solo)
        let soloDone = await waitUntil(20) { solo.state == .completed }
        check(soloDone && power.count == 1 && power.first?.0 == .sleep, "finishing it fires its action (\(power.map(\.0.rawValue)))")
        check(solo.whenDone == .nothing, "the action runs only once")
        power.removeAll()

        print("== duplicate links")
        let link = DownloadRequest(url: "\(base)/aonly.mp4?dup=1", kind: .file, filename: "dup.mp4")
        let (first, firstExisting) = m.submit(link, confirm: false)
        let firstDone = await waitUntil(20) { first.state == .completed }
        check(firstDone && !firstExisting, "first copy downloaded")
        var shown: [DownloadItem] = []
        m.onShowExisting = { shown.append($0) }
        m.settings.duplicateAction = .useExisting
        let before = m.items.count
        let (again, wasExisting) = m.submit(link, confirm: false)
        check(wasExisting && again === first && m.items.count == before && shown.first === first, "“use existing”: nothing added, the existing one is shown")
        var asked = 0
        m.onDuplicate = { _, _, _ in asked += 1 }
        m.settings.duplicateAction = .ask
        _ = m.submit(link, confirm: false)
        check(asked == 1 && m.items.count == before, "“ask”: the app is asked, nothing added yet")
        m.settings.duplicateAction = .addNumbered
        let (numbered, numberedExisting) = m.submit(link, confirm: false)
        check(!numberedExisting && numbered !== first && numbered.filename != first.filename && m.items.count == before + 1,
              "“numbered”: added again as \(numbered.filename)")
        m.remove(numbered)
        let different = m.submit(DownloadRequest(url: "\(base)/aonly.mp4?dup=2", kind: .file), confirm: false)
        check(!different.existing, "a different link isn't a duplicate")
        m.remove(different.item)
        try? FileManager.default.removeItem(atPath: first.outputPaths[0])
        check(m.existingItem(for: link) == nil, "a finished download whose file was deleted isn't a duplicate")
        m.settings.duplicateAction = .ask
        m.onDuplicate = nil

        print("== batch download and export")
        let batch = m.addBatch(["\(base)/vonly.webm?solo=1", "\(base)/files/a.zip", "\(base)/files/b.zip", "ftp://x/y.zip"], startNow: false)
        check(batch.added == 2 && batch.skipped == 2, "adds new links, skips ones in the list and non-http (\(batch.added) added, \(batch.skipped) skipped)")
        let exported = m.exportLinks()
        check(exported.contains("\(base)/files/a.zip\n") && exported.contains("\(base)/files/b.zip\n"), "export writes one address per line")

        print("== moving data from the old name (Grabber)")
        let fm = FileManager.default
        let oldDir = home.appendingPathComponent("mig/Grabber"), newDir = home.appendingPathComponent("mig/Castnet")
        for d in [oldDir.appendingPathComponent("Browser Extension"), oldDir.appendingPathComponent("bin"), newDir.appendingPathComponent("Browser Extension")] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try? Data("[{\"id\":1}]".utf8).write(to: oldDir.appendingPathComponent("downloads.json"))
        try? Data("[]".utf8).write(to: newDir.appendingPathComponent("downloads.json"))
        try? Data().write(to: oldDir.appendingPathComponent("ipc.sock"))
        try? Data("keep".utf8).write(to: oldDir.appendingPathComponent("notes.txt"))
        LegacyMigration.merge(oldDir, into: newDir, regenerated: ["Browser Extension", "Firefox Add-on", "bin", "ipc.sock", "bridge.json"])
        let movedList = (try? String(contentsOf: newDir.appendingPathComponent("downloads.json"), encoding: .utf8)) ?? ""
        check(movedList.contains("\"id\":1"), "the old download list replaces an empty new one")
        check(fm.fileExists(atPath: newDir.appendingPathComponent("bin").path) && fm.fileExists(atPath: newDir.appendingPathComponent("notes.txt").path),
              "everything the new folder lacked is moved over")
        check(!fm.fileExists(atPath: oldDir.path), "the old folder is gone afterwards")
        check(!fm.fileExists(atPath: newDir.appendingPathComponent("ipc.sock").path), "the old app's runtime files aren't carried over")

        print(fails == 0 ? "\nSELF-TEST PASSED" : "\n\(fails) CHECK(S) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
