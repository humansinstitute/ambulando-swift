import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct GoalsRelationalTests {
    static let workspace = GoalWireTests.workspace, channel = GoalWireTests.channel, id = GoalWireTests.file

    static func value() throws -> Goal {
        var value = try Goal.create(name: "Canonical purpose", description: "Keep the full plan")
        value.checkpoints = [GoalCheckpoint(id: "string_1", title: "First", extra: .object([("future_cp", .bool(true))])), GoalCheckpoint(id: "a-b", title: "Second", reached: true)]
        value.links = [GoalLink(type: .chat, recordId: Fixtures.scopeA, channelId: channel, extra: .object([("future_link", .int(9))]))]
        value.pinnedRefs = [GoalLink(type: .doc, recordId: Fixtures.scopeB)]
        value.defaultChannelId = channel
        value.extra = .object([("future", .object([("retained", .bool(true)), ("large", .number("9007199254740993")), ("decimal", .number("0.123456789012345678901"))])), ("focus_rank", .string("a1"))])
        return value
    }

    @Test func normalizedFactsRoundtripAndRetainReferenceIdentity() throws {
        let value = try Self.value()
        let rows = GoalsRelationalRepository.rows(goal: value, id: Self.id, workspace: Self.workspace, channel: Self.channel, owner: TestKeys.npub,
            revision: 7, createdAt: .string("2026-11-27"), timestamp: "2026-11-27", actor: TestKeys.npub)
        let documents = try GoalsRelationalRows(goals: rows["goals"]!, checkpoints: rows["goal_checkpoints"]!.reversed(), associations: rows["goal_associations"]!)
            .documents(workspaceId: Self.workspace, channelId: Self.channel, owner: TestKeys.npub)
        #expect(documents.count == 1)
        #expect(documents[0].id == Self.id && documents[0].versionId == "7" && documents[0].storage == .relational)
        #expect(documents[0].goal == value)
        #expect(documents[0].file.storageObjectId == nil)
        #expect(GoalMentions.suggestions(documents, query: MentionQuery("goal:")).first?.mention.npub == Self.id)
        #expect(documents[0].goal.links.first?.recordId == Fixtures.scopeA) // Thread UUID, never channel#root.
    }

    @Test func independentSharedMapperFixturePreservesDatesOrderPinsAndExactNumbers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/goals-relational")
        let fixture = try JSONValue.parse(Data(contentsOf: root.appendingPathComponent("current-rows-v1.json")))
        let source = try Goal.parse(Data(contentsOf: root.appendingPathComponent("current-goal-v1.json")))
        let tables = fixture["tables"]!
        let id = "11111111-1111-4111-8111-111111111111"
        let document = try #require(GoalsRelationalRows(goals: tables["goals"]!.arrayValue!, checkpoints: tables["goal_checkpoints"]!.arrayValue!, associations: tables["goal_associations"]!.arrayValue!)
            .documents(workspaceId: id, channelId: id, owner: "npub1fixture").first)
        #expect(document.id == id && document.versionId == "7" && document.storage == .relational)
        #expect(document.goal.name == source.name && document.goal.startDate == source.startDate && document.goal.targetDate == source.targetDate)
        #expect(document.goal.checkpoints == source.checkpoints && document.goal.links == source.links && document.goal.pinnedRefs == source.pinnedRefs)
        #expect(document.goal.defaultChannelId == source.defaultChannelId && GoalFocus.rank(document.goal) == GoalFocus.rank(source))
        #expect(document.goal.extra["future"]?["integer"] == .number("9007199254740993"))
        #expect(document.goal.extra["future"]?["decimal"] == .number("0.123456789012345678901"))
    }

    @Test func malformedAndForeignChildrenFailClosed() throws {
        let original = GoalsRelationalRepository.rows(goal: try Self.value(), id: Self.id, workspace: Self.workspace, channel: Self.channel, owner: TestKeys.npub,
            revision: 7, createdAt: .string(""), timestamp: "", actor: TestKeys.npub)
        for field in ["workspace_id", "channel_id", "owner_npub", "goal_id", "position", "revision"] {
            var rows = original
            rows["goal_checkpoints"]![0] = rows["goal_checkpoints"]![0].setting(field, .string("foreign"))
            #expect(throws: (any Error).self) {
                try GoalsRelationalRows(goals: rows["goals"]!, checkpoints: rows["goal_checkpoints"]!, associations: rows["goal_associations"]!)
                    .documents(workspaceId: Self.workspace, channelId: Self.channel, owner: TestKeys.npub)
            }
        }
    }

    @Test func nativeReadCreateEditConflictAndRetryNeverWriteFiles() async throws {
        let fixture = try Fixture(), identity = try await makeIdentity()
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { try fixture.handle($0) }, signer: identity))
        let repository = Self.repository(api)
        let before = try #require(try await repository.snapshot())
        #expect(try before.documents(workspaceId: Self.workspace, channelId: Self.channel, owner: TestKeys.npub).first?.goal == (try Self.value()))
        let next = try GoalEdit.setReached(id: "string_1", expected: false, reached: true).apply(to: Self.value())
        fixture.loseResponse()
        let saved = try await repository.save(goal: next, id: Self.id, before: before, actor: TestKeys.npub)
        #expect(saved.goal == next && saved.versionId == "2")
        #expect(fixture.batchAttempts == 2 && fixture.commits == 1)
        await #expect(throws: GoalError.self) { try await repository.save(goal: next, id: Self.id, before: before, actor: TestKeys.npub) }
        let fresh = try #require(try await repository.snapshot())
        let created = try await repository.save(goal: Goal.create(name: "New SQL goal", description: "No File body"), id: Fixtures.scopeB, before: fresh, actor: TestKeys.npub)
        #expect(created.id == Fixtures.scopeB && created.storage == .relational && created.versionId == "1")
        #expect(fixture.fileWrites == 0)
        #expect(fixture.tables["goal_history"]?.count == 2)
        #expect(fixture.tables["goal_checkpoint_history"]?.count == 2)
    }

    @Test func generationMismatchAndRepeatedPageNeverPublishPartialRows() async throws {
        let fixture = try Fixture(), identity = try await makeIdentity()
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { try fixture.handle($0) }, signer: identity))
        fixture.changeGenerationOnce()
        #expect(try await Self.repository(api).snapshot() != nil)
        await #expect(throws: (any Error).self) {
            try await GoalsRelationalSnapshot.load(query: { _, _, _ in
                .object([("version", .int(1)), ("generation", .string("1")), ("rows", .array([.object([("id", .string("a"))])])),
                    ("has_more", .bool(true)), ("next_after", .string("a"))])
            })
        }
    }

    @Test func stagingWithoutFenceUsesLegacyAndFencedStagingPauses() async throws {
        let identity = try await makeIdentity()
        for fenced in [false, true] {
            let transport = StubTransport { _ in
                (200, JSONValue.object([("version", .int(1)), ("authority", .object([("mode", .string("staging"))])),
                    ("fence", .object([("active", .bool(fenced))]))]).serialized())
            }
            let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
            if fenced { await #expect(throws: GoalSaveFailed.self) { try await Self.repository(api).snapshot() } }
            else { #expect(try await Self.repository(api).snapshot() == nil) }
            #expect(transport.recorded.allSatisfy { $0.url!.path.hasSuffix("/status") })
        }
    }

    @Test func uuidOnlyRelationalReferenceNeedsNoFileAndDenialStays403() async throws {
        let fixture = try Fixture(), identity = try await makeIdentity()
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { try fixture.handle($0) }, signer: identity))
        var service = GoalsService(api: api, workspaceId: Self.workspace, appNpub: Fixtures.appNpub, viewer: TestKeys.npub, identity: identity)
        service.workspaceOwner = TestKeys.npub
        #expect(try await service.resolveReference(Self.id).goal == (try Self.value()))
        let denied = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { _ in (403, ["code": "permission_denied"]) }, signer: identity))
        await #expect(throws: TowerError.http(status: 403, code: "permission_denied", stage: nil)) {
            try await GoalsRelationalRepository.resolve(api: denied, workspaceId: Self.workspace, workspaceOwner: TestKeys.npub, appNpub: Fixtures.appNpub, id: Self.id)
        }
    }

    @Test func missingActiveRowNeverReadsRetainedFileBytes() async throws {
        let fixture = try Fixture(), identity = try await makeIdentity()
        let legacy = GoalWireTests.Tower(try Self.value())
        let transport = StubTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/read") { return (404, ["code": "row_not_found"]) }
            if path.hasSuffix("/files/" + Self.id) { return (200, ["file": legacy.fileRow()]) }
            return try fixture.handle(request)
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
        var service = GoalsService(api: api, workspaceId: Self.workspace, appNpub: Fixtures.appNpub, viewer: TestKeys.npub, identity: identity)
        service.workspaceOwner = TestKeys.npub
        await #expect(throws: (any Error).self) { try await service.resolveReference(Self.id) }
        #expect(!transport.recorded.contains { $0.url!.path.hasSuffix("/object") })
    }

    @Test func sealedSnapshotRelaunchOfflineAndAuthorityStampPreventLegacyFallback() async throws {
        let fixture = try Fixture(), identity = try await makeIdentity(), dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = WorkspaceRecord(id: Self.workspace, appNpub: Fixtures.appNpub, label: "Goals", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        func service(_ transport: any HTTPTransport) throws -> GoalsService {
            try WorkspaceSync(store: LocalStore(directory: dir), engine: SyncEngine(), identity: identity, transport: transport).goals(connection, workspace)
        }
        let live = try service(StubTransport { try fixture.handle($0) })
        let loaded = try await live.load()
        #expect(loaded.goals.first?.storage == .relational)
        let canonical = try #require(loaded.goals.first)
        var old = canonical.goal; old.name = "Delayed legacy content"
        await live.remember(GoalsSnapshot(space: loaded.space, goals: [GoalDocument(file: canonical.file, versionId: UUID().uuidString.lowercased(), goal: old)], unreadable: []))
        #expect(await live.cached()?.goals.first?.goal.name == canonical.goal.name)
        let offline = try service(StubTransport { _ in throw URLError(.notConnectedToInternet) })
        #expect(await offline.cached()?.goals.first?.goal == (try Self.value()))
        await #expect(throws: (any Error).self) { try await offline.edit(Self.id, [.setReached(id: "string_1", expected: false, reached: true)]) }
        #expect(await offline.cached()?.goals.first?.versionId == "1")
        let vanished = try service(StubTransport { request in
            if request.url!.path.contains("/native-v1/") { return (404, ["code": "namespace_not_available"]) }
            return try fixture.handle(request)
        })
        await #expect(throws: (any Error).self) { try await vanished.load() }
        #expect(await vanished.cached()?.goals.count == 1)
        #expect(fixture.fileWrites == 0)
        fixture.freeze()
        await #expect(throws: (any Error).self) { try await live.create(Goal.create(name: "Blocked", description: "Frozen"), channelId: Self.channel) }
        #expect(await live.cached()?.goals.count == 1)
        let revoked = try service(StubTransport { request in
            if request.url!.path.contains("/native-v1/") { return (403, ["code": "permission_denied"]) }
            return try fixture.handle(request)
        })
        await #expect(throws: (any Error).self) { try await revoked.load() }
        #expect(await revoked.cached() == nil)
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        let cache = LocalContentSnapshot(store: try LocalStore(directory: dir), identity: identity, boundary: boundary)
        try await cache.store.writer.invalidateLocalContent(workspace: workspace.id, record: Self.channel)
        #expect(await live.cached() == nil)
    }

    static func repository(_ api: TowerAPI) -> GoalsRelationalRepository {
        GoalsRelationalRepository(api: api, workspaceId: workspace, workspaceOwner: TestKeys.npub, appNpub: Fixtures.appNpub, channelId: channel, owner: TestKeys.npub)
    }

    @Test func committedCreateLostAcrossRelaunchRecoversExactRequestOnce() async throws {
        let fixture = try Fixture(), identity = try await makeIdentity(), dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: StubTransport { try fixture.handle($0) }, signer: identity))
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = WorkspaceRecord(id: Self.workspace, appNpub: Fixtures.appNpub, label: "Goals", slug: nil, towerBaseURL: nil, role: "owner", ownerNpub: TestKeys.npub, raw: Data())
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        var first = Self.repository(api)
        first.cache = LocalContentSnapshot(store: try LocalStore(directory: dir), identity: identity, boundary: boundary)
        let before = try #require(try await first.snapshot())
        fixture.dropResponses(2)
        await #expect(throws: (any Error).self) {
            try await first.save(goal: Goal.create(name: "Created once", description: "Keep this draft"), id: Fixtures.scopeB, before: before, actor: TestKeys.npub)
        }
        #expect(fixture.commits == 1)
        var reopened = Self.repository(api)
        reopened.cache = LocalContentSnapshot(store: try LocalStore(directory: dir), identity: identity, boundary: boundary)
        let retry = try await reopened.save(goal: Goal.create(name: "Created once", description: "Keep this draft"), id: Fixtures.scopeA, before: before, actor: TestKeys.npub)
        #expect(retry.id == Fixtures.scopeB)
        #expect(try await !reopened.recoverPending())
        let recovered = try #require(try await reopened.snapshot())
        #expect(try recovered.documents(workspaceId: Self.workspace, channelId: Self.channel, owner: TestKeys.npub).filter { $0.id == Fixtures.scopeB }.count == 1)
        #expect(fixture.commits == 1 && fixture.tables["goal_history"]?.count == 1)
    }

    final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        var tables: [String: [JSONValue]]
        var generation = 1, batchAttempts = 0, commits = 0, fileWrites = 0
        private var receipts: [String: JSONValue] = [:]
        private var lose = false, change = false, frozen = false, drops = 0
        init() throws {
            tables = GoalsRelationalRepository.rows(goal: try GoalsRelationalTests.value(), id: id, workspace: workspace, channel: channel, owner: TestKeys.npub,
                revision: 1, createdAt: .string("2026-11-27"), timestamp: "2026-11-27", actor: TestKeys.npub)
            tables["goals_authority"] = [.object([("id", .string(channel)), ("workspace_id", .string(workspace)), ("channel_id", .string(channel)), ("owner_npub", .string(TestKeys.npub)),
                ("revision", .int(1)), ("mode", .string("relational")), ("epoch", .int(1)), ("contract_version", .int(1)), ("schema_version", .string("ambulando-goals-relational-1"))])]
        }
        func loseResponse() { lock.withLock { lose = true } }
        func dropResponses(_ count: Int) { lock.withLock { drops = count } }
        func changeGenerationOnce() { lock.withLock { change = true } }
        func freeze() { lock.withLock { frozen = true } }
        func handle(_ request: URLRequest) throws -> (Int, Any) {
            try lock.withLock {
                let path = request.url!.path
                if path.contains("/native-v1/") {
                    #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") != nil)
                    let body = try JSONValue.parse(request.httpBody!)
                    if path.hasSuffix("/read") {
                        guard let row = tables["goals"]?.first(where: { $0["id"] == body["id"] }) else { return (404, ["code": "row_not_found"]) }
                        return (200, JSONValue.object([("version", .int(1)), ("generation", .string(String(generation))), ("channel_id", .string(channel)), ("row", row)]).serialized())
                    }
                    if path.hasSuffix("/status") { return (200, JSONValue.object([("version", .int(1)), ("authority", .object([("mode", .string(frozen ? "frozen" : "active")), ("revision", .string("1")), ("content_type", .string(Goal.mime))]))]).serialized()) }
                    if path.hasSuffix("/query") {
                        if change && body["table"] == .string("goal_checkpoints") { change = false; generation += 1 }
                        if let requested = body["generation"]?.stringValue, requested != String(generation) { return (409, ["code": "snapshot_changed"]) }
                        let table = body["table"]!.stringValue!
                        let rows = (tables[table] ?? []).sorted { $0["id"]!.stringValue! < $1["id"]!.stringValue! }
                        return (200, JSONValue.object([("version", .int(1)), ("generation", .string(String(generation))), ("rows", .array(rows)), ("has_more", .bool(false)), ("next_after", .null)]).serialized())
                    }
                    if path.hasSuffix("/batch") {
                        batchAttempts += 1
                        let operation = body["operation_id"]!.stringValue!
                        if let receipt = receipts[operation] {
                            if drops > 0 { drops -= 1; throw URLError(.networkConnectionLost) }
                            return (200, receipt.serialized())
                        }
                        var next = tables, results: [JSONValue] = []
                        for op in body["operations"]!.arrayValue! {
                            let table = op["table"]!.stringValue!, rowId = op["id"]!.stringValue!, kind = op["kind"]!.stringValue!
                            var rows = next[table] ?? []
                            let prior = rows.first { $0["id"] == .string(rowId) }
                            let revision = prior?["revision"]?.intValue ?? 0
                            if kind == "insert" ? prior != nil : revision != op["expected_revision"]?.intValue { return (409, ["code": "row_conflict"]) }
                            var row = prior ?? .object([])
                            for (key, value) in op["data"]?.objectValue ?? [] { row = row.setting(key, value) }
                            row = row.setting("id", .string(rowId)).setting("workspace_id", .string(workspace)).setting("channel_id", .string(channel)).setting("revision", .int(revision + 1))
                            rows.removeAll { $0["id"] == .string(rowId) }
                            if kind != "delete" { rows.append(row) }
                            next[table] = rows
                            results.append(.object([("table", .string(table)), ("kind", .string(kind)), ("row", row)]))
                        }
                        tables = next; generation += 1; commits += 1
                        let result = JSONValue.object([("version", .int(1)), ("operation_id", .string(operation)), ("generation", .string(String(generation))), ("results", .array(results))])
                        receipts[operation] = result
                        if drops > 0 { drops -= 1; throw URLError(.networkConnectionLost) }
                        if lose { lose = false; throw URLError(.networkConnectionLost) }
                        return (200, result.serialized())
                    }
                }
                if request.httpMethod == "POST" { fileWrites += 1 }
                if path.hasSuffix("/scopes") { return (200, ["scopes": [Fixtures.scope(Fixtures.scopeA, workspace: workspace, name: "Home")]]) }
                if path.hasSuffix("/channels") {
                    var row = Fixtures.channel(channel, scope: Fixtures.scopeA, workspace: workspace, name: "Goals")
                    row["metadata"] = GoalsSpace.metadata(owner: TestKeys.npub)
                    return (200, ["channels": [row]])
                }
                if path.hasSuffix("/members") { return (200, ["members": [Fixtures.member(TestKeys.npub, name: "Owner")]]) }
                if path.hasSuffix("/grants") { return (200, ["grants": [["principal": ["npub": TestKeys.npub], "access_level": "manage"]]]) }
                return (404, ["code": "unexpected_route"])
            }
        }
    }
}
