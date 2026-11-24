import Foundation
import XCTest
@testable import AmbulandoCore

private actor InboxLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

private struct HeldInbox: HTTPTransport {
    let base: StubTransport
    let entered: InboxLatch
    let release: InboxLatch
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url!.path.hasSuffix("/resource-view-states") {
            await entered.release()
            await release.wait() // Deliberately ignores cancellation, like a late network completion.
            return (Data("{\"states\":[],\"has_more\":false}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return try await base.send(request)
    }
}

final class InboxSnapshotLifetimeTests: XCTestCase {
    func testIncompletePageCannotEstablishNavigationBaseline() async throws {
        let h = try await WorkHarness.make()
        defer { try? FileManager.default.removeItem(at: h.chat.directory) }
        let transport = StubTransport { request in
            if request.url!.path.hasSuffix("/resource-view-states") { return (200, ["states": [], "has_more": true]) }
            return try h.transport.handlerResult(request)
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        for _ in 0..<2 {
            do { try await sync.synchronizeInbox(h.connection, h.workspace, reuseBaseline: true); XCTFail("incomplete page") }
            catch TowerError.malformed { }
        }
        XCTAssertEqual(transport.recorded.filter { $0.url!.path.hasSuffix("/resource-view-states") }.count, 2)
    }

    func testCancelledOrPausedSnapshotCannotDeleteCacheAfterImmediateResume() async throws {
        for pause in [false, true] {
            let h = try await WorkHarness.make(), activity = WorkspaceActivity()
            defer { try? FileManager.default.removeItem(at: h.chat.directory) }
            await h.store.writer.bindWorkspaceActivity(activity)
            let engine = SyncEngine(parent: h.engine, namespace: "snapshot-lifetime", activity: activity)
            let entered = InboxLatch(), release = InboxLatch()
            let sync = WorkspaceSync(store: h.store, engine: engine, identity: h.chat.identity,
                transport: HeldInbox(base: h.transport, entered: entered, release: release))
            try await h.store.writer.upsertViewStates(workspaceId: h.workspace.id, [.init(workspaceId: h.workspace.id,
                resourceType: .task, resourceId: "cached", scopeId: nil, channelId: Fixtures.channel1,
                activityVersion: 9, viewedActivityVersion: 8, updatedAt: "today")])
            await sync.refreshInbox(h.connection, h.workspace)
            await entered.wait()
            if pause { await engine.pause(); await engine.resume() }
            else { await engine.cancel(WorkspaceSync.inboxKey(h.workspace.id)) }
            await release.release()
            await h.engine.waitUntilIdle()
            let rows = try await h.store.reader.viewStates(workspaceId: h.workspace.id)
            XCTAssertEqual(rows.map(\.resourceId), ["cached"])
            XCTAssertEqual(rows.first?.viewedActivityVersion, 8)
            // A cancelled snapshot cannot establish a reusable navigation baseline.
            try await sync.synchronizeInbox(h.connection, h.workspace, reuseBaseline: true)
            let repaired = try await h.store.reader.viewStates(workspaceId: h.workspace.id)
            XCTAssertTrue(repaired.isEmpty)
        }
    }

    /// Leftover view states of removed records answer 400/resource-not-found. They must not use up the hydration
    /// budget (nor be asked again), or the readable record behind them never reaches the Inbox.
    func testGoneViewStatesDoNotStarveReadableRecordsOrRepeat() async throws {
        let h = try await WorkHarness.make()
        defer { try? FileManager.default.removeItem(at: h.chat.directory) }
        let ghosts = (0..<WorkspaceSync.inboxHydrationLimit + 10).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        for ghost in ghosts { h.work.seedViewState(type: "task", resource: ghost, scope: Fixtures.scopeA, channel: Fixtures.channel1, activity: 3, viewed: 1) }
        let real = h.work.seedTask(id: "ffffffff-0000-4000-8000-000000000001", scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Readable")
        h.work.seedViewState(type: "task", resource: real, scope: Fixtures.scopeA, channel: Fixtures.channel1, activity: 3, viewed: 1)
        let gone = Set(ghosts)
        let transport = StubTransport { request in
            if let id = request.url?.pathComponents.last, gone.contains(id), request.url!.path.contains("/tasks/") { return (400, ["code": "resource-not-found"]) }
            return try h.transport.handlerResult(request)
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        try await sync.synchronizeInbox(h.connection, h.workspace)
        let hydrated = try await h.store.reader.task(workspaceId: h.workspace.id, id: real)
        XCTAssertEqual(hydrated?.title, "Readable")
        let first = transport.recorded.filter { $0.url!.path.contains("/tasks/") }.count
        try await sync.synchronizeInbox(h.connection, h.workspace)
        XCTAssertEqual(transport.recorded.filter { $0.url!.path.contains("/tasks/") }.count, first, "gone records are not asked for again")
    }

    /// A 403 is never remembered, and a remembered "does not exist" is dropped when access changes: a conversation
    /// that becomes readable later still reaches the Inbox.
    func testRegainedAccessHydratesPreviouslyRefusedRecords() async throws {
        final class Mode: @unchecked Sendable {
            private let lock = NSLock(); private var value = 403
            var status: Int { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
        }
        for first in [403, 400] {
            let h = try await WorkHarness.make()
            defer { try? FileManager.default.removeItem(at: h.chat.directory) }
            let hidden = h.work.seedTask(id: "00000000-0000-4000-8000-000000000001", scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Hidden")
            h.work.seedViewState(type: "task", resource: hidden, scope: Fixtures.scopeA, channel: Fixtures.channel1, activity: 3, viewed: 1)
            let mode = Mode(); mode.status = first
            let transport = StubTransport { request in
                if request.url!.path.hasSuffix("/tasks/" + hidden), mode.status != 200 {
                    return (mode.status, ["code": mode.status == 403 ? "permission_denied" : "resource-not-found"])
                }
                return try h.transport.handlerResult(request)
            }
            let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
            try await sync.synchronizeInbox(h.connection, h.workspace)
            let before = try await h.store.reader.task(workspaceId: h.workspace.id, id: hidden)
            XCTAssertNil(before)
            mode.status = 200
            if first == 400 {
                // Remembered as missing: stays quiet until access is re-verified.
                try await sync.synchronizeInbox(h.connection, h.workspace)
                let still = try await h.store.reader.task(workspaceId: h.workspace.id, id: hidden)
                XCTAssertNil(still)
                await sync.accessEpochChanged(h.connection, h.workspace)
            }
            try await sync.synchronizeInbox(h.connection, h.workspace)
            let after = try await h.store.reader.task(workspaceId: h.workspace.id, id: hidden)
            XCTAssertEqual(after?.title, "Hidden", "first answer \(first)")
        }
    }
}
