import Foundation
import XCTest
@testable import AmbulandoCore

final class WorkspaceAdministrationTests: XCTestCase {
    func testRealWriteShapesAndNarrowGrantBodies() throws {
        func body(_ command: AdministrationCommand, method: String, path: String) throws -> [String: Any] {
            let request = try command.request()
            XCTAssertEqual(request.0, method); XCTAssertEqual(request.1, path)
            return try request.2.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
        }
        let member = try body(.addMember(npub: TestKeys.npub, kind: "human"), method: "POST", path: "/members")
        XCTAssertEqual(member["member_npub"] as? String, TestKeys.npub); XCTAssertEqual(member["role"] as? String, "member")
        let group = try body(.createGroup(name: " Operations "), method: "POST", path: "/groups")
        XCTAssertEqual(group["name"] as? String, "Operations"); XCTAssertEqual(group["kind"] as? String, "custom")
        let add = try body(.groupMember(group: Fixtures.scopeA, npub: TestKeys.npub), method: "POST", path: "/groups/\(Fixtures.scopeA)/members")
        XCTAssertEqual(Set(add.keys), ["member_npub"])
        _ = try body(.removeGroupMember(group: Fixtures.scopeA, actor: Fixtures.scopeB), method: "DELETE", path: "/groups/\(Fixtures.scopeA)/members/\(Fixtures.scopeB)")
        let child = try body(.childGroup(parent: Fixtures.scopeA, child: Fixtures.scopeB, remove: false), method: "POST", path: "/groups/\(Fixtures.scopeA)/child-groups")
        XCTAssertEqual(child["child_group_id"] as? String, Fixtures.scopeB)
        let grant = try body(.channelGrant(channel: Fixtures.channel1, principalType: "group", principal: Fixtures.scopeA, access: "contribute", update: false), method: "POST", path: "/channels/\(Fixtures.channel1)/grants")
        XCTAssertEqual(grant["access_level"] as? String, "contribute"); XCTAssertEqual(grant["principal_type"] as? String, "group")
        XCTAssertNil(grant["permissions"])
        let update = try body(.channelGrant(channel: Fixtures.channel1, principalType: "actor", principal: Fixtures.scopeB, access: "view", update: true), method: "PUT", path: "/channels/\(Fixtures.channel1)/grants/actor/\(Fixtures.scopeB)")
        XCTAssertEqual(Set(update.keys), ["access_level"])
        let delegation = try body(.delegation(actor: Fixtures.scopeA, expires: "2099-01-01T00:00:00Z", app: "approved-app", scope: Fixtures.scopeA, channel: Fixtures.channel1), method: "POST", path: "/wapp-delegations")
        let filters = try XCTUnwrap(delegation["filters"] as? [String: Any])
        XCTAssertEqual(filters["app_ids"] as? [String], ["approved-app"])
        XCTAssertEqual(filters["channel_ids"] as? [String], [Fixtures.channel1])
        XCTAssertEqual(filters["capabilities"] as? [String], ["activity.publish"])
        _ = try body(.revokeDelegation(id: Fixtures.scopeA), method: "POST", path: "/wapp-delegations/\(Fixtures.scopeA)/revoke")
        _ = try body(.installation(id: Fixtures.scopeA, revoke: false), method: "POST", path: "/wapp-installations/\(Fixtures.scopeA)/reconcile")
        _ = try body(.installation(id: Fixtures.scopeA, revoke: true), method: "POST", path: "/wapp-installations/\(Fixtures.scopeA)/revoke")
    }

    func testLostAuthorityNeverSendsTheMutation() async throws {
        let h = try await ChatHarness.make()
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertTrue(request.url!.path.hasSuffix("/me"))
            return (200, ["membership": ["role": "member"], "permissions": ["workspace.read"]])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        do { try await manager.administer(h.connection, h.workspace, command: .createGroup(name: "Draft retained")); XCTFail("must refuse") }
        catch ManagementError.forbidden {} catch { XCTFail("\(error)") }
    }

