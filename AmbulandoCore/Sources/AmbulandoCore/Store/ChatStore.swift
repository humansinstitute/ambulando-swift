import Foundation

/// Where a composer writes: one channel (new conversation) or one thread (reply), under one connection.
/// It is captured by the screen that owns the composer, never read from a global selection, so a workspace switch
/// or lock between typing and sending cannot redirect a message.
public struct ChatTarget: Sendable, Hashable, Codable {
    public let connectionId: String
    public let workspaceId: String
    public let channelId: String
    public let threadId: String?

    public init(connectionId: String, workspaceId: String, channelId: String, threadId: String? = nil) {
        self.connectionId = connectionId; self.workspaceId = workspaceId; self.channelId = channelId; self.threadId = threadId
    }

    public var draftKey: String { [connectionId, workspaceId, channelId, threadId ?? "_channel"].joined(separator: ":") }
}

public struct Draft: Sendable, Equatable {
    public let text: String
    public let mentions: [Mention]
    /// When the stored draft was last written (millisecond precision), so a composer can tell a draft written after
    /// its own send (an Edit restore) from one read before it.
    public let updatedAt: Date?
    public init(text: String, mentions: [Mention], updatedAt: Date? = nil) { self.text = text; self.mentions = mentions; self.updatedAt = updatedAt }
}

extension StoreWriter {
    /// Draft timestamps keep milliseconds (`now()` is second precision).
    func draftStamp() -> String { ISO8601DateFormatter.tower.string(from: Date()) }
}

/// Outbox lifecycle. A row is deleted when Tower acknowledges it (or a synced copy with its `client_request_id` arrives).
public enum OutboxState: String, Sendable, Codable {
    /// Written while the identity was locked; it is signed only after an explicit unlock.
    case awaitingSignature = "awaiting_signature"
    /// Request frozen (body + kind 33358 signature + client_request_id); ready to send.
    case queued
    case sending
    /// Network/server problem; retried automatically with backoff using the same frozen request.
    case retrying
    /// Tower rejected the request permanently; the user chooses retry, edit or discard.
    case failed
}

public struct OutboxItem: Sendable, Equatable, Identifiable {
    public let id: String            // also the client_request_id
    public let connectionId: String
    public let origin: String
    public let signerNpub: String
    public let workspaceId: String
    public let appNpub: String
    public let channelId: String
    public let threadId: String?
    public let createThread: Bool
    public let body: String          // exact trimmed wire body, mention tokens included
    public let mentions: [Mention]
    public let request: Data?        // frozen exact JSON bytes, once signed
    public let state: OutboxState
    public let attempts: Int
    public let lastStatus: Int?
    public let lastCode: String?
    public let lastError: String?
    public let createdAt: String
    /// Images to upload before the message is signed (their storage ids become part of the signed request).
    public var attachments: [PendingAttachment] = []

    public var target: ChatTarget { ChatTarget(connectionId: connectionId, workspaceId: workspaceId, channelId: channelId, threadId: threadId) }
}

public struct FeedPost: Sendable, Equatable, Identifiable {
    public let message: MessageRecord
    public let replyCount: Int
    public let lastReplyAt: String?
    public var id: String { message.id }
}

public struct ChannelSyncState: Sendable, Equatable {
    public let resumeCursor: String?
    public let resumeAfterCreatedAt: String?
    public let resumeAfterId: String?
    public let complete: Bool
    public let syncedAt: String
}

/// `(created_at, id)` position in Tower's message order.
public struct MessageKey: Sendable, Equatable, Comparable {
    public let createdAt: String
    public let id: String
    public init(createdAt: String, id: String) { self.createdAt = createdAt; self.id = id }
    public static func < (a: Self, b: Self) -> Bool { (a.createdAt, a.id) < (b.createdAt, b.id) }
}

enum JSONText {
    static func mentions(_ value: [Mention]) -> String { String(decoding: (try? JSONEncoder().encode(value)) ?? Data("[]".utf8), as: UTF8.self) }
    static func mentions(_ text: String?) -> [Mention] { text.flatMap { try? JSONDecoder().decode([Mention].self, from: Data($0.utf8)) } ?? [] }
    static func attachments(_ value: [PendingAttachment]) -> String { String(decoding: (try? JSONEncoder().encode(value)) ?? Data("[]".utf8), as: UTF8.self) }
    static func attachments(_ text: String?) -> [PendingAttachment] { text.flatMap { try? JSONDecoder().decode([PendingAttachment].self, from: Data($0.utf8)) } ?? [] }
}

