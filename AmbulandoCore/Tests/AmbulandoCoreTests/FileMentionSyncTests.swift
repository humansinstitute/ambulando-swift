import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct FileMentionSyncTests {
    @Test func discoveryFetchesEveryPageAndRefusesForeignRows() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(directory: directory), identity = try await makeIdentity()
        let workspace = WorkspaceRecord(id: Fixtures.workspaceId, appNpub: Fixtures.appNpub, label: "Studio", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        try await store.writer.upsertChannels(workspaceId: workspace.id, scopeId: Fixtures.scopeA,
            [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "General")))], complete: false)
        func transport(foreign: Bool) -> StubTransport {
            StubTransport { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
                let second = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" && $0.value == "next" } == true
                let row: [String: Any] = ["id": second ? "cccccccc-0000-4000-8000-000000000002" : "cccccccc-0000-4000-8000-000000000001",
                    "workspace_id": foreign ? "foreign" : Fixtures.workspaceId, "channel_id": Fixtures.channel1,
                    "display_name": second ? "Ambulando Scratch" : "First page", "row_version": 1, "updated_at": "2026-11-28"]
                return (200, ["files": [row], "next_cursor": second ? NSNull() : "next" as Any])
            }
        }
        let sync = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: transport(foreign: false))
        try await sync.refreshMentionFiles(connection, workspace, channelId: Fixtures.channel1)
        let rows = try await store.reader.mentionSuggestions(workspaceId: workspace.id, query: MentionQuery("Scratch"))
        #expect(rows.first?.mention.id == "cccccccc-0000-4000-8000-000000000002")
        let unsafe = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity, transport: transport(foreign: true))
        await #expect(throws: TowerError.self) { try await unsafe.refreshMentionFiles(connection, workspace, channelId: Fixtures.channel1) }
        #expect(try await store.reader.files(workspaceId: workspace.id).count == 2)
        let denied = WorkspaceSync(store: store, engine: SyncEngine(), identity: identity,
            transport: StubTransport { _ in (403, ["code": "forbidden"]) })
        await #expect(throws: TowerError.self) { try await denied.refreshMentionFiles(connection, workspace, channelId: Fixtures.channel1) }
        #expect(try await store.reader.files(workspaceId: workspace.id).isEmpty)
    }
}
