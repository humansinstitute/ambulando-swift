import Foundation

/// Event routes. Both are ordinary NIP-98 GETs over the exact URL (including the cursor query).
extension TowerAPI {
    public static let eventPageLimit = 200

    public struct EventPage: Sendable {
        public let events: [TowerEvent]
        /// Cursor to resume from after this page (Tower's `next_cursor`, else the last event's cursor).
        public let nextCursor: String?
        /// Rows Tower returned that this client could not parse; they still advance the cursor.
        public let skipped: Int
    }

    public static func eventsPath(_ workspaceId: String) throws -> String { try base(workspaceId) + "/events" }
    public static func streamPath(_ workspaceId: String) throws -> String { try base(workspaceId) + "/events/stream" }

    /// `GET /workspaces/:w/events?cursor=&limit=` — visible events with `row_version` above the cursor, oldest first.
    public func events(workspaceId: String, appNpub: String, cursor: String?, limit: Int = TowerAPI.eventPageLimit) async throws -> EventPage {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        if let cursor { query.insert(URLQueryItem(name: "cursor", value: cursor), at: 0) }
        let o = try object(try await client.request(path: try Self.eventsPath(workspaceId), query: query, appNpub: appNpub), "events")
        guard let rows = o["events"] as? [[String: Any]] else { throw TowerError.malformed("events") }
        let events = rows.compactMap(TowerEvent.init(json:))
        guard events.allSatisfy({ $0.workspaceId == workspaceId }) else { throw TowerError.malformed("events") }
        let next = (o["next_cursor"] as? String) ?? (rows.last?["cursor"] as? String) ?? cursor
        return EventPage(events: events, nextCursor: next, skipped: rows.count - events.count)
    }

    /// The workspace's current event high-water mark, from `GET /workspaces/:w/sync?limit=1` (`through_cursor`). Used
    /// to start live updates without replaying the whole event history; the local lists are then caught up directly.
    public func eventHead(workspaceId: String, appNpub: String) async throws -> String {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/sync", query: [URLQueryItem(name: "limit", value: "1")],
                                                    appNpub: appNpub), "sync")
        guard let through = o["through_cursor"] as? String, !through.isEmpty else { throw TowerError.malformed("sync cursor") }
        return through
    }

    /// Signed request for the event stream. NIP-98 is checked when the stream opens (Tower's 300 s window), so a
    /// fresh header is made for every connection attempt.
    public func streamRequest(workspaceId: String, appNpub: String, cursor: String?) async throws -> URLRequest {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        var request = try await client.signed(method: "GET", path: try Self.streamPath(workspaceId), query: query, appNpub: appNpub, jsonBody: nil)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90   // heartbeats arrive every 25 s
        return request
    }
}

/// Streaming seam for SSE. Production uses a delegate-based `URLSession` data task; tests feed chunks.
public protocol EventStreamTransport: Sendable {
    /// Opens the request and returns the response head with a stream of body chunks. Cancelling the consuming task
    /// (or terminating the stream) cancels the connection.
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

/// `URLSession` SSE transport: ephemeral, redirects refused, delegate callbacks on URLSession's own queue.
public final class URLSessionEventStreamTransport: NSObject, EventStreamTransport, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var heads: [Int: CheckedContinuation<HTTPURLResponse, Error>] = [:]
    private var bodies: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { _ in task.cancel() }
        lock.withLock { bodies[id] = continuation }
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.withLock { heads[id] = c }
                task.resume()
            }
        } onCancel: { task.cancel() }
        return (head, stream)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let head = lock.withLock { heads.removeValue(forKey: dataTask.taskIdentifier) }
        if let http = response as? HTTPURLResponse { head?.resume(returning: http) } else { head?.resume(throwing: TowerError.malformed("non-HTTP")) }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = lock.withLock { bodies[dataTask.taskIdentifier] }?.yield(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (head, body) = lock.withLock { (heads.removeValue(forKey: task.taskIdentifier), bodies.removeValue(forKey: task.taskIdentifier)) }
        head?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error { body?.finish(throwing: error) } else { body?.finish() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
