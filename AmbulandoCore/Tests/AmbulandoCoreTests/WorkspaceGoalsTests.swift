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

    @Test func deniedChannelsAreSkippedButOutagesFailInsteadOfEmptySuccess() async throws {
        #expect(try await fixture(denied: true).loadWorkspace().goals.map(\.goal.name) == ["Personal"])
        await #expect(throws: TowerError.self) { try await fixture(outage: true).loadWorkspace() }
    }

    private func fixture(denied: Bool = false, outage: Bool = false) async throws -> GoalsService {
        let identity = try await makeIdentity()
        let workspace = GoalWireTests.workspace, scope = Fixtures.scopeA, channel = GoalWireTests.channel
        let sharedChannel = Fixtures.channel2
        let ids = [GoalWireTests.file, "cccccccc-0000-4000-8000-000000000099"]
        let transport = StubTransport { request in
            let path = request.url!.path
            let base = "/api/v4/flightdeck-pg/workspaces/" + workspace
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
                    if index == 1 && denied { return (403, ["code": "forbidden"]) }
                    if index == 1 && outage { return (503, ["code": "unavailable"]) }
                    return (200, ["files": [row], "next_cursor": NSNull()])
                }
                if path == base + "/files/" + ids[index] { return (200, ["file": row]) }
                if path == base + "/files/" + ids[index] + "/versions/" + GoalWireTests.head + "/object" { return (200, goal.encode()) }
            }
            return (404, ["code": "not_found"])
        }
        return GoalsService(api: TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity)), workspaceId: workspace, appNpub: Fixtures.appNpub, viewer: TestKeys.npub, identity: identity)
    }
}
