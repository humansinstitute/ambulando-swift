import XCTest
@testable import AmbulandoCore

@MainActor
final class ThreadChangeTests: XCTestCase {
    func testExactScopeAndBroadFallback() {
        let target = ChatTarget(connectionId: "connection", workspaceId: "workspace", channelId: "channel", threadId: "thread")
        func affects(_ key: ChangeKey) -> Bool {
            key.affectsThread(workspaceId: target.workspaceId, channelId: target.channelId, threadId: target.threadId!)
        }
        XCTAssertTrue(affects(ChangeKey(.messages, "workspace", chatScope: .conversation(channelId: "channel", threadId: "thread"))))
        XCTAssertFalse(affects(ChangeKey(.messages, "workspace", chatScope: .conversation(channelId: "channel", threadId: "other"))))
        XCTAssertFalse(affects(ChangeKey(.messages, "workspace", chatScope: .conversation(channelId: "channel", threadId: nil))))
        XCTAssertFalse(affects(ChangeKey(.messages, "workspace", chatScope: .channelHistory("channel"))))
        XCTAssertFalse(affects(ChangeKey(.threads, "foreign", chatScope: .conversation(channelId: "channel", threadId: "thread"))))
        for table in [StoreTable.messages, .threads, .members, .agents, .profiles, .writes, .reactions, .outbox, .access] {
            XCTAssertTrue(affects(ChangeKey(table, "workspace")), "unknown scope must remain safe for \(table)")
            XCTAssertTrue(affects(ChangeKey(table)), "global reset must remain safe for \(table)")
        }
    }

    func testThreadMetadataScopesAndBroadEvents() async throws {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(5))
        let w = Fixtures.workspaceId, c = Fixtures.channel1
        let thread = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        func record(_ id: String, title: String, version: Int = 1) throws -> ThreadRecord {
            try ThreadRecord(raw: Fixtures.json(["id": id, "workspace_id": w, "channel_id": c,
                                                 "title": title, "row_version": version, "record_state": "active"]))
        }
        let query = LiveQuery<ThreadRecord?>(initial: nil)
        var loads = 0
        query.onLoad = { _ in loads += 1 }
        query.start(store: store, matches: { $0.table == .threads && $0.affectsThread(workspaceId: w, channelId: c, threadId: thread) }) {
            try await store.reader.thread(workspaceId: w, id: thread)
        }
        try await Task.sleep(for: .milliseconds(100))
        try await store.writer.upsertThreads(workspaceId: w, [record(thread, title: "initial")])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(query.value?.title, "initial")
        let beforeOther = loads
        // A catch-up batch can contain unchanged selected metadata alongside a changed unrelated thread.
        try await store.writer.upsertThreads(workspaceId: w, [record(thread, title: "initial"), record(other, title: "other")])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loads, beforeOther)
        try await store.writer.upsertThreads(workspaceId: w, [record(thread, title: "renamed", version: 2)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(query.value?.title, "renamed")
        let beforeBroad = loads
        await store.changes.record([ChangeKey(.threads, w)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loads, beforeBroad + 1, "broad events must reload even after exact scopes were observed")
        query.stop()
    }

    /// Exercises writer notifications and the actual live query, including edits, soft deletion and reparenting.
    func testWriterScopesReloadsWithoutLosingChanges() async throws {
        let store = try LocalStore(directory: temporaryDirectory(), coalesceInterval: .milliseconds(5))
        let tower = FakeChatTower()
        let root = tower.seed(channel: Fixtures.channel1, body: "root")
        let original = try MessageRecord(raw: Fixtures.json(root))
        let thread = try XCTUnwrap(original.threadId)
        let query = LiveQuery<[MessageRecord]>(initial: [])
        var loads = 0
        query.onLoad = { _ in loads += 1 }
        query.start(store: store, matches: {
            $0.table == .messages && $0.affectsThread(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, threadId: thread)
        }) { try await store.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: thread, limit: 500) }
        try await Task.sleep(for: .milliseconds(100))
        let initialLoads = loads
        let other = try MessageRecord(raw: Fixtures.json(tower.seed(channel: Fixtures.channel1, body: "unrelated")))
        try await store.writer.upsertMessages([other])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loads, initialLoads, "other conversations must not reload an open thread")
        try await store.writer.upsertMessages([original])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(query.value.map(\.body), ["root"])
        var edited = root
        edited["body"] = "edited"
        edited["row_version"] = 2
        try await store.writer.upsertMessages([try MessageRecord(raw: Fixtures.json(edited))])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(query.value.map(\.body), ["edited"])
        edited["record_state"] = "deleted"
        edited["row_version"] = 3
        try await store.writer.upsertMessages([try MessageRecord(raw: Fixtures.json(edited))])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(query.value.isEmpty, "deleted rows must disappear")
        let saved = try await store.reader.message(workspaceId: Fixtures.workspaceId, id: original.id)
        XCTAssertTrue(saved?.deleted == true)
        edited["record_state"] = "active"
        edited["row_version"] = 4
        try await store.writer.upsertMessages([try MessageRecord(raw: Fixtures.json(edited))])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(query.value.map(\.body), ["edited"])
        edited["thread_id"] = other.threadId
        edited["row_version"] = 5
        try await store.writer.upsertMessages([try MessageRecord(raw: Fixtures.json(edited))])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(query.value.isEmpty, "moving a row must also invalidate its old conversation")
        let beforeRepeat = loads
        try await store.writer.upsertMessages([original])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loads, beforeRepeat, "stale server rows must not emit changes")
    }
}
