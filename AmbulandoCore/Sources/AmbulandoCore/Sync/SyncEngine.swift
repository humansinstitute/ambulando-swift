import Foundation

/// `user` is an explicit user action (send, open a thread); `visible` refreshes the screen in view;
/// `background` is bulk catch-up and can never occupy the reserved foreground slot.
public enum SyncPriority: Int, Sendable, Comparable {
    case background = 0, visible = 1, user = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum SyncBackoff {
    /// 2 s, 4 s, 8 s … capped at 300 s, with ±20 % jitter (`random` in 0...1).
    public static func delay(failures: Int, random: Double) -> Duration {
        guard failures > 0 else { return .zero }
        let base = min(2.0 * pow(2.0, Double(failures - 1)), 300.0)
        return .milliseconds(Int((base * (0.8 + 0.4 * min(max(random, 0), 1))) * 1000))
    }
}

public struct SyncSnapshot: Sendable, Equatable {
    public var running: Set<String> = []
    /// Ready to run now.
    public var queued: Set<String> = []
    /// Waiting for a scheduled retry time; not shown as active syncing.
    public var scheduled: Set<String> = []
    public var errors: [String: String] = [:]
    public var isIdle: Bool { running.isEmpty && queued.isEmpty }

    public init(running: Set<String> = [], queued: Set<String> = [], scheduled: Set<String> = [], errors: [String: String] = [:]) {
        self.running = running; self.queued = queued; self.scheduled = scheduled; self.errors = errors
    }
}

/// The single owner of network refresh work (architecture board v7: "sole network/update owner").
///
/// - Keyed jobs coalesce: enqueueing a queued key replaces its work; enqueueing a running key schedules
///   exactly one rerun after it finishes, so changes that land mid-fetch are not lost.
/// - At most `maxConcurrent` jobs run; user and visible-screen work runs before catch-up, and
///   `reservedForeground` slots are never given to background jobs, so a send is not stuck behind a storm.
/// - Every job runs detached from the main actor and is cancellable (lock, workspace switch, BG expiry).
/// - Failures back off exponentially per key; `force` (user pull-to-refresh) bypasses the wait.
public actor SyncEngine {
    public typealias Work = @Sendable () async throws -> Void

    private struct Job { let key: String; var priority: SyncPriority; var work: Work; let sequence: UInt64 }

    public let maxConcurrent: Int
    public let reservedForeground: Int
    private let clock = ContinuousClock()
    private let random: @Sendable () -> Double
    private var queue: [Job] = []
    private var running: [String: Task<Void, Never>] = [:]
    private var runningPriority: [String: SyncPriority] = [:]
    private var reruns: [String: Job] = [:]
    private var failures: [String: Int] = [:]
    private var notBefore: [String: ContinuousClock.Instant] = [:]      // failure backoff
    private var delayedUntil: [String: ContinuousClock.Instant] = [:]   // requested delay (scheduled retry)
    private var errors: [String: String] = [:]
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var wakeTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<SyncSnapshot>.Continuation] = [:]

    public init(maxConcurrent: Int = 3, reservedForeground: Int = 1, random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.reservedForeground = min(max(0, reservedForeground), self.maxConcurrent - 1)
        self.random = random
    }

    public var snapshot: SyncSnapshot {
        let now = clock.now
        let waiting = Set(queue.map(\.key).filter { readyAt($0).map { $0 > now } ?? false })
        return SyncSnapshot(running: Set(running.keys), queued: Set(queue.map(\.key)).subtracting(waiting), scheduled: waiting, errors: errors)
    }

    public func statusStream() -> AsyncStream<SyncSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish() { let s = snapshot; for o in observers.values { o.yield(s) } }

    /// Adds or coalesces a keyed job. `delay` schedules it for later (an automatic retry); a delayed request never
    /// postpones one already pending without delay, and an immediate request cancels an earlier delay.
    public func enqueue(_ key: String, priority: SyncPriority = .background, force: Bool = false, delay: Duration? = nil,
                        _ work: @escaping Work) {
        sequence &+= 1
        let job = Job(key: key, priority: priority, work: work, sequence: sequence)
        if force { notBefore[key] = nil }
        let pendingImmediately = (reruns[key] != nil || queue.contains { $0.key == key }) && delayedUntil[key] == nil
        if let delay, !force {
            if !pendingImmediately {
                let at = clock.now + delay
                delayedUntil[key] = delayedUntil[key].map { min($0, at) } ?? at
            }
        } else {
            delayedUntil[key] = nil
        }
        if running[key] != nil {
            var rerun = job
            if let existing = reruns[key] { rerun.priority = max(existing.priority, priority) }
            reruns[key] = rerun
        } else if let index = queue.firstIndex(where: { $0.key == key }) {
            queue[index].work = work
            queue[index].priority = max(queue[index].priority, priority)
        } else {
            queue.append(job)
        }
        pump()
        publish()
    }

