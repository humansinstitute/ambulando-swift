import Foundation

/// Merges store change keys and delivers them to observers at most once per `interval`.
/// A burst of thousands of writes becomes a handful of UI refreshes, bounding main-thread invalidation.
public actor ChangeCoalescer {
    private let interval: Duration
    private var pending = Set<ChangeKey>()
    private var flushScheduled = false
    private var observers: [UUID: AsyncStream<Set<ChangeKey>>.Continuation] = [:]

    public init(interval: Duration = .milliseconds(100)) { self.interval = interval }

    public func record(_ keys: Set<ChangeKey>) {
        guard !keys.isEmpty else { return }
        pending.formUnion(keys)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [interval] in
            try? await Task.sleep(for: interval)
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        for continuation in observers.values { continuation.yield(batch) }
    }

    /// A stream of coalesced change sets. Batches are never dropped (a filtering observer must not miss
    /// its key); emission is already rate-limited, so the buffer stays small.
    public func stream() -> AsyncStream<Set<ChangeKey>> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Set<ChangeKey>>.makeStream(bufferingPolicy: .unbounded)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }

    private func remove(_ id: UUID) { observers[id] = nil }

    public var observerCount: Int { observers.count }
}
