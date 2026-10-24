import AmbulandoCore
import Foundation
import Observation

/// A store-backed value for one screen, the native equivalent of Dexie `liveQuery`.
///
/// It loads from the local database immediately, then reloads only when a coalesced change batch
/// (≤ 10 Hz) touches a matching key. Reads run on the store's reader actor; the main actor only
/// assigns the finished `Sendable` value, so sync bursts never block typing, scrolling or navigation.
@MainActor
@Observable
final class LiveQuery<Value: Sendable & Equatable> {
    private(set) var value: Value
    private(set) var loaded = false
    private(set) var error: String?
    @ObservationIgnored private let handle = TaskHandle()

    init(initial: Value) { value = initial }

    func start(store: LocalStore, matches: @escaping @Sendable (ChangeKey) -> Bool, load: @escaping @Sendable () async throws -> Value) {
        handle.replace(Task { [weak self] in
            let changes = await store.changes.stream()
            await self?.reload(load)
            for await batch in changes {
                guard !Task.isCancelled else { return }
                if batch.contains(where: matches) { await self?.reload(load) }
            }
        })
    }

    func stop() { handle.replace(nil) }

    private func reload(_ load: @Sendable () async throws -> Value) async {
        do {
            let next = try await load()
            if next != value { value = next }   // unchanged results never invalidate the view
            error = nil
        } catch {
            self.error = error.localizedDescription
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
