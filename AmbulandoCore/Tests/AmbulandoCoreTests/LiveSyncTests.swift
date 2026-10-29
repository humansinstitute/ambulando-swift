import Foundation
import XCTest
@testable import AmbulandoCore

/// Tower's event log (`GET /events`, `GET /sync?limit=1` head) on top of the fake chat routes, plus single-task reads.
/// Cursors are opaque to the client; here they encode the row version.
final class FakeEventTower: @unchecked Sendable {
    let chat: FakeChatTower
    let lock = NSLock()
    private(set) var events: [[String: Any]] = []
    private var rowVersion = 0
    var tasks: [String: [String: Any]] = [:]
    var eventStatus: Int?
    var eventFetches = 0
    var headFetches = 0
    var taskFetches = 0

    init(chat: FakeChatTower = FakeChatTower()) { self.chat = chat }

    static func cursor(_ row: Int) -> String { Data("ev:\(row)".utf8).base64EncodedString() }
    static func row(_ cursor: String?) -> Int? {
        guard let cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8), text.hasPrefix("ev:") else { return nil }
        return Int(text.dropFirst(3))
    }

    @discardableResult
    func emit(_ type: String, id: String?, op: String = "created", channel: String? = Fixtures.channel1, entityRowVersion: Int? = nil,
              payload: [String: Any] = [:], workspace: String = Fixtures.workspaceId) -> Int {
        lock.withLock {
            rowVersion += 1
            events.append(["id": UUID().uuidString.lowercased(), "cursor": Self.cursor(rowVersion), "row_version": rowVersion, "workspace_id": workspace,
                           "scope_id": NSNull(), "channel_id": channel as Any, "entity_type": type, "entity_id": id as Any, "operation": op,
                           "entity_row_version": entityRowVersion as Any, "payload": payload, "event_type": "flightdeck_pg.\(type).\(op)"])
            return rowVersion
        }
    }

    var head: Int { lock.withLock { rowVersion } }

    func handler() -> StubTransport.Handler {
        let chatHandler = chat.handler()
        return { [self] request in
            let url = request.url!
            let base = "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)"
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
            if url.path == base + "/events" {
                return lock.withLock {
                    eventFetches += 1
                    if let eventStatus { return (eventStatus, ["code": "x"]) }
                    guard let after = Self.row(q("cursor")) else { return (400, ["code": "validation_error"]) }
                    let limit = min(200, Int(q("limit") ?? "50") ?? 50)
                    let page = Array(events.filter { ($0["row_version"] as! Int) > after }.prefix(limit))
                    let next = page.last?["cursor"] as? String ?? (after > 0 ? Self.cursor(after) : nil)
                    return (200, ["events": page, "next_cursor": next as Any])
                }
            }
            if url.path == base + "/sync" {
                return lock.withLock { headFetches += 1; return (200, ["mode": "snapshot", "through_cursor": Self.cursor(rowVersion), "channel_bundles": []]) }
            }
            if url.path.hasPrefix(base + "/tasks/") {
                let parts = url.path.replacingOccurrences(of: base + "/tasks/", with: "").split(separator: "/").map(String.init)
                return lock.withLock {
                    taskFetches += 1
                    guard let task = tasks[parts[0]] else { return (404, ["code": "task_not_found"]) }
                    if parts.count == 2 { return (200, ["comments": [], "next_cursor": NSNull()]) }
                    return (200, ["task": task])
                }
            }
            if url.path.hasPrefix(base + "/scopes") || url.path.hasSuffix("/members") || url.path.hasSuffix("/scope-order")
                || url.path.hasSuffix("/resource-view-states") || url.path.hasSuffix("/tasks") || url.path.hasSuffix("/docs")
                || url.path.hasSuffix("/files") || url.path.hasSuffix("/file-folders") {
                let key = ["scopes", "members", "scope_order", "resources", "tasks", "docs", "files", "folders"]
                    .first { url.path.hasSuffix("/" + $0.replacingOccurrences(of: "_", with: "-")) } ?? "scopes"
                return (200, [key: [], "states": [], "next_cursor": NSNull(), "order": []])
            }
            // Main sync negotiates capabilities; priority pin reads do not advertise them.
            if url.path == base + "/record-sync" {
                guard q("protocol_version") == "1" else { return (400, ["error": "unsupported_protocol_version"]) }
                return (200, ["protocol_version": 1, "personal_pin_order_version": 1, "changes": [], "has_more": false])
            }
            // Reseed also lists pins, canvases, the Toolbox and agents; this workspace has none.
            if url.path == base + "/record-sync/priority" {
                return (200, ["protocol_version": 1, "captured_head": "0", "changes": [], "next_cursor": "done", "has_more": false])
            }
            if url.path == base + "/canvases" { return (200, ["workspace_id": Fixtures.workspaceId, "complete": true, "canvases": []]) }
            if url.path == base + "/personal-wapps" { return (200, ["personal_wapps": [], "next_cursor": NSNull()]) }
            if url.path == base + "/workspace-agents" { return (200, ["workspace_agents": [], "next_cursor": NSNull()]) }
            if url.path == "/api/v4/flightdeck-pg/workspaces" {
                return (200, ["workspaces": [Fixtures.workspace(Fixtures.workspaceId, label: "Studio")], "next_cursor": NSNull()])
            }
            return try chatHandler(request)
        }
    }

    static func task(_ id: String, title: String, version: Int, channel: String = Fixtures.channel1) -> [String: Any] {
        ["id": id, "workspace_id": Fixtures.workspaceId, "scope_id": Fixtures.scopeA, "channel_id": channel, "title": title, "description": NSNull(),
         "state": "new", "priority": "rock", "row_version": version, "activity_version": version,
         "created_at": "2026-10-01T00:00:00.000Z", "updated_at": "2026-10-0\(min(version, 9))T00:00:00.000Z"]
    }
}

