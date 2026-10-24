import XCTest
@testable import AmbulandoCore

final class MentionTests: XCTestCase {
    let ann = Mention(type: .person, npub: TestKeys.npub, label: "Ann Lee")
    let bot = Mention(type: .agent, npub: "npub1hd37reqgfcnz3pvzj4grknd2nkzc94p9ercmunrxx22razr2rfxsw6dns5", label: "Rick")

    func testVisibleAndStructuredComeFromOneIdentity() {
        let (body, mentions) = MentionCodec.encode(text: "Hi @Ann Lee and @Rick, ship it", selected: [ann, bot])
        XCTAssertEqual(body, "Hi @[Ann Lee](mention:person:\(TestKeys.npub)) and @[Rick](mention:agent:\(bot.npub)), ship it")
        XCTAssertEqual(mentions, [ann, bot])
        XCTAssertEqual(mentions.map(\.requestObject), [["type": "person", "npub": TestKeys.npub, "label": "Ann Lee"],
                                                       ["type": "agent", "npub": bot.npub, "label": "Rick"]])
        // Every structured entry has its exact visible token in the body, and vice versa.
        for mention in mentions { XCTAssertTrue(body.contains(mention.token)) }
        XCTAssertEqual(MentionCodec.segments(body).compactMap { if case .mention(let m) = $0 { m } else { nil } }, mentions)
    }

    func testEditedAwayMentionIsNotSent() {
        let (body, mentions) = MentionCodec.encode(text: "Hi Ann", selected: [ann])
        XCTAssertEqual(body, "Hi Ann")
        XCTAssertTrue(mentions.isEmpty)
        let (prefix, prefixMentions) = MentionCodec.encode(text: "@Ann Leeds is here", selected: [ann])
        XCTAssertEqual(prefix, "@Ann Leeds is here", "a longer word is not a mention")
        XCTAssertTrue(prefixMentions.isEmpty)
    }

    func testDecodeRoundTripAndRecordReferences() {
        let body = "See @[Plan](mention:document:2d235803-6954-4007-959c-541821a118f6) with @[Rick](mention:agent:\(bot.npub))"
        XCTAssertEqual(MentionCodec.plain(body), "See Plan with @Rick")
        let (text, mentions) = MentionCodec.decode(body: body)
        XCTAssertEqual(mentions, [bot])
        XCTAssertEqual(MentionCodec.encode(text: text, selected: mentions).body, body)
    }

    func testLabelsCannotBreakTokens() {
        let odd = Mention(type: .person, npub: TestKeys.npub, label: "Eve [admin](x)")
        XCTAssertEqual(odd.label, "Eve admin x")
        XCTAssertEqual(MentionCodec.segments(odd.token), [.mention(odd)])
    }

    func testPickerQuery() {
        XCTAssertEqual(MentionCodec.activeQuery(in: "hello @an"), "an")
        XCTAssertEqual(MentionCodec.activeQuery(in: "@"), "")
        XCTAssertNil(MentionCodec.activeQuery(in: "mail me at a@b"))
        XCTAssertNil(MentionCodec.activeQuery(in: "hello"))
        XCTAssertEqual(MentionCodec.complete("hello @an", with: ann), "hello @Ann Lee ")
    }
}

final class DraftTests: XCTestCase {
    func testDraftsArePerTargetAndSurviveRelaunch() async throws {
        let h = try await ChatHarness.make()
        let channel = h.target(), thread = h.target(thread: "dd555036-0000-4000-8000-000000000001"), other = h.target(Fixtures.channel2)
        try await h.store.writer.saveDraft(channel, Draft(text: "channel text", mentions: []))
        try await h.store.writer.saveDraft(thread, Draft(text: "reply @Me", mentions: [Mention(type: .person, npub: TestKeys.npub, label: "Me")]))
        let relaunched = try await h.relaunch(unlock: false)
        let restoredChannel = try await relaunched.store.reader.draft(channel)
        let restoredThread = try await relaunched.store.reader.draft(thread)
        let restoredOther = try await relaunched.store.reader.draft(other)
        XCTAssertEqual(restoredChannel?.text, "channel text")
        XCTAssertEqual(restoredThread?.mentions.first?.label, "Me")
        XCTAssertNil(restoredOther)
        // Another workspace or connection never sees this draft.
        let foreign = ChatTarget(connectionId: h.connection.id, workspaceId: Fixtures.workspaceId2, channelId: Fixtures.channel1)
        let foreignDraft = try await relaunched.store.reader.draft(foreign)
        XCTAssertNil(foreignDraft)
        try await relaunched.store.writer.saveDraft(channel, Draft(text: "   ", mentions: []))
        let cleared = try await relaunched.store.reader.draft(channel)
        XCTAssertNil(cleared, "an empty draft is removed")
    }
}

