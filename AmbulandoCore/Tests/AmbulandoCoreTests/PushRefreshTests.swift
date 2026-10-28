import Foundation
import XCTest
@testable import AmbulandoCore

final class PushRefreshTests: XCTestCase {
    func payload(_ h: LiveHarness, workspace: String? = nil, origin: String? = nil, task: String? = nil) throws -> PushPayload {
        var fd: [String: Any] = ["v": 1, "origin": origin ?? h.connection.origin, "workspace_id": workspace ?? h.workspace.id,
                                 "notification_id": UUID().uuidString, "change_seq": 999999]
        if let task { fd["task_id"] = task }
        return try PushPayload.parse(userInfo: ["fd": fd])
    }

    func testPushPersistsDeltaWithoutReadWritesAndCursorSurvivesReopen() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        let message = h.chat.tower.seed(channel: Fixtures.channel1, body: "available before opening")
        h.tower.emit("message", id: message["id"] as? String, entityRowVersion: 1)
        _ = try await h.sync.refreshAfterPush(payload(h), connection: h.connection)
        let reopened = try LocalStore(directory: ProductionStorage.storeDirectory(h.chat.directory))
        let stored = try await reopened.reader.message(workspaceId: h.workspace.id, id: message["id"] as! String)
        XCTAssertEqual(stored?.body, "available before opening")
        let cursor = try await h.store.reader.eventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(cursor, FakeEventTower.cursor(h.tower.head))
        XCTAssertTrue(h.transport.recorded.allSatisfy { ($0.httpMethod ?? "GET") == "GET" }, "sync must never mark read or send edits")
    }

    func testColdThreadPushIncludesRepliesAndPreservesDraftAndNavigation() async throws {
        let h = try await LiveHarness.make()
        let root = h.chat.tower.seed(channel: Fixtures.channel1, body: "Root")
        let thread = root["thread_id"] as! String
        let reply = h.chat.tower.seed(channel: Fixtures.channel1, body: "New reply", thread: thread)
        let target = h.chat.target(thread: thread)
        try await h.store.writer.saveDraft(target, Draft(text: "Unsent reply", mentions: []))
        try await h.store.writer.setState("chat-path:\(h.connection.id):\(h.workspace.id)", "keep current channel")
        let hint = try PushPayload.parse(userInfo: ["fd": ["v": 1, "origin": h.connection.origin,
            "workspace_id": h.workspace.id, "channel_id": Fixtures.channel1, "thread_id": thread]])
        _ = try await h.sync.refreshAfterPush(hint, connection: h.connection)
        let stored = try await h.store.reader.message(workspaceId: h.workspace.id, id: reply["id"] as! String)
        XCTAssertEqual(stored?.body, "New reply")
        let draft = try await h.store.reader.draft(target)
        XCTAssertEqual(draft?.text, "Unsent reply")
        let navigation = try await h.store.reader.state("chat-path:\(h.connection.id):\(h.workspace.id)")
        XCTAssertEqual(navigation, "keep current channel")
        XCTAssertTrue(h.transport.recorded.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }

    func testLockedPushWithoutOptInMakesNoRequests() async throws {
        let h = try await LiveHarness.make(unlocked: false)
        do { _ = try await h.sync.refreshAfterPush(payload(h), connection: h.connection); XCTFail() }
        catch { XCTAssertEqual(error as? IdentityError, .locked) }
        XCTAssertTrue(h.transport.recorded.isEmpty)
    }

    func testForeignOriginWorkspaceAndSignerMakeNoRequests() async throws {
        let h = try await LiveHarness.make()
        for hint in [try payload(h, workspace: Fixtures.workspaceId2), try payload(h, origin: "https://elsewhere.example")] {
            let changed = try await h.sync.refreshAfterPush(hint, connection: h.connection)
            XCTAssertFalse(changed)
        }
        XCTAssertTrue(h.transport.recorded.isEmpty)
        let connection = ConnectionRecord(id: h.connection.id, origin: try TowerOrigin(h.connection.origin), signerNpub: "npub1other", towerNpub: h.connection.towerNpub)
        do { _ = try await h.sync.refreshAfterPush(payload(h), connection: connection); XCTFail() } catch {}
        XCTAssertTrue(h.transport.recorded.isEmpty)
    }

    func testColdOrInvalidCursorNeverAdoptsPushSequenceAndStillFetchesTarget() async throws {
        let h = try await LiveHarness.make()
        let id = UUID().uuidString.lowercased()
        h.tower.tasks[id] = FakeEventTower.task(id, title: "Fresh task", version: 3)
        for oldCursor in [nil, "invalid-cursor"] as [String?] {
            if let oldCursor { try await h.store.writer.saveEventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id, oldCursor) }
            _ = try await h.sync.refreshAfterPush(payload(h, task: id), connection: h.connection)
            let stored = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
            XCTAssertEqual(stored?.title, "Fresh task")
            let cursor = try await h.store.reader.eventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id)
            XCTAssertEqual(cursor, oldCursor, "only successful deltas advance progress; foreground owns gap recovery")
        }
    }

    func testFailedDeltaKeepsCursorAndNextCatchUpRecovers() async throws {
        let h = try await LiveHarness.make()
        try await h.store.writer.saveEventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id, FakeEventTower.cursor(0))
        let message = h.chat.tower.seed(channel: Fixtures.channel1, body: "missed while offline")
        h.tower.emit("message", id: message["id"] as? String, entityRowVersion: 1)
        h.tower.eventStatus = 503
        do { _ = try await h.sync.refreshAfterPush(payload(h), connection: h.connection); XCTFail() } catch {}
        let failedCursor = try await h.store.reader.eventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(failedCursor, FakeEventTower.cursor(0))
        h.tower.eventStatus = nil
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        let stored = try await h.store.reader.message(workspaceId: h.workspace.id, id: message["id"] as! String)
        XCTAssertEqual(stored?.body, "missed while offline")
    }

    func testPushLeavesStructuralPageReplayableInsteadOfStartingUnboundedFanout() async throws {
        let h = try await LiveHarness.make()
        try await h.store.writer.saveEventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id, FakeEventTower.cursor(0))
        h.tower.emit("workspace_member", id: UUID().uuidString.lowercased())
        _ = try await h.sync.refreshAfterPush(payload(h), connection: h.connection)
        let cursor = try await h.store.reader.eventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(cursor, FakeEventTower.cursor(0))
        let snapshot = await h.sync.engine.snapshot
        XCTAssertTrue(snapshot.queued.isEmpty)
        XCTAssertFalse(h.transport.recorded.contains { $0.url?.path.hasSuffix("/scopes") == true })
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        await h.sync.engine.waitUntilIdle()
        let recovered = try await h.store.reader.eventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(recovered, FakeEventTower.cursor(h.tower.head))
    }

    func testCancellationLeavesUnrelatedWriteJobRunning() async throws {
        let h = try await LiveHarness.make()
        try await h.store.writer.saveEventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id, FakeEventTower.cursor(0))
        let slow = SlowTransport(inner: h.transport, slowPath: "/events", delay: .seconds(10))
        let sync = WorkspaceSync(store: h.store, engine: h.sync.engine, identity: h.sync.identity, transport: slow)
        await sync.engine.enqueue("write:unrelated", priority: .user) { try await Task.sleep(for: .seconds(10)) }
        let hint = try payload(h)
        let work = Task { try await sync.refreshAfterPush(hint, connection: h.connection) }
        try await Task.sleep(for: .milliseconds(50))
        work.cancel()
        _ = await work.result
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await sync.engine.snapshot
        XCTAssertTrue(snapshot.running.contains("write:unrelated"))
        let cursor = try await h.store.reader.eventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(cursor, FakeEventTower.cursor(0))
        await sync.engine.cancelAll()
    }
}