struct LiveHarness {
    let chat: ChatHarness
    let tower: FakeEventTower
    let transport: StubTransport
    let sync: WorkspaceSync

    var store: LocalStore { chat.store }
    var connection: ConnectionRecord { chat.connection }
    var workspace: WorkspaceRecord { chat.workspace }

    static func make(unlocked: Bool = true, background: BackgroundCredentialStore? = nil) async throws -> LiveHarness {
        let chat = try await ChatHarness.make(unlocked: unlocked)
        let tower = FakeEventTower(chat: chat.tower)
        let transport = StubTransport(tower.handler())
        let identity: IdentityService
        if let background {
            identity = IdentityService(vaultURL: chat.directory.appendingPathComponent("vault.json"), secrets: chat.secretsCarrier, background: background)
            if unlocked { try await identity.unlock(pin: TestKeys.pin) }
        } else { identity = chat.identity }
        let sync = WorkspaceSync(store: chat.store, engine: chat.engine, identity: identity, transport: transport)
        return LiveHarness(chat: chat, tower: tower, transport: transport, sync: sync)
    }

    func cursor() async throws -> String? { try await store.reader.eventCursor(connectionId: connection.id, workspaceId: workspace.id) }
}

final class MemoryBackgroundStore: BackgroundCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: BackgroundReadCredential?
    func read() throws -> BackgroundReadCredential? { lock.withLock { value } }
    func write(_ credential: BackgroundReadCredential) throws { lock.withLock { value = credential } }
    func delete() throws { lock.withLock { value = nil } }
}

final class SSEParserTests: XCTestCase {
    func testFramesAcrossChunksLineEndingsAndComments() throws {
        var parser = SSEParser()
        let stream = "event: connected\r\ndata: {\"cursor\":\"a\"}\r\n\r\n: heartbeat\n\nid: 7\nevent: flightdeck_pg.event\ndata: line1\ndata: line2\n\n"
        var frames: [SSEFrame] = []
        for byte in Data(stream.utf8) { frames += try parser.feed(Data([byte])) }   // worst case: one byte per chunk
        XCTAssertEqual(frames, [SSEFrame(event: "connected", data: "{\"cursor\":\"a\"}", id: nil),
                                SSEFrame(event: "flightdeck_pg.event", data: "line1\nline2", id: "7")])
        XCTAssertEqual(parser.takeComments(), 1)
        // CR-only line ends and a frame without `event` (default "message").
        XCTAssertEqual(try parser.feed(Data("data:x\r\r".utf8)), [SSEFrame(event: "message", data: "x", id: nil)])
    }

