import Foundation
import XCTest
@testable import AmbulandoCore

final class WorkContextTests: XCTestCase {
    static let channel3 = "0617d526-0000-4000-8000-000000000003"
    static let dmScope = "76d518f7-0000-4000-8000-0000000000dd"
    static let dmChannel = "0617d526-0000-4000-8000-0000000000dd"
    static let other = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"

    func scope(_ id: String, _ name: String, kind: String = "project") throws -> ScopeRecord {
        var object = Fixtures.scope(id, name: name)
        object["kind"] = kind
        return try ScopeRecord(raw: Fixtures.json(object))
    }

    func channel(_ id: String, scope: String, _ name: String, position: Double? = nil, created: String = "2026-10-01T00:00:00.000Z",
                 kind: String = "channel", participants: [String]? = nil) throws -> ChannelRecord {
        var object = Fixtures.channel(id, scope: scope, name: name, position: position, updated: created)
        object["kind"] = kind
        if let participants { object["participant_npubs"] = participants }
        return try ChannelRecord(raw: Fixtures.json(object))
    }

    func task(_ id: String, scope: String?, channel: String) throws -> TaskRecord {
        var object = FakeEventTower.task(id, title: "Task \(id.suffix(2))", version: 1, channel: channel)
        object["scope_id"] = scope.map { $0 as Any } ?? NSNull()
        return try TaskRecord(raw: Fixtures.json(object))
    }

    // MARK: Context value

