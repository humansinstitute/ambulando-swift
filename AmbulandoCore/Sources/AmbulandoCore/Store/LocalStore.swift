import Foundation

public enum StoreTable: String, Sendable, Hashable, CaseIterable {
    case connections, workspaces, scopes, channels, messages, threads, members, drafts, outbox, appState
    case tasks, comments, docs, docBodies, docDrafts, files, folders, viewStates, reactions, writes
}

/// A change notification key. `workspaceId == nil` means "not workspace-scoped".
public struct ChangeKey: Sendable, Hashable {
    public let table: StoreTable
    public let workspaceId: String?
    public init(_ table: StoreTable, _ workspaceId: String? = nil) { self.table = table; self.workspaceId = workspaceId }
}

public struct ConnectionRecord: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let origin: String
    public let signerNpub: String
    public var towerNpub: String?
    public let createdAt: String

    public init(id: String = UUID().uuidString.lowercased(), origin: TowerOrigin, signerNpub: String, towerNpub: String?,
                createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id; self.origin = origin.description; self.signerNpub = signerNpub; self.towerNpub = towerNpub; self.createdAt = createdAt
    }

    init(id: String, origin: String, signerNpub: String, towerNpub: String?, createdAt: String) {
        self.id = id; self.origin = origin; self.signerNpub = signerNpub; self.towerNpub = towerNpub; self.createdAt = createdAt
    }
}

enum Schema {
    static let version = 3

