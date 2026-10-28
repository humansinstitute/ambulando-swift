import Foundation

/// Typed views over the Tower serializers used by tasks, documents, files, inbox and reactions
/// (`serializeFlightDeckPgTask/TaskComment/Doc/DocComment/File/FileFolder/ResourceViewState/Reaction`).
/// Each keeps its canonical JSON in `raw`.

func lowerUUID(_ value: String?) -> String? {
    guard let value, UUID(uuidString: value) != nil else { return nil }
    return value.lowercased()
}

func rawJSON(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

/// Tower BIGINT columns can arrive as JSON strings or numbers.
func flexibleInt(_ value: Any?) -> Int? {
    if let n = value as? Int { return n }
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) }
    return nil
}

public enum TaskState: String, Sendable, CaseIterable, Codable {
    case new, backlog, ready, inProgress = "in_progress", review, blocked, done, archive, archived

    public var label: String {
        switch self {
        case .new: "New"
        case .backlog: "Backlog"
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .review: "Review"
        case .blocked: "Blocked"
        case .done: "Done"
        case .archive, .archived: "Archived"
        }
    }

    /// Board columns, in the web board's order. Archived tasks are not shown on the board.
    public static let board: [TaskState] = [.new, .ready, .inProgress, .review, .blocked, .done]
    public var isTerminal: Bool { [.done, .archive, .archived].contains(self) }
}

public enum TaskPriority: String, Sendable, CaseIterable, Codable {
    case rock, pebble, sand, low, normal, high, urgent
    public var label: String { rawValue.capitalized }
    /// The priorities the web task editor offers.
    public static let editable: [TaskPriority] = [.rock, .pebble, .sand]
}

public struct TaskRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let scopeId: String?
    public let channelId: String
    public let threadId: String?
    public let title: String
    public let description: String?
    public let state: String
    public let priority: String
    public let assignedToNpub: String?
    public let createdByNpub: String?
    public let rowVersion: Int
    public let activityVersion: Int
    public let createdAt: String
    public let updatedAt: String
    public let raw: Data

    public var taskState: TaskState? { TaskState(rawValue: state) }

    public init(raw: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = lowerUUID(o["id"] as? String),
              let w = lowerUUID(o["workspace_id"] as? String), let c = lowerUUID(o["channel_id"] as? String) else { throw TowerError.malformed("task") }
        workspaceId = w; self.id = id; channelId = c
        scopeId = lowerUUID(o["scope_id"] as? String); threadId = lowerUUID(o["thread_id"] as? String)
        title = (o["title"] as? String) ?? "Untitled task"; description = o["description"] as? String
        state = (o["state"] as? String) ?? "new"; priority = (o["priority"] as? String) ?? "sand"
        assignedToNpub = (o["assigned_to_npub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        createdByNpub = o["created_by_actor_npub"] as? String
        rowVersion = flexibleInt(o["row_version"]) ?? 0; activityVersion = flexibleInt(o["activity_version"]) ?? 0
        createdAt = (o["created_at"] as? String) ?? ""; updatedAt = (o["updated_at"] as? String) ?? createdAt
        self.raw = raw
    }

    public init(workspaceId: String, id: String, scopeId: String?, channelId: String, threadId: String? = nil, title: String, description: String?,
                state: String, priority: String, assignedToNpub: String?, createdByNpub: String? = nil, rowVersion: Int, activityVersion: Int = 0,
                createdAt: String, updatedAt: String, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.scopeId = scopeId; self.channelId = channelId; self.threadId = threadId
        self.title = title; self.description = description; self.state = state; self.priority = priority; self.assignedToNpub = assignedToNpub
        self.createdByNpub = createdByNpub; self.rowVersion = rowVersion; self.activityVersion = activityVersion
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.raw = raw
    }
}

/// Task and document comments share one shape locally.
public struct CommentRecord: Sendable, Equatable, Identifiable {
    public enum Parent: String, Sendable { case task, doc }
    public let workspaceId: String
    public let id: String
    public let parent: Parent
    public let parentId: String
    public let parentCommentId: String?
    public let body: String
    public let senderNpub: String?
    public let status: String?       // doc comments: open / resolved
    public let deleted: Bool
    public let rowVersion: Int
    public let createdAt: String
    public let updatedAt: String
    public let clientRecordId: String?
    public let raw: Data

    public init(raw: Data, parent: Parent) throws {
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = lowerUUID(o["id"] as? String),
              let w = lowerUUID(o["workspace_id"] as? String),
              let p = lowerUUID(o[parent == .task ? "task_id" : "doc_id"] as? String) else { throw TowerError.malformed("comment") }
        let metadata = o["metadata"] as? [String: Any]
        workspaceId = w; self.id = id; self.parent = parent; parentId = p
        parentCommentId = lowerUUID(o["parent_comment_id"] as? String)
        body = (o["body"] as? String) ?? ""; senderNpub = (o["sender_npub"] as? String) ?? (o["created_by_actor_npub"] as? String)
        status = metadata?["comment_status"] as? String
        deleted = o["record_state"] as? String == "deleted"
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        createdAt = (o["created_at"] as? String) ?? ""; updatedAt = (o["updated_at"] as? String) ?? createdAt
        clientRecordId = (metadata?["client_record_id"] as? String)?.lowercased()
        self.raw = raw
    }

    public init(workspaceId: String, id: String, parent: Parent, parentId: String, parentCommentId: String? = nil, body: String, senderNpub: String?,
                status: String? = nil, deleted: Bool = false, rowVersion: Int = 1, createdAt: String, updatedAt: String? = nil,
                clientRecordId: String? = nil, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.parent = parent; self.parentId = parentId; self.parentCommentId = parentCommentId
        self.body = body; self.senderNpub = senderNpub; self.status = status; self.deleted = deleted; self.rowVersion = rowVersion
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.clientRecordId = clientRecordId; self.raw = raw
    }
}

public struct DocRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let scopeId: String?
    public let channelId: String
    public let storageObjectId: String?
    public let title: String
    public let summary: String?
    public let archived: Bool
    public let rowVersion: Int
    public let activityVersion: Int
    public let createdAt: String
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = lowerUUID(o["id"] as? String),
              let w = lowerUUID(o["workspace_id"] as? String), let c = lowerUUID(o["channel_id"] as? String) else { throw TowerError.malformed("document") }
        workspaceId = w; self.id = id; channelId = c; scopeId = lowerUUID(o["scope_id"] as? String)
        storageObjectId = lowerUUID(o["storage_object_id"] as? String)
        title = (o["title"] as? String) ?? "Untitled document"; summary = o["summary"] as? String
        archived = o["record_state"] as? String == "archived" || (o["archived_at"] as? String) != nil
        rowVersion = flexibleInt(o["row_version"]) ?? 0; activityVersion = flexibleInt(o["activity_version"]) ?? 0
        createdAt = (o["created_at"] as? String) ?? ""; updatedAt = (o["updated_at"] as? String) ?? createdAt
        self.raw = raw
    }

    public init(workspaceId: String, id: String, scopeId: String?, channelId: String, storageObjectId: String?, title: String, summary: String?,
                archived: Bool = false, rowVersion: Int, activityVersion: Int = 0, createdAt: String, updatedAt: String, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.scopeId = scopeId; self.channelId = channelId; self.storageObjectId = storageObjectId
        self.title = title; self.summary = summary; self.archived = archived; self.rowVersion = rowVersion; self.activityVersion = activityVersion
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.raw = raw
    }
}

