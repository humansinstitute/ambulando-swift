import Foundation

/// In-process stand-in for Tower's task, document, file, storage, view-state, lease and reaction routes.
///
/// It exists for deterministic tests and for the clearly labelled sample-data mode of Debug builds. It is **not** Tower
/// and is never evidence of live behaviour. It follows the server rules the client depends on, read from
/// `tower/src/routes/flightdeck-pg.ts` and `routes/storage.ts`:
/// - every signed route needs a valid NIP-98 event over the exact URL, method and body bytes;
/// - task `PATCH` checks `row_version` only for assignment; task create replays by `client_request_id`;
/// - document body saves need a valid lease and a matching base (`row_version` + body sha256), otherwise the
///   submission becomes a recovery (409 `document_recovery_created`);
/// - storage prepare returns a presigned upload URL on another host, which must be called **without** credentials;
///   completion checks size and sha256.
/// Faults can be injected per route for retry and conflict tests.
public final class SampleWorkTower: @unchecked Sendable {
    public enum Fault: Sendable { case offline, dropResponseAfterCommit, status(Int, String) }

    private let lock = NSLock()
    private let file: URL?
    public let workspaceId: String
    public let objectHost: String
    private var actor = ""
    private var state: [String: Any] = [:]
    private var faults: [(match: String, fault: Fault)] = []
    private var clock = 0
    /// Requests that reached the presigned host carrying an Authorization header or cookie (must stay empty).
    public private(set) var credentialLeaks: [URL] = []
    public private(set) var log: [String] = []

    public let towerOrigin: String

