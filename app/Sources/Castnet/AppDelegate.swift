import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
@preconcurrency import UserNotifications
import CastnetCore

/// Clipboard reads that never trigger macOS's "paste from other apps" alert on their own.
@MainActor
enum Clipboard {
    /// The clipboard text, only if reading it can't show a permission alert (macOS 15.4+ asks
    /// unless the person set Castnet to "Always Allow").
    static func stringIfAllowed() -> String? {
        let pb = NSPasteboard.general
        if #available(macOS 15.4, *), pb.accessBehavior != .alwaysAllow { return nil }
        return pb.string(forType: .string)
    }
}

/// Global hooks the SwiftUI views use to reach AppKit-level actions.
@MainActor
enum AppActions {
    static var showSettings: () -> Void = {}
    static var showAddURL: () -> Void = {}
    static var showSetup: () -> Void = {}
    static var showScheduler: () -> Void = {}
    static var showStatus: (DownloadItem) -> Void = { _ in }
    static var refreshLink: (DownloadItem) -> Void = { _ in }
    static var changeAddress: (DownloadItem) -> Void = { _ in }
    static var confirmDelete: ([DownloadItem]) -> Void = { _ in }
    static var showBatch: (String?) -> Void = { _ in }
    static var showUpdate: (AppUpdate) -> Void = { _ in }
    /// Clipboard change made by Castnet itself (Copy Address), ignored by the clipboard monitor.
    static var ownClipboardChange = -1

    static func openItem(_ item: DownloadItem) {
        if item.state == .completed, let p = item.outputPaths.first {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        } else {
            showStatus(item)
        }
    }

    static func reveal(_ item: DownloadItem) {
        let urls = item.outputPaths.map { URL(fileURLWithPath: $0) }
        if urls.isEmpty { NSWorkspace.shared.open(item.directory) } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let manager = DownloadManager.shared
    private var server: IPCServer?
    private var bridge: TCPBridgeServer?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var schedulerWindow: NSWindow?
    private var powerWindow: NSWindow?
    private var powerModel: CountdownModel?
    private var clipboardTimer: Timer?
    private var clipboardSeen = 0
    private var lastClipboardLink: String?
    private var settingsWatch: AnyCancellable?
    private var batchCounter = 0
    private var itemWindows: [String: NSWindow] = [:]
    private var maintenanceTimer: Timer?
    private var statusItem: NSStatusItem?
    private let addURLModel = AddURLModel()
    /// Test mode (CASTNET_HOME + CASTNET_HEADLESS): no windows, no changes to real browsers.
    private let headless = ProcessInfo.processInfo.environment["CASTNET_HEADLESS"] != nil
    private var testMode: Bool { Paths.testHome != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if headless { NSApp.setActivationPolicy(.prohibited) }
        // Only one Castnet at a time (e.g. a copy in Downloads and one in Applications).
        if !testMode, let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        // Self-setup (what install.sh used to do): bridge registration, extension files, tools.
        ExtractorUpdater.prepare()
        if !testMode {
            BrowserSetup.installExtensionFiles()
            BrowserSetup.registerNativeHost()
        }
        AppActions.showSetup = { [weak self] in self?.showSetup() }
        AppActions.showSettings = { [weak self] in self?.showSettings() }
        AppActions.showAddURL = { [weak self] in self?.showMainWindow(); self?.addURLModel.isPresented = true }
        AppActions.showScheduler = { [weak self] in self?.showScheduler() }
        AppActions.showStatus = { [weak self] in self?.showStatus($0) }
        AppActions.refreshLink = { [weak self] in self?.refreshLink($0) }
        AppActions.changeAddress = { [weak self] in self?.showChangeAddress($0) }
        AppActions.confirmDelete = { [weak self] in self?.confirmDelete($0) }
        AppActions.showBatch = { [weak self] in self?.showBatch(text: $0) }
        AppActions.showUpdate = { [weak self] in self?.offerUpdate($0, manual: true) }
        // A plain "terminate" signal (scripts, some shutdowns) quits like the Quit menu: the list is
        // saved and downloads are paused so they continue later.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
        resumeAfterUpdate()
        if !headless {
            buildMainMenu()
            buildStatusItem()
        }

        manager.onAdded = { [weak self] item in
            guard let self, !self.headless, self.manager.settings.showWindowOnAdd, !item.awaitingConfirmation else { return }
            self.showMainWindow()
        }
        if !headless { manager.onConfirmNeeded = { [weak self] item in self?.showInfo(item) } }
        manager.onStarted = { [weak self] item in
            guard let self, self.manager.settings.showProgressDialog else { return }
            self.showStatus(item, activate: false)
        }
        manager.onShowRequested = { [weak self] in self?.showMainWindow() }
        manager.onFinished = { [weak self] item in self?.finished(item) }
        manager.onExpired = { [weak self] item in
            self?.notify("Link expired", "\(item.filename): getting a fresh link to continue where it stopped.", id: "exp-\(item.id)")
        }
        manager.onRenewed = { [weak self] item in
            self?.notify("Download continued", "\(item.filename) got a fresh link and continues where it stopped.", id: "ren-\(item.id)")
        }
        manager.onPowerAction = { [weak self] action, reason in self?.performPowerAction(action, reason: reason) }
        if !headless {
            manager.onDuplicate = { [weak self] existing, request, confirm in
                self?.itemWindow("dup-\(existing.id)", title: "Duplicate Link") { close in
                    DuplicateView(existing: existing, request: request, confirm: confirm, close: close)
                }
            }
            manager.onShowExisting = { [weak self] item in
                guard let self else { return }
                if item.state == .completed {
                    self.itemWindow("done-\(item.id)", title: "Download complete") { close in CompleteView(item: item, close: close) }
                } else {
                    self.showStatus(item)
                }
            }
            settingsWatch = manager.$settings.map(\.monitorClipboard).removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateClipboardMonitor() }
            }
        }

