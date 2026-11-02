import XCTest
@testable import AmbulandoCore

final class TaskBoardTests: XCTestCase {
    func testDragBoundaryAndColumnSelection() {
        let drag = TaskBoardDrag(signer: "signer", connection: "connection", workspace: Fixtures.workspaceId, app: "app", task: Fixtures.channel1)
        XCTAssertEqual(TaskBoardDrag.taskId(from: drag.text, signer: "signer", connection: "connection", workspace: Fixtures.workspaceId, app: "app"), Fixtures.channel1)
        XCTAssertNil(TaskBoardDrag.taskId(from: drag.text, signer: "signer", connection: "other", workspace: Fixtures.workspaceId, app: "app"))
        XCTAssertNil(TaskBoardDrag.taskId(from: drag.text, signer: "signer", connection: "connection", workspace: Fixtures.workspaceId2, app: "app"))
        XCTAssertNil(TaskBoardDrag.taskId(from: drag.text, signer: "other", connection: "connection", workspace: Fixtures.workspaceId, app: "app"))
        XCTAssertNil(TaskBoardDrag.taskId(from: "plain text", signer: "signer", connection: "connection", workspace: Fixtures.workspaceId, app: "app"))
        XCTAssertEqual(TaskBoardSelection.togglingColumn(["a", "x"], ids: ["a", "b"]), ["a", "b", "x"])
        XCTAssertEqual(TaskBoardSelection.togglingColumn(["a", "b", "x"], ids: ["a", "b"]), ["x"])
        XCTAssertEqual(TaskBoardSelection.togglingColumn(["x"], ids: []), ["x"])
    }