    func testServerDenialAfterFreshAuthorityIsPreservedAndNotRetried() async throws {
        let h = try await ChatHarness.make()
        let transport = StubTransport { request in
            if request.httpMethod == "GET" { return (200, ["membership": ["role": "admin"]]) }
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["name"] as? String, "Only once")
            return (403, ["code": "permission_denied"])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        do { try await manager.administer(h.connection, h.workspace, command: .createGroup(name: "Only once")); XCTFail("must refuse") }
        catch ManagementError.forbidden {} catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.recorded.count, 2)
    }

    func testPersistedDirectoriesAreIsolatedAndRemainOnOfflineFailure() async throws {
        let h = try await ChatHarness.make()
        let online = StubTransport { _ in (200, ["groups": [["group_id": Fixtures.scopeA, "name": "Ops", "members": [["actor_id": Fixtures.scopeB, "display_name": "Ana"]]]], "next_cursor": NSNull()]) }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: online)
        try await manager.refreshAdministration(h.connection, h.workspace, list: .groups)
        let rows = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        XCTAssertEqual(rows.first?.title, "Ops"); XCTAssertEqual(rows.first?.children.first?.title, "Ana")
        let other = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: Fixtures.scopeB, list: .groups)
        XCTAssertTrue(other.isEmpty)
        let failing = ScopeChannelManager(store: h.store, identity: h.identity, transport: StubTransport { _ in throw URLError(.notConnectedToInternet) })
        do { try await failing.refreshAdministration(h.connection, h.workspace, list: .groups); XCTFail("must fail") } catch {}
        let kept = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        XCTAssertEqual(kept, rows)
        // Draft identity includes the connection/workspace/action, and survives reopening the SQLite store.
        let key = "admin.draft.v1:\(h.connection.id):\(h.workspace.id):group"
        try await h.store.writer.setState(key, "{\"name\":\"Unsent group\"}")
        let saved = try await h.store.reader.state(key)
        XCTAssertEqual(saved, "{\"name\":\"Unsent group\"}")
    }

    func testInvalidTargetsAndBroadGrantsFailBeforeNetwork() throws {
        XCTAssertThrowsError(try AdministrationCommand.channelGrant(channel: Fixtures.channel1, principalType: "workspace", principal: Fixtures.scopeA, access: "manage", update: false).request())
        XCTAssertThrowsError(try AdministrationCommand.delegation(actor: Fixtures.scopeA, expires: "2000-01-01T00:00:00Z", app: "", scope: Fixtures.scopeA, channel: Fixtures.channel1).request())
        XCTAssertThrowsError(try AdministrationCommand.groupMember(group: "../other", npub: TestKeys.npub).request())
    }
}

extension WorkspaceAdministrationTests {
    func testNestedActorProjectionAndStableMalformedIdentity() throws {
        let actor = AdministrationRow(["actor": ["actor_id": Fixtures.scopeA, "display_name": "Ana", "npub": TestKeys.npub], "membership": ["role": "member"]])
        XCTAssertEqual(actor.id, Fixtures.scopeA); XCTAssertEqual(actor.title, "Ana"); XCTAssertTrue(actor.detail.contains("member"))
        let first = AdministrationRow(["name": "Missing id"]), second = AdministrationRow(["name": "Missing id"])
        XCTAssertEqual(first.id, second.id); XCTAssertTrue(first.id.hasPrefix("unavailable:"))
    }

