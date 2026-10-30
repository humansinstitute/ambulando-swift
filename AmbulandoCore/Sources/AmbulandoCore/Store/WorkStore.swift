import Foundation

// Local tables for tasks, documents, files, inbox view states, reactions, the write queue and search (schema v3).

extension Schema {
    /// Workspace-scoped v3 tables, cleared with the workspace.
    static let v3WorkspaceTables = ["tasks", "comments", "docs", "doc_bodies", "files", "folders", "view_states", "reactions", "list_sync"]

    static func migrateV3(_ db: SQLiteConnection) throws {
        try db.execute("""
        CREATE TABLE tasks(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, scope_id TEXT, channel_id TEXT NOT NULL, title TEXT NOT NULL, description TEXT,
          state TEXT NOT NULL, priority TEXT NOT NULL, assigned_to_npub TEXT, created_by_npub TEXT,
          row_version INTEGER NOT NULL, activity_version INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX tasks_channel ON tasks(workspace_id, channel_id);
        CREATE INDEX tasks_scope_state ON tasks(workspace_id, scope_id, state, updated_at);
        CREATE TABLE comments(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, parent TEXT NOT NULL, parent_id TEXT NOT NULL, parent_comment_id TEXT,
          body TEXT NOT NULL, sender_npub TEXT, status TEXT, deleted INTEGER NOT NULL DEFAULT 0, client_record_id TEXT,
          row_version INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX comments_parent ON comments(workspace_id, parent, parent_id, created_at, id);
        CREATE TABLE docs(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, scope_id TEXT, channel_id TEXT NOT NULL, storage_object_id TEXT,
          title TEXT NOT NULL, summary TEXT, archived INTEGER NOT NULL DEFAULT 0, body_text TEXT,
          row_version INTEGER NOT NULL, activity_version INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX docs_channel ON docs(workspace_id, channel_id);
        CREATE TABLE doc_bodies(
          workspace_id TEXT NOT NULL, doc_id TEXT NOT NULL, storage_object_id TEXT NOT NULL, sha256 TEXT NOT NULL, content_type TEXT NOT NULL,
          doc_row_version INTEGER NOT NULL, bytes BLOB NOT NULL, fetched_at TEXT NOT NULL,
          PRIMARY KEY(workspace_id, doc_id));
        CREATE TABLE doc_drafts(
          key TEXT PRIMARY KEY,
          connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
          workspace_id TEXT NOT NULL, doc_id TEXT NOT NULL, title TEXT NOT NULL, body BLOB NOT NULL, content_type TEXT NOT NULL,
          base_row_version INTEGER NOT NULL, base_sha256 TEXT NOT NULL, base_storage_object_id TEXT NOT NULL,
          state TEXT NOT NULL, last_error TEXT, recovery_id TEXT, updated_at TEXT NOT NULL);
        CREATE TABLE files(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, scope_id TEXT, channel_id TEXT NOT NULL, folder_id TEXT, storage_object_id TEXT,
          display_name TEXT NOT NULL, description TEXT, content_type TEXT, size_bytes INTEGER, sha256 TEXT, archived INTEGER NOT NULL DEFAULT 0,
          row_version INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX files_channel ON files(workspace_id, channel_id, folder_id);
        CREATE TABLE folders(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, channel_id TEXT NOT NULL, parent_folder_id TEXT, title TEXT NOT NULL,
          deleted INTEGER NOT NULL DEFAULT 0, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE TABLE view_states(
          workspace_id TEXT NOT NULL, resource_type TEXT NOT NULL, resource_id TEXT NOT NULL, scope_id TEXT, channel_id TEXT,
          activity_version INTEGER NOT NULL, viewed_activity_version INTEGER NOT NULL, attention_activity_version INTEGER,
          row_version INTEGER NOT NULL, updated_at TEXT NOT NULL,
          PRIMARY KEY(workspace_id, resource_type, resource_id));
        CREATE TABLE reactions(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, target_type TEXT NOT NULL, target_id TEXT NOT NULL, emoji TEXT NOT NULL,
          reactor_npub TEXT, deleted INTEGER NOT NULL DEFAULT 0, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX reactions_target ON reactions(workspace_id, target_type, target_id);
        CREATE TABLE list_sync(workspace_id TEXT NOT NULL, key TEXT NOT NULL, complete INTEGER NOT NULL, synced_at TEXT NOT NULL,
          PRIMARY KEY(workspace_id, key));
        CREATE TABLE writes(
          id TEXT PRIMARY KEY,
          connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
          origin TEXT NOT NULL, signer_npub TEXT NOT NULL, workspace_id TEXT NOT NULL, app_npub TEXT NOT NULL,
          kind TEXT NOT NULL, target_id TEXT, group_key TEXT NOT NULL, payload BLOB NOT NULL, request BLOB,
          state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_status INTEGER, last_code TEXT, last_error TEXT,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
        CREATE INDEX writes_target ON writes(workspace_id, target_id);
        ALTER TABLE outbox ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]';
        """)
        try SearchIndex.install(db)
    }
}

