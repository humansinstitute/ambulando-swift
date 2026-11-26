import XCTest
@testable import AmbulandoCore

private actor MembershipServer {
    enum Mode { case normal, staleAddition, lostCommit, lost502, lostMalformed, lostUnchanged, lostUnchangedThenReversed, staleAfterAmbiguous, commitThenRemove, removeThenReadd, denied, offline }
    var row: ThreadRecord
    var writes = 0
    var mode: Mode = .normal
    let other = try! ThreadArtefactMember(kind: "doc", id: "bbbbbbbb-0000-4000-8000-000000000001")
    init(_ metadata: String = "{\"other_app\":{\"keep\":true}}") throws { row = try Self.record(1, Data(metadata.utf8)) }
    static func record(_ version: Int, _ metadata: Data) throws -> ThreadRecord {
        try ThreadRecord(raw: JSONSerialization.data(withJSONObject: ["id": "cccccccc-0000-4000-8000-000000000001", "workspace_id": Fixtures.workspaceId,
            "channel_id": Fixtures.channel1, "row_version": version, "activity_version": 1, "latest": "unchanged",
            "metadata": try JSONSerialization.jsonObject(with: metadata)]))
    }
    func set(_ mode: Mode) { self.mode = mode }
    func get() -> ThreadRecord { row }
    func count() -> Int { writes }
    func verify(_ member: ThreadArtefactMember) throws { if member.id.hasPrefix("dead") { throw TowerError.http(status: 403, code: "forbidden", stage: nil) } }
    func write(_ base: ThreadRecord, _ metadata: Data) throws -> ThreadRecord {
        writes += 1
        guard base.rowVersion == row.rowVersion else { throw TowerError.http(status: 409, code: "stale_row_version", stage: nil) }
        let behavior = mode; mode = .normal
        switch behavior {
        case .denied: throw TowerError.http(status: 403, code: "forbidden", stage: nil)
        case .offline: mode = .offline; throw URLError(.notConnectedToInternet)
        case .lostUnchanged: throw URLError(.networkConnectionLost)
        case .lostUnchangedThenReversed:
            mode = .staleAfterAmbiguous
            throw URLError(.networkConnectionLost)
        case .staleAfterAmbiguous:
            // The first readback saw an unchanged base, then an ambiguous first attempt committed
            // and another client removed it before the safe old-base retry reached CAS.
            row = try Self.record(row.rowVersion + 2, ThreadArtefactMembership.replacing(ThreadArtefactMembership.metadata(row), with: []))
            throw TowerError.http(status: 409, code: "stale_row_version", stage: nil)
        case .staleAddition:
            row = try Self.record(row.rowVersion + 1, ThreadArtefactMembership.replacing(ThreadArtefactMembership.metadata(row), with: [other]))
            throw TowerError.http(status: 409, code: "stale_row_version", stage: nil)
        default: break
        }
        row = try Self.record(row.rowVersion + 1, metadata)
        if behavior == .commitThenRemove {
            row = try Self.record(row.rowVersion + 1, ThreadArtefactMembership.replacing(metadata, with: []))
        }
        if behavior == .removeThenReadd {
            row = try Self.record(row.rowVersion + 1, ThreadArtefactMembership.metadata(base))
        }
        if behavior == .lost502 { throw TowerError.http(status: 502, code: "bad_gateway", stage: nil) }
        if behavior == .lostMalformed { throw TowerError.malformed("acknowledgement") }
        if [.lostCommit, .commitThenRemove, .removeThenReadd].contains(behavior) { throw URLError(.networkConnectionLost) }
        return row
    }
    nonisolated var transport: ThreadArtefactMembershipSync.Transport {
        .init(read: { await self.get() }, write: { try await self.write($0, $1) }, verify: { try await self.verify($0) })
    }
}

