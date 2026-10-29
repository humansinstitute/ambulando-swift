import XCTest
@testable import AmbulandoCore

final class GroupDirectoryTests: XCTestCase {
    func testNamesKindsCanonicalIDsAndCycleHints() {
        let person = AdministrationRow(["actor_id": Fixtures.scopeA, "npub": TestKeys.npub, "display_name": "Ana María · Operations", "kind": "human"])
        XCTAssertEqual(GroupDirectory.search([person], query: "MARÍA").count, 1)
        XCTAssertEqual(GroupDirectory.search([person], query: TestKeys.npub).count, 1)
        XCTAssertEqual(GroupDirectory.search([person], query: Fixtures.scopeA).count, 1)
        XCTAssertTrue(GroupDirectory.search([person], query: "missing").isEmpty)
        let a = AdministrationRow(["group_id": Fixtures.scopeA, "child_group_ids": [Fixtures.scopeB]])
        let b = AdministrationRow(["group_id": Fixtures.scopeB])
        XCTAssertEqual(GroupDirectory.attachmentState(parent: a.id, child: b.id, groups: [a,b]), "Already nested")
        XCTAssertEqual(GroupDirectory.attachmentState(parent: b.id, child: a.id, groups: [a,b]), "Would create a cycle")
        XCTAssertEqual(GroupDirectory.attachmentState(parent: a.id, child: a.id, groups: [a,b]), "This group")
    }

    func testExistingMemberAddIsIdempotentAndNeverWritesWorkspaceMembership() async throws {
        let h = try await ChatHarness.make()
        let tower = SampleAdministrationTower(workspace: h.workspace.id)
        tower.seedMembers([["actor_id": Fixtures.scopeB, "npub": TestKeys.npub, "display_name": "Ana", "role": "admin", "kind": "human"]])
        tower.seedGroups([["group_id": Fixtures.scopeA, "name": "Operations", "kind": "custom", "members": []]])
        let transport = StubTransport { request in try tower.handle(request) ?? (404, ["code": "not_found"]) }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        for _ in 0..<3 { try await manager.addExistingGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub) }
        let writes = transport.recorded.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes.allSatisfy { $0.url!.path.hasSuffix("/groups/\(Fixtures.scopeA)/members") })
        tower.denied = true
        do { try await manager.addExistingGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub); XCTFail("denied") } catch {}
        XCTAssertEqual(transport.recorded.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testMissingPersonAndInvalidKeyNeverCreateMembership() async throws {
        let h = try await ChatHarness.make()
        let tower = SampleAdministrationTower(workspace: h.workspace.id)
        tower.seedMembers([]); tower.seedGroups([["group_id": Fixtures.scopeA, "name": "Ops"]])
        let transport = StubTransport { request in try tower.handle(request) ?? (404, [:]) }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        do { try await manager.addExistingGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: "npub-bad"); XCTFail("invalid") } catch {}
        XCTAssertTrue(transport.recorded.isEmpty)
        do { try await manager.addExistingGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub); XCTFail("missing") } catch {}
        XCTAssertFalse(transport.recorded.contains { $0.httpMethod == "POST" })
    }

    func testOfflineRetainsDirectoriesAndDoesNotReplay() async throws {
        let h = try await ChatHarness.make()
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        do { try await manager.addExistingGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub); XCTFail("offline") } catch {}
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(transport.recorded.first?.httpMethod, "GET")
    }

    func testLargeLocalDirectorySearchBudget() {
        let rows = (0..<5000).map { AdministrationRow(["actor_id": "actor-\($0)", "display_name": "Person \($0) Operations", "kind": "human"]) }
        let start = ContinuousClock.now
        for i in 0..<10 { XCTAssertFalse(GroupDirectory.search(rows, query: "Person \(i)").isEmpty) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }
}

extension GroupDirectoryTests {
    func testAtomicEnrolmentBodyAndNoUnsafeFallbackOnOldOrDeniedServer() async throws {
        let h = try await ChatHarness.make()
        for status in [404, 403, 503] {
            let transport = StubTransport { request in
                if request.url!.path.hasSuffix("/groups") { return (200, ["groups": [["group_id": Fixtures.scopeA, "name": "Operations"]]]) }
                if request.url!.path.hasSuffix("/me") { return (200, ["membership": ["role": "admin"]]) }
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(request.url!.path.hasSuffix("/groups/\(Fixtures.scopeA)/members"))
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["member_npub"] as? String, TestKeys.npub)
                XCTAssertEqual(body["ensure_workspace_member"] as? Bool, true)
                XCTAssertEqual(body["kind"] as? String, "agent")
                XCTAssertNil(body["role"])
                return (status, ["code": status == 404 ? "workspace_member_not_found" : "permission_denied"])
            }
            let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
            do { try await manager.enrolGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub, kind: "agent"); XCTFail("refusal") } catch {}
            XCTAssertEqual(transport.recorded.filter { $0.httpMethod == "POST" }.count, 1)
            XCTAssertFalse(transport.recorded.contains { $0.httpMethod == "POST" && $0.url!.path == "/api/v4/flightdeck-pg/workspaces/\(h.workspace.id)/members" })
        }
    }

    func testAtomicEnrolmentRepeatedAddsPreserveExistingRoleAndKind() async throws {
        let h = try await ChatHarness.make()
        let tower = SampleAdministrationTower(workspace: h.workspace.id)
        tower.seedMembers([["actor_id": Fixtures.scopeB, "npub": TestKeys.npub, "display_name": "Existing admin", "role": "admin", "kind": "agent"]])
        tower.seedGroups([["group_id": Fixtures.scopeA, "name": "Ops", "members": []]])
        let transport = StubTransport { request in try tower.handle(request) ?? (404, [:]) }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        async let first: Void = manager.enrolGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub, kind: "human")
        async let race: Void = manager.enrolGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub, kind: "human")
        _ = try await (first, race)
        try await manager.refreshAdministration(h.connection, h.workspace, list: .members)
        try await manager.refreshAdministration(h.connection, h.workspace, list: .groups)
        let members = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .members)
        let groups = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .groups)
        XCTAssertEqual(members.count, 1); XCTAssertEqual(members.first?.fields["role"], "admin"); XCTAssertEqual(members.first?.fields["kind"], "agent")
        XCTAssertEqual(groups.first?.children.count, 1)
    }

    func testAtomicNewIdentityAndInvalidInput() async throws {
        let h = try await ChatHarness.make()
        let tower = SampleAdministrationTower(workspace: h.workspace.id)
        tower.seedMembers([]); tower.seedGroups([["group_id": Fixtures.scopeA, "name": "Ops"]])
        let transport = StubTransport { request in try tower.handle(request) ?? (404, [:]) }
        let manager = ScopeChannelManager(store: h.store, identity: h.identity, transport: transport)
        do { try await manager.enrolGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub, kind: "owner"); XCTFail("invalid kind") } catch {}
        XCTAssertTrue(transport.recorded.isEmpty)
        try await manager.enrolGroupPerson(h.connection, h.workspace, group: Fixtures.scopeA, npub: TestKeys.npub, kind: "agent")
        try await manager.refreshAdministration(h.connection, h.workspace, list: .members)
        let members = try await h.store.reader.administrationRows(connection: h.connection.id, workspace: h.workspace.id, list: .members)
        XCTAssertEqual(members.count, 1); XCTAssertEqual(members.first?.fields["role"], "member"); XCTAssertEqual(members.first?.fields["kind"], "agent")
    }
}
