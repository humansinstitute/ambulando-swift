import Foundation
import XCTest
@testable import AmbulandoCore

/// A small in-memory Tower notification inbox for one recipient: per-recipient `change_seq`, `row_version` compare-and-set,
/// `mutation_id` replay, keyset paging, `changes` with `through_seq`, tombstones and `reset_required`.
final class FakeNotificationTower: @unchecked Sendable {
    let lock = NSLock()
    private(set) var seq = 0
    private var items: [String: [String: Any]] = [:]
    private var log: [(seq: Int, change: [String: Any])] = []
    private var mutations: [String: (body: String, item: [String: Any])] = [:]
    var invalidCursorOnce = false
    var invalidCursorAlways = false
    var churnRulesEveryItemsPage = false
    var rulesRevision = 1
    /// Categories this app's view hides (an `off` rule): omitted from items, counts and changes.
    var hiddenCategories: Set<String> = []
    private var rules: [String: [String: Any]] = [:]      // exact key -> rule with row_version
    private(set) var ruleBodies: [[String: Any]] = []
    var conflictNextRulesPut = false
    fileprivate var reuseNext = false
    var status: Int?                       // forced status for every notification route
    var resetBelow = 0                     // `changes` older than this answers 410 reset_required
    var changeLimit = 200
    var patchFailure: Int?
    private(set) var requests: [String] = []
    private(set) var patchBodies: [[String: Any]] = []
    let workspace: String

    init(workspace: String = Fixtures.workspaceId) { self.workspace = workspace }

    static func uuid() -> String { UUID().uuidString.lowercased() }

    @discardableResult
    func put(id: String = FakeNotificationTower.uuid(), title: String = "Rick mentioned you", category: String = "mention", read: Bool = false,
             target: [String: Any]? = nil, occurred: String? = nil, access: String = "ok") -> String {
        lock.withLock {
            seq += 1
            var item: [String: Any] = [
                "schema": "org.wingman.notification.item", "version": 1, "id": id, "workspace_id": workspace, "recipient_actor_id": Self.uuid(),
                "change_seq": seq, "row_version": 1, "source": ["app_id": "flightdeck.core", "label": "Flight Deck", "kind": "tower_rule"],
                "category": category, "reasons": [category], "severity": "normal", "status": "active", "origin": "live",
                "group": ["key": "thread:x", "event_count": 1], "subject": ["kind": "thread", "activity_version": 3],
                "presentation": ["title": title, "body": "In Ambulando", "icon": "mention"],
                "action": ["type": "open", "target": target ?? ["kind": "thread", "channel_id": Fixtures.channel1, "thread_id": Self.uuid()]],
                "occurred_at": occurred ?? String(format: "2026-10-26T13:%02d:00Z", min(seq, 59)), "updated_at": "2026-10-26T13:00:00Z",
                "state": ["read": read, "read_at": NSNull(), "read_reason": NSNull(), "dismissed": false, "archived": false], "access": access,
            ]
            if access != "ok" { item["action"] = NSNull() }
            items[id] = item
            log.append((seq, item))
            return id
        }
    }

    @discardableResult
    func set(_ id: String, read: Bool? = nil, dismissed: Bool? = nil, archived: Bool? = nil) -> [String: Any] {
        lock.withLock { setLocked(id, read: read, dismissed: dismissed, archived: archived) }
    }

    private func setLocked(_ id: String, read: Bool?, dismissed: Bool?, archived: Bool?) -> [String: Any] {
        var item = items[id]!
        var state = item["state"] as! [String: Any]
        if let read { state["read"] = read }
        if let dismissed { state["dismissed"] = dismissed; if dismissed { state["read"] = true } }
        if let archived { state["archived"] = archived; if archived { state["read"] = true } }
        seq += 1
        item["state"] = state
        item["row_version"] = (item["row_version"] as! Int) + 1
        item["change_seq"] = seq
        items[id] = item
        log.append((seq, item))
        return item
    }

    /// A new event folded into an open item: more updates, newer activity, new text, unread again.
    @discardableResult
    func fold(_ id: String, body: String = "newer activity") -> [String: Any] {
        lock.withLock {
            var item = items[id]!
            seq += 1
            var group = item["group"] as! [String: Any]
            group["event_count"] = (group["event_count"] as! Int) + 1
            var subject = item["subject"] as! [String: Any]
            subject["activity_version"] = (subject["activity_version"] as! Int) + 1
            var presentation = item["presentation"] as! [String: Any]
            presentation["body"] = body
            var state = item["state"] as! [String: Any]
            state["read"] = false
            item["group"] = group; item["subject"] = subject; item["presentation"] = presentation; item["state"] = state
            item["row_version"] = (item["row_version"] as! Int) + 1
            item["change_seq"] = seq
            items[id] = item
            log.append((seq, item))
            return item
        }
    }

    func remove(_ id: String, reason: String = "access_lost") {
        lock.withLock {
            seq += 1
            items[id] = nil
            log.append((seq, ["schema": "org.wingman.notification.tombstone", "version": 1, "id": id, "workspace_id": workspace, "change_seq": seq,
                              "change_type": "remove", "removal_reason": reason]))
        }
    }

    var recordedRequests: [String] { lock.withLock { requests } }
    var recordedPatches: [[String: Any]] { lock.withLock { patchBodies } }

    private func isRemoved(_ item: [String: Any]) -> Bool { false }

