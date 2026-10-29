import Foundation

/// Tower routes for tasks, documents, files, view states, reactions, leases and storage, read from
/// `tower/src/routes/flightdeck-pg.ts` and `routes/storage.ts`. Paths are built only from validated UUIDs, and every
/// response is checked to belong to the requested workspace before it is materialised.
extension TowerAPI {
    func object(_ data: Data, _ what: String) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TowerError.malformed(what) }
        return o
    }

    /// Forward-paged list (`limit ≤ 200`, opaque `next_cursor`, `has_more`).
    func pages(_ path: String, appNpub: String, key: String, query extra: [URLQueryItem] = [], maxPages: Int = 50) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<maxPages {
            var query = [URLQueryItem(name: "limit", value: "200")] + extra
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let o = try object(try await client.request(path: path, query: query, appNpub: appNpub), key)
            guard let page = o[key] as? [[String: Any]] else { throw TowerError.malformed(key) }
            rows += page
            guard let next = o["next_cursor"] as? String, !next.isEmpty else { return rows }
            guard seen.insert(next).inserted else { throw TowerError.malformed("\(key) cursor") }
            cursor = next
        }
        throw TowerError.listLimitReached(key)
    }

    // MARK: Tasks

    public func channelTasks(workspaceId: String, appNpub: String, channelId: String) async throws -> [TaskRecord] {
        let rows = try await pages(try Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/tasks", appNpub: appNpub, key: "tasks")
        let tasks = try rows.map { try TaskRecord(raw: rawJSON($0)) }
        guard tasks.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId }) else { throw TowerError.malformed("tasks") }
        return tasks
    }

    public func task(workspaceId: String, appNpub: String, taskId: String) async throws -> TaskRecord {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/tasks/" + Self.uuid(taskId), appNpub: appNpub), "task")
        guard let row = o["task"] as? [String: Any] else { throw TowerError.malformed("task") }
        let task = try TaskRecord(raw: rawJSON(row))
        guard task.workspaceId == workspaceId, task.id == taskId.lowercased() else { throw TowerError.malformed("task") }
        return task
    }

    public func taskComments(workspaceId: String, appNpub: String, taskId: String) async throws -> [CommentRecord] {
        let rows = try await pages(try Self.base(workspaceId) + "/tasks/" + Self.uuid(taskId) + "/comments", appNpub: appNpub, key: "comments")
        return try rows.map { try CommentRecord(raw: rawJSON($0), parent: .task) }.filter { $0.workspaceId == workspaceId && $0.parentId == taskId.lowercased() }
    }

    // MARK: Documents

    /// Tower returns one page (≤ 200) with `next_cursor: null`; a full page is reported as possibly incomplete.
    public func channelDocs(workspaceId: String, appNpub: String, channelId: String) async throws -> (docs: [DocRecord], complete: Bool) {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/docs",
                                                    query: [URLQueryItem(name: "limit", value: "200")], appNpub: appNpub), "docs")
        guard let rows = o["docs"] as? [[String: Any]] else { throw TowerError.malformed("docs") }
        let docs = try rows.map { try DocRecord(raw: rawJSON($0)) }
        guard docs.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId }) else { throw TowerError.malformed("docs") }
        return (docs, rows.count < 200)
    }

    public func doc(workspaceId: String, appNpub: String, docId: String) async throws -> DocRecord {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/docs/" + Self.uuid(docId), appNpub: appNpub), "document")
        guard let row = o["doc"] as? [String: Any] else { throw TowerError.malformed("document") }
        let doc = try DocRecord(raw: rawJSON(row))
        guard doc.workspaceId == workspaceId, doc.id == docId.lowercased() else { throw TowerError.malformed("document") }
        return doc
    }

    /// The canonical body with the document row it belongs to. The bytes must hash to Tower's sha256 when Tower
    /// reports one; a body that does not match is refused rather than shown or used as an edit base.
    public func docBody(workspaceId: String, appNpub: String, docId: String) async throws -> (doc: DocRecord, body: DocBodyRecord) {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/docs/" + Self.uuid(docId) + "/body", appNpub: appNpub), "document body")
        guard let row = o["doc"] as? [String: Any], let body = o["body"] as? [String: Any],
              body["encoding"] as? String == "base64", let encoded = body["base64_data"] as? String,
              let bytes = Data(base64Encoded: encoded), let objectId = lowerUUID(body["object_id"] as? String) else { throw TowerError.malformed("document body") }
        let doc = try DocRecord(raw: rawJSON(row))
        guard doc.workspaceId == workspaceId, doc.id == docId.lowercased(), doc.storageObjectId == objectId else { throw TowerError.malformed("document body") }
        let computed = SHA256Hex.of(bytes)
        if let reported = (body["sha256_hex"] as? String)?.lowercased(), reported != computed { throw DocumentBodyError.integrity }
        let record = DocBodyRecord(workspaceId: workspaceId, docId: doc.id, storageObjectId: objectId,
                                   sha256: (body["sha256_hex"] as? String)?.lowercased() ?? computed,
                                   contentType: (body["content_type"] as? String) ?? "", docRowVersion: doc.rowVersion, bytes: bytes,
                                   fetchedAt: ISO8601DateFormatter.tower.string(from: Date()))
        return (doc, record)
    }

    public func docComments(workspaceId: String, appNpub: String, docId: String) async throws -> [CommentRecord] {
        let rows = try await pages(try Self.base(workspaceId) + "/docs/" + Self.uuid(docId) + "/comments", appNpub: appNpub, key: "comments")
        return try rows.map { try CommentRecord(raw: rawJSON($0), parent: .doc) }.filter { $0.workspaceId == workspaceId && $0.parentId == docId.lowercased() }
    }

    // MARK: Files

    public func channelFiles(workspaceId: String, appNpub: String, channelId: String) async throws -> (files: [FileRecord], complete: Bool) {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/files",
                                                    query: [URLQueryItem(name: "limit", value: "200")], appNpub: appNpub), "files")
        guard let rows = o["files"] as? [[String: Any]] else { throw TowerError.malformed("files") }
        let files = try rows.map { try FileRecord(raw: rawJSON($0)) }
        guard files.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId }) else { throw TowerError.malformed("files") }
        return (files, rows.count < 200)
    }

    public func channelFolders(workspaceId: String, appNpub: String, channelId: String) async throws -> (folders: [FolderRecord], complete: Bool) {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/file-folders",
                                                    query: [URLQueryItem(name: "limit", value: "200")], appNpub: appNpub), "folders")
        guard let rows = o["folders"] as? [[String: Any]] else { throw TowerError.malformed("folders") }
        let folders = try rows.map { try FolderRecord(raw: rawJSON($0)) }
        guard folders.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId }) else { throw TowerError.malformed("folders") }
        return (folders, rows.count < 200)
    }

    public static let maxDownloadBytes = 100 * 1024 * 1024

    /// File content through the typed object route (base64 with sha256). The bytes must match Tower's hash.
    public func fileObject(workspaceId: String, appNpub: String, fileId: String) async throws -> (bytes: Data, contentType: String?, fileName: String?, sha256: String) {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/object", appNpub: appNpub), "file")
        guard let row = o["file"] as? [String: Any], let object = o["object"] as? [String: Any], object["encoding"] as? String == "base64",
              let encoded = object["base64_data"] as? String else { throw TowerError.malformed("file") }
        guard encoded.utf8.count / 4 * 3 <= Self.maxDownloadBytes else { throw FileTransferError.tooLarge }
        guard let bytes = Data(base64Encoded: encoded) else { throw TowerError.malformed("file") }
        let file = try FileRecord(raw: rawJSON(row))
        guard file.workspaceId == workspaceId, file.id == fileId.lowercased() else { throw TowerError.malformed("file") }
        let computed = SHA256Hex.of(bytes)
        if let reported = (object["sha256_hex"] as? String)?.lowercased(), reported != computed { throw FileTransferError.integrity }
        return (bytes, object["content_type"] as? String, object["file_name"] as? String, computed)
    }

    /// Raw storage content (`GET /api/v4/storage/:id/content`) for chat attachments, signed, on the pinned origin only.
    public func storageContent(objectId: String) async throws -> Data {
        try await client.request(path: "/api/v4/storage/" + Self.uuid(objectId) + "/content")
    }

    // MARK: Inbox

    public func viewStates(workspaceId: String, appNpub: String) async throws -> [ViewStateRecord] {
        let rows = try await pages(try Self.base(workspaceId) + "/resource-view-states", appNpub: appNpub, key: "states")
        return rows.compactMap { try? ViewStateRecord(raw: rawJSON($0)) }.filter { $0.workspaceId == workspaceId }
    }

    // MARK: Messages and reactions

    public func message(workspaceId: String, appNpub: String, messageId: String) async throws -> MessageRecord? {
        do {
            let o = try object(try await client.request(path: try Self.base(workspaceId) + "/messages/" + Self.uuid(messageId), appNpub: appNpub), "message")
            guard let row = o["message"] as? [String: Any] else { throw TowerError.malformed("message") }
            let message = try MessageRecord(raw: rawJSON(row))
            guard message.workspaceId == workspaceId else { throw TowerError.malformed("message") }
            return message
        } catch TowerError.http(404, _, _) {
            return nil
        }
    }

    public func reactions(workspaceId: String, appNpub: String, targetType: String, targetId: String) async throws -> [ReactionRecord] {
        let o = try object(try await client.request(path: try Self.base(workspaceId) + "/reactions",
                                                    query: [URLQueryItem(name: "target_type", value: targetType), URLQueryItem(name: "target_id", value: try Self.uuid(targetId)),
                                                            URLQueryItem(name: "limit", value: "200")], appNpub: appNpub), "reactions")
        guard let rows = o["reactions"] as? [[String: Any]] else { throw TowerError.malformed("reactions") }
        return rows.compactMap { try? ReactionRecord(raw: rawJSON($0)) }.filter { $0.workspaceId == workspaceId && $0.targetId == targetId.lowercased() }
    }
}

