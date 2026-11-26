import Foundation

/// Deliberately small search language. User input is never passed through as FTS syntax.
public struct ConversationQuery: Sendable, Equatable {
    public enum Field: String, Sendable { case title, body }
    public struct Clause: Sendable, Equatable {
        public let field: Field?
        public let words: [String]
        public let phrase: Bool
        var match: String {
            let literal = words.map { "\"\($0)\"" }.joined(separator: phrase ? " + " : " AND ")
            return field.map { "\($0.rawValue) : (\(literal))" } ?? "(\(literal))"
        }
    }
    public let clauses: [Clause]
    public enum Invalid: LocalizedError, Equatable {
        case input(String)
        public var errorDescription: String? { if case .input(let text) = self { text } else { nil } }
    }
    public init(_ input: String) throws {
        guard input.count <= 2048 else { throw Invalid.input("Use a search of at most 2,048 characters.") }
        let text = Array(input.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\""))
        var index = 0
        var result: [Clause] = []
        while index < text.count {
            if text[index].isWhitespace { index += 1; continue }
            var field: Field?
            let start = index
            while index < text.count && text[index].isLetter { index += 1 }
            if index < text.count && text[index] == ":" {
                guard let parsed = Field(rawValue: String(text[start..<index]).lowercased()) else {
                    throw Invalid.input("Use title: or body: to choose a search field.")
                }
                field = parsed; index += 1
                while index < text.count && text[index].isWhitespace { index += 1 }
            } else { index = start }
            guard index < text.count else { throw Invalid.input("Add a word or quoted phrase after the field name.") }
            let phrase = text[index] == "\""
            if phrase { index += 1 }
            let valueStart = index
            while index < text.count && (phrase ? text[index] != "\"" : !text[index].isWhitespace) { index += 1 }
            let value = String(text[valueStart..<index])
            if phrase {
                guard index < text.count else { throw Invalid.input("Close the quoted phrase with a quotation mark.") }
                index += 1
                guard index == text.count || text[index].isWhitespace else { throw Invalid.input("Put a space after a quoted phrase.") }
            } else if value.contains("\"") || value.contains(":") {
                throw Invalid.input("Put phrases in quotes and use only title: or body: fields.")
            }
            let words = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard !words.isEmpty else { throw Invalid.input("Enter a word or a nonempty quoted phrase.") }
            if phrase { result.append(Clause(field: field, words: words, phrase: true)) }
            else { result += words.map { Clause(field: field, words: [$0], phrase: false) } }
            guard result.count <= 32 else { throw Invalid.input("Use at most 32 search terms.") }
        }
        clauses = result
    }
}

public enum ConversationFilter: String, CaseIterable, Sendable { case all = "All", unread = "Unread", mine = "Mine" }
public struct ConversationRow: Sendable, Equatable, Identifiable {
    public let summary: ThreadSummary
    public let participants: [String]
    public let unread: Bool
    public let hitMessageId: String?
    /// FTS highlight delimiters are separate from user Markdown and rendered as plain attributed text.
    public let excerpt: String
    public var standalone = false
    public var id: String { summary.id }
}