    func handler() -> StubTransport.Handler {
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspace)/notifications"
        return { [self] request in
            let url = request.url!
            guard url.path.hasPrefix(base) else { return (404, ["error": "not_found"]) }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
            return lock.withLock {
                requests.append("\(request.httpMethod ?? "GET") \(url.path.dropFirst(base.count))?\(url.query ?? "")")
                if let status { return (status, ["error": status == 410 ? "reset_required" : "x"]) }
                let tail = String(url.path.dropFirst(base.count))
                if tail == "/items", request.httpMethod == "GET" {
                    let live = items.values.filter { item in
                        if hiddenCategories.contains((item["category"] as? String) ?? "") { return false }
                        let s = item["state"] as! [String: Any]
                        switch q("view") ?? "inbox" {
                        case "archived": return s["archived"] as? Bool == true && s["dismissed"] as? Bool != true
                        default: return s["dismissed"] as? Bool != true && s["archived"] as? Bool != true
                        }
                    }.sorted { ($0["occurred_at"] as! String, $0["id"] as! String) > ($1["occurred_at"] as! String, $1["id"] as! String) }
                    let limit = Int(q("limit") ?? "50") ?? 50
                    if churnRulesEveryItemsPage { rulesRevision += 1 }
                    if q("cursor") != nil, invalidCursorAlways { return (410, ["error": "reset_required"]) }
                    if q("cursor") != nil, invalidCursorOnce { invalidCursorOnce = false; return (400, ["error": "invalid cursor", "code": "invalid_cursor"]) }
                    let offset = q("cursor").flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
                    let page = Array(live.dropFirst(offset).prefix(limit))
                    let next: Any = offset + limit < live.count ? Data(String(offset + limit).utf8).base64EncodedString() : NSNull()
                    return (200, ["items": page, "next_cursor": next, "head_seq": seq, "rules_revision": rulesRevision, "inbox_started_at": "2026-10-26T12:00:00Z"])
                }
                if tail == "/changes" {
                    let after = Int(q("after_seq") ?? "0") ?? 0
                    if after < resetBelow { return (410, ["error": "reset_required"]) }
                    if let asked = q("rules_revision").flatMap(Int.init), asked != rulesRevision {
                        return (410, ["code": "reset_required", "reason": "rules_changed", "rules_revision": rulesRevision])
                    }
                    let limit = min(Int(q("limit") ?? "200") ?? 200, changeLimit)
                    let pending = log.filter { $0.seq > after && (hiddenCategories.isEmpty || !hiddenCategories.contains(($0.change["category"] as? String) ?? "")) }
                    let page = Array(pending.prefix(limit))
                    return (200, ["changes": page.map(\.change), "through_seq": pending.count > page.count ? (page.last?.seq ?? after) : seq, "head_seq": seq, "has_more": pending.count > page.count, "rules_revision": rulesRevision])
                }
                if tail == "/counts" {
                    let unread = items.values.filter { item in
                        if hiddenCategories.contains((item["category"] as? String) ?? "") { return false }
                        let s = item["state"] as! [String: Any]
                        return s["read"] as? Bool != true && s["dismissed"] as? Bool != true && s["archived"] as? Bool != true
                    }.count
                    return (200, ["unread_total": unread, "by_category": ["mention": unread], "badge": unread, "capped_at": 999, "head_seq": seq, "rules_revision": rulesRevision, "inbox_started_at": "2026-10-26T12:00:00Z"])
                }
                if tail == "/categories" {
                    return (200, ["sources": [["app_id": "flightdeck.core", "label": "Flight Deck", "kind": "tower_rule",
                                               "categories": [["category": "mention", "label": "Mentions", "default_inbox": "on", "mandatory": false],
                                                              ["category": "security", "label": "Security", "default_inbox": "on", "mandatory": true]]]]])
                }
                if tail == "/rules", request.httpMethod == "GET" { return (200, ["rules": Array(rules.values), "rules_revision": rulesRevision]) }
                if tail == "/rules", request.httpMethod == "PUT" {
                    let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                    ruleBodies.append(body)
                    let entries = body["rules"] as? [[String: Any]] ?? []
                    func key(_ r: [String: Any]) -> String { "\(r["source_app_id"] ?? "")|\(r["category"] ?? "")|\(r["client_app_id"] ?? "")|\(r["channel"] ?? "")" }
                    if conflictNextRulesPut {
                        conflictNextRulesPut = false
                        // Another device wrote the key first.
                        var other = entries[0]; other["mode"] = "off"; other["row_version"] = 5; other["preview"] = NSNull(); other.removeValue(forKey: "expected_row_version")
                        rules[key(entries[0])] = other; rulesRevision += 1
                    }
                    for e in entries where (e["expected_row_version"] as? Int) != (rules[key(e)]?["row_version"] as? Int ?? 0) {
                        return (409, ["code": "rules_conflict", "conflicts": [], "rules": Array(rules.values), "rules_revision": rulesRevision])
                    }
                    for e in entries {
                        var stored = e; stored.removeValue(forKey: "expected_row_version")
                        stored["row_version"] = (rules[key(e)]?["row_version"] as? Int ?? 0) + 1
                        rules[key(e)] = stored
                    }
                    rulesRevision += 1
                    return (200, ["rules": Array(rules.values), "rules_revision": rulesRevision])
                }
                if tail.hasPrefix("/items/"), request.httpMethod == "PATCH" {
                    let id = String(tail.dropFirst(7))
                    let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                    patchBodies.append(body)
                    if let patchFailure { return (patchFailure, ["error": "boom"]) }
                    guard var item = items[id] else { return (404, ["error": "not_found"]) }
                    let mutation = body["mutation_id"] as! String
                    let signature = String(data: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
                    if reuseNext { reuseNext = false; return (409, ["error": "mutation_id_reused", "code": "mutation_id_reused"]) }
                    if let known = mutations[mutation] {
                        return known.body == signature ? (200, ["item": known.item]) : (409, ["error": "mutation_id_reused", "code": "mutation_id_reused"])
                    }
                    let stale = body["expected_row_version"] as? Int != item["row_version"] as? Int
                    let overtaken = (body["observed_change_seq"] as? Int).map { $0 < (item["change_seq"] as! Int) } ?? false
                    guard !stale, !overtaken else { return (409, ["error": "state_conflict", "code": "state_conflict", "item": item]) }
                    let patch = body["patch"] as! [String: Any]
                    item = setLocked(id, read: patch["read"] as? Bool, dismissed: patch["dismissed"] as? Bool, archived: patch["archived"] as? Bool)
                    mutations[mutation] = (signature, item)
                    return (200, ["item": item])
                }
                if tail == "/bulk", request.httpMethod == "POST" {
                    let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                    patchBodies.append(body)
                    let selector = body["selector"] as? [String: Any] ?? [:]
                    let upTo = selector["up_to_seq"] as? Int ?? Int.max
                    var affected = 0
                    for (id, item) in items where (item["change_seq"] as! Int) <= upTo {
                        let s = item["state"] as! [String: Any]
                        if s["read"] as? Bool != true, s["dismissed"] as? Bool != true, s["archived"] as? Bool != true { _ = setLocked(id, read: true, dismissed: nil, archived: nil); affected += 1 }
                    }
                    return (200, ["affected": affected, "through_seq": upTo == Int.max ? seq : upTo])
                }
                return (404, ["error": "not_found"])
            }
        }
    }
}

struct NotificationHarness {
    let chat: ChatHarness
    let tower: FakeNotificationTower
    let transport: StubTransport
    let sync: WorkspaceSync
    let writes: WriteSender
    let actions: NotificationActions

    var store: LocalStore { chat.store }
    var connection: ConnectionRecord { chat.connection }
    var workspace: WorkspaceRecord { chat.workspace }

    static func make(unlocked: Bool = true) async throws -> NotificationHarness {
        let chat = try await ChatHarness.make(unlocked: unlocked)
        let tower = FakeNotificationTower()
        let transport = StubTransport(tower.handler())
        let sync = WorkspaceSync(store: chat.store, engine: chat.engine, identity: chat.identity, transport: transport)
        let staging = chat.directory.appendingPathComponent("Staging", isDirectory: true)
        let writes = WriteSender(store: chat.store, engine: chat.engine, identity: chat.identity, transport: transport, staging: staging)
        return NotificationHarness(chat: chat, tower: tower, transport: transport, sync: sync, writes: writes,
                                   actions: NotificationActions(store: chat.store, writes: writes))
    }