/// An image staged on the device for a chat message. Its bytes are already privacy-stripped (see `ImagePrivacy`).
public struct PendingAttachment: Sendable, Equatable, Codable, Hashable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let sha256: String
    /// File name inside the staging directory.
    public let staged: String
    public var objectId: String?
    public var uploadURL: String?
    public var complete: Bool

    public init(id: String = UUID().uuidString.lowercased(), filename: String, mimeType: String, sizeBytes: Int, sha256: String, staged: String,
                objectId: String? = nil, uploadURL: String? = nil, complete: Bool = false) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.sizeBytes = sizeBytes; self.sha256 = sha256; self.staged = staged
        self.objectId = objectId; self.uploadURL = uploadURL; self.complete = complete
    }

    public var wire: MessageAttachment? {
        objectId.map { MessageAttachment(kind: "image", storageObjectId: $0, filename: filename, mimeType: mimeType, sizeBytes: sizeBytes) }
    }
}

extension StoreWriter {
    // MARK: Drafts

    /// Saves (or clears, when empty) the composer state for one target.
    public func saveDraft(_ target: ChatTarget, _ draft: Draft) async throws {
        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.mentions.isEmpty {
            try db.prepare("DELETE FROM drafts WHERE key = ?").run([.text(target.draftKey)])
        } else {
            try db.prepare("""
            INSERT INTO drafts(key, connection_id, workspace_id, channel_id, thread_id, text, mentions, updated_at) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET text = excluded.text, mentions = excluded.mentions, updated_at = excluded.updated_at
            """).run([.text(target.draftKey), .text(target.connectionId), .text(target.workspaceId), .text(target.channelId), target.threadId.sql,
                      .text(draft.text), .text(JSONText.mentions(draft.mentions)), .text(draftStamp())])
        }
        await emit([ChangeKey(.drafts, target.workspaceId)])
    }

    // MARK: Outbox

    /// Moves a composed message into the outbox and clears that target's draft in one transaction:
    /// the text is never held only in memory between the two.
    @discardableResult
    public func enqueueSend(id: String = UUID().uuidString.lowercased(), target: ChatTarget, origin: String, signerNpub: String, appNpub: String,
                            body: String, mentions: [Mention], attachments: [PendingAttachment] = []) async throws -> OutboxItem {
        let stamp = now()
        try db.transaction {
            try db.prepare("""
            INSERT INTO outbox(id, connection_id, origin, signer_npub, workspace_id, app_npub, channel_id, thread_id, create_thread, body, mentions,
                               request, state, attempts, created_at, updated_at, attachments)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,NULL,?,0,?,?,?)
            """).run([.text(id), .text(target.connectionId), .text(origin), .text(signerNpub), .text(target.workspaceId), .text(appNpub),
                      .text(target.channelId), target.threadId.sql, .int(target.threadId == nil ? 1 : 0), .text(body),
                      .text(JSONText.mentions(mentions)), .text(OutboxState.awaitingSignature.rawValue), .text(stamp), .text(stamp),
                      .text(JSONText.attachments(attachments))])
            try db.prepare("DELETE FROM drafts WHERE key = ?").run([.text(target.draftKey)])
        }
        await emit([ChangeKey(.outbox, target.workspaceId), ChangeKey(.drafts, target.workspaceId)])
        return OutboxItem(id: id, connectionId: target.connectionId, origin: origin, signerNpub: signerNpub, workspaceId: target.workspaceId,
                          appNpub: appNpub, channelId: target.channelId, threadId: target.threadId, createThread: target.threadId == nil,
                          body: body, mentions: mentions, request: nil, state: .awaitingSignature, attempts: 0, lastStatus: nil, lastCode: nil,
                          lastError: nil, createdAt: stamp, attachments: attachments)
    }

    /// Records upload progress for an unsigned row's attachments (never after the request is frozen).
    public func updateOutboxAttachments(id: String, _ attachments: [PendingAttachment]) async throws {
        try db.prepare("UPDATE outbox SET attachments = ?, updated_at = ? WHERE id = ? AND request IS NULL")
            .run([.text(JSONText.attachments(attachments)), .text(now()), .text(id)])
    }

