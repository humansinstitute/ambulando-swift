import Foundation
import Observation

/// A store-backed value for one screen, the native equivalent of Dexie `liveQuery`.
///
/// It loads from the local database immediately, then reloads only when a coalesced change batch
/// (≤ 10 Hz) touches a matching key. Reads run on the store's reader actor; the main actor only
/// assigns the finished `Sendable` value, so sync bursts never block typing, scrolling or navigation.
///
/// Every `start` gets a new generation. A load that finishes after its query was replaced or stopped
/// (for example a slow read for the previous workspace) is discarded, including its error and
/// `loaded` state, so stale rows can never overwrite the current query.
@MainActor
@Observable
public final class LiveQuery<Value: Sendable & Equatable> {
    public private(set) var value: Value
    public private(set) var loaded = false
    public private(set) var error: String?
    @ObservationIgnored private let handle = TaskHandle()
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let initial: Value

    public init(initial: Value) { value = initial; self.initial = initial }

    public func start(store: LocalStore, matches: @escaping @Sendable (ChangeKey) -> Bool, load: @escaping @Sendable () async throws -> Value) {
        start(changes: store.changes, matches: matches, load: load)
    }

    public func start(changes coalescer: ChangeCoalescer, matches: @escaping @Sendable (ChangeKey) -> Bool,
                      load: @escaping @Sendable () async throws -> Value) {
        generation &+= 1
        let current = generation
        value = initial
        loaded = false
        error = nil
        handle.replace(Task { [weak self] in
            let changes = await coalescer.stream()
            await self?.reload(load, generation: current)
            for await batch in changes {
                guard !Task.isCancelled else { return }
                if batch.contains(where: matches) { await self?.reload(load, generation: current) }
            }
        })
    }

    public func stop() {
        generation &+= 1
        handle.replace(nil)
    }

    private func reload(_ load: @Sendable () async throws -> Value, generation started: UInt64) async {
        let result: Result<Value, Error>
        do { result = .success(try await load()) } catch { result = .failure(error) }
        // The query may have been restarted or stopped while the read was in flight.
        guard started == generation, !Task.isCancelled else { return }
        switch result {
        case .success(let next):
            if next != value { value = next }   // unchanged results never invalidate the view
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
        loaded = true
    }

    deinit { handle.replace(nil) }
}

/// Holds a cancellable task so a non-isolated deinit can cancel it.
final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func replace(_ next: Task<Void, Never>?) {
        let previous = lock.withLock { () -> Task<Void, Never>? in let p = task; task = next; return p }
        previous?.cancel()
    }
}
