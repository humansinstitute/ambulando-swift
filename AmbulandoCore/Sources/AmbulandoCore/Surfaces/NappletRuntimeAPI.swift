import Foundation

public struct RuntimeBundle: Equatable, Sendable {
    public let file: String
    public let version: String
    public let digest: String
    static func parse(_ value: Any?) throws -> Self {
        guard let o = value as? [String:Any], GenericJSON.exact(o,["file_id","file_version_id","sha256_hex"]),
              let file = o["file_id"] as? String, GenericJSON.uuid(file), let version = o["file_version_id"] as? String, GenericJSON.uuid(version),
              let digest = o["sha256_hex"] as? String, GenericJSON.matches(digest,"^[a-f0-9]{64}") else { throw FileNappletError.invalid }
        return Self(file:file,version:version,digest:digest)
    }
}
public struct RuntimeInstallation: Equatable, Sendable, Identifiable {
    public var id: String { manifest.id }
    public let removed: Bool
    public let owner: String
    public let publisher: String
    public let audience: [String]
    public let bundle: RuntimeBundle
    public let manifest: NappletRuntimeManifest
    public let revision: Int
    public let pendingBundle: RuntimeBundle?
    public let pendingManifest: NappletRuntimeManifest?
    public let raw: Data
    public static func parse(_ o: [String:Any], context: NappletRuntimeContext, allowRemoved: Bool = false) throws -> Self {
        guard o["workspace_id"] as? String == context.workspace, o["app_npub"] as? String == context.app,
              let removed = TrackerDocument.boolean(o["removed"]), (!removed || allowRemoved), let owner = o["owner_npub"] as? String, NostrKeys.isValidNpub(owner),
              let publisher = o["publisher_npub"] as? String, NostrKeys.isValidNpub(publisher),
              let audience = o["audience_npubs"] as? [String], audience.count <= 200, Set(audience).count == audience.count, audience.allSatisfy(NostrKeys.isValidNpub),
              removed && allowRemoved || context.viewer == owner || context.viewer == publisher || audience.contains(context.viewer),
              let m = o["manifest"] as? [String:Any], let revision = NappletRuntimeManifest.positive(o["revision"]) else { throw FileNappletError.unavailable }
        let manifest = try NappletRuntimeManifest.parse(GenericJSON.canonical(m))
        guard o["napplet_id"] as? String == manifest.id else { throw FileNappletError.invalid }
        var pendingBundle: RuntimeBundle?, pendingManifest: NappletRuntimeManifest?
        if let pending = o["pending_release"] as? [String:Any] {
            pendingBundle = try RuntimeBundle.parse(pending["bundle"])
            guard let pm = pending["manifest"] as? [String:Any] else { throw FileNappletError.invalid }
            pendingManifest = try NappletRuntimeManifest.parse(GenericJSON.canonical(pm))
            guard pendingManifest?.id == manifest.id else { throw FileNappletError.invalid }
        } else if !(o["pending_release"] is NSNull) { throw FileNappletError.invalid }
        return Self(removed:removed,owner:owner,publisher:publisher,audience:audience,bundle:try RuntimeBundle.parse(o["bundle"]),manifest:manifest,revision:revision,pendingBundle:pendingBundle,pendingManifest:pendingManifest,raw:try GenericJSON.canonical(o))
    }
    /// Mutable audience/revision and pending release metadata do not alter active code identity.
    public func sameRelease(as other: Self) -> Bool {
        id == other.id && publisher == other.publisher && bundle == other.bundle && manifest == other.manifest
    }
}
public struct RuntimeCode: Sendable {
    public let installation: RuntimeInstallation
    public let html: String
}

