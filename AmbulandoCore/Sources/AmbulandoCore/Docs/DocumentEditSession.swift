import Foundation

/// Inspection exposes the authority identity, never another editor's token.
public struct DocumentEditInspection: Sendable, Equatable {
    public let supported: Bool
    public let leaseId: String?
    public let holderNpub: String?
}

extension TowerAPI {
    public static let documentEditProtocol = "document_edit_session_v1"

    public func inspectDocumentEdit(workspaceId: String, appNpub: String, docId: String) async throws -> DocumentEditInspection {
        let reply = try await client.request(path: try Self.base(workspaceId) + "/edit-leases", query: [URLQueryItem(name: "entity_type", value: "document"), URLQueryItem(name: "entity_id", value: try Self.uuid(docId))], appNpub: appNpub)
        let row = try object(reply, "document edit authority")
        let lease = row["lease"] as? [String: Any]
        return DocumentEditInspection(supported: row["document_edit_protocol"] as? String == Self.documentEditProtocol,
                                      leaseId: lease?["id"] as? String, holderNpub: lease?["holder_actor_npub"] as? String)
    }
}
