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

/// Body chunks of one event-stream connection, pulled on demand (so a bounded buffer stays bounded). `cancel` closes
/// the connection; the reader calls it when it stops reading for any reason.
public struct EventChunks: AsyncSequence, Sendable {
    public typealias Element = Data
    private let pull: @Sendable () async throws -> Data?
    public let cancel: @Sendable () -> Void

    public init(next: @escaping @Sendable () async throws -> Data?, cancel: @escaping @Sendable () -> Void) { pull = next; self.cancel = cancel }

    /// Wraps a stream (tests and the sample-data stand-in).
    public init(_ stream: AsyncThrowingStream<Data, Error>) {
        let box = IteratorBox(stream.makeAsyncIterator())
        self.init(next: { try await box.next() }, cancel: { box.cancel() })
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let pull: @Sendable () async throws -> Data?
        public mutating func next() async throws -> Data? { try await pull() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(pull: pull) }
}

private actor IteratorBox {
    var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator?
    init(_ iterator: AsyncThrowingStream<Data, Error>.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> Data? {
        guard var it = iterator else { return nil }
        let value = try await it.next(isolation: self)
        iterator = value == nil ? nil : it
        return value
    }
    nonisolated func cancel() { Task { await self.drop() } }
    private func drop() { iterator = nil }
}

/// Streaming seam for SSE. Production uses a delegate-based `URLSession` data task; tests feed chunks.
public protocol EventStreamTransport: Sendable {
    /// Opens the request and returns the response head with the body chunks.
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks)
}

/// Bounded hand-off between URLSession's delegate queue and the stream reader. Bytes count against `limit` until the
/// reader takes them; if a slow reader lets more than `limit` accumulate, the buffer fails with `overflow` instead of
/// dropping bytes, so the stream reconnects from the last durably stored cursor and nothing is silently skipped.
public final class BoundedChunkBuffer: @unchecked Sendable {
    public enum Failure: Error, Equatable { case overflow }

    public let limit: Int
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var buffered = 0
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Data?, Error>?

    public init(limit: Int) { self.limit = limit }

    public var bufferedBytes: Int { lock.withLock { buffered } }

    /// Producer side. Returns false once the buffer has failed or finished (the producer should cancel its task).
    @discardableResult
    public func append(_ data: Data) -> Bool {
        let (resume, ok): (CheckedContinuation<Data?, Error>?, Bool) = lock.withLock {
            guard !finished, failure == nil else { return (nil, false) }
            if let waiter { self.waiter = nil; return (waiter, true) }
            guard buffered + data.count <= limit else {
                failure = Failure.overflow
                chunks.removeAll()
                buffered = 0
                return (nil, false)
            }
            chunks.append(data)
            buffered += data.count
            return (nil, true)
        }
        resume?.resume(returning: data)
        return ok
    }

    public func finish(throwing error: Error? = nil) {
        let resume: CheckedContinuation<Data?, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            if let error, failure == nil { failure = error }
            defer { waiter = nil }
            return waiter
        }
        guard let resume else { return }
        let (pendingFailure, hasChunks) = lock.withLock { (failure, !chunks.isEmpty) }
        if hasChunks { resume.resume(returning: lock.withLock { () -> Data? in buffered -= chunks[0].count; return chunks.removeFirst() }) }
        else if let pendingFailure { resume.resume(throwing: pendingFailure) }
        else { resume.resume(returning: nil) }
    }

    /// Consumer side: the next chunk, nil at the end, or the failure (an overflow is reported as soon as it happens).
    public func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            let action: () -> Void = lock.withLock {
                if let failure, chunks.isEmpty || failure as? Failure == .overflow { return { c.resume(throwing: failure) } }
                if !chunks.isEmpty {
                    let chunk = chunks.removeFirst()
                    buffered -= chunk.count
                    return { c.resume(returning: chunk) }
                }
                if finished { return { c.resume(returning: nil) } }
                waiter = c
                return {}
            }
            action()
        }
    }

}

/// `URLSession` SSE transport: ephemeral, redirects refused, delegate callbacks on URLSession's own queue, and a
/// bounded receive buffer per connection (`bufferLimit`).
public final class URLSessionEventStreamTransport: NSObject, EventStreamTransport, URLSessionDataDelegate, @unchecked Sendable {
    public static let defaultBufferLimit = 2 * 1024 * 1024

    private let lock = NSLock()
    private var session: URLSession!
    private let bufferLimit: Int
    private var heads: [Int: CheckedContinuation<HTTPURLResponse, Error>] = [:]
    private var bodies: [Int: BoundedChunkBuffer] = [:]

    public init(bufferLimit: Int = URLSessionEventStreamTransport.defaultBufferLimit) {
        self.bufferLimit = bufferLimit
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks) {
        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        let buffer = BoundedChunkBuffer(limit: bufferLimit)
        lock.withLock { bodies[id] = buffer }
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.withLock { heads[id] = c }
                task.resume()
            }
        } onCancel: { task.cancel() }
        let chunks = EventChunks(next: {
            try await withTaskCancellationHandler { try await buffer.next() } onCancel: {
                task.cancel()
                buffer.finish(throwing: CancellationError())
            }
        }, cancel: {
            task.cancel()
            buffer.finish(throwing: CancellationError())
        })
        return (head, chunks)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let head = lock.withLock { heads.removeValue(forKey: dataTask.taskIdentifier) }
        if let http = response as? HTTPURLResponse { head?.resume(returning: http) } else { head?.resume(throwing: TowerError.malformed("non-HTTP")) }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let buffer = lock.withLock({ bodies[dataTask.taskIdentifier] }) else { return }
        if !buffer.append(data) { dataTask.cancel() }   // overflow: fail the stream, reconnect from the stored cursor
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (head, body) = lock.withLock { (heads.removeValue(forKey: task.taskIdentifier), bodies.removeValue(forKey: task.taskIdentifier)) }
        head?.resume(throwing: error ?? URLError(.badServerResponse))
        body?.finish(throwing: error)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
