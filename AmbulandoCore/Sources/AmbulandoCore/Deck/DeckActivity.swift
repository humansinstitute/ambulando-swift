import Foundation

/// Deck's Inbox and Recent cards, built from the local store with the web app's rules (sol
/// `autopilot-overview-manager.js`: `buildAutopilotOverviewThreads/Tasks/Documents/Files`, `buildAutopilotOverviewInbox`,
/// `filterAutopilotOverviewInbox`, `buildRecentChannels`).
///
/// Deck's Inbox is an activity feed for the current Scope | Channel: conversations, open tasks (finished ones only while
/// unread), documents and files, newest first. Unread comes from Tower's view states, "working" from agent
/// activity that has not ended. It is not the unread-only list the build 3–8 Inbox tab showed.
public enum DeckActivity {
    public enum Kind: String, Sendable, CaseIterable, Codable { case chat, task, document, file }

    public struct Item: Sendable, Equatable, Identifiable {
        public let kind: Kind
        public let recordId: String
        public let channelId: String?
        public let scopeId: String?
        public let title: String
        /// Chat: latest message; task: state label; document: summary; file: description or type.
        public let subtitle: String
        /// Why it is here ("2 recent comments", "Task updated", …).
        public let reason: String
        public let activityAt: String
        public let isUnread: Bool
        public let isWorking: Bool
        public let taskState: String?
        /// Chat: false for a channel post stored without a thread id (it opens the channel).
        public var isThread = true
        /// Lower-cased text searched by the Inbox search field.
        public let searchText: String
        public var id: String { "\(kind.rawValue):\(recordId)" }
    }

    /// One conversation with its latest stored message (a Deck chat card or a Recent channel row).
    public struct ThreadActivity: Sendable, Equatable {
        public let threadId: String
        public let channelId: String
        /// False for a channel post stored without a thread id (opens the channel instead).
        public let isThread: Bool
        public let title: String?
        public let rootBody: String?
        public let latestBody: String
        public let latestAt: String
        public let messageCount: Int
        public init(threadId: String, channelId: String, isThread: Bool, title: String?, rootBody: String?, latestBody: String,
                    latestAt: String, messageCount: Int) {
            self.threadId = threadId; self.channelId = channelId; self.isThread = isThread; self.title = title; self.rootBody = rootBody
            self.latestBody = latestBody; self.latestAt = latestAt; self.messageCount = messageCount
        }
    }

    /// Comment activity per parent record: count and newest time (tasks: comments by others; documents: open comments).
    public struct CommentActivity: Sendable, Equatable {
        public var count: Int
        public var latestAt: String?
        public init(count: Int, latestAt: String?) { self.count = count; self.latestAt = latestAt }
    }

    public struct Sources: Sendable {
        public var threads: [ThreadActivity] = []
        public var tasks: [TaskRecord] = []
        public var docs: [DocRecord] = []
        public var files: [FileRecord] = []
        public var viewStates: [ViewStateRecord] = []
        public var taskComments: [String: CommentActivity] = [:]
        public var docComments: [String: CommentActivity] = [:]
        public var activities: [AgentActivityRecord] = []
        /// Channel → scope, for records stored without a scope id.
        public var channelScopes: [String: String] = [:]
        public init() {}
    }

    /// Task states the web counts as "completed": shown only while unread.
    static let completedStates: Set<String> = ["done", "complete", "completed"]
    static let terminalStates: Set<String> = ["done", "complete", "completed", "archive", "archived", "cancelled", "canceled"]

