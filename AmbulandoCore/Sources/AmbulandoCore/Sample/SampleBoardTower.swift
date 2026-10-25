import Foundation

/// In-process stand-in for Tower's board File version routes (`tower/src/routes/flightdeck-pg.ts`), for sample data and
/// tests:
///
/// - `GET  /files/:f/versions` (newest first, with `current_version_id`)
/// - `GET  /files/:f/versions/:v/object`
/// - `POST /files/:f/versions` with `base_version_id` and a completed `storage_object_id` (409 `stale_base_version`
///   unless the base is the current version; 403 without write access)
///
/// It also keeps the Canvas snapshot's projection of each board current (`project`), as Tower re-projects a naplet's
/// board after a save.
public final class SampleBoardTower: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL?
    public let workspaceId: String
    /// Bytes of a completed storage object (the work stand-in's object store).
    public var objectBytes: (@Sendable (String) -> Data?)?
    private var boards: [String: [String: Any]] = [:]
    public private(set) var log: [String] = []
    /// Someone else saves (a new rectangle) just before this device's next save, which then meets a stale base.
    public var externalSaveBeforeNextPublish = false

    public init(workspaceId: String, file: URL? = nil) {
        self.workspaceId = workspaceId.lowercased()
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] {
            boards = saved
        }
    }

    private func persist() {
        guard let file, let data = try? JSONSerialization.data(withJSONObject: boards) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func versions(_ fileId: String) -> [[String: Any]] { boards[fileId]?["versions"] as? [[String: Any]] ?? [] }

    private func append(_ fileId: String, bytes: Data, author: String, summary: String?) -> [String: Any] {
        var board = boards[fileId] ?? ["can_write": true, "versions": [[String: Any]]()]
        var rows = board["versions"] as? [[String: Any]] ?? []
        let id = UUID().uuidString.lowercased()
        let row: [String: Any] = ["id": id, "file_id": fileId, "version_number": rows.count + 1, "created_at": ISO8601DateFormatter.tower.string(from: Date()),
                                  "created_by_actor_npub": author, "summary": summary ?? NSNull(), "size_bytes": bytes.count,
                                  "sha256_hex": SHA256Hex.of(bytes), "content_type": BoardScene.contentType, "bytes": bytes.base64EncodedString()]
        rows.append(row)
        board["versions"] = rows
        boards[fileId] = board
        return row
    }

    /// A board this stand-in owns, starting from `bytes` as version 1 (`versions` earlier versions are added first).
    public func seed(fileId: String, bytes: Data, canWrite: Bool, author: String) {
        lock.withLock {
            guard boards[fileId] == nil else { return }
            _ = append(fileId, bytes: bytes, author: author, summary: nil)
            boards[fileId]?["can_write"] = canWrite
            persist()
        }
    }

    /// Someone else saves a new version (conflict testing).
    public func externalSave(fileId: String, bytes: Data, author: String) { lock.withLock { _ = append(fileId, bytes: bytes, author: author, summary: "external"); persist() } }

    public func versionCount(_ fileId: String) -> Int { lock.withLock { versions(fileId).count } }
    public func currentBytes(_ fileId: String) -> Data? { lock.withLock { (versions(fileId).last?["bytes"] as? String).flatMap { Data(base64Encoded: $0) } } }

    private func public_(_ row: [String: Any]) -> [String: Any] { row.filter { $0.key != "bytes" } }

    /// The ready naplet projection of a board (sol/Tower `content` for `source.type == "excalidraw"`).
    private func projection(_ fileId: String) -> [String: Any]? {
        guard let head = versions(fileId).last else { return nil }
        return ["file_id": fileId, "current_version_id": head["id"]!, "current_version_number": head["version_number"]!,
                "content_type": BoardScene.contentType, "size_bytes": head["size_bytes"]!, "sha256": head["sha256_hex"]!,
                "updated_at": head["created_at"]!, "updated_by_actor_npub": head["created_by_actor_npub"] ?? NSNull(),
                "can_write": boards[fileId]?["can_write"] as? Bool ?? false]
    }

    public func handle(_ request: URLRequest) throws -> (Int, Any)? {
        guard let url = request.url else { return nil }
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspaceId)/files/"
        guard url.path.hasPrefix(base) else { return nil }
        let p = url.path.dropFirst(base.count).split(separator: "/").map(String.init)
        guard p.count >= 2, p[1] == "versions" else { return nil }
        let fileId = p[0].lowercased()
        guard lock.withLock({ boards[fileId] != nil }) else { return nil }
        let body = request.httpBody ?? Data()
        guard SampleAuth.verify(request, body: body) else { return (401, ["code": "unauthorized"]) }
        let method = request.httpMethod ?? "GET"
        return lock.withLock {
            log.append("\(method) \(url.path)")
            switch (method, p.count) {
            case ("GET", 2):
                let rows = versions(fileId)
                return (200, ["file_id": fileId, "current_version_id": rows.last?["id"] ?? NSNull(), "versions": rows.reversed().map(public_)])
            case ("GET", 4) where p[3] == "object":
                guard let row = versions(fileId).first(where: { $0["id"] as? String == p[2] }), let bytes = Data(base64Encoded: row["bytes"] as? String ?? "") else {
                    return (404, ["code": "file_version_object_not_found"])
                }
                return (200, bytes)
            case ("POST", 2):
                guard boards[fileId]?["can_write"] as? Bool == true else { return (403, ["code": "permission_denied"]) }
                let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                if externalSaveBeforeNextPublish, let bytes = (versions(fileId).last?["bytes"] as? String).flatMap({ Data(base64Encoded: $0) }),
                   var scene = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                    externalSaveBeforeNextPublish = false
                    let other: [String: Any] = ["id": "external-\(UUID().uuidString.prefix(8))", "type": "rectangle", "version": 1, "versionNonce": 1, "x": -400, "y": -300,
                                                "width": 160, "height": 90, "angle": 0, "strokeColor": "#e03131", "backgroundColor": "transparent", "fillStyle": "solid",
                                                "strokeWidth": 2, "roughness": 1, "opacity": 100, "isDeleted": false, "seed": 7, "groupIds": [], "boundElements": NSNull()]
                    scene["elements"] = ((scene["elements"] as? [Any]) ?? []) + [other]
                    if let changed = try? JSONSerialization.data(withJSONObject: scene) { _ = append(fileId, bytes: changed, author: "external", summary: "external") }
                }
                guard let current = versions(fileId).last else { return (404, ["code": "file_not_found"]) }
                guard o["base_version_id"] as? String == current["id"] as? String else {
                    return (409, ["code": "stale_base_version", "error": "stale_base_version", "current_version": public_(current)])
                }
                guard let object = o["storage_object_id"] as? String, let bytes = objectBytes?(object) else { return (400, ["code": "storage_object_unavailable"]) }
                let author = (try? JSONDecoder().decode(NostrEvent.self, from: Data(base64Encoded: String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(6))) ?? Data()))
                    .map { Bech32.encode(hrp: "npub", data: Data(hex: $0.pubkey) ?? Data()) } ?? ""
                let row = append(fileId, bytes: bytes, author: author, summary: o["summary"] as? String)
                persist()
                return (201, ["version": public_(row)])
            default:
                return (405, ["code": "method_not_allowed"])
            }
        }
    }

    /// Re-projects the boards this stand-in owns inside a Canvas snapshot response.
    public func project(_ result: (Int, Any), for request: URLRequest) -> (Int, Any) {
        guard result.0 == 200, request.url?.path.hasSuffix("/snapshot") == true, var o = result.1 as? [String: Any],
              let naplets = o["naplets"] as? [[String: Any]] else { return result }
        o["naplets"] = lock.withLock {
            naplets.map { n in
                guard (n["source"] as? [String: Any])?["type"] as? String == "excalidraw", let id = (n["source"] as? [String: Any])?["id"] as? String,
                      let content = projection(id.lowercased()) else { return n }
                var out = n
                out["content"] = content
                return out
            }
        }
        return (result.0, o)
    }
}