public enum DocumentBodyError: LocalizedError, Equatable, Sendable {
    case integrity
    public var errorDescription: String? { "The document body Tower returned does not match its checksum; it was not used." }
}

public enum FileTransferError: LocalizedError, Equatable, Sendable {
    case integrity, tooLarge, unsafeUploadURL, fallbackTooLarge, notAttachable
    public var errorDescription: String? {
        switch self {
        case .integrity: "The file Tower returned does not match its checksum; it was not saved."
        case .tooLarge: "This file is larger than this app downloads (100 MB)."
        case .unsafeUploadURL: "Tower offered an upload address this app does not trust; nothing was uploaded."
        case .fallbackTooLarge: "This Tower only accepts uploads through its API, limited to 8 MB."
        case .notAttachable: "Tower did not confirm the uploaded file."
        }
    }
}

// MARK: Edit leases

public struct EditLease: Sendable, Equatable {
    public let id: String
    public let token: String
    public let expiresAt: String
    public let documentEditProtocol: String?
    public let editorSessionId: String?

    public init(id: String, token: String, expiresAt: String, documentEditProtocol: String? = nil, editorSessionId: String? = nil) {
        self.id = id; self.token = token; self.expiresAt = expiresAt
        self.documentEditProtocol = documentEditProtocol; self.editorSessionId = editorSessionId
    }
}

