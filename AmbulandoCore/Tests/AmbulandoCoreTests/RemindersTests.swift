import XCTest
@testable import AmbulandoCore

final class RemindersTests: XCTestCase {
    private func channel(_ id: String = Fixtures.channel2, workspace: String = Fixtures.workspaceId, participants: [String] = [TestKeys.npub], kind: String = "dm", extra: [String: Any] = [:]) throws -> ChannelRecord {
        var row = Fixtures.channel(id, scope: Fixtures.scopeA, workspace: workspace, name: "Notes to Self")
        row["kind"] = kind; row["participant_npubs"] = participants
        row.merge(extra) { _, new in new }
        return try ChannelRecord(raw: Fixtures.json(row))
    }

    func testBoardOwnershipWorkspaceAndAvailability() throws {
        let own = try channel()
        XCTAssertEqual(Reminders.personalBoard([own], workspace: Fixtures.workspaceId, viewer: TestKeys.npub)?.id, own.id)
        let other = "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5"
        for bad in [try channel(participants: [other]), try channel(participants: [TestKeys.npub, other]),
                    try channel(participants: [TestKeys.npub, TestKeys.npub]), try channel(participants: [TestKeys.npub, ""]),
                    try channel(kind: "channel"), try channel(workspace: Fixtures.workspaceId2),
                    try channel(extra: ["archived_at": "2026-11-01"]), try channel(extra: ["record_state": "deleted"])] {
            XCTAssertNil(Reminders.personalBoard([bad], workspace: Fixtures.workspaceId, viewer: TestKeys.npub))
        }
        XCTAssertNil(Reminders.personalBoard([own], workspace: Fixtures.workspaceId, viewer: other))
        XCTAssertNil(Reminders.personalBoard([], workspace: Fixtures.workspaceId, viewer: TestKeys.npub))
        XCTAssertNil(Reminders.personalBoard([own, try channel(Fixtures.channel1)], workspace: Fixtures.workspaceId, viewer: TestKeys.npub))
    }

    func testTitleAndBodyPreserveReadableSource() {
        XCTAssertEqual(Reminders.title(" \n", body: " \n"), "Saved conversation")
        XCTAssertEqual(Reminders.title(nil, body: "first\nsecond"), "first")
        XCTAssertEqual(Reminders.title(String(repeating: "🦊", count: 300), body: "x").count, 200)
        let body = "**Keep formatting**\nhttps://example.com/a?sig=x\n@[Plan](mention:doc:abc)"
        let result = Reminders.description(body: body, channel: Fixtures.channel1, message: Fixtures.channel2)
        XCTAssertTrue(result.hasPrefix(body + "\n\n"))
        XCTAssertTrue(result.contains("mention:chat:\(Fixtures.channel1)#\(Fixtures.channel2)"))
    }

