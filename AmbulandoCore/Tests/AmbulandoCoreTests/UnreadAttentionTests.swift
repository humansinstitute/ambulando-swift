import Foundation
import XCTest
@testable import AmbulandoCore

final class UnreadAttentionTests: XCTestCase {
    func testOffDeckProjectionAndBulkReadPreserveMissingParentsAndReadPositions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(directory: dir)
        let w = Fixtures.workspaceId, c = Fixtures.channel1
        var version = 1
        func task(_ state: String) -> TaskRecord {
            version += 1
            return TaskRecord(workspaceId: w, id: "hidden", scopeId: Fixtures.scopeA, channelId: c, title: "Retained task", description: nil,
                       state: state, priority: "rock", assignedToNpub: nil, rowVersion: version, createdAt: "2026-11-01", updatedAt: "2026-11-02", raw: Data(state.utf8))
        }
        let states = ["hidden", "unloaded"].map { id in
            ViewStateRecord(workspaceId: w, resourceType: .task, resourceId: id, scopeId: Fixtures.scopeA, channelId: c,
                            activityVersion: 8, viewedActivityVersion: 2, attentionActivityVersion: 7, updatedAt: "2026-11-02")
        }
        try await store.writer.upsertViewStates(workspaceId: w, states)
        try await store.writer.upsertTasks(workspaceId: w, [task("cancelled")])
        var projected = try await store.reader.viewStates(workspaceId: w)
        XCTAssertFalse(try XCTUnwrap(projected.first { $0.resourceId == "hidden" }).unread)
        XCTAssertTrue(try XCTUnwrap(projected.first { $0.resourceId == "unloaded" }).unread)
        var channels = try await store.reader.unreadChannelIds(workspaceId: w)
        XCTAssertEqual(channels, [c])
        // Off-deck only leaves no sidebar dot; the read position remains unchanged.
        try await store.writer.markViewedLocally(workspaceId: w, [(.task, "unloaded", 8)])
        channels = try await store.reader.unreadChannelIds(workspaceId: w)
        XCTAssertTrue(channels.isEmpty)
        projected = try await store.reader.viewStates(workspaceId: w)
        XCTAssertEqual(try XCTUnwrap(projected.first { $0.resourceId == "hidden" }).viewedActivityVersion, 2)
        try await store.writer.upsertTasks(workspaceId: w, [task("ready")])
        channels = try await store.reader.unreadChannelIds(workspaceId: w)
        XCTAssertEqual(channels, [c], "restore without explicit read retains real attention")
        try await store.writer.upsertTasks(workspaceId: w, [task("archived")])
        projected = try await store.reader.viewStates(workspaceId: w)
        let read = DeckActivity.readResources(projected, kinds: [.task], context: WorkContext(scopeId: Fixtures.scopeA), channelScopes: [:])
        XCTAssertEqual(read.map(\.resourceId), ["hidden"], "bulk read includes hidden records, independently of card paging/search")
        try await store.writer.markViewedLocally(workspaceId: w, read.map { ($0.resourceType, $0.resourceId, $0.activityVersion) })
        // A stale sync cannot regress the acknowledgement; restoring the parent remains read.
        try await store.writer.upsertViewStates(workspaceId: w, states)
        try await store.writer.upsertTasks(workspaceId: w, [task("ready")])
        let reopened = try LocalStore(directory: dir)
        channels = try await reopened.reader.unreadChannelIds(workspaceId: w)
        XCTAssertTrue(channels.isEmpty)
        let retained = try await reopened.reader.task(workspaceId: w, id: "hidden")
        XCTAssertEqual(retained?.title, "Retained task")
    }

    func testArchivedDocumentsAndThreadsExcludeMentionAttentionWithoutDroppingHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(directory: dir)
        let w = Fixtures.workspaceId, c = Fixtures.channel1
        let states = [ViewStateRecord.ResourceType.document, .thread].map { type in
            ViewStateRecord(workspaceId: w, resourceType: type, resourceId: type.rawValue, scopeId: Fixtures.scopeA, channelId: c,
                            activityVersion: 9, viewedActivityVersion: 2, attentionActivityVersion: 8,
                            mentionActivityVersion: 8, channelMentionsOnly: true, updatedAt: "2026-11-02")
        }
        try await store.writer.upsertViewStates(workspaceId: w, states)
        try await store.writer.upsertDocs(workspaceId: w, [.init(workspaceId: w, id: "document", scopeId: Fixtures.scopeA, channelId: c,
            storageObjectId: nil, title: "History", summary: nil, archived: true, rowVersion: 1, createdAt: "2026-11-01", updatedAt: "2026-11-02")])
        try await store.writer.upsertThreads(workspaceId: w, [.init(workspaceId: w, id: "thread", channelId: c,
            sourceMessageId: nil, title: "History", archived: true, rowVersion: 1, updatedAt: "2026-11-02")])
        let projected = try await store.reader.viewStates(workspaceId: w)
        XCTAssertTrue(projected.allSatisfy { !$0.unread && !$0.needsAttention && $0.underlyingUnread })
        let channels = try await store.reader.unreadChannelIds(workspaceId: w)
        XCTAssertTrue(channels.isEmpty)
        let selected = DeckActivity.readResources(projected, kinds: [.chat, .document], context: WorkContext(scopeId: Fixtures.scopeA, channelId: c), channelScopes: [:])
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(DeckActivity.readResources(projected, kinds: [.task], context: .home, channelScopes: [:]).isEmpty)
        XCTAssertTrue(DeckActivity.readResources(projected, kinds: [.chat, .document], context: WorkContext(scopeId: Fixtures.scopeB), channelScopes: [:]).isEmpty)
    }

    func testMutedStoreProjectionRetainsUnreadCursorAndRestoresOnUnmute() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(directory: dir)
        let w = Fixtures.workspaceId, c = Fixtures.channel1
        func state(_ mention: Int?, muted: Bool, viewed: Int = 2) -> ViewStateRecord {
            ViewStateRecord(workspaceId: w, resourceType: .thread, resourceId: "thread", scopeId: Fixtures.scopeA, channelId: c,
                            activityVersion: 8, viewedActivityVersion: viewed, attentionActivityVersion: 8,
                            mentionActivityVersion: mention, channelMentionsOnly: muted, updatedAt: "2026-11-01")
        }
        try await store.writer.upsertViewStates(workspaceId: w, [state(0, muted: true)])
        var ids = try await store.reader.unreadChannelIds(workspaceId: w)
        XCTAssertTrue(ids.isEmpty)
        var states = try await store.reader.viewStates(workspaceId: w)
        var stored = try XCTUnwrap(states.first)
        XCTAssertTrue(stored.underlyingUnread); XCTAssertFalse(stored.unread); XCTAssertFalse(stored.needsAttention)
        try await store.writer.upsertViewStates(workspaceId: w, [state(5, muted: true)])
        ids = try await store.reader.unreadChannelIds(workspaceId: w); XCTAssertEqual(ids, [c])
        try await store.writer.upsertViewStates(workspaceId: w, [state(5, muted: true, viewed: 5)])
        ids = try await store.reader.unreadChannelIds(workspaceId: w); XCTAssertTrue(ids.isEmpty)
        states = try await store.reader.viewStates(workspaceId: w)
        stored = try XCTUnwrap(states.first)
        XCTAssertTrue(stored.underlyingUnread); XCTAssertEqual(stored.viewedActivityVersion, 5)
        // Older/sparse write acknowledgements must not erase a confirmed muted projection.
        let sparse = ViewStateRecord(workspaceId: w, resourceType: .thread, resourceId: "thread", scopeId: Fixtures.scopeA, channelId: c,
                                     activityVersion: 8, viewedActivityVersion: 5, updatedAt: "2026-11-02")
        try await store.writer.upsertViewStates(workspaceId: w, [sparse])
        states = try await store.reader.viewStates(workspaceId: w)
        XCTAssertTrue(try XCTUnwrap(states.first).channelMentionsOnly)
        XCTAssertFalse(try XCTUnwrap(states.first).unread)
        try await store.writer.upsertViewStates(workspaceId: w, [state(5, muted: false, viewed: 5)])
        ids = try await store.reader.unreadChannelIds(workspaceId: w); XCTAssertEqual(ids, [c])
        let other = try await store.reader.unreadChannelIds(workspaceId: "other")
        XCTAssertTrue(other.isEmpty)
    }

    func testDeckKeepsOrdinaryCardWithoutUnreadOrWorkingEmphasis() throws {
        var s = DeckActivity.Sources()
        let c = Fixtures.channel1
        s.threads = [.init(threadId: "thread", channelId: c, isThread: true, title: "Research", rootBody: "root", latestBody: "ordinary", latestAt: "2026-11-01", messageCount: 3)]
        s.viewStates = [.init(workspaceId: Fixtures.workspaceId, resourceType: .thread, resourceId: "thread", scopeId: Fixtures.scopeA, channelId: c, activityVersion: 9, viewedActivityVersion: 3, attentionActivityVersion: 9, mentionActivityVersion: 2, channelMentionsOnly: true, updatedAt: "")]
        var items = DeckActivity.inbox(s, context: .home)
        XCTAssertEqual(items.count, 1); XCTAssertFalse(items[0].isUnread)
        s.viewStates = [.init(workspaceId: Fixtures.workspaceId, resourceType: .thread, resourceId: "thread", scopeId: Fixtures.scopeA, channelId: c, activityVersion: 9, viewedActivityVersion: 3, mentionActivityVersion: 5, channelMentionsOnly: true, updatedAt: "")]
        items = DeckActivity.inbox(s, context: .home); XCTAssertTrue(items[0].isUnread)
    }
}