public enum LeaseError: LocalizedError, Equatable, Sendable {
    case held(by: String?, until: String?)
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .held(let by, _): "Someone else is editing this document" + (by.map { " (\(shortLabel($0)))" } ?? "") + ". Your changes stay on this device."
        case .invalid(let code): "The edit lease is no longer valid (\(code)). Reopen the editor to continue."
        }
    }
}

extension TowerAPI {
    public static let leaseSeconds = 120

    public func acquireLease(workspaceId: String, appNpub: String, entityType: String, entityId: String, editorSessionId: String? = nil, takeoverLeaseId: String? = nil) async throws -> EditLease {
        var fields: [String: Any] = ["entity_type": entityType, "entity_id": try Self.uuid(entityId), "ttl_seconds": Self.leaseSeconds]
        if entityType == "document", let editorSessionId {
            fields["document_edit_protocol"] = Self.documentEditProtocol
            fields["editor_session_id"] = try Self.uuid(editorSessionId)
        }
        if let takeoverLeaseId { fields["takeover"] = true; fields["expected_lease_id"] = try Self.uuid(takeoverLeaseId) }
        let body = try rawJSON(fields)
        let reply = try await client.exchange(method: "POST", path: try Self.base(workspaceId) + "/edit-leases/acquire", appNpub: appNpub, jsonBody: body)
        let o = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        if reply.status == 409 {
            let details = (o?["details"] as? [String: Any]) ?? o
            throw LeaseError.held(by: details?["holder_actor_npub"] as? String, until: details?["expires_at"] as? String)
        }
        guard (200..<300).contains(reply.status) else { throw TowerError.http(status: reply.status, code: o?["code"] as? String, stage: "edit lease") }
        guard let lease = o?["lease"] as? [String: Any], let id = lease["id"] as? String, let token = lease["lease_token"] as? String,
              lease["entity_id"] as? String == entityId.lowercased() || (lease["entity_id"] as? String)?.lowercased() == entityId.lowercased()
        else { throw TowerError.malformed("edit lease") }
        let marker = o?["document_edit_protocol"] as? String
        if takeoverLeaseId != nil, marker != Self.documentEditProtocol { throw LeaseError.invalid("takeover_not_supported") }
        return EditLease(id: id, token: token, expiresAt: (lease["expires_at"] as? String) ?? "", documentEditProtocol: marker,
                         editorSessionId: lease["editor_session_id"] as? String)
    }

