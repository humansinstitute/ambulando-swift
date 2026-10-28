import Foundation

/// A record offered by the `@` picker besides people and agents: what the mention will name and how it is described.
public struct MentionSuggestion: Sendable, Equatable, Identifiable {
    public let mention: Mention
    /// The kind word or scope level shown under the name ("Doc", "Task", "Thread", "Project").
    public let detail: String
    public let updatedAt: String
    public var id: String { "\(mention.type.rawValue):\(mention.id)" }

    public init(mention: Mention, detail: String, updatedAt: String) {
        self.mention = mention; self.detail = detail; self.updatedAt = updatedAt
    }
}

/// The `@` lookahead (sol `searchMentions` / `getDefaultMentionResults`): what was typed after `@`, optionally led by a
/// kind prefix as on the web (`doc:`, `task:`, `channel:` or its alias `chat:`, `scope:`, `agent:`, `person:`, plus
/// `thread:` for conversations), matched anywhere in the name ignoring case.
public struct MentionQuery: Sendable, Equatable {
    public let text: String
    /// Only this kind (from a prefix); nil for every kind.
    public let only: MentionType?
    /// A web prefix for records this device does not store (`flow:`, `opportunity:`): nothing is offered.
    public let unavailable: Bool

    public init(_ raw: String) {
        let lower = raw.lowercased()
        for (prefix, type) in Self.prefixes where lower.hasPrefix(prefix) {
            only = type
            unavailable = type == nil
            text = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return
        }
        only = nil
        unavailable = false
        text = raw.trimmingCharacters(in: .whitespaces)
    }

    static let prefixes: [(String, MentionType?)] = [
        ("doc:", .doc), ("task:", .task), ("channel:", .channel), ("chat:", .channel), ("thread:", .chat), ("scope:", .scope),
        ("agent:", .agent), ("person:", .person), ("flow:", nil), ("opportunity:", nil),
    ]

    public func allows(_ type: MentionType) -> Bool {
        if unavailable { return false }
        guard let only else { return true }
        // As on the web, `person:` lists agents too.
        return only == type || (only == .person && type == .agent)
    }

    /// How many suggestions are offered: 15 for a bare `@` (recently tagged first, the rest scrolls), 10 once a name is typed,
    /// every channel for `channel:`.
    public var limit: Int { text.isEmpty && only == nil ? 15 : only == .channel ? 500 : 10 }

    /// Where `label` matches: 0 exact, 1 at the start, 2 inside; nil no match. Case is ignored in any script.
    public func rank(_ label: String) -> Int? {
        guard !text.isEmpty else { return 2 }
        if label.compare(text, options: .caseInsensitive) == .orderedSame { return 0 }
        guard let found = label.range(of: text, options: .caseInsensitive) else { return nil }
        return found.lowerBound == label.startIndex ? 1 : 2
    }
}

