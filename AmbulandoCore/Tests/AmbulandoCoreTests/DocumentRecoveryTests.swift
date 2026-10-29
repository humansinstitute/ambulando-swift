import Foundation
import XCTest
@testable import AmbulandoCore

final class DocumentRecoveryTests: XCTestCase {
    func testIdentityIgnoresJSONSerializationOrderButPreservesEveryContentField() {
        let a = Data(#"{"content_model":{"editor_state":{"type":"doc","content":[{"type":"text","text":"a","marks":[{"type":"bold"}]}]},"unknown":1},"format":"document_content_v1"}"#.utf8)
        let b = Data(#"{ "format":"document_content_v1", "content_model":{"unknown":1,"editor_state":{"content":[{"marks":[{"type":"bold"}],"text":"a","type":"text"}],"type":"doc"}} }"#.utf8)
        XCTAssertTrue(DocumentContentIdentity.equal(a, title: "Title", b, otherTitle: "Title"))
        XCTAssertFalse(DocumentContentIdentity.equal(a, title: "Title", b, otherTitle: "Title "))
        XCTAssertFalse(DocumentContentIdentity.equal(a, title: "Title", Data(String(decoding: b, as: UTF8.self).replacingOccurrences(of: "bold", with: "italic").utf8), otherTitle: "Title"))
        XCTAssertFalse(DocumentContentIdentity.equal(a, title: "Title", Data(String(decoding: b, as: UTF8.self).replacingOccurrences(of: "unknown\":1", with: "unknown\":2").utf8), otherTitle: "Title"))
    }
    func testSingleCharacterDeletionWhitespaceAndEmptyAreMeaningful() {
        for (a,b) in [("a",""),("hello","hell"),("hello","hello "),("a\nb","a b")] {
            XCTAssertFalse(DocumentContentIdentity.equal(Data(a.utf8), title: "t", Data(b.utf8), otherTitle: "t"))
        }
    }
    func testRecoveryRequiresExactWorkspaceAndDocumentIdentity() throws {
        let w = UUID().uuidString.lowercased(), d = UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
        let raw = try rawJSON(["id":id,"workspace_id":w,"doc_id":d,"storage_object_id":UUID().uuidString.lowercased(),"submitted_patch":["title":"Exact title"],"provenance":["created_at":"today"]])
        XCTAssertEqual(try DocumentRecovery(raw: raw, workspaceId: w, docId: d).title, "Exact title")
        XCTAssertThrowsError(try DocumentRecovery(raw: raw, workspaceId: UUID().uuidString, docId: d))
        XCTAssertThrowsError(try DocumentRecovery(raw: raw, workspaceId: w, docId: UUID().uuidString))
    }
}

extension WorkTests {
    func testRecoveryPreviewPromotionRaceAndDismissKeepCanonicalAndBytes() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        await h.sync.refreshDoc(h.connection, h.workspace, docId: id); await h.engine.waitUntilIdle()
        let previous = try await draft(h, doc: id) { try DocumentEditor.setText($0, path: [0], text: "Previous exact text 🙂") }
        let saver = h.saver
        try await h.store.writer.saveDocDraft(previous)
        guard case .recovery(let recoveryId, _) = await saver.save(previous, connection: h.connection, workspace: h.workspace, asRecovery: true) else { return XCTFail("missing recovery") }
        let recovery = try XCTUnwrap(recoveryId)
        let list = try await saver.recoveries(h.connection, h.workspace, docId: id)
        XCTAssertEqual(list.map(\.id), [recovery])
        let preview = try await saver.recoveryBody(h.connection, h.workspace, docId: id, recoveryId: recovery)
        XCTAssertEqual(preview.bytes, previous.body)
        let reviewed = try await saver.latest(h.connection, h.workspace, docId: id)
        h.work.externalDocSave(id, body: DocumentBody.newDocument(text: "Newer remote head").bytes, contentType: DocumentBody.envelopeContentType)
        let newHead = try await saver.latest(h.connection, h.workspace, docId: id)
        let session = UUID().uuidString.lowercased()
        do {
            try await saver.resolveRecovery(h.connection, h.workspace, docId: id, recoveryId: recovery, promote: true, head: reviewed.body, editorSessionId: session)
            XCTFail("stale choice applied")
        } catch TowerError.http(let status, let code, _) {
            XCTAssertEqual(status, 409); XCTAssertEqual(code, "recovery_promotion_conflict")
        } catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(h.work.docBody(id), newHead.body.bytes)
        let retainedPrevious = try await saver.recoveryBody(h.connection, h.workspace, docId: id, recoveryId: recovery)
        XCTAssertEqual(retainedPrevious.bytes, previous.body)
        try await saver.resolveRecovery(h.connection, h.workspace, docId: id, recoveryId: recovery, promote: true, head: newHead.body, editorSessionId: session)
        XCTAssertEqual(h.work.docBody(id), previous.body)
        await saver.release(h.connection, h.workspace, docId: id, editorSessionId: session)
        // A second recovery can be dismissed without changing or deleting the canonical object.
        guard case .recovery(let secondId, _) = await saver.save(previous, connection: h.connection, workspace: h.workspace, asRecovery: true) else { return XCTFail("missing second recovery") }
        let second = try XCTUnwrap(secondId)
        let canonical = try await saver.latest(h.connection, h.workspace, docId: id)
        try await saver.resolveRecovery(h.connection, h.workspace, docId: id, recoveryId: second, promote: false, head: canonical.body, editorSessionId: UUID().uuidString.lowercased())
        let after = try await saver.latest(h.connection, h.workspace, docId: id)
        XCTAssertEqual(after.body.bytes, canonical.body.bytes)
        XCTAssertEqual(after.body.docRowVersion, canonical.body.docRowVersion)
        XCTAssertEqual(after.body.storageObjectId, canonical.body.storageObjectId)
        let dismissedBytes = try await saver.recoveryBody(h.connection, h.workspace, docId: id, recoveryId: second)
        XCTAssertEqual(dismissedBytes.bytes, previous.body)
        let localDraft = try await h.store.reader.docDraft(key: previous.key)
        XCTAssertNotNil(localDraft, "cloud preview and resolution do not silently remove durable local work")
    }
}