    @discardableResult
    func run(force: Bool = false) async throws -> WorkspaceSync.NotificationRun { try await sync.runNotifications(connection, workspace, force: force) }

    func items(_ filter: NotificationFilter = .all) async throws -> [NotificationItem] {
        try await store.reader.notifications(connectionId: connection.id, workspaceId: workspace.id, filter: filter)
    }

    func status() async throws -> NotificationSyncStatus { try await store.reader.notificationStatus(connectionId: connection.id, workspaceId: workspace.id) }
    func unread() async throws -> Int { try await store.reader.notificationUnreadCount(connectionId: connection.id, workspaceId: workspace.id) }

    /// Polls (bounded) for a condition that a background job will make true; never waits on scheduled retries.
    func eventually(_ what: String = "", timeout: Double = 5, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func drainWrites() async {
        await writes.kick(connection, force: true)
        await chat.engine.waitUntilIdle()
    }
}

final class NotificationRecordTests: XCTestCase {
    func item(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> NotificationItem? {
        let tower = FakeNotificationTower()
        let id = tower.put()
        var json = tower.set(id, read: false)
        mutate(&json)
        return NotificationItem(json: json, workspaceId: Fixtures.workspaceId)
    }

    func testParsesStateTargetAndKeepsTextPlain() throws {
        let parsed = try XCTUnwrap(item { json in
            json["presentation"] = ["title": "Re\u{202E}ad  me\u{0007}", "body": "line"]
        })
        XCTAssertEqual(parsed.title, "Read  me", "bidi override and control characters are stripped")
        XCTAssertTrue(parsed.isUnread)
        XCTAssertTrue(parsed.accessOK)
        if case .thread(let channel, _, _)? = parsed.target { XCTAssertEqual(channel, Fixtures.channel1) } else { XCTFail("thread target") }
    }

    func testForeignWorkspaceAndWrongSchemaAreRejected() {
        XCTAssertNil(item { $0["workspace_id"] = Fixtures.workspaceId2 })
        XCTAssertNil(item { $0["schema"] = "org.example.other" })
        // A newer schema version is kept as a generic card, never dropped and never openable.
        let future = item { $0["version"] = 2 }
        XCTAssertNotNil(future)
        XCTAssertTrue(future?.isFutureVersion == true)
        XCTAssertNil(future?.target)
    }

    func testAppObjectAndUnknownKindsOpenAGenericDetail() throws {
        let app = try XCTUnwrap(item { $0["action"] = ["type": "open", "target": ["kind": "app_object", "app_id": "blinkers", "object_id": "c1"]] })
        XCTAssertEqual(app.target, .generic(kind: "app_object"))
        let future = try XCTUnwrap(item { $0["action"] = ["type": "open", "target": ["kind": "hologram"]] })
        XCTAssertEqual(future.target, .generic(kind: "hologram"))
        let task = try XCTUnwrap(item { $0["action"] = ["type": "open", "target": ["kind": "task", "task_id": FakeNotificationTower.uuid()]] })
        if case .task? = task.target {} else { XCTFail("task target") }
    }

    func testUnavailableItemNeverKeepsProducerText() throws {
        let hidden = try XCTUnwrap(item { json in
            json["access"] = "unavailable"
            json["presentation"] = ["title": "Secret plan", "body": "details"]
        })
        XCTAssertFalse(hidden.accessOK)
        XCTAssertEqual(hidden.title, "Item no longer available")
        XCTAssertEqual(hidden.body, "")
        XCTAssertNil(hidden.target, "nothing to open")
    }

    func testChangeParsingDistinguishesRemovalFromUpsert() throws {
        let id = FakeNotificationTower.uuid()
        let removal = NotificationChange(json: ["removed": true, "id": id, "change_seq": 9, "removal_reason": "access_lost"], workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(removal, .removed(id: id, changeSeq: 9, reason: "access_lost"))
        let withdrawn = try XCTUnwrap(item { $0["status"] = "withdrawn" })
        XCTAssertEqual(NotificationChange(json: try XCTUnwrap(JSONSerialization.jsonObject(with: withdrawn.raw) as? [String: Any]), workspaceId: Fixtures.workspaceId),
                       .removed(id: withdrawn.id, changeSeq: withdrawn.changeSeq, reason: "withdrawn"))
    }

    func testEventHintSchedulesTheInboxJobOnly() {
        let plan = EventPlan.make([TowerEvent(rowVersion: 1, cursor: "c1", workspaceId: Fixtures.workspaceId, entityType: "notification_item",
                                              entityId: FakeNotificationTower.uuid(), operation: "state")], workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(plan.refreshes, [.notifications], "a hint carries no content and triggers exactly one coalescing refresh")
        XCTAssertTrue(plan.tombstones.isEmpty)
    }

    func testFilters() throws {
        let unread = try XCTUnwrap(item())
        let read = try XCTUnwrap(item { ($0["state"] as! [String: Any]).self; $0["state"] = ["read": true, "dismissed": false, "archived": false] })
        let archived = try XCTUnwrap(item { $0["state"] = ["read": true, "dismissed": false, "archived": true] })
        XCTAssertTrue(NotificationFilter.unread.includes(unread)); XCTAssertFalse(NotificationFilter.unread.includes(read))
        XCTAssertTrue(NotificationFilter.all.includes(read)); XCTAssertFalse(NotificationFilter.all.includes(archived))
        XCTAssertTrue(NotificationFilter.archived.includes(archived))
    }
}

final class NotificationSyncTests: XCTestCase {
    func testEmptyInboxFromActivationHasNoHistoryAndIsReady() async throws {
        let h = try await NotificationHarness.make()
        let run = try await h.run()
        XCTAssertTrue(run.coldStart)
        let status = try await h.status()
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.localSeq, 0)
        let items = try await h.items()
        XCTAssertTrue(items.isEmpty)
        // A second job is steady state: changes only, no re-listing.
        let again = try await h.run()
        XCTAssertFalse(again.coldStart)
        XCTAssertFalse(h.tower.recordedRequests.dropFirst(3).contains { $0.hasPrefix("GET /items") })
    }

    func testColdStartPagesTheInboxThenReplaysFromTheSnapshotSequence() async throws {
        let h = try await NotificationHarness.make()
        for i in 0..<120 { h.tower.put(title: "n\(i)") }
        let run = try await h.run()
        XCTAssertEqual(run.listed, 120, "three pages of 50")
        let status = try await h.status()
        XCTAssertEqual(status.localSeq, h.tower.seq)
        let count = try await h.items().count
        XCTAssertEqual(count, 120)
        let unread = try await h.unread()
        XCTAssertEqual(unread, 120)
        XCTAssertEqual(status.counts?.unreadTotal, 120, "server counts are kept for reconciliation")
    }

    func testChangeBetweenListingAndReplayIsRepaired() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put(title: "before")
        try await h.run()
        // Created and then read on another device while this device was away.
        let late = h.tower.put(title: "late")
        h.tower.set(id, read: true)
        h.tower.set(late, read: false)
        try await h.run()
        let items = try await h.items()
        XCTAssertEqual(Set(items.map(\.title)), ["before", "late"])
        XCTAssertEqual(items.first { $0.title == "before" }?.isRead, true)
        let unread = try await h.unread()
        XCTAssertEqual(unread, 1)
    }

    func testCursorAdvancesOnlyToWhatWasDeliveredAcrossPages() async throws {
        let h = try await NotificationHarness.make()
        try await h.run()
        h.tower.changeLimit = 2
        for i in 0..<5 { h.tower.put(title: "c\(i)") }
        let run = try await h.run()
        XCTAssertEqual(run.pages, 3)
        XCTAssertEqual(run.replayed, 5)
        let status = try await h.status()
        XCTAssertEqual(status.localSeq, h.tower.seq)
        // Replaying the same changes again is idempotent.
        try await h.store.writer.resetNotificationCursor(connectionId: h.connection.id, workspaceId: h.workspace.id)
        try await h.run()
        let count = try await h.items().count
        XCTAssertEqual(count, 5)
    }

    func testRemovalTombstonePurgesTheItem() async throws {
        let h = try await NotificationHarness.make()
        let secret = h.tower.put(title: "Private plan")
        try await h.run()
        let before = try await h.items()
        XCTAssertEqual(before.count, 1)
        h.tower.remove(secret)
        try await h.run()
        let after = try await h.items(.all)
        XCTAssertTrue(after.isEmpty)
        let readback = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: secret)
        XCTAssertNil(readback, "the row and its text are gone")
    }

