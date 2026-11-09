import XCTest
@testable import AmbulandoCore

final class DocumentActionsTests: XCTestCase {
    func testCanonicalHistoryPreservesRawEnvelopeAndRejectsForeignIdentity() throws {
        let w = UUID().uuidString.lowercased(), d = UUID().uuidString.lowercased()
        let bytes = DocumentBody.newDocument(text: "Historical **text**").bytes
        let row: [String: Any] = ["workspace_id": w, "doc_id": d, "row_version": 4, "title": "History", "content": ["raw": String(decoding: bytes, as: UTF8.self), "content_type": DocumentBody.envelopeContentType]]
        let version = try DocumentVersion(raw: rawJSON(row), workspaceId: w, docId: d)
        XCTAssertEqual(version.bytes, bytes)
        XCTAssertEqual(version.rowVersion, 4)
        XCTAssertThrowsError(try DocumentVersion(raw: rawJSON(row), workspaceId: UUID().uuidString, docId: d))
        var missing = row; missing["content"] = ["missing": true]
        XCTAssertNil(try DocumentVersion(raw: rawJSON(missing), workspaceId: w, docId: d).bytes)
    }
    func testReferenceEscapesMarkdownLabel() {
        XCTAssertEqual(DocumentActionText.reference(title: "  A\n\t B  ", docId: "123456789"), "@[A B](mention:document:123456789)")
        XCTAssertEqual(DocumentActionText.reference(title: "   ", docId: "123456789"), "@[12345678](mention:document:123456789)")
        XCTAssertEqual(DocumentActionText.reference(title: "A [B]", docId: "id"), "@[A \\[B\\]](mention:document:id)")
    }
    func testHistoryReadsCanonicalRouteNotRecoveries() async throws {
        let h = try await WorkHarness.make(), id = UUID().uuidString.lowercased()
        let workspaceId = h.workspace.id
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod,"GET")
            XCTAssertTrue(request.url!.path.hasSuffix("/docs/" + id + "/versions"))
            return (200,["versions":[["workspace_id":workspaceId,"doc_id":id,"title":"Shared history","row_version":2,"content":["raw":"earlier text","content_type":"text/markdown"]]],"next_cursor":NSNull()])
        }
        let saver = DocumentSaver(store:h.store,identity:h.chat.identity,transport:transport)
        let versions = try await saver.versions(h.connection,h.workspace,docId:id)
        XCTAssertEqual(versions.count,1); XCTAssertEqual(versions.first?.bytes,Data("earlier text".utf8))
    }

    func testArchiveRejectsStaleAndDeniedWithoutChangingCache() async throws {
        let h = try await WorkHarness.make()
        let docId = UUID().uuidString.lowercased(), storage = UUID().uuidString.lowercased()
        let row: [String: Any] = ["id":docId,"workspace_id":h.workspace.id,"channel_id":Fixtures.channel1,"storage_object_id":storage,"title":"Active","row_version":3,"created_at":"today","updated_at":"today","archived_at":NSNull()]
        let doc = try DocRecord(raw: rawJSON(row)); let serialized = try rawJSON(row)
        try await h.store.writer.upsertDocs(workspaceId: h.workspace.id, [doc])
        for status in [0, 403, 409, 500] {
            let transport = StubTransport { request in
                XCTAssertEqual(request.httpMethod, "PATCH")
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(payload["row_version"] as? Int, 3); XCTAssertEqual(payload["archived"] as? Bool, true)
                if status == 0 { throw URLError(.timedOut) }
                return (status, ["code": status == 409 ? "stale_row_version" : "denied"])
            }
            let saver = DocumentSaver(store:h.store,identity:h.chat.identity,transport:transport)
            do { try await saver.setLifecycle(h.connection,h.workspace,doc:doc,delete:false); XCTFail("Unconfirmed operation succeeded") } catch { }
            let cached = try await h.store.reader.doc(workspaceId:h.workspace.id,id:docId)
            XCTAssertEqual(cached?.rowVersion,3); XCTAssertEqual(cached?.archived,false)
        }
        let transport = StubTransport { _ in
            var archived = try JSONSerialization.jsonObject(with: serialized) as! [String: Any]
            archived["row_version"] = 4; archived["archived_at"] = "now"
            return (200,["doc":archived])
        }
        try await DocumentSaver(store:h.store,identity:h.chat.identity,transport:transport).setLifecycle(h.connection,h.workspace,doc:doc,delete:false)
        let cached = try await h.store.reader.doc(workspaceId:h.workspace.id,id:docId)
        XCTAssertEqual(cached?.archived,true); XCTAssertEqual(cached?.rowVersion,4)
    }

    func testLifecycleUsesVersionGuardAndPreservesDraftUntilConfirmed() async throws {
        let h = try await WorkHarness.make()
        let docId = UUID().uuidString.lowercased()
        let storage = UUID().uuidString.lowercased()
        let row: [String: Any] = ["id":docId,"workspace_id":h.workspace.id,"channel_id":Fixtures.channel1,"storage_object_id":storage,"title":"Lifecycle","row_version":3,"created_at":"today","updated_at":"today","archived_at":NSNull()]
        let doc = try DocRecord(raw: rawJSON(row))
        try await h.store.writer.upsertDocs(workspaceId: h.workspace.id, [doc])
        let draft = DocDraft(connectionId:h.connection.id,workspaceId:h.workspace.id,docId:docId,title:"Unsaved",body:Data("retained".utf8),contentType:"text/markdown",baseRowVersion:3,baseSha256:"abc",baseStorageObjectId:storage,state:.editing)
        try await h.store.writer.saveDocDraft(draft)
        let serialized = try rawJSON(row)
        let transport = StubTransport { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {$0.name == "row_version"})?.value, "3")
            var deleted = try JSONSerialization.jsonObject(with: serialized) as! [String: Any]; deleted["row_version"] = 4; deleted["record_state"] = "deleted"
            return (200, ["doc":deleted])
        }
        let saver = DocumentSaver(store:h.store,identity:h.chat.identity,transport:transport)
        try await saver.setLifecycle(h.connection,h.workspace,doc:doc,delete:true)
        let remaining = try await h.store.reader.doc(workspaceId:h.workspace.id,id:docId)
        let retained = try await h.store.reader.docDraft(key:draft.key)
        XCTAssertNil(remaining); XCTAssertEqual(retained?.body,draft.body)
    }
}
