import Foundation
import XCTest
@testable import AmbulandoCore

private final class MoveTower: @unchecked Sendable {
    let lock = NSLock()
    var failAfterSave = true
    var status = 200
    var confirmations: [[String: Any]] = []
    func handler(_ request: URLRequest) throws -> (Int, Any) {
        try lock.withLock {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if request.url!.path.hasSuffix("move-preview") {
                return (200, ["preview": ["channel_id": Fixtures.channel1, "source_scope_id": Fixtures.scopeA,
                    "destination_scope_id": Fixtures.scopeB, "confirmation_token": "bound-token",
                    "access_changes": ["gained": [], "lost": [], "retained": [], "direct_grants_preserved": true, "direct_grant_count": 2,
                        "source_scope_access": [["label": "Alpha readers", "permissions": ["scope.read"]]], "destination_scope_access": [["label": "Beta readers", "permissions": ["scope.read"]]]],
                    "warnings": ["Scope grants do not confer channel content access."]]])
            }
            confirmations.append(body)
            if status != 200 { return (status, ["message": "Preview expired; review access again."]) }
            if failAfterSave { failAfterSave = false; throw URLError(.networkConnectionLost) }
            var row = Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeB, name: "Moved")
            row["row_version"] = 2
            return (200, ["channel": row])
        }
    }
}