final class OutboxTests: XCTestCase {
    func items(_ h: ChatHarness) async throws -> [OutboxItem] { try await h.store.reader.outbox(connectionId: h.connection.id, signerNpub: TestKeys.npub) }

    func testSendSignsExactTrimmedBodyAndMaterialisesAsNewConversation() async throws {
        let h = try await ChatHarness.make()
        try await h.store.writer.saveDraft(h.target(), Draft(text: "  hello  ", mentions: []))
        let item = try await h.outbox.send(text: "  hello @Me \n", mentions: [Mention(type: .person, npub: TestKeys.npub, label: "Me")],
                                           target: h.target(), connection: h.connection, workspace: h.workspace)
        let draft = try await h.store.reader.draft(h.target())
        XCTAssertNil(draft, "the draft moves into the outbox atomically")
        await h.engine.waitUntilIdle()

        let post = try XCTUnwrap(h.tower.recordedPosts.first)
        XCTAssertEqual(h.tower.recordedPosts.count, 1)
        XCTAssertEqual(post.request.url?.path, "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)/channels/\(Fixtures.channel1)/messages")
        XCTAssertEqual(post.request.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub"), Fixtures.appNpub)
        XCTAssertTrue(post.auth.tags.contains(["payload", SHA256Hex.of(post.body)]), "NIP-98 covers the exact bytes sent")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: post.body) as? [String: Any])
        XCTAssertEqual(object["body"] as? String, "hello @[Me](mention:person:\(TestKeys.npub))")
        XCTAssertEqual(object["client_request_id"] as? String, item?.id)
        XCTAssertEqual(object["create_thread"] as? Bool, true)
        XCTAssertNil(object["thread_id"])
        XCTAssertEqual((object["mentions"] as? [[String: String]])?.first?["npub"], TestKeys.npub)