    func testContextKeepsAChannelOnlyUnderAScope() {
        XCTAssertEqual(WorkContext(scopeId: nil, channelId: Fixtures.channel1), .home)
        let context = WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1)
        XCTAssertEqual(WorkContext.decode(context.encoded()), context)
        XCTAssertNil(WorkContext.decode("not json"))
        XCTAssertEqual(WorkContext.stateKey(connectionId: "c", workspaceId: "w"), "context:c:w")
    }

    /// Losing access (or deletion) narrows the context instead of keeping an id the member can no longer read.
    func testResolvedContextFallsBackWhenAccessIsLost() throws {
        let scopes = [try scope(Fixtures.scopeA, "Alpha"), try scope(Fixtures.scopeB, "Beta")]
        let channels = [try channel(Fixtures.channel1, scope: Fixtures.scopeA, "general"), try channel(Self.channel3, scope: Fixtures.scopeB, "ops")]
        let selected = WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1)
        XCTAssertEqual(selected.resolved(scopes: scopes, channels: channels), selected)
        XCTAssertEqual(selected.resolved(scopes: scopes, channels: Array(channels.dropFirst())), WorkContext(scopeId: Fixtures.scopeA))
        XCTAssertEqual(selected.resolved(scopes: Array(scopes.dropFirst()), channels: channels), .home)
        // A channel id paired with the wrong scope never survives.
        XCTAssertEqual(WorkContext(scopeId: Fixtures.scopeB, channelId: Fixtures.channel1).resolved(scopes: scopes, channels: channels),
                       WorkContext(scopeId: Fixtures.scopeB))
    }

    // MARK: Scoped queries

    func testQueriesStayInsideTheContext() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let w = Fixtures.workspaceId
        try await store.writer.upsertScopes(workspaceId: w, [try scope(Fixtures.scopeA, "Alpha"), try scope(Fixtures.scopeB, "Beta")], complete: true)
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [try channel(Fixtures.channel1, scope: Fixtures.scopeA, "general"),
                                                                                         try channel(Fixtures.channel2, scope: Fixtures.scopeA, "design")], complete: true)
        try await store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeB, [try channel(Self.channel3, scope: Fixtures.scopeB, "ops")], complete: true)
        let t1 = "a0000000-0000-4000-8000-000000000001", t2 = "a0000000-0000-4000-8000-000000000002", t3 = "a0000000-0000-4000-8000-000000000003"
        // t2 carries only its channel (no scope id): it still belongs to its channel's scope.
        try await store.writer.upsertTasks(workspaceId: w, [try task(t1, scope: Fixtures.scopeA, channel: Fixtures.channel1),
                                                            try task(t2, scope: nil, channel: Fixtures.channel2),
                                                            try task(t3, scope: Fixtures.scopeB, channel: Self.channel3)])
        let home = try await store.reader.tasks(workspaceId: w, context: .home).map(\.id)
        XCTAssertEqual(Set(home), [t1, t2, t3])
        let alpha = try await store.reader.tasks(workspaceId: w, context: WorkContext(scopeId: Fixtures.scopeA)).map(\.id)
        XCTAssertEqual(Set(alpha), [t1, t2])
        let design = try await store.reader.tasks(workspaceId: w, context: WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel2)).map(\.id)
        XCTAssertEqual(design, [t2])
        let beta = try await store.reader.tasks(workspaceId: w, context: WorkContext(scopeId: Fixtures.scopeB)).map(\.id)
        XCTAssertEqual(beta, [t3])
        // Another workspace with the same scope id sees none of them.
        let elsewhere = try await store.reader.tasks(workspaceId: Fixtures.workspaceId2, context: WorkContext(scopeId: Fixtures.scopeA))
        XCTAssertTrue(elsewhere.isEmpty)
        XCTAssertTrue(WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel2).contains(scopeId: nil, channelId: Fixtures.channel2))
        XCTAssertFalse(WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel2).contains(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1))
    }

    // MARK: Sidebar projection

    func testSidebarPutsDirectMessagesFirstThenPersonalOrderAndChannelPositions() throws {
        let scopes = [try scope(Fixtures.scopeA, "Alpha"), try scope(Fixtures.scopeB, "Beta"), try scope(Self.dmScope, "DMs", kind: "dm")]
        let channels = [
            try channel(Fixtures.channel1, scope: Fixtures.scopeA, "zeta", position: 2),
            try channel(Fixtures.channel2, scope: Fixtures.scopeA, "alpha", position: nil, created: "2026-09-01T00:00:00.000Z"),
            try channel(Self.channel3, scope: Fixtures.scopeA, "mid", position: 1),
            try channel(Self.dmChannel, scope: Self.dmScope, "DM", kind: "dm", participants: [TestKeys.npub, Self.other]),
            // A channel whose scope the member cannot see is not listed.
            try channel("0617d526-0000-4000-8000-0000000000ff", scope: "76d518f7-0000-4000-8000-0000000000ff", "hidden"),
        ]
        let groups = SidebarNavigation.groups(scopes: scopes, channels: channels, personalOrder: [Fixtures.scopeB, Fixtures.scopeA])
        XCTAssertEqual(groups.map(\.scope.name), ["DMs", "Beta", "Alpha"])
        XCTAssertTrue(groups[0].isDirectMessages)
        XCTAssertEqual(groups[2].channels.map(\.name), ["mid", "zeta", "alpha"])
        XCTAssertFalse(groups.flatMap(\.channels).contains { $0.name == "hidden" })
        XCTAssertEqual(SidebarNavigation.unreadChannels(groups, unreadChannelIds: [Fixtures.channel2, Self.channel3]).map(\.name), ["mid", "alpha"])
    }

    func testDirectMessageLabelsUseParticipants() throws {
        let dm = try channel(Self.dmChannel, scope: Self.dmScope, "DM", kind: "dm", participants: [TestKeys.npub, Self.other])
        XCTAssertEqual(SidebarNavigation.label(dm, viewerNpub: TestKeys.npub, names: [Self.other: "Rick"]), "Rick")
        let note = try channel(Self.dmChannel, scope: Self.dmScope, "DM", kind: "dm", participants: [TestKeys.npub])
        XCTAssertEqual(SidebarNavigation.label(note, viewerNpub: TestKeys.npub, names: [:]), "Note to self")
        let plain = try channel(Fixtures.channel1, scope: Fixtures.scopeA, "general")
        XCTAssertEqual(SidebarNavigation.label(plain, viewerNpub: TestKeys.npub, names: [:]), "general")
    }

    // MARK: Threads in a channel

    /// The thread list shows every conversation with replies, including one with no stored source message or thread
    /// record, newest activity first, with its root, latest message and reply count.
    func testChannelThreadsListEveryConversationWithReplies() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let w = Fixtures.workspaceId, c = Fixtures.channel1
        func message(_ id: String, _ body: String, _ at: String, thread: String?, source: String?) -> MessageRecord {
            MessageRecord(workspaceId: w, id: id, channelId: c, threadId: thread, threadSourceId: source, body: body, senderNpub: TestKeys.npub, createdAt: at)
        }
        let root = UUID().uuidString.lowercased(), titled = UUID().uuidString.lowercased(), sourceless = UUID().uuidString.lowercased()
        try await store.writer.upsertThreads(workspaceId: w, [try ThreadRecord(raw: Fixtures.json([
            "id": titled, "workspace_id": w, "channel_id": c, "source_message_id": root, "title": "Release plan", "latest": NSNull(),
            "record_state": "active", "row_version": 1, "updated_at": "2026-10-24T01:00:00.000Z"]))])
        try await store.writer.upsertMessages([
            message(root, "Shall we ship?", "2026-10-24T01:00:00.000Z", thread: titled, source: root),
            message(UUID().uuidString.lowercased(), "Yes", "2026-10-24T01:05:00.000Z", thread: titled, source: root),
            message(UUID().uuidString.lowercased(), "first without source", "2026-10-24T02:00:00.000Z", thread: sourceless, source: nil),
            message(UUID().uuidString.lowercased(), "second", "2026-10-24T02:01:00.000Z", thread: sourceless, source: nil),
            message(UUID().uuidString.lowercased(), "third", "2026-10-24T02:02:00.000Z", thread: sourceless, source: nil),
            message(UUID().uuidString.lowercased(), "a post without replies", "2026-10-24T03:00:00.000Z", thread: nil, source: nil),
        ])
        let threads = try await store.reader.channelThreads(workspaceId: w, channelId: c)
        XCTAssertEqual(threads.map(\.id), [sourceless, titled])
        XCTAssertEqual(threads[0].replyCount, 2)
        XCTAssertEqual(threads[0].rootBody, "first without source")
        XCTAssertEqual(threads[0].latestBody, "third")
        XCTAssertNil(threads[0].title)
        XCTAssertEqual(threads[1].title, "Release plan")
        XCTAssertEqual(threads[1].replyCount, 1)
        XCTAssertEqual(threads[1].lastActivityAt, "2026-10-24T01:05:00.000Z")
        let titles = try await store.reader.threadTitles(workspaceId: w, channelId: c)
        XCTAssertEqual(titles, [titled: "Release plan"])
        let other = try await store.reader.channelThreads(workspaceId: w, channelId: Fixtures.channel2)
        XCTAssertTrue(other.isEmpty)
    }
}
