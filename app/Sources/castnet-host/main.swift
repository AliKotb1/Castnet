import Foundation
import Darwin

// Chrome native-messaging host for Castnet.
//
// The browser starts this process and talks to it over stdin/stdout. Each message is a
// 4-byte native-endian length followed by UTF-8 JSON. Each request is relayed to
// the Castnet app over its Unix socket; the app is launched first if needed.
// The host keeps no state and exits when the browser closes stdin.

let version = "1.5.4"
let bundleID = "app.castnet.mac"

let socketPath: String = {
    if let home = ProcessInfo.processInfo.environment["CASTNET_HOME"], !home.isEmpty {
        // test mode: same short hashed name as Paths.socket in the app
        var h: UInt32 = 5381
        for b in URL(fileURLWithPath: home, isDirectory: true).path.utf8 { h = (h &* 33) ^ UInt32(b) }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("castnet-\(String(h, radix: 16)).sock").path
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Castnet/ipc.sock").path
}()

func log(_ s: String) {
    // stderr ends up in the browser's log (chrome://… --enable-logging); never write logs to stdout.
    FileHandle.standardError.write(Data("castnet-host: \(s)\n".utf8))
}

func readExactly(_ n: Int) -> Data? {
    var data = Data()
    while data.count < n {
        let chunk = FileHandle.standardInput.readData(ofLength: n - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func readMessage() -> Data? {
    guard let header = readExactly(4) else { return nil }
    let len = header.withUnsafeBytes { $0.load(as: UInt32.self) }
    guard len > 0, len < 64 << 20 else { return nil }
    return readExactly(Int(len))
}

func writeMessage(_ obj: Any) {
    guard var body = try? JSONSerialization.data(withJSONObject: obj) else { return }
    if body.count > 1_000_000 { body = Data(#"{"ok":false,"error":"response too large"}"#.utf8) }
    var len = UInt32(body.count)
    let header = Data(bytes: &len, count: 4)
    FileHandle.standardOutput.write(header + body)
}

func findTool(_ name: String) -> Bool {
    // Tools ship inside Castnet.app (Contents/Helpers); the extractor may also have an updated copy.
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let helpers = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/\(name)")
    if FileManager.default.isExecutableFile(atPath: helpers.path) { return true }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    if FileManager.default.isExecutableFile(atPath: support.appendingPathComponent("Castnet/bin/\(name)").path) { return true }
    let home = NSHomeDirectory()
    var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/bin"]
    dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return dirs.contains { FileManager.default.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent(name)) }
}

func sendToApp(_ line: Data, timeout: Int = 15) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var payload = line
    payload.append(0x0A)
    let sent = payload.withUnsafeBytes { raw -> Bool in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    guard sent else { return nil }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(buf, count: n)
    }
    return out.split(separator: 0x0A).first.map { Data($0) }
}

/// The browser that started this host (our parent process), as its bundle identifier, so the app
/// knows which browsers have Castnet. Chrome-family browsers may start hosts from a helper app
/// inside their bundle, so the outermost ".app" in the path is the browser itself.
let clientApp: String? = {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(getppid(), &buf, UInt32(buf.count)) > 0 else { return nil }
    let path = String(cString: buf)
    guard let r = path.range(of: ".app/") else { return nil }
    return Bundle(path: String(path[..<r.lowerBound]) + ".app")?.bundleIdentifier
}()

func appIsRunning() -> Bool {
    sendToApp(Data(#"{"type":"ping"}"#.utf8), timeout: 3) != nil
}

/// The host lives at Castnet.app/Contents/MacOS/castnet-host, so the app is three levels up.
func appBundlePath() -> String? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app.path : nil
}

func launchApp(background: Bool) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    var args = background ? ["-g"] : []
    if let path = appBundlePath() { args += ["-a", path] } else { args += ["-b", bundleID] }
    p.arguments = args
    do { try p.run() } catch { log("open failed: \(error)"); return false }
    p.waitUntilExit()
    for _ in 0..<60 {
        if appIsRunning() { return true }
        usleep(150_000)
    }
    return false
}

while let msg = readMessage() {
    guard let obj = try? JSONSerialization.jsonObject(with: msg) as? [String: Any], let type = obj["type"] as? String else {
        writeMessage(["ok": false, "error": "bad message"])
        continue
    }
    // Tell the app which browser this came from (see clientApp).
    var tagged = obj
    if let c = clientApp { tagged["client"] = c }
    let msg = (try? JSONSerialization.data(withJSONObject: tagged)) ?? msg
    switch type {
    case "ping":
        // Never launch the app just to answer a status check.
        if let reply = sendToApp(msg, timeout: 3), var info = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] {
            info["host"] = version
            writeMessage(info)
        } else {
            writeMessage(["ok": true, "running": false, "version": version, "host": version,
                          "ffmpeg": findTool("ffmpeg"), "ytdlp": findTool("yt-dlp")])
        }
    case "renewals":
        // Only ask a running app; never launch it just to check.
        if let reply = sendToApp(msg, timeout: 5), let info = try? JSONSerialization.jsonObject(with: reply) {
            writeMessage(info)
        } else {
            writeMessage(["ok": true, "items": []])
        }
    case "list", "remove", "renewFailed":
        // Bookkeeping only: never launch the app for these.
        if let reply = sendToApp(msg, timeout: 10), let info = try? JSONSerialization.jsonObject(with: reply) {
            writeMessage(info)
        } else {
            writeMessage(["ok": false, "error": "Castnet is not running"])
        }
    case "download", "downloadBatch", "formats", "show", "renew", "adopt":
        // Listing a site's qualities can take a while (the site is queried live).
        let wait = type == "formats" ? 100 : (type == "renew" ? 40 : 15)
        var reply = sendToApp(msg, timeout: wait)
        if reply == nil {
            if launchApp(background: type != "show") { reply = sendToApp(msg, timeout: wait) }
        }
        if let reply, let info = try? JSONSerialization.jsonObject(with: reply) {
            writeMessage(info)
        } else {
            writeMessage(["ok": false, "error": "Could not start or reach the Castnet app."])
        }
    default:
        writeMessage(["ok": false, "error": "unknown message type \(type)"])
    }
}
exit(0)
