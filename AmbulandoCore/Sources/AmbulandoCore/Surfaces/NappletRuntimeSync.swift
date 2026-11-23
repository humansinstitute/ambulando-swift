import Foundation

public enum RuntimeManagement: Sendable {
    case audience([String])
    case approveRelease
    case remove(deleteData: Bool)
    case createCollection(name: String)
    case collectionGrants(id: String, revision: Int, read: [String], write: [String])
    case importFile(collection: String, revision: Int, schema: Int, sourceFile: String, record: String)
}
extension WorkspaceSync {
    public static let runtimeRun = UUID().uuidString
    public static func runtimeKey(_ c: ConnectionRecord, _ w: WorkspaceRecord) -> String { "runtime-v3:\(c.id):\(w.id):\(c.signerNpub)" }
    public func runtimeContext(_ c: ConnectionRecord, _ w: WorkspaceRecord) throws -> NappletRuntimeContext {
        guard let root = try JSONSerialization.jsonObject(with:w.raw) as? [String:Any], let i = root["identity"] as? [String:String],
              i["workspace_id"] == w.id, i["app_npub"] == w.appNpub, i["tower_service_npub"] == c.towerNpub,
              let service = i["workspace_service_npub"], NostrKeys.isValidNpub(service), let tower = c.towerNpub, NostrKeys.isValidNpub(tower) else { throw FileNappletError.unavailable }
        return .init(origin:c.origin,tower:tower,service:service,workspace:w.id,app:w.appNpub,viewer:c.signerNpub)
    }
    public func refreshRuntimeApps(_ c: ConnectionRecord, _ w: WorkspaceRecord) async throws {
        let context = try runtimeContext(c,w), key = Self.runtimeKey(c,w)
        try await identity.requireReader(npub:c.signerNpub)
        do {
            let rows = try await api(origin:TowerOrigin(c.origin)).runtimeInstallations(context)
            try Task.checkCancellation()
            let list = "[" + rows.map { String(decoding:$0.raw,as:UTF8.self) }.joined(separator:",") + "]"
            try await store.writer.setState(key,Self.runtimeRun + "\n" + list)
        } catch { if !Task.isCancelled { try? await store.writer.setState(key,nil) }; throw error }
    }
    public func runtimeCode(_ c: ConnectionRecord, _ w: WorkspaceRecord, id: String) async throws -> RuntimeCode {
        try await identity.requireReader(npub:c.signerNpub)
        return try await api(origin:TowerOrigin(c.origin)).runtimeCode(runtimeContext(c,w),id:id)
    }
    public func runtimeAuthorize(_ c: ConnectionRecord, _ w: WorkspaceRecord, installation: RuntimeInstallation) async throws -> RuntimeInstallation {
        try await identity.requireReader(npub:c.signerNpub)
        let latest = try await api(origin:TowerOrigin(c.origin)).runtimeInstallation(runtimeContext(c,w),id:installation.id)
        guard latest.sameRelease(as:installation) else { throw FileNappletError.unavailable }; return latest
    }
    public func runtimeCommand(_ c: ConnectionRecord, _ w: WorkspaceRecord, installation: RuntimeInstallation, request: NappletRuntimeRequest, selections: [String:String] = [:]) async throws -> Data {
        if ["list","get"].contains(request.operation) { try await identity.requireReader(npub:c.signerNpub) }
        else { try await identity.requireSigner(npub:c.signerNpub) }
        let result = try await api(origin:TowerOrigin(c.origin)).runtimeCommand(runtimeContext(c,w),installation:installation,request:request,selections:selections)
        try Task.checkCancellation()
        // Commands return only the confirmed response. The local store owns the result projection.
        let key = Self.runtimeKey(c,w) + ":result:" + installation.id + ":" + (request.collection ?? "")
        try await store.writer.setState(key,Self.runtimeRun + "\n" + String(decoding:result,as:UTF8.self))
        guard let saved = try await store.reader.state(key), saved.hasPrefix(Self.runtimeRun + "\n") else { throw FileNappletError.unavailable }
        return Data(saved.dropFirst(Self.runtimeRun.count + 1).utf8)
    }
    public func runtimeCollections(_ c: ConnectionRecord, _ w: WorkspaceRecord, id: String) async throws -> Data {
        try await identity.requireReader(npub:c.signerNpub)
        let context = try runtimeContext(c,w), api = try api(origin:TowerOrigin(c.origin))
        let path = try TowerAPI.runtimeBase(context,id) + "/collections"
        // Management picker explicitly paginates rather than treating the first page as complete.
        var rows: [[String:Any]] = [], cursor: String?, seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name:"limit",value:"100")]; if let cursor { query.append(URLQueryItem(name:"after",value:cursor)) }
            let o = try GenericJSON.decode(try await api.client.request(path:path,query:query,appNpub:w.appNpub))
            guard let page = o["collections"] as? [[String:Any]], page.count <= 100 else { throw FileNappletError.invalid }
            for row in page {
                guard row["workspace_id"] as? String == w.id, row["app_npub"] as? String == w.appNpub, row["napplet_id"] as? String == id,
                      let key = row["id"] as? String, GenericJSON.uuid(key), seen.insert(key).inserted,
                      let name = row["name"] as? String, NappletRuntimeManifest.name(name),
                      let scope = row["scope"] as? String, ["personal","team"].contains(scope),
                      let owner = row["owner_npub"] as? String, NostrKeys.isValidNpub(owner),
                      let readers = row["read_npubs"] as? [String], readers.count <= 200, readers.allSatisfy(NostrKeys.isValidNpub),
                      let writers = row["write_npubs"] as? [String], writers.count <= 200, writers.allSatisfy(NostrKeys.isValidNpub),
                      NappletRuntimeManifest.positive(row["schema_version"]) != nil, NappletRuntimeManifest.positive(row["revision"]) != nil else { throw FileNappletError.invalid }
                rows.append(row)
            }
            if o["next_cursor"] is NSNull { cursor = nil }
            else { guard let next = o["next_cursor"] as? String, GenericJSON.uuid(next), next != cursor, page.last?["id"] as? String == next else { throw FileNappletError.invalid }; cursor = next }
            guard rows.count <= 2000 else { throw FileNappletError.invalid }
        } while cursor != nil
        return try GenericJSON.canonical(["collections":rows])
    }
    /// Reconnect uses authenticated lifecycle metadata from this device, never a guessed revision.
    public func reconnectRuntimeApp(_ c: ConnectionRecord, _ w: WorkspaceRecord, id: String) async throws {
        try await identity.requireSigner(npub:c.signerNpub)
        let context = try runtimeContext(c,w), api = try api(origin:TowerOrigin(c.origin))
        let removed = try await api.runtimeInstallation(context,id:id,includeRemoved:true)
        guard removed.removed else { throw FileNappletError.conflict }
        let body: [String:Any] = ["expected_revision":removed.revision,"requester_npub":removed.owner,"publisher_npub":removed.publisher,
                                 "display_name":removed.manifest.title,"bundle":["file_id":removed.bundle.file,"file_version_id":removed.bundle.version,"sha256_hex":removed.bundle.digest],
                                 "manifest":try GenericJSON.decode(removed.manifest.canonical)]
        let response = try GenericJSON.decode(try await api.client.request(method:"PUT",path:TowerAPI.runtimeBase(context,id),appNpub:w.appNpub,jsonBody:GenericJSON.canonical(body)))
        guard let row = response["installation"] as? [String:Any] else { throw FileNappletError.unavailable }
        let installed = try RuntimeInstallation.parse(row,context:context)
        guard installed.sameRelease(as:removed), installed.owner == removed.owner, installed.revision > removed.revision else { throw FileNappletError.unavailable }
        try Task.checkCancellation(); try await refreshRuntimeApps(c,w)
    }
    public func runtimeManage(_ c: ConnectionRecord, _ w: WorkspaceRecord, installation: RuntimeInstallation, action: RuntimeManagement) async throws {
        try await identity.requireSigner(npub:c.signerNpub)
        let context = try runtimeContext(c,w), api = try api(origin:TowerOrigin(c.origin))
        let current = try await api.runtimeInstallation(context,id:installation.id)
        guard current.revision == installation.revision, current.sameRelease(as:installation) else { throw FileNappletError.conflict }
        var path = try TowerAPI.runtimeBase(context,installation.id), method = "POST", body: [String:Any] = ["expected_revision":installation.revision]
        var exactBody: Data?
        switch action {
        case .audience(let npubs):
            guard npubs.count <= 200, npubs.allSatisfy(NostrKeys.isValidNpub) else { throw FileNappletError.invalid }
            method = "PATCH"; body["audience_npubs"] = Array(Set(npubs)).sorted()
        case .approveRelease: path += "/releases/approve"
        case .remove(let delete):
            method = "DELETE"; body["data"] = delete ? "delete" : "keep"
            if delete { body["confirm_napplet_id"] = installation.id }
        case .createCollection(let name):
            guard let declaration = installation.manifest.collections[name] else { throw FileNappletError.invalid }
            path += "/collections"
            body = ["name":name,"scope":declaration.scope,"schema_version":declaration.schema,"read_npubs":[],"write_npubs":[]]
        case .collectionGrants(let id,let revision,let read,let write):
            guard GenericJSON.uuid(id), revision > 0, read.count <= 200, write.count <= 200, (read + write).allSatisfy(NostrKeys.isValidNpub) else { throw FileNappletError.invalid }
            method = "PATCH"; path += "/collections/" + id
            body = ["expected_revision":revision,"read_npubs":Array(Set(read)).sorted(),"write_npubs":Array(Set(write)).sorted()]
        case .importFile(let collection,let revision,let schema,let sourceFile,let record):
            guard GenericJSON.uuid(collection), GenericJSON.uuid(sourceFile), revision > 0, schema > 0, NappletRuntimeRequest.recordID(record) else { throw FileNappletError.invalid }
            let source = try await api.nappletFile(workspace:w.id,app:w.appNpub,id:sourceFile)
            let (bytes,version) = try await api.nappletBytes(workspace:w.id,app:w.appNpub,file:source,mime:"application/json",limit:256 * 1024)
            let value = try GenericJSON.canonicalData(bytes)
            path += "/collections/" + collection + "/migrations"
            // Compatible import preserves the complete legacy JSON object as one explicitly named record.
            // It never rewrites tracker Files or invents per-day schema conversion.
            body = ["expected_revision":revision,"from_schema_version":schema,"to_schema_version":schema,"compatible":true,
                    "source":["file_id":sourceFile,"file_version_id":version,"sha256_hex":SHA256Hex.of(bytes)]]
            let header = String(decoding:try GenericJSON.canonical(body),as:UTF8.self)
            let recordID = String(decoding:try GenericJSON.canonical(record),as:UTF8.self)
            exactBody = Data((String(header.dropLast()) + ",\"records\":[{\"id\":" + recordID + ",\"data\":" + String(decoding:value,as:UTF8.self) + "}]}").utf8)
        }
        _ = try await api.client.request(method:method,path:path,appNpub:w.appNpub,jsonBody:exactBody ?? GenericJSON.canonical(body))
        try Task.checkCancellation()
        try await refreshRuntimeApps(c,w)
    }
}
extension StoreReader {
    public func runtimeApps(connection: ConnectionRecord, workspace: WorkspaceRecord, context: NappletRuntimeContext) throws -> [RuntimeInstallation] {
        guard let value = try state(WorkspaceSync.runtimeKey(connection,workspace)), value.hasPrefix(WorkspaceSync.runtimeRun + "\n"),
              let rows = try JSONSerialization.jsonObject(with:Data(value.dropFirst(WorkspaceSync.runtimeRun.count + 1).utf8)) as? [[String:Any]] else { return [] }
        return try rows.map { try RuntimeInstallation.parse($0,context:context) }
    }
}