/// Local full-text search (SQLite FTS5, maintained by triggers inside the writer's transactions). If this SQLite
/// build has no FTS5, a bounded `LIKE` scan over the same tables is used instead.
enum SearchIndex {
    static func install(_ db: SQLiteConnection) throws {
        do {
            try db.execute("CREATE VIRTUAL TABLE search_index USING fts5(workspace_id UNINDEXED, kind UNINDEXED, record_id UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2')")
        } catch {
            return   // no FTS5: LIKE fallback
        }
        try db.execute("""
        CREATE TRIGGER search_messages_ai AFTER INSERT ON messages WHEN new.deleted = 0 BEGIN
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) VALUES(new.workspace_id, 'message', new.id, '', new.body); END;
        CREATE TRIGGER search_messages_au AFTER UPDATE OF body, deleted ON messages BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'message' AND record_id = old.id;
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) SELECT new.workspace_id, 'message', new.id, '', new.body WHERE new.deleted = 0; END;
        CREATE TRIGGER search_messages_ad AFTER DELETE ON messages BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'message' AND record_id = old.id; END;
        CREATE TRIGGER search_tasks_ai AFTER INSERT ON tasks BEGIN
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) VALUES(new.workspace_id, 'task', new.id, new.title, coalesce(new.description, '')); END;
        CREATE TRIGGER search_tasks_au AFTER UPDATE OF title, description ON tasks BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'task' AND record_id = old.id;
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) VALUES(new.workspace_id, 'task', new.id, new.title, coalesce(new.description, '')); END;
        CREATE TRIGGER search_tasks_ad AFTER DELETE ON tasks BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'task' AND record_id = old.id; END;
        CREATE TRIGGER search_docs_ai AFTER INSERT ON docs BEGIN
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) VALUES(new.workspace_id, 'doc', new.id, new.title, coalesce(new.body_text, new.summary, '')); END;
        CREATE TRIGGER search_docs_au AFTER UPDATE OF title, summary, body_text ON docs BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'doc' AND record_id = old.id;
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) VALUES(new.workspace_id, 'doc', new.id, new.title, coalesce(new.body_text, new.summary, '')); END;
        CREATE TRIGGER search_docs_ad AFTER DELETE ON docs BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'doc' AND record_id = old.id; END;
        CREATE TRIGGER search_files_ai AFTER INSERT ON files BEGIN
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) VALUES(new.workspace_id, 'file', new.id, new.display_name, coalesce(new.description, '')); END;
        CREATE TRIGGER search_files_au AFTER UPDATE OF display_name, description ON files BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'file' AND record_id = old.id;
          INSERT INTO search_index(workspace_id, kind, record_id, title, body) VALUES(new.workspace_id, 'file', new.id, new.display_name, coalesce(new.description, '')); END;
        CREATE TRIGGER search_files_ad AFTER DELETE ON files BEGIN
          DELETE FROM search_index WHERE workspace_id = old.workspace_id AND kind = 'file' AND record_id = old.id; END;
        INSERT INTO search_index(workspace_id, kind, record_id, title, body) SELECT workspace_id, 'message', id, '', body FROM messages WHERE deleted = 0;
        """)
    }

    /// FTS5 query from user text: each word is a quoted prefix term, so punctuation cannot inject syntax.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }.prefix(8)
        guard !words.isEmpty else { return nil }
        return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }.joined(separator: " ")
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case message, task, doc, file }
    public let kind: Kind
    public let recordId: String
    public let title: String
    public let snippet: String
    public let channelId: String?
    /// Thread of a message hit (for navigation).
    public let threadId: String?
    public var id: String { "\(kind.rawValue):\(recordId)" }
}

extension StoreWriter {
    // MARK: Tasks

    func writeTasks(_ records: [TaskRecord]) throws -> Int {
        var changed = 0
        let s = try db.prepare("""
        INSERT INTO tasks(workspace_id, id, scope_id, channel_id, title, description, state, priority, assigned_to_npub, created_by_npub,
                          row_version, activity_version, created_at, updated_at, raw) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(workspace_id, id) DO UPDATE SET scope_id=excluded.scope_id, channel_id=excluded.channel_id, title=excluded.title,
          description=excluded.description, state=excluded.state, priority=excluded.priority, assigned_to_npub=excluded.assigned_to_npub,
          created_by_npub=excluded.created_by_npub, row_version=excluded.row_version, activity_version=excluded.activity_version,
          updated_at=excluded.updated_at, raw=excluded.raw
        \(newerGuard("tasks"))
        """)
        for r in records {
            try s.run([.text(r.workspaceId), .text(r.id), r.scopeId.sql, .text(r.channelId), .text(r.title), r.description.sql, .text(r.state),
                       .text(r.priority), r.assignedToNpub.sql, r.createdByNpub.sql, .int(Int64(r.rowVersion)), .int(Int64(r.activityVersion)),
                       .text(r.createdAt), .text(r.updatedAt), .blob(r.raw)])
            let wrote = db.changes
            changed += wrote
            if wrote > 0 { try noteTaskRelationship(r) }
        }
        return changed
    }