        let mgr = manager
        let handler: IPCServer.Handler = { message, raw in await mgr.handle(message: message, raw: raw) }
        server = IPCServer(path: Paths.socket.path, handler: handler)
        // For the Safari extension (sandboxed); everything arriving there comes from Safari.
        bridge = TCPBridgeServer(handler: { message, raw in
            var m = message
            m["client"] = "com.apple.Safari"
            return await mgr.handle(message: m, raw: raw)
        })
        do {
            try server?.start()
            try? bridge?.start()
        } catch {
            if !headless {
                let alert = NSAlert()
                alert.messageText = "Castnet couldn't open its browser connection"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }

        UNUserNotificationCenter.current().delegate = self
        if headless {
            // Tests: a test copy installs an update from a local feed by itself (no windows).
            if testMode, ProcessInfo.processInfo.environment["CASTNET_TEST_AUTO_UPDATE"] != nil {
                Task { [weak self] in if let u = await UpdateChecker.check() { self?.installUpdate(u) } }
            }
            return
        }
        showMainWindow()
        if !manager.extensionEverConnected { showSetup() }
        runMaintenance()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runMaintenance() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.prepareForQuit()
        server?.stop()
        bridge?.stop()
    }

    /// Daily: refresh the site extractor; check for a newer Castnet if a feed is configured.
    private func runMaintenance() {
        BrowserSetup.registerNativeHost()
        Task.detached(priority: .background) { await ExtractorUpdater.updateIfDue() }
        Task { [weak self] in
            let update = await UpdateChecker.check()
            await MainActor.run {
                self?.manager.availableUpdate = update
                if let u = update { self?.offerUpdate(u, manual: false) }
            }
        }
    }

    // MARK: app updates (offered in a window, downloaded and installed inside the app)

    private var updateWindow: NSWindow?
    private var termSource: DispatchSourceSignal?
    private let updateModel = UpdateModel()
    private var offeredThisSession: String?