    public init(workspaceId: String, towerOrigin: String, objectHost: String = "objects.sample.invalid", file: URL? = nil) {
        self.workspaceId = workspaceId.lowercased()
        self.towerOrigin = towerOrigin
        self.objectHost = objectHost
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            state = saved
            clock = (saved["clock"] as? Int) ?? 0
        }
        for key in Self.collections where state[key] == nil { state[key] = [String: Any]() }
    }

    static let collections = ["tasks", "task_comments", "docs", "doc_comments", "objects", "files", "folders", "view_states", "reactions", "leases", "requests", "recoveries"]

    public var actorNpub: String { get { lock.withLock { actor } } set { lock.withLock { actor = newValue } } }

    public func inject(_ fault: Fault, matching path: String) { lock.withLock { faults.append((path, fault)) } }

    public var requestLog: [String] { lock.withLock { log } }

    // MARK: State helpers (lock held)

    private func table(_ name: String) -> [String: [String: Any]] { (state[name] as? [String: [String: Any]]) ?? [:] }
    private func put(_ name: String, _ id: String, _ row: [String: Any]?) {
        var t = table(name)
        t[id] = row
        state[name] = t
    }
    private func now() -> String {
        clock += 1
        state["clock"] = clock
        return String(format: "2026-10-24T10:%02d:%02d.%03dZ", (clock / 60_000) % 60, (clock / 1000) % 60, clock % 1000)
    }
    private func persist() {
        guard let file, let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Seeding (sample data and tests)

    public func seeded() -> Bool { lock.withLock { state["seeded"] as? Bool == true } }

    public func markSeeded() { lock.withLock { state["seeded"] = true; persist() } }

    @discardableResult
    public func seedTask(id: String = UUID().uuidString.lowercased(), scope: String, channel: String, title: String, description: String? = nil,
                         state taskState: String = "new", priority: String = "sand", assignee: String? = nil, creator: String? = nil) -> String {
        lock.withLock {
            let stamp = now()
            put("tasks", id, ["id": id, "workspace_id": workspaceId, "scope_id": scope, "channel_id": channel, "thread_id": NSNull(), "title": title,
                              "description": description ?? NSNull(), "state": taskState, "priority": priority, "metadata": ["assigned_to_npub": (assignee as Any?) ?? NSNull()],
                              "assigned_to_npub": assignee ?? NSNull(), "row_version": 1, "activity_version": 1, "created_by_actor_npub": creator ?? NSNull(),
                              "sender_npub": creator ?? NSNull(), "assignments": [], "created_at": stamp, "updated_at": stamp])
            persist()
            return id
        }
    }

    /// Someone else edits a task (bumps row and activity versions).
    public func externalTaskEdit(_ id: String, fields: [String: Any]) {
        lock.withLock {
            guard var row = table("tasks")[id] else { return }
            for (k, v) in fields { row[k] = v }
            row["row_version"] = ((row["row_version"] as? Int) ?? 1) + 1
            row["activity_version"] = ((row["activity_version"] as? Int) ?? 1) + 1
            row["updated_at"] = now()
            put("tasks", id, row)
            persist()
        }
    }

    public func task(_ id: String) -> [String: Any]? { lock.withLock { table("tasks")[id] } }

    @discardableResult
    public func seedTaskComment(task: String, body: String, sender: String) -> String {
        lock.withLock {
            let id = UUID().uuidString.lowercased(), stamp = now()
            let t = table("tasks")[task] ?? [:]
            put("task_comments", id, ["id": id, "workspace_id": workspaceId, "scope_id": t["scope_id"] ?? NSNull(), "channel_id": t["channel_id"] ?? NSNull(),
                                      "task_id": task, "thread_id": NSNull(), "body": body, "metadata": [:], "row_version": 1, "sender_npub": sender,
                                      "created_by_actor_npub": sender, "created_at": stamp, "updated_at": stamp])
            persist()
            return id
        }
    }

    /// Stores a completed object as if uploaded earlier.
    private func storeObject(_ bytes: Data, contentType: String, name: String) -> String {
        let id = UUID().uuidString.lowercased()
        put("objects", id, ["id": id, "content_type": contentType, "file_name": name, "size_bytes": String(bytes.count), "sha256_hex": SHA256Hex.of(bytes),
                            "is_public": false, "completed_at": now(), "bytes": bytes.base64EncodedString(), "owner_npub": actor])
        return id
    }

    /// The uploaded bytes of a completed storage object (other sample routes that take a `storage_object_id`).
    public func completedObjectBytes(_ id: String) -> Data? {
        lock.withLock {
            guard let row = table("objects")[id], row["completed_at"] is String, let b64 = row["bytes"] as? String else { return nil }
            return Data(base64Encoded: b64)
        }
    }

    /// A stored object on its own (an image referenced from a document or message as `storage://<id>`).
    @discardableResult
    public func seedObject(_ bytes: Data, contentType: String, name: String) -> String {
        lock.withLock {
            let id = storeObject(bytes, contentType: contentType, name: name)
            persist()
            return id
        }
    }

    @discardableResult
    public func seedDoc(id: String = UUID().uuidString.lowercased(), scope: String, channel: String, title: String, body: Data, contentType: String) -> String {
        lock.withLock {
            let object = storeObject(body, contentType: contentType, name: "\(title).document.json")
            let stamp = now()
            put("docs", id, ["id": id, "workspace_id": workspaceId, "scope_id": scope, "channel_id": channel, "storage_object_id": object, "title": title,
                             "summary": DocumentBody(bytes: body, contentType: contentType).markdown, "metadata": ["mentions": []], "row_version": 1,
                             "activity_version": 1, "created_at": stamp, "updated_at": stamp, "archived_at": NSNull(), "record_state": "active"])
            persist()
            return id
        }
    }

    /// Someone else saves a new body (moves the head; a stale native save then becomes a recovery).
    public func externalDocSave(_ id: String, body: Data, contentType: String) {
        lock.withLock {
            guard var row = table("docs")[id] else { return }
            row["storage_object_id"] = storeObject(body, contentType: contentType, name: "external.json")
            row["row_version"] = ((row["row_version"] as? Int) ?? 1) + 1
            row["updated_at"] = now()
            put("docs", id, row)
            persist()
        }
    }

    public func doc(_ id: String) -> [String: Any]? { lock.withLock { table("docs")[id] } }

    public func docBody(_ id: String) -> Data? {
        lock.withLock {
            guard let object = table("docs")[id]?["storage_object_id"] as? String, let b64 = table("objects")[object]?["bytes"] as? String else { return nil }
            return Data(base64Encoded: b64)
        }
    }

    public var recoveryCount: Int { lock.withLock { table("recoveries").count } }

    /// Another editor holds the document's lease.
    public func holdLease(doc: String, by npub: String) {
        lock.withLock {
            put("leases", "held-\(doc)", ["id": UUID().uuidString.lowercased(), "entity_id": doc, "holder": npub, "token": "other", "expires": Int.max])
            persist()
        }
    }

    public func releaseHeldLease(doc: String) { lock.withLock { put("leases", "held-\(doc)", nil); persist() } }

    @discardableResult
    public func seedFile(channel: String, scope: String, name: String, bytes: Data, contentType: String, folder: String? = nil) -> String {
        lock.withLock {
            let object = storeObject(bytes, contentType: contentType, name: name)
            let id = UUID().uuidString.lowercased(), stamp = now()
            put("files", id, fileRow(id: id, channel: channel, scope: scope, object: object, name: name, folder: folder, stamp: stamp))
            persist()
            return id
        }
    }

    private func fileRow(id: String, channel: String, scope: Any, object: String, name: String, folder: String?, stamp: String) -> [String: Any] {
        let meta = table("objects")[object] ?? [:]
        return ["id": id, "workspace_id": workspaceId, "scope_id": scope, "channel_id": channel, "folder_id": folder ?? NSNull(), "storage_object_id": object,
                "current_version_id": NSNull(), "display_name": name, "description": NSNull(), "metadata": [:], "row_version": 1, "created_at": stamp,
                "updated_at": stamp, "archived_at": NSNull(), "record_state": "active", "deleted_at": NSNull(),
                "object": ["object_id": object, "storage_object": ["content_type": meta["content_type"] ?? "application/octet-stream",
                                                                    "size_bytes": meta["size_bytes"] ?? "0", "sha256_hex": meta["sha256_hex"] ?? NSNull(),
                                                                    "file_name": meta["file_name"] ?? name]],
                "current_version": NSNull()]
    }

    @discardableResult
    public func seedFolder(channel: String, scope: String, title: String) -> String {
        lock.withLock {
            let id = UUID().uuidString.lowercased()
            put("folders", id, ["id": id, "workspace_id": workspaceId, "scope_id": scope, "channel_id": channel, "parent_folder_id": NSNull(), "title": title,
                                "metadata": [:], "row_version": 1, "updated_at": now(), "deleted_at": NSNull()])
            persist()
            return id
        }
    }

    public var fileCount: Int { lock.withLock { table("files").count } }
    public func files() -> [[String: Any]] { lock.withLock { Array(table("files").values) } }

    public func seedViewState(type: String, resource: String, scope: String?, channel: String?, activity: Int, viewed: Int, attention: Int? = nil) {
        lock.withLock {
            var row: [String: Any] = ["workspace_id": workspaceId, "viewer_actor_id": "sample", "resource_type": type, "resource_id": resource,
                                      "scope_id": scope ?? NSNull(), "channel_id": channel ?? NSNull(), "activity_version": activity,
                                      "viewed_activity_version": viewed, "unread": activity > viewed, "row_version": 1, "created_at": now(), "updated_at": now()]
            if let attention { row["attention_policy_version"] = 1; row["attention_activity_version"] = attention; row["attention_unread"] = attention > viewed }
            put("view_states", "\(type):\(resource)", row)
            persist()
        }
    }

    public func viewState(type: String, resource: String) -> [String: Any]? { lock.withLock { table("view_states")["\(type):\(resource)"] } }

    public func reactionRows() -> [[String: Any]] { lock.withLock { Array(table("reactions").values) } }
    public func taskComments(_ task: String) -> [[String: Any]] { lock.withLock { table("task_comments").values.filter { $0["task_id"] as? String == task } } }
    public func docComments(_ doc: String) -> [[String: Any]] { lock.withLock { table("doc_comments").values.filter { $0["doc_id"] as? String == doc } } }

    // MARK: Routing

    /// Handles a request for these routes, or returns nil for routes it does not own (chat, discovery).
    public func handle(_ request: URLRequest) throws -> (Int, Any)? {
        guard let url = request.url else { return nil }
        if url.host == objectHost { return try presignedPut(request) }
        let path = url.path
        let base = "/api/v4/flightdeck-pg/workspaces/\(workspaceId)"
        let isStorage = path.hasPrefix("/api/v4/storage/")
        guard isStorage || path.hasPrefix(base + "/") else { return nil }
        let parts = isStorage ? Array(path.dropFirst("/api/v4/storage/".count).split(separator: "/").map(String.init))
                              : path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        guard isStorage || Self.owns(parts, method: method) else { return nil }
        let body = request.httpBody ?? Data()
        guard verify(request, body: body) else { return (401, ["code": "unauthorized", "error": "invalid NIP-98"]) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fault: Fault? = lock.withLock {
            log.append("\(method) \(path)")
            guard let index = faults.firstIndex(where: { path.hasSuffix($0.match) || path.contains($0.match) }) else { return nil }
            return faults.remove(at: index).fault
        }
        if case .offline = fault { throw URLError(.notConnectedToInternet) }
        if case .status(let status, let code) = fault { return (status, ["code": code, "error": code]) }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let result = lock.withLock { () -> (Int, Any) in
            let r = isStorage ? storage(parts, method: method, object: object) : route(parts, method: method, object: object, query: query)
            persist()
            return r
        }
        if case .dropResponseAfterCommit = fault { throw URLError(.networkConnectionLost) }
        return result
    }

    static func owns(_ p: [String], method: String) -> Bool {
        guard let first = p.first else { return false }
        switch first {
        case "tasks", "docs", "files", "edit-leases", "resource-view-states", "reactions", "storage": return true
        case "channels": return p.count == 3 && ["tasks", "docs", "files", "file-folders"].contains(p[2])
        default: return false
        }
    }

    private func verify(_ request: URLRequest, body: Data) -> Bool {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Nostr "),
              let data = Data(base64Encoded: String(header.dropFirst(6))), let event = try? JSONDecoder().decode(NostrEvent.self, from: data),
              SignatureVerifier.verify(event), event.kind == 27235, event.tags.contains(["u", request.url!.absoluteString]),
              event.tags.contains(["method", (request.httpMethod ?? "GET").uppercased()]) else { return false }
        let payload = event.tags.first { $0.first == "payload" }?.last
        if body.isEmpty { return payload == nil } else { return payload == SHA256Hex.of(body) }
    }

    private func presignedPut(_ request: URLRequest) throws -> (Int, Any) {
        lock.withLock {
            if request.value(forHTTPHeaderField: "Authorization") != nil || request.value(forHTTPHeaderField: "Cookie") != nil {
                credentialLeaks.append(request.url!)
            }
            log.append("PUT presigned \(request.url!.path)")
        }
        guard request.httpMethod == "PUT", let id = request.url!.pathComponents.last else { return (400, ["error": "bad request"]) }
        if let fault = lock.withLock({ () -> Fault? in
            guard let index = faults.firstIndex(where: { $0.match == "presigned" }) else { return nil }
            return faults.remove(at: index).fault
        }) {
            if case .offline = fault { throw URLError(.notConnectedToInternet) }
            if case .status(let s, _) = fault { return (s, Data()) }
        }
        return lock.withLock {
            guard var row = table("objects")[id], row["completed_at"] is NSNull || row["completed_at"] == nil else { return (403, Data()) }
            row["bytes"] = (request.httpBody ?? Data()).base64EncodedString()
            put("objects", id, row)
            persist()
            return (200, Data())
        }
    }

    private func error(_ status: Int, _ code: String, _ extra: [String: Any] = [:]) -> (Int, Any) {
        (status, ["code": code, "error": code].merging(extra) { a, _ in a })
    }

    private func page(_ rows: [[String: Any]], key: String, query: [URLQueryItem], extra: [String: Any] = [:]) -> (Int, Any) {
        let limit = min(200, Int(query.first { $0.name == "limit" }?.value ?? "50") ?? 50)
        let start = query.first { $0.name == "cursor" }?.value.flatMap { Int($0.dropFirst(4)) } ?? 0
        let slice = Array(rows.dropFirst(start).prefix(limit))
        let more = start + slice.count < rows.count
        return (200, [key: slice, "next_cursor": more ? "idx:\(start + slice.count)" : NSNull() as Any, "has_more": more].merging(extra) { a, _ in a })
    }

    private func route(_ p: [String], method: String, object: [String: Any], query: [URLQueryItem]) -> (Int, Any) {
        switch (method, p.count, p[0]) {
        case ("GET", 3, "channels") where p[2] == "tasks":
            let rows = table("tasks").values.filter { $0["channel_id"] as? String == p[1] }.sorted { ($0["updated_at"] as! String) > ($1["updated_at"] as! String) }
            return page(rows, key: "tasks", query: query, extra: ["channel_id": p[1]])
        case ("POST", 3, "channels") where p[2] == "tasks": return createTask(channel: p[1], object)
        case ("GET", 2, "tasks"): return table("tasks")[p[1]].map { (200, ["task": $0]) } ?? error(404, "task_not_found")
        case ("PATCH", 2, "tasks"): return patchTask(p[1], object)
        case ("POST", 3, "tasks") where p[2] == "state":
            guard var row = table("tasks")[p[1]] else { return error(404, "task_not_found") }
            let s = object["state"] as? String ?? ""
            guard TaskState(rawValue: s) != nil else { return error(400, "validation_error", ["details": ["fields": [["message": "state is not a valid task state"]]]]) }
            row["state"] = s; bump(&row); put("tasks", p[1], row)
            return (200, ["task": row])
        case ("GET", 3, "tasks") where p[2] == "comments":
            guard table("tasks")[p[1]] != nil else { return error(404, "task_not_found") }
            return page(table("task_comments").values.filter { $0["task_id"] as? String == p[1] }.sorted { ($0["created_at"] as! String) < ($1["created_at"] as! String) },
                        key: "comments", query: query, extra: ["task_id": p[1]])
        case ("POST", 3, "tasks") where p[2] == "comments":
            guard var t = table("tasks")[p[1]] else { return error(404, "task_not_found") }
            let text = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return error(400, "validation_error", ["details": ["fields": [["message": "body must be a non-empty string"]]]]) }
            let id = UUID().uuidString.lowercased(), stamp = now()
            let row: [String: Any] = ["id": id, "workspace_id": workspaceId, "scope_id": t["scope_id"] ?? NSNull(), "channel_id": t["channel_id"] ?? NSNull(),
                                      "task_id": p[1], "thread_id": NSNull(), "body": text, "metadata": object["metadata"] ?? [:], "row_version": 1,
                                      "created_by_actor_npub": actor, "sender_npub": actor, "created_at": stamp, "updated_at": stamp]
            put("task_comments", id, row)
            t["activity_version"] = ((t["activity_version"] as? Int) ?? 1) + 1; put("tasks", p[1], t)
            return (201, ["comment": row])

        case ("GET", 3, "channels") where p[2] == "docs":
            let rows = table("docs").values.filter { $0["channel_id"] as? String == p[1] && $0["archived_at"] is NSNull }
            return (200, ["docs": rows.map(docOut), "channel_id": p[1], "next_cursor": NSNull()])
        case ("POST", 3, "channels") where p[2] == "docs":
            guard let objectId = object["storage_object_id"] as? String, let o = table("objects")[objectId], o["completed_at"] is String else {
                return error(400, "validation_error")
            }
            if table("docs").values.contains(where: { $0["storage_object_id"] as? String == objectId }) { return error(409, "doc_storage_object_conflict") }
            let id = UUID().uuidString.lowercased(), stamp = now()
            let row: [String: Any] = ["id": id, "workspace_id": workspaceId, "scope_id": "", "channel_id": p[1], "storage_object_id": objectId,
                                      "title": object["title"] ?? "Untitled", "summary": object["summary"] ?? NSNull(), "metadata": ["mentions": []],
                                      "row_version": 1, "activity_version": 1, "created_at": stamp, "updated_at": stamp, "archived_at": NSNull(), "record_state": "active"]
            put("docs", id, row)
            return (201, ["doc": docOut(row)])
        case ("GET", 2, "docs"): return table("docs")[p[1]].map { (200, ["doc": docOut($0)]) } ?? error(404, "doc_not_found")
        case ("GET", 3, "docs") where p[2] == "body":
            guard let d = table("docs")[p[1]], let objectId = d["storage_object_id"] as? String, let o = table("objects")[objectId],
                  let b64 = o["bytes"] as? String else { return error(404, "doc_body_not_found") }
            return (200, ["doc": docOut(d), "body": ["object_id": objectId, "content_type": o["content_type"] ?? "", "size_bytes": Data(base64Encoded: b64)?.count ?? 0,
                                                     "sha256_hex": o["sha256_hex"] ?? NSNull(), "encoding": "base64", "base64_data": b64]])
        case ("PATCH", 2, "docs"): return patchDoc(p[1], object)
        case ("GET", 3, "docs") where p[2] == "comments":
            guard table("docs")[p[1]] != nil else { return error(404, "doc_not_found") }
            return page(table("doc_comments").values.filter { $0["doc_id"] as? String == p[1] }.sorted { ($0["created_at"] as! String) < ($1["created_at"] as! String) },
                        key: "comments", query: query, extra: ["doc_id": p[1]])
        case ("POST", 3, "docs") where p[2] == "comments":
            guard let d = table("docs")[p[1]] else { return error(404, "doc_not_found") }
            let text = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return error(400, "validation_error") }
            let id = UUID().uuidString.lowercased(), stamp = now()
            let row: [String: Any] = ["id": id, "workspace_id": workspaceId, "scope_id": d["scope_id"] ?? NSNull(), "channel_id": d["channel_id"] ?? NSNull(),
                                      "doc_id": p[1], "parent_comment_id": object["parent_comment_id"] ?? NSNull(), "body": text,
                                      "metadata": object["metadata"] ?? [:], "record_state": "active", "deleted_at": NSNull(), "row_version": 1,
                                      "created_by_actor_npub": actor, "sender_npub": actor, "created_at": stamp, "updated_at": stamp]
            put("doc_comments", id, row)
            return (201, ["comment": row])
        case ("PATCH", 4, "docs") where p[2] == "comments":
            guard var c = table("doc_comments")[p[3]] else { return error(404, "doc_comment_not_found") }
            guard object["row_version"] as? Int == c["row_version"] as? Int else { return error(409, "stale_row_version") }
            var meta = (c["metadata"] as? [String: Any]) ?? [:]
            meta["comment_status"] = object["comment_status"] ?? "open"
            c["metadata"] = meta; c["row_version"] = ((c["row_version"] as? Int) ?? 1) + 1; c["updated_at"] = now()
            put("doc_comments", p[3], c)
            return (200, ["comment": c])

        case ("POST", 2, "edit-leases") where p[1] == "acquire":
            let entity = object["entity_id"] as? String ?? ""
            if let held = table("leases")["held-\(entity)"] { return error(409, "edit_lease_held", ["details": ["holder_actor_npub": held["holder"] ?? "", "expires_at": "later"]]) }
            let id = UUID().uuidString.lowercased(), token = UUID().uuidString.lowercased()
            put("leases", id, ["id": id, "entity_id": entity, "holder": actor, "token": token])
            return (201, ["lease": ["id": id, "entity_type": "document", "entity_id": entity, "field_path": NSNull(), "lease_token": token,
                                    "holder_actor_npub": actor, "expires_at": "2026-10-24T11:00:00.000Z"]])
        case ("POST", 3, "edit-leases") where p[2] == "renew":
            guard let lease = table("leases")[p[1]], lease["token"] as? String == object["lease_token"] as? String else { return error(409, "lease_invalid") }
            return (200, ["lease": ["id": p[1], "entity_type": "document", "entity_id": lease["entity_id"] ?? "", "holder_actor_npub": actor,
                                    "expires_at": "2026-10-24T11:05:00.000Z"]])
        case ("POST", 3, "edit-leases") where p[2] == "release":
            let released = table("leases")[p[1]]?["token"] as? String == object["lease_token"] as? String
            if released { put("leases", p[1], nil) }
            return (200, ["released": released])

        case ("GET", 3, "channels") where p[2] == "files":
            return (200, ["files": table("files").values.filter { $0["channel_id"] as? String == p[1] && $0["deleted_at"] is NSNull }, "next_cursor": NSNull()])
        case ("GET", 3, "channels") where p[2] == "file-folders":
            return (200, ["folders": table("folders").values.filter { $0["channel_id"] as? String == p[1] }, "next_cursor": NSNull()])
        case ("POST", 3, "channels") where p[2] == "files":
            guard let objectId = object["storage_object_id"] as? String, let o = table("objects")[objectId], o["completed_at"] is String else {
                return error(400, "validation_error")
            }
            if table("files").values.contains(where: { $0["storage_object_id"] as? String == objectId }) { return error(409, "file_storage_object_conflict") }
            let id = UUID().uuidString.lowercased()
            let row = fileRow(id: id, channel: p[1], scope: NSNull(), object: objectId, name: (object["display_name"] as? String) ?? "file",
                              folder: object["folder_id"] as? String, stamp: now())
            put("files", id, row)
            return (201, ["file": row])
        case ("GET", 3, "files") where p[2] == "object":
            guard let f = table("files")[p[1]], let objectId = f["storage_object_id"] as? String, let o = table("objects")[objectId],
                  let b64 = o["bytes"] as? String else { return error(404, "file_object_not_found") }
            return (200, ["file": f, "object": ["object_id": objectId, "content_type": o["content_type"] ?? "", "file_name": o["file_name"] ?? "",
                                                 "size_bytes": Data(base64Encoded: b64)?.count ?? 0, "sha256_hex": o["sha256_hex"] ?? NSNull(),
                                                 "encoding": "base64", "base64_data": b64]])

        case ("GET", 1, "resource-view-states"):
            return page(table("view_states").values.sorted { ($0["resource_id"] as! String) < ($1["resource_id"] as! String) }, key: "states", query: query,
                        extra: ["baseline_created": false])
        case ("PUT", 3, "resource-view-states"):
            guard var row = table("view_states")["\(p[1]):\(p[2])"] else { return error(404, "resource_not_found") }
            let requested = object["viewed_activity_version"] as? Int ?? -1
            guard requested >= 0 else { return error(400, "validation_error") }
            guard requested <= (row["activity_version"] as? Int ?? 0) else { return error(409, "activity_version_ahead") }
            row["viewed_activity_version"] = max(requested, row["viewed_activity_version"] as? Int ?? 0)
            row["unread"] = (row["activity_version"] as? Int ?? 0) > (row["viewed_activity_version"] as? Int ?? 0)
            if let attention = row["attention_activity_version"] as? Int { row["attention_unread"] = attention > (row["viewed_activity_version"] as? Int ?? 0) }
            row["row_version"] = (row["row_version"] as? Int ?? 1) + 1
            put("view_states", "\(p[1]):\(p[2])", row)
            return (200, ["state": row, "changed": true])
        case ("POST", 2, "resource-view-states") where p[1] == "mark-viewed":
            var states: [[String: Any]] = []
            for r in (object["resources"] as? [[String: Any]]) ?? [] {
                let key = "\(r["resource_type"] as? String ?? ""):\(r["resource_id"] as? String ?? "")"
                guard var row = table("view_states")[key] else { return error(404, "resource_not_found") }
                row["viewed_activity_version"] = row["activity_version"]; row["unread"] = false; row["attention_unread"] = false
                row["row_version"] = (row["row_version"] as? Int ?? 1) + 1
                put("view_states", key, row)
                states.append(row)
            }
            return (200, ["states": states, "changed_count": states.count])

        case ("GET", 1, "reactions"):
            let target = query.first { $0.name == "target_id" }?.value ?? ""
            return (200, ["reactions": table("reactions").values.filter { $0["target_id"] as? String == target }, "next_cursor": NSNull()])
        case ("POST", 1, "reactions"):
            let emoji = object["emoji"] as? String ?? ""
            guard ReactionEmoji(rawValue: emoji) != nil else { return error(400, "validation_error") }
            let id = UUID().uuidString.lowercased()
            let row: [String: Any] = ["id": id, "workspace_id": workspaceId, "target_type": object["target_type"] ?? "message", "target_id": object["target_id"] ?? "",
                                      "emoji": emoji, "reactor_npub": actor, "record_state": "active", "row_version": 1, "updated_at": now()]
            put("reactions", id, row)
            return (201, ["reaction": row])
        case ("DELETE", 2, "reactions"):
            guard table("reactions")[p[1]] != nil else { return error(404, "reaction_not_found") }
            put("reactions", p[1], nil)
            return (200, ["reaction": ["id": p[1], "record_state": "deleted"]])

        case ("POST", 2, "storage") where p[1] == "prepare":
            guard let type = object["content_type"] as? String, !type.isEmpty else { return error(400, "validation_error") }
            guard object["is_public"] as? Bool != true else { return error(400, "validation_error") }
            let id = UUID().uuidString.lowercased()
            put("objects", id, ["id": id, "content_type": type, "file_name": object["file_name"] ?? NSNull(), "size_bytes": NSNull(), "sha256_hex": NSNull(),
                                "is_public": false, "completed_at": NSNull(), "owner_npub": actor])
            let presigned = state["fallback_uploads"] as? Bool == true
                ? "\(towerOrigin)/api/v4/storage/\(id)"
                : "https://\(objectHost)/bucket/\(id)?X-Amz-Signature=sample"
            return (201, ["object_id": id, "is_public": false, "upload_url": presigned, "content_type": type])
        default:
            return error(404, "not_found")
        }
    }

    /// Tower's API-fallback upload path (`upload_url` on the Tower origin) instead of a presigned host.
    public func useFallbackUploads(_ on: Bool) { lock.withLock { state["fallback_uploads"] = on } }

    private func storage(_ p: [String], method: String, object: [String: Any]) -> (Int, Any) {
        guard let id = p.first, var row = table("objects")[id] else { return (404, ["error": "storage object not found"]) }
        switch (method, p.count) {
        case ("GET", 1):
            var meta = row
            meta["bytes"] = nil
            meta["object_id"] = id
            return (200, meta)
        case ("PUT", 1):
            guard let b64 = object["base64_data"] as? String, Data(base64Encoded: b64) != nil else { return (400, ["error": "base64_data required"]) }
            row["bytes"] = b64
            put("objects", id, row)
            return (200, ["object_id": id])
        case ("POST", 2) where p[1] == "complete":
            guard let b64 = row["bytes"] as? String, let bytes = Data(base64Encoded: b64) else { return (409, ["error": "storage upload missing"]) }
            guard SHA256Hex.of(bytes) == (object["sha256_hex"] as? String), object["size_bytes"] as? Int == bytes.count else {
                return (409, ["error": "storage SHA-256 mismatch"])
            }
            row["sha256_hex"] = SHA256Hex.of(bytes); row["size_bytes"] = String(bytes.count); row["completed_at"] = now()
            put("objects", id, row)
            return (200, ["object_id": id, "completed_at": row["completed_at"]!, "size_bytes": row["size_bytes"]!])
        case ("GET", 2) where p[1] == "content":
            guard let b64 = row["bytes"] as? String, let bytes = Data(base64Encoded: b64), row["completed_at"] is String else { return (409, ["error": "incomplete"]) }
            return (200, bytes)
        default:
            return (404, ["error": "not found"])
        }
    }

    private func docOut(_ row: [String: Any]) -> [String: Any] {
        var out = row
        out["body"] = ["object_id": row["storage_object_id"] ?? NSNull(), "route": "/api/v4/flightdeck-pg/workspaces/\(workspaceId)/docs/\(row["id"] ?? "")/body"]
        return out
    }

    private func bump(_ row: inout [String: Any]) {
        row["row_version"] = ((row["row_version"] as? Int) ?? 1) + 1
        row["activity_version"] = ((row["activity_version"] as? Int) ?? 1) + 1
        row["updated_at"] = now()
    }

    private func createTask(channel: String, _ o: [String: Any]) -> (Int, Any) {
        let title = (o["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return error(400, "validation_error", ["details": ["fields": [["message": "title must be a non-empty string"]]]]) }
        let requestId = o["client_request_id"] as? String
        var hashed = o
        hashed["client_request_id"] = nil
        let hash = SHA256Hex.of((try? JSONSerialization.data(withJSONObject: hashed, options: [.sortedKeys])) ?? Data())
        if let requestId, let prior = table("requests")[requestId] {
            guard prior["hash"] as? String == hash, let id = prior["task_id"] as? String, let task = table("tasks")[id] else { return error(409, "idempotency_conflict") }
            return (200, ["task": task, "replayed": true])
        }
        let id = UUID().uuidString.lowercased(), stamp = now()
        let assignee = (o["assigned_to_npub"] as? String) ?? nil
        let row: [String: Any] = ["id": id, "workspace_id": workspaceId, "scope_id": NSNull(), "channel_id": channel, "thread_id": NSNull(), "title": title,
                                  "description": o["description"] ?? NSNull(), "state": o["state"] ?? "new", "priority": o["priority"] ?? "sand",
                                  "metadata": ["assigned_to_npub": (assignee as Any?) ?? NSNull()], "assigned_to_npub": assignee ?? NSNull(), "row_version": 1,
                                  "activity_version": 1, "created_by_actor_npub": actor, "sender_npub": actor, "assignments": [],
                                  "created_at": stamp, "updated_at": stamp]
        put("tasks", id, row)
        if let requestId { put("requests", requestId, ["hash": hash, "task_id": id]) }
        return (201, ["task": row])
    }

    private func patchTask(_ id: String, _ o: [String: Any]) -> (Int, Any) {
        guard var row = table("tasks")[id] else { return error(404, "task_not_found") }
        // Tower checks row_version only when the assignee (or relationships) change.
        if o.keys.contains("assigned_to_npub") {
            guard o["row_version"] as? Int == row["row_version"] as? Int else { return error(409, "stale_row_version") }
            let npub = (o["assigned_to_npub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            row["assigned_to_npub"] = npub ?? NSNull()
            row["metadata"] = ["assigned_to_npub": (npub as Any?) ?? NSNull()]
        }
        if let t = o["title"] as? String {
            guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return error(400, "validation_error") }
            row["title"] = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if o.keys.contains("description") { row["description"] = o["description"] is NSNull ? NSNull() : (o["description"] as? String ?? "") }
        if let pr = o["priority"] as? String {
            guard TaskPriority(rawValue: pr) != nil else { return error(400, "validation_error") }
            row["priority"] = pr
        }
        bump(&row)
        put("tasks", id, row)
        return (200, ["task": row])
    }

    private func patchDoc(_ id: String, _ o: [String: Any]) -> (Int, Any) {
        guard var row = table("docs")[id] else { return error(404, "doc_not_found") }
        guard let objectId = o["storage_object_id"] as? String else {
            if let t = o["title"] as? String { row["title"] = t }
            bump(&row); put("docs", id, row)
            return (200, ["doc": docOut(row)])
        }
        guard let submitted = table("objects")[objectId], submitted["completed_at"] is String else { return error(400, "validation_error") }
        let head = table("objects")[row["storage_object_id"] as? String ?? ""] ?? [:]
        let stale = o["row_version"] as? Int != row["row_version"] as? Int || (o["base_body_sha256_hex"] as? String) != (head["sha256_hex"] as? String)
        if stale {
            let recovery = UUID().uuidString.lowercased()
            put("recoveries", recovery, ["id": recovery, "doc_id": id, "storage_object_id": objectId])
            return error(409, "document_recovery_created", ["recovery": ["id": recovery], "canonical_advanced": false])
        }
        let token = o["lease_token"] as? String
        guard table("leases").values.contains(where: { $0["entity_id"] as? String == id && $0["token"] as? String == token && $0["holder"] as? String == actor }) else {
            return error(409, "lease_required")
        }
        row["storage_object_id"] = objectId
        if let t = o["title"] as? String { row["title"] = t }
        if let s = o["summary"] as? String { row["summary"] = s }
        bump(&row)
        put("docs", id, row)
        return (200, ["doc": docOut(row), "canonical_version": ["row_version": row["row_version"]!, "storage_object_id": objectId,
                                                                "body_sha256_hex": submitted["sha256_hex"] ?? NSNull()]])
    }
}