    func testLostResponseAndRepeatedSaveReuseFrozenRequestAfterSourceEdit() async throws {
        let h = try await WorkHarness.make()
        defer { try? FileManager.default.removeItem(at: h.chat.directory) }
        let board = try channel()
        var raw = h.chat.tower.seed(channel: Fixtures.channel1, body: "**Original** https://example.com")
        raw["thread_id"] = NSNull()
        let message = try MessageRecord(raw: Fixtures.json(raw))
        let source = Source(raw: raw)
        let transport = StubTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/members") { return (200, Fixtures.json(["members": [Fixtures.member(TestKeys.npub, name: "Human")]])) }
            if path.hasSuffix("/scopes") { return (200, Fixtures.json(["scopes": [Fixtures.scope(Fixtures.scopeA, name: "Personal")]])) }
            if path.hasSuffix("/channels") {
                var row = try JSONSerialization.jsonObject(with: board.raw) as! [String: Any]
                row["id"] = source.boardId
                return (200, Fixtures.json(["channels": [row]]))
            }
            if path.hasSuffix("/messages/" + message.id) { return (200, Fixtures.json(["message": source.raw])) }
            return try h.work.handle(request)!
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        h.work.inject(.dropResponseAfterCommit, matching: "/channels/\(board.id)/tasks")
        do { _ = try await sync.saveReminder(h.connection, h.workspace, message: message, title: "Chat title"); XCTFail("Lost reply must not report success") } catch {}
        source.boardId = Fixtures.channel1
        do { _ = try await sync.saveReminder(h.connection, h.workspace, message: message, title: nil); XCTFail("Replacement board must be refused") } catch {}
        XCTAssertEqual(transport.recorded.filter { $0.httpMethod == "POST" }.count, 1)
        source.boardId = board.id
        source.raw["body"] = "edited body"
        let relaunched = try await h.chat.relaunch(unlock: true)
        let restarted = WorkspaceSync(store: relaunched.store, engine: relaunched.engine, identity: relaunched.identity, transport: transport)
        let task = try await restarted.saveReminder(h.connection, h.workspace, message: message, title: "Changed title")
        let repeated = try await restarted.saveReminder(h.connection, h.workspace, message: message, title: nil)
        XCTAssertEqual(task.id, repeated.id)
        XCTAssertEqual(task.title, "Chat title")
        XCTAssertEqual(task.state, "ready")
        XCTAssertEqual(task.assignedToNpub, TestKeys.npub)
        XCTAssertEqual(task.channelId, board.id)
        XCTAssertNil(task.threadId)
        XCTAssertTrue(task.description?.hasPrefix("**Original**") == true)
        let posts = transport.recorded.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(Set(posts.compactMap(\.httpBody)).count, 1)
        XCTAssertTrue(posts.allSatisfy { $0.url!.path.hasSuffix("/channels/\(board.id)/tasks") })
    }

    func testAbsentBoardBotAndPermissionRefusalNeverWrite() async throws {
        let h = try await WorkHarness.make()
        defer { try? FileManager.default.removeItem(at: h.chat.directory) }
        for scenario in ["missing", "bot", "forbidden"] {
            let transport = StubTransport { request in
                let path = request.url!.path
                if scenario == "forbidden" { return (403, Fixtures.json(["code": "forbidden"])) }
                if path.hasSuffix("/members") { return (200, Fixtures.json(["members": [Fixtures.member(TestKeys.npub, name: "Viewer", kind: scenario == "bot" ? "agent" : "human")]])) }
                if path.hasSuffix("/scopes") { return (200, Fixtures.json(["scopes": [Fixtures.scope(Fixtures.scopeA, name: "Home")]])) }
                return (200, Fixtures.json(["channels": []]))
            }
            let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
            do { _ = try await sync.remindersBoard(h.connection, h.workspace); XCTFail("Must refuse \(scenario)") } catch {}
            XCTAssertTrue(transport.recorded.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testColdSourceResolvesOriginalThreadAndRefusesMismatchOrDeniedAccess() async throws {
        let h = try await ChatHarness.make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let row = h.tower.seed(channel: Fixtures.channel1, body: "Source")
        let id = row["id"] as! String
        let initial = try await h.store.reader.message(workspaceId: h.workspace.id, id: id)
        XCTAssertNil(initial)
        do { _ = try await h.sync.linkedChatMessage(h.connection, h.workspace, messageId: id, channelId: Fixtures.channel2); XCTFail("Mismatched channel") } catch {}
        let source = try await h.sync.linkedChatMessage(h.connection, h.workspace, messageId: id, channelId: Fixtures.channel1)
        XCTAssertEqual(source.threadId, row["thread_id"] as? String)
        let cached = try await h.store.reader.message(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(cached?.id, id)
        let denied = WorkspaceSync(store: h.store, engine: h.engine, identity: h.identity,
                                  transport: StubTransport { _ in (403, Fixtures.json(["code": "forbidden"])) })
        do { _ = try await denied.linkedChatMessage(h.connection, h.workspace, messageId: id, channelId: nil); XCTFail("Denied source") } catch {}
        h.tower.delete(id: id)
        do { _ = try await h.sync.linkedChatMessage(h.connection, h.workspace, messageId: id, channelId: nil); XCTFail("Missing source") } catch {}
    }

    private final class Source: @unchecked Sendable {
        var raw: [String: Any]
        var boardId = Fixtures.channel2
        init(raw: [String: Any]) { self.raw = raw }
    }
}
