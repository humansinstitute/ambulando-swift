import Foundation

// Local tables for the Context Tree, canvases (definitions, snapshots, board scenes), agents and their activity, the
// Toolbox and personal pins (schema v4). Every table is workspace-scoped and cleared with the workspace; every read is
// bounded in SQL and runs on the reader actor.

extension Schema {
    /// Workspace-scoped v4 tables, cleared with the workspace.
    static let v4WorkspaceTables = ["context_components", "context_references", "canvases", "canvas_snapshots", "board_scenes", "board_links",
                                    "workspace_agents", "agent_activities", "personal_wapps", "pins"]

    static func migrateV4(_ db: SQLiteConnection) throws {
        try db.execute("""
        CREATE TABLE context_components(
          workspace_id TEXT NOT NULL, scope_id TEXT NOT NULL, id TEXT NOT NULL, parent_id TEXT, title TEXT NOT NULL, sort_order INTEGER NOT NULL,
          row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX context_components_scope ON context_components(workspace_id, scope_id, parent_id, sort_order, id);
        CREATE TABLE context_references(
          workspace_id TEXT NOT NULL, scope_id TEXT NOT NULL, component_id TEXT NOT NULL, id TEXT NOT NULL, target_type TEXT NOT NULL,
          target_id TEXT, status TEXT NOT NULL, sort_order INTEGER NOT NULL, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX context_references_component ON context_references(workspace_id, component_id, sort_order, id);
        CREATE TABLE canvases(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, position INTEGER NOT NULL,
          row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE TABLE canvas_snapshots(
          workspace_id TEXT NOT NULL, canvas_id TEXT NOT NULL, canvas_row_version INTEGER NOT NULL, bytes BLOB NOT NULL, fetched_at TEXT NOT NULL,
          PRIMARY KEY(workspace_id, canvas_id));
        CREATE TABLE board_scenes(
          workspace_id TEXT NOT NULL, file_id TEXT NOT NULL, version_id TEXT NOT NULL, sha256 TEXT NOT NULL, bytes BLOB NOT NULL, fetched_at TEXT NOT NULL,
          PRIMARY KEY(workspace_id, file_id));
        CREATE TABLE board_links(
          workspace_id TEXT NOT NULL, canvas_id TEXT NOT NULL, file_id TEXT NOT NULL,
          PRIMARY KEY(workspace_id, canvas_id, file_id));
        CREATE TABLE workspace_agents(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, agent_npub TEXT NOT NULL, display_name TEXT NOT NULL, sort_order INTEGER NOT NULL,
          visible INTEGER NOT NULL, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE TABLE agent_activities(
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, activity_id TEXT NOT NULL, scope_id TEXT, channel_id TEXT NOT NULL, thread_id TEXT,
          agent_npub TEXT NOT NULL, state TEXT NOT NULL, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(workspace_id, id));
        CREATE INDEX agent_activities_channel ON agent_activities(workspace_id, channel_id, updated_at);
        CREATE TABLE personal_wapps(
          connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, sort_order INTEGER NOT NULL, status TEXT NOT NULL,
          row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(connection_id, workspace_id, id));
        CREATE TABLE pins(
          connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
          workspace_id TEXT NOT NULL, id TEXT NOT NULL, resource_type TEXT NOT NULL, resource_id TEXT NOT NULL, channel_id TEXT, scope_id TEXT,
          pinned INTEGER NOT NULL, row_version INTEGER NOT NULL, updated_at TEXT NOT NULL, raw BLOB NOT NULL,
          PRIMARY KEY(connection_id, workspace_id, id));
        CREATE INDEX pins_resource ON pins(connection_id, workspace_id, resource_type, resource_id);
        """)
    }
}