final class ChannelMoveTests: XCTestCase {
    func testPreviewDoesNotMoveAndInterruptedConfirmationRetriesExactMutation() async throws {
        let h = try await ChatHarness.make()
        let tower = MoveTower()
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: StubTransport { try tower.handler($0) })
        let original = try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "Original")))
        try await h.store.writer.upsertChannels(workspaceId: h.workspace.id, scopeId: Fixtures.scopeA, [original], complete: false)
        let preview = try await manager.previewChannelMove(h.connection, h.workspace, channelId: original.id, destinationScopeId: Fixtures.scopeB)
        XCTAssertTrue(preview.accessSummary.contains("Beta readers"))
        XCTAssertTrue(preview.accessSummary.contains("Direct channel grants: unchanged"))
        let before = try await h.store.reader.channel(workspaceId: h.workspace.id, id: original.id)
        XCTAssertEqual(before?.scopeId, Fixtures.scopeA)
        do { _ = try await manager.confirmChannelMove(h.connection, h.workspace, preview: preview); XCTFail("Expected interrupted response") }
        catch ManagementError.offline { }
        let afterInterruption = try await h.store.reader.channel(workspaceId: h.workspace.id, id: original.id)
        XCTAssertEqual(afterInterruption?.scopeId, Fixtures.scopeA)
        let saved = try await manager.confirmChannelMove(h.connection, h.workspace, preview: preview)
        XCTAssertEqual(saved.scopeId, Fixtures.scopeB)
        XCTAssertEqual(tower.confirmations.count, 2)
        XCTAssertEqual(tower.confirmations[0]["mutation_id"] as? String, tower.confirmations[1]["mutation_id"] as? String)
        XCTAssertEqual(tower.confirmations[0]["confirmation_token"] as? String, "bound-token")
    }

    func testConflictAndPermissionRefusalNeverWriteScope() async throws {
        for status in [403, 404, 409] {
            let h = try await ChatHarness.make()
            let tower = MoveTower(); tower.status = status
            let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: StubTransport { try tower.handler($0) })
            let preview = try await manager.previewChannelMove(h.connection, h.workspace, channelId: Fixtures.channel1, destinationScopeId: Fixtures.scopeB)
            do { _ = try await manager.confirmChannelMove(h.connection, h.workspace, preview: preview); XCTFail("Expected refusal") }
            catch is ManagementError { }
            let channel = try await h.store.reader.channel(workspaceId: h.workspace.id, id: Fixtures.channel1)
            XCTAssertNotEqual(channel?.scopeId, Fixtures.scopeB)
        }
    }

    func testCanonicalChannelMoveRelocatesLoadedTaskAndPreservesContentOnSourcePrune() async throws {
        let h = try await ChatHarness.make()
        let w = h.workspace.id
        var channel = Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "Original")
        try await h.store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [try ChannelRecord(raw: Fixtures.json(channel))], complete: false)
        let id = "a0000000-0000-4000-8000-000000000001"
        var taskRow = FakeEventTower.task(id, title: "Preserved task", version: 1, channel: Fixtures.channel1)
        taskRow["scope_id"] = Fixtures.scopeA
        let task = try TaskRecord(raw: Fixtures.json(taskRow))
        try await h.store.writer.upsertTasks(workspaceId: w, [task])
        var messageRow = h.tower.seed(channel: Fixtures.channel1, body: "Preserved message")
        messageRow["scope_id"] = Fixtures.scopeA
        let message = try MessageRecord(raw: Fixtures.json(messageRow))
        try await h.store.writer.upsertMessages([message])
        let content = SampleWorkTower(workspaceId: w, towerOrigin: "https://tower.example")
        let docId = content.seedDoc(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Preserved doc", body: Data("draft body".utf8), contentType: "text/plain")
        let fileId = content.seedFile(channel: Fixtures.channel1, scope: Fixtures.scopeA, name: "preserved.txt", bytes: Data("file bytes".utf8), contentType: "text/plain")
        try await h.store.writer.upsertDocs(workspaceId: w, [try DocRecord(raw: Fixtures.json(try XCTUnwrap(content.doc(docId))))])
        try await h.store.writer.upsertFiles(workspaceId: w, [try FileRecord(raw: Fixtures.json(try XCTUnwrap(content.file(fileId))))])
        try await h.store.writer.upsertViewStates(workspaceId: w, [ViewStateRecord(workspaceId: w, resourceType: .task, resourceId: id,
            scopeId: Fixtures.scopeA, channelId: Fixtures.channel1, activityVersion: 9, viewedActivityVersion: 4, updatedAt: "2026-11-04T00:00:00Z")])
        channel["scope_id"] = Fixtures.scopeB; channel["row_version"] = 2
        try await h.store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeB, [try ChannelRecord(raw: Fixtures.json(channel))], complete: false)
        try await h.store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [], complete: true)
        let old = try await h.store.reader.tasks(workspaceId: w, context: WorkContext(scopeId: Fixtures.scopeA))
        let moved = try await h.store.reader.tasks(workspaceId: w, context: WorkContext(scopeId: Fixtures.scopeB))
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(moved.map(\.id), [id])
        XCTAssertEqual(moved.first?.scopeId, Fixtures.scopeB)
        XCTAssertEqual(moved.first?.title, task.title)
        XCTAssertEqual(moved.first?.rowVersion, task.rowVersion)
        let doc = try await h.store.reader.doc(workspaceId: w, id: docId)
        let file = try await h.store.reader.file(workspaceId: w, id: fileId)
        let views = try await h.store.reader.viewStates(workspaceId: w)
        let movedMessage = try await h.store.reader.message(workspaceId: w, id: message.id)
        XCTAssertEqual(movedMessage?.body, "Preserved message")
        let movedMessageObject = try JSONSerialization.jsonObject(with: try XCTUnwrap(movedMessage?.raw)) as? [String: Any]
        XCTAssertEqual(movedMessageObject?["scope_id"] as? String, Fixtures.scopeB)
        XCTAssertEqual(doc?.scopeId, Fixtures.scopeB); XCTAssertEqual(doc?.title, "Preserved doc")
        XCTAssertEqual(file?.scopeId, Fixtures.scopeB); XCTAssertEqual(file?.displayName, "preserved.txt")
        XCTAssertEqual(views.first?.scopeId, Fixtures.scopeB)
        XCTAssertEqual(views.first?.viewedActivityVersion, 4); XCTAssertEqual(views.first?.activityVersion, 9)
        // An old projection cannot move the channel or child rows back.
        channel["scope_id"] = Fixtures.scopeA; channel["row_version"] = 1
        try await h.store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [try ChannelRecord(raw: Fixtures.json(channel))], complete: false)
        let current = try await h.store.reader.channel(workspaceId: w, id: Fixtures.channel1)
        XCTAssertEqual(current?.scopeId, Fixtures.scopeB)
    }

    func testWorkspaceRefreshFindsDestinationBeforePruningSource() async throws {
        let h = try await ChatHarness.make()
        let w = h.workspace.id
        try await h.store.writer.upsertScopes(workspaceId: w, [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "Source"))),
            try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeB, name: "Destination")))], complete: true)
        let channel = try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "Original")))
        try await h.store.writer.upsertChannels(workspaceId: w, scopeId: Fixtures.scopeA, [channel], complete: false)
        let taskId = UUID().uuidString.lowercased()
        var taskRow = FakeEventTower.task(taskId, title: "Retain across reconnect", version: 1, channel: channel.id)
        taskRow["scope_id"] = Fixtures.scopeA
        try await h.store.writer.upsertTasks(workspaceId: w, [try TaskRecord(raw: Fixtures.json(taskRow))])
        let fallback = h.tower.handler()
        let transport = StubTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/scopes") {
                return (200, ["scopes": [Fixtures.scope(Fixtures.scopeA, name: "Source"), Fixtures.scope(Fixtures.scopeB, name: "Destination")], "next_cursor": NSNull()])
            }
            if path.hasSuffix("/channels") {
                var moved = Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeB, name: "Original"); moved["row_version"] = 2
                return (200, ["channels": path.contains(Fixtures.scopeB) ? [moved] : [], "next_cursor": NSNull()])
            }
            return try fallback(request)
        }
        let sync = WorkspaceSync(store: h.store, engine: h.engine, identity: h.identity, transport: transport)
        await sync.refreshWorkspace(h.connection, h.workspace, includeDirectory: false)
        await h.engine.waitUntilIdle()
        let tasks = try await h.store.reader.tasks(workspaceId: w, context: WorkContext(scopeId: Fixtures.scopeB))
        XCTAssertEqual(tasks.map(\.id), [taskId], "Source-first complete lists must not erase the moved channel's cache")
        XCTAssertEqual(tasks.first?.title, "Retain across reconnect")
    }

    func testDestinationHintsExcludeUnsupportedAndKnownUnmanageableScopes() throws {
        let channel = try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "Original")))
        for kind in ["dm", "system", "archive"] {
            var row = Fixtures.scope(Fixtures.scopeB, name: "Unavailable"); row["kind"] = kind
            let scope = try ScopeRecord(raw: Fixtures.json(row))
            XCTAssertFalse(ChannelMoveEligibility.destination(scope, channel: channel, membership: WorkspaceMembership(role: "admin")))
        }
        var row = Fixtures.scope(Fixtures.scopeB, name: "Restricted"); row["can_manage"] = false
        let restricted = try ScopeRecord(raw: Fixtures.json(row))
        XCTAssertFalse(ChannelMoveEligibility.destination(restricted, channel: channel, membership: WorkspaceMembership(role: "member")))
        XCTAssertTrue(ChannelMoveEligibility.destination(restricted, channel: channel, membership: WorkspaceMembership(role: "admin")))
        row["default_channel_id"] = channel.id
        XCTAssertFalse(ChannelMoveEligibility.supports(channel, source: try ScopeRecord(raw: Fixtures.json(row))))
    }

    func testMalformedOrMismatchedPreviewCannotBeConfirmed() {
        XCTAssertThrowsError(try ChannelMovePreview(["preview": ["channel_id": Fixtures.channel2]], channelId: Fixtures.channel1, destination: Fixtures.scopeB))
        let access: [String: Any] = ["gained": [], "lost": [], "retained": [], "direct_grants_preserved": true,
                                  "direct_grant_count": 0, "source_scope_access": [], "destination_scope_access": []]
        let complete: [String: Any] = ["channel_id": Fixtures.channel1, "source_scope_id": Fixtures.scopeA,
            "destination_scope_id": Fixtures.scopeB, "confirmation_token": "token", "access_changes": access, "warnings": []]
        XCTAssertNoThrow(try ChannelMovePreview(["preview": complete], channelId: Fixtures.channel1, destination: Fixtures.scopeB))
        for field in ["gained", "lost", "retained", "direct_grants_preserved", "direct_grant_count", "source_scope_access", "destination_scope_access"] {
            var incompleteAccess = access; incompleteAccess.removeValue(forKey: field)
            var incomplete = complete; incomplete["access_changes"] = incompleteAccess
            XCTAssertThrowsError(try ChannelMovePreview(["preview": incomplete], channelId: Fixtures.channel1, destination: Fixtures.scopeB), field)
        }
        var mismatched = complete; mismatched["destination_scope_id"] = Fixtures.scopeA
        XCTAssertThrowsError(try ChannelMovePreview(["preview": mismatched], channelId: Fixtures.channel1, destination: Fixtures.scopeB))
    }
}
