import XCTest
@testable import AmbulandoCore

final class WorkspaceReportTests: XCTestCase {
    let workspace = "11111111-1111-4111-8111-111111111111"
    let identity = ["workspace_id": "11111111-1111-4111-8111-111111111111", "app_npub": "test-app"]
    func fixture() -> [String: Any] {
        ["identity": identity, "format": "workspace-report-v1", "workspace_id": workspace, "range": "30d",
         "from": "2026-10-24T00:00:00.000Z", "to": "2026-11-23T00:00:00.000Z", "as_of": "2026-11-23T00:00:00.000Z", "timezone": "UTC", "complete": true,
         "channel_policy": "active-project-channels", "activity": ["messages": 7, "conversations": 2],
         "inventory": ["channels": 1, "conversations": 3, "documents": 4, "files": 5,
                       "tasks": ["total": 5, "open": 2, "completed": 1, "archived": 2,
                                 "by_state": ["new": 1, "ready": 0, "in_progress": 1, "review": 0, "done": 1, "archive": 1, "backlog": 0, "blocked": 0, "archived": 1]]],
         "channels": [["channel_id": workspace, "scope_id": workspace, "name": "Visible", "scope_name": "Project", "messages": 7, "conversations": 2]],
         "ranking": ["total_channels": 1, "returned_channels": 1, "has_more": false, "other_messages": 0, "other_conversations": 0],
         "coverage": ["tasks_channels": 1, "documents_channels": 1, "files_channels": 1]]
    }
    func validate(_ o: [String: Any]) throws -> Data { try WorkspaceReportDocument.validate(rawJSON(o), workspace: workspace, range: "30d", identity: identity) }
    func testCanonicalCountsAndIdentityStripped() throws {
        let result = try JSONSerialization.jsonObject(with: validate(fixture())) as! [String: Any]
        XCTAssertNil(result["identity"])
        XCTAssertEqual((result["activity"] as? [String: Int])?["messages"], 7)
    }
    func testRefusesPartialForeignMalformedAndLeakingCounts() throws {
        var bad = fixture(); bad["complete"] = false; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["workspace_id"] = UUID().uuidString; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["identity"] = ["workspace_id": workspace, "app_npub": "wrong"]; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["activity"] = ["messages": 8, "conversations": 2]; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["activity"] = ["messages": true, "conversations": 2]; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["coverage"] = ["tasks_channels": 2, "documents_channels": 1, "files_channels": 1]; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["from"] = "2026-10-23T00:00:00.000Z"; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["channels"] = []; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); bad["private_body"] = "must never pass"; XCTAssertThrowsError(try validate(bad))
        bad = fixture(); var inventory = bad["inventory"] as! [String: Any]; var tasks = inventory["tasks"] as! [String: Any]
        var states = tasks["by_state"] as! [String: Int]; states["unknown"] = 1; tasks["by_state"] = states; inventory["tasks"] = tasks; bad["inventory"] = inventory
        XCTAssertThrowsError(try validate(bad))
    }
    func testZeroAndTopTenRemainder() throws {
        var o = fixture(); o["activity"] = ["messages": 0, "conversations": 0]
        o["channels"] = []; o["inventory"] = ["channels": 0, "conversations": 0, "documents": 0, "files": 0, "tasks": ["total": 0, "open": 0, "completed": 0, "archived": 0, "by_state": ["new": 0, "ready": 0, "in_progress": 0, "review": 0, "done": 0, "archive": 0, "backlog": 0, "blocked": 0, "archived": 0]]]
        o["ranking"] = ["total_channels": 0, "returned_channels": 0, "has_more": false, "other_messages": 0, "other_conversations": 0]
        o["coverage"] = ["tasks_channels": 0, "documents_channels": 0, "files_channels": 0]
        _ = try validate(o)
        o = fixture(); var inv = o["inventory"] as! [String: Any]; inv["channels"] = 11; o["inventory"] = inv
        o["channels"] = (1...10).map { ["channel_id": String(format: "11111111-1111-4111-8111-%012d", $0), "scope_id": workspace, "name": "Visible", "scope_name": "Project", "messages": 1, "conversations": 1] as [String: Any] }
        o["ranking"] = ["total_channels": 11, "returned_channels": 10, "has_more": true, "other_messages": 2, "other_conversations": 1]
        o["activity"] = ["messages": 12, "conversations": 11]; _ = try validate(o)
        o["activity"] = ["messages": 10, "conversations": 10]; XCTAssertThrowsError(try validate(o))
    }
    func testStrictReadOnlyRequest() throws {
        var request: [String: Any] = ["type": "wingman-napplet-data", "version": 1, "session": "nonce", "requestId": "r_1", "operation": "read", "binding": "report", "range": "30d"]
        XCTAssertEqual(try WorkspaceReportRequest.parse(rawJSON(request), session: "nonce").range, "30d")
        XCTAssertThrowsError(try WorkspaceReportRequest.parse(rawJSON(request), session: "wrong"))
        request["operation"] = "save"; XCTAssertThrowsError(try WorkspaceReportRequest.parse(rawJSON(request), session: "nonce"))
        request["operation"] = "read"; request["url"] = "https://example.com"; XCTAssertThrowsError(try WorkspaceReportRequest.parse(rawJSON(request), session: "nonce"))
        request.removeValue(forKey: "url"); request["range"] = "1d"; XCTAssertThrowsError(try WorkspaceReportRequest.parse(rawJSON(request), session: "nonce"))
    }
    func testManifestSeparateFromTracker() throws {
        let manifest = "<script type=\"application/json\" id=\"wingman-napplet-manifest\">{\"version\":1,\"app_id\":\"workspace-report\",\"bindings\":{\"report\":{\"format\":\"workspace-report-v1\",\"operations\":[\"read\"],\"privacy\":\"viewer\"}}}</script>"
        let metadata = try rawJSON(["napplet": ["version": 1, "app_id": "workspace-report", "bindings": ["report": ["workspace_id": workspace]]]])
        XCTAssertEqual(try WorkspaceReportBinding.parse(html: manifest, metadata: metadata).workspaceId, workspace)
        XCTAssertThrowsError(try FileNappletBinding.parse(html: manifest, metadata: metadata))
        XCTAssertThrowsError(try WorkspaceReportBinding.parse(html: manifest + manifest, metadata: metadata))
        XCTAssertThrowsError(try WorkspaceReportBinding.parse(html: manifest.replacingOccurrences(of: "[\"read\"]", with: "[\"read\",\"save\"]"), metadata: metadata))
    }
}

