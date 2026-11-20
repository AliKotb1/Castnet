import Foundation
import AppKit
import SafariServices
import Darwin

/// Native side of Castnet's Safari web extension. Safari delivers `browser.runtime.sendNativeMessage`
/// calls here; this sandboxed extension forwards them to the Castnet app over the app's
/// loopback bridge (port + secret token in ~/Library/Application Support/Castnet/bridge.json,
/// readable through a narrow sandbox exception) and returns the app's reply.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = (item?.userInfo?[SFExtensionMessageKey] as? [String: Any]) ?? [:]
        DispatchQueue.global().async {
            let reply = Bridge.send(message)
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}

enum Bridge {
    /// The real home folder (inside the sandbox NSHomeDirectory() is the container).
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    static var infoFile: URL { URL(fileURLWithPath: realHome).appendingPathComponent("Library/Application Support/Castnet/bridge.json") }

    static func info() -> (port: UInt16, token: String)? {
        guard let data = try? Data(contentsOf: infoFile),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = o["port"] as? Int, let token = o["token"] as? String else { return nil }
        return (UInt16(port), token)
    }

    /// Castnet.app = this .appex's bundle → PlugIns → Contents → Castnet.app
    static var appURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func send(_ message: [String: Any]) -> [String: Any] {
        let type = message["type"] as? String ?? ""
        let timeout = type == "formats" ? 100 : (type == "renew" ? 45 : 15)
        if let r = attempt(message, timeout: timeout) { return r }
        // Not running: status checks just say so; real requests start the app first.
        if type == "ping" || type == "renewals" {
            return type == "ping" ? ["ok": true, "running": false, "version": "safari", "ytdlp": true, "ffmpeg": true] : ["ok": true, "items": []]
        }
        launchApp()
        for _ in 0..<60 {
            usleep(200_000)
            if let r = attempt(message, timeout: timeout) { return r }
        }
        return ["ok": false, "error": "Couldn’t start the Castnet app."]
    }

    static func launchApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let sema = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in sema.signal() }
        _ = sema.wait(timeout: .now() + 10)
    }

    static func attempt(_ message: [String: Any], timeout: Int) -> [String: Any]? {
        guard let (port, token) = info() else { return nil }
        var msg = message
        msg["token"] = token
        guard var payload = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
        payload.append(0x0A)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        guard sent == payload.count else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        guard let line = out.split(separator: 0x0A).first else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }
}