    func offerUpdate(_ u: AppUpdate, manual: Bool) {
        guard !headless else { return }
        if !manual {
            if Paths.defaults.string(forKey: "SkippedUpdate") == u.version || offeredThisSession == u.version { return }
        }
        offeredThisSession = u.version
        if updateModel.update != u || updateWindow == nil { updateModel.phase = .offer }
        updateModel.update = u
        if updateWindow == nil {
            let close: () -> Void = { [weak self] in self?.updateWindow?.close() }
            let view = UpdateView(model: updateModel,
                                  install: { [weak self] in if let u = self?.updateModel.update { self?.installUpdate(u) } },
                                  later: close,
                                  skip: { [weak self] in
                                      if let v = self?.updateModel.update?.version { Paths.defaults.set(v, forKey: "SkippedUpdate") }
                                      close()
                                  },
                                  openInBrowser: { [weak self] in
                                      if let s = self?.updateModel.update?.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
                                  })
            updateWindow = makeWindow("Software Update", view, size: NSSize(width: 520, height: 420))
        }
        NSApp.activate(ignoringOtherApps: true)
        updateWindow?.makeKeyAndOrderFront(nil)
    }

    private func installUpdate(_ u: AppUpdate) {
        if case .downloading = updateModel.phase { return }
        if updateModel.phase == .installing { return }
        updateModel.phase = .downloading(0)
        let model = updateModel
        Task { [weak self] in
            do {
                let dmg = try await AppInstaller().download(u) { p in DispatchQueue.main.async { model.phase = .downloading(p) } }
                await MainActor.run { model.phase = .installing }
                let app = Bundle.main.bundleURL
                try await Task.detached { try AppInstaller.install(dmg: dmg, expectedVersion: u.version, replacing: app) }.value
                try? FileManager.default.removeItem(at: dmg)
                await MainActor.run {
                    guard let self else { return }
                    // Downloads in progress continue after the update.
                    Paths.defaults.set(self.manager.items.filter { $0.state.isActive }.map(\.id.uuidString), forKey: "ResumeAfterUpdate")
                    AppInstaller.relaunch(app)
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run { model.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            }
        }
    }

    private func resumeAfterUpdate() {
        guard let ids = Paths.defaults.stringArray(forKey: "ResumeAfterUpdate") else { return }
        Paths.defaults.removeObject(forKey: "ResumeAfterUpdate")
        for item in manager.items where ids.contains(item.id.uuidString) { manager.resume(item) }
    }

    // MARK: windows

    private func makeWindow<V: View>(_ title: String, _ view: V, size: NSSize, resizable: Bool = false) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: view.environmentObject(manager))
        w.center()
        return w
    }