    /// Upserts tasks. With `completeChannel`, tasks of that channel Tower no longer lists are removed.
    @discardableResult
    public func upsertTasks(workspaceId: String, _ records: [TaskRecord], completeChannel: String? = nil) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction {
            var changed = try writeTasks(rows)
            if let channel = completeChannel {
                changed += try removeMissing(table: "tasks", workspaceId: workspaceId, column: "channel_id", value: channel, keep: Set(rows.map(\.id)))
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.tasks, workspaceId)]) }
        return changed
    }

    func removeMissing(table: String, workspaceId: String, column: String, value: String, keep: Set<String>) throws -> Int {
        let s = try db.prepare("SELECT id FROM \(table) WHERE workspace_id = ? AND \(column) = ?")
        try s.bind([.text(workspaceId), .text(value)])
        var gone: [String] = []
        while try s.step() { if let id = s.text(0), !keep.contains(id) { gone.append(id) } }
        let delete = try db.prepare("DELETE FROM \(table) WHERE workspace_id = ? AND id = ?")
        for id in gone { try delete.run([.text(workspaceId), .text(id)]) }
        return gone.count
    }

    // MARK: Comments

    @discardableResult
    public func upsertComments(workspaceId: String, _ records: [CommentRecord], complete parent: (CommentRecord.Parent, String)? = nil) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction {
            var changed = 0
            let s = try db.prepare("""
            INSERT INTO comments(workspace_id, id, parent, parent_id, parent_comment_id, body, sender_npub, status, deleted, client_record_id,
                                 row_version, created_at, updated_at, raw) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id, id) DO UPDATE SET body=excluded.body, sender_npub=COALESCE(excluded.sender_npub, comments.sender_npub), status=excluded.status, deleted=excluded.deleted,
              parent_comment_id=excluded.parent_comment_id, client_record_id=excluded.client_record_id,
              row_version=excluded.row_version, updated_at=excluded.updated_at, raw=excluded.raw
            \(newerGuard("comments"))
            """)
            for r in rows {
                try s.run([.text(workspaceId), .text(r.id), .text(r.parent.rawValue), .text(r.parentId), r.parentCommentId.sql, .text(r.body),
                           r.senderNpub.sql, r.status.sql, .int(r.deleted ? 1 : 0), r.clientRecordId.sql, .int(Int64(r.rowVersion)),
                           .text(r.createdAt), .text(r.updatedAt), .blob(r.raw)])
                changed += db.changes
            }
            if let (kind, id) = parent {
                let keep = Set(rows.filter { $0.parent == kind && $0.parentId == id }.map(\.id))
                let q = try db.prepare("SELECT id FROM comments WHERE workspace_id = ? AND parent = ? AND parent_id = ?")
                try q.bind([.text(workspaceId), .text(kind.rawValue), .text(id)])
                var gone: [String] = []
                while try q.step() { if let c = q.text(0), !keep.contains(c) { gone.append(c) } }
                for c in gone { try db.prepare("DELETE FROM comments WHERE workspace_id = ? AND id = ?").run([.text(workspaceId), .text(c)]); changed += 1 }
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.comments, workspaceId)]) }
        return changed
    }

    // MARK: Documents

    func writeDocs(_ records: [DocRecord]) throws -> Int {
        var changed = 0
        let s = try db.prepare("""
        INSERT INTO docs(workspace_id, id, scope_id, channel_id, storage_object_id, title, summary, archived, row_version, activity_version,
                         created_at, updated_at, raw) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(workspace_id, id) DO UPDATE SET scope_id=excluded.scope_id, channel_id=excluded.channel_id,
          storage_object_id=excluded.storage_object_id, title=excluded.title, summary=excluded.summary, archived=excluded.archived,
          row_version=excluded.row_version, activity_version=excluded.activity_version, updated_at=excluded.updated_at, raw=excluded.raw
        \(newerGuard("docs"))
        """)
        for r in records {
            try s.run([.text(r.workspaceId), .text(r.id), r.scopeId.sql, .text(r.channelId), r.storageObjectId.sql, .text(r.title), r.summary.sql,
                       .int(r.archived ? 1 : 0), .int(Int64(r.rowVersion)), .int(Int64(r.activityVersion)), .text(r.createdAt), .text(r.updatedAt),
                       .blob(r.raw)])
            changed += db.changes
        }
        return changed
    }

    @discardableResult
    public func upsertDocs(workspaceId: String, _ records: [DocRecord], completeChannel: String? = nil) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction {
            var changed = try writeDocs(rows)
            if let channel = completeChannel {
                changed += try removeMissing(table: "docs", workspaceId: workspaceId, column: "channel_id", value: channel, keep: Set(rows.map(\.id)))
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.docs, workspaceId)]) }
        return changed
    }

    /// Stores a verified body together with the document row it was read with, and indexes its text for search.
    public func saveDocBody(_ body: DocBodyRecord, doc: DocRecord?, searchText: String) async throws {
        try db.transaction {
            if let doc { _ = try writeDocs([doc]) }
            try db.prepare("""
            INSERT INTO doc_bodies(workspace_id, doc_id, storage_object_id, sha256, content_type, doc_row_version, bytes, fetched_at)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id, doc_id) DO UPDATE SET storage_object_id=excluded.storage_object_id, sha256=excluded.sha256,
              content_type=excluded.content_type, doc_row_version=excluded.doc_row_version, bytes=excluded.bytes, fetched_at=excluded.fetched_at
            WHERE excluded.doc_row_version >= doc_bodies.doc_row_version
            """).run([.text(body.workspaceId), .text(body.docId), .text(body.storageObjectId), .text(body.sha256), .text(body.contentType),
                      .int(Int64(body.docRowVersion)), .blob(body.bytes), .text(body.fetchedAt)])
            try db.prepare("UPDATE docs SET body_text = ? WHERE workspace_id = ? AND id = ? AND storage_object_id IS ?")
                .run([.text(String(searchText.prefix(20_000))), .text(body.workspaceId), .text(body.docId), .text(body.storageObjectId)])
        }
        await emit([ChangeKey(.docBodies, body.workspaceId), ChangeKey(.docs, body.workspaceId)])
    }

    // MARK: Document drafts

    public func saveDocDraft(_ draft: DocDraft) async throws {
        try db.prepare("""
        INSERT INTO doc_drafts(key, connection_id, workspace_id, doc_id, title, body, content_type, base_row_version, base_sha256,
                               base_storage_object_id, state, last_error, recovery_id, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET title=excluded.title, body=excluded.body, content_type=excluded.content_type,
          base_row_version=excluded.base_row_version, base_sha256=excluded.base_sha256, base_storage_object_id=excluded.base_storage_object_id,
          state=excluded.state, last_error=excluded.last_error, recovery_id=excluded.recovery_id, updated_at=excluded.updated_at
        """).run([.text(draft.key), .text(draft.connectionId), .text(draft.workspaceId), .text(draft.docId), .text(draft.title), .blob(draft.body),
                  .text(draft.contentType), .int(Int64(draft.baseRowVersion)), .text(draft.baseSha256), .text(draft.baseStorageObjectId),
                  .text(draft.state.rawValue), draft.lastError.sql, draft.recoveryId.sql, .text(now())])
        await emit([ChangeKey(.docDrafts, draft.workspaceId)])
    }

    /// Replaces a draft only if it is still exactly `expected` (same body, base and state), in one statement, so a later edit
    /// made while a caller was awaiting the network is never overwritten by an older snapshot. False: it changed; nothing written.
    @discardableResult
    public func replaceDocDraft(ifUnchanged expected: DocDraft, with next: DocDraft) async throws -> Bool {
        try db.prepare("""
        UPDATE doc_drafts SET title = ?, body = ?, content_type = ?, base_row_version = ?, base_sha256 = ?, base_storage_object_id = ?, state = ?,
          last_error = ?, recovery_id = ?, updated_at = ?
        WHERE key = ? AND body = ? AND base_row_version = ? AND base_sha256 = ? AND state = ? AND title = ? AND content_type = ? AND base_storage_object_id = ?
        """).run([.text(next.title), .blob(next.body), .text(next.contentType), .int(Int64(next.baseRowVersion)), .text(next.baseSha256),
                  .text(next.baseStorageObjectId), .text(next.state.rawValue), next.lastError.sql, next.recoveryId.sql, .text(now()),
                  .text(expected.key), .blob(expected.body), .int(Int64(expected.baseRowVersion)), .text(expected.baseSha256),
                  .text(expected.state.rawValue), .text(expected.title), .text(expected.contentType), .text(expected.baseStorageObjectId)])
        let changed = db.changes > 0
        if changed { await emit([ChangeKey(.docDrafts, next.workspaceId)]) }
        return changed
    }

    /// Removes only the recovery snapshot the user deliberately replaced with the remote document.
    @discardableResult
    public func deleteDocDraft(ifUnchanged expected: DocDraft) async throws -> Bool {
        try db.prepare("""
        DELETE FROM doc_drafts WHERE key = ? AND body = ? AND title = ? AND content_type = ?
          AND base_row_version = ? AND base_sha256 = ? AND base_storage_object_id = ? AND state = ?
        """).run([.text(expected.key), .blob(expected.body), .text(expected.title), .text(expected.contentType),
                  .int(Int64(expected.baseRowVersion)), .text(expected.baseSha256), .text(expected.baseStorageObjectId), .text(expected.state.rawValue)])
        let changed = db.changes > 0
        if changed { await emit([ChangeKey(.docDrafts, expected.workspaceId)]) }
        return changed
    }

    /// Completes only the submitted snapshot. Typing persisted during the request keeps its body/title and advances
    /// to the accepted base, so its next save cannot conflict with this device's own successful checkpoint.
    public func finishDocDraftSave(_ submitted: DocDraft, saved: DocBodyRecord) async throws {
        try db.prepare("""
        DELETE FROM doc_drafts WHERE key = ? AND body = ? AND title = ? AND content_type = ?
          AND base_row_version = ? AND base_sha256 = ? AND base_storage_object_id = ? AND state = ?
        """).run([.text(submitted.key), .blob(submitted.body), .text(submitted.title), .text(submitted.contentType),
                  .int(Int64(submitted.baseRowVersion)), .text(submitted.baseSha256), .text(submitted.baseStorageObjectId), .text(submitted.state.rawValue)])
        try db.prepare("""
        UPDATE doc_drafts SET base_row_version = ?, base_sha256 = ?, base_storage_object_id = ?, updated_at = ?
        WHERE key = ? AND base_row_version = ? AND base_sha256 = ? AND base_storage_object_id = ?
        """).run([.int(Int64(saved.docRowVersion)), .text(saved.sha256), .text(saved.storageObjectId), .text(now()),
                  .text(submitted.key), .int(Int64(submitted.baseRowVersion)), .text(submitted.baseSha256), .text(submitted.baseStorageObjectId)])
        await emit([ChangeKey(.docDrafts, submitted.workspaceId)])
    }

    /// Moves a draft's base to a new row version only while it is still based on `from` (a document move changes the row
    /// version, not the text). The body is never touched. False: no such draft, or it is based on another version.
    @discardableResult
    public func rebaseDocDraft(key: String, workspaceId: String, from: Int, to: Int) async throws -> Bool {
        try db.prepare("UPDATE doc_drafts SET base_row_version = ?, updated_at = ? WHERE key = ? AND base_row_version = ?")
            .run([.int(Int64(to)), .text(now()), .text(key), .int(Int64(from))])
        let changed = db.changes > 0
        if changed { await emit([ChangeKey(.docDrafts, workspaceId)]) }
        return changed
    }

    /// Stores a draft only if none exists yet (a clean document's first draft). False: another draft appeared first.
    @discardableResult
    public func insertDocDraftIfAbsent(_ draft: DocDraft) async throws -> Bool {
        try db.prepare("""
        INSERT INTO doc_drafts(key, connection_id, workspace_id, doc_id, title, body, content_type, base_row_version, base_sha256,
                               base_storage_object_id, state, last_error, recovery_id, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(key) DO NOTHING
        """).run([.text(draft.key), .text(draft.connectionId), .text(draft.workspaceId), .text(draft.docId), .text(draft.title), .blob(draft.body),
                  .text(draft.contentType), .int(Int64(draft.baseRowVersion)), .text(draft.baseSha256), .text(draft.baseStorageObjectId),
                  .text(draft.state.rawValue), draft.lastError.sql, draft.recoveryId.sql, .text(now())])
        let changed = db.changes > 0
        if changed { await emit([ChangeKey(.docDrafts, draft.workspaceId)]) }
        return changed
    }

    public func deleteDocDraft(key: String, workspaceId: String) async throws {
        try db.prepare("DELETE FROM doc_drafts WHERE key = ?").run([.text(key)])
        await emit([ChangeKey(.docDrafts, workspaceId)])
    }

    // MARK: Files

    @discardableResult
    public func upsertFiles(workspaceId: String, _ records: [FileRecord], completeChannel: String? = nil) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction {
            var changed = 0
            let s = try db.prepare("""
            INSERT INTO files(workspace_id, id, scope_id, channel_id, folder_id, storage_object_id, display_name, description, content_type,
                              size_bytes, sha256, archived, row_version, created_at, updated_at, raw) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id, id) DO UPDATE SET scope_id=excluded.scope_id, channel_id=excluded.channel_id, folder_id=excluded.folder_id,
              storage_object_id=excluded.storage_object_id, display_name=excluded.display_name, description=excluded.description,
              content_type=excluded.content_type, size_bytes=excluded.size_bytes, sha256=excluded.sha256, archived=excluded.archived,
              row_version=excluded.row_version, updated_at=excluded.updated_at, raw=excluded.raw
            \(newerGuard("files"))
            """)
            for r in rows {
                try s.run([.text(workspaceId), .text(r.id), r.scopeId.sql, .text(r.channelId), r.folderId.sql, r.storageObjectId.sql, .text(r.displayName),
                           r.description.sql, r.contentType.sql, r.sizeBytes.map { .int(Int64($0)) } ?? .null, r.sha256.sql, .int(r.archived ? 1 : 0),
                           .int(Int64(r.rowVersion)), .text(r.createdAt), .text(r.updatedAt), .blob(r.raw)])
                changed += db.changes
            }
            if let channel = completeChannel {
                changed += try removeMissing(table: "files", workspaceId: workspaceId, column: "channel_id", value: channel, keep: Set(rows.map(\.id)))
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.files, workspaceId)]) }
        return changed
    }

    @discardableResult
    public func upsertFolders(workspaceId: String, channelId: String, _ records: [FolderRecord], complete: Bool) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId && $0.channelId == channelId }
        let changed: Int = try db.transaction {
            var changed = 0
            let s = try db.prepare("""
            INSERT INTO folders(workspace_id, id, channel_id, parent_folder_id, title, deleted, row_version, updated_at, raw) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id, id) DO UPDATE SET channel_id=excluded.channel_id, parent_folder_id=excluded.parent_folder_id, title=excluded.title,
              deleted=excluded.deleted, row_version=excluded.row_version, updated_at=excluded.updated_at, raw=excluded.raw
            \(newerGuard("folders"))
            """)
            for r in rows {
                try s.run([.text(workspaceId), .text(r.id), .text(channelId), r.parentFolderId.sql, .text(r.title), .int(r.deleted ? 1 : 0),
                           .int(Int64(r.rowVersion)), .text(r.updatedAt), .blob(r.raw)])
                changed += db.changes
            }
            if complete {
                changed += try removeMissing(table: "folders", workspaceId: workspaceId, column: "channel_id", value: channelId, keep: Set(rows.map(\.id)))
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.folders, workspaceId)]) }
        return changed
    }

    // MARK: View states

    /// Stores Tower's view states. A newer local read position (marked on this device, not yet confirmed) is kept.
    @discardableResult
    public func upsertViewStates(workspaceId: String, _ records: [ViewStateRecord], complete: Bool = false) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction {
            var changed = 0
            let s = try db.prepare("""
            INSERT INTO view_states(workspace_id, resource_type, resource_id, scope_id, channel_id, activity_version, viewed_activity_version,
                                    attention_activity_version, row_version, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id, resource_type, resource_id) DO UPDATE SET scope_id=excluded.scope_id, channel_id=excluded.channel_id,
              activity_version=MAX(view_states.activity_version, excluded.activity_version),
              viewed_activity_version=MAX(view_states.viewed_activity_version, excluded.viewed_activity_version),
              attention_activity_version=excluded.attention_activity_version, row_version=excluded.row_version, updated_at=excluded.updated_at
            WHERE excluded.row_version <> view_states.row_version OR excluded.activity_version <> view_states.activity_version
              OR excluded.viewed_activity_version > view_states.viewed_activity_version
              OR excluded.attention_activity_version IS NOT view_states.attention_activity_version
            """)
            for r in rows {
                try s.run([.text(workspaceId), .text(r.resourceType.rawValue), .text(r.resourceId), r.scopeId.sql, r.channelId.sql,
                           .int(Int64(r.activityVersion)), .int(Int64(r.viewedActivityVersion)), r.attentionActivityVersion.map { .int(Int64($0)) } ?? .null,
                           .int(Int64(r.rowVersion)), .text(r.updatedAt)])
                changed += db.changes
            }
            if complete {
                let keep = Set(rows.map(\.id))
                let q = try db.prepare("SELECT resource_type, resource_id FROM view_states WHERE workspace_id = ?")
                try q.bind([.text(workspaceId)])
                var gone: [(String, String)] = []
                while try q.step() { let t = q.text(0)!, r = q.text(1)!; if !keep.contains("\(t):\(r)") { gone.append((t, r)) } }
                let d = try db.prepare("DELETE FROM view_states WHERE workspace_id = ? AND resource_type = ? AND resource_id = ?")
                for (t, r) in gone { try d.run([.text(workspaceId), .text(t), .text(r)]); changed += 1 }
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.viewStates, workspaceId)]) }
        return changed
    }

    /// Marks resources read on this device immediately (the durable write tells Tower).
    public func markViewedLocally(workspaceId: String, _ resources: [(ViewStateRecord.ResourceType, String, Int)]) async throws {
        try db.transaction {
            let s = try db.prepare("""
            UPDATE view_states SET viewed_activity_version = MAX(viewed_activity_version, ?) WHERE workspace_id = ? AND resource_type = ? AND resource_id = ?
            """)
            for (type, id, version) in resources { try s.run([.int(Int64(version)), .text(workspaceId), .text(type.rawValue), .text(id)]) }
        }
        await emit([ChangeKey(.viewStates, workspaceId)])
    }

    // MARK: Reactions

    /// Replaces the reactions of the given targets (each fetch returns a target's complete list).
    public func replaceReactions(workspaceId: String, targets: [String], _ records: [ReactionRecord]) async throws {
        try db.transaction {
            let d = try db.prepare("DELETE FROM reactions WHERE workspace_id = ? AND target_id = ?")
            for target in targets { try d.run([.text(workspaceId), .text(target)]) }
            try writeReactions(records.filter { $0.workspaceId == workspaceId && targets.contains($0.targetId) })
        }
        await emit([ChangeKey(.reactions, workspaceId)])
    }

    func writeReactions(_ records: [ReactionRecord]) throws {
        let s = try db.prepare("""
        INSERT OR REPLACE INTO reactions(workspace_id, id, target_type, target_id, emoji, reactor_npub, deleted, row_version, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?)
        """)
        for r in records where !r.deleted {
            try s.run([.text(r.workspaceId), .text(r.id), .text(r.targetType), .text(r.targetId), .text(r.emoji), r.reactorNpub.sql,
                       .int(0), .int(Int64(r.rowVersion)), .text(r.updatedAt)])
        }
    }

    public func upsertReaction(_ record: ReactionRecord) async throws {
        try writeReactions([record])
        await emit([ChangeKey(.reactions, record.workspaceId)])
    }

    public func deleteReaction(workspaceId: String, id: String) async throws {
        try db.prepare("DELETE FROM reactions WHERE workspace_id = ? AND id = ?").run([.text(workspaceId), .text(id)])
        await emit([ChangeKey(.reactions, workspaceId)])
    }

    // MARK: List sync state

    public func saveListSync(workspaceId: String, key: String, complete: Bool) async throws {
        try db.prepare("""
        INSERT INTO list_sync(workspace_id, key, complete, synced_at) VALUES(?,?,?,?)
        ON CONFLICT(workspace_id, key) DO UPDATE SET complete = excluded.complete, synced_at = excluded.synced_at
        """).run([.text(workspaceId), .text(key), .int(complete ? 1 : 0), .text(now())])
    }
}