/// A fetched document body with the identity Tower needs to accept a save against it.
public struct DocBodyRecord: Sendable, Equatable {
    public let workspaceId: String
    public let docId: String
    public let storageObjectId: String
    /// sha256 of the canonical body (Tower's storage identity, verified against the bytes).
    public let sha256: String
    public let contentType: String
    public let docRowVersion: Int
    public let bytes: Data
    public let fetchedAt: String
}

public struct FileRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let scopeId: String?
    public let channelId: String
    public let folderId: String?
    public let storageObjectId: String?
    public let displayName: String
    public let description: String?
    public let contentType: String?
    public let sizeBytes: Int?
    public let sha256: String?
    public let archived: Bool
    public let rowVersion: Int
    public let createdAt: String
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = lowerUUID(o["id"] as? String),
              let w = lowerUUID(o["workspace_id"] as? String), let c = lowerUUID(o["channel_id"] as? String) else { throw TowerError.malformed("file") }
        let version = o["current_version"] as? [String: Any]
        let storage = (o["object"] as? [String: Any])?["storage_object"] as? [String: Any]
        workspaceId = w; self.id = id; channelId = c; scopeId = lowerUUID(o["scope_id"] as? String)
        folderId = lowerUUID(o["folder_id"] as? String); storageObjectId = lowerUUID(o["storage_object_id"] as? String)
        displayName = (o["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (storage?["file_name"] as? String) ?? "Untitled file"
        description = o["description"] as? String
        contentType = (version?["content_type"] as? String) ?? (storage?["content_type"] as? String)
        sizeBytes = flexibleInt(version?["size_bytes"]) ?? flexibleInt(storage?["size_bytes"])
        sha256 = ((version?["sha256_hex"] as? String) ?? (storage?["sha256_hex"] as? String))?.lowercased()
        archived = o["record_state"] as? String == "archived" || (o["archived_at"] as? String) != nil
        rowVersion = flexibleInt(o["row_version"]) ?? 0
        createdAt = (o["created_at"] as? String) ?? ""; updatedAt = (o["updated_at"] as? String) ?? createdAt
        self.raw = raw
    }

    public init(workspaceId: String, id: String, scopeId: String?, channelId: String, folderId: String?, storageObjectId: String?, displayName: String,
                description: String? = nil, contentType: String?, sizeBytes: Int?, sha256: String?, archived: Bool = false, rowVersion: Int = 1,
                createdAt: String, updatedAt: String, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.scopeId = scopeId; self.channelId = channelId; self.folderId = folderId
        self.storageObjectId = storageObjectId; self.displayName = displayName; self.description = description; self.contentType = contentType
        self.sizeBytes = sizeBytes; self.sha256 = sha256; self.archived = archived; self.rowVersion = rowVersion
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.raw = raw
    }
}

