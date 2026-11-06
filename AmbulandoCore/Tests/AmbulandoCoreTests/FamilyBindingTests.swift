import Foundation
import XCTest
@testable import AmbulandoCore

final class FamilyBindingTests: XCTestCase {
    static let thread = "7a1c0000-0000-4000-8000-000000000001"
    static let otherThread = "7a1c0000-0000-4000-8000-000000000002"

    func binding(thread: String = FamilyBindingTests.thread, signer: String = TestKeys.npub) -> FamilyBinding {
        FamilyBinding(connectionId: "conn-1", origin: "https://tower.example", signerNpub: signer, workspaceId: Fixtures.workspaceId,
                      appNpub: Fixtures.appNpub, workspaceLabel: "Studio", channelId: Fixtures.channel1, channelName: "Family",
                      threadId: thread, conversationTitle: "Sunday lunch")
    }

    func connection(origin: String = "https://tower.example", signer: String = TestKeys.npub) throws -> ConnectionRecord {
        ConnectionRecord(id: "conn-1", origin: origin, signerNpub: signer, towerNpub: nil, createdAt: "2026-11-01T00:00:00Z")
    }

    func workspace(id: String = Fixtures.workspaceId) throws -> WorkspaceRecord {
        try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(id, label: "Studio")))
    }

    func channel(id: String = Fixtures.channel1) throws -> ChannelRecord {
        try ChannelRecord(raw: Fixtures.json(Fixtures.channel(id, scope: Fixtures.scopeA, name: "Family")))
    }

    func thread(id: String = FamilyBindingTests.thread, channel: String = Fixtures.channel1, state: String = "active") throws -> ThreadRecord {
        try ThreadRecord(raw: Fixtures.json(["id": id, "workspace_id": Fixtures.workspaceId, "channel_id": channel, "source_message_id": NSNull(),
                                             "title": "Sunday lunch", "record_state": state, "row_version": 1, "updated_at": "2026-11-01T00:00:00.000Z"]))
    }

    func facts(signer: String? = TestKeys.npub, connection: ConnectionRecord?? = .none, workspaces: [WorkspaceRecord]?? = .none,
               channel: ChannelRecord?? = .none, channelsLoaded: Bool = true, thread: ThreadRecord?? = .none, threadLoaded: Bool = true) throws -> FamilyFacts {
        FamilyFacts(signerNpub: signer, connection: try connection ?? (try self.connection()),
                    accessibleWorkspaces: try workspaces ?? [try workspace()], channelsLoaded: channelsLoaded,
                    channel: try channel ?? (try self.channel()), threadLoaded: threadLoaded, thread: try thread ?? (try self.thread()))
    }

    // MARK: Access

    func testReadyOnlyWhenEveryLevelMatches() throws {
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts()), .ready)
        XCTAssertTrue(FamilyAccess.ready.canSend)
    }

    func testIdentityAndAccountComeFirst() throws {
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(signer: nil)), .needsSignIn)
        let other = Bech32.encode(hrp: "npub", data: Data(repeating: 0x22, count: 32))
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(signer: other)), .differentAccount)
        XCTAssertFalse(FamilyAccess.differentAccount.canSend)
        XCTAssertFalse(FamilyAccess.differentAccount.canShowConversation, "another account never sees the previous account's family chat")
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(connection: .some(nil))), .needsConnection)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(connection: .some(try connection(origin: "https://elsewhere.example")))), .differentTower)
    }

    func testMissingRecordsAreUnavailableOnlyOnceListingsAreKnown() throws {
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(workspaces: .some(nil))), .checking)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(workspaces: .some([try workspace(id: Fixtures.workspaceId2)]))), .workspaceUnavailable)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(channel: .some(nil), channelsLoaded: false)), .checking)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(channel: .some(nil))), .channelUnavailable)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(thread: .some(nil), threadLoaded: false)), .checking)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(thread: .some(nil))), .conversationUnavailable)
        XCTAssertFalse(FamilyAccess.checking.canSend, "nothing is sent until the target is confirmed")
        // A live thread answer proves channel access before the channel listing has loaded.
        var live = try facts(channel: .some(nil), channelsLoaded: false)
        live.threadConfirmedLive = true
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), live), .ready)
    }

    func testAnotherThreadIsNeverSubstituted() throws {
        let wrongThread = try thread(id: Self.otherThread)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(thread: .some(wrongThread))), .conversationUnavailable)
        let movedChannel = try thread(channel: Fixtures.channel2)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(thread: .some(movedChannel))), .conversationUnavailable)
    }

    func testArchivedAndDeletedTargets() throws {
        let archived = FamilyAccessEvaluator.evaluate(binding(), try facts(thread: .some(try thread(state: "archived"))))
        XCTAssertEqual(archived, .conversationArchived)
        XCTAssertTrue(archived.canShowConversation)
        XCTAssertFalse(archived.canSend)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(binding(), try facts(thread: .some(try thread(state: "deleted")))), .conversationUnavailable)
    }

    // MARK: Persistence

    func testBindingRoundTripsAndIsScopedPerSigner() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let mine = binding()
        try await store.writer.setFamilyBinding(mine)
        let restored = try await store.reader.familyBinding(signerNpub: TestKeys.npub)
        XCTAssertEqual(restored, mine)
        let other = Bech32.encode(hrp: "npub", data: Data(repeating: 0x22, count: 32))
        let foreign = try await store.reader.familyBinding(signerNpub: other)
        XCTAssertNil(foreign, "a different account does not see this binding")
        // Signing in as someone else and back keeps the original choice.
        let theirs = binding(thread: Self.otherThread, signer: other)
        try await store.writer.setFamilyBinding(theirs)
        let again = try await store.reader.familyBinding(signerNpub: TestKeys.npub)
        XCTAssertEqual(again, mine)
    }

    func testRelaunchRestoresBindingFromDisk() async throws {
        let directory = temporaryDirectory()
        do { let store = try LocalStore(directory: directory); try await store.writer.setFamilyBinding(binding()) }
        let reopened = try LocalStore(directory: directory)
        let restored = try await reopened.reader.familyBinding(signerNpub: TestKeys.npub)
        XCTAssertEqual(restored?.threadId, Self.thread)
        XCTAssertEqual(restored?.conversationTitle, "Sunday lunch")
    }

    func testMalformedBindingIsNotSavedOrRestored() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        do { try await store.writer.setFamilyBinding(binding(thread: "not-a-uuid")); XCTFail("saved a binding with no real conversation") }
        catch { XCTAssertEqual(error as? FamilyBindingError, .malformed) }
        try await store.writer.setState(StoreReader.familyBindingKey(signerNpub: TestKeys.npub), "{\"not\":\"a binding\"}")
        let none = try await store.reader.familyBinding(signerNpub: TestKeys.npub)
        XCTAssertNil(none)
    }

    func testChangeFamilyChatForgetsOnlyTheChoice() async throws {
        let h = try await ChatHarness.make()
        let mine = binding()
        try await h.store.writer.setFamilyBinding(mine)
        let target = mine.target
        let sameTarget = ChatTarget(connectionId: h.connection.id, workspaceId: target.workspaceId, channelId: target.channelId, threadId: target.threadId)
        try await h.store.writer.saveDraft(sameTarget, Draft(text: "half written", mentions: []))
        try await h.store.writer.clearFamilyBinding(signerNpub: TestKeys.npub)
        let cleared = try await h.store.reader.familyBinding(signerNpub: TestKeys.npub)
        XCTAssertNil(cleared)
        let draft = try await h.store.reader.draft(sameTarget)
        XCTAssertEqual(draft?.text, "half written", "changing the family chat does not delete drafts")
    }

    // MARK: Routing

    func testRoutesCannotEscapeTheBoundConversation() {
        let b = binding()
        let w = Fixtures.workspaceId, c = Fixtures.channel1
        XCTAssertEqual(FamilyRouting.resolve(.thread(workspaceId: w, channelId: c, threadId: Self.thread), binding: b), .showConversation)
        XCTAssertEqual(FamilyRouting.resolve(.thread(workspaceId: w.uppercased(), channelId: c, threadId: Self.thread.uppercased()), binding: b), .showConversation)
        XCTAssertEqual(FamilyRouting.resolve(.threadById(workspaceId: w, threadId: Self.thread), binding: b), .showConversation)
        XCTAssertEqual(FamilyRouting.resolve(.thread(workspaceId: w, channelId: c, threadId: Self.otherThread), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.thread(workspaceId: Fixtures.workspaceId2, channelId: c, threadId: Self.thread), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.thread(workspaceId: w, channelId: Fixtures.channel2, threadId: Self.thread), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.threadById(workspaceId: w, threadId: Self.otherThread), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.channel(workspaceId: w, channelId: c), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.task(workspaceId: w, taskId: "t"), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.doc(workspaceId: w, docId: "d"), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.notification(workspaceId: w, notificationId: "n"), binding: b), .ignore)
        XCTAssertEqual(FamilyRouting.resolve(.thread(workspaceId: w, channelId: c, threadId: Self.thread), binding: nil), .ignore)
    }

    // MARK: Setup choices

    func testOptionsIncludeSingleMessageConversationsAndSortNewestFirst() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let w = Fixtures.workspaceId, c = Fixtures.channel1
        let lonely = UUID().uuidString.lowercased(), busy = UUID().uuidString.lowercased()
        func message(_ thread: String, _ body: String, _ at: String) -> MessageRecord {
            MessageRecord(workspaceId: w, id: UUID().uuidString.lowercased(), channelId: c, threadId: thread, threadSourceId: nil, body: body, senderNpub: TestKeys.npub, createdAt: at)
        }
        try await store.writer.upsertMessages([message(lonely, "Anyone for Sunday?", "2026-11-01T10:00:00.000Z"),
                                               message(busy, "Photos from the park", "2026-11-02T10:00:00.000Z"),
                                               message(busy, "Lovely", "2026-11-02T10:05:00.000Z")])
        let normal = try await store.reader.channelThreads(workspaceId: w, channelId: c)
        XCTAssertEqual(normal.map(\.id), [busy], "Ambulando's thread list is unchanged")
        let all = try await store.reader.channelThreads(workspaceId: w, channelId: c, minimumMessages: 1)
        let options = FamilyConversationOption.options(from: all)
        XCTAssertEqual(options.map(\.id), [busy, lonely])
        XCTAssertEqual(options[1].title, "Anyone for Sunday?")
        XCTAssertEqual(options[0].messageCount, 2)
    }

    func testOptionsFromTowerThreadListSkipDeletedAndMarkArchived() throws {
        func record(_ id: String, title: String?, latest: String?, state: String, at: String) throws -> ThreadRecord {
            try ThreadRecord(raw: Fixtures.json(["id": id, "workspace_id": Fixtures.workspaceId, "channel_id": Fixtures.channel1, "source_message_id": NSNull(),
                                                 "title": title as Any? ?? NSNull(), "latest": latest as Any? ?? NSNull(), "record_state": state,
                                                 "row_version": 1, "updated_at": at]))
        }
        let a = "7a1c0000-0000-4000-8000-00000000000a", b = "7a1c0000-0000-4000-8000-00000000000b", c = "7a1c0000-0000-4000-8000-00000000000c"
        let options = FamilyConversationOption.options(fromThreads: [
            try record(a, title: "Sunday lunch", latest: "See you at one", state: "active", at: "2026-11-02T10:00:00.000Z"),
            try record(b, title: nil, latest: "Photos from the park", state: "archived", at: "2026-11-03T10:00:00.000Z"),
            try record(c, title: "Gone", latest: nil, state: "deleted", at: "2026-11-04T10:00:00.000Z")])
        XCTAssertEqual(options.map(\.id), [b, a])
        XCTAssertEqual(options[0].title, "Photos from the park")
        XCTAssertTrue(options[0].archived)
        XCTAssertEqual(options[1].title, "Sunday lunch")
    }

    // MARK: Live verification before sending

    private func api(_ h: ChatHarness, workspaceIds: [String]? = nil, offline: Bool = false) throws -> TowerAPI {
        let ids = workspaceIds ?? [Fixtures.workspaceId]
        let transport = StubTransport { request in
            if offline { throw URLError(.notConnectedToInternet) }
            if request.url?.path == "/api/v4/flightdeck-pg/workspaces" { return (200, ["workspaces": ids.map { Fixtures.workspace($0, label: "Studio") }]) }
            return try h.tower.handler()(request)
        }
        return TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: h.identity))
    }

    func testVerificationConfirmsTheBoundThreadAndNothingElse() async throws {
        let h = try await ChatHarness.make()
        let root = h.tower.seed(channel: Fixtures.channel1, body: "Family")
        let threadId = root["thread_id"] as! String
        var b = binding(thread: threadId)
        b.connectionId = h.connection.id
        let confirmed = await FamilyVerification.verify(b, api: try api(h))
        guard case .confirmed(let thread) = confirmed else { return XCTFail("\(confirmed)") }
        XCTAssertEqual(thread.id, threadId)

        // Bound to a thread that Tower no longer has: lost, and no other thread is considered.
        h.tower.seed(channel: Fixtures.channel1, body: "Another conversation")
        let gone = binding(thread: Self.otherThread)
        let lost = await FamilyVerification.verify(gone, api: try api(h))
        XCTAssertEqual(lost, .channelOrThreadLost)

        // The thread belongs to a different channel than the binding names.
        var moved = b
        moved = FamilyBinding(connectionId: b.connectionId, origin: b.origin, signerNpub: b.signerNpub, workspaceId: b.workspaceId, appNpub: b.appNpub,
                              workspaceLabel: b.workspaceLabel, channelId: Fixtures.channel2, channelName: "Other", threadId: threadId, conversationTitle: b.conversationTitle)
        let mismatch = await FamilyVerification.verify(moved, api: try api(h))
        XCTAssertEqual(mismatch, .channelOrThreadLost)
    }

    func testVerificationReportsLostWorkspaceAndOfflineSeparately() async throws {
        let h = try await ChatHarness.make()
        let root = h.tower.seed(channel: Fixtures.channel1, body: "Family")
        var b = binding(thread: root["thread_id"] as! String)
        b.connectionId = h.connection.id
        let removed = await FamilyVerification.verify(b, api: try api(h, workspaceIds: [Fixtures.workspaceId2]))
        XCTAssertEqual(removed, .workspaceLost)
        let offline = await FamilyVerification.verify(b, api: try api(h, offline: true))
        guard case .unreachable = offline else { return XCTFail("\(offline)") }
        XCTAssertFalse(offline.allowsSend)
    }
}


