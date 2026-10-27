import XCTest
@testable import AmbulandoCore

final class ComposerParityTests: XCTestCase {
    let rick = Mention(type: .agent, npub: "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5", label: "Rick")
    let id = "00000000-0000-4000-8000-000000000001"

    func testBackspaceInsideAPickedNameRemovesTheWholeName() {
        let old = "Hi @Rick"
        XCTAssertEqual(MentionCodec.wholeMentionDeletion(old: old, new: "Hi @Ric", mentions: [rick]), "Hi ")
        // Deleting the space after the name only removes the space; the name stays until the next Backspace.
        XCTAssertNil(MentionCodec.wholeMentionDeletion(old: "Hi @Rick ", new: "Hi @Rick", mentions: [rick]))
        XCTAssertEqual(MentionCodec.wholeMentionDeletion(old: "Hi @Rick please", new: "Hi @Rik please", mentions: [rick]), "Hi please")
        XCTAssertNil(MentionCodec.wholeMentionDeletion(old: "Hi there", new: "Hi ther", mentions: [rick]))
    }

    func testPillsFollowTheTextAndRemovalKeepsRouting() {
        XCTAssertEqual(MentionCodec.present([rick], in: "ask @Rick now"), [rick])
        XCTAssertEqual(MentionCodec.present([rick], in: "ask now"), [])
        XCTAssertEqual(MentionCodec.removing(rick, from: "ask @Rick now"), "ask now")
        let (body, mentions) = MentionCodec.encode(text: "ask @Rick now", selected: [rick])
        XCTAssertEqual(body, "ask \(rick.token) now")
        XCTAssertEqual(mentions, [rick])
    }

    func testUploadedReferencesStayWhereTheyWerePlacedAndRemoveInPlace() {
        let image = StorageMarkdown.image(objectId: id, alt: "shot.png")
        let text = "look\n\(image)\nbelow"
        XCTAssertEqual(StorageMarkdown.rawReferences(in: text).map(\.attachment.storageObjectId), [id])
        // Removing the thumbnail takes out only that reference (and the line it was alone on).
        XCTAssertEqual(StorageMarkdown.removingInline(objectId: id, from: text), "look\nbelow")
        XCTAssertEqual(StorageMarkdown.removingInline(objectId: id, from: "a \(image) b"), "a b")
        XCTAssertEqual(StorageMarkdown.removingInline(objectId: id.uppercased(), from: image), "")
        XCTAssertEqual(StorageMarkdown.removingInline(objectId: id, from: "end\n\(image)"), "end")
        XCTAssertEqual(StorageMarkdown.removingInline(objectId: "00000000-0000-4000-8000-000000000002", from: text), text)
        // The message shows an inline image once: a metadata attachment for the same object is not repeated below.
        let attachment = MessageAttachment(kind: "image", storageObjectId: id, filename: "shot.png", mimeType: "image/png", sizeBytes: 1)
        XCTAssertEqual(StorageMarkdown.standalone([attachment], body: text), [])
    }
}