    /// Every Deck Inbox item in `context`, newest first.
    public static func inbox(_ sources: Sources, context: WorkContext) -> [Item] {
        let unread = Dictionary(sources.viewStates.map { ("\($0.resourceType.rawValue):\($0.resourceId)", $0.unread) }, uniquingKeysWith: { a, b in a || b })
        let working = workingKeys(sources.activities)
        func scope(_ scopeId: String?, _ channelId: String?) -> String? { scopeId ?? channelId.flatMap { sources.channelScopes[$0] } }
        func matches(_ scopeId: String?, _ channelId: String?) -> Bool {
            guard let wanted = context.scopeId else { return true }
            if let channel = context.channelId { return channelId == channel }
            return scope(scopeId, channelId) == wanted
        }
        var items: [Item] = []
        for thread in sources.threads where matches(nil, thread.channelId) {
            let title = threadTitle(thread)
            items.append(Item(kind: .chat, recordId: thread.threadId, channelId: thread.channelId, scopeId: scope(nil, thread.channelId),
                              title: title, subtitle: MentionCodec.plain(thread.latestBody), reason: thread.messageCount == 1 ? "1 message" : "\(thread.messageCount) messages",
                              activityAt: thread.latestAt, isUnread: unread["thread:\(thread.threadId)"] == true,
                              isWorking: working.contains("thread:\(thread.threadId)"), taskState: nil, isThread: thread.isThread,
                              searchText: [title, thread.latestBody, thread.rootBody ?? ""].joined(separator: " ").lowercased()))
        }
        for task in sources.tasks where matches(task.scopeId, task.channelId) {
            let state = task.state.lowercased()
            let isUnread = unread["task:\(task.id)"] == true
            if terminalStates.contains(state) && !(completedStates.contains(state) && isUnread) { continue }
            let comments = sources.taskComments[task.id]
            let updated = task.updatedAt.isEmpty ? task.createdAt : task.updatedAt
            let commentDrove = (comments?.latestAt ?? "") > updated
            let activity = max(updated, comments?.latestAt ?? "")
            guard !activity.isEmpty else { continue }
            let label = task.taskState?.label ?? task.state.capitalized
            items.append(Item(kind: .task, recordId: task.id, channelId: task.channelId, scopeId: scope(task.scopeId, task.channelId),
                              title: task.title.isEmpty ? "Untitled task" : task.title, subtitle: label,
                              reason: commentDrove ? "\(comments!.count) recent \(comments!.count == 1 ? "comment" : "comments")"
                                                   : (task.updatedAt.isEmpty ? "Task created" : "Task updated"),
                              activityAt: activity, isUnread: isUnread, isWorking: working.contains("task:\(task.id)"), taskState: task.state,
                              searchText: [task.title, task.description ?? "", task.state, label].joined(separator: " ").lowercased()))
        }
        for doc in sources.docs where !doc.archived && matches(doc.scopeId, doc.channelId) {
            let comments = sources.docComments[doc.id]
            let updated = doc.updatedAt.isEmpty ? doc.createdAt : doc.updatedAt
            let activity = max(updated, comments?.latestAt ?? "")
            guard !activity.isEmpty else { continue }
            let open = comments?.count ?? 0
            items.append(Item(kind: .document, recordId: doc.id, channelId: doc.channelId, scopeId: scope(doc.scopeId, doc.channelId),
                              title: doc.title.isEmpty ? "Untitled document" : doc.title, subtitle: doc.summary ?? "Document",
                              reason: open > 0 ? "\(open) unresolved \(open == 1 ? "comment" : "comments")" : (doc.updatedAt.isEmpty ? "Document created" : "Document updated"),
                              activityAt: activity, isUnread: unread["document:\(doc.id)"] == true, isWorking: working.contains("document:\(doc.id)"), taskState: nil,
                              searchText: [doc.title, doc.summary ?? ""].joined(separator: " ").lowercased()))
        }
        for file in sources.files where !file.archived && matches(file.scopeId, file.channelId) {
            let activity = file.updatedAt.isEmpty ? file.createdAt : file.updatedAt
            items.append(Item(kind: .file, recordId: file.id, channelId: file.channelId, scopeId: scope(file.scopeId, file.channelId),
                              title: file.displayName, subtitle: file.description ?? file.contentType ?? "File",
                              reason: file.updatedAt.isEmpty || file.updatedAt == file.createdAt ? "Uploaded file" : "Edited file",
                              activityAt: activity, isUnread: false, isWorking: false, taskState: nil,
                              searchText: [file.displayName, file.description ?? "", file.contentType ?? ""].joined(separator: " ").lowercased()))
        }
        return items.sorted { a, b in a.activityAt != b.activityAt ? a.activityAt > b.activityAt : a.id < b.id }
    }

    /// The web's type toggles and search: any combination of kinds, then a case-insensitive substring match.
    public static func filter(_ items: [Item], kinds: Set<Kind>, query: String) -> [Item] {
        let needle = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return items.filter { kinds.contains($0.kind) && (needle.isEmpty || $0.searchText.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(needle)) }
    }

    /// Recent channels: each channel's newest conversation in the scope (the channel choice is ignored, as on the web),
    /// at most `limit`.
    public static func recentChannels(_ threads: [ThreadActivity], scopeId: String?, channelScopes: [String: String], limit: Int = 10) -> [ThreadActivity] {
        var seen = Set<String>(), rows: [ThreadActivity] = []
        for thread in threads.sorted(by: { $0.latestAt != $1.latestAt ? $0.latestAt > $1.latestAt : $0.threadId < $1.threadId }) {
            if let scopeId, channelScopes[thread.channelId] != scopeId { continue }
            guard seen.insert(thread.channelId).inserted else { continue }
            rows.append(thread)
            if rows.count == limit { break }
        }
        return rows
    }