    func showMainWindow() {
        guard !headless else { return }
        if mainWindow == nil {
            let root = ContentView(addURL: addURLModel).environmentObject(manager)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Castnet"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: root)
            w.setContentSize(NSSize(width: 1060, height: 600))
            w.minSize = NSSize(width: 860, height: 420)
            w.setFrameAutosaveName("CastnetMain")
            if !w.setFrameUsingName("CastnetMain") { w.center() }
            w.delegate = self
            mainWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        guard !headless else { return }
        if settingsWindow == nil { settingsWindow = makeWindow("Castnet Options", SettingsView(), size: NSSize(width: 560, height: 680), resizable: true) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSetup() {
        guard !headless else { return }
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Set Up Castnet"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SetupView { [weak w] in w?.close() }.environmentObject(manager))
            w.center()
            setupWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showScheduler() {
        guard !headless else { return }
        if schedulerWindow == nil { schedulerWindow = makeWindow("Scheduler", SchedulerView(), size: NSSize(width: 720, height: 500)) }
        NSApp.activate(ignoringOtherApps: true)
        schedulerWindow?.makeKeyAndOrderFront(nil)
    }

    private func itemWindow<V: View>(_ key: String, title: String, activate: Bool = true, build: (@escaping () -> Void) -> V) {
        guard !headless else { return }
        if let w = itemWindows[key] {
            if activate { NSApp.activate(ignoringOtherApps: true) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        let close: () -> Void = { [weak self] in
            self?.itemWindows[key]?.close()
            self?.itemWindows[key] = nil
        }
        let w = makeWindow(title, build(close), size: NSSize(width: 520, height: 360))
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier(key)
        itemWindows[key] = w
        if activate { NSApp.activate(ignoringOtherApps: true) }
        w.makeKeyAndOrderFront(nil)
    }

    func showStatus(_ item: DownloadItem, activate: Bool = true) {
        itemWindow("status-\(item.id)", title: item.filename, activate: activate) { close in StatusView(item: item, close: close) }
    }

    func showInfo(_ item: DownloadItem) {
        itemWindow("info-\(item.id)", title: "Download File Info") { close in DownloadInfoView(item: item, close: close) }
    }

    func showChangeAddress(_ item: DownloadItem) {
        itemWindow("address-\(item.id)", title: "Change Address") { close in ChangeAddressView(item: item, close: close) }
    }

    func showBatch(text: String?) {
        batchCounter += 1
        let model = BatchModel(text: text)
        itemWindow("batch-\(batchCounter)", title: "Add Batch Download") { close in BatchView(model: model, close: close) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let key = w.identifier?.rawValue else { return }
        if key == "power" {   // closing the countdown cancels it
            powerModel?.stop()
            powerModel = nil
            powerWindow = nil
            return
        }
        if key.hasPrefix("info-"), let id = UUID(uuidString: String(key.dropFirst(5))),
           let item = manager.items.first(where: { $0.id == id }), item.awaitingConfirmation {
            // Closing the dialog without choosing = Download Later.
            manager.confirm(item, filename: item.filename, directory: item.directory, startNow: false)
        }
        itemWindows[key] = nil
    }

    private func finished(_ item: DownloadItem) {
        itemWindows["status-\(item.id)"]?.close()
        itemWindows["status-\(item.id)"] = nil
        if manager.settings.notifyOnComplete { notify("Download complete", item.filename, id: item.id.uuidString, path: item.outputPaths.first) }
        if manager.settings.showCompleteDialog {
            itemWindow("done-\(item.id)", title: "Download complete", activate: false) { close in CompleteView(item: item, close: close) }
        }
    }

    // MARK: actions

    /// "Refresh Link": reopen the page; when the video plays again, the
    /// extension hands Castnet the fresh link and the download continues where it stopped.
    private func refreshLink(_ item: DownloadItem) {
        manager.requestRenewal(item)
        if let p = item.request.pageUrl, let u = URL(string: p) {
            NSWorkspace.shared.open(u)
        } else {
            showChangeAddress(item)
        }
    }

    private func confirmDelete(_ items: [DownloadItem]) {
        guard !items.isEmpty else { return }
        let a = NSAlert()
        a.messageText = items.count == 1 ? "Delete “\(items[0].filename)” from the list?" : "Delete \(items.count) downloads from the list?"
        a.informativeText = "Unfinished downloads are stopped and their partial data removed."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        let box = NSButton(checkboxWithTitle: "Also move downloaded files to the Trash", target: nil, action: nil)
        a.accessoryView = box
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for i in items { manager.remove(i, deleteFiles: box.state == .on) }
    }

    // MARK: Tasks menu: batch download, import, export

    @objc func addBatch() { showBatch(text: nil) }

    @objc func addBatchFromClipboard() {
        // A menu choice the person made, so reading the clipboard here is expected.
        showBatch(text: NSPasteboard.general.string(forType: .string) ?? "")
    }

    @objc func importLinks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .html, .text]
        panel.message = "Choose a text file with links to download"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        showBatch(text: text)
    }

    @objc func exportLinks() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Castnet links.txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Saves the address of every download in the list, one per line."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try manager.exportLinks().write(to: url, atomically: true, encoding: .utf8) } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }

    // MARK: clipboard monitoring (catches download links you copy)

    private func updateClipboardMonitor() {
        let on = manager.settings.monitorClipboard && !headless
        if on, clipboardTimer == nil {
            clipboardSeen = NSPasteboard.general.changeCount   // only links copied from now on
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkClipboard() }
            }
        } else if !on {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != clipboardSeen else { return }
        clipboardSeen = cc
        guard cc != AppActions.ownClipboardChange else { return }
        if #available(macOS 15.4, *) {
            switch pb.accessBehavior {
            case .alwaysDeny: return
            case .alwaysAllow: break
            default:
                // Reading would make macOS ask on every copy, so first check, without reading,
                // whether the clipboard holds a link at all.
                Task { @MainActor [weak self] in
                    let key: PartialKeyPath<NSPasteboard.DetectedValues> = \NSPasteboard.DetectedValues.probableWebURL
                    guard let found = try? await pb.detectedPatterns(for: [key]), found.contains(key) else { return }
                    self?.takeClipboardLink(changeCount: cc)
                }
                return
            }
        }
        takeClipboardLink(changeCount: cc)
    }

    private func takeClipboardLink(changeCount cc: Int) {
        let pb = NSPasteboard.general
        guard pb.changeCount == cc, let raw = pb.string(forType: .string),
              let url = FileCategory.downloadLink(fromClipboard: raw), url.absoluteString != lastClipboardLink else { return }
        lastClipboardLink = url.absoluteString
        manager.submit(DownloadRequest(url: url.absoluteString, kind: DownloadKind.guess(for: url)), confirm: true)
    }

    // MARK: "when done": quit, sleep or shut down (queue and per-download options)

    private func performPowerAction(_ action: DoneAction, reason: String) {
        guard action != .nothing else { return }
        if testMode {
            // Tests check what would happen; a test run never sleeps or shuts down the Mac.
            let line = "\(action.rawValue)\t\(reason)\n"
            let log = Paths.support.appendingPathComponent("power-actions.log")
            if let h = try? FileHandle(forWritingTo: log) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: log)
            }
            return
        }
        guard !headless, powerWindow == nil else { return }
        if action == .quit {
            notify("Downloads finished", "\(reason) Castnet is quitting.", id: "power-quit")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            return
        }
        let model = CountdownModel(seconds: action == .shutDown ? 60 : 30)
        let finish: (Bool) -> Void = { [weak self] go in
            model.stop()
            self?.powerWindow?.close()
            self?.powerWindow = nil
            self?.powerModel = nil
            if go { self?.executePower(action) }
        }
        let w = makeWindow("Downloads Finished",
                           PowerCountdownView(action: action, reason: reason, model: model, now: { finish(true) }, cancel: { finish(false) }),
                           size: NSSize(width: 460, height: 130))
        w.identifier = NSUserInterfaceItemIdentifier("power")
        w.delegate = self
        w.level = .floating
        powerWindow = w
        powerModel = model
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.start { finish(true) }
    }

    private func executePower(_ action: DoneAction) {
        switch action {
        case .sleep:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["sleepnow"]
            try? p.run()
        case .shutDown:
            manager.prepareForQuit()
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"System Events\" to shut down")?.executeAndReturnError(&error)
            if error != nil {
                let a = NSAlert()
                a.messageText = "Castnet couldn’t shut down your Mac"
                a.informativeText = "Allow Castnet to control “System Events” in System Settings → Privacy & Security → Automation, then it can shut down when your downloads finish."
                a.runModal()
            }
        default:
            break
        }
    }

