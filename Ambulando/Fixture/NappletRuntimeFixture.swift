import AmbulandoCore
import Foundation

/// Opt-in post-build scenario. Signed requests still traverse the real native client and store.
final class NappletRuntimeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private static let seededURL: URL? = {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of:"-AmbulandoRuntimeSeed"), args.indices.contains(at + 1),
              let bytes = Data(base64Encoded:args[at + 1]), let seed = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let run = seed["runID"] as? String, UUID(uuidString:run) != nil else { return nil }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeScenario-" + run + ".json")
        if !FileManager.default.fileExists(atPath:path.path) { try? bytes.write(to:path,options:.atomic) }
        else if args.contains("-AmbulandoRuntimeApplyCode"), var current = try? JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any],
                var apps = current["apps"] as? [[String:Any]], let replacements = seed["apps"] as? [[String:Any]] {
            for i in apps.indices {
                if let replacement = replacements.first(where:{ $0["id"] as? String == apps[i]["id"] as? String }) {
                    for key in ["html","updated","version","updateVersion","activeUpdate"] { if let value = replacement[key] { apps[i][key] = value } }
                }
            }
            current["apps"] = apps; try? JSONSerialization.data(withJSONObject:current).write(to:path,options:.atomic)
        }
        return path
    }()
    static var url: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of:"-AmbulandoRuntimeScenario"), args.indices.contains(at + 1) else { return seededURL }
        return URL(fileURLWithPath:args[at + 1])
    }
    static var enabled: Bool { url != nil }
    func scenario() throws -> [String:Any] {
        guard let url = Self.url else { throw FileNappletError.invalid }
        return try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    }
    func update(_ id: String) throws {
        try lock.withLock {
            var s = try scenario(), apps = s["apps"] as! [[String:Any]]
            guard let at = apps.firstIndex(where:{ $0["id"] as? String == id }) else { throw FileNappletError.invalid }
            apps[at]["activeUpdate"] = true; s["apps"] = apps
            try JSONSerialization.data(withJSONObject:s).write(to:Self.url!,options:.atomic)
        }
    }
    func handle(_ request: URLRequest, actor: String) throws -> (Int,Any)? {
        guard Self.enabled else { return nil }
        let base = "/api/v4/flightdeck-pg/workspaces/" + FixtureTower.studio + "/apps/" + FixtureTower.appNpub + "/napplets"
        let path = request.url!.path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return try lock.withLock {
            var s = try scenario(), apps = s["apps"] as! [[String:Any]]
            if s["denied"] as? Bool == true { return (403,["code":"denied","error":"Synthetic revocation"]) }
            func installation(_ app: [String:Any]) throws -> [String:Any] {
                let updated = app["activeUpdate"] as? Bool == true, html = app[updated ? "updated" : "html"] as! String
                let manifest = try NappletRuntimeManifest.parse(html:html)
                return ["workspace_id":FixtureTower.studio,"app_npub":FixtureTower.appNpub,"napplet_id":manifest.id,
                        "owner_npub":actor,"publisher_npub":actor,"display_name":manifest.title,"audience_npubs":[actor],
                        "bundle":["file_id":app["file"]!,"file_version_id":app[updated ? "updateVersion" : "version"]!,"sha256_hex":SHA256Hex.of(Data(html.utf8))],
                        "manifest":try JSONSerialization.jsonObject(with:manifest.canonical),"pending_release":NSNull(),"revision":updated ? 2 : 1,"removed":false]
            }
            if path == base { return (200,["installations":try apps.map(installation),"next_cursor":NSNull()]) }
            let suffix = String(path.dropFirst(base.count + 1)).split(separator:"/").map(String.init)
            guard let id = suffix.first, let index = apps.firstIndex(where:{ $0["id"] as? String == id }) else { return (404,["error":"unavailable"]) }
            var app = apps[index]
            if suffix.count == 1 { return (200,["installation":try installation(app)]) }
            if suffix == [id,"bundle"] { return (200,Data((app[app["activeUpdate"] as? Bool == true ? "updated" : "html"] as! String).utf8)) }
            let collectionId = app["collectionID"] as! String, name = app["collection"] as! String
            if suffix == [id,"collections"] {
                return (200,["collections":[["workspace_id":FixtureTower.studio,"app_npub":FixtureTower.appNpub,"napplet_id":id,
                                            "id":collectionId,"name":name,"scope":"personal","owner_npub":actor,"read_npubs":[],"write_npubs":[],"schema_version":1,"revision":1]],"next_cursor":NSNull()])
            }
            guard suffix.count >= 4, suffix[1] == "collections", suffix[2] == collectionId, suffix[3] == "records" else { return (404,["error":"unavailable"]) }
            var history = app["history"] as? [[String:Any]] ?? []
            if suffix.count == 4 { return (200,["records":history.last.map { [$0] } ?? [],"next_cursor":NSNull()]) }
            if request.httpMethod == "PUT" {
                let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                guard body["expected_revision"] as? Int == history.count else { return (409,["code":"conflict","error":"Synthetic CAS conflict"]) }
                let record: [String:Any] = ["collection_id":collectionId,"id":suffix[4],"revision":history.count + 1,"schema_version":1,"data":body["data"]!,"deleted":false,"provenance":NSNull(),"updated_by_npub":actor]
                history.append(record); app["history"] = history; apps[index] = app; s["apps"] = apps
                try JSONSerialization.data(withJSONObject:s).write(to:Self.url!,options:.atomic)
                return (200,["record":record])
            }
            guard let record = history.last else { return (404,["error":"unavailable"]) }; return (200,["record":record])
        }
    }
}
