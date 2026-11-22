import Foundation
import Testing
@testable import AmbulandoCore

@Suite struct TrackerDocumentTests {
    let metric = "00000000-0000-4000-8000-000000000001"
    func model(type: String = "number", value: Any? = nil, date: String = "2024-02-29") throws -> Data {
        var days: [String: Any] = [:]
        if let value { days[date] = [metric: value] }
        return try rawJSON(["format": "daily-tracker-v1", "metrics": [["id": metric, "label": "Custom metric", "type": type, "unit": "", "archived": false]], "days": days])
    }
    @Test func falseZeroAndUnansweredRemainDistinct() throws {
        for bytes in [try model(type: "boolean", value: false), try model(value: 0), try model()] { try TrackerDocument.validate(bytes) }
        #expect(try model(type: "boolean", value: false) != model())
        #expect(throws: (any Error).self) { try TrackerDocument.validate(model(type: "boolean", value: 0)) }
        #expect(throws: (any Error).self) { try TrackerDocument.validate(model(value: false)) }
        #expect(throws: (any Error).self) { try TrackerDocument.validate(model(value: NSNull())) }
    }
    @Test func calendarDatesDoNotConvertThroughUTC() throws {
        for date in ["2024-02-29", "2026-01-01", "2000-02-29", "2026-12-31"] { try TrackerDocument.validate(model(value: 0, date: date)) }
        for date in ["2026-02-29", "1900-02-29", "2026-04-31", "2026-1-01", "0000-01-01", "2026-01-01T00:00:00Z", "2026-01-01\n"] {
            #expect(throws: (any Error).self) { try TrackerDocument.validate(model(value: 0, date: date)) }
        }
    }
    @Test func usedTypeCannotChangeAndHistoryCanBeEdited() throws {
        let previous = try model(value: 12)
        try TrackerDocument.validate(model(value: 0), previous: previous)
        #expect(throws: (any Error).self) { try TrackerDocument.validate(model(type: "boolean", value: false), previous: previous) }
        var object = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
        object["metrics"] = []
        object["days"] = [:]
        #expect(throws: (any Error).self) { try TrackerDocument.validate(rawJSON(object), previous: previous) }
        object = try JSONSerialization.jsonObject(with: previous) as! [String: Any]
        object["extra"] = true
        #expect(throws: (any Error).self) { try TrackerDocument.validate(rawJSON(object)) }
        #expect(throws: (any Error).self) { try TrackerDocument.validate(Data(repeating: 32, count: TrackerDocument.maxBytes + 1)) }
    }
    @Test func exactEnvelopeRejectsAuthorityAndNonceInjection() throws {
        let valid: [String: Any] = ["type": "wingman-napplet-data", "version": 1, "session": "nonce", "requestId": "one_1", "operation": "read", "binding": "tracker"]
        #expect(try FileNappletRequest.parse(rawJSON(valid), session: "nonce").operation == "read")
        for (key, value): (String, Any) in [("session", "other"), ("version", true), ("binding", "other"), ("requestId", "a/b"), ("requestId", "one\n"), ("operation", "sign"), ("url", "https://example.com"), ("workspace", Fixtures.workspaceId)] {
            var changed = valid; changed[key] = value
            #expect(throws: (any Error).self) { try FileNappletRequest.parse(rawJSON(changed), session: "nonce") }
        }
        var save = valid; save["operation"] = "save"; save["baseVersionId"] = metric
        save["value"] = try JSONSerialization.jsonObject(with: model(value: 0))
        #expect(try FileNappletRequest.parse(rawJSON(save), session: "nonce").base == metric)
    }
    @Test func canonicalLabelUnitAndUUIDParity() throws {
        let original = try JSONSerialization.jsonObject(with: model()) as! [String: Any]
        for (field, text) in [("label", "   "), ("label", "a\u{7f}"), ("unit", "kg\n"), ("label", String(repeating: "😀", count: 61)), ("unit", String(repeating: "😀", count: 13))] {
            var object = original; var metrics = object["metrics"] as! [[String: Any]]
            metrics[0][field] = text; object["metrics"] = metrics
            #expect(throws: (any Error).self) { try TrackerDocument.validate(rawJSON(object)) }
        }
        var object = original; var metrics = object["metrics"] as! [[String: Any]]
        let upper = "ABCDEF00-0000-4000-8000-000000000001"
        metrics[0]["id"] = upper; object["metrics"] = metrics
        object["days"] = ["2026-01-01": [upper: 0]]
        try TrackerDocument.validate(rawJSON(object))
        object["days"] = ["2026-01-01": [upper.lowercased(): 0]]
        #expect(throws: (any Error).self) { try TrackerDocument.validate(rawJSON(object)) }
    }
    @Test func metadataAndManifestMustAgree() throws {
        let fixture = FileNappletFixture()
        #expect(try FileNappletBinding.parse(html: fixture.html, metadata: rawJSON(fixture.metadata))?.dataFileId == fixture.dataId)
        #expect(try FileNappletBinding.parse(html: fixture.html, metadata: Data("{}".utf8)) == nil)
        for html in [fixture.html + fixture.html, fixture.html.replacingOccurrences(of: "daily-tracker-v1", with: "other"), fixture.html.replacingOccurrences(of: "application/json", with: "text/javascript")] {
            #expect(throws: (any Error).self) { try FileNappletBinding.parse(html: html, metadata: rawJSON(fixture.metadata)) }
        }
    }
}