extension StoreWriter {
    /// Upserts rows of one simple table under the shared row-version guard and, when `complete`, removes rows of the
    /// same partition that Tower no longer lists. Returns the number of rows written or removed.
    /// `connectionId` binds actor-personal tables (pins, personal WApps) to the connection (origin + signer) as well.
    private func replace(table: String, columns: [String], rows: [[SQLValue]], ids: [String], workspaceId: String, connectionId: String? = nil,
                         partition: (column: String, value: String)?, complete: Bool) throws -> Int {
        var changed = 0
        let owner = connectionId.map { _ in "connection_id, " } ?? ""
        let ownerKey = connectionId.map { _ in "connection_id, " } ?? ""
        let ownerFilter = connectionId.map { _ in " AND connection_id = ?" } ?? ""
        let ownerValues: [SQLValue] = connectionId.map { [.text($0)] } ?? []
        let placeholders = Array(repeating: "?", count: columns.count + 1 + ownerValues.count).joined(separator: ",")
        let updates = columns.filter { $0 != "id" }.map { "\($0)=excluded.\($0)" }.joined(separator: ", ")
        let s = try db.prepare("""
        INSERT INTO \(table)(\(owner)workspace_id, \(columns.joined(separator: ", "))) VALUES(\(placeholders))
        ON CONFLICT(\(ownerKey)workspace_id, id) DO UPDATE SET \(updates)
        \(newerGuard(table))
        """)
        for row in rows {
            try s.run(ownerValues + [.text(workspaceId)] + row)
            changed += db.changes
        }
        if complete {
            let filter = partition.map { " AND \($0.column) = ?" } ?? ""
            let existing = try db.prepare("SELECT id FROM \(table) WHERE workspace_id = ?\(ownerFilter)\(filter)")
            try existing.bind([.text(workspaceId)] + ownerValues + (partition.map { [.text($0.value)] } ?? []))
            let keep = Set(ids)
            var gone: [String] = []
            while try existing.step() { if let id = existing.text(0), !keep.contains(id) { gone.append(id) } }
            let delete = try db.prepare("DELETE FROM \(table) WHERE workspace_id = ? AND id = ?\(ownerFilter)")
            for id in gone { try delete.run([.text(workspaceId), .text(id)] + ownerValues) }
            changed += gone.count
        }
        return changed
    }

    /// Board scenes are kept only while a stored canvas snapshot still shows the board to this viewer.
    func purgeUnlinkedBoards(workspaceId: String) throws {
        try db.prepare("DELETE FROM board_links WHERE workspace_id = ? AND canvas_id NOT IN (SELECT canvas_id FROM canvas_snapshots WHERE workspace_id = ?)")
            .run([.text(workspaceId), .text(workspaceId)])
        try db.prepare("DELETE FROM board_scenes WHERE workspace_id = ? AND file_id NOT IN (SELECT file_id FROM board_links WHERE workspace_id = ?)")
            .run([.text(workspaceId), .text(workspaceId)])
    }

    // MARK: Context Tree

