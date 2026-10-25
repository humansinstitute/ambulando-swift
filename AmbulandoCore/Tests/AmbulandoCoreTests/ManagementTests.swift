import Foundation
import XCTest
@testable import AmbulandoCore

/// Stand-in for Tower's scope/channel management routes with the server rules the client relies on: permission
/// refusals (403), duplicate names (409), 1-based reorder, archive, and the personal scope order's row version.
final class FakeManagementTower: @unchecked Sendable {
    let lock = NSLock()
    var scopes: [[String: Any]] = [Fixtures.scope(Fixtures.scopeA, name: "Alpha").merging(["can_manage": true]) { $1 },
                                   Fixtures.scope(Fixtures.scopeB, name: "Beta").merging(["can_manage": false]) { $1 }]
    var channels: [[String: Any]] = [Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "general", position: 1),
                                     Fixtures.channel(Fixtures.channel2, scope: Fixtures.scopeA, name: "design", position: 2)]
    var orderIds: [String] = []
    var orderVersion = 3
    /// Scopes/channels where writes are refused with 403.
    var denied: Set<String> = [Fixtures.scopeB]
    /// Another session saves the order between the client's read and write.
    var concurrentOrderEdit = false
    var offline = false
    private(set) var bodies: [(method: String, path: String, body: [String: Any])] = []

    func handler() -> StubTransport.Handler { { [self] request in try self.route(request) } }

    private func route(_ request: URLRequest) throws -> (Int, Any) {
        if offline { throw URLError(.notConnectedToInternet) }
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true else { return (401, ["code": "unauthorized"]) }
        let method = request.httpMethod ?? "GET"
        let base = "/api/v4/flightdeck-pg/workspaces/\(Fixtures.workspaceId)"
        let path = request.url!.path.replacingOccurrences(of: base, with: "")
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        return lock.withLock {
            bodies.append((method, path, body))
            let parts = path.split(separator: "/").map(String.init)
            switch (method, parts.count, parts.first) {
            case ("GET", 1, "me"):
                return (200, ["membership": ["role": "member"], "permissions": ["channel.create", "channel.manage"], "actor": ["actor_id": "a1"]])
            case ("GET", 1, "scopes"):
                return (200, ["scopes": scopes, "next_cursor": NSNull()])
            case ("GET", 3, "scopes"):
                return (200, ["channels": channels.filter { $0["scope_id"] as? String == parts[1] }
                    .sorted { ($0["position"] as? Double ?? 0) < ($1["position"] as? Double ?? 0) }, "next_cursor": NSNull()])
            case ("POST", 3, "scopes"):
                if denied.contains(parts[1]) { return (403, ["code": "forbidden"]) }
                let name = body["name"] as? String ?? ""
                if channels.contains(where: { $0["scope_id"] as? String == parts[1] && $0["name"] as? String == name }) { return (409, ["code": "duplicate_channel"]) }
                var row = Fixtures.channel(UUID().uuidString.lowercased(), scope: parts[1], name: name, position: Double(channels.count + 1))
                row["metadata"] = body["metadata"] ?? [:]
                row["kind"] = body["kind"] ?? "channel"
                channels.append(row)
                return (201, ["channel": row])
            case ("POST", 1, "scopes"):
                let row = Fixtures.scope(UUID().uuidString.lowercased(), name: body["name"] as? String ?? "").merging(["can_manage": true]) { $1 }
                scopes.append(row)
                return (201, ["scope": row])
            case ("PATCH", 2, "scopes"), ("DELETE", 2, "scopes"):
                if denied.contains(parts[1]) { return (403, ["code": "forbidden"]) }
                guard let index = scopes.firstIndex(where: { $0["id"] as? String == parts[1] }) else { return (404, ["code": "scope_not_found"]) }
                if method == "DELETE" { let row = scopes.remove(at: index); return (200, ["scope": row]) }
                scopes[index]["name"] = body["name"]; scopes[index]["description"] = body["description"]; scopes[index]["updated_at"] = "2026-10-25T00:00:00.000Z"
                return (200, ["scope": scopes[index]])
            case ("PATCH", 2, "channels"), ("DELETE", 2, "channels"), ("POST", 3, "channels"):
                guard let index = channels.firstIndex(where: { $0["id"] as? String == parts[1] }) else { return (404, ["code": "channel_not_found"]) }
                if denied.contains(parts[1]) || denied.contains(channels[index]["scope_id"] as? String ?? "") { return (403, ["code": "forbidden"]) }
                if method == "DELETE" { let row = channels.remove(at: index); return (200, ["channel": row]) }
                if method == "POST" {
                    var siblings = channels.filter { $0["scope_id"] as? String == channels[index]["scope_id"] as? String }
                        .sorted { ($0["position"] as? Double ?? 0) < ($1["position"] as? Double ?? 0) }
                    let moved = siblings.remove(at: siblings.firstIndex { $0["id"] as? String == parts[1] }!)
                    siblings.insert(moved, at: min(max(0, (body["position"] as? Int ?? 1) - 1), siblings.count))
                    for (i, sibling) in siblings.enumerated() {
                        let j = channels.firstIndex { $0["id"] as? String == sibling["id"] as? String }!
                        channels[j]["position"] = Double(i + 1); channels[j]["updated_at"] = "2026-10-25T00:00:0\(i).000Z"
                    }
                    return (200, ["channel": channels[index], "changed": true])
                }
                if let name = body["name"] { channels[index]["name"] = name }
                if let metadata = body["metadata"] { channels[index]["metadata"] = metadata }
                channels[index]["updated_at"] = "2026-10-25T00:00:00.000Z"
                return (200, ["channel": channels[index]])
            case ("GET", 2, "me"):
                return (200, ["scope_order": ["scope_ids": orderIds, "row_version": orderVersion]])
            case ("PUT", 2, "me"):
                if concurrentOrderEdit { concurrentOrderEdit = false; orderVersion += 1; orderIds = [Fixtures.scopeB] }
                guard body["expected_row_version"] as? Int == orderVersion else { return (409, ["code": "scope_order_conflict"]) }
                orderIds = body["scope_ids"] as? [String] ?? []; orderVersion += 1
                return (200, ["scope_order": ["scope_ids": orderIds, "row_version": orderVersion]])
            default:
                return (404, ["code": "not_found"])
            }
        }
    }
}

