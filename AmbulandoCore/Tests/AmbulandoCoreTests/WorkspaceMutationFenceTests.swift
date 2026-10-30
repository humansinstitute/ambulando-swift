import Foundation
import XCTest
@testable import AmbulandoCore

private actor MutationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

/// Commits the first POST on the fixture Tower, then returns its acknowledgement only after the test resumes it.
private actor CommittedSendTransport: HTTPTransport {
    let base: StubTransport
    let committed: MutationGate
    let release: MutationGate
    private var held = false
    init(base: StubTransport, committed: MutationGate, release: MutationGate) {
        self.base = base; self.committed = committed; self.release = release
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try await base.send(request)
        if request.httpMethod == "POST", !held {
            held = true
            await committed.release()
            await release.wait() // The server already accepted it; cancellation cannot undo that.
        }
        return response
    }
}

final class WorkspaceMutationFenceTests: XCTestCase {
    func testOldSchedulerLeaseCannotMutateScopesOrMessagesAfterPauseAndImmediateResume() async throws {
        let store = try LocalStore(directory: temporaryDirectory()), activity = WorkspaceActivity()
        await store.writer.bindWorkspaceActivity(activity)
        let pool = SyncEngine(), engine = SyncEngine(parent: pool, namespace: "private-workspace", activity: activity)
        let baseline = try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "current")))
        try await store.writer.upsertScopes(workspaceId: Fixtures.workspaceId, [baseline], complete: true)
        let stale = try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "stale", updated: "2026-10-30T00:00:00Z")))
        let message = try MessageRecord(raw: Fixtures.json(FakeChatTower().seed(channel: Fixtures.channel1, body: "late private result")))
        let suspended = MutationGate(), release = MutationGate(), finished = MutationGate(), rejected = Counter()
        await engine.enqueue("fetch:w") {
            // A normal child Task inherits the lease but not cancellation. Only the storage generation fence can
            // reject these writes after the workspace has already been re-enabled.
            Task {
                await suspended.release(); await release.wait()
                do { try await store.writer.upsertScopes(workspaceId: Fixtures.workspaceId, [stale], complete: true) }
                catch is CancellationError { await rejected.enter("scopes") }
                catch { }
                do { _ = try await store.writer.upsertMessages([message]) }
                catch is CancellationError { await rejected.enter("messages") }
                catch { }
                await finished.release()
            }
        }
        await suspended.wait()
        await engine.pause(); await engine.resume()
        await release.release(); await finished.wait(); await pool.waitUntilIdle()
        let labels = try await store.reader.scopes(workspaceId: Fixtures.workspaceId).map(\.name)
        let messages = try await store.reader.messageCount(workspaceId: Fixtures.workspaceId)
        let refusals = await rejected.order
        XCTAssertEqual(labels, ["current"])
        XCTAssertEqual(messages, 0)
        XCTAssertEqual(refusals, ["scopes", "messages"])
        // Fresh work in the new generation still materialises normally.
        await engine.enqueue("fetch:w", force: true) { _ = try await store.writer.upsertMessages([message]) }
        await pool.waitUntilIdle()
        let fresh = try await store.reader.messageCount(workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(fresh, 1)
    }

    func testLocalDraftAndNavigationWritesRemainAvailableWhilePaused() async throws {
        let h = try await ChatHarness.make(unlocked: false), activity = WorkspaceActivity()
        await h.store.writer.bindWorkspaceActivity(activity)
        activity.pause()
        try await h.store.writer.saveDraft(h.target(), Draft(text: "preserve this offline draft", mentions: []))
        let key = WorkContext.stateKey(connectionId: h.connection.id, workspaceId: h.workspace.id)
        let context = WorkContext(scopeId: Fixtures.scopeA, channelId: Fixtures.channel1)
        try await h.store.writer.setState(key, context.encoded())
        let reopened = try LocalStore(directory: h.directory.appendingPathComponent("Store"))
        let draft = try await reopened.reader.draft(h.target())
        let navigation = try await reopened.reader.state(key)
        XCTAssertEqual(draft?.text, "preserve this offline draft")
        XCTAssertEqual(WorkContext.decode(navigation), context)
    }

    func testLateDurableStateReconciliationRetainsFrozenIDsAndRequests() async throws {
        let h = try await ChatHarness.make(unlocked: false), activity = WorkspaceActivity()
        await h.store.writer.bindWorkspaceActivity(activity)
        _ = try await h.store.writer.enqueueSend(id: "frozen-send", target: h.target(), origin: h.connection.origin,
            signerNpub: h.connection.signerNpub, appNpub: h.workspace.appNpub, body: "in flight", mentions: [])
        let frozen = Data("{\"client_request_id\":\"frozen-send\",\"signed\":true}".utf8)
        try await h.store.writer.freezeOutbox(id: "frozen-send", request: frozen)
        _ = try await h.store.writer.enqueueWrite(id: "frozen-write", connection: h.connection, workspace: h.workspace,
            intent: WriteIntent(kind: .taskState, targetId: "same-task", payload: ["state": "done"]))
        try await h.store.writer.freezeWrite(id: "frozen-write", request: frozen)
        let lease = try activity.lease(), suspended = MutationGate(), release = MutationGate()
        let late = Task {
            try await activity.withLease(lease, checkingResult: false) {
                await suspended.release(); await release.wait()
                // These durable outcome writes must persist even though the originating content lease expired.
                try await h.store.writer.markOutbox(id: "frozen-send", state: .sending)
                try await h.store.writer.markWrite(id: "frozen-write", state: .sending)
                try await h.store.writer.updateWritePayload(id: "frozen-write", merging: ["ambiguous": true])
            }
        }
        await suspended.wait(); activity.pause(); activity.resume(); await release.release()
        try await late.value
        try await h.store.writer.resetInterruptedSends(); try await h.store.writer.resetInterruptedWrites()
        let send = try await h.store.reader.outboxItem(id: "frozen-send")
        let write = try await h.store.reader.writeItem(id: "frozen-write")
        XCTAssertEqual(send?.id, "frozen-send"); XCTAssertEqual(send?.request, frozen); XCTAssertEqual(send?.state, .queued)
        XCTAssertEqual(write?.id, "frozen-write"); XCTAssertEqual(write?.request, frozen); XCTAssertEqual(write?.state, .queued)
        XCTAssertEqual(write?.payloadObject["ambiguous"] as? Bool, true)
    }

    func testPauseAfterServerCommitReplaysSameFrozenRequestWithoutDuplicateMessage() async throws {
        let h = try await ChatHarness.make(), activity = WorkspaceActivity()
        await h.store.writer.bindWorkspaceActivity(activity)
        let pool = SyncEngine(), engine = SyncEngine(parent: pool, namespace: "one", activity: activity)
        let committed = MutationGate(), release = MutationGate()
        let base = CommittedSendTransport(base: h.transport, committed: committed, release: release)
        let sender = OutboxSender(store: h.store, engine: engine, identity: h.identity,
            transport: WorkspaceHTTPTransport(base: base, activity: activity))
        let enqueued = try await sender.send(text: "accepted before pause", mentions: [], target: h.target(),
            connection: h.connection, workspace: h.workspace)
        let item = try XCTUnwrap(enqueued)
        await committed.wait()
        XCTAssertEqual(h.tower.messageCount, 1)
        let frozenBefore = try await h.store.reader.outboxItem(id: item.id)?.request
        await engine.pause(); await engine.resume(); await release.release(); await pool.waitUntilIdle()
        let unknown = try await h.store.reader.outboxItem(id: item.id)
        XCTAssertEqual(unknown?.state, .queued)
        XCTAssertEqual(unknown?.request, frozenBefore)
        XCTAssertEqual(h.tower.recordedPosts.count, 1)
        await sender.kick(h.connection, force: true); await pool.waitUntilIdle()
        let retired = try await h.store.reader.outboxItem(id: item.id)
        XCTAssertNil(retired)
        XCTAssertEqual(h.tower.messageCount, 1, "The replay must reconcile the committed message instead of creating another")
        XCTAssertEqual(h.tower.recordedPosts.count, 2)
        XCTAssertEqual(h.tower.recordedPosts.first?.body, h.tower.recordedPosts.last?.body)
    }

    func testLateAcceptedAcknowledgementRollsBackContentAndRetainsItsRequestUntilResume() async throws {
        let h = try await ChatHarness.make(unlocked: false), activity = WorkspaceActivity()
        await h.store.writer.bindWorkspaceActivity(activity)
        _ = try await h.store.writer.enqueueSend(id: "accepted-send", target: h.target(), origin: h.connection.origin,
            signerNpub: h.connection.signerNpub, appNpub: h.workspace.appNpub, body: "accepted", mentions: [])
        let frozen = Data("{\"client_request_id\":\"accepted-send\"}".utf8)
        try await h.store.writer.freezeOutbox(id: "accepted-send", request: frozen)
        try await h.store.writer.markOutbox(id: "accepted-send", state: .sending)
        let accepted = try MessageRecord(raw: Fixtures.json(h.tower.seed(channel: Fixtures.channel1, body: "accepted")))
        let lease = try activity.lease(), suspended = MutationGate(), release = MutationGate()
        let late = Task {
            try await activity.withLease(lease) {
                await suspended.release(); await release.wait()
                try await h.store.writer.acknowledgeSend(id: "accepted-send", message: accepted, thread: nil)
            }
        }
        await suspended.wait(); activity.pause(); activity.resume(); await release.release()
        do { try await late.value; XCTFail("Stale accepted content was materialised") }
        catch is CancellationError { }
        let retained = try await h.store.reader.outboxItem(id: "accepted-send")
        let countBeforeResume = try await h.store.reader.messageCount(workspaceId: h.workspace.id)
        XCTAssertEqual(retained?.request, frozen); XCTAssertEqual(retained?.state, .sending)
        XCTAssertEqual(countBeforeResume, 0)
        try await h.store.writer.resetInterruptedSends()
        try await activity.withLease(activity.lease()) {
            try await h.store.writer.acknowledgeSend(id: "accepted-send", message: accepted, thread: nil)
        }
        let retired = try await h.store.reader.outboxItem(id: "accepted-send")
        let countAfterResume = try await h.store.reader.messageCount(workspaceId: h.workspace.id)
        XCTAssertNil(retired); XCTAssertEqual(countAfterResume, 1)
    }
}
