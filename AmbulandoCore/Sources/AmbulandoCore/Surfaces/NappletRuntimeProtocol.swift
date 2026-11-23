import Foundation

/// Common v3 cartridge manifest. File-backed v1/v2 remain separately parsed.
public struct NappletRuntimeManifest: Equatable, Sendable {
    public struct Collection: Equatable, Sendable {
        public let scope: String
        public let schema: Int
        public let operations: Set<String>
    }
    public struct Capability: Equatable, Sendable {
        public let version: Int
        public let resources: Set<String>
        public let operations: Set<String>
    }
    public let id: String
    public let bundleVersion: String
    public let title: String
    public let icon: String
    public let minimumHost: Int
    public let collections: [String: Collection]
    public let capabilities: [String: Capability]
    public let canonical: Data
    public static func name(_ value: String) -> Bool { GenericJSON.matches(value, "^[a-z][a-z0-9_-]{0,63}") }
    static func positive(_ value: Any?) -> Int? {
        guard let n = TrackerDocument.number(value), n.doubleValue > 0, n.doubleValue <= 9007199254740991, n.doubleValue == Double(n.intValue) else { return nil }; return n.intValue
    }
    static func text(_ value: Any?, max: Int) -> String? {
        guard let s = value as? String, (1...max).contains(s.unicodeScalars.count),
              !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || (0xD800...0xDFFF).contains($0.value) }) else { return nil }; return s
    }
    static func strings(_ value: Any?, nonempty: Bool = false) -> [String]? {
        guard let a = value as? [String], a.count <= 64, !nonempty || !a.isEmpty,
              Set(a.map { Data($0.utf8) }).count == a.count else { return nil }; return a
    }
    public static func parse(_ data: Data) throws -> Self {
        let o = try GenericJSON.decode(data)
        guard GenericJSON.exact(o, ["version","napplet_id","bundle_version","title","icon","runtime","collections","capabilities"]), TrackerDocument.number(o["version"]) == 3,
              let id = o["napplet_id"] as? String, name(id), let version = text(o["bundle_version"], max:64),
              let title = text(o["title"], max:80), let icon = text(o["icon"], max:8), !icon.contains(where: { "<>:/\\".contains($0) }),
              let runtime = o["runtime"] as? [String: Any], GenericJSON.exact(runtime,["protocol","min_host"]), TrackerDocument.number(runtime["protocol"]) == 3,
              let minimum = positive(runtime["min_host"]), let rawCollections = o["collections"] as? [String: Any], rawCollections.count <= 32,
              let rawCapabilities = o["capabilities"] as? [String: Any], rawCapabilities.count <= 32 else { throw FileNappletError.invalid }
        var collections: [String: Collection] = [:], capabilities: [String: Capability] = [:]
        for (key,value) in rawCollections {
            guard name(key), let c = value as? [String:Any], GenericJSON.exact(c,["scope","schema_version","operations"]),
                  let scope = c["scope"] as? String, ["personal","team"].contains(scope), let schema = positive(c["schema_version"]),
                  let ops = strings(c["operations"],nonempty:true), Set(ops).isSubset(of:["list","get","create","update","delete"]) else { throw FileNappletError.invalid }
            collections[key] = Collection(scope:scope,schema:schema,operations:Set(ops))
        }
        for (key,value) in rawCapabilities {
            guard name(key), let c = value as? [String:Any], GenericJSON.exact(c,["version","resources","operations"]), let version = positive(c["version"]),
                  let resources = strings(c["resources"]), resources.allSatisfy({ text($0,max:2048) != nil }),
                  let ops = strings(c["operations"],nonempty:true), ops.allSatisfy(name) else { throw FileNappletError.invalid }
            capabilities[key] = Capability(version:version,resources:Set(resources),operations:Set(ops))
        }
        return Self(id:id,bundleVersion:version,title:title,icon:icon,minimumHost:minimum,collections:collections,capabilities:capabilities,canonical:try GenericJSON.canonicalData(data))
    }
    public static func parse(html: String) throws -> Self {
        // Match actual quoted id attributes, rather than text embedded in another attribute.
        let re = try NSRegularExpression(pattern: #"<script\b((?:[^>"']|"[^"]*"|'[^']*')*)>([\s\S]*?)</script\s*>"#, options:.caseInsensitive)
        let attrs = try NSRegularExpression(pattern: #"(?:^|\s)([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
        let source = html as NSString
        let matches = re.matches(in:html,range:NSRange(location:0,length:source.length)).filter { tag in
            let raw = source.substring(with:tag.range(at:1)) as NSString
            return attrs.matches(in:raw as String,range:NSRange(location:0,length:raw.length)).contains { attr in
                raw.substring(with:attr.range(at:1)).lowercased() == "id" && [2,3].contains { i in
                    attr.range(at:i).location != NSNotFound && raw.substring(with:attr.range(at:i)).lowercased() == "wingman-napplet-manifest"
                }
            }
        }
        guard matches.count == 1 else { throw FileNappletError.invalid }
        return try parse(Data(source.substring(with:matches[0].range(at:2)).utf8))
    }
    /// A schema or scope change is an expansion even if operation names are unchanged.
    public func permits(_ requested: Self) -> Bool {
        guard id == requested.id else { return false }
        for (key,c) in requested.collections {
            guard let old = collections[key], old.scope == c.scope, old.schema == c.schema, c.operations.isSubset(of:old.operations) else { return false }
        }
        for (key,c) in requested.capabilities {
            guard let old = capabilities[key], old.version == c.version, c.resources.isSubset(of:old.resources), c.operations.isSubset(of:old.operations) else { return false }
        }
        return true
    }
    public var unsupportedReason: String? {
        if minimumHost > 3 { return "This napplet requires a newer host runtime." }
        if !capabilities.isEmpty { return "This host does not support the requested personal capabilities. DM read, decrypt, send, plaintext persistence and agent access require separate permissions and are unavailable through this runtime." }
        return nil
    }
}

public struct NappletRuntimeRequest: Sendable {
    public let id: String
    public let operation: String
    public let collection: String?
    public let record: String?
    public let revision: Int?
    public let limit: Int?
    public let cursor: String?
    public let value: Data?
    public let dirty: Bool?
    public static func recordID(_ s: String) -> Bool { GenericJSON.matches(s,"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}") }
    public static func parse(_ data: Data, session: String, manifest: NappletRuntimeManifest) throws -> Self {
        let tree = try GenericJSON.tree(data,envelope:true)
        guard tree.isObject, let o = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              GenericJSON.matches(session,"^[a-f0-9]{32}"), o["session"] as? String == session,
              o["type"] as? String == "wingman-napplet-data", TrackerDocument.number(o["version"]) == 3,
              let id = o["requestId"] as? String, GenericJSON.matches(id,"^[A-Za-z0-9_-]{1,64}"), let op = o["operation"] as? String else { throw FileNappletError.invalid }
        let common: Set<String> = ["type","version","session","requestId","operation"]
        if op == "dirty" {
            guard GenericJSON.exact(o,common.union(["dirty"])), let flag = TrackerDocument.boolean(o["dirty"]) else { throw FileNappletError.invalid }
            return Self(id:id,operation:op,collection:nil,record:nil,revision:nil,limit:nil,cursor:nil,value:nil,dirty:flag)
        }
        guard let collection = o["collection"] as? String, let c = manifest.collections[collection], c.operations.contains(op) else { throw FileNappletError.invalid }
        let keys = common.union(["collection"])
        var record: String?, revision: Int?, limit: Int?, cursor: String?, value: Data?
        if op == "list" {
            guard GenericJSON.exact(o,keys.union(["limit","cursor"])), let n = NappletRuntimeManifest.positive(o["limit"]), n <= 100,
                  o["cursor"] is NSNull || (o["cursor"] as? String).map({ (1...2048).contains($0.utf16.count) }) == true else { throw FileNappletError.invalid }
            limit = n; cursor = o["cursor"] as? String
        } else {
            guard let r = o["record_id"] as? String, recordID(r) else { throw FileNappletError.invalid }; record = r
            if op == "get" { guard GenericJSON.exact(o,keys.union(["record_id"])) else { throw FileNappletError.invalid } }
            else {
                guard ["create","update","delete"].contains(op), GenericJSON.exact(o,keys.union(op == "delete" ? ["record_id","base_revision"] : ["record_id","base_revision","value"])),
                      let n = TrackerDocument.number(o["base_revision"]), n.doubleValue <= 9007199254740991, n.doubleValue == Double(n.intValue), op == "create" ? n.intValue == 0 : n.intValue > 0 else { throw FileNappletError.invalid }
                revision = n.intValue
                if op != "delete" { guard let v = tree.member("value"), v.isObject else { throw FileNappletError.invalid }; value = try GenericJSON.canonicalData(Data(v.encoded.utf8)) }
            }
        }
        return Self(id:id,operation:op,collection:collection,record:record,revision:revision,limit:limit,cursor:cursor,value:value,dirty:nil)
    }
}