@MainActor final class ThreadArtefactMembershipTests: XCTestCase {
    let doc = try! ThreadArtefactMember(kind: "doc", id: "aaaaaaaa-0000-4000-8000-000000000001")
    let file = try! ThreadArtefactMember(kind: "file", id: "aaaaaaaa-0000-4000-8000-000000000002")
    func members(_ row: ThreadRecord) throws -> [ThreadArtefactMember]? { try ThreadArtefactMembership.read(ThreadArtefactMembership.metadata(row)) }
    func testDurablePublishingHoldSurvivesStaleReviewAndDatabaseReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(directory: directory)
        let key = "connection:workspace:doc", other = "connection:workspace:other"
        let generation = try await store.writer.holdDocumentAutomaticPublishing(key: key)
        try await store.writer.saveDocumentReview(DocumentReviewJournal(), key: key)
        let reopened = try LocalStore(directory: directory)
        let held = try await reopened.reader.documentAutomaticPublishingHeld(key: key)
        let unrelated = try await reopened.reader.documentAutomaticPublishingHeld(key: other)
        XCTAssertTrue(held); XCTAssertFalse(unrelated)
        try await reopened.writer.releaseDocumentAutomaticPublishingHold(key: key, expectedGeneration: generation)
        let released = try await store.reader.documentAutomaticPublishingHeld(key: key)
        XCTAssertFalse(released)
    }
    func testAtomicPublishingHoldReleasePreservesNewerDraftAndGeneration() async throws {
        let h = try await ChatHarness.make()
        let draft = DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: doc.id, title: "Newer recovery",
            body: Data("recovery".utf8), contentType: "text/plain", baseRowVersion: 1, baseSha256: String(repeating: "a", count: 64),
            baseStorageObjectId: UUID().uuidString.lowercased(), state: .recovery)
        let first = try await h.store.writer.holdDocumentAutomaticPublishing(key: draft.key, renew: true)
        try await h.store.writer.saveDocDraft(draft)
        let retained = try await h.store.writer.releaseDocumentAutomaticPublishingHold(key: draft.key, expectedGeneration: first)
        XCTAssertFalse(retained)
        try await h.store.writer.deleteDocDraft(key: draft.key, workspaceId: h.workspace.id)
        let second = try await h.store.writer.holdDocumentAutomaticPublishing(key: draft.key, renew: true)
        XCTAssertNotEqual(first, second)
        let stale = try await h.store.writer.releaseDocumentAutomaticPublishingHold(key: draft.key, expectedGeneration: first)
        XCTAssertFalse(stale)
        let held = try await h.store.reader.documentAutomaticPublishingHeld(key: draft.key)
        XCTAssertTrue(held)
        let released = try await h.store.writer.releaseDocumentAutomaticPublishingHold(key: draft.key, expectedGeneration: second)
        XCTAssertTrue(released)
    }
    func testNewAttachmentsRejectUnsupportedAndArchivedSourcesButLabelsStayLazy() async throws {
        let h = try await ChatHarness.make()
        let fileID = file.id, docID = doc.id
        let stub = StubTransport { request in
            let id = request.url!.lastPathComponent
            let row: [String: Any] = ["id": id, "workspace_id": Fixtures.workspaceId, "channel_id": Fixtures.channel1,
                "row_version": 1, "display_name": "Photo.png", "content_type": "image/png", "title": "Archived Doc",
                "record_state": id == docID ? "archived" : "active"]
            return (200, [id == fileID ? "file" : "doc": row])
        }
        let sync = WorkspaceSync(store: h.store, engine: SyncEngine(), identity: h.identity, transport: stub)
        let transport = try sync.threadMembershipTransport(h.connection, h.workspace, threadId: "cccccccc-0000-4000-8000-000000000001")
        for member in [file, doc] {
            do { try await transport.verify(member); XCTFail("unsupported/archived attachment") }
            catch ThreadArtefactMembership.Error.unsupported {} catch { throw error }
        }
        let label = try await sync.threadArtefactLabel(h.connection, h.workspace, member: file)
        XCTAssertEqual(label, "Photo.png")
        XCTAssertTrue(stub.recorded.allSatisfy { $0.httpMethod == "GET" && !$0.url!.path.contains("versions") && !$0.url!.path.contains("object") })
    }
    func testInteroperabilityFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/thread-artefact-membership-v1.json")
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        func data(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: fixtures[key]!) }
        XCTAssertNil(try ThreadArtefactMembership.read(data("absent")))
        XCTAssertEqual(try ThreadArtefactMembership.read(data("initialized_empty")), [])
        let parsed = try ThreadArtefactMembership.read(data("doc_board_html"))
        XCTAssertEqual(parsed?.map(\.kind), ["doc", "file", "file"])
        XCTAssertEqual(parsed?.first, doc)
        XCTAssertThrowsError(try ThreadArtefactMembership.read(data("future_version")))
    }
    func testSchemaAbsentEmptyDedupAndUnknown() throws {
        XCTAssertNil(try ThreadArtefactMembership.read(Data("{}".utf8)))
        let empty = try ThreadArtefactMembership.replacing(Data("{}".utf8), with: [])
        XCTAssertEqual(try ThreadArtefactMembership.read(empty), [])
        XCTAssertEqual(try ThreadArtefactMembership.read(ThreadArtefactMembership.replacing(empty, with: [doc, doc, file])), [doc, file])
        for invalid in ["null", "{\"version\":true,\"items\":[]}", "{\"version\":2,\"items\":[]}", "{\"version\":1,\"items\":[],\"active\":true}", "{\"version\":1,\"items\":[{\"kind\":\"doc\",\"id\":\"bad\"}]}" ] {
            XCTAssertThrowsError(try ThreadArtefactMembership.read(Data("{\"ambulando_thread_artefacts\":\(invalid)}".utf8)))
        }
        let refs = try (0..<33).map { _ in try ThreadArtefactMember(kind: "file", id: UUID().uuidString) }
        XCTAssertThrowsError(try ThreadArtefactMembership.replacing(empty, with: refs))
        XCTAssertEqual(try ThreadArtefactMembership.read(ThreadArtefactMembership.replacing(empty, with: Array(refs.prefix(32))))?.count, 32)
    }
    func testTwoIndependentStoresReopenAndStaleCacheCannotResurrect() async throws {
        let server = try MembershipServer(), t = server.transport
        let d1 = temporaryDirectory(), d2 = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: d1); try? FileManager.default.removeItem(at: d2) }
        let a = try LocalStore(directory: d1), b = try LocalStore(directory: d2)
        let added = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: t)
        _ = try await a.writer.upsertThreads(workspaceId: Fixtures.workspaceId, [added])
        _ = try await b.writer.upsertThreads(workspaceId: Fixtures.workspaceId, [t.read()])
        let second = try await b.reader.thread(workspaceId: Fixtures.workspaceId, id: "cccccccc-0000-4000-8000-000000000001")
        XCTAssertEqual(try members(XCTUnwrap(second)), [doc])
        _ = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: t)
        let count = await server.count(); XCTAssertEqual(count, 1)
        let removed = try await ThreadArtefactMembershipSync.change(doc, adding: false, transport: t)
        _ = try await b.writer.upsertThreads(workspaceId: Fixtures.workspaceId, [removed, added])
        let latest = try await b.reader.thread(workspaceId: Fixtures.workspaceId, id: "cccccccc-0000-4000-8000-000000000001")
        XCTAssertEqual(try members(XCTUnwrap(latest)), [])
        let migrated = try await ThreadArtefactMembershipSync.migrate([doc], transport: t)
        XCTAssertEqual(try members(migrated), [])
        let reopened = try LocalStore(directory: d2)
        let persisted = try await reopened.reader.thread(workspaceId: Fixtures.workspaceId, id: "cccccccc-0000-4000-8000-000000000001")
        XCTAssertEqual(try members(XCTUnwrap(persisted)), [])
    }
    func testConflictPreservesOtherAdditionAndUnrelatedMetadata() async throws {
        let s = try MembershipServer(); await s.set(.staleAddition)
        let saved = try await ThreadArtefactMembershipSync.change(file, adding: true, transport: s.transport)
        let other = await s.other
        XCTAssertEqual(Set(try members(saved) ?? []), Set([file, other]))
        XCTAssertTrue(String(decoding: try ThreadArtefactMembership.metadata(saved), as: UTF8.self).contains("other_app"))
        XCTAssertEqual(saved.latest, "unchanged")
    }
    func testUnchangedReadbackThenStaleRetryCannotForgetEarlierAmbiguity() async throws {
        let s = try MembershipServer(); await s.set(.lostUnchangedThenReversed)
        do { _ = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: s.transport); XCTFail("earlier ambiguous commit must remain uncertain") }
        catch ThreadArtefactMembership.Error.uncertain {} catch { throw error }
        let row = await s.get(); XCTAssertEqual(try members(row), [])
        let count = await s.count(); XCTAssertEqual(count, 2, "no replay on the advanced base")
    }
    func testAmbiguousCommittedAndUnchangedBaseRetry() async throws {
        for mode in [MembershipServer.Mode.lostCommit, .lost502, .lostMalformed, .lostUnchanged] {
            let s = try MembershipServer(); await s.set(mode)
            let saved = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: s.transport)
            XCTAssertEqual(try members(saved), [doc])
            let count = await s.count(); XCTAssertEqual(count, mode == .lostUnchanged ? 2 : 1)
        }
    }
    func testAmbiguousCommitThenLaterRemovalAndRemovalThenReaddNeverReplay() async throws {
        let s = try MembershipServer(); await s.set(.commitThenRemove)
        do { _ = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: s.transport); XCTFail("must report uncertainty") }
        catch { XCTAssertTrue(error is ThreadArtefactMembership.Error) }
        let row = await s.get(); XCTAssertEqual(try members(row), [])
        let count = await s.count(); XCTAssertEqual(count, 1)
        _ = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: s.transport)
        await s.set(.removeThenReadd)
        do { _ = try await ThreadArtefactMembershipSync.change(doc, adding: false, transport: s.transport); XCTFail("must report uncertainty") }
        catch { XCTAssertTrue(error is ThreadArtefactMembership.Error) }
        let readded = await s.get(); XCTAssertEqual(try members(readded), [doc])
        let countAfter = await s.count(); XCTAssertEqual(countAfter, 3)
    }
    func testDeniedOfflineAndUnknownDoNotReplaceMembership() async throws {
        let s = try MembershipServer()
        for mode in [MembershipServer.Mode.denied, .offline] {
            await s.set(mode)
            do { _ = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: s.transport); XCTFail("failure expected") } catch {}
            let row = await s.get(); XCTAssertNil(try members(row))
        }
        let unknown = try MembershipServer("{\"ambulando_thread_artefacts\":{\"version\":2,\"items\":[]}}")
        do { _ = try await ThreadArtefactMembershipSync.change(doc, adding: true, transport: unknown.transport); XCTFail("unknown") } catch {}
        let count = await unknown.count(); XCTAssertEqual(count, 0)
    }
    func testMigrationOnlyNonemptyVerifiedWhenAbsent() async throws {
        let s = try MembershipServer()
        _ = try await ThreadArtefactMembershipSync.migrate([], transport: s.transport)
        let count = await s.count(); XCTAssertEqual(count, 0)
        let denied = try ThreadArtefactMember(kind: "doc", id: "dead0000-0000-4000-8000-000000000001")
        let saved = try await ThreadArtefactMembershipSync.migrate([denied, doc, doc], transport: s.transport)
        XCTAssertEqual(try members(saved), [doc])
    }
}
