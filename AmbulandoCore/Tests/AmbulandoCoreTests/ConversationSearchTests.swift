import XCTest
@testable import AmbulandoCore

final class ConversationSearchTests: XCTestCase {
    func testGrammar() throws {
        let mixed = try ConversationQuery("title:deployment checklist")
        XCTAssertEqual(mixed.clauses.map(\.field), [.title, nil])
        XCTAssertEqual(try ConversationQuery("title:”deployment checklist”").clauses.first?.match, "title : (\"deployment\" + \"checklist\")")
        XCTAssertEqual(try ConversationQuery("body:\"deployment checklist\"").clauses.first?.field, .body)
        XCTAssertEqual(try ConversationQuery("OR NEAR(test)").clauses.prefix(2).map(\.words), [["OR"], ["NEAR" ]])
        for malformed in ["title:", "title:\"unclosed", "body:\"\"", "scope:secret", "\"phrase\"tail", "***", String(repeating: "x ", count: 33)] {
            XCTAssertThrowsError(try ConversationQuery(malformed), malformed)
        }
        XCTAssertTrue(try ConversationQuery(" \n ").clauses.isEmpty)
    }

    func testVersionTenTitleBackfillAndLifecycleTriggers() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try SQLiteConnection(path: directory.appendingPathComponent("migration.sqlite").path, readOnly: false)
        try Schema.migrate(db)
        try db.execute("DROP TRIGGER search_threads_ai; DROP TRIGGER search_threads_au; DROP TRIGGER search_threads_ad; DELETE FROM search_index WHERE kind = 'thread'; PRAGMA user_version = 10;")
        let insert = try db.prepare("INSERT INTO threads(workspace_id,id,channel_id,title,archived,deleted,row_version,updated_at,raw) VALUES(?,?,?,?,0,0,1,'1',?)")
        try insert.run([.text("w"), .text("t"), .text("c"), .text("backfilled title"), .blob(Data("{}".utf8))])
        try Schema.migrate(db)
        func titleMatches(_ word: String) throws -> Int {
            let statement = try db.prepare("SELECT COUNT(*) FROM search_index WHERE search_index MATCH ? AND kind = 'thread'")
            try statement.bind([.text("title : \"\(word)\"")])
            _ = try statement.step()
            return Int(statement.int(0))
        }
        XCTAssertEqual(try db.userVersion, 11)
        XCTAssertEqual(try titleMatches("backfilled"), 1)
        try db.execute("UPDATE threads SET title = 'changed title' WHERE id = 't'")
        XCTAssertEqual(try titleMatches("backfilled"), 0)
        XCTAssertEqual(try titleMatches("changed"), 1)
        try db.execute("UPDATE threads SET deleted = 1 WHERE id = 't'")
        XCTAssertEqual(try titleMatches("changed"), 0)
        try db.execute("DELETE FROM threads WHERE id = 't'")
        XCTAssertEqual(try titleMatches("changed"), 0)
    }

    private func make() async throws -> ChatHarness {
        let h = try await ChatHarness.make()
        try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [
            ChannelRecord(workspaceId: h.workspace.id, id: Fixtures.channel1, scopeId: Fixtures.scopeA, name: "general", updatedAt: "1"),
            ChannelRecord(workspaceId: h.workspace.id, id: Fixtures.channel2, scopeId: Fixtures.scopeA, name: "other", updatedAt: "1")
        ], complete: true)
        return h
    }

    private func rows(_ h: ChatHarness, _ query: String, filter: ConversationFilter = .all, context: WorkContext = .home) async throws -> [ConversationRow] {
        try await h.store.reader.conversations(workspaceId: h.workspace.id, context: context, viewer: TestKeys.npub, filter: filter, query: query)
    }

    func testTitleReplySplitTermsPhrasesDedupAndOldHitPage() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let root = h.tower.seed(channel: Fixtures.channel1, body: "deployment plan")
        let thread = root["thread_id"] as! String
        let reply = h.tower.seed(channel: Fixtures.channel1, body: "checklist for release", thread: thread)
        for n in 0..<130 { h.tower.seed(channel: Fixtures.channel1, body: "Later reply \(n)", thread: thread) }
        h.tower.seed(channel: Fixtures.channel2, body: "deployment checklist")
        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel2)
        await h.engine.waitUntilIdle()
        let split = try await rows(h, "deployment checklist")
        XCTAssertEqual(split.count, 2)
        let target = try XCTUnwrap(split.first { $0.id == thread })
        XCTAssertEqual(target.summary.replyCount, 131)
        XCTAssertEqual(target.hitMessageId, reply["id"] as? String)
        XCTAssertTrue(target.excerpt.contains("⟦checklist⟧"))
        let page = try await h.store.reader.threadMessagePage(workspaceId: h.workspace.id, threadId: thread, anchor: target.hitMessageId)
        XCTAssertTrue(page.messages.contains { $0.id == target.hitMessageId })
        XCTAssertTrue(page.hasNewer)
        let phrase = try await rows(h, "\"deployment checklist\"")
        XCTAssertEqual(phrase.count, 1)
        let scoped = try await rows(h, "title:deployment checklist", context: WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1))
        XCTAssertEqual(scoped.map(\.id), [thread])
        let titlePhrase = try await rows(h, "title:”deployment checklist”")
        XCTAssertEqual(titlePhrase.count, 1)
        let bodyPhrase = try await rows(h, "body:\"deployment checklist\"")
        XCTAssertEqual(bodyPhrase.count, 1)
        let foreign = try await h.store.reader.conversations(workspaceId: Fixtures.workspaceId2, context: .home, viewer: TestKeys.npub, query: "deployment")
        XCTAssertTrue(foreign.isEmpty)
        let unknownScope = try await rows(h, "deployment", context: WorkContext(scopeId: Fixtures.scopeB))
        XCTAssertTrue(unknownScope.isEmpty)
    }

    func testRenameEditDeleteUnreadMineAndRevocation() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let root = h.tower.seed(channel: Fixtures.channel1, body: "original title", sender: FixtureNpubs.other)
        let thread = root["thread_id"] as! String
        let reply = h.tower.seed(channel: Fixtures.channel1, body: "needle reply", thread: thread)
        let other = h.tower.seed(channel: Fixtures.channel2, body: "other conversation", sender: FixtureNpubs.other)
        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel2)
        await h.engine.waitUntilIdle()
        let all = try await rows(h, "")
        XCTAssertEqual(all.first?.id, other["thread_id"] as? String)
        let mine = try await rows(h, "", filter: .mine)
        XCTAssertEqual(mine.map(\.id), [thread])
        let noUnread = try await rows(h, "", filter: .unread)
        XCTAssertTrue(noUnread.isEmpty, "missing attention state must never manufacture unread")
        try await h.store.writer.upsertViewStates(workspaceId: h.workspace.id, [ViewStateRecord(workspaceId: h.workspace.id, resourceType: .thread, resourceId: thread, scopeId: Fixtures.scopeA, channelId: Fixtures.channel1, activityVersion: 2, viewedActivityVersion: 1, updatedAt: "2")])
        let unread = try await rows(h, "needle", filter: .unread)
        XCTAssertEqual(unread.map(\.id), [thread])
        let renamed = ThreadRecord(workspaceId: h.workspace.id, id: thread, channelId: Fixtures.channel1, sourceMessageId: root["id"] as? String, title: "renamed conversation", rowVersion: 2, updatedAt: "2026-11-26T00:00:00Z", raw: Data("{\"v\":2}".utf8))
        try await h.store.writer.upsertThreads(workspaceId: h.workspace.id, [renamed])
        let oldTitle = try await rows(h, "title:original")
        XCTAssertTrue(oldTitle.isEmpty)
        let newTitle = try await rows(h, "title:renamed")
        XCTAssertEqual(newTitle.map(\.id), [thread])
        var edited = reply
        edited["body"] = "replacement body"; edited["row_version"] = 2; edited["updated_at"] = "2026-11-26T00:00:00Z"
        try await h.store.writer.upsertMessages([try MessageRecord(raw: Fixtures.json(edited))])
        let oldBody = try await rows(h, "needle")
        XCTAssertTrue(oldBody.isEmpty)
        let newBody = try await rows(h, "replacement")
        XCTAssertEqual(newBody.map(\.id), [thread])
        edited["record_state"] = "deleted"; edited["row_version"] = 3
        try await h.store.writer.upsertMessages([try MessageRecord(raw: Fixtures.json(edited))])
        let deleted = try await rows(h, "replacement")
        XCTAssertTrue(deleted.isEmpty)
        try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [], complete: true)
        let revoked = try await rows(h, "renamed")
        XCTAssertTrue(revoked.isEmpty)
    }
    func testExplicitHistoryDownloadHydratesTitlesOutsideCappedCatalogue() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let root = h.tower.seed(channel: Fixtures.channel1, body: "older renamed metadata")
        let handler = h.tower.handler()
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/channels/\(Fixtures.channel1)/threads") == true {
                return (200, ["threads": [], "next_cursor": NSNull()])
            }
            return try handler(request)
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.identity, transport: transport)
        await sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.engine.waitUntilIdle()
        let before = try await rows(h, "title:metadata")
        XCTAssertTrue(before.isEmpty)
        await sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1, force: true)
        await h.engine.waitUntilIdle()
        let after = try await rows(h, "title:\"older renamed metadata\"")
        XCTAssertEqual(after.map(\.id), [root["thread_id"] as! String])
        XCTAssertTrue(h.tower.recordedGets.contains { $0.url?.path.hasSuffix("/threads/\(root["thread_id"] as! String)") == true })
    }

    func testRecordDenialRemovesCachedSearchPreservesDraftAndPendingSendAndRestores() async throws {
        for status in [403, 404, 401, 500] {
            let h = try await make()
            defer { try? FileManager.default.removeItem(at: h.directory) }
            let root = h.tower.seed(channel: Fixtures.channel1, body: "private cached title")
            let thread = root["thread_id"] as! String
            let foreign = h.tower.seed(channel: Fixtures.channel2, body: "independent canonical message")
            try await h.sync.runChannelCatchUp(h.connection, h.workspace, channelId: Fixtures.channel1, fromStart: true)
            try await h.sync.runChannelCatchUp(h.connection, h.workspace, channelId: Fixtures.channel2, fromStart: true)
            try await h.store.writer.replaceThreadMembership(workspaceId: h.workspace.id, channelId: Fixtures.channel1, threadId: thread, messageIds: [foreign["id"] as! String])
            let target = h.target(thread: thread)
            let pending = try await h.store.writer.enqueueSend(target: target, origin: h.connection.origin, signerNpub: TestKeys.npub, appNpub: h.workspace.appNpub, body: "keep pending", mentions: [])
            try await h.store.writer.saveDraft(target, Draft(text: "keep draft", mentions: []))
            let handler = h.tower.handler()
            let transport = StubTransport { request in
                if request.url?.path.hasSuffix("/channels/\(Fixtures.channel1)/threads") == true { return (200, ["threads": []]) }
                if request.url?.path.hasSuffix("/threads/\(thread)") == true { return (status, ["code": status == 403 ? "forbidden" : "thread_not_found"]) }
                return try handler(request)
            }
            let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.identity, transport: transport)
            do {
                try await sync.runChannelCatchUp(h.connection, h.workspace, channelId: Fixtures.channel1, fromStart: true)
                XCTAssertTrue([403, 404].contains(status))
            } catch { XCTAssertTrue([401, 500].contains(status)) }
            let result = try await rows(h, "title:private")
            XCTAssertEqual(result.isEmpty, [403, 404].contains(status))
            let draft = try await h.store.reader.draft(target)
            let retained = try await h.store.reader.outboxItem(id: pending.id)
            let other = try await h.store.reader.message(workspaceId: h.workspace.id, id: foreign["id"] as! String)
            XCTAssertEqual(draft?.text, "keep draft")
            XCTAssertEqual(retained?.body, "keep pending")
            XCTAssertNotNil(other, "foreign-owned canonical messages must survive thread cache removal")
            try await h.sync.runChannelCatchUp(h.connection, h.workspace, channelId: Fixtures.channel1, fromStart: true)
            let restored = try await rows(h, "title:private")
            XCTAssertEqual(restored.map(\.id), [thread])
        }
    }

    func testRevokedTermCannotSatisfyConversationAndEffectiveBranchHits() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let root = h.tower.seed(channel: Fixtures.channel1, body: "allowed title")
        let owner = root["thread_id"] as! String
        var forbidden = h.tower.seed(channel: Fixtures.channel1, body: "secretterm", thread: owner)
        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.engine.waitUntilIdle()
        forbidden["record_state"] = "access_removed"; forbidden["row_version"] = 2
        try await h.store.writer.upsertMessages([try MessageRecord(raw: Fixtures.json(forbidden))])
        let leaked = try await rows(h, "allowed secretterm")
        XCTAssertTrue(leaked.isEmpty)
        let branch = UUID().uuidString.lowercased()
        try await h.store.writer.upsertThreads(workspaceId: h.workspace.id, [ThreadRecord(workspaceId: h.workspace.id, id: branch, channelId: Fixtures.channel1, sourceMessageId: nil, title: "branch title", updatedAt: "2026-11-26")])
        try await h.store.writer.replaceThreadMembership(workspaceId: h.workspace.id, channelId: Fixtures.channel1, threadId: branch, messageIds: [root["id"] as! String])
        let inherited = try await rows(h, "title:branch body:allowed")
        XCTAssertEqual(inherited.map(\.id), [branch])
        XCTAssertEqual(inherited.first?.hitMessageId, root["id"] as? String)
        let standalone = UUID().uuidString.lowercased()
        try await h.store.writer.upsertMessages([MessageRecord(workspaceId: h.workspace.id, id: standalone, channelId: Fixtures.channel1, body: "legacy channel post", senderNpub: TestKeys.npub, createdAt: "2026-11-26")])
        let legacy = try await rows(h, "legacy")
        XCTAssertEqual(legacy.map(\.id), [standalone])
        XCTAssertEqual(legacy.first?.standalone, true)
        let limit = try await h.store.reader.channelFeedLimit(workspaceId: h.workspace.id, channelId: Fixtures.channel1, through: standalone)
        let feed = try await h.store.reader.channelFeed(workspaceId: h.workspace.id, channelId: Fixtures.channel1, limit: limit)
        XCTAssertTrue(feed.contains { $0.id == standalone })
        let removedThread = ThreadRecord(workspaceId: h.workspace.id, id: owner, channelId: Fixtures.channel1, sourceMessageId: nil, title: "allowed title", rowVersion: 3, updatedAt: "2026-11-26", raw: Data("{\"record_state\":\"revoked\"}".utf8))
        try await h.store.writer.upsertThreads(workspaceId: h.workspace.id, [removedThread])
        let revoked = try await rows(h, "allowed")
        XCTAssertTrue(revoked.isEmpty, "revoked owner cannot contribute inherited content")
    }

}