    private func readyAt(_ key: String) -> ContinuousClock.Instant? {
        switch (notBefore[key], delayedUntil[key]) {
        case (nil, nil): nil
        case (let a?, nil): a
        case (nil, let b?): b
        case (let a?, let b?): max(a, b)
        }
    }

    public func cancel(_ key: String) {
        queue.removeAll { $0.key == key }
        reruns[key] = nil
        delayedUntil[key] = nil
        running[key]?.cancel()
        publish()
        resumeIdleWaitersIfIdle()
    }

    /// Cancels every job whose key starts with `prefix` (for example all profile refreshes of a connection).
    public func cancel(prefix: String) {
        let keys = Set(queue.map(\.key)).union(reruns.keys).union(delayedUntil.keys).union(running.keys).filter { $0.hasPrefix(prefix) }
        for key in keys { cancel(key) }
    }

    /// Cancels everything (identity locked, workspace removed, background task expiring).
    public func cancelAll() {
        generation &+= 1
        queue.removeAll()
        reruns.removeAll()
        delayedUntil.removeAll()
        for task in running.values { task.cancel() }
        publish()
        resumeIdleWaitersIfIdle()
    }

    /// Returns when nothing is queued or running, or when the calling task is cancelled (BG expiration).
    public func waitUntilIdle() async {
        if queue.isEmpty && running.isEmpty { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled { c.resume(); return }
                idleWaiters[id] = c
            }
        } onCancel: {
            Task { await self.releaseIdleWaiter(id) }
        }
    }

    private func releaseIdleWaiter(_ id: UUID) { idleWaiters.removeValue(forKey: id)?.resume() }

    public func failureCount(_ key: String) -> Int { failures[key] ?? 0 }

    private func pump() {
        let now = clock.now
        while running.count < maxConcurrent {
            let backgroundRunning = runningPriority.values.filter { $0 == .background }.count
            let backgroundAllowed = backgroundRunning < maxConcurrent - reservedForeground
            let eligible = queue.indices.filter {
                (backgroundAllowed || queue[$0].priority > .background) && (readyAt(queue[$0].key).map { $0 <= now } ?? true)
            }
            guard let index = eligible.max(by: { a, b in
                (queue[a].priority, UInt64.max - queue[a].sequence) < (queue[b].priority, UInt64.max - queue[b].sequence)
            }) else { break }
            start(queue.remove(at: index))
        }
        scheduleWake(now: now)
    }

    private func start(_ job: Job) {
        let key = job.key, work = job.work, started = generation
        runningPriority[key] = job.priority
        delayedUntil[key] = nil
        running[key] = Task.detached(priority: job.priority > .background ? .userInitiated : .utility) { [weak self] in
            let interval = SyncSignposts.begin(key)
            var failure: Error?
            do { try await work() } catch { failure = error }
            SyncSignposts.end(interval)
            await self?.finish(key, error: failure, generation: started)
        }
    }

    private func finish(_ key: String, error: Error?, generation started: UInt64) {
        running[key] = nil
        runningPriority[key] = nil
        if let error, !(error is CancellationError), !Task.isCancelled, !((error as? URLError)?.code == .cancelled) {
            let count = (failures[key] ?? 0) + 1
            failures[key] = count
            notBefore[key] = clock.now + SyncBackoff.delay(failures: count, random: random())
            errors[key] = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        } else if error == nil {
            failures[key] = nil
            notBefore[key] = nil
            errors[key] = nil
        }
        if let rerun = reruns.removeValue(forKey: key), started == generation { queue.append(rerun) }
        pump()
        publish()
        resumeIdleWaitersIfIdle()
    }

    private func scheduleWake(now: ContinuousClock.Instant) {
        wakeTask?.cancel()
        wakeTask = nil
        guard running.count < maxConcurrent else { return }
        let waits = queue.compactMap { readyAt($0.key) }.filter { $0 > now }
        guard let next = waits.min() else { return }
        wakeTask = Task { [weak self] in
            try? await Task.sleep(until: next, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.wake()
        }
    }

    private func wake() { pump(); publish() }

    private func resumeIdleWaitersIfIdle() {
        guard queue.isEmpty, running.isEmpty else { return }
        let waiters = idleWaiters.values
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