    static func migrate(_ db: SQLiteConnection) throws {
        let current = try db.userVersion
        guard current < version else { return }
        try db.transaction {
            if current < 1 {
                try db.execute("""
                CREATE TABLE connections(
                  id TEXT PRIMARY KEY, origin TEXT NOT NULL, signer_npub TEXT NOT NULL, tower_npub TEXT, created_at TEXT NOT NULL,
                  UNIQUE(origin, signer_npub));
                CREATE TABLE workspaces(
                  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
                  workspace_id TEXT NOT NULL, app_npub TEXT NOT NULL, label TEXT NOT NULL, slug TEXT, tower_base_url TEXT,
                  role TEXT, owner_npub TEXT, raw BLOB NOT NULL, synced_at TEXT NOT NULL,
                  PRIMARY KEY(connection_id, workspace_id));
                CREATE TABLE scopes(
                  workspace_id TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT, description TEXT,
                  default_channel_id TEXT, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
                  PRIMARY KEY(workspace_id, id));
                CREATE TABLE channels(
                  workspace_id TEXT NOT NULL, id TEXT NOT NULL, scope_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT,
                  position REAL, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
                  PRIMARY KEY(workspace_id, id));
                CREATE INDEX channels_scope ON channels(workspace_id, scope_id, position, name);
                CREATE TABLE messages(
                  workspace_id TEXT NOT NULL, id TEXT NOT NULL, channel_id TEXT NOT NULL, thread_id TEXT, body TEXT NOT NULL,
                  sender_npub TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, row_version INTEGER NOT NULL,
                  deleted INTEGER NOT NULL DEFAULT 0, raw BLOB NOT NULL,
                  PRIMARY KEY(workspace_id, id));
                CREATE INDEX messages_channel_time ON messages(workspace_id, channel_id, created_at, id);
                CREATE TABLE app_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
            }
            if current < 2 {
                // Chat: thread structure, directory, drafts, durable outbox and per-channel catch-up state.
                try db.execute("""
                ALTER TABLE messages ADD COLUMN thread_source_id TEXT;
                ALTER TABLE messages ADD COLUMN sender_label TEXT;
                ALTER TABLE messages ADD COLUMN client_request_id TEXT;
                CREATE INDEX messages_thread_time ON messages(workspace_id, thread_id, created_at, id);
                CREATE TABLE threads(
                  workspace_id TEXT NOT NULL, id TEXT NOT NULL, channel_id TEXT NOT NULL, source_message_id TEXT, title TEXT, latest TEXT,
                  archived INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0,
                  row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
                  PRIMARY KEY(workspace_id, id));
                CREATE INDEX threads_channel ON threads(workspace_id, channel_id);
                CREATE TABLE members(
                  workspace_id TEXT NOT NULL, npub TEXT NOT NULL, actor_id TEXT NOT NULL, kind TEXT, display_name TEXT,
                  PRIMARY KEY(workspace_id, npub));
                CREATE TABLE drafts(
                  key TEXT PRIMARY KEY,
                  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
                  workspace_id TEXT NOT NULL, channel_id TEXT NOT NULL, thread_id TEXT,
                  text TEXT NOT NULL, mentions TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE outbox(
                  id TEXT PRIMARY KEY,
                  connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
                  origin TEXT NOT NULL, signer_npub TEXT NOT NULL, workspace_id TEXT NOT NULL, app_npub TEXT NOT NULL,
                  channel_id TEXT NOT NULL, thread_id TEXT, create_thread INTEGER NOT NULL,
                  body TEXT NOT NULL, mentions TEXT NOT NULL, request BLOB,
                  state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_status INTEGER, last_code TEXT, last_error TEXT,
                  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE INDEX outbox_target ON outbox(workspace_id, channel_id, thread_id, created_at);
                CREATE TABLE channel_sync(
                  workspace_id TEXT NOT NULL, channel_id TEXT NOT NULL,
                  resume_cursor TEXT, resume_after_created_at TEXT, resume_after_id TEXT,
                  complete INTEGER NOT NULL DEFAULT 0, synced_at TEXT NOT NULL,
                  PRIMARY KEY(workspace_id, channel_id));
                """)
            }
            if current < 3 { try migrateV3(db) }
            try db.execute("PRAGMA user_version = \(version)")
        }
    }
}

/// Guard shared by every record upsert: never let an older (row_version, updated_at) overwrite a newer row,
/// and skip identical payloads so re-syncing unchanged data produces no change notifications.
func newerGuard(_ table: String) -> String {
    "WHERE (excluded.row_version > \(table).row_version OR (excluded.row_version = \(table).row_version AND excluded.updated_at >= \(table).updated_at)) AND excluded.raw IS NOT \(table).raw"
}

/// The only writer. One serialized connection; every method is one short transaction.
public actor StoreWriter {
    let db: SQLiteConnection
    let changes: ChangeCoalescer

    init(path: String, changes: ChangeCoalescer) throws {
        db = try SQLiteConnection(path: path, readOnly: false)
        self.changes = changes
        try Schema.migrate(db)
    }

    public func schemaVersion() throws -> Int { try db.userVersion }

    func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    func emit(_ keys: Set<ChangeKey>) async { if !keys.isEmpty { await changes.record(keys) } }

    /// Notifies observers that data outside SQLite changed (for example a finished download in the file cache).
    public func touch(_ keys: Set<ChangeKey>) async { await emit(keys) }

    public func saveConnection(_ c: ConnectionRecord) async throws -> ConnectionRecord {
        let saved: ConnectionRecord = try db.transaction {
            try db.prepare("""
            INSERT INTO connections(id, origin, signer_npub, tower_npub, created_at) VALUES(?,?,?,?,?)
            ON CONFLICT(origin, signer_npub) DO UPDATE SET tower_npub = excluded.tower_npub
            """).run([.text(c.id), .text(c.origin), .text(c.signerNpub), c.towerNpub.sql, .text(c.createdAt)])
            let s = try db.prepare("SELECT id, created_at FROM connections WHERE origin = ? AND signer_npub = ?")
            try s.bind([.text(c.origin), .text(c.signerNpub)])
            guard try s.step() else { throw SQLiteError(code: -1, message: "connection not saved") }
            return ConnectionRecord(id: s.text(0)!, origin: c.origin, signerNpub: c.signerNpub, towerNpub: c.towerNpub, createdAt: s.text(1)!)
        }
        await emit([ChangeKey(.connections)])
        return saved
    }

    /// Removes a connection and all workspace data reachable only through it.
    public func removeConnection(id: String) async throws {
        try db.transaction {
            let ids = try workspaceIds(connectionId: id)
            try db.prepare("DELETE FROM connections WHERE id = ?").run([.text(id)])
            for workspace in ids { if try !workspaceStillReferenced(workspace) { try deleteWorkspaceRows(workspace) } }
        }
        await emit(Set(StoreTable.allCases.map { ChangeKey($0) }))
    }

    private func workspaceIds(connectionId: String) throws -> [String] {
        let s = try db.prepare("SELECT workspace_id FROM workspaces WHERE connection_id = ?")
        try s.bind([.text(connectionId)])
        var ids: [String] = []
        while try s.step() { ids.append(s.text(0)!) }
        return ids
    }

    func workspaceStillReferenced(_ workspaceId: String) throws -> Bool {
        let s = try db.prepare("SELECT 1 FROM workspaces WHERE workspace_id = ? LIMIT 1")
        try s.bind([.text(workspaceId)])
        return try s.step()
    }

    func deleteWorkspaceRows(_ workspaceId: String) throws {
        for table in ["scopes", "channels", "messages", "threads", "members", "channel_sync"] + Schema.v3WorkspaceTables {
            try db.prepare("DELETE FROM \(table) WHERE workspace_id = ?").run([.text(workspaceId)])
        }
    }

    /// Replaces the complete workspace list for one connection (authoritative discovery result).
    public func replaceWorkspaces(connectionId: String, _ records: [WorkspaceRecord]) async throws {
        let stamp = now()
        let removed: [String] = try db.transaction {
            let upsert = try db.prepare("""
            INSERT INTO workspaces(connection_id, workspace_id, app_npub, label, slug, tower_base_url, role, owner_npub, raw, synced_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(connection_id, workspace_id) DO UPDATE SET app_npub=excluded.app_npub, label=excluded.label, slug=excluded.slug,
              tower_base_url=excluded.tower_base_url, role=excluded.role, owner_npub=excluded.owner_npub, raw=excluded.raw, synced_at=excluded.synced_at
            """)
            for r in records {
                try upsert.run([.text(connectionId), .text(r.id), .text(r.appNpub), .text(r.label), r.slug.sql, r.towerBaseURL.sql,
                                r.role.sql, r.ownerNpub.sql, .blob(r.raw), .text(stamp)])
            }
            let keep = Set(records.map(\.id))
            let gone = try workspaceIds(connectionId: connectionId).filter { !keep.contains($0) }
            for id in gone {
                try db.prepare("DELETE FROM workspaces WHERE connection_id = ? AND workspace_id = ?").run([.text(connectionId), .text(id)])
                if try !workspaceStillReferenced(id) { try deleteWorkspaceRows(id) }
            }
            return gone
        }
        var keys: Set<ChangeKey> = [ChangeKey(.workspaces)]
        for id in removed {
            keys.formUnion([ChangeKey(.scopes, id), ChangeKey(.channels, id), ChangeKey(.messages, id), ChangeKey(.threads, id), ChangeKey(.members, id),
                            ChangeKey(.tasks, id), ChangeKey(.comments, id), ChangeKey(.docs, id), ChangeKey(.docBodies, id), ChangeKey(.files, id),
                            ChangeKey(.folders, id), ChangeKey(.viewStates, id), ChangeKey(.reactions, id)])
        }
        await emit(keys)
    }

    /// Upserts scopes. When `complete`, rows the actor can no longer see are removed with their channels.
    @discardableResult
    public func upsertScopes(workspaceId: String, _ records: [ScopeRecord], complete: Bool) async throws -> Int {
        let changed: Int = try db.transaction {
            var changed = 0
            let s = try db.prepare("""
            INSERT INTO scopes(workspace_id, id, name, kind, description, default_channel_id, row_version, updated_at, raw)
            VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id, id) DO UPDATE SET name=excluded.name, kind=excluded.kind, description=excluded.description,
              default_channel_id=excluded.default_channel_id, row_version=excluded.row_version, updated_at=excluded.updated_at, raw=excluded.raw
            \(newerGuard("scopes"))
            """)
            for r in records where r.workspaceId == workspaceId {
                try s.run([.text(workspaceId), .text(r.id), .text(r.name), r.kind.sql, r.description.sql, r.defaultChannelId.sql,
                           .int(Int64(r.rowVersion)), .text(r.updatedAt), .blob(r.raw)])
                changed += db.changes
            }
            if complete {
                let keep = Set(records.map(\.id))
                let existing = try db.prepare("SELECT id FROM scopes WHERE workspace_id = ?")
                try existing.bind([.text(workspaceId)])
                var gone: [String] = []
                while try existing.step() { if let id = existing.text(0), !keep.contains(id) { gone.append(id) } }
                for id in gone {
                    try db.prepare("DELETE FROM scopes WHERE workspace_id = ? AND id = ?").run([.text(workspaceId), .text(id)])
                    try db.prepare("DELETE FROM channels WHERE workspace_id = ? AND scope_id = ?").run([.text(workspaceId), .text(id)])
                    changed += 1
                }
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.scopes, workspaceId), ChangeKey(.channels, workspaceId)]) }
        return changed
    }

    @discardableResult
    public func upsertChannels(workspaceId: String, scopeId: String, _ records: [ChannelRecord], complete: Bool) async throws -> Int {
        let changed: Int = try db.transaction {
            var changed = 0
            let s = try db.prepare("""
            INSERT INTO channels(workspace_id, id, scope_id, name, kind, position, row_version, updated_at, raw) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(workspace_id, id) DO UPDATE SET scope_id=excluded.scope_id, name=excluded.name, kind=excluded.kind,
              position=excluded.position, row_version=excluded.row_version, updated_at=excluded.updated_at, raw=excluded.raw
            \(newerGuard("channels"))
            """)
            for r in records where r.workspaceId == workspaceId && r.scopeId == scopeId {
                try s.run([.text(workspaceId), .text(r.id), .text(scopeId), .text(r.name), r.kind.sql, r.position.sql,
                           .int(Int64(r.rowVersion)), .text(r.updatedAt), .blob(r.raw)])
                changed += db.changes
            }
            if complete {
                let keep = Set(records.map(\.id))
                let existing = try db.prepare("SELECT id FROM channels WHERE workspace_id = ? AND scope_id = ?")
                try existing.bind([.text(workspaceId), .text(scopeId)])
                var gone: [String] = []
                while try existing.step() { if let id = existing.text(0), !keep.contains(id) { gone.append(id) } }
                for id in gone {
                    try db.prepare("DELETE FROM channels WHERE workspace_id = ? AND id = ?").run([.text(workspaceId), .text(id)])
                    changed += 1
                }
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.channels, workspaceId)]) }
        return changed
    }

    /// Upserts one batch of messages in a single transaction. Callers keep batches ≤ 500 rows
    /// so a reader is never blocked for long (WAL readers are never blocked by the writer at all).
    @discardableResult
    public func upsertMessages(_ records: [MessageRecord]) async throws -> Int {
        var keys = Set<ChangeKey>()
        let changed: Int = try db.transaction { try writeMessages(records, keys: &keys) }
        await emit(keys)
        return changed
    }

    /// Shared by catch-up and send acknowledgement. A server row carrying the `client_request_id` of one of this
    /// sender's outbox rows retires that row in the same transaction, so a message is never shown twice.
    func writeMessages(_ records: [MessageRecord], keys: inout Set<ChangeKey>) throws -> Int {
        var changed = 0
        let s = try db.prepare("""
        INSERT INTO messages(workspace_id, id, channel_id, thread_id, thread_source_id, body, sender_npub, sender_label, client_request_id,
                             created_at, updated_at, row_version, deleted, raw)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(workspace_id, id) DO UPDATE SET channel_id=excluded.channel_id, thread_id=excluded.thread_id,
          thread_source_id=excluded.thread_source_id, body=excluded.body, sender_npub=excluded.sender_npub, sender_label=excluded.sender_label,
          client_request_id=excluded.client_request_id, updated_at=excluded.updated_at, row_version=excluded.row_version,
          deleted=excluded.deleted, raw=excluded.raw
        \(newerGuard("messages"))
        """)
        let retire = try db.prepare("DELETE FROM outbox WHERE id = ? AND workspace_id = ? AND signer_npub = ?")
        for r in records {
            try s.run([.text(r.workspaceId), .text(r.id), .text(r.channelId), r.threadId.sql, r.threadSourceId.sql, .text(r.body), r.senderNpub.sql,
                       r.senderLabel.sql, r.clientRequestId.sql, .text(r.createdAt), .text(r.updatedAt), .int(Int64(r.rowVersion)),
                       .int(r.deleted ? 1 : 0), .blob(r.raw)])
            if db.changes > 0 { changed += 1; keys.insert(ChangeKey(.messages, r.workspaceId)) }
            if let request = r.clientRequestId, let sender = r.senderNpub {
                try retire.run([.text(request.lowercased()), .text(r.workspaceId), .text(sender)])
                if db.changes > 0 { keys.insert(ChangeKey(.outbox, r.workspaceId)) }
            }
        }
        return changed
    }

    public func setState(_ key: String, _ value: String?) async throws {
        if let value {
            try db.prepare("INSERT INTO app_state(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
                .run([.text(key), .text(value)])
        } else {
            try db.prepare("DELETE FROM app_state WHERE key = ?").run([.text(key)])
        }
        await emit([ChangeKey(.appState)])
    }
}

/// Read-only connection on its own actor. WAL gives it a consistent snapshot while the writer commits.
public actor StoreReader {
    let db: SQLiteConnection

    init(path: String) throws { db = try SQLiteConnection(path: path, readOnly: true) }

    public func connections() throws -> [ConnectionRecord] {
        let s = try db.prepare("SELECT id, origin, signer_npub, tower_npub, created_at FROM connections ORDER BY created_at")
        var rows: [ConnectionRecord] = []
        while try s.step() {
            rows.append(ConnectionRecord(id: s.text(0)!, origin: s.text(1)!, signerNpub: s.text(2)!, towerNpub: s.text(3), createdAt: s.text(4)!))
        }
        return rows
    }

    public func workspaces(connectionId: String) throws -> [WorkspaceRecord] {
        let s = try db.prepare("""
        SELECT workspace_id, app_npub, label, slug, tower_base_url, role, owner_npub, raw FROM workspaces
        WHERE connection_id = ? ORDER BY label COLLATE NOCASE, workspace_id
        """)
        try s.bind([.text(connectionId)])
        var rows: [WorkspaceRecord] = []
        while try s.step() {
            rows.append(WorkspaceRecord(id: s.text(0)!, appNpub: s.text(1)!, label: s.text(2)!, slug: s.text(3), towerBaseURL: s.text(4),
                                        role: s.text(5), ownerNpub: s.text(6), raw: s.blob(7)))
        }
        return rows
    }

    public func scopes(workspaceId: String) throws -> [ScopeRecord] {
        let s = try db.prepare("""
        SELECT id, name, kind, description, default_channel_id, row_version, updated_at, raw FROM scopes
        WHERE workspace_id = ? ORDER BY name COLLATE NOCASE, id
        """)
        try s.bind([.text(workspaceId)])
        var rows: [ScopeRecord] = []
        while try s.step() {
            rows.append(ScopeRecord(workspaceId: workspaceId, id: s.text(0)!, name: s.text(1)!, kind: s.text(2), description: s.text(3),
                                    defaultChannelId: s.text(4), rowVersion: Int(s.int(5)), updatedAt: s.text(6)!, raw: s.blob(7)))
        }
        return rows
    }

    public func channels(workspaceId: String) throws -> [ChannelRecord] {
        let s = try db.prepare("""
        SELECT id, scope_id, name, kind, position, row_version, updated_at, raw FROM channels
        WHERE workspace_id = ? ORDER BY scope_id, position IS NULL, position, name COLLATE NOCASE, id
        """)
        try s.bind([.text(workspaceId)])
        var rows: [ChannelRecord] = []
        while try s.step() {
            rows.append(ChannelRecord(workspaceId: workspaceId, id: s.text(0)!, scopeId: s.text(1)!, name: s.text(2)!, kind: s.text(3),
                                      position: s.isNull(4) ? nil : s.double(4), rowVersion: Int(s.int(5)), updatedAt: s.text(6)!, raw: s.blob(7)))
        }
        return rows
    }

    /// Newest `limit` messages of a channel, returned oldest first for display.
    public func latestMessages(workspaceId: String, channelId: String, limit: Int) throws -> [MessageRecord] {
        let s = try db.prepare("""
        SELECT \(Self.messageColumns) FROM messages
        WHERE workspace_id = ? AND channel_id = ? ORDER BY created_at DESC, id DESC LIMIT ?
        """)
        try s.bind([.text(workspaceId), .text(channelId), .int(Int64(limit))])
        var rows: [MessageRecord] = []
        while try s.step() { rows.append(Self.message(s, workspaceId: workspaceId)) }
        return rows.reversed()
    }

    public func messageCount(workspaceId: String) throws -> Int {
        let s = try db.prepare("SELECT COUNT(*) FROM messages WHERE workspace_id = ?")
        try s.bind([.text(workspaceId)])
        return try s.step() ? Int(s.int(0)) : 0
    }

    public func state(_ key: String) throws -> String? {
        let s = try db.prepare("SELECT value FROM app_state WHERE key = ?")
        try s.bind([.text(key)])
        return try s.step() ? s.text(0) : nil
    }
}

/// Opens (and migrates) the on-device database. All members are actors, so the store is freely shareable.
public final class LocalStore: Sendable {
    public let writer: StoreWriter
    public let reader: StoreReader
    public let changes: ChangeCoalescer
    public let path: String

    public init(directory: URL, coalesceInterval: Duration = .milliseconds(100)) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
        #if os(iOS)
        // Readable after first unlock so opportunistic background refresh can open it.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        path = directory.appendingPathComponent("ambulando.sqlite").path
        changes = ChangeCoalescer(interval: coalesceInterval)
        writer = try StoreWriter(path: path, changes: changes)
        reader = try StoreReader(path: path)
    }
}
