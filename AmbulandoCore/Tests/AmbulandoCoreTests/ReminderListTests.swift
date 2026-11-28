import XCTest
@testable import AmbulandoCore

final class ReminderListTests: XCTestCase {
    func testHumanViewerStateAndRelationalAssignmentBoundaries() throws {
        let viewer = MemberRecord(workspaceId: Fixtures.workspaceId, actorId: UUID().uuidString.lowercased(), npub: TestKeys.npub, kind: "human", displayName: "Viewer")
        XCTAssertEqual(Reminders.viewer([viewer], workspace: viewer.workspaceId, signer: viewer.npub), viewer)
        XCTAssertNil(Reminders.viewer([viewer], workspace: Fixtures.workspaceId2, signer: viewer.npub))
        XCTAssertNil(Reminders.viewer([MemberRecord(workspaceId: viewer.workspaceId, actorId: viewer.actorId, npub: viewer.npub, kind: "agent", displayName: "Agent")], workspace: viewer.workspaceId, signer: viewer.npub))
        for state in TaskState.allCases { XCTAssertEqual(Reminders.isOpen(state.rawValue), [.new, .ready, .inProgress].contains(state)) }
        let id = UUID().uuidString.lowercased()
        var raw: [String: Any] = ["id": id, "workspace_id": viewer.workspaceId, "channel_id": Fixtures.channel1, "state": "ready"]
        func assigned() throws -> Bool { Reminders.isAssigned(try TaskRecord(raw: Fixtures.json(raw)), to: viewer) }
        XCTAssertFalse(try assigned())
        var assignment: [String: Any] = ["workspace_id": viewer.workspaceId, "task_id": id, "channel_id": Fixtures.channel1, "actor_id": viewer.actorId]
        raw["assignments"] = [assignment, assignment]
        XCTAssertTrue(try assigned())
        assignment["actor_id"] = UUID().uuidString; assignment["actor_npub"] = viewer.npub
        raw["assignments"] = [assignment]; XCTAssertTrue(try assigned())
        assignment["task_id"] = UUID().uuidString
        raw["assignments"] = [assignment]; XCTAssertFalse(try assigned())
        raw["assigned_to_npub"] = viewer.npub; XCTAssertTrue(try assigned())
        for field in ["deleted_at", "archived_at"] { var bad = raw; bad[field] = "2026-11-28"; XCTAssertFalse(Reminders.available(Fixtures.json(bad))) }
        for state in ["deleted", "revoked", "access_removed", "archived"] { var bad = raw; bad["record_state"] = state; XCTAssertFalse(Reminders.available(Fixtures.json(bad))) }
    }

    func testCandidatesBeyondGeneralListLimitAndChannelRevocation() async throws {
        let h = try await WorkHarness.make()
        defer { try? FileManager.default.removeItem(at: h.chat.directory) }
        var tasks: [TaskRecord] = []
        for n in 0..<601 {
            tasks.append(TaskRecord(workspaceId: h.workspace.id, id: UUID().uuidString.lowercased(), scopeId: Fixtures.scopeA, channelId: Fixtures.channel1,
                title: "Task \(n)", description: nil, state: "ready", priority: "sand", assignedToNpub: n == 0 ? TestKeys.npub : nil,
                rowVersion: 1, createdAt: "2026-11-28", updatedAt: String(format: "%04d", n)))
        }
        var deleted = tasks[0]
        var raw: [String: Any] = ["id": UUID().uuidString.lowercased(), "workspace_id": h.workspace.id, "channel_id": Fixtures.channel1, "assigned_to_npub": TestKeys.npub, "deleted_at": "2026-11-28"]
        deleted = try TaskRecord(raw: Fixtures.json(raw)); tasks.append(deleted)
        raw["id"] = UUID().uuidString.lowercased(); raw["deleted_at"] = NSNull(); raw["channel_id"] = UUID().uuidString.lowercased()
        tasks.append(try TaskRecord(raw: Fixtures.json(raw)))
        try await h.store.writer.upsertTasks(workspaceId: h.workspace.id, tasks)
        let limited = try await h.store.reader.tasks(workspaceId: h.workspace.id)
        XCTAssertFalse(limited.contains { $0.id == tasks[0].id })
        let all = try await h.store.reader.reminderCandidates(workspaceId: h.workspace.id)
        XCTAssertEqual(all.count, 601)
        XCTAssertTrue(all.contains { $0.id == tasks[0].id })
        XCTAssertEqual(Set(all.map(\.id)).count, 601)
        let foreign = try await h.store.reader.reminderCandidates(workspaceId: Fixtures.workspaceId2)
        XCTAssertTrue(foreign.isEmpty)
        try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [], complete: true)
        let revoked = try await h.store.reader.reminderCandidates(workspaceId: h.workspace.id)
        XCTAssertTrue(revoked.isEmpty)
    }
}
