import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct ArtefactTypeTests {
    private func file(_ name: String, mime: String? = nil, fields: [String: Any] = [:]) throws -> FileRecord {
        var row: [String: Any] = ["id": "00000000-0000-4000-8000-000000000001", "workspace_id": "00000000-0000-4000-8000-000000000002",
            "channel_id": "00000000-0000-4000-8000-000000000003", "display_name": name]
        if let mime { row["content_type"] = mime }
        row.merge(fields) { _, new in new }
        return try FileRecord(raw: JSONSerialization.data(withJSONObject: row))
    }
    @Test func legacyAndProjectedFilesRemainDiscoverable() throws {
        #expect(ArtefactType.file(try file("Sketch.EXCALIDRAW")) == .whiteboard)
        #expect(ArtefactType.file(try file("Preview", mime: "text/html; charset=utf-8")) == .html)
        #expect(ArtefactType.file(try file("Saved scene", fields: ["artefact_type": "excalidraw"])) == .whiteboard)
        #expect(ArtefactType.file(try file("Package", fields: ["metadata": ["artefact": ["schema_version": 1, "type": "html"]]])) == .html)
        #expect(ArtefactType.file(try file("Notes.pdf", mime: "application/pdf")) == nil)
        #expect(ArtefactType.file(try file("Future", fields: ["artefact_type": "spreadsheet"])) == nil)
    }
    @Test func filePinDecodesThroughExistingRecord() throws {
        let row: [String: Any] = ["id": "00000000-0000-4000-8000-000000000001", "workspace_id": "00000000-0000-4000-8000-000000000002",
            "resource_type": "file", "resource_id": "00000000-0000-4000-8000-000000000003", "pinned": true, "row_version": 3]
        let pin = try PinRecord(raw: JSONSerialization.data(withJSONObject: row))
        #expect(pin.resourceType == .file)
        #expect(pin.rowVersion == 3)
    }
}

import XCTest

final class ArtefactAssetTests: XCTestCase {
    func testOnlyAuthorizedVerifiedImageBytesEnterSandbox() async throws {
        let identity = try await makeIdentity()
        let bytes = Data([1, 2, 3])
        let transport = StubTransport { _ in (200, bytes) }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
        let file = "00000000-0000-4000-8000-000000000001", version = "00000000-0000-4000-8000-000000000002"
        let asset: [String: Any] = ["name": "image", "status": "ready", "file_id": file, "version_id": version,
            "sha256": SHA256Hex.of(bytes), "size_bytes": bytes.count, "content_type": "image/png"]
        let result = try await api.hydratedArtefactHTML("<img data-asset='image'>", content: ["assets": [asset]], workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub)
        XCTAssertTrue(result.contains("base64,AQID"))
        XCTAssertEqual(transport.recorded.count, 1)
        var denied = asset; denied["status"] = "unavailable"
        let unavailable = try await api.hydratedArtefactHTML("<img>", content: ["assets": [denied]], workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub)
        XCTAssertFalse(unavailable.contains("base64,AQID"))
        XCTAssertEqual(transport.recorded.count, 1, "denied projection must not fetch private bytes")
        var mismatch = asset; mismatch["sha256"] = String(repeating: "0", count: 64)
        let invalid = try await api.hydratedArtefactHTML("<img>", content: ["assets": [mismatch]], workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub)
        XCTAssertFalse(invalid.contains("base64,AQID"), "digest mismatch never reaches the sandbox")
        var script = asset; script["content_type"] = "application/javascript"
        _ = try await api.hydratedArtefactHTML("<img>", content: ["assets": [script]], workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub)
        XCTAssertEqual(transport.recorded.count, 2, "non-image scripts are refused before any fetch")
    }
}
