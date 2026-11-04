import Foundation

// Stored agent lifecycles and their public commentary (schema v9). Lifecycles are merged, never blindly replaced, so a
// snapshot that was fetched before a stream event cannot undo it (design §10); commentary is immutable history kept
// per lifecycle, bounded, and removed with its lifecycle, channel or workspace.

extension Schema {
    static let v9WorkspaceTables = ["agent_activity_commentary"]

    static func migrateV9(_ db: SQLiteConnection) throws {
        let info = try db.prepare("PRAGMA table_info(agent_activities)")
        var columns = Set<String>()
        while try info.step() { if let name = info.text(1) { columns.insert(name) } }
        if !columns.contains("created_at") { try db.execute("ALTER TABLE agent_activities ADD COLUMN created_at TEXT") }
        if !columns.contains("commentary_progress") { try db.execute("ALTER TABLE agent_activities ADD COLUMN commentary_progress TEXT") }
        try db.execute("""
        UPDATE agent_activities SET created_at = COALESCE(json_extract(CAST(raw AS TEXT), '$.created_at'), updated_at) WHERE created_at IS NULL;
        CREATE INDEX IF NOT EXISTS agent_activities_thread ON agent_activities(workspace_id, thread_id, created_at);
        CREATE TABLE IF NOT EXISTS agent_activity_commentary(
          workspace_id TEXT NOT NULL, activity_row_id TEXT NOT NULL, channel_id TEXT NOT NULL, thread_id TEXT, turn_id TEXT,
          sequence INTEGER NOT NULL, delivery_cursor TEXT, label TEXT, summary TEXT, body TEXT, created_at TEXT NOT NULL,
          PRIMARY KEY(workspace_id, activity_row_id, sequence));
        CREATE INDEX IF NOT EXISTS agent_activity_commentary_channel ON agent_activity_commentary(workspace_id, channel_id);
        """)
    }
}

extension StoreWriter {
    /// Entries kept per lifecycle (the newest by producer sequence) and lifecycles kept per channel (newest created).
    public static let commentaryPerActivity = 50
    public static let activitiesPerChannel = 50

    /// Merges lifecycles and commentary from a snapshot page or stream events (`AgentLiveness.merge`). `progress`
    /// advances a lifecycle's commentary recovery cursor (never backwards); `seedProgress` gives lifecycles without
    /// one Tower's high-water cursor (first materialisation of a display page).
    @discardableResult
    public func mergeAgentActivities(workspaceId: String, _ records: [AgentActivityRecord], commentary: [AgentCommentaryEntry] = [],
                                     progress: [String: String] = [:], seedProgress: Bool = false) async throws -> Int {
        let changed: Int = try db.transaction { try mergeActivities(workspaceId: workspaceId, records, commentary: commentary, progress: progress, seedProgress: seedProgress) }
        if changed > 0 { await emit([ChangeKey(.agents, workspaceId)]) }
        return changed
    }

