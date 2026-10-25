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
    /// Called on the main actor after every successful load of the current query, including an unchanged first one.
    @ObservationIgnored public var onLoad: (@MainActor (Value) -> Void)?

    public init(initial: Value) { value = initial; self.initial = initial }

    /// `keepingValue` resumes a paused query: the rows on screen stay until the fresh read replaces them (no flash, no
    /// scroll jump). Use it only for the same query that was paused.
    public func start(store: LocalStore, keepingValue: Bool = false, matches: @escaping @Sendable (ChangeKey) -> Bool,
                      load: @escaping @Sendable () async throws -> Value) {
        start(changes: store.changes, keepingValue: keepingValue, matches: matches, load: load)
    }

    public func start(changes coalescer: ChangeCoalescer, keepingValue: Bool = false, matches: @escaping @Sendable (ChangeKey) -> Bool,
                      load: @escaping @Sendable () async throws -> Value) {
        generation &+= 1
        let current = generation
        if !keepingValue {
            value = initial
            loaded = false
            error = nil
        }
        handle.replace(Task { [weak self] in
            let changes = await coalescer.stream()
            await self?.reload(load, generation: current)
            for await batch in changes {
                guard !Task.isCancelled else { return }
                if batch.contains(where: matches) { await self?.reload(load, generation: current) }
            }
        })
    }

    /// Stops reloading but keeps the current rows (a screen that is out of sight; resume with `keepingValue`).
    public func pause() {
        generation &+= 1
        handle.replace(nil)
    }

    /// Stops reloading and returns to the initial value, so rows of a workspace that is no longer shown never render.
    public func stop() {
        generation &+= 1
        handle.replace(nil)
        if value != initial { value = initial }
        if loaded { loaded = false }
        if error != nil { error = nil }
    }

    private func reload(_ load: @escaping @Sendable () async throws -> Value, generation started: UInt64) async {
        // The read and the equality check both run off the main actor (a snapshot of a busy channel compares
        // hundreds of rows); the main actor only assigns a value that actually changed.
        let result = await Self.fetch(load, previous: value)
        // The query may have been restarted or stopped while the read was in flight.
        guard started == generation, !Task.isCancelled else { return }
        switch result {
        case .success(let next):
            if let next { value = next }   // unchanged results never invalidate the view
            if error != nil { error = nil }
            if !loaded { loaded = true }
            onLoad?(value)
            return
        case .failure(let failure):
            let message = failure.localizedDescription
            if error != message { error = message }
        }
        // Observation notifies on every assignment, so state that is already current is not assigned again.
        if !loaded { loaded = true }
    }

    /// Loads and compares on the global concurrent executor. Returns nil when the result equals `previous`.
    @concurrent
    nonisolated private static func fetch(_ load: @Sendable () async throws -> Value, previous: Value) async -> Result<Value?, Error> {
        do {
            let next = try await load()
            return .success(next == previous ? nil : next)
        } catch { return .failure(error) }
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
