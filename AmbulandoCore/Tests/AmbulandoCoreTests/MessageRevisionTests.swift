import XCTest
@testable import AmbulandoCore

/// Isolated native composer serialization and signed transport, with no real messages or bot execution.
final class MessageRevisionTests: XCTestCase {
    let bot = Mention(type: .agent, npub: "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5", label: "Rick")

    func testPickerCompletionPreservesCanonicalFormattingSuffixAndExactIdentity() throws {
        let original = "**Instruction**\n@ric\n![image](storage://image)\n> keep this"
        let caret = ("**Instruction**\n@ric" as NSString).length
        let picked = try XCTUnwrap(CommentMentions.complete(original, selection: NSRange(location: caret, length: 0), with: bot))
        let revision = MessageRevisionDraft(body: picked)
        XCTAssertEqual(revision.body, "**Instruction**\n\(bot.token) \n![image](storage://image)\n> keep this")
        XCTAssertEqual(revision.mentions, [bot])
        // Repeated canonical tags and record references keep their exact body bytes.
        let body = "\(bot.token)\n\(bot.token) @[Doc](mention:document:doc-id)"
        XCTAssertEqual(MessageRevisionDraft(body: body).body, body)
        XCTAssertEqual(MessageRevisionDraft(body: body).mentions, [bot])
        XCTAssertTrue(MessageRevisionDraft(body: body.replacingOccurrences(of: bot.token, with: "@Rick")).mentions.isEmpty)
        XCTAssertEqual(MessageRevisionDraft(body: "ordinary edit \(bot.token)").mentions, [bot])
    }

    func testEditDraftRecoveryAndCancelNeverTouchUnsentReplyDraft() async throws {
        let h = try await WorkHarness.make()
        let reply = ChatTarget(connectionId: h.connection.id, workspaceId: h.workspace.id, channelId: Fixtures.channel1, threadId: Fixtures.scopeA)
        let edit = ChatTarget(connectionId: h.connection.id, workspaceId: h.workspace.id,
                              channelId: "content-" + MessageRevisionDraft.field(messageId: Fixtures.scopeB, rowVersion: 1))
        let replyDraft = Draft(text: "Unsent reply **formatting**", mentions: [])
        let editDraft = Draft(text: "Original\n\(bot.token)", mentions: [bot])
        try await h.store.writer.saveDraft(reply, replyDraft)
        try await h.store.writer.saveDraft(edit, editDraft)
        let restored = try await h.store.reader.draft(edit)
        XCTAssertEqual(restored?.text, editDraft.text)
        XCTAssertEqual(restored?.mentions, [bot])
        // Explicit cancel or successful queueing clears only the private revision draft.
        try await h.store.writer.saveDraft(edit, Draft(text: "", mentions: []))
        let cancelled = try await h.store.reader.draft(edit)
        let unsent = try await h.store.reader.draft(reply)
        XCTAssertNil(cancelled)
        XCTAssertEqual(unsent?.text, replyDraft.text)
        XCTAssertNotEqual(MessageRevisionDraft.field(messageId: Fixtures.scopeB, rowVersion: 1),
                          MessageRevisionDraft.field(messageId: Fixtures.scopeB, rowVersion: 2))
    }

    func testPickerAddedBotIsInSignedRevisionRequestAndReadback() async throws {
        let h = try await WorkHarness.make()
        let seeded = h.chat.tower.seed(channel: Fixtures.channel1, body: "An untagged instruction")
        let id = seeded["id"] as! String, thread = seeded["thread_id"] as! String
        await h.chat.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.engine.waitUntilIdle()
        let typed = "An untagged instruction @ric"
        let picked = try XCTUnwrap(CommentMentions.complete(typed, selection: NSRange(location: (typed as NSString).length, length: 0), with: bot))
        let revision = MessageRevisionDraft(body: picked)
        try await h.writes.submit(WriteIntent(kind: .messageEdit, targetId: id, payload: [
            "channel_id": Fixtures.channel1, "thread_id": thread, "body": revision.body, "row_version": 1,
            "mentions": revision.mentions.map(\.requestObject)]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let patch = try XCTUnwrap(h.transport.recorded.first { $0.httpMethod == "PATCH" && $0.url?.path.hasSuffix("/messages/" + id) == true })
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["body"] as? String, revision.body)
        XCTAssertEqual(payload["mentions"] as? [[String: String]], [bot.requestObject])
        let signed = try XCTUnwrap(h.chat.tower.revisions.first)
        XCTAssertTrue(SignatureVerifier.verify(signed))
        XCTAssertEqual(signed.content, revision.body)
        XCTAssertEqual(signed.kind, 33358)
        XCTAssertTrue(signed.tags.contains(["message_id", id]))
        XCTAssertTrue(signed.tags.contains(["revision", "2"]))
        XCTAssertTrue(signed.tags.contains(["workspace_id", h.workspace.id]))
        XCTAssertTrue(signed.tags.contains(["channel_id", Fixtures.channel1]))
        XCTAssertTrue(signed.tags.contains(["thread_id", thread]))
        let readback = try await h.store.reader.message(workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(readback?.body, revision.body)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(readback?.raw)) as? [String: Any])
        XCTAssertEqual(raw["mentions"] as? [[String: String]], [bot.requestObject])
        let metadata = try XCTUnwrap(raw["metadata"] as? [String: Any])
        let storedSignature = try XCTUnwrap(metadata["agent_instruction_signature"] as? [String: Any])
        XCTAssertEqual(storedSignature["revision"] as? Int, 2)
        XCTAssertEqual(storedSignature["message_id"] as? String, id)
        for (version, body) in [(2, "An untagged instruction"), (3, revision.body)] {
            let edited = MessageRevisionDraft(body: body)
            try await h.writes.submit(WriteIntent(kind: .messageEdit, targetId: id, payload: [
                "channel_id": Fixtures.channel1, "thread_id": thread, "body": edited.body,
                "row_version": version, "mentions": edited.mentions.map(\.requestObject)]), connection: h.connection, workspace: h.workspace)
            await h.engine.waitUntilIdle()
            let savedRow = try await h.store.reader.message(workspaceId: h.workspace.id, id: id)
            let saved = try XCTUnwrap(savedRow)
            let savedRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: saved.raw) as? [String: Any])
            XCTAssertEqual(savedRaw["mentions"] as? [[String: String]], edited.mentions.map(\.requestObject))
            XCTAssertEqual(saved.threadId, thread)
        }
    }
}