/// The per-attempt guard on every outbox: a queued or background-retried message is re-checked against the binding and
/// Tower at the moment it would be posted.
final class FamilySendGuardTests: XCTestCase {
    final class BindingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [FamilyBinding?]
        private(set) var reads = 0
        init(_ values: [FamilyBinding?]) { self.values = values }
        func set(_ value: FamilyBinding?) { lock.withLock { values = [value] } }
        func read() -> FamilyBinding? { lock.withLock { reads += 1; return values.count > 1 ? values.removeFirst() : values.first ?? nil } }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value: Bool
        init(_ value: Bool) { self.value = value }
        var isOn: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    func binding(thread: String, channel: String = Fixtures.channel1) -> FamilyBinding {
        FamilyBinding(connectionId: "c", origin: "https://tower.example", signerNpub: TestKeys.npub, workspaceId: Fixtures.workspaceId,
                      appNpub: Fixtures.appNpub, workspaceLabel: "Studio", channelId: channel, channelName: "Family",
                      threadId: thread, conversationTitle: "Family")
    }

    func sender(_ h: ChatHarness, slot: OutboxGuardSlot?, online: Flag = Flag(true)) -> OutboxSender {
        let transport = StubTransport { request in
            if !online.isOn, request.httpMethod == "GET" { throw URLError(.notConnectedToInternet) }
            if request.url?.path == "/api/v4/flightdeck-pg/workspaces" { return (200, ["workspaces": [Fixtures.workspace(Fixtures.workspaceId, label: "Studio")]]) }
            return try h.tower.handler()(request)
        }
        return OutboxSender(store: h.store, engine: h.engine, identity: h.identity, transport: transport, guardSlot: slot)
    }

