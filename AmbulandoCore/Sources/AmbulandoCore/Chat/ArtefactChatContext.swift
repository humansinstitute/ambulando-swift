import Foundation

/// App-owned descriptive context carried by generic message metadata. Never an ACL or instruction source.
public struct ArtefactChatReference: Codable, Equatable, Sendable {
    public let kind: String
    public let recordID: String
    public let revision: String
    public let digest: String?
    public let revisionKind: String
    public let historical: Bool
    public init(kind: String, recordID: String, revision: String, historical: Bool, digest: String? = nil) {
        self.kind = kind; self.recordID = recordID; self.revision = revision; self.historical = historical; self.digest = digest
        self.revisionKind = kind == "doc" ? "doc_versions.row_version" : "file_version_id"
    }
}

public struct ArtefactChatContext: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let channelID: String
    public let threadID: String
    public let workspaceVisible: Bool
    public let visibleRecordID: String
    public let open: [ArtefactChatReference]
    public init(workspaceID: String, channelID: String, threadID: String, visibleRecordID: String, workspaceVisible: Bool = true, open: [ArtefactChatReference]) {
        self.schemaVersion = 1
        self.workspaceID = workspaceID; self.channelID = channelID; self.threadID = threadID
        self.visibleRecordID = visibleRecordID; self.workspaceVisible = workspaceVisible; self.open = open
    }
    public static let metadataKey = "ambulando_artefact_context"
    public static let maxBytes = 16_384
    public static let maxReferences = 32
    public let schemaVersion: Int

    /// Freeze only validated references; routing always comes from the composer/outbox target.
    public func encoded(for target: ChatTarget) throws -> Data {
        guard schemaVersion == 1, workspaceID == target.workspaceId, channelID == target.channelId,
              threadID == target.threadId,
              [workspaceID, channelID, threadID, visibleRecordID].allSatisfy({ UUID(uuidString: $0) != nil }),
              !open.isEmpty, open.count <= Self.maxReferences,
              Set(open.map { $0.recordID.lowercased() }).count == open.count,
              open.contains(where: { $0.recordID == visibleRecordID }),
              open.allSatisfy({ ref in
                  guard UUID(uuidString: ref.recordID) != nil else { return false }
                  let validDigest = ref.digest.map { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } ?? false
                  return validDigest && ((ref.kind == "file" && ref.revisionKind == "file_version_id" && UUID(uuidString: ref.revision) != nil)
                    || (ref.kind == "doc" && ref.revisionKind == "doc_versions.row_version" && ref.digest != nil
                        && Int64(ref.revision).map { $0 > 0 && $0 <= 9_007_199_254_740_991 && String($0) == ref.revision } == true))
              }) else { throw ContextError.unresolved }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw ContextError.unresolved }
        return data
    }

    public static func validate(_ data: Data, for target: ChatTarget) throws -> Data {
        guard data.count <= maxBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "workspaceID", "channelID", "threadID", "workspaceVisible", "visibleRecordID", "open"]),
              let refs = object["open"] as? [[String: Any]],
              refs.allSatisfy({ Set($0.keys).isSubset(of: ["kind", "recordID", "revision", "revisionKind", "historical", "digest"]) }) else { throw ContextError.unresolved }
        let context = try JSONDecoder().decode(Self.self, from: data)
        _ = try context.encoded(for: target)
        return data
    }
    public enum ContextError: LocalizedError {
        case unresolved
        public var errorDescription: String? { "An artefact revision is unavailable. Open the tab, resolve its save or access error, then retry Send. Your draft is retained." }
    }
}

extension DocumentVersion {
    /// Doc history's supported key is the snapshot row_version; require the complete stored envelope.
    public func chatReference(docID: String, historical: Bool) throws -> ArtefactChatReference {
        guard let bytes else { throw ArtefactChatContext.ContextError.unresolved }
        return ArtefactChatReference(kind: "doc", recordID: docID, revision: String(rowVersion), historical: historical, digest: SHA256Hex.of(bytes))
    }
}