extension StoreReader {
    static func searchVisible(_ raw: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return false }
        let state = (object["record_state"] as? String ?? "active").lowercased()
        return !["deleted", "access_removed", "revoked"].contains(state) && (object["deleted_at"] == nil || object["deleted_at"] is NSNull)
    }
    public func cachedThreadIds(workspaceId: String, channelId: String) throws -> [String] {
        let statement = try db.prepare("SELECT thread_id FROM messages WHERE workspace_id = ?1 AND channel_id = ?2 AND deleted = 0 AND thread_id IS NOT NULL UNION SELECT id FROM threads WHERE workspace_id = ?1 AND channel_id = ?2 AND deleted = 0 ORDER BY 1")
        try statement.bind([.text(workspaceId), .text(channelId)])
        var ids: [String] = []
        while try statement.step() { if let id = statement.text(0) { ids.append(id) } }
        return ids
    }

    public func threadParticipantNpubs(workspaceId: String, threadId: String) throws -> [String] {
        let statement = try db.prepare("SELECT DISTINCT sender_npub FROM messages WHERE workspace_id = ?1 AND (thread_id = ?2 OR id IN (SELECT message_id FROM thread_membership WHERE workspace_id = ?1 AND thread_id = ?2)) AND deleted = 0 AND sender_npub IS NOT NULL ORDER BY sender_npub")
        try statement.bind([.text(workspaceId), .text(threadId)])
        var people: [String] = []
        while try statement.step() { if let npub = statement.text(0) { people.append(npub) } }
        return people
    }

    public func channelFeedLimit(workspaceId: String, channelId: String, through messageId: String) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM messages WHERE workspace_id = ?1 AND channel_id = ?2 AND deleted = 0 AND created_at >= (SELECT created_at FROM messages WHERE workspace_id = ?1 AND id = ?3)")
        try statement.bind([.text(workspaceId), .text(channelId), .text(messageId)])
        return try statement.step() ? Int(statement.int(0)) + 1 : 150
    }

    public func channelMessageCount(workspaceId: String, channelId: String) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM messages WHERE workspace_id = ? AND channel_id = ? AND deleted = 0")
        try statement.bind([.text(workspaceId), .text(channelId)])
        return try statement.step() ? Int(statement.int(0)) : 0
    }

    public func conversations(workspaceId: String, context: WorkContext, viewer: String?,
                              filter: ConversationFilter = .all, query: String = "") throws -> [ConversationRow] {
        let parsed = try ConversationQuery(query)
        let scopes = Dictionary(try scopes(workspaceId: workspaceId).map { ($0.id, $0.raw) }, uniquingKeysWith: { _, b in b })
        let accessible = try channels(workspaceId: workspaceId).filter {
            Self.searchVisible($0.raw) && (scopes[$0.scopeId].map(Self.searchVisible) ?? true)
        }
        let allowed = Set(accessible.map(\.id))
        let channels = accessible.filter { context.contains(scopeId: $0.scopeId, channelId: $0.id) }
        func visibleThread(_ id: String) throws -> Bool {
            guard let record = try thread(workspaceId: workspaceId, id: id) else { return true }
            return !record.deleted && allowed.contains(record.channelId) && Self.searchVisible(record.raw)
        }
        let states = Dictionary(try viewStates(workspaceId: workspaceId).filter { $0.resourceType == .thread }.map { ($0.resourceId, $0.unread) }, uniquingKeysWith: { _, b in b })
        var matching: Set<String>?
        var excerpts: [String: (String?, String)] = [:]
        for clause in parsed.clauses {
            guard hasFTS else { throw ConversationQuery.Invalid.input("Indexed search is unavailable in this SQLite build.") }
            let sql = try db.prepare("""
            SELECT kind, record_id, snippet(search_index, 4, '⟦', '⟧', '…', 32), highlight(search_index, 3, '⟦', '⟧')
            FROM search_index WHERE search_index MATCH ? AND workspace_id = ? AND kind IN ('message', 'thread')
            """)
            try sql.bind([.text(clause.match), .text(workspaceId)])
            var ids = Set<String>()
            while try sql.step() {
                guard let record = sql.text(1) else { continue }
                if sql.text(0) == "thread" {
                    guard try visibleThread(record) else { continue }
                    ids.insert(record)
                    if excerpts[record] == nil { excerpts[record] = (nil, sql.text(3) ?? "") }
                } else if let message = try message(workspaceId: workspaceId, id: record), !message.deleted,
                          Self.searchVisible(message.raw), allowed.contains(message.channelId) {
                    // An inherited message keeps its canonical owner while also belonging to an effective branch.
                    if let owner = message.threadId, try !visibleThread(owner) { continue }
                    let membership = try db.prepare("SELECT thread_id FROM thread_membership WHERE workspace_id = ? AND message_id = ?")
                    try membership.bind([.text(workspaceId), .text(record)])
                    var conversations = Set([message.threadId ?? message.id])
                    while try membership.step() { if let id = membership.text(0) { conversations.insert(id) } }
                    for id in conversations where try visibleThread(id) {
                        ids.insert(id)
                        excerpts[id] = (record, sql.text(2) ?? message.body)
                    }
                }
            }
            matching = matching.map { $0.intersection(ids) } ?? ids
        }
        var rows: [ConversationRow] = []
        for channel in channels {
            for summary in try channelThreads(workspaceId: workspaceId, channelId: channel.id, limit: Int.max, minimumMessages: 0) {
                guard try visibleThread(summary.id) else { continue }
                if let matching, !matching.contains(summary.id) { continue }
                let unread = states[summary.id] ?? false
                if filter == .unread && !unread { continue }
                let participants = try threadParticipantNpubs(workspaceId: workspaceId, threadId: summary.id)
                if filter == .mine {
                    let record = try thread(workspaceId: workspaceId, id: summary.id)
                    let raw = record.flatMap { try? JSONSerialization.jsonObject(with: $0.raw) as? [String: Any] }
                    guard let viewer, participants.contains(viewer) || raw?["created_by_actor_npub"] as? String == viewer else { continue }
                }
                let hit = excerpts[summary.id]
                rows.append(ConversationRow(summary: summary, participants: participants, unread: unread,
                                            hitMessageId: hit?.0, excerpt: hit?.1 ?? summary.latestBody))
            }
            let posts = try db.prepare("SELECT id FROM messages WHERE workspace_id = ? AND channel_id = ? AND thread_id IS NULL AND deleted = 0 ORDER BY created_at DESC, id DESC")
            try posts.bind([.text(workspaceId), .text(channel.id)])
            while try posts.step() {
                guard let id = posts.text(0), let message = try message(workspaceId: workspaceId, id: id), Self.searchVisible(message.raw) else { continue }
                if let matching, !matching.contains(id) { continue }
                if filter == .unread { continue } // no canonical thread read state exists for a legacy channel post
                if filter == .mine && (viewer == nil || message.senderNpub != viewer) { continue }
                let summary = ThreadSummary(id: id, channelId: channel.id, title: nil, rootBody: message.body, rootSender: message.senderNpub,
                                            latestBody: message.body, latestSender: message.senderNpub, replyCount: 0, lastActivityAt: message.createdAt)
                rows.append(ConversationRow(summary: summary, participants: message.senderNpub.map { [$0] } ?? [], unread: false,
                                            hitMessageId: excerpts[id]?.0, excerpt: excerpts[id]?.1 ?? message.body, standalone: true))
            }
        }
        return rows.sorted { ($0.summary.lastActivityAt, $0.id) > ($1.summary.lastActivityAt, $1.id) }
    }
}
