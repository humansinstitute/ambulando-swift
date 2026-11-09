import Foundation

/// Tower's canonical snapshots, distinct from recoveries and this device's drafts.
public struct DocumentVersion: Sendable, Equatable, Identifiable {
    public var id: Int { rowVersion }
    public let rowVersion: Int
    public let title: String
    public let updatedAt: String
    public let operation: String
    public let actorNpub: String?
    public let bytes: Data?
    public let contentType: String

    public init(raw: Data, workspaceId: String, docId: String) throws {
        guard let row = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              row["workspace_id"] as? String == workspaceId, row["doc_id"] as? String == docId,
              let version = row["row_version"] as? Int ?? row["version"] as? Int, version > 0,
              let title = row["title"] as? String else { throw TowerError.malformed("document version identity") }
        rowVersion = version; self.title = title
        updatedAt = row["updated_at"] as? String ?? ""
        operation = row["operation"] as? String ?? "updated"
        actorNpub = row["actor_npub"] as? String
        let content = row["content"] as? [String: Any]
        contentType = content?["content_type"] as? String ?? "text/markdown"
        // raw is the complete stored envelope: preserve unknown nodes and fields when restoring.
        bytes = (content?["missing"] as? Bool == true) ? nil : (content?["raw"] as? String).map { Data($0.utf8) }
    }
}

public enum DocumentActionText {
    public static func reference(title: String, docId: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let label = (clean.isEmpty ? String(docId.prefix(8)) : clean).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
        return "@[\(label)](mention:document:\(docId))"
    }
}

extension DocumentSaver {
    public func versions(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String) async throws -> [DocumentVersion] {
        let api = try await api(connection)
        let path = try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(docId) + "/versions"
        let rows = try await api.pages(path, appNpub: workspace.appNpub, key: "versions")
        return try rows.map { try DocumentVersion(raw: rawJSON($0), workspaceId: workspace.id, docId: docId) }.sorted { $0.rowVersion > $1.rowVersion }
    }

    /// Online, version guarded, never queued or retried automatically. A failed/lost reply is not success.
    public func setLifecycle(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, doc: DocRecord, delete: Bool) async throws {
        let api = try await api(connection)
        let path = try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(doc.id)
        let data = try await api.client.request(method: delete ? "DELETE" : "PATCH", path: path,
            query: delete ? [URLQueryItem(name: "row_version", value: String(doc.rowVersion))] : [], appNpub: workspace.appNpub,
            jsonBody: delete ? nil : rawJSON(["row_version": doc.rowVersion, "archived": true]))
        let object = try api.object(data, "document lifecycle")
        guard let raw = object["doc"] as? [String: Any] else { throw TowerError.malformed("document lifecycle") }
        let updated = try DocRecord(raw: rawJSON(raw))
        guard updated.id == doc.id, updated.workspaceId == workspace.id, updated.rowVersion > doc.rowVersion else { throw TowerError.malformed("document lifecycle identity") }
        if delete {
            guard raw["record_state"] as? String == "deleted" || raw["deleted_at"] is String else { throw TowerError.malformed("document deletion") }
            try await store.writer.applyTombstones(workspaceId: workspace.id, [.doc(doc.id)])
        } else {
            guard updated.archived else { throw TowerError.malformed("document archive") }
            try await store.writer.upsertDocs(workspaceId: workspace.id, [updated])
        }
    }
}