    func testDismissedAndArchivedUnknownItemsAreNotHydrated() async throws {
        let h = try await NotificationHarness.make()
        try await h.run()
        let a = h.tower.put(title: "a"), b = h.tower.put(title: "b")
        h.tower.set(a, dismissed: true)
        h.tower.set(b, archived: true)
        try await h.run()
        let inbox = try await h.items(.all)
        XCTAssertTrue(inbox.isEmpty)
        let archived = try await h.items(.archived)
        XCTAssertTrue(archived.isEmpty, "the archive is hydrated only on request")
        let status = try await h.status()
        XCTAssertEqual(status.localSeq, h.tower.seq, "the sequence still advances")
        await h.sync.loadArchivedNotifications(h.connection, h.workspace)
        await h.chat.engine.waitUntilIdle()
        let loaded = try await h.items(.archived)
        XCTAssertEqual(loaded.map(\.title), ["b"])
    }

    func testUnsupportedBackendIsAStateNotAnError() async throws {
        let h = try await NotificationHarness.make()
        h.tower.status = 404
        let run = try await h.run()
        XCTAssertTrue(run.unsupported)
        let status = try await h.status()
        XCTAssertEqual(status.state, .unsupported)
        let requests = h.tower.recordedRequests.count
        // Not asked again straight away; a forced check (Settings refresh) asks again.
        let skipped = try await h.run()
        XCTAssertTrue(skipped.skippedByRecheck)
        XCTAssertEqual(h.tower.recordedRequests.count, requests)
        h.tower.status = nil
        h.tower.put()
        let recovered = try await h.run(force: true)
        XCTAssertFalse(recovered.unsupported)
        let now = try await h.status()
        XCTAssertEqual(now.state, .ready)
    }

    func testRefusedWorkspacePurgesLocalNotifications() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put(title: "kept until access ends")
        try await h.run()
        h.tower.status = 403
        let run = try await h.run()
        XCTAssertTrue(run.accessLost)
        let items = try await h.items()
        XCTAssertTrue(items.isEmpty)
        let status = try await h.status()
        XCTAssertEqual(status.state, .noAccess)
    }

    func testResetRequiredListsAgainAndKeepsPendingChanges() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put(title: "pending")
        let other = h.tower.put(title: "other")
        try await h.run()
        try await h.store.writer.setNotificationPending(connectionId: h.connection.id, workspaceId: h.workspace.id, ids: [id], NotificationPatch(read: true))
        h.tower.put(title: "new")
        h.tower.resetBelow = h.tower.seq + 1
        let first = try await h.run()
        XCTAssertTrue(first.reschedule)
        h.tower.resetBelow = 0
        let second = try await h.run()
        XCTAssertTrue(second.coldStart)
        let items = try await h.items(.all)
        XCTAssertEqual(Set(items.map(\.title)), ["pending", "other", "new"])
        let mine = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(mine?.isRead, true, "the unsent read survives the re-listing")
        XCTAssertNotNil(other)
    }

    func testCountsMismatchRelistsOnceAndRepairs() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put(); h.tower.put()
        try await h.run()
        // The device wrongly believes one item is read (a missed change); nothing is waiting to be sent.
        let wrong = try await h.items().first!
        try await h.store.writer.setNotificationPending(connectionId: h.connection.id, workspaceId: h.workspace.id, ids: [wrong.id], NotificationPatch(read: true))
        try await h.store.writer.confirmNotificationPending(connectionId: h.connection.id, workspaceId: h.workspace.id, ids: [wrong.id])
        var unread = try await h.unread()
        XCTAssertEqual(unread, 1)
        try await h.run()
        await h.chat.engine.waitUntilIdle()
        unread = try await h.unread()
        XCTAssertEqual(unread, 2, "Tower's count won: the inbox was listed again")
        let listings = h.tower.recordedRequests.filter { $0.hasPrefix("GET /items") }.count
        try await h.run()
        await h.chat.engine.waitUntilIdle()
        XCTAssertEqual(h.tower.recordedRequests.filter { $0.hasPrefix("GET /items") }.count, listings, "no loop once they agree")
    }

    func testMembersOfOtherWorkspacesNeverEnterTheStore() async throws {
        let h = try await NotificationHarness.make()
        let foreign = FakeNotificationTower(workspace: Fixtures.workspaceId2)
        foreign.put(title: "wrong place")
        var json = foreign.set(foreign.put(title: "x"), read: false)
        json["workspace_id"] = Fixtures.workspaceId2
        XCTAssertNil(NotificationItem(json: json, workspaceId: h.workspace.id))
    }
}