    func testUnterminatedLineIsBounded() {
        var parser = SSEParser()
        XCTAssertThrowsError(try parser.feed(Data(repeating: 0x61, count: SSEParser.maxLine + 1)))
    }
}

final class EventPlanTests: XCTestCase {
    let w = Fixtures.workspaceId, c = Fixtures.channel1
    func event(_ type: String, _ id: String?, _ op: String = "updated", channel: String? = Fixtures.channel1, version: Int? = nil,
               parent: String? = nil, workspace: String = Fixtures.workspaceId, row: Int = 1) -> TowerEvent {
        TowerEvent(rowVersion: row, cursor: "c\(row)", workspaceId: workspace, entityType: type, entityId: id, operation: op,
                   channelId: channel, parentId: parent, entityRowVersion: version)
    }

    func testTargetedRefreshesTombstonesAndAccess() {
        let m = UUID().uuidString.lowercased(), gone = UUID().uuidString.lowercased(), t = UUID().uuidString.lowercased()
        let plan = EventPlan.make([
            event("message", m, "created", version: 1), event("message", m, "updated", version: 3),
            event("message", gone, "deleted"), event("task_comment", UUID().uuidString.lowercased(), "created", parent: t),
            event("resource_view_state", nil), event("channel_grant", nil), event("workroom", UUID().uuidString.lowercased()),
            event("message", UUID().uuidString.lowercased(), workspace: Fixtures.workspaceId2),
        ], workspaceId: w)
        XCTAssertTrue(plan.refreshes.contains(.message(channelId: c, messageId: m)))
        XCTAssertEqual(plan.versions[.message(channelId: c, messageId: m)], 3, "highest reported version wins")
        XCTAssertEqual(plan.tombstones, [.message(gone)])
        XCTAssertTrue(plan.refreshes.contains(.task(t)))
        XCTAssertNil(plan.versions[.task(t)], "a child change never skips the parent fetch")
        XCTAssertTrue(plan.refreshes.isSuperset(of: [.inbox, .access, .structure, .directory]))
        XCTAssertEqual(plan.ignored, 2, "unrendered type and other workspace")
    }

    func testBurstFoldsIntoChannelCatchUps() {
        let events = (0..<(EventPlan.targetedLimit + 1)).map { i in
            event(i % 2 == 0 ? "message" : "task", UUID().uuidString.lowercased(), "created", channel: i % 3 == 0 ? Fixtures.channel2 : Fixtures.channel1, row: i)
        }
        let plan = EventPlan.make(events, workspaceId: w)
        XCTAssertTrue(plan.folded)
        XCTAssertEqual(plan.refreshes, [.channelMessages(channelId: Fixtures.channel1), .channelMessages(channelId: Fixtures.channel2),
                                        .channelTasks(Fixtures.channel1), .channelTasks(Fixtures.channel2)])
    }

    func testDeletedRecordIsNotFetchedInSameBatch() {
        let t = UUID().uuidString.lowercased()
        let plan = EventPlan.make([event("task", t, "updated", version: 2), event("task", t, "deleted")], workspaceId: w)
        XCTAssertEqual(plan.tombstones, [.task(t)])
        XCTAssertFalse(plan.refreshes.contains(.task(t)))
    }
}

final class LiveSyncTests: XCTestCase {
    func testFirstCatchUpSeedsAtHeadWithoutReplayingHistory() async throws {
        let h = try await LiveHarness.make()
        for _ in 0..<500 { h.tower.emit("message", id: UUID().uuidString.lowercased()) }
        let result = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        XCTAssertTrue(result.seeded)
        XCTAssertEqual(h.tower.eventFetches, 0, "history is not replayed")
        let cursor = try await h.cursor()
        XCTAssertEqual(cursor.flatMap(FakeEventTower.row), 500)
    }