    public static func threadTitle(_ thread: ThreadActivity) -> String {
        let source = [thread.title, thread.rootBody, thread.latestBody].compactMap { $0 }.map { MentionCodec.plain($0) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Conversation"
        var line = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? source
        // A Markdown heading's marks are not part of the title.
        if line.hasPrefix("#") { line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }

    /// Records an agent is working on now (activity not ended): `thread:<id>`.
    static func workingKeys(_ activities: [AgentActivityRecord]) -> Set<String> {
        Set(activities.filter { !$0.isTerminal }.compactMap { $0.threadId.map { "thread:\($0)" } })
    }
}

extension StoreReader {
    /// Newest `limit` conversations with their latest stored message, optionally limited to `channelIds`.
    public func deckThreads(workspaceId: String, channelIds: [String]?, limit: Int = 300) throws -> [DeckActivity.ThreadActivity] {
        if let channelIds, channelIds.isEmpty { return [] }
        let filter = channelIds.map { "AND m.channel_id IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))" } ?? ""
        // Newest conversations first (one grouped scan), then the titles and bodies for only those rows.
        let s = try db.prepare("""
        WITH latest AS (
          SELECT COALESCE(m.thread_id, m.id) AS tid, MIN(m.channel_id) AS channel, MAX(m.created_at) AS at, COUNT(*) AS n,
                 MAX(m.thread_id IS NOT NULL) AS threaded
          FROM messages m
          WHERE m.workspace_id = ? AND m.deleted = 0 \(filter)
          GROUP BY tid ORDER BY at DESC, tid LIMIT ?)
        SELECT latest.tid, latest.channel, latest.at, latest.n, latest.threaded,
          (SELECT t.title FROM threads t WHERE t.workspace_id = ?1 AND t.id = latest.tid AND t.deleted = 0),
          (SELECT r.body FROM messages r WHERE r.workspace_id = ?1 AND r.thread_id = latest.tid AND r.thread_source_id = r.id AND r.deleted = 0 LIMIT 1),
          CASE WHEN latest.threaded THEN
            (SELECT l.body FROM messages l WHERE l.workspace_id = ?1 AND l.thread_id = latest.tid AND l.deleted = 0 ORDER BY l.created_at DESC, l.id DESC LIMIT 1)
          ELSE (SELECT l.body FROM messages l WHERE l.workspace_id = ?1 AND l.id = latest.tid) END
        FROM latest
        WHERE NOT EXISTS (SELECT 1 FROM threads x WHERE x.workspace_id = ?1 AND x.id = latest.tid AND (x.deleted = 1 OR x.archived = 1))
        ORDER BY latest.at DESC, latest.tid
        """)
        try s.bind([.text(workspaceId)] + (channelIds ?? []).map { .text($0) } + [.int(Int64(limit))])
        var rows: [DeckActivity.ThreadActivity] = []
        while try s.step() {
            rows.append(.init(threadId: s.text(0)!, channelId: s.text(1)!, isThread: s.int(4) != 0, title: s.text(5), rootBody: s.text(6),
                              latestBody: s.text(7) ?? "", latestAt: s.text(2) ?? "", messageCount: Int(s.int(3))))
        }
        return rows
    }

    /// Comment counts and newest times per task (comments by anyone but `viewerNpub`) or per document (open comments).
    public func deckCommentActivity(workspaceId: String, parent: CommentRecord.Parent, viewerNpub: String?) throws -> [String: DeckActivity.CommentActivity] {
        let condition = parent == .task ? "AND (sender_npub IS NULL OR sender_npub <> ?)" : "AND COALESCE(status, 'open') = 'open'"
        let s = try db.prepare("""
        SELECT parent_id, COUNT(*), MAX(updated_at) FROM comments
        WHERE workspace_id = ? AND parent = ? AND deleted = 0 \(condition) GROUP BY parent_id
        """)
        var binds: [SQLValue] = [.text(workspaceId), .text(parent.rawValue)]
        if parent == .task { binds.append(.text(viewerNpub ?? "")) }
        try s.bind(binds)
        var rows: [String: DeckActivity.CommentActivity] = [:]
        while try s.step() { rows[s.text(0)!] = .init(count: Int(s.int(1)), latestAt: s.text(2)) }
        return rows
    }
}