    func testDirectoryPaginationAndCrossWorkspaceRows() async throws {
        let h = try await ChatHarness.make()
        let transport = StubTransport { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "cursor" && $0.value == "second" }) {
                return (200, ["groups": [["group_id": Fixtures.scopeB, "name": "Second"]], "next_cursor": NSNull()])
            }
            return (200, ["groups": [["group_id": Fixtures.scopeA, "name": "First"]], "next_cursor": "second"])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        try await manager.refreshAdministration(h.connection, h.workspace, list: .groups)
        let rows = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        XCTAssertEqual(rows.map(\.title), ["First", "Second"]); XCTAssertEqual(transport.recorded.count, 2)
        transport.setHandler { _ in (200, ["groups": [["group_id": Fixtures.scopeA, "workspace_id": Fixtures.workspaceId2]], "next_cursor": NSNull()]) }
        do { try await manager.refreshAdministration(h.connection, h.workspace, list: .groups); XCTFail("must reject cross-workspace rows") } catch {}
        let kept = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        XCTAssertEqual(kept, rows)
    }

    func testGroupMemberAndNestedGroupFlowThroughActualSignedTransport() async throws {
        let h = try await ChatHarness.make()
        let sample = SampleAdministrationTower(workspace: h.workspace.id)
        sample.seedMembers([["actor_id": Fixtures.scopeA, "npub": TestKeys.npub, "display_name": "Ana"]])
        let transport = StubTransport { request in
            let event = try decodeAuthorization(request)
            XCTAssertEqual(event.kind, 27235)
            XCTAssertTrue(event.tags.contains(["u", request.url!.absoluteString]))
            XCTAssertTrue(event.tags.contains(["method", request.httpMethod!]))
            if let body = request.httpBody { XCTAssertTrue(event.tags.contains(["payload", SHA256Hex.of(body)])) }
            return try sample.handle(request) ?? (404, ["code": "not_found"])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        try await manager.administer(h.connection, h.workspace, command: .createGroup(name: "Parent"))
        try await manager.administer(h.connection, h.workspace, command: .createGroup(name: "Child"))
        try await manager.refreshAdministration(h.connection, h.workspace, list: .groups)
        var groups = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        let parent = try XCTUnwrap(groups.first { $0.title == "Parent" }), child = try XCTUnwrap(groups.first { $0.title == "Child" })
        try await manager.administer(h.connection, h.workspace, command: .groupMember(group: parent.id, npub: TestKeys.npub))
        try await manager.administer(h.connection, h.workspace, command: .childGroup(parent: parent.id, child: child.id, remove: false))
        try await manager.refreshAdministration(h.connection, h.workspace, list: .groups)
        groups = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        XCTAssertEqual(groups.first { $0.id == parent.id }?.children.first?.id, Fixtures.scopeA)
        XCTAssertEqual(groups.first { $0.id == parent.id }?.childGroupIds, [child.id])
        try await manager.administer(h.connection, h.workspace, command: .removeGroupMember(group: parent.id, actor: Fixtures.scopeA))
        try await manager.administer(h.connection, h.workspace, command: .childGroup(parent: parent.id, child: child.id, remove: true))
        try await manager.refreshAdministration(h.connection, h.workspace, list: .groups)
        let final = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        XCTAssertTrue(final.first { $0.id == parent.id }?.children.isEmpty == true)
        XCTAssertTrue(final.first { $0.id == parent.id }?.childGroupIds.isEmpty == true)
    }

    func testScopeAccessRejectsStaleRevisionWithoutLeaseOrWrite() async throws {
        let h = try await ChatHarness.make()
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, ["revision": 5, "can_manage": true, "grants": []])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        do {
            try await manager.saveScopeAccess(h.connection, h.workspace, scope: Fixtures.scopeA, principalType: "actor", principal: Fixtures.scopeB, role: "context_editor", revoke: false, expectedRevision: 4)
            XCTFail("must preserve concurrent change")
        } catch ManagementError.conflict {} catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.recorded.count, 1)
    }

    func testScopeGrantUsesExactLeaseRevisionAndReleasesIt() async throws {
        let h = try await ChatHarness.make()
        let transport = StubTransport { request in
            let path = request.url!.path
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            if path.hasSuffix("/edit-leases/acquire") {
                XCTAssertEqual(body["entity_type"] as? String, "scope"); XCTAssertEqual(body["entity_id"] as? String, Fixtures.scopeA)
                return (200, ["lease": ["id": Fixtures.scopeB, "entity_id": Fixtures.scopeA, "lease_token": "scope-token", "expires_at": "2099-01-01T00:00:00Z"]])
            }
            if path.hasSuffix("/release") { XCTAssertEqual(body["lease_token"] as? String, "scope-token"); return (200, [:]) }
            if request.httpMethod == "PUT" {
                XCTAssertEqual(body["expected_revision"] as? Int, 3)
                XCTAssertEqual(body["lease_token"] as? String, "scope-token")
                XCTAssertEqual(body["role"] as? String, "context_editor")
                return (200, ["revision": 4, "can_manage": true, "grants": [["principal_type": "actor", "principal_id": Fixtures.scopeB, "role": "context_editor"]]])
            }
            return (200, ["revision": 3, "can_manage": true, "grants": []])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        try await manager.saveScopeAccess(h.connection, h.workspace, scope: Fixtures.scopeA, principalType: "actor", principal: Fixtures.scopeB, role: "context_editor", revoke: false, expectedRevision: 3)
        XCTAssertEqual(transport.recorded.map { $0.httpMethod! }, ["GET", "POST", "PUT", "POST"])
        let saved = try await h.store.reader.scopeAdministrationAccess(connection: h.connection.id, workspace: h.workspace.id, scope: Fixtures.scopeA)
        XCTAssertEqual(saved?.revision, 4)
    }

    func testProfileAcknowledgementUpdatesOnlyItsPersistedWorkspace() async throws {
        let h = try await ChatHarness.make()
        try await h.store.writer.replaceWorkspaces(connectionId: h.connection.id, [h.workspace, try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId2, label: "Other")))])
        let transport = StubTransport { request in
            if request.httpMethod == "GET" { return (200, ["membership": ["role": "admin"]]) }
            return (200, ["name": "Confirmed name", "description": "New description", "avatar_url": "https://images.example.com/avatar.png"])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        try await manager.administer(h.connection, h.workspace, command: .profile(name: "Requested", description: "New description", avatarURL: "https://images.example.com/avatar.png"))
        let rows = try await h.store.reader.workspaces(connectionId: h.connection.id)
        XCTAssertEqual(rows.first { $0.id == h.workspace.id }?.label, "Confirmed name")
        XCTAssertEqual(rows.first { $0.id == Fixtures.workspaceId2 }?.label, "Other")
    }

    func testExactGrantAuthorityDoesNotTreatChannelManageAsGrantManage() {
        let membership = WorkspaceMembership(role: "member", permissions: ["channel.manage"], actorId: Fixtures.scopeA)
        let row = AdministrationRow(["principal_type": "actor", "principal_id": Fixtures.scopeA, "permissions": ["channel.grants.manage"]])
        XCTAssertTrue(AdministrationAuthority.canManageChannelGrants(membership: membership, grants: [row], groups: [], npub: TestKeys.npub))
        let other = AdministrationRow(["principal_type": "actor", "principal_id": Fixtures.scopeB, "permissions": ["channel.grants.manage"]])
        XCTAssertFalse(AdministrationAuthority.canManageChannelGrants(membership: membership, grants: [other], groups: [], npub: TestKeys.npub))
        XCTAssertFalse(AdministrationAuthority.canManageChannelGrants(membership: membership, grants: [], groups: [], npub: TestKeys.npub))
    }

    func testAutopilotExactPathsAndNoAppHeaderOrOriginSubstitution() async throws {
        let h = try await ChatHarness.make()
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.host, "autopilot.example.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-flightdeck-pg-app-npub"))
            let event = try decodeAuthorization(request)
            XCTAssertTrue(event.tags.contains(["u", request.url!.absoluteString]))
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["workspace_id"] as? String, Fixtures.workspaceId)
                XCTAssertEqual(body["intent_id"] as? String, Fixtures.scopeA)
                return (200, ["status": "completed"])
            }
            return (200, ["apps": [["app_id": "sample-app", "app_version": "1", "title": "Sample app", "launch_url": "https://app.example.com", "autopilot_origin": "https://autopilot.example.com", "autopilot_npub": TestKeys.npub, "view_origin": "https://app.example.com"]]])
        }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        let catalog = try await manager.activationCatalog(h.connection, origin: "https://autopilot.example.com")
        XCTAssertEqual(catalog.first?.id, "sample-app")
        try await manager.processActivationIntent(h.connection, h.workspace, origin: "https://autopilot.example.com", intent: Fixtures.scopeA)
        XCTAssertThrowsError(try TowerOrigin("https://autopilot.example.com").url(path: "/api/wapps/arbitrary-operation"))
        do {
            _ = try await manager.createActivationIntent(h.connection, h.workspace, app: XCTUnwrap(catalog.first), origin: "https://other.example.com", scope: Fixtures.scopeA, channel: Fixtures.channel1, installation: Fixtures.scopeB, requestId: Fixtures.scopeB, delegation: nil)
            XCTFail("must not substitute origin")
        } catch ManagementError.invalid {} catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.recorded.count, 2)
    }
}