final class MessageFlowTests: XCTestCase {
    func testAutopilotLinkNeedsASessionMessageAndAnAddress() {
        let session = "0a1b2c3d-1111-4222-8333-444455556666"
        let raw = Data(#"{"metadata":{"source":"autopilot_session","session_id":"\#(session)"}}"#.utf8)
        XCTAssertEqual(AutopilotSessionLink.sessionId(in: raw), session)
        XCTAssertNil(AutopilotSessionLink.sessionId(in: Data(#"{"metadata":{"source":"other","session_id":"\#(session)"}}"#.utf8)))
        XCTAssertNil(AutopilotSessionLink.sessionId(in: Data(#"{"metadata":{"source":"autopilot_session","session_id":"nope"}}"#.utf8)))
        XCTAssertEqual(AutopilotSessionLink.url(sessionId: session, autopilot: "https://autopilot.example/agents?x=1")?.absoluteString,
                       "https://autopilot.example/live/\(session)")
        XCTAssertNil(AutopilotSessionLink.url(sessionId: session, autopilot: "javascript:alert(1)"))
        XCTAssertEqual(AutopilotSessionLink.address(inWorkspace: Data(#"{"metadata":{"autopilot_url":"https://a.example"}}"#.utf8)), "https://a.example")
    }

    func testGetItDoneDescriptionFollowsTheWebTemplate() {
        let text = GetItDone.description(prompt: " Fix it ", output: .doc, extra: "", sourceReference: "@[Chat thread](mention:chat:c#m)",
                                         messages: [(sender: "Ann", body: "first"), (sender: "Rick", body: "second")])
        XCTAssertTrue(text.hasPrefix("## Request\nFix it\n\n## Source\n@[Chat thread](mention:chat:c#m)\n\n## Output\nCreate and attach the linked document deliverable."))
        XCTAssertTrue(text.contains("## Extra Instructions\nNone."))
        XCTAssertTrue(text.hasSuffix("## Latest Thread Excerpt\nRick: second\nAnn: first"))
    }
}

final class MessageFlowTransportTests: XCTestCase {
    let rick = "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5"
    let branchThread = "b0b0b0b0-0000-4000-8000-000000000001"

    func testAutopilotAddressComesOnlyFromTheMessageSendersLauncher() throws {
        let other = "npub1llwrq3rtah3rg3r2dyfyht55ek7aa0ey7z47ujju407pzfp38shqa7zcvr"
        let launchers = [PersonalAgentLauncher(npub: other, address: "https://other.example"), PersonalAgentLauncher(npub: rick, address: "https://rick.example")]
        XCTAssertEqual(AutopilotSessionLink.address(forSender: rick, launchers: launchers), "https://rick.example")
        XCTAssertEqual(AutopilotSessionLink.address(forSender: other, launchers: launchers), "https://other.example")
        XCTAssertNil(AutopilotSessionLink.address(forSender: TestKeys.npub, launchers: launchers), "an unrelated sender never borrows another agent's host")
        XCTAssertNil(AutopilotSessionLink.address(forSender: nil, launchers: launchers))
    }

    func testBranchRequestIsStoredAndRepliesKeepTheInheritedAgent() async throws {
        let h = try await WorkHarness.make()
        let parent = "a0a0a0a0-0000-4000-8000-000000000001", point = "c0c0c0c0-0000-4000-8000-000000000001"
        nonisolated(unsafe) let thread: [String: Any] = ["id": branchThread, "workspace_id": Fixtures.workspaceId, "channel_id": Fixtures.channel1, "source_message_id": point,
                                     "title": "Branch", "row_version": 1, "updated_at": "2026-10-26T00:00:00.000Z",
                                     "metadata": ["source": "flightdeck_branch", "inherited_agent_recipient_npub": rick]]
        let inner = h.transport
        let transport = StubTransport { request in
            if request.url!.path.hasSuffix("/branches") { return (201, ["thread": thread]) }
            return try inner.handlerResult(request)
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport)
        let created = try await sync.branchThread(h.connection, h.workspace, channelId: Fixtures.channel1, parentThreadId: parent,
                                                  branchPointMessageId: point, recipientNpub: rick)
        XCTAssertEqual(created.id, branchThread)
        let request = try XCTUnwrap(transport.recorded.first { $0.url!.path.hasSuffix("/branches") })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url!.path, "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/channels/\(Fixtures.channel1)/threads/\(parent)/branches")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["branch_point_message_id"] as? String, point)
        XCTAssertEqual((body["metadata"] as? [String: Any])?["inherited_agent_recipient_npub"] as? String, rick)
        XCTAssertTrue((body["client_request_id"] as? String ?? "").hasPrefix("branch:"))

        let stored = try await h.store.reader.thread(workspaceId: Fixtures.workspaceId, id: branchThread)
        XCTAssertEqual(stored?.inheritedAgentRecipient, rick)

        // A reply that names nobody still reaches the inherited agent; one that names someone does not add it.
        let target = ChatTarget(connectionId: h.connection.id, workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, threadId: branchThread)
        let sender = OutboxSender(store: h.store, engine: h.engine, identity: h.chat.identity, transport: transport, staging: h.staging)
        try await sender.send(text: "any update?", mentions: [], target: target, connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let posts = transport.recorded.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/messages") }
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(posts.first?.httpBody)) as? [String: Any])
        XCTAssertEqual((reply["metadata"] as? [String: Any])?["agent_direct_recipient_npub"] as? String, rick)
    }

    func testGetItDoneTaskCreateForwardsThreadSourceAndAssignee() async throws {
        let h = try await WorkHarness.make()
        let thread = "d0d0d0d0-0000-4000-8000-000000000001"
        let source: [String: String] = ["type": "chat", "id": "\(Fixtures.channel1)#\(thread)"]
        let payload: [String: any Sendable] = ["channel_id": Fixtures.channel1, "title": "Check the outbox", "description": "## Request\nCheck", "state": "ready",
                                               "priority": "sand", "thread_id": thread, "assigned_to_npub": rick,
                                               "metadata": ["source_links": [source], "assigned_to_npub": rick] as [String: any Sendable]]
        try await h.writes.submit(WriteIntent(kind: .taskCreate, targetId: nil, payload: payload), connection: h.connection, workspace: h.workspace)
        await h.settled()
        let create = try XCTUnwrap(h.transport.recorded.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/tasks") })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create.httpBody!) as? [String: Any])
        XCTAssertEqual(body["state"] as? String, "ready")
        XCTAssertEqual(body["thread_id"] as? String, thread)
        XCTAssertEqual(body["assigned_to_npub"] as? String, rick)
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual((metadata["source_links"] as? [[String: String]])?.first, source)
    }
}