extension StoreReader {
    /// Documents, tasks, conversations, channels and scopes of one workspace whose names contain `query`, names that
    /// start with it first, then the most recently updated, at most `limit` per kind. Only rows this viewer synced are
    /// here (Tower lists what they may read), and a document, task or conversation must also sit in a channel this device
    /// still lists (one whose access was lost is gone). Archived tasks and documents and deleted conversations are left
    /// out. An empty query lists the most recently updated of each kind (the picker's bare `@`).
    ///
    /// Typed ASCII uses SQLite's `LIKE` (case-insensitive for ASCII); other text uses `amb_ifind`, which ignores case in
    /// any script (and declines all-ASCII names from their bytes). Each kind is one scan of that workspace's rows found
    /// through the `(workspace_id, channel_id)` index: a few milliseconds for 16,000 titles (`MentionLookupTests`).
    public func mentionSuggestions(workspaceId: String, query: MentionQuery, limit: Int = 10, resolving mention: Mention? = nil) throws -> [MentionSuggestion] {
        let needle = query.text
        let ascii = needle.unicodeScalars.allSatisfy(\.isASCII)
        let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        // Positional bindings after the inner query's `?1` (the workspace): ?2 the text, ?3 its pattern, ?4 its prefix
        // pattern, ?5 the limit.
        let match = ascii ? "(?2 = '' OR label LIKE ?3 ESCAPE '\\')" : "amb_ifind(label, ?2) > 0"
        let starts = ascii ? "(label LIKE ?4 ESCAPE '\\')" : "(amb_ifind(label, ?2) = 1)"
        let binds: [SQLValue] = [.text(workspaceId), .text(needle), .text("%" + escaped + "%"), .text(escaped + "%"), .int(Int64(limit))]
        let listed = "channel_id IN (SELECT id FROM channels WHERE workspace_id = ?1)"

        var out: [MentionSuggestion] = []
        func run(_ type: MentionType, _ sql: String, _ make: (SQLiteConnection.Statement) -> MentionSuggestion?) throws {
            guard query.allows(type), mention == nil || mention?.type == type else { return }
            let identity = type == .chat ? "channel_id || '#' || root" : "id"
            let exact = mention == nil ? "" : " AND \(identity) = ?6"
            let s = try db.prepare("SELECT * FROM (\(sql)) WHERE \(match)\(exact) ORDER BY \(starts) DESC, updated_at DESC, label LIMIT ?5")
            try s.bind(binds + (mention.map { [.text($0.id)] } ?? []))
            while try s.step() { if let row = make(s) { out.append(row) } }
        }
        try run(.doc, "SELECT id, title AS label, updated_at FROM docs WHERE workspace_id = ?1 AND archived = 0 AND \(listed)") { s in
            MentionSuggestion(mention: Mention(type: .doc, npub: s.text(0)!, label: Self.label(s.text(1))), detail: "Doc", updatedAt: s.text(2) ?? "")
        }
        try run(.task, "SELECT id, title AS label, updated_at FROM tasks WHERE workspace_id = ?1 AND state NOT IN ('archive', 'archived') AND \(listed)") { s in
            MentionSuggestion(mention: Mention(type: .task, npub: s.text(0)!, label: Self.label(s.text(1))), detail: "Task", updatedAt: s.text(2) ?? "")
        }
        // A conversation is named by its title (Tower derives one from the first message) or else its first message,
        // and referenced as the web's FD Ref: `<channel>#<root message>` (the real root message, never the thread id).
        try run(.chat, """
            SELECT t.id, coalesce(nullif(trim(t.title), ''), r.body) AS label, t.updated_at, t.channel_id, r.id AS root
            FROM threads t
            JOIN messages r ON r.workspace_id = t.workspace_id AND r.id = coalesce(t.source_message_id,
              (SELECT m.id FROM messages m WHERE m.workspace_id = t.workspace_id AND m.thread_id = t.id ORDER BY m.created_at, m.id LIMIT 1))
            WHERE t.workspace_id = ?1 AND t.deleted = 0 AND t.archived = 0 AND r.deleted = 0 AND t.\(listed)
            """) { s in
            guard let channel = s.text(3), let root = s.text(4) else { return nil }
            let label = String(MentionCodec.plain(s.text(1) ?? "").split(whereSeparator: \.isNewline).first ?? "").prefix(60)
            return MentionSuggestion(mention: Mention(type: .chat, npub: "\(channel)#\(root)", label: Self.label(String(label))), detail: "Thread",
                                     updatedAt: s.text(2) ?? "")
        }
        try run(.channel, "SELECT id, name AS label, updated_at FROM channels WHERE workspace_id = ?1") { s in
            MentionSuggestion(mention: Mention(type: .channel, npub: s.text(0)!, label: Self.label(s.text(1))), detail: "Channel", updatedAt: s.text(2) ?? "")
        }
        try run(.scope, "SELECT id, name AS label, updated_at, kind FROM scopes WHERE workspace_id = ?1") { s in
            let level = (s.text(3) ?? "").lowercased()
            let detail = level == "product" ? "Product" : level == "project" ? "Project" : level == "deliverable" ? "Deliverable" : "Scope"
            return MentionSuggestion(mention: Mention(type: .scope, npub: s.text(0)!, label: Self.label(s.text(1))), detail: detail, updatedAt: s.text(2) ?? "")
        }
        return out
    }