        let remaining = try await items(h)
        XCTAssertTrue(remaining.isEmpty)
        let feed = try await h.store.reader.channelFeed(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, limit: 50)
        XCTAssertEqual(feed.map(\.message.body), ["hello @[Me](mention:person:\(TestKeys.npub))"])
        XCTAssertTrue(feed[0].message.isThreadRoot, "a new conversation's message is its thread's source")
    }

    func testReplyCarriesThreadTagAndThreadId() async throws {
        let h = try await ChatHarness.make()
        let root = h.tower.seed(channel: Fixtures.channel1, body: "root")
        let thread = root["thread_id"] as! String
        try await h.outbox.send(text: "reply", mentions: [], target: h.target(thread: thread), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let post = try XCTUnwrap(h.tower.recordedPosts.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: post.body) as? [String: Any])
        XCTAssertEqual(object["thread_id"] as? String, thread)
        XCTAssertNil(object["create_thread"])
        let event = try XCTUnwrap((object["message_signature"] as? [String: Any])?["nostr_event"] as? [String: Any])
        XCTAssertTrue((event["tags"] as? [[String]] ?? []).contains(["thread_id", thread]))
        let replies = try await h.store.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: thread, limit: 10)
        XCTAssertEqual(replies.map(\.body), ["reply"])
        XCTAssertFalse(replies[0].isThreadRoot)
    }

    func testOfflineRetryResendsFrozenBytesWithFreshNIP98() async throws {
        let h = try await ChatHarness.make()
        h.tower.inject(.offline)
        let item = try await XCTUnwrapAsync(try await h.outbox.send(text: "offline", mentions: [], target: h.target(),
                                                                    connection: h.connection, workspace: h.workspace))
        try await waitFor { try await h.store.reader.outboxItem(id: item.id)?.state == .retrying }
        let failed = try await h.store.reader.outboxItem(id: item.id)
        XCTAssertEqual(failed?.attempts, 1)
        XCTAssertEqual(failed?.lastError, "Offline; will send when the connection returns.")
        XCTAssertEqual(h.tower.messageCount, 0)

        await h.outbox.kick(h.connection, force: true)   // connection restored
        try await waitFor { try await h.store.reader.outboxItem(id: item.id) == nil }
        let posts = h.tower.recordedPosts
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].body, posts[1].body, "identical frozen request bytes (same client_request_id and kind 33358)")
        // Each attempt is signed anew at send time (Tower accepts NIP-98 events only within 300 s of created_at),
        // so a retry after a long offline period still verifies; the frozen part is the body, not the header.
        XCTAssertNotEqual(posts[0].auth.sig, posts[1].auth.sig, "each attempt carries a freshly signed NIP-98 event")
        XCTAssertLessThanOrEqual(abs(posts[1].auth.created_at - Int(Date().timeIntervalSince1970)), 5)
        XCTAssertEqual(h.tower.messageCount, 1)
    }

    func testRetryableFailureKeepsConversationOrder() async throws {
        let h = try await ChatHarness.make(unlocked: false)
        try await h.outbox.send(text: "first", mentions: [], target: h.target(), connection: h.connection, workspace: h.workspace)
        try await h.outbox.send(text: "second", mentions: [], target: h.target(), connection: h.connection, workspace: h.workspace)
        try await h.outbox.send(text: "elsewhere", mentions: [], target: h.target(Fixtures.channel2), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()     // locked passes send nothing
        h.tower.inject(.offline)          // only the first attempt fails
        try await h.identity.unlock(pin: TestKeys.pin)
        await h.outbox.kick(h.connection)
        try await waitFor { h.tower.recordedPosts.count >= 2 }
        try await Task.sleep(for: .milliseconds(300))           // the automatic retry is scheduled ~2 s later
        await h.engine.cancel(OutboxSender.key(h.connection))   // stop it; inspect exactly one pass
        let firstPass = h.tower.recordedPosts.compactMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["body"] as? String }
        XCTAssertEqual(firstPass, ["first", "elsewhere"], "a later message in the same conversation waits behind a retryable failure")
        await h.outbox.kick(h.connection, force: true)
        try await waitFor { try await h.store.reader.outbox(connectionId: h.connection.id, signerNpub: TestKeys.npub).isEmpty }
        let feed = try await h.store.reader.channelFeed(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, limit: 10)
        XCTAssertEqual(feed.map(\.message.body), ["first", "second"])
    }

    func testLostResponseIsReplayedNotDuplicated() async throws {
        let h = try await ChatHarness.make()
        h.tower.inject(.dropResponseAfterCommit)
        let item = try await XCTUnwrapAsync(try await h.outbox.send(text: "once", mentions: [], target: h.target(),
                                                                    connection: h.connection, workspace: h.workspace))
        try await waitFor { try await h.store.reader.outboxItem(id: item.id)?.state == .retrying }
        XCTAssertEqual(h.tower.messageCount, 1, "Tower committed although the reply was lost")
        await h.outbox.kick(h.connection, force: true)
        try await waitFor { try await h.store.reader.outboxItem(id: item.id) == nil }
        XCTAssertEqual(h.tower.messageCount, 1, "client_request_id replay, no duplicate")
        let feed = try await h.store.reader.channelFeed(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, limit: 50)
        XCTAssertEqual(feed.count, 1)
    }

    func testAutomaticRetryAfterServerError() async throws {
        let h = try await ChatHarness.make()
        h.tower.inject(.status(503, "unavailable"))
        let item = try await XCTUnwrapAsync(try await h.outbox.send(text: "later", mentions: [], target: h.target(),
                                                                    connection: h.connection, workspace: h.workspace))
        // The sender schedules its own retry (2 s ± 20 %) without any user action.
        try await waitFor(timeout: 6) { try await h.store.reader.outboxItem(id: item.id) == nil }
        XCTAssertEqual(h.tower.recordedPosts.count, 2)
    }

    func testPermanentFailuresWaitForTheUser() async throws {
        for (status, code, expected) in [(404, "thread_not_found", "This thread no longer exists."),
                                         (409, "idempotency_conflict", "Tower already has a different message with this request. Edit and send it as a new message."),
                                         (403, "forbidden", "You do not have permission to post here.")] {
            let h = try await ChatHarness.make()
            h.tower.inject(.status(status, code))
            let item = try await XCTUnwrapAsync(try await h.outbox.send(text: "nope", mentions: [], target: h.target(),
                                                                        connection: h.connection, workspace: h.workspace))
            try await waitFor { try await h.store.reader.outboxItem(id: item.id)?.state == .failed }
            let failed = try await h.store.reader.outboxItem(id: item.id)
            XCTAssertEqual(failed?.lastCode, code)
            XCTAssertEqual(failed?.lastError, expected)
            await h.outbox.kick(h.connection)
            await h.engine.waitUntilIdle()
            XCTAssertEqual(h.tower.recordedPosts.count, 1, "\(code): no automatic resend")

            try await h.outbox.retry(item.id, connection: h.connection)   // user taps Retry
            try await waitFor { try await h.store.reader.outboxItem(id: item.id) == nil }
            XCTAssertEqual(h.tower.recordedPosts.count, 2)
        }
    }

    func testEditFailedSendRestoresComposerText() async throws {
        let h = try await ChatHarness.make()
        h.tower.inject(.status(400, "validation_error"))
        let me = Mention(type: .person, npub: TestKeys.npub, label: "Me")
        let item = try await XCTUnwrapAsync(try await h.outbox.send(text: "fix @Me", mentions: [me], target: h.target(),
                                                                    connection: h.connection, workspace: h.workspace))
        try await waitFor { try await h.store.reader.outboxItem(id: item.id)?.state == .failed }
        try await h.store.writer.discardOutbox(id: item.id, restoreDraft: true)
        let draft = try await h.store.reader.draft(h.target())
        XCTAssertEqual(draft, Draft(text: "fix @Me", mentions: [me]))
        let remaining = try await items(h)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLockedComposeWaitsForExplicitUnlockAndSurvivesRelaunch() async throws {
        let h = try await ChatHarness.make(unlocked: false)
        let item = try await XCTUnwrapAsync(try await h.outbox.send(text: "while locked", mentions: [], target: h.target(),
                                                                    connection: h.connection, workspace: h.workspace))
        await h.engine.waitUntilIdle()
        XCTAssertTrue(h.tower.recordedPosts.isEmpty, "nothing is signed or sent while locked")
        let waiting = try await h.store.reader.outboxItem(id: item.id)
        XCTAssertEqual(waiting?.state, .awaitingSignature)
        XCTAssertNil(waiting?.request)

        let relaunched = try await h.relaunch(unlock: false)
        let persisted = try await relaunched.store.reader.outboxItem(id: item.id)
        XCTAssertEqual(persisted?.body, "while locked", "pending send survives relaunch")
        try await relaunched.identity.unlock(pin: TestKeys.pin)
        await relaunched.outbox.kick(relaunched.connection)
        try await waitFor { try await relaunched.store.reader.outboxItem(id: item.id) == nil }
        XCTAssertEqual(h.tower.recordedPosts.count, 1)
    }

    func testInterruptedSendIsReplayedAfterRelaunch() async throws {
        let h = try await ChatHarness.make(unlocked: false)
        let item = try await XCTUnwrapAsync(try await h.outbox.send(text: "in flight", mentions: [], target: h.target(),
                                                                    connection: h.connection, workspace: h.workspace))
        try await h.store.writer.freezeOutbox(id: item.id, request: Data("{}".utf8))
        let refrozen = try await h.store.writer.freezeOutbox(id: item.id, request: Data("{\"x\":1}".utf8))
        XCTAssertFalse(refrozen, "frozen exactly once")
        try await h.store.writer.markOutbox(id: item.id, state: .sending)
        let relaunched = try await h.relaunch(unlock: false)
        let reset = try await relaunched.store.reader.outboxItem(id: item.id)
        XCTAssertEqual(reset?.state, .queued)
        XCTAssertEqual(reset?.request, Data("{}".utf8))
    }

    func testRowsAreScopedToConnectionAndSigner() async throws {
        let h = try await ChatHarness.make()
        let other = try await h.store.writer.saveConnection(ConnectionRecord(origin: try TowerOrigin("https://other.example"),
                                                                             signerNpub: TestKeys.npub, towerNpub: nil))
        let foreign = ChatTarget(connectionId: other.id, workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1)
        try await h.store.writer.enqueueSend(target: foreign, origin: other.origin, signerNpub: TestKeys.npub, appNpub: Fixtures.appNpub,
                                             body: "for other tower", mentions: [])
        let otherSigner = Bech32.encode(hrp: "npub", data: Data(repeating: 7, count: 32))
        try await h.store.writer.enqueueSend(target: h.target(), origin: h.connection.origin, signerNpub: otherSigner, appNpub: Fixtures.appNpub,
                                             body: "other identity", mentions: [])
        await h.outbox.kick(h.connection)
        await h.engine.waitUntilIdle()
        XCTAssertTrue(h.tower.recordedPosts.isEmpty, "only this connection's rows signed by the unlocked identity are sent")

        // A connection target can never be sent under a different workspace record.
        let w2 = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId2, label: "Other")))
        do {
            try await h.outbox.send(text: "x", mentions: [], target: h.target(), connection: h.connection, workspace: w2)
            XCTFail("mismatched workspace accepted")
        } catch { XCTAssertEqual(error as? TowerError, .unsafePath) }
    }

    func testClassification() {
        func body(_ code: String) -> Data { Fixtures.json(["code": code]) }
        XCTAssertEqual(OutboxRequest.classify(status: 201, body: Fixtures.json(["created": true]), attempts: 1), .accepted(replayed: false))
        XCTAssertEqual(OutboxRequest.classify(status: 200, body: Fixtures.json(["replayed": true]), attempts: 1), .accepted(replayed: true))
        if case .retryable = OutboxRequest.classify(status: 502, body: Data(), attempts: 9) {} else { XCTFail("5xx retryable") }
        if case .retryable = OutboxRequest.classify(status: 429, body: Data(), attempts: 9) {} else { XCTFail("429 retryable") }
        if case .retryable = OutboxRequest.classify(status: 401, body: body("unauthorized"), attempts: 1) {} else { XCTFail("first 401 retryable") }
        if case .permanent = OutboxRequest.classify(status: 401, body: body("unauthorized"), attempts: 3) {} else { XCTFail("repeated 401 permanent") }
        if case .permanent(_, let code, let message) = OutboxRequest.classify(
            status: 400, body: Fixtures.json(["code": "validation_error", "details": ["fields": [["message": "body must be non-empty"]]]]), attempts: 1) {
            XCTAssertEqual(code, "validation_error"); XCTAssertEqual(message, "Tower rejected the message: body must be non-empty")
        } else { XCTFail("400 permanent") }
        if case .permanent = OutboxRequest.classify(status: 404, body: body("channel_not_found"), attempts: 1) {} else { XCTFail("404 permanent") }
    }
}

