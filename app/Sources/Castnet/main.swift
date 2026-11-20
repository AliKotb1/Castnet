import AppKit
import CastnetCore

MainActor.assumeIsolated {
    if Snapshot.runIfRequested() { return }
    LegacyMigration.run()   // before the download manager loads anything
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