    func testIncrementalEventsMaterialiseAndTombstone() async throws {
        let h = try await LiveHarness.make()
        let kept = h.chat.tower.seed(channel: Fixtures.channel1, body: "hello")
        let removed = h.chat.tower.seed(channel: Fixtures.channel1, body: "bye")
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)   // seed
        let removedRow = try MessageRecord(raw: rawJSON(removed))
        try await h.store.writer.upsertMessages([removedRow])
        h.tower.emit("message", id: kept["id"] as? String, entityRowVersion: 1)
        h.tower.emit("message", id: removed["id"] as? String, op: "deleted")
        let result = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        XCTAssertEqual(result.events, 2)
        XCTAssertTrue(result.complete)
        let keptLocal = try await h.store.reader.message(workspaceId: h.workspace.id, id: kept["id"] as! String)
        let removedLocal = try await h.store.reader.message(workspaceId: h.workspace.id, id: removed["id"] as! String)
        XCTAssertEqual(keptLocal?.body, "hello")
        XCTAssertNil(removedLocal, "deleted message removed locally")
        let cursor = try await h.cursor()
        XCTAssertEqual(cursor.flatMap(FakeEventTower.row), h.tower.head)

        // A record already stored at the reported version is not fetched again.
        let gets = h.chat.tower.recordedGets.count
        h.tower.emit("message", id: kept["id"] as? String, entityRowVersion: 1)
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        XCTAssertEqual(h.chat.tower.recordedGets.count, gets)
    }

    func testFailedFetchKeepsCursorAndReplays() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        let before = try await h.cursor()
        let task = UUID().uuidString.lowercased()
        h.tower.emit("task", id: task, entityRowVersion: 2)
        h.transport.setHandler { request in
            if request.url!.path.contains("/tasks/") { throw URLError(.notConnectedToInternet) }
            return try h.tower.handler()(request)
        }
        do { _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace); XCTFail("expected failure") } catch {}
        let afterFailure = try await h.cursor()
        XCTAssertEqual(afterFailure, before, "cursor not advanced past an event that was not stored")
        h.tower.tasks[task] = FakeEventTower.task(task, title: "Live", version: 2)
        h.transport.setHandler(h.tower.handler())
        await h.sync.engine.waitUntilIdle()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        let stored = try await h.store.reader.task(workspaceId: h.workspace.id, id: task)
        XCTAssertEqual(stored?.title, "Live")
    }

    func testTaskAccessLossRemovesLocalCopy() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        let task = UUID().uuidString.lowercased()
        try await h.store.writer.upsertTasks(workspaceId: h.workspace.id, [try TaskRecord(raw: rawJSON(FakeEventTower.task(task, title: "Old", version: 1)))])
        h.tower.emit("task", id: task, entityRowVersion: 5)   // Tower now answers 404 for it
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        let local = try await h.store.reader.task(workspaceId: h.workspace.id, id: task)
        XCTAssertNil(local)
    }

    func testBacklogBeyondBudgetRecoversAtHead() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        for _ in 0..<(TowerAPI.eventPageLimit * 3) { h.tower.emit("resource_view_state", id: nil, channel: nil) }
        let result = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace, pages: 2)
        XCTAssertTrue(result.gapRecovered)
        XCTAssertEqual(result.pages, 2)
        let cursor = try await h.cursor()
        XCTAssertEqual(cursor.flatMap(FakeEventTower.row), h.tower.head, "skipped to the head, lists caught up directly")
    }

    func testRefusedCursorAndAccessLoss() async throws {
        let h = try await LiveHarness.make()
        try await h.store.writer.saveEventCursor(connectionId: h.connection.id, workspaceId: h.workspace.id, "not-a-cursor")
        let refused = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        XCTAssertTrue(refused.gapRecovered)
        h.tower.eventStatus = 403
        let lost = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        XCTAssertTrue(lost.accessLost)
    }

    func testChannelRemovedFromListPurgesItsContent() async throws {
        let h = try await LiveHarness.make()
        let w = h.workspace.id
        try await h.store.writer.upsertScopes(workspaceId: w, [ScopeRecord(workspaceId: w, id: Fixtures.scopeA, name: "A", rowVersion: 1, updatedAt: "2026-10-01T00:00:00.000Z", raw: Data("{}".utf8))], complete: true)
        try await h.store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [
            ChannelRecord(workspaceId: w, id: Fixtures.channel1, scopeId: Fixtures.scopeA, name: "one", rowVersion: 1, updatedAt: "2026-10-01T00:00:00.000Z", raw: Data("{}".utf8)),
            ChannelRecord(workspaceId: w, id: Fixtures.channel2, scopeId: Fixtures.scopeA, name: "two", rowVersion: 1, updatedAt: "2026-10-01T00:00:00.000Z", raw: Data("{}".utf8)),
        ], complete: true)
        try await h.store.writer.upsertMessages([try MessageRecord(raw: rawJSON(h.chat.tower.seed(channel: Fixtures.channel2, body: "secret")))])
        try await h.store.writer.upsertTasks(workspaceId: w, [try TaskRecord(raw: rawJSON(FakeEventTower.task(UUID().uuidString.lowercased(), title: "t", version: 1, channel: Fixtures.channel2)))])
        // Access to channel two is gone: the complete channel list no longer has it.
        try await h.store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [
            ChannelRecord(workspaceId: w, id: Fixtures.channel1, scopeId: Fixtures.scopeA, name: "one", rowVersion: 1, updatedAt: "2026-10-01T00:00:00.000Z", raw: Data("{}".utf8)),
        ], complete: true)
        let messages = try await h.store.reader.latestMessages(workspaceId: w, channelId: Fixtures.channel2, limit: 10)
        let tasks = try await h.store.reader.tasks(workspaceId: w, scopeId: nil)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(tasks.isEmpty)
    }
}

