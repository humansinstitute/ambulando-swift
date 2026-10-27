import XCTest
@testable import AmbulandoCore

/// A tap on a delivered alert, resolved end to end against the fake Tower: cold start (nothing synced, workspaces read from
/// the store), warm tap, locked identity, a revoked/tombstoned item and a failing check. The crash that made build 29 abort
/// on every tap is an isolation bug in the app target; these cover what the tap does once it runs.
final class PushTapTests: XCTestCase {
    private func payload(_ h: NotificationHarness, notification: String?, category: String? = "mention", workspace: String? = nil,
                         origin: String? = nil) throws -> PushPayload {
        var fd: [String: Any] = ["v": 1, "origin": origin ?? h.connection.origin, "workspace_id": workspace ?? h.workspace.id]
        if let notification { fd["notification_id"] = notification }
        if let category { fd["category"] = category }
        return try PushPayload.parse(userInfo: ["aps": ["alert": ["title": "New activity", "body": ""]], "fd": fd])
    }

    /// The app's snapshot: workspaces come from the store, not from a view that may not have loaded on a cold start.
    private func snapshot(_ h: NotificationHarness, locked: Bool = false) async throws -> PushTapSnapshot {
        let listed = try await h.store.reader.workspaces(connectionId: h.connection.id)
        return PushTapSnapshot(connectedOrigin: try TowerOrigin(h.connection.origin), connectedTowerNpub: h.connection.towerNpub,
                               workspaceIds: Set(listed.map(\.id)), isLocked: locked)
    }

    private func resolve(_ h: NotificationHarness, _ p: PushPayload?, locked: Bool = false) async throws -> PushTapResolution {
        let s = try await snapshot(h, locked: locked)
        return await PushTapResolver.resolve(p, snapshot: s) { workspaceId, id in
            XCTAssertEqual(workspaceId, h.workspace.id)
            return try await h.sync.notificationForTap(h.connection, h.workspace, id: id)
        }
    }

    func testColdTapWithNothingSyncedReadsTheItemAndOpensIt() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put(title: "Blinkers", target: ["kind": "app_object", "app_id": "blinkers", "object_type": "capture", "object_id": "x"])
        let cached = try await h.items()
        XCTAssertTrue(cached.isEmpty)
        let ids = try await snapshot(h).workspaceIds
        XCTAssertFalse(ids.isEmpty, "the saved connection lists its workspace without any view having loaded")
        let resolution = try await resolve(h, try payload(h, notification: id))
        guard case .openItem(let item) = resolution else { return XCTFail("expected openItem, got \(resolution)") }
        XCTAssertEqual(item.id, id)
        XCTAssertTrue(h.tower.requests.contains("GET /items/\(id)?"), "a direct id read with no query: \(h.tower.requests)")
    }

    func testWarmTapReadsFreshEvenWhenTheItemIsCachedAndChanged() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put(title: "Before")
        try await h.run()
        _ = h.tower.set(id, read: true)
        let resolution = try await resolve(h, try payload(h, notification: id))
        guard case .openItem = resolution else { return XCTFail("expected openItem, got \(resolution)") }
        XCTAssertTrue(h.tower.requests.contains("GET /items/\(id)?"))
    }

    func testRevokedTestItemIsNeutralUnavailableNotACrashOrAGenericFailure() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put(title: "Secret thread title")
        try await h.run()
        h.tower.lock.withLock { h.tower.tombstoned.insert(id) }
        let resolution = try await resolve(h, try payload(h, notification: id, category: "mention"))
        XCTAssertEqual(resolution, .show(.unavailable(category: "mention")))
        guard case .show(let outcome) = resolution else { return }
        XCTAssertEqual(outcome.message, "That mention is no longer available to you. It may have been withdrawn or you may have lost access.")
        XCTAssertFalse(outcome.message.contains("Secret"), "the cached title is never shown for an item Tower refuses")
    }

    func testFailedCheckOpensNothingAndSaysSo() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        try await h.run()
        h.tower.status = 503
        let resolution = try await resolve(h, try payload(h, notification: id, category: "task_assignment"))
        XCTAssertEqual(resolution, .show(.couldNotCheck(category: "task_assignment")))
        guard case .show(let outcome) = resolution else { return }
        XCTAssertEqual(outcome.message, "Couldn't check that task assignment just now. Open Notifications to try again.")
    }

    func testLockedIdentityHoldsWithoutAnyRequestAndResolvesAfterUnlock() async throws {
        let locked = try await NotificationHarness.make(unlocked: false)
        let id = locked.tower.put()
        let p = try payload(locked, notification: id)
        let held = try await resolve(locked, p, locked: true)
        XCTAssertEqual(held, .hold(p))
        XCTAssertFalse(locked.tower.requests.contains { $0.contains("/items/\(id)") })
        // Locked at the signer even though the app thinks it is unlocked: the check throws, nothing opens.
        let stale = try await resolve(locked, p, locked: false)
        XCTAssertEqual(stale, .show(.couldNotCheck(category: "mention")))

        let unlocked = try await NotificationHarness.make()
        let again = unlocked.tower.put()
        let after = try await resolve(unlocked, try payload(unlocked, notification: again))
        guard case .openItem = after else { return XCTFail("expected openItem after unlock, got \(after)") }
    }

    func testForeignOriginUnknownWorkspaceAndUnreadablePayloadAreNeutralAndMakeNoRequest() async throws {
        let h = try await NotificationHarness.make()
        let id = h.tower.put()
        let foreign = try await resolve(h, try payload(h, notification: id, origin: "https://elsewhere.sample.invalid"))
        XCTAssertEqual(foreign, .show(.notForThisConnection))
        let stranger = try await resolve(h, try payload(h, notification: id, workspace: UUID().uuidString.lowercased()))
        XCTAssertEqual(stranger, .show(.notForThisConnection))
        let unreadable = try await resolve(h, nil)
        XCTAssertEqual(unreadable, .show(.notForThisConnection))
        XCTAssertFalse(h.tower.requests.contains { $0.contains("/items/") }, "no payload-origin authority: nothing was fetched")
    }

    func testRecordOnlyAlertOpensTheRecordWithoutAnInboxRead() async throws {
        let h = try await NotificationHarness.make()
        let thread = UUID().uuidString.lowercased()
        let p = try PushPayload.parse(userInfo: ["fd": ["v": 1, "origin": h.connection.origin, "workspace_id": h.workspace.id, "thread_id": thread]])
        let resolution = try await resolve(h, p)
        XCTAssertEqual(resolution, .openRecord(p))
        XCTAssertTrue(h.tower.requests.isEmpty)
    }

    func testCategoryWordingNamesTheKindOnly() {
        XCTAssertEqual(PushCategoryWording.noun("mention"), "mention")
        XCTAssertEqual(PushCategoryWording.noun("task_assignment"), "task assignment")
        XCTAssertEqual(PushCategoryWording.noun("chat_thread"), "reply")
        XCTAssertEqual(PushCategoryWording.noun("something_new"), "notification")
        XCTAssertEqual(PushCategoryWording.noun(nil), "notification")
    }
}