final class ChannelCatchUpTests: XCTestCase {
    func testPagedCatchUpResumesFromLastPageAndReconcilesItsRange() async throws {
        let h = try await ChatHarness.make()
        var seeded: [[String: Any]] = []
        for i in 0..<450 { seeded.append(h.tower.seed(channel: Fixtures.channel1, body: "m\(i)")) }
        let firstRoot = seeded[0]["thread_id"] as! String
        h.tower.seed(channel: Fixtures.channel1, body: "reply", thread: firstRoot)
        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.engine.waitUntilIdle()
        let errors = await h.engine.snapshot.errors
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let count = try await h.store.reader.messageCount(workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(count, 451)
        let feed = try await h.store.reader.channelFeed(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, limit: 1000)
        XCTAssertEqual(feed.count, 450, "the reply is not a channel-level post")
        XCTAssertEqual(feed.first?.replyCount, 1)
        let state = try await h.store.reader.channelSync(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1)
        XCTAssertEqual(state?.complete, true)
        let firstRun = h.tower.recordedGets.filter { $0.url!.path.hasSuffix("/messages") }.count
        XCTAssertEqual(firstRun, 3, "451 rows in pages of 200")

        // New message, one deleted inside the last page's range, one deleted before it.
        h.tower.seed(channel: Fixtures.channel1, body: "new")
        h.tower.delete(id: seeded[440]["id"] as! String)
        h.tower.delete(id: seeded[10]["id"] as! String)
        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.engine.waitUntilIdle()
        let secondRun = h.tower.recordedGets.filter { $0.url!.path.hasSuffix("/messages") }.count - firstRun
        XCTAssertEqual(secondRun, 1, "resumes from the last page cursor instead of re-reading the channel")
        var present = try await h.store.reader.message(workspaceId: Fixtures.workspaceId, id: seeded[440]["id"] as! String)
        XCTAssertNil(present, "deletion inside the re-read range is reconciled")
        present = try await h.store.reader.message(workspaceId: Fixtures.workspaceId, id: seeded[10]["id"] as! String)
        XCTAssertNotNil(present, "older range is untouched by an incremental catch-up")
        let latest = try await h.store.reader.channelFeed(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, limit: 1)
        XCTAssertEqual(latest.map(\.message.body), ["new"])

        await h.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1, force: true)   // pull to refresh
        await h.engine.waitUntilIdle()
        present = try await h.store.reader.message(workspaceId: Fixtures.workspaceId, id: seeded[10]["id"] as! String)
        XCTAssertNil(present, "a full refresh reconciles the whole channel")
    }

