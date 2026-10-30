import Foundation

private enum WorkspaceLeaseContext {
    @TaskLocal static var leases: [UUID: UInt64] = [:]
}

/// A generation fence shared by a workspace's scheduler, HTTP reads/writes and live subscription.
/// Pausing invalidates every outstanding lease before invoking cancellation, so a late result cannot start work.
public final class WorkspaceActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let contextId = UUID()
    private var active: Bool
    private var generation: UInt64 = 0
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    public init(enabled: Bool = true) { active = enabled }
    public var isEnabled: Bool { lock.withLock { active } }

    public func lease() throws -> UInt64 {
        try lock.withLock {
            guard active, WorkspaceLeaseContext.leases[contextId].map({ $0 == generation }) ?? true else { throw CancellationError() }
            return generation
        }
    }

    public func check(_ lease: UInt64) throws {
        try lock.withLock {
            guard active, lease == generation else { throw CancellationError() }
        }
    }

    public func check() throws { _ = try lease() }

    /// A storage mutation fence: cached network results inherit a lease, while local draft/navigation edits may
    /// deliberately continue without one during pause. Durable acknowledgement/reconciliation writes use their
    /// own explicitly reviewed path, since a server-accepted outcome must not be forgotten.
    public func checkInheritedLease() throws {
        guard let lease = WorkspaceLeaseContext.leases[contextId] else { return }
        try check(lease)
    }

    /// Preserve the originating generation across actor calls and inherited child tasks. A late callback must not
    /// acquire a fresh lease merely because the user has already re-enabled this workspace.
    public func withLease<T: Sendable>(_ lease: UInt64, checkingResult: Bool = true, _ operation: @Sendable () async throws -> T) async throws -> T {
        try check(lease)
        var leases = WorkspaceLeaseContext.leases
        if let inherited = leases[contextId], inherited != lease { throw CancellationError() }
        leases[contextId] = lease
        return try await WorkspaceLeaseContext.$leases.withValue(leases) {
            try check(lease)
            let result = try await operation()
            if checkingResult { try check(lease) }
            return result
        }
    }

    public func pause() {
        let pending = lock.withLock {
            active = false
            generation &+= 1
            let pending = Array(cancellations.values)
            cancellations.removeAll()
            return pending
        }
        for cancel in pending { cancel() }
    }

    public func resume() {
        lock.withLock {
            guard !active else { return }
            generation &+= 1
            active = true
        }
    }

    fileprivate func register(_ lease: UInt64, cancel: @escaping @Sendable () -> Void) -> UUID? {
        let id = UUID()
        let accepted = lock.withLock {
            guard active, lease == generation else { return false }
            cancellations[id] = cancel
            return true
        }
        if !accepted { cancel() }
        return accepted ? id : nil
    }

    fileprivate func remove(_ id: UUID?) {
        if let id { _ = lock.withLock { cancellations.removeValue(forKey: id) } }
    }
}

/// Enforces the workspace pause contract even for native commands outside a queued refresh.
/// A write's frozen request remains durable when cancellation makes its outcome ambiguous.
public struct WorkspaceHTTPTransport: HTTPTransport {
    public let base: any HTTPTransport
    public let activity: WorkspaceActivity
    public init(base: any HTTPTransport, activity: WorkspaceActivity) { self.base = base; self.activity = activity }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let lease = try activity.lease(), base = self.base, activity = self.activity
        let task = Task {
            try await activity.withLease(lease) {
                try Task.checkCancellation()
                return try await base.send(request)
            }
        }
        let id = activity.register(lease, cancel: { task.cancel() })
        defer { activity.remove(id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try activity.check(lease)
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }
}

/// A stream opener and its body retain the same generation lease until explicitly closed.
public struct WorkspaceEventStreamTransport: EventStreamTransport {
    public let base: any EventStreamTransport
    public let activity: WorkspaceActivity
    public init(base: any EventStreamTransport, activity: WorkspaceActivity) { self.base = base; self.activity = activity }

    public func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks) {
        try Task.checkCancellation()
        let lease = try activity.lease(), base = self.base, activity = self.activity
        let task = Task {
            try await activity.withLease(lease, checkingResult: false) {
                try Task.checkCancellation()
                return try await base.open(request)
            }
        }
        let opening = activity.register(lease, cancel: { task.cancel() })
        defer { activity.remove(opening) }
        let (response, chunks) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        let reading = activity.register(lease, cancel: chunks.cancel)
        do { try activity.check(lease); try Task.checkCancellation() }
        catch { chunks.cancel(); activity.remove(reading); throw error }
        let iterator = WorkspaceChunkIterator(chunks.makeAsyncIterator())
        return (response, EventChunks(next: {
            try activity.check(lease)
            let result = try await iterator.next()
            try activity.check(lease)
            try Task.checkCancellation()
            return result
        }, cancel: {
            chunks.cancel()
            activity.remove(reading)
        }))
    }
}

private actor WorkspaceChunkIterator {
    private var iterator: EventChunks.AsyncIterator
    init(_ iterator: EventChunks.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> Data? {
        var current = iterator
        let next = try await current.next(isolation: self)
        iterator = current
        return next
    }
}