final class ManagementTests: XCTestCase {
    private func harness(_ tower: FakeManagementTower = FakeManagementTower(), unlocked: Bool = true) async throws -> (ChatHarness, ScopeChannelManager) {
        let chat = try await ChatHarness.make(unlocked: unlocked)
        let transport = StubTransport(tower.handler())
        try await chat.store.writer.upsertScopes(workspaceId: Fixtures.workspaceId, try tower.scopes.map { try ScopeRecord(raw: Fixtures.json($0)) }, complete: true)
        try await chat.store.writer.upsertChannels(workspaceId: Fixtures.workspaceId, scopeId: Fixtures.scopeA,
                                                   try tower.channels.map { try ChannelRecord(raw: Fixtures.json($0)) }, complete: true)
        return (chat, ScopeChannelManager(store: chat.store, identity: chat.identity, transport: transport))
    }

    func testCreateChannelSendsTheWebBodyAndStoresTowersAnswer() async throws {
        let tower = FakeManagementTower()
        let (h, manager) = try await harness(tower)
        let channel = try await manager.createChannel(h.connection, h.workspace, scopeId: Fixtures.scopeA, name: "  ops  ",
                                                      description: "Runbooks", contextPrompt: "Be brief")
        XCTAssertEqual(channel.name, "ops")
        let sent = try XCTUnwrap(tower.bodies.last)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/scopes/\(Fixtures.scopeA)/channels")
        XCTAssertEqual(sent.body["kind"] as? String, "channel")
        XCTAssertEqual(sent.body["description"] as? String, "Runbooks")
        let chat = (sent.body["metadata"] as? [String: Any])?["agent_chat"] as? [String: Any]
        XCTAssertEqual(chat?["context_prompt"] as? String, "Be brief")
        XCTAssertEqual(chat?["activation"] as? String, "mention_then_continue")
        let stored = try await h.store.reader.channel(workspaceId: Fixtures.workspaceId, id: channel.id)
        XCTAssertEqual(stored?.scopeId, Fixtures.scopeA, "the new channel is in the sidebar's store at once")
    }

