import AmbulandoCore
import Foundation

/// Opt-in synthetic transport. The scenario is supplied AFTER the runtime build, with arbitrary IDs/HTML.
/// This is test evidence only and never connects to a human backend or supplies production app templates.
final class GenericNappletFixture: @unchecked Sendable {
    private static let seededURL: URL? = {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of:"-AmbulandoGenericSeed"), args.indices.contains(at + 1),
              let data = Data(base64Encoded:args[at + 1]), let seed = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let run = seed["runID"] as? String, UUID(uuidString:run) != nil else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GenericScenario-" + run + ".json")
        if !FileManager.default.fileExists(atPath:url.path) { try? data.write(to:url,options:.atomic) }
        else if args.contains("-AmbulandoGenericApplyCode"), var current = try? JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any], var files = current["files"] as? [[String:Any]], let replacements = seed["files"] as? [[String:Any]] {
            for replacement in replacements where replacement["content_type"] as? String == "text/html" {
                if let at = files.firstIndex(where:{ $0["id"] as? String == replacement["id"] as? String }) { files[at] = replacement }
            }
            current["files"] = files; try? JSONSerialization.data(withJSONObject:current).write(to:url,options:.atomic)
        }
        return url
    }()
    static var scenarioURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of:"-AmbulandoGenericScenario"), args.indices.contains(at + 1) else { return seededURL }
        return URL(fileURLWithPath:args[at + 1])
    }
    static var enabled: Bool { scenarioURL != nil }
    let lock = NSLock()
    func scenario() throws -> [String:Any] {
        guard let url = Self.scenarioURL else { throw FileNappletError.invalid }
        return try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
    }
    func mime(_ path:String) -> String? {
        guard path.hasSuffix("/object"), let scenario = try? scenario(), let files = scenario["files"] as? [[String:Any]] else { return nil }
        return files.first(where:{ path.contains("/files/" + ($0["id"] as! String) + "/") })?["content_type"] as? String
    }
    func handle(_ request:URLRequest, actor:String) throws -> (Int,Any)? {
        guard Self.enabled else { return nil }
        let path = request.url!.path, base = "/api/v4/flightdeck-pg/workspaces/" + FixtureTower.studio
        guard path.hasPrefix(base) || path.hasPrefix("/api/v4/storage/") else { return nil }
        return try lock.withLock {
            var s = try scenario(), files = s["files"] as! [[String:Any]], pins = s["pins"] as? [[String:Any]] ?? []
            if s["denied"] as? Bool == true { return (403,["code":"denied"]) }
            func persist() throws {
                s["files"] = files; s["pins"] = pins
                try JSONSerialization.data(withJSONObject:s,options:[.sortedKeys]).write(to:Self.scenarioURL!,options:.atomic)
            }
            let method = request.httpMethod ?? "GET"
            let parts = path.split(separator:"/").map(String.init)
            if path.hasSuffix("/record-sync/priority"), URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "family" })?.value == "personal_pin" {
                return (200,["protocol_version":1,"changes":pins.map { ["family":"personal_pin","id":$0["id"]!,"workspace_id":FixtureTower.studio,"operation":"upsert","row":$0] },"has_more":false,"next_cursor":NSNull()])
            }
            if path.contains("/me/pins/file/"), method == "PUT", let id = parts.last {
                let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                let at = pins.firstIndex(where:{ $0["resource_id"] as? String == id }), old = at.map { pins[$0] }
                guard (old?["row_version"] as? Int ?? 0) == body["expected_row_version"] as? Int else { return (409,["code":"thread_pin_conflict"]) }
                let row: [String:Any] = ["id":old?["id"] ?? UUID().uuidString.lowercased(),"workspace_id":FixtureTower.studio,"resource_type":"file","resource_id":id,"pinned":body["pinned"]!,"row_version":(old?["row_version"] as? Int ?? 0) + 1,"updated_at":"2026-11-23T00:00:00.000Z"]
                if let at { pins[at] = row } else { pins.append(row) }; try persist(); return (200,["pin":row])
            }
            if path == base + "/channels/" + NappletTrustFixture.channelId {
                return (200,["channel":["id":NappletTrustFixture.channelId,"workspace_id":FixtureTower.studio,"kind":"dm","participant_npubs":[actor]]])
            }
            if path == base + "/channels/" + NappletTrustFixture.channelId + "/files" { return (200,["files":files]) }
            if path.hasSuffix("/storage/prepare") {
                let object = UUID().uuidString.lowercased(); s["upload"] = ["id":object]; try persist()
                return (200,["object_id":object,"upload_url":"https://fixture.ambulando.invalid/api/v4/storage/" + object])
            }
            if path.hasPrefix("/api/v4/storage/"), var upload = s["upload"] as? [String:Any] {
                if method == "PUT" {
                    let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                    upload["text"] = String(data:Data(base64Encoded:body["base64_data"] as! String)!,encoding:.utf8)!
                } else if path.hasSuffix("/complete") { upload["completed_at"] = "now" }
                s["upload"] = upload; try persist()
                let bytes = Data((upload["text"] as? String ?? "").utf8)
                return (200,["id":upload["id"]!,"is_public":false,"size_bytes":bytes.count,"sha256_hex":SHA256Hex.of(bytes),"completed_at":upload["completed_at"] ?? NSNull()])
            }
            guard let fileAt = parts.firstIndex(of:"files"), parts.indices.contains(fileAt + 1), let at = files.firstIndex(where:{ $0["id"] as? String == parts[fileAt + 1] }) else { return nil }
            var file = files[at]; let id = file["id"] as! String
            if parts.last == id {
                var row = file; row["workspace_id"] = FixtureTower.studio; row["channel_id"] = NappletTrustFixture.channelId
                row["current_version_id"] = file["head"]; row["record_state"] = "active"; row.removeValue(forKey:"text"); row.removeValue(forKey:"history")
                return (200,["file":row,"can_write":s["canWrite"] as? Bool ?? true])
            }
            if path.hasSuffix("/versions") {
                if method == "POST" {
                    let body = try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                    guard body["base_version_id"] as? String == file["head"] as? String else { return (409,["code":"stale_base_version"]) }
                    let upload = s["upload"] as! [String:Any], head = UUID().uuidString.lowercased(), text = upload["text"] as! String
                    var history = file["history"] as! [String:String]; history[head] = text
                    file["history"] = history; file["head"] = head; file["text"] = text; files[at] = file; try persist()
                    return (200,["version":["id":head]])
                }
                let text = file["text"] as! String, bytes = Data(text.utf8), head = file["head"] as! String
                return (200,["file_id":id,"current_version_id":head,"versions":[["id":head,"content_type":file["content_type"]!,"size_bytes":bytes.count,"sha256_hex":SHA256Hex.of(bytes)]]])
            }
            if path.hasSuffix("/object"), let versionAt = parts.firstIndex(of:"versions"), parts.indices.contains(versionAt + 1), let text = (file["history"] as? [String:String])?[parts[versionAt + 1]] { return (200,Data(text.utf8)) }
            return (404,["code":"missing"])
        }
    }
}
