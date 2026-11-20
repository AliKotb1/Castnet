import Foundation
import Network

/// Token-bucket speed limiter. `global` caps all downloads together; each download can
/// also have its own. 0 = unlimited.
public final class RateLimiter {
    public static let global = RateLimiter()
    private let lock = NSLock()
    private var rate: Double = 0
    private var tokens: Double = 0
    private var last = Date()

    public init(bytesPerSecond: Double = 0) { rate = bytesPerSecond }

    public var bytesPerSecond: Double {
        get { lock.lock(); defer { lock.unlock() }; return rate }
        set { lock.lock(); rate = max(0, newValue); tokens = min(tokens, rate); lock.unlock() }
    }

    /// Records `n` received bytes; returns how long the receiver should pause to stay under the limit.
    public func consume(_ n: Int) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard rate > 0 else { return 0 }
        let now = Date()
        tokens = min(rate * 0.5, tokens + now.timeIntervalSince(last) * rate)
        last = now
        tokens -= Double(n)
        return tokens >= 0 ? 0 : min(5, -tokens / rate)
    }
}

/// Watches connectivity so downloads can wait out network drops instead of failing.
public final class NetworkWatcher {
    public static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var waiters: [() -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.online = path.status == .satisfied
            let run = self.online ? self.waiters : []
            if self.online { self.waiters.removeAll() }
            self.lock.unlock()
            run.forEach { $0() }
        }
        monitor.start(queue: DispatchQueue(label: "castnet.network"))
    }

    public var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    /// Runs `block` as soon as the network is back (immediately if it already is).
    public func whenOnline(_ block: @escaping () -> Void) {
        lock.lock()
        if online { lock.unlock(); block(); return }
        waiters.append(block)
        lock.unlock()
    }
}

extension Error {
    /// Transient connectivity problems: worth waiting for, never a reason to give up.
    var isNetworkFailure: Bool {
        guard let u = self as? URLError else { return false }
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
             .cannotLoadFromNetwork, .resourceUnavailable, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }
}

/// HTTP statuses that mean "this address no longer works" (expired or revoked signed URL).
func isLinkError(_ code: Int) -> Bool { [400, 401, 403, 404, 410, 498].contains(code) }
