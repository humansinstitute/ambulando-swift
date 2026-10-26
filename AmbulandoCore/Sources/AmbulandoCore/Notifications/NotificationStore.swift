import Foundation

// Local notification inbox (schema v7). One row per item the signed-in identity may see in one workspace; the hydrated
// partition is exactly the `inbox` (not dismissed, not archived). Archived items are stored only after the user asked
// for them. Rows are keyed by connection as well as workspace because two identities have different inboxes.

extension Schema {
    static let v7WorkspaceTables = ["notification_items", "notification_sync"]

    static func migrateV7(_ db: SQLiteConnection) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS notification_items(
          connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
          workspace_id TEXT NOT NULL, id TEXT NOT NULL,
          change_seq INTEGER NOT NULL, row_version INTEGER NOT NULL,
          category TEXT NOT NULL, source_app_id TEXT NOT NULL, severity TEXT NOT NULL,
          is_read INTEGER NOT NULL, is_dismissed INTEGER NOT NULL, is_archived INTEGER NOT NULL,
          pending_read INTEGER, pending_dismissed INTEGER, pending_archived INTEGER,
          gen INTEGER NOT NULL DEFAULT 0,
          occurred_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(connection_id, workspace_id, id));
        CREATE INDEX IF NOT EXISTS notification_items_time ON notification_items(connection_id, workspace_id, occurred_at DESC, id);
        CREATE TABLE IF NOT EXISTS notification_sync(
          connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
          workspace_id TEXT NOT NULL,
          state TEXT NOT NULL, local_seq INTEGER NOT NULL DEFAULT 0, head_seq INTEGER NOT NULL DEFAULT 0,
          started_at TEXT, synced_at TEXT, counts BLOB, archived_hydrated INTEGER NOT NULL DEFAULT 0,
          last_error TEXT, checked_at TEXT, reset_at TEXT,
          hydrating INTEGER NOT NULL DEFAULT 0, hydrate_gen INTEGER NOT NULL DEFAULT 0, hydrate_seq INTEGER, hydrate_cursor TEXT,
          archive_cursor TEXT, archive_complete INTEGER NOT NULL DEFAULT 1,
          PRIMARY KEY(connection_id, workspace_id));
        """)
    }
}

/// A local user-state change not yet accepted by Tower, applied over the stored server state while it is pending.
public struct NotificationPatch: Sendable, Equatable {
    public var read: Bool?
    public var dismissed: Bool?
    public var archived: Bool?
    public init(read: Bool? = nil, dismissed: Bool? = nil, archived: Bool? = nil) { self.read = read; self.dismissed = dismissed; self.archived = archived }
    public var isEmpty: Bool { read == nil && dismissed == nil && archived == nil }
}

/// The stored row, before pending changes are applied.
struct StoredNotification {
    let item: NotificationItem
    let pending: NotificationPatch
    var effective: NotificationItem {
        if pending.isEmpty { return item }
        return item.withState(read: pending.read, dismissed: pending.dismissed, archived: pending.archived) ?? item
    }
}

extension StoreWriter {
    private static let notificationColumns = """
    change_seq, row_version, category, source_app_id, severity, is_read, is_dismissed, is_archived, occurred_at, raw
    """

    private func upsertNotification(connectionId: String, _ item: NotificationItem) throws {
        try db.prepare("""
        INSERT INTO notification_items(connection_id, workspace_id, id, change_seq, row_version, category, source_app_id, severity,
                                       is_read, is_dismissed, is_archived, gen, occurred_at, raw)
        VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,
               COALESCE((SELECT hydrate_gen FROM notification_sync WHERE connection_id = ?1 AND workspace_id = ?2), 0),?12,?13)
        ON CONFLICT(connection_id, workspace_id, id) DO UPDATE SET change_seq=excluded.change_seq, row_version=excluded.row_version,
          category=excluded.category, source_app_id=excluded.source_app_id, severity=excluded.severity, is_read=excluded.is_read,
          is_dismissed=excluded.is_dismissed, is_archived=excluded.is_archived, gen=excluded.gen, occurred_at=excluded.occurred_at, raw=excluded.raw
        WHERE excluded.change_seq >= notification_items.change_seq
        """).run([.text(connectionId), .text(item.workspaceId), .text(item.id), .int(Int64(item.changeSeq)), .int(Int64(item.rowVersion)),
                  .text(item.category), .text(item.sourceAppId), .text(item.severity), .int(item.isRead ? 1 : 0), .int(item.isDismissed ? 1 : 0),
                  .int(item.isArchived ? 1 : 0), .text(item.occurredAt), .blob(item.raw)])
    }

    private func notificationExists(_ connectionId: String, _ workspaceId: String, _ id: String) throws -> Bool {
        let s = try db.prepare("SELECT 1 FROM notification_items WHERE connection_id = ? AND workspace_id = ? AND id = ?")
        try s.bind([.text(connectionId), .text(workspaceId), .text(id)])
        return try s.step()
    }

    private func deleteNotification(_ connectionId: String, _ workspaceId: String, _ id: String) throws {
        try db.prepare("DELETE FROM notification_items WHERE connection_id = ? AND workspace_id = ? AND id = ?")
            .run([.text(connectionId), .text(workspaceId), .text(id)])
    }

    private func archivedHydrated(_ connectionId: String, _ workspaceId: String) throws -> Bool {
        let s = try db.prepare("SELECT archived_hydrated FROM notification_sync WHERE connection_id = ? AND workspace_id = ?")
        try s.bind([.text(connectionId), .text(workspaceId)])
        return try s.step() && s.int(0) != 0
    }

    /// Applies one ascending page of `changes` and records `through_seq`, in one transaction. Idempotent by
    /// `(id, change_seq)`. An unknown item that enters a partition this device does not hold (dismissed, or archived
    /// before the archive was requested) is ignored, but the sequence still advances. A removal deletes the row and with
    /// it every word of its text.
    public func applyNotificationChanges(connectionId: String, workspaceId: String, _ changes: [NotificationChange], throughSeq: Int, headSeq: Int) async throws {
        try db.transaction {
            let archiveHeld = try archivedHydrated(connectionId, workspaceId)
            for change in changes.sorted(by: { $0.changeSeq < $1.changeSeq }) {
                switch change {
                case .removed(let id, _, _):
                    try deleteNotification(connectionId, workspaceId, id)
                case .upsert(let item):
                    guard item.workspaceId == workspaceId else { continue }
                    let known = try notificationExists(connectionId, workspaceId, item.id)
                    if item.isDismissed || (item.isArchived && !archiveHeld) {
                        if known { try deleteNotification(connectionId, workspaceId, item.id) }
                        continue
                    }
                    try upsertNotification(connectionId: connectionId, item)
                }
            }
            try db.prepare("""
            INSERT INTO notification_sync(connection_id, workspace_id, state, local_seq, head_seq, synced_at, checked_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(connection_id, workspace_id) DO UPDATE SET state = excluded.state, local_seq = MAX(notification_sync.local_seq, excluded.local_seq),
              head_seq = MAX(notification_sync.head_seq, excluded.head_seq), synced_at = excluded.synced_at, checked_at = excluded.checked_at, last_error = NULL
            """).run([.text(connectionId), .text(workspaceId), .text(NotificationSyncState.ready.rawValue), .int(Int64(throughSeq)), .int(Int64(headSeq)),
                      .text(now()), .text(now())])
        }
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    /// Starts (or restarts) the inbox listing at snapshot sequence `snapshotSeq`. The listing may take several jobs: this
    /// records the generation, the sequence read with the first page and (later) the next page cursor, so a later job
    /// resumes exactly there. Nothing is removed and `local_seq` does not move until the listing reaches its end.
    @discardableResult
    public func beginNotificationHydration(connectionId: String, workspaceId: String, snapshotSeq: Int) async throws -> Int {
        let gen: Int = try db.transaction {
            try db.prepare("""
            INSERT INTO notification_sync(connection_id, workspace_id, state, hydrating, hydrate_gen, hydrate_seq, hydrate_cursor)
            VALUES(?,?,?,1,1,?,NULL)
            ON CONFLICT(connection_id, workspace_id) DO UPDATE SET hydrating = 1, hydrate_gen = notification_sync.hydrate_gen + 1,
              hydrate_seq = excluded.hydrate_seq, hydrate_cursor = NULL, state = ?
            """).run([.text(connectionId), .text(workspaceId), .text(NotificationSyncState.cold.rawValue), .int(Int64(snapshotSeq)),
                      .text(NotificationSyncState.cold.rawValue)])
            let s = try db.prepare("SELECT hydrate_gen FROM notification_sync WHERE connection_id = ? AND workspace_id = ?")
            try s.bind([.text(connectionId), .text(workspaceId)])
            return try s.step() ? Int(s.int(0)) : 1
        }
        await emit([ChangeKey(.notifications, workspaceId)])
        return gen
    }

    /// Stores one listing page of generation `gen` and the cursor to resume from. A page of a superseded generation is
    /// dropped (a restart happened meanwhile). Returns false in that case.
    @discardableResult
    public func storeNotificationHydrationPage(connectionId: String, workspaceId: String, gen: Int, items: [NotificationItem], nextCursor: String?) async throws -> Bool {
        let stored: Bool = try db.transaction {
            let s = try db.prepare("SELECT hydrate_gen, hydrating FROM notification_sync WHERE connection_id = ? AND workspace_id = ?")
            try s.bind([.text(connectionId), .text(workspaceId)])
            guard try s.step(), Int(s.int(0)) == gen, s.int(1) != 0 else { return false }
            for item in items where item.workspaceId == workspaceId && !item.isDismissed && !item.isArchived {
                // A listing row never replaces a newer replayed or confirmed one.
                try upsertNotification(connectionId: connectionId, item)
            }
            try db.prepare("UPDATE notification_sync SET hydrate_cursor = ? WHERE connection_id = ? AND workspace_id = ?")
                .run([nextCursor.sql, .text(connectionId), .text(workspaceId)])
            return true
        }
        if stored { await emit([ChangeKey(.notifications, workspaceId)]) }
        return stored
    }

    /// The listing reached its end: what the listing did not mention (and has no unsent change) leaves the inbox, replay
    /// starts at the snapshot sequence, and only now is the inbox ready.
    public func finishNotificationHydration(connectionId: String, workspaceId: String, gen: Int, startedAt: String?) async throws {
        try db.transaction {
            let s = try db.prepare("SELECT hydrate_gen, hydrating, hydrate_seq FROM notification_sync WHERE connection_id = ? AND workspace_id = ?")
            try s.bind([.text(connectionId), .text(workspaceId)])
            guard try s.step(), Int(s.int(0)) == gen, s.int(1) != 0 else { return }
            let seq = s.int(2)
            try db.prepare("""
            DELETE FROM notification_items WHERE connection_id = ? AND workspace_id = ? AND gen <> ? AND is_dismissed = 0 AND is_archived = 0
              AND pending_read IS NULL AND pending_dismissed IS NULL AND pending_archived IS NULL
            """).run([.text(connectionId), .text(workspaceId), .int(Int64(gen))])
            try db.prepare("""
            UPDATE notification_sync SET state = ?, hydrating = 0, hydrate_cursor = NULL, local_seq = ?, head_seq = MAX(head_seq, ?),
              started_at = COALESCE(?, started_at), synced_at = ?, checked_at = ?, last_error = NULL, reset_at = NULL
            WHERE connection_id = ? AND workspace_id = ?
            """).run([.text(NotificationSyncState.ready.rawValue), .int(seq), .int(seq), startedAt.sql, .text(now()), .text(now()),
                      .text(connectionId), .text(workspaceId)])
        }
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    /// Convenience for tests and small inboxes: list, store and finish in one step.
    public func replaceNotificationInbox(connectionId: String, workspaceId: String, items: [NotificationItem], snapshotSeq: Int, startedAt: String?) async throws {
        let gen = try await beginNotificationHydration(connectionId: connectionId, workspaceId: workspaceId, snapshotSeq: snapshotSeq)
        try await storeNotificationHydrationPage(connectionId: connectionId, workspaceId: workspaceId, gen: gen, items: items, nextCursor: nil)
        try await finishNotificationHydration(connectionId: connectionId, workspaceId: workspaceId, gen: gen, startedAt: startedAt)
    }

    /// Archived items fetched on demand, a page at a time. From the first page on, `changes` keeps archived items current
    /// (so nothing archived meanwhile is missed); `nextCursor` is where the next job continues, nil when complete.
    public func storeArchivedNotifications(connectionId: String, workspaceId: String, items: [NotificationItem], nextCursor: String?) async throws {
        try db.transaction {
            for item in items where item.workspaceId == workspaceId && item.isArchived && !item.isDismissed { try upsertNotification(connectionId: connectionId, item) }
            try db.prepare("""
            INSERT INTO notification_sync(connection_id, workspace_id, state, archived_hydrated, archive_cursor, archive_complete) VALUES(?,?,?,1,?,?)
            ON CONFLICT(connection_id, workspace_id) DO UPDATE SET archived_hydrated = 1, archive_cursor = excluded.archive_cursor,
              archive_complete = excluded.archive_complete
            """).run([.text(connectionId), .text(workspaceId), .text(NotificationSyncState.cold.rawValue), nextCursor.sql, .int(nextCursor == nil ? 1 : 0)])
        }
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    /// The archive cursor Tower no longer accepts: list the archive again from its first page.
    public func resetArchivedNotificationCursor(connectionId: String, workspaceId: String) async throws {
        try db.prepare("UPDATE notification_sync SET archive_cursor = NULL, archive_complete = 0 WHERE connection_id = ? AND workspace_id = ?")
            .run([.text(connectionId), .text(workspaceId)])
    }

    public func saveNotificationCounts(connectionId: String, workspaceId: String, _ counts: NotificationCounts) async throws {
        let data = try JSONEncoder().encode(counts)
        try db.prepare("""
        UPDATE notification_sync SET counts = ?, head_seq = MAX(head_seq, ?), started_at = COALESCE(?, started_at)
        WHERE connection_id = ? AND workspace_id = ?
        """).run([.blob(data), .int(Int64(counts.headSeq)), counts.inboxStartedAt.sql, .text(connectionId), .text(workspaceId)])
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    /// Records the outcome of a check without changing the stored inbox (unsupported backend, refused access, an error).
    public func markNotificationSync(connectionId: String, workspaceId: String, state: NotificationSyncState?, error: String? = nil) async throws {
        try db.prepare("""
        INSERT INTO notification_sync(connection_id, workspace_id, state, last_error, checked_at) VALUES(?,?,?,?,?)
        ON CONFLICT(connection_id, workspace_id) DO UPDATE SET state = COALESCE(?, notification_sync.state), last_error = excluded.last_error,
          checked_at = excluded.checked_at
        """).run([.text(connectionId), .text(workspaceId), .text((state ?? .cold).rawValue), error.sql, .text(now()), state.map { .text($0.rawValue) } ?? .null])
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    /// The sequence is no longer trustworthy (Tower said `reset_required`, or counts disagree): the next job lists the
    /// inbox again. Pending local changes are kept and re-applied.
    public func resetNotificationCursor(connectionId: String, workspaceId: String) async throws {
        try db.prepare("UPDATE notification_sync SET state = ?, local_seq = 0, hydrating = 0, hydrate_cursor = NULL, reset_at = ? WHERE connection_id = ? AND workspace_id = ?")
            .run([.text(NotificationSyncState.cold.rawValue), .text(now()), .text(connectionId), .text(workspaceId)])
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    /// Removes every stored notification of a workspace for one identity (access refused, membership gone).
    public func purgeNotifications(connectionId: String, workspaceId: String, state: NotificationSyncState = .noAccess) async throws {
        try db.transaction {
            try db.prepare("DELETE FROM notification_items WHERE connection_id = ? AND workspace_id = ?").run([.text(connectionId), .text(workspaceId)])
            try db.prepare("""
            INSERT INTO notification_sync(connection_id, workspace_id, state, checked_at) VALUES(?,?,?,?)
            ON CONFLICT(connection_id, workspace_id) DO UPDATE SET state = excluded.state, local_seq = 0, head_seq = 0, counts = NULL,
              archived_hydrated = 0, hydrating = 0, hydrate_cursor = NULL, archive_cursor = NULL, archive_complete = 1, checked_at = excluded.checked_at
            """).run([.text(connectionId), .text(workspaceId), .text(state.rawValue), .text(now())])
        }
        await emit([ChangeKey(.notifications, workspaceId), ChangeKey(.access, workspaceId)])
    }

    // MARK: Local (optimistic) changes

    /// Applies a user's change on this device immediately. The patch stays pending (and over the server state) until
    /// Tower accepts it or it is cleared.
    public func setNotificationPending(connectionId: String, workspaceId: String, ids: [String], _ patch: NotificationPatch) async throws {
        try db.transaction {
            let s = try db.prepare("""
            UPDATE notification_items SET pending_read = COALESCE(?, pending_read), pending_dismissed = COALESCE(?, pending_dismissed),
              pending_archived = COALESCE(?, pending_archived)
            WHERE connection_id = ? AND workspace_id = ? AND id = ?
            """)
            let read: SQLValue = (patch.read ?? ((patch.dismissed == true || patch.archived == true) ? true : nil)).map { .int($0 ? 1 : 0) } ?? .null
            let dismissed: SQLValue = patch.dismissed.map { .int($0 ? 1 : 0) } ?? .null
            let archived: SQLValue = patch.archived.map { .int($0 ? 1 : 0) } ?? .null
            for id in ids { try s.run([read, dismissed, archived, .text(connectionId), .text(workspaceId), .text(id)]) }
        }
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    public func clearNotificationPending(connectionId: String, workspaceId: String, ids: [String]) async throws {
        try db.transaction {
            let s = try db.prepare("""
            UPDATE notification_items SET pending_read = NULL, pending_dismissed = NULL, pending_archived = NULL
            WHERE connection_id = ? AND workspace_id = ? AND id = ?
            """)
            for id in ids { try s.run([.text(connectionId), .text(workspaceId), .text(id)]) }
        }
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    /// Tower accepted a change and returned the item: store it, drop the pending overlay, and leave the hydrated
    /// partition if the item left it.
    public func acknowledgeNotification(connectionId: String, workspaceId: String, _ item: NotificationItem) async throws {
        try db.transaction {
            let archiveHeld = try archivedHydrated(connectionId, workspaceId)
            // Further changes to this item may still be queued behind this one: their optimistic state stays over the server's.
            let more = try db.prepare("SELECT 1 FROM writes WHERE connection_id = ? AND workspace_id = ? AND target_id = ? AND kind = ? LIMIT 1")
            try more.bind([.text(connectionId), .text(workspaceId), .text(item.id), .text(WriteKind.notificationState.rawValue)])
            let othersQueued = try more.step()
            if item.isDismissed || (item.isArchived && !archiveHeld) {
                try deleteNotification(connectionId, workspaceId, item.id)
            } else {
                try upsertNotification(connectionId: connectionId, item)
                if !othersQueued {
                    try db.prepare("""
                    UPDATE notification_items SET pending_read = NULL, pending_dismissed = NULL, pending_archived = NULL
                    WHERE connection_id = ? AND workspace_id = ? AND id = ?
                    """).run([.text(connectionId), .text(workspaceId), .text(item.id)])
                }
            }
        }
        await emit([ChangeKey(.notifications, workspaceId)])
    }
}

extension StoreReader {
    private static let notificationSelect = """
    SELECT raw, pending_read, pending_dismissed, pending_archived FROM notification_items
    """

    private static func stored(_ s: SQLiteConnection.Statement) -> StoredNotification? {
        guard let item = NotificationItem(raw: s.blob(0)) else { return nil }
        func flag(_ column: Int32) -> Bool? { s.isNull(column) ? nil : s.int(column) != 0 }
        return StoredNotification(item: item, pending: NotificationPatch(read: flag(1), dismissed: flag(2), archived: flag(3)))
    }

    /// Items to show, newest first, with pending local changes applied. `archived` returns the archived partition
    /// (empty until it has been requested).
    public func notifications(connectionId: String, workspaceId: String, filter: NotificationFilter, category: String? = nil, limit: Int = 400) throws -> [NotificationItem] {
        let s = try db.prepare(Self.notificationSelect + """
         WHERE connection_id = ? AND workspace_id = ? AND (? IS NULL OR category = ?)
         ORDER BY occurred_at DESC, id DESC LIMIT ?
        """)
        try s.bind([.text(connectionId), .text(workspaceId), category.sql, category.sql, .int(Int64(limit * 2))])
        var rows: [NotificationItem] = []
        while try s.step() {
            guard let stored = Self.stored(s) else { continue }
            let item = stored.effective
            if filter.includes(item) { rows.append(item) }
            if rows.count == limit { break }
        }
        return rows
    }

    /// Unread items in the inbox partition, pending changes applied.
    public func notificationUnreadCount(connectionId: String, workspaceId: String) throws -> Int {
        let s = try db.prepare("""
        SELECT COUNT(*) FROM notification_items WHERE connection_id = ? AND workspace_id = ?
          AND COALESCE(pending_dismissed, is_dismissed) = 0 AND COALESCE(pending_archived, is_archived) = 0 AND COALESCE(pending_read, is_read) = 0
        """)
        try s.bind([.text(connectionId), .text(workspaceId)])
        return try s.step() ? Int(s.int(0)) : 0
    }

    public func notificationItem(connectionId: String, workspaceId: String, id: String) throws -> NotificationItem? {
        let s = try db.prepare(Self.notificationSelect + " WHERE connection_id = ? AND workspace_id = ? AND id = ?")
        try s.bind([.text(connectionId), .text(workspaceId), .text(id)])
        return try s.step() ? Self.stored(s)?.effective : nil
    }

    /// The server-confirmed (not optimistic) row, for building the next request's `expected_row_version`.
    public func storedNotificationRowVersion(connectionId: String, workspaceId: String, id: String) throws -> Int? {
        let s = try db.prepare("SELECT row_version FROM notification_items WHERE connection_id = ? AND workspace_id = ? AND id = ?")
        try s.bind([.text(connectionId), .text(workspaceId), .text(id)])
        return try s.step() ? Int(s.int(0)) : nil
    }

    public func pendingNotificationIds(connectionId: String, workspaceId: String) throws -> Set<String> {
        let s = try db.prepare("""
        SELECT id FROM notification_items WHERE connection_id = ? AND workspace_id = ?
          AND (pending_read IS NOT NULL OR pending_dismissed IS NOT NULL OR pending_archived IS NOT NULL)
        """)
        try s.bind([.text(connectionId), .text(workspaceId)])
        var ids = Set<String>()
        while try s.step() { if let id = s.text(0) { ids.insert(id) } }
        return ids
    }

    public func notificationStatus(connectionId: String, workspaceId: String) throws -> NotificationSyncStatus {
        let s = try db.prepare("""
        SELECT state, local_seq, head_seq, started_at, synced_at, counts, archived_hydrated, last_error, checked_at, reset_at, hydrating, hydrate_gen, hydrate_seq, hydrate_cursor, archive_cursor, archive_complete FROM notification_sync
        WHERE connection_id = ? AND workspace_id = ?
        """)
        try s.bind([.text(connectionId), .text(workspaceId)])
        var status = NotificationSyncStatus()
        guard try s.step() else { return status }
        status.state = NotificationSyncState(rawValue: s.text(0) ?? "") ?? .cold
        status.localSeq = Int(s.int(1)); status.headSeq = Int(s.int(2))
        status.startedAt = s.text(3); status.syncedAt = s.text(4)
        status.counts = s.isNull(5) ? nil : try? JSONDecoder().decode(NotificationCounts.self, from: s.blob(5))
        status.archivedHydrated = s.int(6) != 0
        status.lastError = s.text(7); status.checkedAt = s.text(8); status.resetAt = s.text(9)
        status.hydrating = s.int(10) != 0; status.hydrateGen = Int(s.int(11)); status.hydrateSeq = s.isNull(12) ? nil : Int(s.int(12))
        status.hydrateCursor = s.text(13); status.archiveCursor = s.text(14); status.archiveIncomplete = status.archivedHydrated && s.int(15) == 0
        return status
    }

    /// The whole screen state in one read.
    public func notificationSnapshot(connectionId: String, workspaceId: String, filter: NotificationFilter, category: String?) throws -> NotificationSnapshot {
        var snapshot = NotificationSnapshot()
        snapshot.items = try notifications(connectionId: connectionId, workspaceId: workspaceId, filter: filter, category: category)
        snapshot.unread = try notificationUnreadCount(connectionId: connectionId, workspaceId: workspaceId)
        snapshot.status = try notificationStatus(connectionId: connectionId, workspaceId: workspaceId)
        snapshot.pendingIds = try pendingNotificationIds(connectionId: connectionId, workspaceId: workspaceId)
        snapshot.categories = try notificationCategories(connectionId: connectionId, workspaceId: workspaceId)
        snapshot.rejected = try notificationRejections(connectionId: connectionId, workspaceId: workspaceId)
        return snapshot
    }

    /// Notification changes that did not apply (refused, rejected, or overtaken by newer activity), until acknowledged.
    public func notificationRejections(connectionId: String, workspaceId: String) throws -> [NotificationRejection] {
        try writes(connectionId: connectionId, workspaceId: workspaceId)
            .filter { ($0.kind == .notificationState || $0.kind == .notificationBulk) && ($0.state == .failed || $0.state == .conflict) }
            .map { NotificationRejection(id: $0.id, message: $0.lastError ?? "A notification change could not be applied.") }
    }

    /// Distinct categories present locally, for the category filter.
    public func notificationCategories(connectionId: String, workspaceId: String) throws -> [String] {
        let s = try db.prepare("SELECT DISTINCT category FROM notification_items WHERE connection_id = ? AND workspace_id = ? ORDER BY category")
        try s.bind([.text(connectionId), .text(workspaceId)])
        var rows: [String] = []
        while try s.step() { if let c = s.text(0) { rows.append(c) } }
        return rows
    }
}

extension StoreWriter {
    /// Tower accepted a change without returning items (a bulk change): the pending patch becomes the stored state. The
    /// row keeps its sequence and version, so the replayed server row replaces it, and a user action in between is
    /// settled by the compare-and-set conflict path.
    public func confirmNotificationPending(connectionId: String, workspaceId: String, ids: [String]) async throws {
        for id in ids {
            guard let item = try await storedNotificationForConfirm(connectionId: connectionId, workspaceId: workspaceId, id: id) else { continue }
            let confirmed = item.effective
            let held = try archivedHeld(connectionId, workspaceId)
            if confirmed.isDismissed || (confirmed.isArchived && !held) {
                try db.prepare("DELETE FROM notification_items WHERE connection_id = ? AND workspace_id = ? AND id = ?")
                    .run([.text(connectionId), .text(workspaceId), .text(id)])
            } else {
                try db.prepare("""
                UPDATE notification_items SET is_read = ?, is_dismissed = ?, is_archived = ?, raw = ?,
                  pending_read = NULL, pending_dismissed = NULL, pending_archived = NULL
                WHERE connection_id = ? AND workspace_id = ? AND id = ?
                """).run([.int(confirmed.isRead ? 1 : 0), .int(confirmed.isDismissed ? 1 : 0), .int(confirmed.isArchived ? 1 : 0), .blob(confirmed.raw),
                          .text(connectionId), .text(workspaceId), .text(id)])
            }
        }
        await emit([ChangeKey(.notifications, workspaceId)])
    }

    private func archivedHeld(_ connectionId: String, _ workspaceId: String) throws -> Bool {
        let s = try db.prepare("SELECT archived_hydrated FROM notification_sync WHERE connection_id = ? AND workspace_id = ?")
        try s.bind([.text(connectionId), .text(workspaceId)])
        return try s.step() && s.int(0) != 0
    }

    private func storedNotificationForConfirm(connectionId: String, workspaceId: String, id: String) async throws -> StoredNotification? {
        let s = try db.prepare("SELECT raw, pending_read, pending_dismissed, pending_archived FROM notification_items WHERE connection_id = ? AND workspace_id = ? AND id = ?")
        try s.bind([.text(connectionId), .text(workspaceId), .text(id)])
        guard try s.step(), let item = NotificationItem(raw: s.blob(0)) else { return nil }
        func flag(_ column: Int32) -> Bool? { s.isNull(column) ? nil : s.int(column) != 0 }
        return StoredNotification(item: item, pending: NotificationPatch(read: flag(1), dismissed: flag(2), archived: flag(3)))
    }

    /// Marks the rows of the hydrated inbox with `change_seq ≤ upToSeq` read on this device at once (optionally one
    /// category). Returns the ids it marked, which the queued bulk write remembers.
    public func markNotificationsReadUpTo(connectionId: String, workspaceId: String, upToSeq: Int, category: String?) async throws -> [String] {
        let ids: [String] = try db.transaction {
            let s = try db.prepare("""
            SELECT id FROM notification_items WHERE connection_id = ? AND workspace_id = ? AND change_seq <= ?
              AND COALESCE(pending_dismissed, is_dismissed) = 0 AND COALESCE(pending_archived, is_archived) = 0
              AND COALESCE(pending_read, is_read) = 0 AND (? IS NULL OR category = ?)
            """)
            try s.bind([.text(connectionId), .text(workspaceId), .int(Int64(upToSeq)), category.sql, category.sql])
            var ids: [String] = []
            while try s.step() { if let id = s.text(0) { ids.append(id) } }
            let mark = try db.prepare("UPDATE notification_items SET pending_read = 1 WHERE connection_id = ? AND workspace_id = ? AND id = ?")
            for id in ids { try mark.run([.text(connectionId), .text(workspaceId), .text(id)]) }
            return ids
        }
        if !ids.isEmpty { await emit([ChangeKey(.notifications, workspaceId)]) }
        return ids
    }

    /// A server item stored without touching a newer pending change (the current state after a compare-and-set conflict).
    public func storeServerNotification(connectionId: String, workspaceId: String, _ item: NotificationItem) async throws {
        guard item.workspaceId == workspaceId else { return }
        try db.prepare("""
        UPDATE notification_items SET change_seq = ?, row_version = ?, category = ?, source_app_id = ?, severity = ?, is_read = ?, is_dismissed = ?,
          is_archived = ?, occurred_at = ?, raw = ? WHERE connection_id = ? AND workspace_id = ? AND id = ? AND change_seq <= ?
        """).run([.int(Int64(item.changeSeq)), .int(Int64(item.rowVersion)), .text(item.category), .text(item.sourceAppId), .text(item.severity),
                  .int(item.isRead ? 1 : 0), .int(item.isDismissed ? 1 : 0), .int(item.isArchived ? 1 : 0), .text(item.occurredAt), .blob(item.raw),
                  .text(connectionId), .text(workspaceId), .text(item.id), .int(Int64(item.changeSeq))])
        await emit([ChangeKey(.notifications, workspaceId)])
    }
}

extension StoreWriter {
    /// A change the person made twice on the same card (read, then archive) is queued twice against the same rendered
    /// version. When the first is accepted, the second continues from the version Tower just produced: it saw the same
    /// content, so this chains only the person's own preceding writes. A write made on a different view (another version
    /// or content) is left alone and meets Tower's compare-and-set.
    public func chainNotificationWrites(connectionId: String, workspaceId: String, id: String, after writeId: String, base: Int, seenDigest: String,
                                        rowVersion: Int, changeSeq: Int) async throws {
        let s = try db.prepare("""
        SELECT id, payload FROM writes WHERE connection_id = ? AND workspace_id = ? AND target_id = ? AND kind = ? AND id <> ? AND state IN ('queued', 'retrying')
        """)
        try s.bind([.text(connectionId), .text(workspaceId), .text(id), .text(WriteKind.notificationState.rawValue), .text(writeId)])
        var chained: [String] = []
        while try s.step() {
            guard let object = (try? JSONSerialization.jsonObject(with: s.blob(1))) as? [String: Any],
                  object["base_row_version"] as? Int == base, object["seen_digest"] as? String == seenDigest else { continue }
            chained.append(s.text(0)!)
        }
        for write in chained {
            try await updateWritePayload(id: write, merging: ["expected_row_version": rowVersion, "observed_change_seq": changeSeq, "base_row_version": rowVersion])
        }
    }
}
