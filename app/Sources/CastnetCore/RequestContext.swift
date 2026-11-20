import Foundation

/// Replays the browser's identity (headers, cookies, user agent, referer) on every
/// request the app makes, so CDNs that check them serve the same content.
public final class RequestContext {
    public let headers: [String: String]
    public let cookies: [CookieInfo]
    public let userAgent: String?
    public let referer: String?

    private static let skip: Set<String> = [
        "host", "connection", "content-length", "cookie", "range", "if-range", "accept-encoding",
        "proxy-authorization", "proxy-connection", "keep-alive", "te", "transfer-encoding", "upgrade",
    ]

    public init(request: DownloadRequest) {
        var h: [String: String] = [:]
        for (k, v) in request.headers ?? [:] where !Self.skip.contains(k.lowercased()) && !k.lowercased().hasPrefix("sec-") {
            h[k] = v
        }
        headers = h
        cookies = request.cookies ?? []
        userAgent = request.userAgent ?? h.first { $0.key.lowercased() == "user-agent" }?.value
        referer = request.referer ?? h.first { $0.key.lowercased() == "referer" }?.value
    }

    public init(headers: [String: String] = [:], cookies: [CookieInfo] = [], userAgent: String? = nil, referer: String? = nil) {
        self.headers = headers
        self.cookies = cookies
        self.userAgent = userAgent
        self.referer = referer
    }

    public func cookieHeader(for url: URL) -> String? {
        let parts = cookies.filter { $0.matches(url) }.map { "\($0.name)=\($0.value)" }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    public func makeRequest(_ url: URL, range: String? = nil, extra: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.httpShouldHandleCookies = false
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let ua = userAgent { r.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let ref = referer, r.value(forHTTPHeaderField: "Referer") == nil { r.setValue(ref, forHTTPHeaderField: "Referer") }
        if let c = cookieHeader(for: url) { r.setValue(c, forHTTPHeaderField: "Cookie") }
        if let range { r.setValue(range, forHTTPHeaderField: "Range") }
        for (k, v) in extra { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    public static func sessionConfiguration(maxConnectionsPerHost: Int) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = max(4, maxConnectionsPerHost)
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60 * 60 * 24
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.waitsForConnectivity = false
        return c
    }

    /// Simple GET returning the whole body (manifests, keys).
    public func fetch(_ url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: makeRequest(url))
        guard let http = resp as? HTTPURLResponse else { throw CastnetError.invalid("Not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw CastnetError.http(http.statusCode, url.absoluteString) }
        return (data, http)
    }
}
