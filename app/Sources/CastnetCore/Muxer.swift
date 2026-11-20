import Foundation

/// Runs an external tool, streaming stdout lines to `onLine`; returns (status, stderr tail).
final class ToolRunner {
    private(set) var process: Process?
    private let lock = NSLock()

    private func setProcess(_ p: Process?) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }

    func terminate() {
        lock.lock(); let p = process; lock.unlock()
        if let p, p.isRunning { p.interrupt(); DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } } }
    }

    func run(_ exe: URL, _ args: [String], cwd: URL? = nil, onLine: ((String) -> Void)? = nil) async throws -> (Int32, String) {
        try Task.checkCancellation()
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Tools.searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let errBuf = LineBuffer(keep: 40)
        let outBuf = LineBuffer(keep: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            outBuf.feed(d) { onLine?($0) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            errBuf.feed(d) { onLine?($0) }
        }

        setProcess(p)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int32, String), Error>) in
                p.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? out.fileHandleForReading.readToEnd() { outBuf.feed(rest) { onLine?($0) } }
                    if let rest = try? err.fileHandleForReading.readToEnd() { errBuf.feed(rest) { onLine?($0) } }
                    outBuf.flush { onLine?($0) }
                    errBuf.flush { onLine?($0) }
                    cont.resume(returning: (proc.terminationStatus, errBuf.tail))
                }
                do { try p.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            self.terminate()
        }
    }
}

/// Splits a byte stream into lines (handles \r progress updates too) and keeps the last N.
final class LineBuffer {
    private var pending = Data()
    private var lines: [String] = []
    private let keep: Int
    private let lock = NSLock()
    init(keep: Int) { self.keep = keep }

    func feed(_ d: Data, _ each: (String) -> Void) {
        lock.lock()
        pending.append(d)
        var out: [String] = []
        while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...i)
            if !line.isEmpty { out.append(line) }
        }
        if keep > 0 {
            lines.append(contentsOf: out)
            if lines.count > keep { lines.removeFirst(lines.count - keep) }
        }
        lock.unlock()
        out.forEach(each)
    }

    func flush(_ each: (String) -> Void) {
        lock.lock()
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        if !line.isEmpty, keep > 0 { lines.append(line) }
        lock.unlock()
        if !line.isEmpty { each(line) }
    }

    var tail: String { lock.lock(); defer { lock.unlock() }; return lines.suffix(8).joined(separator: "\n") }
}

/// Thin ffmpeg wrapper: stream copy only (no re-encoding).
enum Muxer {
    /// Remux one file into a new container (e.g. MPEG-TS → MP4).
    static func remux(ffmpeg: URL, input: URL, output: URL, runner: ToolRunner) async throws {
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]
        if ["mp4", "m4a", "mov"].contains(output.pathExtension.lowercased()) {
            // MP4 can't hold MPEG-TS data/ID3 streams: keep only audio and video.
            args += ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart"]
        } else {
            args += ["-map", "0", "-c", "copy"]
        }
        args.append(output.path)
        let (status, err) = try await runner.run(ffmpeg, args)
        guard status == 0 else { throw CastnetError.process("ffmpeg remux failed: \(err)") }
    }

    /// Merge a video-only and an audio-only track.
    static func merge(ffmpeg: URL, video: URL, audio: URL, output: URL, runner: ToolRunner) async throws {
        var args = ["-hide_banner", "-loglevel", "error", "-y", "-i", video.path, "-i", audio.path,
                    "-map", "0:v:0?", "-map", "1:a:0?", "-c", "copy"]
        if output.pathExtension.lowercased() == "mp4" { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        let (status, err) = try await runner.run(ffmpeg, args)
        guard status == 0 else { throw CastnetError.process("ffmpeg merge failed: \(err)") }
    }
}
