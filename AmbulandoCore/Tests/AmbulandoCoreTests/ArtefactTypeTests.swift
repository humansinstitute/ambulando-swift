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
        #expect(ArtefactType.file(try file("Package", fields: ["metadata": ["artefact": ["schema_version": 1, "format_version": 1, "type": "html", "editor_id": "builtin.html"]]])) == .html)
        #expect(ArtefactType.file(try file("Notes.pdf", mime: "application/pdf")) == nil)
        #expect(ArtefactType.file(try file("Future", fields: ["artefact_type": "spreadsheet"])) == nil)
    }
    @Test func unsupportedDescriptorsNeverFallBackToMIMEOrProjection() throws {
        let supported: [String: Any] = ["schema_version": 1, "format_version": 1, "type": "html", "editor_id": "builtin.html"]
        for (key, value) in [("schema_version", 2 as Any), ("format_version", 2 as Any),
                             ("editor_id", "future.html" as Any), ("type", "spreadsheet" as Any),
                             ("schema_version", true as Any)] {
            var descriptor = supported; descriptor[key] = value
            #expect(ArtefactType.file(try file("Future.html", mime: "text/html", fields: [
                "artefact_type": "html", "metadata": ["artefact": descriptor]])) == nil)
        }
        for value: Any in [[:], "unknown"] {
            #expect(ArtefactType.file(try file("Future.html", mime: "text/html", fields: ["metadata": ["artefact": value]])) == nil)
        }
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
    func testDirectHTMLRejectsForeignIdentityBeforeAssetHydration() async throws {
        let identity = try await makeIdentity()
        let file = "00000000-0000-4000-8000-000000000001"
        for (workspace, source) in [(Fixtures.workspaceId, "00000000-0000-4000-8000-000000000099"),
                                    ("00000000-0000-4000-8000-000000000099", file)] {
            let response: [String: Any] = ["workspace_id": workspace, "source": ["type": "html", "id": source],
                "content": ["html": "<p>foreign</p>", "assets": [["name": "image", "status": "ready", "file_id": file,
                    "version_id": file, "sha256": String(repeating: "0", count: 64), "size_bytes": 3, "content_type": "image/png"]]]]
            let data = try JSONSerialization.data(withJSONObject: response)
            let transport = StubTransport { _ in (200, data) }
            let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
            do {
                _ = try await api.artefactHTML(workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub, fileId: file)
                XCTFail("Foreign projection must be rejected")
            } catch TowerError.malformed { }
            XCTAssertEqual(transport.recorded.count, 1, "foreign projection must not hydrate assets")
        }
    }
    func testOnlyAuthorizedVerifiedImageBytesEnterSandbox() async throws {
        let identity = try await makeIdentity()
        let bytes = Data([1, 2, 3])
        let transport = StubTransport { _ in (200, bytes) }
        let api = TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: transport, signer: identity))
        let file = "00000000-0000-4000-8000-000000000001", version = "00000000-0000-4000-8000-000000000002"
        let asset: [String: Any] = ["name": "image", "status": "ready", "file_id": file, "version_id": version,
            "sha256": SHA256Hex.of(bytes), "size_bytes": bytes.count, "content_type": "image/png"]
        let result = try await api.hydratedArtefactHTML("<!DOCTYPE html><html><head></head><body><img data-asset='image'></body></html>", content: ["assets": [asset]], workspaceId: Fixtures.workspaceId, appNpub: Fixtures.appNpub)
        XCTAssertTrue(result.contains("base64,AQID"))
        XCTAssertTrue(result.hasPrefix("<!DOCTYPE html><html><head><script>"))
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