extension TowerAPI {
    static func runtimeBase(_ context: NappletRuntimeContext, _ napplet: String? = nil) throws -> String {
        guard NostrKeys.isValidNpub(context.app), napplet == nil || NappletRuntimeManifest.name(napplet!) else { throw FileNappletError.invalid }
        return try Self.base(context.workspace) + "/apps/" + context.app + "/napplets" + (napplet.map { "/" + $0 } ?? "")
    }
    func runtimeInstallation(_ context: NappletRuntimeContext, id: String, includeRemoved: Bool = false) async throws -> RuntimeInstallation {
        let o = try object(try await client.request(path:Self.runtimeBase(context,id),appNpub:context.app),"napplet installation")
        guard let row = o["installation"] as? [String:Any] else { throw FileNappletError.invalid }
        let result = try RuntimeInstallation.parse(row,context:context,allowRemoved:includeRemoved)
        guard result.id == id else { throw FileNappletError.invalid }; return result
    }
    func runtimeInstallations(_ context: NappletRuntimeContext) async throws -> [RuntimeInstallation] {
        var result: [RuntimeInstallation] = [], cursor: String?, seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name:"limit",value:"100")]
            if let cursor { query.append(URLQueryItem(name:"after",value:cursor)) }
            let o = try object(try await client.request(path:Self.runtimeBase(context),query:query,appNpub:context.app),"napplet installations")
            guard let rows = o["installations"] as? [[String:Any]], rows.count <= 100 else { throw FileNappletError.invalid }
            for row in rows {
                let item = try RuntimeInstallation.parse(row,context:context)
                guard seen.insert(item.id).inserted else { throw FileNappletError.invalid }; result.append(item)
            }
            if o["next_cursor"] is NSNull { cursor = nil }
            else { guard let next = o["next_cursor"] as? String, NappletRuntimeManifest.name(next), next != cursor, rows.last?["napplet_id"] as? String == next else { throw FileNappletError.invalid }; cursor = next }
            guard result.count <= 2000 else { throw FileNappletError.invalid }
        } while cursor != nil
        return result
    }
    func runtimeCode(_ context: NappletRuntimeContext, id: String) async throws -> RuntimeCode {
        let installation = try await runtimeInstallation(context,id:id), bundle = installation.bundle
        // Fetch the immutable authorized version, never whichever File head happens to be current.
        let path = try Self.runtimeBase(context,id) + "/bundle"
        let request = try await client.signed(method:"GET",path:path,query:[],appNpub:context.app,jsonBody:nil)
        let (bytes,response) = try await client.transport.send(request)
        try Task.checkCancellation()
        guard response.statusCode == 200, response.mimeType?.lowercased() == "application/octet-stream", bytes.count <= 2 * 1024 * 1024,
              SHA256Hex.of(bytes) == bundle.digest, let html = String(data:bytes,encoding:.utf8),
              try NappletRuntimeManifest.parse(html:html) == installation.manifest else { throw FileNappletError.invalid }
        let current = try await runtimeInstallation(context,id:id)
        guard current.sameRelease(as:installation) else { throw FileNappletError.unavailable }
        return RuntimeCode(installation:current,html:html)
    }
    func runtimeCommand(_ context: NappletRuntimeContext, installation: RuntimeInstallation, request: NappletRuntimeRequest, selections: [String:String] = [:]) async throws -> Data {
        let current = try await runtimeInstallation(context,id:installation.id)
        guard current.sameRelease(as:installation), let name = request.collection, let declaration = installation.manifest.collections[name], declaration.operations.contains(request.operation) else { throw FileNappletError.unavailable }
        let base = try Self.runtimeBase(context,installation.id)
        // Resolve a named dataset under current grants. Personal defaults always select the acting owner.
        var candidates: [[String:Any]] = [], cursor: String?, seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name:"limit",value:"100")]; if let cursor { query.append(URLQueryItem(name:"after",value:cursor)) }
            let o = try object(try await client.request(path:base + "/collections",query:query,appNpub:context.app),"napplet collections")
            guard let rows = o["collections"] as? [[String:Any]], rows.count <= 100 else { throw FileNappletError.invalid }
            for row in rows {
                guard row["workspace_id"] as? String == context.workspace, row["app_npub"] as? String == context.app, row["napplet_id"] as? String == installation.id,
                      let id = row["id"] as? String, GenericJSON.uuid(id), seen.insert(id).inserted else { throw FileNappletError.invalid }
                if row["name"] as? String == name, row["scope"] as? String == declaration.scope,
                   NappletRuntimeManifest.positive(row["schema_version"]) == declaration.schema { candidates.append(row) }
            }
            if o["next_cursor"] is NSNull { cursor = nil }
            else { guard let next = o["next_cursor"] as? String, GenericJSON.uuid(next), next != cursor, rows.last?["id"] as? String == next else { throw FileNappletError.invalid }; cursor = next }
            guard seen.count <= 2000 else { throw FileNappletError.invalid }
        } while cursor != nil
        if let selected = selections[name] { candidates = candidates.filter { $0["id"] as? String == selected } }
        else if declaration.scope == "personal" {
            let own = candidates.filter { $0["owner_npub"] as? String == context.viewer }
            if !own.isEmpty { candidates = own }
        }
        guard candidates.count == 1, let collection = candidates.first, let collectionId = collection["id"] as? String else { throw FileNappletError.unavailable }
        let path = base + "/collections/" + collectionId + "/records"
        let response: Data
        if request.operation == "list" {
            guard let limit = request.limit else { throw FileNappletError.invalid }
            // API v1 uses record-ID keyset cursors; opaque bridge cursors cannot escape this query.
            var query = [URLQueryItem(name:"limit",value:String(limit))]
            if let cursor = request.cursor { guard NappletRuntimeRequest.recordID(cursor) else { throw FileNappletError.invalid }; query.append(URLQueryItem(name:"after",value:cursor)) }
            response = try await client.request(path:path,query:query,appNpub:context.app)
        } else {
            guard let record = request.record, NappletRuntimeRequest.recordID(record) else { throw FileNappletError.invalid }
            if request.operation == "get" { response = try await client.request(path:path + "/" + record,appNpub:context.app) }
            else {
                guard let revision = request.revision else { throw FileNappletError.invalid }
                let body: Data
                if request.operation == "delete" { body = try GenericJSON.canonical(["expected_revision":revision]) }
                else {
                    guard let value = request.value, value.count <= 256 * 1024 else { throw FileNappletError.invalid }
                    body = Data(("{\"expected_revision\":\(revision),\"schema_version\":\(declaration.schema),\"data\":" + String(decoding:value,as:UTF8.self) + "}").utf8)
                }
                response = try await client.request(method:request.operation == "delete" ? "DELETE" : "PUT",path:path + "/" + record,appNpub:context.app,jsonBody:body)
            }
        }
        return try Self.validateRuntimeResult(response,collection:collectionId,schema:declaration.schema,request:request)
    }
    static func validateRuntimeResult(_ data: Data, collection: String, schema: Int, request: NappletRuntimeRequest) throws -> Data {
        let o = try GenericJSON.decode(data)
        let rows: [[String:Any]]
        if request.operation == "list" {
            guard GenericJSON.exact(o,["records","next_cursor"]), let list = o["records"] as? [[String:Any]], list.count <= (request.limit ?? 0),
                  o["next_cursor"] is NSNull || (o["next_cursor"] as? String).map(NappletRuntimeRequest.recordID) == true else { throw FileNappletError.invalid }; rows = list
        } else { guard GenericJSON.exact(o,["record"]), let row = o["record"] as? [String:Any] else { throw FileNappletError.invalid }; rows = [row] }
        var seen = Set<String>()
        for row in rows {
            guard row["collection_id"] as? String == collection, let id = row["id"] as? String, NappletRuntimeRequest.recordID(id), seen.insert(id).inserted,
                  request.operation == "list" || id == request.record, NappletRuntimeManifest.positive(row["revision"]) != nil,
                  NappletRuntimeManifest.positive(row["schema_version"]) == schema, let deleted = TrackerDocument.boolean(row["deleted"]),
                  deleted ? row["data"] is NSNull : row["data"] is [String:Any], let updater = row["updated_by_npub"] as? String, NostrKeys.isValidNpub(updater) else { throw FileNappletError.invalid }
            if ["create","update","delete"].contains(request.operation) {
                guard let base = request.revision, NappletRuntimeManifest.positive(row["revision"]) == base + 1 else { throw FileNappletError.invalid }
            }
            if request.operation == "delete" { guard deleted else { throw FileNappletError.invalid } }
            if request.operation == "list" || request.operation == "get" { guard !deleted else { throw FileNappletError.invalid } }
        }
        if request.operation == "list", let cursor = o["next_cursor"] as? String {
            guard rows.last?["id"] as? String == cursor else { throw FileNappletError.invalid }
        }
        if let expected = request.value {
            guard let stored = try GenericJSON.tree(data).member("record")?.member("data"), Data(stored.encoded.utf8) == expected else { throw FileNappletError.invalid }
        }
        return try GenericJSON.canonicalData(data)
    }
}
