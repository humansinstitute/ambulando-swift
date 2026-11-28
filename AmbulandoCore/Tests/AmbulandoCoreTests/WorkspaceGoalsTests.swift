import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct WorkspaceGoalsTests {
    @Test func combinesAccessibleChannelsWithoutChangingPersonalGoals() async throws {
        let service = try await fixture()
        let personal = try await service.load()
        #expect(personal.goals.count == 1)
        let all = try await service.loadWorkspace()
        #expect(Set(all.goals.map(\.goal.name)) == ["Personal", "Shared"])
        #expect(all.goals.allSatisfy { $0.file.workspaceId == GoalWireTests.workspace })
        #expect(try await service.load().goals.map(\.goal.name) == ["Personal"])
        let shared = try #require(all.goals.first { $0.goal.name == "Shared" })
        #expect(try await service.read(shared.id).goal.name == "Shared")
    }

    @Test func foreignReadsAndPublishedEditsDoNotReplacePersonalSnapshot() async throws {
        var service = try await fixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = WorkspaceRecord(id: service.workspaceId, appNpub: service.appNpub, label: "Goals", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        service.cache = LocalContentSnapshot(store: try LocalStore(directory: directory), identity: service.identity,
            boundary: try WorkspaceBoundary(connection: connection, workspace: workspace))
        _ = try await service.load()
        #expect(await service.cached()?.goals.map(\.goal.name) == ["Personal"])
        let all = try await service.loadWorkspace()
        let shared = try #require(all.goals.first { $0.goal.name == "Shared" })
        _ = try await service.read(shared.id)
        // Edits publish through this same cache entry point; a foreign goal must never join the personal index.
        await service.remember(GoalDocument(file: shared.file, versionId: "edited", goal: try Goal.create(name: "Edited shared", description: "Preserve isolation")))
        #expect(await service.cached()?.goals.map(\.goal.name) == ["Personal"])
    }

    @Test func deniedChannelsAreSkippedAndPartialOutagesRemainVisible() async throws {
        #expect(try await fixture(denied: true).loadWorkspace().goals.map(\.goal.name) == ["Personal"])
        let partial = try await fixture(outage: true).loadWorkspace()
        #expect(partial.goals.map(\.goal.name) == ["Personal"])
        #expect(partial.warnings.count == 1)
        await #expect(throws: TowerError.self) { try await fixture(allOutage: true).loadWorkspace() }
        await #expect(throws: TowerError.self) { try await fixture(rootOutage: true).loadWorkspace() }
        await #expect(throws: TowerError.self) { try await fixture(bodyOutage: true).loadWorkspace() }
    }

    @Test func partialWorkspaceFailureRetainsAccessibleGoals() async throws {
        // Real service seam: Home succeeds, then a second channel's File list returns 503.
        let service = try await fixture(outage: true)
        #expect(try await service.load().goals.map(\.goal.name) == ["Personal"])
        let started = ContinuousClock.now
        do {
            let snapshot = try await service.loadWorkspace()
            #expect(snapshot.goals.map(\.goal.name) == ["Personal"])
            #expect(snapshot.warnings.count == 1)
        } catch {
            print("WORKSPACE_GOALS_REPRO Home=Personal loadWorkspace=\(error) elapsed=\(started.duration(to: .now))")
            throw error
        }
    }

    @Test func relationalAuthorityIsChannelScopedAcrossWorkspaceDiscovery() async throws {
        let identity = try await makeIdentity(), sql = try GoalsRelationalTests.Fixture()
        let legacy = try await fixture()
        let transport = StubTransport { request in
            if request.url!.path.contains("/native-v1/") {
                let body = try JSONValue.parse(request.httpBody!)
                if body["channel_id"] == .string(Fixtures.channel2) {
                    return (200, ["version": 1, "authority": NSNull()])
                }
                return try sql.handle(request)
            }
            // Same discovery and legacy File responses; SQL personal + legacy shared.
            return try (legacy.api.client.transport as! StubTransport).handlerResult(request)
        }
        var service = GoalsService(api: TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity)), workspaceId: legacy.workspaceId, appNpub: legacy.appNpub, viewer: TestKeys.npub, identity: identity)
        service.workspaceOwner = TestKeys.npub
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = WorkspaceRecord(id: service.workspaceId, appNpub: service.appNpub, label: "Goals", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        service.cache = LocalContentSnapshot(store: try LocalStore(directory: directory), identity: identity, boundary: try WorkspaceBoundary(connection: connection, workspace: workspace))
        #expect(try await service.load().goals.first?.storage == .relational)
        let all = try await service.loadWorkspace()
        #expect(Set(all.goals.map(\.goal.name)) == ["Canonical purpose", "Shared"])
        #expect(await service.cached()?.goals.map(\.goal.name) == ["Canonical purpose"])
    }

    @Test func workspaceCacheSurvivesReopenButNotRevocationLockOrBoundaryChange() async throws {
        var service = try await fixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = WorkspaceRecord(id: service.workspaceId, appNpub: service.appNpub, label: "Goals", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        service.cache = LocalContentSnapshot(store: try LocalStore(directory: directory), identity: service.identity, boundary: boundary)
        _ = try await service.load()
        _ = try await service.loadWorkspace()
        // Reopen the durable database, rather than relying on retained UI state.
        let reopened = try LocalStore(directory: directory)
        service.cache = LocalContentSnapshot(store: reopened, identity: service.identity, boundary: boundary)
        #expect(Set(await service.cachedWorkspace()?.goals.map(\.goal.name) ?? []) == ["Personal", "Shared"])
        #expect(await service.cached()?.goals.map(\.goal.name) == ["Personal"])
        try await reopened.writer.invalidateLocalContent(workspace: service.workspaceId, record: Fixtures.channel2)
        #expect(await service.cachedWorkspace()?.goals.map(\.goal.name) == ["Personal"])
        await service.identity.lock()
        #expect(await service.cachedWorkspace() == nil)
        try await service.identity.unlock(pin: TestKeys.pin)
        var other = service
        let otherWorkspace = WorkspaceRecord(id: Fixtures.workspaceId2, appNpub: service.appNpub, label: "Other", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        other.cache = LocalContentSnapshot(store: reopened, identity: service.identity, boundary: try WorkspaceBoundary(connection: connection, workspace: otherWorkspace))
        #expect(await other.cachedWorkspace() == nil)
    }

    @Test func deniedDiscoveryInvalidatesCachedDependenciesAndCanRepeatWithoutCancellation() async throws {
        for status in [403, 404, 410] {
            var service = try await fixture()
            let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
            let workspace = WorkspaceRecord(id: service.workspaceId, appNpub: service.appNpub, label: "Goals", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
            let store = try LocalStore(directory: temporaryDirectory())
            service.cache = LocalContentSnapshot(store: store, identity: service.identity, boundary: try WorkspaceBoundary(connection: connection, workspace: workspace))
            _ = try await service.load(); _ = try await service.loadWorkspace()
            var denied = try await fixture(denied: true, deniedStatus: status)
            denied.cache = service.cache
            for _ in 0..<2 {
                #expect(try await denied.loadWorkspace().goals.map(\.goal.name) == ["Personal"])
                #expect(await service.cachedWorkspace()?.goals.map(\.goal.name) == ["Personal"])
            }
            #expect(await service.cached()?.goals.map(\.goal.name) == ["Personal"])
            try await store.writer.invalidateLocalContent(workspace: service.workspaceId, record: Fixtures.scopeA)
            #expect(await service.cachedWorkspace()?.goals.isEmpty == true)
        }
    }

    private func fixture(denied: Bool = false, outage: Bool = false, allOutage: Bool = false, rootOutage: Bool = false, deniedStatus: Int = 403, bodyOutage: Bool = false) async throws -> GoalsService {
        let identity = try await makeIdentity()
        let workspace = GoalWireTests.workspace, scope = Fixtures.scopeA, channel = GoalWireTests.channel
        let sharedChannel = Fixtures.channel2
        let ids = [GoalWireTests.file, "cccccccc-0000-4000-8000-000000000099"]
        let transport = StubTransport { request in
            let path = request.url!.path
            let base = "/api/v4/flightdeck-pg/workspaces/" + workspace
            if path == base + "/scopes", rootOutage { return (503, ["code": "unavailable"]) }
            if path == base + "/scopes" { return (200, ["scopes": [Fixtures.scope(scope, workspace: workspace, name: "Home")]]) }
            if path == base + "/scopes/" + scope + "/channels" {
                var own = Fixtures.channel(channel, scope: scope, workspace: workspace, name: "Goals")
                own["metadata"] = GoalsSpace.metadata(owner: TestKeys.npub)
                return (200, ["channels": [own, Fixtures.channel(sharedChannel, scope: scope, workspace: workspace, name: "Shared")]])
            }
            if path == base + "/members" { return (200, ["members": [Fixtures.member(TestKeys.npub, name: "Owner")]]) }
            if path.hasSuffix("/grants") { return (200, ["grants": [["principal": ["npub": TestKeys.npub], "access_level": "manage"]]]) }
            for (index, channelId) in [channel, sharedChannel].enumerated() {
                let goal = try Goal.create(name: index == 0 ? "Personal" : "Shared", description: "Existing goal")
                var row = GoalWireTests.Tower(goal).fileRow()
                row["id"] = ids[index]; row["channel_id"] = channelId
                row["current_version"] = ["id": GoalWireTests.head, "sha256_hex": SHA256Hex.of(goal.encode()), "size_bytes": goal.encode().count]
                if path == base + "/channels/" + channelId + "/files" {
                    if index == 1 && denied { return (deniedStatus, ["code": "forbidden"]) }
                    if allOutage || index == 1 && outage { return (503, ["code": "unavailable"]) }
                    return (200, ["files": [row], "next_cursor": NSNull()])
                }
                if path == base + "/files/" + ids[index] { return (200, ["file": row]) }
                if path == base + "/files/" + ids[index] + "/versions/" + GoalWireTests.head + "/object" {
                    if bodyOutage { return (503, ["code": "unavailable"]) }
                    return (200, goal.encode())
                }
            }
            return (404, ["code": "not_found"])
        }
        return GoalsService(api: TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity)), workspaceId: workspace, appNpub: Fixtures.appNpub, viewer: TestKeys.npub, identity: identity)
    }
}