/// A document's unsaved edit, kept on the device until Tower accepts it (or the user discards it).
public struct DocDraft: Sendable, Equatable {
    public enum State: String, Sendable { case editing, saving, conflict, recovery, failed }
    public let connectionId: String
    public let workspaceId: String
    public let docId: String
    public let title: String
    /// Complete encoded body in its own representation (what would be uploaded).
    public let body: Data
    public let contentType: String
    public let baseRowVersion: Int
    public let baseSha256: String
    public let baseStorageObjectId: String
    public let state: State
    public let lastError: String?
    public let recoveryId: String?

    public static func key(connectionId: String, workspaceId: String, docId: String) -> String { "\(connectionId):\(workspaceId):\(docId)" }
    public var key: String { Self.key(connectionId: connectionId, workspaceId: workspaceId, docId: docId) }

    public init(connectionId: String, workspaceId: String, docId: String, title: String, body: Data, contentType: String, baseRowVersion: Int,
                baseSha256: String, baseStorageObjectId: String, state: State, lastError: String? = nil, recoveryId: String? = nil) {
        self.connectionId = connectionId; self.workspaceId = workspaceId; self.docId = docId; self.title = title; self.body = body
        self.contentType = contentType; self.baseRowVersion = baseRowVersion; self.baseSha256 = baseSha256
        self.baseStorageObjectId = baseStorageObjectId; self.state = state; self.lastError = lastError; self.recoveryId = recoveryId
    }

