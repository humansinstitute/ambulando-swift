import Foundation
import XCTest
@testable import AmbulandoCore

extension WorkTests {
    func testConcurrentProtocolIsCapabilityGatedAndPreservesSessionAcrossRenewal() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let session = UUID().uuidString.lowercased(), leaseId = UUID().uuidString.lowercased()
        let transport = StubTransport { request in
            if request.url?.path.hasSuffix("/edit-leases") == true {
                return (200, ["document_edit_protocol": TowerAPI.documentEditProtocol,
                    "document_edit_protocols": [TowerAPI.documentEditProtocol, TowerAPI.concurrentDocumentEditProtocol]])
            }
            let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if request.url?.path.hasSuffix("/acquire") == true {
                XCTAssertEqual(fields["document_edit_protocol"] as? String, TowerAPI.concurrentDocumentEditProtocol)
                XCTAssertEqual(fields["editor_session_id"] as? String, session)
                XCTAssertNil(fields["takeover"])
            }
            return (200, ["document_edit_protocol": TowerAPI.concurrentDocumentEditProtocol,
                "lease": ["id": leaseId, "entity_id": id, "lease_token": "concurrent-test-token", "editor_session_id": session]])
        }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        let lease = try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session)
        XCTAssertEqual(lease.documentEditProtocol, TowerAPI.concurrentDocumentEditProtocol)
        try await saver.renew(h.connection, h.workspace, docId: id, editorSessionId: session)
        XCTAssertEqual(transport.recorded.filter { $0.url?.path.hasSuffix("/acquire") == true }.count, 1)
    }
    func testAdvertisedConcurrentModeNeverDowngradesOrTakesOverAfterConflict() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let transport = StubTransport { request in
            if request.httpMethod == "GET" { return (200, ["document_edit_protocols": [TowerAPI.concurrentDocumentEditProtocol]]) }
            return (409, ["code": "edit_lease_held", "holder_actor_npub": "someone-else"])
        }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        do { try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: UUID().uuidString.lowercased()); XCTFail("conflict accepted") }
        catch is LeaseError {}
        let writes = transport.recorded.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1)
        let fields = try JSONSerialization.jsonObject(with: writes[0].httpBody!) as! [String: Any]
        XCTAssertEqual(fields["document_edit_protocol"] as? String, TowerAPI.concurrentDocumentEditProtocol)
        XCTAssertNil(fields["takeover"])
    }
    func testConcurrentAcquireAndRenewRequireExactProtocolAndSessionEcho() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let session = UUID().uuidString.lowercased(), leaseId = UUID().uuidString.lowercased()
        for wrongSession in [false, true] {
            let transport = StubTransport { request in
                if request.httpMethod == "GET" { return (200, ["document_edit_protocols": [TowerAPI.concurrentDocumentEditProtocol]]) }
                return (200, ["document_edit_protocol": wrongSession ? TowerAPI.concurrentDocumentEditProtocol : TowerAPI.documentEditProtocol,
                    "lease": ["id": leaseId, "entity_id": id, "lease_token": "test-token", "editor_session_id": wrongSession ? UUID().uuidString.lowercased() : session]])
            }
            let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
            do { try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session); XCTFail("invalid echo accepted") }
            catch is LeaseError {}
        }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin(h.connection.origin), transport: StubTransport { _ in
            (200, ["lease": ["id": leaseId, "entity_id": id, "editor_session_id": session]])
        }, signer: h.chat.identity))
        let lease = EditLease(id: leaseId, token: "test-token", expiresAt: "", documentEditProtocol: TowerAPI.concurrentDocumentEditProtocol, editorSessionId: session)
        do { _ = try await api.renewLease(workspaceId: h.workspace.id, appNpub: h.workspace.appNpub, lease: lease); XCTFail("missing echo accepted") }
        catch is LeaseError {}
    }
    func testOldServerWithoutInspectionKeepsExclusiveProtocol() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let session = UUID().uuidString.lowercased()
        let lease = try await h.saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session)
        XCTAssertNotEqual(lease.documentEditProtocol, TowerAPI.concurrentDocumentEditProtocol)
        let request = try XCTUnwrap(h.transport.recorded.first { $0.url?.path.hasSuffix("/acquire") == true })
        let fields = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(fields["document_edit_protocol"] as? String, TowerAPI.documentEditProtocol)
    }
}

extension WorkTests {
    func testOpenConcurrentSessionDoesNotDowngradeIfCapabilityDisappearsOnRetry() async throws {
        let h = try await WorkHarness.make()
        let (id, _) = seedDoc(h)
        let session = UUID().uuidString.lowercased()
        let transport = StubTransport { request in
            if request.httpMethod == "GET" { return (200, ["document_edit_protocols": [TowerAPI.concurrentDocumentEditProtocol]]) }
            return (409, ["code": "edit_lease_held"])
        }
        let saver = DocumentSaver(store: h.store, identity: h.chat.identity, transport: transport)
        do { try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session); XCTFail("should be held") }
        catch is LeaseError {}
        transport.setHandler { _ in (200, ["document_edit_protocol": TowerAPI.documentEditProtocol]) }
        do { try await saver.acquire(h.connection, h.workspace, docId: id, editorSessionId: session); XCTFail("must not downgrade") }
        catch LeaseError.invalid(let message) { XCTAssertEqual(message, "concurrent_protocol_unavailable") }
        XCTAssertEqual(transport.recorded.filter { $0.httpMethod == "POST" }.count, 1)
    }
}