/// In-process signed-transport fixture. Never writes human records or uses a network endpoint.
final class FileNappletFixture: @unchecked Sendable {
    let codeId = "00000000-0000-4000-8000-000000000010"
    let dataId = "00000000-0000-4000-8000-000000000011"
    let channelId = "00000000-0000-4000-8000-000000000012"
    var codeVersion = "00000000-0000-4000-8000-000000000013"
    let objectId = "00000000-0000-4000-8000-000000000014"
    let lock = NSLock()
    var bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[],\"days\":{}}".utf8)
    var revision = 1
    var participants = [TestKeys.npub]
    var reportMode = false
    var reportPayload: [String: Any] = [:]
    var reportRequests: [URLRequest] = []
    var denied = false
    var writable = true
    var topLevelWritable: Any?
    var corrupt = false
    var wrongMIME = false
    var wrongHead = false
    var channelKind = "dm"
    var channelWorkspace = Fixtures.workspaceId
    var codeOverride: String?
    var codeWritable = true
    var bindingOverride: String?
    var changeOnUpload = ""
    var acknowledgedWrongVersion = false
    var publishedCodeBases: [String] = []
    var codePrefix = ""
    var codeSuffix = ""
    var uploaded: Data?
    var completed = false
    var race = false
    var lostResponse = false
    var uncommittedResponseLost = false
    var posts = 0
    var discoveryCount = 0
    var discoveryPartial = false
    var discoveryInvalid = false
    var createdFiles: [(String, Data, [String: Any])] = []
    var metadata: [String: Any] {
        if reportMode { return ["html_artifact": true, "artefact": ["schema_version": 1, "type": "html", "format_version": 1, "editor_id": "builtin.html"], "napplet": ["version": 1, "app_id": "workspace-report", "bindings": ["report": ["workspace_id": bindingOverride ?? Fixtures.workspaceId]]]] }
        return ["html_artifact": true, "artefact": ["schema_version": 1, "type": "html", "format_version": 1, "editor_id": "builtin.html"],
         "napplet": ["version": 1, "app_id": "daily-tracker", "bindings": ["tracker": ["file_id": bindingOverride ?? dataId]]]]
    }
    var html: String { codeOverride ?? (codePrefix + "<script type=\"application/json\" id=\"wingman-napplet-manifest\">{\"version\":1,\"app_id\":\"daily-tracker\",\"bindings\":{\"tracker\":{\"format\":\"daily-tracker-v1\",\"operations\":[\"read\",\"save\"],\"privacy\":\"self\"}}}</script>" + codeSuffix) }
    var version: String { "00000000-0000-4000-8000-" + String(format: "%012d", revision) }
    func route(_ request: URLRequest) throws -> (Int, Any) {
        try lock.withLock { () throws -> (Int, Any) in
            _ = try decodeAuthorization(request)
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            if denied { return (403, ["code": "permission_denied"]) }
            if reportMode, path.hasSuffix("/me") { return (200, ["identity": ["workspace_id": Fixtures.workspaceId, "app_npub": Fixtures.appNpub]]) }
            if reportMode, path.hasSuffix("/workspace-report") { reportRequests.append(request); return (200, reportPayload) }
            if path.hasSuffix("/scopes") {
                return (200, ["scopes": [["id": Fixtures.scopeA, "workspace_id": Fixtures.workspaceId, "name": "DMs", "kind": "dm"]]])
            }
            if path.hasSuffix("/channels"), method == "GET" {
                return (200, ["channels": [["id": channelId, "workspace_id": Fixtures.workspaceId, "scope_id": Fixtures.scopeA,
                    "name": "Self", "kind": "dm", "participant_npubs": participants]], "next_cursor": NSNull()])
            }
            if path.hasSuffix("/files"), method == "GET" {
                let candidateMetadata: [String: Any] = discoveryInvalid ? ["napplet": ["app_id": "daily-tracker"]] : metadata
                let rows: [[String: Any]] = (0..<discoveryCount).map { index -> [String: Any] in
                    ["id": index == 0 ? codeId : "00000000-0000-4000-8000-000000000099", "workspace_id": Fixtures.workspaceId,
                     "channel_id": channelId, "display_name": "Renamed private tracker", "record_state": "active",
                     "metadata": candidateMetadata]
                }
                return (200, ["files": rows, "partial": discoveryPartial])
            }
            if path.hasSuffix("/files"), method == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let name = body["display_name"] as! String, metadata = body["metadata"] as! [String: Any]
                createdFiles.append((name, uploaded!, metadata))
                if name.hasSuffix(".html") { discoveryCount = 1 }
                return (200, ["file": ["id": name.hasSuffix(".html") ? codeId : dataId, "workspace_id": Fixtures.workspaceId,
                    "channel_id": channelId, "scope_id": Fixtures.scopeA, "display_name": name, "metadata": metadata]])
            }
            if path.hasSuffix("/files/" + codeId) || path.hasSuffix("/files/" + dataId) || path.hasSuffix("/files/00000000-0000-4000-8000-000000000099") {
                let isCode = !path.hasSuffix(dataId)
                let codeMetadata: [String: Any] = discoveryInvalid ? ["napplet": ["app_id": "daily-tracker"]] : metadata
                var response: [String: Any] = ["file": ["id": path.components(separatedBy: "/").last!, "workspace_id": Fixtures.workspaceId,
                    "channel_id": channelId, "can_write": isCode ? codeWritable : writable, "record_state": "active", "metadata": isCode ? codeMetadata : [:],
                    "current_version_id": isCode ? codeVersion : version, "current_version": NSNull()]]
                if let topLevelWritable { response["can_write"] = topLevelWritable }
                return (200, response)
            }
            if path.hasSuffix("/versions"), method == "GET" {
                let isCode = !path.contains(dataId), data = isCode ? Data(html.utf8) : bytes
                let current = isCode ? codeVersion : version
                return (200, ["file_id": path.components(separatedBy: "/").dropLast().last!, "current_version_id": current,
                    "versions": [["id": wrongHead ? objectId : current, "content_type": isCode ? "text/html" : "application/json", "size_bytes": data.count, "sha256_hex": SHA256Hex.of(data)]]])
            }
            if path.hasSuffix("/object") { return (200, !path.contains(dataId) ? Data(html.utf8) : corrupt ? Data("corrupt".utf8) : bytes) }
            if path.hasSuffix("/channels/" + channelId) {
                return (200, ["channel": ["id": channelId, "workspace_id": channelWorkspace, "kind": channelKind, "participant_npubs": participants]])
            }
            if path.hasSuffix("/storage/prepare") { uploaded = nil; completed = false; return (200, ["object_id": objectId, "upload_url": "https://tower.example/api/v4/storage/" + objectId]) }
            if path.hasSuffix("/storage/" + objectId), method == "PUT" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                uploaded = Data(base64Encoded: body["base64_data"] as! String); return (200, [:])
            }
            if path.hasSuffix("/complete") {
                if changeOnUpload == "binding" { bindingOverride = objectId }
                if changeOnUpload == "permission" { codeWritable = false }
                if changeOnUpload == "code" { codeVersion = objectId }
                completed = true; return (200, ["completed_at": "now"]) }
            if path.hasSuffix("/storage/" + objectId) {
                var row: [String: Any] = ["id": objectId, "is_public": false, "size_bytes": uploaded?.count ?? 0, "sha256_hex": SHA256Hex.of(uploaded ?? Data())]
                if completed { row["completed_at"] = "now" }
                return (200, row)
            }
            if path.hasSuffix("/versions"), method == "POST" {
                posts += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if path.contains(codeId) {
                    publishedCodeBases.append(body["base_version_id"] as! String)
                    if uncommittedResponseLost { throw URLError(.networkConnectionLost) }
                    if race { codeVersion = objectId }
                    guard body["base_version_id"] as? String == codeVersion else { return (409, ["code": "stale_base_version"]) }
                    codeOverride = String(data: uploaded!, encoding: .utf8)!; codeVersion = "00000000-0000-4000-8000-000000000015"
                    if lostResponse { throw URLError(.networkConnectionLost) }
                    return (200, ["version": ["id": acknowledgedWrongVersion ? objectId : codeVersion]])
                }
                if race { revision += 1 }
                guard body["base_version_id"] as? String == version else { return (409, ["code": "stale_base_version"]) }
                bytes = uploaded!; revision += 1
                if lostResponse { throw URLError(.networkConnectionLost) }
                return (200, ["version": ["id": version]])
            }
            throw TowerError.malformed(path)
        }
    }
}