    /// State/error labels can change during a retry; body, title and complete base identity define the edit.
    func matchesContentAndBase(_ other: DocDraft) -> Bool {
        key == other.key && body == other.body && title == other.title && contentType == other.contentType
            && baseRowVersion == other.baseRowVersion && baseSha256 == other.baseSha256
            && baseStorageObjectId == other.baseStorageObjectId
    }

    public func with(state: State, error: String? = nil, recoveryId: String? = nil) -> DocDraft {
        DocDraft(connectionId: connectionId, workspaceId: workspaceId, docId: docId, title: title, body: body, contentType: contentType,
                 baseRowVersion: baseRowVersion, baseSha256: baseSha256, baseStorageObjectId: baseStorageObjectId, state: state,
                 lastError: error, recoveryId: recoveryId ?? self.recoveryId)
    }
}

// MARK: Reads

extension StoreReader {
    static let taskColumns = "id, scope_id, channel_id, title, description, state, priority, assigned_to_npub, created_by_npub, row_version, activity_version, created_at, updated_at, raw"

    static func task(_ s: SQLiteConnection.Statement, workspaceId: String) -> TaskRecord {
        TaskRecord(workspaceId: workspaceId, id: s.text(0)!, scopeId: s.text(1), channelId: s.text(2)!, title: s.text(3)!, description: s.text(4),
                   state: s.text(5)!, priority: s.text(6)!, assignedToNpub: s.text(7), createdByNpub: s.text(8), rowVersion: Int(s.int(9)),
                   activityVersion: Int(s.int(10)), createdAt: s.text(11)!, updatedAt: s.text(12)!, raw: s.blob(13))
    }