    /// Stores the signed request bytes exactly once. A row that is already frozen keeps its original request,
    /// so every retry resends identical bytes under the same client_request_id.
    @discardableResult
    public func freezeOutbox(id: String, request: Data) async throws -> Bool {
        try db.prepare("UPDATE outbox SET request = ?, state = ?, updated_at = ? WHERE id = ? AND request IS NULL")
            .run([.blob(request), .text(OutboxState.queued.rawValue), .text(now()), .text(id)])
        let frozen = db.changes > 0
        if let workspace = try outboxWorkspace(id) { await emit([ChangeKey(.outbox, workspace)]) }
        return frozen
    }

    public func markOutbox(id: String, state: OutboxState, status: Int? = nil, code: String? = nil, error: String? = nil,
                           countAttempt: Bool = false) async throws {
        try db.prepare("""
        UPDATE outbox SET state = ?, last_status = ?, last_code = ?, last_error = ?, attempts = attempts + ?, updated_at = ? WHERE id = ?
        """).run([.text(state.rawValue), status.map { .int(Int64($0)) } ?? .null, code.sql, error.sql, .int(countAttempt ? 1 : 0), .text(now()), .text(id)])
        if let workspace = try outboxWorkspace(id) { await emit([ChangeKey(.outbox, workspace)]) }
    }

    /// Tower accepted (or replayed) the send: store its message and thread and retire the outbox row together.
    public func acknowledgeSend(id: String, message: MessageRecord, thread: ThreadRecord?) async throws {
        var keys: Set<ChangeKey> = [ChangeKey(.outbox, message.workspaceId)]
        try db.transaction {
            _ = try writeMessages([message], keys: &keys)
            if let thread { _ = try writeThreads([thread]); keys.insert(ChangeKey(.threads, thread.workspaceId)) }
            try db.prepare("DELETE FROM outbox WHERE id = ?").run([.text(id)])
        }
        await emit(keys)
    }

    /// User-initiated retry: back to the send queue (or to signing, if never signed).
    public func retryOutbox(id: String) async throws {
        try db.prepare("UPDATE outbox SET state = CASE WHEN request IS NULL THEN ? ELSE ? END, updated_at = ? WHERE id = ? AND state IN (?, ?)")
            .run([.text(OutboxState.awaitingSignature.rawValue), .text(OutboxState.queued.rawValue), .text(now()), .text(id),
                  .text(OutboxState.failed.rawValue), .text(OutboxState.retrying.rawValue)])
        if let workspace = try outboxWorkspace(id) { await emit([ChangeKey(.outbox, workspace)]) }
    }

    /// Removes an unsent message. With `restoreDraft`, its text returns to the composer it came from
    /// (when that composer is empty), so the user can edit and resend it.
    public func discardOutbox(id: String, restoreDraft: Bool) async throws {
        guard let item = try outboxItem(id) else { return }
        guard item.state != .sending else { return }
        try db.transaction {
            if restoreDraft {
                let (text, mentions) = MentionCodec.decode(body: item.body)
                try db.prepare("""
                INSERT INTO drafts(key, connection_id, workspace_id, channel_id, thread_id, text, mentions, updated_at) VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(key) DO NOTHING
                """).run([.text(item.target.draftKey), .text(item.connectionId), .text(item.workspaceId), .text(item.channelId), item.threadId.sql,
                          .text(text), .text(JSONText.mentions(mentions)), .text(draftStamp())])
            }
            try db.prepare("DELETE FROM outbox WHERE id = ?").run([.text(id)])
        }
        await emit([ChangeKey(.outbox, item.workspaceId), ChangeKey(.drafts, item.workspaceId)])
    }

    /// After relaunch nothing is in flight: a send interrupted mid-request is queued again (idempotent replay).
    public func resetInterruptedSends() async throws {
        try db.prepare("UPDATE outbox SET state = ? WHERE state = ?").run([.text(OutboxState.queued.rawValue), .text(OutboxState.sending.rawValue)])
        if db.changes > 0 { await emit([ChangeKey(.outbox)]) }
    }

    private func outboxWorkspace(_ id: String) throws -> String? {
        let s = try db.prepare("SELECT workspace_id FROM outbox WHERE id = ?")
        try s.bind([.text(id)])
        return try s.step() ? s.text(0) : nil
    }

    func outboxItem(_ id: String) throws -> OutboxItem? {
        let s = try db.prepare("SELECT \(StoreReader.outboxColumns) FROM outbox WHERE id = ?")
        try s.bind([.text(id)])
        return try s.step() ? StoreReader.outbox(s) : nil
    }

