import XCTest
@testable import AmbulandoCore

final class InstalledNappletTests: XCTestCase {
    func testSuppliedAuthorizedSnapshotUsesTheSameParser() throws {
        guard let path = ProcessInfo.processInfo.environment["AMBULANDO_NAPPLET_SNAPSHOT"] else { throw XCTSkip("No authorized local snapshot supplied") }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let o = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let identity = o["identity"] as! [String: Any]
        let workspace = try WorkspaceRecord(raw: JSONSerialization.data(withJSONObject: ["identity": identity]))
        let connection = ConnectionRecord(origin: try TowerOrigin("https://snapshot.invalid"), signerNpub: workspace.appNpub, towerNpub: identity["tower_service_npub"] as? String)
        let result = try NappletSnapshot.parse(bytes, workspace: workspace, connection: connection, catalogue: false)
        XCTAssertFalse(result.installations.isEmpty)
        for item in result.installations { XCTAssertNotNil(result.html[item.key]); XCTAssertTrue(item.version > 0) }
    }
    func fixture() async throws -> SurfaceHarness {
        let h = try await SurfaceHarness.make()
        h.tower.seedInstalledNapplet(app: h.workspace.appNpub, owner: h.workspace.ownerNpub!, tower: h.connection.towerNpub ?? h.workspace.appNpub)
        return h
    }
    func testDiscoveryIsSeparateFromWappsAndNeverStoresHtmlOrRows() async throws {
        let h = try await fixture()
        await h.sync.refreshInstalledNapplets(h.connection, h.workspace); await h.idle()
        let apps = try await h.store.reader.installedNapplets(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertEqual(apps.map(\.key), ["project_register"])
        let state = try await h.store.reader.state(WorkspaceSync.nappletsKey(h.connection.id, h.workspace.id))!
        XCTAssertFalse(state.contains("<script>")); XCTAssertFalse(state.contains("expected_revision"))
        let other = try await h.store.reader.installedNapplets(connectionId: "different-viewer", workspaceId: h.workspace.id)
        XCTAssertTrue(other.isEmpty)
        h.tower.inject(.status(403, "denied"), matching: "/org-data/catalogue")
        await h.sync.refreshInstalledNapplets(h.connection, h.workspace, force: true); await h.idle()
        let denied = try await h.store.reader.installedNapplets(connectionId: h.connection.id, workspaceId: h.workspace.id)
        XCTAssertTrue(denied.isEmpty)
    }
    func testProjectionMatchesBridgeAndWritesUseExactRevisionAndOperation() async throws {
        let h = try await fixture()
        let before = try await h.sync.readNapplets(h.connection, h.workspace)
        let projection = try XCTUnwrap(JSONSerialization.jsonObject(with: before.projection) as? [String: Any])
        let rows = try XCTUnwrap(projection["records"] as? [String: [[String: Any]]])
        XCTAssertEqual(rows["project_register_feedback"]?.first?["revision"] as? Int, 1)
        let body = try JSONSerialization.data(withJSONObject: ["expected_revision": 1, "values": ["project_id": "example", "note": "Saved on phone", "status": "done", "operation_id": UUID().uuidString]])
        let path = "types/project_register_feedback/records/" + SampleSurfaceTower.nappletRecordId
        try await h.sync.writeNapplet(h.connection, h.workspace, path: path, method: "PATCH", body: body)
        // Identical operation replay must not create a second revision.
        try await h.sync.writeNapplet(h.connection, h.workspace, path: path, method: "PATCH", body: body)
        let after = try await h.sync.readNapplets(h.connection, h.workspace)
        XCTAssertEqual(before.authority, after.authority, "ordinary values and revisions preserve a draft's authority")
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: after.projection) as? [String: Any])
        let records = try XCTUnwrap(updated["records"] as? [String: [[String: Any]]])
        XCTAssertEqual(records["project_register_feedback"]?.first?["revision"] as? Int, 2)
        let conflict = try JSONSerialization.data(withJSONObject: ["expected_revision": 1, "values": ["note": "stale", "operation_id": UUID().uuidString]])
        do { try await h.sync.writeNapplet(h.connection, h.workspace, path: path, method: "PATCH", body: conflict); XCTFail("stale write accepted") }
        catch { guard case TowerError.http(409, _, _) = error else { return XCTFail("wrong error \(error)") } }
    }
    func testBridgeRejectsCapabilitiesSessionSchemaEscapesAndMissingRevision() throws {
        let session = "current"
        func parse(_ extra: [String: Any], capabilities: [String] = ["org_data.write"]) throws -> NappletIntent {
            try NappletIntent.parse(JSONSerialization.data(withJSONObject: ["version": 1, "session": session].merging(extra, uniquingKeysWith: { _, b in b })), session: session, capabilities: capabilities)
        }
        let path = "types/project_register_feedback/records/" + SampleSurfaceTower.nappletRecordId
        XCTAssertNoThrow(try parse(["type": "write", "path": path, "method": "PATCH", "body": ["expected_revision": 1, "values": ["note": "hello"]]]))
        for bad in ["napplets/bundles", "napplets/installations/project_register", "../snapshot", "https://evil.invalid", "types/x/records/../snapshot", "types/x/records/" + SampleSurfaceTower.nappletRecordId + "?workspace=other"] {
            XCTAssertThrowsError(try parse(["type": "write", "path": bad, "method": "POST", "body": [:]]))
        }
        XCTAssertThrowsError(try parse(["type": "write", "path": path, "method": "PATCH", "body": ["values": [:]]]))
        XCTAssertThrowsError(try parse(["type": "write", "path": path, "method": "PATCH", "body": ["expected_revision": 1]], capabilities: []))
        XCTAssertThrowsError(try parse(["type": "write", "path": "types", "method": "POST", "body": [:]]))
        XCTAssertThrowsError(try parse(["type": "ready", "session": "old"]))
        XCTAssertThrowsError(try parse(["type": "ready", "url": "https://evil.invalid"]))
        XCTAssertThrowsError(try parse(["type": "ready", "version": true]))
    }
    func testSnapshotRejectsTamperedHtmlWrongIdentityAndIncompleteReads() async throws {
        let h = try await fixture()
        let url = URL(string: h.connection.origin + "/api/v4/flightdeck-pg/workspaces/" + h.workspace.id + "/org-data/snapshot")!
        let client = TowerClient(origin: try TowerOrigin(h.connection.origin), transport: h.transport, signer: h.work.chat.identity)
        let bytes = try await client.request(path: url.path, appNpub: h.workspace.appNpub)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for field in ["html", "identity", "complete"] {
            var modified = original
            if field == "html" { var rows = modified["installations"] as! [[String: Any]]; rows[0]["html"] = "tampered"; modified["installations"] = rows }
            if field == "identity" { var id = modified["identity"] as! [String: Any]; id["app_npub"] = Bech32.encode(hrp: "npub", data: Data(repeating: 0xDE, count: 32)); modified["identity"] = id }
            if field == "complete" { modified["complete"] = false }
            XCTAssertThrowsError(try NappletSnapshot.parse(JSONSerialization.data(withJSONObject: modified), workspace: h.workspace, connection: h.connection, catalogue: false))
        }
    }
}
