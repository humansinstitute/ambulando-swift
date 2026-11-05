import XCTest
@testable import AmbulandoCore

/// Synthetic PRT-like records only; a passing probe does not establish the reported live hang is fixed.
final class PRTNavigationProbeTests: XCTestCase {
    func testRenamedDeletedNestedScopesAndStaleSelectionAreBounded() async throws {
        let store = try LocalStore(directory: temporaryDirectory())
        let w = Fixtures.workspaceId
        let parent = Fixtures.scopeA, prt = Fixtures.scopeB
        func scope(_ id: String, _ name: String, parent: String?) throws -> ScopeRecord {
            var row = Fixtures.scope(id, name: name)
            row["parent_id"] = parent ?? NSNull() as Any
            return try ScopeRecord(raw: Fixtures.json(row))
        }
        let old = try scope(prt, "Plantrite", parent: parent)
        try await store.writer.upsertScopes(workspaceId: w, [try scope(parent, "Old projects", parent: nil), old], complete: true)
        let selected = WorkContext(scopeId: prt, channelId: Fixtures.channel2)
        let channels = [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: prt, name: "general"))),
                        try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel2, scope: parent, name: "removed")))]
        try await store.writer.upsertChannels(workspaceId: w, scopeId: prt, [channels[0]], complete: true)
        try await store.writer.upsertChannels(workspaceId: w, scopeId: parent, [channels[1]], complete: true)
        // Rename same UUID; removed parent remains only in unknown raw metadata and stale order.
        try await store.writer.upsertScopes(workspaceId: w, [try scope(prt, "PRT", parent: parent)], complete: true)
        let scopes = try await store.reader.scopes(workspaceId: w)
        let storedChannels = try await store.reader.channels(workspaceId: w)
        let start = ContinuousClock.now
        for _ in 0..<100 {
            let groups = SidebarNavigation.groups(scopes: scopes + scopes, channels: storedChannels + channels, personalOrder: [parent, prt, prt, parent])
            XCTAssertEqual(groups.map(\.id), [prt])
            XCTAssertEqual(groups.first?.scope.name, "PRT")
            XCTAssertEqual(groups.first?.channels.map(\.id), [Fixtures.channel1])
            let resolved = selected.resolved(scopes: scopes, channels: storedChannels)
            XCTAssertEqual(resolved, WorkContext(scopeId: prt))
            XCTAssertEqual(resolved.resolved(scopes: scopes, channels: storedChannels), resolved)
            XCTAssertEqual(WorkContext(scopeId: parent).resolved(scopes: scopes, channels: storedChannels), .home)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        // Context components are the hierarchy actually traversed by the app: deleted parent, cycle, self-parent.
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased(), c = UUID().uuidString.lowercased()
        func component(_ id: String, _ parent: String?, _ title: String) throws -> ContextComponentRecord {
            try ContextComponentRecord(raw: Fixtures.json(["workspace_id": w, "scope_id": prt, "id": id,
                "parent_id": parent ?? NSNull() as Any, "title": title, "sort_order": 0, "row_version": 1, "updated_at": "2026-11-05T00:00:00Z"]))
        }
        let orphan = UUID().uuidString.lowercased()
        try await store.writer.upsertContextComponents(workspaceId: w, scopeId: prt,
            [component(a, b, "Renamed PRT API"), component(b, a, "Nested PRT"), component(c, c, "Self parent"), component(orphan, parent, "Deleted parent child")], complete: true)
        let tree = try await store.reader.contextTree(workspaceId: w, scopeId: prt)
        func ids(_ nodes: [ContextNode]) -> [String] { nodes.flatMap { [$0.id] + ids($0.children) } }
        let flattened = ids(tree)
        XCTAssertEqual(Set(flattened), [a, b, c, orphan])
        XCTAssertEqual(flattened.count, 4)
    }
}
