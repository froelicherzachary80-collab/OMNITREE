import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let fromCache: Bool
    public init(status: Int, body: Data, fromCache: Bool = false) { self.status = status; self.body = body; self.fromCache = fromCache }
}

public enum HTTPError: Error, CustomStringConvertible {
    case status(Int, String)
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case invalidURL(String)

    public var description: String {
        switch self {
        case .status(let c, let u): return "HTTP \(c) from \(u)"
        case .rateLimited(let r): return "Rate limited\(r.map { " — retry after \(Int($0))s" } ?? "")"
        case .offline: return "Offline mode: network research is disabled"
        case .invalidURL(let u): return "Invalid URL \(u)"
        }
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// Identifies the app to free public APIs, as required by Wikimedia's User-Agent policy.
public enum UserAgent {
    public static let value = "MultiverseTree/0.1 (iOS; open-source research app; https://github.com/froelicherzachary80-collab/OMNITREE)"
}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if status == 429 {
                    let retry = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                    cont.resume(throwing: HTTPError.rateLimited(retryAfter: retry)); return
                }
                cont.resume(returning: HTTPResponse(status: status, body: data ?? Data()))
            }.resume()
        }
    }
}

/// Enforces a minimum interval between requests per host — every connector respects the
/// source's published rate limits rather than bursting.
public actor RateLimiter {
    private var nextAllowed: [String: Date] = [:]
    private let intervals: [String: TimeInterval]
    private let defaultInterval: TimeInterval

    public init(intervals: [String: TimeInterval] = ["query.wikidata.org": 1.0, "www.wikidata.org": 0.25,
                                                      "en.wikipedia.org": 0.25, "www.googleapis.com": 0.2],
                defaultInterval: TimeInterval = 0.5) {
        self.intervals = intervals
        self.defaultInterval = defaultInterval
    }

    public func wait(for host: String) async {
        let now = Date()
        let slot = max(now, nextAllowed[host] ?? now)
        nextAllowed[host] = slot.addingTimeInterval(intervals[host] ?? defaultInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}

/// HTTP layer used by all connectors: rate limiting, SQLite-backed response cache, offline mode.
public final class ResearchHTTP: @unchecked Sendable {
    public let client: HTTPClient
    public let store: GraphStore?
    public let limiter: RateLimiter
    public var offline: Bool
    public var cacheTTL: TimeInterval
    /// Count of network requests actually made (for the source-availability dashboard).
    public private(set) var requestCount = 0
    private let lock = NSLock()

    public init(client: HTTPClient = URLSessionHTTPClient(), store: GraphStore? = nil, limiter: RateLimiter = RateLimiter(),
                offline: Bool = false, cacheTTL: TimeInterval = 7 * 24 * 3600) {
        self.client = client; self.store = store; self.limiter = limiter; self.offline = offline; self.cacheTTL = cacheTTL
    }

    /// `cacheKey` lets callers strip secrets (API keys) from the cache key.
    public func get(_ url: URL, headers: [String: String] = [:], cacheKey: String? = nil) async throws -> HTTPResponse {
        let key = cacheKey ?? url.absoluteString
        if let store, let body = try? store.cached(key) { return HTTPResponse(status: 200, body: body, fromCache: true) }
        if offline { throw HTTPError.offline }
        await limiter.wait(for: url.host ?? "")
        lock.withLock { requestCount += 1 }
        let response = try await client.get(url, headers: headers)
        guard (200..<300).contains(response.status) else { throw HTTPError.status(response.status, url.host ?? "") }
        try? store?.cache(key, body: response.body, ttl: cacheTTL)
        return response
    }

    public func getJSON(_ url: URL, headers: [String: String] = [:], cacheKey: String? = nil) async throws -> Any {
        let r = try await get(url, headers: headers, cacheKey: cacheKey)
        return try JSONSerialization.jsonObject(with: r.body)
    }
}

extension URL {
    static func build(_ base: String, _ query: [String: String]) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw HTTPError.invalidURL(base) }
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // '+' must be encoded explicitly for SPARQL bodies.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw HTTPError.invalidURL(base) }
        return url
    }
}