    /// Replaces a scope's components (a complete listing removes components deleted on Tower, with their references).
    @discardableResult
    public func upsertContextComponents(workspaceId: String, scopeId: String, _ records: [ContextComponentRecord], complete: Bool) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId && $0.scopeId == scopeId }
        let changed: Int = try db.transaction {
            var changed = try replace(table: "context_components", columns: ["scope_id", "id", "parent_id", "title", "sort_order", "row_version", "updated_at", "raw"],
                                      rows: rows.map { [.text($0.scopeId), .text($0.id), $0.parentId.sql, .text($0.title), .int(Int64($0.sortOrder)),
                                                        .int(Int64($0.rowVersion)), .text($0.updatedAt), .blob($0.raw)] },
                                      ids: rows.map(\.id), workspaceId: workspaceId, partition: ("scope_id", scopeId), complete: complete)
            if complete {
                try db.prepare("""
                DELETE FROM context_references WHERE workspace_id = ? AND scope_id = ?
                  AND component_id NOT IN (SELECT id FROM context_components WHERE workspace_id = ? AND scope_id = ?)
                """).run([.text(workspaceId), .text(scopeId), .text(workspaceId), .text(scopeId)])
                changed += db.changes
            }
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.contextTree, workspaceId)]) }
        return changed
    }

    /// Replaces one component's references with a complete listing.
    @discardableResult
    public func replaceContextReferences(workspaceId: String, scopeId: String, componentId: String, _ records: [ContextReferenceRecord]) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId && $0.scopeId == scopeId && $0.componentId == componentId }
        let changed: Int = try db.transaction {
            try replace(table: "context_references",
                        columns: ["scope_id", "component_id", "id", "target_type", "target_id", "status", "sort_order", "row_version", "updated_at", "raw"],
                        rows: rows.map { [.text($0.scopeId), .text($0.componentId), .text($0.id), .text($0.targetTypeName), $0.targetRecordId.sql,
                                          .text($0.resolution.rawValue), .int(Int64($0.sortOrder)), .int(Int64($0.rowVersion)), .text($0.updatedAt), .blob($0.raw)] },
                        ids: rows.map(\.id), workspaceId: workspaceId, partition: ("component_id", componentId), complete: true)
        }
        if changed > 0 { await emit([ChangeKey(.contextTree, workspaceId)]) }
        return changed
    }

    /// Removes a component (and its references) Tower reports as gone or no longer visible.
    public func removeContextComponent(workspaceId: String, id: String) async throws {
        try db.transaction {
            try db.prepare("DELETE FROM context_references WHERE workspace_id = ? AND component_id = ?").run([.text(workspaceId), .text(id)])
            try db.prepare("DELETE FROM context_components WHERE workspace_id = ? AND id = ?").run([.text(workspaceId), .text(id)])
        }
        await emit([ChangeKey(.contextTree, workspaceId)])
    }

    /// Removes a whole scope's tree (the scope is unavailable to this viewer).
    public func removeContextTree(workspaceId: String, scopeId: String) async throws {
        try db.transaction { try purgeScopeSurfaces(workspaceId: workspaceId, scopeId: scopeId) }
        await emit([ChangeKey(.contextTree, workspaceId), ChangeKey(.access, workspaceId)])
    }

    func purgeScopeSurfaces(workspaceId: String, scopeId: String) throws {
        for table in ["context_references", "context_components"] {
            try db.prepare("DELETE FROM \(table) WHERE workspace_id = ? AND scope_id = ?").run([.text(workspaceId), .text(scopeId)])
        }
    }

    func purgeChannelSurfaces(workspaceId: String, channelId: String) throws {
        try db.prepare("DELETE FROM agent_activities WHERE workspace_id = ? AND channel_id = ?").run([.text(workspaceId), .text(channelId)])
    }

    // MARK: Canvas

    /// Replaces the visible canvas list. Canvases that are no longer visible lose their stored snapshot too.
    @discardableResult
    public func replaceCanvases(workspaceId: String, _ records: [CanvasRecord]) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction {
            var changed = try replace(table: "canvases", columns: ["id", "title", "position", "row_version", "updated_at", "raw"],
                                      rows: rows.map { [.text($0.id), .text($0.title), .int(Int64($0.position)), .int(Int64($0.rowVersion)), .text($0.updatedAt), .blob($0.raw)] },
                                      ids: rows.map(\.id), workspaceId: workspaceId, partition: nil, complete: true)
            try db.prepare("DELETE FROM canvas_snapshots WHERE workspace_id = ? AND canvas_id NOT IN (SELECT id FROM canvases WHERE workspace_id = ?)")
                .run([.text(workspaceId), .text(workspaceId)])
            changed += db.changes
            try purgeUnlinkedBoards(workspaceId: workspaceId)
            return changed
        }
        if changed > 0 { await emit([ChangeKey(.canvases, workspaceId)]) }
        return changed
    }

    /// Stores a fetched snapshot with the canvas definition it came with. The boards it shows become its links; a board
    /// that no stored snapshot shows any more (removed, or now denied to this viewer) loses its stored scene.
    public func saveCanvasSnapshot(_ snapshot: CanvasSnapshotRecord, canvas: CanvasRecord) async throws {
        guard snapshot.workspaceId == canvas.workspaceId, snapshot.canvasId == canvas.id else { throw TowerError.malformed("canvas snapshot") }
        let boards = Set(try CanvasScene.parse(snapshot.bytes).boards.map(\.fileId))
        let changed: Bool = try db.transaction {
            _ = try replace(table: "canvases", columns: ["id", "title", "position", "row_version", "updated_at", "raw"],
                            rows: [[.text(canvas.id), .text(canvas.title), .int(Int64(canvas.position)), .int(Int64(canvas.rowVersion)), .text(canvas.updatedAt), .blob(canvas.raw)]],
                            ids: [canvas.id], workspaceId: canvas.workspaceId, partition: nil, complete: false)
            try db.prepare("""
            INSERT INTO canvas_snapshots(workspace_id, canvas_id, canvas_row_version, bytes, fetched_at) VALUES(?,?,?,?,?)
            ON CONFLICT(workspace_id, canvas_id) DO UPDATE SET canvas_row_version=excluded.canvas_row_version, bytes=excluded.bytes, fetched_at=excluded.fetched_at
            WHERE excluded.bytes IS NOT canvas_snapshots.bytes OR excluded.canvas_row_version IS NOT canvas_snapshots.canvas_row_version
            """).run([.text(snapshot.workspaceId), .text(snapshot.canvasId), .int(Int64(snapshot.canvasRowVersion)), .blob(snapshot.bytes), .text(snapshot.fetchedAt)])
            let stored = db.changes > 0
            let w = SQLValue.text(snapshot.workspaceId), c = SQLValue.text(snapshot.canvasId)
            try db.prepare("DELETE FROM board_links WHERE workspace_id = ? AND canvas_id = ?").run([w, c])
            let link = try db.prepare("INSERT INTO board_links(workspace_id, canvas_id, file_id) VALUES(?,?,?)")
            for board in boards { try link.run([w, c, .text(board)]) }
            try purgeUnlinkedBoards(workspaceId: snapshot.workspaceId)
            return stored
        }
        if changed { await emit([ChangeKey(.canvases, snapshot.workspaceId), ChangeKey(.boards, snapshot.workspaceId)]) }
    }

    /// A canvas that is no longer visible (404 `canvas_unavailable`): its definition and snapshot are removed.
    public func removeCanvas(workspaceId: String, id: String) async throws {
        try db.transaction {
            try db.prepare("DELETE FROM canvas_snapshots WHERE workspace_id = ? AND canvas_id = ?").run([.text(workspaceId), .text(id)])
            try db.prepare("DELETE FROM canvases WHERE workspace_id = ? AND id = ?").run([.text(workspaceId), .text(id)])
            try purgeUnlinkedBoards(workspaceId: workspaceId)
        }
        await emit([ChangeKey(.canvases, workspaceId), ChangeKey(.boards, workspaceId)])
    }

    /// Stores verified board bytes; only the newest fetched version per board is kept, and only while a stored canvas
    /// still shows the board (a fetch that finishes after access was lost stores nothing).
    public func saveBoardScene(_ scene: BoardSceneRecord) async throws {
        try db.prepare("""
        INSERT INTO board_scenes(workspace_id, file_id, version_id, sha256, bytes, fetched_at)
        SELECT ?,?,?,?,?,? WHERE EXISTS (SELECT 1 FROM board_links WHERE workspace_id = ? AND file_id = ?)
        ON CONFLICT(workspace_id, file_id) DO UPDATE SET version_id=excluded.version_id, sha256=excluded.sha256, bytes=excluded.bytes, fetched_at=excluded.fetched_at
        """).run([.text(scene.workspaceId), .text(scene.fileId), .text(scene.versionId), .text(scene.sha256), .blob(scene.bytes), .text(scene.fetchedAt),
                  .text(scene.workspaceId), .text(scene.fileId)])
        if db.changes > 0 { await emit([ChangeKey(.boards, scene.workspaceId)]) }
    }

    // MARK: Agents

    @discardableResult
    public func replaceWorkspaceAgents(workspaceId: String, _ records: [WorkspaceAgentRecord]) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId && !$0.archived }
        let changed: Int = try db.transaction {
            try replace(table: "workspace_agents", columns: ["id", "agent_npub", "display_name", "sort_order", "visible", "row_version", "updated_at", "raw"],
                        rows: rows.map { [.text($0.id), .text($0.agentNpub), .text($0.displayName), .int(Int64($0.sortOrder)), .int($0.isVisible ? 1 : 0),
                                          .int(Int64($0.rowVersion)), .text($0.updatedAt), .blob($0.raw)] },
                        ids: rows.map(\.id), workspaceId: workspaceId, partition: nil, complete: true)
        }
        if changed > 0 { await emit([ChangeKey(.agents, workspaceId)]) }
        return changed
    }

    /// Replaces a channel's stored activity with Tower's newest page for it (the only activity shown natively).
    /// `sequence` stands in for a row version: an older sequence of the same activity never overwrites a newer one.
    @discardableResult
    public func replaceAgentActivities(workspaceId: String, channelId: String, _ records: [AgentActivityRecord]) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId && $0.channelId == channelId }
        let changed: Int = try db.transaction {
            try replace(table: "agent_activities",
                        columns: ["id", "activity_id", "scope_id", "channel_id", "thread_id", "agent_npub", "state", "row_version", "updated_at", "raw"],
                        rows: rows.map { [.text($0.id), .text($0.activityId), $0.scopeId.sql, .text($0.channelId), $0.threadId.sql, .text($0.agentNpub),
                                          .text($0.state), .int(Int64($0.sequence)), .text($0.updatedAt), .blob($0.raw)] },
                        ids: rows.map(\.id), workspaceId: workspaceId, partition: ("channel_id", channelId), complete: true)
        }
        if changed > 0 { await emit([ChangeKey(.agents, workspaceId)]) }
        return changed
    }

    // MARK: Toolbox

    @discardableResult
    public func replacePersonalWapps(connectionId: String, workspaceId: String, _ records: [PersonalWappRecord], complete: Bool = true) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction {
            try replace(table: "personal_wapps", columns: ["id", "title", "sort_order", "status", "row_version", "updated_at", "raw"],
                        rows: rows.map { [.text($0.id), .text($0.title), .int(Int64($0.sortOrder)), .text($0.status), .int(Int64($0.rowVersion)), .text($0.updatedAt), .blob($0.raw)] },
                        ids: rows.map(\.id), workspaceId: workspaceId, connectionId: connectionId, partition: nil, complete: complete)
        }
        if changed > 0 { await emit([ChangeKey(.toolbox, workspaceId)]) }
        return changed
    }

    // MARK: Pins

    /// Upserts pin rows (pinned or tombstoned) for one connection. With `complete`, a pin Tower no longer returns is removed.
    /// Pins are private to the actor: they are stored under the connection (origin + signer) that read them.
    @discardableResult
    public func upsertPins(connectionId: String, workspaceId: String, _ records: [PinRecord], complete: Bool) async throws -> Int {
        let rows = records.filter { $0.workspaceId == workspaceId }
        let changed: Int = try db.transaction { try writePins(connectionId: connectionId, workspaceId: workspaceId, rows, complete: complete) }
        if changed > 0 { await emit([ChangeKey(.pins, workspaceId)]) }
        return changed
    }

    func writePins(connectionId: String, workspaceId: String, _ rows: [PinRecord], complete: Bool) throws -> Int {
        let allIds = rows.map(\.id)
        // A delayed mutation replay may contain older pins than a later sync/tombstone.
        let rows = try rows.filter { row in
            let prior = try db.prepare("SELECT row_version FROM pins WHERE connection_id = ? AND workspace_id = ? AND id = ?")
            try prior.bind([.text(connectionId), .text(workspaceId), .text(row.id)])
            return !(try prior.step()) || prior.int(0) <= row.rowVersion
        }
        return try replace(table: "pins", columns: ["id", "resource_type", "resource_id", "channel_id", "scope_id", "pinned", "row_version", "updated_at", "raw"],
                    rows: rows.map { [.text($0.id), .text($0.resourceType.rawValue), .text($0.resourceId), $0.channelId.sql, $0.scopeId.sql,
                                      .int($0.pinned ? 1 : 0), .int(Int64($0.rowVersion)), .text($0.updatedAt), .blob($0.raw)] },
                    ids: allIds, workspaceId: workspaceId, connectionId: connectionId, partition: nil, complete: complete)
    }
}

