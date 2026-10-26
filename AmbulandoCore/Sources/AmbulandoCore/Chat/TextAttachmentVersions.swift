import Foundation

/// One readable version of a sent text attachment: the original on the message, or a later file version.
public struct TextVersionRef: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    /// nil for the original attachment on the signed message (it has no file version).
    public let versionId: String?
    public let number: Int
    public let storageObjectId: String
    public let sizeBytes: Int?
    public let sha256: String?
    public let createdAt: String?
    public let author: String?
    public var isOriginal: Bool { versionId == nil }

    public init(id: String, versionId: String?, number: Int, storageObjectId: String, sizeBytes: Int?, sha256: String?, createdAt: String?, author: String?) {
        self.id = id; self.versionId = versionId; self.number = number; self.storageObjectId = storageObjectId
        self.sizeBytes = sizeBytes; self.sha256 = sha256; self.createdAt = createdAt; self.author = author
    }

    init?(version o: [String: Any]) {
        guard let vid = lowerUUID(o["id"] as? String), let storage = lowerUUID(o["storage_object_id"] as? String) else { return nil }
        self.init(id: vid, versionId: vid, number: flexibleInt(o["version_number"]) ?? 0, storageObjectId: storage, sizeBytes: flexibleInt(o["size_bytes"]),
                  sha256: (o["sha256_hex"] as? String)?.lowercased(), createdAt: o["created_at"] as? String,
                  author: o["created_by_actor_npub"] as? String)
    }
}

/// The Tower file that holds the edit history of one sent text attachment.
public struct TextLineage: Sendable, Equatable, Codable {
    public let fileId: String
    public let displayName: String
    public let currentVersionId: String?
    public let rowVersion: Int?

    public init(fileId: String, displayName: String, currentVersionId: String?, rowVersion: Int? = nil) {
        self.fileId = fileId; self.displayName = displayName; self.currentVersionId = currentVersionId; self.rowVersion = rowVersion
    }
}

public enum TextSaveOutcome: Sendable, Equatable {
    case saved(lineage: TextLineage, version: TextVersionRef?)
    /// Someone saved first (stale base, or the first edit already exists): the local edit is kept, nothing overwritten.
    case conflict(lineage: TextLineage, current: TextVersionRef?)
}

public enum TextVersionError: LocalizedError, Equatable, Sendable {
    case malformed, forbidden, notFound, http(Int, String?)
    public var errorDescription: String? {
        switch self {
        case .malformed: "Tower's answer could not be read."
        case .forbidden: "You do not have permission to edit this file."
        case .notFound: "The file was not found."
        case .http(let status, let code): "Tower refused the save (HTTP \(status)\(code.map { ", \($0)" } ?? ""))."
        }
    }
}

extension TowerAPI {
    private func fileLineage(_ file: [String: Any]) -> TextLineage? {
        guard let id = lowerUUID(file["id"] as? String) else { return nil }
        return TextLineage(fileId: id, displayName: (file["display_name"] as? String) ?? "Pasted text.txt", currentVersionId: lowerUUID(file["current_version_id"] as? String), rowVersion: flexibleInt(file["row_version"]))
    }

    private func classify(_ status: Int, _ body: Data) throws -> [String: Any] {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if (200..<300).contains(status) { return o }
        switch status {
        case 403: throw TextVersionError.forbidden
        case 404: throw TextVersionError.notFound
        default: throw TextVersionError.http(status, o["code"] as? String)
        }
    }

    /// The file whose lineage metadata names this message attachment, found by matching both ids (never by name or age).
    public func textLineage(workspaceId: String, appNpub: String, channelId: String, originMessageId: String, originStorageObjectId: String) async throws -> TextLineage? {
        let data = try await client.request(path: Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/files",
            query: [URLQueryItem(name: "origin_message_id", value: Self.uuid(originMessageId)),
                    URLQueryItem(name: "origin_storage_object_id", value: Self.uuid(originStorageObjectId))], appNpub: appNpub)
        guard let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["files"] as? [[String: Any]] else { throw TextVersionError.malformed }
        let files = try rows.map { try FileRecord(raw: rawJSON($0)) }
        guard files.allSatisfy({ $0.workspaceId == workspaceId && $0.channelId == channelId }) else { throw TextVersionError.malformed }
        let message = originMessageId.lowercased(), storage = originStorageObjectId.lowercased()
        for file in files where !file.archived {
            guard let o = (try? JSONSerialization.jsonObject(with: file.raw)) as? [String: Any],
                  let lineage = (o["metadata"] as? [String: Any])?["text_attachment_lineage"] as? [String: Any],
                  (lineage["origin_message_id"] as? String)?.lowercased() == message,
                  (lineage["origin_storage_object_id"] as? String)?.lowercased() == storage else { continue }
            return fileLineage(o)
        }
        return nil
    }