final class NotificationActionTests: XCTestCase {
    func testMarkReadIsImmediateThenConfirmedByTower() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        h.tower.put()
        try await h.run()
        let item = try await h.items().first { $0.id == id }!
        try await h.actions.apply(.markRead, to: item, connection: h.connection, workspace: h.workspace)
        let optimistic = try await h.unread()
        XCTAssertEqual(optimistic, 1, "the badge drops before Tower answers")
        await h.drainWrites()
        let patch = h.tower.recordedPatches.first
        XCTAssertEqual(patch?["expected_row_version"] as? Int, 1)
        XCTAssertEqual((patch?["patch"] as? [String: Any])?["read"] as? Bool, true)
        XCTAssertNotNil(patch?["mutation_id"] as? String)
        let stored = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(stored?.rowVersion, 2, "Tower's item replaced the optimistic one")
        let pending = try await h.store.reader.pendingNotificationIds(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertTrue(pending.isEmpty)
    }

    func testDismissLeavesTheInboxAndUndoBringsItBack() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put(title: "bring me back")
        try await h.run()
        let item = try await h.items().first!
        try await h.actions.apply(.dismiss, to: item, connection: h.connection, workspace: h.workspace)
        let hidden = try await h.items(.all)
        XCTAssertTrue(hidden.isEmpty, "hidden at once")
        await h.drainWrites()
        let gone = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertNil(gone, "a dismissed item is not kept on the device")
        try await h.actions.apply(.undismiss, to: item, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let back = try await h.items(.all)
        XCTAssertEqual(back.map(\.id), [id], "stale version conflicted once, then the intent was re-applied")
    }

    func testStateConflictReappliesIntentOnceWithAFreshMutationId() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        let item = try await h.items().first!
        h.tower.set(id, archived: false)   // another device bumped the version (no visible change)
        try await h.actions.apply(.markRead, to: item, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let patches = h.tower.recordedPatches
        XCTAssertEqual(patches.count, 2)
        XCTAssertNotEqual(patches[0]["mutation_id"] as? String, patches[1]["mutation_id"] as? String)
        XCTAssertEqual(patches[1]["expected_row_version"] as? Int, 2)
        let stored = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(stored?.isRead, true)
    }

    func testChangeAlreadyMadeElsewhereIsNotSentAgain() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        let item = try await h.items().first!
        h.tower.set(id, read: true)
        try await h.actions.apply(.markRead, to: item, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        XCTAssertEqual(h.tower.recordedPatches.count, 1, "conflict showed the wanted state; nothing resent")
        let stored = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(stored?.isRead, true)
    }

    func testOfflineChangeStaysVisibleAndIsRetried() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        h.tower.patchFailure = 503
        let item = try await h.items().first!
        try await h.actions.apply(.markRead, to: item, connection: h.connection, workspace: h.workspace)
        let retrying = try await h.eventually {
            try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub).first?.state == .retrying
        }
        XCTAssertTrue(retrying, "Tower unavailable: the change is queued for automatic retry")
        var unread = try await h.unread()
        XCTAssertEqual(unread, 0, "still shown as read while it waits")
        h.tower.patchFailure = nil
        let queued = try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub)
        try await h.writes.retry(queued[0].id, connection: h.connection)
        let sent = try await h.eventually {
            try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub).isEmpty
        }
        XCTAssertTrue(sent)
        unread = try await h.unread()
        XCTAssertEqual(unread, 0)
        let stored = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(stored?.rowVersion, 2)
    }

    func testRefusedChangeRevertsTheOptimisticState() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put()
        try await h.run()
        h.tower.patchFailure = 403
        let item = try await h.items().first!
        try await h.actions.apply(.markRead, to: item, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let unread = try await h.unread()
        XCTAssertEqual(unread, 1, "a refused change does not leave the item looking read")
    }

    func testLockedIdentityNeverSignsAWrite() async throws {
        let h = try await NotificationHarness.make(unlocked: false)
        // Reading needs the identity too; seed the inbox without a network call.
        let tower = h.tower
        let json = tower.set(tower.put(), read: false)
        let item = try XCTUnwrap(NotificationItem(json: json, workspaceId: h.workspace.id))
        try await h.store.writer.replaceNotificationInbox(connectionId: h.connection.id, workspaceId: h.workspace.id, items: [item], snapshotSeq: 2, startedAt: nil)
        try await h.actions.apply(.markRead, to: item, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        XCTAssertTrue(h.tower.recordedPatches.isEmpty, "nothing was signed or sent while locked")
        let queued = try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub)
        XCTAssertEqual(queued.count, 1)
        let unread = try await h.unread()
        XCTAssertEqual(unread, 0)
    }

    func testMarkAllReadIsBoundedByTheObservedSequence() async throws {
        let h = try await NotificationHarness.make()
        for _ in 0..<3 { h.tower.put() }
        try await h.run()
        let observed = try await h.status().localSeq
        let late = h.tower.put(title: "arrived after the tap")   // reaches Tower, not yet seen on the device
        let marked = try await h.actions.markAllRead(connection: h.connection, workspace: h.workspace, upToSeq: observed)
        XCTAssertEqual(marked, 3)
        await h.drainWrites()
        let body = h.tower.recordedPatches.last
        XCTAssertEqual((body?["selector"] as? [String: Any])?["up_to_seq"] as? Int, observed)
        try await h.run()
        let items = try await h.items(.unread)
        XCTAssertEqual(items.map(\.id), [late], "the newer notification stays unread")
    }

    func testViewingARecordIsNotInventedByTheInbox() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put()
        try await h.run()
        let item = try await h.items().first!
        try await h.actions.apply(.markRead, to: item, connection: h.connection, workspace: h.workspace)
        try await h.actions.apply(.archive, to: item, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let viewStateWrites = h.transport.recorded.filter { $0.url!.path.contains("resource-view-states") }
        XCTAssertTrue(viewStateWrites.isEmpty, "notification state never writes a resource view")
    }
}

extension NotificationHarness {
    @discardableResult
    func run(budget: Int) async throws -> WorkspaceSync.NotificationRun {
        try await sync.runNotifications(connection, workspace, listBudget: budget, continueListing: false)
    }

    func failedWrites() async throws -> [WriteItem] {
        try await store.reader.writes(connectionId: connection.id, signerNpub: TestKeys.npub).filter { $0.state == .failed || $0.state == .conflict }
    }
}