/// A pinned record with what the store knows about it, for the sidebar.
public struct PinnedItem: Sendable, Equatable, Identifiable {
    public let pin: PinRecord
    /// The record's title, or nil when it is not stored on this iPhone (no access, or not synced yet).
    public let title: String?
    public let channelId: String?
    public let scopeId: String?
    public var id: String { pin.id }
}

/// A Context Tree node with its children, in Tower's sort order.
public struct ContextNode: Sendable, Equatable, Identifiable {
    public let component: ContextComponentRecord
    public var children: [ContextNode]
    public var id: String { component.id }
}

extension StoreReader {
    private func rows<T>(_ sql: String, _ values: [SQLValue], _ make: (Data) throws -> T) throws -> [T] {
        let s = try db.prepare(sql)
        try s.bind(values)
        var out: [T] = []
        while try s.step() { if let r = try? make(s.blob(0)) { out.append(r) } }
        return out
    }

    // MARK: Context Tree

    public static let contextComponentLimit = 2000

    /// A scope's components as a forest (roots in sort order, children nested). Orphans whose parent is not stored are
    /// shown as roots rather than hidden.
    public func contextTree(workspaceId: String, scopeId: String) throws -> [ContextNode] {
        let all = try rows("SELECT raw FROM context_components WHERE workspace_id = ? AND scope_id = ? ORDER BY sort_order, id LIMIT ?",
                           [.text(workspaceId), .text(scopeId), .int(Int64(Self.contextComponentLimit))], ContextComponentRecord.init(raw:))
        let ids = Set(all.map(\.id))
        var byParent: [String: [ContextComponentRecord]] = [:]
        for c in all { byParent[c.parentId.flatMap { ids.contains($0) ? $0 : nil } ?? "", default: []].append(c) }
        var visited = Set<String>()
        func build(_ c: ContextComponentRecord) -> ContextNode {
            visited.insert(c.id)
            let kids = (byParent[c.id] ?? []).filter { !visited.contains($0.id) }.map(build)
            return ContextNode(component: c, children: kids)
        }
        var roots = (byParent[""] ?? []).map(build)
        // A cycle (never produced by Tower, which refuses circular parents) still surfaces every node once.
        for c in all where !visited.contains(c.id) { roots.append(build(c)) }
        return roots
    }

