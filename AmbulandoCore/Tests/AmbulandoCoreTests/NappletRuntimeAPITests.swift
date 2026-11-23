import Foundation
import Testing
@testable import AmbulandoCore

final class RuntimeAPIFixture: @unchecked Sendable {
    let lock = NSLock()
    var rows: [String:Any]
    var requests: [URLRequest] = []
    var html: String
    var deny = false
    var corrupt = false
    var foreign = false
    var writes = 0
    var removed = false
    var revision = 1
    let context = NappletRuntimeContext(origin:"https://tower.example",tower:TestKeys.npub,service:TestKeys.npub,workspace:Fixtures.workspaceId,app:Fixtures.appNpub,viewer:TestKeys.npub)
    init() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/napplet-runtime-v3/")
        let raw = String(decoding:try Data(contentsOf:root.appendingPathComponent("api.json")),as:UTF8.self)
            .replacingOccurrences(of:"2e5caefd-dd65-45d2-b747-ee874e8e5fc9",with:Fixtures.workspaceId)
            .replacingOccurrences(of:"<workspace app npub>",with:Fixtures.appNpub)
            .replacingOccurrences(of:"<requester npub>",with:TestKeys.npub)
            .replacingOccurrences(of:"<authenticated publisher npub>",with:TestKeys.npub)
        rows = try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
        html = "<script id='wingman-napplet-manifest' type='application/json'>" + String(decoding:try Data(contentsOf:root.appendingPathComponent("manifest.json")),as:UTF8.self) + "</script><p>Arbitrary payload</p>"
    }
    func installation() throws -> [String:Any] {
        var item = (rows["installation"] as! [String:Any])["installation"] as! [String:Any]
        item["removed"] = removed; item["revision"] = revision
        item["workspace_id"] = foreign ? Fixtures.scopeA : Fixtures.workspaceId
        var bundle = item["bundle"] as! [String:Any]; bundle["sha256_hex"] = SHA256Hex.of(Data(html.utf8)); item["bundle"] = bundle
        return item
    }
    func route(_ r: URLRequest) throws -> (Data,HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }; requests.append(r)
        let url = r.url!, path = url.path, method = r.httpMethod ?? "GET"
        var status = 200, value: Any = ["error":"unexpected"]
        var mime = "application/json"
        if deny { status = 403; value = ["code":"denied","error":"Denied"] }
        else if path.hasSuffix("/bundle") { mime = "application/octet-stream"; value = Data((html + (corrupt ? "corrupt" : "")).utf8) }
        else if path.hasSuffix("/napplets") { value = ["installations":[try installation()],"next_cursor":NSNull()] }
        else if path.hasSuffix("/field-notes") {
            if method == "PUT" {
                let body = try GenericJSON.decode(r.httpBody!)
                if !removed || body["expected_revision"] as? Int != revision { status = 409; value = ["error":"Conflict"] }
                else { removed = false; revision += 1; value = ["installation":try installation()] }
            } else { value = ["installation":try installation()] }
        }
        else if path.hasSuffix("/collections") { value = rows["collections"]! }
        else if path.hasSuffix("/records") { value = rows["records"]! }
        else if path.contains("/records/") {
            if method == "PUT" {
                writes += 1
                let body = try JSONSerialization.jsonObject(with:r.httpBody!) as! [String:Any]
                if body["expected_revision"] as? Int != 1 { status = 409; value = ["code":"conflict","error":"Conflict"] }
                else { var result = rows["record"] as! [String:Any]; var record = result["record"] as! [String:Any]; record["revision"] = 2; record["data"] = body["data"]; result["record"] = record; value = result }
            } else { value = rows["record"]! }
        }
        let data = try (value as? Data) ?? JSONSerialization.data(withJSONObject:value)
        return (data,HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":mime])!)
    }
}
struct RuntimeAPITransport: HTTPTransport {
    let fixture: RuntimeAPIFixture
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) { try fixture.route(request) }
}
@Suite struct NappletRuntimeAPITests {
    func api(_ f: RuntimeAPIFixture) async throws -> TowerAPI { TowerAPI(client:TowerClient(origin:try TowerOrigin(f.context.origin),transport:RuntimeAPITransport(fixture:f),signer:try await makeIdentity())) }
    func request(_ manifest: NappletRuntimeManifest, op: String, revision: Int = 1) throws -> NappletRuntimeRequest {
        var o: [String:Any] = ["type":"wingman-napplet-data","version":3,"session":String(repeating:"a",count:32),"requestId":"one","operation":op,"collection":"entries"]
        if op == "list" { o["limit"] = 2; o["cursor"] = NSNull() }
        else { o["record_id"] = "entry_1" }
        if ["create","update"].contains(op) { o["base_revision"] = revision; o["value"] = ["zero":0,"false":false,"nested":["arbitrary":true]] }
        return try .parse(JSONSerialization.data(withJSONObject:o),session:String(repeating:"a",count:32),manifest:manifest)
    }
    @Test func authenticatedImmutableCodeAndBoundedRecordCAS() async throws {
        let f = try RuntimeAPIFixture(), api = try await api(f)
        let installs = try await api.runtimeInstallations(f.context); #expect(installs.count == 1)
        let code = try await api.runtimeCode(f.context,id:"field-notes")
        #expect(code.html == f.html)
        let list = try await api.runtimeCommand(f.context,installation:code.installation,request:request(code.installation.manifest,op:"list"))
        #expect(try GenericJSON.decode(list)["next_cursor"] is NSNull)
        let saved = try await api.runtimeCommand(f.context,installation:code.installation,request:request(code.installation.manifest,op:"update"))
        #expect((try GenericJSON.decode(saved)["record"] as? [String:Any])?["revision"] as? Int == 2)
        await #expect(throws:(any Error).self) { try await api.runtimeCommand(f.context,installation:code.installation,request:request(code.installation.manifest,op:"update",revision:8)) }
        #expect(f.writes == 2)
        for r in f.requests { #expect(r.value(forHTTPHeaderField:"Authorization")?.hasPrefix("Nostr ") == true); #expect(r.url?.host == "tower.example") }
        let put = f.requests.first { $0.httpMethod == "PUT" }!
        let body = try GenericJSON.decode(put.httpBody!); #expect(body["base_revision"] == nil); #expect(body["expected_revision"] as? Int == 1)
    }
    @Test func corruptedForeignAndRevokedAuthorityFailClosed() async throws {
        for mode in 0..<3 {
            let f = try RuntimeAPIFixture(), api = try await api(f)
            if mode == 0 { f.corrupt = true }; if mode == 1 { f.foreign = true }; if mode == 2 { f.deny = true }
            await #expect(throws:(any Error).self) { try await api.runtimeCode(f.context,id:"field-notes") }
            #expect(f.writes == 0)
        }
    }
    @Test func freshDeviceReconnectUsesAuthoritativeRemovedRevisionAndRetainsRecords() async throws {
        let f = try RuntimeAPIFixture(); f.removed = true; f.revision = 7
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let identity = try await makeIdentity(), store = try LocalStore(directory:directory)
        let sync = WorkspaceSync(store:store,engine:SyncEngine(),identity:identity,transport:RuntimeAPITransport(fixture:f))
        let connection = ConnectionRecord(origin:try TowerOrigin(f.context.origin),signerNpub:TestKeys.npub,towerNpub:TestKeys.npub)
        let workspace = try WorkspaceRecord(raw:GenericJSON.canonical(["identity":["workspace_id":f.context.workspace,"app_npub":f.context.app,"tower_service_npub":f.context.tower,"workspace_service_npub":f.context.service]]))
        let recordBefore = try GenericJSON.canonical(f.rows["record"]!)
        try await sync.reconnectRuntimeApp(connection,workspace,id:"field-notes")
        #expect(!f.removed && f.revision == 8 && f.writes == 0)
        let put = f.requests.first { $0.httpMethod == "PUT" }!
        #expect(try GenericJSON.decode(put.httpBody!)["expected_revision"] as? Int == 7)
        #expect(try GenericJSON.canonical(f.rows["record"]!) == recordBefore)
        let apps = try await store.reader.runtimeApps(connection:connection,workspace:workspace,context:f.context)
        #expect(apps.count == 1 && apps[0].revision == 8)
    }
    @Test func removedMetadataCannotOpenAndRequiresExplicitReconnectParsing() throws {
        let f = try RuntimeAPIFixture(); var row = try f.installation(); row["removed"] = true; row["revision"] = 7
        #expect(throws:(any Error).self) { try RuntimeInstallation.parse(row,context:f.context) }
        let metadata = try RuntimeInstallation.parse(row,context:f.context,allowRemoved:true)
        #expect(metadata.removed && metadata.revision == 7)
        row["workspace_id"] = Fixtures.scopeA
        #expect(throws:(any Error).self) { try RuntimeInstallation.parse(row,context:f.context,allowRemoved:true) }
    }
    @Test func trustReceiptsBindIdentityPublisherAndAccess() throws {
        let f = try RuntimeAPIFixture(), installation = try RuntimeInstallation.parse(f.installation(),context:f.context)
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let trust = NappletRuntimeTrust(directory:directory)
        #expect(!trust.approved(context:f.context,publisher:installation.publisher,manifest:installation.manifest))
        try trust.remember(context:f.context,publisher:installation.publisher,manifest:installation.manifest)
        #expect(trust.approved(context:f.context,publisher:installation.publisher,manifest:installation.manifest))
        let other = NappletRuntimeContext(origin:f.context.origin,tower:f.context.tower,service:f.context.service,workspace:Fixtures.scopeA,app:f.context.app,viewer:f.context.viewer)
        #expect(!trust.approved(context:other,publisher:installation.publisher,manifest:installation.manifest))
        try trust.forget(context:f.context,publisher:installation.publisher,napplet:installation.id)
        #expect(!trust.approved(context:f.context,publisher:installation.publisher,manifest:installation.manifest))
    }
}

private final class RuntimeMigrationCapture: @unchecked Sendable {
    let lock = NSLock()
    var body: Data?
    func capture(_ data: Data?) { lock.withLock { body = data } }
}
private struct RuntimeMigrationTransport: HTTPTransport {
    let runtime: RuntimeAPIFixture
    let files: FileNappletFixture
    let capture: RuntimeMigrationCapture
    func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        if request.url!.path.contains("/files/") { return try await NappletFixtureTransport(fixture:files).send(request) }
        if request.url!.path.hasSuffix("/migrations") {
            capture.capture(request.httpBody)
            return (Data("{\"collection\":{}}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!)
        }
        return try runtime.route(request)
    }
}
extension NappletRuntimeAPITests {
    @Test func explicitImportPreservesWholeObjectScalarKeysAndOriginalFileHistory() async throws {
        let runtime = try RuntimeAPIFixture(), files = FileNappletFixture(), capture = RuntimeMigrationCapture()
        files.bytes = Data("{\"é\":false,\"é\":0,\"unanswered\":null}".utf8)
        let before = files.bytes, version = files.version
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let sync = WorkspaceSync(store:try LocalStore(directory:directory),engine:SyncEngine(),identity:try await makeIdentity(),transport:RuntimeMigrationTransport(runtime:runtime,files:files,capture:capture))
        let connection = ConnectionRecord(origin:try TowerOrigin(runtime.context.origin),signerNpub:TestKeys.npub,towerNpub:TestKeys.npub)
        let workspace = try WorkspaceRecord(raw:GenericJSON.canonical(["identity":["workspace_id":runtime.context.workspace,"app_npub":runtime.context.app,"tower_service_npub":runtime.context.tower,"workspace_service_npub":runtime.context.service]]))
        let installation = try RuntimeInstallation.parse(runtime.installation(),context:runtime.context)
        try await sync.runtimeManage(connection,workspace,installation:installation,action:.importFile(collection:"00000000-0000-4000-8000-000000000003",revision:1,schema:1,sourceFile:files.dataId,record:"legacy-copy"))
        let body = try #require(capture.body), tree = try GenericJSON.tree(body)
        guard let recordsNode = tree.member("records"), case .array(let records) = recordsNode, let value = records.first?.member("data") else { Issue.record("Missing imported record"); return }
        #expect(Data(value.encoded.utf8) == (try GenericJSON.canonicalData(before)))
        #expect(try GenericJSON.decode(body)["compatible"] as? Bool == true)
        #expect(files.bytes == before && files.version == version && files.posts == 0 && files.createdFiles.isEmpty)
    }
}