    func testRefusalsAreClassifiedAndNothingIsStored() async throws {
        let tower = FakeManagementTower()
        let (h, manager) = try await harness(tower)
        do {
            _ = try await manager.createChannel(h.connection, h.workspace, scopeId: Fixtures.scopeB, name: "x", description: nil, contextPrompt: nil)
            XCTFail("expected a refusal")
        } catch let error as ManagementError {
            XCTAssertEqual(error, .forbidden("You don't have permission to create channels in this scope."))
            XCTAssertFalse(error.retryable)
        }
        do {
            _ = try await manager.createChannel(h.connection, h.workspace, scopeId: Fixtures.scopeA, name: "general", description: nil, contextPrompt: nil)
            XCTFail("expected a duplicate")
        } catch let error as ManagementError {
            XCTAssertEqual(error, .duplicate("A channel with this name already exists in this scope."))
        }
        let channels = try await h.store.reader.channels(workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(channels.count, 2)
        tower.offline = true
        do {
            _ = try await manager.renameChannel(h.connection, h.workspace, channelId: Fixtures.channel1, name: "main")
            XCTFail("expected offline")
        } catch let error as ManagementError {
            guard case .offline = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.retryable)
        }
        let first = try await h.store.reader.channel(workspaceId: Fixtures.workspaceId, id: Fixtures.channel1)
        XCTAssertEqual(first?.name, "general", "a failed rename leaves the stored name")
    }

    func testLockedIdentityIsReportedBeforeAnyRequest() async throws {
        let tower = FakeManagementTower()
        let (h, manager) = try await harness(tower, unlocked: false)
        do {
            _ = try await manager.renameChannel(h.connection, h.workspace, channelId: Fixtures.channel1, name: "main")
            XCTFail("expected locked")
        } catch let error as ManagementError { XCTAssertEqual(error, .locked) }
        XCTAssertTrue(tower.bodies.isEmpty)
    }

    func testRenamePromptMoveAndArchiveUpdateTheStore() async throws {
        let tower = FakeManagementTower()
        tower.channels[0]["metadata"] = ["basePrompt": "old", "keep": "me"]
        let (h, manager) = try await harness(tower)
        let renamed = try await manager.renameChannel(h.connection, h.workspace, channelId: Fixtures.channel1, name: "main")
        XCTAssertEqual(renamed.name, "main")
        XCTAssertEqual(renamed.contextPrompt, "old", "the legacy prompt is read")
        let prompted = try await manager.saveContextPrompt(h.connection, h.workspace, channel: renamed, prompt: "new prompt")
        let sent = try XCTUnwrap(tower.bodies.last?.body["metadata"] as? [String: Any])
        XCTAssertNil(sent["basePrompt"], "the legacy key is replaced by agent_chat")
        XCTAssertEqual(sent["keep"] as? String, "me", "other metadata is kept")
        XCTAssertEqual(prompted.contextPrompt, "new prompt")

        try await manager.moveChannel(h.connection, h.workspace, channel: prompted, position: 2)
        XCTAssertEqual(tower.bodies.first { $0.path.hasSuffix("/reorder") }?.body["position"] as? Int, 2)
        let order = try await h.store.reader.channels(workspaceId: Fixtures.workspaceId).filter { $0.scopeId == Fixtures.scopeA }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }.map(\.name)
        XCTAssertEqual(order, ["design", "main"], "every sibling's new position is stored")