    public func contextComponent(workspaceId: String, id: String) throws -> ContextComponentRecord? {
        try rows("SELECT raw FROM context_components WHERE workspace_id = ? AND id = ?", [.text(workspaceId), .text(id)], ContextComponentRecord.init(raw:)).first
    }

    public func contextReferences(workspaceId: String, componentId: String) throws -> [ContextReferenceRecord] {
        try rows("SELECT raw FROM context_references WHERE workspace_id = ? AND component_id = ? ORDER BY sort_order, id LIMIT 500",
                 [.text(workspaceId), .text(componentId)], ContextReferenceRecord.init(raw:))
    }

    // MARK: Canvas

    public func canvases(workspaceId: String) throws -> [CanvasRecord] {
        let s = try db.prepare("SELECT raw FROM canvases WHERE workspace_id = ? ORDER BY position, id LIMIT 500")
        try s.bind([.text(workspaceId)])
        var out: [CanvasRecord] = []
        while try s.step() { if let c = try? CanvasRecord(raw: s.blob(0), workspaceId: workspaceId) { out.append(c) } }
        return out
    }

    public func canvas(workspaceId: String, id: String) throws -> CanvasRecord? {
        let s = try db.prepare("SELECT raw FROM canvases WHERE workspace_id = ? AND id = ?")
        try s.bind([.text(workspaceId), .text(id)])
        return try s.step() ? try? CanvasRecord(raw: s.blob(0), workspaceId: workspaceId) : nil
    }

