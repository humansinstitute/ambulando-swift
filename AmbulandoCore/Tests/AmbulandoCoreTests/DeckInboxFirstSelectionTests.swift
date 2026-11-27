import Foundation
import XCTest
@testable import AmbulandoCore

/// Pete's report: after switching workspace, the first Deck selection of Product > Discussion showed "No activity here
/// yet" until another channel was opened and the first one reselected. The restored context names a channel before the
/// workspace's channels have synced, so the Inbox must follow the channel list as it arrives.
@MainActor
final class DeckInboxFirstSelectionTests: XCTestCase {
    private let w = Fixtures.workspaceId

    private func eventually(_ message: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(25)) }
        XCTFail(message)
    }

    func testChannelRestoredBeforeItsChannelListSyncsStillShowsItsDiscussion() async throws {
        let h = try await ChatHarness.make()
        let store = h.store, w = w
        let context = WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1)
        let query = LiveQuery<DeckInboxSnapshot>(initial: DeckInboxSnapshot())
        // The Deck card starts the moment the restored context is known: the workspace has no channels stored yet.
        query.start(store: store, matches: { $0.workspaceId == w || $0.workspaceId == nil }) {
            try await DeckInboxLoader.load(store: store, workspaceId: w, context: context, viewer: TestKeys.npub, origin: nil)
        }
        await eventually("first read") { query.loaded }
        XCTAssertTrue(query.value.items.isEmpty)

        // The workspace then syncs: its channel, then the discussion.
        _ = try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [
            ChannelRecord(workspaceId: w, id: Fixtures.channel1, scopeId: Fixtures.scopeA, name: "Discussion", updatedAt: "2026-11-27T09:00:00.000Z")
        ], complete: true)
        let thread = UUID().uuidString.lowercased()
        try await store.writer.upsertThreads(workspaceId: w, [
            ThreadRecord(workspaceId: w, id: thread, channelId: Fixtures.channel1, sourceMessageId: nil,
                         title: "Goals versus Process", latest: "Processes are repeatable", updatedAt: "2026-11-27T09:18:00.000Z")
        ])
        await eventually("the discussion appears without leaving the channel") { query.value.items.contains { $0.recordId == thread } }
    }

    /// Switching workspace restarts the card's query. Rows written for the workspace just left, before or after the
    /// switch, must never appear in the new workspace's Inbox.
    func testRapidWorkspaceSwitchNeverShowsTheOldWorkspacesDiscussion() async throws {
        let h = try await ChatHarness.make()
        let store = h.store, a = Fixtures.workspaceId, b = Fixtures.workspaceId2
        let context = WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1)
        let query = LiveQuery<DeckInboxSnapshot>(initial: DeckInboxSnapshot())
        func start(_ workspace: String) {
            query.start(store: store, matches: { $0.workspaceId == workspace || $0.workspaceId == nil }) {
                try await DeckInboxLoader.load(store: store, workspaceId: workspace, context: context, viewer: TestKeys.npub, origin: nil)
            }
        }
        let old = UUID().uuidString.lowercased(), new = UUID().uuidString.lowercased()
        try await store.writer.upsertThreads(workspaceId: a, [ThreadRecord(workspaceId: a, id: old, channelId: Fixtures.channel1,
            sourceMessageId: nil, title: "Old workspace", latest: "old", updatedAt: "2026-11-27T09:00:00.000Z")])
        for _ in 0..<5 { start(a); start(b) }
        try await store.writer.upsertThreads(workspaceId: a, [ThreadRecord(workspaceId: a, id: old, channelId: Fixtures.channel1,
            sourceMessageId: nil, title: "Late old workspace", latest: "late", updatedAt: "2026-11-27T09:30:00.000Z")])
        try await store.writer.upsertThreads(workspaceId: b, [ThreadRecord(workspaceId: b, id: new, channelId: Fixtures.channel1,
            sourceMessageId: nil, title: "New workspace", latest: "new", updatedAt: "2026-11-27T09:40:00.000Z")])
        await eventually("new workspace discussion appears") { query.value.items.contains { $0.recordId == new } }
        XCTAssertFalse(query.value.items.contains { $0.recordId == old }, "old workspace rows must not leak")
        XCTAssertEqual(query.value.items.count, 1)
    }
}