    public func renewLease(workspaceId: String, appNpub: String, lease: EditLease) async throws -> EditLease {
        let body = try rawJSON(["lease_token": lease.token, "ttl_seconds": Self.leaseSeconds])
        let reply = try await client.exchange(method: "POST", path: try Self.base(workspaceId) + "/edit-leases/" + Self.uuid(lease.id) + "/renew",
                                              appNpub: appNpub, jsonBody: body)
        let o = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        if reply.status == 409 { throw LeaseError.invalid(o?["code"] as? String ?? "expired") }
        guard (200..<300).contains(reply.status), let next = o?["lease"] as? [String: Any] else {
            throw TowerError.http(status: reply.status, code: o?["code"] as? String, stage: "edit lease")
        }
        return EditLease(id: lease.id, token: (next["lease_token"] as? String) ?? lease.token, expiresAt: (next["expires_at"] as? String) ?? lease.expiresAt, documentEditProtocol: lease.documentEditProtocol, editorSessionId: lease.editorSessionId)
    }

    public func releaseLease(workspaceId: String, appNpub: String, lease: EditLease) async throws {
        _ = try await client.exchange(method: "POST", path: try Self.base(workspaceId) + "/edit-leases/" + Self.uuid(lease.id) + "/release",
                                      appNpub: appNpub, jsonBody: try rawJSON(["lease_token": lease.token]))
    }
}

// MARK: Storage

public struct PreparedObject: Sendable, Equatable, Codable {
    public let objectId: String
    public let uploadURL: String
}

extension TowerAPI {
    public static let fallbackUploadLimit = 8 * 1024 * 1024

    /// Workspace storage prepare (`POST /workspaces/:w/storage/prepare`); Tower assigns the workspace owner and refuses
    /// public objects for ordinary content.
    public func prepareStorage(workspaceId: String, appNpub: String, contentType: String, sizeBytes: Int, fileName: String, sha256: String) async throws -> PreparedObject {
        let body = try rawJSON(["content_type": contentType, "size_bytes": sizeBytes, "file_name": fileName, "sha256_hex": sha256, "is_public": false])
        let o = try object(try await client.request(method: "POST", path: try Self.base(workspaceId) + "/storage/prepare", appNpub: appNpub, jsonBody: body), "storage prepare")
        guard let id = lowerUUID(o["object_id"] as? String), o["is_public"] as? Bool != true, let upload = o["upload_url"] as? String else {
            throw TowerError.malformed("storage prepare")
        }
        return PreparedObject(objectId: id, uploadURL: upload)
    }

    /// Presigned download URL of a storage object, when Tower offers one on another host (otherwise nil: the signed
    /// Tower routes are used in-process).
    public func presignedDownloadURL(objectId: String) async throws -> (url: URL, sha256: String?, size: Int?)? {
        guard let meta = try await storageObject(objectId: objectId), let raw = meta["download_url"] as? String, let url = URL(string: raw),
              (try? BackgroundTransfers.validate(url, towerHost: client.origin.url.host)) != nil else { return nil }
        return (url, (meta["sha256_hex"] as? String)?.lowercased(), flexibleInt(meta["size_bytes"]))
    }

    /// Storage metadata (`GET /api/v4/storage/:id`), or nil when the object is gone.
    public func storageObject(objectId: String) async throws -> [String: Any]? {
        do { return try object(try await client.request(path: "/api/v4/storage/" + Self.uuid(objectId)), "storage object") }
        catch TowerError.http(404, _, _) { return nil }
    }

