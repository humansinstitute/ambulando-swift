import Foundation
import XCTest
@testable import AmbulandoCore

private actor SchedulerGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

private struct LateHTTP: HTTPTransport {
    let entered: SchedulerGate
    let release: SchedulerGate
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await entered.release()
        await release.wait() // Deliberately ignores cancellation: a late network completion.
        return (Data("late".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class SchedulerStreams: EventStreamTransport, @unchecked Sendable {
    let lock = NSLock()
    private var stopped: Set<String> = []
    var cancelled: Set<String> { lock.withLock { stopped } }
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks) {
        let host = request.url!.host!
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                EventChunks(next: { Data("data: \(host)\n\n".utf8) }, cancel: { [self] in _ = lock.withLock { stopped.insert(host) } }))
    }
}

private struct LateStream: EventStreamTransport {
    let entered: SchedulerGate
    let release: SchedulerGate
    let cancelled: SchedulerGate
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks) {
        await entered.release(); await release.wait()
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                EventChunks(next: { Data() }, cancel: { Task { await cancelled.release() } }))
    }
}

final class WorkspaceSchedulerTests: XCTestCase {
    func testIdenticalKeysAcrossBoundariesDoNotCoalesce() async {
        let pool = SyncEngine(maxConcurrent: 2, reservedForeground: 0)
        let one = SyncEngine(parent: pool, namespace: "origin-one/identity/app/workspace")
        let two = SyncEngine(parent: pool, namespace: "origin-two/identity/app/workspace")
        let first = SchedulerGate(), second = SchedulerGate(), release = SchedulerGate()
        await one.enqueue("events:same") { await first.release(); await release.wait() }
        await two.enqueue("events:same") { await second.release(); await release.wait() }
        await first.wait(); await second.wait()
        let state = await pool.snapshot
        XCTAssertEqual(state.running.count, 2)
        let local = await one.snapshot
        XCTAssertEqual(local.running, ["events:same"])
        await release.release()
        await pool.waitUntilIdle()
    }

    func testPauseCancelsOnlyOwnQueueAndRejectsLateAndNewWork() async {
        let pool = SyncEngine(maxConcurrent: 1, reservedForeground: 0)
        let one = SyncEngine(parent: pool, namespace: "one"), two = SyncEngine(parent: pool, namespace: "two")
        let entered = SchedulerGate(), release = SchedulerGate(), counter = Counter()
        await one.enqueue("events:w", retries: 3) {
            await entered.release(); await release.wait()
            // An in-flight read returns after pause and tries to enqueue follow-up work.
            await one.enqueue("scopes:w") { await counter.enter("late") }
            throw URLError(.timedOut)
        }
        await entered.wait()
        await one.enqueue("retry:w", delay: .milliseconds(20)) { await counter.enter("delayed") }
        await two.enqueue("events:w") { await counter.enter("other") }
        await one.pause()
        await one.enqueue("new:w", force: true) { await counter.enter("new") }
        await release.release()
        await pool.waitUntilIdle()
        let order = await counter.order
        XCTAssertEqual(order, ["other"])
        let state = await one.snapshot
        XCTAssertTrue(state.scheduled.isEmpty)
        XCTAssertTrue(state.errors.isEmpty)
        await one.resume()
        await one.enqueue("events:w", force: true) { await counter.enter("resumed") }
        await pool.waitUntilIdle()
        let resumed = await counter.order
        XCTAssertEqual(resumed, ["other", "resumed"])
    }

    func testCancelKeyDoesNotRescheduleAnIgnoringCancellationFailure() async {
        let engine = SyncEngine(maxConcurrent: 1)
        let entered = SchedulerGate(), release = SchedulerGate(), counter = Counter()
        await engine.enqueue("read:w", retries: 3) {
            await counter.enter()
            await entered.release(); await release.wait()
            throw URLError(.networkConnectionLost)
        }
        await entered.wait()
        await engine.cancel("read:w")
        await release.release()
        await engine.waitUntilIdle()
        let state = await engine.snapshot
        XCTAssertTrue(state.scheduled.isEmpty)
        XCTAssertTrue(state.connectionFailures.isEmpty)
        let total = await counter.total
        XCTAssertEqual(total, 1)
    }