    func testBulkDoneOnSeveralRowsClearsAssignmentsAndPreservesMetadata() async throws {
        let h = try await WorkHarness.make()
        let ids = (0..<3).map { h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Bulk \($0)", assignee: TestKeys.npub) }
        for id in ids { h.work.externalTaskEdit(id, fields: ["metadata": ["tags": "keep", "scheduled_for": "2026-10-01"]]) }
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let rows = try await h.store.reader.tasks(workspaceId: h.workspace.id)
        for row in rows { try await h.writes.submit(TaskBoardAction.done.intent(for: row)!, connection: h.connection, workspace: h.workspace) }
        await h.engine.waitUntilIdle()
        let pending = try await h.pending(); XCTAssertTrue(pending.isEmpty)
        for id in ids {
            XCTAssertEqual(h.work.task(id)?["state"] as? String, "done")
            XCTAssertTrue(h.work.task(id)?["assigned_to_npub"] is NSNull)
            XCTAssertEqual((h.work.task(id)?["metadata"] as? [String: Any])?["tags"] as? String, "keep")
        }
    }

    func testAlreadyAppliedActionDoesNotMutateAgain() async throws {
        let h = try await WorkHarness.make()
        let id = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Done", state: "done")
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let loaded = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        let task = try XCTUnwrap(loaded)
        try await h.writes.submit(TaskBoardAction.done.intent(for: task)!, connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        XCTAssertFalse(h.transport.recorded.contains { $0.httpMethod == "POST" || $0.httpMethod == "PATCH" })
        let pending = try await h.pending(); XCTAssertTrue(pending.isEmpty)
    }

    func testPartialStateAcceptanceAndAssignmentFailureIsKeptAndRetryDoesNotRepeatState() async throws {
        let other = try await WorkHarness.make()
        let taskId = other.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Partial", assignee: TestKeys.npub)
        await other.sync.refreshTasks(other.connection, other.workspace); await other.engine.waitUntilIdle()
        let loaded = try await other.store.reader.task(workspaceId: other.workspace.id, id: taskId)
        let task = try XCTUnwrap(loaded)
        let gate = PatchGate()
        let transport = StubTransport { request in
            if request.httpMethod == "PATCH" && gate.reject { return (status: 403, body: Data("{\"code\":\"forbidden\"}".utf8)) }
            return try other.work.handle(request)!
        }
        let sender = WriteSender(store: other.store, engine: other.engine, identity: other.chat.identity, transport: transport, staging: other.staging)
        let item = try await sender.submit(TaskBoardAction.archive.intent(for: task)!, connection: other.connection, workspace: other.workspace)
        await other.engine.waitUntilIdle()
        let failed = try await other.store.reader.writeItem(id: item.id)
        XCTAssertEqual(failed?.state, .failed)
        let local = try await other.store.reader.task(workspaceId: other.workspace.id, id: taskId)
        XCTAssertEqual(local?.state, "archive", "accepted first step remains visible locally")
        XCTAssertEqual(other.work.task(taskId)?["assigned_to_npub"] as? String, TestKeys.npub)
        gate.reject = false
        try await sender.retry(item.id, connection: other.connection); await other.engine.waitUntilIdle()
        let remaining = try await other.store.reader.writeItem(id: item.id); XCTAssertNil(remaining)
        XCTAssertEqual(transport.recorded.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/state") }.count, 1)
    }

    func testOfflineReadyAndBlockedPreserveExistingAssignmentSemantics() async throws {
        let h = try await WorkHarness.make()
        let id = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Offline")
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let loaded = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        let row = try XCTUnwrap(loaded)
        h.work.inject(.offline, matching: "/tasks/\(id)")
        let item = try await h.writes.submit(TaskBoardAction.ready.intent(for: row, agent: TestKeys.npub)!, connection: h.connection, workspace: h.workspace)
        await h.settled()
        let queued = try await h.store.reader.writeItem(id: item.id)
        XCTAssertEqual(queued?.state, .retrying)
        await h.drainWrites()
        let accepted = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(accepted?.state, "ready")
        XCTAssertEqual(accepted?.assignedToNpub, TestKeys.npub)
        try await h.writes.submit(TaskBoardAction.blocked.intent(for: accepted!)!, connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let blocked = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(blocked?.state, "blocked")
        XCTAssertEqual(blocked?.assignedToNpub, TestKeys.npub)
    }

    func testRejectedRowDoesNotBlockOtherSelectedRowsAndConflictDoesNotOverwrite() async throws {
        let h = try await WorkHarness.make()
        let first = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Denied")
        let second = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Allowed")
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let rows = try await h.store.reader.tasks(workspaceId: h.workspace.id)
        h.work.inject(.status(403, "forbidden"), matching: "/tasks/\(first)")
        for row in rows { try await h.writes.submit(TaskBoardAction.blocked.intent(for: row)!, connection: h.connection, workspace: h.workspace) }
        await h.engine.waitUntilIdle()
        let pending = try await h.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.targetId, first)
        XCTAssertEqual(pending.first?.state, .failed)
        XCTAssertEqual(h.work.task(second)?["state"] as? String, "blocked")
        XCTAssertEqual(h.work.task(first)?["state"] as? String, "new")
        let original = rows.first { $0.id == second }!
        let item = try await h.writes.submit(TaskBoardAction.done.intent(for: original)!, connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let conflict = try await h.store.reader.writeItem(id: item.id)
        XCTAssertEqual(conflict?.state, .conflict)
        XCTAssertEqual(h.work.task(second)?["state"] as? String, "blocked")
    }

    func testTodayMergesMetadataAndConcurrentRescheduleConflicts() async throws {
        let h = try await WorkHarness.make()
        let id = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Schedule")
        h.work.externalTaskEdit(id, fields: ["metadata": ["tags": "keep", "scheduled_for": "2026-10-01"]])
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let loaded = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        let row = try XCTUnwrap(loaded)
        let intent = TaskBoardAction.today.intent(for: row, date: Date(timeIntervalSince1970: 0))!
        try await h.writes.submit(intent, connection: h.connection, workspace: h.workspace); await h.engine.waitUntilIdle()
        XCTAssertEqual((h.work.task(id)?["metadata"] as? [String: Any])?["scheduled_for"] as? String, "1970-01-01")
        XCTAssertEqual((h.work.task(id)?["metadata"] as? [String: Any])?["tags"] as? String, "keep")
        h.work.externalTaskEdit(id, fields: ["metadata": ["scheduled_for": "2026-12-01"]])
        let item = try await h.writes.submit(intent, connection: h.connection, workspace: h.workspace); await h.engine.waitUntilIdle()
        let failed = try await h.store.reader.writeItem(id: item.id); XCTAssertEqual(failed?.state, .conflict)
        XCTAssertEqual((h.work.task(id)?["metadata"] as? [String: Any])?["scheduled_for"] as? String, "2026-12-01")
        XCTAssertNil(TaskBoardAction.ready.intent(for: row))
    }
}

private final class PatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var reject: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}
