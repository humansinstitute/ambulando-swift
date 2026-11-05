import XCTest
@testable import AmbulandoCore

final class BranchHistoryTests: XCTestCase {
    let parent = "a0a0a0a0-0000-4000-8000-000000000001"
    let child = "b0b0b0b0-0000-4000-8000-000000000001"
    let nested = "b0b0b0b0-0000-4000-8000-000000000002"

    func testMembershipSurvivesCanonicalSyncReloadAndNestedBranches() async throws {
        let h = try await ChatHarness.make()
        let rows = (0..<6).map { index in
            MessageRecord(workspaceId: Fixtures.workspaceId, id: UUID().uuidString.lowercased(), channelId: Fixtures.channel1,
                          threadId: index < 5 ? parent : child, body: "message \(index)", createdAt: "2026-11-05T00:00:0\(index).000Z")
        }
        try await h.store.writer.upsertMessages(rows)
        try await h.store.writer.replaceThreadMembership(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1,
                                                         threadId: child, messageIds: Array(rows.prefix(3)).map(\.id) + [rows[5].id])
        try await h.store.writer.replaceThreadMembership(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1,
                                                         threadId: nested, messageIds: Array(rows.prefix(2)).map(\.id))
        // Re-reading the parent must not erase the child's membership or add later parent messages.
        try await h.store.writer.upsertMessages(rows)
        let visible = try await h.store.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: child, limit: 500)
        XCTAssertEqual(visible.map(\.id), Array(rows.prefix(3)).map(\.id) + [rows[5].id])
        XCTAssertEqual(visible.first?.threadId, parent)
        XCTAssertTrue(visible[0].isInherited(in: child))
        XCTAssertFalse(visible[3].isInherited(in: child))
        let tail = try await h.store.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: child, limit: 2)
        XCTAssertEqual(tail.map(\.id), [rows[2].id, rows[5].id])
        let ancestorSelection = try await h.store.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: nested, limit: 500)
        XCTAssertEqual(ancestorSelection.map(\.id), Array(rows.prefix(2)).map(\.id))
        let reopened = try LocalStore(directory: h.directory.appendingPathComponent("Store"))
        let cold = try await reopened.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: child, limit: 500)
        XCTAssertEqual(cold, visible)
        XCTAssertTrue(cold[0].isInherited(in: child), "parent canonical sync must not remove read-only semantics")
        // Selecting the child's own reply keeps its inherited prefix as well as that reply.
        try await reopened.writer.replaceThreadMembership(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1,
                                                         threadId: nested, messageIds: cold.map(\.id))
        let ownSelection = try await reopened.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: nested, limit: 500)
        XCTAssertEqual(ownSelection.map(\.id), cold.map(\.id))
        XCTAssertTrue(ownSelection.allSatisfy { $0.isInherited(in: nested) })
        let parentRows = try await reopened.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: parent, limit: 500)
        XCTAssertEqual(parentRows.count, 5)
    }

    func testPaginationCanReachInheritedHistoryBeforeTheLast500Messages() async throws {
        let h = try await ChatHarness.make()
        let rows = (0..<620).map { index in
            MessageRecord(workspaceId: Fixtures.workspaceId, id: UUID().uuidString.lowercased(), channelId: Fixtures.channel1,
                          threadId: index < 610 ? parent : child, body: "message \(index)", createdAt: String(format: "%06d", index))
        }
        try await h.store.writer.upsertMessages(rows)
        try await h.store.writer.replaceThreadMembership(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1,
                                                         threadId: child, messageIds: rows.map(\.id))
        let newest = try await h.store.reader.threadMessagePage(workspaceId: Fixtures.workspaceId, threadId: child)
        XCTAssertEqual(newest.order.count, 620)
        XCTAssertEqual(newest.messages.count, 50)
        XCTAssertEqual(newest.start, 570)
        let earliest = try await h.store.reader.threadMessagePage(workspaceId: Fixtures.workspaceId, threadId: child, anchor: rows[0].id)
        XCTAssertEqual(earliest.messages.map(\.id), Array(rows.prefix(50)).map(\.id))
        XCTAssertFalse(earliest.hasEarlier)
        XCTAssertTrue(earliest.hasNewer)
    }

    func testThreadRefreshRequestsEveryEffectivePageWithoutMovingOwnership() async throws {
        let h = try await WorkHarness.make()
        let first = UUID().uuidString.lowercased(), last = UUID().uuidString.lowercased()
        let parent = parent, child = child
        let inner = h.transport
        let transport = StubTransport { request in
            let url = request.url!, query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if url.path.hasSuffix("/messages") && request.httpMethod == "GET" {
                XCTAssertEqual(query.first { $0.name == "effective_transcript" }?.value, "true")
                XCTAssertEqual(query.first { $0.name == "thread_id" }?.value, child)
                let second = query.contains { $0.name == "cursor" && $0.value == "page-two" }
                let row: [String: Any] = ["id": second ? last : first, "workspace_id": Fixtures.workspaceId,
                    "channel_id": Fixtures.channel1, "thread_id": child, "owning_thread_id": second ? child : parent,
                    "effective_thread_id": child, "body": second ? "child" : "ancestor ![file](storage://example)",
                    "created_at": second ? "2026-11-05T00:00:02.000Z" : "2026-11-05T00:00:01.000Z", "row_version": 1]
                return (200, ["messages": [row], "next_cursor": second ? NSNull() : "page-two" as Any])
            }
            if url.path.hasSuffix("/threads/\(child)") {
                return (200, ["thread": ["id": child, "workspace_id": Fixtures.workspaceId, "channel_id": Fixtures.channel1,
                    "parent_thread_id": parent, "branch_point_message_id": first]])
            }
            return try inner.handlerResult(request)
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        try await sync.runThreadRefresh(h.connection, h.workspace, channelId: Fixtures.channel1, threadId: child)
        let rows = try await h.store.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: child, limit: 500)
        XCTAssertEqual(rows.map(\.id), [first, last])
        XCTAssertEqual(rows.map(\.threadId), [parent, child])
        XCTAssertTrue(rows[0].body.contains("storage://example"))
        XCTAssertEqual(transport.recorded.filter { $0.url!.path.hasSuffix("/messages") }.count, 2)
    }
}
