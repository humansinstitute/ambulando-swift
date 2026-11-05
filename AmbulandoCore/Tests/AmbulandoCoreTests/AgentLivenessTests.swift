import XCTest
@testable import AmbulandoCore

/// Live agent activity: local lease evaluation against Tower's clock, order-independent merge of snapshots and stream
/// events, public commentary from the open conversation's snapshot, stream deltas and delivery-cursor recovery.
final class AgentLivenessTests: XCTestCase {
    let scope = Fixtures.scopeA
    let f = ISO8601DateFormatter.tower

    private func record(id: String = "7e1a0000-0000-4000-8000-000000000001", turn: String? = "turn-1", state: String = "working", sequence: Int,
                        lease: Date?, epoch: Int? = nil, leaseSequence: Int? = nil, expiredAt: Date? = nil, body: String? = nil,
                        created: String = "2026-11-04T02:00:00.000Z", channel: String = Fixtures.channel1, thread: String = "7e1a0000-0000-4000-8000-0000000000aa", agent: String = TestKeys.npub) -> AgentActivityRecord {
        var o: [String: Any] = ["id": id, "workspace_id": Fixtures.workspaceId, "channel_id": channel, "thread_id": thread, "activity_id": "act-1",
                                "visibility": "user_visible", "sequence": sequence, "state": state, "agent_npub": agent, "created_at": created,
                                "updated_at": created, "lease_health": "live"]
        if let turn { o["turn_id"] = turn }
        if let lease { o["lease_expires_at"] = f.string(from: lease) }
        if let epoch { o["lease_epoch"] = epoch }
        if let leaseSequence { o["lease_sequence"] = leaseSequence }
        if let expiredAt { o["expired_at"] = f.string(from: expiredAt) }
        if let body { o["body"] = body }
        if AgentActivityRecord.terminalStates.contains(state) { o["terminal_at"] = created }
        return try! AgentActivityRecord(raw: JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
    }

    // MARK: Lease evaluation

    func testWorkingClearsAtDeadlinePlusGraceAndTerminalAlwaysWins() {
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        let a = record(sequence: 3, lease: deadline)
        XCTAssertEqual(AgentLiveness.phase(a, now: deadline.addingTimeInterval(-60)), .working)
        XCTAssertEqual(AgentLiveness.phase(a, now: deadline.addingTimeInterval(14.9)), .working, "within the 15 s grace")
        XCTAssertEqual(AgentLiveness.phase(a, now: deadline.addingTimeInterval(15)), .stopped, "never shown as finished")
        XCTAssertEqual(AgentLiveness.clearsAt(a), deadline.addingTimeInterval(AgentLiveness.grace))
        XCTAssertFalse(AgentLiveness.isWorking(a, now: deadline.addingTimeInterval(20)))

        let done = record(state: "completed", sequence: 4, lease: deadline.addingTimeInterval(-3600))
        XCTAssertEqual(AgentLiveness.phase(done, now: deadline), .completed, "terminal regardless of the lease")
        XCTAssertNil(AgentLiveness.clearsAt(done))
        XCTAssertEqual(AgentLiveness.phase(record(state: "failed", sequence: 4, lease: nil), now: deadline), .failed)

        XCTAssertEqual(AgentLiveness.phase(record(state: "queued", sequence: 1, lease: deadline), now: deadline), .queued(position: nil))
        XCTAssertEqual(AgentLiveness.phase(record(state: "waiting", sequence: 1, lease: deadline), now: deadline), .waiting)
        XCTAssertFalse(AgentLiveness.isWorking(record(state: "queued", sequence: 1, lease: deadline), now: deadline), "queued is not working")
        XCTAssertEqual(AgentLiveness.phase(record(sequence: 1, lease: deadline, epoch: 1, leaseSequence: 2, expiredAt: deadline), now: deadline.addingTimeInterval(-100)),
                       .stopped, "Tower's recorded expiry is final for its epoch")
        XCTAssertEqual(AgentLiveness.phase(record(sequence: 1, lease: nil), now: deadline), .stopped, "no lease: never claims to be live")

        let later = record(id: "7e1a0000-0000-4000-8000-000000000002", sequence: 1, lease: deadline.addingTimeInterval(100))
        XCTAssertEqual(AgentLiveness.nextChange([a, later, done], now: deadline), deadline.addingTimeInterval(15))
        XCTAssertEqual(AgentLiveness.nextChange([a, later], now: deadline.addingTimeInterval(16)), deadline.addingTimeInterval(115))
    }

    func testServerClockUsesMonotonicAnchorNotTheDeviceClock() {
        final class Box: @unchecked Sendable { var wall = Date(timeIntervalSince1970: 1_000); var mono: UInt64 = 5_000_000_000 }
        let box = Box()
        let clock = ServerClock(wall: { box.wall }, monotonic: { box.mono })
        let origin = "https://tower.example"
        XCTAssertEqual(clock.now(origin: origin), box.wall, "uncalibrated: the device clock")
        // Tower is five minutes ahead of this device.
        clock.observe(origin: origin, serverTime: Date(timeIntervalSince1970: 1_300), roundTrip: 0.2, resolution: 1)
        XCTAssertEqual(clock.now(origin: origin).timeIntervalSince1970, 1_300.1, accuracy: 0.001)
        XCTAssertEqual(clock.offset(origin: origin)!, 300.1, accuracy: 0.001)
        // The device clock is changed by the user; only monotonic time moves Tower's clock.
        box.wall = Date(timeIntervalSince1970: 50_000)
        box.mono += 10_000_000_000
        XCTAssertEqual(clock.now(origin: origin).timeIntervalSince1970, 1_310.1, accuracy: 0.001)
        // A less precise sample does not replace a recent precise one.
        clock.observe(origin: origin, serverTime: Date(timeIntervalSince1970: 9_999), roundTrip: 8, resolution: 1)
        XCTAssertEqual(clock.now(origin: origin).timeIntervalSince1970, 1_310.1, accuracy: 0.001)
        // A cold launch restores a persisted offset only until the process has its own sample.
        let cold = ServerClock(wall: { Date(timeIntervalSince1970: 2_000) }, monotonic: { 1 })
        cold.restore(origin: origin, offset: -60)
        XCTAssertEqual(cold.now(origin: origin).timeIntervalSince1970, 1_940, accuracy: 0.001)
        XCTAssertEqual(ServerClock.httpDate("Wed, 04 Nov 2026 02:11:39 GMT"), f.date(from: "2026-11-04T02:11:39.000Z"))
        XCTAssertNil(ServerClock.httpDate("yesterday"))
    }

    // MARK: Merge

    func testMergeIsOrderIndependentAndTerminalWins() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let copies = [record(sequence: 3, lease: t0, body: "Reading the repo"),
                      record(sequence: 5, lease: t0.addingTimeInterval(120), body: "Running tests"),
                      record(state: "completed", sequence: 6, lease: t0.addingTimeInterval(60)),
                      record(sequence: 4, lease: t0.addingTimeInterval(60))]
        func permutations(_ a: [AgentActivityRecord]) -> [[AgentActivityRecord]] {
            a.count <= 1 ? [a] : a.indices.flatMap { i -> [[AgentActivityRecord]] in
                var rest = a; let x = rest.remove(at: i); return permutations(rest).map { [x] + $0 }
            }
        }
        var results = Set<Data>()
        for order in permutations(copies) {
            var merged: AgentActivityRecord?
            for copy in order { merged = AgentLiveness.merge(merged, copy) }
            XCTAssertEqual(merged?.state, "completed")
            results.insert(merged!.raw)
        }
        XCTAssertEqual(results.count, 1, "every arrival order converges")
        // A late non-terminal replay never reopens a finished lifecycle, even with a higher sequence.
        let finished = AgentLiveness.merge(nil, record(state: "cancelled", sequence: 2, lease: t0))!
        XCTAssertEqual(AgentLiveness.merge(finished, record(sequence: 9, lease: t0.addingTimeInterval(999)))?.state, "cancelled")
        // A different turn of the same row is refused.
        XCTAssertNil(AgentLiveness.merge(finished, record(turn: "turn-2", sequence: 10, lease: t0)))
        // A pre-contract row learns its turn identity.
        XCTAssertEqual(AgentLiveness.merge(record(turn: nil, sequence: 1, lease: t0), record(sequence: 2, lease: t0))?.turnId, "turn-1")
    }

