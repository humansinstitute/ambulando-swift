import Foundation

/// `user` is an explicit user action (send, open a thread); `visible` refreshes the screen in view;
/// `background` is bulk catch-up and can never occupy the reserved foreground slot.
public enum SyncPriority: Int, Sendable, Comparable {
    case background = 0, visible = 1, user = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What the engine did about a failing job, for the local diagnostics log. `key` is the job family (the part before
/// the first colon), never a workspace or record identifier.
public struct SyncEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case retryScheduled(attempt: Int, of: Int, delayMs: Int), retriesExhausted, recovered(afterFailures: Int) }
    public let family: String
    public let kind: Kind
}

public enum SyncBackoff {
    /// Automatic reruns after a transient read failure: 2 s, 4 s, 8 s (±20 %), then wait for a foreground, network-return or manual retry.
    public static let readRetries = 3

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
    /// Latest failure per key, excluding connection failures (`connectionFailures`): those are shown as one simple
    /// connection status, never as a raw transport message.
    public var errors: [String: String] = [:]
    /// Keys whose latest failure was transient (timeout, dropped or missing network, gateway unavailable) and not yet recovered.
    public var connectionFailures: Set<String> = []
    /// Keys waiting for an automatic retry after a transient failure (a subset of `scheduled`/`queued`).
    public var retrying: Set<String> = []
    public var isIdle: Bool { running.isEmpty && queued.isEmpty }

    public init(running: Set<String> = [], queued: Set<String> = [], scheduled: Set<String> = [], errors: [String: String] = [:],
                connectionFailures: Set<String> = [], retrying: Set<String> = []) {
        self.running = running; self.queued = queued; self.scheduled = scheduled; self.errors = errors
        self.connectionFailures = connectionFailures; self.retrying = retrying
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

    private struct Job {
        let key: String; var priority: SyncPriority; var work: Work; let sequence: UInt64
        /// Automatic retries left after a transient failure; reads only (a write is never replayed by the engine).
        var retries = 0
        var attempt = 0
        /// Called when the job is removed without running (cancelled, or replaced by a newer job of its key).
        var dropped: (@Sendable () -> Void)? = nil
    }

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
    private var connectionFailures: Set<String> = []
    private var onEvent: (@Sendable (SyncEvent) -> Void)?
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
        return SyncSnapshot(running: Set(running.keys), queued: Set(queue.map(\.key)).subtracting(waiting), scheduled: waiting, errors: errors,
                            connectionFailures: connectionFailures, retrying: Set(queue.filter { $0.attempt > 0 }.map(\.key)))
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

    /// Receives retry and recovery events (diagnostics). Not called for jobs without `retries`.
    public func setEventHandler(_ handler: (@Sendable (SyncEvent) -> Void)?) { onEvent = handler }

    /// A fresh result for `key` arrived by another path (a live event refetched the same data): its connection failure is obsolete.
    public func clearConnectionFailure(_ key: String) {
        guard connectionFailures.remove(key) != nil else { return }
        errors[key] = nil
        failures[key] = nil
        notBefore[key] = nil
        publish()
    }

    /// Adds or coalesces a keyed job. `delay` schedules it for later (an automatic retry); a delayed request never
    /// postpones one already pending without delay, and an immediate request cancels an earlier delay.
    /// `retries` is the number of automatic, backed-off reruns after a transient connection failure (a timeout, a dropped
    /// or missing network, a 502/503/504). Only for idempotent reads: each rerun calls `work` again, so it signs afresh.
    public func enqueue(_ key: String, priority: SyncPriority = .background, force: Bool = false, delay: Duration? = nil,
                        retries: Int = 0, _ work: @escaping Work) {
        enqueue(key, priority: priority, force: force, delay: delay, retries: retries, work: work, dropped: nil)
    }

    private func enqueue(_ key: String, priority: SyncPriority, force: Bool, delay: Duration?, retries: Int = 0, work: @escaping Work,
                         dropped: (@Sendable () -> Void)?) {
        sequence &+= 1
        var job = Job(key: key, priority: priority, work: work, sequence: sequence, dropped: dropped)
        job.retries = max(0, retries)
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
            if let existing = reruns[key] { rerun.priority = max(existing.priority, priority); rerun.retries = max(existing.retries, retries); existing.dropped?() }
            reruns[key] = rerun
        } else if let index = queue.firstIndex(where: { $0.key == key }) {
            queue[index].dropped?()
            queue[index].work = work
            queue[index].dropped = dropped
            queue[index].priority = max(queue[index].priority, priority)
            queue[index].retries = max(queue[index].retries, retries)
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
        for job in queue where job.key == key { job.dropped?() }
        queue.removeAll { $0.key == key }
        reruns.removeValue(forKey: key)?.dropped?()
        delayedUntil[key] = nil
        if connectionFailures.remove(key) != nil { errors[key] = nil }
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
        for job in queue { job.dropped?() }
        for job in reruns.values { job.dropped?() }
        queue.removeAll()
        reruns.removeAll()
        delayedUntil.removeAll()
        for key in connectionFailures { errors[key] = nil }
        connectionFailures.removeAll()
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

    /// Runs one job under the engine's slots and priorities and returns its result. The job's own error is returned
    /// to the caller rather than recorded (no backoff for the key). A job removed before it ran (cancel, `cancelAll`)
    /// or a cancelled caller ends with `CancellationError`, so a waiter is never left hanging.
    public nonisolated func perform<T: Sendable>(_ key: String, priority: SyncPriority = .user,
                                                 _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = OneShot<T>()
        return try await withTaskCancellationHandler {
            await enqueue(key, priority: priority, force: true, delay: nil, retries: 0, work: {
                do { result.resume(.success(try await work())) } catch { result.resume(.failure(error)) }
            }, dropped: { result.resume(.failure(CancellationError())) })
            return try await result.value()
        } onCancel: {
            result.resume(.failure(CancellationError()))
            Task { await self.cancel(key) }
        }
    }

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
            await self?.finish(job, error: failure, generation: started)
        }
    }

