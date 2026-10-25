import Foundation
import XCTest
@testable import AmbulandoCore

/// Deck's Inbox and Recent cards follow the web's projection (sol `autopilot-overview-manager.js`).
final class DeckActivityTests: XCTestCase {
    private let w = Fixtures.workspaceId
    private let otherChannel = "0617d526-0000-4000-8000-000000000003"

    private func sources() -> DeckActivity.Sources {
        var s = DeckActivity.Sources()
        s.channelScopes = [Fixtures.channel1: Fixtures.scopeA, Fixtures.channel2: Fixtures.scopeA, otherChannel: Fixtures.scopeB]
        s.threads = [
            .init(threadId: "t1", channelId: Fixtures.channel1, isThread: true, title: nil, rootBody: "Plan the launch\nmore", latestBody: "ok",
                  latestAt: "2026-10-24T10:00:00.000Z", messageCount: 3),
            .init(threadId: "t2", channelId: otherChannel, isThread: true, title: "Ops sync", rootBody: nil, latestBody: "done",
                  latestAt: "2026-10-24T12:00:00.000Z", messageCount: 1),
        ]
        s.tasks = [
            TaskRecord(workspaceId: w, id: "k-open", scopeId: Fixtures.scopeA, channelId: Fixtures.channel2, title: "Open task", description: nil,
                       state: "review", priority: "rock", assignedToNpub: nil, rowVersion: 1, createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-24T09:00:00.000Z"),
            TaskRecord(workspaceId: w, id: "k-done-read", scopeId: Fixtures.scopeA, channelId: Fixtures.channel1, title: "Finished", description: nil,
                       state: "done", priority: "rock", assignedToNpub: nil, rowVersion: 1, createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-24T11:00:00.000Z"),
            TaskRecord(workspaceId: w, id: "k-done-unread", scopeId: Fixtures.scopeA, channelId: Fixtures.channel1, title: "Finished unread", description: nil,
                       state: "done", priority: "rock", assignedToNpub: nil, rowVersion: 1, createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-24T08:00:00.000Z"),
            TaskRecord(workspaceId: w, id: "k-archived", scopeId: Fixtures.scopeA, channelId: Fixtures.channel1, title: "Archived", description: nil,
                       state: "archived", priority: "rock", assignedToNpub: nil, rowVersion: 1, createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-24T13:00:00.000Z"),
        ]
        s.taskComments = ["k-open": .init(count: 2, latestAt: "2026-10-24T11:30:00.000Z")]
        s.docs = [DocRecord(workspaceId: w, id: "d1", scopeId: nil, channelId: Fixtures.channel1, storageObjectId: nil, title: "Spec", summary: "Draft",
                            rowVersion: 1, createdAt: "2026-10-20T00:00:00.000Z", updatedAt: "2026-10-23T00:00:00.000Z")]
        s.docComments = ["d1": .init(count: 1, latestAt: "2026-10-22T00:00:00.000Z")]
        s.files = [FileRecord(workspaceId: w, id: "f1", scopeId: Fixtures.scopeB, channelId: otherChannel, folderId: nil, storageObjectId: nil,
                              displayName: "plan.pdf", contentType: "application/pdf", sizeBytes: 10, sha256: nil,
                              createdAt: "2026-10-21T00:00:00.000Z", updatedAt: "2026-10-21T00:00:00.000Z")]
        s.viewStates = [
            ViewStateRecord(workspaceId: w, resourceType: .task, resourceId: "k-done-unread", scopeId: nil, channelId: nil, activityVersion: 2,
                            viewedActivityVersion: 1, updatedAt: ""),
            ViewStateRecord(workspaceId: w, resourceType: .thread, resourceId: "t1", scopeId: nil, channelId: nil, activityVersion: 4,
                            viewedActivityVersion: 3, updatedAt: ""),
        ]
        return s
    }

    func testHomeShowsEverythingNewestFirstWithTheWebsTaskRules() {
        let items = DeckActivity.inbox(sources(), context: .home)
        XCTAssertEqual(items.map(\.id), ["chat:t2", "task:k-open", "chat:t1", "task:k-done-unread", "document:d1", "file:f1"],
                       "done tasks only while unread, archived never; comments move a task up")
        let task = items.first { $0.recordId == "k-open" }!
        XCTAssertEqual(task.reason, "2 recent comments")
        XCTAssertEqual(task.activityAt, "2026-10-24T11:30:00.000Z")
        XCTAssertEqual(items.first { $0.recordId == "t1" }?.title, "Plan the launch", "a conversation's first line is its title")
        XCTAssertEqual(items.first { $0.recordId == "t1" }?.isUnread, true)
        XCTAssertEqual(items.first { $0.recordId == "d1" }?.reason, "1 unresolved comment")
    }

    func testScopeAndChannelNarrowTheFeed() {
        let scoped = DeckActivity.inbox(sources(), context: WorkContext(scopeId: Fixtures.scopeA))
        XCTAssertEqual(Set(scoped.map(\.recordId)), ["k-open", "t1", "k-done-unread", "d1"], "a record without a scope id uses its channel's scope")
        let channel = DeckActivity.inbox(sources(), context: WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel2))
        XCTAssertEqual(channel.map(\.recordId), ["k-open"])
    }

    func testTypeTogglesAndSearchCombine() {
        let items = DeckActivity.inbox(sources(), context: .home)
        XCTAssertEqual(DeckActivity.filter(items, kinds: [.task], query: "").map(\.recordId), ["k-open", "k-done-unread"])
        XCTAssertEqual(DeckActivity.filter(items, kinds: Set(DeckActivity.Kind.allCases), query: "  OPS   sync ").map(\.recordId), ["t2"])
        XCTAssertTrue(DeckActivity.filter(items, kinds: [], query: "").isEmpty, "all types hidden shows nothing")
    }

    func testRecentChannelsKeepEachChannelsNewestConversationInScope() {
        let s = sources()
        let extra = DeckActivity.ThreadActivity(threadId: "t3", channelId: Fixtures.channel1, isThread: true, title: "Older", rootBody: nil,
                                                latestBody: "", latestAt: "2026-10-23T00:00:00.000Z", messageCount: 1)
        let all = DeckActivity.recentChannels(s.threads + [extra], scopeId: nil, channelScopes: s.channelScopes)
        XCTAssertEqual(all.map(\.threadId), ["t2", "t1"])
        let scoped = DeckActivity.recentChannels(s.threads + [extra], scopeId: Fixtures.scopeA, channelScopes: s.channelScopes)
        XCTAssertEqual(scoped.map(\.threadId), ["t1"])
    }

    func testStoreQueriesBuildConversationsAndCommentActivity() async throws {
        let h = try await ChatHarness.make()
        let thread = UUID().uuidString.lowercased(), root = UUID().uuidString.lowercased()
        try await h.store.writer.upsertMessages([
            MessageRecord(workspaceId: w, id: root, channelId: Fixtures.channel1, threadId: thread, threadSourceId: root, body: "Root post",
                          senderNpub: TestKeys.npub, createdAt: "2026-10-24T09:00:00.000Z"),
            MessageRecord(workspaceId: w, id: UUID().uuidString.lowercased(), channelId: Fixtures.channel1, threadId: thread, threadSourceId: root,
                          body: "Latest reply", senderNpub: TestKeys.npub, createdAt: "2026-10-24T09:05:00.000Z"),
            MessageRecord(workspaceId: w, id: UUID().uuidString.lowercased(), channelId: Fixtures.channel2, threadId: nil, body: "Loose post",
                          createdAt: "2026-10-24T08:00:00.000Z"),
        ])
        let rows = try await h.store.reader.deckThreads(workspaceId: w, channelIds: nil)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].threadId, thread)
        XCTAssertEqual(rows[0].rootBody, "Root post")
        XCTAssertEqual(rows[0].latestBody, "Latest reply")
        XCTAssertEqual(rows[0].messageCount, 2)
        XCTAssertFalse(rows[1].isThread, "a post without a thread opens its channel")
        let channelOnly = try await h.store.reader.deckThreads(workspaceId: w, channelIds: [Fixtures.channel2])
        XCTAssertEqual(channelOnly.map(\.channelId), [Fixtures.channel2])

        let task = UUID().uuidString.lowercased()
        try await h.store.writer.upsertComments(workspaceId: w, [
            CommentRecord(workspaceId: w, id: UUID().uuidString.lowercased(), parent: .task, parentId: task, body: "mine", senderNpub: TestKeys.npub,
                          createdAt: "2026-10-24T10:00:00.000Z", updatedAt: "2026-10-24T10:00:00.000Z"),
            CommentRecord(workspaceId: w, id: UUID().uuidString.lowercased(), parent: .task, parentId: task, body: "theirs", senderNpub: "npub1other",
                          createdAt: "2026-10-24T11:00:00.000Z", updatedAt: "2026-10-24T11:00:00.000Z"),
        ])
        let activity = try await h.store.reader.deckCommentActivity(workspaceId: w, parent: .task, viewerNpub: TestKeys.npub)
        XCTAssertEqual(activity[task], .init(count: 1, latestAt: "2026-10-24T11:00:00.000Z"), "the viewer's own comments don't count")
    }
}
