import XCTest
@testable import AmbulandoCore

final class WorkspaceStorageTests: XCTestCase {
    func fixture(_ name: String) throws -> [String: Any] {
        try GenericJSON.decode(Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name + ".json")))
    }
    func validate(_ s: [String: Any]) throws {
        try WorkspaceStorageDocument.validate(s, workspace: "00000000-0000-4000-8000-000000000001", asOf: "2026-01-01T00:00:00.000Z")
    }
    func testFrozenFixtureAndFutureMetrics() throws {
        var s = try fixture("workspace-storage-v1"); try validate(s)
        var groups = s["groups"] as! [[String: Any]]
        groups.append(["id": "future_group", "metrics": [["id": "future_bytes", "value": 9007199254740991, "unit": "bytes", "method": "future-method", "status": "actual"]]])
        s["groups"] = groups; try validate(s)
        let golden = try fixture("workspace-report-storage-v1")
        var r = golden["value"] as! [String: Any]
        r["identity"] = ["workspace_id": r["workspace_id"] as! String, "app_npub": "synthetic-app"]
        let output = try WorkspaceStorageDocument.validateReport(rawJSON(r), workspace: r["workspace_id"] as! String, range: r["range"] as! String, identity: r["identity"] as! [String: String])
        let projected = try GenericJSON.decode(output)
        XCTAssertNil(projected["identity"])
        let storage = projected["storage"] as! [String: Any]
        let metrics = (storage["groups"] as! [[String: Any]])[0]["metrics"] as! [[String: Any]]
        XCTAssertTrue(metrics.first { $0["id"] as? String == "physical_bytes" }!["value"] is NSNull)
        XCTAssertThrowsError(try WorkspaceReportDocument.validate(rawJSON(r), workspace: r["workspace_id"] as! String, range: r["range"] as! String, identity: r["identity"] as! [String: String]))
    }
    func testRejectsUnsafeMetricsAndScope() throws {
        let original = try fixture("workspace-storage-v1")
        for value: Any in [true, -1, 1.5, 9007199254740992, NSNull()] {
            var s = original; var groups = s["groups"] as! [[String: Any]]; var metrics = groups[0]["metrics"] as! [[String: Any]]
            metrics[0]["value"] = value; groups[0]["metrics"] = metrics; s["groups"] = groups
            XCTAssertThrowsError(try validate(s))
        }
        for patch: [String: Any] in [["workspace_id": "foreign"], ["as_of": "2025-01-01T00:00:00.000Z"], ["activity_range_applies": true], ["caveats": [String(repeating: "a", count: 1025)]], ["provider_measured_at": "2027-01-01T00:00:00.000Z"], ["provider_measured_at": "2025-01-01T00:00:00.00Z"]] {
            var s = original; s.merge(patch) { _, new in new }; XCTAssertThrowsError(try validate(s))
        }
        var s = original; var groups = s["groups"] as! [[String: Any]]
        groups.append(groups[0]); s["groups"] = groups; XCTAssertThrowsError(try validate(s))
        s = original; groups = s["groups"] as! [[String: Any]]; var metrics = groups[0]["metrics"] as! [[String: Any]]
        metrics[6]["value"] = 0; groups[0]["metrics"] = metrics; s["groups"] = groups; XCTAssertThrowsError(try validate(s))
        s = original; s["groups"] = Array(repeating: groups[0], count: 9); XCTAssertThrowsError(try validate(s))
    }
    func testMetricBoundsControlsAndProjectionBudget() throws {
        let original = try fixture("workspace-storage-v1")
        for patch: [String: Any] in [["id": "<unsafe>"], ["method": String(repeating: "a", count: 65)], ["unit": "USD"], ["status": "unknown"], ["extra": "content"]] {
            var s = original; var groups = s["groups"] as! [[String: Any]]; var metrics = groups[0]["metrics"] as! [[String: Any]]
            metrics[0].merge(patch) { _, new in new }; groups[0]["metrics"] = metrics; s["groups"] = groups; XCTAssertThrowsError(try validate(s))
        }
        var s = original; var groups = s["groups"] as! [[String: Any]]; var metrics = groups[0]["metrics"] as! [[String: Any]]
        metrics.append(metrics[0]); groups[0]["metrics"] = metrics; s["groups"] = groups; XCTAssertThrowsError(try validate(s))
        groups[0]["metrics"] = (0..<33).map { ["id": "m\($0)", "value": 0, "unit": "count", "method": "count", "status": "estimated"] }
        s["groups"] = groups; XCTAssertThrowsError(try validate(s))
        for caveats in [["control\n"], [String(repeating: "😀", count: 513)], Array(repeating: "x", count: 17)] {
            s = original; s["caveats"] = caveats; XCTAssertThrowsError(try validate(s))
        }
        let golden = try fixture("workspace-report-storage-v1")
        var report = golden["value"] as! [String: Any]; let workspace = report["workspace_id"] as! String
        let identity = ["workspace_id": workspace, "app_npub": "synthetic"]
        report["identity"] = identity
        var storage = report["storage"] as! [String: Any]
        storage["groups"] = (0..<8).map { g in ["id": "g\(g)", "metrics": (0..<32).map { m in ["id": "m\(m)" + String(repeating: "a", count: 55), "value": 9007199254740991, "unit": "bytes", "method": String(repeating: "a", count: 64), "status": "estimated"] }] }
        storage["caveats"] = Array(repeating: String(repeating: "a", count: 1024), count: 16); report["storage"] = storage
        XCTAssertThrowsError(try WorkspaceStorageDocument.validateReport(rawJSON(report), workspace: workspace, range: report["range"] as! String, identity: identity))
    }
    func binding(_ version: Int) throws -> GenericNappletBinding {
        let m: [String: Any] = ["version": 2, "app_id": "any-report", "title": "Report", "icon": "R", "bindings": ["summary": ["capability": "workspace-aggregate", "version": version, "operations": ["read"]]]]
        guard let result = try GenericNappletBinding.parse(html: "<script id=\"wingman-napplet-manifest\">" + String(decoding: rawJSON(m), as: UTF8.self) + "</script>", metadata: rawJSON(["napplet": ["version": 2, "app_id": "any-report", "bindings": ["summary": ["workspace_id": Fixtures.workspaceId]]]])) else { throw FileNappletError.invalid }
        return result
    }
    func testCapabilityVersionAndReceiptUpgrade() throws {
        let v1 = try binding(1), v2 = try binding(2)
        XCTAssertFalse(v1.includesWorkspaceStorage); XCTAssertTrue(v2.includesWorkspaceStorage); XCTAssertFalse(v2.allowsSave)
        XCTAssertThrowsError(try binding(3))
        func receipt(_ binding: GenericNappletBinding) throws -> GenericNappletReceipt {
            try GenericNappletReceipt(baseURL: "https://example.test", app: "app", workspace: Fixtures.workspaceId, viewer: "viewer", file: Fixtures.workspaceId, digest: String(repeating: "a", count: 64), binding: binding, canWrite: false)
        }
        let a = try receipt(v1), b = try receipt(v2)
        XCTAssertEqual(a.key, b.key); XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        let trust = GenericNappletTrustStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: trust.directory) }
        try trust.remember(a); XCTAssertFalse(trust.contains(b)); try trust.remember(b); try trust.forget(b); XCTAssertFalse(trust.contains(b))
    }
    func testApprovedBindingOwnsOptInAndForbiddenMapping() async throws {
        let f = FileNappletFixture(); f.reportMode = true; f.genericSharedCode = true
        let api = try await FileNappletTransportTests().api(f)
        for version in [1, 2] {
            let b = try binding(version)
            f.codeOverride = "<script id=\"wingman-napplet-manifest\">" + String(decoding: b.manifest, as: UTF8.self) + "</script>"
            f.genericMetadata = ["html_artifact": true, "artefact": ["schema_version": 1, "type": "html", "format_version": 1, "editor_id": "builtin.html"], "napplet": ["version": 2, "app_id": b.appId, "bindings": ["summary": ["workspace_id": Fixtures.workspaceId]]]]
            let code = try await api.genericNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
            var payload = WorkspaceReportTests().fixture()
            let identity = ["workspace_id": Fixtures.workspaceId, "app_npub": Fixtures.appNpub]
            payload["identity"] = identity; payload["workspace_id"] = Fixtures.workspaceId
            if version == 2 {
                var storage = try fixture("workspace-storage-v1"); storage["workspace_id"] = Fixtures.workspaceId; storage["as_of"] = payload["as_of"]; payload["storage"] = storage
            }
            f.reportPayload = payload; f.reportStatus = 200
            _ = try await api.readGenericAggregate(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId, expected: code, range: "30d", identity: identity)
            let request = try XCTUnwrap(f.reportRequests.last)
            XCTAssertEqual(request.url?.path, "/api/v4/flightdeck-pg/workspaces/" + Fixtures.workspaceId + "/workspace-report")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "storage" }?.value, version == 2 ? "workspace" : nil)
            f.reportStatus = 403
            do { _ = try await api.readGenericAggregate(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, fileId: f.codeId, expected: code, range: "30d", identity: identity); XCTFail("denial accepted") }
            catch { if version == 2 { guard case FileNappletError.forbidden = error else { return XCTFail("expected forbidden: \(error)") } } else { guard case TowerError.http = error else { return XCTFail("legacy mapping changed") } } }
        }
        XCTAssertEqual(f.posts, 0)
    }
}