    func testReconcileNeverRemovesMessagesAfterTheCoveredRange() async throws {
        let h = try await ChatHarness.make()
        let early = MessageRecord(workspaceId: Fixtures.workspaceId, id: "00000000-0000-4000-8000-000000000001", channelId: Fixtures.channel1,
                                  body: "listed", createdAt: "2026-10-24T09:00:00.001Z")
        let acknowledged = MessageRecord(workspaceId: Fixtures.workspaceId, id: "00000000-0000-4000-8000-000000000002", channelId: Fixtures.channel1,
                                         body: "acked mid-catch-up", createdAt: "2026-10-24T09:00:05.000Z")
        try await h.store.writer.upsertMessages([early, acknowledged])
        let removed = try await h.store.writer.reconcileMessages(workspaceId: Fixtures.workspaceId, channelId: Fixtures.channel1, threadId: nil, after: nil,
                                                                 through: MessageKey(createdAt: early.createdAt, id: early.id), keep: [early.id])
        XCTAssertEqual(removed, 0)
        let kept = try await h.store.reader.message(workspaceId: Fixtures.workspaceId, id: acknowledged.id)
        XCTAssertNotNil(kept)
    }

    func testThreadRefreshAndForeignRowsRejected() async throws {
        let h = try await ChatHarness.make()
        let root = h.tower.seed(channel: Fixtures.channel1, body: "root")
        let thread = root["thread_id"] as! String
        h.tower.seed(channel: Fixtures.channel1, body: "r1", thread: thread)
        await h.sync.refreshThread(h.connection, h.workspace, channelId: Fixtures.channel1, threadId: thread)
        await h.engine.waitUntilIdle()
        let rows = try await h.store.reader.threadMessages(workspaceId: Fixtures.workspaceId, threadId: thread, limit: 10)
        XCTAssertEqual(rows.map(\.body), ["root", "r1"])
        let record = try await h.store.reader.thread(workspaceId: Fixtures.workspaceId, id: thread)
        XCTAssertEqual(record?.title, "root")

        // A page whose rows belong to another channel is refused and nothing is written.
        let stray = StubTransport { _ in
            (200, ["messages": [["id": UUID().uuidString, "workspace_id": Fixtures.workspaceId, "channel_id": Fixtures.channel2, "body": "x",
                                 "created_at": "2026-10-24T09:00:00.000Z", "row_version": 1]], "next_cursor": NSNull()])
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: stray, signer: h.identity))
        do {
            _ = try await api.messagesPage(workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub, channelId: Fixtures.channel1, cursor: nil)
            XCTFail("foreign rows accepted")
        } catch { XCTAssertEqual(error as? TowerError, .malformed("messages")) }
    }

    func testLockCancelsCatchUpWithoutReconcilingAPartialRange() async throws {
        let h = try await ChatHarness.make()
        for i in 0..<5 { h.tower.seed(channel: Fixtures.channel1, body: "m\(i)") }
        let slow = StubTransport { request in
            // Block inside the transport until cancelled.
            let semaphore = DispatchSemaphore(value: 0)
            _ = semaphore.wait(timeout: .now() + 0.3)
            return try h.tower.handler()(request)
        }
        let local = MessageRecord(workspaceId: Fixtures.workspaceId, id: "00000000-0000-4000-8000-0000000000ff", channelId: Fixtures.channel1,
                                  body: "local only", createdAt: "2026-10-24T08:00:00.000Z")
        try await h.store.writer.upsertMessages([local])
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.identity, transport: slow)
        await sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        try await Task.sleep(for: .milliseconds(50))
        await h.engine.cancelAll()        // identity locked
        await h.identity.lock()
        await h.engine.waitUntilIdle()
        let kept = try await h.store.reader.message(workspaceId: Fixtures.workspaceId, id: local.id)
        XCTAssertNotNil(kept, "a cancelled catch-up never reconciles")
        let errors = await h.engine.snapshot.errors
        XCTAssertTrue(errors.isEmpty, "cancellation is not reported as a failure: \(errors)")
    }
}