    // MARK: Threads, members, catch-up

    func writeThreads(_ records: [ThreadRecord]) throws -> Int {
        var changed = 0
        let s = try db.prepare("""
        INSERT INTO threads(workspace_id, id, channel_id, source_message_id, title, latest, archived, deleted, row_version, updated_at, raw)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(workspace_id, id) DO UPDATE SET channel_id=excluded.channel_id, source_message_id=excluded.source_message_id,
          title=excluded.title, latest=excluded.latest, archived=excluded.archived, deleted=excluded.deleted,
          row_version=excluded.row_version, updated_at=excluded.updated_at, raw=excluded.raw
        \(newerGuard("threads"))
        """)
        for r in records {
            try s.run([.text(r.workspaceId), .text(r.id), .text(r.channelId), r.sourceMessageId.sql, r.title.sql, r.latest.sql,
                       .int(r.archived ? 1 : 0), .int(r.deleted ? 1 : 0), .int(Int64(r.rowVersion)), .text(r.updatedAt), .blob(r.raw)])
            changed += db.changes
        }
        return changed
    }

    @discardableResult
    public func upsertThreads(workspaceId: String, _ records: [ThreadRecord]) async throws -> Int {
        let changed = try db.transaction { try writeThreads(records.filter { $0.workspaceId == workspaceId }) }
        if changed > 0 { await emit([ChangeKey(.threads, workspaceId)]) }
        return changed
    }

    /// The directory is small and authoritative: replace it whole.
    public func replaceMembers(workspaceId: String, _ records: [MemberRecord]) async throws {
        try db.transaction {
            try db.prepare("DELETE FROM members WHERE workspace_id = ?").run([.text(workspaceId)])
            let s = try db.prepare("INSERT OR REPLACE INTO members(workspace_id, npub, actor_id, kind, display_name) VALUES(?,?,?,?,?)")
            for r in records where r.workspaceId == workspaceId {
                try s.run([.text(workspaceId), .text(r.npub), .text(r.actorId), r.kind.sql, r.displayName.sql])
            }
        }
        await emit([ChangeKey(.members, workspaceId)])
    }

    /// Removes local messages Tower no longer lists, but only inside the range a completed catch-up actually covered:
    /// strictly after `after` (or from the start) and no later than `through`. Rows outside it are untouched, so a
    /// message acknowledged while the catch-up was paging is never removed.
    @discardableResult
    public func reconcileMessages(workspaceId: String, channelId: String, threadId: String?, after: MessageKey?, through: MessageKey,
                                  keep: Set<String>) async throws -> Int {
        let removed: Int = try db.transaction {
            let s = try db.prepare("""
            SELECT id, created_at FROM messages WHERE workspace_id = ? AND channel_id = ? AND (? IS NULL OR thread_id = ?)
              AND (created_at > ? OR (created_at = ? AND id > ?)) AND (created_at < ? OR (created_at = ? AND id <= ?))
            """)
            let start = after ?? MessageKey(createdAt: "", id: "")
            try s.bind([.text(workspaceId), .text(channelId), threadId.sql, threadId.sql, .text(start.createdAt), .text(start.createdAt), .text(start.id),
                        .text(through.createdAt), .text(through.createdAt), .text(through.id)])
            var gone: [String] = []
            while try s.step() { if let id = s.text(0), !keep.contains(id) { gone.append(id) } }
            let delete = try db.prepare("DELETE FROM messages WHERE workspace_id = ? AND id = ?")
            for id in gone { try delete.run([.text(workspaceId), .text(id)]) }
            return gone.count
        }
        if removed > 0 { await emit([ChangeKey(.messages, workspaceId)]) }
        return removed
    }

    public func saveChannelSync(workspaceId: String, channelId: String, resumeCursor: String?, resumeAfter: MessageKey?, complete: Bool) async throws {
        try db.prepare("""
        INSERT INTO channel_sync(workspace_id, channel_id, resume_cursor, resume_after_created_at, resume_after_id, complete, synced_at)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(workspace_id, channel_id) DO UPDATE SET resume_cursor = excluded.resume_cursor,
          resume_after_created_at = excluded.resume_after_created_at, resume_after_id = excluded.resume_after_id,
          complete = MAX(channel_sync.complete, excluded.complete), synced_at = excluded.synced_at
        """).run([.text(workspaceId), .text(channelId), resumeCursor.sql, (resumeAfter?.createdAt).sql, (resumeAfter?.id).sql,
                  .int(complete ? 1 : 0), .text(now())])
        await emit([ChangeKey(.messages, workspaceId)])
    }
}