/// The SSE path end to end with a scripted stream: catch-up, connected frame, live events applied in a batch, cursor
/// saved only after storage, reconnect after the server closes, access revocation.
final class LiveStreamTests: XCTestCase {
    final class ScriptedStreams: EventStreamTransport, @unchecked Sendable {
        let lock = NSLock()
        var scripts: [(Int, [String])] = []
        /// Connection numbers (0-based) whose body fails with a buffer overflow after its frames.
        var overflowAfter: Set<Int> = []
        var opened: [URLRequest] = []
        func open(_ request: URLRequest) async throws -> (HTTPURLResponse, EventChunks) {
            let (status, frames, overflow) = lock.withLock { () -> (Int, [String], Bool) in
                opened.append(request)
                let n = opened.count - 1
                let (status, frames) = scripts.isEmpty ? (200, []) : scripts.removeFirst()
                return (status, frames, overflowAfter.contains(n))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            let stream = AsyncThrowingStream<Data, Error> { c in
                Task {
                    for f in frames { c.yield(Data(f.utf8)); try? await Task.sleep(for: .milliseconds(20)) }
                    if overflow { c.finish(throwing: BoundedChunkBuffer.Failure.overflow); return }
                    if frames.isEmpty { try? await Task.sleep(for: .seconds(30)) }
                    c.finish()
                }
            }
            return (response, EventChunks(stream))
        }
        var openedCount: Int { lock.withLock { opened.count } }
    }

    static func frame(_ event: [String: Any]) -> String {
        "event: flightdeck_pg.event\nid: \(event["row_version"]!)\ndata: \(String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self))\n\n"
    }

    func testStreamAppliesEventsAndReconnectsFromStoredCursor() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)   // seed at head
        let seeded = h.tower.head
        let message = h.chat.tower.seed(channel: Fixtures.channel1, body: "live hello")
        h.tower.emit("message", id: message["id"] as? String, entityRowVersion: 1)
        let event = h.tower.lock.withLock { h.tower.events.last! }
        let streams = ScriptedStreams()
        // First connection: the event arrives over SSE, then the server closes. Second: access revoked.
        streams.scripts = [(200, ["event: connected\ndata: {}\n\n", ": heartbeat\n\n", Self.frame(event)]),
                           (200, ["event: connected\ndata: {}\n\n", "event: flightdeck_pg.error\ndata: {\"error\":\"workspace_access_revoked\"}\n\n"])]
        // Keep the catch-up before the first connection from consuming the event: Tower's log stays at the seed.
        h.transport.setHandler { request in
            if request.url!.path.hasSuffix("/events") {
                let asked = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
                return (200, ["events": [], "next_cursor": asked ?? FakeEventTower.cursor(seeded)])
            }
            return try h.tower.handler()(request)
        }
        let live = LiveStream(sync: h.sync, transport: streams, idleTimeout: .seconds(5), batchWindow: .milliseconds(50), random: { 0 })
        await live.start(h.connection, h.workspace)
        let feed = await h.sync.live.feed(h.workspace.id)
        let deadline = Date().addingTimeInterval(20)
        while await feed.status.stream != .accessLost, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let status = await feed.status
        XCTAssertEqual(status.stream, .accessLost)
        XCTAssertGreaterThanOrEqual(status.eventsApplied, 1)
        let stored = try await h.store.reader.message(workspaceId: h.workspace.id, id: message["id"] as! String)
        XCTAssertEqual(stored?.body, "live hello")
        XCTAssertEqual(streams.openedCount, 2, "reconnected once after the server closed")
        let second = streams.lock.withLock { streams.opened[1] }
        let resumed = URLComponents(url: second.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        XCTAssertEqual(resumed, FakeEventTower.cursor(h.tower.head), "resumes from the cursor saved after the streamed batch")
        let first = streams.lock.withLock { streams.opened[0] }
        XCTAssertEqual(URLComponents(url: first.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value,
                       FakeEventTower.cursor(seeded))
        let auth = try decodeAuthorization(second)
        XCTAssertTrue(auth.tags.contains(["method", "GET"]))
        XCTAssertEqual(auth.tags.first?[1], second.url!.absoluteString, "NIP-98 signed over the exact stream URL")
        await live.stop()
    }
}

final class LiveErrorPropagationTests: XCTestCase {
    /// A failing record read surfaces as that error (not a cancellation), so the stream reconnects instead of stopping.
    func testApplyFailureIsReportedAsItself() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        h.tower.emit("resource_view_state", id: nil, channel: nil)
        h.transport.setHandler { request in
            if request.url!.path.hasSuffix("/resource-view-states") { return (200, ["unexpected": true]) }
            return try h.tower.handler()(request)
        }
        do { _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace); XCTFail("expected failure") }
        catch { XCTAssertFalse(error is CancellationError, "\(error)") }
    }
}