    /// What this person tagged most recently in this workspace, newest message first (and in order within a message), each
    /// once: read from the `@[Label](mention:type:id)` tokens of their own stored messages, so existing history counts and
    /// nothing new is stored. Feeds the bare `@` list.
    public func recentMentions(workspaceId: String, senderNpub: String, limit: Int = 8, scan: Int = 300) throws -> [Mention] {
        let s = try db.prepare("""
            SELECT body FROM messages WHERE workspace_id = ?1 AND sender_npub = ?2 AND deleted = 0 AND body LIKE '%(mention:%'
            ORDER BY created_at DESC, id DESC LIMIT ?3
            """)
        try s.bind([.text(workspaceId), .text(senderNpub), .int(Int64(scan))])
        var seen = Set<String>(), out: [Mention] = []
        while try s.step(), out.count < limit {
            for mention in MentionRanking.mentions(inBody: s.text(0) ?? "") where seen.insert(mention.type.rawValue + ":" + mention.npub).inserted {
                // Resolve each identity independently: an old but eligible record need not be in the
                // truncated default results. Never reuse the historical label or resurrect removed rows.
                if mention.type.isActor { out.append(mention) }
                else if let current = try mentionSuggestions(workspaceId: workspaceId, query: MentionQuery(""), limit: 1, resolving: mention).first {
                    out.append(current.mention)
                }
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// SQLite's plan for the documents lookup (for the timing test's evidence).
    func explainMentionLookup(workspaceId: String) throws -> [String] {
        let s = try db.prepare("""
            EXPLAIN QUERY PLAN SELECT * FROM (SELECT id, title AS label, updated_at FROM docs WHERE workspace_id = ?1 AND archived = 0
              AND channel_id IN (SELECT id FROM channels WHERE workspace_id = ?1)) WHERE (?2 = '' OR label LIKE ?3 ESCAPE '\\')
            ORDER BY (label LIKE ?4 ESCAPE '\\') DESC, updated_at DESC, label LIMIT ?5
            """)
        try s.bind([.text(workspaceId), .text("plan"), .text("%plan%"), .text("plan%"), .int(10)])
        var rows: [String] = []
        while try s.step() { rows.append(s.text(3) ?? "") }
        return rows
    }

    private static func label(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

public enum MentionRanking {
    /// Display order of the kinds (sol `searchMentions`: people, docs, tasks, channels, scopes; conversations follow tasks).
    static let order: [MentionType] = [.agent, .person, .doc, .task, .chat, .channel, .scope]

    /// People and agents from the directory (`actors`, each with extra text it also matches, such as the npub) and
    /// records, merged as the web orders them: grouped by kind in the web's order, an exact person or agent first;
    /// inside a kind, names starting with the text first, then the most recent.
    /// The mentions a stored body carries, in order. People, agents and the picker's record kinds only; the web's
    /// `document` spelling counts as `doc`.
    public static func mentions(inBody body: String) -> [Mention] {
        MentionCodec.segments(body).compactMap { segment in
            switch segment {
            case .mention(let mention): return mention
            case .reference(let label, let kind, let id):
                guard let type = MentionType(rawValue: kind == "document" ? "doc" : kind) else { return nil }
                return Mention(type: type, npub: id, label: label)
            case .text: return nil
            }
        }
    }

    public static func merge(actors: [(mention: Mention, also: String)], records: [MentionSuggestion], query: MentionQuery,
                             recent: [Mention] = []) -> [MentionSuggestion] {
        let limit = query.limit
        let people = actors.filter { query.allows($0.mention.type) && (query.rank($0.mention.label) != nil || query.text.isEmpty
                                                                        || $0.also.range(of: query.text, options: .caseInsensitive) != nil) }
            .map { MentionSuggestion(mention: $0.mention, detail: $0.mention.type.label, updatedAt: "") }
        if query.text.isEmpty && query.only == nil {
            // Bare `@`: what was tagged most recently comes first (people and agents only while the directory still lists
            // them, under their current name), then sol's getDefaultMentionResults: 2 people, the 3 most recent documents,
            // then 2 of each other kind.
            let directory = Dictionary(actors.map { ($0.mention.npub, $0.mention) }, uniquingKeysWith: { first, _ in first })
            var out: [MentionSuggestion] = recent.compactMap { mention in
                if mention.type.isActor { return directory[mention.npub].map { MentionSuggestion(mention: $0, detail: $0.type.label, updatedAt: "") } }
                return MentionSuggestion(mention: mention, detail: mention.type.label, updatedAt: "")
            }
            out += people.prefix(2)
            let byKind = Dictionary(grouping: records, by: \.mention.type)
            let quota: [MentionType: Int] = [.doc: 3, .task: 2, .chat: 2, .channel: 2, .scope: 2]
            for type in order where !type.isActor {
                out += (byKind[type] ?? []).sorted { $0.updatedAt > $1.updatedAt }.prefix(quota[type] ?? 2)
            }
            return dedupe(out, limit: limit)
        }
        let rows = people + records.filter { query.allows($0.mention.type) && query.rank($0.mention.label) != nil }
        let sorted = rows.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            let exactX = x.mention.type.isActor && query.rank(x.mention.label) == 0
            let exactY = y.mention.type.isActor && query.rank(y.mention.label) == 0
            if exactX != exactY { return exactX }
            let kx = order.firstIndex(of: x.mention.type) ?? 0, ky = order.firstIndex(of: y.mention.type) ?? 0
            if x.mention.type.isActor && y.mention.type.isActor { return a.offset < b.offset }
            if kx != ky { return kx < ky }
            let rx = query.rank(x.mention.label) ?? 2, ry = query.rank(y.mention.label) ?? 2
            if (rx <= 1) != (ry <= 1) { return rx <= 1 }
            if x.updatedAt != y.updatedAt { return x.updatedAt > y.updatedAt }
            return a.offset < b.offset
        }
        return dedupe(sorted.map(\.element), limit: limit)
    }

    private static func dedupe(_ rows: [MentionSuggestion], limit: Int) -> [MentionSuggestion] {
        var seen = Set<String>()
        return Array(rows.filter { seen.insert($0.id).inserted }.prefix(limit))
    }
}