public struct FolderRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let channelId: String
    public let parentFolderId: String?
    public let title: String
    public let deleted: Bool
    public let rowVersion: Int
    public let updatedAt: String
    public let raw: Data

    public init(raw: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = lowerUUID(o["id"] as? String),
              let w = lowerUUID(o["workspace_id"] as? String), let c = lowerUUID(o["channel_id"] as? String) else { throw TowerError.malformed("folder") }
        workspaceId = w; self.id = id; channelId = c; parentFolderId = lowerUUID(o["parent_folder_id"] as? String)
        title = (o["title"] as? String) ?? "Folder"; deleted = (o["deleted_at"] as? String) != nil
        rowVersion = flexibleInt(o["row_version"]) ?? 0; updatedAt = (o["updated_at"] as? String) ?? ""; self.raw = raw
    }

    public init(workspaceId: String, id: String, channelId: String, parentFolderId: String?, title: String, deleted: Bool = false,
                rowVersion: Int = 1, updatedAt: String, raw: Data = Data("{}".utf8)) {
        self.workspaceId = workspaceId; self.id = id; self.channelId = channelId; self.parentFolderId = parentFolderId; self.title = title
        self.deleted = deleted; self.rowVersion = rowVersion; self.updatedAt = updatedAt; self.raw = raw
    }
}

/// `serializeFlightDeckPgResourceViewState`: the actor's read position for one task, document or thread.
public struct ViewStateRecord: Sendable, Equatable, Identifiable {
    public enum ResourceType: String, Sendable, CaseIterable, Codable { case task, document, thread }
    public let workspaceId: String
    public let resourceType: ResourceType
    public let resourceId: String
    public let scopeId: String?
    public let channelId: String?
    public let activityVersion: Int
    public let viewedActivityVersion: Int
    /// Present when Tower evaluated its attention policy (mentions, assignment).
    public let attentionActivityVersion: Int?
    public let rowVersion: Int
    public let updatedAt: String
    public var id: String { "\(resourceType.rawValue):\(resourceId)" }

    public var unread: Bool { activityVersion > viewedActivityVersion }
    public var needsAttention: Bool { (attentionActivityVersion ?? 0) > viewedActivityVersion }

    public init(raw: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let w = lowerUUID(o["workspace_id"] as? String),
              let type = (o["resource_type"] as? String).flatMap(ResourceType.init(rawValue:)), let r = lowerUUID(o["resource_id"] as? String)
        else { throw TowerError.malformed("view state") }
        workspaceId = w; resourceType = type; resourceId = r
        scopeId = lowerUUID(o["scope_id"] as? String); channelId = lowerUUID(o["channel_id"] as? String)
        activityVersion = flexibleInt(o["activity_version"]) ?? 0; viewedActivityVersion = flexibleInt(o["viewed_activity_version"]) ?? 0
        attentionActivityVersion = flexibleInt(o["attention_activity_version"])
        rowVersion = flexibleInt(o["row_version"]) ?? 0; updatedAt = (o["updated_at"] as? String) ?? ""
    }

    public init(workspaceId: String, resourceType: ResourceType, resourceId: String, scopeId: String?, channelId: String?, activityVersion: Int,
                viewedActivityVersion: Int, attentionActivityVersion: Int? = nil, rowVersion: Int = 1, updatedAt: String) {
        self.workspaceId = workspaceId; self.resourceType = resourceType; self.resourceId = resourceId; self.scopeId = scopeId
        self.channelId = channelId; self.activityVersion = activityVersion; self.viewedActivityVersion = viewedActivityVersion
        self.attentionActivityVersion = attentionActivityVersion; self.rowVersion = rowVersion; self.updatedAt = updatedAt
    }
}

