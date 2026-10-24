import Foundation

/// Reads bounded by the shared `WorkContext`. A scope context matches records whose own scope is the scope or whose
/// channel belongs to it (older records may carry only a channel); a channel context matches that channel only. Home
/// spans the workspace. Every query stays inside one workspace.
extension StoreReader {
    /// SQL condition on a table with `scope_id` and `channel_id` columns, and its bindings.
    static func contextFilter(_ context: WorkContext, workspaceId: String) -> (sql: String, bindings: [SQLValue]) {
        guard let scopeId = context.scopeId else { return ("1 = 1", []) }
        if let channelId = context.channelId { return ("channel_id = ?", [.text(channelId)]) }
        return ("(scope_id = ? OR channel_id IN (SELECT id FROM channels WHERE workspace_id = ? AND scope_id = ?))",
                [.text(scopeId), .text(workspaceId), .text(scopeId)])
    }

    public func tasks(workspaceId: String, context: WorkContext, includeArchived: Bool = false, limit: Int = 500) throws -> [TaskRecord] {
        let filter = Self.contextFilter(context, workspaceId: workspaceId)
        let s = try db.prepare("""
        SELECT \(Self.taskColumns) FROM tasks WHERE workspace_id = ? AND \(filter.sql)
          AND (? = 1 OR state NOT IN ('archive', 'archived')) ORDER BY updated_at DESC, id LIMIT ?
        """)
        try s.bind([.text(workspaceId)] + filter.bindings + [.int(includeArchived ? 1 : 0), .int(Int64(limit))])
        var rows: [TaskRecord] = []
        while try s.step() { rows.append(Self.task(s, workspaceId: workspaceId)) }
        return rows
    }

    public func docs(workspaceId: String, context: WorkContext, limit: Int = 500) throws -> [DocRecord] {
        let filter = Self.contextFilter(context, workspaceId: workspaceId)
        let s = try db.prepare("""
        SELECT \(Self.docColumns) FROM docs WHERE workspace_id = ? AND \(filter.sql) AND archived = 0
        ORDER BY updated_at DESC, id LIMIT ?
        """)
        try s.bind([.text(workspaceId)] + filter.bindings + [.int(Int64(limit))])
        var rows: [DocRecord] = []
        while try s.step() { rows.append(Self.doc(s, workspaceId: workspaceId)) }
        return rows
    }

    public func files(workspaceId: String, context: WorkContext, limit: Int = 500) throws -> [FileRecord] {
        let filter = Self.contextFilter(context, workspaceId: workspaceId)
        let s = try db.prepare("""
        SELECT \(Self.fileColumns) FROM files WHERE workspace_id = ? AND \(filter.sql) AND archived = 0
        ORDER BY display_name COLLATE NOCASE, id LIMIT ?
        """)
        try s.bind([.text(workspaceId)] + filter.bindings + [.int(Int64(limit))])
        var rows: [FileRecord] = []
        while try s.step() { rows.append(Self.file(s, workspaceId: workspaceId)) }
        return rows
    }

    /// Channels with unread or attention-needing activity (any resource in them), for the sidebar.
    public func unreadChannelIds(workspaceId: String) throws -> Set<String> {
        let s = try db.prepare("""
        SELECT DISTINCT channel_id FROM view_states WHERE workspace_id = ? AND channel_id IS NOT NULL
          AND (activity_version > viewed_activity_version OR (attention_activity_version IS NOT NULL AND attention_activity_version > viewed_activity_version))
        """)
        try s.bind([.text(workspaceId)])
        var ids = Set<String>()
        while try s.step() { if let id = s.text(0) { ids.insert(id) } }
        return ids
    }
}

/// A conversation inside a channel, for the channel's thread list: what it is about, how much was said and when.
public struct ThreadSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let channelId: String
    /// Tower's thread title (derived from the source message when not set), or nil when only messages are stored.
    public let title: String?
    /// The first stored message (the root), as shown in the channel.
    public let rootBody: String
    public let rootSender: String?
    /// The newest message and its sender (activity cue).
    public let latestBody: String
    public let latestSender: String?
    public let replyCount: Int
    public let lastActivityAt: String
    public let archived: Bool
}

extension StoreReader {
    /// Threads of a channel with replies, newest activity first. Threads known only from their messages (no thread
    /// record, or no stored source message) are included, so no synced conversation is hidden.
    public func channelThreads(workspaceId: String, channelId: String, limit: Int = 200) throws -> [ThreadSummary] {
        let s = try db.prepare("""
        WITH ids(id) AS (
          SELECT id FROM threads WHERE workspace_id = ?1 AND channel_id = ?2 AND deleted = 0
          UNION SELECT DISTINCT thread_id FROM messages WHERE workspace_id = ?1 AND channel_id = ?2 AND thread_id IS NOT NULL AND deleted = 0
        ),
        stats AS (
          SELECT ids.id AS id,
            (SELECT COUNT(*) FROM messages m WHERE m.workspace_id = ?1 AND m.thread_id = ids.id AND m.deleted = 0) AS total,
            (SELECT MAX(m.created_at) FROM messages m WHERE m.workspace_id = ?1 AND m.thread_id = ids.id AND m.deleted = 0) AS last_at
          FROM ids
        )
        SELECT stats.id, t.title, t.archived, stats.total, stats.last_at,
          (SELECT body FROM messages m WHERE m.workspace_id = ?1 AND m.thread_id = stats.id AND m.deleted = 0 ORDER BY created_at, id LIMIT 1),
          (SELECT COALESCE(sender_label, sender_npub) FROM messages m WHERE m.workspace_id = ?1 AND m.thread_id = stats.id AND m.deleted = 0 ORDER BY created_at, id LIMIT 1),
          (SELECT body FROM messages m WHERE m.workspace_id = ?1 AND m.thread_id = stats.id AND m.deleted = 0 ORDER BY created_at DESC, id DESC LIMIT 1),
          (SELECT sender_npub FROM messages m WHERE m.workspace_id = ?1 AND m.thread_id = stats.id AND m.deleted = 0 ORDER BY created_at DESC, id DESC LIMIT 1),
          (SELECT sender_npub FROM messages m WHERE m.workspace_id = ?1 AND m.thread_id = stats.id AND m.deleted = 0 ORDER BY created_at, id LIMIT 1)
        FROM stats LEFT JOIN threads t ON t.workspace_id = ?1 AND t.id = stats.id
        WHERE stats.total > 1
        ORDER BY stats.last_at DESC, stats.id LIMIT ?3
        """)
        try s.bind([.text(workspaceId), .text(channelId), .int(Int64(limit))])
        var rows: [ThreadSummary] = []
        while try s.step() {
            let total = Int(s.int(3))
            rows.append(ThreadSummary(id: s.text(0)!, channelId: channelId, title: s.text(1), rootBody: s.text(5) ?? "",
                                      rootSender: s.text(9) ?? s.text(6), latestBody: s.text(7) ?? "", latestSender: s.text(8),
                                      replyCount: max(0, total - 1), lastActivityAt: s.text(4) ?? "", archived: s.int(2) != 0))
        }
        return rows
    }

    /// Thread titles for a channel, for labelling thread roots in its message list.
    public func threadTitles(workspaceId: String, channelId: String) throws -> [String: String] {
        let s = try db.prepare("SELECT id, title FROM threads WHERE workspace_id = ? AND channel_id = ? AND deleted = 0 AND title IS NOT NULL AND title <> ''")
        try s.bind([.text(workspaceId), .text(channelId)])
        var titles: [String: String] = [:]
        while try s.step() { titles[s.text(0)!] = s.text(1)! }
        return titles
    }
}