    /// Tasks of a workspace (optionally one scope), newest activity first, bounded.
    public func tasks(workspaceId: String, scopeId: String? = nil, channelId: String? = nil, includeArchived: Bool = false, limit: Int = 500) throws -> [TaskRecord] {
        let s = try db.prepare("""
        SELECT \(Self.taskColumns) FROM tasks WHERE workspace_id = ? AND (? IS NULL OR scope_id = ?) AND (? IS NULL OR channel_id = ?)
          AND (? = 1 OR state NOT IN ('archive', 'archived')) ORDER BY updated_at DESC, id LIMIT ?
        """)
        try s.bind([.text(workspaceId), scopeId.sql, scopeId.sql, channelId.sql, channelId.sql, .int(includeArchived ? 1 : 0), .int(Int64(limit))])
        var rows: [TaskRecord] = []
        while try s.step() { rows.append(Self.task(s, workspaceId: workspaceId)) }
        return rows
    }

    public func task(workspaceId: String, id: String) throws -> TaskRecord? {
        let s = try db.prepare("SELECT \(Self.taskColumns) FROM tasks WHERE workspace_id = ? AND id = ?")
        try s.bind([.text(workspaceId), .text(id)])
        return try s.step() ? Self.task(s, workspaceId: workspaceId) : nil
    }

    public func comments(workspaceId: String, parent: CommentRecord.Parent, parentId: String, limit: Int = 500) throws -> [CommentRecord] {
        let s = try db.prepare("""
        SELECT id, parent_comment_id, body, sender_npub, status, deleted, row_version, created_at, updated_at, client_record_id, raw FROM comments
        WHERE workspace_id = ? AND parent = ? AND parent_id = ? AND deleted = 0 ORDER BY created_at, id LIMIT ?
        """)
        try s.bind([.text(workspaceId), .text(parent.rawValue), .text(parentId), .int(Int64(limit))])
        var rows: [CommentRecord] = []
        while try s.step() {
            rows.append(CommentRecord(workspaceId: workspaceId, id: s.text(0)!, parent: parent, parentId: parentId, parentCommentId: s.text(1),
                                      body: s.text(2) ?? "", senderNpub: s.text(3), status: s.text(4), deleted: s.int(5) != 0,
                                      rowVersion: Int(s.int(6)), createdAt: s.text(7)!, updatedAt: s.text(8), clientRecordId: s.text(9), raw: s.blob(10)))
        }
        return rows
    }