extension StoreReader {
    static let messageColumns = "id, channel_id, thread_id, thread_source_id, body, sender_npub, sender_label, client_request_id, created_at, updated_at, row_version, deleted, raw"

    static func message(_ s: SQLiteConnection.Statement, workspaceId: String, offset: Int32 = 0) -> MessageRecord {
        MessageRecord(workspaceId: workspaceId, id: s.text(offset)!, channelId: s.text(offset + 1)!, threadId: s.text(offset + 2),
                      threadSourceId: s.text(offset + 3), body: s.text(offset + 4) ?? "", senderNpub: s.text(offset + 5),
                      senderLabel: s.text(offset + 6), clientRequestId: s.text(offset + 7), createdAt: s.text(offset + 8)!,
                      updatedAt: s.text(offset + 9), rowVersion: Int(s.int(offset + 10)), deleted: s.int(offset + 11) != 0, raw: s.blob(offset + 12))
    }

    static let outboxColumns = """
    id, connection_id, origin, signer_npub, workspace_id, app_npub, channel_id, thread_id, create_thread, body, mentions, request, state, attempts,
    last_status, last_code, last_error, created_at, attachments
    """

    static func outbox(_ s: SQLiteConnection.Statement) -> OutboxItem {
        OutboxItem(id: s.text(0)!, connectionId: s.text(1)!, origin: s.text(2)!, signerNpub: s.text(3)!, workspaceId: s.text(4)!, appNpub: s.text(5)!,
                   channelId: s.text(6)!, threadId: s.text(7), createThread: s.int(8) != 0, body: s.text(9)!, mentions: JSONText.mentions(s.text(10)),
                   request: s.isNull(11) ? nil : s.blob(11), state: OutboxState(rawValue: s.text(12) ?? "") ?? .failed, attempts: Int(s.int(13)),
                   lastStatus: s.isNull(14) ? nil : Int(s.int(14)), lastCode: s.text(15), lastError: s.text(16), createdAt: s.text(17)!,
                   attachments: JSONText.attachments(s.text(18)))
    }

    /// Newest `limit` channel-level posts (thread roots), oldest first, each with its reply count.
    public func channelFeed(workspaceId: String, channelId: String, limit: Int) throws -> [FeedPost] {
        let s = try db.prepare("""
        SELECT \(Self.messageColumns.split(separator: ",").map { "m." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")),
          (SELECT COUNT(*) FROM messages r WHERE r.workspace_id = m.workspace_id AND r.thread_id = m.thread_id AND r.id <> m.id AND r.deleted = 0),
          (SELECT MAX(r.created_at) FROM messages r WHERE r.workspace_id = m.workspace_id AND r.thread_id = m.thread_id AND r.id <> m.id AND r.deleted = 0)
        FROM messages m
        WHERE m.workspace_id = ? AND m.channel_id = ? AND m.deleted = 0 AND (m.thread_id IS NULL OR m.thread_source_id = m.id)
        ORDER BY m.created_at DESC, m.id DESC LIMIT ?
        """)
        try s.bind([.text(workspaceId), .text(channelId), .int(Int64(limit))])
        var rows: [FeedPost] = []
        while try s.step() {
            rows.append(FeedPost(message: Self.message(s, workspaceId: workspaceId), replyCount: Int(s.int(13)), lastReplyAt: s.text(14)))
        }
        return rows.reversed()
    }

    /// Messages of one thread (root first), newest `limit`, oldest first.
    public func threadMessages(workspaceId: String, threadId: String, limit: Int) throws -> [MessageRecord] {
        let s = try db.prepare("""
        SELECT \(Self.messageColumns) FROM messages WHERE workspace_id = ? AND thread_id = ? AND deleted = 0
        ORDER BY created_at DESC, id DESC LIMIT ?
        """)
        try s.bind([.text(workspaceId), .text(threadId), .int(Int64(limit))])
        var rows: [MessageRecord] = []
        while try s.step() { rows.append(Self.message(s, workspaceId: workspaceId)) }
        return rows.reversed()
    }

    public func message(workspaceId: String, id: String) throws -> MessageRecord? {
        let s = try db.prepare("SELECT \(Self.messageColumns) FROM messages WHERE workspace_id = ? AND id = ?")
        try s.bind([.text(workspaceId), .text(id)])
        return try s.step() ? Self.message(s, workspaceId: workspaceId) : nil
    }