extension WorkspaceReportTests {
    func testSignedTransportPrivateCodeRangeAndRevocation() async throws {
        let f = FileNappletFixture(); f.reportMode = true; f.discoveryCount = 1
        f.codeOverride = "<script type=\"application/json\" id=\"wingman-napplet-manifest\">{\"version\":1,\"app_id\":\"workspace-report\",\"bindings\":{\"report\":{\"format\":\"workspace-report-v1\",\"operations\":[\"read\"],\"privacy\":\"viewer\"}}}</script>"
        let api = try await FileNappletTransportTests().api(f)
        var payload = fixture(); payload["workspace_id"] = Fixtures.workspaceId
        let identity = ["workspace_id": Fixtures.workspaceId, "app_npub": Fixtures.appNpub]
        payload["identity"] = identity; f.reportPayload = payload
        let code = try await api.workspaceReportCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId)
        let connection = try ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))
        let receipt = try FileNappletTrustReceipt(connection: connection, workspace: workspace, codeFile: f.codeId, report: code)
        let store = FileNappletTrustStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.remember(receipt)
        XCTAssertTrue(store.contains(receipt)); XCTAssertEqual(receipt.operations, ["read"]); XCTAssertFalse(receipt.canWrite)
        let changed = WorkspaceReportCode(html: code.html + "<!-- changed -->", binding: code.binding, versionId: code.versionId, sha256: SHA256Hex.of(Data((code.html + "<!-- changed -->").utf8)))
        XCTAssertFalse(store.contains(try FileNappletTrustReceipt(connection: connection, workspace: workspace, codeFile: f.codeId, report: changed)))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        XCTAssertNil(saved["channel_ids"]); XCTAssertNil(saved["counts"])
        let files = try await api.workspaceReports(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub)
        XCTAssertEqual(files.map(\.id), [f.codeId])
        _ = try await api.readWorkspaceReport(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId, expected: code, range: "30d", identity: identity)
        XCTAssertEqual(f.reportRequests.count, 1)
        let request = try XCTUnwrap(f.reportRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "top_n" })?.value, "10")
        XCTAssertEqual(f.posts, 0); XCTAssertEqual(f.createdFiles.count, 0)
        f.codeSuffix = "changed"; f.codeOverride! += "<!-- changed -->"
        do { _ = try await api.readWorkspaceReport(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId, expected: code, range: "30d", identity: identity); XCTFail("changed digest accepted") } catch {}
        XCTAssertEqual(f.reportRequests.count, 1)
        f.participants = ["foreign-viewer"]
        do { _ = try await api.workspaceReportCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId); XCTFail("foreign private code accepted") } catch {}
        f.participants = [TestKeys.npub]; f.bindingOverride = UUID().uuidString.lowercased()
        do { _ = try await api.workspaceReportCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId); XCTFail("foreign workspace binding accepted") } catch {}
        f.bindingOverride = nil; f.denied = true
        do { _ = try await api.workspaceReportCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId); XCTFail("denied code accepted") } catch {}
    }
}

