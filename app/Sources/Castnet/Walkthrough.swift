import SwiftUI
import AppKit
import CastnetCore

/// Step-by-step guide for adding the extension to a Chrome-family browser: open its Extensions
/// page, turn on Developer mode, add the Castnet folder. Each step shows a drawing of the page
/// with the spot to click highlighted, and the last step appears by itself once the browser has
/// loaded the extension (it reports to the app as soon as it's installed).
final class WalkthroughModel: ObservableObject {
    @Published var step: Int
    @Published var copied = false
    init(step: Int) { self.step = step }
}

struct ChromiumWalkthrough: View {
    @EnvironmentObject var manager: DownloadManager
    let browser: BrowserSetup.Browser
    @StateObject private var model: WalkthroughModel

    init(browser: BrowserSetup.Browser, step: Int = 0) {
        self.browser = browser
        _model = StateObject(wrappedValue: WalkthroughModel(step: step))
    }

    private var name: String { browser.name }
    private var isEdge: Bool { browser.bundleIDs.contains("com.microsoft.edgemac") }
    private var added: Bool { browser.bundleIDs.contains { manager.connectedBrowsers.contains($0) } }
    private let labels = ["Open", "Developer mode", "Add Castnet", "Done"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepBar(labels: labels, current: model.step)
            HStack(alignment: .top, spacing: 20) {
                ExtensionsPageDrawing(scheme: browser.pageScheme, edge: isEdge, step: model.step)
                    .frame(width: 290, height: 200)
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.step == 1 || model.step == 2 {
                    Button("Back") { model.step -= 1 }
                }
                Spacer()
                if model.step == 0 {
                    Button("It’s open") { model.step = 1 }
                } else if model.step == 1 {
                    Button("It’s on. Next") { model.step = 2 }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { if added && model.step == 0 { model.step = 3 } }
        .onChange(of: added) { now in if now { withAnimation(.easeInOut) { model.step = 3 } } }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case 0:
            Text("Open the Extensions page").font(.title3.weight(.semibold))
            Text("Castnet’s extension comes with the app instead of the Chrome Web Store, so you add it on \(name)’s Extensions page. It takes about a minute.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open \(name) Extensions") {
                BrowserSetup.open("\(browser.pageScheme)://extensions", in: browser)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if model.step == 0 { model.step = 1 } }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text("Didn’t open? Click \(name)’s address bar, paste with ⌘V and press Return. The address is on your clipboard.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case 1:
            Text("Turn on Developer mode").font(.title3.weight(.semibold))
            Text(isEdge ? "On the left side of the page, near the bottom, click the **Developer mode** switch so it turns on."
                        : "In the top-right corner of the page, click the **Developer mode** switch so it turns on.")
                .fixedSize(horizontal: false, vertical: true)
            Text("It lets \(name) add an extension that comes from an app on your Mac. Leave it on: \(name) turns such extensions off when it’s off.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case 2:
            Text("Add Castnet").font(.title3.weight(.semibold))
            HStack(alignment: .center, spacing: 12) {
                FolderTile(url: BrowserSetup.extensionFolder, title: "Castnet Extension")
                Text("**Drag this folder** onto \(name)’s Extensions page.").fixedSize(horizontal: false, vertical: true)
            }
            Text("Or click **Load unpacked** on the page, press ⌘⇧G in the window that opens, paste with ⌘V, press Return, then click **Select**.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(model.copied ? "Copied ✓" : "Copy Folder Location") { copyFolderPath() }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BrowserSetup.extensionFolder]) }
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for \(name) to load Castnet…").foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Text("Already added it? Click the Castnet button in \(name)’s toolbar once.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default:
            Label("Castnet is in \(name)", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
            Text("**Pin it:** click the puzzle-piece icon in \(name)’s toolbar, then the pin next to Castnet.")
                .fixedSize(horizontal: false, vertical: true)
            Text("**Try it:** play any video. A **Download this video** button appears on it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep Developer mode on. Castnet keeps the extension up to date, and \(name) uses the new version after it restarts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Show the steps again") { model.step = 0 }.buttonStyle(.link).font(.caption)
        }
    }

    private func copyFolderPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BrowserSetup.extensionFolder.path, forType: .string)
        AppActions.ownClipboardChange = NSPasteboard.general.changeCount
        model.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.copied = false }
    }
}

/// "① Open — ② Developer mode — ③ Add Castnet — ④ Done"
struct StepBar: View {
    let labels: [String]
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                HStack(spacing: 5) {
                    ZStack {
                        Circle().fill(i < current ? Color.green : i == current ? Color.accentColor : Color.primary.opacity(0.1))
                        if i < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(i == current ? .white : .secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(label).font(.caption.weight(i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? .primary : .secondary)
                        .fixedSize()
                }
                if i < labels.count - 1 {
                    Rectangle().fill(i < current ? Color.green.opacity(0.6) : Color.primary.opacity(0.12)).frame(height: 1.5)
                }
            }
        }
    }
}

/// A simplified drawing of a Chrome-family Extensions page, highlighting what to click in each step.
struct ExtensionsPageDrawing: View {
    let scheme: String
    let edge: Bool
    let step: Int

    var body: some View {
        VStack(spacing: 0) {
            // Title bar and address field.
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.75)).frame(width: 7, height: 7) }
                Text("\(scheme)://extensions")
                    .font(.system(size: 9.5, design: .monospaced)).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .background(step == 0 ? Pulse(radius: 10) : nil)
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(Color.primary.opacity(0.04))
            Divider()
            if edge { edgePage } else { chromePage }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var devOn: Bool { step >= 2 }

    private var chromePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Extensions").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Developer mode").font(.system(size: 8.5)).foregroundStyle(.secondary)
                MiniSwitch(on: devOn).background(step == 1 ? Pulse(radius: 9) : nil)
            }
            if devOn { devButtons }
            pageBody
        }
        .padding(10)
    }

    private var edgePage: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Extensions").font(.system(size: 11, weight: .semibold))
                ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08)).frame(width: 52, height: 6) }
                Spacer()
                HStack(spacing: 4) {
                    MiniSwitch(on: devOn).background(step == 1 ? Pulse(radius: 9) : nil)
                    Text("Developer mode").font(.system(size: 7.5)).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(width: 92)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
            VStack(alignment: .leading, spacing: 8) {
                Text("Installed extensions").font(.system(size: 10.5, weight: .semibold))
                if devOn { devButtons }
                pageBody
            }
            .padding(9)
        }
    }

    private var devButtons: some View {
        HStack(spacing: 5) {
            MiniButton(title: "Load unpacked").background(step == 2 ? Pulse(radius: 6) : nil)
            MiniButton(title: "Pack extension")
            MiniButton(title: "Update")
        }
    }

    @ViewBuilder private var pageBody: some View {
        if step == 2 {
            DropTarget()
        } else if step >= 3 {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Castnet").font(.system(size: 10.5, weight: .semibold))
                    Text("Video & Download Catcher").font(.system(size: 8.5)).foregroundStyle(.secondary)
                }
                Spacer()
                MiniSwitch(on: true)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.green.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.green.opacity(0.4)))
            Spacer(minLength: 0)
        } else {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.10)).frame(width: 70, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)).frame(width: 110, height: 5)
                    }
                    Spacer()
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
            }
            Spacer(minLength: 0)
        }
    }
}