/// Listing longer than one job's page budget, and the cursor/snapshot that carry it across jobs.
final class NotificationHydrationTests: XCTestCase {
    func testLongInboxResumesFromTheStoredCursorAndKeepsTheOriginalSnapshot() async throws {
        let h = try await NotificationHarness.make()
        for i in 0..<130 { h.tower.put(title: "n\(i)") }
        let snapshot = h.tower.seq
        // One page per job: 50 + 50 + 30. Older unread items must not be dropped to fit a budget.
        var run = try await h.run(budget: 1)
        XCTAssertEqual(run.listed, 50)
        var status = try await h.status()
        XCTAssertTrue(status.hydrating)
        XCTAssertNotEqual(status.state, .ready, "not ready while the listing is unfinished")
        XCTAssertEqual(status.localSeq, 0, "the delta cursor does not move before the listing ends")
        XCTAssertEqual(status.hydrateSeq, snapshot)
        let unreadDuring = try await h.unread()
        XCTAssertEqual(unreadDuring, 50)
        // Things change at Tower between jobs; the listing still resumes under the first page's snapshot.
        h.tower.put(title: "arrived between jobs")
        run = try await h.run(budget: 1)
        status = try await h.status()
        XCTAssertEqual(status.hydrateSeq, snapshot, "S is the first page's head_seq, not a later one")
        XCTAssertTrue(status.hydrating)
        run = try await h.run(budget: 1)
        status = try await h.status()
        XCTAssertEqual(status.state, .ready)
        XCTAssertFalse(status.hydrating)
        let firstPages = h.tower.recordedRequests.filter { $0.hasPrefix("GET /items?") && !$0.contains("cursor=") }.count
        XCTAssertEqual(firstPages, 1, "the first page was fetched once, not restarted by each job")
        // Replay (from S) then brings the item that arrived between jobs.
        try await h.run()
        let all = try await h.items(.all)
        XCTAssertEqual(all.count, 131)
        XCTAssertTrue(all.contains { $0.title == "n0" }, "the oldest items are present")
        let unread = try await h.unread()
        XCTAssertEqual(unread, 131)
        let final = try await h.status()
        XCTAssertEqual(final.localSeq, h.tower.seq)
        XCTAssertEqual(final.startedAt, "2026-10-26T12:00:00Z", "the inbox start time is kept for the empty-state text")
    }

    func testExpiredListingCursorRestartsUnderANewSnapshot() async throws {
        let h = try await NotificationHarness.make()
        for i in 0..<120 { h.tower.put(title: "n\(i)") }
        try await h.run(budget: 1)
        h.tower.put(title: "new")
        h.tower.invalidCursorOnce = true
        let run = try await h.run(budget: 1)
        XCTAssertEqual(run.listed, 50, "restarted from the first page")
        let status = try await h.status()
        XCTAssertEqual(status.hydrateSeq, h.tower.seq, "a new snapshot, so the new item is inside it")
        XCTAssertTrue(status.hydrating)
        try await h.run(budget: 5)
        let ready = try await h.status()
        XCTAssertEqual(ready.state, .ready)
        let count = try await h.items(.all).count
        XCTAssertEqual(count, 121)
    }

    func testRulesChurnAndRepeatedCursorRejectionAreBoundedPerJobAndNeverReady() async throws {
        for churn in [true, false] {
            let h = try await NotificationHarness.make()
            for i in 0..<120 { h.tower.put(title: "n\(i)") }
            try await h.run(budget: 1)            // a listing in progress with a stored cursor
            let before = h.tower.recordedRequests.count
            if churn { h.tower.churnRulesEveryItemsPage = true } else { h.tower.invalidCursorAlways = true }
            let run = try await h.run(budget: 1)
            let used = h.tower.recordedRequests.count - before
            XCTAssertTrue(run.reschedule, "the job reschedules instead of looping")
            XCTAssertLessThanOrEqual(used, 2 * (WorkspaceSync.notificationListRestartBudget + 1), "bounded requests (churn: \(churn))")
            let status = try await h.status()
            XCTAssertNotEqual(status.state, .ready, "never ready from a mixed or partial snapshot")
            XCTAssertEqual(status.localSeq, 0)
            XCTAssertTrue(run.coldStart)
        }
    }

    func testRestartedListingRemovesWhatTowerNoLongerHolds() async throws {
        let h = try await NotificationHarness.make()
        let keep = h.tower.put(title: "keep"), gone = h.tower.put(title: "gone")
        try await h.run()
        h.tower.remove(gone)
        h.tower.resetBelow = h.tower.seq + 1   // the saved sequence is too old: list again
        try await h.run()
        h.tower.resetBelow = 0
        try await h.run()
        let items = try await h.items(.all)
        XCTAssertEqual(items.map(\.id), [keep])
    }

    func testArchiveListingResumesAcrossJobs() async throws {
        let h = try await NotificationHarness.make()
        try await h.run()
        for i in 0..<60 { let id = h.tower.put(title: "a\(i)"); h.tower.set(id, archived: true) }
        await h.sync.loadArchivedNotifications(h.connection, h.workspace, pages: 1)
        await h.chat.engine.waitUntilIdle()
        var count = try await h.items(.archived).count
        XCTAssertEqual(count, 60, "the job continued on its own from the stored cursor until the end")
        let status = try await h.status()
        XCTAssertFalse(status.archiveIncomplete)
        // An item archived afterwards arrives through changes.
        let late = h.tower.put(title: "late"); h.tower.set(late, archived: true)
        try await h.run()
        count = try await h.items(.archived).count
        XCTAssertEqual(count, 61)
    }
}