    /// Applies one `GET agent-activities` page of a channel (or one thread of it). A lifecycle Tower did not list is
    /// removed only when the page proves it gone: it is inside the page's window (newer than the page's oldest row, or
    /// the page was not full) and was created well before Tower answered, so a lifecycle that started while the page
    /// was in flight is never lost.
    @discardableResult
    public func applyAgentActivityPage(workspaceId: String, channelId: String, threadId: String? = nil, _ page: TowerAPI.AgentActivityPage,
                                       limit: Int, seedProgress: Bool = false) async throws -> Int {
        let records = page.activities.filter { $0.workspaceId == workspaceId && $0.channelId == channelId && (threadId == nil || $0.threadId == threadId) }
        let changed: Int = try db.transaction {
            var changed = try mergeActivities(workspaceId: workspaceId, records, commentary: page.commentary, progress: [:], seedProgress: seedProgress)
            if let served = page.serverTime {
                let floor = records.count >= limit ? records.map(\.createdAt).min() : nil
                let settled = ISO8601DateFormatter.tower.string(from: served.addingTimeInterval(-5))
                let listed = Set(records.map(\.id))
                let s = try db.prepare("SELECT id, created_at FROM agent_activities WHERE workspace_id = ? AND channel_id = ?" + (threadId == nil ? "" : " AND thread_id = ?"))
                try s.bind([.text(workspaceId), .text(channelId)] + (threadId.map { [.text($0)] } ?? []))
                var gone: [String] = []
                while try s.step() {
                    guard let id = s.text(0), !listed.contains(id) else { continue }
                    let created = s.text(1) ?? ""
                    if let floor, created < floor { continue }   // older than this page: kept until pruned by count
                    if created < settled { gone.append(id) }
                }
                changed += try removeActivities(workspaceId: workspaceId, gone)
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.agents, workspaceId)]) }
        return changed
    }

    /// Applies lease changes to stored lifecycles. A renewal replaces the lease only when its `(epoch, sequence)` is
    /// newer; an expiry applies only to the epoch it names and only if no later renewal of that epoch is stored (its
    /// deadline is at least the stored one). Terminal lifecycles and other turns are untouched.
    @discardableResult
    public func applyAgentLeases(workspaceId: String, _ changes: [(rowId: String, turnId: String?, lease: AgentLease)]) async throws -> Int {
        guard !changes.isEmpty else { return 0 }
        let changed: Int = try db.transaction {
            var changed = 0
            let read = try db.prepare("SELECT raw FROM agent_activities WHERE workspace_id = ? AND id = ?")
            let write = try db.prepare("UPDATE agent_activities SET raw = ? WHERE workspace_id = ? AND id = ?")
            for change in changes {
                try read.bind([.text(workspaceId), .text(change.rowId)])
                guard try read.step(), let stored = try? AgentActivityRecord(raw: read.blob(0)), !stored.isTerminal else { continue }
                if let turn = change.turnId, let mine = stored.turnId, turn != mine { continue }
                let current = AgentLease(stored)
                var next = current
                if change.lease.sequence != nil, change.lease.expiredAt == nil {
                    guard change.lease.supersedes(current) else { continue }
                    next = change.lease
                } else if let expired = change.lease.expiredAt {
                    guard (current.epoch ?? 1) == change.lease.epoch, current.expiredAt == nil,
                          let deadline = change.lease.expiresAt, (current.expiresAt ?? .distantPast) <= deadline else { continue }
                    next.epoch = change.lease.epoch
                    next.expiredAt = expired
                } else { continue }
                let updated = stored.with(lease: next, turnId: stored.turnId)
                guard updated.raw != stored.raw else { continue }
                try write.run([.blob(updated.raw), .text(workspaceId), .text(stored.id)])
                changed += db.changes
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.agents, workspaceId)]) }
        return changed
    }

    /// No `channel.read` any more: nothing of that channel's activity stays on the device.
    public func purgeAgentActivities(workspaceId: String, channelId: String) async throws {
        let removed: Int = try db.transaction {
            try db.prepare("DELETE FROM agent_activity_commentary WHERE workspace_id = ? AND channel_id = ?").run([.text(workspaceId), .text(channelId)])
            try db.prepare("DELETE FROM agent_activities WHERE workspace_id = ? AND channel_id = ?").run([.text(workspaceId), .text(channelId)])
            return db.changes
        }
        if removed > 0 { await emit([ChangeKey(.agents, workspaceId)]) }
    }

    private func mergeActivities(workspaceId: String, _ records: [AgentActivityRecord], commentary: [AgentCommentaryEntry],
                                 progress: [String: String], seedProgress: Bool) throws -> Int {
        var changed = 0
        var channels = Set<String>()
        let read = try db.prepare("SELECT raw FROM agent_activities WHERE workspace_id = ? AND id = ?")
        let upsert = try db.prepare("""
        INSERT INTO agent_activities(workspace_id, id, activity_id, scope_id, channel_id, thread_id, agent_npub, state, row_version, updated_at, raw, created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(workspace_id, id) DO UPDATE SET activity_id=excluded.activity_id, scope_id=excluded.scope_id, state=excluded.state,
          row_version=excluded.row_version, updated_at=excluded.updated_at, raw=excluded.raw
        """)
        for record in records where record.workspaceId == workspaceId {
            try read.bind([.text(workspaceId), .text(record.id)])
            let stored = try read.step() ? try? AgentActivityRecord(raw: read.blob(0)) : nil
            if let stored, stored.channelId != record.channelId || stored.threadId != record.threadId || stored.activityId != record.activityId { continue }
            guard let merged = AgentLiveness.merge(stored, record), merged.raw != stored?.raw else { continue }
            try upsert.run([.text(workspaceId), .text(merged.id), .text(merged.activityId), merged.scopeId.sql, .text(merged.channelId), merged.threadId.sql,
                            .text(merged.agentNpub), .text(merged.state), .int(Int64(merged.sequence)), .text(merged.updatedAt), .blob(merged.raw),
                            .text(merged.createdAt)])
            changed += db.changes
            channels.insert(merged.channelId)
        }
        if seedProgress {
            let seed = try db.prepare("UPDATE agent_activities SET commentary_progress = ? WHERE workspace_id = ? AND id = ? AND commentary_progress IS NULL")
            for record in records { if let cursor = record.commentaryCursor { try seed.run([.text(cursor), .text(workspaceId), .text(record.id)]) } }
        }
        let advance = try db.prepare("""
        UPDATE agent_activities SET commentary_progress = ?1 WHERE workspace_id = ?2 AND id = ?3
          AND (commentary_progress IS NULL OR CAST(commentary_progress AS INTEGER) < CAST(?1 AS INTEGER))
        """)
        for (id, cursor) in progress where AgentCommentaryEntry.validCursor(cursor) { try advance.run([.text(cursor), .text(workspaceId), .text(id)]) }
        // History is immutable: an entry already stored is never rewritten. Only entries of a stored lifecycle (with its
        // channel and thread) are kept.
        let insert = try db.prepare("""
        INSERT OR IGNORE INTO agent_activity_commentary(workspace_id, activity_row_id, channel_id, thread_id, turn_id, sequence, delivery_cursor, label, summary, body, created_at)
        SELECT workspace_id, id, channel_id, thread_id, ?, ?, ?, ?, ?, ?, ? FROM agent_activities WHERE workspace_id = ? AND id = ?
        """)
        var touched = Set<String>()
        for entry in commentary {
            try insert.run([entry.turnId.sql, .int(Int64(entry.sequence)), entry.deliveryCursor.sql, entry.label.sql, entry.summary.sql, entry.body.sql,
                            .text(entry.createdAt), .text(workspaceId), .text(entry.activityRowId)])
            if db.changes > 0 { changed += 1; touched.insert(entry.activityRowId) }
        }
        let prune = try db.prepare("""
        DELETE FROM agent_activity_commentary WHERE workspace_id = ?1 AND activity_row_id = ?2 AND sequence NOT IN
          (SELECT sequence FROM agent_activity_commentary WHERE workspace_id = ?1 AND activity_row_id = ?2 ORDER BY sequence DESC LIMIT ?3)
        """)
        for id in touched { try prune.run([.text(workspaceId), .text(id), .int(Int64(Self.commentaryPerActivity))]) }
        for channel in channels {
            let s = try db.prepare("SELECT id FROM agent_activities WHERE workspace_id = ? AND channel_id = ? ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?")
            try s.bind([.text(workspaceId), .text(channel), .int(Int64(Self.activitiesPerChannel))])
            var old: [String] = []
            while try s.step() { if let id = s.text(0) { old.append(id) } }
            changed += try removeActivities(workspaceId: workspaceId, old)
        }
        return changed
    }

    private func removeActivities(workspaceId: String, _ ids: [String]) throws -> Int {
        let history = try db.prepare("DELETE FROM agent_activity_commentary WHERE workspace_id = ? AND activity_row_id = ?")
        let row = try db.prepare("DELETE FROM agent_activities WHERE workspace_id = ? AND id = ?")
        var removed = 0
        for id in ids {
            try history.run([.text(workspaceId), .text(id)])
            try row.run([.text(workspaceId), .text(id)])
            removed += db.changes
        }
        return removed
    }
}

