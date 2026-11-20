import SwiftUI
import AppKit
import CastnetCore

/// "A new version of Castnet is available": offered when a release is published, downloaded and
/// installed inside the app. Downloads, settings and files live outside the app and stay as they are.
final class UpdateModel: ObservableObject {
    enum Phase: Equatable { case offer, downloading(Double), installing, failed(String) }
    @Published var update: AppUpdate?
    @Published var phase: Phase = .offer
}

struct UpdateView: View {
    @ObservedObject var model: UpdateModel
    let install: () -> Void
    let later: () -> Void
    let skip: () -> Void
    let openInBrowser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of Castnet is available").font(.title3.weight(.semibold))
                    Text("Castnet \(model.update?.version ?? "") is ready. You have \(UpdateChecker.appVersion).")
                        .foregroundStyle(.secondary)
                }
            }
            if let notes = model.update?.notes, !notes.isEmpty {
                Text("What’s new").font(.headline)
                ScrollView {
                    Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 190)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Text("Your downloads, settings and files stay as they are. Downloads in progress continue after the update.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch model.phase {
            case .offer:
                HStack {
                    Button("Skip This Version", action: skip)
                    Spacer()
                    Button("Later", action: later).keyboardShortcut(.cancelAction)
                    Button("Download & Install", action: install).keyboardShortcut(.defaultAction)
                }
            case let .downloading(p):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p)
                    Text("Downloading… \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing. Castnet will reopen in a moment.").foregroundStyle(.secondary)
                }
            case let .failed(message):
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Download in Browser", action: openInBrowser)
                    Button("Try Again", action: install).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