@MainActor
final class PushRefreshWindowTests: XCTestCase {
    func testDuplicateAndDistinctEventsCoalesceWithExactlyOneCompletionEach() async throws {
        let window = PushRefreshWindow(budget: .seconds(2))
        var runs = 0, completions = 0
        let work: PushRefreshWindow.Work = { runs += 1; try? await Task.sleep(for: .milliseconds(40)); return .newData }
        window.submit(key: "workspace", event: "a", work: work) { _ in completions += 1 }
        try await Task.sleep(for: .milliseconds(10))
        window.submit(key: "workspace", event: "a", work: work) { _ in completions += 1 }
        window.submit(key: "workspace", event: "b", work: work) { _ in completions += 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(completions, 3)
        window.cancel()
        XCTAssertEqual(completions, 3)
    }

    func testDeadlineIncludesStartupDoesNotExtendAndLateResultCannotCompleteTwice() async throws {
        let window = PushRefreshWindow(budget: .milliseconds(70))
        var results: [PushRefreshWindow.Result] = []
        let startup = PushStartupGate()
        let work: PushRefreshWindow.Work = {
            // Storage has not returned, even after cancellation. The OS completion must not wait for it.
            await startup.wait()
            return .newData
        }
        window.submit(key: "one", event: "a", work: work) { results.append($0) }
        try await Task.sleep(for: .milliseconds(40))
        window.submit(key: "one", event: "b", work: work) { results.append($0) }
        for _ in 0..<200 {
            if results.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(results, [.failed, .failed])
        await startup.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(results.count, 2)
        window.submit(key: "two", event: nil, work: { .noData }) { results.append($0) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(results.last, .noData, "a subsequent wake starts cleanly")
    }
}

final class PushRefreshOwnershipTests: XCTestCase {
    func testExpiringBackgroundPerformPreservesForegroundRerunOfSameKey() async throws {
        let engine = SyncEngine()
        let ran = OwnershipProbe()
        let background = Task {
            try await engine.perform("events:workspace", priority: .background) {
                await ran.started()
                try await Task.sleep(for: .seconds(10))
            }
        }
        for _ in 0..<100 {
            if await ran.didStart { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await engine.enqueue("events:workspace", priority: .visible) { await ran.foreground() }
        background.cancel()
        _ = await background.result
        await engine.waitUntilIdle()
        let count = await ran.count
        XCTAssertEqual(count, 1, "push expiry must not drop the queued foreground catch-up")
    }
}

private actor OwnershipProbe {
    var didStart = false
    var count = 0
    func started() { didStart = true }
    func foreground() { count += 1 }
}

private actor PushStartupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