extension WorkspaceReportTests {
    func testGenericAggregateDispatchIsIndependentOfAppIDAndUsesCanonicalReadOnlyRoute() async throws {
        let f = FileNappletFixture(); f.reportMode = true; f.genericSharedCode = true
        let golden = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/generic-v2.json"))) as! [String:Any]
        let m = golden["aggregateManifest"] as! [String:Any]
        f.codeOverride = "<script id=\"wingman-napplet-manifest\">" + String(decoding:try rawJSON(m),as:UTF8.self) + "</script>"
        f.genericMetadata = ["html_artifact":true,"artefact":["schema_version":1,"type":"html","format_version":1,"editor_id":"builtin.html"],"napplet":["version":2,"app_id":m["app_id"]!,"bindings":["summary":["workspace_id":Fixtures.workspaceId]]]]
        let api = try await FileNappletTransportTests().api(f)
        let code = try await api.genericNappletCode(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,fileId:f.codeId)
        let identity = ["workspace_id":Fixtures.workspaceId,"app_npub":Fixtures.appNpub]
        let writable = try await api.authorizeGenericNapplet(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code)
        XCTAssertFalse(writable)
        for range in ["7d","30d","90d","all"] {
            var payload = fixture(); payload["workspace_id"] = Fixtures.workspaceId; payload["identity"] = identity; payload["range"] = range
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            let end = formatter.date(from:payload["to"] as! String)!
            payload["from"] = ["7d":7,"30d":30,"90d":90][range].map { formatter.string(from:end.addingTimeInterval(-Double($0)*86400)) as Any } ?? NSNull()
            f.reportPayload = payload
            let result = try await api.readGenericAggregate(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code,range:range,identity:identity)
            XCTAssertNil((try JSONSerialization.jsonObject(with:result) as? [String:Any])?["identity"])
            let query = URLComponents(url:f.reportRequests.last!.url!,resolvingAgainstBaseURL:false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "top_n" }?.value,"10"); XCTAssertEqual(query.first { $0.name == "range" }?.value,range)
        }
        let session = "0123456789abcdef0123456789abcdef"
        var request:[String:Any] = ["type":"wingman-napplet-data","version":2,"session":session,"requestId":"r1","operation":"read","binding":"summary","range":"90d"]
        XCTAssertEqual(try GenericNappletRequest.parse(rawJSON(request),session:session,binding:code.binding).range,"90d")
        request["operation"] = "save"; XCTAssertThrowsError(try GenericNappletRequest.parse(rawJSON(request),session:session,binding:code.binding))
        f.reportPayload["complete"] = false
        do { _ = try await api.readGenericAggregate(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code,range:"all",identity:identity); XCTFail("partial result") } catch {}
        f.denied = true
        do { _ = try await api.readGenericAggregate(workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub,fileId:f.codeId,expected:code,range:"all",identity:identity); XCTFail("denied result") } catch {}
    }
}