        let design = try await XCTUnwrapAsync(try await h.store.reader.channel(workspaceId: Fixtures.workspaceId, id: Fixtures.channel2))
        try await manager.archiveChannel(h.connection, h.workspace, channel: design)
        let remaining = try await h.store.reader.channels(workspaceId: Fixtures.workspaceId).map(\.id)
        XCTAssertEqual(remaining, [Fixtures.channel1], "an archived channel leaves the sidebar")
    }

    func testScopeOrderSendsTheCurrentVersionAndReportsAConflictWithoutReplaying() async throws {
        let tower = FakeManagementTower()
        let (h, manager) = try await harness(tower)
        try await manager.saveScopeOrder(h.connection, h.workspace, scopeIds: [Fixtures.scopeB, Fixtures.scopeA])
        let put = try XCTUnwrap(tower.bodies.last { $0.method == "PUT" })
        XCTAssertEqual(put.body["expected_row_version"] as? Int, 3)
        XCTAssertNotNil(put.body["mutation_id"] as? String)
        let stored = try await h.store.reader.state(WorkspaceSync.scopeOrderKey(Fixtures.workspaceId))
        XCTAssertEqual(ScopeOrdering.decode(stored), [Fixtures.scopeB, Fixtures.scopeA])

        tower.concurrentOrderEdit = true
        do {
            try await manager.saveScopeOrder(h.connection, h.workspace, scopeIds: [Fixtures.scopeA, Fixtures.scopeB])
            XCTFail("expected a conflict")
        } catch let error as ManagementError {
            XCTAssertEqual(error, .conflict("Your scope order changed in another session. Try your move again."))
        }
        XCTAssertEqual(tower.bodies.filter { $0.method == "PUT" }.count, 2, "the rejected order is not sent again")
        let fresh = try await h.store.reader.state(WorkspaceSync.scopeOrderKey(Fixtures.workspaceId))
        XCTAssertEqual(ScopeOrdering.decode(fresh), [Fixtures.scopeB], "the other session's order is stored")
    }

    func testScopeCreateEditArchiveAndCanManage() async throws {
        let tower = FakeManagementTower()
        let (h, manager) = try await harness(tower)
        let created = try await manager.createScope(h.connection, h.workspace, name: "Gamma", description: "New work")
        XCTAssertEqual(tower.bodies.first { $0.method == "POST" }?.body["kind"] as? String, "project", "the web form's kind")
        let stored = try await h.store.reader.scopes(workspaceId: Fixtures.workspaceId)
        XCTAssertEqual(stored.first { $0.id == created.id }?.canManage, true, "the list read back carries can_manage")
        XCTAssertEqual(stored.first { $0.id == Fixtures.scopeB }?.canManage, false)

        try await manager.updateScope(h.connection, h.workspace, scopeId: created.id, name: "Gamma 2", description: nil)
        let renamed = try await h.store.reader.scopes(workspaceId: Fixtures.workspaceId).first { $0.id == created.id }
        XCTAssertEqual(renamed?.name, "Gamma 2")
        do {
            try await manager.updateScope(h.connection, h.workspace, scopeId: Fixtures.scopeB, name: "Nope", description: nil)
            XCTFail("expected a refusal")
        } catch let error as ManagementError { XCTAssertEqual(error, .forbidden("You need Manage access on this scope.")) }

        try await manager.archiveScope(h.connection, h.workspace, scopeId: created.id)
        let after = try await h.store.reader.scopes(workspaceId: Fixtures.workspaceId).map(\.id)
        XCTAssertFalse(after.contains(created.id))
    }

    func testMembershipAndVisibilityRulesFollowTheWeb() async throws {
        let (h, manager) = try await harness()
        let membership = try await manager.membership(h.connection, h.workspace)
        XCTAssertEqual(membership.permissions, ["channel.create", "channel.manage"])
        XCTAssertFalse(membership.isAdmin)
        let scopes = try await h.store.reader.scopes(workspaceId: Fixtures.workspaceId)
        let alpha = try XCTUnwrap(scopes.first { $0.id == Fixtures.scopeA }), beta = try XCTUnwrap(scopes.first { $0.id == Fixtures.scopeB })
        XCTAssertTrue(ManagementPermissions.canCreateChannel(in: alpha, membership: membership))
        XCTAssertFalse(ManagementPermissions.canCreateChannel(in: beta, membership: membership), "can_manage false wins, as on the web")
        XCTAssertTrue(ManagementPermissions.canManage(alpha, membership: membership))
        XCTAssertFalse(ManagementPermissions.canManage(beta, membership: membership))
        XCTAssertFalse(ManagementPermissions.canCreateScope(membership))
        XCTAssertTrue(ManagementPermissions.canCreateScope(WorkspaceMembership(role: "admin")))
        let dm = ChannelRecord(workspaceId: Fixtures.workspaceId, id: UUID().uuidString.lowercased(), scopeId: Fixtures.scopeA, name: "dm", kind: "dm", updatedAt: "")
        XCTAssertFalse(ManagementPermissions.canManage(dm, membership: WorkspaceMembership(role: "owner")), "DMs are never managed here")
        let dmScope = ScopeRecord(workspaceId: Fixtures.workspaceId, id: UUID().uuidString.lowercased(), name: "Direct", kind: "dm", updatedAt: "")
        XCTAssertTrue(ManagementPermissions.canCreateChannel(in: dmScope, membership: nil))
        XCTAssertFalse(ManagementPermissions.isPersonallyOrdered(dmScope))
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
