import Foundation
import XCTest
@testable import AmbulandoCore

final class UnreadAttentionTests: XCTestCase {
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
