import Foundation

public enum TransferError: LocalizedError, Equatable, Sendable {
    case unsafeURL, failed(status: Int?, reason: String?), lost

    public var errorDescription: String? {
        switch self {
        case .unsafeURL: "Refused a transfer URL that is not a presigned HTTPS object-store address."
        case .failed(let status, let reason):
            "The transfer failed" + (status.map { " (HTTP \($0))" } ?? "") + (reason.map { ": \($0)" } ?? "") + "."
        case .lost: "The system no longer has this transfer; it will be started again."
        }
    }
}

/// System transfer seam. Production uses a background `URLSession`; tests drive completions by hand.
public protocol TransferBackend: AnyObject, Sendable {
    /// Called by the backend when a task ends: description, HTTP status, error text, and for downloads the file the
    /// backend moved the body to (inside the transfers directory).
    func setCompletionHandler(_ handler: @escaping @Sendable (String, Int?, String?, URL?) -> Void)
    func startUpload(_ request: URLRequest, file: URL, description: String)
    func startDownload(_ request: URLRequest, description: String)
    /// Descriptions of tasks the system still holds (including ones started before a relaunch).
    func activeDescriptions() async -> Set<String>
}

/// Durable coordinator for transfers to and from presigned object-store URLs.
///
/// - Only **unsigned** requests to a host other than the Tower origin are accepted: the NIP-98 identity, cookies and
///   any Authorization header never reach an object store. Tower's own signed storage routes stay in-process.
/// - Each transfer has a stable key (the storage object id for uploads) persisted with its state, so a transfer that
///   finishes while the app is suspended or after it was terminated is picked up by the next attempt instead of being
///   repeated. Prepare and complete stay with the caller (`TowerAPI.store`), which commits only after Tower verifies
///   size and hash.
/// - Waiting is cancellable without cancelling the system transfer (lock, background expiry).
public actor BackgroundTransfers {
    public struct Record: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case upload, download }
        public enum State: String, Codable, Sendable { case running, succeeded, failed }
        public let key: String
        public let kind: Kind
        public let url: String
        public var state: State
        public var status: Int?
        public var reason: String?
        public var resultFile: String?
        public let createdAt: Date
    }

    public let directory: URL
    private let backend: TransferBackend
    private var records: [String: Record] = [:]
    private var waiters: [String: [UUID: CheckedContinuation<Record, Error>]] = [:]
    private var indexURL: URL { directory.appendingPathComponent("transfers.json") }

    public init(directory: URL, backend: TransferBackend) {
        self.directory = directory
        self.backend = backend
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("transfers.json")),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) { records = saved }
    }

    /// Connects backend callbacks. Call once at launch, before the background session delivers pending events.
    public func activate() {
        backend.setCompletionHandler { [weak self] key, status, reason, file in
            Task { await self?.finished(key: key, status: status, reason: reason, file: file) }
        }
    }

    public func record(_ key: String) -> Record? { records[key] }
    public var all: [Record] { Array(records.values) }

    static func safeName(_ key: String) -> String { key.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression) }

    /// Accepts only presigned HTTPS URLs on a host other than the pinned Tower host.
    static func validate(_ url: URL, towerHost: String?) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host?.lowercased(), !host.isEmpty, host != towerHost?.lowercased(), !url.path.hasPrefix("/api/v4/") else {
            throw TransferError.unsafeURL
        }
    }

    static func unsignedRequest(_ url: URL, method: String, contentType: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// Uploads `bytes` with an unsigned PUT and returns when the object store accepted them.
    public func upload(key: String, url: URL, bytes: Data, contentType: String, towerHost: String?) async throws {
        try Self.validate(url, towerHost: towerHost)
        if let done = try await settled(key) { _ = done; return }
        let active = await backend.activeDescriptions()
        if records[key]?.state != .running || !active.contains(key) {
            let file = directory.appendingPathComponent(Self.safeName(key) + ".upload")
            try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            records[key] = Record(key: key, kind: .upload, url: url.absoluteString, state: .running, status: nil, reason: nil, resultFile: nil, createdAt: Date())
            save()
            backend.startUpload(Self.unsignedRequest(url, method: "PUT", contentType: contentType), file: file, description: key)
        }
        _ = try await wait(key)
        _ = try await settled(key)
    }

    /// Downloads with an unsigned GET and returns the downloaded file (inside `directory`). Call `forget` once the
    /// caller has verified and moved it.
    public func download(key: String, url: URL, towerHost: String?) async throws -> URL {
        try Self.validate(url, towerHost: towerHost)
        if let done = try await settled(key, keepResult: true), let file = done.resultFile { return directory.appendingPathComponent(file) }
        let active = await backend.activeDescriptions()
        if records[key]?.state != .running || !active.contains(key) {
            records[key] = Record(key: key, kind: .download, url: url.absoluteString, state: .running, status: nil, reason: nil, resultFile: nil, createdAt: Date())
            save()
            backend.startDownload(Self.unsignedRequest(url, method: "GET", contentType: nil), description: key)
        }
        _ = try await wait(key)
        guard let done = try await settled(key, keepResult: true), let file = done.resultFile else { throw TransferError.lost }
        return directory.appendingPathComponent(file)
    }

    /// Returns a finished record (removing it unless `keepResult`), throws for a failed one, nil while running/absent.
    private func settled(_ key: String, keepResult: Bool = false) async throws -> Record? {
        guard let record = records[key] else { return nil }
        switch record.state {
        case .running: return nil
        case .succeeded:
            if !keepResult { forget(key) }
            return record
        case .failed:
            forget(key)
            throw TransferError.failed(status: record.status, reason: record.reason)
        }
    }

    private func wait(_ key: String) async throws -> Record {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Record, Error>) in
                if let record = records[key], record.state != .running { c.resume(returning: record); return }
                waiters[key, default: [:]][id] = c
            }
        } onCancel: {
            Task { await self.cancelWait(key, id) }
        }
    }

    private func cancelWait(_ key: String, _ id: UUID) {
        waiters[key]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Backend completion (also after a relaunch, when the background session delivers events for earlier tasks).
    func finished(key: String, status: Int?, reason: String?, file: URL?) {
        guard var record = records[key] else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        let ok = reason == nil && status.map { (200..<300).contains($0) } == true && (record.kind == .upload || file != nil)
        record.state = ok ? .succeeded : .failed
        record.status = status
        record.reason = ok ? nil : (reason ?? "status \(status.map(String.init) ?? "none")")
        record.resultFile = ok ? file?.lastPathComponent : nil
        if !ok, let file { try? FileManager.default.removeItem(at: file) }
        if record.kind == .upload { try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.safeName(key) + ".upload")) }
        records[key] = record
        save()
        for (_, waiter) in waiters.removeValue(forKey: key) ?? [:] { waiter.resume(returning: record) }
    }

    /// At launch: a running record whose task the system no longer has (and that never reported) is marked lost, so
    /// the next attempt starts it again.
    public func recover() async {
        let active = await backend.activeDescriptions()
        var changed = false
        for (key, record) in records where record.state == .running && !active.contains(key) {
            var lost = record
            lost.state = .failed
            lost.reason = "lost"
            records[key] = lost
            changed = true
            for (_, waiter) in waiters.removeValue(forKey: key) ?? [:] { waiter.resume(returning: lost) }
        }
        if changed { save() }
    }

    public func forget(_ key: String) {
        guard let record = records.removeValue(forKey: key) else { return }
        if let file = record.resultFile { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Background `URLSession` backend. Tasks continue while the app is suspended; after termination iOS relaunches the app
/// in the background to deliver results (`handleEventsForBackgroundURLSession`).
public final class URLSessionTransferBackend: NSObject, TransferBackend, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let identifier = "studio.otherstuff.ambulando.native.transfers"

    private let lock = NSLock()
    private let directory: URL
    private var session: URLSession!
    private var handler: (@Sendable (String, Int?, String?, URL?) -> Void)?
    private var downloaded: [Int: URL] = [:]
    private var eventsCompletion: (() -> Void)?
    /// The session finished delivering events before the app handed over the system's completion handler.
    private var eventsFinishedEarly = false

    public init(directory: URL, identifier: String = URLSessionTransferBackend.identifier) {
        self.directory = directory
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func setCompletionHandler(_ handler: @escaping @Sendable (String, Int?, String?, URL?) -> Void) { lock.withLock { self.handler = handler } }

    /// Stores the system's completion handler from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func setEventsCompletion(_ completion: @escaping () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if eventsFinishedEarly { eventsFinishedEarly = false; return true }
            eventsCompletion = completion
            return false
        }
        if runNow { DispatchQueue.main.async(execute: completion) }
    }

    public func startUpload(_ request: URLRequest, file: URL, description: String) {
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil, "object-store transfers are never signed")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
    }

    public func startDownload(_ request: URLRequest, description: String) {
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil, "object-store transfers are never signed")
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        task.resume()
    }

    public func activeDescriptions() async -> Set<String> {
        Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so the body is moved now.
        guard let key = downloadTask.taskDescription else { return }
        let target = directory.appendingPathComponent(BackgroundTransfers.safeName(key) + ".download")
        try? FileManager.default.removeItem(at: target)
        if (try? FileManager.default.moveItem(at: location, to: target)) != nil {
            lock.withLock { downloaded[downloadTask.taskIdentifier] = target }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let (file, handler) = lock.withLock { (downloaded.removeValue(forKey: task.taskIdentifier), self.handler) }
        handler?(key, status, error.map { ($0 as NSError).localizedDescription }, file)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in
            defer { eventsCompletion = nil }
            if eventsCompletion == nil { eventsFinishedEarly = true }
            return eventsCompletion
        }
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
}