    static let docColumns = "id, scope_id, channel_id, storage_object_id, title, summary, archived, row_version, activity_version, created_at, updated_at, raw"

    static func doc(_ s: SQLiteConnection.Statement, workspaceId: String) -> DocRecord {
        DocRecord(workspaceId: workspaceId, id: s.text(0)!, scopeId: s.text(1), channelId: s.text(2)!, storageObjectId: s.text(3), title: s.text(4)!,
                  summary: s.text(5), archived: s.int(6) != 0, rowVersion: Int(s.int(7)), activityVersion: Int(s.int(8)),
                  createdAt: s.text(9)!, updatedAt: s.text(10)!, raw: s.blob(11))
    }

    public func docs(workspaceId: String, scopeId: String? = nil, limit: Int = 500) throws -> [DocRecord] {
        let s = try db.prepare("""
        SELECT \(Self.docColumns) FROM docs WHERE workspace_id = ? AND (? IS NULL OR scope_id = ?) AND archived = 0
        ORDER BY updated_at DESC, id LIMIT ?
        """)
        try s.bind([.text(workspaceId), scopeId.sql, scopeId.sql, .int(Int64(limit))])
        var rows: [DocRecord] = []
        while try s.step() { rows.append(Self.doc(s, workspaceId: workspaceId)) }
        return rows
    }

    public func doc(workspaceId: String, id: String) throws -> DocRecord? {
        let s = try db.prepare("SELECT \(Self.docColumns) FROM docs WHERE workspace_id = ? AND id = ?")
        try s.bind([.text(workspaceId), .text(id)])
        return try s.step() ? Self.doc(s, workspaceId: workspaceId) : nil
    }

    public func docBody(workspaceId: String, docId: String) throws -> DocBodyRecord? {
        let s = try db.prepare("""
        SELECT storage_object_id, sha256, content_type, doc_row_version, bytes, fetched_at FROM doc_bodies WHERE workspace_id = ? AND doc_id = ?
        """)
        try s.bind([.text(workspaceId), .text(docId)])
        guard try s.step() else { return nil }
        return DocBodyRecord(workspaceId: workspaceId, docId: docId, storageObjectId: s.text(0)!, sha256: s.text(1)!, contentType: s.text(2)!,
                             docRowVersion: Int(s.int(3)), bytes: s.blob(4), fetchedAt: s.text(5)!)
    }

    public func docDraft(key: String) throws -> DocDraft? {
        let s = try db.prepare("""
        SELECT connection_id, workspace_id, doc_id, title, body, content_type, base_row_version, base_sha256, base_storage_object_id, state,
               last_error, recovery_id FROM doc_drafts WHERE key = ?
        """)
        try s.bind([.text(key)])
        guard try s.step() else { return nil }
        return DocDraft(connectionId: s.text(0)!, workspaceId: s.text(1)!, docId: s.text(2)!, title: s.text(3)!, body: s.blob(4),
                        contentType: s.text(5)!, baseRowVersion: Int(s.int(6)), baseSha256: s.text(7)!, baseStorageObjectId: s.text(8)!,
                        state: DocDraft.State(rawValue: s.text(9) ?? "") ?? .editing, lastError: s.text(10), recoveryId: s.text(11))
    }

    public func docDraftIds(connectionId: String, workspaceId: String) throws -> Set<String> {
        let s = try db.prepare("SELECT doc_id FROM doc_drafts WHERE connection_id = ? AND workspace_id = ?")
        try s.bind([.text(connectionId), .text(workspaceId)])
        var ids = Set<String>()
        while try s.step() { ids.insert(s.text(0)!) }
        return ids
    }

    static let fileColumns = "id, scope_id, channel_id, folder_id, storage_object_id, display_name, description, content_type, size_bytes, sha256, archived, row_version, created_at, updated_at, raw"

    static func file(_ s: SQLiteConnection.Statement, workspaceId: String) -> FileRecord {
        FileRecord(workspaceId: workspaceId, id: s.text(0)!, scopeId: s.text(1), channelId: s.text(2)!, folderId: s.text(3), storageObjectId: s.text(4),
                   displayName: s.text(5)!, description: s.text(6), contentType: s.text(7), sizeBytes: s.isNull(8) ? nil : Int(s.int(8)),
                   sha256: s.text(9), archived: s.int(10) != 0, rowVersion: Int(s.int(11)), createdAt: s.text(12)!, updatedAt: s.text(13)!, raw: s.blob(14))
    }

    public func files(workspaceId: String, channelId: String? = nil, limit: Int = 500) throws -> [FileRecord] {
        let s = try db.prepare("""
        SELECT \(Self.fileColumns) FROM files WHERE workspace_id = ? AND (? IS NULL OR channel_id = ?) AND archived = 0
        ORDER BY display_name COLLATE NOCASE, id LIMIT ?
        """)
        try s.bind([.text(workspaceId), channelId.sql, channelId.sql, .int(Int64(limit))])
        var rows: [FileRecord] = []
        while try s.step() { rows.append(Self.file(s, workspaceId: workspaceId)) }
        return rows
    }

    public func file(workspaceId: String, id: String) throws -> FileRecord? {
        let s = try db.prepare("SELECT \(Self.fileColumns) FROM files WHERE workspace_id = ? AND id = ?")
        try s.bind([.text(workspaceId), .text(id)])
        return try s.step() ? Self.file(s, workspaceId: workspaceId) : nil
    }

    public func folders(workspaceId: String, channelId: String) throws -> [FolderRecord] {
        let s = try db.prepare("""
        SELECT id, parent_folder_id, title, deleted, row_version, updated_at, raw FROM folders WHERE workspace_id = ? AND channel_id = ? AND deleted = 0
        ORDER BY title COLLATE NOCASE, id
        """)
        try s.bind([.text(workspaceId), .text(channelId)])
        var rows: [FolderRecord] = []
        while try s.step() {
            rows.append(FolderRecord(workspaceId: workspaceId, id: s.text(0)!, channelId: channelId, parentFolderId: s.text(1), title: s.text(2)!,
                                     deleted: s.int(3) != 0, rowVersion: Int(s.int(4)), updatedAt: s.text(5)!, raw: s.blob(6)))
        }
        return rows
    }