final class PriorityTests: XCTestCase {
    func testBackgroundCatchUpCannotTakeTheReservedSlot() async {
        let engine = SyncEngine(maxConcurrent: 3, reservedForeground: 1)
        let counter = Counter()
        let gate = AsyncStream<Void>.makeStream()
        for i in 0..<10 {
            await engine.enqueue("bg\(i)", priority: .background) {
                await counter.enter("bg\(i)")
                for await _ in gate.stream { break }
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        var snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.running.count, 2, "one slot stays free for the user")
        let userRan = expectation(description: "user job runs during the storm")
        await engine.enqueue("outbox:c", priority: .user) { userRan.fulfill() }
        await fulfillment(of: [userRan], timeout: 1)
        snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.running.filter { $0.hasPrefix("bg") }.count, 2)
        await engine.cancelAll()
    }

    func testDelayedRetryNeverPostponesAnImmediateRequest() async throws {
        let engine = SyncEngine(maxConcurrent: 2)
        let counter = Counter()
        let clock = ContinuousClock(), start = clock.now
        await engine.enqueue("k", priority: .user, delay: .milliseconds(300)) { await counter.enter("delayed") }
        var snapshot = await engine.snapshot
        XCTAssertEqual(snapshot.scheduled, ["k"])
        XCTAssertTrue(snapshot.queued.isEmpty, "a scheduled retry is not shown as active sync")
        await engine.enqueue("k", priority: .user) { await counter.enter("now") }
        await engine.waitUntilIdle()
        XCTAssertLessThan(clock.now - start, .milliseconds(250))
        let order = await counter.order
        XCTAssertEqual(order, ["now"])

        await engine.enqueue("k", priority: .user, delay: .milliseconds(150)) { await counter.enter("later") }
        await engine.waitUntilIdle()
        snapshot = await engine.snapshot
        XCTAssertTrue(snapshot.isIdle)
        let total = await counter.total
        XCTAssertEqual(total, 2)
    }
}

func waitFor(timeout: Double = 3, _ condition: @escaping () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition not met within \(timeout) s")
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
    guard let value = try await value() else { throw TowerError.malformed("nil") }
    return value
}
