import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct CachedNappletTests {
    @Test func cachedCodeAndDataSurviveReopenAndSaveUsesDisplayedVersion() async throws {
        let (fixture, _) = try await GenericNappletTransportTests().fixture()
        let identity = try await makeIdentity()
        let directory = temporaryDirectory()
        let store = try LocalStore(directory: directory)
        let c = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let w = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(Fixtures.workspaceId, label: "Cache")))
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: NappletFixtureTransport(fixture: fixture))
        let code = try await sync.genericNappletCode(c, w, fileId: fixture.codeId)
        let initial = try await sync.readGenericJSON(c, w, fileId: fixture.codeId, code: code)
        let reopened = WorkspaceSync(store: try LocalStore(directory: directory), engine: SyncEngine(), identity: identity, transport: StubTransport { _ in throw URLError(.notConnectedToInternet) })
        let cached = try #require(await reopened.cachedGenericNapplet(c, w, fileId: fixture.codeId))
        #expect(cached.code == code && cached.data.bytes == initial.bytes && cached.data.versionId == initial.versionId)
        let saved = try await sync.saveGenericJSON(c, w, fileId: fixture.codeId, code: cached.code, base: cached.data.versionId, bytes: Data("{\"cachedEdit\":true}".utf8))
        #expect(saved.versionId != initial.versionId)
        #expect(await reopened.cachedGenericNapplet(c, w, fileId: fixture.codeId)?.data.bytes == saved.bytes)
        // An old displayed base still conflicts; the cache cannot authorize an overwrite.
        await #expect(throws: FileNappletError.conflict) {
            try await sync.saveGenericJSON(c, w, fileId: fixture.codeId, code: cached.code, base: cached.data.versionId, bytes: Data("{}".utf8))
        }
        _ = try await store.writer.applyTombstones(workspaceId: w.id, [.file(fixture.dataId)])
        #expect(await reopened.cachedGenericNapplet(c, w, fileId: fixture.codeId) == nil)
        _ = try await sync.readGenericJSON(c, w, fileId: fixture.codeId, code: code)
        try await store.writer.invalidateLocalContent(workspace: w.id, record: fixture.channelId)
        #expect(await reopened.cachedGenericNapplet(c, w, fileId: fixture.codeId) == nil)
    }
    @Test func legacyTrackerRestoresDeliveredBaseAndChannelRemovalClearsOnlyItsSnapshot() async throws {
        let fixture = FileNappletFixture(), identity = try await makeIdentity()
        let store = try LocalStore(directory: temporaryDirectory())
        let c = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let w = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(Fixtures.workspaceId, label: "Cache")))
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: NappletFixtureTransport(fixture: fixture))
        let code = try await sync.fileNappletCode(c, w, fileId: fixture.codeId)
        let data = try await sync.readFileNapplet(c, w, fileId: fixture.codeId, code: code)
        let cached = try #require(await sync.cachedFileNapplet(c, w, fileId: fixture.codeId))
        #expect(cached.code == code && cached.data.versionId == data.versionId && cached.data.bytes == data.bytes)
        let saved = try await sync.saveFileNapplet(c, w, fileId: fixture.codeId, code: cached.code, base: cached.data.versionId, bytes: cached.data.bytes)
        #expect(saved.versionId != data.versionId)
        try await store.writer.invalidateLocalContent(workspace: w.id, record: fixture.channelId)
        #expect(await sync.cachedFileNapplet(c, w, fileId: fixture.codeId) == nil)
    }
    @Test func perGoalRemovalKeepsOtherGoalsAndFullFormat() async throws {
        let identity = try await makeIdentity(), store = try LocalStore(directory: temporaryDirectory())
        let c = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let w = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(Fixtures.workspaceId, label: "Cache")))
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: StubTransport { _ in throw URLError(.notConnectedToInternet) })
        let service = try sync.goals(c, w)
        var channelRow = Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "Goals")
        channelRow["kind"] = "channel"; channelRow["metadata"] = GoalsSpace.metadata(owner: TestKeys.npub)
        let channel = try ChannelRecord(raw: rawJSON(channelRow))
        var docs: [GoalDocument] = []
        for index in 0..<2 {
            let goal = try Goal.create(name: "Cached \(index)", description: "Durable", startDate: "2026-11-01", targetDate: "2026-12-01")
            let row: [String: Any] = ["id": UUID().uuidString.lowercased(), "workspace_id": w.id, "channel_id": channel.id, "display_name": "goal.json", "content_type": Goal.mime, "row_version": 1]
            docs.append(GoalDocument(file: try FileRecord(raw: rawJSON(row)), versionId: UUID().uuidString.lowercased(), goal: goal))
        }
        await service.remember(GoalsSnapshot(space: .ready(channel: channel, agents: []), goals: docs, unreadable: []))
        #expect(await service.cached()?.goals == docs.sorted(by: GoalsService.order))
        try await store.writer.invalidateLocalContent(workspace: w.id, record: docs[0].id)
        #expect(await service.cached()?.goals.map(\.id) == [docs[1].id])
        try await store.writer.invalidateLocalContent(workspace: w.id, record: channel.id)
        #expect(await service.cached() == nil)
    }
}