    public func canvasSnapshot(workspaceId: String, canvasId: String) throws -> CanvasSnapshotRecord? {
        let s = try db.prepare("SELECT canvas_row_version, bytes, fetched_at FROM canvas_snapshots WHERE workspace_id = ? AND canvas_id = ?")
        try s.bind([.text(workspaceId), .text(canvasId)])
        guard try s.step() else { return nil }
        return CanvasSnapshotRecord(workspaceId: workspaceId, canvasId: canvasId, canvasRowVersion: Int(s.int(0)), bytes: s.blob(1), fetchedAt: s.text(2) ?? "")
    }

    /// Canvas ids that have a stored snapshot (refreshed when canvas events arrive).
    public func snapshotCanvasIds(workspaceId: String) throws -> [String] {
        let s = try db.prepare("SELECT canvas_id FROM canvas_snapshots WHERE workspace_id = ? ORDER BY fetched_at DESC LIMIT 20")
        try s.bind([.text(workspaceId)])
        var out: [String] = []
        while try s.step() { if let id = s.text(0) { out.append(id) } }
        return out
    }

    public func boardScene(workspaceId: String, fileId: String) throws -> BoardSceneRecord? {
        let s = try db.prepare("SELECT version_id, sha256, bytes, fetched_at FROM board_scenes WHERE workspace_id = ? AND file_id = ?")
        try s.bind([.text(workspaceId), .text(fileId)])
        guard try s.step() else { return nil }
        return BoardSceneRecord(workspaceId: workspaceId, fileId: fileId, versionId: s.text(0) ?? "", sha256: s.text(1) ?? "", bytes: s.blob(2), fetchedAt: s.text(3) ?? "")
    }

    // MARK: Agents