    /// Uploads bytes for a prepared object.
    ///
    /// - A presigned URL on another HTTPS host gets an **unsigned** PUT: no Authorization header, no cookies, redirects
    ///   refused. The NIP-98 identity never leaves the pinned Tower origin.
    /// - Tower's own object route (`/api/v4/storage/:id` on the pinned origin) gets the signed JSON upload.
    /// - Anything else (another path on the Tower host, plain HTTP elsewhere, credentials in the URL) is refused.
    public func upload(_ prepared: PreparedObject, bytes: Data, contentType: String) async throws {
        guard let url = URL(string: prepared.uploadURL), url.user == nil, url.password == nil, url.fragment == nil, let host = url.host?.lowercased()
        else { throw FileTransferError.unsafeUploadURL }
        let towerHost = client.origin.url.host?.lowercased()
        let objectPath = "/api/v4/storage/" + (try Self.uuid(prepared.objectId))
        if host == towerHost {
            // Tower's API fallback can advertise http:// behind a proxy: only the exact object path is accepted, and the
            // request goes to the pinned HTTPS origin.
            guard url.path == objectPath, url.query == nil, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw FileTransferError.unsafeUploadURL }
            guard bytes.count <= Self.fallbackUploadLimit else { throw FileTransferError.fallbackTooLarge }
            _ = try await client.request(method: "PUT", path: objectPath, jsonBody: try rawJSON(["base64_data": bytes.base64EncodedString()]))
            return
        }
        guard url.scheme?.lowercased() == "https", !url.path.hasPrefix("/api/v4/") else { throw FileTransferError.unsafeUploadURL }
        if let transfers {
            // Background URLSession: continues while suspended; keyed by object id so a finished upload is not repeated.
            try await transfers.upload(key: "upload:" + prepared.objectId, url: url, bytes: bytes, contentType: contentType, towerHost: towerHost)
        } else {
            try await client.putUnsigned(url: url, body: bytes, contentType: contentType)
        }
    }

    public func completeStorage(objectId: String, sizeBytes: Int, sha256: String) async throws {
        let o = try object(try await client.request(method: "POST", path: "/api/v4/storage/" + Self.uuid(objectId) + "/complete",
                                                    jsonBody: try rawJSON(["size_bytes": sizeBytes, "sha256_hex": sha256])), "storage complete")
        guard o["completed_at"] is String else { throw FileTransferError.notAttachable }
    }

    /// Prepare → upload → complete, verifying Tower's recorded size and hash. `prepared` resumes an earlier attempt.
    public func store(workspaceId: String, appNpub: String, bytes: Data, contentType: String, fileName: String,
                      prepared existing: PreparedObject?, allowReplacingMissingPrepared: Bool = true, onPrepared: @Sendable (PreparedObject) async throws -> Void) async throws -> String {
        let sha = SHA256Hex.of(bytes)
        var prepared = existing
        if let current = prepared, try await storageObject(objectId: current.objectId) == nil {
            guard allowReplacingMissingPrepared else { throw FileTransferError.notAttachable }
            prepared = nil
        }
        if prepared == nil {
            let fresh = try await prepareStorage(workspaceId: workspaceId, appNpub: appNpub, contentType: contentType, sizeBytes: bytes.count,
                                                 fileName: fileName, sha256: sha)
            try await onPrepared(fresh)
            prepared = fresh
        }
        guard let prepared else { throw FileTransferError.notAttachable }
        let meta = try await storageObject(objectId: prepared.objectId)
        if !(meta?["completed_at"] is String) {
            try await upload(prepared, bytes: bytes, contentType: contentType)
            try await completeStorage(objectId: prepared.objectId, sizeBytes: bytes.count, sha256: sha)
        }
        guard let done = try await storageObject(objectId: prepared.objectId), done["completed_at"] is String,
              (done["sha256_hex"] as? String)?.lowercased() == sha, flexibleInt(done["size_bytes"]) == bytes.count, done["is_public"] as? Bool != true
        else { throw FileTransferError.notAttachable }
        return prepared.objectId
    }
}

extension TowerClient {
    /// Unsigned upload to a presigned object-store URL. Never carries the NIP-98 header or cookies.
    public func putUnsigned(url: URL, body: Data, contentType: String) async throws {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw FileTransferError.unsafeUploadURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        try Task.checkCancellation()
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw TowerError.http(status: response.statusCode, code: nil, stage: "upload") }
    }
}