/// A person acts on what they saw. Newer activity is never acknowledged by an older tap.
final class NotificationGuardTests: XCTestCase {
    func testFoldBetweenRenderAndTapIsNotMarkedRead() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put(title: "thread")
        try await h.run()
        let rendered = try await h.items().first!          // what the person is looking at
        h.tower.fold(id, body: "two new replies")           // Tower folds newer activity ...
        try await h.run()                                   // ... and this device applies it before the tap
        let folded = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(folded?.rowVersion, 2)
        try await h.actions.apply(.markRead, to: rendered, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        XCTAssertEqual(h.tower.recordedPatches.count, 1, "sent once, against the version the person saw, and not re-sent")
        XCTAssertEqual(h.tower.recordedPatches[0]["expected_row_version"] as? Int, 1, "not the newer version in the store")
        XCTAssertEqual(h.tower.recordedPatches[0]["observed_change_seq"] as? Int, rendered.changeSeq)
        let now = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(now?.isRead, false, "the newer activity stays unread")
        XCTAssertEqual(now?.body, "two new replies")
        let unread = try await h.unread()
        XCTAssertEqual(unread, 1)
        let rejected = try await h.failedWrites()
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].lastError?.contains("New activity arrived") == true, "the person is told")
        let shown = try await h.store.reader.notificationRejections(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(shown.count, 1)
    }

    func testFoldWhileTheWriteWaitsOfflineIsNotArchivedEither() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        let rendered = try await h.items().first!
        h.tower.status = 503    // offline when the person taps Archive
        try await h.actions.apply(.archive, to: rendered, connection: h.connection, workspace: h.workspace)
        let waiting = try await h.eventually {
            try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub).first?.state == .retrying
        }
        XCTAssertTrue(waiting)
        h.tower.status = nil
        h.tower.fold(id)
        let queued = try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub)
        try await h.writes.retry(queued[0].id, connection: h.connection)
        let settled = try await h.eventually { try await h.failedWrites().count == 1 }
        XCTAssertTrue(settled)
        let now = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(now?.isArchived, false)
        XCTAssertEqual(now?.isRead, false)
    }

    func testRestoringVisibilityIsStillAppliedAfterAFold() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        let rendered = try await h.items().first!
        try await h.actions.apply(.dismiss, to: rendered, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        // Undo uses the card as rendered; Tower has changed it meanwhile (a no-op bump).
        h.tower.set(id, read: true)
        try await h.actions.apply(.undismiss, to: rendered, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let back = try await h.items(.all)
        XCTAssertEqual(back.map(\.id), [id])
    }

    func testTwoQuickActionsOnTheSameCardChainFromTheFirstResult() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        let rendered = try await h.items().first!
        h.tower.status = 503
        try await h.actions.apply(.markRead, to: rendered, connection: h.connection, workspace: h.workspace)
        try await h.actions.apply(.archive, to: rendered, connection: h.connection, workspace: h.workspace)   // same rendered card
        h.tower.status = nil
        let queued = try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub)
        XCTAssertEqual(queued.count, 2)
        try await h.writes.retry(queued[0].id, connection: h.connection)
        let done = try await h.eventually { try await h.store.reader.writes(connectionId: h.connection.id, signerNpub: TestKeys.npub).isEmpty }
        XCTAssertTrue(done)
        let patches = h.tower.recordedPatches
        XCTAssertEqual(patches.suffix(2).map { $0["expected_row_version"] as? Int }, [1, 2], "the second continued from the first's result")
        let failed = try await h.failedWrites()
        XCTAssertTrue(failed.isEmpty)
        let archived = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertNil(archived, "archived items leave the inbox partition")
    }

    func testMutationIdReusedIsARejectionNotAReplay() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        let rendered = try await h.items().first!
        // Tower already holds that mutation id for a different request.
        h.tower.reserveMutationAsDifferent()
        try await h.actions.apply(.markRead, to: rendered, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        let failed = try await h.failedWrites()
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed[0].lastCode, "mutation_id_reused")
        let item = try await h.store.reader.notificationItem(connectionId: h.connection.id, workspaceId: h.workspace.id, id: id)
        XCTAssertEqual(item?.isRead, false, "the optimistic read was reverted")
        XCTAssertEqual(h.tower.recordedPatches.count, 1, "no silent retry with a new id")
        let shown = try await h.store.reader.notificationRejections(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(shown.count, 1)
    }

    func testIdenticalRetryIsReplayedByTower() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        let rendered = try await h.items().first!
        try await h.actions.apply(.markRead, to: rendered, connection: h.connection, workspace: h.workspace)
        await h.drainWrites()
        // The same request again (a lost reply): Tower answers with the original item.
        let first = h.tower.recordedPatches[0]
        let replay = try await h.tower.replay(first, id: id)
        XCTAssertEqual(replay, 200)
    }

    func testMarkAllReadUsesTheRenderedSequenceNotTheStoresLatest() async throws {
        let h = try await NotificationHarness.make()
        let a = h.tower.put(title: "a"); h.tower.put(title: "b")
        try await h.run()
        let drawn = try await h.status().localSeq
        h.tower.fold(a, body: "folded after the screen was drawn")
        try await h.run()                                     // the store now has the fold
        let marked = try await h.actions.markAllRead(connection: h.connection, workspace: h.workspace, upToSeq: drawn)
        XCTAssertEqual(marked, 1, "only b is covered; a's card changed after it was drawn")
        await h.drainWrites()
        try await h.run()
        let unread = try await h.items(.unread)
        XCTAssertEqual(unread.map(\.id), [a])
    }
}

extension FakeNotificationTower {
    /// The next PATCH's mutation id is treated as already used for a different request.
    func reserveMutationAsDifferent() { lock.withLock { reuseNext = true } }

    /// Sends a recorded PATCH body again through the handler and returns the status (a lost-reply retry).
    func replay(_ body: [String: Any], id: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "https://tower.example/api/v4/flightdeck-pg/workspaces/\(workspace)/notifications/items/\(id)")!)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try handler()(request).0
    }
}