    func testV2LeaseOrderingIsIndependentOfStateSequence() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // A renewal (epoch 1, lease 9) reached the client before a state write that does not move the lease.
        let renewed = record(sequence: 4, lease: t0.addingTimeInterval(180), epoch: 1, leaseSequence: 9)
        let state = record(sequence: 5, lease: t0, epoch: 1, leaseSequence: 3, body: "Writing the report")
        for merged in [AgentLiveness.merge(renewed, state)!, AgentLiveness.merge(state, renewed)!] {
            XCTAssertEqual(merged.sequence, 5); XCTAssertEqual(merged.body, "Writing the report")
            XCTAssertEqual(merged.leaseExpiresAt, t0.addingTimeInterval(180)); XCTAssertEqual(merged.leaseSequence, 9)
        }
        // A resume starts epoch 2; an old-epoch renewal replayed later does not replace it.
        let resumed = record(sequence: 6, lease: t0.addingTimeInterval(600), epoch: 2, leaseSequence: 1)
        let old = record(sequence: 6, lease: t0.addingTimeInterval(900), epoch: 1, leaseSequence: 40)
        XCTAssertEqual(AgentLiveness.merge(resumed, old)?.leaseEpoch, 2)
        XCTAssertEqual(AgentLiveness.merge(old, resumed)?.leaseExpiresAt, t0.addingTimeInterval(600))
        // Tower's lease events reuse the snapshot envelope (same `sequence`): an expiry of epoch 2 survives a later-arriving
        // copy of that epoch, and a resume (epoch 3) clears it.
        let expired = record(sequence: 6, lease: t0.addingTimeInterval(600), epoch: 2, leaseSequence: 1, expiredAt: t0.addingTimeInterval(601))
        XCTAssertNotNil(AgentLiveness.merge(expired, resumed)?.expiredAt)
        XCTAssertNotNil(AgentLiveness.merge(resumed, expired)?.expiredAt)
        let again = record(sequence: 6, lease: t0.addingTimeInterval(900), epoch: 3, leaseSequence: 0)
        XCTAssertNil(AgentLiveness.merge(expired, again)?.expiredAt)
        XCTAssertEqual(AgentLiveness.phase(AgentLiveness.merge(again, expired)!, now: t0.addingTimeInterval(700)), .working, "resumed")
    }

    // MARK: Store and sync

    func testStreamEventsRenewLeaseAndDeliverCommentaryWithoutARefetch() async throws {
        let h = try await SurfaceHarness.make()
        let thread = UUID().uuidString.lowercased()
        let id = h.tower.seedActivity(channel: Fixtures.channel1, scope: scope, thread: thread, agent: TestKeys.npub, state: "accepted", label: "Accepted",
                                      leaseSeconds: 30, turnId: "turn-a")
        let before = h.transport.recorded.count
        var events: [TowerEvent] = []
        for (n, text) in ["Reading the repository", "Running the focused tests"].enumerated() {
            let payload = try XCTUnwrap(h.tower.publishActivity(id, state: "working", label: "Working", body: text, leaseSeconds: 180))
            events.append(activityEvent(n + 1, id: id, payload: payload))
        }
        try await h.sync.applyEvents(events, h.connection, h.workspace)
        XCTAssertEqual(h.transport.recorded.count, before, "lifecycle and commentary come from the event payload")
        let stored = try await h.store.reader.threadAgentActivities(workspaceId: h.workspace.id, threadId: thread)
        XCTAssertEqual(stored.map(\.turnId), ["turn-a"])
        XCTAssertEqual(stored.first?.body, "Running the focused tests")
        XCTAssertGreaterThan(stored.first!.leaseExpiresAt!, Date().addingTimeInterval(150), "the renewal's deadline reached the client")
        let history = try await h.store.reader.agentCommentary(workspaceId: h.workspace.id, activityRowIds: [id])
        XCTAssertEqual(history[id]?.map(\.text), ["Reading the repository", "Running the focused tests"])

        // A replay of the first event (older sequence, earlier deadline) changes nothing; the terminal event clears it.
        try await h.sync.applyEvents([events[0]], h.connection, h.workspace)
        var current = try await h.store.reader.threadAgentActivities(workspaceId: h.workspace.id, threadId: thread)
        XCTAssertEqual(current.first?.body, "Running the focused tests")
        let done = try XCTUnwrap(h.tower.publishActivity(id, state: "completed", label: "Done"))
        try await h.sync.applyEvents([activityEvent(3, id: id, payload: done)], h.connection, h.workspace)
        current = try await h.store.reader.threadAgentActivities(workspaceId: h.workspace.id, threadId: thread)
        XCTAssertEqual(AgentLiveness.phase(current[0], now: Date()), .completed)
        let kept = try await h.store.reader.agentCommentary(workspaceId: h.workspace.id, activityRowIds: [id])
        XCTAssertEqual(kept[id]?.count, 2, "commentary stays as history of the finished turn")
        // A late working replay after terminal adds no liveness.
        try await h.sync.applyEvents([events[1]], h.connection, h.workspace)
        current = try await h.store.reader.threadAgentActivities(workspaceId: h.workspace.id, threadId: thread)
        XCTAssertEqual(current.first?.state, "completed")
    }

    func testOpenThreadReadsBoundedCommentaryAndRecoversMissedEntriesByDeliveryCursor() async throws {
        let h = try await SurfaceHarness.make()
        let thread = UUID().uuidString.lowercased()
        let id = h.tower.seedActivity(channel: Fixtures.channel1, scope: scope, thread: thread, agent: TestKeys.npub, state: "working", label: "Working",
                                      body: "Reading the brief", turnId: "turn-r")
        h.tower.seedActivity(channel: Fixtures.channel1, scope: scope, thread: UUID().uuidString.lowercased(), agent: TestKeys.npub, state: "working",
                             label: "Other thread", body: "Elsewhere")
        for n in 1...24 { h.tower.publishActivity(id, state: "working", label: "Working", body: "Step \(n)") }
        await h.sync.refreshThreadActivity(h.connection, h.workspace, channelId: Fixtures.channel1, threadId: thread)
        await h.idle()
        let query = try XCTUnwrap(h.transport.recorded.compactMap(\.url).last { $0.path.hasSuffix("/agent-activities") }?.query)
        XCTAssertTrue(query.contains("thread_id=\(thread)") && query.contains("history_limit=20"), query)
        var history = try await h.store.reader.agentCommentary(workspaceId: h.workspace.id, activityRowIds: [id])
        XCTAssertEqual(history[id]?.count, 20, "newest bounded page")
        XCTAssertEqual(history[id]?.last?.text, "Step 24")
        let stored = try await h.store.reader.threadAgentActivities(workspaceId: h.workspace.id, threadId: thread)
        XCTAssertEqual(stored.map(\.id), [id], "only the open conversation")
        let seeded = try await h.store.reader.agentCommentaryProgress(workspaceId: h.workspace.id, activityRowId: id)
        XCTAssertNotNil(seeded, "first materialisation seeds Tower's high-water cursor")

        // Entries published while the device was not listening (no events delivered) are recovered after the saved
        // cursor, in delivery order, and progress advances only with what was stored.
        for n in 25...27 { h.tower.publishActivity(id, state: "working", label: "Working", body: "Step \(n)") }
        await h.sync.refreshThreadActivity(h.connection, h.workspace, channelId: Fixtures.channel1, threadId: thread, force: true)
        await h.idle()
        let recovery = h.transport.recorded.compactMap(\.url).filter { $0.query?.contains("after_commentary_cursor=\(seeded!)") == true }
        XCTAssertEqual(recovery.count, 1)
        history = try await h.store.reader.agentCommentary(workspaceId: h.workspace.id, activityRowIds: [id])
        XCTAssertEqual(history[id]?.suffix(3).map(\.text), ["Step 25", "Step 26", "Step 27"])
        let progress = try await h.store.reader.agentCommentaryProgress(workspaceId: h.workspace.id, activityRowId: id)
        XCTAssertGreaterThan(Int(progress!)!, Int(seeded!)!)
        let failure = await h.error(WorkspaceSync.threadActivityKey(h.workspace.id, thread))
        XCTAssertNil(failure)
    }

    func testSnapshotFetchedBeforeAStreamEventCannotUndoIt() async throws {
        let h = try await SurfaceHarness.make()
        let served = Date()
        // The event (a newer lifecycle and a newer sequence) arrived while an older snapshot page was in flight.
        let newer = record(id: "7e1a0000-0000-4000-8000-0000000000b1", sequence: 7, lease: served.addingTimeInterval(170), body: "Newest",
                           created: f.string(from: served.addingTimeInterval(-1)))
        let old = record(id: "7e1a0000-0000-4000-8000-0000000000b2", sequence: 2, lease: served.addingTimeInterval(100), body: "Older",
                         created: f.string(from: served.addingTimeInterval(-600)))
        try await h.store.writer.mergeAgentActivities(workspaceId: h.workspace.id, [newer, record(id: old.id, sequence: 5, lease: served.addingTimeInterval(160),
                                                                                                    body: "Older, renewed", created: old.createdAt)])
        var page = TowerAPI.AgentActivityPage()
        page.activities = [old]
        page.serverTime = served
        try await h.store.writer.applyAgentActivityPage(workspaceId: h.workspace.id, channelId: Fixtures.channel1, page, limit: 50)
        let rows = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: [Fixtures.channel1])
        XCTAssertEqual(Set(rows.map(\.id)), [newer.id, old.id], "a lifecycle created while the page was in flight is kept")
        XCTAssertEqual(rows.first { $0.id == old.id }?.body, "Older, renewed", "a lower-sequence snapshot does not regress a newer copy")
        // A lifecycle the page proves gone (inside its window, created well before Tower answered) is removed.
        let gone = record(id: "7e1a0000-0000-4000-8000-0000000000b3", sequence: 1, lease: served, created: f.string(from: served.addingTimeInterval(-300)))
        try await h.store.writer.mergeAgentActivities(workspaceId: h.workspace.id, [gone])
        try await h.store.writer.applyAgentActivityPage(workspaceId: h.workspace.id, channelId: Fixtures.channel1, page, limit: 50)
        let after = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: [Fixtures.channel1])
        XCTAssertFalse(after.contains { $0.id == gone.id })
    }

    func testLeaseDeltasApplyOnlyWhenNewerAndExpiryCannotOverrideALaterRenewal() async throws {
        let h = try await SurfaceHarness.make()
        let t0 = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() + 60)
        let row = record(sequence: 2, lease: t0, epoch: 1, leaseSequence: 4)
        try await h.store.writer.mergeAgentActivities(workspaceId: h.workspace.id, [row])
        func payload(_ o: [String: Any]) -> TowerEvent {
            var e = TowerEvent(rowVersion: 1, cursor: "c1", workspaceId: Fixtures.workspaceId, entityType: "agent_activity", entityId: row.id,
                               operation: "updated", channelId: Fixtures.channel1)
            e.activityPayload = try! JSONSerialization.data(withJSONObject: o)
            return e
        }
        let renewal = payload(["activity_id": "act-1", "turn_id": "turn-1", "lease_epoch": 1, "lease_sequence": 5, "lease_expires_at": f.string(from: t0.addingTimeInterval(180))])
        let stale = payload(["activity_id": "act-1", "turn_id": "turn-1", "lease_epoch": 1, "lease_sequence": 3, "lease_expires_at": f.string(from: t0.addingTimeInterval(900))])
        let expiryOfOld = payload(["activity_id": "act-1", "turn_id": "turn-1", "lease_epoch": 1, "expired_at": f.string(from: t0), "lease_expires_at": f.string(from: t0)])
        XCTAssertTrue(EventPlan.make([renewal], workspaceId: Fixtures.workspaceId).refreshes.isEmpty, "applied directly, not refetched")
        try await h.sync.applyEvents([renewal, stale, expiryOfOld], h.connection, h.workspace)
        var stored = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: nil)
        XCTAssertEqual(stored.first?.leaseSequence, 5)
        XCTAssertEqual(stored.first?.leaseExpiresAt, t0.addingTimeInterval(180))
        XCTAssertNil(stored.first?.expiredAt, "an expiry of an earlier deadline does not override the later renewal")
        let expiry = payload(["activity_id": "act-1", "turn_id": "turn-1", "lease_epoch": 1, "expired_at": f.string(from: t0.addingTimeInterval(181)),
                              "lease_expires_at": f.string(from: t0.addingTimeInterval(180))])
        try await h.sync.applyEvents([expiry], h.connection, h.workspace)
        stored = try await h.store.reader.agentActivities(workspaceId: h.workspace.id, channelIds: nil)
        XCTAssertEqual(AgentLiveness.phase(stored[0], now: Date()), .stopped)
        // A payload without enough lease identity is refetched instead.
        let partial = payload(["activity_id": "act-1", "lease_epoch": 1])
        XCTAssertEqual(EventPlan.make([partial], workspaceId: Fixtures.workspaceId).refreshes, [.agentActivity(channelId: Fixtures.channel1)])
    }

    func testLosingChannelReadPurgesLifecyclesAndCommentary() async throws {
        let h = try await SurfaceHarness.make()
        let thread = UUID().uuidString.lowercased()
        let id = h.tower.seedActivity(channel: Fixtures.channel1, scope: scope, thread: thread, agent: TestKeys.npub, state: "working", label: "Working", body: "Private plan")
        await h.sync.refreshThreadActivity(h.connection, h.workspace, channelId: Fixtures.channel1, threadId: thread)
        await h.idle()
        var history = try await h.store.reader.agentCommentary(workspaceId: h.workspace.id, activityRowIds: [id])
        XCTAssertEqual(history[id]?.count, 1)
        h.tower.deny(channel: Fixtures.channel1)
        await h.sync.refreshThreadActivity(h.connection, h.workspace, channelId: Fixtures.channel1, threadId: thread, force: true)
        await h.idle()
        history = try await h.store.reader.agentCommentary(workspaceId: h.workspace.id, activityRowIds: [id])
        XCTAssertEqual(history[id]?.count ?? 0, 0)
        let rows = try await h.store.reader.threadAgentActivities(workspaceId: h.workspace.id, threadId: thread)
        XCTAssertTrue(rows.isEmpty)
    }

    func testDeckWorkingFlagFollowsTheLeaseNotJustTheState() {
        var sources = DeckActivity.Sources()
        let thread = "7e1a0000-0000-4000-8000-0000000000aa"
        sources.threads = [.init(threadId: thread, channelId: Fixtures.channel1, isThread: true, title: "Release", rootBody: nil, latestBody: "Go",
                                 latestAt: "2026-11-04T02:00:00.000Z", messageCount: 1)]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        sources.now = now
        sources.activities = [record(sequence: 3, lease: now.addingTimeInterval(30))]
        let item = DeckActivity.inbox(sources, context: .home)[0]
        XCTAssertTrue(item.isWorking(at: now))
        XCTAssertTrue(item.isWorking(at: now.addingTimeInterval(44)))
        XCTAssertFalse(item.isWorking(at: now.addingTimeInterval(45)), "clears at deadline + grace while the list stays on screen")
        sources.activities = [record(sequence: 3, lease: now.addingTimeInterval(-20))]
        XCTAssertNil(DeckActivity.inbox(sources, context: .home)[0].workingUntil, "an expired non-terminal lifecycle is not working")
        sources.activities = [record(state: "queued", sequence: 1, lease: now.addingTimeInterval(100))]
        XCTAssertNil(DeckActivity.inbox(sources, context: .home)[0].workingUntil)
    }

    func testCommentaryEntriesOfAnotherTurnOrNonPublicStateAreRefused() {
        let a = record(sequence: 1, lease: nil)
        XCTAssertNil(AgentCommentaryEntry(json: ["sequence": 1, "turn_id": "other", "body": "x"], activity: a))
        XCTAssertNil(AgentCommentaryEntry(json: ["sequence": 1, "visibility": "internal", "body": "x"], activity: a))
        XCTAssertNil(AgentCommentaryEntry(json: ["sequence": 1, "state": "completed", "body": "x"], activity: a))
        XCTAssertNil(AgentCommentaryEntry(json: ["sequence": 1, "agent_activity_id": "7e1a0000-0000-4000-8000-0000000000ff", "body": "x"], activity: a))
        XCTAssertNil(AgentCommentaryEntry(json: ["sequence": 1, "body": "  "], activity: a))
        let ok = AgentCommentaryEntry(json: ["sequence": 2, "turn_id": "turn-1", "body": "Reading", "delivery_cursor": "0012"], activity: a)
        XCTAssertEqual(ok?.text, "Reading")
        XCTAssertNil(ok?.deliveryCursor, "a malformed cursor is never used for recovery")
    }

    // MARK: Supersession of stale failures

    func testNewerWorkSupersedesOlderFailureOfSameAgentAndThreadOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let live = now.addingTimeInterval(60)
        let old = "2026-11-04T02:00:00.000Z", new = "2026-11-05T02:00:00.000Z"
        func id(_ n: Int) -> String { "7e1a0000-0000-4000-8000-00000000010\(n)" }
        let failed = record(id: id(1), state: "failed", sequence: 5, lease: nil, created: old)
        let working = record(id: id(2), sequence: 2, lease: live, created: new)
        XCTAssertEqual(AgentLiveness.supersededFailures([working, failed], now: now), [failed.id], "recovery: newer live work retires the failure")
        XCTAssertEqual(AgentLiveness.supersededFailures([failed, working], now: now), [failed.id], "input order is irrelevant")

        // Completion survives reconnect/history reload: no live row any more, the newer completion still supersedes.
        let done = record(id: id(2), state: "completed", sequence: 9, lease: nil, created: new)
        XCTAssertEqual(AgentLiveness.supersededFailures([failed, done], now: now.addingTimeInterval(86_400)), [failed.id])
        // Stopped and cancelled attempts are retired the same way.
        let stopped = record(id: id(3), sequence: 1, lease: now.addingTimeInterval(-600), created: old)
        let cancelled = record(id: id(4), state: "cancelled", sequence: 1, lease: nil, created: old)
        XCTAssertEqual(AgentLiveness.supersededFailures([stopped, cancelled, working], now: now), [stopped.id, cancelled.id])

        // Out-of-order replay: a delayed old failure (older created_at, bumped sequence) never resurrects over newer work
        // and a failure newer than the work is never masked.
        let replayed = record(id: id(1), state: "failed", sequence: 99, lease: nil, created: old)
        XCTAssertEqual(AgentLiveness.supersededFailures([working, replayed], now: now), [replayed.id])
        let currentFailure = record(id: id(5), state: "failed", sequence: 3, lease: nil, created: "2026-11-05T03:00:00.000Z")
        XCTAssertTrue(AgentLiveness.supersededFailures([working, currentFailure], now: now).isEmpty, "newer failure is current")
        XCTAssertTrue(AgentLiveness.supersededFailures([failed], now: now).isEmpty, "a lone failure stays")

        // Isolation: other agent, other thread, and non-authoritative successors do not supersede.
        let otherAgent = record(id: id(6), sequence: 2, lease: live, created: new, agent: "npub1other")
        let otherThread = record(id: id(7), sequence: 2, lease: live, created: new, thread: "7e1a0000-0000-4000-8000-0000000000bb")
        XCTAssertTrue(AgentLiveness.supersededFailures([failed, otherAgent, otherThread], now: now).isEmpty)
        let queued = record(id: id(8), state: "queued", sequence: 1, lease: live, created: new)
        let expired = record(id: id(9), sequence: 1, lease: now.addingTimeInterval(-600), created: new)
        XCTAssertTrue(AgentLiveness.supersededFailures([failed, queued, expired], now: now).isEmpty, "queued or lease-expired work is not fresh")
        // Existing lease expiry: once the newer work's lease lapses it stops superseding.
        XCTAssertTrue(AgentLiveness.supersededFailures([failed, working], now: live.addingTimeInterval(AgentLiveness.grace)).isEmpty)
    }

    private func activityEvent(_ row: Int, id: String, payload: [String: Any]) -> TowerEvent {
        var e = TowerEvent(rowVersion: row, cursor: "a\(row)", workspaceId: Fixtures.workspaceId, entityType: "agent_activity", entityId: id,
                           operation: "updated", channelId: Fixtures.channel1)
        e.activityPayload = try! JSONSerialization.data(withJSONObject: payload)
        return e
    }
}
