import Foundation

/// Equality for deciding whether an old editor contains work worth recovering. JSON key order and envelope
/// whitespace are immaterial; text, marks, attributes, unknown fields and the exact title remain significant.
public enum DocumentContentIdentity {
    public static func equal(_ lhs: Data, title: String, _ rhs: Data, otherTitle: String) -> Bool {
        guard title == otherTitle else { return false }
        if lhs == rhs { return true }
        guard let a = try? JSONValue.parse(lhs), let b = try? JSONValue.parse(rhs) else { return false }
        return equalJSON(identity(a), identity(b))
    }
    private static func identity(_ root: JSONValue) -> JSONValue {
        let wrapped = root["content_model"] != nil
        var model = wrapped ? root["content_model"]! : root
        if model["editor_state"]?["type"]?.stringValue == "doc" {
            // These fields are generated from editor_state by both clients; their serializer spelling is not work.
            for key in ["content", "content_blocks", "content_format", "editor_state_format", "editor_state_version"] { model = model.setting(key, nil) }
        }
        return wrapped ? root.setting("content_model", model) : model
    }
    private static func equalJSON(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            // Duplicate keys are ambiguous: preserve rather than collapse them.
            guard Set(x.map(\.0)).count == x.count, Set(y.map(\.0)).count == y.count, x.count == y.count else { return a == b }
            return x.allSatisfy { key, value in y.first { $0.0 == key }.map { equalJSON(value, $0.1) } ?? false }
        case (.number(let x), .number(let y)): return numberIdentity(x) == numberIdentity(y)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equalJSON($0, $1) }
        default: return a == b
        }
    }
    private static func numberIdentity(_ source: String) -> String {
        let parts = source.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2, let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return source }
        let mantissa = String(parts[0]); let negative = mantissa.hasPrefix("-")
        let fraction = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let places = fraction.count == 2 ? fraction[1].count : 0
        var digits = mantissa.filter { $0.isNumber }
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return "0" }
        let (initialScale, overflow) = exponent.subtractingReportingOverflow(places)
        guard !overflow else { return source }
        var scale = initialScale
        while digits.last == "0" {
            let (next, overflow) = scale.addingReportingOverflow(1)
            guard !overflow else { return source }
            digits.removeLast(); scale = next
        }
        return (negative ? "-" : "") + digits + "e" + String(scale)
    }

}

public struct DocumentRecovery: Sendable, Equatable, Identifiable {
    public let id: String
    public let storageObjectId: String
    public let title: String?
    public let createdAt: String
    public init(raw: Data, workspaceId: String, docId: String) throws {
        guard let row = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let id = lowerUUID(row["id"] as? String), row["workspace_id"] as? String == workspaceId,
              row["doc_id"] as? String == docId else { throw TowerError.malformed("document recovery") }
        self.id = id
        guard let objectId = lowerUUID((row["submitted_body"] as? [String: Any])?["storage_object_id"] as? String ?? row["storage_object_id"] as? String) else { throw TowerError.malformed("recovery storage identity") }
        storageObjectId = objectId
        title = (row["submitted_patch"] as? [String: Any])?["title"] as? String
        createdAt = (row["provenance"] as? [String: Any])?["created_at"] as? String ?? ""
    }
}

extension DocumentSaver {
    public func latest(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String) async throws -> (doc: DocRecord, body: DocBodyRecord) {
        let fresh = try await api(connection).docBody(workspaceId: workspace.id, appNpub: workspace.appNpub, docId: docId)
        try await store.writer.saveDocBody(fresh.body, doc: fresh.doc, searchText: DocumentBody(bytes: fresh.body.bytes, contentType: fresh.body.contentType).markdown)
        return fresh
    }
    public func recoveries(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String) async throws -> [DocumentRecovery] {
        let api = try await api(connection)
        let rows = try await api.pages(try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(docId) + "/recoveries", appNpub: workspace.appNpub, key: "recoveries")
        return try rows.map { try DocumentRecovery(raw: rawJSON($0), workspaceId: workspace.id, docId: docId) }
    }
    public func recoveryBody(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String, recoveryId: String) async throws -> (bytes: Data, contentType: String) {
        let api = try await api(connection)
        let row = try api.object(try await api.client.request(path: try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(docId) + "/recoveries/" + TowerAPI.uuid(recoveryId) + "/body", appNpub: workspace.appNpub), "recovery body")
        guard let recoveryRow = row["recovery"] as? [String: Any] else { throw TowerError.malformed("recovery identity") }
        let recovery = try DocumentRecovery(raw: rawJSON(recoveryRow), workspaceId: workspace.id, docId: docId)
        guard recovery.id == recoveryId else { throw TowerError.malformed("recovery identity") }
        guard let body = row["body"] as? [String: Any], body["object_id"] as? String == recovery.storageObjectId, body["encoding"] as? String == "base64",
              let encoded = body["base64_data"] as? String, let bytes = Data(base64Encoded: encoded),
              (body["sha256_hex"] as? String)?.lowercased() == SHA256Hex.of(bytes) else { throw DocumentBodyError.integrity }
        return (bytes, body["content_type"] as? String ?? "")
    }
    /// Promotion is an explicit command against the exact head the person reviewed. It never retries a stale choice.
    public func resolveRecovery(_ connection: ConnectionRecord, _ workspace: WorkspaceRecord, docId: String, recoveryId: String,
                                promote: Bool, head: DocBodyRecord, editorSessionId: String) async throws {
        let api = try await api(connection)
        var payload: [String: Any] = [:]
        if promote {
            let lease = try await acquire(connection, workspace, docId: docId, editorSessionId: editorSessionId)
            payload = ["row_version": head.docRowVersion, "base_body_sha256_hex": head.sha256, "lease_token": lease.token]
        }
        _ = try await api.client.request(method: "POST", path: try TowerAPI.base(workspace.id) + "/docs/" + TowerAPI.uuid(docId) + "/recoveries/" + TowerAPI.uuid(recoveryId) + (promote ? "/promote" : "/discard"), appNpub: workspace.appNpub, jsonBody: rawJSON(payload))
    }
}