/// Contract v1.1: this app's presentation view (`client_app_id`), rules revision, and per-key compare-and-set rules.
final class NotificationAppViewTests: XCTestCase {
    func testEveryReadAndBulkIsAskedForAsAmbulando() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put()
        try await h.run()
        let item = try await h.items().first!
        _ = try await h.actions.markAllRead(connection: h.connection, workspace: h.workspace, upToSeq: item.changeSeq)
        await h.drainWrites()
        let reads = h.tower.recordedRequests.filter { $0.hasPrefix("GET") }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.allSatisfy { $0.contains("client_app_id=ambulando") }, "\(reads)")
        let bulk = h.tower.recordedPatches.last
        XCTAssertEqual((bulk?["selector"] as? [String: Any])?["client_app_id"] as? String, "ambulando")
    }

    func testRulesRevisionIsPersistedSentWithChangesAndAChangeRelists() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put(title: "kept")
        try await h.run()
        var status = try await h.status()
        XCTAssertEqual(status.rulesRevision, 1)
        try await h.run()
        XCTAssertTrue(h.tower.recordedRequests.contains { $0.contains("/changes") && $0.contains("rules_revision=1") })
        // Another device changed the rules: changes answers 410 rules_changed, the next job lists again under revision 2.
        h.tower.rulesRevision = 2
        let first = try await h.run()
        XCTAssertTrue(first.reschedule)
        let second = try await h.run()
        XCTAssertTrue(second.coldStart)
        status = try await h.status()
        XCTAssertEqual(status.rulesRevision, 2)
        XCTAssertEqual(status.state, .ready)
        let items = try await h.items()
        XCTAssertEqual(items.map(\.title), ["kept"])
    }

    func testRulesRevisionSeenOnlyInCountsAlsoRelists() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put()
        try await h.run()
        // A run whose changes carry no revision check (older stored value missing) must still notice via counts.
        h.tower.rulesRevision = 3
        try await h.store.writer.markNotificationSync(connectionId: h.connection.id, workspaceId: h.workspace.id, state: nil)
        let run = try await h.run()
        XCTAssertTrue(run.reschedule)
    }

    func testPreferenceChoiceIsAmbulandosViewAndUsesExactKeyRevision() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put()
        try await h.run()
        let prefs = try await h.sync.loadNotificationPreferences(h.connection, h.workspace)
        let mention = try XCTUnwrap(prefs.categories.first { $0.category == "mention" })
        XCTAssertTrue(prefs.inboxOn(mention))
        let updated = try await h.sync.setNotificationInboxRule(h.connection, h.workspace, category: mention, on: false, known: prefs)
        XCTAssertFalse(updated.inboxOn(mention))
        let sent = try XCTUnwrap(h.tower.ruleBodies.last?["rules"] as? [[String: Any]])
        XCTAssertEqual(sent.first?["client_app_id"] as? String, "ambulando", "only this app's view")
        XCTAssertEqual(sent.first?["channel"] as? String, "inbox")
        XCTAssertEqual(sent.first?["mode"] as? String, "off")
        XCTAssertEqual(sent.first?["expected_row_version"] as? Int, 0, "0 only because the key was absent")
        // Turn it back on: the exact key's current revision is the base.
        let again = try await h.sync.setNotificationInboxRule(h.connection, h.workspace, category: mention, on: true, known: updated)
        XCTAssertTrue(again.inboxOn(mention))
        XCTAssertEqual((h.tower.ruleBodies.last?["rules"] as? [[String: Any]])?.first?["expected_row_version"] as? Int, 1)
        await h.chat.engine.waitUntilIdle()
    }

    func testRulesConflictAdoptsCurrentRulesWithoutSilentlyReapplying() async throws {
        let h = try await NotificationHarness.make()
        let prefs = try await h.sync.loadNotificationPreferences(h.connection, h.workspace)
        let mention = try XCTUnwrap(prefs.categories.first { $0.category == "mention" })
        h.tower.conflictNextRulesPut = true   // another device turned it off first
        do {
            _ = try await h.sync.setNotificationInboxRule(h.connection, h.workspace, category: mention, on: true, known: prefs)
            XCTFail("a conflict is reported, not overwritten")
        } catch NotificationPreferenceError.changedElsewhere(let current) {
            XCTAssertFalse(current.inboxOn(mention), "the screen shows the actual (other device's) choice")
            XCTAssertEqual(current.rowVersion(source: "flightdeck.core", category: "mention", clientAppId: "ambulando", channel: "inbox"), 5)
        }
        XCTAssertEqual(h.tower.ruleBodies.count, 1, "no second PUT")
        // The next explicit choice rebases on the adopted row with a new mutation id.
        let reloaded = try await h.sync.loadNotificationPreferences(h.connection, h.workspace)
        let applied = try await h.sync.setNotificationInboxRule(h.connection, h.workspace, category: mention, on: true, known: reloaded)
        XCTAssertTrue(applied.inboxOn(mention))
        let bodies = h.tower.ruleBodies
        XCTAssertNotEqual(bodies[0]["mutation_id"] as? String, bodies[1]["mutation_id"] as? String)
        XCTAssertEqual((bodies[1]["rules"] as? [[String: Any]])?.first?["expected_row_version"] as? Int, 5)
        await h.chat.engine.waitUntilIdle()
    }

    func testFilteredEmptyPageAdvancesToHeadOnceAndAPreferenceChangeRelists() async throws {
        let h = try await NotificationHarness.make()
        h.tower.put(title: "visible", category: "mention")
        try await h.run()
        // A hidden category keeps arriving: the filtered page is empty but the cursor must still advance, once.
        h.tower.hiddenCategories = ["chat_thread"]
        for _ in 0..<3 { h.tower.put(title: "hidden", category: "chat_thread") }
        let before = h.tower.recordedRequests.filter { $0.contains("/changes") }.count
        try await h.run()
        let status = try await h.status()
        XCTAssertEqual(status.localSeq, h.tower.seq, "advanced to the head though every row was filtered")
        XCTAssertEqual(h.tower.recordedRequests.filter { $0.contains("/changes") }.count, before + 1, "no healing loop")
        try await h.run()
        XCTAssertEqual(h.tower.recordedRequests.filter { $0.contains("/changes") }.count, before + 2, "the next job asks once from the head")
        let titles = try await h.items().map(\.title)
        XCTAssertEqual(titles, ["visible"])
        // The person's rules change (another app view): 410 rules_changed, then the listing is recomputed.
        h.tower.hiddenCategories = []
        h.tower.rulesRevision = 2
        let first = try await h.run()
        XCTAssertTrue(first.reschedule)
        try await h.run()
        let after = try await h.items().count
        XCTAssertEqual(after, 4)
    }

    func testMixedRulesRevisionPagesRestartTheListing() async throws {
        let h = try await NotificationHarness.make()
        for i in 0..<120 { h.tower.put(title: "n\(i)") }
        try await h.run(budget: 1)
        var status = try await h.status()
        XCTAssertEqual(status.rulesRevision, 1)
        h.tower.rulesRevision = 2                     // changes while the listing is between jobs
        let resumed = try await h.run(budget: 1)
        XCTAssertEqual(resumed.listed, 50, "the listing restarted from the first page rather than mixing revisions")
        status = try await h.status()
        XCTAssertEqual(status.rulesRevision, 2)
        try await h.run(budget: 5)
        status = try await h.status()
        XCTAssertEqual(status.state, .ready)
        let count = try await h.items(.all).count
        XCTAssertEqual(count, 120)
    }

    func testMandatoryCategoryIsRefusedBeforeAnyRequest() async throws {
        let h = try await NotificationHarness.make()
        let prefs = try await h.sync.loadNotificationPreferences(h.connection, h.workspace)
        let security = try XCTUnwrap(prefs.categories.first { $0.category == "security" })
        do { _ = try await h.sync.setNotificationInboxRule(h.connection, h.workspace, category: security, on: false, known: prefs); XCTFail("refused") }
        catch NotificationPreferenceError.mandatory {}
        XCTAssertTrue(h.tower.ruleBodies.isEmpty)
    }

    func testResolutionOwnBeatsSharedAndDefaultIsSkipped() {
        let category = NotificationCategoryInfo(sourceAppId: "s", sourceLabel: "S", category: "c", label: "C", mandatory: false, defaultInbox: true)
        var prefs = NotificationPreferences()
        prefs.rules = [NotificationRule(sourceAppId: "s", category: "c", clientAppId: "*", channel: "inbox", mode: "off")]
        XCTAssertFalse(prefs.inboxOn(category))
        prefs.rules.append(NotificationRule(sourceAppId: "s", category: "c", clientAppId: "ambulando", channel: "inbox", mode: "on"))
        XCTAssertTrue(prefs.inboxOn(category), "this app's own rule beats the shared one")
        prefs.rules = [NotificationRule(sourceAppId: "s", category: "c", clientAppId: "ambulando", channel: "inbox", mode: "default", rowVersion: 4)]
        XCTAssertTrue(prefs.inboxOn(category), "a reset keeps its row but is skipped")
        XCTAssertEqual(prefs.rowVersion(source: "s", category: "c", clientAppId: "ambulando", channel: "inbox"), 4)
    }
}