    public func thread(workspaceId: String, id: String) throws -> ThreadRecord? {
        let s = try db.prepare("""
        SELECT id, channel_id, source_message_id, title, latest, archived, deleted, row_version, updated_at, raw FROM threads WHERE workspace_id = ? AND id = ?
        """)
        try s.bind([.text(workspaceId), .text(id)])
        guard try s.step() else { return nil }
        return ThreadRecord(workspaceId: workspaceId, id: s.text(0)!, channelId: s.text(1)!, sourceMessageId: s.text(2), title: s.text(3),
                            latest: s.text(4), archived: s.int(5) != 0, deleted: s.int(6) != 0, rowVersion: Int(s.int(7)),
                            updatedAt: s.text(8)!, raw: s.blob(9))
    }

    public func channel(workspaceId: String, id: String) throws -> ChannelRecord? {
        try channels(workspaceId: workspaceId).first { $0.id == id }
    }

    /// Unsent messages shown inline in one conversation: the channel level (new posts) or one thread (replies).
    public func outbox(target: ChatTarget) throws -> [OutboxItem] {
        let s = try db.prepare("""
        SELECT \(Self.outboxColumns) FROM outbox
        WHERE connection_id = ? AND workspace_id = ? AND channel_id = ? AND ((? IS NULL AND thread_id IS NULL) OR thread_id = ?)
        ORDER BY created_at, rowid
        """)
        try s.bind([.text(target.connectionId), .text(target.workspaceId), .text(target.channelId), target.threadId.sql, target.threadId.sql])
        var rows: [OutboxItem] = []
        while try s.step() { rows.append(Self.outbox(s)) }
        return rows
    }

    /// Every unsent row for one connection and signer, in creation order (the sender's work list).
    public func outbox(connectionId: String, signerNpub: String) throws -> [OutboxItem] {
        let s = try db.prepare("SELECT \(Self.outboxColumns) FROM outbox WHERE connection_id = ? AND signer_npub = ? ORDER BY created_at, rowid")
        try s.bind([.text(connectionId), .text(signerNpub)])
        var rows: [OutboxItem] = []
        while try s.step() { rows.append(Self.outbox(s)) }
        return rows
    }

    public func outboxItem(id: String) throws -> OutboxItem? {
        let s = try db.prepare("SELECT \(Self.outboxColumns) FROM outbox WHERE id = ?")
        try s.bind([.text(id)])
        return try s.step() ? Self.outbox(s) : nil
    }

    public func outboxCount(connectionId: String) throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM outbox WHERE connection_id = ?")
        try s.bind([.text(connectionId)])
        return try s.step() ? Int(s.int(0)) : 0
    }

    public func draft(_ target: ChatTarget) throws -> Draft? {
        let s = try db.prepare("SELECT text, mentions, updated_at FROM drafts WHERE key = ?")
        try s.bind([.text(target.draftKey)])
        guard try s.step() else { return nil }
        let stamp = s.text(2)
        return Draft(text: s.text(0) ?? "", mentions: JSONText.mentions(s.text(1)),
                     updatedAt: stamp.flatMap { ISO8601DateFormatter.tower.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) })
    }

    public func members(workspaceId: String) throws -> [MemberRecord] {
        let s = try db.prepare("SELECT npub, actor_id, kind, display_name FROM members WHERE workspace_id = ? ORDER BY display_name COLLATE NOCASE, npub")
        try s.bind([.text(workspaceId)])
        var rows: [MemberRecord] = []
        while try s.step() { rows.append(MemberRecord(workspaceId: workspaceId, actorId: s.text(1)!, npub: s.text(0)!, kind: s.text(2), displayName: s.text(3))) }
        return rows
    }

    public func channelSync(workspaceId: String, channelId: String) throws -> ChannelSyncState? {
        let s = try db.prepare("""
        SELECT resume_cursor, resume_after_created_at, resume_after_id, complete, synced_at FROM channel_sync WHERE workspace_id = ? AND channel_id = ?
        """)
        try s.bind([.text(workspaceId), .text(channelId)])
        guard try s.step() else { return nil }
        return ChannelSyncState(resumeCursor: s.text(0), resumeAfterCreatedAt: s.text(1), resumeAfterId: s.text(2), complete: s.int(3) != 0,
                                syncedAt: s.text(4) ?? "")
    }
}