    @objc func showMain() { showMainWindow() }
    @objc func addURL() { AppActions.showAddURL() }
    @objc func pauseAll() { manager.pauseAll() }
    @objc func resumeAll() { manager.resumeAll() }
    @objc func deleteCompleted() { manager.clearFinished() }
    @objc func startQueue() { manager.startQueue() }
    @objc func stopQueue() { manager.stopQueue() }
    @objc func toggleLimiter() { manager.settings.speedLimitEnabled.toggle() }

    @objc func checkForUpdates() {
        Task { [weak self] in
            let update = await UpdateChecker.check()
            await MainActor.run {
                self?.manager.availableUpdate = update
                if let u = update { self?.offerUpdate(u, manual: true) }
                if update == nil {
                    let a = NSAlert()
                    a.messageText = "Castnet is up to date"
                    a.informativeText = "You have version \(UpdateChecker.appVersion)."
                    a.runModal()
                }
            }
        }
    }

    // MARK: menus

    private func buildMainMenu() {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ target: AnyObject? = nil) {
            let it = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            it.target = target
        }

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        add(appMenu, "About Castnet", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        appMenu.addItem(.separator())
        add(appMenu, "Options…", #selector(showSettings), ",", self)
        add(appMenu, "Set Up Browser Extension…", #selector(showSetup), "", self)
        if UpdateChecker.feedURL != nil { add(appMenu, "Check for Updates…", #selector(checkForUpdates), "", self) }
        appMenu.addItem(.separator())
        add(appMenu, "Hide Castnet", #selector(NSApplication.hide(_:)), "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        add(appMenu, "Quit Castnet", #selector(NSApplication.terminate(_:)), "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let tasksItem = NSMenuItem()
        let tasks = NSMenu(title: "Tasks")
        add(tasks, "Add New Download…", #selector(addURL), "n", self)
        add(tasks, "Add Batch Download…", #selector(addBatch), "N", self)
        add(tasks, "Add Batch Download from Clipboard", #selector(addBatchFromClipboard), "", self)
        tasks.addItem(.separator())
        add(tasks, "Import Links from File…", #selector(importLinks), "", self)
        add(tasks, "Export Links to File…", #selector(exportLinks), "", self)
        tasks.addItem(.separator())
        add(tasks, "Show Downloads", #selector(showMain), "0", self)
        tasks.addItem(.separator())
        add(tasks, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        tasksItem.submenu = tasks
        main.addItem(tasksItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        add(editMenu, "Undo", Selector(("undo:")), "z")
        add(editMenu, "Redo", Selector(("redo:")), "Z")
        editMenu.addItem(.separator())
        add(editMenu, "Cut", #selector(NSText.cut(_:)), "x")
        add(editMenu, "Copy", #selector(NSText.copy(_:)), "c")
        add(editMenu, "Paste", #selector(NSText.paste(_:)), "v")
        add(editMenu, "Select All", #selector(NSText.selectAll(_:)), "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let dlItem = NSMenuItem()
        let dl = NSMenu(title: "Downloads")
        add(dl, "Resume All", #selector(resumeAll), "r", self)
        add(dl, "Stop All", #selector(pauseAll), ".", self)
        add(dl, "Delete All Completed", #selector(deleteCompleted), "", self)
        dl.addItem(.separator())
        add(dl, "Speed Limiter On/Off", #selector(toggleLimiter), "l", self)
        dl.addItem(.separator())
        add(dl, "Scheduler…", #selector(showScheduler), "", self)
        add(dl, "Start Queue", #selector(startQueue), "", self)
        add(dl, "Stop Queue", #selector(stopQueue), "", self)
        dlItem.submenu = dl
        main.addItem(dlItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Castnet")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        let running = manager.items.filter { $0.state == .running }
        let header = running.isEmpty ? "No active downloads" : "\(running.count) downloading · \(formatBytes(Int64(manager.totalSpeed)))/s"
        menu.addItem(withTitle: header, action: nil, keyEquivalent: "").isEnabled = false
        for d in running.prefix(5) {
            let pct = d.fraction.map { " \(Int($0 * 100))%" } ?? ""
            menu.addItem(withTitle: "  \(d.filename)\(pct)", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Castnet", action: #selector(showMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add New Download…", action: #selector(addURL), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop All", action: #selector(pauseAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Resume All", action: #selector(resumeAll), keyEquivalent: "").target = self
        let lim = menu.addItem(withTitle: "Speed Limiter", action: #selector(toggleLimiter), keyEquivalent: "")
        lim.target = self
        lim.state = manager.settings.speedLimitEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Options…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Castnet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    // MARK: notifications

    private func notify(_ title: String, _ body: String, id: String, path: String? = nil) {
        guard !headless, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let path { content.userInfo = ["path": path] }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String, !path.isEmpty {
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        completionHandler()
    }
}