    func slot(_ box: BindingBox) -> OutboxGuardSlot {
        let slot = OutboxGuardSlot(failClosed: true)
        slot.install(FamilySendGuard.make { _ in box.read() })
        return slot
    }

    func state(_ h: ChatHarness, _ id: String) async throws -> OutboxItem? { try await h.store.reader.outboxItem(id: id) }

    func testBoundConversationIsSentAfterAFreshCheck() async throws {
        let h = try await ChatHarness.make()
        let thread = h.tower.seed(channel: Fixtures.channel1, body: "Family")["thread_id"] as! String
        let box = BindingBox([binding(thread: thread)])
        let outbox = sender(h, slot: slot(box))
        let item = try await XCTUnwrapAsync(try await outbox.send(text: "Hello", mentions: [], target: h.target(thread: thread), connection: h.connection, workspace: h.workspace))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.tower.recordedPosts.count, 1)
        let remaining = try await state(h, item.id)
        XCTAssertNil(remaining, "accepted and retired")
        XCTAssertGreaterThanOrEqual(box.reads, 2, "the binding is read before and after the check")
    }

    func testChangingTheFamilyChatStopsQueuedMessagesFromGoingToTheOldOne() async throws {
        let h = try await ChatHarness.make()
        let old = h.tower.seed(channel: Fixtures.channel1, body: "Old family")["thread_id"] as! String
        let new = h.tower.seed(channel: Fixtures.channel1, body: "New family")["thread_id"] as! String
        let box = BindingBox([binding(thread: new)])      // the person has since chosen another conversation
        let outbox = sender(h, slot: slot(box))
        let item = try await XCTUnwrapAsync(try await outbox.send(text: "Meant for old", mentions: [], target: h.target(thread: old), connection: h.connection, workspace: h.workspace))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.tower.recordedPosts.count, 0)
        let blocked = try await state(h, item.id)
        XCTAssertEqual(blocked?.state, .failed)
        XCTAssertEqual(blocked?.threadId, old, "never retargeted")
        box.set(nil)                                          // and with no binding at all
        try await outbox.retry(item.id, connection: h.connection)
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.tower.recordedPosts.count, 0)
    }

    func testAThreadArchivedAfterQueueingIsNotReopened() async throws {
        let h = try await ChatHarness.make()
        let thread = h.tower.seed(channel: Fixtures.channel1, body: "Family")["thread_id"] as! String
        let box = BindingBox([binding(thread: thread)])
        h.tower.setThreadState(thread, "archived")
        let outbox = sender(h, slot: slot(box))
        let item = try await XCTUnwrapAsync(try await outbox.send(text: "Too late", mentions: [], target: h.target(thread: thread), connection: h.connection, workspace: h.workspace))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.tower.recordedPosts.count, 0)
        let blocked = try await state(h, item.id)
        XCTAssertEqual(blocked?.state, .failed)
        XCTAssertTrue(blocked?.lastError?.contains("archived") == true)
    }

    func testOfflineHoldsTheMessageAndSendsItToTheSameConversationLater() async throws {
        let h = try await ChatHarness.make()
        let thread = h.tower.seed(channel: Fixtures.channel1, body: "Family")["thread_id"] as! String
        let box = BindingBox([binding(thread: thread)])
        let online = Flag(false)
        let outbox = sender(h, slot: slot(box), online: online)
        let item = try await XCTUnwrapAsync(try await outbox.send(text: "Later", mentions: [], target: h.target(thread: thread), connection: h.connection, workspace: h.workspace))
        try await waitFor { try await h.store.reader.outboxItem(id: item.id)?.state == .retrying }
        XCTAssertEqual(h.tower.recordedPosts.count, 0, "nothing is posted while the target cannot be checked")
        let held = try await state(h, item.id)
        XCTAssertEqual(held?.state, .retrying)
        online.isOn = true
        try await outbox.retry(item.id, connection: h.connection)
        await h.engine.waitUntilIdle()
        try await waitFor { try await h.store.reader.outboxItem(id: item.id) == nil }
        let post = try XCTUnwrap(h.tower.recordedPosts.first)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: post.body) as? [String: Any])?["thread_id"] as? String, thread)
        XCTAssertEqual(h.tower.recordedPosts.count, 1)
    }

    func testNothingIsSentUntilAGuardIsInstalled() async throws {
        let h = try await ChatHarness.make()
        let thread = h.tower.seed(channel: Fixtures.channel1, body: "Family")["thread_id"] as! String
        let slot = OutboxGuardSlot(failClosed: true)
        let outbox = sender(h, slot: slot)
        let item = try await XCTUnwrapAsync(try await outbox.send(text: "Early", mentions: [], target: h.target(thread: thread), connection: h.connection, workspace: h.workspace))
        try await waitFor { try await h.store.reader.outboxItem(id: item.id)?.state == .retrying }
        XCTAssertEqual(h.tower.recordedPosts.count, 0)
        let early = try await state(h, item.id)
        XCTAssertEqual(early?.state, .retrying)
        let fixed = binding(thread: thread)
        slot.install(FamilySendGuard.make { _ in fixed })
        try await outbox.retry(item.id, connection: h.connection)
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.tower.recordedPosts.count, 1)
    }

    func testABindingChangeWhileTowerIsBeingAskedBlocksTheSend() async throws {
        let h = try await ChatHarness.make()
        let thread = h.tower.seed(channel: Fixtures.channel1, body: "Family")["thread_id"] as! String
        let other = h.tower.seed(channel: Fixtures.channel1, body: "Other")["thread_id"] as! String
        let box = BindingBox([binding(thread: thread), binding(thread: other)])   // changed between the two reads
        let outbox = sender(h, slot: slot(box))
        let item = try await XCTUnwrapAsync(try await outbox.send(text: "Racing", mentions: [], target: h.target(thread: thread), connection: h.connection, workspace: h.workspace))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.tower.recordedPosts.count, 0)
        let blocked = try await state(h, item.id)
        XCTAssertEqual(blocked?.state, .failed)
    }

    func testRowsAreAdmittedOnlyForTheExactOriginSignerWorkspaceChannelAndThread() throws {
        let b = binding(thread: FamilyBindingTests.thread)
        func item(origin: String = "https://tower.example", signer: String = TestKeys.npub, workspace: String = Fixtures.workspaceId,
                  app: String = Fixtures.appNpub, channel: String = Fixtures.channel1, thread: String? = FamilyBindingTests.thread) -> OutboxItem {
            OutboxItem(id: UUID().uuidString, connectionId: "other-connection-id", origin: origin, signerNpub: signer, workspaceId: workspace, appNpub: app,
                       channelId: channel, threadId: thread, createThread: false, body: "x", mentions: [], request: nil, state: .queued, attempts: 0,
                       lastStatus: nil, lastCode: nil, lastError: nil, createdAt: "2026-11-01T00:00:00.000Z", attachments: [])
        }
        XCTAssertTrue(b.admits(item()), "a reconnect to the same NStack may carry another connection id")
        XCTAssertFalse(b.admits(item(origin: "https://elsewhere.example")))
        XCTAssertFalse(b.admits(item(signer: Bech32.encode(hrp: "npub", data: Data(repeating: 0x22, count: 32)))))
        XCTAssertFalse(b.admits(item(workspace: Fixtures.workspaceId2)))
        XCTAssertFalse(b.admits(item(app: "npub1other")))
        XCTAssertFalse(b.admits(item(channel: Fixtures.channel2)))
        XCTAssertFalse(b.admits(item(thread: FamilyBindingTests.otherThread)))
        XCTAssertFalse(b.admits(item(thread: nil)), "a new conversation is never admitted")
    }
}