@Suite struct FileNappletTransportTests {
    func api(_ fixture: FileNappletFixture) async throws -> TowerAPI {
        TowerAPI(client: TowerClient(origin: try TowerOrigin("https://tower.example"), transport: NappletFixtureTransport(fixture: fixture), signer: try await makeIdentity()))
    }
    func originalTemplate() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Ambulando/Fixture/daily-tracker-original-v1.html"), encoding: .utf8)
    }
    @Test func codeOnlyUpdatePreservesBindingDataHistoryAndRequiresNewConsent() async throws {
        for lost in [false, true] {
            let f = FileNappletFixture(), api = try await api(f)
            f.codeOverride = try originalTemplate()
            f.bytes = Data("{\"format\":\"daily-tracker-v1\",\"metrics\":[{\"id\":\"00000000-0000-4000-8000-000000000020\",\"label\":\"Synthetic\",\"type\":\"boolean\",\"unit\":\"\",\"archived\":true}],\"days\":{\"2024-02-29\":{\"00000000-0000-4000-8000-000000000020\":false}}}".utf8)
            let beforeBytes = f.bytes, beforeVersion = f.version, metadata = try rawJSON(f.metadata)
            let old = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
            #expect(DailyTrackerUpdate.recognizes(old))
            let replacement = Data((old.html + "<!-- synthetic update -->").utf8)
            f.lostResponse = lost
            let updated = try await api.updateDailyTracker(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: old, template: replacement)
            #expect(updated.sha256 == SHA256Hex.of(replacement)); #expect(updated.binding == old.binding)
            #expect(!DailyTrackerUpdate.recognizes(updated)); #expect(updated.versionId != old.versionId)
            #expect(f.bytes == beforeBytes); #expect(f.version == beforeVersion)
            let currentMetadata = try JSONSerialization.jsonObject(with: rawJSON(f.metadata)) as! NSDictionary
            #expect(currentMetadata == (try JSONSerialization.jsonObject(with: metadata) as! NSDictionary))
            #expect(f.publishedCodeBases == [old.versionId]); #expect(f.posts == 1); #expect(f.createdFiles.isEmpty)
            let connection = try ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
            let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))
            #expect(try FileNappletTrustReceipt(connection: connection, workspace: workspace, codeFile: f.codeId, code: old, canWrite: true) != FileNappletTrustReceipt(connection: connection, workspace: workspace, codeFile: f.codeId, code: updated, canWrite: true))
        }
    }
    @Test func codeUpdateRejectsUnknownDeniedChangedBindingStaleCASAndWrongAcknowledgement() async throws {
        for mode in 0..<11 {
            let f = FileNappletFixture(), api = try await api(f)
            f.codeOverride = try originalTemplate()
            if mode == 0 { f.codeOverride! += "<!-- customized -->" }
            let old = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
            let originalBytes = f.bytes, originalVersion = f.version
            if mode == 1 { f.codeWritable = false }
            if mode == 2 { f.participants = [] }
            if mode == 3 { f.denied = true }
            if mode == 4 { f.changeOnUpload = "binding" }
            if mode == 5 { f.changeOnUpload = "permission" }
            if mode == 6 { f.changeOnUpload = "code" }
            if mode == 7 { f.race = true }
            if mode == 8 { f.acknowledgedWrongVersion = true }
            if mode == 9 { f.codeVersion = f.objectId }
            if mode == 10 { f.uncommittedResponseLost = true }
            await #expect(throws: (any Error).self) {
                try await api.updateDailyTracker(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: old, template: Data((old.html + "<!-- synthetic update -->").utf8))
            }
            #expect(f.bytes == originalBytes); #expect(f.version == originalVersion)
            #expect(f.posts == ((mode == 7 || mode == 8 || mode == 10) ? 1 : 0))
            #expect(f.createdFiles.isEmpty)
        }
    }
    @Test func appsDiscoveryReusesMetadataAndNeverCreatesFiles() async throws {
        let f = FileNappletFixture(), api = try await api(f)
        #expect(try await api.dailyTrackers(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub).isEmpty)
        f.discoveryCount = 1
        for _ in 0..<2 {
            let rows = try await api.dailyTrackers(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub)
            #expect(rows.map(\.id) == [f.codeId])
        }
        f.discoveryCount = 2
        #expect(try await api.dailyTrackers(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub).count == 2)
        #expect(f.createdFiles.isEmpty)
    }
    @Test func appsDiscoveryRejectsPartialInvalidDeniedAndWrongViewer() async throws {
        for mode in 0..<6 {
            let f = FileNappletFixture(), api = try await api(f)
            f.discoveryCount = 1
            if mode == 0 { f.discoveryPartial = true }
            if mode == 1 { f.discoveryInvalid = true }
            if mode == 2 { f.denied = true }
            if mode == 3 { f.corrupt = true }
            if mode == 4 { f.channelWorkspace = Fixtures.scopeA }
            if mode == 5 { f.discoveryCount = 200 }
            await #expect(throws: (any Error).self) { try await api.dailyTrackers(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub) }
            #expect(f.createdFiles.isEmpty)
        }
        let f = FileNappletFixture(), api = try await api(f)
        f.discoveryCount = 1
        #expect(try await api.dailyTrackers(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: Bech32.encode(hrp: "npub", data: Data(repeating: 0x42, count: 32))).isEmpty)
    }
    @Test func workspaceReportSetupCreatesOnlyCodeAndDiscoveryIsComplete() async throws {
        let f = FileNappletFixture(), work = try await WorkHarness.make()
        f.reportMode = true
        f.codeOverride = "<script type=\"application/json\" id=\"wingman-napplet-manifest\">{\"version\":1,\"app_id\":\"workspace-report\",\"bindings\":{\"report\":{\"format\":\"workspace-report-v1\",\"operations\":[\"read\"],\"privacy\":\"viewer\"}}}</script>"
        let sync = WorkspaceSync(store: work.store, engine: work.engine, identity: work.chat.identity, transport: NappletFixtureTransport(fixture: f))
        #expect(try await sync.workspaceReports(work.connection, work.workspace).isEmpty)
        let file = try await sync.createWorkspaceReport(work.connection, work.workspace, template: Data(f.html.utf8))
        #expect(f.createdFiles.count == 1)
        #expect(f.createdFiles[0].0 == "Workspace Report.html")
        #expect(f.createdFiles[0].1 == Data(f.html.utf8))
        #expect(try WorkspaceReportBinding.parse(html: f.html, metadata: rawJSON(f.createdFiles[0].2)).workspaceId == work.workspace.id)
        #expect(try await sync.workspaceReports(work.connection, work.workspace).map(\.id) == [file.id])
        f.discoveryCount = 2
        #expect(try await sync.workspaceReports(work.connection, work.workspace).count == 2)
        f.discoveryPartial = true
        await #expect(throws: (any Error).self) { try await sync.workspaceReports(work.connection, work.workspace) }
        #expect(f.createdFiles.count == 1)
        #expect(try await work.store.reader.file(workspaceId: work.workspace.id, id: f.dataId) == nil)
    }
    @Test func explicitCreationUploadsOnlyEmptyDataToSelfDM() async throws {
        let f = FileNappletFixture(), work = try await WorkHarness.make()
        let sync = WorkspaceSync(store: work.store, engine: work.engine, identity: work.chat.identity, transport: NappletFixtureTransport(fixture: f))
        let file = try await sync.createDailyTracker(work.connection, work.workspace, template: Data(f.html.utf8))
        #expect(file.channelId == f.channelId)
        #expect(f.createdFiles.count == 2)
        let empty = try JSONSerialization.jsonObject(with: f.createdFiles[0].1) as! [String: Any]
        #expect((empty["metrics"] as? [Any])?.isEmpty == true)
        #expect((empty["days"] as? [String: Any])?.isEmpty == true)
        #expect(f.createdFiles[1].1 == Data(f.html.utf8))
        #expect(try FileNappletBinding.parse(html: f.html, metadata: rawJSON(f.createdFiles[1].2))?.dataFileId == f.dataId)
        let localCode = try await work.store.reader.file(workspaceId: work.workspace.id, id: file.id)
        #expect(localCode != nil)
        #expect(try await work.store.reader.file(workspaceId: work.workspace.id, id: f.dataId) == nil)
    }
    @Test func firstSetupIsAdoptedAcrossFreshResolversWithoutMoreFiles() async throws {
        let f = FileNappletFixture(), work = try await WorkHarness.make()
        let sync = WorkspaceSync(store: work.store, engine: work.engine, identity: work.chat.identity, transport: NappletFixtureTransport(fixture: f))
        #expect(try await sync.dailyTrackers(work.connection, work.workspace).isEmpty)
        let file = try await sync.createDailyTracker(work.connection, work.workspace, template: Data(f.html.utf8))
        let originalBytes = f.bytes
        for _ in 0..<3 {
            let fresh = try await api(f)
            #expect(try await fresh.dailyTrackers(workspace: work.workspace.id, app: work.workspace.appNpub, viewer: work.connection.signerNpub).map(\.id) == [file.id])
        }
        #expect(f.createdFiles.count == 2)
        #expect(f.bytes == originalBytes)
    }
    @Test func explicitCurrentWriteDenialOverridesEmbeddedFileFlag() async throws {
        let f = FileNappletFixture(), api = try await api(f)
        let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
        f.topLevelWritable = false
        let access = try await api.readFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code)
        #expect(!access.canWrite)
        await #expect(throws: (any Error).self) { try await api.saveFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code, base: access.versionId, bytes: access.bytes) }
        #expect(f.posts == 0)
    }
    @Test func malformedPresentWriteAuthorityFailsClosed() async throws {
        for malformed: Any in [1, 0, "false", NSNull(), [String: Any]() ] {
            let f = FileNappletFixture(), api = try await api(f)
            let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
            f.topLevelWritable = malformed
            await #expect(throws: (any Error).self) {
                try await api.readFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code)
            }
            #expect(f.posts == 0)
        }
    }
    @Test func explicitWriteAuthorityWinsAndAbsentAuthorityUsesFileFallback() async throws {
        let f = FileNappletFixture(), api = try await api(f)
        let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
        f.writable = false; f.topLevelWritable = true
        let granted = try await api.readFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code)
        #expect(granted.canWrite)
        f.topLevelWritable = nil
        let fallback = try await api.readFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code)
        #expect(!fallback.canWrite)
    }
    @Test func consentDigestUsesExactVerifiedBytesIncludingUTF8BOM() async throws {
        let f = FileNappletFixture(), api = try await api(f)
        f.codePrefix = "\u{FEFF}"
        let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
        #expect(code.sha256 == SHA256Hex.of(Data(f.html.utf8)))
        let connection = try ConnectionRecord(origin: TowerOrigin("https://tower.example"), signerNpub: TestKeys.npub, towerNpub: nil)
        let workspace = try WorkspaceRecord(raw: Fixtures.json(Fixtures.workspace(Fixtures.workspaceId, label: "Studio")))
        let receipt = try FileNappletTrustReceipt(connection: connection, workspace: workspace, codeFile: f.codeId, code: code, canWrite: true)
        #expect(receipt.codeSHA256 == code.sha256)
    }
    @Test func reopenReadsSameVerifiedFileWithoutLocalStore() async throws {
        let f = FileNappletFixture(), api = try await api(f)
        let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
        for _ in 0..<2 {
            let result = try await api.readFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code)
            #expect(result.bytes == f.bytes); #expect(result.canWrite)
        }
    }
    @Test func deniedOrNonSelfDMOrCorruptBytesFailClosed() async throws {
        for mode in 0..<10 {
            let f = FileNappletFixture(), api = try await api(f)
            let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
            if mode == 0 { f.denied = true }
            if mode == 1 { f.participants.append("someone-else") }
            if mode == 2 { f.participants = [] }
            if mode == 3 { f.corrupt = true }
            if mode == 4 { f.wrongMIME = true }
            if mode == 5 { f.wrongHead = true }
            if mode == 6 { f.channelKind = "channel" }
            if mode == 7 { f.channelWorkspace = Fixtures.workspaceId2 }
            if mode == 8 { f.codeSuffix = "<!-- new code -->" }
            if mode == 9 { f.bytes = Data("{}".utf8) }
            await #expect(throws: (any Error).self) { try await api.readFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code) }
        }
    }
    @Test func saveCASAndUncertainResponseAreReadBack() async throws {
        for lost in [false, true] {
            let f = FileNappletFixture(), api = try await api(f)
            let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
            let original = f.version
            let changed = try rawJSON(["format": "daily-tracker-v1", "metrics": [], "days": ["2026-11-22": [:]]])
            f.lostResponse = lost
            let saved = try await api.saveFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code, base: original, bytes: changed)
            #expect(saved.bytes == changed); #expect(saved.versionId != original); #expect(f.posts == 1)
        }
    }
    @Test func concurrentSaveAndReadOnlyNeverOverwrite() async throws {
        for readonly in [false, true] {
            let f = FileNappletFixture(), api = try await api(f)
            let code = try await api.fileNappletCode(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, fileId: f.codeId)
            f.race = true; f.writable = !readonly
            let original = f.bytes
            await #expect(throws: (any Error).self) { try await api.saveFileNapplet(workspace: Fixtures.workspaceId, app: Fixtures.appNpub, viewer: TestKeys.npub, codeFile: f.codeId, expected: code, base: f.version, bytes: f.bytes) }
            #expect(f.bytes == original); #expect(f.posts == (readonly ? 0 : 1))
        }
    }
}

private struct NappletFixtureTransport: HTTPTransport {
    let fixture: FileNappletFixture
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = try fixture.route(request)
        let bytes = try (body as? Data) ?? JSONSerialization.data(withJSONObject: body)
        let type = fixture.wrongMIME ? "text/plain" : request.url!.path.hasSuffix("/object") && !request.url!.path.contains(fixture.dataId) ? "text/html" : "application/json"
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!)
    }
}