    func testUnstructuredCallbackRetainsOriginalLeaseAfterImmediateReenable() async {
        let pool = SyncEngine(), activity = WorkspaceActivity()
        let engine = SyncEngine(parent: pool, namespace: "one", activity: activity)
        let callbackCreated = SchedulerGate(), callbackRelease = SchedulerGate(), callbackFinished = SchedulerGate()
        let counter = Counter()
        await engine.enqueue("read:w") {
            // Unstructured tasks do not inherit cancellation, but must inherit the workspace generation.
            Task {
                await callbackCreated.release(); await callbackRelease.wait()
                await engine.enqueue("followup:w", force: true) { await counter.enter("unsafe followup") }
                do { _ = try activity.lease(); await counter.enter("unsafe fresh lease") } catch { }
                await callbackFinished.release()
            }
        }
        await callbackCreated.wait()
        await engine.pause(); await engine.resume()
        await callbackRelease.release(); await callbackFinished.wait()
        await pool.waitUntilIdle()
        let unsafe = await counter.total
        XCTAssertEqual(unsafe, 0)
        await engine.enqueue("fresh:w") { await counter.enter("new user action") }
        await pool.waitUntilIdle()
        let new = await counter.order
        XCTAssertEqual(new, ["new user action"])
    }

    func testFairnessLetsAnotherTowerPassALargeSamePriorityBacklog() async {
        let pool = SyncEngine(maxConcurrent: 1, reservedForeground: 0)
        let one = SyncEngine(parent: pool, namespace: "one"), two = SyncEngine(parent: pool, namespace: "two")
        let entered = SchedulerGate(), release = SchedulerGate(), counter = Counter()
        await pool.enqueue("blocker") { await entered.release(); await release.wait() }
        await entered.wait()
        for i in 0..<30 { await one.enqueue("history:\(i)") { await counter.enter("one\(i)") } }
        await two.enqueue("history:same") { await counter.enter("two") }
        await release.release()
        await pool.waitUntilIdle()
        let order = await counter.order
        XCTAssertEqual(order.count, 31)
        XCTAssertLessThanOrEqual(order.firstIndex(of: "two") ?? .max, 1, "A new Tower gets a turn within one boundary round")
    }

    func testForegroundCapacityIsReservedAcrossWorkspaceFacades() async {
        let pool = SyncEngine(maxConcurrent: 3, reservedForeground: 1)
        let one = SyncEngine(parent: pool, namespace: "one"), two = SyncEngine(parent: pool, namespace: "two")
        let enteredOne = SchedulerGate(), enteredTwo = SchedulerGate(), release = SchedulerGate(), sent = SchedulerGate()
        await one.enqueue("history:1") { await enteredOne.release(); await release.wait() }
        await two.enqueue("history:1") { await enteredTwo.release(); await release.wait() }
        await enteredOne.wait(); await enteredTwo.wait()
        await one.enqueue("history:2") { await release.wait() }
        await two.enqueue("send:1", priority: .user) { await sent.release(); await release.wait() }
        await sent.wait()
        let state = await pool.snapshot
        XCTAssertEqual(state.running.count, 3)
        XCTAssertEqual(state.queued.count, 1)
        await release.release()
        await pool.waitUntilIdle()
    }

    func testSlowVisibleTowerCannotOccupyAllPoolSlots() async {
        let pool = SyncEngine(maxConcurrent: 3, reservedForeground: 1)
        let slow = SyncEngine(parent: pool, namespace: "slow-workspace-one", connectionNamespace: "slow-tower")
        let slowOtherWorkspace = SyncEngine(parent: pool, namespace: "slow-workspace-two", connectionNamespace: "slow-tower")
        let healthy = SyncEngine(parent: pool, namespace: "healthy", connectionNamespace: "healthy-tower")
        let first = SchedulerGate(), second = SchedulerGate(), responsive = SchedulerGate(), release = SchedulerGate()
        await slow.enqueue("visible:1", priority: .visible) { await first.release(); await release.wait() }
        await slowOtherWorkspace.enqueue("visible:2", priority: .visible) { await second.release(); await release.wait() }
        await first.wait(); await second.wait()
        await slow.enqueue("visible:3", priority: .visible) { await release.wait() }
        await healthy.enqueue("history:1") { await responsive.release(); await release.wait() }
        await responsive.wait()
        let state = await pool.snapshot
        XCTAssertEqual(state.running.count, 3)
        XCTAssertEqual(state.queued.count, 1)
        await release.release(); await pool.waitUntilIdle()
    }