    public func textVersions(workspaceId: String, appNpub: String, fileId: String) async throws -> (versions: [TextVersionRef], currentVersionId: String?) {
        let data = try await client.request(path: Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/versions", query: [URLQueryItem(name: "limit", value: "200")], appNpub: appNpub)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rows = o["versions"] as? [[String: Any]] else { throw TextVersionError.malformed }
        let versions = rows.compactMap(TextVersionRef.init(version:)).sorted { $0.number < $1.number }
        return (versions, lowerUUID(o["current_version_id"] as? String))
    }

    /// Bytes of one file version, checked against the version's recorded checksum.
    public func textVersionBytes(workspaceId: String, appNpub: String, fileId: String, version: TextVersionRef) async throws -> Data {
        guard let versionId = version.versionId else { throw TextVersionError.notFound }
        let bytes = try await client.request(path: Self.base(workspaceId) + "/files/" + Self.uuid(fileId) + "/versions/" + Self.uuid(versionId) + "/object", appNpub: appNpub)
        if let expected = version.sha256, SHA256Hex.of(bytes) != expected { throw FileTransferError.integrity }
        return bytes
    }

    /// The content version is already accepted. Retry only this optimistic rename, never the version upload.
    public func renameTextFile(workspaceId: String, appNpub: String, lineage: TextLineage, filename: String,
                               refreshBase: Bool, onCanonical: @Sendable (TextLineage) async throws -> Void) async throws -> TextLineage {
        let path = try Self.base(workspaceId) + "/files/" + Self.uuid(lineage.fileId)
        var canonical = lineage
        if canonical.rowVersion == nil || refreshBase {
            let data = try await client.request(path: path, appNpub: appNpub)
            guard let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let row = object["file"] as? [String: Any], let found = fileLineage(row) else { throw TextVersionError.malformed }
            canonical = found
            try await onCanonical(canonical)
        }
        if canonical.displayName == filename { return canonical }
        guard let row = canonical.rowVersion else { throw TextVersionError.malformed }
        let reply = try await client.exchange(method: "PATCH", path: path, appNpub: appNpub,
            jsonBody: rawJSON(["display_name": filename, "row_version": row]))
        let object = try classify(reply.status, reply.body)
        guard let file = (object["file"] as? [String: Any]).flatMap(fileLineage), file.displayName == filename else { throw TextVersionError.malformed }
        return file
    }

    /// Saves an edit of a sent text attachment as a new version; nothing already sent or saved is overwritten.
    ///
    /// The bytes upload as a new storage object first (`prepared` resumes an earlier attempt). Without a lineage file
    /// this is the first edit: a channel file is created carrying the lineage. Tower creates at most one per
    /// attachment; if one already exists the answer is `.conflict` with that file, and the local edit stays with the
    /// caller to rebase. With a lineage file the save is a version on `baseVersionId`; a stale base is a `.conflict`.
    public func saveTextEdit(workspaceId: String, appNpub: String, channelId: String, origin: (messageId: String, storageObjectId: String, filename: String),
                             lineage: TextLineage?, baseVersionId: String?, bytes: Data, filename: String, clientMutationId: String,
                             prepared: PreparedObject? = nil, onPrepared: @Sendable (PreparedObject) async throws -> Void = { _ in }) async throws -> TextSaveOutcome {
        let objectId = try await store(workspaceId: workspaceId, appNpub: appNpub, bytes: bytes, contentType: textAttachmentContentType,
                                       fileName: filename, prepared: prepared, allowReplacingMissingPrepared: false, onPrepared: onPrepared)
        if let lineage {
            guard let baseVersionId else { throw TextVersionError.malformed }
            let body = try rawJSON(["base_version_id": baseVersionId, "storage_object_id": objectId, "client_mutation_id": clientMutationId])
            let reply = try await client.exchange(method: "POST", path: Self.base(workspaceId) + "/files/" + Self.uuid(lineage.fileId) + "/versions", appNpub: appNpub, jsonBody: body)
            if reply.status == 409 {
                let o = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
                guard o["code"] as? String == "stale_base_version" else { throw TextVersionError.http(409, o["code"] as? String) }
                let current = (o["current_version"] as? [String: Any]).flatMap(TextVersionRef.init(version:))
                let file = (o["file"] as? [String: Any]).flatMap(fileLineage) ?? lineage
                return .conflict(lineage: file, current: current)
            }
            let o = try classify(reply.status, reply.body)
            let version = (o["version"] as? [String: Any]).flatMap(TextVersionRef.init(version:))
            let file = (o["file"] as? [String: Any]).flatMap(fileLineage) ?? lineage
            return .saved(lineage: file, version: version)
        }
        let meta: [String: Any] = ["text_attachment_lineage": ["v": 1, "origin_message_id": origin.messageId.lowercased(),
                                                                "origin_storage_object_id": origin.storageObjectId.lowercased(), "origin_filename": origin.filename]]
        let body = try rawJSON(["storage_object_id": objectId, "display_name": filename, "metadata": meta])
        let reply = try await client.exchange(method: "POST", path: Self.base(workspaceId) + "/channels/" + Self.uuid(channelId) + "/files", appNpub: appNpub, jsonBody: body)
        let o = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] ?? [:]
        if reply.status == 409, o["code"] as? String == "lineage_file_exists" {
            guard let file = (o["file"] as? [String: Any]).flatMap(fileLineage) else { throw TextVersionError.malformed }
            return .conflict(lineage: file, current: (o["current_version"] as? [String: Any]).flatMap(TextVersionRef.init(version:)))
        }
        let ok = try classify(reply.status, reply.body)
        guard let file = (ok["file"] as? [String: Any]).flatMap(fileLineage) else { throw TextVersionError.malformed }
        // 200 is Tower's replay of this very save; 201 a new file. Either way the file now holds our object.
        return .saved(lineage: file, version: (ok["current_version"] as? [String: Any]).flatMap(TextVersionRef.init(version:)))
    }
}