    public func workspaceAgents(workspaceId: String) throws -> [WorkspaceAgentRecord] {
        try rows("SELECT raw FROM workspace_agents WHERE workspace_id = ? AND visible = 1 ORDER BY sort_order, display_name COLLATE NOCASE, id LIMIT 200",
                 [.text(workspaceId)], WorkspaceAgentRecord.init(raw:))
    }

    /// Newest activity across the given channels (nil = every channel), bounded.
    public func agentActivities(workspaceId: String, channelIds: [String]?, limit: Int = 100) throws -> [AgentActivityRecord] {
        if let channelIds {
            guard !channelIds.isEmpty else { return [] }
            let marks = Array(repeating: "?", count: channelIds.count).joined(separator: ",")
            return try rows("SELECT raw FROM agent_activities WHERE workspace_id = ? AND channel_id IN (\(marks)) ORDER BY updated_at DESC, id LIMIT ?",
                            [.text(workspaceId)] + channelIds.map { .text($0) } + [.int(Int64(limit))], AgentActivityRecord.init(raw:))
        }
        return try rows("SELECT raw FROM agent_activities WHERE workspace_id = ? ORDER BY updated_at DESC, id LIMIT ?",
                        [.text(workspaceId), .int(Int64(limit))], AgentActivityRecord.init(raw:))
    }

    // MARK: Toolbox

    public func personalWapps(connectionId: String, workspaceId: String) throws -> [PersonalWappRecord] {
        try rows("""
        SELECT raw FROM personal_wapps WHERE connection_id = ? AND workspace_id = ? AND status = 'active'
        ORDER BY sort_order, title COLLATE NOCASE, id LIMIT 200
        """, [.text(connectionId), .text(workspaceId)], PersonalWappRecord.init(raw:))
    }

    public func personalWapp(connectionId: String, workspaceId: String, id: String) throws -> PersonalWappRecord? {
        try rows("SELECT raw FROM personal_wapps WHERE connection_id = ? AND workspace_id = ? AND id = ?",
                 [.text(connectionId), .text(workspaceId), .text(id)], PersonalWappRecord.init(raw:)).first
    }

    // MARK: Pins

    /// The stored pin row for a resource type/id (pinned or tombstoned).
    public func pin(connectionId: String, workspaceId: String, type: PinRecord.ResourceType, resourceId: String) throws -> PinRecord? {
        try rows("SELECT raw FROM pins WHERE connection_id = ? AND workspace_id = ? AND resource_type = ? AND resource_id = ? LIMIT 1",
                 [.text(connectionId), .text(workspaceId), .text(type.rawValue), .text(resourceId)], PinRecord.init(raw:)).first
    }

    /// Pinned items in Tower's order, with titles from the local store where the record is stored.
    public func pinnedItems(connectionId: String, workspaceId: String) throws -> [PinnedItem] {
        let pins = try rows("SELECT raw FROM pins WHERE connection_id = ? AND workspace_id = ? AND pinned = 1 LIMIT 500",
                            [.text(connectionId), .text(workspaceId)], PinRecord.init(raw:))
            .sorted(by: PinRecord.displayOrder)
        return try pins.map { pin in
            switch pin.resourceType {
            case .task:
                let t = try task(workspaceId: workspaceId, id: pin.resourceId)
                return PinnedItem(pin: pin, title: t?.title, channelId: t?.channelId ?? pin.channelId, scopeId: t?.scopeId ?? pin.scopeId)
            case .document:
                let d = try doc(workspaceId: workspaceId, id: pin.resourceId)
                return PinnedItem(pin: pin, title: d?.title, channelId: d?.channelId ?? pin.channelId, scopeId: d?.scopeId ?? pin.scopeId)
            case .channel:
                let c = try channel(workspaceId: workspaceId, id: pin.resourceId)
                return PinnedItem(pin: pin, title: c?.name, channelId: c?.id, scopeId: c?.scopeId ?? pin.scopeId)
            case .thread:
                let t = try thread(workspaceId: workspaceId, id: pin.resourceId)
                var title = t?.title
                if title?.isEmpty != false, let source = t?.sourceMessageId, let m = try message(workspaceId: workspaceId, id: source) {
                    title = String(m.body.prefix(80))
                }
                return PinnedItem(pin: pin, title: t == nil ? nil : (title?.isEmpty == false ? title : "Conversation"),
                                  channelId: t?.channelId ?? pin.channelId, scopeId: pin.scopeId)
            }
        }
    }
}
