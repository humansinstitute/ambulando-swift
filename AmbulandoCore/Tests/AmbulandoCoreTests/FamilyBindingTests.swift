import Foundation
import XCTest
@testable import AmbulandoCore

final class FamilyBindingTests: XCTestCase {
    static let thread = "7a1c0000-0000-4000-8000-000000000001"
    static let otherThread = "7a1c0000-0000-4000-8000-000000000002"

    func binding(thread: String? = FamilyBindingTests.thread, pending: FamilyBinding.PendingCreation? = nil, signer: String = TestKeys.npub) -> FamilyBinding {
        FamilyBinding(connectionId: "conn-1", origin: "https://tower.example", signerNpub: signer, workspaceId: Fixtures.workspaceId,
                      appNpub: Fixtures.appNpub, workspaceLabel: "Studio", channelId: Fixtures.channel1, channelName: "Family",
                      threadId: thread, conversationTitle: "Sunday lunch", pendingCreation: pending)
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

    func testConversationBeingCreatedWaitsForTower() throws {
        let pending = FamilyCreationGate.makePending()
        let waiting = binding(thread: nil, pending: pending)
        XCTAssertTrue(waiting.isWellFormed)
        XCTAssertNil(waiting.target)
        XCTAssertEqual(FamilyAccessEvaluator.evaluate(waiting, try facts()), .awaitingCreation)
        XCTAssertFalse(binding(thread: nil).isWellFormed, "no thread and no creation in flight is not a binding")
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
        do { try await store.writer.setFamilyBinding(binding(thread: nil)); XCTFail("saved a binding with no conversation") }
        catch { XCTAssertEqual(error as? FamilyBindingError, .malformed) }
        try await store.writer.setState(StoreReader.familyBindingKey(signerNpub: TestKeys.npub), "{\"not\":\"a binding\"}")
        let none = try await store.reader.familyBinding(signerNpub: TestKeys.npub)
        XCTAssertNil(none)
    }

    func testChangeFamilyChatForgetsOnlyTheChoice() async throws {
        let h = try await ChatHarness.make()
        let mine = binding()
        try await h.store.writer.setFamilyBinding(mine)
        let target = try XCTUnwrap(mine.target)
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
        XCTAssertEqual(FamilyRouting.resolve(.threadById(workspaceId: w, threadId: Self.thread), binding: binding(thread: nil, pending: FamilyCreationGate.makePending())), .ignore)
    }

    func testOnlyTheBoundConversationPresentsABanner() {
        let b = binding()
        XCTAssertTrue(FamilyRouting.presentsBanner(.threadById(workspaceId: Fixtures.workspaceId, threadId: Self.thread), binding: b))
        XCTAssertFalse(FamilyRouting.presentsBanner(.threadById(workspaceId: Fixtures.workspaceId, threadId: Self.otherThread), binding: b))
        XCTAssertFalse(FamilyRouting.presentsBanner(nil, binding: b))
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

    func testCreationNeedsAFreshListingAndAnExplicitChoiceWhenConversationsExist() {
        let existing = [FamilyConversationOption(id: Self.thread, title: "Sunday lunch", firstMessage: "Hi", startedBy: nil, messageCount: 3,
                                                 lastActivityAt: "2026-11-02T10:00:00.000Z", archived: false)]
        XCTAssertEqual(FamilyCreationGate.check(refreshedFromTower: false, existing: [], acknowledgedExisting: false, firstMessage: "Hello"), .refreshRequired)
        XCTAssertEqual(FamilyCreationGate.check(refreshedFromTower: true, existing: existing, acknowledgedExisting: false, firstMessage: "Hello"), .existingConversations(existing))
        XCTAssertEqual(FamilyCreationGate.check(refreshedFromTower: true, existing: existing, acknowledgedExisting: true, firstMessage: "Hello"), .allowed)
        XCTAssertEqual(FamilyCreationGate.check(refreshedFromTower: true, existing: [], acknowledgedExisting: false, firstMessage: "  \n "), .emptyMessage)
        XCTAssertEqual(FamilyCreationGate.check(refreshedFromTower: true, existing: [], acknowledgedExisting: false, firstMessage: "Hello"), .allowed)
        let archivedOnly = [FamilyConversationOption(id: Self.thread, title: "Old", firstMessage: "", startedBy: nil, messageCount: 2, lastActivityAt: "", archived: true)]
        XCTAssertEqual(FamilyCreationGate.check(refreshedFromTower: true, existing: archivedOnly, acknowledgedExisting: false, firstMessage: "Hello"), .allowed)
    }

    // MARK: Creation idempotency

    func testRepeatedCreationRequestMakesOneConversationAndIsRecognisedAfterwards() async throws {
        let h = try await ChatHarness.make()
        let pending = FamilyCreationGate.makePending()
        h.tower.inject(.dropResponseAfterCommit)
        let first = try await h.outbox.send(text: "Hello family", mentions: [], target: h.target(), connection: h.connection, workspace: h.workspace,
                                            requestId: pending.requestId)
        XCTAssertEqual(first?.id, pending.requestId, "the fixed request id is the outbox row and the wire client_request_id")
        await h.engine.waitUntilIdle()
        // The answer was lost, so the row is still waiting; Tower already committed. Retry replays the same request.
        await h.outbox.kick(h.connection, force: true)
        await h.engine.waitUntilIdle()
        try await waitFor { try await h.store.reader.outboxItem(id: pending.requestId) == nil }
        XCTAssertEqual(h.tower.messageCount, 1, "Tower holds one message for the request id")
        let created = try await h.store.reader.familyCreatedThread(workspaceId: Fixtures.workspaceId, requestId: pending.requestId)
        XCTAssertNotNil(created, "the bound conversation can be recognised from the request id after relaunch")
        XCTAssertEqual(created?.body, "Hello family")
        let missing = try await h.store.reader.familyCreatedThread(workspaceId: Fixtures.workspaceId, requestId: UUID().uuidString)
        XCTAssertNil(missing)
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
        var b = binding(thread: root["thread_id"] as? String)
        b.connectionId = h.connection.id
        let removed = await FamilyVerification.verify(b, api: try api(h, workspaceIds: [Fixtures.workspaceId2]))
        XCTAssertEqual(removed, .workspaceLost)
        let offline = await FamilyVerification.verify(b, api: try api(h, offline: true))
        guard case .unreachable = offline else { return XCTFail("\(offline)") }
        XCTAssertFalse(offline.allowsSend)
    }
}