final class LiveStreamOverflowTests: XCTestCase {
    /// A slow reader overflows the receive buffer mid-batch: the stream fails, reconnects from the durable cursor and
    /// the events that were not stored arrive again; nothing is skipped.
    func testOverflowReconnectsFromStoredCursorWithoutSkipping() async throws {
        let h = try await LiveHarness.make()
        _ = try await h.sync.catchUpEventsAndWait(h.connection, h.workspace)
        let seeded = h.tower.head
        let first = h.chat.tower.seed(channel: Fixtures.channel1, body: "before overflow")
        let second = h.chat.tower.seed(channel: Fixtures.channel1, body: "after overflow")
        h.tower.emit("message", id: first["id"] as? String, entityRowVersion: 1)
        h.tower.emit("message", id: second["id"] as? String, entityRowVersion: 1)
        let events = h.tower.lock.withLock { Array(h.tower.events.suffix(2)) }
        let streams = LiveStreamTests.ScriptedStreams()
        // Connection 0 delivers only the first event, then overflows (the second event's bytes were never read).
        // Connection 1 starts from the stored cursor and delivers the second event, then access is revoked to end the test.
        streams.scripts = [(200, ["event: connected\ndata: {}\n\n", LiveStreamTests.frame(events[0])]),
                           (200, ["event: connected\ndata: {}\n\n", LiveStreamTests.frame(events[1]),
                                  "event: flightdeck_pg.error\ndata: {\"error\":\"workspace_access_revoked\"}\n\n"])]
        streams.overflowAfter = [0]
        h.transport.setHandler { request in
            if request.url!.path.hasSuffix("/events") {
                let asked = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
                return (200, ["events": [], "next_cursor": asked ?? FakeEventTower.cursor(seeded)])
            }
            return try h.tower.handler()(request)
        }
        let live = LiveStream(sync: h.sync, transport: streams, idleTimeout: .seconds(5), batchWindow: .milliseconds(30), random: { 0 })
        await live.start(h.connection, h.workspace)
        let feed = await h.sync.live.feed(h.workspace.id)
        let deadline = Date().addingTimeInterval(20)
        while await feed.status.stream != .accessLost, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let a = try await h.store.reader.message(workspaceId: h.workspace.id, id: first["id"] as! String)
        let b = try await h.store.reader.message(workspaceId: h.workspace.id, id: second["id"] as! String)
        XCTAssertEqual(a?.body, "before overflow")
        XCTAssertEqual(b?.body, "after overflow")
        let resumed = streams.lock.withLock { streams.opened[1] }
        let cursor = URLComponents(url: resumed.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
        XCTAssertEqual(cursor, events[0]["cursor"] as? String, "reconnected exactly after the last stored event")
        await live.stop()
    }
}
