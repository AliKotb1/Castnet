import Foundation
import Darwin

/// Newline-delimited JSON over a Unix domain socket that only the current user can open (0600).
/// Unlike a localhost WebSocket, web pages can't reach it.
public final class IPCServer {
    public typealias Handler = (_ message: [String: Any], _ raw: Data) async -> [String: Any]

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "castnet.ipc", attributes: .concurrent)

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        // Never take the socket away from a running Castnet.
        if FileManager.default.fileExists(atPath: path),
           IPCClient.send(Data(#"{"type":"ping"}"#.utf8), to: path, timeout: 2) != nil {
            throw CastnetError.process("Another copy of Castnet is already running")
        }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CastnetError.process("socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw CastnetError.process("Socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        umask(old)
        guard rc == 0 else { close(fd); throw CastnetError.process("bind(\(path)) failed: \(errno)") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw CastnetError.process("listen failed: \(errno)") }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        queue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buffer.count < 64 << 20 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if buffer.last == 0x0A { break }
        }
        guard let line = buffer.split(separator: 0x0A).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            respond(client, ["ok": false, "error": "bad request"])
            return
        }
        let sema = DispatchSemaphore(value: 0)
        var reply: [String: Any] = [:]
        Task {
            reply = await self.handler(obj, Data(line))
            sema.signal()
        }
        sema.wait()
        respond(client, reply)
    }

    private func respond(_ client: Int32, _ obj: [String: Any]) {
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":false}".utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(client, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
        close(client)
    }
}

/// Client side, used by castnet-host and the CLI.
public enum IPCClient {
    public static func send(_ line: Data, to path: String, timeout: Int = 15) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
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
        if payload.last != 0x0A { payload.append(0x0A) }
        let ok = payload.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard ok else { return nil }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            out.append(chunk, count: n)
        }
        return out.split(separator: 0x0A).first.map { Data($0) }
    }
}

/// Loopback TCP bridge for the Safari extension, whose sandbox can't reach the Unix socket.
/// Every request must carry a random token that only the current user can read
/// (~/Library/Application Support/Castnet/bridge.json, mode 0600).
public final class TCPBridgeServer {
    private let handler: IPCServer.Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "castnet.bridge", attributes: .concurrent)
    public private(set) var port: UInt16 = 0
    private let token: String = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()

    public static var infoFile: URL { Paths.support.appendingPathComponent("bridge.json") }

    public init(handler: @escaping IPCServer.Handler) { self.handler = handler }
    deinit { stop() }

    public func start() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CastnetError.process("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }) == 0,
              listen(fd, 16) == 0 else { close(fd); throw CastnetError.process("bridge bind failed") }
        var bound = sockaddr_in()
        var blen = len
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) } }
        port = UInt16(bigEndian: bound.sin_port)
        let info = try JSONSerialization.data(withJSONObject: ["port": Int(port), "token": token])
        let old = umask(0o077)
        try info.write(to: Self.infoFile, options: .atomic)
        umask(old)
        chmod(Self.infoFile.path, 0o600)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        try? FileManager.default.removeItem(at: Self.infoFile)
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        queue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buffer.count < 8 << 20 {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            if buffer.last == 0x0A { break }
        }
        var reply: [String: Any] = ["ok": false, "error": "unauthorized"]
        if let line = buffer.split(separator: 0x0A).first,
           var obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
           let t = obj["token"] as? String, Self.equal(t, token) {
            obj.removeValue(forKey: "token")
            let sema = DispatchSemaphore(value: 0)
            let message = obj
            Task {
                reply = await self.handler(message, Data(line))
                sema.signal()
            }
            sema.wait()
        }
        var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in _ = write(client, raw.baseAddress!, raw.count) }
        close(client)
    }

    /// Constant-time comparison so the token can't be guessed byte by byte.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