    private func finish(_ job: Job, error: Error?, generation started: UInt64) {
        let key = job.key
        running[key] = nil
        runningPriority[key] = nil
        let family = key.split(separator: ":").first.map(String.init) ?? key
        var retry: Job?
        if let error, !(error is CancellationError), !Task.isCancelled, !((error as? URLError)?.code == .cancelled) {
            let count = (failures[key] ?? 0) + 1
            failures[key] = count
            let wait = SyncBackoff.delay(failures: count, random: random())
            notBefore[key] = clock.now + wait
            if ConnectionFailure.isTransient(error) {
                connectionFailures.insert(key)
                errors[key] = nil
                // Retried only while this generation is current, nothing newer is already waiting for the key, and budget remains.
                // The automatic budget is per outage: once a key has failed this many times in a row, later forced attempts (probe,
                // foreground, network return, Retry) run once each instead of starting another retry sequence.
                if job.retries > 0, count <= SyncBackoff.readRetries + 1, started == generation, reruns[key] == nil, !queue.contains(where: { $0.key == key }) {
                    var next = job
                    next.retries -= 1; next.attempt += 1
                    sequence &+= 1
                    retry = next
                    onEvent?(SyncEvent(family: family, kind: .retryScheduled(attempt: next.attempt, of: next.attempt + next.retries,
                                                                            delayMs: Int(wait.components.seconds * 1000 + wait.components.attoseconds / 1_000_000_000_000_000))))
                } else if job.retries == 0, job.attempt > 0 {
                    onEvent?(SyncEvent(family: family, kind: .retriesExhausted))
                }
            } else {
                connectionFailures.remove(key)
                errors[key] = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        } else if error == nil {
            if job.attempt > 0 || connectionFailures.contains(key) { onEvent?(SyncEvent(family: family, kind: .recovered(afterFailures: failures[key] ?? 0))) }
            failures[key] = nil
            notBefore[key] = nil
            errors[key] = nil
            connectionFailures.remove(key)
        }
        if let rerun = reruns.removeValue(forKey: key) {
            if started == generation { queue.append(rerun) } else { rerun.dropped?() }
        } else if let retry {
            queue.append(retry)
        }
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

/// A result delivered once, whether it arrives before or after someone waits for it.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func resume(_ value: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard case .none = result else { return nil }
            result = value
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: value)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                waiter = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }
    }
}
