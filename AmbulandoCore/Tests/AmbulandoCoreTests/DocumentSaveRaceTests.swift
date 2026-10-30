import Foundation
import XCTest
@testable import AmbulandoCore

/// Pauses the PATCH response while the editor can durably checkpoint fresh typing.
private actor PausedDocumentTransport: HTTPTransport {
    let transport: StubTransport
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let pauseMethod: String
    private let pauseSuffix: String?
    init(_ transport: StubTransport, method: String = "PATCH", suffix: String? = nil) {
        self.transport = transport; pauseMethod = method; pauseSuffix = suffix
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == pauseMethod, pauseSuffix.map({ request.url?.path.hasSuffix($0) == true }) ?? true, !paused {
            paused = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await transport.send(request)
    }
    func waitUntilPaused() async throws {
        for _ in 0..<500 {
            if paused { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TowerError.malformed("save never reached PATCH")
    }
    func resume() { continuation?.resume(); continuation = nil }
}

extension WorkTests {
    func testDocumentSuccessKeepsFreshTypingAndRenameOnAcceptedBase() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let first = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "First") }
        let later = DocDraft(connectionId: first.connectionId, workspaceId: first.workspaceId, docId: first.docId,
                             title: "Renamed while saving", body: DocumentBody.newDocument(text: "Fresh typing").bytes,
                             contentType: first.contentType, baseRowVersion: first.baseRowVersion,
                             baseSha256: first.baseSha256, baseStorageObjectId: first.baseStorageObjectId, state: .editing)
        try await h.store.writer.saveDocDraft(first)
        let gate = PausedDocumentTransport(h.transport)
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: gate)
        let saving = Task { await saver.save(first, connection: h.connection, workspace: h.workspace) }
        try await gate.waitUntilPaused()
        try await h.store.writer.saveDocDraft(later)
        let overlap = await saver.save(later, connection: h.connection, workspace: h.workspace)
        guard case .notSaved = overlap else { return XCTFail("overlapping save was allowed") }
        await gate.resume()
        guard case .saved(_, let accepted) = await saving.value else { return XCTFail("first checkpoint failed") }
        let read = try await h.store.reader.docDraft(key: first.key)
        let kept = try XCTUnwrap(read)
        XCTAssertEqual(kept.body, later.body)
        XCTAssertEqual(kept.title, later.title)
        XCTAssertEqual(kept.contentType, later.contentType)
        XCTAssertEqual(kept.baseRowVersion, accepted.docRowVersion)
        XCTAssertEqual(kept.baseSha256, accepted.sha256)
        XCTAssertEqual(kept.baseStorageObjectId, accepted.storageObjectId)
        XCTAssertEqual(h.transport.recorded.filter { $0.httpMethod == "PATCH" }.count, 1)
        guard case .saved = await saver.save(kept, connection: h.connection, workspace: h.workspace) else { return XCTFail("fresh edit could not save on new base") }
        let final = try await h.store.reader.docDraft(key: first.key)
        XCTAssertNil(final)
    }

    func testDocumentFailureNeverReplacesFreshDurableTyping() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let first = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "First") }
        let later = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "Fresh") }
        try await h.store.writer.saveDocDraft(first)
        h.work.inject(.offline, matching: "/docs/\(id)")
        let gate = PausedDocumentTransport(h.transport)
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: gate)
        let saving = Task { await saver.save(first, connection: h.connection, workspace: h.workspace) }
        try await gate.waitUntilPaused()
        try await h.store.writer.saveDocDraft(later)
        await gate.resume()
        guard case .notSaved = await saving.value else { return XCTFail("offline save should fail") }
        let kept = try await h.store.reader.docDraft(key: first.key)
        XCTAssertEqual(kept, later)
        let cached = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        XCTAssertEqual(cached?.docRowVersion, 1, "last successful cloud checkpoint survives")
    }

    func testOldSnapshotCannotOverwriteNewerDraftBeforeUpload() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let old = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "Old") }
        let latest = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "Latest") }
        try await h.store.writer.saveDocDraft(latest)
        guard case .notSaved = await h.saver.save(old, connection: h.connection, workspace: h.workspace) else { return XCTFail("stale snapshot was uploaded") }
        let kept = try await h.store.reader.docDraft(key: old.key)
        XCTAssertEqual(kept, latest)
        XCTAssertFalse(h.transport.recorded.contains { $0.httpMethod == "PATCH" || $0.url?.path.hasSuffix("/storage/prepare") == true })
    }
    func testUnchangedCheckpointDoesNotUpload() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let cached = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        let body = try XCTUnwrap(cached)
        let unchanged = DocDraft(connectionId: h.connection.id, workspaceId: h.workspace.id, docId: id, title: "Plan",
                                 body: body.bytes, contentType: body.contentType, baseRowVersion: body.docRowVersion,
                                 baseSha256: body.sha256, baseStorageObjectId: body.storageObjectId, state: .editing)
        try await h.store.writer.saveDocDraft(unchanged)
        guard case .saved = await h.saver.save(unchanged, connection: h.connection, workspace: h.workspace) else { return XCTFail("unchanged checkpoint failed") }
        XCTAssertFalse(h.transport.recorded.contains { $0.httpMethod == "PATCH" || $0.url?.path.hasSuffix("/storage/prepare") == true })
    }

    func testLostEditorSessionCannotSilentlyAcquireAgain() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let saver = h.saver
        let session = UUID().uuidString.lowercased()
        try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session)
        h.work.inject(.status(409, "lease_invalid"), matching: "/renew")
        do { try await saver.renew(h.connection, h.workspace, docId: id, editorSessionId: session); XCTFail("lost authority accepted") }
        catch is LeaseError { }
        let before = h.transport.recorded.count
        do { try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session); XCTFail("silently reacquired") }
        catch is LeaseError { }
        XCTAssertEqual(h.transport.recorded.count, before)
    }

    func testFailedPatchReusesCompletedUploadAcrossSaverRelaunch() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let edit = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "Retry once") }
        h.work.inject(.offline, matching: "/docs/\(id)")
        let first = h.saver
        guard case .notSaved = await first.save(edit, connection: h.connection, workspace: h.workspace) else { return XCTFail("first PATCH should fail") }
        await first.release(h.connection, h.workspace, docId: id)
        guard case .saved = await h.saver.save(edit, connection: h.connection, workspace: h.workspace) else { return XCTFail("retry should save") }
        XCTAssertEqual(h.transport.recorded.filter { $0.url?.path.hasSuffix("/storage/prepare") == true }.count, 1)
        XCTAssertEqual(h.transport.recorded.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func testExpiredUnchangedEditorCanResumeSameIdentityAfterFreshHeadCheck() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let original = h.transport
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/edit-leases") == true { return (200, ["lease": NSNull()]) }
            return try original.handlerResult(request)
        }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        let session = UUID().uuidString.lowercased()
        try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session)
        h.work.inject(.status(409, "lease_expired"), matching: "/renew")
        do { try await saver.renew(h.connection, h.workspace, docId: id, editorSessionId: session); XCTFail("expected expiry") }
        catch is LeaseError { }
        let resumed = await saver.resumeUnchangedSession(h.connection, h.workspace, docId: id, editorSessionId: session)
        XCTAssertTrue(resumed)
        let acquires = transport.recorded.filter { $0.url?.path.hasSuffix("/acquire") == true }
        XCTAssertEqual(acquires.count, 2)
        for request in acquires {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(object["editor_session_id"] as? String, session)
        }
        h.work.externalDocSave(id, body: DocumentBody.newDocument(text: "Another device").bytes, contentType: DocumentBody.envelopeContentType)
        await saver.release(h.connection, h.workspace, docId: id, editorSessionId: session)
        let stale = await saver.resumeUnchangedSession(h.connection, h.workspace, docId: id, editorSessionId: session)
        XCTAssertFalse(stale, "changed remote base must never be silently rebased")
    }

    func testTakeoverRequiresCapabilityBeforeSendingMutation() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let expected = UUID().uuidString.lowercased()
        let transport = StubTransport { _ in (200, ["lease": ["id": expected, "holder_actor_npub": h.connection.signerNpub]]) }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        do {
            _ = try await saver.takeover(h.connection, h.workspace, docId: id, editorSessionId: UUID().uuidString.lowercased(), expectedLeaseId: expected)
            XCTFail("old server accepted as takeover-capable")
        } catch is LeaseError { }
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(transport.recorded.first?.httpMethod, "GET")
    }

    func testTakeoverRejectsChangedObservedLeaseBeforeMutation() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let transport = StubTransport { _ in
            (200, ["document_edit_protocol": TowerAPI.documentEditProtocol,
                   "lease": ["id": UUID().uuidString.lowercased(), "holder_actor_npub": "npub1other-editor"]])
        }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        do {
            _ = try await saver.takeover(h.connection, h.workspace, docId: id,
                                         editorSessionId: UUID().uuidString.lowercased(), expectedLeaseId: UUID().uuidString.lowercased())
            XCTFail("changed observed lease accepted")
        } catch is LeaseError { }
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(transport.recorded.first?.httpMethod, "GET")
    }

    func testTakeoverRetainsServerAuthorizationDenialWithoutLoadingBody() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let expected = UUID().uuidString.lowercased()
        let transport = StubTransport { request in
            if request.httpMethod == "GET" {
                return (200, ["document_edit_protocol": TowerAPI.documentEditProtocol,
                              "lease": ["id": expected, "holder_actor_npub": "npub1other-editor"]])
            }
            return (403, ["error": "forbidden", "code": "forbidden"])
        }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        do {
            _ = try await saver.takeover(h.connection, h.workspace, docId: id,
                                         editorSessionId: UUID().uuidString.lowercased(), expectedLeaseId: expected)
            XCTFail("server authorization denial ignored")
        } catch { }
        XCTAssertEqual(transport.recorded.count, 2)
        XCTAssertTrue(transport.recorded.last?.url?.path.hasSuffix("/acquire") == true)
    }

    func testTakeoverFromAnotherActorLoadsVerifiedLatestRemoteContentAndTitle() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        h.work.externalDocSave(id, body: DocumentBody.newDocument(text: "Latest remote text").bytes, contentType: DocumentBody.envelopeContentType)
        let expected = UUID().uuidString.lowercased()
        let session = UUID().uuidString.lowercased()
        let original = h.transport
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/edit-leases") == true {
                return (200, ["document_edit_protocol": TowerAPI.documentEditProtocol,
                              "lease": ["id": expected, "holder_actor_npub": "npub1other-authorized-editor"]])
            }
            let (status, raw) = try original.handlerResult(request)
            if request.url?.path.hasSuffix("/acquire") == true, var row = raw as? [String: Any] {
                row["document_edit_protocol"] = TowerAPI.documentEditProtocol
                return (status, row)
            }
            return (status, raw)
        }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        let (remote, body) = try await saver.takeover(h.connection, h.workspace, docId: id, editorSessionId: session, expectedLeaseId: expected)
        XCTAssertEqual(remote.rowVersion, 2)
        XCTAssertEqual(DocumentBody(bytes: body.bytes, contentType: body.contentType).markdown, "Latest remote text")
        let cached = try await h.store.reader.docBody(workspaceId: h.workspace.id, docId: id)
        XCTAssertEqual(cached?.sha256, body.sha256)
        XCTAssertEqual(cached?.docRowVersion, remote.rowVersion)
        let acquire = try XCTUnwrap(transport.recorded.first { $0.url?.path.hasSuffix("/acquire") == true })
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: acquire.httpBody!) as? [String: Any])
        XCTAssertEqual(fields["takeover"] as? Bool, true)
        XCTAssertEqual(fields["expected_lease_id"] as? String, expected)
        XCTAssertEqual(fields["editor_session_id"] as? String, session)
        XCTAssertTrue(transport.recorded.contains { $0.url?.path.hasSuffix("/renew") == true }, "authority is verified before publishing the loaded base")
    }

    func testLockForgetsInflightAcquireWithoutPermanentlyBlockingBackgroundOperations() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let gate = PausedDocumentTransport(h.transport, method: "POST", suffix: "/acquire")
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: gate)
        let pending = Task { try await saver.acquire(h.connection, h.workspace, docId: id) }
        try await gate.waitUntilPaused()
        await saver.forgetAll()
        await gate.resume()
        do { _ = try await pending.value; XCTFail("late response restored editing authority after lock") }
        catch is LeaseError { }
        catch is CancellationError { }
        let held = await saver.hasLease(workspaceId: h.workspace.id, docId: id)
        XCTAssertFalse(held)
        let next = try await saver.acquire(h.connection, h.workspace, docId: id)
        XCTAssertFalse(next.token.isEmpty, "background wiki binding can acquire after unlock instead of retaining a permanent default tombstone")
    }

}
