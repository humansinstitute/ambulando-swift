import Foundation

/// Lifetime is one WorkspaceSync, never a process-global freshness cache. Keys contain the full account,
/// connection and workspace boundary. Only navigation may reuse a baseline; reconciliation always dirties it.
actor InboxSnapshots {
    private var running: [String: Task<Void, Error>] = [:]
    private var dirty = Set<String>()
    private var baselines = Set<String>()
    private var gone: [String: ContinuousClock.Instant] = [:]
    static let goneLifetime: Duration = .seconds(600)

    /// View states can outlive their record. A record Tower says does not exist (404, or 400 resource-not-found; never a
    /// 403, which can be lifted) is not fetched again for a while, so leftovers do not use up the hydration budget that
    /// readable records need. Entries expire, and any access change for the workspace clears them.
    func isGone(_ resource: String) -> Bool {
        guard let until = gone[resource] else { return false }
        if ContinuousClock.now < until { return true }
        gone[resource] = nil
        return false
    }
    func markGone(_ resource: String) { gone[resource] = ContinuousClock.now + Self.goneLifetime }

    func refresh(_ key: String, reuseBaseline: Bool, work: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        if let task = running[key] {
            if !reuseBaseline { dirty.insert(key) }
            try await task.value
            try Task.checkCancellation()
            return
        }
        if reuseBaseline && baselines.contains(key) { return }
        let task = Task { try await self.run(key, work: work) }
        running[key] = task
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: { task.cancel() }
    }

    func isDirty(_ key: String) -> Bool { dirty.contains(key) }

    func invalidate(_ key: String) {
        baselines.remove(key)
        gone = gone.filter { !$0.key.hasPrefix(key + "/") }
        if running[key] != nil { dirty.insert(key) }
    }

    private func run(_ key: String, work: @escaping @Sendable () async throws -> Void) async throws {
        defer { running[key] = nil; dirty.remove(key) }
        do {
            repeat {
                dirty.remove(key)
                try Task.checkCancellation()
                try await work()
                try Task.checkCancellation()
            } while dirty.contains(key)
            baselines.insert(key)
        } catch {
            baselines.remove(key)
            throw error
        }
    }
}
