import ImageIO
import XCTest
@testable import AmbulandoCore

/// Tasks, documents, files, inbox, reactions, message revisions, uploads and search against deterministic transport
/// fixtures that follow the Tower route rules (`SampleWorkTower`, `FakeChatTower`). No live Tower is involved.
struct WorkHarness {
    let chat: ChatHarness
    let work: SampleWorkTower
    let transport: StubTransport
    let staging: URL

    var store: LocalStore { chat.store }
    var connection: ConnectionRecord { chat.connection }
    var workspace: WorkspaceRecord { chat.workspace }
    var engine: SyncEngine { chat.engine }
    var sync: WorkspaceSync { WorkspaceSync(store: store, engine: engine, identity: chat.identity, transport: transport) }
    var writes: WriteSender { WriteSender(store: store, engine: engine, identity: chat.identity, transport: transport, staging: staging) }
    var outbox: OutboxSender { OutboxSender(store: store, engine: engine, identity: chat.identity, transport: transport, staging: staging) }
    var saver: DocumentSaver { DocumentSaver(store: store, identity: chat.identity, transport: transport) }

    static func make() async throws -> WorkHarness {
        let chat = try await ChatHarness.make()
        let work = SampleWorkTower(workspaceId: Fixtures.workspaceId, towerOrigin: "https://tower.example")
        work.actorNpub = TestKeys.npub
        let chatHandler = chat.tower.handler()
        let transport = StubTransport { request in try work.handle(request) ?? chatHandler(request) }
        try await chat.store.writer.upsertScopes(workspaceId: Fixtures.workspaceId,
                                                 [try ScopeRecord(raw: Fixtures.json(Fixtures.scope(Fixtures.scopeA, name: "A")))], complete: true)
        try await chat.store.writer.upsertChannels(workspaceId: Fixtures.workspaceId, scopeId: Fixtures.scopeA,
                                                   [try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel1, scope: Fixtures.scopeA, name: "one"))),
                                                    try ChannelRecord(raw: Fixtures.json(Fixtures.channel(Fixtures.channel2, scope: Fixtures.scopeA, name: "two")))],
                                                   complete: true)
        return WorkHarness(chat: chat, work: work, transport: transport, staging: chat.directory.appendingPathComponent("Staging"))
    }

    /// Waits until nothing runs or is ready to run; a scheduled automatic retry may still be waiting.
    func settled() async {
        for _ in 0..<500 {
            if await engine.snapshot.isIdle { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func drainWrites() async { await writes.kick(connection, force: true); await engine.waitUntilIdle() }
    func pending() async throws -> [WriteItem] { try await store.reader.writes(connectionId: connection.id, workspaceId: workspace.id) }
}

final class WorkTests: XCTestCase {
    func taskIntent(_ kind: WriteKind, _ task: String?, _ payload: [String: any Sendable]) -> WriteIntent { WriteIntent(kind: kind, targetId: task, payload: payload) }

    // MARK: Tasks

    func testTaskListSyncReconcilesPerChannelAndStaysInWorkspace() async throws {
        let h = try await WorkHarness.make()
        let a = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Alpha")
        h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel2, title: "Beta", state: "in_progress")
        await h.sync.refreshTasks(h.connection, h.workspace)
        await h.engine.waitUntilIdle()
        var tasks = try await h.store.reader.tasks(workspaceId: h.workspace.id)
        XCTAssertEqual(Set(tasks.map(\.title)), ["Alpha", "Beta"])
        // Removed on Tower: gone locally after the channel's complete list.
        h.work.externalTaskEdit(a, fields: ["channel_id": Fixtures.channel2])
        await h.sync.refreshTasks(h.connection, h.workspace, force: true)
        await h.engine.waitUntilIdle()
        tasks = try await h.store.reader.tasks(workspaceId: h.workspace.id, channelId: Fixtures.channel1)
        XCTAssertTrue(tasks.isEmpty)
        let awaited1 = try await h.store.reader.tasks(workspaceId: Fixtures.workspaceId2).isEmpty
        XCTAssertTrue(awaited1)
    }

    func testTaskCreateReplaysAfterLostResponse() async throws {
        let h = try await WorkHarness.make()
        h.work.inject(.dropResponseAfterCommit, matching: "/channels/\(Fixtures.channel1)/tasks")
        let item = try await h.writes.submit(taskIntent(.taskCreate, nil, ["channel_id": Fixtures.channel1, "title": "Ship build 3", "state": "ready", "priority": "pebble"]),
                                             connection: h.connection, workspace: h.workspace)
        await h.settled()
        var rows = try await h.pending()
        XCTAssertEqual(rows.first?.state, .retrying)
        XCTAssertEqual(rows.first?.payloadObject["ambiguous"] as? Bool, true)
        await h.drainWrites()
        rows = try await h.pending()
        XCTAssertTrue(rows.isEmpty)
        let tasks = try await h.store.reader.tasks(workspaceId: h.workspace.id)
        XCTAssertEqual(tasks.map(\.title), ["Ship build 3"], "replayed by client_request_id, not duplicated")
        let creates = h.transport.recorded.filter { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("/tasks") }
        XCTAssertEqual(creates.count, 2)
        for request in creates {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["client_request_id"] as? String, item.id)
        }
    }

    func testTaskStateAndOfflineRetry() async throws {
        let h = try await WorkHarness.make()
        let id = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "T")
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        h.work.inject(.offline, matching: "/state")
        try await h.writes.submit(taskIntent(.taskState, id, ["state": "done"]), connection: h.connection, workspace: h.workspace)
        await h.settled()
        let awaited2 = try await h.pending().first?.state
        XCTAssertEqual(awaited2, .retrying)
        let awaited3 = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)?.state
        XCTAssertEqual(awaited3, "new", "not applied until Tower accepts")
        await h.drainWrites()
        let awaited4 = try await h.pending().isEmpty
        XCTAssertTrue(awaited4)
        let awaited5 = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)?.state
        XCTAssertEqual(awaited5, "done")
        XCTAssertEqual(h.work.task(id)?["state"] as? String, "done")
    }

    func testTaskEditConflictKeepsUserTextUntilAppliedAnyway() async throws {
        let h = try await WorkHarness.make()
        let id = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Original", description: "d")
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let awaited6 = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        let local = try XCTUnwrap(awaited6)
        h.work.externalTaskEdit(id, fields: ["title": "Theirs"])
        let item = try await h.writes.submit(taskIntent(.taskPatch, id, ["base_row_version": local.rowVersion, "base": ["title": "Original", "description": "d", "priority": "sand"],
                                                                         "patch": ["title": "Mine"]]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited7 = try await h.store.reader.writeItem(id: item.id)
        var row = try XCTUnwrap(awaited7)
        XCTAssertEqual(row.state, .conflict)
        XCTAssertEqual((row.payloadObject["patch"] as? [String: Any])?["title"] as? String, "Mine", "the user's text is kept")
        XCTAssertEqual(h.work.task(id)?["title"] as? String, "Theirs", "someone else's change was not overwritten")
        XCTAssertFalse(h.transport.recorded.contains { $0.httpMethod == "PATCH" })
        try await h.writes.retry(item.id, connection: h.connection, force: true)
        await h.engine.waitUntilIdle()
        let awaited8 = try await h.store.reader.writeItem(id: item.id)
        XCTAssertNil(awaited8)
        XCTAssertEqual(h.work.task(id)?["title"] as? String, "Mine")
        // An unrelated concurrent change (priority) does not block a title edit.
        let awaited9 = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        let fresh = try XCTUnwrap(awaited9)
        h.work.externalTaskEdit(id, fields: ["priority": "rock"])
        row = try await h.writes.submit(taskIntent(.taskPatch, id, ["base_row_version": fresh.rowVersion, "base": ["title": "Mine", "description": "d", "priority": "sand"],
                                                                    "patch": ["title": "Mine again"]]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited10 = try await h.store.reader.writeItem(id: row.id)
        XCTAssertNil(awaited10)
        XCTAssertEqual(h.work.task(id)?["title"] as? String, "Mine again")
        XCTAssertEqual(h.work.task(id)?["priority"] as? String, "rock")
    }

    func testAssignmentUsesRowVersionAndDetectsCompetingAssignee() async throws {
        let h = try await WorkHarness.make()
        let id = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "A")
        await h.sync.refreshTasks(h.connection, h.workspace); await h.engine.waitUntilIdle()
        let awaited11 = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        let base = try XCTUnwrap(awaited11)
        h.work.externalTaskEdit(id, fields: ["title": "renamed"])   // row version moves, assignee unchanged
        try await h.writes.submit(taskIntent(.taskAssign, id, ["assigned_to_npub": TestKeys.npub, "base_row_version": base.rowVersion, "base_assigned_to_npub": ""]),
                                  connection: h.connection, workspace: h.workspace)
        await h.settled()
        let awaited12 = try await h.pending().isEmpty
        XCTAssertTrue(awaited12)
        XCTAssertEqual(h.work.task(id)?["assigned_to_npub"] as? String, TestKeys.npub)
        let patches = h.transport.recorded.filter { $0.httpMethod == "PATCH" }.map { try! JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
        XCTAssertEqual(patches.count, 2, "stale first attempt, then the fresh row version")
        XCTAssertEqual(patches.first?["row_version"] as? Int, base.rowVersion)

        let awaited13 = try await h.store.reader.task(workspaceId: h.workspace.id, id: id)
        let now = try XCTUnwrap(awaited13)
        h.work.externalTaskEdit(id, fields: ["assigned_to_npub": FixtureNpubs.other])
        let item = try await h.writes.submit(taskIntent(.taskAssign, id, ["assigned_to_npub": "", "base_row_version": now.rowVersion, "base_assigned_to_npub": TestKeys.npub]),
                                             connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited14 = try await h.store.reader.writeItem(id: item.id)?.state
        XCTAssertEqual(awaited14, .conflict)
    }

    func testCommentsReconcileInsteadOfDuplicating() async throws {
        let h = try await WorkHarness.make()
        let task = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "C")
        h.work.inject(.dropResponseAfterCommit, matching: "/tasks/\(task)/comments")
        let item = try await h.writes.submit(taskIntent(.taskComment, task, ["body": "Looks good"]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        await h.drainWrites()
        let awaited15 = try await h.pending().isEmpty
        XCTAssertTrue(awaited15)
        let comments = h.work.taskComments(task)
        XCTAssertEqual(comments.count, 1, "the second pass found the first attempt by client_record_id")
        XCTAssertEqual((comments.first?["metadata"] as? [String: Any])?["client_record_id"] as? String, item.id)
        let local = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .task, parentId: task)
        XCTAssertEqual(local.map(\.body), ["Looks good"])
    }

    func testPermissionDenialIsPermanentAndBlocksOnlyThatRecord() async throws {
        let h = try await WorkHarness.make()
        let a = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "A")
        let b = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "B")
        h.work.inject(.status(403, "forbidden"), matching: "/tasks/\(a)/state")
        let denied = try await h.writes.submit(taskIntent(.taskState, a, ["state": "done"]), connection: h.connection, workspace: h.workspace)
        try await h.writes.submit(taskIntent(.taskState, a, ["state": "review"]), connection: h.connection, workspace: h.workspace)
        try await h.writes.submit(taskIntent(.taskState, b, ["state": "done"]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited16 = try await h.store.reader.writeItem(id: denied.id)
        let row = try XCTUnwrap(awaited16)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.lastStatus, 403)
        XCTAssertEqual(h.work.task(a)?["state"] as? String, "new", "the later write for A waits behind the refusal")
        XCTAssertEqual(h.work.task(b)?["state"] as? String, "done", "B is independent")
    }

    func testWritesWaitForTheirOwnUnlockedSigner() async throws {
        let h = try await WorkHarness.make()
        let id = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "L")
        await h.chat.identity.lock()
        try await h.writes.submit(taskIntent(.taskState, id, ["state": "done"]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        XCTAssertTrue(h.transport.recorded.isEmpty, "nothing is signed or sent while locked")
        try await h.chat.identity.unlock(pin: TestKeys.pin)
        await h.drainWrites()
        XCTAssertEqual(h.work.task(id)?["state"] as? String, "done")
    }

    // MARK: Documents

    func seedDoc(_ h: WorkHarness, text: String = "Hello") -> (id: String, bytes: Data) {
        var body = DocumentBody.newDocument(text: text).bytes
        // Unknown envelope and model fields must survive native saves.
        var root = try! JSONValue.parse(body).setting("future_field", .object([("keep", .bool(true))]))
        root = root.setting("content_model", root["content_model"]!.setting("references", .array([.string("r1")])))
        body = root.serialized()
        return (h.work.seedDoc(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Plan", body: body, contentType: DocumentBody.envelopeContentType), body)
    }

    func draft(_ h: WorkHarness, doc: String, edit: (JSONValue) throws -> JSONValue) async throws -> DocDraft {
        let awaited17 = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: doc)
        let cached = try XCTUnwrap(awaited17)
        let body = DocumentBody(bytes: cached.bytes, contentType: cached.contentType)
        let encoded = try body.encoded(editorState: try edit(try XCTUnwrap(body.editorState)))
        return DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: doc, title: "Plan", body: encoded.bytes, contentType: encoded.contentType,
                        baseRowVersion: cached.docRowVersion, baseSha256: cached.sha256, baseStorageObjectId: cached.storageObjectId, state: .editing)
    }

    func testDocumentBodyIsVerifiedAndCached() async throws {
        let h = try await WorkHarness.make()
        let (doc, bytes) = seedDoc(h)
        await h.sync.refreshDocs(h.connection, h.workspace); await h.sync.refreshDoc(h.connection, h.workspace, docId: doc)
        await h.engine.waitUntilIdle()
        let awaited18 = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: doc)
        let cached = try XCTUnwrap(awaited18)
        XCTAssertEqual(cached.bytes, bytes)
        XCTAssertEqual(cached.sha256, SHA256Hex.of(bytes))
        let hits = try await h.store.reader.search(workspaceId: h.workspace.id, text: "hello")
        XCTAssertEqual(hits.map(\.kind), [.doc])

        // A body that does not match Tower's hash is refused.
        let bad = StubTransport { request in
            if request.url!.path.hasSuffix("/body") {
                return (200, ["doc": ["id": doc, "workspace_id": Fixtures.workspaceId, "channel_id": Fixtures.channel1, "storage_object_id": cached.storageObjectId,
                                      "title": "Plan", "row_version": 9],
                              "body": ["object_id": cached.storageObjectId, "content_type": "application/json", "sha256_hex": String(repeating: "0", count: 64),
                                       "encoding": "base64", "base64_data": Data("tampered".utf8).base64EncodedString()]])
            }
            return (404, [:])
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: bad, signer: h.chat.identity))
        do { _ = try await api.docBody(workspaceId: h.workspace.id, appNpub: h.workspace.appNpub, docId: doc); XCTFail("accepted a tampered body") }
        catch { XCTAssertEqual(error as? DocumentBodyError, .integrity) }
    }

    func testDocumentSaveUsesLeaseAndPreservesUnknownContent() async throws {
        let h = try await WorkHarness.make()
        let (doc, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: doc); await h.engine.waitUntilIdle()
        let edited = try await draft(h, doc: doc) { state in
            let block = DocumentEditor.blocks(state)[0]
            return try DocumentEditor.setText(state, path: block.path, text: "Hello from the iPhone")
        }
        try await h.store.writer.saveDocDraft(edited)
        let result = await h.saver.save(edited, connection: h.connection, workspace: h.workspace)
        guard case .saved(let record, _) = result else { return XCTFail("not saved: \(result)") }
        XCTAssertEqual(record.rowVersion, 2)
        let awaited19 = try await h.store.reader.docDraft(key: edited.key)
        XCTAssertNil(awaited19, "the draft is removed only after Tower accepts")
        let stored = try XCTUnwrap(h.work.docBody(doc))
        let root = try JSONValue.parse(stored)
        XCTAssertEqual(root["future_field"]?["keep"], .bool(true))
        XCTAssertEqual(root["content_model"]?["references"], .array([.string("r1")]))
        XCTAssertEqual(root["content_model"]?["content"]?.stringValue, "Hello from the iPhone")
        let patch = try XCTUnwrap(h.transport.recorded.last { $0.httpMethod == "PATCH" })
        let body = try JSONSerialization.jsonObject(with: patch.httpBody!) as! [String: Any]
        XCTAssertEqual(body["row_version"] as? Int, 1)
        XCTAssertNotNil(body["lease_token"] as? String)
        XCTAssertEqual(body["base_body_sha256_hex"] as? String, edited.baseSha256)
        XCTAssertTrue(h.work.credentialLeaks.isEmpty, "the presigned upload never carried credentials")
        XCTAssertTrue(h.work.requestLog.contains { $0.hasPrefix("PUT presigned") })
    }

    func testStaleDocumentSaveBecomesRecoveryAndKeepsDraft() async throws {
        let h = try await WorkHarness.make()
        let (doc, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: doc); await h.engine.waitUntilIdle()
        let edited = try await draft(h, doc: doc) { try DocumentEditor.setText($0, path: [0], text: "Mine") }
        try await h.store.writer.saveDocDraft(edited)
        h.work.externalDocSave(doc, body: DocumentBody.newDocument(text: "Theirs").bytes, contentType: DocumentBody.envelopeContentType)
        let result = await h.saver.save(edited, connection: h.connection, workspace: h.workspace)
        guard case .recovery = result else { return XCTFail("expected recovery: \(result)") }
        XCTAssertEqual(h.work.recoveryCount, 1)
        XCTAssertEqual(DocumentBody(bytes: h.work.docBody(doc)!, contentType: nil).markdown, "Theirs", "the head was not overwritten")
        let awaited20 = try await h.store.reader.docDraft(key: edited.key)
        let kept = try XCTUnwrap(awaited20)
        XCTAssertEqual(kept.state, .recovery)
        XCTAssertEqual(kept.body, edited.body, "the unsaved edit is preserved on the device")
    }

    func testHeldLeaseAndOfflineKeepTheDraft() async throws {
        let h = try await WorkHarness.make()
        let (doc, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: doc); await h.engine.waitUntilIdle()
        let edited = try await draft(h, doc: doc) { try DocumentEditor.setText($0, path: [0], text: "Draft") }
        try await h.store.writer.saveDocDraft(edited)
        h.work.holdLease(doc: doc, by: FixtureNpubs.other)
        guard case .leaseHeld = await h.saver.save(edited, connection: h.connection, workspace: h.workspace) else { return XCTFail("lease should be held") }
        XCTAssertFalse(h.transport.recorded.contains { $0.httpMethod == "PATCH" }, "nothing saved without the lease")
        h.work.releaseHeldLease(doc: doc)
        h.work.inject(.offline, matching: "/storage/prepare")
        guard case .notSaved = await h.saver.save(edited, connection: h.connection, workspace: h.workspace) else { return XCTFail("offline should not save") }
        let awaited21 = try await h.store.reader.docDraft(key: edited.key)?.state
        XCTAssertEqual(awaited21, .editing)
        guard case .saved = await h.saver.save(edited, connection: h.connection, workspace: h.workspace) else { return XCTFail("should save when online") }
        let saver = h.saver
        try await saver.acquire(h.connection, h.workspace, docId: doc)
        await saver.release(h.connection, h.workspace, docId: doc)
        let hasLease = await saver.hasLease(workspaceId: h.workspace.id, docId: doc)
        XCTAssertFalse(hasLease)
    }

    func testDocumentCommentsAndStatus() async throws {
        let h = try await WorkHarness.make()
        let (doc, _) = seedDoc(h)
        try await h.writes.submit(taskIntent(.docComment, doc, ["body": "Typo in line 2"]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited22 = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: doc).first
        let comment = try XCTUnwrap(awaited22)
        XCTAssertEqual(comment.status, "open")
        try await h.writes.submit(WriteIntent(kind: .docCommentStatus, targetId: comment.id, payload: ["doc_id": doc, "status": "resolved", "row_version": comment.rowVersion]),
                                  connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited23 = try await h.store.reader.comments(workspaceId: h.workspace.id, parent: .doc, parentId: doc).first?.status
        XCTAssertEqual(awaited23, "resolved")
    }

    // MARK: Files and storage

    func testUploadUsesUnsignedPresignedPutThenFileRecord() async throws {
        let h = try await WorkHarness.make()
        let bytes = Data("quarterly numbers".utf8)
        try FileManager.default.createDirectory(at: h.staging, withIntermediateDirectories: true)
        try bytes.write(to: h.staging.appendingPathComponent("up-1"))
        h.work.inject(.offline, matching: "presigned")
        let item = try await h.writes.submit(WriteIntent(kind: .fileUpload, targetId: Fixtures.channel1, payload: [
            "channel_id": Fixtures.channel1, "staged": "up-1", "content_type": "text/plain", "file_name": "numbers.txt", "display_name": "numbers.txt"]),
            connection: h.connection, workspace: h.workspace)
        await h.settled()
        let awaited24 = try await h.store.reader.writeItem(id: item.id)?.state
        XCTAssertEqual(awaited24, .retrying)
        await h.drainWrites()
        let awaited25 = try await h.store.reader.writeItem(id: item.id)
        XCTAssertNil(awaited25)
        XCTAssertEqual(h.work.fileCount, 1)
        XCTAssertEqual(h.transport.recorded.filter { $0.url!.path.hasSuffix("/storage/prepare") }.count, 1, "the prepared object was reused after the failed transfer")
        let presigned = h.transport.recorded.filter { $0.url!.host == h.work.objectHost }
        XCTAssertEqual(presigned.count, 2)
        XCTAssertTrue(presigned.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertTrue(h.work.credentialLeaks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.staging.appendingPathComponent("up-1").path), "staged bytes removed after acceptance")
        let files = try await h.store.reader.files(workspaceId: h.workspace.id)
        XCTAssertEqual(files.map(\.displayName), ["numbers.txt"])
        // Download verifies the hash.
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: h.transport, signer: h.chat.identity))
        let object = try await api.fileObject(workspaceId: h.workspace.id, appNpub: h.workspace.appNpub, fileId: files[0].id)
        XCTAssertEqual(object.bytes, bytes)
    }

    func testFallbackUploadIsSignedOnPinnedOriginAndUnsafeURLsAreRefused() async throws {
        let h = try await WorkHarness.make()
        h.work.useFallbackUploads(true)
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: h.transport, signer: h.chat.identity))
        let objectId = try await api.store(workspaceId: h.workspace.id, appNpub: h.workspace.appNpub, bytes: Data("x".utf8), contentType: "text/plain",
                                           fileName: "x.txt", prepared: nil) { _ in }
        let put = try XCTUnwrap(h.transport.recorded.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(put.url?.path, "/api/v4/storage/\(objectId)")
        XCTAssertNotNil(put.value(forHTTPHeaderField: "Authorization"))
        let event = try decodeAuthorization(put)
        XCTAssertTrue(event.tags.contains(["payload", SHA256Hex.of(put.httpBody!)]), "NIP-98 covers the exact body")

        for unsafe in ["https://tower.example/api/v4/flightdeck-pg/workspaces/x", "http://objects.elsewhere.example/b/\(objectId)",
                       "https://user:pw@objects.example/b/\(objectId)", "https://objects.example/api/v4/storage/\(objectId)"] {
            do {
                try await api.upload(PreparedObject(objectId: objectId, uploadURL: unsafe), bytes: Data("y".utf8), contentType: "text/plain")
                XCTFail("accepted \(unsafe)")
            } catch { XCTAssertEqual(error as? FileTransferError, .unsafeUploadURL, unsafe) }
        }
    }

    // MARK: Inbox

    func testInboxMarkReadIsLocalFirstAndDurable() async throws {
        let h = try await WorkHarness.make()
        let task = h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Review me")
        h.work.seedViewState(type: "task", resource: task, scope: Fixtures.scopeA, channel: Fixtures.channel1, activity: 3, viewed: 1, attention: 3)
        h.work.seedViewState(type: "document", resource: UUID().uuidString.lowercased(), scope: nil, channel: Fixtures.channel1, activity: 2, viewed: 2)
        await h.sync.refreshInbox(h.connection, h.workspace); await h.engine.waitUntilIdle()
        var states = try await h.store.reader.viewStates(workspaceId: h.workspace.id)
        XCTAssertEqual(states.filter(\.unread).count, 1)
        XCTAssertTrue(states.first { $0.resourceId == task }?.needsAttention == true)
        let awaited26 = try await h.store.reader.task(workspaceId: h.workspace.id, id: task)
        XCTAssertNotNil(awaited26, "an inbox record missing locally is fetched")

        await h.chat.identity.lock()   // offline/locked: still marked read on the device
        try await h.store.writer.markViewedLocally(workspaceId: h.workspace.id, [(.task, task, 3)])
        try await h.writes.submit(WriteIntent(kind: .viewMark, targetId: task, payload: ["resources": [["resource_type": "task", "resource_id": task, "viewed_activity_version": 3] as [String: any Sendable]]]),
                                  connection: h.connection, workspace: h.workspace)
        states = try await h.store.reader.viewStates(workspaceId: h.workspace.id)
        XCTAssertFalse(states.first { $0.resourceId == task }!.unread)
        // A sync while the write is pending does not resurrect the unread state.
        try await h.store.writer.upsertViewStates(workspaceId: h.workspace.id, [try ViewStateRecord(raw: rawJSON(h.work.viewState(type: "task", resource: task)!))])
        let awaited27 = try await h.store.reader.viewStates(workspaceId: h.workspace.id).first { $0.resourceId == task }!.unread
        XCTAssertFalse(awaited27)
        try await h.chat.identity.unlock(pin: TestKeys.pin)
        await h.drainWrites()
        XCTAssertEqual(h.work.viewState(type: "task", resource: task)?["viewed_activity_version"] as? Int, 3)
        let awaited28 = try await h.pending().isEmpty
        XCTAssertTrue(awaited28)
    }

    // MARK: Messages: reactions, edit, delete, attachments

    func testReactionsAddRemoveAndReconcile() async throws {
        let h = try await WorkHarness.make()
        let message = h.chat.tower.seed(channel: Fixtures.channel1, body: "React to me")
        let id = message["id"] as! String
        h.work.inject(.dropResponseAfterCommit, matching: "/reactions")
        try await h.writes.submit(WriteIntent(kind: .reactionAdd, targetId: id, payload: ["target_type": "message", "emoji": "heart"]),
                                  connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle(); await h.drainWrites()
        XCTAssertEqual(h.work.reactionRows().count, 1, "reconciled, not duplicated")
        let local = try await h.store.reader.reactions(workspaceId: h.workspace.id, targetIds: [id])
        XCTAssertEqual(local.map(\.emoji), ["heart"])
        try await h.writes.submit(WriteIntent(kind: .reactionRemove, targetId: id, payload: ["reaction_id": local[0].id]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        XCTAssertTrue(h.work.reactionRows().isEmpty)
        let awaited29 = try await h.store.reader.reactions(workspaceId: h.workspace.id, targetIds: [id]).isEmpty
        XCTAssertTrue(awaited29)
    }

    func testMessageEditSignsRevisionAndDetectsConflicts() async throws {
        let h = try await WorkHarness.make()
        let seeded = h.chat.tower.seed(channel: Fixtures.channel1, body: "Tpyo here")
        let id = seeded["id"] as! String, thread = seeded["thread_id"] as! String
        await h.chat.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1); await h.engine.waitUntilIdle()
        let item = try await h.writes.submit(WriteIntent(kind: .messageEdit, targetId: id, payload: [
            "channel_id": Fixtures.channel1, "thread_id": thread, "body": "Typo here", "row_version": 1, "mentions": [String]()]),
            connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited30 = try await h.store.reader.writeItem(id: item.id)
        XCTAssertNil(awaited30)
        let awaited31 = try await h.store.reader.message(workspaceId: h.workspace.id, id: id)?.body
        XCTAssertEqual(awaited31, "Typo here")
        let revision = try XCTUnwrap(h.chat.tower.revisions.first)
        XCTAssertTrue(revision.tags.contains(["revision", "2"]))
        XCTAssertTrue(revision.tags.contains(["message_id", id]))
        XCTAssertTrue(revision.tags.contains(["thread_id", thread]))

        h.chat.tower.externalEdit(id: id, body: "Changed elsewhere")
        let stale = try await h.writes.submit(WriteIntent(kind: .messageEdit, targetId: id, payload: [
            "channel_id": Fixtures.channel1, "thread_id": thread, "body": "Mine", "row_version": 2, "mentions": [String]()]),
            connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited32 = try await h.store.reader.writeItem(id: stale.id)?.state
        XCTAssertEqual(awaited32, .conflict)

        // Writes to one message run in order: the conflict holds a later delete until the user discards it.
        try await h.writes.submit(WriteIntent(kind: .messageDelete, targetId: id, payload: ["row_version": 3]), connection: h.connection, workspace: h.workspace)
        await h.engine.waitUntilIdle()
        let awaited33 = try await h.store.reader.message(workspaceId: h.workspace.id, id: id)?.deleted ?? true
        XCTAssertFalse(awaited33)
        try await h.store.writer.discardWrite(id: stale.id)
        await h.drainWrites()
        let awaited34 = try await h.store.reader.message(workspaceId: h.workspace.id, id: id)?.deleted ?? false
        XCTAssertTrue(awaited34)
        let awaited35 = try await h.store.reader.channelFeed(workspaceId: h.workspace.id, channelId: Fixtures.channel1, limit: 50).isEmpty
        XCTAssertTrue(awaited35)
    }

    func testImageAttachmentUploadsBeforeSigningAndStripsMetadata() async throws {
        let h = try await WorkHarness.make()
        let png = try ImagePrivacy.strippedPNG(SamplePixels.jpegWithEXIF())
        XCTAssertFalse(ImagePrivacy.chunkTypes(png).contains("eXIf"))
        XCTAssertTrue(Set(ImagePrivacy.chunkTypes(png)).isSubset(of: ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "iCCP", "sRGB", "gAMA", "cHRM"]))
        let attachment = try ImagePrivacy.stage(png, in: h.staging, filename: "photo.png")
        let sent = try await h.outbox.send(text: "", mentions: [], target: h.chat.target(), connection: h.connection, workspace: h.workspace,
                                           attachments: [attachment])
        XCTAssertNotNil(sent)
        await h.engine.waitUntilIdle()
        let post = try XCTUnwrap(h.chat.tower.recordedPosts.first)
        let body = try JSONSerialization.jsonObject(with: post.body) as! [String: Any]
        let attachments = ((body["metadata"] as? [String: Any])?["attachments"] as? [[String: Any]]) ?? []
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0]["kind"] as? String, "image")
        XCTAssertEqual(attachments[0]["size_bytes"] as? Int, png.count)
        XCTAssertNotNil(lowerUUID(attachments[0]["storage_object_id"] as? String))
        XCTAssertTrue(h.work.credentialLeaks.isEmpty)
        let awaited36 = try await h.store.reader.outbox(target: h.chat.target()).isEmpty
        XCTAssertTrue(awaited36)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.staging.appendingPathComponent(attachment.staged).path))
    }

    // MARK: Search

    func testLocalSearchIsWorkspaceScopedAndInjectionSafe() async throws {
        let h = try await WorkHarness.make()
        h.chat.tower.seed(channel: Fixtures.channel1, body: "Quarterly roadmap review tomorrow")
        h.work.seedTask(scope: Fixtures.scopeA, channel: Fixtures.channel1, title: "Roadmap slides")
        await h.chat.sync.catchUpChannel(h.connection, h.workspace, channelId: Fixtures.channel1)
        await h.sync.refreshTasks(h.connection, h.workspace)
        await h.engine.waitUntilIdle()
        let hits = try await h.store.reader.search(workspaceId: h.workspace.id, text: "roadm")
        XCTAssertEqual(Set(hits.map(\.kind)), [.message, .task])
        let awaited37 = try await h.store.reader.search(workspaceId: Fixtures.workspaceId2, text: "roadmap").isEmpty
        XCTAssertTrue(awaited37)
        let awaited38 = try await h.store.reader.search(workspaceId: h.workspace.id, text: "\" OR * NEAR(").isEmpty
        XCTAssertTrue(awaited38)
        let awaited39 = try await h.store.reader.search(workspaceId: h.workspace.id, text: "x").isEmpty
        XCTAssertTrue(awaited39, "one character is too short")
    }
}

enum FixtureNpubs {
    static let other = Bech32.encode(hrp: "npub", data: Data(repeating: 0x42, count: 32))
}

/// A tiny JPEG with an EXIF block, generated with ImageIO.
enum SamplePixels {
    static func jpegWithEXIF() throws -> Data {
        let width = 8, height = 8
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImagePrivacy.Failure.encode }
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ImagePrivacy.Failure.encode }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { throw ImagePrivacy.Failure.encode }
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: 0.12]
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"]] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImagePrivacy.Failure.encode }
        return out as Data
    }
}
