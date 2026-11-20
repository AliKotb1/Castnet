// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Castnet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Castnet", targets: ["Castnet"]),
        .executable(name: "castnet-host", targets: ["castnet-host"]),
        .executable(name: "castnet-cli", targets: ["castnet-cli"]),
    ],
    targets: [
        // Download engine: segmented HTTP, HLS, DASH, yt-dlp, ffmpeg muxing, IPC.
        .target(name: "CastnetCore", path: "Sources/CastnetCore"),
        // SwiftUI app (download list window + menu bar).
        .executableTarget(name: "Castnet", dependencies: ["CastnetCore"], path: "Sources/Castnet"),
        // Chrome native-messaging host: stdin/stdout <-> Unix socket of the app.
        .executableTarget(name: "castnet-host", path: "Sources/castnet-host"),
        // Headless command-line downloader, used for testing the engine.
        .executableTarget(name: "castnet-cli", dependencies: ["CastnetCore"], path: "Sources/castnet-cli"),
        // In-process tests of the download manager (queues, scheduler, duplicates…). Not shipped.
        .executableTarget(name: "castnet-selftest", dependencies: ["CastnetCore"], path: "Sources/castnet-selftest"),
    ]
)
