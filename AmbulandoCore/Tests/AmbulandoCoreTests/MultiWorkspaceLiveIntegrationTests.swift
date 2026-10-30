import Foundation
import XCTest
@testable import AmbulandoCore

/// Local Tower/SSE fixtures exercising the production stream -> scheduler -> event plan -> SQLite path.
/// These tests do not establish live-device or real multi-Tower validation.
final class MultiWorkspaceLiveIntegrationTests: XCTestCase {
    private final class OpenStream: EventStreamTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        private var opens = 0
        var openedCount: Int { lock.withLock { opens } }

        func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks) {
            let pair = AsyncThrowingStream<Data, Error>.makeStream()
            lock.withLock { continuation = pair.continuation; opens += 1 }
            pair.continuation.yield(Data("event: connected\ndata: {}\n\n".utf8))
            let chunks = EventChunks(pair.stream)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    EventChunks(next: { try await chunks.makeAsyncIterator().nextValue() }, cancel: {
                        pair.continuation.finish(); chunks.cancel()
                    }))
        }

        func event(_ raw: [String: Any]) {
            let target = lock.withLock { continuation }
            target?.yield(Data(LiveStreamTests.frame(raw).utf8))
        }

        func revokeAccess() {
            let target = lock.withLock { continuation }
            target?.yield(Data("event: flightdeck_pg.error\ndata: workspace_access_revoked\n\n".utf8))
        }
    }

    private struct Lane {
        let connection: ConnectionRecord
        let workspace: WorkspaceRecord
        let store: LocalStore
        let tower: FakeEventTower
        let http: StubTransport
        let events: OpenStream
        let activity: WorkspaceActivity
        let engine: SyncEngine
        let sync: WorkspaceSync
        let stream: LiveStream
    }

    private func lane(connection: ConnectionRecord, workspaceId: String, pool: WorkspaceStorePool,
                      shared: SyncEngine, identity: IdentityService) async throws -> Lane {
        let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(workspaceId, label: connection.origin + workspaceId)))
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        let store = try await pool.store(connection: connection, workspace: workspace)
        try await store.writer.saveEventCursor(connectionId: connection.id, workspaceId: workspace.id, FakeEventTower.cursor(0))
        let tower = FakeEventTower(), activity = WorkspaceActivity(), events = OpenStream()
        let handler = tower.handler()
        let http = StubTransport { request in
            // FakeEventTower's legacy test helper has one hard-coded workspace route. Rewrite the fixture route
            // only; production signs/sends the original per-workspace request to this injected seam.
            var fixtureRequest = request
            if workspaceId != Fixtures.workspaceId {
                fixtureRequest.url = URL(string: request.url!.absoluteString.replacingOccurrences(of: workspaceId, with: Fixtures.workspaceId))
            }
            return try handler(fixtureRequest)
        }
        let engine = SyncEngine(parent: shared, namespace: boundary.id, activity: activity)
        let sync = WorkspaceSync(store: store, engine: engine, identity: identity,
            transport: WorkspaceHTTPTransport(base: http, activity: activity), boundary: boundary)
        let stream = LiveStream(sync: sync, transport: WorkspaceEventStreamTransport(base: events, activity: activity),
            idleTimeout: .seconds(20), batchWindow: .milliseconds(10), reconciliationInterval: .seconds(30), random: { 0 })
        return Lane(connection: connection, workspace: workspace, store: store, tower: tower, http: http,
                    events: events, activity: activity, engine: engine, sync: sync, stream: stream)
    }

    private func emit(_ lane: Lane, taskId: String, title: String, version: Int) {
        var task = FakeEventTower.task(taskId, title: title, version: version)
        task["workspace_id"] = lane.workspace.id
        lane.tower.lock.withLock { lane.tower.tasks[taskId] = task }
        lane.tower.emit("task", id: taskId, entityRowVersion: version, workspace: lane.workspace.id)
        let event = lane.tower.lock.withLock { lane.tower.events.last! }
        lane.events.event(event)
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Production live pipeline did not converge within five seconds")
    }

    func testSameTowerWorkspacesAndSameSignerDifferentTowersStayLiveAndPauseIndependently() async throws {
        let directory = temporaryDirectory(), catalog = try LocalStore(directory: temporaryDirectory())
        let identity = try await makeIdentity(), shared = SyncEngine(maxConcurrent: 3, reservedForeground: 1)
        let one = ConnectionRecord(origin: try TowerOrigin("https://one.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let two = ConnectionRecord(origin: try TowerOrigin("https://two.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let pool = WorkspaceStorePool(catalog: catalog, directory: directory)
        let a = try await lane(connection: one, workspaceId: Fixtures.workspaceId, pool: pool, shared: shared, identity: identity)
        let b = try await lane(connection: one, workspaceId: Fixtures.workspaceId2, pool: pool, shared: shared, identity: identity)
        let c = try await lane(connection: two, workspaceId: Fixtures.workspaceId, pool: pool, shared: shared, identity: identity)
        let lanes = [a,b,c], taskId = "a50d9885-0000-4000-8000-000000000001"
        for lane in lanes { await lane.stream.start(lane.connection, lane.workspace) }
        try await wait { lanes.allSatisfy { $0.events.openedCount == 1 } }
        for (index, lane) in lanes.enumerated() { emit(lane, taskId: taskId, title: "private-\(index)", version: 1) }
        try await wait {
            for (index, lane) in lanes.enumerated() {
                if try await lane.store.reader.task(workspaceId: lane.workspace.id, id: taskId)?.title != "private-\(index)" { return false }
            }
            return true
        }
        for lane in lanes {
            let cursor = try await lane.store.reader.eventCursor(connectionId: lane.connection.id, workspaceId: lane.workspace.id)
            XCTAssertEqual(cursor, FakeEventTower.cursor(1))
        }
        // No currently viewed-workspace concept enters the stream owner: all three converge concurrently.
        a.activity.pause(); await a.engine.pause(); await a.stream.stop()
        let readsAtPause = a.http.recorded.count
        emit(a, taskId: taskId, title: "paused-new", version: 2)
        emit(b, taskId: taskId, title: "same-tower-still-live", version: 2)
        emit(c, taskId: taskId, title: "other-tower-still-live", version: 2)
        await a.sync.refreshTask(a.connection, a.workspace, taskId: taskId, force: true)
        try await wait {
            let second = try await b.store.reader.task(workspaceId: b.workspace.id, id: taskId)?.title
            let third = try await c.store.reader.task(workspaceId: c.workspace.id, id: taskId)?.title
            return second == "same-tower-still-live" && third == "other-tower-still-live"
        }
        let paused = try await a.store.reader.task(workspaceId: a.workspace.id, id: taskId)
        XCTAssertEqual(paused?.title, "private-0")
        XCTAssertEqual(a.http.recorded.count, readsAtPause, "paused runtime must not fetch or reconnect")
        a.activity.resume(); await a.engine.resume(); await a.stream.start(a.connection, a.workspace)
        try await wait { try await a.store.reader.task(workspaceId: a.workspace.id, id: taskId)?.title == "paused-new" }

        // Revocation on one Tower deletes that boundary's inaccessible content, while the other Tower converges.
        let deniedHandler = c.tower.handler()
        c.http.setHandler { request in
            if request.url?.path == "/api/v4/flightdeck-pg/workspaces" {
                return (200, ["workspaces": [], "next_cursor": NSNull()])
            }
            return try deniedHandler(request)
        }
        c.events.revokeAccess()
        emit(a, taskId: taskId, title: "survives-other-tower-revocation", version: 3)
        emit(b, taskId: taskId, title: "second-workspace-survives", version: 3)
        try await wait {
            let revoked = try await c.store.reader.workspaces(connectionId: c.connection.id)
            let aTitle = try await a.store.reader.task(workspaceId: a.workspace.id, id: taskId)?.title
            let bTitle = try await b.store.reader.task(workspaceId: b.workspace.id, id: taskId)?.title
            return revoked.isEmpty && aTitle == "survives-other-tower-revocation" && bTitle == "second-workspace-survives"
        }
        let inaccessible = try await c.store.reader.task(workspaceId: c.workspace.id, id: taskId)
        XCTAssertNil(inaccessible)
        for lane in lanes { lane.activity.pause(); await lane.engine.pause(); await lane.stream.stop() }
        await shared.cancelAll(); await shared.waitUntilIdle()
    }
}

private extension EventChunks.AsyncIterator {
    func nextValue() async throws -> Data? { var iterator = self; return try await iterator.next() }
}