/// The page with a folder gliding onto it (step "Add Castnet").
struct DropTarget: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let p = (t.truncatingRemainder(dividingBy: 2.6)) / 2.6
            let move = min(1, p / 0.7)
            let eased = 1 - pow(1 - move, 3)
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(Color.accentColor.opacity(0.55))
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(p > 0.7 ? 0.10 : 0.04)))
                    Text(p > 0.7 ? "Castnet added" : "Drop to add")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.accentColor)
                        .offset(y: 22)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22)).foregroundStyle(Color.accentColor)
                        .position(x: -10 + (geo.size.width / 2 + 10) * eased, y: geo.size.height / 2 - 4)
                        .opacity(p > 0.92 ? 0 : 1)
                }
            }
        }
    }
}

struct MiniSwitch: View {
    let on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: 24, height: 13)
            Circle().fill(.white).frame(width: 10, height: 10).padding(1.5).shadow(radius: 0.5)
        }
    }
}

struct MiniButton: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
    }
}

/// A softly pulsing orange ring around the thing to click.
struct Pulse: View {
    var radius: CGFloat = 8
    var body: some View {
        TimelineView(.animation) { ctx in
            let phase = (sin(ctx.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
            RoundedRectangle(cornerRadius: radius)
                .stroke(Color.orange, lineWidth: 2)
                .padding(-4 - 2.5 * phase)
                .opacity(0.55 + 0.45 * phase)
        }
        .allowsHitTesting(false)
    }
}