extension StoreReader {
    /// The newest lifecycles of one conversation, newest first.
    public func threadAgentActivities(workspaceId: String, threadId: String, limit: Int = 10) throws -> [AgentActivityRecord] {
        let s = try db.prepare("SELECT raw FROM agent_activities WHERE workspace_id = ? AND thread_id = ? ORDER BY created_at DESC, id DESC LIMIT ?")
        try s.bind([.text(workspaceId), .text(threadId), .int(Int64(max(1, min(limit, 50))))])
        var rows: [AgentActivityRecord] = []
        while try s.step() { if let r = try? AgentActivityRecord(raw: s.blob(0)) { rows.append(r) } }
        return rows
    }

    /// The newest `perActivity` public entries of each lifecycle, in producer order.
    public func agentCommentary(workspaceId: String, activityRowIds: [String], perActivity: Int = TowerAPI.agentCommentaryPage) throws -> [String: [AgentCommentaryEntry]] {
        var out: [String: [AgentCommentaryEntry]] = [:]
        let s = try db.prepare("""
        SELECT activity_row_id, turn_id, sequence, delivery_cursor, label, summary, body, created_at FROM agent_activity_commentary
        WHERE workspace_id = ? AND activity_row_id = ? ORDER BY sequence DESC LIMIT ?
        """)
        for id in Set(activityRowIds) {
            try s.bind([.text(workspaceId), .text(id), .int(Int64(max(1, min(perActivity, StoreWriter.commentaryPerActivity))))])
            var entries: [AgentCommentaryEntry] = []
            while try s.step() {
                entries.append(AgentCommentaryEntry(activityRowId: s.text(0) ?? id, turnId: s.text(1), sequence: Int(s.int(2)), deliveryCursor: s.text(3),
                                                    label: s.text(4), summary: s.text(5), body: s.text(6), createdAt: s.text(7) ?? ""))
            }
            out[id] = entries.reversed()
        }
        return out
    }

    /// A lifecycle's commentary recovery cursor (nil: never materialised from a display page).
    public func agentCommentaryProgress(workspaceId: String, activityRowId: String) throws -> String? {
        let s = try db.prepare("SELECT commentary_progress FROM agent_activities WHERE workspace_id = ? AND id = ?")
        try s.bind([.text(workspaceId), .text(activityRowId)])
        return try s.step() ? s.text(0) : nil
    }
}