/// The seven reactions Tower accepts (`reactionEmojis`), with the glyph shown for each.
public enum ReactionEmoji: String, Sendable, CaseIterable, Codable {
    case thumbsUp = "thumbs_up", smile, heart, eyes, party, shaka, check = "white_check_mark"
    public var name: String {
        switch self {
        case .thumbsUp: "Thumbs up"
        case .smile: "Smile"
        case .heart: "Heart"
        case .eyes: "Eyes"
        case .party: "Party"
        case .shaka: "Shaka"
        case .check: "Done"
        }
    }

    /// SF Symbol shown for the reaction (emoji fonts are not guaranteed on every device or simulator).
    public var symbol: String {
        switch self {
        case .thumbsUp: "hand.thumbsup.fill"
        case .smile: "face.smiling"
        case .heart: "heart.fill"
        case .eyes: "eyes"
        case .party: "party.popper.fill"
        case .shaka: "hand.wave.fill"
        case .check: "checkmark.seal.fill"
        }
    }

    public var glyph: String {
        switch self {
        case .thumbsUp: "👍"
        case .smile: "😄"
        case .heart: "❤️"
        case .eyes: "👀"
        case .party: "🎉"
        case .shaka: "🤙"
        case .check: "✅"
        }
    }
}

public struct ReactionRecord: Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let id: String
    public let targetType: String
    public let targetId: String
    public let emoji: String
    public let reactorNpub: String?
    public let deleted: Bool
    public let rowVersion: Int
    public let updatedAt: String

    public init(raw: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = lowerUUID(o["id"] as? String),
              let w = lowerUUID(o["workspace_id"] as? String), let target = lowerUUID(o["target_id"] as? String) else { throw TowerError.malformed("reaction") }
        workspaceId = w; self.id = id; targetType = (o["target_type"] as? String) ?? "message"; targetId = target
        emoji = (o["emoji"] as? String) ?? ""; reactorNpub = o["reactor_npub"] as? String
        deleted = o["record_state"] as? String == "deleted"; rowVersion = flexibleInt(o["row_version"]) ?? 0
        updatedAt = (o["updated_at"] as? String) ?? ""
    }

    public init(workspaceId: String, id: String, targetType: String, targetId: String, emoji: String, reactorNpub: String?, deleted: Bool = false,
                rowVersion: Int = 1, updatedAt: String) {
        self.workspaceId = workspaceId; self.id = id; self.targetType = targetType; self.targetId = targetId; self.emoji = emoji
        self.reactorNpub = reactorNpub; self.deleted = deleted; self.rowVersion = rowVersion; self.updatedAt = updatedAt
    }
}

/// A chat attachment as Tower stores it in `metadata.attachments`.
public struct MessageAttachment: Sendable, Equatable, Codable, Hashable {
    public let kind: String
    public let storageObjectId: String
    public let filename: String
    public let mimeType: String?
    public let sizeBytes: Int?
    public let sha256: String?
    /// Counts of a pasted or edited text file (shared contract v1); nil for every other attachment.
    public let textAttachment: TextAttachmentInfo?

    public init(kind: String, storageObjectId: String, filename: String, mimeType: String?, sizeBytes: Int?,
                sha256: String? = nil, textAttachment: TextAttachmentInfo? = nil) {
        self.kind = kind; self.storageObjectId = storageObjectId; self.filename = filename; self.mimeType = mimeType; self.sizeBytes = sizeBytes
        self.sha256 = sha256; self.textAttachment = textAttachment
    }

    public var requestObject: [String: Any] {
        var o: [String: Any] = ["kind": kind, "storage_object_id": storageObjectId, "filename": filename]
        if let mimeType { o["mime_type"] = mimeType }
        if let sizeBytes { o["size_bytes"] = sizeBytes }
        if let sha256 { o["sha256_hex"] = sha256 }
        if let textAttachment {
            // Contract v1 names the type `content_type`; `mime_type` stays for clients that read the older field.
            if let mimeType { o["content_type"] = mimeType }
            o["text_attachment"] = textAttachment.requestObject
        }
        return o
    }

    /// Attachments of a message's canonical JSON (only well-formed storage references).
    public static func from(messageRaw raw: Data) -> [MessageAttachment] {
        guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return [] }
        let list = (o["attachments"] as? [[String: Any]]) ?? ((o["metadata"] as? [String: Any])?["attachments"] as? [[String: Any]]) ?? []
        return list.compactMap { a in
            guard let id = lowerUUID(a["storage_object_id"] as? String) else { return nil }
            return MessageAttachment(kind: (a["kind"] as? String) ?? "file", storageObjectId: id, filename: (a["filename"] as? String) ?? "Attachment",
                                     mimeType: (a["mime_type"] as? String) ?? (a["content_type"] as? String), sizeBytes: flexibleInt(a["size_bytes"]),
                                     sha256: (a["sha256_hex"] as? String)?.lowercased(), textAttachment: TextAttachmentInfo.from(a["text_attachment"]))
        }
    }
}