    func testSlowTowerCannotOccupyAllBackgroundCapacityAcrossItsWorkspaces() async {
        let pool = SyncEngine(maxConcurrent: 3, reservedForeground: 1)
        let slow = SyncEngine(parent: pool, namespace: "slow-one", connectionNamespace: "slow")
        let slowOther = SyncEngine(parent: pool, namespace: "slow-two", connectionNamespace: "slow")
        let healthy = SyncEngine(parent: pool, namespace: "healthy", connectionNamespace: "healthy")
        let entered = SchedulerGate(), responsive = SchedulerGate(), release = SchedulerGate()
        await slow.enqueue("history:1") { await entered.release(); await release.wait() }
        await entered.wait()
        await slowOther.enqueue("history:1") { await release.wait() }
        await healthy.enqueue("history:1") { await responsive.release(); await release.wait() }
        await responsive.wait()
        let state = await pool.snapshot
        XCTAssertEqual(state.running.count, 2)
        XCTAssertEqual(state.queued.count, 1)
        await release.release(); await pool.waitUntilIdle()
    }

    func testTransportPauseRejectsLateResultEvenAfterResume() async throws {
        let activity = WorkspaceActivity()
        let entered = SchedulerGate(), release = SchedulerGate()
        let transport = WorkspaceHTTPTransport(base: LateHTTP(entered: entered, release: release), activity: activity)
        let request = URLRequest(url: URL(string: "https://tower.example/api/v4/read")!)
        let task = Task { try await transport.send(request) }
        await entered.wait()
        activity.pause(); activity.resume()
        await release.release()
        do { _ = try await task.value; XCTFail("A pre-pause completion must never be accepted on resume") }
        catch is CancellationError { }
        let lease = try activity.lease()
        activity.pause()
        XCTAssertThrowsError(try activity.check(lease))
        XCTAssertThrowsError(try activity.check())
    }

    func testPausedPerformReturnsCancellationRatherThanHanging() async {
        let pool = SyncEngine()
        let engine = SyncEngine(parent: pool, namespace: "one")
        await engine.pause()
        do { let _: String = try await engine.perform("send:w") { "sent" }; XCTFail("Paused work ran") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
    }

    func testPauseReleasesRunningPerformWaiterBeforeNoncancellableWorkReturns() async {
        let pool = SyncEngine(), engine = SyncEngine(parent: pool, namespace: "one")
        let entered = SchedulerGate(), release = SchedulerGate()
        let work = Task {
            try await engine.perform("send:w") {
                await entered.release(); await release.wait()
                return "late acknowledgement"
            }
        }
        await entered.wait()
        let fallback = Task { try? await Task.sleep(for: .seconds(1)); await release.release() }
        let started = ContinuousClock.now
        await engine.pause()
        do { _ = try await work.value; XCTFail("Paused perform returned a late success") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected \(error)") }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))
        fallback.cancel()
        await release.release(); await pool.waitUntilIdle()
    }

    func testPausingOneStreamLeavesOtherTowerLive() async throws {
        let base = SchedulerStreams(), one = WorkspaceActivity(), two = WorkspaceActivity()
        let first = WorkspaceEventStreamTransport(base: base, activity: one)
        let second = WorkspaceEventStreamTransport(base: base, activity: two)
        let (_, chunksOne) = try await first.open(URLRequest(url: URL(string: "https://one.example/events")!))
        let (_, chunksTwo) = try await second.open(URLRequest(url: URL(string: "https://two.example/events")!))
        one.pause()
        XCTAssertEqual(base.cancelled, ["one.example"])
        var iteratorOne = chunksOne.makeAsyncIterator(), iteratorTwo = chunksTwo.makeAsyncIterator()
        do { _ = try await iteratorOne.next(); XCTFail("Paused stream delivered data") }
        catch is CancellationError { }
        let live = try await iteratorTwo.next()
        XCTAssertEqual(live, Data("data: two.example\n\n".utf8))
        chunksOne.cancel(); chunksTwo.cancel()
    }

    func testLateStreamOpenIsClosedAndCannotSurvivePauseResume() async throws {
        let entered = SchedulerGate(), release = SchedulerGate(), cancelled = SchedulerGate(), activity = WorkspaceActivity()
        let transport = WorkspaceEventStreamTransport(base: LateStream(entered: entered, release: release, cancelled: cancelled), activity: activity)
        let request = URLRequest(url: URL(string: "https://tower.example/events")!)
        let task = Task { try await transport.open(request) }
        await entered.wait()
        activity.pause(); activity.resume()
        await release.release()
        do { _ = try await task.value; XCTFail("Late open survived its generation") }
        catch is CancellationError { }
        await cancelled.wait()
    }
}
