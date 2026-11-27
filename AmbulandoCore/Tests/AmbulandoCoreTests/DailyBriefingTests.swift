import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct DailyBriefingTests {
    let workspace = "11111111-1111-4111-8111-111111111111"
    let owner = TestKeys.npub
    let author = NostrKeys.npub(publicKeyHex: String(repeating: "11", count: 32))!
    let humanId = "22222222-2222-4222-8222-222222222222"
    let agentId = "33333333-3333-4333-8333-333333333333"
    let now = DailyBriefing.timestamp("2026-11-27T01:00:00Z")!
    var entry: [String: Any] { ["generated_at": "2026-11-26T21:30:00Z", "paragraphs": ["Saved analysis, not current goal facts."], "links": []] }
    func journal(_ entry: [String: Any]? = nil, day: String = "2026-11-27") -> [String: Any] {
        ["schema": "ambulando.briefing", "schema_version": 1, "workspace_id": workspace, "owner_npub": owner,
         "author_npub": author, "timezone": "Australia/Perth", "entries": [day: entry ?? self.entry]]
    }
    func parse(_ object: [String: Any], owner: String? = nil) throws -> DailyBriefing {
        try DailyBriefing.parse(rawJSON(object), workspace: workspace, owner: owner ?? self.owner, author: author, now: now)
    }
    @Test func exactSchemaRetainsSavedHistoryAndAllowsUnknownFields() throws {
        var o = journal(); o["future_extension"] = ["opaque": true]
        let parsed = try parse(o)
        #expect(parsed.entries["2026-11-27"]?.paragraphs == ["Saved analysis, not current goal facts."])
        #expect(parsed.entries["2026-11-26"] == nil)
        #expect(throws: BriefingError.self) { try parse(o, owner: author) }
        o["timezone"] = "UTC"
        #expect(throws: BriefingError.self) { try parse(o) }
    }
    @Test func perthMidnightAndRealCalendarDates() throws {
        #expect(DailyBriefing.day(DailyBriefing.timestamp("2026-11-26T15:59:59Z")!) == "2026-11-26")
        #expect(DailyBriefing.day(DailyBriefing.timestamp("2026-11-26T16:00:00Z")!) == "2026-11-27")
        for day in ["2026-02-29", "2026-04-31", "2026-1-01", "2026-11-27\n", "0000-01-01"] { #expect(!DailyBriefing.validDay(day)) }
        #expect(DailyBriefing.validDay("2024-02-29"))
        #expect(throws: BriefingError.self) { try parse(journal(day: "2026-11-26")) }
        var e = entry; e["generated_at"] = "2026-11-28T05:30:00+08:00"
        #expect(throws: BriefingError.self) { try parse(journal(e, day: "2026-11-28")) }
        e["generated_at"] = "2026-11-27T05:30:00"
        #expect(throws: BriefingError.self) { try parse(journal(e)) }
    }
    @Test func invalidContentIsNeverPartiallyShown() throws {
        for paragraphs in [[], [" "], ["one", "two", "three"], [String(repeating: "x", count: 4001)]] {
            var e = entry; e["paragraphs"] = paragraphs
            #expect(throws: BriefingError.self) { try parse(journal(e)) }
        }
        var e = entry; e["links"] = [["type": "thread", "record_id": humanId, "label": "Chat"]]
        #expect(throws: BriefingError.self) { try parse(journal(e)) }
        e["links"] = [["type": "thread", "record_id": humanId, "channel_id": agentId, "label": "Chat"]]
        #expect(try parse(journal(e)).entries["2026-11-27"]?.links.count == 1)
        e.removeValue(forKey: "links")
        #expect(throws: BriefingError.self) { try parse(journal(e)) }
    }
    var members: [MemberRecord] {
        [MemberRecord(workspaceId: workspace, actorId: humanId, npub: owner, kind: "agent", displayName: "Owner"),
         MemberRecord(workspaceId: workspace, actorId: agentId, npub: author, kind: "person", displayName: "Author")]
    }
    var grants: [GoalsChannelGrant] {
        [GoalsChannelGrant(actorId: humanId, npub: owner, isGroup: false, access: "manage"),
         GoalsChannelGrant(actorId: agentId, npub: author, isGroup: false, access: "contribute")]
    }
    @Test func onlyExplicitOwnerAndAuthorGrantsAreAccepted() throws {
        try BriefingAccess.verify(grants: grants, members: members, owner: owner, author: author)
        for bad in [Array(grants.prefix(1)), grants + [GoalsChannelGrant(actorId: nil, npub: nil, isGroup: true, access: "read")],
                    [grants[0], GoalsChannelGrant(actorId: agentId, npub: owner, isGroup: false, access: "contribute")],
                    [GoalsChannelGrant(actorId: humanId, npub: owner, isGroup: false, access: "read"), grants[1]]] {
            #expect(throws: BriefingError.unsafe) { try BriefingAccess.verify(grants: bad, members: members, owner: owner, author: author) }
        }
    }
}

@Suite struct BriefingTransportTests {
    @Test func canonicalAndroidFixtureParsesIdenticalBytes() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/fixtures/briefing/v1.json")
        let bytes = try Data(contentsOf: path), raw = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let journal = try DailyBriefing.parse(bytes, workspace: raw["workspace_id"] as! String, owner: raw["owner_npub"] as! String,
                                             author: raw["author_npub"] as! String, now: DailyBriefing.timestamp("2026-11-27T01:00:00Z")!)
        #expect(journal.entries["2026-11-27"]?.paragraphs.count == 2)
        #expect(journal.entries["2026-11-27"]?.coverageNote == "Synthetic coverage limitation.")
    }
    @Test func exactVersionReadVerifiesHashAndRejectsUnsafeDuplicateAndPartialSources() async throws {
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try await makeIdentity(directory: dir)
        let sample = SampleBriefingTower(workspace: Fixtures.workspaceId, scope: Fixtures.scopeA,
                                         author: NostrKeys.npub(publicKeyHex: String(repeating: "22", count: 32))!, app: Fixtures.appNpub)
        let transport = StubTransport { request in try sample.response(request, owner: TestKeys.npub, fallback: (200, [:])) }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
        let service = BriefingService(api: api, workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub)
        let snapshot = try await service.load()
        #expect(snapshot.journal.entries[DailyBriefing.day()]?.paragraphs.count == 2)
        #expect(snapshot.versionId == sample.version)
        #expect(!sample.paths.contains { $0.hasSuffix("/versions") || $0.contains("/messages") })
        #expect(transport.recorded.allSatisfy { $0.httpMethod == "GET" })
        sample.corrupt = true
        await #expect(throws: BriefingError.invalid) { try await service.load() }
        sample.corrupt = false; sample.publicObject = true
        await #expect(throws: BriefingError.unsafe) { try await service.load() }
        sample.publicObject = false; sample.unsafe = true
        await #expect(throws: BriefingError.unsafe) { try await service.load() }
        sample.unsafe = false; sample.duplicate = true
        await #expect(throws: BriefingError.ambiguous) { try await service.load() }
        sample.duplicate = false; sample.partial = true
        await #expect(throws: (any Error).self) { try await service.load() }
        sample.partial = false; sample.missingToday = true
        let missing = try await service.load()
        #expect(missing.journal.entries[DailyBriefing.day()] == nil)
        #expect(missing.journal.entries.count == 1)
    }
    @Test func encryptedBriefingCacheRestoresOnlyItsUnlockedBoundaryAndHonorsRemoval() async throws {
        let dir = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try await makeIdentity(directory: dir.appendingPathComponent("identity"))
        let store = try LocalStore(directory: dir.appendingPathComponent("store"))
        let connection = ConnectionRecord(origin: try TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: TestKeys.npub)
        let workspace = try WorkspaceRecord(raw: rawJSON(Fixtures.workspace(Fixtures.workspaceId, label: "Synthetic")))
        let boundary = try WorkspaceBoundary(connection: connection, workspace: workspace)
        let sample = SampleBriefingTower(workspace: Fixtures.workspaceId, scope: Fixtures.scopeA,
                                         author: NostrKeys.npub(publicKeyHex: String(repeating: "22", count: 32))!, app: Fixtures.appNpub)
        let transport = StubTransport { request in try sample.response(request, owner: TestKeys.npub, fallback: (200, [:])) }
        var service = BriefingService(api: TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity)), workspace: workspace.id, app: workspace.appNpub, viewer: TestKeys.npub)
        service.cache = LocalContentSnapshot(store: store, identity: identity, boundary: boundary)
        let fresh = try await service.load()
        #expect(await service.cached() == fresh)
        await identity.lock()
        #expect(await service.cached() == nil)
        _ = try await identity.unlock(pin: TestKeys.pin)
        #expect(await service.cached() == fresh)
        try await store.writer.invalidateLocalContent(workspace: workspace.id, record: sample.file)
        #expect(await service.cached() == nil)
    }
}

/// Explicitly opt-in real-byte check. No identity, record ID, prose or private bytes are embedded in source/output.
@Suite struct AuthorizedBriefingReadbackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AMBULANDO_BRIEFING_READBACK"] != nil))
    func exactAuthorizedBytesMatchExpectedDigestAndOwnerSchema() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["AMBULANDO_BRIEFING_READBACK"], let workspace = env["AMBULANDO_BRIEFING_WORKSPACE"],
              let owner = env["AMBULANDO_BRIEFING_OWNER"], let author = env["AMBULANDO_BRIEFING_AUTHOR"],
              let hash = env["AMBULANDO_BRIEFING_SHA256"], let date = env["AMBULANDO_BRIEFING_DATE"] else { throw BriefingError.invalid }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        guard SHA256Hex.of(bytes) == hash else { throw BriefingError.invalid }
        let journal = try DailyBriefing.parse(bytes, workspace: workspace, owner: owner, author: author)
        guard journal.entries[date] != nil else { throw BriefingError.invalid }
        print("Authorized immutable briefing bytes: digest, owner, author, workspace and dated v1 entry verified; prose withheld.")
    }
}