    public func viewStates(workspaceId: String) throws -> [ViewStateRecord] {
        let s = try db.prepare("""
        SELECT resource_type, resource_id, scope_id, channel_id, activity_version, viewed_activity_version, attention_activity_version, row_version, updated_at
        FROM view_states WHERE workspace_id = ? ORDER BY updated_at DESC
        """)
        try s.bind([.text(workspaceId)])
        var rows: [ViewStateRecord] = []
        while try s.step() {
            guard let type = ViewStateRecord.ResourceType(rawValue: s.text(0) ?? "") else { continue }
            rows.append(ViewStateRecord(workspaceId: workspaceId, resourceType: type, resourceId: s.text(1)!, scopeId: s.text(2), channelId: s.text(3),
                                        activityVersion: Int(s.int(4)), viewedActivityVersion: Int(s.int(5)),
                                        attentionActivityVersion: s.isNull(6) ? nil : Int(s.int(6)), rowVersion: Int(s.int(7)), updatedAt: s.text(8)!))
        }
        return rows
    }

    public func viewState(workspaceId: String, type: ViewStateRecord.ResourceType, id: String) throws -> ViewStateRecord? {
        try viewStates(workspaceId: workspaceId).first { $0.resourceType == type && $0.resourceId == id }
    }

    public func reactions(workspaceId: String, targetIds: [String]) throws -> [ReactionRecord] {
        guard !targetIds.isEmpty else { return [] }
        var rows: [ReactionRecord] = []
        // Bounded IN lists keep the statement small for long conversations.
        for chunk in stride(from: 0, to: targetIds.count, by: 200).map({ Array(targetIds[$0..<min($0 + 200, targetIds.count)]) }) {
            let s = try db.prepare("""
            SELECT id, target_type, target_id, emoji, reactor_npub, row_version, updated_at FROM reactions
            WHERE workspace_id = ? AND deleted = 0 AND target_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
            ORDER BY updated_at, id
            """)
            try s.bind([.text(workspaceId)] + chunk.map(SQLValue.text))
            while try s.step() {
                rows.append(ReactionRecord(workspaceId: workspaceId, id: s.text(0)!, targetType: s.text(1)!, targetId: s.text(2)!, emoji: s.text(3)!,
                                           reactorNpub: s.text(4), rowVersion: Int(s.int(5)), updatedAt: s.text(6)!))
            }
        }
        return rows
    }

    public func listSyncComplete(workspaceId: String, key: String) throws -> Bool? {
        let s = try db.prepare("SELECT complete FROM list_sync WHERE workspace_id = ? AND key = ?")
        try s.bind([.text(workspaceId), .text(key)])
        return try s.step() ? s.int(0) != 0 : nil
    }

    // MARK: Search

    var hasFTS: Bool {
        (try? db.prepare("SELECT 1 FROM sqlite_master WHERE name = 'search_index'")).map { (try? $0.step()) ?? false } ?? false
    }

    /// Searches this workspace's local records only (never the network), newest-relevant first, bounded.
    public func search(workspaceId: String, text: String, limit: Int = 60) throws -> [SearchHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var hits: [(kind: String, id: String)] = []
        if hasFTS, let query = SearchIndex.ftsQuery(trimmed) {
            let s = try db.prepare("SELECT kind, record_id FROM search_index WHERE search_index MATCH ? AND workspace_id = ? ORDER BY rank LIMIT ?")
            try s.bind([.text(query), .text(workspaceId), .int(Int64(limit))])
            while try s.step() { hits.append((s.text(0)!, s.text(1)!)) }
        } else {
            let like = "%" + trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "") + "%"
            for (kind, sql) in [("task", "SELECT id FROM tasks WHERE workspace_id = ? AND (title LIKE ? OR description LIKE ?)"),
                                ("doc", "SELECT id FROM docs WHERE workspace_id = ? AND (title LIKE ? OR coalesce(body_text, summary, '') LIKE ?)"),
                                ("file", "SELECT id FROM files WHERE workspace_id = ? AND (display_name LIKE ? OR description LIKE ?)"),
                                ("message", "SELECT id FROM messages WHERE workspace_id = ? AND deleted = 0 AND (body LIKE ? OR body LIKE ?) ORDER BY created_at DESC")] {
                let s = try db.prepare(sql + " LIMIT \(limit)")
                try s.bind([.text(workspaceId), .text(like), .text(like)])
                while try s.step() { hits.append((kind, s.text(0)!)) }
            }
        }
        var out: [SearchHit] = []
        for hit in hits.prefix(limit) {
            switch hit.kind {
            case "task":
                if let t = try task(workspaceId: workspaceId, id: hit.id) {
                    out.append(SearchHit(kind: .task, recordId: t.id, title: t.title, snippet: t.description.map { String($0.prefix(140)) } ?? (t.taskState?.label ?? t.state),
                                         channelId: t.channelId, threadId: nil))
                }
            case "doc":
                if let d = try doc(workspaceId: workspaceId, id: hit.id) {
                    out.append(SearchHit(kind: .doc, recordId: d.id, title: d.title, snippet: String((d.summary ?? "").prefix(140)), channelId: d.channelId, threadId: nil))
                }
            case "file":
                if let f = try file(workspaceId: workspaceId, id: hit.id) {
                    out.append(SearchHit(kind: .file, recordId: f.id, title: f.displayName, snippet: f.contentType ?? "", channelId: f.channelId, threadId: nil))
                }
            default:
                if let m = try message(workspaceId: workspaceId, id: hit.id), !m.deleted {
                    out.append(SearchHit(kind: .message, recordId: m.id, title: m.senderLabel ?? "Message", snippet: String(MentionCodec.plain(m.body).prefix(160)),
                                         channelId: m.channelId, threadId: m.threadId))
                }
            }
        }
        return out
    }
}
